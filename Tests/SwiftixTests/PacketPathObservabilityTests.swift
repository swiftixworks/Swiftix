import Testing
@testable import Swiftix

@Suite("Packet path procfs and commands")
struct PacketPathObservabilityTests {

    @Test func packetPathHistoryRetainsNewestEntriesInSequenceOrder() {
        let loop = EventLoop()
        let stack = Kernel(loop: loop).netns.stack
        stack.configure(NetworkConfiguration(
            interfaces: [NetworkInterfaceConfiguration(
                address: IPv4Address(10, 0, 0, 1),
                mac: MACAddress("02:00:00:00:00:01")!)],
            neighbors: [NetworkNeighborConfiguration(
                ip: IPv4Address(10, 0, 0, 2),
                mac: MACAddress("02:00:00:00:00:02")!)]))

        for _ in 0..<200 {
            #expect(stack.sendUDP(sourcePort: 1,
                                  destinationAddress: IPv4Address(10, 0, 0, 2),
                                  destinationPort: 2,
                                  payload: [1]))
        }
        let events = stack.snapshotPacketPathEvents()
        #expect(events.count == 256)
        #expect(zip(events, events.dropFirst()).allSatisfy { left, right in
            right.sequence == left.sequence + 1
        })
        #expect(events.last?.sequence == 399)
    }

    @Test func procNetTraceListsRecentRouteAndEgressEvents() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let stack = kernel.netns.stack
        stack.configuredInterface(address: IPv4Address(10, 0, 0, 1),
                              mac: MACAddress("02:00:00:00:00:01")!)
        stack.configuredNeighbor(ip: IPv4Address(10, 0, 0, 2),
                          mac: MACAddress("02:00:00:00:00:02")!)

        #expect(stack.sendUDP(sourcePort: 1234,
                              destinationAddress: IPv4Address(10, 0, 0, 2),
                              destinationPort: 5678,
                              payload: [1, 2, 3]))

        let text = readProcFile("/proc/net/trace", kernel, loop: loop)
        #expect(text.contains("outbound eth0 route"))
        #expect(text.contains("proto=udp"))
        #expect(text.contains("route=10.0.0.2"))
        #expect(text.contains("via=10.0.0.2"))
        #expect(text.contains("network=10.0.0.0/24"))
        #expect(text.contains("outbound eth0 egress"))
        #expect(text.contains("ether=ipv4"))
    }

    @Test func procNetDropListsOnlyDropEvents() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let interface = kernel.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 1),
                                                           mac: MACAddress("02:00:00:00:00:01")!)

        kernel.netns.stack.receive(PacketBuffer([0x00, 0x01, 0x02]), on: interface)

        let trace = readProcFile("/proc/net/trace", kernel, loop: loop)
        let drops = readProcFile("/proc/net/drop", kernel, loop: loop)

        #expect(trace.contains("inbound eth0 ingress"))
        #expect(drops.contains("inbound eth0 layer2"))
        #expect(drops.contains("drop=malformedEthernet"))
        #expect(!drops.contains(" ingress "))
    }

    @Test func traceCommandReadsPacketPathProcFile() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let stack = kernel.netns.stack
        stack.configuredInterface(address: IPv4Address(10, 0, 0, 1),
                              mac: MACAddress("02:00:00:00:00:01")!)
        stack.configuredNeighbor(ip: IPv4Address(10, 0, 0, 2),
                          mac: MACAddress("02:00:00:00:00:02")!)
        _ = stack.sendUDP(sourcePort: 1234,
                          destinationAddress: IPv4Address(10, 0, 0, 2),
                          destinationPort: 5678,
                          payload: [1, 2, 3])

        let pty = PseudoTerminal()
        let captured = capture(pty)
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("trace\n".utf8))
        loop.runUntilIdle()

        let output = String(decoding: captured.out, as: UTF8.self)
        #expect(output.contains("seq direction interface stage details"))
        #expect(output.contains("outbound eth0 route"))
        #expect(output.contains("route=10.0.0.2"))
    }

    private final class Capture {
        var out: [UInt8] = []
    }

    private func capture(_ pty: PseudoTerminal) -> Capture {
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        return captured
    }

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
}
