/// A mutable byte buffer for packets. Backed by `[UInt8]` for clarity in the
/// skeleton; replace with a pooled / `UnsafeMutableRawBufferPointer`-backed
/// implementation when you optimize the hot path (the goal is to avoid a
/// per-packet heap allocation).
public struct PacketBuffer: Sendable {
    public private(set) var bytes: [UInt8]

    public init(_ bytes: [UInt8] = []) {
        self.bytes = bytes
    }

    init(count: Int) {
        self.bytes = [UInt8](repeating: 0, count: count)
    }

    public var count: Int { bytes.count }

    mutating func reserveCapacity(_ minimumCapacity: Int) {
        bytes.reserveCapacity(minimumCapacity)
    }

    // MARK: - Append (build)

    mutating func append(_ byte: UInt8) { bytes.append(byte) }
    mutating func append(_ slice: [UInt8]) { bytes.append(contentsOf: slice) }
    mutating func append(_ slice: ArraySlice<UInt8>) { bytes.append(contentsOf: slice) }

    mutating func appendUInt16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0x00FF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    // MARK: - Read (parse) — big-endian, bounds-checked (nil on overrun)

    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < bytes.count else { return nil }
        return bytes[offset]
    }

    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    func slice(_ range: Range<Int>) -> ArraySlice<UInt8>? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return nil }
        return bytes[range]
    }
}
