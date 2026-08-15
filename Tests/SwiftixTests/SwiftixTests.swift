import Testing
@testable import Swiftix

@Suite("Network interface seam")
struct InterfaceSeamTests {

    @Test func versionIsSet() {
        #expect(Swiftix.version == "0.10.0")
    }

    /// A UDP send from a socket is emitted as a frame through the interface's
    /// `onEgress` hook — the library's outbound boundary, with no link/topology.
    @Test func socketSendEmitsFrameOnEgress() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let mac = MACAddress("02:00:00:00:00:01")!
        let peerMAC = MACAddress("02:00:00:00:00:02")!
        let ip = IPv4Address(10, 0, 0, 1)
        let peer = IPv4Address(10, 0, 0, 2)
        let iface = kernel.netns.stack.configuredInterface(address: ip, mac: mac)
        kernel.netns.stack.configuredNeighbor(ip: peer, mac: peerMAC)   // skip ARP

        final class Capture { var frames: [PacketBuffer] = [] }
        let captured = Capture()
        iface.onEgress = { captured.frames.append($0) }

        kernel.spawn("sender") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: ip, port: 5000)
            ctx.sendto(fd, Array("hi".utf8), to: peer, port: 7000)
        }
        loop.runUntilIdle()

        #expect(captured.frames.count == 1)
        guard let frame = captured.frames.first,
              let eth = EthernetFrame.parseHeader(frame),
              let (ipHeader, ipPayload) = IPv4Packet.parse(EthernetFrame.payload(frame)),
              let (udpHeader, udpPayload) = UDPDatagram.parse(ipPayload) else {
            Issue.record("egress frame did not parse")
            return
        }
        #expect(eth.destination == peerMAC)
        #expect(ipHeader.destination == peer)
        #expect(udpHeader.destinationPort == 7000)
        #expect(Array(udpPayload) == Array("hi".utf8))
    }
}
