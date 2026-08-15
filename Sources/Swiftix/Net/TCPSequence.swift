/// Wraparound-safe TCP sequence-number comparisons and interval helpers.
enum TCPSequence {
    /// Serial-number "greater than" over the 32-bit space (RFC 1982, half-window).
    static func greater(_ a: UInt32, than b: UInt32) -> Bool {
        let diff = a &- b
        return diff != 0 && diff < 0x8000_0000
    }
}
