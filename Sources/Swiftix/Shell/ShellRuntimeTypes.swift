/// Mutable runtime state shared by the shell interpreter and its execution
/// helpers. These reference types remain confined to the shell process's serial
/// executor; they are intentionally non-Sendable and require no locking.
extension Programs {

    /// User-defined shell functions (`name() { … }`) keyed by name.
    final class FunctionTable {
        private var bodies: [String: [ScriptStatement]] = [:]

        func define(_ name: String, _ body: [ScriptStatement]) {
            bodies[name] = body
        }

        func body(_ name: String) -> [ScriptStatement]? {
            bodies[name]
        }
    }

    /// Background and stopped pipelines known to one shell process.
    final class JobTable {
        struct Job {
            let id: Int
            var pids: Set<PID>
            let command: String
            var stopped = false
        }

        private var jobsByID: [Int: Job] = [:]
        private var order: [Int] = []
        private var nextID = 1

        /// Register a launched pipeline; returns its job id and last pid for the
        /// `[id] pid` launch notice.
        func add(pids: [PID], command: String) -> (id: Int, last: PID) {
            let id = nextID
            nextID += 1
            jobsByID[id] = Job(id: id, pids: Set(pids), command: command)
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
                    jobsByID[id] = nil
                    order.removeAll { $0 == id }
                    return (id, job.command)
                }
                jobsByID[id] = job
                return nil
            }
            return nil
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

        func list() -> [(id: Int, command: String, stopped: Bool)] {
            order.compactMap { jobsByID[$0].map { ($0.id, $0.command, $0.stopped) } }
        }
    }

    /// One expanded pipeline stage, including process-local assignments and file
    /// descriptor redirections.
    struct Stage {
        var argv: [String]
        var stdinFile: String?
        var stdoutFile: String?
        var appendOut = false
        var stderrFile: String?
        var appendErr = false
        var stderrToStdout = false
        var stdoutToStderr = false
        var assignments: [(name: String, value: String)] = []
    }

    /// Last foreground command status used by `$?` expansion.
    final class ShellStatus {
        var last: Int32 = 0
    }

    /// Parse a `NAME=VALUE` token when NAME is a valid shell identifier.
    static func assignment(_ token: String) -> (name: String, value: String)? {
        guard let eq = token.firstIndex(of: "=") else { return nil }
        let name = String(token[token.startIndex..<eq])
        guard let first = name.first, first.isLetter || first == "_",
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }
        return (name, String(token[token.index(after: eq)...]))
    }
}
