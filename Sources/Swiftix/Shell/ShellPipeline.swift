/// Process launching, child waiting, and descriptor redirection for the shell
/// interpreter. All process, pipe, job-table, and status mutations run on the
/// kernel's single serial executor.
extension Programs.ShellInterpreter {

    // MARK: - Launching

    /// Spawn every stage, wire adjacent stages with pipes, and complete after
    /// every foreground process exits (or immediately after a background launch).
    func launchStages(_ stages: [Programs.StageLaunch], background: Bool, done: @escaping () -> Void) {
        let count = stages.count
        var pipes: [(read: Int, write: Int)] = []
        for _ in 0..<max(0, count - 1) {
            pipes.append(ctx.pipe())
        }
        let allPipeFDs = pipes.flatMap { [$0.read, $0.write] }

        // Start downstream stages first. Each child closes every inherited pipe
        // descriptor it does not use in `wire`; doing this from right to left
        // prevents an unstarted downstream process from retaining an upstream
        // write end and delaying EOF in a synchronous guest runtime.
        var stagePIDs = [PID](repeating: 0, count: count)
        for index in (0..<count).reversed() {
            let stage = stages[index]
            let argv = stage.argv
            let pipeIn = index > 0 ? pipes[index - 1].read : nil
            let pipeOut = index < count - 1 ? pipes[index].write : nil

            // Pipes first, then the command's own redirections on top (so
            // `cmd < file` in mid-pipeline reads the file, not the pipe).
            let wire: (ProcessContext) -> Void = { child in
                if let pipeIn { child.dup2(pipeIn, onto: 0) }
                if let pipeOut { child.dup2(pipeOut, onto: 1) }
                for fd in allPipeFDs {
                    child.close(fd)
                }
            }

            switch stage.body {
            case let .shell(run):
                stagePIDs[index] = ctx.spawn(stage.name, args: argv) { child in
                    wire(child)
                    run(child)
                }
            case let .command(command, setup):
                switch command.body {
                case let .sync(run):
                    stagePIDs[index] = ctx.spawn(stage.name, args: argv) { child in
                        wire(child)
                        guard setup(child) else { child.exit(1); return }
                        run(child, argv)
                    }
                case let .async(run):
                    stagePIDs[index] = ctx.spawn(stage.name, args: argv) { (child: ProcessContext) async in
                        wire(child)
                        guard setup(child) else { child.exit(1); return }
                        await run(child, argv)
                    }
                }
            }
        }
        let pids = stagePIDs.filter { $0 != 0 }

        // The children own their dup'd descriptors; retaining these in the shell
        // would prevent readers from observing EOF.
        for fd in allPipeFDs {
            ctx.close(fd)
        }
        guard !pids.isEmpty else {
            err("sh: cannot start process\n")
            status.last = 126
            done()
            return
        }

        if jobControl { _ = ctx.setProcessGroup(pids) }
        let commandText = stages.map(\.label).joined(separator: " | ")
        let job = jobs.add(pids: pids, command: commandText)

        if background {
            inheritedJobs.removeAll()           // this shell now has jobs of its own
            lastBackgroundPID = job.last
            backgroundPIDs.formUnion(pids)
            if interactive { out("[\(job.id)] \(job.last)\n") }
            status.last = 0
            done()
            return
        }

        if jobControl { ctx.setForegroundJob(pids) }
        waitForJob(job.id, lastPID: stagePIDs[count - 1], commandText: commandText, done: done)
    }

    /// Wait until every process of foreground job `jobID` exits (or the job
    /// stops), setting `$?` from its last stage.
    func waitForJob(_ jobID: Int, lastPID: PID, commandText: String, done: @escaping () -> Void) {
        var interrupted = false
        Programs.drive({ next in
            self.ctx.waitEvent { result in
                guard case .success(let event) = result else {
                    self.jobs.remove(id: jobID)
                    next(false)
                    return
                }
                let childStatus = event.status
                if childStatus.isStopped {
                    let owner = self.jobs.markStopped(pid: event.childPID)
                    if owner == nil || owner?.id == jobID {
                        self.status.last = childStatus.code
                        self.out("\n[\(jobID)]+ Stopped\t\(commandText)\n")
                        next(false)
                    } else {
                        next(true)
                    }
                    return
                }
                if event.childPID == lastPID {
                    self.status.last = childStatus.code
                }
                if case .signaled(Signal.sigint.rawValue) = childStatus { interrupted = true }
                self.noteExit(event, foregroundJob: jobID)
                next(self.jobs.job(id: jobID) != nil)
            }
        }, done: {
            if self.jobControl { self.ctx.setForegroundJob([]) }
            // Ctrl-C killed the foreground job: an interactive shell abandons
            // the rest of the command line (the enclosing loop, `; next`).
            if interrupted, self.interactive, self.flow == .none { self.flow = .abort }
            done()
        })
    }

    /// Record a terminated child: remember a background pid's status for
    /// `wait`, and retire its job (announcing it in an interactive shell).
    func noteExit(_ event: ChildWaitEvent, foregroundJob: Int? = nil) {
        if backgroundPIDs.remove(event.childPID) != nil {
            // Kept for a later `wait PID`; bounded so unwaited jobs cannot
            // accumulate without limit.
            if exitStatuses.count >= 256 { exitStatuses.removeAll() }
            exitStatuses[event.childPID] = event.code
        }
        if let finished = jobs.complete(pid: event.childPID), finished.id != foregroundJob, interactive {
            out("[\(finished.id)]+ Done\t\(finished.command)\n")
        }
    }

    /// Harvest completed background children while the shell is at its prompt.
    func reapBackground() {
        while let event = ctx.reapChild() {
            noteExit(event)
        }
    }

    /// Wait for one specific child (not a job) and deliver its exit status.
    func awaitChild(_ pid: PID, _ done: @escaping (Int32) -> Void) {
        ctx.waitpid(pid) { result in
            switch result {
            case let .success(event?):
                done(event.code)
            case .success(nil), .failure:
                done(127)
            }
        }
    }

    // MARK: - Redirection

    /// Apply `redirections` to `ctx` in order. Returns an error message when a
    /// target cannot be opened (earlier redirections stay applied).
    static func applyRedirections(_ ctx: ProcessContext,
                                  _ redirections: [Programs.ResolvedRedirection]) -> String? {
        for redirection in redirections {
            switch redirection {
            case let .read(fd, path):
                guard let opened = ctx.open(path) else { return "\(path): No such file or directory" }
                if opened != fd { ctx.dup2(opened, onto: fd); ctx.close(opened) }
            case let .write(fd, path, append):
                guard let opened = ctx.open(path, create: true, truncate: !append) else {
                    return "\(path): cannot create"
                }
                if append { _ = ctx.seek(opened, to: 0, whence: 2) }
                if opened != fd { ctx.dup2(opened, onto: fd); ctx.close(opened) }
            case let .duplicate(fd, target):
                guard ctx.dup2(target, onto: fd) else { return "\(target): bad file descriptor" }
            case let .close(fd):
                ctx.close(fd)
            case let .data(fd, text):
                let bytes = Array(text.utf8)
                if bytes.count < 60_000 {
                    // Small enough for a pipe buffer: no temporary file needed.
                    let pipe = ctx.pipe()
                    ctx.write(pipe.write, bytes)
                    ctx.close(pipe.write)
                    ctx.dup2(pipe.read, onto: fd)
                    ctx.close(pipe.read)
                } else {
                    _ = ctx.mkdir("/tmp")
                    let path = "/tmp/.heredoc.\(ctx.globalPID)"
                    guard let writer = ctx.open(path, create: true, truncate: true) else {
                        return "cannot create temporary file for here-document"
                    }
                    ctx.write(writer, bytes)
                    ctx.close(writer)
                    guard let reader = ctx.open(path) else {
                        return "cannot open temporary file for here-document"
                    }
                    _ = ctx.remove(path)
                    if reader != fd { ctx.dup2(reader, onto: fd); ctx.close(reader) }
                }
            }
        }
        return nil
    }

    /// Temporarily apply redirections to the shell process while `run`
    /// executes, then restore its descriptors before continuing.
    func withRedirections(_ redirections: [Programs.ResolvedRedirection],
                          run: (_ finish: @escaping () -> Void) -> Void,
                          then done: @escaping () -> Void) {
        if redirections.isEmpty { run(done); return }
        // Park the originals on high descriptors (a stack shared by nested
        // redirected blocks) so they can never collide with a redirected fd.
        var saved: [(fd: Int, copy: Int?)] = []
        for redirection in redirections where !saved.contains(where: { $0.fd == redirection.fd }) {
            let slot = nextSavedFD
            nextSavedFD += 1
            saved.append((redirection.fd, ctx.dup2(redirection.fd, onto: slot) ? slot : nil))
        }
        let restore = {
            for entry in saved.reversed() {
                if let copy = entry.copy {
                    self.ctx.dup2(copy, onto: entry.fd)
                    self.ctx.close(copy)
                } else {
                    self.ctx.close(entry.fd)
                }
            }
            self.nextSavedFD -= saved.count
        }
        if let error = Self.applyRedirections(ctx, redirections) {
            restore()
            err("sh: \(error)\n")
            status.last = 1
            done()
            return
        }
        run {
            restore()
            done()
        }
    }
}
