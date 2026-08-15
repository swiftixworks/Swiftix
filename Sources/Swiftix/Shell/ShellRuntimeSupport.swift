/// Independent runtime operations used by `Programs.shell`: function argument
/// scopes, job control, compound-command redirection, here-doc materialization,
/// and multiline input. The caller supplies interpreter continuations explicitly,
/// keeping AST recursion local to `Shell.swift` and all mutation on one executor.
extension Programs {

    /// Bind `$1…$9`, `$#`, `$@`, and `$*` while `run` executes, then restore the
    /// caller's values before invoking `done`.
    static func callFunction(_ ctx: ProcessContext,
                             args: [String],
                             run: (_ finish: @escaping () -> Void) -> Void,
                             then done: @escaping () -> Void) {
        let keys = (1...9).map(String.init) + ["#", "@", "*"]
        let saved = keys.map { ($0, ctx.getenv($0)) }
        for index in 1...9 {
            ctx.setenv(String(index), index <= args.count ? args[index - 1] : "")
        }
        ctx.setenv("#", String(args.count))
        let joined = args.joined(separator: " ")
        ctx.setenv("@", joined)
        ctx.setenv("*", joined)

        run {
            for (key, value) in saved {
                ctx.setenv(key, value ?? "")
            }
            done()
        }
    }

    /// Harvest completed background children while the shell is at its prompt.
    static func reapBackground(_ ctx: ProcessContext, jobs: JobTable) {
        while let event = ctx.reapChild() {
            if let finished = jobs.complete(pid: event.childPID) {
                ctx.write(1, Array("[\(finished.id)]+ Done\t\(finished.command)\n".utf8))
            }
        }
    }

    /// Resume the selected job in the foreground or background.
    static func foreground(_ ctx: ProcessContext,
                           _ argv: [String],
                           jobs: JobTable,
                           status: ShellStatus,
                           resumeInBackground: Bool,
                           done: @escaping () -> Void) {
        let jobID: Int? = argv.count > 1 ? Int(argv[1]) : jobs.list().last?.id
        guard let jobID, let job = jobs.job(id: jobID) else {
            ctx.write(2, Array("\(resumeInBackground ? "bg" : "fg"): no such job\n".utf8))
            done()
            return
        }

        for pid in job.pids {
            ctx.kill(pid, signal: Signal.sigcont.rawValue)
        }
        jobs.setRunning(id: jobID)

        if resumeInBackground {
            ctx.write(1, Array("[\(jobID)]\t\(job.command) &\n".utf8))
            done()
            return
        }

        ctx.setForegroundJob(Array(job.pids))
        func step() {
            ctx.waitEvent { result in
                guard case .success(let event) = result else {
                    ctx.setForegroundJob([])
                    done()
                    return
                }
                let childStatus = event.status
                if childStatus.isStopped {
                    if let stoppedJob = jobs.markStopped(pid: event.childPID) {
                        ctx.setForegroundJob([])
                        status.last = childStatus.code
                        ctx.write(1, Array("\n[\(stoppedJob.id)]+ Stopped\t\(stoppedJob.command)\n".utf8))
                        done()
                    } else {
                        step()
                    }
                    return
                }
                status.last = childStatus.code
                if let finished = jobs.complete(pid: event.childPID), finished.id != jobID {
                    ctx.write(1, Array("[\(finished.id)]+ Done\t\(finished.command)\n".utf8))
                }
                if jobs.job(id: jobID) == nil {
                    ctx.setForegroundJob([])
                    done()
                } else {
                    step()
                }
            }
        }
        step()
    }

    /// Temporarily apply redirects to the shell process while `run` executes,
    /// then restore its descriptors before continuing.
    static func runWithRedirects(_ ctx: ProcessContext,
                                 _ redirects: Redirects,
                                 status: ShellStatus,
                                 run: (_ finish: @escaping () -> Void) -> Void,
                                 then done: @escaping () -> Void) {
        func expand(_ word: String) -> String {
            expandWord(word, env: { ctx.getenv($0) }, status: status.last)
        }

        let saved0 = redirects.stdinFile != nil ? ctx.dup(0) : nil
        let saved1 = (redirects.stdoutFile != nil || redirects.stdoutToStderr) ? ctx.dup(1) : nil
        let saved2 = (redirects.stderrFile != nil || redirects.stderrToStdout) ? ctx.dup(2) : nil

        if let file = redirects.stdinFile, let fd = ctx.open(expand(file)) {
            ctx.dup2(fd, onto: 0)
            ctx.close(fd)
        }
        if let file = redirects.stdoutFile,
           let fd = ctx.open(expand(file), create: true, truncate: !redirects.appendOut) {
            if redirects.appendOut {
                _ = ctx.seek(fd, to: 0, whence: 2)
            }
            ctx.dup2(fd, onto: 1)
            ctx.close(fd)
        }
        if let file = redirects.stderrFile,
           let fd = ctx.open(expand(file), create: true, truncate: !redirects.appendErr) {
            if redirects.appendErr {
                _ = ctx.seek(fd, to: 0, whence: 2)
            }
            ctx.dup2(fd, onto: 2)
            ctx.close(fd)
        } else if redirects.stderrToStdout {
            ctx.dup2(1, onto: 2)
        }
        if redirects.stdoutToStderr {
            ctx.dup2(2, onto: 1)
        }

        run {
            if let saved0 {
                ctx.dup2(saved0, onto: 0)
                ctx.close(saved0)
            }
            if let saved1 {
                ctx.dup2(saved1, onto: 1)
                ctx.close(saved1)
            }
            if let saved2 {
                ctx.dup2(saved2, onto: 2)
                ctx.close(saved2)
            }
            done()
        }
    }

    /// Materialize the first here-document in `text` and rewrite its operator to
    /// an input redirect from the temporary file.
    static func processHeredoc(_ ctx: ProcessContext,
                               _ text: String,
                               status: ShellStatus) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstLine = lines.first, let spec = firstHeredocSpec(in: firstLine) else {
            return text
        }
        var body: [String] = []
        var index = 1
        var closed = false
        while index < lines.count {
            let raw = lines[index]
            let candidate = spec.stripTabs ? String(raw.drop(while: { $0 == "\t" })) : raw
            index += 1
            if candidate == spec.delimiter {
                closed = true
                break
            }
            body.append(candidate)
        }
        guard closed else { return text }

        var bodyText = body.isEmpty ? "" : body.joined(separator: "\n") + "\n"
        if spec.expand {
            bodyText = expandHeredocBody(bodyText, env: { ctx.getenv($0) }, status: status.last)
        }
        _ = ctx.mkdir("/tmp")
        let temporaryPath = "/tmp/.heredoc"
        if let fd = ctx.open(temporaryPath, create: true, truncate: true) {
            ctx.write(fd, Array(bodyText.utf8))
            ctx.close(fd)
        }
        let rewritten = replaceFirstOccurrence(in: firstLine,
                                                 of: spec.operatorText,
                                                 with: "< " + temporaryPath)
        var reassembled = [rewritten]
        if index < lines.count {
            reassembled += lines[index...]
        }
        return reassembled.joined(separator: "\n")
    }

    /// Accumulate terminal input until the shell parser considers it complete.
    /// `nil` is canonical EOF (Ctrl-D on an empty line).
    static func readCommand(_ ctx: ProcessContext,
                            accumulated: String,
                            done: @escaping (String?) -> Void) {
        ctx.read(0) { line in
            guard !line.isEmpty else {
                done(nil)
                return
            }
            let text = accumulated + String(decoding: line, as: UTF8.self)
            if isComplete(text) {
                done(text)
            } else {
                ctx.setTerminalLinePrompt(0, "> ")
                ctx.write(1, Array("> ".utf8))
                readCommand(ctx, accumulated: text, done: done)
            }
        }
    }
}
