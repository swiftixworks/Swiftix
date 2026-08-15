/// Retransmission timer scheduling and RFC 6298 sampling for TCP connections.
extension TCPConnection {
    /// RFC 6298 RTT/RTO estimator. Owns the smoothed RTT (`srtt`), the RTT
    /// variation (`rttvar`), and the current retransmission timeout (`rto`).
    /// Before the first RTT sample it reports a conservative initial RTO of 1s
    /// (R6.8); once sampling begins it computes `rto = clamp(srtt + 4*rttvar)`
    /// within the `[minRTO, maxRTO]` bounds and doubles the RTO on each timeout.
    struct RTOEstimator {
        private(set) var srtt: Double = 0
        private(set) var rttvar: Double = 0
        private(set) var rto: Double = 1.0        // initial RTO before first sample (R6.8)
        private(set) var hasSample = false

        let minRTO = 0.2
        let maxRTO = 60.0

        /// Incorporate a fresh, unambiguous RTT sample `r` (seconds) per RFC 6298.
        mutating func onRTTSample(_ r: Double) {
            if !hasSample {
                // First sample (R6.1): SRTT = R, RTTVAR = R / 2.
                srtt = r
                rttvar = r / 2
                hasSample = true
            } else {
                // Subsequent samples (R6.2): standard 1/4 and 1/8 gains. RTTVAR is
                // updated before SRTT so it uses the previous SRTT (RFC 6298).
                rttvar = (1 - 1.0 / 4.0) * rttvar + (1.0 / 4.0) * abs(srtt - r)
                srtt = (1 - 1.0 / 8.0) * srtt + (1.0 / 8.0) * r
            }
            // R6.3 + clamp (R6.4, R6.5).
            rto = clamp(srtt + 4 * rttvar)
        }

        /// Exponential backoff on retransmission timeout: double the RTO up to the
        /// maximum bound (R6.6).
        mutating func onTimeout() {
            rto = Swift.min(rto * 2, maxRTO)
        }

        private func clamp(_ value: Double) -> Double {
            Swift.min(Swift.max(value, minRTO), maxRTO)
        }
    }
}
