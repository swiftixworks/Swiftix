/// Applies signal masks, pending delivery, default actions, and installed handlers.
final class SignalDispatcher {
    private let processTable: ProcessTable
    private let childWaitQueue: ChildWaitQueue
    private let schedule: (Process, @escaping () -> Void) -> Void
    private let terminate: (Process, Int32) -> Void
    private let signalParent: (PID, Int32) -> Void

    private static let unmaskableSignals: Set<Int32> = [
        Signal.sigkill.rawValue,
        Signal.sigstop.rawValue,
    ]

    init(processTable: ProcessTable,
         childWaitQueue: ChildWaitQueue,
         schedule: @escaping (Process, @escaping () -> Void) -> Void,
         terminate: @escaping (Process, Int32) -> Void,
         signalParent: @escaping (PID, Int32) -> Void) {
        self.processTable = processTable
        self.childWaitQueue = childWaitQueue
        self.schedule = schedule
        self.terminate = terminate
        self.signalParent = signalParent
    }

    /// Deliver a signal. Masked regular signals are queued pending; SIGKILL
    /// always terminates; SIGCONT always resumes a stopped process.
    ///
    /// `sender` is the guest process that issued the `kill`, or `nil` for a
    /// signal raised with host authority (the public `Kernel` API, terminal
    /// job-control keys, kernel-generated SIGCHLD/SIGPIPE). Guest signals are
    /// subject to the PID-1 protection in `initDiscards`; host signals never are.
    func kill(_ pid: PID, signal: Int32, sender: Process? = nil) {
        guard let process = processTable.process(pid), process.isLive else { return }
        if let sender, initDiscards(signal, target: process, sender: sender) { return }
        if signal == Signal.sigcont.rawValue {
            let didContinue = resumeStopped(process)
            if isSignalBlocked(signal, in: process) {
                process.pendingSignals.append(signal)
            } else {
                deliverSignal(signal, to: process, continueEffectApplied: true)
            }
            if didContinue { notifyParent(of: process) }
            return
        }
        if isSignalBlocked(signal, in: process) {
            process.pendingSignals.append(signal)
            return
        }
        deliverSignal(signal, to: process)
    }

    func setSignalMask(for process: Process, _ signals: Set<Int32>) {
        guard process.isLive else { return }
        process.signalMask = Set(signals.filter(Self.isMaskableSignal))
        _ = deliverPendingSignals(process)
    }

    func blockSignal(_ signal: Int32, for process: Process) {
        guard process.isLive, Self.isMaskableSignal(signal) else { return }
        process.signalMask.insert(signal)
    }

    func unblockSignal(_ signal: Int32, for process: Process) {
        guard process.isLive else { return }
        process.signalMask.remove(signal)
        _ = deliverPendingSignals(process)
    }

    @discardableResult
    func deliverPendingSignals(_ process: Process) -> Bool {
        guard process.isLive else { return false }
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

    /// Linux protects a PID namespace's init (its local pid 1): a signal sent
    /// by a process is dropped unless init installed a handler for it.
    ///
    /// - From inside the namespace (the sender is in init's namespace or one
    ///   nested below it) this covers SIGKILL and SIGSTOP too, so `kill -9 1`
    ///   cannot take down the session it is typed into.
    /// - From an ancestor namespace only SIGKILL and SIGSTOP are forced through;
    ///   other signals still need a handler.
    ///
    /// SIGCONT is exempt: its resume effect is not a disposition and is always
    /// applied.
    private func initDiscards(_ signal: Int32, target: Process, sender: Process) -> Bool {
        guard let namespace = target.pidNamespace,
              namespace.localPID(forGlobal: target.pid) == 1,
              signal != Signal.sigcont.rawValue else { return false }
        let uncatchable = Self.unmaskableSignals.contains(signal)
        // `contains(global:)` is true for members of this namespace and of every
        // namespace nested below it.
        if namespace.contains(global: sender.pid) {
            return uncatchable || target.signalHandlers[signal] == nil
        }
        return !uncatchable && target.signalHandlers[signal] == nil
    }

    private static func isMaskableSignal(_ signal: Int32) -> Bool {
        !unmaskableSignals.contains(signal)
    }

    private func isSignalBlocked(_ signal: Int32, in process: Process) -> Bool {
        Self.isMaskableSignal(signal) && process.signalMask.contains(signal)
    }

    private func deliverSignal(_ signal: Int32,
                               to process: Process,
                               continueEffectApplied: Bool = false) {
        guard processTable.contains(process.pid), process.isLive else { return }
        if signal == Signal.sigkill.rawValue {
            terminate(process, signal)
            return
        }
        if signal == Signal.sigstop.rawValue {
            if stopProcess(process, signal: signal) { notifyParent(of: process) }
            return
        }
        // SIGCONT always resumes a stopped process (before any handler runs), so
        // even a stopped process with no handler can be woken.
        if signal == Signal.sigcont.rawValue {
            if !continueEffectApplied, resumeStopped(process) {
                notifyParent(of: process)
            }
            if let handler = process.signalHandlers[signal] {
                schedule(process) { handler() }
            }
            return
        }
        if let handler = process.signalHandlers[signal] {
            if process.runState == .running {
                handler()
            } else {
                schedule(process) { handler() }
            }
            return
        }
        switch signal {
        case Signal.sigint.rawValue, Signal.sigpipe.rawValue, Signal.sigterm.rawValue:
            terminate(process, signal)
        case Signal.sigtstp.rawValue:
            if stopProcess(process, signal: signal) { notifyParent(of: process) }
        default:
            break   // e.g. SIGCHLD: default ignore
        }
    }

    /// SIGTSTP default: suspend the process. Steps posted while stopped are held
    /// and replayed by `resumeStopped`.
    private func stopProcess(_ process: Process, signal: Int32) -> Bool {
        guard process.isLive, !process.isStopped else { return false }
        process.runState = .stopped
        // Notify the parent (WUNTRACED): a shell parked in `waitEvent` wakes and
        // returns to the prompt with the job marked Stopped. The process is not
        // reaped -- it stays alive, resumable by SIGCONT.
        childWaitQueue.post(parent: process.ppid,
                            child: process.pid,
                            status: .stopped(signal))
        return true
    }

    /// SIGCONT: clear the stop and replay any deferred steps. If none were
    /// deferred, restore the process to blocked (still parked on I/O) or runnable.
    @discardableResult
    private func resumeStopped(_ process: Process) -> Bool {
        guard process.isLive, process.isStopped else { return false }
        let deferred = process.pendingSteps
        process.pendingSteps.removeAll()
        if deferred.isEmpty {
            process.runState = process.blockedOn > 0 ? .waiting : .runnable
        } else {
            process.runState = .runnable
            for work in deferred { schedule(process, work) }
        }
        childWaitQueue.post(parent: process.ppid,
                            child: process.pid,
                            status: .continued)
        return true
    }

    private func notifyParent(of process: Process) {
        guard process.ppid != 0 else { return }
        signalParent(process.ppid, Signal.sigchld.rawValue)
    }
}
