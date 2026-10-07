/// Single-executor scheduler operations for runnable, blocked, and stopped processes.
final class ProcessScheduler {
    private let processTable: ProcessTable
    private let deliverPendingSignals: (Process) -> Bool
    private let exit: (Process, ProcessExitStatus) -> Void

    /// Steps run so far across every process of this kernel. Monotonic; used as
    /// the context-switch counter in `/proc/stat` and as the "current step"
    /// identity that bounds reads from unbounded devices.
    private(set) var stepCount: UInt64 = 0

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
    ///
    /// `yielding` marks the step as the continuation of a CPU-bound process
    /// that gave up the processor: it is queued in the same place, but the
    /// event loop lets timers and the clock pass it (see `EventLoop`).
    func runStep(_ process: Process, yielding: Bool = false, _ work: @escaping () -> Void) {
        guard processTable.contains(process.pid), process.isLive else { return }
        process.queuedSteps += 1
        if !process.isStopped, process.runState != .running {
            process.runState = .runnable
        }
        let enqueue = yielding ? process.workScope.yield : { process.workScope.schedule(after: 0, $0) }
        enqueue { [weak self, weak process] in
            guard let self, let process,
                  self.processTable.contains(process.pid), process.isLive else { return }
            process.queuedSteps -= 1
            if process.isStopped {
                process.pendingSteps.append(work)   // job-control stop: defer until SIGCONT
                return
            }
            process.runState = .running
            process.isInYieldedBurst = yielding
            process.scheduleTicks += 1   // CPU-activity proxy: how often this process was run
            self.stepCount &+= 1
            process.activeStepDepth += 1
            work()
            process.activeStepDepth -= 1
            guard self.processTable.contains(process.pid) else { return }
            // A nested step must not reap a process whose enclosing step is still
            // executing; that step finishes (and decides) once it returns.
            guard process.activeStepDepth == 0 else { return }
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
        } else if process.isInYieldedBurst, process.asyncBodyWaitID != nil, process.blockedOn == 1 {
            // An async body resumed by a yield holds only its lifetime wait:
            // it is computing in executor jobs, not parked.
            process.runState = .runnable
        } else if process.blockedOn > 0 {
            process.runState = .waiting                 // parked on I/O or a child
        } else {
            exit(process, .exited(0))                   // returned with nothing pending
        }
    }
}
