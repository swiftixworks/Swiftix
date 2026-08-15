/// A 48-bit Ethernet MAC address.
public struct MACAddress: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// Exactly 6 bytes.
    public let bytes: [UInt8]

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == 6 else { return nil }
        self.bytes = bytes
    }

    /// Parse "aa:bb:cc:dd:ee:ff" (also accepts '-' separators).
    public init?(_ string: String) {
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(6)
        for part in parts {
            guard let value = UInt8(part, radix: 16) else { return nil }
            out.append(value)
        }
        self.bytes = out
    }

    /// ff:ff:ff:ff:ff:ff
    public static let broadcast = MACAddress([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])!

    public var isBroadcast: Bool { bytes.allSatisfy { $0 == 0xFF } }

    /// IEEE 802 group-address bit, covering multicast and broadcast frames.
    public var isMulticast: Bool { bytes.first.map { ($0 & 0x01) != 0 } ?? false }

    public var description: String {
        let digits = Array("0123456789abcdef")
        func hex(_ b: UInt8) -> String {
            String([digits[Int(b >> 4)], digits[Int(b & 0x0F)]])
        }
        return bytes.map(hex).joined(separator: ":")
    }
}
