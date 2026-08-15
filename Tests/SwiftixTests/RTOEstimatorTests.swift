import Testing
@testable import Swiftix

/// Direct unit tests of the RFC 6298 RTT/RTO estimator math, exercised without a
/// full TCP connection. Covers the initial RTO, first-sample seeding, the smoothed
/// subsequent update, the [minRTO, maxRTO] clamps, and timeout backoff.
@Suite("RTOEstimator (RFC 6298)")
struct RTOEstimatorTests {

    /// Absolute-tolerance floating-point comparison for the estimator math.
    private func approxEqual(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    /// R6.8: before any RTT sample, the estimator uses a conservative 1s RTO.
    @Test func initialRTOBeforeAnySample() {
        let est = TCPConnection.RTOEstimator()
        #expect(est.rto == 1.0)
        #expect(est.hasSample == false)
        #expect(est.srtt == 0)
        #expect(est.rttvar == 0)
    }

    /// R6.1 + R6.3: first sample sets SRTT = R, RTTVAR = R/2, RTO = SRTT + 4*RTTVAR.
    @Test func firstSampleSeedsSrttAndRttvar() {
        var est = TCPConnection.RTOEstimator()
        est.onRTTSample(1.0)

        #expect(est.hasSample)
        #expect(approxEqual(est.srtt, 1.0))
        #expect(approxEqual(est.rttvar, 0.5))
        // rto = clamp(1.0 + 4*0.5) = 3.0
        #expect(approxEqual(est.rto, 3.0))
    }

    /// R6.2 + R6.3: a subsequent sample applies the 1/4 (RTTVAR) and 1/8 (SRTT)
    /// gains, with RTTVAR updated from the previous SRTT before SRTT moves.
    @Test func subsequentSampleSmoothedUpdate() {
        var est = TCPConnection.RTOEstimator()
        est.onRTTSample(1.0)     // srtt=1.0, rttvar=0.5
        est.onRTTSample(1.5)

        // rttvar = 0.75*0.5 + 0.25*|1.0 - 1.5| = 0.375 + 0.125 = 0.5
        #expect(approxEqual(est.rttvar, 0.5))
        // srtt = 0.875*1.0 + 0.125*1.5 = 1.0625
        #expect(approxEqual(est.srtt, 1.0625))
        // rto = 1.0625 + 4*0.5 = 3.0625
        #expect(approxEqual(est.rto, 3.0625))
    }

    /// R6.4: a computed RTO below 0.2s is clamped up to the 0.2s floor.
    @Test func rtoClampedToMinimum() {
        var est = TCPConnection.RTOEstimator()
        est.onRTTSample(0.01)    // srtt=0.01, rttvar=0.005 -> raw rto=0.03
        #expect(approxEqual(est.rto, 0.2))
    }

    /// R6.5: a computed RTO above 60s is clamped down to the 60s ceiling.
    @Test func rtoClampedToMaximum() {
        var est = TCPConnection.RTOEstimator()
        est.onRTTSample(100.0)   // srtt=100, rttvar=50 -> raw rto=300
        #expect(approxEqual(est.rto, 60.0))
    }

    /// R6.6: each timeout doubles the current RTO.
    @Test func timeoutDoublesRTO() {
        var est = TCPConnection.RTOEstimator()
        est.onRTTSample(1.0)
        est.onRTTSample(1.5)     // rto = 3.0625
        est.onTimeout()
        #expect(approxEqual(est.rto, 6.125))
        est.onTimeout()
        #expect(approxEqual(est.rto, 12.25))
    }

    /// R6.6: backoff never exceeds the 60s maximum bound.
    @Test func timeoutBackoffCappedAtMaximum() {
        var est = TCPConnection.RTOEstimator()
        est.onRTTSample(100.0)   // rto clamped to 60
        #expect(approxEqual(est.rto, 60.0))
        est.onTimeout()
        #expect(approxEqual(est.rto, 60.0))
    }

    /// From the initial 1s RTO, timeouts back off geometrically before any sample.
    @Test func timeoutBackoffFromInitialRTO() {
        var est = TCPConnection.RTOEstimator()
        est.onTimeout()
        #expect(approxEqual(est.rto, 2.0))
        est.onTimeout()
        #expect(approxEqual(est.rto, 4.0))
    }
}
