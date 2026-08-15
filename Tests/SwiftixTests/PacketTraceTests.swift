import Testing
@testable import Swiftix

/// Packet trace hook (R14). An installed `onPacketTrace` hook observes every frame
/// the stack transmits (outbound) and every frame handed to `receive(_:on:)`
/// (inbound), receives the frame by value so it cannot mutate delivered bytes, and
/// is best-effort so a misbehaving hook never blocks the data path.
@Suite("Packet trace hook")
struct PacketTraceTests {

    /// A trace observation: the frame bytes, the interface index, and the direction.
    struct TraceEvent {
        let bytes: [UInt8]
        let interface: Int
        let direction: PacketDirection
    }

    /// Collects trace events observed on one stack.
    final class TraceLog {
        var events: [TraceEvent] = []
        var inbound: Int { events.filter { $0.direction == .inbound }.count }
        var outbound: Int { events.filter { $0.direction == .outbound }.count }
    }

    /// A lossless TestWire-style link on the logical loop (no dropping), so each
    /// peer's `receive` sees exactly what the sender's `onEgress` produced.
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

    /// A hook that observes every inbound/outbound frame: its outbound count matches
    /// the interface's `txPackets` and its inbound count matches `rxPackets + drops`
    /// (the counters from R13), and the delivered payload is unaltered by tracing.
    @Test func hookObservesEveryFrameAndPreservesBytes() {
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

        losslessWire(stackA, ifA, stackB, ifB, on: loop, latency: 0.01)
        stackA.configuredNeighbor(ip: ipB, mac: macB)
        stackB.configuredNeighbor(ip: ipA, mac: macA)

        let logA = TraceLog()
        let logB = TraceLog()
        stackA.onPacketTrace = { frame, index, direction in
            logA.events.append(TraceEvent(bytes: frame.bytes, interface: index, direction: direction))
        }
        stackB.onPacketTrace = { frame, index, direction in
            logB.events.append(TraceEvent(bytes: frame.bytes, interface: index, direction: direction))
        }

        let listener = stackB.listen(port: 80)
        let client = stackA.connect(localPort: 50_000, to: ipB, remotePort: 80)
        loop.advance(by: 0.5)   // handshake

        let payload: [UInt8] = (0..<4096).map { UInt8($0 & 0xFF) }
        client.send(payload)
        loop.advance(by: 1.0)
        loop.runUntilIdle()

        // The transfer actually completed with the exact bytes (tracing didn't alter them).
        let server = listener.dequeue()
        #expect(server != nil)
        let delivered = server?.read(max: 1 << 20) ?? []
        #expect(delivered == payload)

        // Every frame was observed: outbound == txPackets, inbound == rxPackets + drops (R14.2, R14.3).
        #expect(logA.outbound == ifA.counters.txPackets)
        #expect(logB.outbound == ifB.counters.txPackets)
        #expect(logA.inbound == ifA.counters.rxPackets + ifA.counters.drops)
        #expect(logB.inbound == ifB.counters.rxPackets + ifB.counters.drops)

        // The hook saw real traffic and reported the correct interface index (eth0 == 0).
        #expect(logA.outbound > 0)
        #expect(logA.inbound > 0)
        #expect(logA.events.allSatisfy { $0.interface == 0 })
        #expect(logB.events.allSatisfy { $0.interface == 0 })
    }

    /// No hook installed => frames are processed without any trace callback (R14.4):
    /// the transfer still completes normally.
    @Test func noHookProcessesFramesNormally() {
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

        losslessWire(stackA, ifA, stackB, ifB, on: loop, latency: 0.01)
        stackA.configuredNeighbor(ip: ipB, mac: macB)
        stackB.configuredNeighbor(ip: ipA, mac: macA)

        let listener = stackB.listen(port: 80)
        let client = stackA.connect(localPort: 50_000, to: ipB, remotePort: 80)
        loop.advance(by: 0.5)

        let payload: [UInt8] = (0..<1024).map { UInt8($0 & 0xFF) }
        client.send(payload)
        loop.advance(by: 1.0)
        loop.runUntilIdle()

        let delivered = listener.dequeue()?.read(max: 1 << 20) ?? []
        #expect(delivered == payload)
    }

    /// A misbehaving hook (one that tries to mutate its copy of the frame and has
    /// unrelated side effects) does not block the data path or alter delivered bytes
    /// (R14.5, R14.6): the transfer still completes with the exact payload.
    @Test func misbehavingHookDoesNotBlockDataPath() {
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

        losslessWire(stackA, ifA, stackB, ifB, on: loop, latency: 0.01)
        stackA.configuredNeighbor(ip: ipB, mac: macB)
        stackB.configuredNeighbor(ip: ipA, mac: macA)

        final class SideEffect { var touched = 0 }
        let sideEffect = SideEffect()
        // The hook receives the frame by value; mutating its own copy cannot affect
        // the bytes the stack transmits/delivers. It also does unrelated work.
        let misbehave: (PacketBuffer, Int, PacketDirection) -> Void = { frame, _, _ in
            var copy = frame
            copy.append([0xFF, 0xFF, 0xFF, 0xFF])   // mutate the local copy only
            _ = copy.count
            sideEffect.touched += 1
        }
        stackA.onPacketTrace = misbehave
        stackB.onPacketTrace = misbehave

        let listener = stackB.listen(port: 80)
        let client = stackA.connect(localPort: 50_000, to: ipB, remotePort: 80)
        loop.advance(by: 0.5)

        let payload: [UInt8] = (0..<4096).map { UInt8($0 & 0xFF) }
        client.send(payload)
        loop.advance(by: 1.0)
        loop.runUntilIdle()

        // Data path completed and bytes are untouched despite the hook's mutation attempt.
        let delivered = listener.dequeue()?.read(max: 1 << 20) ?? []
        #expect(delivered == payload)
        #expect(sideEffect.touched > 0)   // the hook really ran
    }
}
