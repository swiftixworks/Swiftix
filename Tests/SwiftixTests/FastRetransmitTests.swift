import Testing
@testable import Swiftix

/// Fast retransmit + fast recovery (R4, R5, R9.2). Dropping one middle data
/// segment makes the (go-back-N) receiver emit a run of duplicate ACKs. On the
/// 3rd consecutive duplicate the sender must:
///   - retransmit the oldest unacked segment immediately, *before* the RTO timer
///     would fire (R4.1, R4.3),
///   - halve ssthresh with a 2*SMSS floor (R4.2, R9.2),
///   - enter fast recovery with cwnd = ssthresh + 3*SMSS and inflate it by one
///     SMSS per additional duplicate (R5.1, R5.2),
///   - and on the first ACK that advances the cumulative acknowledgment number,
///     deflate cwnd back to ssthresh and return to congestion avoidance (R5.3).
@Suite("Fast retransmit + fast recovery")
struct FastRetransmitTests {

    /// A single observation of the sender's congestion state in logical time.
    private struct Sample {
        let now: Double
        let cwnd: Int
        let ssthresh: Int
        let phase: TCPConnection.CongestionPhase
        let dupAckCount: Int
    }

    @Test func fastRetransmitBeatsRTOAndTransitionsMatchRenoRules() {
        let loop = EventLoop()
        // Small one-way latency: dup-ACKs return in a few ms, far below the 0.2s
        // RTO floor, so fast retransmit must clearly beat the RTO timer.
        let (stackA, stackB, ipB) = makeWiredPair(loop: loop, latency: 0.01,
                                                   dropDataIndex: 3)
        let listener = stackB.listen(port: 80)
        let client = stackA.connect(localPort: 50_100, to: ipB, remotePort: 80)

        // Complete the 3-way handshake (one clean RTT sample => RTO at the floor).
        loop.advance(by: 0.5)

        let ccEstablished = client.congestionControllerSnapshot
        let smss = ccEstablished.smss
        let ssthreshBeforeLoss = ccEstablished.ssthresh
        let rtoAfterHandshake = client.rtoEstimatorSnapshot.rto
        #expect(ccEstablished.phase == .slowStart)

        // ~6 KB => 12 SMSS-sized segments. The 4th data segment (index 3) is
        // dropped on the wire; every later segment is out-of-order at the
        // go-back-N receiver, so it emits duplicate ACKs.
        let payload: [UInt8] = (0..<6144).map { UInt8($0 & 0xFF) }
        let sendStart = loop.now
        client.send(payload)

        // Sample the sender's congestion state finely enough to catch the fast
        // recovery episode and the recovery ACK that exits it.
        var samples: [Sample] = []
        for _ in 0..<200 {
            loop.advance(by: 0.005)
            let cc = client.congestionControllerSnapshot
            samples.append(Sample(now: loop.now, cwnd: cc.cwnd, ssthresh: cc.ssthresh,
                                  phase: cc.phase, dupAckCount: cc.dupAckCount))
            if loop.now - sendStart > 1.0 { break }
        }

        // --- Fast recovery must have been entered (=> fast retransmit fired). ---
        let firstFR = samples.first { $0.phase == .fastRecovery }
        #expect(firstFR != nil)
        guard let firstFR else { return }

        // R4.1/R4.3: the fast retransmit happened well before an RTO would fire.
        // The retransmit is driven by the 3rd dup-ACK, not the timer.
        #expect(firstFR.now - sendStart < rtoAfterHandshake)

        // R4.2 + R9.2: ssthresh was reduced on loss and floored at 2*SMSS.
        #expect(firstFR.ssthresh < ssthreshBeforeLoss)
        #expect(firstFR.ssthresh >= 2 * smss)

        // R5.1 + R5.2: throughout fast recovery, cwnd == ssthresh + N*SMSS where N
        // is the current duplicate-ACK count (>= 3): the 3rd dup sets the base
        // ssthresh + 3*SMSS and every further dup inflates by one SMSS.
        let frSamples = samples.filter { $0.phase == .fastRecovery }
        #expect(!frSamples.isEmpty)
        for s in frSamples {
            #expect(s.dupAckCount >= 3)
            #expect(s.cwnd == s.ssthresh + s.dupAckCount * smss)
        }

        // R5.3: the first ACK that advances the cumulative acknowledgment number
        // exits fast recovery, deflating cwnd to ssthresh and entering congestion
        // avoidance.
        if let frIndex = samples.firstIndex(where: { $0.phase == .fastRecovery }) {
            let exit = samples[frIndex...].first { $0.phase != .fastRecovery }
            #expect(exit != nil)
            if let exit {
                #expect(exit.phase == .congestionAvoidance)
                #expect(exit.cwnd == exit.ssthresh)
            }
        }

        // The oldest unacked segment (the dropped one, bytes 1536..2047) was
        // retransmitted and delivered: after recovery the receiver has the whole
        // in-order prefix through at least the dropped segment. This confirms the
        // retransmit actually filled the gap (R4.1) rather than stalling for RTO.
        loop.advance(by: 1.0)
        let server = listener.dequeue()
        #expect(server != nil)
        let delivered = server?.read(max: 1 << 20) ?? []
        #expect(delivered.count >= 2048)                          // past the dropped segment
        #expect(Array(payload.prefix(delivered.count)) == delivered)   // in-order, uncorrupted
    }

    // MARK: - Helpers

    private func makeWiredPair(loop: EventLoop, latency: Double, dropDataIndex: Int)
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
        // Drop exactly the 4th data-bearing A->B segment (a middle segment). Its
        // retransmits get higher data-segment indices and are not dropped.
        TestWire.connect(stackA, ifA, stackB, ifB, on: loop, latency: latency,
                        dropData: { index, _ in index == dropDataIndex })
        stackA.configuredNeighbor(ip: ipB, mac: macB)
        stackB.configuredNeighbor(ip: ipA, mac: macA)
        return (stackA, stackB, ipB)
    }
}
