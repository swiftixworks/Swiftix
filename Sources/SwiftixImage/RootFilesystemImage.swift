/// Deterministic, bounded distribution root-filesystem images.
///
/// This target owns only the transport format and the atomic restore seam. The
/// files and distribution policy are produced outside the Swiftix core. All
/// operations are synchronous and must be invoked on the same executor that
/// owns the destination `Kernel`.

import Swiftix
import SwiftixDigest

public struct SwiftixDistributionMetadata: Sendable, Equatable {
    public static let targetOS = "swiftix"
    public static let targetArchitecture = "svm64"

    public let identifier: String
    public let name: String
    public let version: String
    public let minimumSwiftixVersion: String
    public let operatingSystem: String
    public let architecture: String

    public init(
        identifier: String,
        name: String,
        version: String,
        minimumSwiftixVersion: String,
        operatingSystem: String = Self.targetOS,
        architecture: String = Self.targetArchitecture
    ) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.minimumSwiftixVersion = minimumSwiftixVersion
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }

    /// Whether a consumer core can safely restore this distribution. Image
    /// format compatibility and distribution/core compatibility are separate
    /// checks, so callers can inspect metadata before touching a Kernel.
    public func isCompatible(withSwiftixVersion version: String) -> Bool {
        guard let required = SemanticVersion(minimumSwiftixVersion),
            let available = SemanticVersion(version)
        else {
            return false
        }
        return available >= required
    }
}

public struct SwiftixRootFilesystemImage: Sendable, Equatable {
    public let distribution: SwiftixDistributionMetadata
    public let filesystem: FilesystemSnapshot

    public init(
        distribution: SwiftixDistributionMetadata,
        filesystem: FilesystemSnapshot
    ) {
        self.distribution = distribution
        self.filesystem = filesystem
    }
}

public enum SwiftixRootFilesystemImageError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidMagic
    case unsupportedVersion(UInt16)
    case unsupportedTarget(operatingSystem: String, architecture: String)
    case invalidDigest
    case truncated
    case trailingData
    case invalidUTF8
    case invalidMetadata(String)
    case invalidFilesystem
    case resourceLimitExceeded(String)

    public var description: String {
        switch self {
        case .invalidMagic:
            return "not a Swiftix root filesystem image"
        case .unsupportedVersion(let version):
            return "unsupported Swiftix root filesystem image version \(version)"
        case .unsupportedTarget(let operatingSystem, let architecture):
            return "unsupported Swiftix distribution target \(operatingSystem)/\(architecture)"
        case .invalidDigest:
            return "Swiftix root filesystem image digest mismatch"
        case .truncated:
            return "truncated Swiftix root filesystem image"
        case .trailingData:
            return "trailing data in Swiftix root filesystem image"
        case .invalidUTF8:
            return "invalid UTF-8 in Swiftix root filesystem image"
        case .invalidMetadata(let field):
            return "invalid Swiftix distribution metadata field \(field)"
        case .invalidFilesystem:
            return "invalid filesystem snapshot in Swiftix distribution image"
        case .resourceLimitExceeded(let resource):
            return "Swiftix root filesystem image exceeds \(resource) limit"
        }
    }
}

public enum SwiftixRootFilesystemImageCodec {
    public static let formatVersion: UInt16 = 1
    public static let maximumImageBytes = 64 * 1_024 * 1_024
    public static let maximumFileBytes = 16 * 1_024 * 1_024
    public static let maximumFilePayloadBytes = 48 * 1_024 * 1_024
    public static let maximumInodeCount = 16_384
    public static let maximumDirectoryEntryCount = 65_536
    public static let maximumDirectoryDepth = 256

    private static let magic = Array("\u{7f}SWIFTIXROOTFS".utf8)
    private static let digestHexBytes = 64
    private static let maximumMetadataBytes = 256
    private static let maximumEntryNameBytes = 255
    private static let maximumSymlinkBytes = 4_096

    public static func recognizes(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: magic)
    }

    public static func digest(of bytes: [UInt8]) throws -> String {
        _ = try decode(bytes)
        return String(decoding: bytes.suffix(digestHexBytes), as: UTF8.self)
    }

    public static func encode(_ image: SwiftixRootFilesystemImage) throws -> [UInt8] {
        try validateMetadata(image.distribution)
        let records = try validateFilesystem(image.filesystem)

        var writer = RootImageWriter(maximumBytes: maximumImageBytes - digestHexBytes)
        try writer.append(magic)
        try writer.writeUInt16(formatVersion)
        try writer.write(image.distribution.identifier, maximumBytes: maximumMetadataBytes)
        try writer.write(image.distribution.name, maximumBytes: maximumMetadataBytes)
        try writer.write(image.distribution.version, maximumBytes: maximumMetadataBytes)
        try writer.write(
            image.distribution.minimumSwiftixVersion,
            maximumBytes: maximumMetadataBytes)
        try writer.write(image.distribution.operatingSystem, maximumBytes: maximumMetadataBytes)
        try writer.write(image.distribution.architecture, maximumBytes: maximumMetadataBytes)
        try writer.writeUInt64(image.filesystem.rootInodeID ?? 0)
        try writer.writeCount(records.count, maximum: maximumInodeCount)

        for inode in records {
            try writer.writeUInt64(inode.id)
            try writer.writeUInt16(inode.metadata.mode)
            try writer.writeUInt32(inode.metadata.uid)
            try writer.writeUInt32(inode.metadata.gid)
            try writer.writeUInt64(inode.metadata.atime.bitPattern)
            try writer.writeUInt64(inode.metadata.mtime.bitPattern)
            try writer.writeUInt64(inode.metadata.ctime.bitPattern)

            switch inode.contents {
            case .directory(let entries):
                try writer.writeByte(0)
                try writer.writeCount(entries.count, maximum: maximumDirectoryEntryCount)
                for entry in entries {
                    try writer.write(entry.name, maximumBytes: maximumEntryNameBytes)
                    try writer.writeUInt64(entry.inodeID)
                }
            case .file(let bytes):
                try writer.writeByte(1)
                try writer.writeData(bytes, maximumBytes: maximumFileBytes)
            case .symlink(let target):
                try writer.writeByte(2)
                try writer.write(target, maximumBytes: maximumSymlinkBytes)
            case .fifo:
                try writer.writeByte(3)
            }
        }

        let body = writer.bytes
        let digest = Array(SwiftixSHA256.hex(body).utf8)
        guard body.count <= maximumImageBytes - digest.count else {
            throw SwiftixRootFilesystemImageError.resourceLimitExceeded("image byte")
        }
        return body + digest
    }

    public static func decode(_ bytes: [UInt8]) throws -> SwiftixRootFilesystemImage {
        guard bytes.count <= maximumImageBytes else {
            throw SwiftixRootFilesystemImageError.resourceLimitExceeded("image byte")
        }
        guard bytes.count >= magic.count + digestHexBytes else {
            throw SwiftixRootFilesystemImageError.truncated
        }

        let body = Array(bytes.dropLast(digestHexBytes))
        let storedDigestBytes = bytes.suffix(digestHexBytes)
        guard storedDigestBytes.allSatisfy({ $0.isASCIIHexDigit }),
            String(decoding: storedDigestBytes, as: UTF8.self) == SwiftixSHA256.hex(body)
        else {
            throw SwiftixRootFilesystemImageError.invalidDigest
        }

        var reader = RootImageReader(bytes: body)
        guard try reader.readBytes(count: magic.count) == magic else {
            throw SwiftixRootFilesystemImageError.invalidMagic
        }
        let version = try reader.readUInt16()
        guard version == formatVersion else {
            throw SwiftixRootFilesystemImageError.unsupportedVersion(version)
        }

        let metadata = SwiftixDistributionMetadata(
            identifier: try reader.readString(maximumBytes: maximumMetadataBytes),
            name: try reader.readString(maximumBytes: maximumMetadataBytes),
            version: try reader.readString(maximumBytes: maximumMetadataBytes),
            minimumSwiftixVersion: try reader.readString(maximumBytes: maximumMetadataBytes),
            operatingSystem: try reader.readString(maximumBytes: maximumMetadataBytes),
            architecture: try reader.readString(maximumBytes: maximumMetadataBytes))
        try validateMetadata(metadata)

        let rootID = try reader.readUInt64()
        let inodeCount = try reader.readCount(maximum: maximumInodeCount)
        guard inodeCount > 0 else {
            throw SwiftixRootFilesystemImageError.invalidFilesystem
        }

        var inodes: [FilesystemSnapshot.Inode] = []
        inodes.reserveCapacity(inodeCount)
        var decodedDirectoryEntries = 0
        var decodedFileBytes = 0
        for _ in 0..<inodeCount {
            let id = try reader.readUInt64()
            let metadata = FilesystemSnapshot.Metadata(
                mode: try reader.readUInt16(),
                uid: try reader.readUInt32(),
                gid: try reader.readUInt32(),
                atime: Double(bitPattern: try reader.readUInt64()),
                mtime: Double(bitPattern: try reader.readUInt64()),
                ctime: Double(bitPattern: try reader.readUInt64()))
            let tag = try reader.readByte()
            let contents: FilesystemSnapshot.InodeContents
            switch tag {
            case 0:
                let count = try reader.readCount(maximum: maximumDirectoryEntryCount)
                guard count <= maximumDirectoryEntryCount - decodedDirectoryEntries else {
                    throw SwiftixRootFilesystemImageError.resourceLimitExceeded(
                        "directory entry")
                }
                decodedDirectoryEntries += count
                var entries: [FilesystemSnapshot.DirectoryEntry] = []
                entries.reserveCapacity(count)
                for _ in 0..<count {
                    entries.append(
                        .init(
                            name: try reader.readString(maximumBytes: maximumEntryNameBytes),
                            inodeID: try reader.readUInt64()))
                }
                contents = .directory(entries: entries)
            case 1:
                let data = try reader.readData(maximumBytes: maximumFileBytes)
                guard data.count <= maximumFilePayloadBytes - decodedFileBytes else {
                    throw SwiftixRootFilesystemImageError.resourceLimitExceeded(
                        "file payload byte")
                }
                decodedFileBytes += data.count
                contents = .file(bytes: data)
            case 2:
                contents = .symlink(
                    target: try reader.readString(maximumBytes: maximumSymlinkBytes))
            case 3:
                contents = .fifo
            default:
                throw SwiftixRootFilesystemImageError.invalidFilesystem
            }
            inodes.append(.init(id: id, metadata: metadata, contents: contents))
        }
        guard reader.isAtEnd else {
            throw SwiftixRootFilesystemImageError.trailingData
        }

        let root = try projectedRoot(rootID: rootID, inodes: inodes)
        let snapshot = FilesystemSnapshot(
            root: root,
            formatVersion: FilesystemSnapshot.currentFormatVersion,
            rootInodeID: rootID,
            inodes: inodes)
        _ = try validateFilesystem(snapshot)
        return SwiftixRootFilesystemImage(distribution: metadata, filesystem: snapshot)
    }

    private static func validateMetadata(_ metadata: SwiftixDistributionMetadata) throws {
        let fields = [
            ("identifier", metadata.identifier),
            ("name", metadata.name),
            ("version", metadata.version),
            ("minimumSwiftixVersion", metadata.minimumSwiftixVersion),
        ]
        for (field, value) in fields {
            let bytes = Array(value.utf8)
            guard !value.isEmpty,
                bytes.count <= maximumMetadataBytes,
                !value.contains("\0"),
                value.unicodeScalars.allSatisfy({ scalar in
                    scalar.value >= 0x20 && scalar.value != 0x7F
                })
            else {
                throw SwiftixRootFilesystemImageError.invalidMetadata(field)
            }
        }
        guard
            metadata.identifier.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
            })
        else {
            throw SwiftixRootFilesystemImageError.invalidMetadata("identifier")
        }
        guard SemanticVersion(metadata.minimumSwiftixVersion) != nil else {
            throw SwiftixRootFilesystemImageError.invalidMetadata(
                "minimumSwiftixVersion")
        }
        guard metadata.operatingSystem == SwiftixDistributionMetadata.targetOS,
            metadata.architecture == SwiftixDistributionMetadata.targetArchitecture
        else {
            throw SwiftixRootFilesystemImageError.unsupportedTarget(
                operatingSystem: metadata.operatingSystem,
                architecture: metadata.architecture)
        }
    }

    private static func validateFilesystem(
        _ snapshot: FilesystemSnapshot
    ) throws -> [FilesystemSnapshot.Inode] {
        guard snapshot.formatVersion == FilesystemSnapshot.currentFormatVersion,
            let rootID = snapshot.rootInodeID,
            let inodes = snapshot.inodes,
            !inodes.isEmpty,
            inodes.count <= maximumInodeCount
        else {
            throw SwiftixRootFilesystemImageError.invalidFilesystem
        }

        let records = try recordsByID(inodes)
        guard records[rootID] != nil else {
            throw SwiftixRootFilesystemImageError.invalidFilesystem
        }
        guard snapshot.isValid else {
            throw SwiftixRootFilesystemImageError.invalidFilesystem
        }

        var totalFileBytes = 0
        var totalDirectoryEntries = 0
        for inode in inodes {
            switch inode.contents {
            case .directory(let entries):
                guard entries.count <= maximumDirectoryEntryCount - totalDirectoryEntries
                else {
                    throw SwiftixRootFilesystemImageError.resourceLimitExceeded(
                        "directory entry")
                }
                totalDirectoryEntries += entries.count
                for entry in entries where entry.name.utf8.count > maximumEntryNameBytes {
                    throw SwiftixRootFilesystemImageError.resourceLimitExceeded(
                        "directory entry name byte")
                }
            case .file(let bytes):
                guard bytes.count <= maximumFileBytes else {
                    throw SwiftixRootFilesystemImageError.resourceLimitExceeded(
                        "single file byte")
                }
                guard bytes.count <= maximumFilePayloadBytes - totalFileBytes else {
                    throw SwiftixRootFilesystemImageError.resourceLimitExceeded(
                        "file payload byte")
                }
                totalFileBytes += bytes.count
            case .symlink(let target):
                guard target.utf8.count <= maximumSymlinkBytes,
                    !target.contains("\0")
                else {
                    throw SwiftixRootFilesystemImageError.invalidFilesystem
                }
            case .fifo:
                break
            }
        }

        var visitedDirectories = Set<UInt64>()
        var stack: [(id: UInt64, depth: Int)] = [(rootID, 0)]
        while let item = stack.popLast() {
            guard item.depth <= maximumDirectoryDepth,
                let inode = records[item.id]
            else {
                throw SwiftixRootFilesystemImageError.resourceLimitExceeded("directory depth")
            }
            switch inode.contents {
            case .directory(let entries):
                guard visitedDirectories.insert(item.id).inserted else {
                    throw SwiftixRootFilesystemImageError.invalidFilesystem
                }
                for entry in entries {
                    guard let child = records[entry.inodeID]
                    else {
                        throw SwiftixRootFilesystemImageError.invalidFilesystem
                    }
                    if case .directory = child.contents {
                        stack.append((entry.inodeID, item.depth + 1))
                    }
                }
            case .file, .symlink, .fifo:
                break
            }
        }
        return inodes
    }

    private static func projectedRoot(
        rootID: UInt64,
        inodes: [FilesystemSnapshot.Inode]
    ) throws -> FilesystemSnapshot.Node {
        let records = try recordsByID(inodes)
        func project(_ id: UInt64, depth: Int) throws -> FilesystemSnapshot.Node {
            guard depth <= maximumDirectoryDepth,
                let inode = records[id]
            else {
                throw SwiftixRootFilesystemImageError.invalidFilesystem
            }
            switch inode.contents {
            case .directory(let entries):
                var children: [String: FilesystemSnapshot.Node] = [:]
                for entry in entries {
                    guard children[entry.name] == nil else {
                        throw SwiftixRootFilesystemImageError.invalidFilesystem
                    }
                    children[entry.name] = try project(entry.inodeID, depth: depth + 1)
                }
                return .directory(children: children)
            case .file(let bytes):
                return .file(bytes: bytes)
            case .symlink(let target):
                return .symlink(target: target)
            case .fifo:
                return .fifo
            }
        }
        return try project(rootID, depth: 0)
    }

    private static func recordsByID(
        _ inodes: [FilesystemSnapshot.Inode]
    ) throws -> [UInt64: FilesystemSnapshot.Inode] {
        var records: [UInt64: FilesystemSnapshot.Inode] = [:]
        records.reserveCapacity(inodes.count)
        for inode in inodes {
            guard inode.id != 0, records.updateValue(inode, forKey: inode.id) == nil else {
                throw SwiftixRootFilesystemImageError.invalidFilesystem
            }
        }
        return records
    }
}

public extension Kernel {
    /// Atomically replace the VFS with a validated distribution image. Existing
    /// VM snapshots should be restored directly and take precedence over this
    /// first-boot template.
    @discardableResult
    func restoreRootFilesystemImage(_ image: SwiftixRootFilesystemImage) -> Bool {
        guard image.distribution.isCompatible(withSwiftixVersion: Swiftix.version) else {
            return false
        }
        return restoreFileSystem(image.filesystem)
    }
}

private struct SemanticVersion: Comparable {
    private enum Identifier: Equatable {
        case numeric(String)
        case text(String)
    }

    private let major: String
    private let minor: String
    private let patch: String
    private let prerelease: [Identifier]?

    init?(_ value: String) {
        let buildParts = value.split(
            separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildParts.count <= 2,
            buildParts.count == 1 || Self.validIdentifiers(buildParts[1])
        else {
            return nil
        }

        let releaseParts = buildParts[0].split(
            separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = releaseParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
            let major = Self.coreNumber(core[0]),
            let minor = Self.coreNumber(core[1]),
            let patch = Self.coreNumber(core[2])
        else {
            return nil
        }

        var prerelease: [Identifier]?
        if releaseParts.count == 2 {
            let parts = releaseParts[1].split(
                separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return nil }
            var parsed: [Identifier] = []
            parsed.reserveCapacity(parts.count)
            for part in parts {
                guard Self.validIdentifier(part) else { return nil }
                if part.allSatisfy({ $0.isNumber }) {
                    guard part.count == 1 || part.first != "0" else {
                        return nil
                    }
                    parsed.append(.numeric(String(part)))
                } else {
                    parsed.append(.text(String(part)))
                }
            }
            prerelease = parsed
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return numericLess(lhs.major, rhs.major) }
        if lhs.minor != rhs.minor { return numericLess(lhs.minor, rhs.minor) }
        if lhs.patch != rhs.patch { return numericLess(lhs.patch, rhs.patch) }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, _):
            return false
        case (_, nil):
            return true
        case (.some(let lhsIdentifiers), .some(let rhsIdentifiers)):
            for (left, right) in zip(lhsIdentifiers, rhsIdentifiers) {
                if left == right { continue }
                switch (left, right) {
                case (.numeric(let lhsNumber), .numeric(let rhsNumber)):
                    return numericLess(lhsNumber, rhsNumber)
                case (.numeric, .text):
                    return true
                case (.text, .numeric):
                    return false
                case (.text(let lhsText), .text(let rhsText)):
                    return lhsText < rhsText
                }
            }
            return lhsIdentifiers.count < rhsIdentifiers.count
        }
    }

    private static func coreNumber(_ value: Substring) -> String? {
        guard !value.isEmpty,
            value.allSatisfy({ $0.isASCII && $0.isNumber }),
            value.count == 1 || value.first != "0"
        else {
            return nil
        }
        return String(value)
    }

    private static func numericLess(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.count != rhs.count { return lhs.count < rhs.count }
        return lhs < rhs
    }

    private static func validIdentifiers(_ value: Substring) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        return !identifiers.isEmpty && identifiers.allSatisfy(validIdentifier)
    }

    private static func validIdentifier(_ value: Substring) -> Bool {
        !value.isEmpty
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
            }
    }
}

private struct RootImageWriter {
    let maximumBytes: Int
    private(set) var bytes: [UInt8] = []

    mutating func append(_ appended: [UInt8]) throws {
        guard appended.count <= maximumBytes - bytes.count else {
            throw SwiftixRootFilesystemImageError.resourceLimitExceeded("image byte")
        }
        bytes.append(contentsOf: appended)
    }

    mutating func writeByte(_ value: UInt8) throws {
        try append([value])
    }

    mutating func writeUInt16(_ value: UInt16) throws {
        try append([
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
        ])
    }

    mutating func writeUInt32(_ value: UInt32) throws {
        try append(
            (0..<4).map { shift in
                UInt8(truncatingIfNeeded: value >> UInt32(shift * 8))
            })
    }

    mutating func writeUInt64(_ value: UInt64) throws {
        try append(
            (0..<8).map { shift in
                UInt8(truncatingIfNeeded: value >> UInt64(shift * 8))
            })
    }

    mutating func writeCount(_ value: Int, maximum: Int) throws {
        guard value >= 0, value <= maximum, value <= Int(UInt32.max) else {
            throw SwiftixRootFilesystemImageError.resourceLimitExceeded("count")
        }
        try writeUInt32(UInt32(value))
    }

    mutating func write(_ value: String, maximumBytes: Int) throws {
        let encoded = Array(value.utf8)
        try writeData(encoded, maximumBytes: maximumBytes)
    }

    mutating func writeData(_ data: [UInt8], maximumBytes: Int) throws {
        guard data.count <= maximumBytes else {
            throw SwiftixRootFilesystemImageError.resourceLimitExceeded("field byte")
        }
        try writeCount(data.count, maximum: maximumBytes)
        try append(data)
    }
}

private struct RootImageReader {
    let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw SwiftixRootFilesystemImageError.truncated
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, count <= bytes.count - offset else {
            throw SwiftixRootFilesystemImageError.truncated
        }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func readUInt16() throws -> UInt16 {
        let raw = try readBytes(count: 2)
        return UInt16(raw[0]) | UInt16(raw[1]) << 8
    }

    mutating func readUInt32() throws -> UInt32 {
        let raw = try readBytes(count: 4)
        return raw.enumerated().reduce(0) { result, item in
            result | UInt32(item.element) << UInt32(item.offset * 8)
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        let raw = try readBytes(count: 8)
        return raw.enumerated().reduce(0) { result, item in
            result | UInt64(item.element) << UInt64(item.offset * 8)
        }
    }

    mutating func readCount(maximum: Int) throws -> Int {
        let value = Int(try readUInt32())
        guard value <= maximum else {
            throw SwiftixRootFilesystemImageError.resourceLimitExceeded("count")
        }
        return value
    }

    mutating func readData(maximumBytes: Int) throws -> [UInt8] {
        try readBytes(count: readCount(maximum: maximumBytes))
    }

    mutating func readString(maximumBytes: Int) throws -> String {
        let data = try readData(maximumBytes: maximumBytes)
        let value = String(decoding: data, as: UTF8.self)
        guard Array(value.utf8) == data else {
            throw SwiftixRootFilesystemImageError.invalidUTF8
        }
        return value
    }
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (48...57).contains(self) || (97...102).contains(self)
    }
}
