/// An IPv4 address stored as a host-order 32-bit value.
public struct IPv4Address: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt32

    public init(raw: UInt32) {
        self.raw = raw
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        raw = (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
    }

    /// Parse "a.b.c.d".
    public init?(_ string: String) {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        self.init(octets[0], octets[1], octets[2], octets[3])
    }

    public var octets: (UInt8, UInt8, UInt8, UInt8) {
        (UInt8((raw >> 24) & 0xFF),
         UInt8((raw >> 16) & 0xFF),
         UInt8((raw >> 8) & 0xFF),
         UInt8(raw & 0xFF))
    }

    public var description: String {
        let o = octets
        return "\(o.0).\(o.1).\(o.2).\(o.3)"
    }
}
