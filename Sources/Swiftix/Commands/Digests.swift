/// Pure-Swift message digests for the checksum built-ins (`md5sum`, `sha1sum`,
/// `sha256sum`): MD5 (RFC 1321), SHA-1 and SHA-256 (FIPS 180-4).
///
/// The core target may not import Foundation/CryptoKit or depend on another
/// target, so the three compression functions live here. Each digest is a
/// one-shot function over a byte array: whole 64-byte blocks are consumed
/// straight out of the caller's buffer (no per-block copies), and only the
/// padded tail is materialized, so multi-megabyte inputs cost one pass.
///
/// These are integrity checksums for the command layer, not a security
/// boundary: nothing in the kernel authenticates with them.
///
/// Concurrency: pure functions over value types; no shared mutable state.

enum Digest {

    /// The algorithms the checksum commands expose.
    enum Algorithm {
        case md5, sha1, sha256

        func hash(_ data: [UInt8]) -> [UInt8] {
            switch self {
            case .md5: return Digest.md5(data)
            case .sha1: return Digest.sha1(data)
            case .sha256: return Digest.sha256(data)
            }
        }

        /// Length of the digest in hex characters.
        var hexLength: Int {
            switch self {
            case .md5: return 32
            case .sha1: return 40
            case .sha256: return 64
            }
        }
    }

    /// Lowercase hex rendering of a digest.
    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Block driver

    /// Feed `data` to `body` one 64-byte block at a time, followed by the
    /// Merkle–Damgård padding (0x80, zeros, 64-bit bit length in the given byte
    /// order). `body` receives a pointer to exactly 64 readable bytes.
    private static func forEachBlock(_ data: [UInt8],
                                     lengthBigEndian: Bool,
                                     _ body: (UnsafePointer<UInt8>) -> Void) {
        let fullBlocks = data.count / 64
        data.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for block in 0..<fullBlocks {
                body(base + block * 64)
            }
        }
        var tail = Array(data[(fullBlocks * 64)...])
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bitLength = UInt64(data.count) &* 8
        for index in 0..<8 {
            let shift = UInt64(lengthBigEndian ? (7 - index) * 8 : index * 8)
            tail.append(UInt8(truncatingIfNeeded: bitLength >> shift))
        }
        tail.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for block in 0..<(tail.count / 64) {
                body(base + block * 64)
            }
        }
    }

    @inline(__always)
    private static func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 &- count))
    }

    @inline(__always)
    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 &- count))
    }

    @inline(__always)
    private static func bigEndianWord(_ p: UnsafePointer<UInt8>, _ index: Int) -> UInt32 {
        let o = index * 4
        return UInt32(p[o]) << 24 | UInt32(p[o + 1]) << 16 | UInt32(p[o + 2]) << 8 | UInt32(p[o + 3])
    }

    @inline(__always)
    private static func littleEndianWord(_ p: UnsafePointer<UInt8>, _ index: Int) -> UInt32 {
        let o = index * 4
        return UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24
    }

    private static func bytes(_ words: [UInt32], bigEndian: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(words.count * 4)
        for word in words {
            for index in 0..<4 {
                let shift = UInt32(bigEndian ? (3 - index) * 8 : index * 8)
                out.append(UInt8(truncatingIfNeeded: word >> shift))
            }
        }
        return out
    }

    // MARK: - MD5

    private static let md5Shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let md5Constants: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    /// MD5 of `data` (16 bytes).
    static func md5(_ data: [UInt8]) -> [UInt8] {
        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476
        var m = [UInt32](repeating: 0, count: 16)
        md5Shifts.withUnsafeBufferPointer { shifts in
            md5Constants.withUnsafeBufferPointer { constants in
                m.withUnsafeMutableBufferPointer { m in
                    forEachBlock(data, lengthBigEndian: false) { block in
                        for index in 0..<16 { m[index] = littleEndianWord(block, index) }
                        var a = a0, b = b0, c = c0, d = d0
                        for i in 0..<64 {
                            var f: UInt32
                            let g: Int
                            if i < 16 {
                                f = (b & c) | (~b & d)
                                g = i
                            } else if i < 32 {
                                f = (d & b) | (~d & c)
                                g = (5 &* i &+ 1) & 15
                            } else if i < 48 {
                                f = b ^ c ^ d
                                g = (3 &* i &+ 5) & 15
                            } else {
                                f = c ^ (b | ~d)
                                g = (7 &* i) & 15
                            }
                            f = f &+ a &+ constants[i] &+ m[g]
                            a = d
                            d = c
                            c = b
                            b = b &+ rotl(f, shifts[i])
                        }
                        a0 = a0 &+ a
                        b0 = b0 &+ b
                        c0 = c0 &+ c
                        d0 = d0 &+ d
                    }
                }
            }
        }
        return bytes([a0, b0, c0, d0], bigEndian: false)
    }

    // MARK: - SHA-1

    /// SHA-1 of `data` (20 bytes).
    static func sha1(_ data: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0
        var w = [UInt32](repeating: 0, count: 80)
        w.withUnsafeMutableBufferPointer { w in
            forEachBlock(data, lengthBigEndian: true) { block in
                for index in 0..<16 { w[index] = bigEndianWord(block, index) }
                for index in 16..<80 {
                    w[index] = rotl(w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16], 1)
                }
                var a = h0, b = h1, c = h2, d = h3, e = h4
                for i in 0..<80 {
                    let f: UInt32
                    let k: UInt32
                    if i < 20 {
                        f = (b & c) | (~b & d)
                        k = 0x5A827999
                    } else if i < 40 {
                        f = b ^ c ^ d
                        k = 0x6ED9EBA1
                    } else if i < 60 {
                        f = (b & c) | (b & d) | (c & d)
                        k = 0x8F1BBCDC
                    } else {
                        f = b ^ c ^ d
                        k = 0xCA62C1D6
                    }
                    let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                    e = d
                    d = c
                    c = rotl(b, 30)
                    b = a
                    a = temp
                }
                h0 = h0 &+ a
                h1 = h1 &+ b
                h2 = h2 &+ c
                h3 = h3 &+ d
                h4 = h4 &+ e
            }
        }
        return bytes([h0, h1, h2, h3, h4], bigEndian: true)
    }

    // MARK: - SHA-256

    private static let sha256Constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// SHA-256 of `data` (32 bytes).
    static func sha256(_ data: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var w = [UInt32](repeating: 0, count: 64)
        sha256Constants.withUnsafeBufferPointer { k in
            w.withUnsafeMutableBufferPointer { w in
                h.withUnsafeMutableBufferPointer { h in
                    forEachBlock(data, lengthBigEndian: true) { block in
                        for index in 0..<16 { w[index] = bigEndianWord(block, index) }
                        for index in 16..<64 {
                            let x = w[index - 15]
                            let y = w[index - 2]
                            let s0 = rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3)
                            let s1 = rotr(y, 17) ^ rotr(y, 19) ^ (y >> 10)
                            w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
                        }
                        var a = h[0], b = h[1], c = h[2], d = h[3]
                        var e = h[4], f = h[5], g = h[6], hh = h[7]
                        for i in 0..<64 {
                            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                            let ch = (e & f) ^ (~e & g)
                            let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                            let maj = (a & b) ^ (a & c) ^ (b & c)
                            let t2 = s0 &+ maj
                            hh = g
                            g = f
                            f = e
                            e = d &+ t1
                            d = c
                            c = b
                            b = a
                            a = t1 &+ t2
                        }
                        h[0] = h[0] &+ a
                        h[1] = h[1] &+ b
                        h[2] = h[2] &+ c
                        h[3] = h[3] &+ d
                        h[4] = h[4] &+ e
                        h[5] = h[5] &+ f
                        h[6] = h[6] &+ g
                        h[7] = h[7] &+ hh
                    }
                }
            }
        }
        return bytes(h, bigEndian: true)
    }
}
