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
    /// Open file-descriptor count.
    let fds: Int
    /// Exact bytes currently reported by a managed runtime. This is intentionally
    /// named MEM rather than RSS because Swiftix has no process address space.
    let memoryBytes: Int
    let memoryLimitBytes: Int
    let heapCells: Int
    let garbageCollections: Int
    let descriptors: [FileDescriptorTable.DiagnosticSnapshot]
    /// Bounded completed-call history for `/proc/<pid>/syscalls`.
    let syscalls: [SyscallTraceEntry]
    /// The process's command line (argv joined by spaces, or its name when it was
    /// spawned without arguments). Surfaced by `/proc/<pid>/cmdline`.
    let command: String
    /// Global pid, regardless of the namespace the row was translated into.
    /// `/proc/<pid>/fd` nodes address the process by this identity.
    let globalPID: PID
    /// Effective credentials; they own the process's private procfs nodes.
    let uid: UInt32
    let gid: UInt32
    /// Environment (`/proc/<pid>/environ`).
    let environment: [String: String]
    /// `pts` number of the controlling terminal, if it has one.
    let terminalIndex: Int?
    /// Foreground process group of that terminal, if any.
    let terminalForegroundGroup: PID?
    /// Open descriptor numbers, ascending (`/proc/<pid>/fd`). Empty for a zombie.
    let descriptorNumbers: [Int]
    /// Absolute working directory (`/proc/<pid>/cwd`).
    let workingDirectory: String
}

final class ProcessIntrospection {
    private let processTable: ProcessTable

    /// Resolves a controlling terminal to its `pts` number. Installed by the
    /// kernel, which owns the terminal registry.
    var terminalIndex: (TerminalControl) -> Int? = { _ in nil }

    init(processTable: ProcessTable) {
        self.processTable = processTable
    }

    func snapshotProcesses() -> [ProcessSnapshotRow] {
        processTable.all
            .map { row(from: $0) }
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
            return row(from: process,
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
        processTable.process(pid).map { row(from: $0) }
    }

    private func row(from process: Process,
                            pid: PID? = nil, ppid: PID? = nil,
                            pgid: PID? = nil, sid: PID? = nil) -> ProcessSnapshotRow {
        ProcessSnapshotRow(
            pid: pid ?? process.pid,
            ppid: ppid ?? process.ppid,
            pgid: pgid ?? process.processGroupID,
            sid: sid ?? process.sessionID,
            name: process.name,
            state: Self.stateName(process),
            ticks: process.scheduleTicks,
            fds: process.fileDescriptors.openDescriptors.count,
            memoryBytes: process.runtimeMemoryBytes,
            memoryLimitBytes: process.runtimeMemoryLimitBytes,
            heapCells: process.runtimeHeapCells,
            garbageCollections: process.runtimeGarbageCollections,
            descriptors: process.fileDescriptors.diagnosticSnapshots,
            syscalls: process.syscallTrace,
            command: process.args.isEmpty ? process.name : process.args.joined(separator: " "),
            globalPID: process.pid,
            uid: process.uid,
            gid: process.gid,
            environment: process.environment,
            terminalIndex: process.controllingTerminal.flatMap(terminalIndex),
            terminalForegroundGroup: process.controllingTerminal?.foregroundProcessGroupID,
            descriptorNumbers: process.fileDescriptors.openDescriptors,
            workingDirectory: process.cwd)
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
