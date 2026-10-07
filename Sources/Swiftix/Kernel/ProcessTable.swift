/// PID allocation and lookup for retained live and zombie process identities.
final class ProcessTable {
    private let loop: EventLoop
    private var storage: [PID: Process] = [:]
    private var nextPID: PID = 1

    init(loop: EventLoop = EventLoop()) {
        self.loop = loop
    }

    var count: Int { storage.count }
    var all: [Process] { Array(storage.values) }

    /// The most recently allocated pid (0 before the first spawn). Because pids
    /// are never reused, this is also the number of processes ever created.
    var lastPID: PID { nextPID - 1 }

    func process(_ pid: PID) -> Process? {
        storage[pid]
    }

    func contains(_ pid: PID) -> Bool {
        storage[pid] != nil
    }

    func allocate(name: String, args: [String], parent: PID) -> Process {
        let pid = nextPID
        nextPID += 1
        let process = Process(
            pid: pid,
            ppid: parent,
            name: name,
            workScope: loop.makeCancellationScope(),
            startTime: loop.now)
        process.args = args
        storage[pid] = process
        return process
    }

    @discardableResult
    func remove(_ pid: PID) -> Process? {
        storage.removeValue(forKey: pid)
    }
}
