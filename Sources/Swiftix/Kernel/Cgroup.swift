/// Control groups (a cgroups-v2-style "pids" controller): the grouping-and-
/// limiting half of the container story, the counterpart to the isolation that
/// namespaces provide. A `Cgroup` is a node in a hierarchy; every process belongs
/// to one (the root by default) and is counted against that group and every
/// ancestor up to the root. The only modeled controller is `pids`:
///
///   - `pids.current` — the number of live processes in the subtree.
///   - `pids.max`     — the admission limit for the subtree (`nil` = unlimited).
///
/// A process is admitted to its group when it is spawned (a child inherits its
/// parent's group). If admitting it would push the group — or any ancestor — past
/// `pids.max`, creation fails before allocating a PID. Moving an existing process
/// remains an organizational operation and is allowed even above the limit; the
/// limit then blocks subsequent creation, matching cgroup-v2 pids semantics.
///
/// Reference type, mutated only on the single serial executor (no lock), like the
/// rest of the kernel core. Kept `internal`; the consumer boundary is the
/// `ProcessContext` cgroup surface and the synthetic `/sys/fs/cgroup` files.
final class Cgroup {
    /// The last path component ("demo"); empty for the root.
    let name: String
    /// The absolute cgroup path ("/", "/demo", "/demo/inner").
    let path: String
    weak var parent: Cgroup?
    private(set) var children: [String: Cgroup] = [:]
    /// Admission limit for this subtree; `nil` means "max" (unlimited).
    var pidsMax: Int?

    init(name: String, path: String, parent: Cgroup?) {
        self.name = name
        self.path = path
        self.parent = parent
    }

    func addChild(_ child: Cgroup) { children[child.name] = child }
    func removeChild(_ name: String) { children[name] = nil }
    var hasChildren: Bool { !children.isEmpty }

    /// Whether `ancestor` is this group or any of its ancestors.
    func isDescendant(ofOrEqual ancestor: Cgroup) -> Bool {
        var node: Cgroup? = self
        while let current = node {
            if current === ancestor { return true }
            node = current.parent
        }
        return false
    }

    /// This group and every ancestor up to the root (inclusive), nearest first.
    var lineage: [Cgroup] {
        var result: [Cgroup] = []
        var node: Cgroup? = self
        while let current = node {
            result.append(current)
            node = current.parent
        }
        return result
    }
}

/// Owns the cgroup hierarchy and the pid→group membership index for one kernel.
/// A process not present in the index is implicitly in the root group (which is
/// never limited), so the common case — everything at root — costs nothing.
final class CgroupController {
    let root: Cgroup
    private var byPath: [String: Cgroup] = [:]
    /// Non-root memberships only; a pid absent here is in the root group.
    private var membership: [PID: Cgroup] = [:]
    /// Liveness oracle (the kernel's process table); exited pids are filtered out
    /// of every count. Pids are never reused, so a stale entry is only ever a
    /// dead one, safely ignored (and pruned opportunistically).
    private let isAlive: (PID) -> Bool

    init(isAlive: @escaping (PID) -> Bool) {
        self.isAlive = isAlive
        self.root = Cgroup(name: "", path: "/", parent: nil)
        byPath["/"] = root
    }

    // MARK: - Hierarchy

    func cgroup(_ path: String) -> Cgroup? { byPath[Self.normalize(path)] }

    var allPaths: [String] { byPath.keys.sorted() }

    /// Create `path` (and any missing intermediate groups, like `mkdir -p`),
    /// returning the leaf group. Returns the existing group if already present.
    @discardableResult
    func create(_ rawPath: String) -> Cgroup? {
        let path = Self.normalize(rawPath)
        if let existing = byPath[path] { return existing }
        var current = root
        var built = ""
        for part in path.split(separator: "/") {
            built += "/" + part
            if let next = byPath[built] {
                current = next
            } else {
                let child = Cgroup(name: String(part), path: built, parent: current)
                current.addChild(child)
                byPath[built] = child
                current = child
            }
        }
        return current
    }

    /// Remove an empty leaf group (no child groups, no live members). The root is
    /// never removed. Returns `false` otherwise.
    @discardableResult
    func remove(_ rawPath: String) -> Bool {
        let path = Self.normalize(rawPath)
        guard path != "/", let group = byPath[path] else { return false }
        guard !group.hasChildren, liveCount(group) == 0 else { return false }
        group.parent?.removeChild(group.name)
        byPath[path] = nil
        return true
    }

    // MARK: - Membership & accounting

    /// The group a pid belongs to (root when it has no explicit membership).
    func cgroupOf(_ pid: PID) -> Cgroup { membership[pid] ?? root }

    /// Live pids assigned *directly* to `group`, sorted.
    func directLiveMembers(_ group: Cgroup) -> [PID] {
        prune()
        return membership.compactMap { $0.value === group ? $0.key : nil }.sorted()
    }

    /// Live processes in the subtree rooted at `group` (its `pids.current`).
    func liveCount(_ group: Cgroup) -> Int {
        prune()
        return membership.reduce(0) { $1.value.isDescendant(ofOrEqual: group) ? $0 + 1 : $0 }
    }

    /// Whether one more process fits in `group`: every node from `group` up to the
    /// root that carries a `pids.max` must still have room.
    func canAdmit(_ group: Cgroup) -> Bool {
        for node in group.lineage {
            if let limit = node.pidsMax, liveCount(node) >= limit { return false }
        }
        return true
    }

    /// Whether a child can be created in its parent's inherited group.
    func canAdmitChild(parentPID: PID) -> Bool {
        let target = cgroupOf(parentPID)
        return canAdmit(target)
    }

    /// Record a freshly-created child's inherited membership after admission.
    func admitChild(pid: PID, parentPID: PID) {
        let target = cgroupOf(parentPID)
        if target !== root { membership[pid] = target }
    }

    /// Move a live process into `group` (the `cgroup.procs` write / `cgexec`
    /// placement). This is organizational rather than process creation, so it is
    /// allowed even when the destination is at/above `pids.max`.
    @discardableResult
    func move(pid: PID, to group: Cgroup) -> Bool {
        let old = cgroupOf(pid)
        if old === group { return true }
        membership[pid] = group === root ? nil : group
        return true
    }

    /// Drop memberships for pids that have exited (keeps the index bounded).
    private func prune() {
        membership = membership.filter { isAlive($0.key) }
    }

    // MARK: - Path normalization

    /// Normalize a raw cgroup path to an absolute, `.`/`..`-collapsed form.
    /// "demo" → "/demo", "/a/b/.." → "/a", "" → "/".
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
