/// Value snapshots used by procfs and diagnostics without exposing processes.
struct ProcessSnapshotRow {
    let pid: PID
    let ppid: PID
    let pgid: PID
    let sid: PID
    let name: String
    let state: String
    /// Deterministic CPU-activity proxy: scheduler steps run for this process.
    let ticks: Int
    /// Open file-descriptor count: a resource/"footprint" proxy (there is no
    /// per-process address space, so no true RSS to report).
    let fds: Int
    /// The process's command line (argv joined by spaces, or its name when it was
    /// spawned without arguments). Surfaced by `/proc/<pid>/cmdline`.
    let command: String
}

final class ProcessIntrospection {
    private let processTable: ProcessTable

    init(processTable: ProcessTable) {
        self.processTable = processTable
    }

    func snapshotProcesses() -> [ProcessSnapshotRow] {
        processTable.all
            .map { Self.row(from: $0) }
            .sorted { $0.pid < $1.pid }
    }

    /// The processes visible in `namespace` (its members: the reader's own PID
    /// namespace plus any descendants), with pid/ppid/pgid/sid translated to that
    /// namespace's local numbering. A pid whose referent is not a member of the
    /// namespace (e.g. pid 1's parent, which lives in an outer namespace) maps to
    /// 0 — matching how a contained process sees "no parent". In the root
    /// namespace this is the identity, so it reproduces `snapshotProcesses()`.
    func snapshotProcesses(in namespace: PIDNamespace) -> [ProcessSnapshotRow] {
        namespace.globalMembers.compactMap { global -> ProcessSnapshotRow? in
            guard let process = processTable.process(global) else { return nil }
            return Self.row(from: process,
                            pid: namespace.localPID(forGlobal: global) ?? global,
                            ppid: namespace.localPID(forGlobal: process.ppid) ?? 0,
                            pgid: namespace.localPID(forGlobal: process.processGroupID) ?? 0,
                            sid: namespace.localPID(forGlobal: process.sessionID) ?? 0)
        }
        .sorted { $0.pid < $1.pid }
    }

    /// The row for a single retained pid, including a zombie. Used by the
    /// per-process `/proc/<pid>` synthetic directories.
    func row(for pid: PID) -> ProcessSnapshotRow? {
        processTable.process(pid).map { Self.row(from: $0) }
    }

    private static func row(from process: Process,
                            pid: PID? = nil, ppid: PID? = nil,
                            pgid: PID? = nil, sid: PID? = nil) -> ProcessSnapshotRow {
        ProcessSnapshotRow(
            pid: pid ?? process.pid,
            ppid: ppid ?? process.ppid,
            pgid: pgid ?? process.processGroupID,
            sid: sid ?? process.sessionID,
            name: process.name,
            state: stateName(process),
            ticks: process.scheduleTicks,
            fds: process.fileDescriptors.openDescriptors.count,
            command: process.args.isEmpty ? process.name : process.args.joined(separator: " "))
    }

    static func stateName(_ process: Process) -> String {
        stateName(runState: process.runState, lifecycle: process.lifecycle)
    }

    static func stateName(runState: Process.RunState,
                          lifecycle: Process.Lifecycle = .live) -> String {
        if case .zombie = lifecycle { return "Z" }
        switch runState {
        case .runnable, .running: return "R"
        case .waiting: return "S"
        case .stopped: return "T"
        }
    }
}
