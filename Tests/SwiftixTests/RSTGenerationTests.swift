import Testing
@testable import Swiftix

/// TCP RST generation for unmatched segments (R9). When a non-RST TCP segment
/// arrives for a port with no listener and no matching connection, the stack
/// answers with a RST so the peer learns the port/connection is unavailable
/// (R9.1, R9.2). The reset's seq/ack are derived from the triggering segment:
///
///   - triggering segment carries ACK  -> RST.seq = triggering.ack, no ACK flag (R9.3)
///   - triggering segment has no ACK    -> RST.seq = 0,
///                                         RST.ack = triggering.seq + segmentLength,
///                                         ACK flag set (R9.4)
///
/// A segment that itself carries RST produces no reply (no RST loops).
///
/// The triggering frames are hand-built and stamped with a valid transport
/// checksum (via `TransportChecksum`) so they pass ingress verification (task 5)
/// and actually reach the RST logic. Emitted frames are captured through the
/// `onPacketTrace` outbound hook (task 7) and parsed to assert the reset fields.
@Suite("TCP RST generation")
struct RSTGenerationTests {

    // MARK: - Fixtures

    private struct Host {
        let kernel: Kernel
        let stack: NetworkStack
        let iface: NetworkStack.Interface
        let ip: IPv4Address
        let mac: MACAddress
        let peerIP: IPv4Address
        let peerMAC: MACAddress
    }

    /// A single stack whose outbound frames are captured (not wired to a peer, so
    /// the emitted RST is observed directly rather than delivered anywhere).
    private func makeHost(loop: EventLoop, capture: @escaping (PacketBuffer) -> Void) -> Host {
        let ip = IPv4Address(10, 0, 0, 1)
        let peerIP = IPv4Address(10, 0, 0, 2)
        let mac = MACAddress("02:00:00:00:00:01")!
        let peerMAC = MACAddress("02:00:00:00:00:02")!
        let kernel = Kernel(loop: loop)
        let stack = kernel.netns.stack
        let iface = stack.configuredInterface(address: ip, mac: mac)
        stack.configuredNeighbor(ip: peerIP, mac: peerMAC)   // no ARP round-trip needed for egress
        stack.onPacketTrace = { frame, _, direction in
            if direction == .outbound { capture(frame) }
        }
        return Host(kernel: kernel, stack: stack, iface: iface,
                    ip: ip, mac: mac, peerIP: peerIP, peerMAC: peerMAC)
    }

    /// Build a checksummed Ethernet/IPv4/TCP frame from the peer to the host, so it
    /// passes IPv4 + transport checksum verification on ingress.
    private func makeTCPFrame(from host: Host,
                              sourcePort: UInt16,
                              destinationPort: UInt16,
                              sequence: UInt32,
                              acknowledgment: UInt32,
                              flags: TCPSegment.Flags,
                              payload: [UInt8] = []) -> PacketBuffer {
        var segment = TCPSegment.build(sourcePort: sourcePort,
                                       destinationPort: destinationPort,
                                       sequence: sequence,
                                       acknowledgment: acknowledgment,
                                       flags: flags,
                                       window: 0xFFFF,
                                       payload: payload)
        // Stamp a valid transport checksum over the pseudo-header (source = peer,
        // destination = host) so ingress verification (task 5) accepts the segment.
        segment[16] = 0
        segment[17] = 0
        let checksum = TransportChecksum.transport(source: host.peerIP,
                                                   destination: host.ip,
                                                   proto: IPProtocol.tcp.rawValue,
                                                   segment: segment)
        segment[16] = UInt8((checksum >> 8) & 0xFF)
        segment[17] = UInt8(checksum & 0xFF)

        let ipPacket = IPv4Packet.build(source: host.peerIP,
                                        destination: host.ip,
                                        proto: IPProtocol.tcp.rawValue,
                                        payload: segment)
        return EthernetFrame.build(destination: host.mac,
                                   source: host.peerMAC,
                                   etherType: EtherType.ipv4.rawValue,
                                   payload: ipPacket)
    }

    /// Parse a captured frame's TCP header (or nil if it is not a TCP segment).
    private func tcpHeader(_ frame: PacketBuffer) -> TCPSegment.Header? {
        guard let eth = EthernetFrame.parseHeader(frame),
              eth.etherType == EtherType.ipv4.rawValue,
              let (ip, ipPayload) = IPv4Packet.parse(EthernetFrame.payload(frame)),
              ip.proto == IPProtocol.tcp.rawValue,
              let (header, _) = TCPSegment.parse(ipPayload) else { return nil }
        return header
    }

    // MARK: - (a) Stray ACK to a closed port -> bare RST (seq = triggering.ack)

    @Test func strayAckToClosedPortProducesRSTWithAckSequence() {
        let loop = EventLoop()
        final class Capture { var frames: [PacketBuffer] = [] }
        let captured = Capture()
        let host = makeHost(loop: loop) { captured.frames.append($0) }

        // A stray ACK (carries an acknowledgment) to a port with no listener.
        let frame = makeTCPFrame(from: host,
                                 sourcePort: 40_000,
                                 destinationPort: 80,
                                 sequence: 5_000,
                                 acknowledgment: 12_345,
                                 flags: [.ack])
        host.stack.receive(frame, on: host.iface)
        loop.runUntilIdle()

        let resets = captured.frames.compactMap(tcpHeader).filter { $0.flags.contains(.rst) }
        #expect(resets.count == 1)
        guard let rst = resets.first else { return }
        // R9.3: seq = triggering.acknowledgment, no ACK flag on the RST.
        #expect(rst.flags.contains(.rst))
        #expect(rst.flags.contains(.ack) == false)
        #expect(rst.sequence == 12_345)
        // The reset is addressed back to the sender's port from our port.
        #expect(rst.sourcePort == 80)
        #expect(rst.destinationPort == 40_000)
    }

    // MARK: - (b) Stray data segment (no ACK) -> RST with ACK flag and ack = seq+len

    @Test func strayDataSegmentWithoutAckProducesAckingRST() {
        let loop = EventLoop()
        final class Capture { var frames: [PacketBuffer] = [] }
        let captured = Capture()
        let host = makeHost(loop: loop) { captured.frames.append($0) }

        let payload = Array("stray-bytes".utf8)   // 11 bytes
        let frame = makeTCPFrame(from: host,
                                 sourcePort: 40_001,
                                 destinationPort: 81,
                                 sequence: 900,
                                 acknowledgment: 0,
                                 flags: [.psh],   // data, no ACK flag
                                 payload: payload)
        host.stack.receive(frame, on: host.iface)
        loop.runUntilIdle()

        let resets = captured.frames.compactMap(tcpHeader).filter { $0.flags.contains(.rst) }
        #expect(resets.count == 1)
        guard let rst = resets.first else { return }
        // R9.4: seq = 0, ack = triggering.seq + segmentLength (payload only here),
        // ACK flag set.
        #expect(rst.flags.contains(.rst))
        #expect(rst.flags.contains(.ack))
        #expect(rst.sequence == 0)
        #expect(rst.acknowledgment == 900 + UInt32(payload.count))
    }

    // MARK: - (c) Stray SYN to a closed port -> RST with ack = seq + 1 (SYN counts)

    @Test func straySYNToClosedPortProducesAckingRST() {
        let loop = EventLoop()
        final class Capture { var frames: [PacketBuffer] = [] }
        let captured = Capture()
        let host = makeHost(loop: loop) { captured.frames.append($0) }

        // A SYN to a port with no listener: no ACK, so R9.4 applies and SYN occupies
        // one sequence number.
        let frame = makeTCPFrame(from: host,
                                 sourcePort: 40_002,
                                 destinationPort: 82,
                                 sequence: 7_000,
                                 acknowledgment: 0,
                                 flags: [.syn])
        host.stack.receive(frame, on: host.iface)
        loop.runUntilIdle()

        let resets = captured.frames.compactMap(tcpHeader).filter { $0.flags.contains(.rst) }
        #expect(resets.count == 1)
        guard let rst = resets.first else { return }
        #expect(rst.flags.contains(.ack))
        #expect(rst.sequence == 0)
        #expect(rst.acknowledgment == 7_001)   // seq + 1 for the SYN
    }

    // MARK: - (d) Inbound RST produces no reply (no RST loops)

    @Test func inboundRSTProducesNoReply() {
        let loop = EventLoop()
        final class Capture { var frames: [PacketBuffer] = [] }
        let captured = Capture()
        let host = makeHost(loop: loop) { captured.frames.append($0) }

        let frame = makeTCPFrame(from: host,
                                 sourcePort: 40_003,
                                 destinationPort: 83,
                                 sequence: 1,
                                 acknowledgment: 99,
                                 flags: [.rst, .ack])
        host.stack.receive(frame, on: host.iface)
        loop.runUntilIdle()

        // No reply at all: a segment carrying RST must not trigger a RST.
        let resets = captured.frames.compactMap(tcpHeader).filter { $0.flags.contains(.rst) }
        #expect(resets.isEmpty)
        #expect(captured.frames.isEmpty)
    }

    // MARK: - (e) A SYN to a valid listener still creates a connection (no RST)

    @Test func synToValidListenerCreatesConnectionWithoutRST() {
        let loop = EventLoop()
        final class Capture { var frames: [PacketBuffer] = [] }
        let captured = Capture()
        let host = makeHost(loop: loop) { captured.frames.append($0) }

        _ = host.stack.listen(port: 80)

        let frame = makeTCPFrame(from: host,
                                 sourcePort: 40_004,
                                 destinationPort: 80,
                                 sequence: 5_000,
                                 acknowledgment: 0,
                                 flags: [.syn])
        host.stack.receive(frame, on: host.iface)
        // The SYN-ACK is emitted synchronously on receive; advance by a small
        // logical duration (well under the initial 1s RTO) to observe it without
        // depending on the half-open connection's retransmit timer exhausting.
        loop.advance(by: 0.1)

        // The handshake reply is a SYN-ACK, never a RST (existing behavior preserved).
        let headers = captured.frames.compactMap(tcpHeader)
        #expect(headers.contains { $0.flags.contains(.syn) && $0.flags.contains(.ack) })
        #expect(headers.allSatisfy { !$0.flags.contains(.rst) })
        // A connection was created for the accepted SYN.
        #expect(host.stack.snapshotTCP().contains { $0.localPort == 80 })
    }
}
