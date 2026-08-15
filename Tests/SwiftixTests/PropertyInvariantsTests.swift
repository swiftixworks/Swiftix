import Testing
@testable import Swiftix

/// Task 16 — seeded, deterministic property-style verification of the five
/// cross-cutting correctness properties from `design.md` ("Correctness
/// Properties"). Every scenario runs on the logical-time `EventLoop` with the
/// test-only `TestWire`, and every random choice is driven by a seeded
/// `SplitMix64`, so any counterexample reproduces exactly from its seed (the seed
/// is included in every failing expectation's message).
///
///   P1 checksum round-trip / verify — a message built with its computed checksum
///      verifies true; flipping any random byte makes verification fail and the
///      stack drops the corrupted segment. (R7.4, R8.1, R8.2, R8.3, R8.6)
///   P2 async ⇄ callback equivalence — the same scenario run through the async and
///      the callback frontends produces identical delivered streams AND identical
///      on-wire frame sequences. (R3.2, R3.3)
///   P3 flow-control invariant — `advertisedWindow == receiveBufferCapacity −
///      receiveBuffer.count` and `FlightSize <= min(cwnd, peerWindow)` at every
///      sampled observation; a full receiver advertises 0 and draining reopens the
///      window; the transfer reaches quiescence. (R11.1, R11.4, R12.1, R12.4)
///   P4 RST teardown — an in-window inbound RST closes + removes the connection and
///      wakes a parked receiver; an out-of-window RST leaves state unchanged.
///      (R10.1, R10.2, R10.3, R10.4)
///   P5 counter conservation — `txPackets == frames handed to onEgress` and
///      `rxPackets + drops == frames passed to receive`. (R13.2, R13.3, R13.4)
///
/// All loops are bounded (iteration caps + logical-time budgets) and always drive
/// the receiver to completion, so no scenario can spin forever; `runUntilIdle()` is
/// only called once a connection has reached quiescence (no re-arming timer left).
@Suite("Cross-cutting invariants (seeded property-style)")
struct PropertyInvariantsTests {

    /// Deterministic seeds shared by the lighter properties.
    static let seeds: [UInt64] = (1...20).map { UInt64($0) &* 0x9E37_79B9 &+ 1 }
    /// Fewer seeds for the heavier flow-control run (still fully deterministic).
    static let flowSeeds: [UInt64] = (1...12).map { UInt64($0) &* 0x9E37_79B9 &+ 7 }

    // MARK: - Shared node fixtures

    private struct Nodes {
        let kernelA: Kernel, kernelB: Kernel
        let stackA: NetworkStack, stackB: NetworkStack
        let ifA: NetworkStack.Interface, ifB: NetworkStack.Interface
        let ipA: IPv4Address, ipB: IPv4Address
        let macA: MACAddress, macB: MACAddress
    }

    /// Build two kernels with one interface each and pre-seeded neighbor entries
    /// (so no ARP frames appear on the wire — keeping frame sequences focused on the
    /// protocol under test). The caller wires the interfaces as the scenario needs.
    private func makeNodes(loop: EventLoop) -> Nodes {
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let stackA = kernelA.netns.stack
        let stackB = kernelB.netns.stack
        let ifA = stackA.configuredInterface(address: ipA, mac: macA)
        let ifB = stackB.configuredInterface(address: ipB, mac: macB)
        stackA.configuredNeighbor(ip: ipB, mac: macB)
        stackB.configuredNeighbor(ip: ipA, mac: macA)
        return Nodes(kernelA: kernelA, kernelB: kernelB, stackA: stackA, stackB: stackB,
                     ifA: ifA, ifB: ifB, ipA: ipA, ipB: ipB, macA: macA, macB: macB)
    }

    // MARK: - Parsing helpers

    private func tcpHeader(_ frame: PacketBuffer) -> TCPSegment.Header? {
        guard let eth = EthernetFrame.parseHeader(frame),
              eth.etherType == EtherType.ipv4.rawValue,
              let (ip, ipPayload) = IPv4Packet.parse(EthernetFrame.payload(frame)),
              ip.proto == IPProtocol.tcp.rawValue,
              let (header, _) = TCPSegment.parse(ipPayload) else { return nil }
        return header
    }

    /// True when the frame carries a data-bearing TCP segment (non-empty payload).
    private func isTCPData(_ frame: PacketBuffer) -> Bool {
        guard let eth = EthernetFrame.parseHeader(frame),
              eth.etherType == EtherType.ipv4.rawValue,
              let (ip, ipPayload) = IPv4Packet.parse(EthernetFrame.payload(frame)),
              ip.proto == IPProtocol.tcp.rawValue,
              let (_, payload) = TCPSegment.parse(ipPayload) else { return false }
        return !payload.isEmpty
    }

    /// Flip the last byte of a frame (corrupts a data-bearing transport payload so
    /// its stamped checksum no longer verifies).
    private func corruptLastByte(_ frame: PacketBuffer) -> PacketBuffer {
        var bytes = frame.bytes
        guard !bytes.isEmpty else { return frame }
        bytes[bytes.count - 1] ^= 0xFF
        return PacketBuffer(bytes)
    }

    /// Read the live occupancy of a connection's receive buffer through the
    /// internal diagnostic snapshot. This is independent of `advertisedWindow`, so
    /// P3 can assert the two are consistent.
    private func receiveBufferOccupancy(_ conn: TCPConnection) -> Int? {
        conn.receiveBufferSnapshot.occupancy
    }

    /// The connection's configured receive buffer capacity, read through the same
    /// internal diagnostic snapshot.
    private func reflectedCapacity(_ conn: TCPConnection) -> Int? {
        conn.receiveBufferSnapshot.capacity
    }

    /// Build a checksummed Ethernet/IPv4/TCP RST frame from A to B so it passes IPv4
    /// + transport checksum verification and reaches the matching connection.
    private func makeRSTFrame(_ nodes: Nodes, sourcePort: UInt16, destinationPort: UInt16,
                             sequence: UInt32) -> PacketBuffer {
        var segment = TCPSegment.build(sourcePort: sourcePort, destinationPort: destinationPort,
                                       sequence: sequence, acknowledgment: 0,
                                       flags: [.rst], window: 0xFFFF, payload: [])
        segment[16] = 0; segment[17] = 0
        let checksum = TransportChecksum.transport(source: nodes.ipA, destination: nodes.ipB,
                                                    proto: IPProtocol.tcp.rawValue, segment: segment)
        segment[16] = UInt8((checksum >> 8) & 0xFF)
        segment[17] = UInt8(checksum & 0xFF)
        let ipPacket = IPv4Packet.build(source: nodes.ipA, destination: nodes.ipB,
                                        proto: IPProtocol.tcp.rawValue, payload: segment)
        return EthernetFrame.build(destination: nodes.macB, source: nodes.macA,
                                   etherType: EtherType.ipv4.rawValue, payload: ipPacket)
    }
}

// MARK: - P1: checksum round-trip / verify under random byte flips

extension PropertyInvariantsTests {

    /// For seeded random TCP-, UDP-, and ICMP-shaped messages: the message built
    /// with its computed checksum verifies true, and flipping any single random byte
    /// makes verification fail. (P1 / R7.4, R8)
    @Test func p1_checksumRoundTripAndRandomFlipRejected() {
        let source = IPv4Address(10, 0, 0, 1)
        let destination = IPv4Address(10, 0, 0, 2)

        for seed in Self.seeds {
            var prng = SplitMix64(seed: seed)

            for _ in 0..<48 {
                // Choose a transport protocol and a checksum-field offset matching a
                // real header layout (TCP: 16-17, UDP: 6-7). Position is irrelevant to
                // the one's-complement math, but exercising both keeps it realistic.
                let isTCP = (prng.next() & 1) == 0
                let proto = isTCP ? IPProtocol.tcp.rawValue : IPProtocol.udp.rawValue
                let checksumOffset = isTCP ? 16 : 6
                let headerLen = isTCP ? 20 : 8
                let payloadLen = Int(prng.next() % 64)

                var segment = [UInt8](repeating: 0, count: headerLen + payloadLen)
                for i in segment.indices { segment[i] = UInt8(prng.next() & 0xFF) }
                segment[checksumOffset] = 0
                segment[checksumOffset + 1] = 0

                let checksum = TransportChecksum.transport(source: source, destination: destination,
                                                           proto: proto, segment: segment)
                segment[checksumOffset] = UInt8((checksum >> 8) & 0xFF)
                segment[checksumOffset + 1] = UInt8(checksum & 0xFF)

                #expect(TransportChecksum.verifyTransport(source: source, destination: destination,
                                                          proto: proto, segment: segment),
                        "seed \(seed): freshly stamped \(isTCP ? "TCP" : "UDP") segment failed to verify")

                // Flip one random byte with a guaranteed non-zero mask -> must fail.
                let index = Int(prng.next() % UInt64(segment.count))
                let mask = UInt8(1 + prng.next() % 255)
                var corrupted = segment
                corrupted[index] ^= mask
                #expect(!TransportChecksum.verifyTransport(source: source, destination: destination,
                                                           proto: proto, segment: corrupted),
                        "seed \(seed): flipping byte \(index) (mask \(mask)) of a \(isTCP ? "TCP" : "UDP") segment still verified")

                // ICMP: checksum over the message alone (no pseudo-header).
                let icmp = ICMPMessage.buildEcho(type: (prng.next() & 1) == 0 ? .echoRequest : .echoReply,
                                                 identifier: UInt16(prng.next() & 0xFFFF),
                                                 sequence: UInt16(prng.next() & 0xFFFF),
                                                 payload: (0..<Int(prng.next() % 32)).map { _ in UInt8(prng.next() & 0xFF) })
                #expect(TransportChecksum.verifyICMP(icmp),
                        "seed \(seed): freshly built ICMP echo failed to verify")
                let icmpIndex = Int(prng.next() % UInt64(icmp.count))
                let icmpMask = UInt8(1 + prng.next() % 255)
                var corruptedICMP = icmp
                corruptedICMP[icmpIndex] ^= icmpMask
                #expect(!TransportChecksum.verifyICMP(corruptedICMP),
                        "seed \(seed): flipping ICMP byte \(icmpIndex) (mask \(icmpMask)) still verified")
            }
        }
    }

    /// End-to-end: a corrupted inbound TCP data segment is dropped by the stack
    /// (drops counter increments, no bytes buffered, connection state untouched), and
    /// because the state was untouched the sender's retransmission still delivers the
    /// payload in order. The corrupted segment index and payload are seed-derived.
    /// (P1 stack-drop / R8.1, R8.2, R13.4)
    @Test func p1_corruptedSegmentDroppedByStack() {
        for seed in Self.seeds {
            var prng = SplitMix64(seed: seed)
            let loop = EventLoop()
            let nodes = makeNodes(loop: loop)

            // Corrupt exactly the first data-bearing TCP segment A→B.
            var corruptArmed = true
            nodes.ifA.onEgress = { [weak stackB = nodes.stackB, weak ifB = nodes.ifB] frame in
                guard let stackB, let ifB else { return }
                var out = frame
                if corruptArmed, self.isTCPData(frame) {
                    corruptArmed = false
                    out = self.corruptLastByte(frame)
                }
                loop.schedule(after: 0.01) { stackB.receive(out, on: ifB) }
            }
            nodes.ifB.onEgress = { [weak stackA = nodes.stackA, weak ifA = nodes.ifA] frame in
                guard let stackA, let ifA else { return }
                loop.schedule(after: 0.01) { stackA.receive(frame, on: ifA) }
            }

            let listener = nodes.stackB.listen(port: 80)
            let client = nodes.stackA.connect(localPort: 50_000, to: nodes.ipB, remotePort: 80)
            loop.advance(by: 0.5)
            guard let server = listener.dequeue() else {
                Issue.record("seed \(seed): server connection not established")
                continue
            }

            let windowBefore = server.advertisedWindow
            let dropsBefore = nodes.ifB.counters.drops
            let size = 1 + Int(prng.next() % 200)
            let payload: [UInt8] = (0..<size).map { _ in UInt8(prng.next() & 0xFF) }
            client.send(payload)

            // Deliver (and drop) the corrupted segment, but stop before the RTO fires.
            loop.advance(by: 0.05)
            #expect(nodes.ifB.counters.drops == dropsBefore + 1,
                    "seed \(seed): corrupted segment was not counted as a drop")
            #expect(server.hasBufferedData == false,
                    "seed \(seed): corrupted segment left buffered data")
            #expect(server.advertisedWindow == windowBefore,
                    "seed \(seed): corrupted segment altered receiver window/state")

            // State was untouched, so the retransmission delivers the payload intact.
            var received: [UInt8] = []
            var iterations = 0
            while received.count < size && iterations < 20_000 {
                received.append(contentsOf: server.read(max: 1 << 16))
                loop.advance(by: 0.1)
                iterations += 1
            }
            received.append(contentsOf: server.read(max: 1 << 16))
            #expect(received == payload,
                    "seed \(seed): payload not fully/correctly delivered after retransmit (\(received.count)/\(size))")
        }
    }
}

// MARK: - P2: async ⇄ callback equivalence

extension PropertyInvariantsTests {

    /// A single-threaded box for observing a scenario's delivered stream from the
    /// process bodies (which run as jobs on the one logical thread).
    private final class DeliveryBox: @unchecked Sendable {
        var delivered: [UInt8] = []
        var done = false
    }

    /// Pump the logical loop until `done` or a cap, yielding to the runtime between
    /// drains so an async task's next continuation job lands on the loop. No
    /// wall-clock waits (matches `AsyncSyscallTests`).
    private func drive(_ loop: EventLoop, until done: @Sendable () -> Bool, max: Int = 100_000) async {
        var pumps = 0
        while !done() && pumps < max {
            loop.advance(by: 0)
            loop.runNext()
            await Task.yield()
            pumps += 1
        }
        loop.advance(by: 0)
            loop.runNext()
    }

    /// Run a UDP request/echo scenario through either the async or the callback
    /// frontend, capturing the client's received reply and the on-wire frame
    /// sequence. Returns them for cross-frontend comparison.
    private func runUDPEcho(useAsync: Bool, request: [UInt8]) async
        -> (reply: [UInt8], frames: [TestWire.CapturedFrame]) {
        let loop = EventLoop()
        let nodes = makeNodes(loop: loop)
        let capture = TestWire.Capture()
        TestWire.connectCapturing(nodes.stackA, nodes.ifA, nodes.stackB, nodes.ifB,
                                  on: loop, latency: 0.005, capture: capture)
        let box = DeliveryBox()
        let ipA = nodes.ipA, ipB = nodes.ipB

        if useAsync {
            nodes.kernelB.spawn("udp-echo") { ctx in
                guard let fd = ctx.socket() else { return }
                ctx.bind(fd, address: ipB, port: 7000)
                while true {
                    guard let dg = try? await ctx.recvfrom(fd) else { return }
                    ctx.sendto(fd, dg.bytes, to: dg.address, port: dg.port)
                }
            }
            nodes.kernelA.spawn("udp-client") { ctx in
                guard let fd = ctx.socket() else { return }
                ctx.bind(fd, address: ipA, port: 5000)
                ctx.sendto(fd, request, to: ipB, port: 7000)
                if let dg = try? await ctx.recvfrom(fd) {
                    box.delivered = dg.bytes
                    box.done = true
                }
            }
            await drive(loop, until: { box.done })
        } else {
            nodes.kernelB.spawn("udp-echo") { ctx in
                guard let fd = ctx.socket() else { return }
                ctx.bind(fd, address: ipB, port: 7000)
                func serve() {
                    ctx.recvfrom(fd) { bytes, address, port in
                        ctx.sendto(fd, bytes, to: address, port: port)
                        serve()
                    }
                }
                serve()
            }
            nodes.kernelA.spawn("udp-client") { ctx in
                guard let fd = ctx.socket() else { return }
                ctx.bind(fd, address: ipA, port: 5000)
                ctx.sendto(fd, request, to: ipB, port: 7000)
                ctx.recvfrom(fd) { bytes, _, _ in
                    box.delivered = bytes
                    box.done = true
                }
            }
            loop.advance(by: 1.0)
        }
        return (box.delivered, capture.frames)
    }

    /// Run a TCP connect + single-send scenario through either frontend, capturing
    /// the server's received stream and the on-wire frame sequence.
    private func runTCPSend(useAsync: Bool, payload: [UInt8]) async
        -> (delivered: [UInt8], frames: [TestWire.CapturedFrame]) {
        let loop = EventLoop()
        let nodes = makeNodes(loop: loop)
        let capture = TestWire.Capture()
        TestWire.connectCapturing(nodes.stackA, nodes.ifA, nodes.stackB, nodes.ifB,
                                  on: loop, latency: 0.005, capture: capture)
        let box = DeliveryBox()
        let ipB = nodes.ipB

        if useAsync {
            nodes.kernelB.spawn("tcp-server") { ctx in
                guard let listenFD = ctx.tcpSocket() else { return }
                ctx.tcpListen(listenFD, port: 80)
                guard let acceptedFD = try? await ctx.tcpAccept(listenFD) else { return }
                guard let bytes = try? await ctx.tcpRecv(acceptedFD) else { return }
                box.delivered = bytes
                box.done = true
            }
            nodes.kernelA.spawn("tcp-client") { ctx in
                guard let fd = ctx.tcpSocket() else { return }
                try? await ctx.tcpConnect(fd, to: ipB, port: 80)
                ctx.tcpSend(fd, payload)
            }
            await drive(loop, until: { box.done })
        } else {
            nodes.kernelB.spawn("tcp-server") { ctx in
                guard let listenFD = ctx.tcpSocket() else { return }
                ctx.tcpListen(listenFD, port: 80)
                ctx.tcpAccept(listenFD) { acceptedFD in
                    ctx.tcpRecv(acceptedFD) { bytes in
                        box.delivered = bytes
                        box.done = true
                    }
                }
            }
            nodes.kernelA.spawn("tcp-client") { ctx in
                guard let fd = ctx.tcpSocket() else { return }
                ctx.tcpConnect(fd, to: ipB, port: 80) {
                    ctx.tcpSend(fd, payload)
                }
            }
            loop.advance(by: 1.0)
        }
        return (box.delivered, capture.frames)
    }

    /// For each seed, the same UDP echo scenario delivers the same reply and emits
    /// the same on-wire frame sequence through both frontends. (P2 / R3.2, R3.3)
    @Test func p2_udpEchoAsyncMatchesCallback() async {
        for seed in Self.seeds {
            var prng = SplitMix64(seed: seed)
            let size = 1 + Int(prng.next() % 48)
            let request: [UInt8] = (0..<size).map { _ in UInt8(prng.next() & 0xFF) }

            let cb = await runUDPEcho(useAsync: false, request: request)
            let asyncRun = await runUDPEcho(useAsync: true, request: request)

            #expect(cb.reply == request, "seed \(seed): callback UDP echo did not round-trip")
            #expect(asyncRun.reply == cb.reply,
                    "seed \(seed): async reply \(asyncRun.reply) != callback reply \(cb.reply)")
            #expect(asyncRun.frames == cb.frames,
                    "seed \(seed): async on-wire frame sequence differs from callback (async \(asyncRun.frames.count) vs callback \(cb.frames.count) frames)")
        }
    }

    /// For each seed, the same TCP connect+send scenario delivers the same stream
    /// and emits the same on-wire frame sequence through both frontends.
    /// (P2 / R3.2, R3.3)
    @Test func p2_tcpSendAsyncMatchesCallback() async {
        for seed in Self.seeds {
            var prng = SplitMix64(seed: seed)
            let size = 1 + Int(prng.next() % 300)
            let payload: [UInt8] = (0..<size).map { _ in UInt8(prng.next() & 0xFF) }

            let cb = await runTCPSend(useAsync: false, payload: payload)
            let asyncRun = await runTCPSend(useAsync: true, payload: payload)

            #expect(cb.delivered == payload, "seed \(seed): callback TCP send did not deliver payload")
            #expect(asyncRun.delivered == cb.delivered,
                    "seed \(seed): async delivered stream differs from callback")
            #expect(asyncRun.frames == cb.frames,
                    "seed \(seed): async on-wire frame sequence differs from callback (async \(asyncRun.frames.count) vs callback \(cb.frames.count) frames)")
        }
    }
}

// MARK: - P3: flow-control invariant

extension PropertyInvariantsTests {

    /// Under seeded A→B data loss with a randomized receive-buffer capacity and
    /// payload, the receiver's advertised window always equals its free buffer space
    /// (`capacity − receiveBuffer.count`, read through the receive-buffer snapshot) and
    /// never exceeds capacity; the sender never injects new data past
    /// `min(cwnd, peerWindow)`; a full receiver advertises a Zero_Window; draining
    /// reopens it; and the transfer reaches quiescence. (P3 / R11.1, R11.4, R12.1,
    /// R12.4)
    @Test func p3_flowControlInvariant() {
        for seed in Self.flowSeeds {
            var prng = SplitMix64(seed: seed)
            // Capacity strictly below the payload so the Zero_Window path is forced.
            let capacity = 600 + Int(prng.next() % 1800)          // 600 … 2399 bytes
            let total = 4_000 + Int(prng.next() % 8_000)          // 4000 … 11999 bytes
            let dropProbability = 0.03 + Double(prng.next() % 6) * 0.02  // 3% … 13%
            let payload: [UInt8] = (0..<total).map { UInt8($0 & 0xFF) }

            let loop = EventLoop()
            let nodes = makeNodes(loop: loop)
            TestWire.connect(nodes.stackA, nodes.ifA, nodes.stackB, nodes.ifB,
                             on: loop, latency: 0.01, dropSeed: seed, dropProbability: dropProbability)

            let listener = nodes.stackB.listen(port: 80)
            let client = nodes.stackA.connect(localPort: 50_000, to: nodes.ipB, remotePort: 80)
            loop.advance(by: 0.5)
            guard let server = listener.dequeue() else {
                Issue.record("seed \(seed): server connection not accepted")
                continue
            }
            server.setReceiveBufferCapacity(capacity)
            client.send(payload)

            var windowInvariantOK = true
            var windowViolation = ""
            var flightInvariantOK = true
            var flightViolation = ""
            var prevFlight = 0
            var sawZeroWindow = false

            // Sample the strict flow-control invariants at the current instant.
            func sample() {
                // R11.1/R11.4: advertisedWindow == clamp(capacity − occupancy), read
                // occupancy independently through the receive-buffer snapshot.
                if windowInvariantOK, let occ = receiveBufferOccupancy(server),
                   let cap = reflectedCapacity(server) {
                    let expected = Swift.min(Swift.max(cap - occ, 0), cap)
                    if Int(server.advertisedWindow) != expected {
                        windowInvariantOK = false
                        windowViolation = "advertisedWindow=\(server.advertisedWindow) expected=\(expected) (cap=\(cap), occ=\(occ))"
                    }
                    if Int(server.advertisedWindow) > cap {
                        windowInvariantOK = false
                        windowViolation = "advertisedWindow=\(server.advertisedWindow) exceeds capacity=\(cap)"
                    }
                }
                if server.advertisedWindow == 0 { sawZeroWindow = true }

                // R12.4: the sender never *injects new data* past min(cwnd, peerWindow).
                // A transient excess after a cwnd reduction that only holds or shrinks
                // is allowed (RFC 5681 / Reno); a net increase above the window is not.
                let cwnd = client.congestionControllerSnapshot.cwnd
                let peer = Int(client.peerAdvertisedWindow)
                let limit = Swift.min(cwnd, peer)
                let flight = client.flightSize
                if flightInvariantOK, flight > limit, flight > prevFlight {
                    flightInvariantOK = false
                    flightViolation = "flight grew to \(flight) past min(cwnd=\(cwnd), peer=\(peer))=\(limit)"
                }
                prevFlight = flight
            }

            // Phase 1: fill the receiver (never draining) so it advertises a
            // Zero_Window and the sender stalls with data still queued.
            var iterations = 0
            sample()
            while server.advertisedWindow > 0 && iterations < 200_000 {
                if client.sendBufferIsEmpty && client.sndFullyAcked { break }
                loop.advance(by: 0.002)
                sample()
                iterations += 1
            }
            loop.advance(by: 0.05)
            sample()

            // Phase 2: drain the receiver; each drain from full reopens the window and
            // wakes the stalled sender, so the whole stream eventually arrives.
            var received: [UInt8] = []
            iterations = 0
            while received.count < total && iterations < 400_000 {
                received.append(contentsOf: server.read(max: 512))
                loop.advance(by: 0.01)
                sample()
                iterations += 1
                if loop.now > 1_500 { break }   // hard logical-time budget
            }
            received.append(contentsOf: server.read(max: total))
            sample()

            let quiesced = client.sndFullyAcked && client.sendBufferIsEmpty && received.count == total
            if quiesced { loop.runUntilIdle() }   // only when no re-arming timer remains

            #expect(windowInvariantOK, "seed \(seed): window invariant broken: \(windowViolation)")
            #expect(flightInvariantOK, "seed \(seed): flight invariant broken: \(flightViolation)")
            #expect(sawZeroWindow, "seed \(seed): receiver never advertised a Zero_Window (capacity \(capacity) vs total \(total))")
            #expect(server.advertisedWindow <= UInt16(capacity),
                    "seed \(seed): advertised window \(server.advertisedWindow) exceeded capacity \(capacity)")
            #expect(received == payload, "seed \(seed): stream not fully/correctly delivered (\(received.count)/\(total))")
            #expect(quiesced, "seed \(seed): transfer did not reach quiescence")
        }
    }
}

// MARK: - P4: RST teardown vs out-of-window ignore

extension PropertyInvariantsTests {

    private struct ParkedServer {
        let nodes: Nodes
        let serverRcvNxt: UInt32
        let clientPort: UInt16
    }

    /// A shared, single-threaded observation record for the parked receiver.
    private final class RecvState: @unchecked Sendable {
        var woken = false
        var bytes: [UInt8] = []
    }

    /// Establish a connection and park the server on `tcpRecv`; capture the server's
    /// SYN-ACK (whose acknowledgment == its `rcvNxt` and destination == the client's
    /// ephemeral port) so a test can inject a precisely-placed RST.
    private func establishParkedServer(loop: EventLoop, recv: RecvState) -> ParkedServer? {
        let nodes = makeNodes(loop: loop)
        final class FrameLog { var frames: [PacketBuffer] = [] }
        let log = FrameLog()
        TestWire.connect(nodes.stackA, nodes.ifA, nodes.stackB, nodes.ifB, on: loop, latency: 0.005)
        nodes.stackB.onPacketTrace = { frame, _, direction in
            if direction == .outbound { log.frames.append(frame) }
        }

        nodes.kernelB.spawn("tcp-server") { ctx in
            guard let listenFD = ctx.tcpSocket() else { return }
            ctx.tcpListen(listenFD, port: 80)
            ctx.tcpAccept(listenFD) { acceptedFD in
                ctx.tcpRecv(acceptedFD) { bytes in
                    recv.woken = true
                    recv.bytes = bytes
                }
            }
        }
        nodes.kernelA.spawn("tcp-client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: nodes.ipB, port: 80) { }
        }
        loop.advance(by: 0.1)   // establish + park, well under the initial RTO

        guard let synAck = log.frames.compactMap(tcpHeader).first(where: {
            $0.flags.contains(.syn) && $0.flags.contains(.ack)
        }) else { return nil }
        return ParkedServer(nodes: nodes, serverRcvNxt: synAck.acknowledgment,
                            clientPort: synAck.destinationPort)
    }

    /// For each seed: an in-window RST (random offset within the advertised window)
    /// tears the connection down — closed, removed from the table, parked recv woken;
    /// an out-of-window RST (random offset beyond the window) is ignored and the
    /// connection stays ESTABLISHED with the recv still parked. (P4 / R10.1–R10.4)
    @Test func p4_rstTeardownVsOutOfWindowIgnore() {
        for seed in Self.seeds {
            var prng = SplitMix64(seed: seed)

            // (a) In-window RST tears the connection down and wakes the parked recv.
            do {
                let loop = EventLoop()
                let recv = RecvState()
                guard let parked = establishParkedServer(loop: loop, recv: recv) else {
                    Issue.record("seed \(seed): no SYN-ACK captured (in-window case)")
                    continue
                }
                let window = UInt32(parked.nodes.stackB.snapshotTCP().first { $0.localPort == 80 }?.rwnd ?? 0xFFFF)
                let offset = window > 0 ? UInt32(prng.next() % UInt64(window)) : 0
                #expect(parked.nodes.stackB.snapshotTCP().contains { $0.localPort == 80 },
                        "seed \(seed): connection missing before in-window RST")
                #expect(recv.woken == false, "seed \(seed): recv woken before RST")

                let rst = makeRSTFrame(parked.nodes, sourcePort: parked.clientPort,
                                       destinationPort: 80, sequence: parked.serverRcvNxt &+ offset)
                parked.nodes.stackB.receive(rst, on: parked.nodes.ifB)
                loop.runUntilIdle()

                #expect(parked.nodes.stackB.snapshotTCP().contains { $0.localPort == 80 } == false,
                        "seed \(seed): in-window RST (offset \(offset)) did not remove the connection")
                #expect(recv.woken, "seed \(seed): in-window RST did not wake the parked recv")
                #expect(recv.bytes.isEmpty, "seed \(seed): aborted recv delivered non-empty bytes")
            }

            // (b) Out-of-window RST leaves the connection untouched.
            do {
                let loop = EventLoop()
                let recv = RecvState()
                guard let parked = establishParkedServer(loop: loop, recv: recv) else {
                    Issue.record("seed \(seed): no SYN-ACK captured (out-of-window case)")
                    continue
                }
                let window = UInt32(parked.nodes.stackB.snapshotTCP().first { $0.localPort == 80 }?.rwnd ?? 0xFFFF)
                // A sequence at or beyond rcvNxt + window is outside the receive window.
                let offset = window &+ UInt32(prng.next() % 100_000)
                let rst = makeRSTFrame(parked.nodes, sourcePort: parked.clientPort,
                                       destinationPort: 80, sequence: parked.serverRcvNxt &+ offset)
                parked.nodes.stackB.receive(rst, on: parked.nodes.ifB)
                loop.runUntilIdle()

                let conns = parked.nodes.stackB.snapshotTCP().filter { $0.localPort == 80 }
                #expect(conns.count == 1, "seed \(seed): out-of-window RST (offset \(offset)) removed the connection")
                #expect(conns.first?.state == "ESTABLISHED",
                        "seed \(seed): out-of-window RST changed state to \(conns.first?.state ?? "nil")")
                #expect(recv.woken == false, "seed \(seed): out-of-window RST woke the parked recv")
            }
        }
    }
}

// MARK: - P5: counter conservation

extension PropertyInvariantsTests {

    /// Sum the byte lengths of captured frames emitted in one direction.
    private func egressBytes(_ capture: TestWire.Capture, _ direction: TestWire.Direction) -> Int {
        capture.frames.lazy.filter { $0.direction == direction }.reduce(0) { $0 + $1.bytes.count }
    }

    /// Drive a TCP transfer to completion over a capturing wire (optionally
    /// corrupting a seeded subset of A→B data segments to force receiver-side drops),
    /// then assert both interfaces' counters conserve exactly:
    ///   `txPackets == frames handed to onEgress` and
    ///   `rxPackets + drops == frames passed to receive`. (P5 / R13.2, R13.3, R13.4)
    private func runCounterConservation(seed: UInt64, corrupt: Bool) {
        var prng = SplitMix64(seed: seed)
        let total = 1 + Int(prng.next() % 6000)
        let payload: [UInt8] = (0..<total).map { UInt8($0 & 0xFF) }

        let loop = EventLoop()
        let nodes = makeNodes(loop: loop)
        let capture = TestWire.Capture()

        // When corrupting, flip the last byte of a seed-selected subset of
        // data-bearing A→B segments so the receiver drops them on checksum failure.
        var dataIndex = 0
        var corruptedAny = false
        let intercept: (PacketBuffer) -> PacketBuffer? = { frame in
            guard corrupt, self.isTCPData(frame) else { return frame }
            let index = dataIndex
            dataIndex += 1
            // Corrupt the first data segment (index 0) plus a seeded ~25% of the rest,
            // guaranteeing at least one drop while still letting the transfer finish.
            if index == 0 || (prng.next() % 4 == 0) {
                corruptedAny = true
                return self.corruptLastByte(frame)
            }
            return frame
        }
        TestWire.connectCapturing(nodes.stackA, nodes.ifA, nodes.stackB, nodes.ifB,
                                  on: loop, latency: 0.01, capture: capture, interceptAtoB: intercept)

        let listener = nodes.stackB.listen(port: 80)
        let client = nodes.stackA.connect(localPort: 50_000, to: nodes.ipB, remotePort: 80)
        loop.advance(by: 0.5)
        guard let server = listener.dequeue() else {
            Issue.record("seed \(seed): server connection not accepted")
            return
        }
        client.send(payload)

        var received: [UInt8] = []
        var iterations = 0
        while received.count < total && iterations < 400_000 {
            received.append(contentsOf: server.read(max: 1 << 16))
            loop.advance(by: 0.05)
            iterations += 1
            if loop.now > 1_500 { break }
        }
        received.append(contentsOf: server.read(max: 1 << 16))
        // Quiescent once fully acked; only then is it safe to drain the loop fully.
        if client.sndFullyAcked && client.sendBufferIsEmpty {
            loop.runUntilIdle()
        }

        #expect(received == payload, "seed \(seed): payload not fully delivered (\(received.count)/\(total))")

        // tx side (R13.2): every frame handed to onEgress is counted once.
        #expect(nodes.ifA.counters.txPackets == capture.egressAtoBCount,
                "seed \(seed): ifA txPackets \(nodes.ifA.counters.txPackets) != egress A→B \(capture.egressAtoBCount)")
        #expect(nodes.ifB.counters.txPackets == capture.egressBtoACount,
                "seed \(seed): ifB txPackets \(nodes.ifB.counters.txPackets) != egress B→A \(capture.egressBtoACount)")
        #expect(nodes.ifA.counters.txBytes == egressBytes(capture, .aToB),
                "seed \(seed): ifA txBytes mismatch")
        #expect(nodes.ifB.counters.txBytes == egressBytes(capture, .bToA),
                "seed \(seed): ifB txBytes mismatch")

        // rx side + conservation (R13.3, R13.4): accepted + dropped == delivered.
        #expect(nodes.ifA.counters.rxPackets + nodes.ifA.counters.drops == capture.deliveredToA.count,
                "seed \(seed): ifA rx+drops \(nodes.ifA.counters.rxPackets + nodes.ifA.counters.drops) != delivered \(capture.deliveredToA.count)")
        #expect(nodes.ifB.counters.rxPackets + nodes.ifB.counters.drops == capture.deliveredToB.count,
                "seed \(seed): ifB rx+drops \(nodes.ifB.counters.rxPackets + nodes.ifB.counters.drops) != delivered \(capture.deliveredToB.count)")

        // B→A is never corrupted, so A never drops.
        #expect(nodes.ifA.counters.drops == 0, "seed \(seed): unexpected drops on ifA")
        if corrupt {
            #expect(corruptedAny, "seed \(seed): corruption harness never fired")
            #expect(nodes.ifB.counters.drops >= 1, "seed \(seed): expected at least one drop on ifB")
        } else {
            #expect(nodes.ifB.counters.drops == 0, "seed \(seed): unexpected drops on a lossless wire")
        }
    }

    /// Counters conserve across seeded lossless TCP transfers. (P5)
    @Test func p5_counterConservationLossless() {
        for seed in Self.seeds { runCounterConservation(seed: seed, corrupt: false) }
    }

    /// Counters conserve across seeded transfers with checksum-corrupted (dropped)
    /// segments — `rxPackets + drops` still equals the frames passed to `receive`. (P5)
    @Test func p5_counterConservationWithDrops() {
        for seed in Self.seeds { runCounterConservation(seed: seed, corrupt: true) }
    }
}
