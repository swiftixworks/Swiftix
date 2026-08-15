import Testing
@testable import Swiftix

/// ARP resolution retry/backoff and dedup (Linux-like `mcast_solicit` /
/// `retrans_time_ms`). The stack broadcasts one ARP request for an unresolved
/// next hop, retries it a bounded number of times on the logical-time loop when
/// no reply arrives, dedupes concurrent resolutions of the same target onto a
/// single request burst, and finally discards the queued packets (surfacing an
/// `arpResolutionFailed` drop event) instead of leaking them forever.
@Suite("ARP resolution retry")
struct ARPResolutionTests {

    private let macA = MACAddress("02:00:00:00:00:0a")!
    private let macB = MACAddress("02:00:00:00:00:0b")!
    private let ipA = IPv4Address(10, 0, 0, 1)
    private let ipB = IPv4Address(10, 0, 0, 2)

    /// Counts ARP requests A emits and (optionally) IPv4 frames delivered to B.
    private final class WireLog {
        var arpRequestsFromA = 0
        var ipv4DeliveredToB = 0
    }

    private func isARPRequest(_ frame: PacketBuffer) -> Bool {
        guard let eth = EthernetFrame.parseHeader(frame),
              eth.etherType == EtherType.arp.rawValue,
              let arp = ARPPacket.parse(EthernetFrame.payload(frame)) else { return false }
        return arp.opcode == ARPPacket.Opcode.request.rawValue
    }

    private func isIPv4(_ frame: PacketBuffer) -> Bool {
        EthernetFrame.parseHeader(frame)?.etherType == EtherType.ipv4.rawValue
    }

    /// Wire A<->B on `loop`, counting into `log`. `dropARPFromA` decides, per ARP
    /// request A emits, whether the wire swallows it (to force a retry). All other
    /// frames (and every B→A frame) are delivered after `latency`. No pre-seeded
    /// neighbors: ARP must resolve dynamically.
    private func wire(_ stackA: NetworkStack, _ ifA: NetworkStack.Interface,
                      _ stackB: NetworkStack, _ ifB: NetworkStack.Interface,
                      on loop: EventLoop, log: WireLog,
                      dropARPFromA: @escaping (_ nth: Int) -> Bool = { _ in false }) {
        ifA.onEgress = { [weak stackB, weak ifB] frame in
            if self.isARPRequest(frame) {
                log.arpRequestsFromA += 1
                if dropARPFromA(log.arpRequestsFromA) { return }   // wire-drop this request
            }
            guard let stackB, let ifB else { return }
            loop.schedule(after: 0.005) {
                if self.isIPv4(frame) { log.ipv4DeliveredToB += 1 }
                stackB.receive(frame, on: ifB)
            }
        }
        ifB.onEgress = { [weak stackA, weak ifA] frame in
            guard let stackA, let ifA else { return }
            loop.schedule(after: 0.005) { stackA.receive(frame, on: ifA) }
        }
    }

    /// The first ARP request is lost on the wire; A retransmits ~1 s later and the
    /// retry resolves the next hop, so the queued datagram is finally delivered.
    @Test func retriesAfterFirstRequestLostThenResolves() {
        let loop = EventLoop()
        let stackA = NetworkStack(loop: loop)
        let stackB = NetworkStack(loop: loop)
        let ifA = stackA.configuredInterface(address: ipA, mac: macA)
        let ifB = stackB.configuredInterface(address: ipB, mac: macB)
        let log = WireLog()
        wire(stackA, ifA, stackB, ifB, on: loop, log: log, dropARPFromA: { $0 == 1 })

        stackA.sendUDP(sourcePort: 5000, destinationAddress: ipB, destinationPort: 7000,
                       payload: Array("hi".utf8))

        // Within the first second: one request went out and was lost; the next hop
        // is not resolved yet and the datagram is still queued (not delivered).
        loop.advance(by: 0.5)
        #expect(log.arpRequestsFromA == 1)
        #expect(stackA.snapshotARP().contains { $0.ip == ipB } == false)
        #expect(log.ipv4DeliveredToB == 0)

        // The ~1 s retry is delivered, B replies, A resolves and flushes the queue.
        loop.advance(by: 1.0)
        #expect(log.arpRequestsFromA == 2)
        #expect(stackA.snapshotARP().contains { $0.ip == ipB && $0.mac == macB })
        #expect(log.ipv4DeliveredToB == 1)
    }

    /// Three datagrams fired at an unresolved next hop before it resolves share a
    /// single ARP request (dedup), and all three are delivered once it resolves.
    @Test func dedupesConcurrentResolutionThenFlushesAll() {
        let loop = EventLoop()
        let stackA = NetworkStack(loop: loop)
        let stackB = NetworkStack(loop: loop)
        let ifA = stackA.configuredInterface(address: ipA, mac: macA)
        let ifB = stackB.configuredInterface(address: ipB, mac: macB)
        let log = WireLog()
        wire(stackA, ifA, stackB, ifB, on: loop, log: log)

        // Three back-to-back sends at t=0, all before any ARP reply can return.
        for _ in 0..<3 {
            stackA.sendUDP(sourcePort: 5000, destinationAddress: ipB, destinationPort: 7000,
                           payload: Array("x".utf8))
        }
        // Only one ARP request should have been broadcast for the shared next hop.
        #expect(log.arpRequestsFromA == 1)

        loop.advance(by: 0.1)
        // Resolved, and every queued datagram was flushed.
        #expect(stackA.snapshotARP().contains { $0.ip == ipB && $0.mac == macB })
        #expect(log.arpRequestsFromA == 1)     // still just the one burst
        #expect(log.ipv4DeliveredToB == 3)
    }

    /// When ARP never resolves, A retries `arpMaxAttempts` (3) times then gives up:
    /// the queued packet is discarded as `arpResolutionFailed`, and the resolution
    /// state is cleared so a later send starts a fresh resolution.
    @Test func givesUpAfterMaxAttemptsThenAllowsFreshResolution() {
        let loop = EventLoop()
        let stackA = NetworkStack(loop: loop)
        let stackB = NetworkStack(loop: loop)
        let ifA = stackA.configuredInterface(address: ipA, mac: macA)
        let ifB = stackB.configuredInterface(address: ipB, mac: macB)
        let log = WireLog()
        wire(stackA, ifA, stackB, ifB, on: loop, log: log, dropARPFromA: { _ in true })  // drop every ARP

        stackA.sendUDP(sourcePort: 5000, destinationAddress: ipB, destinationPort: 7000,
                       payload: Array("gone".utf8))

        // Initial request at t=0, retries at t=1 and t=2, give-up at t=3.
        loop.advance(by: 3.5)
        #expect(log.arpRequestsFromA == 3)     // 3 total attempts, all lost
        #expect(stackA.snapshotARP().contains { $0.ip == ipB } == false)
        #expect(stackA.snapshotPacketDrops().contains { $0.event.dropReason == .arpResolutionFailed })

        // Resolution state was cleared: a new send starts a brand-new ARP burst.
        stackA.sendUDP(sourcePort: 5000, destinationAddress: ipB, destinationPort: 7000,
                       payload: Array("again".utf8))
        #expect(log.arpRequestsFromA == 4)
    }
}
