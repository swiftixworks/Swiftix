/// The shell interpreter: one instance per shell process (the interactive
/// login shell, an `sh` script, a subshell, a pipeline stage running shell
/// code, or a command substitution). It owns the shell's variables, functions,
/// aliases, options, traps, and job table, and walks the AST in
/// continuation-passing style.
///
/// Concurrency: a non-Sendable reference type confined to the kernel's single
/// serial executor. Nothing blocks: every wait (child exit, terminal read,
/// pipe drain) parks through a `ProcessContext` syscall and resumes via its
/// continuation, so no locking is needed.
extension Programs {

    final class ShellInterpreter {
        let ctx: ProcessContext
        let jobs = JobTable()
        let status = ShellStatus()

        var functions: [String: [ScriptStatement]] = [:]
        var aliases: [String: String] = [:]
        /// Shell variables that are not exported; exported ones live in the
        /// process environment.
        var variables: [String: String] = [:]
        var positional: [String] = []
        var scriptName = "sh"
        var shellPID: PID

        var errexit = false
        var nounset = false
        var xtrace = false
        /// Reads commands from a terminal: prompts, job notices, and a syntax
        /// or expansion error does not end the shell.
        var interactive = false
        /// Places jobs in their own process groups and hands them the terminal.
        var jobControl = false

        var flow: ShellFlow = .none
        var loopDepth = 0
        var functionDepth = 0
        var sourceDepth = 0
        /// Non-zero while running a command whose failure is being tested
        /// (`if`/`while` conditions, non-final `&&`/`||` operands, `!`), which
        /// exempts it from `set -e`.
        var conditionDepth = 0

        struct SavedVariable {
            var shell: String?
            var environment: String?
        }
        /// One frame per active function call: the values `local` shadowed.
        var localScopes: [[String: SavedVariable]] = []

        var traps: [String: String] = [:]
        var pendingTraps: [String] = []
        var runningTrap = false

        var lastBackgroundPID: PID?
        var backgroundPIDs: Set<PID> = []
        var exitStatuses: [PID: Int32] = [:]
        var history: [String] = []
        /// The parent shell's traps and jobs as they were when this child was
        /// forked. They are only listed (`$(trap)`, `jobs | cat`): traps are
        /// reset in a child and its parent's jobs are not its children. Each
        /// is forgotten once the child sets a trap / starts a background job.
        var inheritedTraps: [String: String] = [:]
        var inheritedJobs: [(id: Int, command: String, stopped: Bool)] = []
        /// Whether `runText` has started a statement: a command substitution
        /// that runs no command at all (`$()`) exits 0, not the inherited `$?`.
        var ranStatement = false
        /// Next descriptor used to park an fd saved around a redirected block.
        var nextSavedFD = 64

        init(_ ctx: ProcessContext) {
            self.ctx = ctx
            self.shellPID = ctx.getpid()
        }

        /// A child interpreter continuing from `snapshot` in process `ctx`.
        init(_ ctx: ProcessContext, snapshot: ShellSnapshot) {
            self.ctx = ctx
            functions = snapshot.functions
            aliases = snapshot.aliases
            variables = snapshot.variables
            positional = snapshot.positional
            scriptName = snapshot.scriptName
            shellPID = snapshot.shellPID
            errexit = snapshot.errexit
            nounset = snapshot.nounset
            xtrace = snapshot.xtrace
            status.last = snapshot.lastStatus
            lastBackgroundPID = snapshot.lastBackgroundPID
            history = snapshot.history
            inheritedTraps = snapshot.traps
            inheritedJobs = snapshot.jobs
        }

        func snapshot() -> ShellSnapshot {
            ShellSnapshot(functions: functions, aliases: aliases, variables: variables,
                          positional: positional, scriptName: scriptName, shellPID: shellPID,
                          errexit: errexit, nounset: nounset, xtrace: xtrace,
                          lastStatus: status.last, lastBackgroundPID: lastBackgroundPID,
                          history: history, traps: listedTraps, jobs: listedJobs)
        }

        /// What `trap` and `jobs` list: this shell's own entries plus, in a
        /// child shell, the ones its parent had at fork time.
        var listedTraps: [String: String] { inheritedTraps.merging(traps) { $1 } }
        var listedJobs: [(id: Int, command: String, stopped: Bool)] { inheritedJobs + jobs.list() }

        // MARK: - Output helpers

        func out(_ text: String) { ctx.write(1, Array(text.utf8)) }
        func err(_ text: String) { ctx.write(2, Array(text.utf8)) }

        // MARK: - Variables and parameters

        func value(of name: String) -> String? {
            variables[name] ?? ctx.getenv(name)
        }

        /// Assign a variable: an exported name updates the environment, any
        /// other stays a shell variable.
        func setVariable(_ name: String, _ value: String) {
            if ctx.getenv(name) != nil {
                ctx.setenv(name, value)
            } else {
                variables[name] = value
            }
        }

        func exportVariable(_ name: String, value: String? = nil) {
            let resolved = value ?? variables[name] ?? ctx.getenv(name)
            variables[name] = nil
            if let resolved { ctx.setenv(name, resolved) }
        }

        func unsetVariable(_ name: String) {
            variables[name] = nil
            ctx.process.environment[name] = nil
        }

        func saveVariable(_ name: String) -> SavedVariable {
            SavedVariable(shell: variables[name], environment: ctx.getenv(name))
        }

        func restoreVariable(_ name: String, _ saved: SavedVariable) {
            variables[name] = saved.shell
            ctx.process.environment[name] = saved.environment
        }

        /// A variable or special parameter (everything except `$@` / `$*`).
        func parameter(_ name: String) -> String? {
            switch name {
            case "?": return String(status.last)
            case "#": return String(positional.count)
            case "$": return String(shellPID)
            case "!": return lastBackgroundPID.map { String($0) }
            case "0": return scriptName
            case "-":
                return (errexit ? "e" : "") + (nounset ? "u" : "") + (xtrace ? "x" : "")
                    + (interactive ? "i" : "")
            case "RANDOM" where variables[name] == nil && ctx.getenv(name) == nil:
                // 0...32767 from the kernel's deterministic generator.
                let bytes = ctx.randomBytes(2)
                return String((Int(bytes[0]) << 8 | Int(bytes[1])) & 0x7FFF)
            default:
                if let first = name.first, first.isASCII, first.isNumber {
                    guard let index = Int(name), index >= 1, index <= positional.count else { return nil }
                    return positional[index - 1]
                }
                return value(of: name)
            }
        }

        func expansionContext(outputs: [String: String]) -> ExpansionContext {
            ExpansionContext(
                parameter: { [unowned self] in self.parameter($0) },
                positional: positional,
                assign: { [unowned self] in self.setVariable($0, $1) },
                commandOutput: { outputs[$0] ?? "" },
                list: { [unowned self] in self.ctx.listDirectory($0) },
                nounset: nounset)
        }

        // MARK: - Leaving the shell

        /// End this shell process with `code`, running the `EXIT` trap first.
        /// Callers must not invoke their continuation afterwards.
        func exitShell(_ code: Int32) {
            if let action = traps["EXIT"], !action.isEmpty {
                traps["EXIT"] = nil
                flow = .none
                errexit = false
                status.last = code
                runText(action) { self.ctx.exit(code) }
                return
            }
            ctx.exit(code)
        }

        /// Report an expansion error. An interactive shell abandons the command;
        /// any other shell exits, as POSIX requires.
        func expansionError(_ message: String, then done: @escaping () -> Void) {
            err("sh: \(message)\n")
            status.last = 1
            if interactive {
                flow = .abort                // drop the rest of the input line
                done()
            } else {
                exitShell(1)
            }
        }

        // MARK: - Source text

        /// Lex `text` and run it one top-level statement at a time.
        func runText(_ text: String, done: @escaping () -> Void) {
            final class Box { var parser: ScriptParser; init(_ p: ScriptParser) { parser = p } }
            let box = Box(ScriptParser(tokens: lex(text), alias: { [unowned self] in self.aliases[$0] }))
            drive({ next in
                guard self.flow == .none else { next(false); return }
                switch box.parser.parseNext() {
                case .end:
                    next(false)
                case .syntaxError:
                    self.err("sh: syntax error\n")
                    self.status.last = 2
                    if self.interactive { next(false) } else { self.exitShell(2) }
                case let .statement(statement):
                    self.ranStatement = true
                    self.runPendingTraps {
                        self.execStatement(statement) { next(true) }
                    }
                }
            }, done: done)
        }

        // MARK: - Statements

        func execList(_ statements: [ScriptStatement], _ done: @escaping () -> Void) {
            if statements.isEmpty { done(); return }
            var index = 0
            drive({ next in
                guard index < statements.count, self.flow == .none else { next(false); return }
                let statement = statements[index]
                index += 1
                self.runPendingTraps {
                    self.execStatement(statement) { next(true) }
                }
            }, done: done)
        }

        func execStatement(_ statement: ScriptStatement, _ done: @escaping () -> Void) {
            if statement.background {
                if statement.rest.isEmpty {
                    execCommand(statement.first, background: true, done)
                } else {
                    var foreground = statement
                    foreground.background = false
                    execCommand(.group([foreground]), background: true, done)
                }
                return
            }
            if statement.rest.isEmpty {
                execCommand(statement.first, background: false, done)
                return
            }
            // Every operand but the last is "tested": its failure never trips
            // `set -e`.
            conditionDepth += 1
            execCommand(statement.first, background: false) {
                self.conditionDepth -= 1
                self.runChain(statement, 0, done)
            }
        }

        private func runChain(_ statement: ScriptStatement, _ index: Int, _ done: @escaping () -> Void) {
            if index >= statement.rest.count || flow != .none { done(); return }
            let (connector, command) = statement.rest[index]
            // `&&` runs its RHS only after success; `||` only after failure.
            let shouldRun = connector == .and ? (status.last == 0) : (status.last != 0)
            guard shouldRun else { runChain(statement, index + 1, done); return }
            let isLast = index == statement.rest.count - 1
            if !isLast { conditionDepth += 1 }
            execCommand(command, background: false) {
                if !isLast { self.conditionDepth -= 1 }
                self.runChain(statement, index + 1, done)
            }
        }

        /// `set -e`: leave the shell when an untested command failed.
        private func afterCommand(_ done: @escaping () -> Void) {
            if errexit, conditionDepth == 0, flow == .none, status.last != 0 {
                exitShell(status.last)
            } else {
                done()
            }
        }

        // MARK: - Commands

        /// How many iterations a `while`/`until` loop runs before it gives
        /// the processor back, so signals arrive and other work runs. The
        /// first iteration yields too, so a long loop is yielded work (which
        /// does not hold logical time) from its start.
        private static let loopYieldInterval = 256

        func execCommand(_ command: ScriptCommand, background: Bool, _ done: @escaping () -> Void) {
            if background {
                switch command {
                case let .simple(raw):
                    runSimple(raw, background: true, done)
                case let .pipeline(commands, negated) where commands.count > 1:
                    runPipeline(commands, negated: negated, background: true, done)
                default:
                    launchStages([shellStage(for: command)], background: true, done: done)
                }
                return
            }
            switch command {
            case let .simple(raw):
                runSimple(raw, background: false) { self.afterCommand(done) }
            case let .pipeline(commands, negated):
                runPipeline(commands, negated: negated, background: false) {
                    if negated { done() } else { self.afterCommand(done) }
                }
            case let .group(body):
                execList(body, done)
            case .subshell:
                launchStages([shellStage(for: command)], background: false) { self.afterCommand(done) }
            case let .redirected(inner, redirections):
                resolveRedirections(redirections) { resolved in
                    guard let resolved else { done(); return }
                    self.withRedirections(resolved, run: { finish in
                        self.execCommand(inner, background: false, finish)
                    }, then: done)
                }
            case let .ifClause(cond, thenBody, elseBody):
                conditionDepth += 1
                execList(cond) {
                    self.conditionDepth -= 1
                    guard self.flow == .none else { done(); return }
                    if self.status.last == 0 {
                        self.execList(thenBody, done)
                    } else if elseBody.isEmpty {
                        self.status.last = 0          // no branch taken
                        done()
                    } else {
                        self.execList(elseBody, done)
                    }
                }
            case let .whileClause(cond, body, until):
                var lastBodyStatus: Int32 = 0
                var iterations = 0
                loopDepth += 1
                drive({ next in
                    self.conditionDepth += 1
                    self.execList(cond) {
                        self.conditionDepth -= 1
                        guard self.flow == .none else { next(false); return }
                        guard (self.status.last == 0) != until else { next(false); return }
                        self.execList(body) {
                            lastBodyStatus = self.status.last
                            let again = self.continueLoopAfterBody()
                            iterations += 1
                            guard again, iterations % Self.loopYieldInterval == 1 else {
                                next(again)
                                return
                            }
                            // A loop of builtins alone (`while :; do :; done`)
                            // completes every iteration inside one step and
                            // would never return to the event loop.
                            self.ctx.yield { next(true) }
                        }
                    }
                }, done: {
                    self.loopDepth -= 1
                    if self.flow == .none { self.status.last = lastBodyStatus }
                    done()
                })
            case let .forClause(variable, words, body):
                // Expand the list first (command substitutions may block), then
                // run the body with the loop variable bound to each value.
                expandWords(words ?? ["\"$@\""]) { values in
                    guard let values else { done(); return }
                    var index = 0
                    self.status.last = 0
                    self.loopDepth += 1
                    drive({ next in
                        guard index < values.count else { next(false); return }
                        self.setVariable(variable, values[index])
                        index += 1
                        self.execList(body) { next(self.continueLoopAfterBody()) }
                    }, done: {
                        self.loopDepth -= 1
                        done()
                    })
                }
            case let .caseClause(subject, clauses):
                // Expand the subject, then run the first clause whose glob
                // pattern matches it (`*` catches all, like a default).
                let words = [subject] + clauses.flatMap(\.patterns)
                resolveSubstitutions(words.flatMap { commandSubstitutions(in: $0) }) { outputs, _ in
                    var expander = WordExpander(context: self.expansionContext(outputs: outputs))
                    let value = Array(expander.string(subject))
                    var chosen: [ScriptStatement]?
                    search: for clause in clauses {
                        for pattern in clause.patterns where patternMatch(expander.pattern(pattern), value) {
                            chosen = clause.body
                            break search
                        }
                    }
                    if let error = expander.error {
                        self.expansionError(error, then: done)
                        return
                    }
                    self.status.last = 0              // no clause matched / empty body
                    if let chosen { self.execList(chosen, done) } else { done() }
                }
            case let .functionDef(name, body):
                // Register the function; it runs in the shell process when
                // invoked by name (see `execute`).
                functions[name] = body
                status.last = 0
                done()
            }
        }

        /// Apply a pending `break`/`continue` to the innermost loop; returns
        /// whether that loop should run another iteration.
        private func continueLoopAfterBody() -> Bool {
            switch flow {
            case .none:
                return true
            case let .breakLoop(levels):
                flow = levels > 1 ? .breakLoop(levels - 1) : .none
                return false
            case let .continueLoop(levels):
                if levels > 1 { flow = .continueLoop(levels - 1); return false }
                flow = .none
                return true
            case .returning, .abort:
                return false
            }
        }

        // MARK: - Expansion

        /// Run every command substitution in `scripts` (in order), delivering
        /// their outputs keyed by script text and the exit status of the last
        /// one (`nil` when there was none). `$?` itself is left alone: every
        /// expansion of a command sees the status of the *previous* command,
        /// wherever the substitutions sit among its words.
        func resolveSubstitutions(_ scripts: [String],
                                  _ done: @escaping (_ outputs: [String: String], _ status: Int32?) -> Void) {
            if scripts.isEmpty { done([:], nil); return }
            var outputs: [String: String] = [:]
            var last: Int32?
            var index = 0
            drive({ next in
                guard index < scripts.count else { next(false); return }
                let script = scripts[index]
                index += 1
                self.capture(script) { text, code in
                    outputs[script] = text
                    last = code
                    next(true)
                }
            }, done: { done(outputs, last) })
        }

        /// Run `script` in a child shell with its stdout captured, delivering the
        /// output with trailing newlines stripped — the engine behind `$(…)`.
        /// The parent drains the pipe while the child runs, so output larger
        /// than the pipe buffer cannot deadlock. The child's exit status is
        /// delivered alongside; this shell's `$?` is not touched.
        func capture(_ script: String, _ done: @escaping (String, Int32) -> Void) {
            let pipe = ctx.pipe()
            let state = snapshot()
            let pid = ctx.spawn("sh", args: ["sh"]) { child in
                child.dup2(pipe.write, onto: 1)
                child.close(pipe.read)
                child.close(pipe.write)
                let shell = ShellInterpreter(child, snapshot: state)
                shell.runText(script) { shell.exitShell(shell.ranStatement ? shell.status.last : 0) }
            }
            ctx.close(pipe.write)
            guard pid != 0 else {
                ctx.close(pipe.read)
                done("", 126)
                return
            }
            var data: [UInt8] = []
            drive({ next in
                self.ctx.read(pipe.read, max: 65_536) { chunk in
                    data.append(contentsOf: chunk)
                    next(!chunk.isEmpty)
                }
            }, done: {
                self.ctx.close(pipe.read)
                self.awaitChild(pid) { code in
                    var text = String(decoding: data, as: UTF8.self)
                    while text.hasSuffix("\n") { text.removeLast() }
                    done(text, code)
                }
            })
        }

        /// Expand a list of raw words to fields (command substitution, parameter
        /// expansion, splitting, globbing); `nil` after a reported error.
        func expandWords(_ words: [String], _ done: @escaping ([String]?) -> Void) {
            resolveSubstitutions(words.flatMap { commandSubstitutions(in: $0) }) { outputs, _ in
                var expander = WordExpander(context: self.expansionContext(outputs: outputs))
                var fields: [String] = []
                for word in words { fields += expander.fields(word) }
                if let error = expander.error {
                    self.expansionError(error) { done(nil) }
                } else {
                    done(fields)
                }
            }
        }

        private func substitutions(in redirections: [Redirection]) -> [String] {
            redirections.flatMap { redirection -> [String] in
                switch redirection.kind {
                case let .input(word), let .output(word, _), let .hereString(word):
                    return commandSubstitutions(in: word)
                case let .hereDocument(body, expand):
                    return expand ? commandSubstitutions(in: body, heredoc: true) : []
                case .duplicate, .close:
                    return []
                }
            }
        }

        private func resolve(_ redirections: [Redirection],
                             with expander: inout WordExpander) -> [ResolvedRedirection] {
            redirections.map { redirection in
                switch redirection.kind {
                case let .input(word):
                    return .read(fd: redirection.fd, path: expander.string(word))
                case let .output(word, append):
                    return .write(fd: redirection.fd, path: expander.string(word), append: append)
                case let .duplicate(target):
                    return .duplicate(fd: redirection.fd, target: target)
                case .close:
                    return .close(fd: redirection.fd)
                case let .hereDocument(body, expand):
                    return .data(fd: redirection.fd, text: expand ? expander.heredoc(body) : body)
                case let .hereString(word):
                    return .data(fd: redirection.fd, text: expander.string(word) + "\n")
                }
            }
        }

        /// Expand redirection targets; `nil` after a reported error.
        func resolveRedirections(_ redirections: [Redirection],
                                 _ done: @escaping ([ResolvedRedirection]?) -> Void) {
            resolveSubstitutions(substitutions(in: redirections)) { outputs, _ in
                var expander = WordExpander(context: self.expansionContext(outputs: outputs))
                let resolved = self.resolve(redirections, with: &expander)
                if let error = expander.error {
                    self.expansionError(error) { done(nil) }
                } else {
                    done(resolved)
                }
            }
        }

        /// Expand a simple command against the *current* state; `nil` after a
        /// reported error.
        func prepare(_ raw: RawStage, _ done: @escaping (PreparedCommand?) -> Void) {
            let scripts = raw.argv.flatMap { commandSubstitutions(in: $0) }
                + substitutions(in: raw.redirections)
            resolveSubstitutions(scripts) { outputs, substitutionStatus in
                var expander = WordExpander(context: self.expansionContext(outputs: outputs))
                var prepared = PreparedCommand()
                prepared.substitutionStatus = substitutionStatus
                // Leading `NAME=VALUE` words are assignments: the value is
                // expanded but neither split nor globbed.
                var index = 0
                while index < raw.argv.count, let pair = assignment(raw.argv[index]) {
                    prepared.assignments.append((pair.name, expander.string(pair.value)))
                    index += 1
                }
                for word in raw.argv[index...] { prepared.argv += expander.fields(word) }
                prepared.redirections = self.resolve(raw.redirections, with: &expander)
                if let error = expander.error {
                    self.expansionError(error) { done(nil) }
                } else {
                    done(prepared)
                }
            }
        }

        // MARK: - Simple commands and pipelines

        private func runSimple(_ raw: RawStage, background: Bool, _ done: @escaping () -> Void) {
            prepare(raw) { prepared in
                guard let prepared else { done(); return }
                self.execute(prepared, background: background, done: done)
            }
        }

        private func runPipeline(_ commands: [ScriptCommand], negated: Bool, background: Bool,
                                 _ done: @escaping () -> Void) {
            func finish() {
                if negated, flow == .none { status.last = status.last == 0 ? 1 : 0 }
                done()
            }
            if commands.count == 1 {
                // `! command`: the command is tested, so `set -e` ignores it.
                conditionDepth += 1
                execCommand(commands[0], background: false) {
                    self.conditionDepth -= 1
                    finish()
                }
                return
            }
            // Expand every simple stage in the parent, in order, then launch.
            var stages: [StageLaunch] = []
            var index = 0
            var failed = false
            drive({ next in
                guard index < commands.count else { next(false); return }
                let command = commands[index]
                index += 1
                if case let .simple(raw) = command {
                    self.prepare(raw) { prepared in
                        guard let prepared else { failed = true; next(false); return }
                        stages.append(self.stage(for: prepared))
                        next(true)
                    }
                } else {
                    stages.append(self.shellStage(for: command))
                    next(true)
                }
            }, done: {
                if failed { done(); return }
                self.launchStages(stages, background: background, done: finish)
            })
        }

        /// A pipeline stage that runs an AST command in a child shell.
        func shellStage(for command: ScriptCommand) -> StageLaunch {
            let state = snapshot()
            let body: [ScriptStatement]
            let label: String
            switch command {
            case let .subshell(list): body = list; label = "( ... )"
            case let .group(list): body = list; label = "{ ... }"
            default:
                body = [ScriptStatement(first: command, rest: [], background: false)]
                label = "sh"
            }
            return StageLaunch(name: "sh", argv: ["sh"], label: label, body: .shell { child in
                let shell = ShellInterpreter(child, snapshot: state)
                shell.execList(body) { shell.exitShell(shell.status.last) }
            })
        }

        /// A pipeline stage for an expanded simple command: a registered program
        /// runs directly; anything the shell itself must interpret (builtin,
        /// function, assignment, unknown name) runs in a child shell.
        func stage(for prepared: PreparedCommand) -> StageLaunch {
            let label = prepared.argv.joined(separator: " ")
            if let name = prepared.argv.first, !runsInShell(name),
               let command = resolveExternal(prepared) {
                let redirections = prepared.redirections
                let assignments = prepared.assignments
                return StageLaunch(name: name, argv: prepared.argv, label: label,
                                   body: .command(command, setup: { child in
                    for pair in assignments { child.setenv(pair.name, pair.value) }
                    if let error = ShellInterpreter.applyRedirections(child, redirections) {
                        child.write(2, Array("sh: \(error)\n".utf8))
                        return false
                    }
                    return true
                }))
            }
            let state = snapshot()
            return StageLaunch(name: prepared.argv.first ?? "sh",
                               argv: prepared.argv.isEmpty ? ["sh"] : prepared.argv,
                               label: label, body: .shell { child in
                let shell = ShellInterpreter(child, snapshot: state)
                shell.execute(prepared, background: false) { shell.exitShell(shell.status.last) }
            })
        }

        func runsInShell(_ name: String) -> Bool {
            functions[name] != nil || ShellInterpreter.builtinNames.contains(name)
        }

        func resolveExternal(_ prepared: PreparedCommand) -> Command? {
            guard let name = prepared.argv.first else { return nil }
            let assignedPath = prepared.assignments.last(where: { $0.name == "PATH" })?.value
            return ctx.resolveCommand(name, searchPath: assignedPath)
        }

        /// Run one expanded simple command in this shell, updating `$?`.
        func execute(_ command: PreparedCommand, background: Bool, skipFunctions: Bool = false,
                     done: @escaping () -> Void) {
            var prepared = command
            if xtrace {
                let words = prepared.assignments.map { "\($0.name)=\($0.value)" } + prepared.argv
                err("+ " + words.joined(separator: " ") + "\n")
            }
            guard let name = prepared.argv.first else {
                // Assignments and/or bare redirections (`> file`).
                let substitutionStatus = prepared.substitutionStatus ?? 0
                withRedirections(prepared.redirections, run: { finish in
                    for pair in prepared.assignments { self.setVariable(pair.name, pair.value) }
                    self.status.last = substitutionStatus
                    finish()
                }, then: done)
                return
            }
            if name == "kill" {
                // Job specs are a shell notion: hand `kill` the job's pids.
                guard let expanded = expandJobSpecs(prepared.argv) else { done(); return }
                prepared.argv = expanded
            }
            if background {
                launchStages([stage(for: prepared)], background: true, done: done)
                return
            }
            if name == "exec" {
                builtinExec(prepared, done: done)
                return
            }
            if !skipFunctions, let body = functions[name], !ShellInterpreter.specialBuiltinNames.contains(name) {
                inShell(prepared, done: done) { finish in
                    self.callFunction(body, arguments: Array(prepared.argv.dropFirst()), done: finish)
                }
                return
            }
            if ShellInterpreter.builtinNames.contains(name) {
                inShell(prepared, done: done) { finish in
                    self.runBuiltin(prepared.argv, done: finish)
                }
                return
            }
            guard let resolved = resolveExternal(prepared) else {
                reportUnresolved(name)
                done()
                return
            }
            let redirections = prepared.redirections
            let assignments = prepared.assignments
            let stage = StageLaunch(name: name, argv: prepared.argv,
                                    label: prepared.argv.joined(separator: " "),
                                    body: .command(resolved, setup: { child in
                for pair in assignments { child.setenv(pair.name, pair.value) }
                if let error = ShellInterpreter.applyRedirections(child, redirections) {
                    child.write(2, Array("sh: \(error)\n".utf8))
                    return false
                }
                return true
            }))
            launchStages([stage], background: false, done: done)
        }

        /// Explain why `name` cannot be run and set `$?` (127 unknown, 126 found
        /// but not runnable).
        func reportUnresolved(_ name: String) {
            if name.contains("/"), let info = ctx.stat(name) {
                if info.isDirectory {
                    err("sh: \(name): Is a directory\n")
                } else if !ctx.canExecute(name) {
                    err("sh: \(name): Permission denied\n")
                } else {
                    err("sh: \(name): cannot execute: unrecognized format\n")
                }
                status.last = 126
            } else {
                err("\(name): command not found\n")
                status.last = 127
            }
        }

        /// Run shell-side code (builtin or function) under the command's
        /// redirections and temporary assignments.
        private func inShell(_ prepared: PreparedCommand, done: @escaping () -> Void,
                             run: @escaping (_ finish: @escaping () -> Void) -> Void) {
            withRedirections(prepared.redirections, run: { finish in
                guard !prepared.assignments.isEmpty else { run(finish); return }
                // `NAME=VALUE command`: exported for the duration of the call.
                let saved = prepared.assignments.map { ($0.name, self.saveVariable($0.name)) }
                for pair in prepared.assignments {
                    self.variables[pair.name] = nil
                    self.ctx.setenv(pair.name, pair.value)
                }
                run {
                    for (name, value) in saved.reversed() { self.restoreVariable(name, value) }
                    finish()
                }
            }, then: done)
        }

        /// Bind the positional parameters while `body` runs, then restore the
        /// caller's parameters and any variables `local` shadowed.
        func callFunction(_ body: [ScriptStatement], arguments: [String], done: @escaping () -> Void) {
            let savedPositional = positional
            let savedLoopDepth = loopDepth
            positional = arguments
            loopDepth = 0
            functionDepth += 1
            localScopes.append([:])
            execList(body) {
                if let scope = self.localScopes.popLast() {
                    for (name, saved) in scope { self.restoreVariable(name, saved) }
                }
                self.functionDepth -= 1
                self.loopDepth = savedLoopDepth
                self.positional = savedPositional
                if self.flow == .returning { self.flow = .none }
                done()
            }
        }

        /// Replace `%job` arguments with the job's process ids; `nil` (after an
        /// error message) when a spec names no job.
        private func expandJobSpecs(_ argv: [String]) -> [String]? {
            var out: [String] = []
            for argument in argv {
                guard argument.hasPrefix("%") else { out.append(argument); continue }
                guard let id = jobs.id(forSpec: argument), let job = jobs.job(id: id) else {
                    err("\(argv[0]): \(argument): no such job\n")
                    status.last = 1
                    return nil
                }
                out += job.pids.sorted().map { String($0) }
            }
            return out
        }

        // MARK: - Traps

        /// Run the actions of any trapped signals that arrived since the last
        /// command. Traps run between commands, never inside one.
        func runPendingTraps(_ done: @escaping () -> Void) {
            // Ctrl-C while the interactive shell itself is running (a builtin
            // loop, a function): abandon the rest of the command line.
            if interactive, ctx.takeTerminalLineInterrupt(0) {
                status.last = 130
                flow = .abort
                done()
                return
            }
            guard !pendingTraps.isEmpty, !runningTrap else { done(); return }
            let names = pendingTraps
            pendingTraps.removeAll()
            runningTrap = true
            let savedStatus = status.last
            var index = 0
            drive({ next in
                guard index < names.count else { next(false); return }
                let action = self.traps[names[index]] ?? ""
                index += 1
                if action.isEmpty { next(true) } else { self.runText(action) { next(true) } }
            }, done: {
                self.runningTrap = false
                self.status.last = savedStatus
                done()
            })
        }
    }
}
