/// `ProcessContext` namespace surface: UTS (hostname), mount, and cgroup
/// (pids controller) operations — the container/isolation seam.
extension ProcessContext {

    // MARK: - UTS namespace (hostname / isolation)

    /// This process's hostname, read from its UTS namespace (POSIX
    /// `gethostname`).
    public var hostname: String { process.utsNamespace.hostname }

    /// This process's NIS/domain name (POSIX `getdomainname`).
    public var domainName: String { process.utsNamespace.domainName }

    /// Set the hostname in this process's UTS namespace (POSIX `sethostname`).
    /// The change is visible to every process that shares the namespace — the
    /// whole machine — unless the caller first took a private copy with
    /// `unshareUTS()`.
    public func setHostname(_ name: String) { process.utsNamespace.hostname = name }

    /// Set the NIS/domain name in this process's UTS namespace (POSIX
    /// `setdomainname`).
    public func setDomainName(_ name: String) { process.utsNamespace.domainName = name }

    /// Detach this process into a *private copy* of its UTS namespace — the moral
    /// equivalent of `unshare(CLONE_NEWUTS)`. After this call, `setHostname`
    /// changes are invisible to the parent and siblings, and children spawned
    /// afterwards inherit (share) the new private namespace. This is the smallest
    /// concrete demonstration of namespace isolation.
    public func unshareUTS() {
        process.utsNamespace = process.utsNamespace.copy()
    }

    /// Request that this process's *next* spawned child be placed in a brand-new
    /// PID namespace as its pid 1 — the moral equivalent of `unshare(CLONE_NEWPID)`
    /// followed by a fork (Linux `unshare --pid --fork`). A process cannot change
    /// its own PID namespace (its pid is fixed), so the new namespace takes effect
    /// for the child. One-shot: it applies to the next child only.
    public func unsharePIDNamespace() {
        process.unshareChildIntoNewPIDNamespace = true
    }

    /// Join the UTS namespace of process `pid` — the moral equivalent of
    /// `nsenter --uts --target PID`. This process starts sharing that namespace,
    /// so it sees that host's name and any further changes there.
    ///
    /// - Returns: `false` if no process with `pid` exists.
    @discardableResult
    public func enterUTSNamespace(ofPID pid: PID) -> Bool {
        guard let target = kernel.process(pid) else { return false }
        process.utsNamespace = target.utsNamespace
        return true
    }

    // MARK: - Mount namespace

    /// Mount a fresh, empty tmpfs at `path` (an existing directory) in this
    /// process's mount namespace — the moral equivalent of
    /// `mount -t tmpfs tmpfs <path>`. Files created under it live in the mount, and
    /// the mountpoint's previous contents are shadowed while it is mounted.
    @discardableResult
    public func mountTmpfs(at path: String) -> Bool {
        kernel.mountTmpfs(at: absolute(path), ns: process.mountNamespace)
    }

    /// Bind-mount the directory `source` onto `path` (`mount --bind <source>
    /// <path>`): the two paths then refer to the same subtree, so writes through
    /// one are visible through the other.
    @discardableResult
    public func mountBind(source: String, at path: String) -> Bool {
        kernel.mountBind(source: absolute(source), at: absolute(path), ns: process.mountNamespace)
    }

    /// Unmount whatever is mounted at `path` (`umount <path>`).
    @discardableResult
    public func unmount(_ path: String) -> Bool {
        kernel.unmount(absolute(path), ns: process.mountNamespace)
    }

    /// Detach this process into a private copy of its mount namespace — the moral
    /// equivalent of `unshare(CLONE_NEWNS)`. Unlike a PID namespace, this takes
    /// effect for the caller immediately: mounts it performs afterwards are
    /// invisible to the parent, and children it spawns inherit the private table.
    public func unshareMountNamespace() {
        process.mountNamespace = process.mountNamespace.copy()
    }

    /// The mount table visible to this process, as `(source, mountpoint, type)`
    /// rows: the two base mounts (the root tmpfs and `/proc`) followed by this
    /// namespace's mounts. Backs the `mount` (no-arg) listing.
    func mountTable() -> [(source: String, mountpoint: String, type: String)] {
        var rows: [(source: String, mountpoint: String, type: String)] = [
            ("tmpfs", "/", "tmpfs"),
            ("proc", "/proc", "proc"),
        ]
        for entry in process.mountNamespace.entries {
            rows.append((entry.source, entry.mountpoint, entry.type))
        }
        return rows
    }

    // MARK: - Control groups (cgroups: pids controller)

    /// Create a cgroup at `path` (making parents as needed, like `cgcreate`) and
    /// mount its `/sys/fs/cgroup` files. Returns `true` on success.
    @discardableResult
    public func createCgroup(_ path: String) -> Bool {
        kernel.createCgroup(path)
    }

    /// Remove an empty leaf cgroup (no child groups, no live members).
    @discardableResult
    public func removeCgroup(_ path: String) -> Bool {
        kernel.removeCgroup(path)
    }

    /// Set (or clear, with `nil` = unlimited) a cgroup's `pids.max` limit.
    @discardableResult
    public func setCgroupPidsMax(_ path: String, _ max: Int?) -> Bool {
        kernel.setCgroupPidsMax(path, max)
    }

    /// Move *this* process into the cgroup at `path` (the moral equivalent of
    /// writing its pid to `cgroup.procs`). Existing-process migration may place
    /// the group above `pids.max`; the limit applies to subsequent child creation.
    /// Returns `false` only when the path is unknown.
    @discardableResult
    public func joinCgroup(_ path: String) -> Bool {
        kernel.joinCgroup(pid: process.pid, path: path)
    }

    /// Move another process (by pid) into the cgroup at `path`.
    @discardableResult
    public func moveToCgroup(pid: PID, _ path: String) -> Bool {
        kernel.joinCgroup(pid: pid, path: path)
    }

    /// The cgroup path this process currently belongs to (root is "/").
    public var cgroupPath: String { kernel.cgroupPath(of: process.pid) }

    /// `pids.current` for the cgroup at `path`, or `nil` if it does not exist.
    public func cgroupPidsCurrent(_ path: String) -> Int? {
        kernel.cgroupPidsCurrent(path)
    }

}
