/// A serializable, point-in-time image of the VFS tree — the persistence seam
/// between the (Foundation-free) core and a consumer that wants files to survive
/// across launches.
///
/// Format v2 adds an inode table to the original path tree. The table preserves
/// ownership, mode, timestamps, and hard-link identity; `root` remains present
/// as a compatibility projection so archives written by older Swiftix releases
/// still decode and older consumers can ignore the additive v2 keys.
///
/// The inode table is flat, so it represents a tree of any depth. The legacy
/// projection is a recursive value: the compiler-generated code that compares,
/// encodes, and releases it uses one stack frame group per directory level. A
/// capture therefore bounds the projection at `legacyProjectionDepthLimit`;
/// deeper directories are present in full in the inode table only. Everything
/// in this file that walks a whole tree keeps an explicit worklist rather than
/// recursing, so directory depth never becomes host stack depth.
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

    /// Deepest directory level the legacy `root` projection of a capture
    /// describes, counting the root as level 0. A directory at this level is
    /// projected as empty; its contents live in `inodes` only. Restoring from
    /// the inode table is unaffected, so only a consumer that reads `root` alone
    /// loses the levels below.
    public static let legacyProjectionDepthLimit = 256

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
        // Directories whose entries are still being visited, innermost last.
        var open: [(id: UInt64, entries: [DirectoryEntry], next: Int)] = []
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
            open.append((id, entries, 0))
            return true
        }

        guard visit(rootID) else { return nil }
        while let directory = open.last {
            if directory.next < directory.entries.count {
                open[open.count - 1].next += 1
                guard visit(directory.entries[directory.next].inodeID) else { return nil }
            } else {
                visitingDirectories.remove(directory.id)
                open.removeLast()
            }
        }

        guard reachable.count == records.count,
              Self.legacyRoot(root, agreesWith: rootID, records: records) else { return nil }

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
        var pending = [children]
        while let children = pending.popLast() {
            for (name, node) in children {
                guard isValidEntryName(name) else { return false }
                if case let .directory(descendants) = node { pending.append(descendants) }
            }
        }
        return true
    }

    static func isValidEntryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    /// Whether the legacy tree is the path projection of the inode graph. A
    /// directory at or below `legacyProjectionDepthLimit` may be projected as
    /// empty (what a capture writes); a full projection, as written by releases
    /// that did not bound it, is accepted at any depth.
    static func legacyRoot(_ root: Node,
                           agreesWith rootID: UInt64,
                           records: [UInt64: Inode]) -> Bool {
        var pending: [(node: Node, id: UInt64, depth: Int)] = [(root, rootID, 0)]
        while let (node, id, depth) = pending.popLast() {
            guard let inode = records[id] else { return false }
            switch (node, inode.contents) {
            case let (.directory(children), .directory(entries)):
                if children.isEmpty, depth >= legacyProjectionDepthLimit { continue }
                guard children.count == entries.count else { return false }
                for entry in entries {
                    guard let child = children[entry.name] else { return false }
                    pending.append((child, entry.inodeID, depth + 1))
                }
            case let (.file(projected), .file(bytes)):
                guard projected == bytes else { return false }
            case let (.symlink(projected), .symlink(target)):
                guard projected == target else { return false }
            case (.fifo, .fifo):
                break
            default:
                return false
            }
        }
        return true
    }

    /// The legacy path projection of the inode graph, cut off at
    /// `legacyProjectionDepthLimit`. The bound is what keeps this recursion,
    /// and every later use of the recursive `Node` value, within a fixed stack
    /// budget.
    static func project(_ id: UInt64, records: [UInt64: Inode], depth: Int = 0) -> Node? {
        guard let inode = records[id] else { return nil }
        switch inode.contents {
        case let .directory(entries):
            var children: [String: Node] = [:]
            guard depth < legacyProjectionDepthLimit else { return .directory(children: children) }
            for entry in entries {
                guard let child = project(entry.inodeID, records: records, depth: depth + 1) else {
                    return nil
                }
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

        // Directories whose children are still being captured, innermost last.
        // IDs are assigned on first visit, in sorted depth-first order.
        struct OpenDirectory {
            let node: VNode
            let id: UInt64
            let names: [String]
            var next = 0
            var entries: [FilesystemSnapshot.DirectoryEntry] = []
        }
        var open: [OpenDirectory] = []

        func record(_ node: VNode, id: UInt64, contents: FilesystemSnapshot.InodeContents) {
            let metadata = FilesystemSnapshot.Metadata(
                mode: node.mode.rawValue,
                uid: node.uid,
                gid: node.gid,
                atime: node.atime,
                mtime: node.mtime,
                ctime: node.ctime)
            records[id] = .init(id: id, metadata: metadata, contents: contents)
        }

        /// Assign `node` its inode ID. A directory is left open for the loop
        /// below to fill in; anything else is recorded at once.
        func capture(_ node: VNode) -> UInt64 {
            let identity = ObjectIdentifier(node)
            if let existing = inodeIDs[identity] { return existing }

            let id = nextID
            nextID += 1
            inodeIDs[identity] = id

            switch node.kind {
            case .directory:
                open.append(OpenDirectory(node: node, id: id, names: node.children.keys.sorted()))
            case .file:
                record(node, id: id, contents: .file(bytes: node.fileContents))
            case .symlink:
                record(node, id: id, contents: .symlink(target: node.linkTarget))
            case .fifo:
                record(node, id: id, contents: .fifo)
            }
            return id
        }

        let rootID = capture(root)
        while let directory = open.last {
            let top = open.count - 1
            guard directory.next < directory.names.count else {
                record(directory.node, id: directory.id, contents: .directory(entries: directory.entries))
                open.removeLast()
                continue
            }
            open[top].next += 1
            let name = directory.names[directory.next]
            guard let child = directory.node.children[name], shouldPersist(child) else { continue }
            let childID = capture(child)
            open[top].entries.append(.init(name: name, inodeID: childID))
        }
        let orderedRecords = records.keys.sorted().compactMap { records[$0] }
        let legacyRoot = FilesystemSnapshot.project(rootID, records: records)
            ?? .directory(children: [:])
        return FilesystemSnapshot(root: legacyRoot,
                                  formatVersion: FilesystemSnapshot.currentFormatVersion,
                                  rootInodeID: rootID,
                                  inodes: orderedRecords)
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
        var pending: [(id: UInt64, node: VNode)] = [(rootID, root)]
        while let (id, node) = pending.popLast() {
            guard let record = records[id] else { continue }
            let identity = ObjectIdentifier(node)
            if visited.insert(identity).inserted {
                node.mode = FileMode(rawValue: record.metadata.mode)
                node.uid = record.metadata.uid
                node.gid = record.metadata.gid
                node.atime = record.metadata.atime
                node.mtime = record.metadata.mtime
                node.ctime = record.metadata.ctime
            }
            guard case let .directory(entries) = record.contents else { continue }
            for entry in entries {
                guard let child = node.child(entry.name) else { continue }
                pending.append((entry.inodeID, child))
            }
        }
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
        // Directories whose children are still to be built.
        var pending: [(directory: VNode, children: [String: FilesystemSnapshot.Node])] = []
        func build(_ name: String, _ node: FilesystemSnapshot.Node) -> VNode {
            switch node {
            case let .directory(children):
                let directory = VNode(directory: name)
                pending.append((directory, children))
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

        let root = build(name, node)
        while let (directory, children) = pending.popLast() {
            for (childName, child) in children {
                directory.addChild(name: childName, node: build(childName, child))
            }
        }
        return root
    }
}
