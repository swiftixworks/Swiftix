/// Why a live process is parked. These are kernel-level facts rather than the
/// Linux display letter: several simultaneous waits still derive to one `S`.
enum ProcessWaitReason: Sendable, Equatable {
    case asyncBody
    case asyncContinuation
    case child(PID?)
    case sleep(deadline: Double)
    case descriptor(fd: Int, operation: String)
    case readiness([Int])
    case datagram(fd: Int)
    case icmp(identifier: UInt16, sequence: UInt16)
    case tcpAccept(fd: Int)
    case tcpConnect(fd: Int)
    case tcpReceive(fd: Int)
    case terminal(fd: Int)

    var description: String {
        switch self {
        case .asyncBody:
            return "async-body"
        case .asyncContinuation:
            return "async-continuation"
        case .child(let pid):
            return pid.map { "child:\($0)" } ?? "child:any"
        case .sleep(let deadline):
            return "sleep-until:\(deadline)"
        case .descriptor(let fd, let operation):
            return "fd:\(fd):\(operation)"
        case .readiness(let fds):
            return "poll:" + fds.map(String.init).joined(separator: ",")
        case .datagram(let fd):
            return "udp-recv:\(fd)"
        case .icmp(let identifier, let sequence):
            return "icmp:\(identifier):\(sequence)"
        case .tcpAccept(let fd):
            return "tcp-accept:\(fd)"
        case .tcpConnect(let fd):
            return "tcp-connect:\(fd)"
        case .tcpReceive(let fd):
            return "tcp-recv:\(fd)"
        case .terminal(let fd):
            return "tty-read:\(fd)"
        }
    }
}

/// Single-executor registry for all outstanding process waits. A wait has a
/// stable token, a diagnostic reason, and optionally an external cancellation
/// action. Logical exit drains the registry before the process becomes a zombie.
final class ProcessWaitRegistry {
    private struct Entry {
        let reason: ProcessWaitReason
        var cancellation: (() -> Void)?
    }

    private var nextID = 1
    private var entries: [Int: Entry] = [:]

    var count: Int { entries.count }
    var reasons: [ProcessWaitReason] {
        entries.keys.sorted().compactMap { entries[$0]?.reason }
    }

    func begin(_ reason: ProcessWaitReason,
               cancellation: (() -> Void)? = nil) -> Int {
        let id = nextID
        nextID += 1
        entries[id] = Entry(reason: reason, cancellation: cancellation)
        return id
    }

    func setCancellation(_ cancellation: @escaping () -> Void, for id: Int) {
        guard entries[id] != nil else { return }
        entries[id]?.cancellation = cancellation
    }

    func disarmCancellation(for id: Int) {
        entries[id]?.cancellation = nil
    }

    func end(_ id: Int) {
        entries[id] = nil
    }

    func cancelAll() {
        let actions = entries.keys.sorted().compactMap { entries[$0]?.cancellation }
        entries.removeAll(keepingCapacity: false)
        for action in actions { action() }
    }
}
