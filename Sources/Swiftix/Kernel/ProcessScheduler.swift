/// Single-executor scheduler operations for runnable, blocked, and stopped processes.
final class ProcessScheduler {
    private let loop: EventLoop
    private let workOwner: EventLoop.WorkOwner
    private let processTable: ProcessTable
    private let deliverPendingSignals: (Process) -> Bool
    private let exit: (Process, ProcessWaitStatus) -> Void

    init(loop: EventLoop,
         workOwner: EventLoop.WorkOwner,
         processTable: ProcessTable,
         deliverPendingSignals: @escaping (Process) -> Bool,
         exit: @escaping (Process, ProcessWaitStatus) -> Void) {
        self.loop = loop
        self.workOwner = workOwner
        self.processTable = processTable
        self.deliverPendingSignals = deliverPendingSignals
        self.exit = exit
    }

    /// Run one step of a process on the event loop: a fresh body, or the
    /// resumption of a blocking syscall / signal handler. Every step belongs to
    /// the kernel's work owner, so suspend freezes it and shutdown removes it.
    /// `finishStep` then decides the process's fate.
    func runStep(_ process: Process, _ work: @escaping () -> Void) {
        loop.post(owner: workOwner) { [weak self] in
            guard let self, self.processTable.contains(process.pid) else { return }
            if process.isStopped {
                process.pendingSteps.append(work)   // job-control stop: defer until SIGCONT
                return
            }
            process.state = .running
            process.scheduleTicks += 1   // CPU-activity proxy: how often this process was run
            work()
            guard self.processTable.contains(process.pid) else { return }
            self.finishStep(process)
        }
    }

    private func finishStep(_ process: Process) {
        guard processTable.contains(process.pid) else { return }
        if case .zombie(let status) = process.state {
            exit(process, status)                       // exit() was called
        } else if deliverPendingSignals(process) {
            finishStep(process)
        } else if process.isStopped {
            process.state = .stopped
        } else if process.blockedOn > 0 {
            process.state = .blocked                    // parked on I/O or a child
        } else {
            process.state = .zombie(status: .exited(0)) // returned with nothing pending
            exit(process, .exited(0))
        }
    }
}
