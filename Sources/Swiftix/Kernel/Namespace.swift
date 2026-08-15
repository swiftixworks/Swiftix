/// A network namespace: the per-instance network context. For now it owns one
/// `NetworkStack`; pid/mount namespaces — and multiple net namespaces per
/// kernel — come later. This is the bridge between the kernel core and the data
/// plane: a `socket()` syscall creates a `FileObject` bound to `stack`, whose
/// datagrams flow out through a `Port` and across a `Link`.
public final class NetworkNamespace {
    public let name: String
    public let stack: NetworkStack

    init(loop: EventLoop,
         workOwner: EventLoop.WorkOwner? = nil,
         name: String = "default") {
        self.name = name
        self.stack = NetworkStack(loop: loop, workOwner: workOwner)
    }
}

/// A UTS namespace: the isolation unit for the system's identity strings — its
/// hostname and NIS/domain name (the "UTS" in `struct utsname`). A process holds
/// a *reference* to one, and shares it with its parent and children by default,
/// so `hostname foo` changes the name the whole machine sees. `unshare(-u)`
/// swaps in a private *copy*, after which changes are invisible to the parent —
/// the smallest, clearest demonstration of namespace isolation.
///
/// Reference type on purpose: sharing vs. unsharing is exactly "same object" vs.
/// "a copy", and it is mutated only on the single serial executor (no lock).
/// Kept `internal` — the consumer boundary is `ProcessContext.hostname` /
/// `setHostname` / `unshareUTS`, not this type.
final class UTSNamespace {
    var hostname: String
    var domainName: String

    init(hostname: String = "swiftix", domainName: String = "(none)") {
        self.hostname = hostname
        self.domainName = domainName
    }

    /// A private duplicate with the same current names but no further sharing —
    /// the state `unshare(CLONE_NEWUTS)` leaves the caller in.
    func copy() -> UTSNamespace {
        UTSNamespace(hostname: hostname, domainName: domainName)
    }
}

/// A PID namespace: the isolation unit for process identifiers. A process has a
/// distinct pid *in its own namespace and in every ancestor* — that is the whole
/// trick behind `unshare --pid`. The kernel keeps one global pid per process as
/// its internal source of truth (scheduling, `wait`, `kill`, signals, cgroups all
/// key off it); this type is the mapping layer that projects that global pid to a
/// namespace-local one:
///
///   - The **root** namespace is the identity: local pid == global pid, so
///     everything outside a container behaves exactly as before.
///   - A **child** namespace allocates its own sequence starting at 1, so the
///     first process created in it is pid 1 (its "init").
///
/// Visibility follows from membership: a process is registered in its own
/// namespace and each ancestor, so a reader sees exactly the processes registered
/// in *its* namespace (itself + descendants) and never those of an ancestor or a
/// sibling — the isolation a learner observes with `ps`.
///
/// Reference type, mutated only on the single serial executor (no lock). Kept
/// `internal`; the consumer boundary is `ProcessContext` (`getpid`, the ns-aware
/// process listing, `unsharePIDNamespace`).
final class PIDNamespace {
    weak var parent: PIDNamespace?
    let isRoot: Bool
    /// Depth from the root (root = 0), used only for display/ordering.
    let level: Int
    private var localByGlobal: [PID: PID] = [:]
    private var globalByLocal: [PID: PID] = [:]
    private var nextLocal: PID = 1

    init(parent: PIDNamespace?) {
        self.parent = parent
        self.isRoot = (parent == nil)
        self.level = (parent?.level ?? -1) + 1
    }

    /// Register a global pid as a member of this namespace, assigning its
    /// namespace-local pid (the global pid itself in the root; 1, 2, 3, … in a
    /// child). Idempotent: re-registering returns the existing local pid.
    @discardableResult
    func register(global: PID) -> PID {
        if let existing = localByGlobal[global] { return existing }
        let local = isRoot ? global : nextLocal
        if !isRoot { nextLocal += 1 }
        localByGlobal[global] = local
        globalByLocal[local] = global
        return local
    }

    /// Drop a global pid's membership (called when the process is reaped).
    func unregister(global: PID) {
        if let local = localByGlobal.removeValue(forKey: global) {
            globalByLocal[local] = nil
        }
    }

    /// The namespace-local pid for a global pid, or `nil` if it is not a member.
    func localPID(forGlobal global: PID) -> PID? { localByGlobal[global] }

    /// The global pid behind a namespace-local pid, or `nil` if unknown here.
    func globalPID(forLocal local: PID) -> PID? { globalByLocal[local] }

    /// Whether `global` is a member of (visible in) this namespace.
    func contains(global: PID) -> Bool { localByGlobal[global] != nil }

    /// The global pids of every member of this namespace (unordered).
    var globalMembers: [PID] { Array(localByGlobal.keys) }
}
