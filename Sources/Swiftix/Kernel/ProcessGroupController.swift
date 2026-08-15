/// Owns process-group, session, foreground-job, and group-signal transitions.
final class ProcessGroupController {
    private let processTable: ProcessTable

    /// Foreground process group: terminal signals are delivered to every live
    /// process in this group. `nil` means the shell/prompt is idle.
    private(set) var foregroundProcessGroupID: PID?

    init(processTable: ProcessTable) {
        self.processTable = processTable
    }

    func foregroundProcessIDs() -> Set<PID> {
        guard let foregroundProcessGroupID else { return [] }
        return processIDs(inProcessGroup: foregroundProcessGroupID)
    }

    func processIDs(inProcessGroup processGroupID: PID) -> Set<PID> {
        return Set(processTable.all
            .filter { $0.processGroupID == processGroupID }
            .map(\.pid))
    }

    /// Set (or clear, with `[]`) the foreground process group. Every requested
    /// process must be live and belong to the caller's session; a terminal may
    /// never adopt a group from another tab's POSIX session.
    @discardableResult
    func setForegroundGroup(_ pids: [PID], sessionID: PID) -> PID? {
        guard !pids.isEmpty else {
            foregroundProcessGroupID = nil
            return nil
        }
        let members = pids.compactMap { processTable.process($0) }
        guard members.count == pids.count,
              members.allSatisfy({ $0.sessionID == sessionID }) else { return nil }

        let groups = Set(members.map(\.processGroupID))
        let processGroupID: PID?
        if groups.count == 1 {
            processGroupID = groups.first
        } else {
            processGroupID = setProcessGroup(pids)
        }
        guard let processGroupID,
              processGroup(processGroupID, belongsTo: sessionID) else { return nil }
        foregroundProcessGroupID = processGroupID
        return processGroupID
    }

    /// Set a known group as foreground without changing its membership. Returns
    /// false for an unknown group or one containing a process from another
    /// session, leaving the previous foreground group untouched.
    @discardableResult
    func setForegroundProcessGroup(_ processGroupID: PID?, sessionID: PID) -> Bool {
        guard let processGroupID else {
            foregroundProcessGroupID = nil
            return true
        }
        guard processGroup(processGroupID, belongsTo: sessionID) else { return false }
        foregroundProcessGroupID = processGroupID
        return true
    }

    private func processGroup(_ processGroupID: PID, belongsTo sessionID: PID) -> Bool {
        let members = processTable.all.filter { $0.processGroupID == processGroupID }
        return !members.isEmpty && members.allSatisfy { $0.sessionID == sessionID }
    }

    /// Move live processes into one process group without ever changing their
    /// POSIX session. A requested group must either already belong wholly to the
    /// same session or use one of the moved processes as its new group leader.
    @discardableResult
    func setProcessGroup(_ pids: [PID], groupID requestedGroupID: PID? = nil) -> PID? {
        let members = pids.compactMap { processTable.process($0) }
        guard !members.isEmpty, members.count == pids.count else { return nil }
        let sessions = Set(members.map(\.sessionID))
        guard sessions.count == 1, let sessionID = sessions.first else { return nil }

        let processGroupID = requestedGroupID ?? members[0].pid
        let existingMembers = processTable.all.filter {
            $0.processGroupID == processGroupID
        }
        if existingMembers.isEmpty {
            guard members.contains(where: { $0.pid == processGroupID }) else { return nil }
        } else {
            guard existingMembers.allSatisfy({ $0.sessionID == sessionID }) else { return nil }
        }

        for process in members { process.processGroupID = processGroupID }
        return processGroupID
    }

    func processDidExit() {
        guard let foregroundProcessGroupID else { return }
        if !processTable.all.contains(where: { $0.processGroupID == foregroundProcessGroupID }) {
            self.foregroundProcessGroupID = nil
        }
    }
}
