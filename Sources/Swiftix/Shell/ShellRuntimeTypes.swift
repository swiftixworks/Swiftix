/// Mutable runtime state and small value types shared by the shell interpreter
/// and its execution helpers. The reference types remain confined to the shell
/// process's serial executor; they are intentionally non-Sendable and require no
/// locking.
extension Programs {

    /// Background and stopped pipelines known to one shell process.
    final class JobTable {
        struct Job {
            let id: Int
            var pids: Set<PID>
            /// The last pipeline stage: its status is the job's status.
            let lastPID: PID
            let command: String
            var stopped = false
        }

        private var jobsByID: [Int: Job] = [:]
        private var order: [Int] = []

        /// Register a launched pipeline; returns its job id and last pid for the
        /// `[id] pid` launch notice.
        func add(pids: [PID], command: String) -> (id: Int, last: PID) {
            // Like bash: one past the highest id in use, so numbering restarts
            // at 1 once every job has finished.
            let id = (order.max() ?? 0) + 1
            jobsByID[id] = Job(id: id, pids: Set(pids), lastPID: pids.last ?? 0, command: command)
            order.append(id)
            return (id, pids.last ?? 0)
        }

        /// Mark `pid` as exited. Remove and return the job once its last process
        /// exits; otherwise update the remaining process set.
        func complete(pid: PID) -> (id: Int, command: String)? {
            for id in order {
                guard var job = jobsByID[id], job.pids.contains(pid) else { continue }
                job.pids.remove(pid)
                if job.pids.isEmpty {
                    remove(id: id)
                    return (id, job.command)
                }
                jobsByID[id] = job
                return nil
            }
            return nil
        }

        func remove(id: Int) {
            jobsByID[id] = nil
            order.removeAll { $0 == id }
        }

        /// Flag the job owning `pid` as stopped by Ctrl-Z.
        func markStopped(pid: PID) -> (id: Int, command: String)? {
            for id in order where jobsByID[id]?.pids.contains(pid) == true {
                jobsByID[id]?.stopped = true
                return (id, jobsByID[id]!.command)
            }
            return nil
        }

        func setRunning(id: Int) {
            jobsByID[id]?.stopped = false
        }

        func job(id: Int) -> Job? {
            jobsByID[id]
        }

        /// The job that contains `pid`, if any.
        func job(containing pid: PID) -> Job? {
            order.compactMap { jobsByID[$0] }.first { $0.pids.contains(pid) }
        }

        func list() -> [(id: Int, command: String, stopped: Bool)] {
            order.compactMap { jobsByID[$0].map { ($0.id, $0.command, $0.stopped) } }
        }

        /// Resolve a job spec (`%N`, `%%`, `%+`, `%-`, or a bare `N`).
        func id(forSpec spec: String) -> Int? {
            var text = spec
            if text.hasPrefix("%") { text.removeFirst() }
            if text.isEmpty || text == "%" || text == "+" { return order.last }
            if text == "-" { return order.count >= 2 ? order[order.count - 2] : order.last }
            guard let id = Int(text), jobsByID[id] != nil else { return nil }
            return id
        }
    }

    /// Last foreground command status used by `$?` expansion.
    final class ShellStatus {
        var last: Int32 = 0
    }

    /// A simple command after expansion: assignments, argument vector, and
    /// redirections with their targets resolved.
    struct PreparedCommand {
        var assignments: [(name: String, value: String)] = []
        var argv: [String] = []
        var redirections: [ResolvedRedirection] = []
        /// Status of the last command substitution that ran while expanding
        /// it (`$?` for an assignment-only command); `nil` when none ran.
        var substitutionStatus: Int32?
    }

    /// One redirection with its target expanded.
    enum ResolvedRedirection {
        case read(fd: Int, path: String)
        case write(fd: Int, path: String, append: Bool)
        case duplicate(fd: Int, target: Int)
        case close(fd: Int)
        /// Here-document / here-string content delivered on `fd`.
        case data(fd: Int, text: String)

        var fd: Int {
            switch self {
            case let .read(fd, _), let .write(fd, _, _), let .duplicate(fd, _),
                 let .close(fd), let .data(fd, _):
                return fd
            }
        }
    }

    /// One process of a pipeline, ready to spawn.
    struct StageLaunch {
        enum Body {
            /// A registered program; `setup` applies its assignments and
            /// redirections in the child and reports whether to run it.
            case command(Command, setup: (ProcessContext) -> Bool)
            /// Shell code (builtin, function, compound command) run by a child
            /// interpreter. The body owns the child's exit.
            case shell((ProcessContext) -> Void)
        }
        var name: String
        var argv: [String]
        var label: String
        var body: Body
    }

    /// Pending non-local control flow, checked after every command.
    enum ShellFlow: Equatable {
        case none
        case breakLoop(Int)
        case continueLoop(Int)
        case returning
        /// Abandon everything up to the interactive prompt (expansion error).
        case abort
    }

    /// The copyable part of a shell's state, handed to a child interpreter
    /// (subshell, pipeline stage, command substitution) at fork time.
    struct ShellSnapshot {
        var functions: [String: [ScriptStatement]]
        var aliases: [String: String]
        var variables: [String: String]
        var positional: [String]
        var scriptName: String
        var shellPID: PID
        var errexit: Bool
        var nounset: Bool
        var xtrace: Bool
        /// `$?` and `$!` as they were at fork time.
        var lastStatus: Int32
        var lastBackgroundPID: PID?
        var history: [String]
        /// The parent's traps and jobs, for listing only (`$(trap)`,
        /// `jobs | cat`): the child neither runs those traps nor owns those jobs.
        var traps: [String: String]
        var jobs: [(id: Int, command: String, stopped: Bool)]
    }

    /// Run `step` repeatedly until it reports `false`, then call `done`. A step
    /// that completes synchronously is re-run by a loop instead of by recursion,
    /// so a long run of builtin-only iterations never grows the native stack; a
    /// step that completes later (after a parked syscall) simply restarts the
    /// loop from its continuation.
    static func drive(_ step: @escaping (_ next: @escaping (Bool) -> Void) -> Void,
                      done: @escaping () -> Void) {
        final class State {
            var running = false
            var again = false
            var finished = false
        }
        let state = State()
        func pump() {
            if state.running { state.again = true; return }
            state.running = true
            repeat {
                state.again = false
                step { more in
                    if more { pump() }
                    else if state.running { state.finished = true }
                    else { done() }
                }
            } while state.again && !state.finished
            state.running = false
            if state.finished { done() }
        }
        pump()
    }
}
