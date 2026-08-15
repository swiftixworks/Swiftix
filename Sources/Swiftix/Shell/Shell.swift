/// The interactive shell entry point and continuation-based AST interpreter.
/// Lexing, parsing, expansion, mutable state, pipeline launching, and independent
/// runtime operations live in focused `Shell/` siblings; this file retains only
/// the mutually recursive read/expand/execute flow.
extension Programs {

    public static func shell(tty: PseudoTerminal.Slave,
                             commands: CommandRegistry = .builtins) -> (ProcessContext) -> Void {
        { ctx in
            // The shell owns fd 0/1/2 = the terminal; every command it launches
            // inherits them (POSIX descriptor inheritance), so a plain command
            // needs no per-child wiring — only redirection / pipes override them.
            ctx.installStandardIO(tty)
            let freshLogin = ctx.getenv("HOME") == nil
            if ctx.getenv("HOME") == nil { ctx.setenv("HOME", ctx.getuid() == 0 ? "/root" : "/home/user\(ctx.getuid())") }
            if ctx.getenv("USER") == nil { ctx.setenv("USER", ctx.getuid() == 0 ? "root" : "user\(ctx.getuid())") }
            if ctx.getenv("LOGNAME") == nil { ctx.setenv("LOGNAME", ctx.getenv("USER") ?? "root") }
            if ctx.getenv("SHELL") == nil { ctx.setenv("SHELL", "/bin/sh") }
            if ctx.getenv("PATH") == nil {
                ctx.setenv("PATH", ProcessContext.defaultExecutablePath)
            }
            if freshLogin, ctx.currentDirectory == "/", let home = ctx.getenv("HOME") {
                _ = ctx.chdir(home)
            }
            // Publish the shell's command set as the system-wide table so
            // meta-programs (which/env CMD/xargs/timeout) can resolve and launch
            // other commands through the same registry the shell uses.
            ctx.installCommands(commands)
            let jobs = JobTable()
            let status = ShellStatus()
            let functions = FunctionTable()
            func displayedDirectory() -> String {
                let directory = ctx.currentDirectory
                guard let home = ctx.getenv("HOME") else { return directory }
                if directory == home { return "~" }
                if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
                return directory
            }
            func prompt() {
                let user = ctx.getenv("USER") ?? (ctx.getuid() == 0 ? "root" : "user\(ctx.getuid())")
                let marker = ctx.getuid() == 0 ? "#" : "$"
                let text = "\(user)@\(ctx.hostname):\(displayedDirectory())\(marker) "
                ctx.setTerminalLinePrompt(0, text)
                ctx.write(1, Array(text.utf8))
            }

            // Run `script` with its stdout captured, delivering the trimmed output
            // (trailing newlines stripped) — the engine behind `$(…)`. It reuses
            // the whole interpreter by temporarily pointing the shell's own fd 1
            // at a pipe, running the inner statement list to completion, then
            // restoring fd 1 and draining the pipe. Because foreground pipelines
            // complete before their continuation runs, all output is buffered by
            // the time we read it (no deadlock on the single loop).
            func captureCommand(_ script: String, _ done: @escaping (String) -> Void) {
                guard let statements = parseScript(lex(script)), !statements.isEmpty else { done(""); return }
                let savedStdout = ctx.dup(1)
                let pipe = ctx.pipe()
                ctx.dup2(pipe.write, onto: 1)
                ctx.close(pipe.write)
                execList(statements, 0) {
                    if let savedStdout { ctx.dup2(savedStdout, onto: 1); ctx.close(savedStdout) }
                    var data: [UInt8] = []
                    while true {
                        let chunk = ctx.read(pipe.read, max: 65_536)
                        if chunk.isEmpty { break }
                        data.append(contentsOf: chunk)
                    }
                    ctx.close(pipe.read)
                    var text = String(decoding: data, as: UTF8.self)
                    while text.hasSuffix("\n") { text.removeLast() }
                    done(text)
                }
            }

            // Replace every `$(…)` in one raw word, delivering the resulting
            // field(s). An unquoted `$(…)` spanning the whole word is field-split
            // on whitespace (so `for i in $(seq 3)` yields three words); a
            // double-quoted or embedded one is spliced inline as a single field.
            // Output is escaped so it is not re-expanded (but unquoted output is
            // still globbed, matching bash).
            func expandCommandSubs(_ raw: String, _ done: @escaping ([String]) -> Void) {
                guard let occurrence = firstCommandSubstitution(raw) else { done([raw]); return }
                captureCommand(occurrence.inner) { output in
                    if occurrence.context == .doubleQuoted {
                        let spliced = occurrence.prefix + escapeInDoubleQuotes(output) + occurrence.suffix
                        expandCommandSubs(spliced, done)
                    } else if occurrence.prefix.isEmpty && occurrence.suffix.isEmpty {
                        done(splitFields(output).map { escapeSubstitutedField($0) })
                    } else {
                        let spliced = occurrence.prefix + escapeInlineUnquoted(output) + occurrence.suffix
                        expandCommandSubs(spliced, done)
                    }
                }
            }

            // Apply command substitution across a list of raw words (in order),
            // flattening the resulting fields.
            func expandCommandSubsList(_ words: [String], _ done: @escaping ([String]) -> Void) {
                var result: [String] = []
                func step(_ index: Int) {
                    if index >= words.count { done(result); return }
                    expandCommandSubs(words[index]) { fields in result += fields; step(index + 1) }
                }
                step(0)
            }

            // Substitute `$(…)` in every stage's argv before the pipeline runs.
            func substituteStages(_ stages: [RawStage], _ done: @escaping ([RawStage]) -> Void) {
                var out: [RawStage] = []
                func step(_ index: Int) {
                    if index >= stages.count { done(out); return }
                    expandCommandSubsList(stages[index].argv) { argv in
                        var stage = stages[index]; stage.argv = argv
                        out.append(stage); step(index + 1)
                    }
                }
                step(0)
            }

            // Run one simple pipeline (RAW stages, expanded here against the
            // *current* env/status), updating `$?`, then call `done`. Handles lone
            // `NAME=VALUE`, the shell intrinsics (export/cd/jobs/fg/bg), and `&`.
            func runSimple(_ rawStages: [RawStage], background: Bool, done: @escaping () -> Void) {
                let stages = rawStages.map { raw -> Stage in
                    // Redirect targets are expanded here; argv is rebuilt below so
                    // it can also apply pathname globbing.
                    var s = expandStage(raw, env: { ctx.getenv($0) }, status: status.last)
                    // Peel leading `NAME=VALUE` assignments from the expanded argv
                    // (their RHS is not globbed), tracking the matching raw words.
                    var rawArgv = raw.argv
                    while let first = s.argv.first, let pair = assignment(first) {
                        s.assignments.append(pair)
                        s.argv.removeFirst()
                        if !rawArgv.isEmpty { rawArgv.removeFirst() }
                    }
                    // Expand + glob the remaining words (one raw word may yield
                    // several fields when it matches multiple paths).
                    s.argv = rawArgv.flatMap {
                        expandAndGlob($0, env: { ctx.getenv($0) }, status: status.last,
                                      list: { ctx.listDirectory($0) })
                    }
                    return s
                }
                // Lone `NAME=VALUE` (no command): set the shell's own env, `$?`=0.
                if stages.count == 1, stages[0].argv.isEmpty, !stages[0].assignments.isEmpty {
                    for pair in stages[0].assignments { ctx.setenv(pair.name, pair.value) }
                    status.last = 0
                    done()
                    return
                }
                guard !stages.isEmpty, stages.allSatisfy({ !$0.argv.isEmpty }) else {
                    if !stages.isEmpty {
                        ctx.write(2, Array("sh: syntax error\n".utf8))
                        status.last = 2
                    }
                    done()
                    return
                }
                // Single-stage intrinsics run in the shell's own process.
                if stages.count == 1 {
                    let argv = stages[0].argv
                    switch argv[0] {
                    case "export":
                        for token in argv.dropFirst() {
                            if let pair = assignment(token) { ctx.setenv(pair.name, pair.value) }
                        }
                        status.last = 0
                        done()
                        return
                    case "cd":
                        let path = argv.count > 1 ? argv[1] : (ctx.getenv("HOME") ?? "/")
                        if ctx.chdir(path) {
                            status.last = 0
                        } else {
                            ctx.write(2, Array("cd: \(path): No such directory\n".utf8))
                            status.last = 1
                        }
                        done()
                        return
                    case "jobs":
                        for job in jobs.list() {
                            let state = job.stopped ? "Stopped" : "Running"
                            ctx.write(1, Array("[\(job.id)] \(state)\t\(job.command)\n".utf8))
                        }
                        status.last = 0
                        done()
                        return
                    case "fg":
                        foreground(ctx, argv, jobs: jobs, status: status,
                                   resumeInBackground: false, done: done)
                        return
                    case "bg":
                        foreground(ctx, argv, jobs: jobs, status: status,
                                   resumeInBackground: true, done: done)
                        return
                    default:
                        break
                    }
                }
                // A defined shell function runs in the shell's own process (not a
                // child), with `$1…`/`$#`/`$@` bound to its arguments — so it can
                // `cd`, set variables, and define more functions like a real
                // function. Checked after the intrinsics, before external commands.
                // Any redirection on the call (`greet > out`) is applied around
                // the whole function body via the raw stage's redirect targets.
                if stages.count == 1, let body = functions.body(stages[0].argv[0]) {
                    let raw = rawStages[0]
                    let redirects = Redirects(stdinFile: raw.stdinFile,
                                              stdoutFile: raw.stdoutFile,
                                              appendOut: raw.appendOut,
                                              stderrFile: raw.stderrFile,
                                              appendErr: raw.appendErr,
                                              stderrToStdout: raw.stderrToStdout,
                                              stdoutToStderr: raw.stdoutToStderr)
                    let args = Array(stages[0].argv.dropFirst())
                    if redirects.isEmpty {
                        callFunction(ctx, args: args, run: { finish in
                            execList(body, 0, finish)
                        }, then: done)
                    } else {
                        runWithRedirects(ctx, redirects, status: status, run: { redirectedDone in
                            callFunction(ctx, args: args, run: { functionDone in
                                execList(body, 0, functionDone)
                            }, then: redirectedDone)
                        }, then: done)
                    }
                    return
                }

                // Resolve every stage's program before launching any.
                var resolved: [(stage: Stage, command: Command)] = []
                for stage in stages {
                    let assignedPath = stage.assignments.last(where: { $0.name == "PATH" })?.value
                    guard let command = ctx.resolveCommand(
                        stage.argv[0], searchPath: assignedPath)
                    else {
                        ctx.write(2, Array("\(stage.argv[0]): command not found\n".utf8))
                        status.last = 127
                        done()
                        return
                    }
                    resolved.append((stage, command))
                }
                let label = stages.map { $0.argv.joined(separator: " ") }.joined(separator: " | ")
                runPipeline(ctx, resolved, jobs: jobs, status: status,
                            background: background, commandText: label, done: done)
            }

            func execCommand(_ command: ScriptCommand, background: Bool, _ done: @escaping () -> Void) {
                switch command {
                case let .redirected(inner, redirects):
                    runWithRedirects(ctx, redirects, status: status, run: { finish in
                        execCommand(inner, background: background, finish)
                    }, then: done)
                case let .pipeline(rawStages):
                    // Command substitution (`$(…)`) runs first, since it may block
                    // and rewrite the argv, then the (synchronous) pipeline runs.
                    substituteStages(rawStages) { substituted in
                        runSimple(substituted, background: background, done: done)
                    }
                case let .ifClause(cond, thenBody, elseBody):
                    execList(cond, 0) {
                        if status.last == 0 { execList(thenBody, 0, done) }
                        else { execList(elseBody, 0, done) }
                    }
                case let .whileClause(cond, body):
                    func iterate() {
                        execList(cond, 0) {
                            if status.last == 0 { execList(body, 0) { iterate() } }
                            else { done() }
                        }
                    }
                    iterate()
                case let .functionDef(name, body):
                    // Register the function; it runs in the shell process when
                    // invoked by name (see `runSimple`).
                    functions.define(name, body)
                    status.last = 0
                    done()
                case let .caseClause(subject, clauses):
                    // Expand the subject, then run the first clause whose glob
                    // pattern matches it (`*` catches all, like a default).
                    let value = expandWord(subject, env: { ctx.getenv($0) }, status: status.last)
                    for clause in clauses {
                        let matched = clause.patterns.contains { pattern in
                            let expanded = expandWord(pattern, env: { ctx.getenv($0) }, status: status.last)
                            return globMatch(Array(expanded), Array(value))
                        }
                        if matched { execList(clause.body, 0, done); return }
                    }
                    status.last = 0   // no clause matched
                    done()
                case let .forClause(variable, words, body):
                    // Command-substitute the list first (may block), then apply
                    // parameter/arithmetic expansion + globbing, and run the body
                    // with the loop variable bound to each value in turn
                    // (continuation-style so the loop never grows native stack).
                    expandCommandSubsList(words) { subbed in
                        let values = subbed.flatMap {
                            expandAndGlob($0, env: { ctx.getenv($0) }, status: status.last,
                                          list: { ctx.listDirectory($0) })
                        }
                        var index = 0
                        func iterate() {
                            guard index < values.count else { done(); return }
                            ctx.setenv(variable, values[index])
                            index += 1
                            execList(body, 0) { iterate() }
                        }
                        iterate()
                    }
                }
            }

            func execStatement(_ statement: ScriptStatement, _ done: @escaping () -> Void) {
                func runChain(_ i: Int) {
                    if i >= statement.rest.count { done(); return }
                    let (connector, command) = statement.rest[i]
                    // `&&` runs its RHS only after success; `||` only after failure.
                    let shouldRun = connector == .and ? (status.last == 0) : (status.last != 0)
                    if shouldRun { execCommand(command, background: false) { runChain(i + 1) } }
                    else { runChain(i + 1) }
                }
                execCommand(statement.first,
                            background: statement.background && statement.rest.isEmpty) {
                    runChain(0)
                }
            }

            func execList(_ statements: [ScriptStatement], _ index: Int, _ done: @escaping () -> Void) {
                if index >= statements.count { done(); return }
                execStatement(statements[index]) { execList(statements, index + 1, done) }
            }

            // Read a (possibly multi-line) command, then parse + execute it.
            func loop() {
                // Safety net: a full-screen program or pager
                // may have switched the tty to raw mode. The shell always reads
                // cooked, line-edited input, so restore canonical mode before
                // prompting — just as a real shell resets the terminal when it
                // regains the foreground. A no-op when already cooked.
                ctx.setTerminalRawMode(0, false)
                readCommand(ctx, accumulated: "") { rawText in
                    guard let rawText else {
                        ctx.exit(0)
                        return
                    }
                    reapBackground(ctx, jobs: jobs)
                    // Extract any here-document (`<<EOF … EOF`) into a temp file
                    // and rewrite the command to read stdin from it, before lexing.
                    let text = processHeredoc(ctx, rawText, status: status)
                    guard let statements = parseScript(lex(text)) else {
                        ctx.write(2, Array("sh: syntax error\n".utf8))
                        status.last = 2
                        prompt()
                        loop()
                        return
                    }
                    if statements.isEmpty {
                        prompt()
                        loop()
                        return
                    }
                    execList(statements, 0) {
                        prompt()
                        loop()
                    }
                }
            }

            prompt()
            loop()
        }
    }

}
