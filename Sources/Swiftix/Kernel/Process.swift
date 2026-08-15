/// A process identifier.
public typealias PID = Int

/// A "process" — a cooperative task scheduled on the kernel's event loop, **not**
/// an OS process (iOS forbids `fork`/`exec`). It carries the per-process state a
/// Linux process has: identity, working directory, environment, and its open
/// file descriptors. Hundreds of these share one scheduler, so an instance stays
/// cheap.
final class Process {
    enum State {
        case runnable
        case running
        case blocked
        case stopped
        case zombie(status: ProcessWaitStatus)
    }

    let pid: PID
    let ppid: PID
    let name: String
    var state: State = .runnable

    /// Minimal POSIX-style job-control identity. Top-level processes start their
    /// own session and process group; children inherit until a shell places a job
    /// into a distinct process group.
    var processGroupID: PID
    var sessionID: PID

    /// Number of outstanding blocking operations (parked, or scheduled to
    /// resume). The scheduler keeps the process alive while this is > 0.
    var blockedOn = 0

    /// A deterministic CPU-activity proxy: the number of times the scheduler has
    /// run this process (a fresh body or a resumed step). Wall-clock CPU time has
    /// no meaning under the logical clock — every synchronous step completes in a
    /// single logical instant — so this counts scheduling *steps* instead, which
    /// is reproducible and reflects relative busyness. Surfaced as the `TICKS`
    /// column in `/proc/processes` and consumed by `ps`/`top`.
    var scheduleTicks = 0

    /// Job-control stop (SIGTSTP). While stopped, scheduling steps are held in
    /// `pendingSteps` and replayed on SIGCONT.
    var isStopped = false
    var pendingSteps: [() -> Void] = []

    /// Cancellation hooks for currently parked wait operations. Termination
    /// drains these before reaping the process so checked async continuations do
    /// not get stranded behind a process-table guard.
    private var nextWaitCancellationID = 1
    private var waitCancellations: [Int: () -> Void] = [:]

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

    /// One-shot observers invoked after this process has left the process table.
    /// They run on the Kernel's serial executor and are intentionally non-Sendable.
    var exitObservers: [(ProcessWaitStatus) -> Void] = []

    /// Installed signal handlers (number -> action). No handler = default
    /// disposition, applied by the kernel.
    var signalHandlers: [Int32: () -> Void] = [:]

    /// Blocked signals and pending deliveries. SIGKILL is never maskable; SIGCONT
    /// still resumes job-control stops immediately.
    var signalMask: Set<Int32> = []
    var pendingSignals: [Int32] = []

    /// Process credentials (permissive-first: stored for observability, not yet
    /// enforced for permission checks). Default 0 = root.
    var uid: UInt32 = 0
    var gid: UInt32 = 0

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

    init(pid: PID, ppid: PID, name: String) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.processGroupID = pid
        self.sessionID = pid
    }

    @discardableResult
    func addWaitCancellation(_ action: @escaping () -> Void) -> Int {
        let id = nextWaitCancellationID
        nextWaitCancellationID += 1
        waitCancellations[id] = action
        return id
    }

    func removeWaitCancellation(_ id: Int) {
        waitCancellations[id] = nil
    }

    func cancelWaits() {
        let actions = Array(waitCancellations.values)
        waitCancellations.removeAll()
        for action in actions { action() }
    }
}
