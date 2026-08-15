//
//  UplinkNAT.swift
//  Swiftix
//
//  The in-core "user-mode NAT" engine that turns a Swiftix host into a
//  SLIRP-style NAT gateway. It sits behind the `UplinkTransport` seam
//  (Uplink.swift): when `NetworkStack.dispatchInbound` sees an IPv4 datagram
//  whose destination is not local and an uplink is installed, it hands the
//  datagram here instead of L3-forwarding it.
//
//  Rather than rewriting IP headers and re-emitting packets (which would need a
//  raw packet path / elevated privileges the platform — especially iOS — does
//  not grant), the engine TERMINATES the guest's transport connection: it plays
//  the role of the remote peer, driving a minimal TCP endpoint per guest flow
//  and a connected UDP association per datagram tuple, then relaying payloads
//  over ordinary `UplinkTransport` channels. This is exactly how QEMU user
//  networking / gVisor reach the host network. Because Swiftix is itself a
//  user-space TCP/IP stack, terminating TCP and associating UDP on the guest
//  side is a natural fit.
//
//  TCP flows are terminated by `UplinkTCPFlow`: the guest handshake waits for
//  the real connection to open, payload is relayed in both directions with
//  cumulative-ACK reliability + retransmission, receive windows are honored,
//  and FIN/RST teardown is mirrored. UDP datagrams are relayed through connected
//  `UplinkUDPFlow` associations keyed by the guest/remote four-tuple and removed
//  after 30 seconds of logical inactivity. ICMP is not currently relayed.
//
//  Concurrency contract (R16/R17): `UplinkNAT`, `UplinkTCPFlow`, and
//  `UplinkUDPFlow` are non-Sendable reference types, driven entirely on the
//  single executor that owns the `NetworkStack`'s `EventLoop`. There are no
//  locks and no `@unchecked Sendable`. Connect/retransmit/idle timers use one
//  cancellable scope per active epoch, so ACKs and datagrams cannot accumulate
//  stale callbacks; those scopes pause/resume with the owning stack. The engine
//  holds the stack `unowned`
//  (the stack owns the engine); each flow holds the engine `weak` and routes
//  every stack access through guarded helpers, so a channel callback arriving
//  after teardown cannot touch a dead graph.

/// The connection-tracking NAT engine. Owned by its `NetworkStack`; created by
/// `NetworkStack.installUplink(_:)` and torn down by `removeUplink()` / stack
/// shutdown. Internal: it is implementation detail behind the public
/// `UplinkTransport` seam.
final class UplinkNAT {

    /// Hard admission bounds prevent a guest from turning arbitrary tuples into
    /// an unbounded number of host sockets. The per-guest limit also preserves
    /// capacity for other VMs sharing the hidden gateway.
    private static let maxFlowCount = 1_024
    private static let maxFlowsPerGuest = 128

    /// 4-tuple identifying one guest TCP flow being NATed. The guest's source
    /// (address+port) and the real destination (address+port) it addressed.
    struct FlowKey: Hashable {
        let guestIP: UInt32
        let guestPort: UInt16
        let remoteIP: UInt32
        let remotePort: UInt16
    }

    /// The owning stack (used to emit segments toward the guest and to schedule
    /// timers). `unowned`: the stack owns this engine, so it always outlives it.
    private unowned let stack: NetworkStack

    /// The consumer-provided real-network backend. Non-Sendable; only touched on
    /// the stack's executor.
    private let transport: any UplinkTransport

    /// Live TCP flows keyed by their 4-tuple.
    private var flows: [FlowKey: UplinkTCPFlow] = [:]

    /// Live connected UDP associations keyed by the same guest/remote 4-tuple.
    private var udpFlows: [FlowKey: UplinkUDPFlow] = [:]

    /// Monotonic source of our initial send sequence numbers toward the guest.
    /// Injectable so tests are deterministic.
    private var issCounter: UInt32

    init(stack: NetworkStack, transport: any UplinkTransport, initialISN: UInt32 = 0x0001_0000) {
        self.stack = stack
        self.transport = transport
        self.issCounter = initialISN
    }

    /// Number of live TCP + UDP flows — observed by tests / diagnostics.
    var flowCount: Int { flows.count + udpFlows.count }
    var udpFlowCount: Int { udpFlows.count }

    private func canAdmitFlow(for guestIP: UInt32) -> Bool {
        guard flowCount < Self.maxFlowCount else { return false }
        let guestTCPCount = flows.keys.lazy.filter { $0.guestIP == guestIP }.count
        let guestUDPCount = udpFlows.keys.lazy.filter { $0.guestIP == guestIP }.count
        return guestTCPCount + guestUDPCount < Self.maxFlowsPerGuest
    }

    /// Handle a non-local IPv4 datagram the stack would otherwise forward.
    /// Returns `nil` when the datagram was accepted (handled) or a
    /// `PacketDropReason` when it should be counted as a drop.
    func handleGuestDatagram(_ ipHeader: IPv4Packet.Header, _ ipPayload: ArraySlice<UInt8>) -> PacketDropReason? {
        switch ipHeader.proto {
        case IPProtocol.tcp.rawValue:
            return handleGuestTCP(ipHeader, ipPayload)
        case IPProtocol.udp.rawValue:
            return handleGuestUDP(ipHeader, ipPayload)
        default:
            // ICMP over the uplink is not terminated yet. The datagram is not
            // locally destined and cannot be relayed through an ordinary socket.
            return .notLocalDestination
        }
    }

    private func handleGuestTCP(_ ipHeader: IPv4Packet.Header, _ ipPayload: ArraySlice<UInt8>) -> PacketDropReason? {
        // Verify the TCP checksum over the IPv4 pseudo-header before touching any
        // flow state — a corrupted segment must not create or mutate a flow,
        // mirroring NetworkStack.handleTCP (R8.1/R8.2).
        guard TransportChecksum.verifyTransport(source: ipHeader.source,
                                                destination: ipHeader.destination,
                                                proto: IPProtocol.tcp.rawValue,
                                                segment: Array(ipPayload)) else {
            return .invalidTCPChecksum
        }
        guard let (header, payload) = TCPSegment.parse(ipPayload) else { return .malformedTCP }

        let key = FlowKey(guestIP: ipHeader.source.raw,
                          guestPort: header.sourcePort,
                          remoteIP: ipHeader.destination.raw,
                          remotePort: header.destinationPort)

        if let flow = flows[key] {
            flow.receiveFromGuest(header, Array(payload))
        } else if header.flags.contains(.syn),
                  !header.flags.contains(.ack),
                  !header.flags.contains(.rst) {
            // A fresh active open from the guest: start terminating this flow and
            // open the matching real connection. Refuse deterministically once
            // either the gateway-wide or per-guest host-socket budget is full.
            guard canAdmitFlow(for: key.guestIP) else {
                sendStrayReset(guest: ipHeader.source,
                               remote: ipHeader.destination,
                               header: header,
                               payloadCount: payload.count)
                return .resourceLimit
            }
            let flow = UplinkTCPFlow(engine: self,
                                     key: key,
                                     guest: ipHeader.source,
                                     guestPort: header.sourcePort,
                                     remote: ipHeader.destination,
                                     remotePort: header.destinationPort,
                                     guestISN: header.sequence,
                                     ourISN: nextISN(),
                                     guestWindow: UInt32(header.window),
                                     guestMSS: header.options.firstMSS.map(Int.init) ?? 536)
            flows[key] = flow
            flow.start(transport: transport)
        } else if !header.flags.contains(.rst) {
            // A non-SYN segment matching no flow (and not itself a RST): tell the
            // guest the connection is gone with a RST, mirroring the stack's
            // handling of an unmatched segment (R9).
            sendStrayReset(guest: ipHeader.source, remote: ipHeader.destination, header: header, payloadCount: payload.count)
        }
        return nil
    }

    private func handleGuestUDP(_ ipHeader: IPv4Packet.Header,
                                _ ipPayload: ArraySlice<UInt8>) -> PacketDropReason? {
        guard ipPayload.count >= UDPDatagram.headerLength else { return .malformedUDP }
        let base = ipPayload.startIndex
        let checksumField = (UInt16(ipPayload[base + 6]) << 8) | UInt16(ipPayload[base + 7])
        if checksumField != 0,
           !TransportChecksum.verifyTransport(source: ipHeader.source,
                                              destination: ipHeader.destination,
                                              proto: IPProtocol.udp.rawValue,
                                              segment: ipPayload) {
            return .invalidUDPChecksum
        }
        guard let (header, payload) = UDPDatagram.parse(ipPayload),
              header.length == ipPayload.count else {
            return .malformedUDP
        }

        let key = FlowKey(guestIP: ipHeader.source.raw,
                          guestPort: header.sourcePort,
                          remoteIP: ipHeader.destination.raw,
                          remotePort: header.destinationPort)
        if let flow = udpFlows[key] {
            flow.sendFromGuest(Array(payload))
        } else {
            guard canAdmitFlow(for: key.guestIP) else { return .resourceLimit }
            let flow = UplinkUDPFlow(engine: self,
                                     key: key,
                                     guest: ipHeader.source,
                                     guestPort: header.sourcePort,
                                     remote: ipHeader.destination,
                                     remotePort: header.destinationPort)
            udpFlows[key] = flow
            flow.start(transport: transport, firstPayload: Array(payload))
        }
        return nil
    }

    // MARK: - Flow callbacks

    /// Remove a torn-down TCP flow from tracking.
    func removeFlow(_ key: FlowKey) {
        flows[key] = nil
    }

    /// Remove a torn-down UDP association from tracking.
    func removeUDPFlow(_ key: FlowKey) {
        udpFlows[key] = nil
    }

    /// Cancel every association owned by one guest address. Consumers call this
    /// before releasing that guest's interface/kernel generation so delayed host
    /// callbacks can never target a rebooted VM that reused the same tuple.
    func removeFlows(for guest: IPv4Address) {
        let tcpKeys = flows.keys.filter { $0.guestIP == guest.raw }
        let udpKeys = udpFlows.keys.filter { $0.guestIP == guest.raw }
        let removedTCP = tcpKeys.compactMap { flows.removeValue(forKey: $0) }
        let removedUDP = udpKeys.compactMap { udpFlows.removeValue(forKey: $0) }
        for flow in removedTCP { flow.engineDidShutdown() }
        for flow in removedUDP { flow.engineDidShutdown() }
    }

    /// Current logical time, used by idle tracking without consulting a wall clock.
    var now: Double { stack.loop.now }

    /// Create a physically cancellable timer epoch for one flow. Each scope still
    /// lives on the same loop/executor as the stack.
    func makeTimerScope() -> EventLoop.CancellationScope {
        stack.loop.makeCancellationScope()
    }

    /// Keep per-flow timer scopes aligned with Kernel suspension semantics.
    func pause() {
        for flow in flows.values { flow.engineDidPause() }
        for flow in udpFlows.values { flow.engineDidPause() }
    }

    func resume() {
        for flow in flows.values { flow.engineDidResume() }
        for flow in udpFlows.values { flow.engineDidResume() }
    }

    /// Emit a TCP segment toward the guest as though it came from the real peer
    /// (`source`). The stack stamps the TCP checksum over the (source, guest)
    /// pseudo-header at offset 16 and routes it to the guest over the LAN.
    func emitTCPToGuest(source: IPv4Address, guest: IPv4Address, segment: [UInt8]) {
        stack.emitUplinkTransport(source: source,
                                  destination: guest,
                                  proto: IPProtocol.tcp.rawValue,
                                  segment: segment,
                                  checksumOffset: 16)
    }

    /// Emit one upstream UDP reply toward the guest, preserving its datagram
    /// boundary and forging the addressed real peer as source.
    func emitUDPToGuest(source: IPv4Address,
                        sourcePort: UInt16,
                        guest: IPv4Address,
                        guestPort: UInt16,
                        payload: [UInt8]) {
        let datagram = UDPDatagram.build(sourcePort: sourcePort,
                                         destinationPort: guestPort,
                                         payload: payload)
        stack.emitUplinkTransport(source: source,
                                  destination: guest,
                                  proto: IPProtocol.udp.rawValue,
                                  segment: datagram,
                                  checksumOffset: 6)
    }

    /// Tear down every flow (stack shutdown / uplink removal). Cancels each real
    /// channel and drops all tracking.
    func shutdown() {
        let liveTCP = flows.values
        let liveUDP = udpFlows.values
        flows.removeAll()
        udpFlows.removeAll()
        for flow in liveTCP { flow.engineDidShutdown() }
        for flow in liveUDP { flow.engineDidShutdown() }
    }

    private func nextISN() -> UInt32 {
        issCounter = issCounter &+ 0x0001_0000
        return issCounter
    }

    /// Emit a RST toward the guest for a segment that matched no live flow,
    /// mirroring `NetworkStack.handleTCP`'s unmatched-segment logic (R9.3/R9.4).
    private func sendStrayReset(guest: IPv4Address,
                                remote: IPv4Address,
                                header: TCPSegment.Header,
                                payloadCount: Int) {
        let segment: [UInt8]
        if header.flags.contains(.ack) {
            segment = TCPSegment.build(sourcePort: header.destinationPort,
                                       destinationPort: header.sourcePort,
                                       sequence: header.acknowledgment,
                                       acknowledgment: 0,
                                       flags: [.rst],
                                       window: 0,
                                       payload: [])
        } else {
            let consumed = payloadCount
                + (header.flags.contains(.syn) ? 1 : 0)
                + (header.flags.contains(.fin) ? 1 : 0)
            segment = TCPSegment.build(sourcePort: header.destinationPort,
                                       destinationPort: header.sourcePort,
                                       sequence: 0,
                                       acknowledgment: header.sequence &+ UInt32(consumed),
                                       flags: [.rst, .ack],
                                       window: 0,
                                       payload: [])
        }
        emitTCPToGuest(source: remote, guest: guest, segment: segment)
    }
}

/// Terminates ONE guest TCP connection and relays it to a real `UplinkTCPChannel`.
///
/// It is a deliberately small TCP endpoint: in-order receive with cumulative
/// ACKs, a retransmitting sender toward the guest, guest-receive-window flow
/// control, and FIN/RST teardown in both directions. It is NOT a full RFC 9293
/// implementation (no SACK, no window scaling, no zero-window probing, no
/// TIME_WAIT) — enough to relay real traffic correctly over the FIFO in-app
/// links while keeping the surface reviewable.
final class UplinkTCPFlow: UplinkTCPObserver {

    private enum Phase { case connecting, open, closed }

    // MARK: Tuning
    private static let baseRTO: Double = 1.0
    private static let maxRTO: Double = 8.0
    private static let maxRetransmits = 8
    private static let connectTimeout: Double = 30
    private static let maxBufferedPeerBytes = 1_048_576
    private static let advertisedWindow: UInt16 = 0xFFFF

    // MARK: Identity / peers
    private weak var engine: UplinkNAT?
    private let key: UplinkNAT.FlowKey
    private let guest: IPv4Address
    private let guestPort: UInt16
    private let remote: IPv4Address
    private let remotePort: UInt16

    // MARK: Receive space (guest -> us)
    private let irs: UInt32          // guest's initial sequence number
    private var rcvNxt: UInt32       // next in-order sequence expected from the guest

    // MARK: Send space (us -> guest)
    private let iss: UInt32          // our initial sequence number toward the guest
    private var sndUna: UInt32       // oldest unacknowledged sequence
    private var sndNxt: UInt32       // next sequence number to assign

    // MARK: Flow control / sizing
    private var guestWindow: UInt32  // guest's advertised receive window (unscaled)
    private let maxSegment: Int      // largest payload we put in one guest-bound segment

    // MARK: Buffers
    private var sendQueue: [UInt8] = []     // real-peer bytes not yet segmented to the guest
    private struct Unacked { let seq: UInt32; let bytes: [UInt8]; let syn: Bool; let fin: Bool }
    private var unacked: [Unacked] = []     // segments sent to the guest, awaiting ACK (in order)

    // MARK: State flags
    private var phase: Phase = .connecting
    private var channel: (any UplinkTCPChannel)?
    private var guestFinSeen = false        // guest half-closed (guest -> peer done)
    private var peerFinPending = false      // real peer EOF; FIN owed to the guest after queue drains
    private var finSeqSent: UInt32?         // sequence our FIN occupies once emitted

    // MARK: Reliability
    private var rto = UplinkTCPFlow.baseRTO
    private var retransmits = 0
    private var connectTimer: EventLoop.CancellationScope?
    private var retransmitTimer: EventLoop.CancellationScope?
    private var generation: UInt64 = 0      // extra guard for terminal callbacks

    init(engine: UplinkNAT,
         key: UplinkNAT.FlowKey,
         guest: IPv4Address,
         guestPort: UInt16,
         remote: IPv4Address,
         remotePort: UInt16,
         guestISN: UInt32,
         ourISN: UInt32,
         guestWindow: UInt32,
         guestMSS: Int) {
        self.engine = engine
        self.key = key
        self.guest = guest
        self.guestPort = guestPort
        self.remote = remote
        self.remotePort = remotePort
        self.irs = guestISN
        self.rcvNxt = guestISN &+ 1          // the SYN consumes one sequence number
        self.iss = ourISN
        self.sndUna = ourISN
        self.sndNxt = ourISN
        self.guestWindow = guestWindow
        self.maxSegment = min(max(guestMSS, 1), 1460)
    }

    /// Open the real connection. The guest handshake is completed later, when the
    /// transport reports `uplinkDidOpen` — so a refused upstream is surfaced to
    /// the guest as a refused connection rather than a silent black hole.
    func start(transport: any UplinkTransport) {
        let opened = transport.openTCP(
            to: UplinkEndpoint(host: remote, port: remotePort),
            observer: self)
        // A transport is allowed to fail synchronously from openTCP. In that
        // case teardown has already removed this flow; cancel the inert returned
        // handle instead of retaining it in a closed generation.
        guard phase != .closed else {
            opened.cancel()
            return
        }
        channel = opened

        // A host connection stuck in Network.framework's waiting/preparing state
        // must not pin a flow forever after the guest abandons its SYN.
        guard phase == .connecting, let engine else { return }
        let timeout = engine.makeTimerScope()
        connectTimer = timeout
        let generationAtArm = generation
        timeout.schedule(after: Self.connectTimeout) { [weak self] in
            guard let self,
                  self.phase == .connecting,
                  self.generation == generationAtArm else { return }
            self.connectTimer = nil
            self.sendConnectionRefused()
            self.channel?.cancel()
            self.teardown()
        }
    }

    // MARK: - Guest -> engine

    /// Process one inbound segment from the guest.
    func receiveFromGuest(_ header: TCPSegment.Header, _ payload: [UInt8]) {
        guard phase != .closed else { return }
        guestWindow = UInt32(header.window)

        if header.flags.contains(.rst) {
            // Guest aborted: drop the real connection, no RST back.
            channel?.cancel()
            teardown()
            return
        }

        if header.flags.contains(.ack) { processAck(header.acknowledgment) }

        // Before the handshake completes we only wait for the real connection.
        // Duplicate SYN retransmits and any (unexpected) early data are ignored;
        // the guest will retransmit once we SYN-ACK.
        guard phase == .open else { return }

        // In-order data: hand it to the real peer and acknowledge it. Anything not
        // at rcvNxt is a duplicate/out-of-order (FIFO links only reorder under
        // loss) — re-ACK so the guest retransmits the missing in-order bytes.
        if !payload.isEmpty {
            if header.sequence == rcvNxt {
                rcvNxt = rcvNxt &+ UInt32(payload.count)
                channel?.send(payload)
            }
            // A channel may fail synchronously (for example at its bounded send
            // high-water mark), which already emitted RST and closed this flow.
            guard phase == .open else { return }
            sendPureAck()
        }

        // FIN consumes the sequence number just past any in-order payload.
        if header.flags.contains(.fin) {
            let finSeq = header.sequence &+ UInt32(payload.count)
            if finSeq == rcvNxt, !guestFinSeen {
                rcvNxt = rcvNxt &+ 1
                guestFinSeen = true
                channel?.finish()
                guard phase == .open else { return }
                sendPureAck()
            } else if guestFinSeen {
                sendPureAck()
            }
        }

        maybeComplete()
    }

    private func processAck(_ ackNum: UInt32) {
        // Accept an ACK that advances within (sndUna, sndNxt].
        guard TCPSequence.greater(ackNum, than: sndUna),
              !TCPSequence.greater(ackNum, than: sndNxt) else {
            // Duplicate/old ACK — the window may still have opened; try to pump.
            pumpToGuest()
            return
        }
        sndUna = ackNum
        unacked.removeAll { entry in
            let end = entry.seq
                &+ UInt32((entry.syn ? 1 : 0) + entry.bytes.count + (entry.fin ? 1 : 0))
            return !TCPSequence.greater(end, than: sndUna)   // end <= sndUna → fully acked
        }
        // Forward progress rebases the retransmission deadline on the new oldest
        // segment. Cancellation physically removes the old callback, so ACK rate
        // cannot inflate the shared EventLoop queue.
        retransmitTimer?.cancel()
        retransmitTimer = nil
        retransmits = 0
        rto = Self.baseRTO
        pumpToGuest()
    }

    // MARK: - Real peer -> engine (UplinkTCPObserver, all on the stack executor)

    func uplinkDidOpen() {
        guard phase == .connecting else { return }
        connectTimer?.cancel()
        connectTimer = nil
        phase = .open
        sendSynAck()
    }

    func uplinkDidReceive(_ bytes: [UInt8]) {
        guard phase == .open, !bytes.isEmpty else { return }
        guard bytes.count <= Self.maxBufferedPeerBytes,
              sendQueue.count <= Self.maxBufferedPeerBytes - bytes.count else {
            // A peer that outruns a closed/stalled guest window must not grow the
            // process without bound. Reset this relay rather than dropping bytes
            // from an ordered TCP stream.
            abort(sendingReset: true)
            return
        }
        sendQueue.append(contentsOf: bytes)
        pumpToGuest()
    }

    func uplinkDidFinish() {
        guard phase == .open else { return }
        peerFinPending = true
        pumpToGuest()   // emits our FIN once the send queue has drained
    }

    func uplinkDidFail(_ failure: UplinkFailure) {
        switch phase {
        case .connecting:
            // The real connection never opened: tell the guest it was refused.
            sendConnectionRefused()
            channel = nil
            teardown()
        case .open:
            abort(sendingReset: true)
        case .closed:
            break
        }
    }

    func engineDidPause() {
        connectTimer?.pause()
        retransmitTimer?.pause()
    }

    func engineDidResume() {
        connectTimer?.resume()
        retransmitTimer?.resume()
    }

    /// Called by the engine during stack shutdown / uplink removal.
    func engineDidShutdown() {
        guard phase != .closed else { return }
        phase = .closed
        generation &+= 1
        connectTimer?.cancel()
        connectTimer = nil
        retransmitTimer?.cancel()
        retransmitTimer = nil
        channel?.cancel()
        channel = nil
    }

    // MARK: - Sending toward the guest

    private func sendSynAck() {
        emit(seq: iss, flags: [.syn, .ack], payload: [])
        unacked.append(Unacked(seq: iss, bytes: [], syn: true, fin: false))
        sndNxt = iss &+ 1
        armRetransmitIfNeeded()
    }

    private func sendPureAck() {
        // Pure ACKs are not tracked for retransmission; the cumulative ACK also
        // rides every data/FIN segment, and the guest retransmits if it stalls.
        emit(seq: sndNxt, flags: [.ack], payload: [])
    }

    /// Segment as much queued real-peer data toward the guest as the guest's
    /// receive window allows, then emit a pending FIN once the queue is drained.
    private func pumpToGuest() {
        guard phase == .open else { return }

        while !sendQueue.isEmpty {
            let outstanding = sndNxt &- sndUna
            // Force a floor of 1 so a transiently-zero window cannot deadlock the
            // relay (a simplification: no true zero-window probing).
            let window = max(guestWindow, 1)
            guard outstanding < window else { break }
            let allowance = Int(window - outstanding)
            let chunkLen = min(sendQueue.count, min(maxSegment, allowance))
            guard chunkLen > 0 else { break }

            let chunk = Array(sendQueue.prefix(chunkLen))
            sendQueue.removeFirst(chunkLen)
            let seq = sndNxt
            emit(seq: seq, flags: [.ack, .psh], payload: chunk)
            unacked.append(Unacked(seq: seq, bytes: chunk, syn: false, fin: false))
            sndNxt = sndNxt &+ UInt32(chunkLen)
        }

        if peerFinPending, sendQueue.isEmpty, finSeqSent == nil {
            let seq = sndNxt
            emit(seq: seq, flags: [.fin, .ack], payload: [])
            unacked.append(Unacked(seq: seq, bytes: [], syn: false, fin: true))
            finSeqSent = seq
            sndNxt = sndNxt &+ 1
        }

        armRetransmitIfNeeded()
    }

    /// Build and send one segment toward the guest (source = the real peer).
    private func emit(seq: UInt32, flags: TCPSegment.Flags, payload: [UInt8]) {
        let segment = TCPSegment.build(sourcePort: remotePort,
                                       destinationPort: guestPort,
                                       sequence: seq,
                                       acknowledgment: rcvNxt,
                                       flags: flags,
                                       window: Self.advertisedWindow,
                                       payload: payload)
        engine?.emitTCPToGuest(source: remote, guest: guest, segment: segment)
    }

    private func resend(_ entry: Unacked) {
        var flags: TCPSegment.Flags = [.ack]
        if entry.syn { flags.insert(.syn) }
        if entry.fin { flags.insert(.fin) }
        if !entry.bytes.isEmpty { flags.insert(.psh) }
        emit(seq: entry.seq, flags: flags, payload: entry.bytes)
    }

    private func sendConnectionRefused() {
        // RST+ACK acknowledging the guest's SYN. We never sent a SYN-ACK, so the
        // conventional refused-connection sequence number is 0.
        let segment = TCPSegment.build(sourcePort: remotePort,
                                       destinationPort: guestPort,
                                       sequence: 0,
                                       acknowledgment: rcvNxt,
                                       flags: [.rst, .ack],
                                       window: 0,
                                       payload: [])
        engine?.emitTCPToGuest(source: remote, guest: guest, segment: segment)
    }

    private func sendReset() {
        let segment = TCPSegment.build(sourcePort: remotePort,
                                       destinationPort: guestPort,
                                       sequence: sndNxt,
                                       acknowledgment: rcvNxt,
                                       flags: [.rst, .ack],
                                       window: 0,
                                       payload: [])
        engine?.emitTCPToGuest(source: remote, guest: guest, segment: segment)
    }

    // MARK: - Reliability

    private func armRetransmitIfNeeded() {
        guard retransmitTimer == nil,
              !unacked.isEmpty,
              phase != .closed,
              let engine else { return }
        let timer = engine.makeTimerScope()
        retransmitTimer = timer
        let generationAtArm = generation
        timer.schedule(after: rto) { [weak self] in
            guard let self,
                  self.generation == generationAtArm,
                  self.phase != .closed else { return }
            self.retransmitTimer = nil
            self.onRetransmitTimeout()
        }
    }

    private func onRetransmitTimeout() {
        guard let oldest = unacked.first else { return }
        retransmits += 1
        if retransmits > Self.maxRetransmits {
            // The guest is unreachable at L2/L3 or dead: abort and reset.
            abort(sendingReset: true)
            return
        }
        resend(oldest)
        rto = min(rto * 2, Self.maxRTO)
        armRetransmitIfNeeded()
    }

    // MARK: - Teardown

    private func maybeComplete() {
        // Both sides closed and everything we sent (incl. our FIN) is acknowledged.
        guard guestFinSeen, finSeqSent != nil, unacked.isEmpty else { return }
        channel?.cancel()
        teardown()
    }

    private func abort(sendingReset: Bool) {
        if sendingReset { sendReset() }
        channel?.cancel()
        teardown()
    }

    private func teardown() {
        guard phase != .closed else { return }
        phase = .closed
        generation &+= 1
        connectTimer?.cancel()
        connectTimer = nil
        retransmitTimer?.cancel()
        retransmitTimer = nil
        channel = nil
        engine?.removeFlow(key)
    }
}

/// One connected UDP association between a guest 4-tuple and a real endpoint.
/// Datagram boundaries are preserved in both directions. Idle associations are
/// reclaimed on logical time so a one-shot DNS query cannot leak a host socket.
final class UplinkUDPFlow: UplinkUDPObserver {
    private static let idleTimeout: Double = 30

    private weak var engine: UplinkNAT?
    private let key: UplinkNAT.FlowKey
    private let guest: IPv4Address
    private let guestPort: UInt16
    private let remote: IPv4Address
    private let remotePort: UInt16
    private var channel: (any UplinkUDPChannel)?
    private var isClosed = false
    private var lastActivity: Double = 0
    private var idleTimer: EventLoop.CancellationScope?
    private var idleGeneration: UInt64 = 0

    init(engine: UplinkNAT,
         key: UplinkNAT.FlowKey,
         guest: IPv4Address,
         guestPort: UInt16,
         remote: IPv4Address,
         remotePort: UInt16) {
        self.engine = engine
        self.key = key
        self.guest = guest
        self.guestPort = guestPort
        self.remote = remote
        self.remotePort = remotePort
    }

    func start(transport: any UplinkTransport, firstPayload: [UInt8]) {
        let opened = transport.openUDP(
            to: UplinkEndpoint(host: remote, port: remotePort),
            observer: self)
        // A fallback transport may report failure synchronously from openUDP.
        // Do not retain or send through the returned inert channel afterward.
        guard !isClosed else {
            opened.cancel()
            return
        }
        channel = opened
        opened.send(firstPayload)
        touch()
    }

    func sendFromGuest(_ payload: [UInt8]) {
        guard !isClosed else { return }
        channel?.send(payload)
        touch()
    }

    func uplinkUDPDidReceive(_ bytes: [UInt8]) {
        guard !isClosed else { return }
        engine?.emitUDPToGuest(source: remote,
                               sourcePort: remotePort,
                               guest: guest,
                               guestPort: guestPort,
                               payload: bytes)
        touch()
    }

    func uplinkUDPDidFail(_ failure: UplinkFailure) {
        teardown()
    }

    func engineDidPause() {
        idleTimer?.pause()
    }

    func engineDidResume() {
        idleTimer?.resume()
    }

    func engineDidShutdown() {
        guard !isClosed else { return }
        isClosed = true
        idleGeneration &+= 1
        idleTimer?.cancel()
        idleTimer = nil
        channel?.cancel()
        channel = nil
    }

    private func touch() {
        guard !isClosed else { return }
        lastActivity = engine?.now ?? lastActivity
        guard idleTimer == nil else { return }
        scheduleIdleCheck(after: Self.idleTimeout)
    }

    /// Keep exactly one idle callback queued per association. Activity updates a
    /// timestamp only; when the current callback fires it either expires the flow
    /// or schedules one callback for the precise remaining logical duration.
    private func scheduleIdleCheck(after delay: Double) {
        guard !isClosed, idleTimer == nil, let engine else { return }
        let timer = engine.makeTimerScope()
        idleTimer = timer
        let scheduledGeneration = idleGeneration
        timer.schedule(after: delay) { [weak self] in
            guard let self,
                  !self.isClosed,
                  self.idleGeneration == scheduledGeneration else { return }
            self.idleTimer = nil
            guard let engine = self.engine else {
                self.teardown()
                return
            }
            let remaining = Self.idleTimeout - (engine.now - self.lastActivity)
            if remaining <= 0 {
                self.teardown()
            } else {
                self.scheduleIdleCheck(after: remaining)
            }
        }
    }

    private func teardown() {
        guard !isClosed else { return }
        isClosed = true
        idleGeneration &+= 1
        idleTimer?.cancel()
        idleTimer = nil
        channel?.cancel()
        channel = nil
        engine?.removeUDPFlow(key)
    }
}
