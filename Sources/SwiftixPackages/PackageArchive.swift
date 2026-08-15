/// The `.pkg` container: a package's metadata, its file table, and its payload.
///
/// Format (v2) — an ASCII header, a byte marker, then raw payload:
///
///     !<swiftix-pkg>2
///     Package: hello
///     Version: 1.2.0
///     Depends: libgreet (>= 1.0)
///     Entry: dir 0755 - - /usr/share/hello
///     Entry: file 0755 14 <sha256> /bin/hello
///     Payload: 14
///     %%
///     <raw bytes of every file entry, in table order>
///
/// Why not tar or zip: both would drag a compression implementation (and its
/// bug surface) into a target that is meant to be auditable, and neither adds
/// anything here — the VFS stores bytes, not blocks. A readable header keeps the
/// format inspectable with `head`, while the payload stays byte-exact.
///
/// The path field comes last on an `Entry` line, so a file path may contain
/// spaces without an escaping scheme. Every entry carries its own SHA-256, so a
/// truncated or tampered payload is caught per file rather than only in
/// aggregate.

public struct PackageArchive: Sendable {

    /// One installable object. Directories exist as explicit entries so a package
    /// can own (and, on removal, clean up) a directory it created even when the
    /// directory holds no files of its own.
    public struct Entry: Sendable, Hashable {

        public enum Kind: String, Sendable, Hashable {
            case file
            case directory = "dir"
        }

        public let kind: Kind
        /// Normalized absolute install path.
        public let path: String
        public let mode: UInt16
        /// Payload byte count (always 0 for a directory).
        public let size: Int
        /// Lowercase hex SHA-256 of the file's bytes ("" for a directory).
        public let digest: String

        public init(kind: Kind, path: String, mode: UInt16, size: Int, digest: String) {
            self.kind = kind
            self.path = path
            self.mode = mode
            self.size = size
            self.digest = digest
        }
    }

    public let manifest: PackageManifest
    public let entries: [Entry]
    public let payload: [UInt8]

    /// Payload offset of each entry, parallel to `entries` (directories reuse the
    /// running offset). Precomputed so `contents(of:)` is a slice, not a scan.
    private let offsets: [Int]

    private static let magic = "!<swiftix-pkg>\(SwiftixPackages.formatVersion)"
    private static let payloadMarker = "%%"

    private init(manifest: PackageManifest, entries: [Entry], payload: [UInt8]) {
        self.manifest = manifest
        self.entries = entries
        self.payload = payload
        var offsets: [Int] = []
        var running = 0
        offsets.reserveCapacity(entries.count)
        for entry in entries {
            offsets.append(running)
            running += entry.size
        }
        self.offsets = offsets
    }

    /// Files in table order — what the installer writes.
    public var files: [Entry] { entries.filter { $0.kind == .file } }

    /// Directories in table order (shallowest first, guaranteed by `build`).
    public var directories: [Entry] { entries.filter { $0.kind == .directory } }

    /// Total installed byte count, as reported by `pkg info`.
    public var installedSize: Int { files.reduce(0) { $0 + $1.size } }

    /// Bytes of one entry. Verified against the entry digest on decode, so this
    /// is a plain slice.
    public func contents(of entry: Entry) -> [UInt8] {
        guard let index = entries.firstIndex(of: entry), entry.kind == .file else { return [] }
        let start = offsets[index]
        return Array(payload[start..<(start + entry.size)])
    }

    // MARK: - Building

    /// Assemble an archive from in-memory content. Entry order is normalized
    /// (directories shallowest-first, then files by path) so packing the same
    /// input twice produces byte-identical output — a property the tests and any
    /// future signing scheme both rely on.
    public static func build(
        manifest: PackageManifest,
        files: [(path: String, mode: UInt16, bytes: [UInt8])],
        directories: [String] = []
    ) throws -> PackageArchive {
        var normalizedDirectories: [String] = []
        for directory in directories {
            normalizedDirectories.append(try PackagePath.validateInstallTarget(directory))
        }
        var seen = Set<String>()
        var fileEntries: [(entry: Entry, bytes: [UInt8])] = []
        for file in files {
            let path = try PackagePath.validateInstallTarget(file.path)
            guard file.bytes.count <= PackageLimits.maximumEntryBytes else {
                throw PackageError.malformedArchive(
                    reason: "\(path) exceeds \(PackageLimits.maximumEntryBytes) bytes")
            }
            guard seen.insert(path).inserted else {
                throw PackageError.malformedArchive(reason: "duplicate entry \(path)")
            }
            fileEntries.append(
                (
                    Entry(
                        kind: .file,
                        path: path,
                        mode: file.mode & 0o7777,
                        size: file.bytes.count,
                        digest: PackageDigest.hex(file.bytes)),
                    file.bytes
                ))
        }

        // Implicit parents: a package that ships /usr/share/doc/x/README owns the
        // directories leading to it, so removal can prune what it created.
        var directorySet = Set(normalizedDirectories)
        for entry in fileEntries {
            for ancestor in PackagePath.ancestors(of: PackagePath.parent(of: entry.entry.path)) {
                if PackagePath.isInstallable(ancestor) { directorySet.insert(ancestor) }
            }
        }
        let directoryEntries = directorySet.sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            return leftDepth == rightDepth ? $0 < $1 : leftDepth < rightDepth
        }.map { Entry(kind: .directory, path: $0, mode: 0o755, size: 0, digest: "") }

        fileEntries.sort { $0.entry.path < $1.entry.path }
        let entries = directoryEntries + fileEntries.map(\.entry)
        guard entries.count <= PackageLimits.maximumEntryCount else {
            throw PackageError.malformedArchive(
                reason: "archive holds \(entries.count) entries, limit is \(PackageLimits.maximumEntryCount)")
        }
        let payload = fileEntries.flatMap(\.bytes)
        return PackageArchive(manifest: manifest, entries: entries, payload: payload)
    }

    /// Serialize to the on-disk form.
    public func encoded() -> [UInt8] {
        var header = Self.magic + "\n"
        header += manifest.encoded().rendered()
        for entry in entries {
            let size = entry.kind == .file ? "\(entry.size)" : "-"
            let digest = entry.kind == .file ? entry.digest : "-"
            header += "Entry: \(entry.kind.rawValue) \(PackageText.octal(entry.mode)) \(size) \(digest) \(entry.path)\n"
        }
        header += "Payload: \(payload.count)\n"
        header += Self.payloadMarker + "\n"
        return Array(header.utf8) + payload
    }

    // MARK: - Decoding

    /// Parse and fully verify an archive: header shape, entry table, declared
    /// payload length, and every per-file digest. A decoded `PackageArchive` is
    /// therefore safe to hand to the installer without further checks.
    public static func decode(_ bytes: [UInt8]) throws -> PackageArchive {
        guard bytes.count <= PackageLimits.maximumArchiveBytes else {
            throw PackageError.malformedArchive(
                reason: "archive exceeds \(PackageLimits.maximumArchiveBytes) bytes")
        }
        guard let split = payloadStart(in: bytes) else {
            throw PackageError.malformedArchive(reason: "missing '\(payloadMarker)' payload marker")
        }
        let headerText = String(decoding: bytes[0..<split.headerEnd], as: UTF8.self)
        var lines = headerText.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, PackageText.trim(String(first)) == magic else {
            throw PackageError.unsupportedFormat(
                found: String(lines.first ?? "").isEmpty ? "<empty>" : String(lines.first!),
                expected: magic)
        }
        lines.removeFirst()

        var stanzaLines: [String] = []
        var entryLines: [String] = []
        var declaredPayload: Int?
        for rawLine in lines {
            let original = String(rawLine)
            let line = PackageText.trim(original)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("Entry:") {
                entryLines.append(PackageText.trim(String(line.dropFirst("Entry:".count))))
            } else if line.hasPrefix("Payload:") {
                guard let value = Int(PackageText.trim(String(line.dropFirst("Payload:".count)))),
                    value >= 0
                else {
                    throw PackageError.malformedArchive(reason: "invalid Payload length")
                }
                declaredPayload = value
            } else {
                // Preserve leading whitespace for Debian control-field
                // continuation lines (notably the long Description).
                stanzaLines.append(original)
            }
        }

        let stanzas = try PackageStanza.parse(stanzaLines.joined(separator: "\n"))
        guard let stanza = stanzas.first, stanzas.count == 1 else {
            throw PackageError.malformedArchive(reason: "expected exactly one metadata stanza")
        }
        let manifest = try PackageManifest.decode(stanza, context: "archive")

        var entries: [Entry] = []
        var seen = Set<String>()
        for line in entryLines {
            let entry = try decodeEntry(line)
            guard seen.insert(entry.path).inserted else {
                throw PackageError.malformedArchive(reason: "duplicate entry \(entry.path)")
            }
            entries.append(entry)
        }
        guard entries.count <= PackageLimits.maximumEntryCount else {
            throw PackageError.malformedArchive(
                reason: "archive holds \(entries.count) entries, limit is \(PackageLimits.maximumEntryCount)")
        }

        let payload = Array(bytes[split.payloadStart...])
        let expected = entries.reduce(0) { $0 + $1.size }
        guard let declaredPayload else {
            throw PackageError.malformedArchive(reason: "missing Payload length")
        }
        guard declaredPayload == payload.count else {
            throw PackageError.sizeMismatch(path: "payload", expected: declaredPayload, actual: payload.count)
        }
        guard expected == payload.count else {
            throw PackageError.sizeMismatch(path: "payload", expected: expected, actual: payload.count)
        }

        let archive = PackageArchive(manifest: manifest, entries: entries, payload: payload)
        for entry in archive.files {
            let actual = PackageDigest.hex(archive.contents(of: entry))
            guard actual == entry.digest else {
                throw PackageError.digestMismatch(
                    path: entry.path,
                    expected: entry.digest,
                    actual: actual)
            }
        }
        return archive
    }

    private static func decodeEntry(_ line: String) throws -> Entry {
        // `<kind> <mode> <size> <digest> <path…>` — the path is whatever remains,
        // so spaces in a path need no escaping.
        var remainder = Substring(line)
        func nextField() -> String? {
            remainder = remainder.drop(while: { $0 == " " || $0 == "\t" })
            guard !remainder.isEmpty else { return nil }
            guard let space = remainder.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                let value = String(remainder)
                remainder = Substring("")
                return value
            }
            let value = String(remainder[remainder.startIndex..<space])
            remainder = remainder[space...]
            return value
        }

        guard let kindText = nextField(), let kind = Entry.Kind(rawValue: kindText),
            let modeText = nextField(), let mode = PackageText.parseOctal(modeText),
            let sizeText = nextField(),
            let digestText = nextField()
        else {
            throw PackageError.malformedArchive(reason: "malformed Entry line '\(line)'")
        }
        let pathText = PackageText.trim(String(remainder))
        guard !pathText.isEmpty else {
            throw PackageError.malformedArchive(reason: "Entry line without a path: '\(line)'")
        }
        let path = try PackagePath.validateInstallTarget(pathText)

        switch kind {
        case .directory:
            guard sizeText == "-" || sizeText == "0" else {
                throw PackageError.malformedArchive(reason: "directory \(path) declares a size")
            }
            return Entry(kind: .directory, path: path, mode: mode, size: 0, digest: "")
        case .file:
            guard let size = Int(sizeText), size >= 0, size <= PackageLimits.maximumEntryBytes else {
                throw PackageError.malformedArchive(reason: "invalid size for \(path)")
            }
            let digest = digestText.lowercased()
            guard digest.count == 64,
                digest.allSatisfy({ $0.isHexDigit && $0.isASCII })
            else {
                throw PackageError.malformedArchive(reason: "invalid digest for \(path)")
            }
            return Entry(kind: .file, path: path, mode: mode, size: size, digest: digest)
        }
    }

    /// Locate the payload marker line, returning the header end (exclusive) and
    /// the first payload byte.
    private static func payloadStart(in bytes: [UInt8]) -> (headerEnd: Int, payloadStart: Int)? {
        let needle = Array(("\n" + payloadMarker + "\n").utf8)
        guard bytes.count >= needle.count else { return nil }
        for start in 0...(bytes.count - needle.count)
        where Array(bytes[start..<(start + needle.count)]) == needle {
            return (start, start + needle.count)
        }
        return nil
    }
}
