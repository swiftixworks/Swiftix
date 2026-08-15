import Testing
@testable import Swiftix

/// Per-interface traffic counters (R13). Every frame the stack transmits bumps the
/// egress interface's tx counters, and every frame handed to `receive(_:on:)` is
/// accounted for as either an accepted packet (rx) or a drop — so the counters
/// conserve exactly across a run (design Property 5):
///
///   - an interface's `txPackets` == the number of frames handed to its `onEgress`,
///   - `rxPackets + drops`      == the number of frames passed to `receive`.
@Suite("Per-interface counters")
struct InterfaceCountersTests {

    /// Ground-truth tallies collected by an instrumented, TestWire-style link so the
    /// test can compare the stack's internal counters against an independent count.
    final class WireStats {
        var egressPacketsA = 0, egressPacketsB = 0
        var egressBytesA = 0,   egressBytesB = 0
        var recvPacketsA = 0,   recvPacketsB = 0
        var recvBytesA = 0,     recvBytesB = 0
    }

    /// A counting stand-in for `TestWire.connect`: wires A<->B with a fixed latency on
    /// the logical loop and tallies every frame handed to `onEgress` (tx side) and
    /// every frame delivered to `receive` (rx side). No frames are dropped on the wire,
    /// so the peer's `receive` sees exactly what egress produced.
    private func countingWire(_ stackA: NetworkStack, _ ifA: NetworkStack.Interface,
                              _ stackB: NetworkStack, _ ifB: NetworkStack.Interface,
                              on loop: EventLoop, latency: Double, stats: WireStats) {
        ifA.onEgress = { [weak stackB, weak ifB] frame in
            stats.egressPacketsA += 1
            stats.egressBytesA += frame.count
            guard let stackB, let ifB else { return }
            loop.schedule(after: latency) {
                stats.recvPacketsB += 1
                stats.recvBytesB += frame.count
                stackB.receive(frame, on: ifB)
            }
        }
        ifB.onEgress = { [weak stackA, weak ifA] frame in
            stats.egressPacketsB += 1
            stats.egressBytesB += frame.count
            guard let stackA, let ifA else { return }
            loop.schedule(after: latency) {
                stats.recvPacketsA += 1
                stats.recvBytesA += frame.count
                stackA.receive(frame, on: ifA)
            }
        }
    }

    /// Assert both directions conserve: tx counters equal frames handed to onEgress,
    /// and rx packets + drops equal frames delivered to receive. With a lossless wire
    /// there are no drops, so rx bytes equal the delivered byte total too.
    private func expectConservation(_ ifA: NetworkStack.Interface, _ ifB: NetworkStack.Interface,
                                    _ stats: WireStats) {
        // tx side (R13.2)
        #expect(ifA.counters.txPackets == stats.egressPacketsA)
        #expect(ifB.counters.txPackets == stats.egressPacketsB)
        #expect(ifA.counters.txBytes == stats.egressBytesA)
        #expect(ifB.counters.txBytes == stats.egressBytesB)
        // rx side + conservation (R13.3, R13.4)
        #expect(ifA.counters.rxPackets + ifA.counters.drops == stats.recvPacketsA)
        #expect(ifB.counters.rxPackets + ifB.counters.drops == stats.recvPacketsB)
        // lossless wire => no drops => rx bytes equal delivered bytes
        #expect(ifA.counters.drops == 0)
        #expect(ifB.counters.drops == 0)
        #expect(ifA.counters.rxBytes == stats.recvBytesA)
        #expect(ifB.counters.rxBytes == stats.recvBytesB)
    }

    /// Counters conserve across a ping run (ARP resolution + ICMP echo/reply).
    @Test func countersConserveOverPingRun() {
        let loop = EventLoop()
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)

        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let stackA = kernelA.netns.stack
        let stackB = kernelB.netns.stack
        let ifA = stackA.configuredInterface(address: ipA, mac: MACAddress("02:00:00:00:00:0a")!)
        let ifB = stackB.configuredInterface(address: ipB, mac: MACAddress("02:00:00:00:00:0b")!)

        let stats = WireStats()
        countingWire(stackA, ifA, stackB, ifB, on: loop, latency: 0.005, stats: stats)

        final class Capture { var replies: [Programs.PingOutcome] = [] }
        let captured = Capture()
        kernelA.spawn("ping", Programs.ping(to: ipB, count: 3) { outcome in
            captured.replies.append(outcome)
        })

        loop.advance(by: 5.0)

        // The ping actually completed (so there was real traffic to count).
        #expect(captured.replies.count == 3)
        // The snapshot API reports the same live counters.
        let snap = stackA.snapshotInterfaceCounters()
        #expect(snap.count == 1)
        #expect(snap.first?.name == "eth0")
        #expect(snap.first?.counters.txPackets == ifA.counters.txPackets)

        expectConservation(ifA, ifB, stats)
    }

    /// Counters conserve across a TCP handshake + data transfer + teardown.
    @Test func countersConserveOverTCPRun() {
        let loop = EventLoop()
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!

        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let stackA = kernelA.netns.stack
        let stackB = kernelB.netns.stack
        let ifA = stackA.configuredInterface(address: ipA, mac: macA)
        let ifB = stackB.configuredInterface(address: ipB, mac: macB)

        let stats = WireStats()
        countingWire(stackA, ifA, stackB, ifB, on: loop, latency: 0.01, stats: stats)
        stackA.configuredNeighbor(ip: ipB, mac: macB)
        stackB.configuredNeighbor(ip: ipA, mac: macA)

        let listener = stackB.listen(port: 80)
        let client = stackA.connect(localPort: 50_000, to: ipB, remotePort: 80)
        loop.advance(by: 0.5)   // handshake

        let payload: [UInt8] = (0..<4096).map { UInt8($0 & 0xFF) }
        client.send(payload)
        loop.advance(by: 1.0)

        // Sanity: the transfer actually happened.
        let server = listener.dequeue()
        #expect(server != nil)
        let delivered = server?.read(max: 1 << 20) ?? []
        #expect(delivered == payload)

        loop.runUntilIdle()
        expectConservation(ifA, ifB, stats)
    }

    /// A frame that fails to parse is counted as a drop, not an accepted packet, and
    /// does not disturb the byte counters.
    @Test func corruptFrameIncrementsDrops() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let iface = kernel.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 1),
                                                        mac: MACAddress("02:00:00:00:00:01")!)

        // Too short to even hold an Ethernet header => parse failure => drop.
        let garbage = PacketBuffer([0x00, 0x01, 0x02])
        kernel.netns.stack.receive(garbage, on: iface)

        #expect(iface.counters.drops == 1)
        #expect(iface.counters.rxPackets == 0)
        #expect(iface.counters.rxBytes == 0)
    }

    /// Property-style: over several seeds and random payload sizes, counters always
    /// conserve on a lossless wire and the byte totals stay consistent.
    @Test func countersConserveOverSeededTCPRuns() {
        for seed in [UInt64(1), 42, 1337, 0xDEADBEEF, 987654321] {
            var prng = SplitMix64(seed: seed)
            let size = 1 + Int(prng.next() % 8192)   // 1..8192 bytes

            let loop = EventLoop()
            let ipA = IPv4Address(10, 0, 0, 1)
            let ipB = IPv4Address(10, 0, 0, 2)
            let macA = MACAddress("02:00:00:00:00:0a")!
            let macB = MACAddress("02:00:00:00:00:0b")!

            let kernelA = Kernel(loop: loop)
            let kernelB = Kernel(loop: loop)
            let stackA = kernelA.netns.stack
            let stackB = kernelB.netns.stack
            let ifA = stackA.configuredInterface(address: ipA, mac: macA)
            let ifB = stackB.configuredInterface(address: ipB, mac: macB)

            let stats = WireStats()
            countingWire(stackA, ifA, stackB, ifB, on: loop, latency: 0.01, stats: stats)
            stackA.configuredNeighbor(ip: ipB, mac: macB)
            stackB.configuredNeighbor(ip: ipA, mac: macA)

            let listener = stackB.listen(port: 80)
            let client = stackA.connect(localPort: 50_000, to: ipB, remotePort: 80)
            loop.advance(by: 0.5)

            let payload: [UInt8] = (0..<size).map { UInt8($0 & 0xFF) }
            client.send(payload)
            loop.advance(by: 2.0)
            loop.runUntilIdle()

            let server = listener.dequeue()
            let delivered = server?.read(max: 1 << 20) ?? []
            #expect(delivered == payload, "seed \(seed): payload not fully delivered")

            expectConservation(ifA, ifB, stats)
        }
    }
}
