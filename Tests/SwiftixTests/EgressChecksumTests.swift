import Testing
@testable import Swiftix

/// Egress transport-checksum integration (R7.1, R7.2, R7.3). Task 3 proved the
/// `TransportChecksum` helper round-trips in isolation; this suite proves the
/// `NetworkStack` actually stamps a correct checksum onto every TCP, UDP, and
/// ICMP frame it emits, once the egress source IP is known.
///
/// Frames are captured off a lossless, capturing wire on the logical-time
/// `EventLoop`. For each captured frame the IPv4 header (source/destination) and
/// the transport segment are extracted, then `TransportChecksum.verifyTransport`
/// / `verifyICMP` must return `true` — the round-trip property the design ties to
/// R7.4.
@Suite("Egress transport checksums")
struct EgressChecksumTests {

    /// Collects every frame handed to `onEgress` in either direction so the test
    /// can inspect the checksums the stack actually put on the wire.
    final class FrameLog {
        var frames: [PacketBuffer] = []
    }

    /// A capturing, lossless stand-in for `TestWire.connect`: it records every
    /// frame handed to each interface's `onEgress` before delivering it to the
    /// peer's `receive` after `latency`. Recording happens on the sending side, so
    /// the captured bytes are exactly what the stack emitted (checksums included).
    private func connectCapturing(_ stackA: NetworkStack, _ ifA: NetworkStack.Interface,
                                  _ stackB: NetworkStack, _ ifB: NetworkStack.Interface,
                                  on loop: EventLoop, latency: Double, log: FrameLog) {
        ifA.onEgress = { [weak stackB, weak ifB] frame in
            log.frames.append(frame)
            guard let stackB, let ifB else { return }
            loop.schedule(after: latency) { stackB.receive(frame, on: ifB) }
        }
        ifB.onEgress = { [weak stackA, weak ifA] frame in
            log.frames.append(frame)
            guard let stackA, let ifA else { return }
            loop.schedule(after: latency) { stackA.receive(frame, on: ifA) }
        }
    }

    /// Extract (source, destination, proto, transport-segment) from a captured
    /// frame if it is an IPv4 packet, otherwise `nil` (e.g. ARP frames).
    private func transportSegment(_ frame: PacketBuffer)
        -> (source: IPv4Address, destination: IPv4Address, proto: UInt8, segment: [UInt8])? {
        guard let eth = EthernetFrame.parseHeader(frame),
              eth.etherType == EtherType.ipv4.rawValue,
              let (ipHeader, ipPayload) = IPv4Packet.parse(EthernetFrame.payload(frame)) else {
            return nil
        }
        return (ipHeader.source, ipHeader.destination, ipHeader.proto, Array(ipPayload))
    }

    private func makePair(loop: EventLoop, log: FrameLog) -> (Kernel, Kernel, IPv4Address, IPv4Address) {
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)

        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: macB)
        connectCapturing(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB,
                         on: loop, latency: 0.005, log: log)
        kernelA.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        kernelB.netns.stack.configuredNeighbor(ip: ipA, mac: macA)
        return (kernelA, kernelB, ipA, ipB)
    }

    /// Every emitted TCP frame (handshake + data + ACKs) carries a checksum that
    /// verifies over its IPv4 pseudo-header (R7.1).
    @Test func emittedTCPFramesVerify() {
        let loop = EventLoop()
        let log = FrameLog()
        let (kernelA, kernelB, _, ipB) = makePair(loop: loop, log: log)

        final class Capture { var serverGot: [UInt8] = [] }
        let captured = Capture()

        kernelB.spawn("tcp-server") { ctx in
            guard let listenFD = ctx.tcpSocket() else { return }
            ctx.tcpListen(listenFD, port: 80)
            ctx.tcpAccept(listenFD) { acceptedFD in
                ctx.tcpRecv(acceptedFD) { bytes in captured.serverGot = bytes }
            }
        }
        kernelA.spawn("tcp-client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: ipB, port: 80) {
                ctx.tcpSend(fd, Array("hello-tcp".utf8))
            }
        }

        loop.advance(by: 1.0)
        #expect(String(decoding: captured.serverGot, as: UTF8.self) == "hello-tcp")

        let tcpFrames = log.frames.compactMap(transportSegment)
            .filter { $0.proto == IPProtocol.tcp.rawValue }
        #expect(!tcpFrames.isEmpty)
        for f in tcpFrames {
            #expect(TransportChecksum.verifyTransport(source: f.source,
                                                      destination: f.destination,
                                                      proto: IPProtocol.tcp.rawValue,
                                                      segment: f.segment),
                    "captured TCP segment failed checksum verification")
        }
    }

    /// Every emitted UDP frame carries a non-zero checksum that verifies over its
    /// IPv4 pseudo-header (R7.2).
    @Test func emittedUDPFramesVerify() {
        let loop = EventLoop()
        let log = FrameLog()
        let (kernelA, kernelB, ipA, ipB) = makePair(loop: loop, log: log)

        final class Capture { var reply: [UInt8] = []; var replied = false }
        let captured = Capture()

        kernelB.spawn("udp-echo") { ctx in
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
        kernelA.spawn("udp-client") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: ipA, port: 5000)
            ctx.sendto(fd, Array("ping".utf8), to: ipB, port: 7000)
            ctx.recvfrom(fd) { bytes, _, _ in
                captured.reply = bytes
                captured.replied = true
            }
        }

        loop.advance(by: 0.1)
        #expect(captured.replied)

        let udpFrames = log.frames.compactMap(transportSegment)
            .filter { $0.proto == IPProtocol.udp.rawValue }
        #expect(!udpFrames.isEmpty)
        for f in udpFrames {
            // Checksum field (offset 6-7) is populated on egress, so verification runs.
            let field = (UInt16(f.segment[6]) << 8) | UInt16(f.segment[7])
            #expect(field != 0, "egress UDP datagram should carry a computed checksum")
            #expect(TransportChecksum.verifyTransport(source: f.source,
                                                      destination: f.destination,
                                                      proto: IPProtocol.udp.rawValue,
                                                      segment: f.segment),
                    "captured UDP datagram failed checksum verification")
        }
    }

    /// Every emitted ICMP echo frame (request + reply) carries a checksum that
    /// verifies over the message (R7.3).
    @Test func emittedICMPFramesVerify() {
        let loop = EventLoop()
        let log = FrameLog()
        let (kernelA, _, _, ipB) = makePair(loop: loop, log: log)

        final class Capture { var replies: [Programs.PingOutcome] = [] }
        let captured = Capture()
        kernelA.spawn("ping", Programs.ping(to: ipB, count: 1) { outcome in
            captured.replies.append(outcome)
        })

        loop.advance(by: 1.0)
        #expect(captured.replies.count == 1)

        let icmpFrames = log.frames.compactMap(transportSegment)
            .filter { $0.proto == IPProtocol.icmp.rawValue }
        #expect(!icmpFrames.isEmpty)
        for f in icmpFrames {
            #expect(TransportChecksum.verifyICMP(f.segment),
                    "captured ICMP message failed checksum verification")
        }
    }
}
