/// The mount table for one mount namespace — the isolation unit for *what is
/// mounted where*, the last of the container pillars. The kernel keeps a single
/// base tmpfs tree that every process shares (its files are not copied by a
/// namespace); a mount namespace layers additional **mounts** on top of it:
///
///   - a **tmpfs** mount grafts a fresh, empty VNode tree at a mountpoint;
///   - a **bind** mount grafts an *existing* subtree at a second path (the same
///     VNodes, so writes are visible through both paths).
///
/// `unshare -m` gives a process a private *copy* of the table (sharing the mounted
/// trees, copying only the list of entries): a `mount` it then performs is
/// invisible to the parent — the mount-namespace lesson. Path resolution consults
/// the table by **longest matching mountpoint prefix**, so a lookup under a
/// mountpoint is redirected into the mounted tree.
///
/// Reference type, mutated only on the single serial executor (no lock). Kept
/// `internal`; the consumer boundary is the `ProcessContext` mount surface and the
/// `mount`/`umount` commands.
///
/// Known simplifications (documented, out of scope for the teaching model):
/// mounts are not persisted in a filesystem snapshot (runtime state, like
/// `/proc`); a mount nested *inside* another mount's tree is not modeled (the flat
/// longest-prefix table assumes mountpoints resolve against the base tree); and an
/// absolute symlink is resolved against the base tree, not re-projected through
/// the table.
final class MountNamespace {
    struct MountEntry {
        /// Absolute, normalized mountpoint path ("/mnt", "/mnt/data").
        let mountpoint: String
        /// The root VNode of the mounted filesystem (a fresh tree for tmpfs, an
        /// existing subtree for a bind mount).
        let root: VNode
        /// Filesystem type shown by `mount`/`/proc/mounts` ("tmpfs", "bind").
        let type: String
        /// The source shown by `mount` ("tmpfs" for tmpfs, the source path for bind).
        let source: String
    }

    private(set) var entries: [MountEntry] = []

    init() {}

    /// A private copy for `unshare(CLONE_NEWNS)`: the list of mounts is duplicated,
    /// but each entry keeps pointing at the same mounted tree (a namespace isolates
    /// the mount table, not the data).
    func copy() -> MountNamespace {
        let clone = MountNamespace()
        clone.entries = entries
        return clone
    }

    /// Add (or replace an existing mount at the same mountpoint with) `entry`.
    func add(_ entry: MountEntry) {
        entries.removeAll { $0.mountpoint == entry.mountpoint }
        entries.append(entry)
    }

    /// Remove the mount at `mountpoint`. Returns `false` when nothing was mounted
    /// there.
    @discardableResult
    func remove(mountpoint: String) -> Bool {
        let normalized = Self.normalize(mountpoint)
        let before = entries.count
        entries.removeAll { $0.mountpoint == normalized }
        return entries.count != before
    }

    /// Whether anything is mounted at exactly `mountpoint`.
    func isMountpoint(_ path: String) -> Bool {
        let normalized = Self.normalize(path)
        return entries.contains { $0.mountpoint == normalized }
    }

    /// Resolve `path` (an absolute, `.`/`..`-collapsed path) against the table:
    /// the deepest mountpoint that is a path-component prefix of `path` wins. When
    /// one matches, return that mount's root and the remainder of the path
    /// relative to it; when none does, return `nil` (the caller resolves against
    /// the base tree with the original path).
    func resolve(_ path: String) -> (root: VNode, subpath: String)? {
        guard !entries.isEmpty else { return nil }
        let target = Self.components(path)
        var best: (root: VNode, depth: Int)?
        for entry in entries {
            let mount = Self.components(entry.mountpoint)
            guard mount.count <= target.count,
                  Array(target.prefix(mount.count)) == mount else { continue }
            if best == nil || mount.count > best!.depth {
                best = (entry.root, mount.count)
            }
        }
        guard let best else { return nil }
        let remainder = target.dropFirst(best.depth).joined(separator: "/")
        return (best.root, "/" + remainder)
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// Normalize a path to an absolute, `.`/`..`-collapsed form for use as a
    /// mountpoint key.
    static func normalize(_ path: String) -> String {
        var stack: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(part)
            }
        }
        return "/" + stack.joined(separator: "/")
    }
}
