import Testing
@testable import Swiftix

@Suite("IPv4 router mode")
struct RouterModeTests {

    private struct Topology {
        let loop: EventLoop
        let hostA: Kernel
        let router: Kernel
        let hostB: Kernel
        let ipA: IPv4Address
        let ipR0: IPv4Address
        let ipR1: IPv4Address
        let ipB: IPv4Address
        let ifA: NetworkStack.Interface
        let ifR0: NetworkStack.Interface
        let ifR1: NetworkStack.Interface
        let ifB: NetworkStack.Interface
    }

    @Test func forwardingEnabledRoutesIPv4BetweenTwoSubnetsAndDecrementsTTL() {
        let topology = makeTopology()
        final class Capture {
            var routerEvents: [PacketPathEvent] = []
            var framesFromRouterToB: [PacketBuffer] = []
        }
        let capture = Capture()

        topology.router.netns.stack.onPacketPathEvent = { capture.routerEvents.append($0) }
        connect(topology.router.netns.stack, topology.ifR1,
                topology.hostB.netns.stack, topology.ifB,
                on: topology.loop,
                captureAtoB: { capture.framesFromRouterToB.append($0) })

        let server = topology.hostB.netns.stack.openUDPSocket()
        server.bind(address: topology.ipB, port: 7000)

        #expect(topology.hostA.netns.stack.sendUDP(sourcePort: 5000,
                                                  destinationAddress: topology.ipB,
                                                  destinationPort: 7000,
                                                  payload: Array("cross-subnet".utf8)))
        topology.loop.advance(by: 0.1)

        let received = server.receive()
        #expect(String(decoding: received?.payload ?? [], as: UTF8.self) == "cross-subnet")
        #expect(received?.sourceAddress == topology.ipA)

        let forwarded = capture.framesFromRouterToB.compactMap(ipv4Frame).first {
            $0.header.source == topology.ipA && $0.header.destination == topology.ipB
        }
        #expect(forwarded?.header.ttl == 63)
        #expect(capture.routerEvents.contains { event in
            event.stage == .forward
                && event.direction == .outbound
                && event.interfaceName == "eth1"
                && event.routeDecision?.destination == topology.ipB
                && event.routeDecision?.nextHop == topology.ipB
        })
    }

    @Test func ttlExpiredForwardingDropsPacketAndReturnsICMPTimeExceeded() {
        let topology = makeTopology(connectRouterToB: false)
        final class Capture {
            var routerEvents: [PacketPathEvent] = []
            var framesFromRouterToA: [PacketBuffer] = []
        }
        let capture = Capture()

        topology.router.netns.stack.onPacketPathEvent = { capture.routerEvents.append($0) }
        topology.ifR0.onEgress = { capture.framesFromRouterToA.append($0) }

        let udp = UDPDatagram.build(sourcePort: 5000,
                                    destinationPort: 7000,
                                    payload: Array("ttl".utf8))
        let packet = IPv4Packet.build(source: topology.ipA,
                                      destination: topology.ipB,
                                      proto: IPProtocol.udp.rawValue,
                                      ttl: 1,
                                      payload: udp)
        let frame = EthernetFrame.build(destination: topology.ifR0.mac,
                                        source: topology.ifA.mac,
                                        etherType: EtherType.ipv4.rawValue,
                                        payload: packet)

        topology.router.netns.stack.receive(frame, on: topology.ifR0)
        topology.loop.runUntilIdle()

        #expect(topology.ifR0.counters.drops == 1)
        #expect(capture.routerEvents.contains { event in
            event.stage == .forward
                && event.dropReason == .ttlExpired
                && event.ipProtocol == IPProtocol.udp.rawValue
        })

        let icmp = capture.framesFromRouterToA.compactMap(ipv4Frame).first {
            $0.header.source == topology.ipR0
                && $0.header.destination == topology.ipA
                && $0.header.proto == IPProtocol.icmp.rawValue
        }
        #expect(icmp != nil)
        if let icmp {
            let bytes = Array(icmp.payload)
            #expect(bytes.first == ICMPMessage.MessageType.timeExceeded.rawValue)
            #expect(bytes.dropFirst().first == 0)
            #expect(TransportChecksum.verifyICMP(bytes))
        }
    }

    @Test func missingForwardingRouteDropsPacketAndReturnsICMPUnreachable() {
        let topology = makeTopology(connectRouterToB: false)
        final class Capture {
            var routerEvents: [PacketPathEvent] = []
            var framesFromRouterToA: [PacketBuffer] = []
        }
        let capture = Capture()

        topology.router.netns.stack.onPacketPathEvent = { capture.routerEvents.append($0) }
        topology.ifR0.onEgress = { capture.framesFromRouterToA.append($0) }

        let destinationWithoutRoute = IPv4Address(172, 16, 0, 10)
        let udp = UDPDatagram.build(sourcePort: 5000,
                                    destinationPort: 7000,
                                    payload: Array("noroute".utf8))
        let packet = IPv4Packet.build(source: topology.ipA,
                                      destination: destinationWithoutRoute,
                                      proto: IPProtocol.udp.rawValue,
                                      ttl: 64,
                                      payload: udp)
        let frame = EthernetFrame.build(destination: topology.ifR0.mac,
                                        source: topology.ifA.mac,
                                        etherType: EtherType.ipv4.rawValue,
                                        payload: packet)

        topology.router.netns.stack.receive(frame, on: topology.ifR0)
        topology.loop.runUntilIdle()

        #expect(topology.ifR0.counters.drops == 1)
        #expect(capture.routerEvents.contains { event in
            event.stage == .route
                && event.dropReason == .noRoute
                && event.ipProtocol == IPProtocol.udp.rawValue
        })

        let icmp = capture.framesFromRouterToA.compactMap(ipv4Frame).first {
            $0.header.source == topology.ipR0
                && $0.header.destination == topology.ipA
                && $0.header.proto == IPProtocol.icmp.rawValue
        }
        #expect(icmp != nil)
        if let icmp {
            let bytes = Array(icmp.payload)
            #expect(bytes.first == ICMPMessage.MessageType.destinationUnreachable.rawValue)
            #expect(bytes.dropFirst().first == 0)
            #expect(TransportChecksum.verifyICMP(bytes))
        }
    }

    private func makeTopology(connectRouterToB: Bool = true) -> Topology {
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

        hostA.netns.stack.configuredRoute(destination: IPv4Address(0, 0, 0, 0),
                                   prefixLength: 0,
                                   gateway: ipR0,
                                   interfaceIndex: 0)
        hostB.netns.stack.configuredRoute(destination: IPv4Address(0, 0, 0, 0),
                                   prefixLength: 0,
                                   gateway: ipR1,
                                   interfaceIndex: 0)
        router.netns.stack.configure(.setIPForwarding(true))

        hostA.netns.stack.configuredNeighbor(ip: ipR0, mac: ifR0.mac)
        hostB.netns.stack.configuredNeighbor(ip: ipR1, mac: ifR1.mac)
        router.netns.stack.configuredNeighbor(ip: ipA, mac: ifA.mac)
        router.netns.stack.configuredNeighbor(ip: ipB, mac: ifB.mac)

        connect(hostA.netns.stack, ifA, router.netns.stack, ifR0, on: loop)
        if connectRouterToB {
            connect(router.netns.stack, ifR1, hostB.netns.stack, ifB, on: loop)
        }

        return Topology(loop: loop,
                        hostA: hostA,
                        router: router,
                        hostB: hostB,
                        ipA: ipA,
                        ipR0: ipR0,
                        ipR1: ipR1,
                        ipB: ipB,
                        ifA: ifA,
                        ifR0: ifR0,
                        ifR1: ifR1,
                        ifB: ifB)
    }

    private func connect(_ stackA: NetworkStack,
                         _ ifA: NetworkStack.Interface,
                         _ stackB: NetworkStack,
                         _ ifB: NetworkStack.Interface,
                         on loop: EventLoop,
                         captureAtoB: ((PacketBuffer) -> Void)? = nil,
                         captureBtoA: ((PacketBuffer) -> Void)? = nil) {
        ifA.onEgress = { [weak stackB, weak ifB] frame in
            captureAtoB?(frame)
            guard let stackB, let ifB else { return }
            loop.schedule(after: 0.005) { stackB.receive(frame, on: ifB) }
        }
        ifB.onEgress = { [weak stackA, weak ifA] frame in
            captureBtoA?(frame)
            guard let stackA, let ifA else { return }
            loop.schedule(after: 0.005) { stackA.receive(frame, on: ifA) }
        }
    }

    private func ipv4Frame(_ frame: PacketBuffer) -> (header: IPv4Packet.Header, payload: ArraySlice<UInt8>)? {
        guard let eth = EthernetFrame.parseHeader(frame),
              eth.etherType == EtherType.ipv4.rawValue else { return nil }
        return IPv4Packet.parse(EthernetFrame.payload(frame))
    }
}
