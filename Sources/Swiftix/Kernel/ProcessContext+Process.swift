/// `ProcessContext` process-level syscalls: process control + the command
/// table, signals, credentials, block devices, timers, and child waiting.
extension ProcessContext {

    // MARK: - Process control

    @discardableResult
    public func spawn(_ name: String, args: [String] = [],
                      _ body: @escaping (ProcessContext) -> Void) -> PID {
        kernel.spawn(name, args: args, parent: process.pid, body)
    }

    /// Spawn a child whose body is an `async` function (uses the loop-bound
    /// executor). Lets a program launch long-running or `await`-driven children
    /// (servers, clients) with the same ergonomics as the synchronous overload.
    @discardableResult
    public func spawn(_ name: String, args: [String] = [],
                      _ body: @escaping (ProcessContext) async -> Void) -> PID {
        kernel.spawn(name, args: args, parent: process.pid, body)
    }

    /// This process's argument vector (POSIX `argv`); `arguments[0]` is the
    /// program name. Empty when spawned without arguments.
    public var arguments: [String] { process.args }

    /// This process's process group id.
    public func getpgrp() -> PID { process.processGroupID }

    /// This process's session id.
    public func getsid() -> PID { process.sessionID }

    /// Place `pids` into one process group, using the first live pid as the group
    /// id unless `groupID` is provided. Returns the group id that was applied.
    @discardableResult
    public func setProcessGroup(_ pids: [PID], groupID: PID? = nil) -> PID? {
        kernel.setProcessGroup(pids, groupID: groupID)
    }

    /// The full environment (inherited from the parent on `spawn`).
    public var environment: [String: String] { process.environment }

    /// Logical monotonic time in nanoseconds, read from the `EventLoop` clock.
    /// Deterministic and wall-clock-free for programs that need a timestamp.
    public var monotonicNanoseconds: UInt64 {
        UInt64(max(0, kernel.loop.now) * 1_000_000_000)
    }

    /// Look up an environment variable (POSIX `getenv`), or `nil` if unset.
    public func getenv(_ name: String) -> String? { process.environment[name] }

    /// Set an environment variable in this process (POSIX `setenv`). Children
    /// spawned afterwards inherit it.
    public func setenv(_ name: String, _ value: String) { process.environment[name] = value }

    /// This process's current working directory.
    public var currentDirectory: String { process.cwd }

    /// Change the working directory (POSIX `chdir`). Resolves `path` (relative to
    /// the current directory, honoring `.`/`..`) and, if it names an existing
    /// directory, stores the normalized absolute path as the new `cwd`.
    ///
    /// - Returns: `true` on success, `false` when the path does not resolve to a
    ///   directory (the cwd is left unchanged).
    @discardableResult
    public func chdir(_ path: String) -> Bool {
        let resolved = absolute(path)
        guard let node = kernel.vfs.lookup(resolved, mounts: mountNS), node.kind == .directory else { return false }
        process.cwd = resolved
        return true
    }

    public func exit(_ code: Int32 = 0) {
        process.state = .zombie(status: .exited(code))
    }

    // MARK: - Command table (the shell's "/bin")

    /// Default executable search path for a fresh root login shell, matching the
    /// directory order used by Debian-family systems.
    public static let defaultExecutablePath =
        "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    /// Install `registry` as the system-wide command table (see
    /// `Kernel.commandRegistry`). The shell calls this at start so its resolvable
    /// command set is visible to meta-programs (`which`, `env CMD`, `xargs`,
    /// `timeout`, …) that need to look up and launch other commands.
    public func installCommands(_ registry: CommandRegistry) {
        kernel.commandRegistry = registry
    }

    /// Resolve a program using execvp-style path search. Explicit paths are sent
    /// directly to the registered executable loaders. Bare names search `$PATH`
    /// first, then fall back to native commands so a mounted userland can replace
    /// a compatibility builtin without removing the builtin from the registry.
    public func resolveCommand(_ name: String, searchPath: String? = nil) -> Command? {
        guard let registry = kernel.commandRegistry else { return nil }
        if name.contains("/") {
            return registry.resolve(name, in: self)
        }
        let effectivePath = searchPath ?? getenv("PATH") ?? Self.defaultExecutablePath
        for directory in effectivePath.split(
            separator: ":", omittingEmptySubsequences: false)
        {
            let base = String(directory)
            let candidate: String
            if base.isEmpty || base == "." {
                candidate = "./" + name
            } else if base == "/" {
                candidate = "/" + name
            } else if base.hasSuffix("/") {
                candidate = base + name
            } else {
                candidate = base + "/" + name
            }
            if let command = registry.resolve(candidate, in: self) {
                return command
            }
        }
        return registry.resolve(name, in: self)
    }

    /// All resolvable command names (sorted), or `[]` when no table is installed.
    public var commandNames: [String] {
        kernel.commandRegistry?.names ?? []
    }

    // MARK: - Signals

    /// This process's PID — as seen in *its own* PID namespace. Outside any
    /// container this is the global pid; the first process in a namespace created
    /// by `unshare -p` sees itself as pid 1.
    public func getpid() -> PID {
        process.pidNamespace.localPID(forGlobal: process.pid) ?? process.pid
    }

    /// This process's global (root-namespace) pid — stable across namespaces and
    /// unique kernel-wide. Programs that need a collision-free identifier (the
    /// ICMP `id` for `ping`/`traceroute`, the DNS transaction id) use this rather
    /// than the namespace-local `getpid()`, which can repeat across namespaces.
    public var globalPID: PID { process.pid }

    /// A `/proc/processes`-format listing of the processes visible in this
    /// process's PID namespace (itself + descendants), with pids translated to the
    /// namespace's local numbering. In the root namespace this equals the global
    /// `/proc/processes`; inside an `unshare -p` namespace it shows only the
    /// contained processes, starting at pid 1. Backs the namespace-aware `ps`/`top`.
    func namespaceProcessListing() -> [UInt8] {
        let rows = kernel.processRows(visibleTo: process.pid)
        let lines = rows.map {
            ProcfsSchema.Processes.line(pid: $0.pid, ppid: $0.ppid, pgid: $0.pgid, sid: $0.sid,
                                        state: $0.state, ticks: $0.ticks, fds: $0.fds, name: $0.command)
        }
        return ProcfsSchema.render(lines, header: ProcfsSchema.Processes.header)
    }

    /// Translate a pid a user typed (namespace-local, as shown by `ps`) to the
    /// global pid the kernel signals. In the root namespace this is the identity —
    /// any number is taken as a global pid, matching historical `kill` behavior —
    /// so nothing changes outside a container. Inside a child namespace it resolves
    /// the local pid, returning `nil` for a pid the caller cannot see (isolation).
    func resolveVisiblePID(_ visible: PID) -> PID? {
        process.pidNamespace.isRoot ? visible : process.pidNamespace.globalPID(forLocal: visible)
    }

    // MARK: - Credentials (uid/gid)

    /// Current effective user ID (permissive-first: stored, not enforced).
    public func getuid() -> UInt32 { process.uid }
    /// Current effective group ID (permissive-first: stored, not enforced).
    public func getgid() -> UInt32 { process.gid }

    /// Set the effective user ID. No privilege check (permissive-first).
    public func setuid(_ uid: UInt32) { process.uid = uid }
    /// Set the effective group ID. No privilege check (permissive-first).
    public func setgid(_ gid: UInt32) { process.gid = gid }

    /// Change ownership of a file. No privilege check (permissive-first).
    public func chown(_ path: String, uid: UInt32, gid: UInt32) -> Bool {
        guard let node = kernel.vfs.lookup(absolute(path), mounts: mountNS) else { return false }
        node.uid = uid
        node.gid = gid
        node.touchChange(kernel.loop.now)
        return true
    }

    /// Change mode (permission bits) of a file.
    public func chmod(_ path: String, mode: FileMode) -> Bool {
        guard let node = kernel.vfs.lookup(absolute(path), mounts: mountNS) else { return false }
        node.mode = mode
        node.touchChange(kernel.loop.now)
        return true
    }

    /// Whether this process may execute a regular file at `path`. Like POSIX
    /// `exec`, at least one execute bit must be present even for uid 0.
    public func canExecute(_ path: String) -> Bool {
        guard let stat = stat(path), stat.type == .regular else { return false }
        let anyExecute: FileMode = [.ownerExecute, .groupExecute, .otherExecute]
        guard !stat.mode.intersection(anyExecute).isEmpty else { return false }
        if getuid() == 0 { return true }
        if getuid() == stat.uid { return stat.mode.contains(.ownerExecute) }
        if getgid() == stat.gid { return stat.mode.contains(.groupExecute) }
        return stat.mode.contains(.otherExecute)
    }

    /// Whether this process's credentials permit read (or, with `write`, write)
    /// access to `node`. Root (uid 0) is always permitted; otherwise the owner,
    /// group, or other permission triad is selected by comparing the process's
    /// uid/gid to the node's, and the relevant `r`/`w` bit is checked.
    func permits(_ node: VNode, write: Bool) -> Bool {
        if process.uid == 0 { return true }   // root bypasses permission checks
        let readBit: FileMode
        let writeBit: FileMode
        if process.uid == node.uid {
            (readBit, writeBit) = (.ownerRead, .ownerWrite)
        } else if process.gid == node.gid {
            (readBit, writeBit) = (.groupRead, .groupWrite)
        } else {
            (readBit, writeBit) = (.otherRead, .otherWrite)
        }
        return node.mode.contains(write ? writeBit : readBit)
    }


    // MARK: - Block devices

    /// Create a ramdisk block device with the given name and sector count.
    /// Returns false if a device with that name already exists.
    @discardableResult
    public func createBlockDevice(name: String, sectorCount: Int, sectorSize: Int = 512) -> Bool {
        kernel.blockDevices.createRamDisk(name: name, sectorCount: sectorCount, sectorSize: sectorSize)
    }

    /// Read a sector from a named block device. Returns nil if the device doesn't
    /// exist or the sector is out of range.
    public func readBlock(device: String, sector: Int) -> [UInt8]? {
        kernel.blockDevices.device(device)?.read(sector: sector)
    }

    /// Write a sector to a named block device. Returns false if the device doesn't
    /// exist, the sector is out of range, or the data size is wrong.
    @discardableResult
    public func writeBlock(device: String, sector: Int, data: [UInt8]) -> Bool {
        kernel.blockDevices.device(device)?.write(sector: sector, data: data) ?? false
    }

    /// List all registered block device names.
    public func listBlockDevices() -> [String] {
        kernel.blockDevices.names
    }

    /// Install a handler for a signal (replaces the default disposition).
    public func signal(_ number: Int32, _ handler: @escaping () -> Void) {
        process.signalHandlers[number] = handler
    }

    /// The process's current blocked signal set. SIGKILL and SIGCONT are never
    /// retained here.
    public var signalMask: Set<Int32> {
        process.signalMask
    }

    /// Pending signals that were delivered while masked and will run once
    /// unblocked. Exposed as a snapshot for observability/tests.
    public var pendingSignals: [Int32] {
        process.pendingSignals
    }

    /// Replace the blocked signal set, dropping unmaskable signals.
    public func setSignalMask(_ signals: Set<Int32>) {
        kernel.setSignalMask(for: process, signals)
    }

    /// Add one signal to this process's blocked signal set.
    public func blockSignal(_ number: Int32) {
        kernel.blockSignal(number, for: process)
    }

    /// Remove one signal from this process's blocked signal set and deliver any
    /// now-unblocked pending signal.
    public func unblockSignal(_ number: Int32) {
        kernel.unblockSignal(number, for: process)
    }

    /// Send a signal to a process.
    public func kill(_ pid: PID, signal number: Int32) {
        kernel.kill(pid, signal: number)
    }

    /// Mark `pids` as this terminal's foreground job (or clear with `[]`). The
    /// kernel-wide value is retained for single-terminal compatibility, while
    /// the controlling PTY keeps the authoritative per-tab group used by the
    /// consumer's Ctrl-C/Ctrl-Z signal path. Cross-session groups are rejected.
    public func setForegroundJob(_ pids: [PID]) {
        let terminal = controllingTerminal
        if pids.isEmpty {
            kernel.setForegroundGroup([], sessionID: process.sessionID)
            terminal?.foregroundProcessGroupID = nil
            return
        }
        guard let processGroupID = kernel.setForegroundGroup(
            pids,
            sessionID: process.sessionID
        ) else { return }
        terminal?.foregroundProcessGroupID = processGroupID
        terminal?.linePrompt = []
    }

    /// Set this terminal's foreground process group directly. The requested
    /// group must belong wholly to the caller's session.
    public func setForegroundProcessGroup(_ processGroupID: PID?) {
        guard kernel.setForegroundProcessGroup(
            processGroupID,
            sessionID: process.sessionID
        ) else { return }
        controllingTerminal?.foregroundProcessGroupID = processGroupID
        if processGroupID != nil { controllingTerminal?.linePrompt = [] }
    }

    /// A controlling terminal is stable process identity. It is captured when
    /// standard I/O is first wired and inherited by children, so redirecting all
    /// of fd 0/1/2 cannot disconnect job control from its PTY.
    private var controllingTerminal: TerminalControl? {
        process.controllingTerminal
    }

    // MARK: - Timers

    /// Sleep for `seconds` of logical time, then resume. Parks the process on a
    /// loop timer (no wall-clock, no busy-wait); the process stays alive while
    /// parked and resumes on the single loop thread. Call as the tail of a step.
    /// The async front-end is `try await ctx.sleep(_)`.
    public func sleep(_ seconds: Double, resume: @escaping () -> Void) {
        process.blockedOn += 1
        let kernel = self.kernel
        let process = self.process
        kernel.schedule(after: seconds) { [weak kernel, weak process] in
            guard let kernel, let process else { return }
            kernel.runStep(process) {
                process.blockedOn -= 1
                resume()
            }
        }
    }

    // MARK: - Child processes

    /// Block until one of this process's children exits.
    public func wait(resume: @escaping (Result<ChildWaitEvent, SyscallError>) -> Void) {
        kernel.wait(parent: process, resume: resume)
    }

    /// Linux-like `waitpid`. `childPID == nil` waits for any child. With
    /// `.noHang`, `.success(nil)` means a matching child exists but has no
    /// waitable event ready; no-child is `.failure(.noChildProcess)`.
    public func waitpid(_ childPID: PID? = nil,
                        options: ProcessWaitOptions = [],
                        resume: @escaping (Result<ChildWaitEvent?, SyscallError>) -> Void) {
        kernel.waitpid(parent: process, childPID: childPID, options: options, resume: resume)
    }

    /// Non-blocking reap: return the next already-exited child event, or `nil` if
    /// none has exited since the last call.
    public func reapChild() -> ChildWaitEvent? {
        kernel.reapExitedChild(parent: process)
    }

    /// Block until a child exits or stops (POSIX `waitpid` with `WUNTRACED`).
    public func waitEvent(resume: @escaping (Result<ChildWaitEvent, SyscallError>) -> Void) {
        kernel.waitEvent(parent: process, resume: resume)
    }

}
