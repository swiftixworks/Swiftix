/// Coordinates process teardown, descriptor closure, and parent notifications.
final class ProcessExitCoordinator {
    private let processTable: ProcessTable
    private let childWaitQueue: ChildWaitQueue
    private let processGroups: ProcessGroupController
    private let signalParent: (PID, Int32) -> Void
    /// Called with a process just before it is removed from the table, so the
    /// kernel can release resources keyed by it (e.g. drop its PID-namespace
    /// memberships). Runs while the process still exists.
    private let willReap: (Process) -> Void

    init(processTable: ProcessTable,
         childWaitQueue: ChildWaitQueue,
         processGroups: ProcessGroupController,
         signalParent: @escaping (PID, Int32) -> Void,
         willReap: @escaping (Process) -> Void = { _ in }) {
        self.processTable = processTable
        self.childWaitQueue = childWaitQueue
        self.processGroups = processGroups
        self.signalParent = signalParent
        self.willReap = willReap
    }

    /// Record a process's exit and notify its parent: deliver SIGCHLD (before the
    /// wait wakes, so a handler runs while the parent is still alive), then
    /// satisfy a pending `wait()` or queue the status until the parent waits.
    func handleExit(_ process: Process, status: ProcessWaitStatus) {
        let pid = process.pid
        let ppid = process.ppid
        let observers = process.exitObservers
        process.exitObservers.removeAll(keepingCapacity: false)
        reap(pid)
        for observer in observers { observer(status) }
        guard ppid != 0 else { return }
        signalParent(ppid, Signal.sigchld.rawValue)
        childWaitQueue.post(parent: ppid, child: pid, status: status)
    }

    func terminate(_ process: Process, bySignal signal: Int32) {
        let status = ProcessWaitStatus.signaled(signal)
        process.cancelWaits()
        process.pendingSteps.removeAll(keepingCapacity: false)
        process.state = .zombie(status: status)
        handleExit(process, status: status)
    }

    private func reap(_ pid: PID) {
        // Close descriptors on exit (POSIX: fds close when a process dies), so
        // reference-counted resources like pipes see their endpoints disappear.
        if let process = processTable.process(pid) {
            process.fileDescriptors.closeAll()
            willReap(process)
        }
        processTable.remove(pid)
        childWaitQueue.clearProcess(pid)
        processGroups.processDidExit()
    }
}
