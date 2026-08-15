/// FIFO bookkeeping for child-exit waiters owned by the single-executor kernel.
final class ChildWaitQueue {
    private struct Waiter {
        let target: PID?
        let acceptsStop: Bool
        let acceptsContinued: Bool
        let deliver: (ChildWaitEvent) -> Void
    }

    private let processTable: ProcessTable
    var onExitConsumed: (_ parent: PID, _ child: PID) -> Void
    private var events: [PID: [ChildWaitEvent]] = [:]     // parent -> queued, un-waited events
    private var waiters: [PID: Waiter] = [:]     // parent -> pending waiter

    init(processTable: ProcessTable,
         onExitConsumed: @escaping (_ parent: PID, _ child: PID) -> Void = { _, _ in }) {
        self.processTable = processTable
        self.onExitConsumed = onExitConsumed
    }

    func clearProcess(_ pid: PID) {
        waiters[pid] = nil
        events[pid] = nil
        // A terminal wait reaps the child identity. Any older, unconsumed stop
        // or continue notifications for that identity cease to be waitable too.
        for parent in Array(events.keys) {
            events[parent]?.removeAll { $0.childPID == pid }
            if events[parent]?.isEmpty == true { events[parent] = nil }
        }
    }

    /// Deliver a child event to a waiting parent, or queue it. A stop event only
    /// wakes a stop-aware waiter (`waitEvent`); a plain `wait` leaves it queued.
    func post(parent ppid: PID, child pid: PID, status: ProcessWaitStatus) {
        guard ppid != 0 else { return }
        guard processTable.process(ppid)?.isLive == true else { return }
        let event = ChildWaitEvent(childPID: pid, status: status)
        if let waiter = waiters[ppid],
           childEvent(event,
                      matches: waiter.target,
                      acceptsStop: waiter.acceptsStop,
                      acceptsContinued: waiter.acceptsContinued) {
            waiters[ppid] = nil
            consume(event, parent: ppid)
            waiter.deliver(event)
        } else {
            events[ppid, default: []].append(event)
        }
    }

    func reapExitedChild(parent: Process) -> ChildWaitEvent? {
        guard let event = popQueuedChildEvent(
            parent: parent.pid,
            target: nil,
            acceptsStop: false,
            acceptsContinued: false
        ) else {
            return nil
        }
        consume(event, parent: parent.pid)
        return event
    }

    func waitpid(parent: Process,
                 childPID target: PID?,
                 options: ProcessWaitOptions,
                 schedule: @escaping (Process, @escaping () -> Void) -> Void,
                 resume: @escaping (Result<ChildWaitEvent?, SyscallError>) -> Void) {
        let pid = parent.pid
        let acceptsStop = options.contains(.untraced)
        let acceptsContinued = options.contains(.continued)
        if let event = popQueuedChildEvent(
            parent: pid,
            target: target,
            acceptsStop: acceptsStop,
            acceptsContinued: acceptsContinued
        ) {
            consume(event, parent: pid)
            let waitID = parent.beginWait(.child(target))
            schedule(parent) {
                parent.endWait(waitID)
                resume(.success(event))
            }
            return
        }

        let hasChild = hasMatchingChild(parent: pid, target: target)
        if options.contains(.noHang) {
            let waitID = parent.beginWait(.child(target))
            schedule(parent) {
                parent.endWait(waitID)
                if hasChild {
                    resume(.success(nil))
                } else {
                    resume(.failure(.noChildProcess))
                }
            }
            return
        }

        guard hasChild else {
            let waitID = parent.beginWait(.child(target))
            schedule(parent) {
                parent.endWait(waitID)
                resume(.failure(.noChildProcess))
            }
            return
        }

        var completed = false
        let waitID = parent.beginWait(.child(target))
        waiters[pid] = Waiter(
            target: target,
            acceptsStop: acceptsStop,
            acceptsContinued: acceptsContinued,
            deliver: { [weak parent] event in
            guard let parent else { return }
            guard !completed else { return }
            completed = true
            parent.disarmWaitCancellation(waitID)
            schedule(parent) {
                parent.endWait(waitID)
                resume(.success(event))
            }
        })
        parent.setWaitCancellation({ [weak self] in
            guard !completed else { return }
            completed = true
            self?.waiters[pid] = nil
        }, for: waitID)
    }

    /// Move already-recorded child transitions when a parent exits. Events for a
    /// host-owned child (`new parent == 0`) are discarded; terminal children are
    /// force-reaped separately by the exit coordinator.
    func reparentEvents(from oldParent: PID, assignments: [PID: PID]) -> Set<PID> {
        guard let queued = events.removeValue(forKey: oldParent) else { return [] }
        var notified: Set<PID> = []
        for event in queued {
            guard let newParent = assignments[event.childPID], newParent != 0 else { continue }
            post(parent: newParent, child: event.childPID, status: event.status)
            notified.insert(newParent)
        }
        return notified
    }

    private func childEvent(_ event: ChildWaitEvent,
                            matches target: PID?,
                            acceptsStop: Bool,
                            acceptsContinued: Bool) -> Bool {
        guard target == nil || event.childPID == target else { return false }
        switch event.status {
        case .exited, .signaled: return true
        case .stopped: return acceptsStop
        case .continued: return acceptsContinued
        }
    }

    private func popQueuedChildEvent(parent ppid: PID,
                                     target: PID?,
                                     acceptsStop: Bool,
                                     acceptsContinued: Bool) -> ChildWaitEvent? {
        guard var queue = events[ppid],
              let index = queue.firstIndex(where: {
                  childEvent($0,
                             matches: target,
                             acceptsStop: acceptsStop,
                             acceptsContinued: acceptsContinued)
              }) else {
            return nil
        }
        let event = queue.remove(at: index)
        events[ppid] = queue.isEmpty ? nil : queue
        return event
    }

    private func consume(_ event: ChildWaitEvent, parent: PID) {
        if event.status.isTerminated {
            onExitConsumed(parent, event.childPID)
        }
    }

    private func hasMatchingChild(parent ppid: PID, target: PID?) -> Bool {
        processTable.all.contains { process in
            process.ppid == ppid && (target == nil || process.pid == target)
        }
    }
}
