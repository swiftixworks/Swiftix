/// A process identifier.
public typealias PID = Int

/// A "process" — a cooperative task scheduled on the kernel's event loop, **not**
/// an OS process (iOS forbids `fork`/`exec`). It carries the per-process state a
/// Linux process has: identity, working directory, environment, and its open
/// file descriptors. Hundreds of these share one scheduler, so an instance stays
/// cheap.
final class Process {
    /// Scheduling state for a process that is still executable. Exit is tracked
    /// independently in `lifecycle`, matching the separation between runnability
    /// and exit state in Linux and preventing a stopped process from becoming an
    /// invalid "stopped zombie".
    enum RunState: Equatable {
        case runnable
        case running
        case waiting
        case stopped
    }

    enum Lifecycle: Equatable {
        case live
        case exiting(ProcessExitStatus)
        case zombie(ProcessExitStatus)
    }

    let pid: PID
    var ppid: PID
    let name: String
    var runState: RunState = .runnable
    var lifecycle: Lifecycle = .live

    /// Runnable steps currently owned by this process's event-loop scope. This
    /// lets observability report R as soon as a wakeup is queued, instead of
    /// leaving the process in S until the callback actually starts executing.
    var queuedSteps = 0

    /// Every callback created by process/runtime code belongs to this scope.
    /// Logical exit cancels it physically while the lightweight process identity
    /// remains in the table as a zombie.
    let workScope: EventLoop.CancellationScope

    /// Minimal POSIX-style job-control identity. Top-level processes start their
    /// own session and process group; children inherit until a shell places a job
    /// into a distinct process group.
    var processGroupID: PID
    var sessionID: PID

    /// Structured ownership for outstanding blocking operations. The scheduler
    /// derives `waiting` from this registry, while diagnostics retain the exact
    /// reasons instead of exposing only an opaque counter.
    private let waits = ProcessWaitRegistry()
    var blockedOn: Int { waits.count }
    var waitReasons: [ProcessWaitReason] { waits.reasons }

    /// Lifetime hold used by an async command body. Async syscalls register
    /// their own, more specific waits in addition to this outer hold.
    var asyncBodyWaitID: Int?

    /// A deterministic CPU-activity proxy: the number of times the scheduler has
    /// run this process (a fresh body or a resumed step). Wall-clock CPU time has
    /// no meaning under the logical clock — every synchronous step completes in a
    /// single logical instant — so this counts scheduling *steps* instead, which
    /// is reproducible and reflects relative busyness. Surfaced as the `TICKS`
    /// column in `/proc/processes` and consumed by `ps`/`top`.
    var scheduleTicks = 0

    /// Job-control stop (SIGSTOP/SIGTSTP). While stopped, scheduling steps are
    /// held in `pendingSteps` and replayed on SIGCONT.
    var pendingSteps: [() -> Void] = []

    var cwd = "/"
    var environment: [String: String] = [:]

    /// The argument vector the process was spawned with (POSIX `argv`). By
    /// convention `args[0]` is the program name. Empty for processes spawned
    /// without arguments. Read by programs through `ProcessContext.arguments`.
    var args: [String] = []

    let fileDescriptors = FileDescriptorTable()

    /// The process's controlling terminal is identity, not a view of its current
    /// standard descriptors. It survives temporary redirection of fd 0/1/2 and
    /// is inherited by children in the same terminal session.
    weak var controllingTerminal: TerminalControl?

    /// One-shot observers invoked at logical exit, before the zombie is reaped.
    /// They run on the Kernel's serial executor and are intentionally non-Sendable.
    var exitObservers: [(ProcessWaitStatus) -> Void] = []

    /// Installed signal handlers (number -> action). No handler = default
    /// disposition, applied by the kernel.
    var signalHandlers: [Int32: () -> Void] = [:]

    /// Blocked signals and pending deliveries. SIGKILL and SIGSTOP are never
    /// maskable; SIGCONT still resumes job-control stops immediately.
    var signalMask: Set<Int32> = []
    var pendingSignals: [Int32] = []

    /// Compact effective-credential model used by the VFS DAC checks. Swiftix
    /// intentionally does not model real/saved IDs or Linux capabilities, but
    /// these values and supplementary groups are inherited across spawn.
    /// Default 0 = root.
    var uid: UInt32 = 0
    var gid: UInt32 = 0
    var supplementaryGroups: Set<UInt32> = []

    /// The UTS namespace this process belongs to (hostname/domainname). Shared by
    /// reference with the parent on spawn, so a `hostname` change is visible
    /// machine-wide — until the process `unshare`s a private copy. The fresh
    /// default here is a placeholder; the kernel reassigns it in `inherit` (to the
    /// parent's, or to the kernel's root namespace for a top-level process).
    var utsNamespace = UTSNamespace()

    /// The PID namespace this process belongs to. Shared with the parent unless
    /// the parent requested a new one for its next child (see below). Set by the
    /// kernel in `inherit`; `nil` only before that (never observed by a body).
    var pidNamespace: PIDNamespace!

    /// One-shot request (set by `unsharePIDNamespace`, the `unshare(CLONE_NEWPID)`
    /// analogue): the *next* child this process spawns is placed in a fresh PID
    /// namespace as its pid 1. A process cannot change its own pid namespace — its
    /// pid is fixed — so, like Linux, the unshare takes effect for children.
    var unshareChildIntoNewPIDNamespace = false

    /// The mount namespace this process belongs to (its view of the mount table).
    /// Shared with the parent on spawn; `unshare(CLONE_NEWNS)` swaps in a private
    /// copy for this process (and its future children). Set by the kernel in
    /// `inherit`; `nil` only before that (never observed by a body).
    var mountNamespace: MountNamespace!

    init(pid: PID, ppid: PID, name: String, workScope: EventLoop.CancellationScope) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.workScope = workScope
        self.processGroupID = pid
        self.sessionID = pid
    }

    var isLive: Bool {
        if case .live = lifecycle { return true }
        return false
    }

    var isStopped: Bool {
        isLive && runState == .stopped
    }

    var terminalStatus: ProcessExitStatus? {
        switch lifecycle {
        case .live: return nil
        case .exiting(let status), .zombie(let status): return status
        }
    }

    @discardableResult
    func beginExit(_ status: ProcessExitStatus) -> Bool {
        guard isLive else { return false }
        lifecycle = .exiting(status)
        return true
    }

    func becomeZombie() {
        guard case .exiting(let status) = lifecycle else { return }
        lifecycle = .zombie(status)
    }

    func beginWait(_ reason: ProcessWaitReason,
                   cancellation: (() -> Void)? = nil) -> Int {
        guard isLive else { return 0 }
        return waits.begin(reason, cancellation: cancellation)
    }

    func setWaitCancellation(_ action: @escaping () -> Void, for id: Int) {
        waits.setCancellation(action, for: id)
    }

    func disarmWaitCancellation(_ id: Int) {
        waits.disarmCancellation(for: id)
    }

    func endWait(_ id: Int) { waits.end(id) }

    func cancelWaits() { waits.cancelAll() }
}
