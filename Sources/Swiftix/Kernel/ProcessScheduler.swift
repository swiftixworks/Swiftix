/// Single-executor scheduler operations for runnable, blocked, and stopped processes.
final class ProcessScheduler {
    private let processTable: ProcessTable
    private let deliverPendingSignals: (Process) -> Bool
    private let exit: (Process, ProcessExitStatus) -> Void

    init(processTable: ProcessTable,
         deliverPendingSignals: @escaping (Process) -> Bool,
         exit: @escaping (Process, ProcessExitStatus) -> Void) {
        self.processTable = processTable
        self.deliverPendingSignals = deliverPendingSignals
        self.exit = exit
    }

    /// Run one step of a process on the event loop: a fresh body, or the
    /// resumption of a blocking syscall / signal handler. Every step belongs to
    /// the process's work scope, so stop/pause can freeze it and logical exit
    /// physically removes it even while a zombie identity remains.
    /// `finishStep` then decides the process's fate.
    func runStep(_ process: Process, _ work: @escaping () -> Void) {
        guard processTable.contains(process.pid), process.isLive else { return }
        process.queuedSteps += 1
        if !process.isStopped, process.runState != .running {
            process.runState = .runnable
        }
        process.workScope.schedule(after: 0) { [weak self, weak process] in
            guard let self, let process,
                  self.processTable.contains(process.pid), process.isLive else { return }
            process.queuedSteps -= 1
            if process.isStopped {
                process.pendingSteps.append(work)   // job-control stop: defer until SIGCONT
                return
            }
            process.runState = .running
            process.scheduleTicks += 1   // CPU-activity proxy: how often this process was run
            work()
            guard self.processTable.contains(process.pid) else { return }
            self.finishStep(process)
        }
    }

    private func finishStep(_ process: Process) {
        guard processTable.contains(process.pid) else { return }
        switch process.lifecycle {
        case .exiting(let status):
            exit(process, status)
            return
        case .zombie:
            return
        case .live:
            break
        }
        if deliverPendingSignals(process) {
            finishStep(process)
        } else if process.isStopped {
            process.runState = .stopped
        } else if process.queuedSteps > 0 {
            process.runState = .runnable
        } else if process.blockedOn > 0 {
            process.runState = .waiting                 // parked on I/O or a child
        } else {
            exit(process, .exited(0))                   // returned with nothing pending
        }
    }
}
