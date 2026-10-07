/// A small seedable pseudo-random generator (SplitMix64) backing the kernel's
/// `/dev/random` and `/dev/urandom`.
///
/// It is deliberately deterministic: the same seed always yields the same byte
/// stream, which keeps simulations and tests reproducible. It is **not**
/// cryptographically secure and must never be used to derive secrets; a host
/// that wants unpredictable output seeds the kernel from platform entropy
/// (`Kernel.seedRandom(_:)`), which still does not make the stream
/// cryptographic.
///
/// Concurrency: a value type owned by one `Kernel` and mutated only on the
/// kernel's serial executor.
struct DeterministicRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// The next `count` bytes of the stream (little-endian within each word).
    mutating func bytes(_ count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(count)
        while out.count < count {
            var word = next()
            for _ in 0..<min(8, count - out.count) {
                out.append(UInt8(truncatingIfNeeded: word))
                word >>= 8
            }
        }
        return out
    }
}
