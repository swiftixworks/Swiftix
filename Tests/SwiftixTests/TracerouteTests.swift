/// Tests for the `traceroute` command and the underlying TTL + ICMP
/// time-exceeded path through the stack. A 3-node topology
/// (host A → router → host B) wired on the logical-time EventLoop verifies that
/// incrementing TTL probes reveal intermediate hops and terminate at the
/// destination.
import Testing
@testable import Swiftix

@Suite("Traceroute")
struct TracerouteTests {

    /// traceroute from A to B through a router: hop 1 is the router (TTL expired),
    /// hop 2 is the destination (echo reply from B). Validates that the stack
    /// correctly delivers ICMP time-exceeded back to the echo waiter and that a
    /// full echo reply terminates the trace.
    @Test func tracerouteShowsIntermediateRouterAndDestination() {
        let loop = EventLoop()
        let hostA = Kernel(loop: loop)
        let router = Kernel(loop: loop)
        let hostB = Kernel(loop: loop)

        let ipA = IPv4Address(10, 0, 0, 1)
        let ipR0 = IPv4Address(10, 0, 0, 254)
        let ipR1 = IPv4Address(10, 0, 1, 254)
        let ipB = IPv4Address(10, 0, 1, 2)

        let ifA = hostA.netns.stack.configuredInterface(address: ipA,
                                                        mac: MACAddress("02:00:00:00:00:0a")!)
        let ifR0 = router.netns.stack.configuredInterface(address: ipR0,
                                                          mac: MACAddress("02:00:00:00:00:f0")!)
        let ifR1 = router.netns.stack.configuredInterface(address: ipR1,
                                                          mac: MACAddress("02:00:00:00:00:f1")!)
        let ifB = hostB.netns.stack.configuredInterface(address: ipB,
                                                        mac: MACAddress("02:00:00:00:00:0b")!)

        // Routes: A → router → B
        hostA.netns.stack.configuredRoute(destination: IPv4Address(0, 0, 0, 0),
                                          prefixLength: 0, gateway: ipR0, interfaceIndex: 0)
        hostB.netns.stack.configuredRoute(destination: IPv4Address(0, 0, 0, 0),
                                          prefixLength: 0, gateway: ipR1, interfaceIndex: 0)
        router.netns.stack.configure(.setIPForwarding(true))

        // Pre-seed ARP so we don't need to wait for resolution
        hostA.netns.stack.configuredNeighbor(ip: ipR0, mac: ifR0.mac)
        hostB.netns.stack.configuredNeighbor(ip: ipR1, mac: ifR1.mac)
        router.netns.stack.configuredNeighbor(ip: ipA, mac: ifA.mac)
        router.netns.stack.configuredNeighbor(ip: ipB, mac: ifB.mac)

        // Wire: A ↔ Router ↔ B
        let latency = 0.005
        wire(hostA.netns.stack, ifA, router.netns.stack, ifR0, on: loop, latency: latency)
        wire(router.netns.stack, ifR1, hostB.netns.stack, ifB, on: loop, latency: latency)

        // Run traceroute using the async icmpEcho API directly (same logic the
        // command uses): TTL 1 should get a time-exceeded from the router, TTL 2
        // should reach B.
        final class Capture {
            var hops: [(ttl: Int, from: IPv4Address?)] = []
        }
        let captured = Capture()
        let identifier: UInt16 = 42

        hostA.spawn("traceroute") { (ctx: ProcessContext) async in
            for hop in 1...5 {
                let ttl = UInt8(hop)
                let outcome = try? await ctx.icmpEcho(to: ipB,
                                                     identifier: identifier,
                                                     sequence: UInt16(hop),
                                                     ttl: ttl,
                                                     timeout: 1.0)
                switch outcome {
                case let .reply(from, _, _, _, _):
                    captured.hops.append((hop, from))
                    if from == ipB { ctx.exit(0); return }
                case .timeout:
                    captured.hops.append((hop, nil))
                case .none:
                    ctx.exit(1); return
                }
            }
            ctx.exit(0)
        }

        loop.advance(by: 5.0)

        // Expect 2 hops: router (time-exceeded) then destination (echo reply)
        #expect(captured.hops.count == 2)
        if captured.hops.count >= 2 {
            #expect(captured.hops[0].from == ipR0)   // router replied with time-exceeded
            #expect(captured.hops[1].from == ipB)    // destination replied with echo-reply
        }
    }

    /// When TTL is already 1 and there's no router (direct link), the destination
    /// should reply with a normal echo reply (TTL doesn't expire on the final hop
    /// because the destination consumes it locally).
    @Test func directLinkTTL1ReachesDestination() {
        let loop = EventLoop()
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)

        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)

        let ifA = kernelA.netns.stack.configuredInterface(address: ipA,
                                                          mac: MACAddress("02:00:00:00:00:0a")!)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB,
                                                          mac: MACAddress("02:00:00:00:00:0b")!)
        kernelA.netns.stack.configuredNeighbor(ip: ipB, mac: ifB.mac)
        kernelB.netns.stack.configuredNeighbor(ip: ipA, mac: ifA.mac)
        wire(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB, on: loop, latency: 0.005)

        final class Capture { var from: IPv4Address? }
        let captured = Capture()

        kernelA.spawn("probe") { (ctx: ProcessContext) async in
            let outcome = try? await ctx.icmpEcho(to: ipB,
                                                  identifier: 1,
                                                  sequence: 1,
                                                  ttl: 1,
                                                  timeout: 1.0)
            if case let .reply(from, _, _, _, _) = outcome { captured.from = from }
            ctx.exit(0)
        }

        loop.advance(by: 1.0)
        #expect(captured.from == ipB)
    }

    /// Timeout when no intermediate or destination responds (unreachable).
    @Test func tracerouteTimesOutWhenUnreachable() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 1),
                                              mac: MACAddress("02:00:00:00:00:01")!)

        final class Capture { var timedOut = false }
        let captured = Capture()

        kernel.spawn("probe") { (ctx: ProcessContext) async in
            let outcome = try? await ctx.icmpEcho(to: IPv4Address(10, 0, 0, 99),
                                                  identifier: 1,
                                                  sequence: 1,
                                                  ttl: 1,
                                                  timeout: 0.5)
            if case .timeout = outcome { captured.timedOut = true }
            ctx.exit(0)
        }

        loop.advance(by: 2.0)
        #expect(captured.timedOut == true)
    }

    /// The `traceroute` *command* (not the raw `icmpEcho` API) sends three probes
    /// per hop like real traceroute and prints them as three RTT columns on one
    /// line per hop, revealing the router at hop 1 and the destination at hop 2.
    @Test func tracerouteCommandSendsThreeProbesPerHop() async {
        let loop = EventLoop()
        let hostA = Kernel(loop: loop)
        let router = Kernel(loop: loop)
        let hostB = Kernel(loop: loop)

        let ipA = IPv4Address(10, 0, 0, 1)
        let ipR0 = IPv4Address(10, 0, 0, 254)
        let ipR1 = IPv4Address(10, 0, 1, 254)
        let ipB = IPv4Address(10, 0, 1, 2)

        let ifA = hostA.netns.stack.configuredInterface(address: ipA, mac: MACAddress("02:00:00:00:00:0a")!)
        let ifR0 = router.netns.stack.configuredInterface(address: ipR0, mac: MACAddress("02:00:00:00:00:f0")!)
        let ifR1 = router.netns.stack.configuredInterface(address: ipR1, mac: MACAddress("02:00:00:00:00:f1")!)
        let ifB = hostB.netns.stack.configuredInterface(address: ipB, mac: MACAddress("02:00:00:00:00:0b")!)

        hostA.netns.stack.configuredRoute(destination: IPv4Address(0, 0, 0, 0),
                                          prefixLength: 0, gateway: ipR0, interfaceIndex: 0)
        hostB.netns.stack.configuredRoute(destination: IPv4Address(0, 0, 0, 0),
                                          prefixLength: 0, gateway: ipR1, interfaceIndex: 0)
        router.netns.stack.configure(.setIPForwarding(true))
        hostA.netns.stack.configuredNeighbor(ip: ipR0, mac: ifR0.mac)
        hostB.netns.stack.configuredNeighbor(ip: ipR1, mac: ifR1.mac)
        router.netns.stack.configuredNeighbor(ip: ipA, mac: ifA.mac)
        router.netns.stack.configuredNeighbor(ip: ipB, mac: ifB.mac)

        let latency = 0.005
        wire(hostA.netns.stack, ifA, router.netns.stack, ifR0, on: loop, latency: latency)
        wire(router.netns.stack, ifR1, hostB.netns.stack, ifB, on: loop, latency: latency)

        let sink = Sink()
        let pty = PseudoTerminal()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            sink.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        hostA.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("traceroute 10.0.1.2\n".utf8))
        // Two hops × three probes ⇒ six RTT columns once the trace completes.
        await drive(loop, until: { occurrences(of: " ms", in: text(sink)) >= 6 })

        let output = text(sink)
        #expect(output.contains("10.0.0.254"))              // router revealed at hop 1
        #expect(output.contains("10.0.1.2"))                // destination reached at hop 2
        #expect(occurrences(of: " ms", in: output) == 6)    // exactly 3 probes per hop, 2 hops
    }

    // MARK: - Helpers

    final class Sink: @unchecked Sendable { var out: [UInt8] = [] }

    private func text(_ sink: Sink) -> String { String(decoding: sink.out, as: UTF8.self) }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }

    private func drive(_ loop: EventLoop, until done: @Sendable () -> Bool, max: Int = 200_000) async {
        var pumps = 0
        while !done() && pumps < max {
            loop.advance(by: 0)
            loop.runNext()
            await Task.yield()
            pumps += 1
        }
    }

    private func wire(_ stackA: NetworkStack, _ ifA: NetworkStack.Interface,
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
}
