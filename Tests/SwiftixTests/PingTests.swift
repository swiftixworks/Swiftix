import Testing
@testable import Swiftix

@Suite("ICMP ping with dynamic ARP")
struct PingTests {

    /// A `ping` process on A reaches B with no pre-seeded neighbor entries: the
    /// stack resolves B's MAC via ARP, the ICMP echo round-trips (through the
    /// test-wired link), B auto-replies, and ping reports a reply from B with a
    /// positive RTT.
    @Test func pingResolvesARPThenGetsEchoReply() {
        let loop = EventLoop()
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)

        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB, on: loop, latency: 0.005)
        // No addNeighbor — ARP must resolve dynamically.

        final class Capture { var replies: [Programs.PingOutcome] = [] }
        let captured = Capture()
        kernelA.spawn("ping", Programs.ping(to: ipB, count: 1) { outcome in
            captured.replies.append(outcome)
        })

        loop.advance(by: 1.0)

        #expect(captured.replies.count == 1)
        guard case let .reply(from, sequence, _, _, rtt)? = captured.replies.first else {
            Issue.record("expected a ping reply")
            return
        }
        #expect(from == ipB)
        #expect(sequence == 1)
        #expect(rtt > 0)
    }

    /// With no reachable peer (ARP never resolves), the echo request goes
    /// unanswered and `ping` reports a timeout for that sequence.
    @Test func pingTimesOutWhenUnreachable() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 1),
                                           mac: MACAddress("02:00:00:00:00:01")!)
        // No wire, no neighbor: the request can never be answered.

        final class Capture { var outcomes: [Programs.PingOutcome] = [] }
        let captured = Capture()
        kernel.spawn("ping", Programs.ping(to: IPv4Address(10, 0, 0, 99), count: 1, timeout: 0.5) { outcome in
            captured.outcomes.append(outcome)
        })

        loop.advance(by: 2.0)

        #expect(captured.outcomes.count == 1)
        guard case .timeout(let sequence)? = captured.outcomes.first else {
            Issue.record("expected a ping timeout")
            return
        }
        #expect(sequence == 1)
    }

    /// Wire two hosts A<->B with pre-seeded ARP on a `latency`-delayed logical
    /// link. Both kernels are returned so the caller retains `kernelB` — the
    /// TestWire egress closures hold the peer stack weakly, so a dropped `kernelB`
    /// would silently swallow every reply.
    private func makeWiredPair(loop: EventLoop, latency: Double = 0.005)
        -> (kernelA: Kernel, kernelB: Kernel, ipA: IPv4Address, ipB: IPv4Address) {
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB, on: loop, latency: latency)
        kernelA.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        kernelB.netns.stack.configuredNeighbor(ip: ipA, mac: macA)
        return (kernelA, kernelB, ipA, ipB)
    }

    /// Requests are paced ~`interval` apart (send-to-send), not fired back to back:
    /// a 3-count ping streams one reply per interval and only finishes near t≈2s,
    /// and the run's `PingStatistics` tally all three replies with 0 loss. This is
    /// the behavior fix — before, all three returned in the first logical instant.
    @Test func pingPacesRequestsOneIntervalApart() {
        let loop = EventLoop()
        let pair = makeWiredPair(loop: loop)

        final class Capture {
            var replies: [Programs.PingOutcome] = []
            var stats: Programs.PingStatistics?
        }
        let captured = Capture()
        pair.kernelA.spawn("ping", Programs.ping(to: pair.ipB, count: 3, interval: 1.0,
                                                 onFinish: { captured.stats = $0 }) { outcome in
            captured.replies.append(outcome)
        })

        // Seq 1 goes out at t=0 and replies within one RTT; seq 2 is not sent until
        // one interval later (~t=1.0), so at t=0.5 only one reply exists.
        loop.advance(by: 0.5)
        #expect(captured.replies.count == 1)
        #expect(captured.stats == nil)

        loop.advance(by: 1.0)   // t=1.5: seq 2 sent at ~t=1.0
        #expect(captured.replies.count == 2)
        #expect(captured.stats == nil)

        loop.advance(by: 1.0)   // t=2.5: seq 3 sent at ~t=2.0, then the run finishes
        #expect(captured.replies.count == 3)
        #expect(captured.stats?.transmitted == 3)
        #expect(captured.stats?.received == 3)
        #expect(captured.stats?.lost == 0)
        #expect(captured.stats?.lossFraction == 0)
        #expect((captured.stats?.minSeconds ?? -1) > 0)
        #expect((captured.stats?.averageSeconds ?? -1) > 0)
        #expect((captured.stats?.maxSeconds ?? -1) > 0)
        #expect(captured.stats?.deviationSeconds != nil)
    }

    /// A reply reports the reply packet's TTL (B's default outgoing TTL of 64,
    /// undecremented over a direct link) and the received ICMP message size — the
    /// default 56-byte payload plus the 8-byte header = 64, the "64 bytes from …"
    /// Linux prints.
    @Test func pingReplyReportsTTLAndByteCount() {
        let loop = EventLoop()
        let pair = makeWiredPair(loop: loop)

        final class Capture { var replies: [Programs.PingOutcome] = [] }
        let captured = Capture()
        pair.kernelA.spawn("ping", Programs.ping(to: pair.ipB, count: 1) { outcome in
            captured.replies.append(outcome)
        })

        loop.advance(by: 1.0)

        guard case let .reply(_, _, ttl, bytes, _)? = captured.replies.first else {
            Issue.record("expected a ping reply")
            return
        }
        #expect(ttl == 64)
        #expect(bytes == 64)   // 56-byte payload + 8-byte ICMP header
    }

    /// When nothing answers, every request times out and the statistics report
    /// full loss over the transmitted count (with an empty RTT distribution).
    @Test func pingStatisticsReportFullLossWhenUnreachable() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 1),
                                                mac: MACAddress("02:00:00:00:00:01")!)

        final class Capture {
            var outcomes: [Programs.PingOutcome] = []
            var stats: Programs.PingStatistics?
        }
        let captured = Capture()
        kernel.spawn("ping", Programs.ping(to: IPv4Address(10, 0, 0, 99),
                                           count: 2, interval: 1.0, timeout: 0.5,
                                           onFinish: { captured.stats = $0 }) { outcome in
            captured.outcomes.append(outcome)
        })

        loop.advance(by: 3.0)

        #expect(captured.outcomes.count == 2)
        #expect(captured.outcomes.allSatisfy { if case .timeout = $0 { return true } else { return false } })
        #expect(captured.stats?.transmitted == 2)
        #expect(captured.stats?.received == 0)
        #expect(captured.stats?.lost == 2)
        #expect(captured.stats?.lossFraction == 1.0)
        #expect(captured.stats?.minSeconds == nil)
        #expect(captured.stats?.averageSeconds == nil)
    }

    /// A datagram with a corrupted IPv4 header checksum is dropped on parse.
    @Test func ipv4RejectsBadHeaderChecksum() {
        var packet = IPv4Packet.build(source: IPv4Address(10, 0, 0, 1),
                                      destination: IPv4Address(10, 0, 0, 2),
                                      proto: IPProtocol.udp.rawValue,
                                      payload: [1, 2, 3])
        #expect(IPv4Packet.parse(packet[...]) != nil)   // intact: parses
        packet[12] ^= 0xFF                                // corrupt a header byte (source octet)
        #expect(IPv4Packet.parse(packet[...]) == nil)    // checksum mismatch: dropped
    }

    /// ARP build/parse round-trip.
    @Test func arpRoundTrip() {
        let bytes = ARPPacket.build(opcode: .request,
                                    senderMAC: MACAddress("02:00:00:00:00:01")!,
                                    senderIP: IPv4Address(10, 0, 0, 1),
                                    targetMAC: .broadcast,
                                    targetIP: IPv4Address(10, 0, 0, 2))
        let parsed = ARPPacket.parse(bytes[...])
        #expect(parsed?.opcode == ARPPacket.Opcode.request.rawValue)
        #expect(parsed?.senderIP == IPv4Address(10, 0, 0, 1))
        #expect(parsed?.targetIP == IPv4Address(10, 0, 0, 2))
    }

    /// ICMP echo build/parse round-trip.
    @Test func icmpEchoRoundTrip() {
        let bytes = ICMPMessage.buildEcho(type: .echoRequest, identifier: 7, sequence: 3, payload: [9, 9])
        let echo = ICMPMessage.parseEcho(bytes[...])
        #expect(echo?.type == ICMPMessage.MessageType.echoRequest.rawValue)
        #expect(echo?.identifier == 7)
        #expect(echo?.sequence == 3)
        #expect(echo.map { Array($0.payload) } == [9, 9])
    }
}
