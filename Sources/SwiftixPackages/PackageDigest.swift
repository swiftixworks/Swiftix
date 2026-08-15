import SwiftixDigest

/// Content addressing for packages, backed by the shared Foundation-free
/// Swiftix SHA-256 primitive.
public struct PackageDigest: Sendable {
    private var digest = SwiftixSHA256()

    public init() {}

    public static func hex(_ bytes: [UInt8]) -> String {
        SwiftixSHA256.hex(bytes)
    }

    public static func verify(_ bytes: [UInt8], expected: String) -> Bool {
        SwiftixSHA256.verify(bytes, expected: expected)
    }

    public mutating func update(_ bytes: [UInt8]) {
        digest.update(bytes)
    }

    public mutating func finalizeHex() -> String {
        digest.finalizeHex()
    }
}
