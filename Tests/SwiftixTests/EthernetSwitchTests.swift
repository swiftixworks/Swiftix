import Testing
@testable import Swiftix

@Suite("L2 Ethernet switch")
struct EthernetSwitchTests {
    final class FrameLog {
        var frames: [PacketBuffer] = []
        func clear() { frames.removeAll() }
    }

    @Test func floodsUnknownUnicastAndLearnsSource() {
        let loop = EventLoop()
        let lan = EthernetSwitch(loop: loop)
        let portA = lan.addPort()
        let portB = lan.addPort()
        let portC = lan.addPort()
        let logA = FrameLog()
        let logB = FrameLog()
        let logC = FrameLog()
        portA.onEgress = { logA.frames.append($0) }
        portB.onEgress = { logB.frames.append($0) }
        portC.onEgress = { logC.frames.append($0) }

        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let outbound = frame(source: macA, destination: macB)

        lan.receive(outbound, on: portA)
        loop.runUntilIdle()

        #expect(logA.frames.isEmpty)
        #expect(logB.frames.map(\.bytes) == [outbound.bytes])
        #expect(logC.frames.map(\.bytes) == [outbound.bytes])
        #expect(lan.snapshotForwardingTable().contains { $0.mac == macA && $0.port == portA.index })
    }

    @Test func forwardsKnownUnicastToLearnedPortOnly() {
        let loop = EventLoop()
        let lan = EthernetSwitch(loop: loop)
        let portA = lan.addPort()
        let portB = lan.addPort()
        let portC = lan.addPort()
        let logA = FrameLog()
        let logB = FrameLog()
        let logC = FrameLog()
        portA.onEgress = { logA.frames.append($0) }
        portB.onEgress = { logB.frames.append($0) }
        portC.onEgress = { logC.frames.append($0) }

        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        lan.receive(frame(source: macB, destination: .broadcast), on: portB)
        loop.runUntilIdle()
        logA.clear()
        logB.clear()
        logC.clear()

        let unicast = frame(source: macA, destination: macB)
        lan.receive(unicast, on: portA)
        loop.runUntilIdle()

        #expect(logA.frames.isEmpty)
        #expect(logB.frames.map(\.bytes) == [unicast.bytes])
        #expect(logC.frames.isEmpty)
    }

    @Test func agesForwardingEntries() {
        let loop = EventLoop()
        let lan = EthernetSwitch(loop: loop, agingTime: 0.5)
        let portA = lan.addPort()
        _ = lan.addPort()

        lan.receive(frame(source: MACAddress("02:00:00:00:00:0a")!,
                          destination: MACAddress("02:00:00:00:00:0b")!),
                    on: portA)
        #expect(lan.snapshotForwardingTable().count == 1)

        loop.advance(by: 0.5)

        #expect(lan.snapshotForwardingTable().isEmpty)
    }

    @Test func connectsHostsOnSharedLANWithDynamicARP() {
        let loop = EventLoop()
        let lan = EthernetSwitch(loop: loop, forwardingDelay: 0.005)
        let hostA = Kernel(loop: loop)
        let hostB = Kernel(loop: loop)
        let hostC = Kernel(loop: loop)
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let macC = MACAddress("02:00:00:00:00:0c")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let ipC = IPv4Address(10, 0, 0, 3)
        let ifA = hostA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = hostB.netns.stack.configuredInterface(address: ipB, mac: macB)
        let ifC = hostC.netns.stack.configuredInterface(address: ipC, mac: macC)
        let portA = lan.connect(hostA.netns.stack, interface: ifA)
        let portB = lan.connect(hostB.netns.stack, interface: ifB)
        _ = lan.connect(hostC.netns.stack, interface: ifC)

        final class Capture { var replies: [Programs.PingOutcome] = [] }
        let captured = Capture()
        hostA.spawn("ping", Programs.ping(to: ipB, count: 1) { outcome in
            captured.replies.append(outcome)
        })

        loop.advance(by: 1.0)

        #expect(captured.replies.count == 1)
        guard case let .reply(from, sequence, _, _, rtt)? = captured.replies.first else {
            Issue.record("expected a ping reply through the switch")
            return
        }
        #expect(from == ipB)
        #expect(sequence == 1)
        #expect(rtt > 0)
        let learned = lan.snapshotForwardingTable()
        #expect(learned.contains { $0.mac == macA && $0.port == portA.index })
        #expect(learned.contains { $0.mac == macB && $0.port == portB.index })
    }

    @Test func foreignInterfaceBindingCannotRemoveMatchingGeneration() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let stack = kernel.netns.stack
        let interfaceA = stack.configuredInterface(
            address: IPv4Address(10, 0, 0, 1),
            mac: MACAddress("02:00:00:00:00:01")!)
        let interfaceB = stack.configuredInterface(
            address: IPv4Address(10, 0, 0, 2),
            mac: MACAddress("02:00:00:00:00:02")!)
        let logA = FrameLog()
        let logB = FrameLog()

        let bindingA = interfaceA.installEgress { logA.frames.append($0) }
        let bindingB = interfaceB.installEgress { logB.frames.append($0) }
        #expect(interfaceA.ownsEgress(bindingA))
        #expect(interfaceB.ownsEgress(bindingB))

        // Both interfaces are at generation one. Interface identity must still
        // prevent A's otherwise matching token from detaching B.
        interfaceB.removeEgress(bindingA)
        #expect(!interfaceA.ownsEgress(bindingB))
        #expect(interfaceB.ownsEgress(bindingB))

        let outbound = frame(
            source: MACAddress("02:00:00:00:00:02")!,
            destination: .broadcast)
        interfaceB.onEgress?(outbound)
        #expect(logA.frames.isEmpty)
        #expect(logB.frames.map(\.bytes) == [outbound.bytes])
    }

    @Test func removingPortCancelsDeliveryAndPurgesLearnedState() {
        let loop = EventLoop()
        let lan = EthernetSwitch(loop: loop, forwardingDelay: 0.5)
        let portA = lan.addPort()
        let portB = lan.addPort()
        let logB = FrameLog()
        portB.onEgress = { logB.frames.append($0) }

        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        lan.receive(frame(source: macB, destination: .broadcast), on: portB)
        loop.advance(by: 0.5)

        #expect(lan.snapshotForwardingTable().contains {
            $0.mac == macB && $0.port == portB.index
        })
        let pendingBeforeFrame = loop.pendingWorkCount
        lan.receive(frame(source: macA, destination: macB), on: portA)
        #expect(loop.pendingWorkCount == pendingBeforeFrame + 1)
        #expect(lan.activePortCount == 2)
        #expect(lan.removePort(portB))
        #expect(loop.pendingWorkCount == pendingBeforeFrame,
                "port teardown must physically remove its delayed delivery")
        #expect(lan.activePortCount == 1)
        #expect(!lan.snapshotForwardingTable().contains { $0.mac == macB })

        loop.advance(by: 0.5)
        #expect(logB.frames.isEmpty)
        #expect(!lan.removePort(portB), "removal must be idempotent for stale handles")
    }

    @Test func removalIsOwnershipSafeAndRejectsStaleReusedPortHandles() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let stack = kernel.netns.stack
        let interface = stack.configuredInterface(
            address: IPv4Address(10, 0, 0, 1),
            mac: MACAddress("02:00:00:00:00:01")!)
        let lan = EthernetSwitch(loop: loop)
        let oldPort = lan.connect(stack, interface: interface)
        #expect(lan.ownsConnection(oldPort, interface: interface))

        let replacementLog = FrameLog()
        interface.onEgress = { replacementLog.frames.append($0) }
        #expect(!lan.ownsConnection(oldPort, interface: interface))
        #expect(lan.removePort(oldPort))

        let outbound = frame(
            source: MACAddress("02:00:00:00:00:01")!,
            destination: .broadcast)
        interface.onEgress?(outbound)
        #expect(replacementLog.frames.map(\.bytes) == [outbound.bytes],
                "stale switch teardown must preserve a newer egress owner")

        let reusedPort = lan.addPort()
        #expect(reusedPort.index == oldPort.index)
        let peer = lan.addPort()
        let peerLog = FrameLog()
        peer.onEgress = { peerLog.frames.append($0) }
        lan.receive(outbound, on: oldPort)
        loop.runUntilIdle()
        #expect(peerLog.frames.isEmpty,
                "a removed handle must not become valid when its index is reused")
        #expect(lan.snapshotForwardingTable().isEmpty)

        _ = reusedPort
        for _ in 0..<128 {
            let port = lan.addPort()
            #expect(lan.removePort(port))
        }
        #expect(lan.activePortCount == 2,
                "repeated add/remove must not accumulate active ports")
    }

    private func frame(source: MACAddress, destination: MACAddress) -> PacketBuffer {
        EthernetFrame.build(destination: destination,
                            source: source,
                            etherType: EtherType.ipv4.rawValue,
                            payload: [0x45, 0x00, 0x00, 0x00])
    }
}
