import Testing
@testable import Swiftix

/// Inbound TCP RST handling (R10). `TCPConnection.receiveSegment` checks the RST
/// flag before any other processing:
///
///   - An in-window RST (sequence within `[rcvNxt, rcvNxt + advertisedWindow)`,
///     using the connection's serial arithmetic) aborts the connection: it
///     transitions to `.closed` (R10.1), is removed from the stack's connection
///     table (R10.2), and any program parked on a receive for it is resumed so it
///     observes the abort (R10.3).
///   - An out-of-window RST is dropped and the connection is left unchanged
///     (R10.4).
///
/// The connection is established for real over a `TestWire`-connected pair on the
/// logical-time `EventLoop`, matching the existing TCP suites. The abort is driven
/// by injecting a hand-built, checksummed RST frame carrying the sequence number
/// the server actually expects — learned from the acknowledgment field of the
/// server's own outbound handshake segment (which equals its `rcvNxt`).
@Suite("TCP RST handling")
struct RSTHandlingTests {

    // MARK: - Fixtures

    private struct Pair {
        let kernelA: Kernel   // client
        let kernelB: Kernel   // server
        let ifB: NetworkStack.Interface
        let ipA: IPv4Address
        let ipB: IPv4Address
        let macA: MACAddress
        let macB: MACAddress
    }

    /// Two wired kernels (client A, server B) on the shared loop. B's outbound
    /// frames are captured through the outbound packet-trace hook so a test can
    /// read the server's expected sequence number and peer port off the wire.
    private func makePair(loop: EventLoop, captureB: @escaping (PacketBuffer) -> Void) -> Pair {
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)

        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB,
                         on: loop, latency: 0.005)
        kernelA.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        kernelB.netns.stack.configuredNeighbor(ip: ipA, mac: macA)
        kernelB.netns.stack.onPacketTrace = { frame, _, direction in
            if direction == .outbound { captureB(frame) }
        }
        return Pair(kernelA: kernelA, kernelB: kernelB, ifB: ifB,
                    ipA: ipA, ipB: ipB, macA: macA, macB: macB)
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

    /// Build a checksummed Ethernet/IPv4/TCP frame from client A to server B, so it
    /// passes IPv4 + transport checksum verification on ingress and reaches the
    /// matching connection.
    private func makeRSTFrame(_ pair: Pair,
                              sourcePort: UInt16,
                              destinationPort: UInt16,
                              sequence: UInt32) -> PacketBuffer {
        var segment = TCPSegment.build(sourcePort: sourcePort,
                                       destinationPort: destinationPort,
                                       sequence: sequence,
                                       acknowledgment: 0,
                                       flags: [.rst],
                                       window: 0xFFFF,
                                       payload: [])
        segment[16] = 0
        segment[17] = 0
        let checksum = TransportChecksum.transport(source: pair.ipA,
                                                    destination: pair.ipB,
                                                    proto: IPProtocol.tcp.rawValue,
                                                    segment: segment)
        segment[16] = UInt8((checksum >> 8) & 0xFF)
        segment[17] = UInt8(checksum & 0xFF)

        let ipPacket = IPv4Packet.build(source: pair.ipA,
                                        destination: pair.ipB,
                                        proto: IPProtocol.tcp.rawValue,
                                        payload: segment)
        return EthernetFrame.build(destination: pair.macB,
                                   source: pair.macA,
                                   etherType: EtherType.ipv4.rawValue,
                                   payload: ipPacket)
    }

    /// Establish a connection and park the server on `tcpRecv`. The server's
    /// expected sequence number (`rcvNxt`) and the client's ephemeral port are then
    /// read by the caller off the server's outbound SYN-ACK (whose acknowledgment
    /// field equals its `rcvNxt`). `recvResumed` is invoked (with the bytes
    /// delivered) when the parked recv is woken.
    private func establishAndPark(_ pair: Pair, loop: EventLoop,
                                  recvResumed: @escaping ([UInt8]) -> Void) {
        pair.kernelB.spawn("tcp-server") { ctx in
            guard let listenFD = ctx.tcpSocket() else { return }
            ctx.tcpListen(listenFD, port: 80)
            ctx.tcpAccept(listenFD) { acceptedFD in
                ctx.tcpRecv(acceptedFD) { bytes in
                    recvResumed(bytes)
                }
            }
        }
        pair.kernelA.spawn("tcp-client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.ipB, port: 80) { }
        }
        // Advance well under the initial 1s RTO so the connection is established and
        // the server is parked, without the retransmit path firing.
        loop.advance(by: 0.1)
    }

    // MARK: - (a) In-window RST aborts, removes from table, wakes parked recv

    @Test func inWindowRSTAbortsAndWakesParkedRecv() {
        let loop = EventLoop()
        final class Capture {
            var frames: [PacketBuffer] = []
            var recvWoken = false
            var recvBytes: [UInt8] = []
        }
        let cap = Capture()
        let pair = makePair(loop: loop) { cap.frames.append($0) }

        establishAndPark(pair, loop: loop) { bytes in
            cap.recvWoken = true
            cap.recvBytes = bytes
        }

        // The server's SYN-ACK carries acknowledgment == its rcvNxt and
        // destinationPort == the client's ephemeral port.
        guard let synAck = cap.frames.compactMap(tcpHeader).first(where: {
            $0.flags.contains(.syn) && $0.flags.contains(.ack)
        }) else {
            Issue.record("no SYN-ACK captured from server")
            return
        }
        let serverRcvNxt = synAck.acknowledgment
        let clientPort = synAck.destinationPort

        // Precondition: the connection exists and the recv is still parked.
        #expect(pair.kernelB.netns.stack.snapshotTCP().contains { $0.localPort == 80 })
        #expect(cap.recvWoken == false)

        // Inject an in-window RST (sequence == rcvNxt, offset 0 < advertisedWindow).
        let rst = makeRSTFrame(pair, sourcePort: clientPort, destinationPort: 80,
                               sequence: serverRcvNxt)
        pair.kernelB.netns.stack.receive(rst, on: pair.ifB)
        loop.runUntilIdle()

        // R10.1/R10.2: connection removed from the table.
        #expect(pair.kernelB.netns.stack.snapshotTCP().contains { $0.localPort == 80 } == false)
        // R10.3: the parked recv was resumed and observed the abort as an empty read.
        #expect(cap.recvWoken)
        #expect(cap.recvBytes.isEmpty)
    }

    // MARK: - (b) Out-of-window RST is ignored; connection stays established

    @Test func outOfWindowRSTIsIgnored() {
        let loop = EventLoop()
        final class Capture {
            var frames: [PacketBuffer] = []
            var recvWoken = false
        }
        let cap = Capture()
        let pair = makePair(loop: loop) { cap.frames.append($0) }

        establishAndPark(pair, loop: loop) { _ in cap.recvWoken = true }

        guard let synAck = cap.frames.compactMap(tcpHeader).first(where: {
            $0.flags.contains(.syn) && $0.flags.contains(.ack)
        }) else {
            Issue.record("no SYN-ACK captured from server")
            return
        }
        let serverRcvNxt = synAck.acknowledgment
        let clientPort = synAck.destinationPort

        #expect(pair.kernelB.netns.stack.snapshotTCP().contains { $0.localPort == 80 })

        // A far-out-of-window sequence (well beyond the advertised 0xFFFF window).
        let rst = makeRSTFrame(pair, sourcePort: clientPort, destinationPort: 80,
                               sequence: serverRcvNxt &+ 0x2_0000)
        pair.kernelB.netns.stack.receive(rst, on: pair.ifB)
        loop.runUntilIdle()

        // R10.4: dropped, connection unchanged and still ESTABLISHED; recv still parked.
        let conns = pair.kernelB.netns.stack.snapshotTCP().filter { $0.localPort == 80 }
        #expect(conns.count == 1)
        #expect(conns.first?.state == "ESTABLISHED")
        #expect(cap.recvWoken == false)
    }
}
