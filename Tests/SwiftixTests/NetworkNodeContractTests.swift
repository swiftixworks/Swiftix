import Testing
@testable import Swiftix

@Suite("Network node contract and packet path")
struct NetworkNodeContractTests {

    @Test func stackCanBeDrivenThroughNetworkNodeBoundary() {
        let loop = EventLoop()
        let stack = NetworkStack(loop: loop)
        let node: any NetworkNode = stack

        node.configure(.addInterface(NetworkInterfaceConfiguration(address: IPv4Address(10, 0, 0, 1),
                                                                   mac: MACAddress("02:00:00:00:00:01")!,
                                                                   prefixLength: 24)))
        node.configure(.addRoute(NetworkRouteConfiguration(destination: IPv4Address(0, 0, 0, 0),
                                                           prefixLength: 0,
                                                           gateway: IPv4Address(10, 0, 0, 254),
                                                           interfaceIndex: 0)))
        node.configure(.addNeighbor(NetworkNeighborConfiguration(ip: IPv4Address(10, 0, 0, 254),
                                                                 mac: MACAddress("02:00:00:00:00:fe")!)))
        let interface = node.interface(at: 0)!

        final class Capture {
            var frames: [PacketBuffer] = []
            var events: [PacketPathEvent] = []
        }
        let capture = Capture()
        interface.onEgress = { capture.frames.append($0) }
        node.onPacketPathEvent = { capture.events.append($0) }

        #expect(node.snapshotRoutes().contains { route in
            route.network == IPv4Address(0, 0, 0, 0)
                && route.prefixLength == 0
                && route.gateway == IPv4Address(10, 0, 0, 254)
                && route.interface == "eth0"
        })

        #expect(stack.sendUDP(sourcePort: 1000,
                              destinationAddress: IPv4Address(8, 8, 8, 8),
                              destinationPort: 53,
                              payload: [1, 2, 3]))
        loop.runUntilIdle()

        #expect(capture.frames.count == 1)
        let routeEvent = capture.events.first { $0.stage == .route }
        #expect(routeEvent?.routeDecision?.destination == IPv4Address(8, 8, 8, 8))
        #expect(routeEvent?.routeDecision?.nextHop == IPv4Address(10, 0, 0, 254))
        #expect(routeEvent?.routeDecision?.interfaceName == "eth0")
        #expect(routeEvent?.routeDecision?.gateway == IPv4Address(10, 0, 0, 254))
        #expect(capture.events.contains { $0.stage == .egress && $0.direction == .outbound })
    }

    @Test func malformedInboundFrameEmitsDropReasonAndIncrementsDropCounter() {
        let stack = NetworkStack(loop: EventLoop())
        let node: any NetworkNode = stack
        node.configure(.addInterface(NetworkInterfaceConfiguration(address: IPv4Address(10, 0, 0, 1),
                                                                   mac: MACAddress("02:00:00:00:00:01")!,
                                                                   prefixLength: 24)))
        let interface = node.interface(at: 0)!

        final class Capture { var events: [PacketPathEvent] = [] }
        let capture = Capture()
        node.onPacketPathEvent = { capture.events.append($0) }

        node.receive(PacketBuffer([0x00, 0x01, 0x02]), on: interface)

        #expect(node.snapshotInterfaceCounters().first?.counters.drops == 1)
        #expect(capture.events.contains { event in
            event.stage == .layer2
                && event.direction == .inbound
                && event.interfaceName == "eth0"
                && event.dropReason == .malformedEthernet
        })
    }

    @Test func hostDropsIPv4NotAddressedToItWhenForwardingIsDisabled() {
        let stack = NetworkStack(loop: EventLoop())
        stack.configure(.addInterface(NetworkInterfaceConfiguration(
            address: IPv4Address(10, 0, 0, 1),
            mac: MACAddress("02:00:00:00:00:01")!)))
        let interface = stack.interface(at: 0)!
        final class Capture { var events: [PacketPathEvent] = [] }
        let capture = Capture()
        stack.onPacketPathEvent = { capture.events.append($0) }

        let packet = IPv4Packet.build(source: IPv4Address(10, 0, 0, 2),
                                      destination: IPv4Address(10, 0, 0, 99),
                                      proto: IPProtocol.udp.rawValue,
                                      ttl: 64,
                                      payload: UDPDatagram.build(sourcePort: 1,
                                                                 destinationPort: 2,
                                                                 payload: [1]))
        let frame = EthernetFrame.build(destination: interface.mac,
                                        source: MACAddress("02:00:00:00:00:02")!,
                                        etherType: EtherType.ipv4.rawValue,
                                        payload: packet)
        stack.receive(frame, on: interface)

        #expect(interface.counters.drops == 1)
        #expect(capture.events.contains { $0.dropReason == .notLocalDestination })
    }

    @Test func interfaceRejectsUnicastFrameForAnotherMAC() {
        let stack = NetworkStack(loop: EventLoop())
        stack.configure(.addInterface(NetworkInterfaceConfiguration(
            address: IPv4Address(10, 0, 0, 1),
            mac: MACAddress("02:00:00:00:00:01")!)))
        let interface = stack.interface(at: 0)!
        let frame = EthernetFrame.build(destination: MACAddress("02:00:00:00:00:99")!,
                                        source: MACAddress("02:00:00:00:00:02")!,
                                        etherType: EtherType.ipv4.rawValue,
                                        payload: [])

        stack.receive(frame, on: interface)

        #expect(interface.counters.drops == 1)
        #expect(interface.counters.dropsByReason[PacketDropReason.wrongDestinationMAC.rawValue] == 1)
    }
}
