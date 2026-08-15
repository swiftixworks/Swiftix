import Testing
@testable import Swiftix

/// RTO loss response (R3, R6.6, R9.2): when the retransmission timer expires with
/// unacknowledged data outstanding and no duplicate-ACK opportunity, the sender
/// must collapse the congestion window (cwnd = SMSS), halve ssthresh with a floor
/// of 2*SMSS, re-enter slow start, and back off the RTO. A second consecutive
/// timeout must double the RTO again.
@Suite("RTO loss response")
struct RTOLossResponseTests {

    /// Drop the first two data-bearing A→B segments (the original and its first
    /// retransmit) so two consecutive RTOs fire. The receiver never sees the data,
    /// so it emits no duplicate ACKs — this is a pure timeout scenario.
    @Test func rtoCollapsesWindowAndBacksOff() {
        let loop = EventLoop()
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)

        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: macB)
        // Drop the original data segment (index 0) and its first retransmit
        // (index 1); the second retransmit (index 2) gets through.
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB,
                        on: loop, latency: 0.005,
                        dropData: { index, _ in index <= 1 })
        kernelA.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        kernelB.netns.stack.configuredNeighbor(ip: ipA, mac: macA)

        final class Capture { var serverGot: [UInt8] = [] }
        let captured = Capture()

        kernelB.spawn("tcp-server") { ctx in
            guard let listenFD = ctx.tcpSocket() else { return }
            ctx.tcpListen(listenFD, port: 80)
            ctx.tcpAccept(listenFD) { acceptedFD in
                ctx.tcpRecv(acceptedFD) { bytes in
                    captured.serverGot = bytes
                }
            }
        }
        kernelA.spawn("tcp-client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: ipB, port: 80) {
                ctx.tcpSend(fd, Array("hello".utf8))   // 5 bytes => FlightSize == 5
            }
        }

        // Complete the handshake and issue the (doomed) first data segment. The
        // handshake yields an RTT sample, so the initial RTO is the 0.2s floor.
        loop.advance(by: 0.05)

        let conn = kernelA.netns.stack.tcpConnectionList.first
        #expect(conn != nil)
        guard let conn else { return }

        // Baseline: established, slow start, initial window, no loss yet.
        let ccBefore = conn.congestionControllerSnapshot
        #expect(ccBefore.phase == .slowStart)
        #expect(ccBefore.cwnd == ccBefore.initialWindow)
        let rtoAfterHandshake = conn.rtoEstimatorSnapshot.rto
        let smss = ccBefore.smss

        // Advance past the first RTO (armed ~0.21s at rto=0.2).
        loop.advance(by: 0.25)   // now ~0.30s: first timeout has fired

        let ccAfterFirst = conn.congestionControllerSnapshot
        // R3.2: cwnd collapses to one SMSS.
        #expect(ccAfterFirst.cwnd == smss)
        // R3.4: re-enter slow start.
        #expect(ccAfterFirst.phase == .slowStart)
        // R3.1 + R9.2: ssthresh = max(FlightSize/2, 2*SMSS); FlightSize is 5 here,
        // so the 2*SMSS floor applies.
        #expect(ccAfterFirst.ssthresh == max(5 / 2, 2 * smss))
        #expect(ccAfterFirst.ssthresh >= 2 * smss)
        // R6.6: RTO doubled on the first timeout.
        let rtoAfterFirst = conn.rtoEstimatorSnapshot.rto
        #expect(rtoAfterFirst == rtoAfterHandshake * 2)

        // Advance past the second consecutive RTO (armed ~0.61s at rto=0.4).
        loop.advance(by: 0.40)   // now ~0.70s: second timeout has fired

        // R6.6: a second consecutive timeout doubles the RTO again.
        let rtoAfterSecond = conn.rtoEstimatorSnapshot.rto
        #expect(rtoAfterSecond == rtoAfterFirst * 2)

        // Sanity: the third transmission gets through and the data is delivered.
        loop.advance(by: 2.0)
        #expect(String(decoding: captured.serverGot, as: UTF8.self) == "hello")
    }
}
