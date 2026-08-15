import Testing
@testable import Swiftix

/// Tests that RTT sampling and the RFC 6298 adaptive RTO are wired into the live
/// ACK/timer path of a `TCPConnection` (task 4). These drive two real stacks over
/// a `TestWire` with a known one-way latency and read the sender's estimator via
/// the internal `rtoEstimatorSnapshot`.
@Suite("Adaptive RTO wiring (RFC 6298 + Karn)")
struct AdaptiveRTOTests {

    /// R6.3, R6.6: over a wire with a large-enough latency, the sender's RTO is
    /// computed from measured RTT (`rto == clamp(srtt + 4*rttvar)`) and is clearly
    /// different from the old fixed 0.2s value.
    @Test func adaptiveRTOFromWireLatency() {
        let loop = EventLoop()
        // One-way 0.15s => RTT ~= 0.30s, so srtt + 4*rttvar stays well above the
        // 0.2s floor and is never clamped (clearly different from the old 0.2s).
        let latency = 0.15
        let (stackA, stackB, ipB) = makeWiredPair(loop: loop, latency: latency)

        _ = stackB.listen(port: 80)
        let client = stackA.connect(localPort: 50_000, to: ipB, remotePort: 80)

        loop.advance(by: 1.0)   // 3-way handshake: one clean RTT sample from the SYN

        // A few more round trips of data so the estimator smooths toward the RTT.
        for _ in 0..<5 {
            client.send(Array("ping".utf8))
            loop.advance(by: 1.0)
        }

        let est = client.rtoEstimatorSnapshot
        #expect(est.hasSample)
        // RTO is exactly the RFC 6298 formula (unclamped at this latency).
        #expect(abs(est.rto - (est.srtt + 4 * est.rttvar)) < 1e-9)
        // SRTT tracks the measured round trip (~2 * latency).
        #expect(abs(est.srtt - (2 * latency)) < 0.05)
        // Clearly different from the old fixed 0.2s RTO.
        #expect(est.rto > 0.25)
    }

    /// R6.7 (Karn's algorithm): when the only ACK arrives for a segment that had to
    /// be retransmitted, that ambiguous ACK must NOT update SRTT. The estimator's
    /// SRTT stays exactly at the value measured from the (clean) handshake sample.
    @Test func karnRetransmittedAckDoesNotSampleRTT() {
        let loop = EventLoop()
        let latency = 0.01
        // Drop the first data-bearing segment so the client must retransmit it;
        // the resulting ACK is ambiguous (Karn) and must not be sampled.
        let (stackA, stackB, ipB) = makeWiredPair(loop: loop, latency: latency,
                                                  dropFirstData: true)

        let listener = stackB.listen(port: 80)
        let client = stackA.connect(localPort: 50_001, to: ipB, remotePort: 80)

        loop.advance(by: 1.0)   // handshake completes: one clean SYN RTT sample
        let afterHandshake = client.rtoEstimatorSnapshot
        #expect(afterHandshake.hasSample)
        let srttAfterHandshake = afterHandshake.srtt

        client.send(Array("karn".utf8))   // first data segment is dropped on the wire
        loop.advance(by: 3.0)             // RTO fires, retransmits; ambiguous ACK returns

        let est = client.rtoEstimatorSnapshot
        // The ambiguous (retransmitted) ACK left SRTT untouched.
        #expect(est.srtt == srttAfterHandshake)

        // Sanity: the retransmission actually delivered the data end-to-end.
        let server = listener.dequeue()
        #expect(server != nil)
        #expect(String(decoding: server!.read(max: 64), as: UTF8.self) == "karn")
    }

    // MARK: - Helpers

    /// Wire two bare `NetworkStack`s together over a `TestWire` with the given
    /// one-way latency, returning (clientStack, serverStack, serverIP).
    private func makeWiredPair(loop: EventLoop, latency: Double,
                               dropFirstData: Bool = false)
        -> (NetworkStack, NetworkStack, IPv4Address) {
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)

        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let stackA = kernelA.netns.stack
        let stackB = kernelB.netns.stack
        let ifA = stackA.configuredInterface(address: ipA, mac: macA)
        let ifB = stackB.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(stackA, ifA, stackB, ifB, on: loop, latency: latency,
                        dropFirstTCPData: dropFirstData)
        stackA.configuredNeighbor(ip: ipB, mac: macB)
        stackB.configuredNeighbor(ip: ipA, mac: macA)
        return (stackA, stackB, ipB)
    }
}
