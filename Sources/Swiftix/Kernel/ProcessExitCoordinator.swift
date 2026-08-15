/// Coordinates the two-phase process lifecycle: logical exit releases runtime
/// resources and leaves a lightweight zombie; a matching parent wait performs
/// the final reap and removes the PID identity.
final class ProcessExitCoordinator {
    private let processTable: ProcessTable
    private let childWaitQueue: ChildWaitQueue
    private let processGroups: ProcessGroupController
    private let signalParent: (PID, Int32) -> Void
    private let willExit: (Process) -> Void
    private let willReap: (Process) -> Void

    init(processTable: ProcessTable,
         childWaitQueue: ChildWaitQueue,
         processGroups: ProcessGroupController,
         signalParent: @escaping (PID, Int32) -> Void,
         willExit: @escaping (Process) -> Void = { _ in },
         willReap: @escaping (Process) -> Void = { _ in }) {
        self.processTable = processTable
        self.childWaitQueue = childWaitQueue
        self.processGroups = processGroups
        self.signalParent = signalParent
        self.willExit = willExit
        self.willReap = willReap
    }

    /// End execution exactly once. Heavy runtime resources are released here,
    /// while PID/identity remains observable until a parent consumes the exit
    /// event. Host-owned processes (`ppid == 0`) are reaped automatically.
    func handleExit(_ process: Process, status: ProcessExitStatus) {
        guard processTable.contains(process.pid), process.beginExit(status) else { return }

        process.workScope.cancel()
        process.cancelWaits()
        process.asyncBodyWaitID = nil
        process.pendingSteps.removeAll(keepingCapacity: false)
        process.queuedSteps = 0
        process.pendingSignals.removeAll(keepingCapacity: false)
        process.signalHandlers.removeAll(keepingCapacity: false)
        process.fileDescriptors.closeAll()
        willExit(process)
        processGroups.processDidExit()

        reparentChildren(of: process)
        if process.ppid != 0, processTable.process(process.ppid)?.isLive != true {
            process.ppid = adoptiveParent(for: process, excluding: [process.pid])
        }

        process.becomeZombie()
        let observers = process.exitObservers
        process.exitObservers.removeAll(keepingCapacity: false)
        for observer in observers { observer(status.waitStatus) }

        guard process.ppid != 0 else {
            reap(process.pid)
            return
        }

        // Record the waitable event before SIGCHLD can run an in-process handler.
        // A parent already blocked in wait may consume it synchronously and reap
        // the child before this method returns.
        childWaitQueue.post(parent: process.ppid,
                            child: process.pid,
                            status: status.waitStatus)
        signalParent(process.ppid, Signal.sigchld.rawValue)
    }

    func terminate(_ process: Process, bySignal signal: Int32) {
        handleExit(process, status: .signaled(signal))
    }

    /// Called by ChildWaitQueue when a parent consumes a terminal child event.
    func reapExitedChild(parent: PID, child: PID) {
        reap(child, expectedParent: parent)
    }

    /// Kernel shutdown is an ownership boundary, not a POSIX parent wait. It
    /// forcibly removes every remaining zombie after live work has terminated.
    func forceReapAll() {
        for process in processTable.all {
            if case .zombie = process.lifecycle { reap(process.pid) }
        }
    }

    private func reparentChildren(of exitingParent: Process) {
        let children = processTable.all.filter { $0.ppid == exitingParent.pid }
        guard !children.isEmpty else { return }

        var assignments: [PID: PID] = [:]
        for child in children {
            let newParent = adoptiveParent(
                for: child,
                excluding: [exitingParent.pid, child.pid])
            child.ppid = newParent
            assignments[child.pid] = newParent
        }

        let notified = childWaitQueue.reparentEvents(
            from: exitingParent.pid,
            assignments: assignments)
        for parent in notified { signalParent(parent, Signal.sigchld.rawValue) }

        // With no namespace reaper, the embedding host owns the orphan and
        // automatically releases an already-terminal child.
        for child in children where assignments[child.pid] == 0 {
            if case .zombie = child.lifecycle { reap(child.pid) }
        }
    }

    /// Find PID 1 in the process's namespace or an ancestor namespace. This is
    /// the deterministic Swiftix analogue of Linux init/subreaper adoption. A
    /// missing reaper falls back to parent 0, whose lifecycle is host-owned.
    private func adoptiveParent(for process: Process, excluding: Set<PID>) -> PID {
        var namespace: PIDNamespace? = process.pidNamespace
        while let current = namespace {
            if let candidate = current.globalPID(forLocal: 1),
               !excluding.contains(candidate),
               processTable.process(candidate)?.isLive == true {
                return candidate
            }
            namespace = current.parent
        }
        return 0
    }

    private func reap(_ pid: PID, expectedParent: PID? = nil) {
        guard let process = processTable.process(pid),
              case .zombie = process.lifecycle else { return }
        if let expectedParent, process.ppid != expectedParent { return }

        willReap(process)
        processTable.remove(pid)
        childWaitQueue.clearProcess(pid)
    }
}
