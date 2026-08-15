import Testing
@testable import Swiftix

@Suite("Routing (longest-prefix match)")
struct RoutingTests {

    /// An in-subnet destination uses the connected route (frame addressed to the
    /// host's MAC); an off-subnet destination uses the default route (frame
    /// addressed to the gateway's MAC).
    @Test func connectedVersusDefaultRoute() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let macSelf = MACAddress("02:00:00:00:00:01")!
        let interface = kernel.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 1), mac: macSelf)  // 10.0.0.0/24 connected
        kernel.netns.stack.configuredRoute(destination: IPv4Address(0, 0, 0, 0), prefixLength: 0,
                                    gateway: IPv4Address(10, 0, 0, 254), interfaceIndex: 0)

        let macHost = MACAddress("02:00:00:00:00:02")!
        let macGateway = MACAddress("02:00:00:00:00:fe")!
        kernel.netns.stack.configuredNeighbor(ip: IPv4Address(10, 0, 0, 2), mac: macHost)
        kernel.netns.stack.configuredNeighbor(ip: IPv4Address(10, 0, 0, 254), mac: macGateway)

        final class Capture { var frames: [PacketBuffer] = [] }
        let captured = Capture()
        interface.onEgress = { captured.frames.append($0) }

        kernel.netns.stack.sendUDP(sourcePort: 1, destinationAddress: IPv4Address(10, 0, 0, 2), destinationPort: 2, payload: [1])  // in-subnet
        kernel.netns.stack.sendUDP(sourcePort: 1, destinationAddress: IPv4Address(8, 8, 8, 8), destinationPort: 2, payload: [2])  // off-subnet
        loop.runUntilIdle()

        #expect(captured.frames.count == 2)
        #expect(EthernetFrame.parseHeader(captured.frames[0])?.destination == macHost)      // connected -> host
        #expect(EthernetFrame.parseHeader(captured.frames[1])?.destination == macGateway)   // default -> gateway
    }

    @Test func offSubnetSendRequiresExplicitRoute() {
        let stack = NetworkStack(loop: EventLoop())
        let interface = stack.configuredInterface(address: IPv4Address(10, 0, 0, 1),
                                                  mac: MACAddress("02:00:00:00:00:01")!)
        final class Capture { var frames: [PacketBuffer] = [] }
        let capture = Capture()
        interface.onEgress = { capture.frames.append($0) }

        let sent = stack.sendUDP(sourcePort: 1,
                                 destinationAddress: IPv4Address(8, 8, 8, 8),
                                 destinationPort: 53,
                                 payload: [1])

        #expect(!sent)
        #expect(capture.frames.isEmpty)
    }
}
