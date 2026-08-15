import Testing
@testable import Swiftix

@Suite("Socket bridge (kernel <-> network stack)")
struct SocketBridgeTests {

    /// A process on instance A sends a UDP datagram that crosses the (test-wired)
    /// link into the bound socket on instance B.
    @Test func udpDatagramReachesBoundSocketOnPeer() {
        let loop = EventLoop()
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)

        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB, on: loop, latency: 0.005)
        kernelA.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        kernelB.netns.stack.configuredNeighbor(ip: ipA, mac: macA)

        let server = kernelB.netns.stack.openUDPSocket()
        server.bind(address: ipB, port: 7000)

        kernelA.spawn("udp-client") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.sendto(fd, Array("hello-udp".utf8), to: ipB, port: 7000)
        }
        loop.advance(by: 0.05)

        let received = server.receive()
        #expect(received != nil)
        if let received {
            #expect(String(decoding: received.payload, as: UTF8.self) == "hello-udp")
            #expect(received.sourceAddress == ipA)
        }
    }

    /// IPv4 + UDP build and parse are inverses (offsets and lengths line up).
    @Test func ipv4AndUDPRoundTrip() {
        let payload: [UInt8] = [1, 2, 3, 4, 5]
        let udp = UDPDatagram.build(sourcePort: 1111, destinationPort: 2222, payload: payload)
        let ip = IPv4Packet.build(source: IPv4Address(192, 168, 0, 1),
                                destination: IPv4Address(192, 168, 0, 2),
                                proto: IPProtocol.udp.rawValue,
                                payload: udp)

        guard let (ipHeader, ipPayload) = IPv4Packet.parse(ip[...]) else {
            Issue.record("IPv4 parse failed")
            return
        }
        #expect(ipHeader.proto == IPProtocol.udp.rawValue)
        #expect(ipHeader.destination == IPv4Address(192, 168, 0, 2))

        guard let (udpHeader, udpPayload) = UDPDatagram.parse(ipPayload) else {
            Issue.record("UDP parse failed")
            return
        }
        #expect(udpHeader.sourcePort == 1111)
        #expect(udpHeader.destinationPort == 2222)
        #expect(Array(udpPayload) == payload)
    }
}
