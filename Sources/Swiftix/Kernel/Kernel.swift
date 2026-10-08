/// A per-instance, user-space "kernel": the OS substrate one Swiftix instance
/// runs on. It owns the virtual filesystem, the network namespace, and the
/// process table, and uses the shared `EventLoop` as its scheduler — processes
/// are cooperative tasks, never one OS thread per process.
public final class Kernel {
    /// Default aggregate budget for memory explicitly reported by managed guest
    /// runtimes. This is not host RSS and does not include the VFS or Swift object
    /// overhead; those are exposed separately by resource snapshots/procfs.
    public static let defaultRuntimeMemoryLimitBytes = 128 * 1_024 * 1_024

    let vfs = VirtualFileSystem()
    let blockDevices = BlockDeviceTable()

    /// This instance's network namespace (owns the user-space TCP/IP stack).
    public let netns: NetworkNamespace

    /// The kernel's root UTS namespace: the machine's hostname/domainname that
    /// every top-level process shares by default. `unshare -u` gives a process a
    /// private copy of it (see `ProcessContext.unshareUTS`).
    let rootUTS = UTSNamespace()

    /// The kernel's root PID namespace (the identity mapping: local pid == global
    /// pid). Every top-level process joins it; `unshare -p` nests a child below it.
    let rootPIDNS = PIDNamespace(parent: nil)

    /// The kernel's root mount namespace (the machine-wide mount table). Every
    /// top-level process shares it; `unshare -m` gives a process a private copy.
    let rootMountNS = MountNamespace()

    /// The cgroup hierarchy (pids controller). A process is admitted to its
    /// parent's group at spawn; a `pids.max` on that subtree can refuse the spawn.
    private(set) lazy var cgroups = CgroupController(isAlive: { [weak self] pid in
        self?.processTable.process(pid)?.isLive ?? false
    })

    /// The scheduler/clock — shared across instances in a running simulation.
    public let loop: EventLoop

    /// Aggregate admission limit for memory reported by managed runtimes in this
    /// Kernel. A report that would move the live total above this value is
    /// rejected before it becomes observable.
    public let runtimeMemoryLimitBytes: Int

    /// Every timer and process step owned by this kernel is tagged with this
    /// scope. The shared loop can then freeze or physically remove one VM's work
    /// without touching any other kernel on that loop.
    private let workOwner: EventLoop.WorkOwner

    private enum LifecycleState {
        case active
        case paused
        case shutdown
    }

    private var lifecycleState: LifecycleState = .active

    /// The system-wide command table ("/bin"): the set of programs a process can
    /// resolve and launch by name. The shell installs its own `CommandRegistry`
    /// here at start (`ProcessContext.installCommands`), so meta-programs like
    /// `which`, `env CMD`, `xargs`, and `timeout` can look up and run other
    /// commands through `ProcessContext.resolveCommand` / `run(_:args:)` — the
    /// same registry the shell resolves against, without the core hard-coding a
    /// command set. `nil` until a shell (or the consumer) installs one.
    public var commandRegistry: CommandRegistry?

    /// Mapping from logical time to real (epoch) time and the local zone. The
    /// default is deterministic (logical zero == the Unix epoch, UTC); a host
    /// injects real time with `setWallClock(epochSeconds:utcOffsetSeconds:zoneAbbreviation:)`.
    /// Read and written on the kernel's serial executor. File timestamps are
    /// stamped with this clock, so set it before spawning processes.
    public var wallClock = WallClock()

    /// Host handler for guest power requests (`shutdown`, `reboot`, `poweroff`,
    /// `halt`). It is invoked on the kernel's serial executor from a kernel-owned
    /// loop job — never from inside the requesting process's step — so the
    /// handler may call `pause()` or `shutdown()` directly. While it is `nil`
    /// the guest commands report that the host does not support power control
    /// and exit non-zero. The core never changes its own lifecycle in response
    /// to a request; acting on it is entirely the host's decision.
    public var onPowerRequest: ((PowerRequest) -> Void)?

    /// Seed used for `/dev/random` and `/dev/urandom` until `seedRandom(_:)` is
    /// called. Fixed so an unseeded kernel is reproducible.
    public static let defaultRandomSeed: UInt64 = 0x5377_6966_7469_7821

    private var random = DeterministicRandom(seed: Kernel.defaultRandomSeed)

    /// Logical time at which this kernel was created (its "boot"). A shared
    /// `EventLoop` may already have advanced before a kernel is built.
    let bootLogicalTime: Double

    /// Stable `pts/<n>` numbers for terminals that are (or were) a process's
    /// controlling terminal. Entries are weak: a number is reused once its
    /// terminal has been released by the host.
    private struct TerminalSlot {
        let index: Int
        weak var terminal: TerminalControl?
    }
    private var terminalSlots: [TerminalSlot] = []

    private lazy var processTable = ProcessTable(loop: loop)
    private lazy var processIntrospection: ProcessIntrospection = {
        let introspection = ProcessIntrospection(processTable: processTable)
        introspection.terminalIndex = { [weak self] terminal in
            self?.terminalIndex(for: terminal)
        }
        return introspection
    }()
    private lazy var processGroups = ProcessGroupController(processTable: processTable)
    private lazy var childWaitQueue = ChildWaitQueue(processTable: processTable)
    private lazy var processExit = ProcessExitCoordinator(
        processTable: processTable,
        childWaitQueue: childWaitQueue,
        processGroups: processGroups,
        signalParent: { [weak self] pid, signal in
            self?.kill(pid, signal: signal)
        },
        willExit: { [weak self] process in
            self?.processDidExit(process)
        },
        willReap: { process in
            // PID identity remains namespace-visible while the process is a
            // zombie and is removed only by the final parent/host reap.
            var namespace: PIDNamespace? = process.pidNamespace
            while let current = namespace {
                current.unregister(global: process.pid)
                namespace = current.parent
            }
        })
    private lazy var processScheduler = ProcessScheduler(
        processTable: processTable,
        deliverPendingSignals: { [weak self] process in
            self?.signalDispatcher.deliverPendingSignals(process) ?? false
        },
        exit: { [weak self] process, status in
            self?.processExit.handleExit(process, status: status)
        })
    private lazy var signalDispatcher = SignalDispatcher(
        processTable: processTable,
        childWaitQueue: childWaitQueue,
        schedule: { [weak self] process, yielding, work in
            self?.runStep(process, yielding: yielding, work)
        },
        terminate: { [weak self] process, signal in
            self?.processExit.terminate(process, bySignal: signal)
        },
        signalParent: { [weak self] pid, signal in
            self?.kill(pid, signal: signal)
        })

    public init(
        loop: EventLoop,
        runtimeMemoryLimitBytes: Int = Kernel.defaultRuntimeMemoryLimitBytes
    ) {
        let workOwner = loop.makeWorkOwner()
        self.loop = loop
        self.workOwner = workOwner
        self.runtimeMemoryLimitBytes = max(0, runtimeMemoryLimitBytes)
        self.netns = NetworkNamespace(loop: loop, workOwner: workOwner)
        self.bootLogicalTime = loop.now
        vfs.clock = { [weak self] in self?.epochNow ?? 0 }
        childWaitQueue.onExitConsumed = { [weak self] parent, child in
            self?.processExit.reapExitedChild(parent: parent, child: child)
        }
        mountProcFS()
    }

    /// Attach a consumer-supplied storage volume to this node. The core owns
    /// only the guest-visible registration; persistence, encryption, and host
    /// file access remain responsibilities of the supplying adapter.
    ///
    /// Attach volumes before starting applications that depend on them. Like
    /// every Kernel mutation, this method is called on the EventLoop's serial
    /// executor. The volume must deliver asynchronous completions on that same
    /// executor.
    public func attachBlockVolume(_ volume: any BlockVolume, named name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw SyscallError.invalidArgument
        }
        guard volume.sectorSize > 0, volume.sectorCount >= 0 else {
            throw SyscallError.invalidArgument
        }
        let (capacity, overflow) = volume.sectorSize.multipliedReportingOverflow(by: volume.sectorCount)
        guard !overflow, capacity == volume.capacity else {
            throw SyscallError.invalidArgument
        }
        guard blockDevices.attach(name: name, volume: volume) else {
            throw SyscallError.fileExists
        }
    }

    /// Stable names of the volumes currently exposed to this node.
    public var blockVolumeNames: [String] { blockDevices.names }

    /// Whether this kernel's process and protocol work is currently frozen.
    public var isPaused: Bool { lifecycleState == .paused }

    /// Whether this kernel has permanently released its processes, sockets, and
    /// scheduled work. A shut-down Kernel is not reusable.
    public var isShutdown: Bool { lifecycleState == .shutdown }

    /// Schedule consumer-side work (for example loopback delivery) in this
    /// kernel's lifecycle scope rather than as an unowned loop timer.
    public func schedule(after delay: Double, _ work: @escaping () -> Void) {
        loop.schedule(after: delay, owner: workOwner, work)
    }

    /// Schedule work owned by one live process. Logical exit physically removes
    /// it even while the lightweight PID remains present as a zombie.
    func schedule(for process: Process, after delay: Double, _ work: @escaping () -> Void) {
        guard processTable.contains(process.pid), process.isLive else { return }
        process.workScope.schedule(after: delay) { [weak process] in
            guard let process, process.isLive else { return }
            work()
        }
    }

    /// Freeze this kernel while allowing other kernels on the shared EventLoop to
    /// continue. Timer deadlines retain their remaining duration across resume.
    public func pause() {
        guard lifecycleState == .active else { return }
        lifecycleState = .paused
        netns.stack.pause()
        for process in processTable.all where process.isLive {
            process.workScope.pause()
        }
        loop.pause(workOwner)
    }

    /// Resume a previously paused kernel without rebuilding it.
    public func resume() {
        guard lifecycleState == .paused else { return }
        lifecycleState = .active
        netns.stack.resume()
        for process in processTable.all where process.isLive {
            process.workScope.resume()
        }
        loop.resume(workOwner)

        let continuations = Array(pausedAsyncContinuations.values)
        pausedAsyncContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations { continuation.resume(returning: true) }
    }

    /// Permanently tear down this kernel. Pending timer/process callbacks are
    /// physically removed, parked continuations are interrupted, async task
    /// handles are cancelled, all descriptors/sockets are closed, and the data
    /// plane is detached. Idempotent and valid from active or paused state.
    public func shutdown() {
        guard lifecycleState != .shutdown else { return }
        lifecycleState = .shutdown

        // Stop any callback from racing teardown or being re-armed by a close.
        loop.cancel(workOwner)

        let pausedContinuations = Array(pausedAsyncContinuations.values)
        pausedAsyncContinuations.removeAll(keepingCapacity: false)
        for continuation in pausedContinuations { continuation.resume(returning: false) }

        let tasks = Array(asyncTasks.values)
        asyncTasks.removeAll(keepingCapacity: false)
        for task in tasks { task.cancel() }

        // Snapshot first because logical exit can reparent children and satisfy
        // pending waits. Shutdown then force-reaps any retained zombies.
        for process in processTable.all where process.isLive {
            processExit.terminate(process, bySignal: Signal.sigkill.rawValue)
        }
        processExit.forceReapAll()
        netns.stack.shutdown()

        // Cancelling checked continuations enqueues their final Swift jobs on the
        // shared executor. Drain only current-time work so payloads release their
        // strong lifetime holds without jumping to another VM's future timer.
        loop.runUntilIdle()
    }

    public var processCount: Int { processTable.count }
    func process(_ pid: PID) -> Process? { processTable.process(pid) }

    /// Register a one-shot callback for a live process's logical exit. The
    /// callback runs after runtime resources are released; a child may remain in
    /// the table as a zombie until its parent waits.
    /// This is the consumer seam used to keep terminal-session UI synchronized
    /// with a top-level shell without making Process itself public.
    @discardableResult
    public func observeProcessExit(
        _ pid: PID,
        _ observer: @escaping (ProcessWaitStatus) -> Void
    ) -> Bool {
        guard let process = processTable.process(pid), process.isLive else { return false }
        process.exitObservers.append(observer)
        return true
    }

    /// The process rows visible to the reader `pid`, translated into the reader's
    /// PID namespace (see `ProcessIntrospection.snapshotProcesses(in:)`). Backs the
    /// namespace-aware `ps`/`top`. Root readers get the whole table, unchanged.
    func processRows(visibleTo pid: PID) -> [ProcessSnapshotRow] {
        let namespace = processTable.process(pid)?.pidNamespace ?? rootPIDNS
        return processIntrospection.snapshotProcesses(in: namespace)
    }

    /// The effective uid/gid of the process with global pid `pid`, or `nil` when
    /// no such process is retained. Backs the USER column of `ps`.
    func processCredentials(_ pid: PID) -> (uid: UInt32, gid: UInt32)? {
        processTable.process(pid).map { ($0.uid, $0.gid) }
    }

    // MARK: - Mounts

    /// Mount a fresh, empty tmpfs at `path` in mount namespace `ns`. The mountpoint
    /// must resolve (in `ns`'s current view) to an existing directory other than
    /// the root. Returns `false` otherwise.
    @discardableResult
    func mountTmpfs(at path: String, ns: MountNamespace) -> Bool {
        let mountpoint = MountNamespace.normalize(path)
        guard mountpoint != "/",
              let node = vfs.lookup(mountpoint, mounts: ns), node.kind == .directory else { return false }
        let name = MountNamespace.components(mountpoint).last ?? "/"
        // The root of a new filesystem is created now, like any directory.
        let root = VNode(directory: name)
        root.touchAll(epochNow)
        ns.add(MountNamespace.MountEntry(mountpoint: mountpoint,
                                         root: root,
                                         type: "tmpfs", source: "tmpfs"))
        return true
    }

    /// Bind-mount the directory at `source` onto `path` in mount namespace `ns`
    /// (both must resolve to existing directories; the mountpoint may not be root).
    /// The mounted tree is the *same* VNodes as the source, so writes are visible
    /// through both paths.
    @discardableResult
    func mountBind(source: String, at path: String, ns: MountNamespace) -> Bool {
        let sourcePath = MountNamespace.normalize(source)
        let mountpoint = MountNamespace.normalize(path)
        guard mountpoint != "/",
              let sourceNode = vfs.lookup(sourcePath, mounts: ns), sourceNode.kind == .directory,
              let mountNode = vfs.lookup(mountpoint, mounts: ns), mountNode.kind == .directory else { return false }
        ns.add(MountNamespace.MountEntry(mountpoint: mountpoint,
                                         root: sourceNode,
                                         type: "bind", source: sourcePath))
        return true
    }

    /// Unmount whatever is mounted at `path` in `ns`. Returns `false` when nothing
    /// is mounted there.
    @discardableResult
    func unmount(_ path: String, ns: MountNamespace) -> Bool {
        ns.remove(mountpoint: path)
    }

    // MARK: - Resource counters

    /// A point-in-time snapshot of system-wide resource usage. All fields are
    /// computed from live state (not cached), so successive calls always reflect
    /// the current reality.
    public struct ResourceSnapshot: Sendable, Equatable {
        /// Retained process identities: live processes plus zombies.
        public let processes: Int
        public let liveProcesses: Int
        public let zombieProcesses: Int
        public let openFileDescriptors: Int
        public let tcpConnections: Int
        public let networkInterfaces: Int
        public let vfsNodeCount: Int
        /// Bytes in real, non-synthetic VFS files. This is storage content, not
        /// process memory, and is deliberately separate from managed runtime use.
        public let vfsFileBytes: Int
        /// Sum of memory explicitly reported by live managed guest runtimes.
        public let runtimeMemoryBytes: Int
        /// Kernel-wide admission budget for `runtimeMemoryBytes`.
        public let runtimeMemoryLimitBytes: Int
    }

    /// Snapshot current resource usage across the kernel.
    public func snapshotResources() -> ResourceSnapshot {
        let fdCount = processTable.all.reduce(0) { $0 + $1.fileDescriptors.openDescriptors.count }
        let liveCount = processTable.all.lazy.filter(\.isLive).count
        let zombieCount = processTable.all.count - liveCount
        let tcpCount = netns.stack.tcpConnectionCount
        let ifCount = netns.stack.interfaceCount
        let nodeCount = vfs.nodeCount
        let vfsBytes = vfs.totalFileBytes
        let runtimeBytes = processTable.all.reduce(0) {
            $0 + ($1.isLive ? $1.runtimeMemoryBytes : 0)
        }
        return ResourceSnapshot(
            processes: processTable.count,
            liveProcesses: liveCount,
            zombieProcesses: zombieCount,
            openFileDescriptors: fdCount,
            tcpConnections: tcpCount,
            networkInterfaces: ifCount,
            vfsNodeCount: nodeCount,
            vfsFileBytes: vfsBytes,
            runtimeMemoryBytes: runtimeBytes,
            runtimeMemoryLimitBytes: runtimeMemoryLimitBytes
        )
    }

    /// Lifecycle component of a process diagnostic snapshot. Run state and
    /// lifecycle are intentionally separate: a zombie is terminal identity,
    /// while runnable/waiting/stopped describe only executable processes.
    public enum ProcessLifecycleSnapshot: String, Sendable, Equatable {
        case live
        case exiting
        case zombie
    }

    /// Immutable, public process diagnostics. `state` uses the familiar Linux
    /// display letters (`R`, `S`, `T`, `Z`); the other fields explain how that
    /// view was derived without exposing the kernel's mutable Process object.
    public struct ProcessSnapshot: Sendable, Equatable {
        public let pid: PID
        public let parentPID: PID
        public let processGroupID: PID
        public let sessionID: PID
        public let name: String
        public let state: String
        public let lifecycle: ProcessLifecycleSnapshot
        public let exitStatus: ProcessExitStatus?
        public let waitReasons: [String]
        public let queuedSteps: Int
        public let scheduleTicks: Int
        public let openFileDescriptors: Int
        public let pendingSignals: [Int32]
        /// Managed-runtime bytes reported for this process. This is an exact
        /// runtime-owned count, not a fabricated RSS estimate.
        public let runtimeMemoryBytes: Int
        public let runtimeMemoryLimitBytes: Int
        public let runtimeHeapCells: Int
        public let runtimeGarbageCollections: Int
    }

    /// Snapshot every retained process, including waitable zombies, ordered by
    /// global PID. Call on the kernel's serial executor like other kernel APIs.
    public func snapshotProcesses() -> [ProcessSnapshot] {
        processTable.all.map { process in
            let lifecycle: ProcessLifecycleSnapshot
            switch process.lifecycle {
            case .live: lifecycle = .live
            case .exiting: lifecycle = .exiting
            case .zombie: lifecycle = .zombie
            }
            return ProcessSnapshot(
                pid: process.pid,
                parentPID: process.ppid,
                processGroupID: process.processGroupID,
                sessionID: process.sessionID,
                name: process.name,
                state: ProcessIntrospection.stateName(process),
                lifecycle: lifecycle,
                exitStatus: process.terminalStatus,
                waitReasons: process.waitReasons.map(\.description),
                queuedSteps: process.queuedSteps,
                scheduleTicks: process.scheduleTicks,
                openFileDescriptors: process.fileDescriptors.openDescriptors.count,
                pendingSignals: process.pendingSignals,
                runtimeMemoryBytes: process.runtimeMemoryBytes,
                runtimeMemoryLimitBytes: process.runtimeMemoryLimitBytes,
                runtimeHeapCells: process.runtimeHeapCells,
                runtimeGarbageCollections: process.runtimeGarbageCollections)
        }
        .sorted { $0.pid < $1.pid }
    }

    public var foregroundProcessGroupID: PID? { processGroups.foregroundProcessGroupID }

    /// Set (or clear, with `[]`) the foreground process group. Called by the shell
    /// through `ProcessContext.setForegroundJob`. The requested processes must
    /// belong to the caller's terminal session.
    @discardableResult
    func setForegroundGroup(_ pids: [PID], sessionID: PID) -> PID? {
        processGroups.setForegroundGroup(pids, sessionID: sessionID)
    }

    @discardableResult
    func setForegroundProcessGroup(_ processGroupID: PID?, sessionID: PID) -> Bool {
        processGroups.setForegroundProcessGroup(processGroupID, sessionID: sessionID)
    }

    @discardableResult
    func setProcessGroup(_ pids: [PID], groupID requestedGroupID: PID? = nil) -> PID? {
        processGroups.setProcessGroup(pids, groupID: requestedGroupID)
    }

    func processIDs(inProcessGroup processGroupID: PID) -> Set<PID> {
        processGroups.processIDs(inProcessGroup: processGroupID)
    }

    /// Deliver `signal` to every process in `processGroupID`. This unfiltered
    /// variant is retained as a `killpg`-style compatibility primitive; a host
    /// with multiple terminals must use the session-qualified overload below.
    public func interruptProcessGroup(_ processGroupID: PID?, signal: Int32) {
        guard let processGroupID else { return }
        for pid in processIDs(inProcessGroup: processGroupID) {
            kill(pid, signal: signal)
        }
    }

    /// Deliver a terminal-generated signal only to members of one process group
    /// that still belong to the PTY owner's session. Revalidating at delivery
    /// time prevents later process-group changes from crossing terminal tabs.
    public func interruptProcessGroup(
        _ processGroupID: PID?,
        sessionID: PID,
        signal: Int32
    ) {
        guard let processGroupID else { return }
        for pid in processIDs(inProcessGroup: processGroupID)
        where process(pid)?.sessionID == sessionID {
            kill(pid, signal: signal)
        }
    }

    /// Deliver `signal` to the legacy kernel-wide foreground group. Kept for
    /// single-terminal consumers and source compatibility; multi-terminal hosts
    /// should call `interruptProcessGroup(_:signal:)` with their PTY's group.
    public func interruptForeground(signal: Int32) {
        interruptProcessGroup(foregroundProcessGroupID, signal: signal)
    }

    /// Terminate every process in one POSIX-style session. A terminal tab's
    /// top-level shell starts a fresh session whose id equals its PID, and all
    /// commands/jobs inherit that id even if the shell exits first or redirects
    /// every terminal descriptor. This makes tab teardown ownership-based rather
    /// than dependent on a still-connected PPID tree.
    public func terminateProcessSession(_ sessionID: PID) {
        let members = processTable.all
            .filter { $0.sessionID == sessionID }
            .map(\.pid)
        for pid in members where processTable.contains(pid) {
            kill(pid, signal: Signal.sigkill.rawValue)
        }
    }

    /// The loop-owned serial executor. Every Kernel sharing this loop reads the
    /// same executor; a Kernel never installs or replaces executor state on the
    /// loop. Async process bodies run on the loop's task executor where the
    /// runtime has one, and through `asyncHost` on this executor otherwise.
    var asyncExecutor: SwiftixExecutor { loop.executor }

    /// Host actor bound to the loop's shared executor; awaiting a body here runs
    /// it (and its continuations) as jobs on the `EventLoop`.
    private lazy var asyncHost = AsyncProcessHost(executor: loop.executor)

    /// One cancellation handle per live async process. Handles are removed at
    /// logical exit and cancelled en masse during kernel shutdown.
    private var asyncTasks: [PID: Task<Void, Never>] = [:]

    /// Async task jobs are opaque to `SerialExecutor.enqueue`, so a job already
    /// queued when pause begins cannot be removed from the shared job FIFO. It
    /// reaches this gate and parks before entering/resuming user code instead.
    private var pausedAsyncContinuations: [PID: CheckedContinuation<Bool, Never>] = [:]

    /// Create a process and schedule its body. `parent` 0 = no parent (top-level).
    /// `args` is the process's argument vector (POSIX `argv`, `args[0]` = program
    /// name), readable inside the body via `ProcessContext.arguments`.
    @discardableResult
    public func spawn(_ name: String, args: [String] = [], parent: PID = 0,
                      _ body: @escaping (ProcessContext) -> Void) -> PID {
        guard lifecycleState != .shutdown else { return 0 }
        guard parent == 0 || processTable.process(parent)?.isLive == true else { return 0 }
        guard cgroups.canAdmitChild(parentPID: parent) else { return 0 }
        let process = processTable.allocate(name: name, args: args, parent: parent)
        if lifecycleState == .paused { process.workScope.pause() }
        inherit(into: process, from: parent)
        cgroups.admitChild(pid: process.pid, parentPID: parent)
        let context = ProcessContext(process: process, kernel: self)
        runStep(process) { body(context) }
        return process.pid
    }

    /// A child inherits its parent's working directory and environment (POSIX
    /// `fork` semantics), so `cd` in a shell is visible to the commands it
    /// launches. Top-level processes (parent 0) keep the defaults (cwd "/").
    private func inherit(into child: Process, from parentPID: PID) {
        if let parent = processTable.process(parentPID) {
            child.cwd = parent.cwd
            child.environment = parent.environment
            child.uid = parent.uid
            child.gid = parent.gid
            child.umask = parent.umask
            child.supplementaryGroups = parent.supplementaryGroups
            child.processGroupID = parent.processGroupID
            child.sessionID = parent.sessionID
            child.fileDescriptors.clone(from: parent.fileDescriptors)
            child.controllingTerminal = parent.controllingTerminal
            // Namespaces are shared by reference with the parent; `unshare` later
            // swaps in a private copy for the child alone.
            child.utsNamespace = parent.utsNamespace
            // PID namespace: normally shared, but a pending `unshare(CLONE_NEWPID)`
            // on the parent places this child in a brand-new namespace as its pid 1.
            if parent.unshareChildIntoNewPIDNamespace {
                parent.unshareChildIntoNewPIDNamespace = false      // one-shot
                child.pidNamespace = PIDNamespace(parent: parent.pidNamespace)
            } else {
                child.pidNamespace = parent.pidNamespace
            }
            // Mount namespace is shared by reference; `unshare -m` swaps in a copy.
            child.mountNamespace = parent.mountNamespace
        } else {
            // Top-level process (no parent): the machine-wide root namespaces.
            child.utsNamespace = rootUTS
            child.pidNamespace = rootPIDNS
            child.mountNamespace = rootMountNS
        }
        // Register the child in its own PID namespace and every ancestor, so each
        // ancestor can see and translate it (its pid there differs per namespace).
        var namespace: PIDNamespace? = child.pidNamespace
        while let current = namespace {
            current.register(global: child.pid)
            namespace = current.parent
        }
    }

    /// Create a process whose body is an `async` function, and schedule it as a
    /// task bound to the loop-bound serial executor (task 13). The body can use
    /// the async/throwing syscall frontend (`await ctx.tcpRecv(fd)`, …) and makes
    /// progress purely via `advance(by:)` / `runUntilIdle()` — no wall-clock.
    ///
    /// Wait-registry / `runStep` accounting is preserved exactly as the callback
    /// path (R1.6, R3.4): the async syscalls bridge to the same callback
    /// primitives, which register/end structured waits and dispatch
    /// each resumption through `runStep`. The body's first hop is itself posted as
    /// a `runStep`, so the process is scheduled on the loop exactly like a
    /// synchronous body.
    @discardableResult
    public func spawn(_ name: String, args: [String] = [], parent: PID = 0,
                      _ body: @escaping (ProcessContext) async -> Void) -> PID {
        guard lifecycleState != .shutdown else { return 0 }
        guard parent == 0 || processTable.process(parent)?.isLive == true else { return 0 }
        guard cgroups.canAdmitChild(parentPID: parent) else { return 0 }
        let process = processTable.allocate(name: name, args: args, parent: parent)
        if lifecycleState == .paused { process.workScope.pause() }
        inherit(into: process, from: parent)
        cgroups.admitChild(pid: process.pid, parentPID: parent)
        let host = asyncHost
        runStep(process) { [weak self] in
            guard let self else { return }
            // Hold the process "waiting" for the entire lifetime of the async
            // body: without this, `finishStep` (run right after this launch step)
            // would see no registered wait and exit the process before the body's
            // task ever runs. This mirrors the callback path, where a parked
            // syscall keeps a wait registered (R1.6, R3.4). The matching release
            // happens in `finishAsyncBody` when the body returns.
            process.asyncBodyWaitID = process.beginWait(.asyncBody)
            let payload = AsyncProcessHost.Payload(
                body: body,
                context: ProcessContext(process: process, kernel: self),
                kernel: self,
                process: process)
            // Launch the body so that it — and the continuations of the async
            // syscalls it awaits — run as EventLoop jobs on the single logical
            // loop thread. Every Kernel sharing this loop uses the loop's one
            // task executor. Keep the handle so shutdown/signal teardown can cancel
            // a permanently suspended body and release its lifetime payload.
            let task: Task<Void, Never>
            if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
                task = Task(executorPreference: self.loop.taskExecutor) {
                    guard await payload.kernel.awaitAsyncExecution(payload.process) else { return }
                    await payload.body(payload.context)
                    payload.kernel.finishAsyncBody(payload.process)
                }
            } else {
                // Fallback for older Apple runtimes: bind through the loop-bound
                // host actor. (No availability gate applies on Linux.)
                task = Task { await host.run(payload) }
            }
            self.asyncTasks[process.pid] = task
        }
        return process.pid
    }

    /// Gate an opaque Swift-concurrency job at the kernel lifecycle boundary.
    /// Active processes proceed immediately; a paused process parks until resume;
    /// shutdown or reap returns `false` so user code is never entered again.
    func awaitAsyncExecution(_ process: Process) async -> Bool {
        switch lifecycleState {
        case .active:
            return processTable.contains(process.pid) && process.isLive
        case .shutdown:
            return false
        case .paused:
            return await withCheckedContinuation { continuation in
                guard lifecycleState == .paused,
                      processTable.contains(process.pid), process.isLive else {
                    continuation.resume(returning:
                        lifecycleState == .active
                            && processTable.contains(process.pid)
                            && process.isLive)
                    return
                }
                pausedAsyncContinuations[process.pid] = continuation
            }
        }
    }

    private func processDidExit(_ process: Process) {
        process.runtimeMemoryBytes = 0
        process.runtimeMemoryLimitBytes = 0
        process.runtimeHeapCells = 0
        process.runtimeGarbageCollections = 0
        if let continuation = pausedAsyncContinuations.removeValue(forKey: process.pid) {
            continuation.resume(returning: false)
        }
        if let task = asyncTasks.removeValue(forKey: process.pid) {
            task.cancel()
        }
    }

    /// Update one live process's managed-runtime memory report. The update is
    /// atomic: invalid fields or an aggregate-budget overflow leave the previous
    /// report unchanged. Called through the trusted runtime integration seam on
    /// `ProcessContext`, never by the VFS or network stack.
    func reportRuntimeMemory(
        for process: Process,
        bytes: Int,
        limitBytes: Int,
        heapCells: Int,
        garbageCollections: Int
    ) -> Bool {
        guard processTable.contains(process.pid), process.isLive,
              bytes >= 0, limitBytes >= 0, bytes <= limitBytes,
              heapCells >= 0, garbageCollections >= 0 else { return false }
        var otherBytes = 0
        for candidate in processTable.all where candidate.isLive && candidate !== process {
            guard candidate.runtimeMemoryBytes <= runtimeMemoryLimitBytes - otherBytes else {
                return false
            }
            otherBytes += candidate.runtimeMemoryBytes
        }
        guard otherBytes <= runtimeMemoryLimitBytes,
              bytes <= runtimeMemoryLimitBytes - otherBytes else { return false }
        process.runtimeMemoryBytes = bytes
        process.runtimeMemoryLimitBytes = limitBytes
        process.runtimeHeapCells = heapCells
        process.runtimeGarbageCollections = garbageCollections
        return true
    }

    /// Release the lifetime hold taken by async `spawn` when the body returns.
    /// An explicit `ctx.exit` has already performed logical exit; otherwise the
    /// body returning is the process's normal status-0 exit.
    func finishAsyncBody(_ process: Process) {
        asyncTasks[process.pid] = nil
        guard processTable.contains(process.pid), process.isLive else { return }
        if let waitID = process.asyncBodyWaitID {
            process.endWait(waitID)
            process.asyncBodyWaitID = nil
        }
        processExit.handleExit(process, status: ProcessExitStatus.exited(0))
    }

    /// Queue one step of `process`. A step queued by yielded CPU-bound work
    /// is a yield as well: when a spinning process wakes another one (a pipe
    /// it filled or drained, a child it started, its own exit), the woken
    /// step belongs to the same burst and must not hold logical time either,
    /// or two always-ready processes feeding each other would stop the
    /// clock. A process woken by anything else (a timer, terminal input, the
    /// network) takes an ordinary step.
    func runStep(_ process: Process, yielding: Bool = false, _ work: @escaping () -> Void) {
        processScheduler.runStep(process, yielding: yielding || loop.isRunningYieldedWork, work)
    }

    func exit(_ process: Process, code: Int32) {
        processExit.handleExit(process, status: ProcessExitStatus.exited(code))
    }

    // MARK: - Control groups (cgroups: pids controller)

    /// Create a cgroup at `path` (making parents as needed) and mount its
    /// synthetic `/sys/fs/cgroup` files. Returns `true` on success.
    @discardableResult
    func createCgroup(_ path: String) -> Bool {
        guard let group = cgroups.create(path) else { return false }
        mountCgroupFiles(group)
        return true
    }

    /// Remove an empty leaf cgroup (no child groups, no live members) and its
    /// synthetic files. Returns `false` otherwise (or for the root).
    @discardableResult
    func removeCgroup(_ path: String) -> Bool {
        let normalized = CgroupController.normalize(path)
        guard cgroups.remove(normalized) else { return false }
        let dir = cgroupVFSPath(normalized)
        for file in ["pids.current", "pids.max", "cgroup.procs"] {
            vfs.remove(dir + "/" + file)
        }
        vfs.remove(dir)
        return true
    }

    /// Set (or clear, with `nil` = "max") a cgroup's `pids.max` admission limit.
    @discardableResult
    func setCgroupPidsMax(_ path: String, _ max: Int?) -> Bool {
        guard let group = cgroups.cgroup(path) else { return false }
        group.pidsMax = max
        return true
    }

    /// Move a live process into the cgroup at `path` (the `cgroup.procs` write).
    /// Migration may exceed `pids.max`; creation is what the controller limits.
    @discardableResult
    func joinCgroup(pid: PID, path: String) -> Bool {
        guard processTable.process(pid)?.isLive == true,
              let group = cgroups.cgroup(path) else { return false }
        return cgroups.move(pid: pid, to: group)
    }

    /// The cgroup path a process currently belongs to.
    func cgroupPath(of pid: PID) -> String { cgroups.cgroupOf(pid).path }

    /// `pids.current` for the cgroup at `path`, or `nil` if it does not exist.
    /// The root count includes live processes but excludes zombies, which no
    /// longer consume cgroup execution capacity.
    func cgroupPidsCurrent(_ path: String) -> Int? {
        guard let group = cgroups.cgroup(path) else { return nil }
        return group === cgroups.root
            ? processTable.all.filter(\.isLive).count
            : cgroups.liveCount(group)
    }

    /// The VFS path of a cgroup's directory under `/sys/fs/cgroup`.
    private func cgroupVFSPath(_ cgroupPath: String) -> String {
        cgroupPath == "/" ? "/sys/fs/cgroup" : "/sys/fs/cgroup" + cgroupPath
    }

    /// Mount the `pids.current` / `pids.max` / `cgroup.procs` synthetic files for
    /// one cgroup. Each is computed live from the controller at read time.
    private func mountCgroupFiles(_ group: Cgroup) {
        let dir = cgroupVFSPath(group.path)
        let isRoot = group === cgroups.root
        vfs.createSyntheticFile(dir + "/pids.current") { [weak self] in
            guard let self else { return [] }
            let current = isRoot
                ? self.processTable.all.filter(\.isLive).count
                : self.cgroups.liveCount(group)
            return Array("\(current)\n".utf8)
        }
        vfs.createSyntheticFile(dir + "/pids.max") {
            Array(((group.pidsMax.map(String.init) ?? "max") + "\n").utf8)
        }
        vfs.createSyntheticFile(dir + "/cgroup.procs") { [weak self] in
            guard let self else { return [] }
            let pids = isRoot
                ? self.processTable.all.filter(\.isLive).map(\.pid).sorted()
                : self.cgroups.directLiveMembers(group)
            let text = pids.map(String.init).joined(separator: "\n")
            return Array((pids.isEmpty ? "" : text + "\n").utf8)
        }
    }

    /// Non-blocking reap: pop the next already-exited, un-waited child event, or
    /// `nil` if none is queued. Stop events are skipped because job control
    /// consumes them through `waitEvent`.
    func reapExitedChild(parent: Process) -> ChildWaitEvent? {
        childWaitQueue.reapExitedChild(parent: parent)
    }

    func wait(parent: Process, resume: @escaping (Result<ChildWaitEvent, SyscallError>) -> Void) {
        waitpid(parent: parent, childPID: nil, options: []) { result in
            resume(result.flatMap { event in
                guard let event else { return .failure(.noChildProcess) }
                return .success(event)
            })
        }
    }

    /// Linux-like `waitpid`: optionally wait for one child pid, optionally return
    /// stopped events, and optionally avoid blocking when no matching event is
    /// ready. `.success(nil)` is used only for WNOHANG/no ready event; no-child is
    /// reported as `.failure(.noChildProcess)`.
    func waitpid(parent: Process,
                 childPID target: PID?,
                 options: ProcessWaitOptions,
                 resume: @escaping (Result<ChildWaitEvent?, SyscallError>) -> Void) {
        childWaitQueue.waitpid(parent: parent,
                               childPID: target,
                               options: options,
                               schedule: { [weak self] process, work in
                                   self?.runStep(process, work)
                               },
                               resume: resume)
    }

    func waitEvent(parent: Process, resume: @escaping (Result<ChildWaitEvent, SyscallError>) -> Void) {
        waitpid(parent: parent, childPID: nil, options: [.untraced]) { result in
            resume(result.flatMap { event in
                guard let event else { return .failure(.noChildProcess) }
                return .success(event)
            })
        }
    }

    /// Deliver `signal` to `pid` with host authority. Unlike a guest `kill`,
    /// this is never filtered by the PID-1 protection (see
    /// `SignalDispatcher.kill(_:signal:sender:)`), so a host can always stop
    /// or terminate a session's init process.
    public func kill(_ pid: PID, signal: Int32) {
        signalDispatcher.kill(pid, signal: signal, sender: nil)
    }

    /// Guest-originated signal: `sender` is the calling process, which lets the
    /// dispatcher apply Linux's protection of a PID namespace's init.
    func kill(_ pid: PID, signal: Int32, from sender: Process) {
        signalDispatcher.kill(pid, signal: signal, sender: sender)
    }

    func setSignalMask(for process: Process, _ signals: Set<Int32>) {
        signalDispatcher.setSignalMask(for: process, signals)
    }

    func blockSignal(_ signal: Int32, for process: Process) {
        signalDispatcher.blockSignal(signal, for: process)
    }

    func unblockSignal(_ signal: Int32, for process: Process) {
        signalDispatcher.unblockSignal(signal, for: process)
    }

    // MARK: - Wall clock, entropy, terminals, power

    /// Current real time as seconds since the Unix epoch, derived from the
    /// logical clock through `wallClock`. Deterministic unless the host injected
    /// a real epoch.
    var epochNow: Double { wallClock.epochSeconds(atLogicalTime: loop.now) }

    /// Anchor the wall clock so that *now* (the loop's current logical time)
    /// reads as `epochSeconds`. Hosts call this once after construction, and
    /// again after any period in which logical time did not follow real time
    /// (for example after `resume()` from a long suspension). A non-finite
    /// `epochSeconds` leaves the clock unchanged. Call on the kernel's serial
    /// executor.
    public func setWallClock(epochSeconds: Double,
                             utcOffsetSeconds: Int = 0,
                             zoneAbbreviation: String = "UTC") {
        guard epochSeconds.isFinite else { return }
        wallClock = WallClock(epochAtLogicalZero: epochSeconds - loop.now,
                              utcOffsetSeconds: utcOffsetSeconds,
                              zoneAbbreviation: zoneAbbreviation)
        stampKernelProvidedNodes()
    }

    /// Date the nodes the kernel itself provides (`/dev/null`, `/proc/uptime`,
    /// ...) at boot, as `/proc/stat` reports it. They are created before a host
    /// can inject its clock, so they are dated again whenever the mapping
    /// changes; nothing persisted is touched.
    private func stampKernelProvidedNodes() {
        vfs.stampKernelProvidedNodes(wallClock.epochSeconds(atLogicalTime: bootLogicalTime))
    }

    /// Reseed the generator behind `/dev/random` and `/dev/urandom`. The stream
    /// is a deterministic function of the seed and is **not** cryptographically
    /// secure, whatever the seed's origin. Call on the kernel's serial executor.
    public func seedRandom(_ seed: UInt64) {
        random = DeterministicRandom(seed: seed)
    }

    /// The next `count` bytes of the kernel's pseudo-random stream.
    func randomBytes(_ count: Int) -> [UInt8] {
        random.bytes(count)
    }

    /// Total scheduler steps run by this kernel — a monotonic counter with a
    /// real source of truth, used as `ctxt` in `/proc/stat` and to bound how
    /// much an unbounded device hands out within one step.
    var schedulerStepCount: UInt64 { processScheduler.stepCount }

    /// The `pts` number of `terminal`, assigning the lowest free one on first
    /// use. Numbers are stable for the terminal's lifetime.
    @discardableResult
    func terminalIndex(for terminal: TerminalControl) -> Int {
        terminalSlots.removeAll { $0.terminal == nil }
        if let slot = terminalSlots.first(where: { $0.terminal === terminal }) {
            return slot.index
        }
        var index = 0
        let used = Set(terminalSlots.map(\.index))
        while used.contains(index) { index += 1 }
        terminalSlots.append(TerminalSlot(index: index, terminal: terminal))
        return index
    }

    /// The live terminal registered under `pts/<index>`, if any.
    func terminal(atIndex index: Int) -> TerminalControl? {
        terminalSlots.first { $0.index == index }?.terminal
    }

    /// Registered `pts` numbers whose terminal is still alive, ascending.
    var terminalIndices: [Int] {
        terminalSlots.filter { $0.terminal != nil }.map(\.index).sorted()
    }

    /// One login session attached to a terminal, as reported by `who`/`w`.
    struct TerminalSession: Equatable {
        let terminalIndex: Int
        let sessionID: PID
        let uid: UInt32
        /// Epoch seconds at which the session leader was spawned.
        let startEpoch: Double
        /// Name of the terminal's current foreground process-group leader (or
        /// the session leader when no foreground group is set).
        let foregroundCommand: String
    }

    /// Sessions that currently own a controlling terminal, ordered by `pts`
    /// number. Derived entirely from the process table: a session is listed
    /// while its leader is alive and still has a controlling terminal.
    func terminalSessions() -> [TerminalSession] {
        processTable.all.compactMap { process -> TerminalSession? in
            guard process.isLive, process.sessionID == process.pid,
                  let terminal = process.controllingTerminal else { return nil }
            let foreground = terminal.foregroundProcessGroupID
                .flatMap { processTable.process($0) }
                .flatMap { $0.isLive ? $0 : nil }
            let command = foreground ?? process
            return TerminalSession(
                terminalIndex: terminalIndex(for: terminal),
                sessionID: process.pid,
                uid: process.uid,
                startEpoch: wallClock.epochSeconds(atLogicalTime: process.startTime),
                foregroundCommand: command.args.isEmpty
                    ? command.name : command.args.joined(separator: " "))
        }
        .sorted { ($0.terminalIndex, $0.sessionID) < ($1.terminalIndex, $1.sessionID) }
    }

    /// Hand a guest power request to the host. Returns `false` when no handler
    /// is installed. The handler runs from a kernel-owned loop job so it never
    /// re-enters the requesting process's step.
    func postPowerRequest(_ request: PowerRequest) -> Bool {
        guard lifecycleState != .shutdown, onPowerRequest != nil else { return false }
        loop.schedule(after: 0, owner: workOwner) { [weak self] in
            self?.onPowerRequest?(request)
        }
        return true
    }

    // MARK: - Filesystem persistence

    /// Capture the current filesystem as a serializable `FilesystemSnapshot`
    /// (synthetic `/proc` files excluded). A consumer persists this across
    /// launches; must be called on the kernel's executor like any other API.
    public func snapshotFileSystem() -> FilesystemSnapshot {
        vfs.snapshot()
    }

    /// Replace the filesystem with `snapshot`, then re-mount the synthetic
    /// `/proc` tree (which is never persisted). Call this right after building
    /// the kernel and **before** spawning any process, so restored files are
    /// visible to the shell and its children. A malformed snapshot is rejected
    /// atomically: the existing tree remains unchanged and synthetic mounts are
    /// not disturbed.
    @discardableResult
    public func restoreFileSystem(_ snapshot: FilesystemSnapshot) -> Bool {
        guard vfs.restore(snapshot) else { return false }
        mountProcFS()
        vfs.reapplyPersistedMetadata(from: snapshot)
        return true
    }

    /// Mount the synthetic /proc tree: files whose contents are computed from
    /// live kernel + network state each time they are opened.
    private func mountProcFS() {
        ProcfsProvider.mount(on: vfs,
                             networkNamespace: netns,
                             processIntrospection: processIntrospection)
        // /proc/resources: system-wide resource accounting snapshot.
        vfs.createSyntheticFile("/proc/resources") { [weak self] in
            guard let self else { return [] }
            let snap = self.snapshotResources()
            let text = "processes=\(snap.processes) fds=\(snap.openFileDescriptors)"
                + " live=\(snap.liveProcesses) zombies=\(snap.zombieProcesses)"
                + " tcp=\(snap.tcpConnections) interfaces=\(snap.networkInterfaces)"
                + " vnodes=\(snap.vfsNodeCount) vfs_bytes=\(snap.vfsFileBytes)"
                + " runtime_memory=\(snap.runtimeMemoryBytes)"
                + " runtime_memory_limit=\(snap.runtimeMemoryLimitBytes)\n"
            return Array(text.utf8)
        }
        // /proc/devices: block device inventory.
        vfs.createSyntheticFile("/proc/devices") { [weak self] in
            guard let self else { return [] }
            let lines = self.blockDevices.summaries.map { summary in
                "\(summary.name) sectors=\(summary.sectorCount) sectorsize=\(summary.sectorSize) capacity=\(summary.capacity)"
            }
            let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            return Array(text.utf8)
        }
        // /proc/meminfo reports the managed-runtime budget and actual live heap
        // reports. It is deliberately not host physical memory or RSS. VFS file
        // bytes are listed separately and never passed off as process memory.
        vfs.createSyntheticFile("/proc/meminfo") { [weak self] in
            guard let self else { return [] }
            let snap = self.snapshotResources()
            let totalKB = snap.runtimeMemoryLimitBytes / 1024
            let usedKB = min(snap.runtimeMemoryBytes / 1024, totalKB)
            let freeKB = totalKB - usedKB
            let text = "MemTotal:       \(totalKB) kB\n"
                + "MemFree:        \(freeKB) kB\n"
                + "MemAvailable:   \(freeKB) kB\n"
                + "RuntimeHeap:    \(usedKB) kB\n"
                + "VFSFileBytes:   \(snap.vfsFileBytes) B\n"
                + "MemModel:       managed-runtime\n"
            return Array(text.utf8)
        }
        // /proc/cpuinfo: a single synthetic processor (there is one cooperative
        // executor; no per-core parallelism to report).
        vfs.createSyntheticFile("/proc/cpuinfo") {
            let text = "processor\t: 0\n"
                + "model name\t: Swiftix Virtual CPU\n"
                + "cpu cores\t: 1\n"
            return Array(text.utf8)
        }
        // /proc/uptime: logical seconds since boot from the monotonic loop clock
        // (deterministic, wall-clock-free — the same clock `uptime` reads).
        vfs.createSyntheticFile("/proc/uptime") { [weak self] in
            let seconds = Int(max(0, self?.loop.now ?? 0))
            let text = "\(seconds).00 \(seconds).00\n"
            return Array(text.utf8)
        }
        // /proc/mounts: the two synthetic mounts this kernel presents.
        vfs.createSyntheticFile("/proc/mounts") {
            let text = "tmpfs / tmpfs rw 0 0\nproc /proc proc rw 0 0\n"
            return Array(text.utf8)
        }
        // /proc/version: kernel identity string.
        vfs.createSyntheticFile("/proc/version") {
            Array("Swiftix version \(Swiftix.version) (Swift) #1\n".utf8)
        }
        // Versioned teaching-observability contract consumed by independently
        // packaged guest tools. A breaking field/schema change must advance the
        // schema in docs/compatibility.md and rebuild those packages.
        vfs.createSyntheticFile("/proc/swiftix") {
            let text = "Version:\t\(Swiftix.version)\n"
                + "ProcSchema:\t\(Swiftix.teachingProcfsSchemaVersion)\n"
                + "MemoryModel:\tmanaged-runtime\n"
                + "SyscallModel:\tswift-native-completed\n"
                + "SyscallHistory:\t\(Process.syscallTraceCapacity)\n"
            return Array(text.utf8)
        }
        // Per-process directories (/proc/<pid>/status, /proc/<pid>/cmdline),
        // resolved live from the process table (see ProcfsProvider).
        ProcfsProvider.mountPerProcess(on: vfs, processIntrospection: processIntrospection)

        mountSystemProcFS()
        mountDevices()

        // /sys/fs/cgroup: the cgroup hierarchy's synthetic files. Re-mount every
        // existing group (the root always, plus any created at runtime) so the
        // tree survives a filesystem restore, which drops synthetic files.
        for path in cgroups.allPaths {
            if let group = cgroups.cgroup(path) { mountCgroupFiles(group) }
        }
        stampKernelProvidedNodes()
    }

    /// System-wide procfs files that have a real source of truth in this kernel.
    private func mountSystemProcFS() {
        // /proc/loadavg. Every scheduler step completes within one logical
        // instant, so the time-weighted run-queue length over logical time is
        // identically zero: the three averages are exact, not placeholders. The
        // remaining fields are live: runnable/retained processes and the most
        // recently allocated pid.
        vfs.createSyntheticFile(ProcfsSchema.LoadAverage.path) { [weak self] in
            guard let self else { return [] }
            let all = self.processTable.all
            let running = all.lazy.filter {
                $0.isLive && ($0.runState == .running || $0.runState == .runnable)
            }.count
            return ProcfsSchema.render([ProcfsSchema.LoadAverage.line(
                running: running, total: all.count, lastPID: self.processTable.lastPID)])
        }
        // /proc/stat: only the counters this kernel actually maintains. There is
        // no CPU-time accounting, so the Linux `cpu` lines are deliberately absent.
        vfs.createSyntheticFile(ProcfsSchema.Stat.path) { [weak self] in
            guard let self else { return [] }
            let all = self.processTable.all
            let running = all.lazy.filter {
                $0.isLive && ($0.runState == .running || $0.runState == .runnable)
            }.count
            let blocked = all.lazy.filter { $0.isLive && $0.runState == .waiting }.count
            let boot = self.wallClock.epochSeconds(atLogicalTime: self.bootLogicalTime)
            return ProcfsSchema.render(ProcfsSchema.Stat.lines(
                contextSwitches: self.schedulerStepCount,
                bootEpoch: Int64(boot.rounded(.down)),
                processesCreated: self.processTable.lastPID,
                running: running,
                blocked: blocked))
        }
        // /proc/filesystems: the filesystem types `mount` and the kernel provide.
        vfs.createSyntheticFile(ProcfsSchema.Filesystems.path) {
            ProcfsSchema.render(ProcfsSchema.Filesystems.lines)
        }
        // /proc/sys/kernel: read-only identity. `hostname` follows the reader's
        // UTS namespace, like `uname -n`.
        vfs.createSyntheticFile(ProcfsSchema.SysKernel.hostnamePath) { [weak self] in
            guard let self else { return [] }
            let uts = self.vfs.reader?.utsNamespace ?? self.rootUTS
            return Array((uts.hostname + "\n").utf8)
        }
        vfs.createSyntheticFile(ProcfsSchema.SysKernel.ostypePath) {
            Array((ProcfsSchema.SysKernel.ostype + "\n").utf8)
        }
        vfs.createSyntheticFile(ProcfsSchema.SysKernel.osreleasePath) {
            Array((Swiftix.version + "\n").utf8)
        }
        // The directory holds only computed files, so it is not persisted.
        vfs.lookup("/proc/sys")?.isKernelProvided = true
    }

    /// Kernel-provided `/dev`. These nodes are (re)created here rather than
    /// stored, so they exist on a fresh kernel and after restoring a snapshot or
    /// rootfs image that predates them; none of them is ever persisted.
    private func mountDevices() {
        vfs.createDevice("/dev/null", kind: .null)
        vfs.createDevice("/dev/zero", kind: .zero)
        vfs.createDevice("/dev/full", kind: .full)
        // Both names read the same deterministic, seedable, non-cryptographic
        // stream (see `seedRandom(_:)`).
        vfs.createDevice("/dev/random", kind: .random)
        vfs.createDevice("/dev/urandom", kind: .random)
        // The calling process's controlling terminal.
        vfs.createDevice("/dev/tty", kind: .controllingTerminal)
        // Per-process descriptor views resolve through /proc/self/fd.
        vfs.createKernelSymlink("/dev/fd", target: "/proc/self/fd")
        vfs.createKernelSymlink("/dev/stdin", target: "/proc/self/fd/0")
        vfs.createKernelSymlink("/dev/stdout", target: "/proc/self/fd/1")
        vfs.createKernelSymlink("/dev/stderr", target: "/proc/self/fd/2")
        // /dev/pts/<n>: one node per registered terminal, resolved live.
        if let pts = vfs.createDirectory("/dev/pts") {
            pts.isKernelProvided = true
            pts.dynamicChildNames = { [weak self] in
                self?.terminalIndices.map(String.init) ?? []
            }
            pts.resolveDynamicChild = { [weak self] name in
                guard let self, let index = Int(name), String(index) == name,
                      self.terminal(atIndex: index) != nil else { return nil }
                let node = VNode(file: name)
                node.deviceKind = .terminal(index: index)
                node.mode = [.ownerRead, .ownerWrite, .groupWrite]
                return node
            }
        }
    }
}
