import Testing
@testable import Swiftix

@Suite("TCP close")
struct CloseTests {

    /// Client active-closes right after connecting; the server passive-closes on
    /// EOF. The full FIN handshake runs and both connections reach CLOSED and are
    /// removed from their stacks (after TIME_WAIT).
    @Test func orderlyCloseRemovesBothConnections() {
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

        kernelB.spawn("server") { ctx in
            guard let listenFD = ctx.tcpSocket() else { return }
            ctx.tcpListen(listenFD, port: 80)
            ctx.tcpAccept(listenFD) { acceptedFD in
                func recvLoop() {
                    ctx.tcpRecv(acceptedFD) { bytes in
                        if bytes.isEmpty {
                            ctx.tcpClose(acceptedFD)   // EOF -> close our side
                        } else {
                            recvLoop()
                        }
                    }
                }
                recvLoop()
            }
        }
        kernelA.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: ipB, port: 80) {
                ctx.tcpClose(fd)                       // active close immediately after connect
            }
        }

        loop.advance(by: 1.0)   // > TIME_WAIT (0.1s)

        #expect(kernelA.netns.stack.snapshotTCP().isEmpty)
        #expect(kernelB.netns.stack.snapshotTCP().isEmpty)
    }
}
