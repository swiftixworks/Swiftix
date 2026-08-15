/// Pipeline launch and wait mechanics for `Programs.shell`. All process, pipe,
/// job-table, and status mutations run on the kernel's single serial executor.
extension Programs {

    /// Launch a resolved pipeline, wire adjacent stages, and complete after every
    /// foreground process exits (or immediately after a background launch).
    static func runPipeline(_ ctx: ProcessContext,
                            _ stages: [(stage: Stage, command: Command)],
                            jobs: JobTable,
                            status: ShellStatus,
                            background: Bool,
                            commandText: String,
                            done: @escaping () -> Void) {
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
        var stagePIDs = [PID?](repeating: nil, count: count)
        for index in (0..<count).reversed() {
            let (stage, command) = stages[index]
            let argv = stage.argv
            let pipeIn = index > 0 ? pipes[index - 1].read : nil
            let pipeOut = index < count - 1 ? pipes[index].write : nil

            let wire: (ProcessContext) -> Void = { child in
                for pair in stage.assignments {
                    child.setenv(pair.name, pair.value)
                }
                if let file = stage.stdinFile {
                    if let fd = child.open(file) {
                        child.dup2(fd, onto: 0)
                        child.close(fd)
                    }
                } else if let pipeIn {
                    child.dup2(pipeIn, onto: 0)
                }
                if let file = stage.stdoutFile {
                    if let fd = child.open(file, create: true, truncate: !stage.appendOut) {
                        if stage.appendOut {
                            _ = child.seek(fd, to: 0, whence: 2)
                        }
                        child.dup2(fd, onto: 1)
                        child.close(fd)
                    }
                } else if let pipeOut {
                    child.dup2(pipeOut, onto: 1)
                }
                if let file = stage.stderrFile {
                    if let fd = child.open(file, create: true, truncate: !stage.appendErr) {
                        if stage.appendErr {
                            _ = child.seek(fd, to: 0, whence: 2)
                        }
                        child.dup2(fd, onto: 2)
                        child.close(fd)
                    }
                } else if stage.stderrToStdout {
                    child.dup2(1, onto: 2)
                }
                if stage.stdoutToStderr {
                    child.dup2(2, onto: 1)
                }
                for fd in allPipeFDs {
                    child.close(fd)
                }
            }

            let pid: PID
            switch command.body {
            case let .sync(run):
                pid = ctx.spawn(argv[0], args: argv) { child in
                    wire(child)
                    run(child, argv)
                }
            case let .async(run):
                pid = ctx.spawn(argv[0], args: argv) { (child: ProcessContext) async in
                    wire(child)
                    await run(child, argv)
                }
            }
            stagePIDs[index] = pid
        }
        let pids = stagePIDs.compactMap { $0 }

        // The children own their dup'd descriptors; retaining these in the shell
        // would prevent readers from observing EOF.
        for fd in allPipeFDs {
            ctx.close(fd)
        }

        _ = ctx.setProcessGroup(pids)
        let job = jobs.add(pids: pids, command: commandText)
        let lastStagePID = pids.last

        if background {
            ctx.write(1, Array("[\(job.id)] \(job.last)\n".utf8))
            done()
            return
        }

        ctx.setForegroundJob(pids)
        func step() {
            ctx.waitEvent { result in
                guard case .success(let event) = result else {
                    ctx.setForegroundJob([])
                    done()
                    return
                }
                let childStatus = event.status
                if childStatus.isStopped {
                    ctx.setForegroundJob([])
                    status.last = childStatus.code
                    ctx.write(1, Array("\n[\(job.id)]+ Stopped\t\(commandText)\n".utf8))
                    _ = jobs.markStopped(pid: event.childPID)
                    done()
                    return
                }
                if event.childPID == lastStagePID {
                    status.last = childStatus.code
                }
                if let finished = jobs.complete(pid: event.childPID), finished.id != job.id {
                    ctx.write(1, Array("[\(finished.id)]+ Done\t\(finished.command)\n".utf8))
                }
                if jobs.job(id: job.id) == nil {
                    ctx.setForegroundJob([])
                    done()
                } else {
                    step()
                }
            }
        }
        step()
    }
}
