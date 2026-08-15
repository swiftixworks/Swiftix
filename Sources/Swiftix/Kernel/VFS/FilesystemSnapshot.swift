/// A serializable, point-in-time image of the VFS tree — the persistence seam
/// between the (Foundation-free) core and a consumer that wants files to survive
/// across launches.
///
/// Format v2 adds an inode table to the original path tree. The table preserves
/// ownership, mode, timestamps, and hard-link identity; `root` remains present
/// as a compatibility projection so archives written by older Swiftix releases
/// still decode and older consumers can ignore the additive v2 keys.
///
/// Only real (tmpfs) content is captured. Synthetic files and device nodes are
/// re-created by the kernel after restore and are never persisted.
public struct FilesystemSnapshot: Sendable, Codable, Equatable {

    /// One node in the legacy path-tree projection.
    public indirect enum Node: Sendable, Codable, Equatable {
        case directory(children: [String: Node])
        case file(bytes: [UInt8])
        case symlink(target: String)
        case fifo
    }

    /// Persisted inode metadata. `mode` is the raw value of `FileMode`; storing
    /// the integer keeps this value independently Codable without widening the
    /// core's public conformance surface.
    public struct Metadata: Sendable, Codable, Equatable {
        public var mode: UInt16
        public var uid: UInt32
        public var gid: UInt32
        public var atime: Double
        public var mtime: Double
        public var ctime: Double

        public init(mode: UInt16,
                    uid: UInt32,
                    gid: UInt32,
                    atime: Double,
                    mtime: Double,
                    ctime: Double) {
            self.mode = mode
            self.uid = uid
            self.gid = gid
            self.atime = atime
            self.mtime = mtime
            self.ctime = ctime
        }
    }

    /// One named directory entry referring to an inode record. Multiple entries
    /// may refer to the same non-directory inode, which represents a hard link.
    public struct DirectoryEntry: Sendable, Codable, Equatable {
        public var name: String
        public var inodeID: UInt64

        public init(name: String, inodeID: UInt64) {
            self.name = name
            self.inodeID = inodeID
        }
    }

    /// Type-specific inode payload. Directory entries are stored as a sorted
    /// array so captures are canonical and snapshot→restore→snapshot is stable.
    public enum InodeContents: Sendable, Codable, Equatable {
        case directory(entries: [DirectoryEntry])
        case file(bytes: [UInt8])
        case symlink(target: String)
        case fifo
    }

    /// One inode in format v2.
    public struct Inode: Sendable, Codable, Equatable {
        public var id: UInt64
        public var metadata: Metadata
        public var contents: InodeContents

        public init(id: UInt64, metadata: Metadata, contents: InodeContents) {
            self.id = id
            self.metadata = metadata
            self.contents = contents
        }
    }

    /// Current inode-table format. Optional on the value so root-only legacy
    /// archives decode without migration.
    public static let currentFormatVersion = 2

    /// The root directory ("/") in the legacy/source-compatible projection.
    public var root: Node

    /// Additive v2 fields. They are either all absent (legacy) or all present.
    public var formatVersion: Int?
    public var rootInodeID: UInt64?
    public var inodes: [Inode]?

    /// Builds a legacy snapshot by default. Supplying all three v2 arguments is
    /// useful to persistence layers and tests that construct an inode image.
    public init(root: Node,
                formatVersion: Int? = nil,
                rootInodeID: UInt64? = nil,
                inodes: [Inode]? = nil) {
        self.root = root
        self.formatVersion = formatVersion
        self.rootInodeID = rootInodeID
        self.inodes = inodes
    }

    /// Non-mutating preflight for consumers. It verifies the complete graph,
    /// canonical ordering, names, references, reachability, directory acyclicity,
    /// finite timestamps, and agreement between the v2 graph and legacy tree.
    public var isValid: Bool {
        validatedRepresentation != nil
    }
}

// MARK: - Validation

private struct ValidatedFilesystemSnapshot {
    enum Storage {
        case legacy(FilesystemSnapshot.Node)
        case inodeTable(rootID: UInt64,
                        records: [UInt64: FilesystemSnapshot.Inode],
                        incomingLinks: [UInt64: Int])
    }

    let storage: Storage
}

fileprivate extension FilesystemSnapshot {
    var validatedRepresentation: ValidatedFilesystemSnapshot? {
        let hasV2Field = formatVersion != nil || rootInodeID != nil || inodes != nil
        guard hasV2Field else {
            guard Self.validateLegacyRoot(root) else { return nil }
            return ValidatedFilesystemSnapshot(storage: .legacy(root))
        }

        guard formatVersion == Self.currentFormatVersion,
              let rootID = rootInodeID,
              let inodes,
              rootID != 0,
              !inodes.isEmpty else { return nil }

        let ids = inodes.map(\.id)
        guard ids == ids.sorted(), !ids.contains(0), Set(ids).count == ids.count else {
            return nil
        }

        let records = Dictionary(uniqueKeysWithValues: inodes.map { ($0.id, $0) })
        guard case .directory = records[rootID]?.contents else { return nil }

        var incomingLinks = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        for inode in inodes {
            guard inode.metadata.atime.isFinite,
                  inode.metadata.mtime.isFinite,
                  inode.metadata.ctime.isFinite else { return nil }

            guard case let .directory(entries) = inode.contents else { continue }
            let names = entries.map(\.name)
            guard names == names.sorted(), Set(names).count == names.count else { return nil }
            for entry in entries {
                guard Self.isValidEntryName(entry.name), records[entry.inodeID] != nil else {
                    return nil
                }
                incomingLinks[entry.inodeID, default: 0] += 1
            }
        }

        guard incomingLinks[rootID] == 0 else { return nil }
        for inode in inodes where inode.id != rootID {
            let count = incomingLinks[inode.id] ?? 0
            switch inode.contents {
            case .directory:
                // Directory hard links are unsupported by the VFS because they
                // make parentage/cycle semantics ambiguous.
                guard count == 1 else { return nil }
            case .file, .symlink, .fifo:
                guard count > 0 else { return nil }
            }
        }

        var reachable = Set<UInt64>()
        var visitingDirectories = Set<UInt64>()
        func visit(_ id: UInt64) -> Bool {
            guard let inode = records[id] else { return false }
            if reachable.contains(id) {
                if case .directory = inode.contents {
                    return !visitingDirectories.contains(id)
                }
                return true
            }

            // Captures assign IDs in sorted depth-first first-visit order. Enforce
            // that canonical numbering so every accepted v2 image re-captures to
            // an exactly equal value after restore.
            guard id == UInt64(reachable.count + 1) else { return false }
            reachable.insert(id)
            guard case let .directory(entries) = inode.contents else { return true }
            guard visitingDirectories.insert(id).inserted else { return false }
            for entry in entries where !visit(entry.inodeID) { return false }
            visitingDirectories.remove(id)
            return true
        }

        guard visit(rootID), reachable.count == records.count,
              let projectedRoot = Self.project(rootID, records: records),
              projectedRoot == root else { return nil }

        return ValidatedFilesystemSnapshot(storage: .inodeTable(
            rootID: rootID,
            records: records,
            incomingLinks: incomingLinks))
    }

    static func validateLegacyRoot(_ root: Node) -> Bool {
        guard case let .directory(children) = root else { return false }
        return validateLegacyChildren(children)
    }

    static func validateLegacyChildren(_ children: [String: Node]) -> Bool {
        for (name, node) in children {
            guard isValidEntryName(name) else { return false }
            if case let .directory(descendants) = node,
               !validateLegacyChildren(descendants) { return false }
        }
        return true
    }

    static func isValidEntryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    static func project(_ id: UInt64, records: [UInt64: Inode]) -> Node? {
        guard let inode = records[id] else { return nil }
        switch inode.contents {
        case let .directory(entries):
            var children: [String: Node] = [:]
            for entry in entries {
                guard let child = project(entry.inodeID, records: records) else { return nil }
                children[entry.name] = child
            }
            return .directory(children: children)
        case let .file(bytes):
            return .file(bytes: bytes)
        case let .symlink(target):
            return .symlink(target: target)
        case .fifo:
            return .fifo
        }
    }
}

// MARK: - Capture and atomic restore

extension VirtualFileSystem {

    /// Capture a canonical v2 inode table plus the legacy path projection.
    func snapshot() -> FilesystemSnapshot {
        var inodeIDs: [ObjectIdentifier: UInt64] = [:]
        var records: [UInt64: FilesystemSnapshot.Inode] = [:]
        var nextID: UInt64 = 1

        func capture(_ node: VNode) -> UInt64 {
            let identity = ObjectIdentifier(node)
            if let existing = inodeIDs[identity] { return existing }

            let id = nextID
            nextID += 1
            inodeIDs[identity] = id

            let contents: FilesystemSnapshot.InodeContents
            switch node.kind {
            case .directory:
                var entries: [FilesystemSnapshot.DirectoryEntry] = []
                for name in node.children.keys.sorted() {
                    guard let child = node.children[name], shouldPersist(child) else { continue }
                    entries.append(.init(name: name, inodeID: capture(child)))
                }
                contents = .directory(entries: entries)
            case .file:
                contents = .file(bytes: node.fileContents)
            case .symlink:
                contents = .symlink(target: node.linkTarget)
            case .fifo:
                contents = .fifo
            }

            let metadata = FilesystemSnapshot.Metadata(
                mode: node.mode.rawValue,
                uid: node.uid,
                gid: node.gid,
                atime: node.atime,
                mtime: node.mtime,
                ctime: node.ctime)
            records[id] = .init(id: id, metadata: metadata, contents: contents)
            return id
        }

        let rootID = capture(root)
        let orderedRecords = records.keys.sorted().compactMap { records[$0] }
        let legacyRoot = FilesystemSnapshot.project(rootID, records: records)
            ?? .directory(children: [:])
        return FilesystemSnapshot(root: legacyRoot,
                                  formatVersion: FilesystemSnapshot.currentFormatVersion,
                                  rootInodeID: rootID,
                                  inodes: orderedRecords)
    }

    private func shouldPersist(_ node: VNode) -> Bool {
        !(node.kind == .file && (node.provider != nil || node.deviceKind != nil))
    }

    /// Validate and build a detached candidate tree before changing the live VFS.
    /// The final root-state adoption is the only mutation, so any malformed image
    /// returns `false` with the previous tree byte-for-byte and metadata-identical.
    @discardableResult
    func restore(_ snapshot: FilesystemSnapshot) -> Bool {
        guard let validated = snapshot.validatedRepresentation,
              let candidate = buildCandidate(from: validated) else { return false }
        root.adoptRestoredDirectoryState(from: candidate)
        return true
    }

    /// Synthetic mount creation may update the timestamps of persisted mountpoint
    /// directories. Reapply only v2 metadata after those nodes are mounted so a
    /// later capture is structurally identical to the image that was restored.
    func reapplyPersistedMetadata(from snapshot: FilesystemSnapshot) {
        guard let validated = snapshot.validatedRepresentation,
              case let .inodeTable(rootID, records, _) = validated.storage else { return }

        var visited = Set<ObjectIdentifier>()
        func apply(_ id: UInt64, to node: VNode) {
            guard let record = records[id] else { return }
            let identity = ObjectIdentifier(node)
            if visited.insert(identity).inserted {
                node.mode = FileMode(rawValue: record.metadata.mode)
                node.uid = record.metadata.uid
                node.gid = record.metadata.gid
                node.atime = record.metadata.atime
                node.mtime = record.metadata.mtime
                node.ctime = record.metadata.ctime
            }
            guard case let .directory(entries) = record.contents else { return }
            for entry in entries {
                guard let child = node.child(entry.name) else { continue }
                apply(entry.inodeID, to: child)
            }
        }
        apply(rootID, to: root)
    }

    private func buildCandidate(from snapshot: ValidatedFilesystemSnapshot) -> VNode? {
        switch snapshot.storage {
        case let .legacy(root):
            return buildLegacyNode(name: "/", from: root)
        case let .inodeTable(rootID, records, incomingLinks):
            var canonicalNames: [UInt64: String] = [rootID: "/"]
            for id in records.keys.sorted() {
                guard case let .directory(entries) = records[id]?.contents else { continue }
                for entry in entries where canonicalNames[entry.inodeID] == nil {
                    canonicalNames[entry.inodeID] = entry.name
                }
            }

            var nodes: [UInt64: VNode] = [:]
            for id in records.keys.sorted() {
                guard let record = records[id], let name = canonicalNames[id] else { return nil }
                let node: VNode
                switch record.contents {
                case .directory:
                    node = VNode(directory: name)
                case .file:
                    node = VNode(file: name)
                case let .symlink(target):
                    node = VNode(symlink: name, target: target)
                case .fifo:
                    node = VNode(fifo: name)
                }

                node.mode = FileMode(rawValue: record.metadata.mode)
                node.uid = record.metadata.uid
                node.gid = record.metadata.gid
                node.atime = record.metadata.atime
                node.mtime = record.metadata.mtime
                node.ctime = record.metadata.ctime
                if case let .file(bytes) = record.contents { node.setFileContents(bytes) }
                if case .directory = record.contents {
                    node.nlink = 2
                } else {
                    node.nlink = incomingLinks[id] ?? 1
                }
                nodes[id] = node
            }

            for id in records.keys.sorted() {
                guard let record = records[id], let directory = nodes[id] else { return nil }
                guard case let .directory(entries) = record.contents else { continue }
                for entry in entries {
                    guard let child = nodes[entry.inodeID] else { return nil }
                    directory.addChild(name: entry.name, node: child)
                }
            }
            return nodes[rootID]
        }
    }

    private func buildLegacyNode(name: String, from node: FilesystemSnapshot.Node) -> VNode? {
        switch node {
        case let .directory(children):
            let directory = VNode(directory: name)
            for childName in children.keys.sorted() {
                guard let childSnapshot = children[childName],
                      let child = buildLegacyNode(name: childName, from: childSnapshot) else {
                    return nil
                }
                directory.addChild(name: childName, node: child)
            }
            return directory
        case let .file(bytes):
            let file = VNode(file: name)
            file.setFileContents(bytes)
            return file
        case let .symlink(target):
            return VNode(symlink: name, target: target)
        case .fifo:
            return VNode(fifo: name)
        }
    }
}
