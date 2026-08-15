/// A Foundation-free SHA-256 implementation shared by Swiftix artifact
/// formats. The implementation follows FIPS 180-4 and emits lowercase hex.
public struct SwiftixSHA256: Sendable {
    private var state: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
    private var buffer: [UInt8] = []
    private var byteCount: UInt64 = 0

    public init() {}

    public static func hex(_ bytes: [UInt8]) -> String {
        var digest = SwiftixSHA256()
        digest.update(bytes)
        return digest.finalizeHex()
    }

    public static func verify(_ bytes: [UInt8], expected: String) -> Bool {
        hex(bytes) == expected.lowercased()
    }

    public mutating func update(_ bytes: [UInt8]) {
        byteCount &+= UInt64(bytes.count)
        var index = 0
        if !buffer.isEmpty {
            let count = min(64 - buffer.count, bytes.count)
            buffer.append(contentsOf: bytes[0..<count])
            index += count
            if buffer.count == 64 {
                compress(buffer, offset: 0)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while index + 64 <= bytes.count {
            compress(bytes, offset: index)
            index += 64
        }
        if index < bytes.count {
            buffer.append(contentsOf: bytes[index...])
        }
    }

    public mutating func finalizeHex() -> String {
        let bitCount = byteCount &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 { buffer.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }
        var offset = 0
        while offset < buffer.count {
            compress(buffer, offset: offset)
            offset += 64
        }
        buffer.removeAll(keepingCapacity: true)

        let alphabet = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(64)
        for word in state {
            for shift in stride(from: 24, through: 0, by: -8) {
                let byte = UInt8(truncatingIfNeeded: word >> UInt32(shift))
                output.append(alphabet[Int(byte >> 4)])
                output.append(alphabet[Int(byte & 0x0F)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private mutating func compress(_ block: [UInt8], offset blockOffset: Int) {
        var words = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let offset = blockOffset + index * 4
            words[index] =
                UInt32(block[offset]) << 24
                | UInt32(block[offset + 1]) << 16
                | UInt32(block[offset + 2]) << 8
                | UInt32(block[offset + 3])
        }
        for index in 16..<64 {
            let previous15 = words[index - 15]
            let previous2 = words[index - 2]
            let s0 = rotate(previous15, 7) ^ rotate(previous15, 18) ^ (previous15 >> 3)
            let s1 = rotate(previous2, 17) ^ rotate(previous2, 19) ^ (previous2 >> 10)
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for index in 0..<64 {
            let sum1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let choose = (e & f) ^ (~e & g)
            let temporary1 = h &+ sum1 &+ choose &+ Self.constants[index] &+ words[index]
            let sum0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = sum0 &+ majority
            h = g; g = f; f = e
            e = d &+ temporary1
            d = c; c = b; b = a
            a = temporary1 &+ temporary2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }

    private func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private static let constants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5,
        0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3,
        0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC,
        0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7,
        0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13,
        0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3,
        0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5,
        0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208,
        0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]
}
