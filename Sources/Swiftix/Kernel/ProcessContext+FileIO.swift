/// `ProcessContext` file & descriptor I/O: open/read/write/seek/stat, pipes,
/// dup, poll/select, and the throwing file frontend. Split out of the core
/// `ProcessContext` for readability; same type, same module.
extension ProcessContext {

    // MARK: - File I/O

    /// Open (creating it first if `create` is set) a regular file and return its
    /// descriptor, or `nil` if the path can't be resolved/created.
    public func open(_ path: String,
                     create: Bool = false,
                     truncate: Bool = false,
                     access: FileAccessMode? = nil) -> Int? {
        var flags: OpenFlags = []
        if create { flags.insert(.create) }
        if truncate { flags.insert(.truncate) }
        let inferredAccess: FileAccessMode
        if let access {
            inferredAccess = access
        } else if create || truncate {
            // The legacy convenience API historically returned a handle usable
            // for both the initialization write and a subsequent read/seek.
            inferredAccess = .readWrite
        } else if kernel.vfs.lookup(absolute(path), mounts: mountNS)?.deviceKind != nil {
            inferredAccess = .readWrite
        } else if kernel.vfs.lookup(absolute(path), mounts: mountNS)?.kind == .fifo {
            inferredAccess = .readWrite
        } else {
            inferredAccess = .readOnly
        }
        return try? openFile(path, flags: flags, access: inferredAccess)
    }

    /// Create a directory at `path` (making parents as needed, like `mkdir -p`).
    ///
    /// - Returns: `true` on success, `false` if the path already names a regular
    ///   file.
    @discardableResult
    public func mkdir(_ path: String) -> Bool {
        kernel.vfs.createDirectory(absolute(path), mounts: mountNS) != nil
    }

    /// Remove a file or empty directory at `path` (POSIX `unlink`/`rmdir`).
    ///
    /// - Returns: `true` on success, `false` if the path does not exist or names
    ///   a non-empty directory.
    @discardableResult
    public func remove(_ path: String) -> Bool {
        kernel.vfs.remove(absolute(path), mounts: mountNS)
    }

    /// Metadata for the node at `path`, or `nil` if it does not exist. Symbolic
    /// links are followed (like POSIX `stat`); a dangling link resolves to `nil`.
    public func stat(_ path: String) -> FileStat? {
        guard let node = kernel.vfs.lookup(absolute(path), mounts: mountNS) else { return nil }
        return FileStat(node)
    }

    /// Metadata for the node at `path` without following a final symbolic link.
    public func lstat(_ path: String) -> FileStat? {
        guard let node = kernel.vfs.lookup(absolute(path), follow: false, mounts: mountNS) else { return nil }
        return FileStat(node)
    }

    /// Create a symbolic link at `path` pointing at `target` (POSIX `symlink`).
    /// `target` is stored verbatim and resolved on lookup (absolute, or relative
    /// to the link's own directory).
    ///
    /// - Returns: `true` on success, `false` if `path` already exists.
    @discardableResult
    public func symlink(_ target: String, at path: String) -> Bool {
        kernel.vfs.createSymlink(absolute(path), target: target, mounts: mountNS) != nil
    }

    /// The target path of the symbolic link at `path` (POSIX `readlink`), or
    /// `nil` if `path` is not a symbolic link. Does not follow the final link.
    public func readlink(_ path: String) -> String? {
        guard let node = kernel.vfs.lookup(absolute(path), follow: false, mounts: mountNS),
              node.kind == .symlink else { return nil }
        return node.linkTarget
    }

    // MARK: - Hard links

    /// Create a hard link: a new directory entry at `linkPath` that references the
    /// same inode as `targetPath` (POSIX `link`). Fails if `targetPath` is a
    /// directory or doesn't exist, or if `linkPath` already exists.
    @discardableResult
    public func link(_ targetPath: String, at linkPath: String) -> Bool {
        kernel.vfs.link(absolute(targetPath), at: absolute(linkPath), mounts: mountNS)
    }

    // MARK: - Named pipes (FIFO)

    /// Create a named pipe (FIFO) at `path` (POSIX `mkfifo`). Returns `true` on
    /// success, `false` if the path already exists.
    @discardableResult
    public func mkfifo(_ path: String) -> Bool {
        kernel.vfs.createFifo(absolute(path), mounts: mountNS) != nil
    }

    // MARK: - Advisory file locking (flock)

    /// Lock operation type for `flock()`.
    public enum LockOperation {
        /// Shared (read) lock — multiple processes can hold simultaneously.
        case shared
        /// Exclusive (write) lock — only one holder at a time.
        case exclusive
        /// Release the lock.
        case unlock
    }

    /// Apply an advisory lock on the open file descriptor `fd` (POSIX `flock`).
    /// The lock is per-inode, so hard-linked paths share the same lock state.
    /// Returns `true` on success; `false` means the lock could not be acquired
    /// (non-blocking try).
    @discardableResult
    public func flock(_ fd: Int, operation: LockOperation) -> Bool {
        guard let handle = process.fileDescriptors.object(fd) as? RegularFileHandle else { return false }
        let node = handle.underlyingNode
        let holder = ObjectIdentifier(handle).hashValue
        switch operation {
        case .shared:
            return node.acquireSharedLock(holder: holder)
        case .exclusive:
            return node.acquireExclusiveLock(holder: holder)
        case .unlock:
            return node.releaseLock(holder: holder)
        }
    }

    // MARK: - Timestamps

    /// Update the access and modification times of `path` to `now` (like `touch`).
    /// If `atime`/`mtime` are provided they override `now`. Returns `false` if the
    /// path doesn't exist.
    @discardableResult
    public func utimes(_ path: String, atime: Double? = nil, mtime: Double? = nil) -> Bool {
        guard let node = kernel.vfs.lookup(absolute(path), mounts: mountNS) else { return false }
        let now = kernel.loop.now
        node.atime = atime ?? now
        node.mtime = mtime ?? now
        node.ctime = now
        return true
    }

    /// Reposition a descriptor's read offset (POSIX `lseek`). `whence` is 0 (SET),
    /// 1 (CUR), or 2 (END). Returns the new absolute offset, or `nil` if `fd` is
    /// not a seekable descriptor or the resulting offset is negative.
    public func seek(_ fd: Int, to offset: Int, whence: Int) -> Int? {
        guard let seekable = process.fileDescriptors.object(fd) as? Seekable else { return nil }
        let base: Int
        switch whence {
        case 1: base = seekable.seekOffset
        case 2: base = seekable.byteSize
        default: base = 0
        }
        let (target, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, target >= 0 else { return nil }
        seekable.seekOffset = target
        return target
    }

    public func read(_ fd: Int, max: Int) -> [UInt8] {
        guard process.fileDescriptors.access(fd)?.canRead == true else { return [] }
        return process.fileDescriptors.object(fd)?.read(max: max) ?? []
    }

    @discardableResult
    public func write(_ fd: Int, _ bytes: [UInt8]) -> Int {
        guard process.fileDescriptors.access(fd)?.canWrite == true else { return 0 }
        return process.fileDescriptors.object(fd)?.write(bytes) ?? 0
    }

    /// Current file-status flags for an open descriptor, or `nil` if it is not open.
    public func fileStatusFlags(_ fd: Int) -> FileStatusFlags? {
        process.fileDescriptors.flags(fd)
    }

    /// Access mode captured when the descriptor was opened.
    public func fileAccessMode(_ fd: Int) -> FileAccessMode? {
        process.fileDescriptors.access(fd)
    }

    /// Replace the file-status flags for an open descriptor.
    @discardableResult
    public func setFileStatusFlags(_ fd: Int, _ flags: FileStatusFlags) -> Bool {
        process.fileDescriptors.setFlags(fd, flags)
    }

    /// Convenience for toggling POSIX-style non-blocking I/O.
    @discardableResult
    public func setNonBlocking(_ fd: Int, _ enabled: Bool = true) -> Bool {
        guard var flags = fileStatusFlags(fd) else { return false }
        if enabled {
            flags.insert(.nonBlocking)
        } else {
            flags.remove(.nonBlocking)
        }
        return setFileStatusFlags(fd, flags)
    }

    /// Current readiness for a descriptor, or `nil` if it is not open.
    public func readiness(_ fd: Int) -> IOReadiness? {
        guard let object = process.fileDescriptors.object(fd),
              let access = process.fileDescriptors.access(fd) else { return nil }
        return readiness(of: object, limitedBy: access)
    }

    /// Non-blocking readiness snapshot for a set of descriptors.
    ///
    /// This is the kernel-side contract that future blocking `poll`/`select`
    /// syscalls can park on. For now it returns immediately with descriptors whose
    /// current readiness intersects the requested interests; hangup/error are
    /// reported even when not explicitly requested, matching POSIX-style polling.
    public func poll(_ requests: [PollRequest]) -> [PollResult] {
        requests.compactMap { request in
            guard let object = process.fileDescriptors.object(request.fd) else {
                return PollResult(fd: request.fd, readiness: .error)
            }
            let exceptional: IOReadiness = [.hangup, .error]
            let access = process.fileDescriptors.access(request.fd) ?? .none
            let readiness = readiness(of: object, limitedBy: access)
                .intersection(request.interests.union(exceptional))
            guard !readiness.isEmpty else { return nil }
            return PollResult(fd: request.fd, readiness: readiness)
        }
    }

    private func readiness(of object: FileObject, limitedBy access: FileAccessMode) -> IOReadiness {
        var readiness = object.readiness
        if !access.canRead { readiness.remove(.readable) }
        if !access.canWrite { readiness.remove(.writable) }
        return readiness
    }

    /// Blocking readiness wait. Resumes when at least one requested descriptor is
    /// ready, or when `timeout` expires. A `nil` timeout waits indefinitely; a
    /// zero timeout is equivalent to the non-blocking snapshot.
    public func poll(_ requests: [PollRequest],
                     timeout: Double? = nil,
                     resume: @escaping ([PollResult]) -> Void) {
        let immediate = poll(requests)
        let kernel = self.kernel
        let process = self.process
        if !immediate.isEmpty || timeout == 0 {
            process.blockedOn += 1
            kernel.runStep(process) {
                process.blockedOn -= 1
                resume(immediate)
            }
            return
        }

        final class WaitState {
            var completed = false
            var subscriptions: [ReadinessSubscription] = []
            var finish: (() -> Void)?
            var cancellationID: Int?

            func cancelSubscriptions() {
                for subscription in subscriptions {
                    subscription.cancel()
                }
                subscriptions.removeAll()
            }

            func complete() {
                guard !completed else { return }
                completed = true
                cancelSubscriptions()
                let action = finish
                finish = nil
                action?()
            }

            func cancel(process: Process?) {
                guard !completed else { return }
                completed = true
                cancelSubscriptions()
                finish = nil
                if let process, process.blockedOn > 0 {
                    process.blockedOn -= 1
                }
            }
        }

        let state = WaitState()
        process.blockedOn += 1
        let context = self

        state.finish = { [context, weak kernel, weak process] in
            guard let kernel, let process else { return }
            if let cancellationID = state.cancellationID {
                process.removeWaitCancellation(cancellationID)
            }
            kernel.runStep(process) {
                process.blockedOn -= 1
                resume(context.poll(requests))
            }
        }
        state.cancellationID = process.addWaitCancellation { [state, weak process] in
            state.cancel(process: process)
        }
        let complete: () -> Void = { [state] in state.complete() }

        for request in requests {
            guard let source = process.fileDescriptors.object(request.fd) as? ReadinessEventSource else { continue }
            state.subscriptions.append(source.addReadinessListener(complete))
        }

        if state.subscriptions.isEmpty && timeout == nil {
            complete()
            return
        }

        if let timeout {
            kernel.schedule(after: timeout, complete)
        }
    }

    public func close(_ fd: Int) {
        process.fileDescriptors.close(fd)
    }

    // MARK: - select (POSIX-style multi-fd readiness)

    /// Result of a `select` call: fd sets that are ready.
    public struct SelectResult: Equatable, Sendable {
        public let readableFDs: [Int]
        public let writableFDs: [Int]
        public let exceptionalFDs: [Int]

        /// Total number of ready descriptors.
        public var count: Int { readableFDs.count + writableFDs.count + exceptionalFDs.count }
    }

    /// Non-blocking `select`: returns immediately with the subset of requested fds
    /// that are currently ready.
    public func select(readFDs: [Int] = [], writeFDs: [Int] = [], exceptFDs: [Int] = []) -> SelectResult {
        let results = poll(buildSelectRequests(readFDs: readFDs, writeFDs: writeFDs, exceptFDs: exceptFDs))
        return buildSelectResult(results, readFDs: readFDs, writeFDs: writeFDs, exceptFDs: exceptFDs)
    }

    /// Blocking `select`: parks the process until at least one requested fd is
    /// ready or the timeout expires. Timeout `nil` waits indefinitely; `0` returns
    /// immediately (same as non-blocking `select`).
    public func select(readFDs: [Int] = [], writeFDs: [Int] = [], exceptFDs: [Int] = [],
                       timeout: Double? = nil,
                       resume: @escaping (SelectResult) -> Void) {
        let requests = buildSelectRequests(readFDs: readFDs, writeFDs: writeFDs, exceptFDs: exceptFDs)
        poll(requests, timeout: timeout) { [self] results in
            resume(self.buildSelectResult(results, readFDs: readFDs, writeFDs: writeFDs, exceptFDs: exceptFDs))
        }
    }

    private func buildSelectRequests(readFDs: [Int], writeFDs: [Int], exceptFDs: [Int]) -> [PollRequest] {
        var seen = Set<Int>()
        var requests: [PollRequest] = []
        for fd in readFDs where seen.insert(fd).inserted {
            requests.append(PollRequest(fd: fd, interests: .readable))
        }
        for fd in writeFDs where seen.insert(fd).inserted {
            requests.append(PollRequest(fd: fd, interests: .writable))
        }
        for fd in exceptFDs where seen.insert(fd).inserted {
            requests.append(PollRequest(fd: fd, interests: [.hangup, .error]))
        }
        // Fds in multiple sets: merge interests.
        var merged: [Int: IOReadiness] = [:]
        for fd in readFDs { merged[fd, default: []] .insert(.readable) }
        for fd in writeFDs { merged[fd, default: []] .insert(.writable) }
        for fd in exceptFDs { merged[fd, default: []] .formUnion([.hangup, .error]) }
        return merged.map { PollRequest(fd: $0.key, interests: $0.value) }
    }

    private func buildSelectResult(_ results: [PollResult],
                                   readFDs: [Int], writeFDs: [Int], exceptFDs: [Int]) -> SelectResult {
        let readSet = Set(readFDs)
        let writeSet = Set(writeFDs)
        let exceptSet = Set(exceptFDs)
        var readable: [Int] = []
        var writable: [Int] = []
        var exceptional: [Int] = []
        for result in results {
            if readSet.contains(result.fd), result.readiness.contains(.readable) {
                readable.append(result.fd)
            }
            if writeSet.contains(result.fd), result.readiness.contains(.writable) {
                writable.append(result.fd)
            }
            if exceptSet.contains(result.fd), !result.readiness.intersection([.hangup, .error]).isEmpty {
                exceptional.append(result.fd)
            }
        }
        return SelectResult(readableFDs: readable.sorted(),
                            writableFDs: writable.sorted(),
                            exceptionalFDs: exceptional.sorted())
    }

    /// List the entries of the directory at `path`. Returns the child names
    /// sorted, each with a trailing "/" when the entry is itself a directory,
    /// or `nil` when `path` does not resolve to a directory. Used by the shell
    /// `ls` built-in; procfs directories (e.g. `/proc/net`) list too.
    public func listDirectory(_ path: String) -> [String]? {
        guard let node = kernel.vfs.lookup(absolute(path), mounts: mountNS),
              node.kind == .directory else { return nil }
        var entries = node.children.values
            .map { $0.kind == .directory ? $0.name + "/" : $0.name }
        // Computed entries of a dynamic directory (e.g. live pids under /proc);
        // they are directories, so they list with a trailing "/".
        if let dynamic = node.dynamicChildNames?() {
            entries += dynamic.map { $0 + "/" }
        }
        return entries.sorted()
    }

    // MARK: - File I/O (throwing frontend)
    //
    // Throwing file helpers surface typed `SyscallError` values for hard
    // failures while keeping EOF as a successful empty read.

    /// Open (creating it first if `create` is set) a regular file and return its
    /// descriptor.
    ///
    /// - Throws: `SyscallError.noSuchFileOrDirectory` when the path does not
    ///   resolve to an existing node and `create` is `false` (R5.1);
    ///   `SyscallError.isADirectory` when the path resolves to a directory that is
    ///   being opened as a regular file (R5.2).
    public func openFile(_ path: String,
                         create: Bool = false,
                         truncate: Bool = false,
                         access: FileAccessMode? = nil) throws -> Int {
        var flags: OpenFlags = []
        if create { flags.insert(.create) }
        if truncate { flags.insert(.truncate) }
        let inferredAccess = access ?? ((create || truncate) ? .readWrite : .readOnly)
        return try openFile(path, flags: flags, access: inferredAccess)
    }

    /// Open a regular file with POSIX-style open flags.
    public func openFile(_ path: String, flags: OpenFlags) throws -> Int {
        let inferredAccess: FileAccessMode = flags.intersection([.create, .truncate, .append]).isEmpty
            ? .readOnly
            : .readWrite
        return try openFile(path, flags: flags, access: inferredAccess)
    }

    /// Open a regular file with explicit descriptor access rights.
    public func openFile(_ path: String,
                         flags: OpenFlags,
                         access: FileAccessMode) throws -> Int {
        let resolved = absolute(path)
        let existing = kernel.vfs.lookup(resolved, mounts: mountNS)
        return try openFileNode(existing: existing,
                                create: { kernel.vfs.createFile(resolved, mounts: mountNS) },
                                flags: flags,
                                access: access)
    }

    /// Open a path relative to a filesystem capability. Absolute paths and
    /// lexical `..` traversal above the capability root are rejected, while
    /// symlink resolution remains anchored beneath the same root.
    public func openFile(_ path: String,
                         in scope: FileSystemScope,
                         flags: OpenFlags = [],
                         access: FileAccessMode = .readOnly) throws -> Int {
        let (root, relative) = try scopedRootAndPath(scope, path)
        let existing = kernel.vfs.lookup(relative, beneath: root)
        return try openFileNode(existing: existing,
                                create: { kernel.vfs.createFile(relative, beneath: root) },
                                flags: flags,
                                access: access)
    }

    /// Metadata for a path relative to a filesystem capability.
    public func stat(_ path: String, in scope: FileSystemScope) throws -> FileStat {
        let (root, relative) = try scopedRootAndPath(scope, path)
        guard let node = kernel.vfs.lookup(relative, beneath: root) else {
            throw SyscallError.noSuchFileOrDirectory
        }
        return FileStat(node)
    }

    /// Enumerate a directory relative to a filesystem capability. Entries are
    /// stable-sorted and carry their type so an ABI host can encode directory
    /// records without exposing VFS implementation objects.
    public func listDirectory(_ path: String,
                              in scope: FileSystemScope) throws -> [FileSystemDirectoryEntry] {
        let (root, relative) = try scopedRootAndPath(scope, path)
        guard let node = kernel.vfs.lookup(relative, beneath: root) else {
            throw SyscallError.noSuchFileOrDirectory
        }
        guard node.kind == .directory else { throw SyscallError.notADirectory }
        var entries = node.children.values.map {
            FileSystemDirectoryEntry(name: $0.name, type: $0.fileType)
        }
        if let dynamic = node.dynamicChildNames?() {
            entries += dynamic.map { FileSystemDirectoryEntry(name: $0, type: .directory) }
        }
        return entries.sorted { $0.name < $1.name }
    }

    /// Create one directory relative to a filesystem capability.
    public func mkdir(_ path: String, in scope: FileSystemScope) throws {
        let (root, relative) = try scopedRootAndPath(scope, path)
        if kernel.vfs.lookup(relative, follow: false, beneath: root) != nil {
            throw SyscallError.fileExists
        }
        guard kernel.vfs.createDirectory(relative, beneath: root) != nil else {
            throw SyscallError.noSuchFileOrDirectory
        }
    }

    /// Remove a file or empty directory relative to a filesystem capability.
    public func remove(_ path: String, in scope: FileSystemScope) throws {
        let (root, relative) = try scopedRootAndPath(scope, path)
        guard kernel.vfs.lookup(relative, follow: false, beneath: root) != nil else {
            throw SyscallError.noSuchFileOrDirectory
        }
        guard kernel.vfs.remove(relative, beneath: root) else {
            throw SyscallError.permissionDenied
        }
    }

    /// Unlink a non-directory node relative to a filesystem capability.
    public func unlinkFile(_ path: String, in scope: FileSystemScope) throws {
        let (root, relative) = try scopedRootAndPath(scope, path)
        guard let node = kernel.vfs.lookup(relative, follow: false, beneath: root) else {
            throw SyscallError.noSuchFileOrDirectory
        }
        guard node.kind != .directory else { throw SyscallError.isADirectory }
        guard kernel.vfs.remove(relative, beneath: root) else {
            throw SyscallError.permissionDenied
        }
    }

    /// Remove an empty directory relative to a filesystem capability.
    public func removeDirectory(_ path: String, in scope: FileSystemScope) throws {
        let (root, relative) = try scopedRootAndPath(scope, path)
        guard let node = kernel.vfs.lookup(relative, follow: false, beneath: root) else {
            throw SyscallError.noSuchFileOrDirectory
        }
        guard node.kind == .directory else { throw SyscallError.notADirectory }
        guard node.children.isEmpty else { throw SyscallError.directoryNotEmpty }
        guard kernel.vfs.remove(relative, beneath: root) else {
            throw SyscallError.permissionDenied
        }
    }

    /// Rename a node between two capability-scoped directory trees. The VFS
    /// preserves the node object, so already-open file descriptions continue to
    /// reference the same contents after the move.
    public func rename(_ sourcePath: String,
                       in sourceScope: FileSystemScope,
                       to destinationPath: String,
                       in destinationScope: FileSystemScope) throws {
        let (sourceRoot, sourceRelative) = try scopedRootAndPath(sourceScope, sourcePath)
        let (destinationRoot, destinationRelative) = try scopedRootAndPath(destinationScope, destinationPath)
        do {
            try kernel.vfs.rename(sourceRelative,
                                  beneath: sourceRoot,
                                  to: destinationRelative,
                                  beneath: destinationRoot)
        } catch let error as VirtualFileSystem.RenameError {
            switch error {
            case .missingSource, .missingParent:
                throw SyscallError.noSuchFileOrDirectory
            case .sourceIsDirectory:
                throw SyscallError.isADirectory
            case .destinationIsDirectory:
                throw SyscallError.notADirectory
            case .destinationNotEmpty:
                throw SyscallError.directoryNotEmpty
            case .invalidMove:
                throw SyscallError.invalidArgument
            }
        }
    }

    private func scopedRootAndPath(_ scope: FileSystemScope,
                                   _ path: String) throws -> (VNode, String) {
        guard !path.hasPrefix("/") else { throw SyscallError.capabilityViolation }

        var depth = 0
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                guard depth > 0 else { throw SyscallError.capabilityViolation }
                depth -= 1
            default:
                depth += 1
            }
        }

        guard let root = kernel.vfs.lookup(absolute(scope.rootPath), mounts: mountNS) else {
            throw SyscallError.noSuchFileOrDirectory
        }
        guard root.kind == .directory else { throw SyscallError.invalidArgument }
        return (root, path)
    }

    private func openFileNode(existing: VNode?,
                              create: () -> VNode?,
                              flags: OpenFlags,
                              access: FileAccessMode) throws -> Int {
        // Report a directory target as `.isADirectory` regardless of `create`, so
        // opening an existing directory as a file is never mistaken for a missing
        // path or a creation failure (R5.2).
        if existing != nil, flags.contains(.exclusive), flags.contains(.create) {
            throw SyscallError.fileExists
        }
        if let existing, existing.kind == .directory {
            throw SyscallError.isADirectory
        }
        // Named pipe (FIFO): opening it creates a FifoEndpoint connected to the
        // node's shared PipeBuffer. The first open lazily creates the buffer.
        if let existing, existing.kind == .fifo {
            if access.canRead, !permits(existing, write: false) { throw SyscallError.permissionDenied }
            if access.canWrite, !permits(existing, write: true) { throw SyscallError.permissionDenied }
            if existing.fifoBuffer == nil { existing.fifoBuffer = PipeBuffer() }
            let buffer = existing.fifoBuffer!
            let isWrite = access.canWrite && !access.canRead
            let endpoint = FifoEndpoint(buffer: buffer, isWriteEnd: isWrite, vnode: existing)
            let fd = process.fileDescriptors.allocate(endpoint, access: access)
            existing.touchAccess(kernel.loop.now)
            return fd
        }
        guard access.canWrite || flags.intersection([.create, .truncate, .append]).isEmpty else {
            throw SyscallError.invalidArgument
        }
        // Permission check (EACCES) against the exact access carried by the new
        // descriptor. Root bypasses all checks, matching Unix. Creating a brand-new
        // file still skips parent-directory enforcement, which remains out of scope.
        if let existing, existing.kind == .file {
            if access.canRead, !permits(existing, write: false) { throw SyscallError.permissionDenied }
            if access.canWrite, !permits(existing, write: true) { throw SyscallError.permissionDenied }
        }
        let node = flags.contains(.create) ? create() : existing
        guard let node else {
            throw SyscallError.noSuchFileOrDirectory
        }
        guard node.kind == .file else {
            throw SyscallError.isADirectory
        }
        if existing == nil {
            node.uid = process.uid
            node.gid = process.gid
        }

        var descriptorFlags: FileStatusFlags = []
        if flags.contains(.nonBlocking) {
            descriptorFlags.insert(.nonBlocking)
        }

        // A device file (e.g. /dev/null) gets its device backing instead of a
        // stored-bytes handle; truncation is meaningless for it.
        if let deviceKind = node.deviceKind {
            switch deviceKind {
            case .null:
                return process.fileDescriptors.allocate(NullDeviceHandle(),
                                                        flags: descriptorFlags,
                                                        access: access)
            }
        }

        if flags.contains(.truncate) {
            node.truncate()
            node.touchModify(kernel.loop.now)
        }
        let clock = kernel.vfs.clock
        return process.fileDescriptors.allocate(RegularFileHandle(vnode: node,
                                                                  appendWrites: flags.contains(.append),
                                                                  clock: clock),
                                                flags: descriptorFlags,
                                                access: access)
    }

    /// Read up to `max` bytes from a descriptor.
    ///
    /// A valid descriptor whose stream is genuinely at end of stream returns an
    /// empty byte sequence as a *successful* result — EOF is distinct from an
    /// error and from `.wouldBlock` (R5.4, R5.6).
    ///
    /// - Throws: `SyscallError.badFileDescriptor` when `fd` is not allocated in the
    ///   calling process (R5.3, R5.5).
    public func readFile(_ fd: Int, max: Int) throws -> [UInt8] {
        guard let object = process.fileDescriptors.object(fd),
              process.fileDescriptors.access(fd)?.canRead == true else {
            throw SyscallError.badFileDescriptor
        }
        if fileStatusFlags(fd)?.contains(.nonBlocking) == true,
           let stream = object as? ReadableStream,
           !stream.hasBytesAvailable {
            throw SyscallError.wouldBlock
        }
        return object.read(max: max)
    }

    /// Write `bytes` to a descriptor and return the number of bytes accepted.
    ///
    /// - Throws: `SyscallError.badFileDescriptor` when `fd` is not allocated in the
    ///   calling process (R5.3).
    @discardableResult
    public func writeFile(_ fd: Int, _ bytes: [UInt8]) throws -> Int {
        guard let object = process.fileDescriptors.object(fd),
              process.fileDescriptors.access(fd)?.canWrite == true else {
            throw SyscallError.badFileDescriptor
        }
        let readiness = object.readiness
        if !bytes.isEmpty,
           fileStatusFlags(fd)?.contains(.nonBlocking) == true,
           !readiness.contains(.writable),
           !readiness.contains(.hangup) {
            throw SyscallError.wouldBlock
        }
        return object.write(bytes)
    }

    /// Close a descriptor.
    ///
    /// - Throws: `SyscallError.badFileDescriptor` when `fd` is not allocated in the
    ///   calling process (R5.3).
    public func closeFile(_ fd: Int) throws {
        guard process.fileDescriptors.object(fd) != nil else {
            throw SyscallError.badFileDescriptor
        }
        process.fileDescriptors.close(fd)
    }

    /// Create a pipe; returns the (read, write) descriptors.
    public func pipe() -> (read: Int, write: Int) {
        let shared = PipeBuffer()
        let read = process.fileDescriptors.allocate(PipeEndpoint(buffer: shared, isWriteEnd: false),
                                                    access: .readOnly)
        let write = process.fileDescriptors.allocate(PipeEndpoint(buffer: shared, isWriteEnd: true),
                                                     access: .writeOnly)
        return (read, write)
    }

    /// Duplicate `fd` to the lowest free descriptor (POSIX `dup`); both share the
    /// same open-file description. Returns the new descriptor, or `nil` if `fd`
    /// is not open.
    public func dup(_ fd: Int) -> Int? {
        guard let object = process.fileDescriptors.object(fd) else { return nil }
        return process.fileDescriptors.allocate(object,
                                                flags: fileStatusFlags(fd) ?? [],
                                                access: fileAccessMode(fd) ?? .readWrite)
    }

    /// Duplicate `fd` onto `target` (POSIX `dup2`): after the call `target` refers
    /// to the same open-file description as `fd`, and anything previously open at
    /// `target` is closed. Used to wire stdin/stdout to pipes and files for
    /// redirection. No-op success when `fd == target`.
    ///
    /// - Returns: `true` on success, `false` if `fd` is not open.
    @discardableResult
    public func dup2(_ fd: Int, onto target: Int) -> Bool {
        guard let object = process.fileDescriptors.object(fd) else { return false }
        if fd == target { return true }
        process.fileDescriptors.install(object,
                                        at: target,
                                        flags: fileStatusFlags(fd) ?? [],
                                        access: fileAccessMode(fd) ?? .readWrite)
        return true
    }

    /// Convenience: write a UTF-8 string to stdout (fd 1).
    public func print(_ string: String) {
        write(1, Array(string.utf8))
    }

}
