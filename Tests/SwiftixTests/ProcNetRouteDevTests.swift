import Testing
@testable import Swiftix

/// Enriched `/proc/net/route` and `/proc/net/dev` views (R15.1, R15.2, R15.4).
///
/// `/proc/net/route` lists one line per route (destination network, prefix length,
/// gateway, egress interface), computed from `NetworkStack.snapshotRoutes()`.
/// `/proc/net/dev` appends each interface's rx/tx packets, rx/tx bytes, and drops
/// from `snapshotInterfaceCounters()`. Both are computed at read time, so they
/// reflect the current table and post-traffic counters (R15.4). Everything runs on
/// the logical-time EventLoop, matching the existing procfs/TestWire test style.
@Suite("procfs /proc/net/route + /proc/net/dev")
struct ProcNetRouteDevTests {

    /// Read a synthetic /proc file as text from a process spawned on `kernel`.
    private func readProcFile(_ path: String, _ kernel: Kernel, loop: EventLoop) -> String {
        final class Capture { var text = "" }
        let captured = Capture()
        kernel.spawn("reader") { ctx in
            guard let fd = ctx.open(path) else { return }
            captured.text = String(decoding: ctx.read(fd, max: 65535), as: UTF8.self)
            ctx.close(fd)
        }
        loop.runUntilIdle()
        return captured.text
    }

    /// A lossless counting wire so a ping run produces real, observable counters.
    private func losslessWire(_ stackA: NetworkStack, _ ifA: NetworkStack.Interface,
                              _ stackB: NetworkStack, _ ifB: NetworkStack.Interface,
                              on loop: EventLoop, latency: Double) {
        ifA.onEgress = { [weak stackB, weak ifB] frame in
            guard let stackB, let ifB else { return }
            loop.schedule(after: latency) { stackB.receive(frame, on: ifB) }
        }
        ifB.onEgress = { [weak stackA, weak ifA] frame in
            guard let stackA, let ifA else { return }
            loop.schedule(after: latency) { stackA.receive(frame, on: ifA) }
        }
    }

    /// `/proc/net/route` shows the auto-added directly-connected subnet route and a
    /// gateway-backed default route with the correct network, prefix, gateway, and
    /// egress interface (R15.1).
    @Test func procNetRouteListsConnectedAndGatewayRoutes() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        // Attaching with /24 auto-adds a directly-connected route 10.0.0.0/24 via eth0.
        kernel.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 5),
                                        mac: MACAddress("02:00:00:00:00:09")!,
                                        prefixLength: 24)
        // A default route via a gateway on eth0.
        kernel.netns.stack.configuredRoute(destination: IPv4Address(0, 0, 0, 0),
                                    prefixLength: 0,
                                    gateway: IPv4Address(10, 0, 0, 1),
                                    interfaceIndex: 0)

        let text = readProcFile("/proc/net/route", kernel, loop: loop)

        // Directly-connected subnet route: no gateway is shown as "*".
        #expect(text.contains("10.0.0.0/24 * eth0"))
        // Default route via the gateway.
        #expect(text.contains("0.0.0.0/0 10.0.0.1 eth0"))
    }

    /// `/proc/net/dev` includes the per-interface counter columns and reflects
    /// post-traffic values: after a ping run the columns are non-zero and match the
    /// live `snapshotInterfaceCounters()` (R15.2, R15.4).
    @Test func procNetDevReflectsPostTrafficCounters() {
        let loop = EventLoop()
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)

        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let stackA = kernelA.netns.stack
        let stackB = kernelB.netns.stack
        let ifA = stackA.configuredInterface(address: ipA, mac: MACAddress("02:00:00:00:00:0a")!)
        let ifB = stackB.configuredInterface(address: ipB, mac: MACAddress("02:00:00:00:00:0b")!)
        losslessWire(stackA, ifA, stackB, ifB, on: loop, latency: 0.005)

        // Before any traffic: the columns are present and zero.
        let before = readProcFile("/proc/net/dev", kernelA, loop: loop)
        #expect(before.contains("eth0"))
        #expect(before.contains("tx_packets=0"))
        #expect(before.contains("rx_packets=0"))

        // Run a ping so there is real traffic to count.
        final class Capture { var replies: [Programs.PingOutcome] = [] }
        let captured = Capture()
        kernelA.spawn("ping", Programs.ping(to: ipB, count: 3) { outcome in
            captured.replies.append(outcome)
        })
        loop.advance(by: 5.0)
        #expect(captured.replies.count == 3)

        // After the ping: /proc/net/dev reflects the live counters (R15.4).
        let after = readProcFile("/proc/net/dev", kernelA, loop: loop)
        #expect(after.contains("tx_packets=\(ifA.counters.txPackets)"))
        #expect(after.contains("rx_packets=\(ifA.counters.rxPackets)"))
        #expect(after.contains("tx_bytes=\(ifA.counters.txBytes)"))
        #expect(after.contains("rx_bytes=\(ifA.counters.rxBytes)"))
        #expect(after.contains("drops=\(ifA.counters.drops)"))
        // The values actually moved (there was traffic).
        #expect(ifA.counters.txPackets > 0)
        #expect(ifA.counters.rxPackets > 0)
    }
}
