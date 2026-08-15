/// FIFO bookkeeping for child-exit waiters owned by the single-executor kernel.
final class ChildWaitQueue {
    private struct Waiter {
        let target: PID?
        let acceptsStop: Bool
        let deliver: (ChildWaitEvent) -> Void
    }

    private let processTable: ProcessTable
    private var events: [PID: [ChildWaitEvent]] = [:]     // parent -> queued, un-waited events
    private var waiters: [PID: Waiter] = [:]     // parent -> pending waiter

    init(processTable: ProcessTable) {
        self.processTable = processTable
    }

    func clearProcess(_ pid: PID) {
        waiters[pid] = nil
        events[pid] = nil
    }

    /// Deliver a child event to a waiting parent, or queue it. A stop event only
    /// wakes a stop-aware waiter (`waitEvent`); a plain `wait` leaves it queued.
    func post(parent ppid: PID, child pid: PID, status: ProcessWaitStatus) {
        guard ppid != 0 else { return }
        guard processTable.contains(ppid) else { return }
        let event = ChildWaitEvent(childPID: pid, status: status)
        if let waiter = waiters[ppid],
           childEvent(event, matches: waiter.target, acceptsStop: waiter.acceptsStop) {
            waiters[ppid] = nil
            waiter.deliver(event)
        } else {
            events[ppid, default: []].append(event)
        }
    }

    func reapExitedChild(parent: Process) -> ChildWaitEvent? {
        guard let event = popQueuedChildEvent(parent: parent.pid, target: nil, acceptsStop: false) else {
            return nil
        }
        return event
    }

    func waitpid(parent: Process,
                 childPID target: PID?,
                 options: ProcessWaitOptions,
                 schedule: @escaping (Process, @escaping () -> Void) -> Void,
                 resume: @escaping (Result<ChildWaitEvent?, SyscallError>) -> Void) {
        let pid = parent.pid
        let acceptsStop = options.contains(.untraced)
        if let event = popQueuedChildEvent(parent: pid, target: target, acceptsStop: acceptsStop) {
            parent.blockedOn += 1
            schedule(parent) {
                parent.blockedOn -= 1
                resume(.success(event))
            }
            return
        }

        let hasChild = hasLivingChild(parent: pid, target: target)
        if options.contains(.noHang) {
            parent.blockedOn += 1
            schedule(parent) {
                parent.blockedOn -= 1
                if hasChild {
                    resume(.success(nil))
                } else {
                    resume(.failure(.noChildProcess))
                }
            }
            return
        }

        guard hasChild else {
            parent.blockedOn += 1
            schedule(parent) {
                parent.blockedOn -= 1
                resume(.failure(.noChildProcess))
            }
            return
        }

        parent.blockedOn += 1
        var completed = false
        var cancellationID: Int?
        waiters[pid] = Waiter(target: target, acceptsStop: acceptsStop, deliver: { [weak parent] event in
            guard let parent else { return }
            guard !completed else { return }
            completed = true
            if let cancellationID {
                parent.removeWaitCancellation(cancellationID)
            }
            schedule(parent) {
                parent.blockedOn -= 1
                resume(.success(event))
            }
        })
        cancellationID = parent.addWaitCancellation { [weak self, weak parent] in
            guard !completed else { return }
            completed = true
            self?.waiters[pid] = nil
            if let parent, parent.blockedOn > 0 {
                parent.blockedOn -= 1
            }
        }
    }

    private func childEvent(_ event: ChildWaitEvent, matches target: PID?, acceptsStop: Bool) -> Bool {
        guard target == nil || event.childPID == target else { return false }
        return !event.status.isStopped || acceptsStop
    }

    private func popQueuedChildEvent(parent ppid: PID, target: PID?, acceptsStop: Bool) -> ChildWaitEvent? {
        guard var queue = events[ppid],
              let index = queue.firstIndex(where: { childEvent($0, matches: target, acceptsStop: acceptsStop) }) else {
            return nil
        }
        let event = queue.remove(at: index)
        events[ppid] = queue.isEmpty ? nil : queue
        return event
    }

    private func hasLivingChild(parent ppid: PID, target: PID?) -> Bool {
        processTable.all.contains { process in
            process.ppid == ppid && (target == nil || process.pid == target)
        }
    }
}
