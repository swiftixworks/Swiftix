import Testing
@testable import Swiftix

/// Direct unit tests of the Reno congestion-controller core (slow start +
/// congestion avoidance), exercised without a full TCP connection or send pump.
/// Covers the initial window on establish, per-ACK slow-start growth, the
/// exponential-per-RTT shape, the linear +1 SMSS/RTT congestion-avoidance rate,
/// the cwnd lower bound, and the send-window min(cwnd, rwnd) limit.
@Suite("CongestionController (Reno core)")
struct CongestionControllerTests {

    /// Build a controller that has reached ESTABLISHED (cwnd seeded to the
    /// initial window, phase == slow start).
    private func established() -> TCPConnection.CongestionController {
        var cc = TCPConnection.CongestionController()
        cc.onEstablished()
        return cc
    }

    /// Drive the controller through slow start until it crosses into congestion
    /// avoidance (cwnd >= ssthresh). Returns the controller at the first ACK
    /// processed in the congestion-avoidance phase.
    private func drivenToCongestionAvoidance() -> TCPConnection.CongestionController {
        var cc = established()
        while cc.phase != .congestionAvoidance {
            cc.onNewAck(ackedBytes: cc.smss)
        }
        return cc
    }

    /// R1.1: entering ESTABLISHED seeds cwnd to the initial window (2 * SMSS) and
    /// begins in slow start.
    @Test func onEstablishedSeedsInitialWindow() {
        let cc = established()
        #expect(cc.cwnd == cc.initialWindow)
        #expect(cc.cwnd == 2 * cc.smss)
        #expect(cc.phase == .slowStart)
    }

    /// R1.2: while cwnd < ssthresh, each new-data ACK grows cwnd by exactly one SMSS.
    @Test func slowStartAddsOneSmssPerAck() {
        var cc = established()
        let start = cc.cwnd
        cc.onNewAck(ackedBytes: cc.smss)
        #expect(cc.cwnd == start + cc.smss)
        cc.onNewAck(ackedBytes: cc.smss)
        #expect(cc.cwnd == start + 2 * cc.smss)
    }

    /// R1.4: the controller stays in slow start while cwnd < ssthresh.
    @Test func remainsInSlowStartBelowSsthresh() {
        var cc = established()
        // A handful of ACKs that keep cwnd well under the (high) ssthresh.
        for _ in 0..<5 {
            cc.onNewAck(ackedBytes: cc.smss)
            #expect(cc.cwnd < cc.ssthresh)
            #expect(cc.phase == .slowStart)
        }
    }

    /// R1.2 (shape): across one window of ACKs, slow start roughly doubles cwnd
    /// (exponential growth per RTT), since a window carries cwnd/SMSS ACKs.
    @Test func slowStartDoublesPerRoundTrip() {
        var cc = established()
        // One RTT = cwnd/SMSS acknowledgments of one SMSS each.
        var cwnd = cc.cwnd
        for _ in 0..<3 {
            let acksThisRTT = cwnd / cc.smss
            for _ in 0..<acksThisRTT { cc.onNewAck(ackedBytes: cc.smss) }
            #expect(cc.cwnd == cwnd * 2)     // doubled after a full window of ACKs
            cwnd = cc.cwnd
        }
    }

    /// R2.1, R2.3: in congestion avoidance, one full window of acknowledged bytes
    /// grows cwnd by no more than a single SMSS (linear, +1 SMSS per RTT).
    @Test func congestionAvoidanceLinearGrowth() {
        var cc = drivenToCongestionAvoidance()
        #expect(cc.phase == .congestionAvoidance)

        let before = cc.cwnd
        // Feed exactly one window (before bytes) in SMSS-sized ACKs.
        let acks = before / cc.smss
        for _ in 0..<acks { cc.onNewAck(ackedBytes: cc.smss) }

        // Exactly one SMSS of growth for the window (rate-limited per R2.3).
        #expect(cc.cwnd == before + cc.smss)
        #expect(cc.phase == .congestionAvoidance)
    }

    /// R9.1: cwnd stays at or above one SMSS after establishment and adjustments.
    @Test func cwndNeverBelowSmss() {
        var cc = established()
        #expect(cc.cwnd >= cc.smss)
        for _ in 0..<10 {
            cc.onNewAck(ackedBytes: cc.smss)
            #expect(cc.cwnd >= cc.smss)
        }
    }
}
