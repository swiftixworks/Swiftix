/// A VFS node (inode). A node is a directory (named entries), a regular file
/// (byte contents), a symbolic link (a stored target path resolved on lookup),
/// or a named pipe (FIFO). Ownership (uid/gid) and mode bits are enforced when
/// a process opens a file; root retains the usual bypass.
///
/// Hard links: multiple directory entries may reference the same VNode. The
/// `nlink` count tracks how many directory entries point here; `unlinked` is set
/// when the *last* directory entry is removed but open file descriptors still
/// reference the node (deferred deletion / POSIX unlink-while-open semantics).
final class VNode {
    enum Kind {
        case directory
        case file
        case symlink
        /// A named pipe (FIFO): two unrelated processes can open the same path
        /// and communicate through the shared `PipeBuffer`.
        case fifo
    }

    let kind: Kind
    var mode: FileMode
    /// Owner user ID (default 0 = root).
    var uid: UInt32 = 0
    /// Owner group ID (default 0 = root).
    var gid: UInt32 = 0
    private(set) var children: [String: VNode] = [:]
    private(set) var fileContents: [UInt8] = []

    /// The target path of a symbolic link (absolute or relative to the link's
    /// directory). Empty for non-symlink nodes; resolved by `VirtualFileSystem`.
    let linkTarget: String

    /// Synthetic (procfs/sysfs) file: contents are computed by this closure when
    /// the file is opened, instead of being stored. `nil` for ordinary files.
    var provider: (() -> [UInt8])?

    /// Dynamic-directory hooks for synthetic trees whose children come and go
    /// (e.g. `/proc/<pid>`). On a directory node, `dynamicChildNames` supplies the
    /// live child names for listing, and `resolveDynamicChild` builds a transient
    /// child node when one is looked up. Real children (in `children`) always take
    /// precedence, so these only add computed entries. `nil` for ordinary dirs.
    var dynamicChildNames: (() -> [String])?
    var resolveDynamicChild: ((String) -> VNode?)?

    /// A special device file (like `/dev/null`) whose reads/writes are handled by
    /// a device backing rather than stored bytes. `nil` for ordinary files.
    var deviceKind: DeviceKind?

    /// The kinds of special device file the VFS models.
    enum DeviceKind {
        /// `/dev/null` — discards writes, reads as end-of-file.
        case null
    }

    // MARK: - Hard links & deferred deletion

    /// Number of directory entries that reference this inode. Starts at 1 for
    /// files/symlinks/fifos (directories start at 2: the entry in the parent +
    /// the implicit `.` self-link). A hard link (`link()`) increments this; an
    /// unlink decrements it. When it reaches 0 *and* `openHandles == 0` the node
    /// is eligible for deallocation (deferred deletion).
    var nlink: Int

    /// Count of open-file descriptions referencing this node (across all
    /// processes). `dup` and spawn inheritance share a description, so the count
    /// changes only on independent opens and last-close. When both `nlink == 0` and
    /// `openHandles == 0`, the node's data is released.
    var openHandles: Int = 0

    /// Set to `true` when the last directory entry is removed but `openHandles >
    /// 0` — the inode is unreachable by path but still alive for existing readers/
    /// writers. Data is released when the last handle closes.
    var unlinked: Bool = false

    // MARK: - Timestamps (logical clock ticks from EventLoop.now)

    /// Last access time (read). Updated by `read` operations.
    var atime: Double = 0
    /// Last modification time (data change). Updated by `write`/`truncate`.
    var mtime: Double = 0
    /// Last status-change time (metadata change: chmod, chown, link, unlink).
    var ctime: Double = 0

    // MARK: - Named pipe (FIFO) backing

    /// The shared pipe buffer for a `.fifo` node. Created lazily on first open.
    var fifoBuffer: PipeBuffer?

    // MARK: - File locking (advisory, flock-style)

    /// Advisory lock state for this inode. Processes acquire shared (read) or
    /// exclusive (write) locks; they are advisory (not enforced on I/O), matching
    /// POSIX `flock` semantics. The lock table lives on the inode so hard-linked
    /// paths share the same lock set.
    var lockState: FileLockState = .unlocked

    /// Advisory file lock states, modeled after POSIX `flock()`.
    enum FileLockState {
        /// No lock held.
        case unlocked
        /// One or more shared (read) locks held — additional shared locks are
        /// allowed; an exclusive lock must wait.
        case shared(holders: Set<Int>)
        /// Exactly one exclusive (write) lock held.
        case exclusive(holder: Int)
    }

    init(directory _: String) {
        self.kind = .directory
        self.mode = .directoryDefault
        self.linkTarget = ""
        self.nlink = 2  // parent entry + implicit "."
    }

    init(file _: String) {
        self.kind = .file
        self.mode = .regularDefault
        self.linkTarget = ""
        self.nlink = 1
    }

    init(symlink _: String, target: String) {
        self.kind = .symlink
        self.mode = .symlinkDefault
        self.linkTarget = target
        self.nlink = 1
    }

    init(fifo _: String) {
        self.kind = .fifo
        self.mode = .fifoDefault
        self.linkTarget = ""
        self.nlink = 1
    }

    func child(_ name: String) -> VNode? {
        children[name]
    }

    /// Add one directory entry. The name belongs to the containing directory,
    /// not to the inode: hard links can therefore give the same VNode multiple
    /// independent names without choosing a mutable "canonical" name.
    @discardableResult
    func addChild(name: String, node: VNode) -> VNode {
        children[name] = node
        return node
    }

    @discardableResult
    func removeChild(_ name: String) -> Bool {
        children.removeValue(forKey: name) != nil
    }

    /// Byte size of a regular file (synthetic files report their current computed
    /// size); a symlink reports the length of its target path; directories and
    /// fifos report 0.
    var size: Int {
        switch kind {
        case .file: return (provider?() ?? fileContents).count
        case .symlink: return linkTarget.utf8.count
        case .directory, .fifo: return 0
        }
    }

    var fileType: FileType {
        switch kind {
        case .directory: return .directory
        case .file: return .regular
        case .symlink: return .symlink
        case .fifo: return .fifo
        }
    }

    func appendFileContents(_ bytes: [UInt8]) {
        guard kind == .file else { return }
        fileContents.append(contentsOf: bytes)
    }

    /// Write bytes at an explicit file offset, extending with zero-filled holes
    /// when necessary. Returns the number of accepted bytes.
    @discardableResult
    func writeFileContents(_ bytes: [UInt8], at offset: Int) -> Int {
        guard kind == .file,
              offset >= 0,
              provider == nil,
              !offset.addingReportingOverflow(bytes.count).overflow else { return 0 }
        if offset > fileContents.count {
            fileContents.append(contentsOf: repeatElement(0, count: offset - fileContents.count))
        }
        let replaceCount = Swift.min(bytes.count, fileContents.count - offset)
        if replaceCount > 0 {
            fileContents.replaceSubrange(offset..<(offset + replaceCount), with: bytes.prefix(replaceCount))
        }
        if replaceCount < bytes.count {
            fileContents.append(contentsOf: bytes.dropFirst(replaceCount))
        }
        return bytes.count
    }

    func truncate() {
        fileContents = []
    }

    /// Replace a regular file's contents wholesale — used when restoring a
    /// filesystem snapshot.
    func setFileContents(_ bytes: [UInt8]) {
        guard kind == .file else { return }
        fileContents = bytes
    }

    /// Detach every child. Kept for callers that intentionally clear a detached
    /// directory; filesystem restore uses `adoptRestoredDirectoryState` so a
    /// failed preflight never clears the live root first.
    func removeAllChildren() {
        children.removeAll()
    }

    /// Atomically adopt a fully-built detached directory's persisted state while
    /// retaining this VNode's identity. The VFS root is referenced by namespace
    /// and mount objects, so replacing the root object would leave stale graphs;
    /// swapping its value state only after validation preserves those references.
    func adoptRestoredDirectoryState(from source: VNode) {
        guard kind == .directory, source.kind == .directory else { return }
        mode = source.mode
        uid = source.uid
        gid = source.gid
        children = source.children
        fileContents = []
        provider = nil
        dynamicChildNames = nil
        resolveDynamicChild = nil
        deviceKind = nil
        nlink = source.nlink
        openHandles = 0
        unlinked = false
        atime = source.atime
        mtime = source.mtime
        ctime = source.ctime
        fifoBuffer = nil
        lockState = .unlocked
    }

    // MARK: - Timestamp helpers

    /// Mark access time (read).
    func touchAccess(_ now: Double) { atime = now }

    /// Mark data modification (write/truncate/append).
    func touchModify(_ now: Double) { mtime = now; ctime = now }

    /// Mark metadata change (chmod, chown, link, unlink, rename).
    func touchChange(_ now: Double) { ctime = now }

    /// Set all three timestamps at once — used at creation time.
    func touchAll(_ now: Double) { atime = now; mtime = now; ctime = now }

    // MARK: - Advisory file locking (flock)

    /// Attempt to acquire a shared (read) lock for the given holder id.
    /// Returns `true` on success; fails when an exclusive lock is held by another.
    func acquireSharedLock(holder: Int) -> Bool {
        switch lockState {
        case .unlocked:
            lockState = .shared(holders: [holder])
            return true
        case .shared(var holders):
            holders.insert(holder)
            lockState = .shared(holders: holders)
            return true
        case .exclusive(let existing):
            return existing == holder  // re-entrant (same holder holds exclusive → already locked)
        }
    }

    /// Attempt to acquire an exclusive (write) lock for the given holder id.
    /// Returns `true` on success; fails when any other lock is held.
    func acquireExclusiveLock(holder: Int) -> Bool {
        switch lockState {
        case .unlocked:
            lockState = .exclusive(holder: holder)
            return true
        case .shared(let holders):
            if holders == [holder] {
                // Upgrade: only this holder has a shared lock → promote to exclusive.
                lockState = .exclusive(holder: holder)
                return true
            }
            return false
        case .exclusive(let existing):
            return existing == holder
        }
    }

    /// Release any lock held by `holder`. Returns `true` if the holder had a lock.
    @discardableResult
    func releaseLock(holder: Int) -> Bool {
        switch lockState {
        case .unlocked:
            return false
        case .shared(var holders):
            guard holders.remove(holder) != nil else { return false }
            lockState = holders.isEmpty ? .unlocked : .shared(holders: holders)
            return true
        case .exclusive(let existing):
            guard existing == holder else { return false }
            lockState = .unlocked
            return true
        }
    }

    /// Whether a lock is currently held (by anyone).
    var isLocked: Bool {
        switch lockState {
        case .unlocked: return false
        default: return true
        }
    }
}
