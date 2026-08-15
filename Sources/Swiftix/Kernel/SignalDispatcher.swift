/// Applies signal masks, pending delivery, default actions, and installed handlers.
final class SignalDispatcher {
    private let processTable: ProcessTable
    private let childWaitQueue: ChildWaitQueue
    private let schedule: (Process, @escaping () -> Void) -> Void
    private let terminate: (Process, Int32) -> Void

    private static let unmaskableSignals: Set<Int32> = [
        Signal.sigkill.rawValue,
        Signal.sigcont.rawValue,
    ]

    init(processTable: ProcessTable,
         childWaitQueue: ChildWaitQueue,
         schedule: @escaping (Process, @escaping () -> Void) -> Void,
         terminate: @escaping (Process, Int32) -> Void) {
        self.processTable = processTable
        self.childWaitQueue = childWaitQueue
        self.schedule = schedule
        self.terminate = terminate
    }

    /// Deliver a signal. Masked regular signals are queued pending; SIGKILL
    /// always terminates; SIGCONT always resumes a stopped process.
    func kill(_ pid: PID, signal: Int32) {
        guard let process = processTable.process(pid) else { return }
        if isSignalBlocked(signal, in: process) {
            process.pendingSignals.append(signal)
            return
        }
        deliverSignal(signal, to: process)
    }

    func setSignalMask(for process: Process, _ signals: Set<Int32>) {
        process.signalMask = Set(signals.filter(Self.isMaskableSignal))
        _ = deliverPendingSignals(process)
    }

    func blockSignal(_ signal: Int32, for process: Process) {
        guard Self.isMaskableSignal(signal) else { return }
        process.signalMask.insert(signal)
    }

    func unblockSignal(_ signal: Int32, for process: Process) {
        process.signalMask.remove(signal)
        _ = deliverPendingSignals(process)
    }

    @discardableResult
    func deliverPendingSignals(_ process: Process) -> Bool {
        var delivered = false
        var index = 0
        while index < process.pendingSignals.count {
            guard processTable.contains(process.pid) else { return delivered }
            let signal = process.pendingSignals[index]
            if isSignalBlocked(signal, in: process) {
                index += 1
                continue
            }
            process.pendingSignals.remove(at: index)
            deliverSignal(signal, to: process)
            delivered = true
        }
        return delivered
    }

    private static func isMaskableSignal(_ signal: Int32) -> Bool {
        !unmaskableSignals.contains(signal)
    }

    private func isSignalBlocked(_ signal: Int32, in process: Process) -> Bool {
        Self.isMaskableSignal(signal) && process.signalMask.contains(signal)
    }

    private func deliverSignal(_ signal: Int32, to process: Process) {
        guard processTable.contains(process.pid) else { return }
        if signal == Signal.sigkill.rawValue {
            terminate(process, signal)
            return
        }
        // SIGCONT always resumes a stopped process (before any handler runs), so
        // even a stopped process with no handler can be woken.
        if signal == Signal.sigcont.rawValue {
            resumeStopped(process)
            if let handler = process.signalHandlers[signal] {
                schedule(process) { handler() }
            }
            return
        }
        if let handler = process.signalHandlers[signal] {
            if case .running = process.state {
                handler()
            } else {
                schedule(process) { handler() }
            }
            return
        }
        switch signal {
        case Signal.sigint.rawValue, Signal.sigterm.rawValue:
            terminate(process, signal)
        case Signal.sigtstp.rawValue:
            stopProcess(process)
        default:
            break   // e.g. SIGCHLD: default ignore
        }
    }

    /// SIGTSTP default: suspend the process. Steps posted while stopped are held
    /// and replayed by `resumeStopped`.
    private func stopProcess(_ process: Process) {
        guard !process.isStopped else { return }
        process.isStopped = true
        process.state = .stopped
        // Notify the parent (WUNTRACED): a shell parked in `waitEvent` wakes and
        // returns to the prompt with the job marked Stopped. The process is not
        // reaped -- it stays alive, resumable by SIGCONT.
        childWaitQueue.post(parent: process.ppid,
                            child: process.pid,
                            status: .stopped(Signal.sigtstp.rawValue))
    }

    /// SIGCONT: clear the stop and replay any deferred steps. If none were
    /// deferred, restore the process to blocked (still parked on I/O) or runnable.
    private func resumeStopped(_ process: Process) {
        guard process.isStopped else { return }
        process.isStopped = false
        let deferred = process.pendingSteps
        process.pendingSteps.removeAll()
        if deferred.isEmpty {
            process.state = process.blockedOn > 0 ? .blocked : .runnable
        } else {
            for work in deferred { schedule(process, work) }
        }
    }
}
