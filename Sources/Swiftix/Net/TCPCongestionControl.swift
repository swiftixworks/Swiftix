/// A read-only view of a connection's congestion-control state: the
/// window (`cwnd`/`ssthresh`) and the RFC 6298 timing estimates
/// (`srtt`/`rttvar`/`rto`). Exposed for tests, `NetworkStack.snapshotTCP()`, and
/// `/proc/net/tcp`. Internal so the public API is unchanged.
struct CongestionSnapshot: Equatable {
    let cwnd: Int
    let ssthresh: Int
    let srtt: Double
    let rttvar: Double
    let rto: Double
}

extension TCPConnection {
    /// Congestion-control phase per RFC 5681 / 8312.
    enum CongestionPhase { case slowStart, congestionAvoidance, fastRecovery }

    /// CUBIC congestion controller (RFC 8312) with Reno-compatible slow start and
    /// fast recovery. Replaces the original Reno linear growth in congestion
    /// avoidance with CUBIC's cubic function while keeping the slow-start and
    /// loss-response behavior compatible.
    ///
    /// Key parameters (RFC 8312 §4):
    /// - C = 0.4 (scaling factor)
    /// - β = 0.7 (multiplicative decrease factor)
    ///
    /// Congestion-avoidance growth uses the §4.3 `cwnd_cnt` ACK-counter scheme
    /// (same one real CUBIC stacks use): each ACK advances a fractional counter,
    /// and cwnd grows by one SMSS once the counter crosses `cnt` — the number of
    /// ACKs needed for a one-segment increase at the current point on the cubic
    /// curve (or the TCP-friendly Reno-equivalent rate, whichever is faster).
    /// This is an educational implementation: no fast convergence (§4.6) or
    /// per-RTT-only sampling (§4.1's `epoch_start` on the first CA ACK, not on
    /// each RTT boundary) — the cubic *shape* and its TCP-friendly floor are
    /// what's modeled, not the full RFC state machine.
    struct CongestionController {
        let smss = 512                          // Sender MSS (bytes)
        private(set) var cwnd: Int              // set to initialWindow on establish
        private(set) var ssthresh: Int = 0xFFFF // starts high => begin in slow start
        private(set) var phase: CongestionPhase = .slowStart
        var dupAckCount = 0                     // used by fast retransmit
        var initialWindow: Int { 2 * smss }     // R1.1

        // CUBIC state
        private let cubicC = 0.4
        private let cubicBeta = 0.7
        /// W_max: the window size just before the last loss event (in bytes).
        private var wMax: Int = 0
        /// Time of the last loss event (epoch start), in logical seconds.
        private var epochStart: Double = 0
        /// Whether we've entered at least one congestion-avoidance epoch.
        private var epochActive = false
        /// RFC 8312 §4.3 ACK counter: cwnd grows by one SMSS once this counter
        /// reaches `cnt` (the number of ACKs needed for the current growth
        /// rate), then resets. This is the same "cwnd_cnt" scheme real CUBIC
        /// implementations use instead of a flat per-ACK byte step.
        private var cwndCnt: Double = 0

        init() {
            cwnd = 2 * smss   // == initialWindow; refreshed by onEstablished()
        }

        /// Connection reached ESTABLISHED: seed cwnd to the initial window and
        /// begin in slow start.
        mutating func onEstablished() {
            cwnd = initialWindow
            phase = .slowStart
            clampCwnd()
        }

        /// An acknowledgment for `ackedBytes` of new data arrived.
        /// `now` is the current logical time (from the event loop).
        mutating func onNewAck(ackedBytes: Int, now: Double = 0) {
            dupAckCount = 0

            if phase == .fastRecovery {
                // First ACK advancing sndUna exits fast recovery (RFC 5681 §3.2).
                cwnd = ssthresh
                phase = .congestionAvoidance
                cwndCnt = 0
                epochStart = now
                epochActive = true
                clampCwnd()
                return
            }

            if cwnd < ssthresh {
                // Slow start: exponential growth (add SMSS per ACK).
                cwnd += smss
                phase = .slowStart
                cwndCnt = 0
            } else {
                // CUBIC congestion avoidance (RFC 8312 §4.3's "cwnd_cnt" ACK
                // counter, not a flat per-ACK byte step): compute how many ACKs
                // are needed for a one-SMSS increase at the current growth rate
                // (`cnt`, in segments), accumulate a fractional ACK count each
                // call, and only bump cwnd by one SMSS once the accumulator
                // crosses `cnt`. This reproduces the cubic curve's actual
                // per-ACK increment shape instead of clamping every ACK to a
                // full SMSS step.
                phase = .congestionAvoidance
                if !epochActive {
                    epochStart = now
                    epochActive = true
                    cwndCnt = 0
                }
                let t = now - epochStart
                let target = cubicW(t: t)
                let cwndSeg = Double(cwnd) / Double(smss)
                let cnt: Double
                if target > Double(cwnd) {
                    // Cubic region: cnt = cwnd / (W_cubic(t) - cwnd), in segments.
                    cnt = cwndSeg / ((target - Double(cwnd)) / Double(smss))
                } else {
                    // TCP-friendly region: at least Reno-equivalent growth
                    // (one SMSS per window of ACKs, i.e. cnt == cwnd in segments).
                    cnt = cwndSeg
                }
                // Each acked segment advances the counter by one; grow cwnd by
                // one SMSS every time it crosses `cnt` (fractional carry kept).
                cwndCnt += Double(ackedBytes) / Double(smss)
                if cwndCnt >= Swift.max(cnt, 1) {
                    cwndCnt -= Swift.max(cnt, 1)
                    cwnd += smss
                }
            }
            clampCwnd()
        }

        /// A duplicate ACK arrived with `flightSize` bytes outstanding.
        mutating func onDuplicateAck(flightSize: Int) -> Bool {
            dupAckCount += 1
            if dupAckCount == 3 {
                // Loss detected: enter fast recovery.
                wMax = cwnd
                ssthresh = Swift.max(Int(Double(cwnd) * cubicBeta), 2 * smss)
                cwnd = ssthresh + 3 * smss
                phase = .fastRecovery
                epochActive = false
                cwndCnt = 0
                clampCwnd()
                return true
            } else if dupAckCount > 3 {
                cwnd += smss  // inflate during fast recovery
                clampCwnd()
            }
            return false
        }

        /// RTO timer expired: heavy loss response.
        mutating func onRTOExpiry(flightSize: Int) {
            wMax = cwnd
            ssthresh = Swift.max(Int(Double(cwnd) * cubicBeta), 2 * smss)
            cwnd = smss
            phase = .slowStart
            dupAckCount = 0
            cwndCnt = 0
            epochActive = false
            clampCwnd()
        }

        // MARK: - ECN

        /// ECN congestion signal: treat like a loss event without retransmitting.
        /// Reduces cwnd by the CUBIC beta factor and enters congestion avoidance.
        mutating func onECNCongestion() {
            wMax = cwnd
            ssthresh = Swift.max(Int(Double(cwnd) * cubicBeta), 2 * smss)
            cwnd = ssthresh
            phase = .congestionAvoidance
            epochActive = false
            cwndCnt = 0
            clampCwnd()
        }

        // MARK: - CUBIC helpers

        /// CUBIC window function: W(t) = C * (t - K)^3 + W_max (in bytes).
        /// K = cubic_root(W_max * (1 - β) / C)
        /// Returns `Double` (not truncated to `Int`) so the §4.3 `cnt` growth-rate
        /// calculation in `onNewAck` can compute the target/current gap precisely.
        private func cubicW(t: Double) -> Double {
            let wMaxD = Double(wMax > 0 ? wMax : cwnd)
            let k = cubeRoot(wMaxD * (1.0 - cubicBeta) / cubicC)
            let tMinusK = t - k
            let w = cubicC * tMinusK * tMinusK * tMinusK + wMaxD
            return Swift.max(w, Double(smss))
        }

        /// Newton's method cube root (no Foundation dependency).
        private func cubeRoot(_ x: Double) -> Double {
            guard x > 0 else { return 0 }
            var guess = x
            for _ in 0..<20 {
                guess = (2.0 * guess + x / (guess * guess)) / 3.0
            }
            return guess
        }

        private mutating func clampCwnd() {
            cwnd = Swift.max(cwnd, smss)
        }
    }
}
