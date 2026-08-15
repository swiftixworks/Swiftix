import Testing
@testable import Swiftix

/// Property-style (seeded, deterministic) verification of the congestion-control
/// invariants (task 10). For each of a fixed set of seeds we build a `TestWire`
/// with seeded pseudo-random A→B data-segment loss and a random multi-KB payload,
/// run the connection to quiescence on the logical-time `EventLoop`, and assert
/// the correctness properties P1–P7 from the design document.
///
/// Every run is fully deterministic given its seed (payload + drop schedule come
/// from `SplitMix64`), so any failure reproduces exactly: the seed is included in
/// every failing expectation's message.
///
/// Properties (design "Correctness Properties"):
///   P1 reliable in-order delivery      — delivered stream == sent stream (R8.1)
///   P2 exactly-once delivery           — no byte delivered twice (R8.3)
///   P3 forward progress / quiescence   — sndUna == sndNxt, buffers drain, loop
///                                        drains within a bounded number of RTOs (R8.2, R8.4)
///   P4 cwnd lower bound                — cwnd >= SMSS at every observation (R9.1)
///   P5 flight window-gated            — new data never grows FlightSize past min(cwnd, rwnd);
///                                        a transient excess after a cwnd reduction that only
///                                        decreases is allowed (R9.3, R1.3)
///   P6 ssthresh loss floor             — after loss, ssthresh >= 2*SMSS (R9.2)
///   P7 no retransmit storm             — <= one RTO-timer retransmit per RTO interval (R9.4)
@Suite("Congestion control invariants (seeded property-style)")
struct CongestionControlTests {

    /// Deterministic seeds. Each produces a fully reproducible run.
    private static let seeds: [UInt64] = Array(1...30).map { UInt64($0) &* 0x9E37_79B9 &+ 1 }

    // Bounds for the run-to-quiescence loop (all logical time; cheap to advance).
    private let minRTO = 0.2                 // RTO floor (RFC 6298 / R6.4)
    private let sampleStep = 0.02            // fine observation granularity (< minRTO)
    private let timeBudget = 900.0           // generous logical-time budget for P3
    private let iterationCap = 200_000       // hard safety cap against a stuck loop

    /// A compact observation of the sender's state at a logical instant.
    private struct Observation: CustomStringConvertible {
        let cwnd: Int
        let ssthresh: Int
        let flightSize: Int
        let sendWindow: Int
        var description: String {
            "(cwnd=\(cwnd), ssthresh=\(ssthresh), flight=\(flightSize), sendWindow=\(sendWindow))"
        }
    }

    /// The (compact) result of running a single seed to quiescence. Only the first
    /// violating observation per property is retained so failure messages stay small
    /// and reproducible.
    private struct SeedRun {
        let seed: UInt64
        let sentCount: Int
        let deliveredCount: Int
        let deliveredEqualsSent: Bool
        let quiesced: Bool
        let elapsed: Double
        let rtoRetransmitCount: Int
        let pendingCountAfter: Int
        let smss: Int
        let p4Violation: Observation?   // cwnd < SMSS
        let p5Violation: Observation?   // FlightSize grew above Send_Window (new data past window)
        let p6Violation: Observation?   // loss-adjusted ssthresh < 2*SMSS
    }

    // MARK: - The property assertions

    @Test func invariantsHoldAcrossSeeds() {
        for seed in Self.seeds {
            let run = runToQuiescence(seed: seed)
            let s = "seed \(seed)"

            // P1 + P2: the receiver delivered exactly the bytes the sender submitted,
            // in order and each exactly once. Equal length rules out double delivery
            // (exactly-once, P2); equal contents rules out reordering/corruption (P1).
            let deliveredEqualsSent = run.deliveredEqualsSent
            #expect(deliveredEqualsSent,
                    "P1/P2 \(s): delivered \(run.deliveredCount) bytes vs sent \(run.sentCount); streams equal = \(run.deliveredEqualsSent)")

            // P3: the run reached quiescence (sndUna == sndNxt, Send_Buffer empty,
            // all bytes delivered) within the budget, and the event loop then drains.
            let quiesced = run.quiesced
            #expect(quiesced,
                    "P3 \(s): did not reach quiescence within \(timeBudget)s (elapsed \(run.elapsed)s)")
            let pendingAfter = run.pendingCountAfter
            #expect(pendingAfter == 0,
                    "P3 \(s): event loop did not drain (pending=\(run.pendingCountAfter))")
            // Bounded number of RTO expirations: each RTO-timer retransmit consumes at
            // least minRTO of logical time, so the count is bounded by elapsed/minRTO.
            let rtoBound = Int(run.elapsed / minRTO) + 1
            let rtoCount = run.rtoRetransmitCount
            #expect(rtoCount <= rtoBound,
                    "P3 \(s): \(run.rtoRetransmitCount) RTO retransmits exceeds bound \(rtoBound)")

            // P4: cwnd >= SMSS at every observation after establishment.
            let p4 = run.p4Violation
            #expect(p4 == nil,
                    "P4 \(s): cwnd < SMSS \(run.smss) at \(run.p4Violation.map(String.init(describing:)) ?? "-")")

            // P5: the sender never grew FlightSize above the Send_Window by sending new
            // data (net increase beyond the window between observations). A transient
            // excess after a cwnd reduction that only decreases is allowed.
            let p5 = run.p5Violation
            #expect(p5 == nil,
                    "P5 \(s): FlightSize grew above Send_Window (new data past window) at \(run.p5Violation.map(String.init(describing:)) ?? "-")")

            // P6: whenever ssthresh was adjusted on loss, it never dropped below 2*SMSS.
            let p6 = run.p6Violation
            #expect(p6 == nil,
                    "P6 \(s): loss-adjusted ssthresh < 2*SMSS \(2 * run.smss) at \(run.p6Violation.map(String.init(describing:)) ?? "-")")

            // P7: no retransmit storm — the single epoch-guarded RTO timer fires at
            // most once per RTO interval, so timer-driven retransmits are bounded by
            // the number of elapsed RTO intervals (the "at most once per RTO interval"
            // guarantee of R9.4).
            let rtoCountP7 = run.rtoRetransmitCount
            #expect(rtoCountP7 <= Int(run.elapsed / minRTO) + 1,
                    "P7 \(s): retransmit storm — \(run.rtoRetransmitCount) RTO retransmits in \(run.elapsed)s")
        }
    }

    // MARK: - Harness

    /// Build a wired pair with seeded loss + a random payload, drive the transfer
    /// to quiescence, sampling the sender's congestion state each step.
    private func runToQuiescence(seed: UInt64) -> SeedRun {
        let loop = EventLoop()

        // Derive the scenario deterministically from the seed.
        var prng = SplitMix64(seed: seed)
        // Modest random payload: 1.5 KB … 5.5 KB (a handful of SMSS-sized segments).
        let payloadLen = 1536 + Int(prng.next() % 4096)
        let payload: [UInt8] = (0..<payloadLen).map { _ in UInt8(prng.next() & 0xFF) }
        // Modest random drop probability: 5% … 20%.
        let dropProbability = 0.05 + Double(prng.next() % 4) * 0.05

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
        // Seeded pseudo-random loss on A→B data segments (reproducible per seed).
        TestWire.connect(stackA, ifA, stackB, ifB, on: loop, latency: 0.01,
                        dropSeed: seed, dropProbability: dropProbability)
        stackA.configuredNeighbor(ip: ipB, mac: macB)
        stackB.configuredNeighbor(ip: ipA, mac: macA)

        let listener = stackB.listen(port: 80)
        let client = stackA.connect(localPort: 50_000, to: ipB, remotePort: 80)

        // Complete the 3-way handshake.
        loop.advance(by: 0.5)
        let server = listener.dequeue()

        let smss = client.congestionControllerSnapshot.smss
        let sendStart = loop.now
        client.send(payload)

        var deliveredCount = 0
        var deliveredMatches = true       // does every delivered byte match the sent stream?
        var p4Violation: Observation?
        var p5Violation: Observation?
        var p6Violation: Observation?
        var prevFlightSize: Int? = nil    // previous observation's FlightSize (for P5 net-growth check)

        func sample() {
            let snap = client.congestionSnapshot
            let obs = Observation(cwnd: snap.cwnd, ssthresh: snap.ssthresh,
                                  flightSize: client.flightSize, sendWindow: client.effectiveSendWindow)
            if p4Violation == nil, obs.cwnd < smss { p4Violation = obs }
            // P5 (RFC 5681 / Reno-faithful): a violation is a *net increase* of
            // FlightSize above the Send_Window between consecutive observations — i.e.
            // the sender injected new data while already at or over the window. A
            // transient excess right after a cwnd reduction (RTO collapse / fast-recovery
            // deflation) that only ever holds flat or decreases as ACKs arrive is allowed.
            if p5Violation == nil, obs.flightSize > obs.sendWindow,
               let prev = prevFlightSize, obs.flightSize > prev {
                p5Violation = obs
            }
            prevFlightSize = obs.flightSize
            // ssthresh below its initial 0xFFFF means a loss-driven adjustment happened.
            if p6Violation == nil, obs.ssthresh < 0xFFFF, obs.ssthresh < 2 * smss { p6Violation = obs }
        }

        // Drain the receiver, comparing bytes against the sent stream as they arrive
        // (verifies in-order + exactly-once without buffering the whole delivered copy).
        func drainReceiver() {
            guard let server else { return }
            let chunk = server.read(max: 1 << 20)
            guard !chunk.isEmpty else { return }
            for byte in chunk {
                if deliveredCount < payload.count, byte != payload[deliveredCount] {
                    deliveredMatches = false
                }
                deliveredCount += 1
            }
        }

        func isQuiescent() -> Bool {
            client.sndFullyAcked && client.sendBufferIsEmpty && deliveredCount >= payload.count
        }

        var quiesced = false
        sample()
        drainReceiver()
        var iterations = 0
        while loop.now - sendStart < timeBudget && iterations < iterationCap {
            if isQuiescent() { quiesced = true; break }
            // Adaptive step: when the Send_Buffer is drained and we are only waiting
            // on the RTO timer (idle backoff), jump by the current RTO so a deep
            // exponential backoff does not require millions of fine steps. Otherwise
            // sample finely to catch cwnd/flight transitions.
            let idleOnTimer = client.sendBufferIsEmpty && !client.sndFullyAcked
            let step = idleOnTimer ? Swift.max(sampleStep, client.congestionSnapshot.rto) : sampleStep
            loop.advance(by: step)
            sample()
            drainReceiver()
            iterations += 1
        }
        drainReceiver()
        if !quiesced, isQuiescent() { quiesced = true }

        // Forward progress complete => the loop must drain: with the retransmit queue
        // empty the epoch-guarded timer re-arms no further, so advance(by:) terminates
        // and leaves no pending events (P3, "pendingCount → 0").
        if quiesced { loop.advance(by: 60.0) }

        return SeedRun(seed: seed, sentCount: payload.count, deliveredCount: deliveredCount,
                       deliveredEqualsSent: deliveredMatches && deliveredCount == payload.count,
                       quiesced: quiesced, elapsed: loop.now - sendStart,
                       rtoRetransmitCount: client.rtoRetransmitCount,
                       pendingCountAfter: loop.pendingCount, smss: smss,
                       p4Violation: p4Violation, p5Violation: p5Violation, p6Violation: p6Violation)
    }
}
