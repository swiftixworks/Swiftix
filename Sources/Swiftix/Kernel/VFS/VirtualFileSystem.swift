/// An in-memory (tmpfs) filesystem tree. Scope: absolute paths; directory,
/// regular-file, symbolic-link, and named-pipe (FIFO) nodes; create / lookup;
/// synthetic (procfs/sysfs) files; hard links with nlink tracking; deferred
/// deletion (unlink-while-open); mount projection; and device nodes. Access
/// policy stays in `ProcessContext`, while this type owns path resolution: a
/// caller that wants directory search permission enforced hands the walk a
/// `PathSearch` predicate, and the walk consults it once per traversed directory.
final class VirtualFileSystem {
    /// Search-permission policy for one path walk. The VFS knows nothing about
    /// credentials; `permits` is the caller's "may I traverse this directory"
    /// (execute bit) decision, asked for every directory a component is looked
    /// up in. Kernel-internal and uid-0 walks pass no policy at all, so they pay
    /// nothing per component.
    struct PathSearch {
        /// Whether the caller may search (look a name up in) `directory`.
        let permits: (VNode) -> Bool
        /// Leading components resolved without a check. A path at or below the
        /// caller's working directory starts at that directory, as a relative
        /// path does on Linux, so the directories *above* the cwd are not asked
        /// again; the cwd itself and everything beneath it still are.
        var trustedComponents = 0
    }

    /// Why a credential-aware walk ended.
    enum PathResolution {
        case found(VNode)
        /// A component does not exist, or a non-directory was traversed.
        case missing
        /// A traversed directory refused search permission (POSIX `EACCES`).
        case searchDenied

        var node: VNode? {
            if case .found(let node) = self { return node }
            return nil
        }
    }

    let root = VNode(directory: "/")

    /// Logical clock provider — returns `EventLoop.now` so timestamp updates
    /// use the simulation's deterministic time rather than wall-clock time.
    /// Set by the kernel at construction.
    var clock: () -> Double = { 0 }

    /// Total number of VFS nodes (files + directories + symlinks). Used by
    /// resource accounting. Counts all nodes including synthetic (procfs) ones —
    /// they are still VFS nodes even if their content is computed.
    ///
    /// Like every whole-tree helper here, the walk keeps its own worklist
    /// instead of recursing, so its stack use does not grow with tree depth.
    var nodeCount: Int {
        var count = 0
        var pending = [root]
        while let node = pending.popLast() {
            count += 1
            pending.append(contentsOf: node.children.values)
        }
        return count
    }

    /// Total bytes of real (non-synthetic) regular files in the tree. Used by the
    /// synthetic `/proc/meminfo` so the "in-memory tmpfs" usage it reports matches
    /// what `free`/`df` compute. Synthetic (procfs) files are excluded — their
    /// content is computed on read, not stored.
    var totalFileBytes: Int {
        var bytes = 0
        var pending = [root]
        while let node = pending.popLast() {
            if node.kind == .file, node.provider == nil { bytes += node.fileContents.count }
            pending.append(contentsOf: node.children.values)
        }
        return bytes
    }

    /// Maximum symlink hops before giving up (POSIX `ELOOP`), guarding against
    /// cyclic links (`a -> b -> a`).
    private let maxSymlinkHops = 40

    /// Split "/a/b/c" into ["a", "b", "c"], ignoring empty components.
    private func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// Resolve an absolute path to an existing node, following symbolic links.
    /// When `follow` is `false`, a symlink named by the *final* component is
    /// returned as the link node itself (so `remove`/`readlink` see the link, not
    /// its target); symlinks in intermediate components are always followed.
    ///
    /// `mounts` (a process's mount namespace) redirects the resolution into a
    /// mounted tree when `path` falls under a mountpoint; `nil` (the default,
    /// preserving every existing caller) resolves against the base tree only.
    func lookup(_ path: String, follow: Bool = true, mounts: MountNamespace? = nil) -> VNode? {
        resolve(path, follow: follow, mounts: mounts, search: nil).node
    }

    /// `lookup` that enforces `search` on every traversed directory and reports
    /// a refusal separately from a missing path. Crossing into a mount checks the
    /// directories leading to the mountpoint first, then the mounted root in
    /// place of the directory it covers.
    func resolve(_ path: String,
                 follow: Bool = true,
                 mounts: MountNamespace? = nil,
                 search: PathSearch?) -> PathResolution {
        guard let entry = mountEntry(path, mounts, search) else { return .searchDenied }
        return walk(from: entry.origin, entry.subpath, follow: follow, search: entry.search)
    }

    /// `mountOrigin` for a credential-aware walk: the starting tree, the path
    /// inside it, and the policy for the rest of the walk. The longest-prefix
    /// table jumps straight into a mounted tree, so the directories that lead to
    /// the mountpoint are checked here; `nil` means one of them refused search.
    private func mountEntry(_ path: String,
                            _ mounts: MountNamespace?,
                            _ search: PathSearch?) -> (origin: VNode, subpath: String, search: PathSearch?)? {
        guard let mounts, let hit = mounts.resolve(path) else { return (root, path, search) }
        guard var inner = search else { return (hit.root, hit.subpath, nil) }
        var ancestor = ""
        for (depth, part) in components(path).prefix(hit.depth).enumerated() {
            if depth >= inner.trustedComponents,
               let directory = lookup(ancestor.isEmpty ? "/" : ancestor, mounts: mounts),
               !inner.permits(directory) {
                return nil
            }
            ancestor += "/" + part
        }
        inner.trustedComponents = Swift.max(0, inner.trustedComponents - hit.depth)
        return (hit.root, hit.subpath, inner)
    }

    /// Resolve a relative path beneath an already-resolved directory. Absolute
    /// symlink targets are re-rooted at `root` and `..` can never walk above it,
    /// providing the VFS primitive used by capability-scoped operations.
    func lookup(_ relativePath: String, follow: Bool = true, beneath root: VNode) -> VNode? {
        resolve(relativePath, follow: follow, beneath: root, search: nil).node
    }

    /// The capability-scoped `lookup` with search permission enforced from
    /// `root` downwards.
    func resolve(_ relativePath: String,
                 follow: Bool = true,
                 beneath root: VNode,
                 search: PathSearch?) -> PathResolution {
        guard root.kind == .directory else { return .missing }
        return walk(from: root,
                    relativePath,
                    follow: follow,
                    absoluteSymlinkRoot: root,
                    search: search)
    }

    /// Resolve the immediate parent directory of an absolute path in a mount
    /// namespace. Intermediate symlinks are followed exactly as in `lookup`.
    func parentDirectory(of path: String, mounts: MountNamespace? = nil) -> VNode? {
        resolveParentDirectory(of: path, mounts: mounts, search: nil).node
    }

    /// `parentDirectory` with search permission enforced on the way to the
    /// parent. The parent's own permissions are the caller's to judge.
    func resolveParentDirectory(of path: String,
                                mounts: MountNamespace? = nil,
                                search: PathSearch?) -> PathResolution {
        guard let entry = mountEntry(path, mounts, search) else { return .searchDenied }
        return resolveParentDirectory(of: entry.subpath, beneath: entry.origin,
                                      absoluteSymlinkRoot: nil, search: entry.search)
    }

    /// Resolve the immediate parent while remaining anchored beneath a
    /// capability root, including absolute symlink targets.
    func parentDirectory(of relativePath: String, beneath root: VNode) -> VNode? {
        resolveParentDirectory(of: relativePath, beneath: root, search: nil).node
    }

    /// The capability-scoped `parentDirectory` with search permission enforced.
    func resolveParentDirectory(of relativePath: String,
                                beneath root: VNode,
                                search: PathSearch?) -> PathResolution {
        resolveParentDirectory(of: relativePath, beneath: root,
                               absoluteSymlinkRoot: root, search: search)
    }

    private func resolveParentDirectory(of path: String,
                                        beneath root: VNode,
                                        absoluteSymlinkRoot: VNode?,
                                        search: PathSearch?) -> PathResolution {
        let parts = components(path)
        guard !parts.isEmpty else { return .missing }
        let parentPath = parts.dropLast().joined(separator: "/")
        return directory(walk(from: root,
                              parentPath,
                              follow: true,
                              absoluteSymlinkRoot: absoluteSymlinkRoot,
                              search: search))
    }

    private func directory(_ resolution: PathResolution) -> PathResolution {
        if case .found(let node) = resolution, node.kind != .directory { return .missing }
        return resolution
    }

    /// The starting tree and path for resolving `path`: the deepest mount whose
    /// mountpoint is a prefix (its root and the remainder), or the base tree with
    /// the whole path when no mount applies.
    private func mountOrigin(_ path: String, _ mounts: MountNamespace?) -> (VNode, String) {
        if let mounts, let hit = mounts.resolve(path) { return (hit.root, hit.subpath) }
        return (root, path)
    }

    /// Walk `path`'s components starting at `origin`, following symbolic links.
    /// An **absolute** symlink target restarts from the base tree (a documented
    /// simplification: absolute links are not re-projected through the mount
    /// table); a relative one resolves from the link's directory.
    ///
    /// With a `search` policy, every directory a component is looked up in must
    /// permit search, including the directories a symlink target walks through
    /// and the one a `..` steps out of. The final node itself is never asked:
    /// what the caller may do with it is the caller's check.
    private func walk(from origin: VNode,
                      _ path: String,
                      follow: Bool,
                      absoluteSymlinkRoot: VNode? = nil,
                      search: PathSearch? = nil) -> PathResolution {
        var remaining = components(path)[...]   // components still to walk
        var node = origin
        var resolved: [String] = []        // real (symlink-free) components under `walkRoot`
        var walkRoot = origin
        var hops = 0
        // Leading entries of `remaining` exempt from the search check.
        var trusted = search?.trustedComponents ?? 0

        while let part = remaining.popFirst() {
            let exempt = trusted > 0
            if exempt { trusted -= 1 }
            switch part {
            case ".":
                continue
            case "..":
                if let search, !exempt, node.kind == .directory, !search.permits(node) {
                    return .searchDenied
                }
                if !resolved.isEmpty { resolved.removeLast() }
                node = nodeAt(from: walkRoot, resolved) ?? walkRoot
                continue
            default:
                break
            }
            guard node.kind == .directory else { return .missing }
            if let search, !exempt, !search.permits(node) { return .searchDenied }
            // Real children win; a dynamic-directory node (e.g. /proc) can also
            // resolve computed children like a live pid.
            guard let next = node.child(part) ?? node.resolveDynamicChild?(part) else { return .missing }
            let isFinal = remaining.isEmpty
            if next.kind == .symlink, !(isFinal && !follow) {
                hops += 1
                if hops > maxSymlinkHops { return .missing }
                let targetComponents = components(next.linkTarget)
                if next.linkTarget.hasPrefix("/") {
                    let targetRoot = absoluteSymlinkRoot ?? root
                    node = targetRoot
                    walkRoot = targetRoot
                    resolved = []
                }
                // Relative target resolves from the link's directory (`node`
                // stays put); splice the target ahead of the rest of the path.
                // A link inside the trusted prefix is part of how the caller got
                // to its working directory, so its target is trusted with it.
                if exempt { trusted += targetComponents.count }
                remaining = (targetComponents + remaining)[...]
            } else {
                node = next
                resolved.append(part)
            }
        }
        return .found(node)
    }

    /// Create a regular file beneath a capability root. Unlike the convenience
    /// tmpfs API, this requires the parent directory to exist; intermediate
    /// symlinks are resolved with the same confinement as `lookup`.
    func createFile(_ relativePath: String, beneath root: VNode) -> VNode? {
        createNode(relativePath, beneath: root) { VNode(file: $0) }
    }

    /// Create one directory beneath a capability root.
    func createDirectory(_ relativePath: String, beneath root: VNode) -> VNode? {
        createNode(relativePath, beneath: root) { VNode(directory: $0) }
    }

    private func createNode(_ relativePath: String,
                            beneath root: VNode,
                            make: (String) -> VNode) -> VNode? {
        let parts = components(relativePath)
        guard let name = parts.last, name != ".", name != ".." else { return nil }
        let parentPath = parts.dropLast().joined(separator: "/")
        guard let parent = lookup(parentPath, beneath: root),
              parent.kind == .directory else { return nil }
        if let existing = parent.child(name) { return existing }
        return parent.addChild(name: name, node: make(name))
    }

    /// Remove a file or empty directory beneath a capability root without letting
    /// a final symlink redirect the removal outside the root.
    func remove(_ relativePath: String, beneath root: VNode) -> Bool {
        let parts = components(relativePath)
        guard let name = parts.last, name != ".", name != ".." else { return false }
        let parentPath = parts.dropLast().joined(separator: "/")
        guard let parent = lookup(parentPath, beneath: root),
              parent.kind == .directory,
              let target = parent.child(name) else { return false }
        if target.kind == .directory, !target.children.isEmpty { return false }
        return parent.removeChild(name)
    }

    enum RenameError: Error {
        case missingSource
        case missingParent
        case sourceIsDirectory
        case destinationIsDirectory
        case destinationNotEmpty
        case invalidMove
    }

    /// Rename or move one node between two capability roots. Both parent paths
    /// are resolved beneath their supplied roots, so neither source nor
    /// destination can escape through an absolute symlink. Replacing an existing
    /// empty destination follows POSIX rename semantics.
    func rename(_ sourcePath: String,
                beneath sourceRoot: VNode,
                to destinationPath: String,
                beneath destinationRoot: VNode) throws {
        let sourceParts = components(sourcePath)
        let destinationParts = components(destinationPath)
        guard let sourceName = sourceParts.last,
              let destinationName = destinationParts.last,
              sourceName != ".", sourceName != "..",
              destinationName != ".", destinationName != ".." else {
            throw RenameError.invalidMove
        }

        let sourceParentPath = sourceParts.dropLast().joined(separator: "/")
        let destinationParentPath = destinationParts.dropLast().joined(separator: "/")
        guard let sourceParent = lookup(sourceParentPath, beneath: sourceRoot),
              let destinationParent = lookup(destinationParentPath, beneath: destinationRoot),
              sourceParent.kind == .directory,
              destinationParent.kind == .directory else {
            throw RenameError.missingParent
        }
        guard let source = sourceParent.child(sourceName) else {
            throw RenameError.missingSource
        }
        if sourceParent === destinationParent, sourceName == destinationName { return }
        if source.kind == .directory, contains(source, node: destinationParent) {
            throw RenameError.invalidMove
        }

        if let destination = destinationParent.child(destinationName) {
            if source.kind == .directory, destination.kind != .directory {
                throw RenameError.destinationIsDirectory
            }
            if source.kind != .directory, destination.kind == .directory {
                throw RenameError.sourceIsDirectory
            }
            if destination.kind == .directory, !destination.children.isEmpty {
                throw RenameError.destinationNotEmpty
            }
            _ = destinationParent.removeChild(destinationName)
        }

        _ = sourceParent.removeChild(sourceName)
        destinationParent.addChild(name: destinationName, node: source)
    }

    private func contains(_ root: VNode, node candidate: VNode) -> Bool {
        var pending = [root]
        while let node = pending.popLast() {
            if node === candidate { return true }
            pending.append(contentsOf: node.children.values)
        }
        return false
    }

    /// Walk already-resolved (symlink-free) components from `origin` without
    /// following links — used to recompute the current node after a `..`.
    private func nodeAt(from origin: VNode, _ parts: [String]) -> VNode? {
        var node = origin
        for part in parts {
            guard let next = node.child(part) else { return nil }
            node = next
        }
        return node
    }

    /// Create a symbolic link at `path` pointing at `target` (stored verbatim;
    /// resolved on lookup). Makes parent directories as needed. Returns the link
    /// node, or `nil` if `path` already exists.
    @discardableResult
    func createSymlink(_ path: String, target: String, mounts: MountNamespace? = nil) -> VNode? {
        let (origin, subpath) = mountOrigin(path, mounts)
        let parts = components(subpath)
        guard let name = parts.last else { return nil }
        var node = origin
        for part in parts.dropLast() {
            let child = node.child(part)
                ?? node.addChild(name: part, node: VNode(directory: part))
            child.touchAll(clock())
            node = child
        }
        if node.child(name) != nil { return nil }
        let link = node.addChild(name: name, node: VNode(symlink: name, target: target))
        let now = clock()
        link.touchAll(now)
        node.touchModify(now)
        return link
    }

    /// Create intermediate directories as needed (like `mkdir -p`).
    @discardableResult
    func makeDirectories(_ path: String, mounts: MountNamespace? = nil) -> VNode {
        let (origin, subpath) = mountOrigin(path, mounts)
        var node = origin
        let now = clock()
        for part in components(subpath) {
            if let existing = node.child(part) {
                node = existing
            } else {
                let dir = node.addChild(name: part, node: VNode(directory: part))
                dir.touchAll(now)
                node.touchModify(now)
                node = dir
            }
        }
        return node
    }

    /// Create (or return an existing) regular file at `path`, making parent
    /// directories as needed. Returns `nil` if the path names an existing
    /// directory.
    @discardableResult
    func createFile(_ path: String, mounts: MountNamespace? = nil) -> VNode? {
        let (origin, subpath) = mountOrigin(path, mounts)
        let parts = components(subpath)
        guard let fileName = parts.last else { return nil }
        var node = origin
        let now = clock()
        for part in parts.dropLast() {
            if let existing = node.child(part) {
                node = existing
            } else {
                let dir = node.addChild(name: part, node: VNode(directory: part))
                dir.touchAll(now)
                node.touchModify(now)
                node = dir
            }
        }
        if let existing = node.child(fileName) {
            return existing.kind == .file ? existing : nil
        }
        let file = node.addChild(name: fileName, node: VNode(file: fileName))
        file.touchAll(now)
        node.touchModify(now)
        return file
    }

    /// Create an (empty) directory at `path`, making parents as needed. Returns
    /// the directory node, or `nil` if the path already names a regular file.
    @discardableResult
    func createDirectory(_ path: String, mounts: MountNamespace? = nil) -> VNode? {
        let (origin, subpath) = mountOrigin(path, mounts)
        var node = origin
        let now = clock()
        for part in components(subpath) {
            if let existing = node.child(part) {
                guard existing.kind == .directory else { return nil }
                node = existing
            } else {
                let dir = node.addChild(name: part, node: VNode(directory: part))
                dir.touchAll(now)
                node.touchModify(now)
                node = dir
            }
        }
        return node
    }

    /// Remove the node at `path` from its parent. Refuses to remove a non-empty
    /// directory (like `rmdir`/`unlink`). Supports deferred deletion: if the node
    /// has open file handles, the directory entry is removed (making it
    /// unreachable by path) but the VNode stays alive until the last handle closes.
    /// Returns `true` on success.
    @discardableResult
    func remove(_ path: String, mounts: MountNamespace? = nil) -> Bool {
        let (origin, subpath) = mountOrigin(path, mounts)
        let parts = components(subpath)
        guard let name = parts.last else { return false }
        var parent = origin
        for part in parts.dropLast() {
            guard let next = parent.child(part), next.kind == .directory else { return false }
            parent = next
        }
        guard let target = parent.child(name) else { return false }
        if target.kind == .directory, !target.children.isEmpty { return false }
        let now = clock()
        target.nlink -= 1
        if target.nlink <= 0, target.openHandles > 0 {
            // Deferred deletion: unreachable by path but still alive for open fds.
            target.unlinked = true
        }
        target.touchChange(now)
        parent.touchModify(now)
        return parent.removeChild(name)
    }

    /// Create a synthetic (procfs/sysfs) file whose contents are computed by
    /// `provider` at open time.
    @discardableResult
    func createSyntheticFile(_ path: String, _ provider: @escaping () -> [UInt8]) -> VNode? {
        guard let node = createFile(path) else { return nil }
        node.provider = provider
        return node
    }

    /// Create a special device file at `path` (e.g. `/dev/null`), making parent
    /// directories as needed. Device files are world read/write (0666) and their
    /// I/O is handled by a device backing, not stored bytes.
    @discardableResult
    func createDevice(_ path: String, kind: VNode.DeviceKind) -> VNode? {
        guard let node = createFile(path) else { return nil }
        node.deviceKind = kind
        node.mode = [.ownerRead, .ownerWrite, .groupRead, .groupWrite, .otherRead, .otherWrite]
        return node
    }

    // MARK: - Hard links

    /// Create a hard link: a new directory entry at `linkPath` pointing at the
    /// same VNode as `targetPath`. Both paths must resolve; `targetPath` must not
    /// be a directory (POSIX `EPERM` on directory hard links). Increments `nlink`.
    @discardableResult
    func link(_ targetPath: String, at linkPath: String, mounts: MountNamespace? = nil) -> Bool {
        guard let target = lookup(targetPath, mounts: mounts),
              target.kind != .directory else { return false }
        let (origin, subpath) = mountOrigin(linkPath, mounts)
        let parts = components(subpath)
        guard let name = parts.last, name != ".", name != ".." else { return false }
        var parent = origin
        for part in parts.dropLast() {
            guard let next = parent.child(part), next.kind == .directory else { return false }
            parent = next
        }
        guard parent.child(name) == nil else { return false }  // already exists
        // A directory entry owns its name; the inode-like VNode is shared without
        // mutation, so sibling hard links retain independent names.
        parent.addChild(name: name, node: target)
        let now = clock()
        target.nlink += 1
        target.touchChange(now)
        parent.touchModify(now)
        return true
    }

    // MARK: - Named pipes (FIFO)

    /// Create a named pipe (FIFO) at `path`. Returns the fifo node, or `nil` if
    /// the path already exists. Parent directories are made as needed.
    @discardableResult
    func createFifo(_ path: String, mounts: MountNamespace? = nil) -> VNode? {
        let (origin, subpath) = mountOrigin(path, mounts)
        let parts = components(subpath)
        guard let name = parts.last else { return nil }
        var node = origin
        let now = clock()
        for part in parts.dropLast() {
            if let existing = node.child(part) {
                node = existing
            } else {
                let dir = node.addChild(name: part, node: VNode(directory: part))
                dir.touchAll(now)
                node.touchModify(now)
                node = dir
            }
        }
        if node.child(name) != nil { return nil }  // already exists
        let fifo = node.addChild(name: name, node: VNode(fifo: name))
        fifo.touchAll(now)
        node.touchModify(now)
        return fifo
    }
}
