import Testing
@testable import Swiftix

@Suite("Blocking I/O — UDP echo server")
struct BlockingIOTests {

    /// A server process binds a UDP socket and blocks in a recv loop; a client
    /// process sends a datagram and blocks for the reply. Both park on `recvfrom`
    /// and are rescheduled when their datagram arrives.
    @Test func echoServerRepliesToBlockingClient() {
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

        kernelB.spawn("udp-echo") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: ipB, port: 7000)
            func serve() {
                ctx.recvfrom(fd) { bytes, address, port in
                    ctx.sendto(fd, bytes, to: address, port: port)   // echo back
                    serve()                                          // wait for the next one
                }
            }
            serve()
        }

        final class Capture {
            var reply: [UInt8] = []
            var replied = false
        }
        let captured = Capture()
        kernelA.spawn("udp-client") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: ipA, port: 5000)
            ctx.sendto(fd, Array("ping".utf8), to: ipB, port: 7000)
            ctx.recvfrom(fd) { bytes, _, _ in
                captured.reply = bytes
                captured.replied = true
            }
        }

        loop.advance(by: 0.1)

        #expect(captured.replied)
        #expect(String(decoding: captured.reply, as: UTF8.self) == "ping")
        #expect(kernelA.processCount == 0)   // client finished and was reaped
        #expect(kernelB.processCount == 1)   // server still parked (alive)
    }
}
