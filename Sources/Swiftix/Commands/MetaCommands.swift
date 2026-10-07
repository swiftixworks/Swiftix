/// "Meta" programs: commands that resolve and/or launch *other* commands. They
/// are the reason `ProcessContext` gained a command-table seam
/// (`resolveCommand` / `run(_:args:)` / `commandNames`, backed by
/// `Kernel.commandRegistry`): unlike a plain filter, these need to see the set
/// of runnable programs and spawn one.
///
/// They join `CommandRegistry.builtins` via `BuiltinCommands.all()`. All run on
/// the single loop-bound executor like the rest of the core.
extension BuiltinCommands {

    static func metaCommands() -> [Command] {
        [
            // which [-a] NAME... — report where each name resolves: an executable
            // found on $PATH, or a built-in (shown under /bin, where the built-in
            // set conceptually lives). Exits 1 if any name is unresolved.
            Command(name: "which", summary: "locate a command by name", category: .system,
                    usage: """
                    which [-a] NAME...
                      -a  print all matches on $PATH (and the built-in), not just the first
                    """) { ctx, argv in
                guard let parsed = ctx.options("which", Array(argv.dropFirst()), "as") else { return }
                guard !parsed.operands.isEmpty else { ctx.usage("which", "which [-a] <name>..."); return }
                var status: Int32 = 0
                for name in parsed.operands {
                    var found: [String] = []
                    if name.contains("/") {
                        if ctx.canExecute(name) { found.append(name) }
                    } else {
                        let path = ctx.getenv("PATH") ?? ProcessContext.defaultExecutablePath
                        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
                            let candidate = directory.isEmpty ? name : ctx.join(String(directory), name)
                            if ctx.canExecute(candidate), !found.contains(candidate) { found.append(candidate) }
                        }
                        // A built-in answers when nothing on $PATH shadows it.
                        let builtin = "/bin/\(name)"
                        if ctx.kernel.commandRegistry?.resolve(name) != nil, !found.contains(builtin) {
                            found.append(builtin)
                        } else if found.isEmpty, let command = ctx.resolveCommand(name) {
                            found.append(command.name.contains("/") ? command.name : builtin)
                        }
                    }
                    if found.isEmpty { status = 1; continue }
                    if !parsed.has("s") {
                        ctx.print((parsed.has("a") ? found : Array(found.prefix(1))).joined(separator: "\n") + "\n")
                    }
                }
                ctx.exit(status)
            },

            // man NAME — show a command's manual page, synthesized from the live
            // command registry: name and summary, the synopsis, and the option
            // list from the command's `usage` text. There are no on-disk man
            // pages; this makes the built-in set self-documenting so a learner
            // can look a command up without leaving the shell.
            Command(name: "man", summary: "show a command's manual page", category: .system,
                    usage: "man COMMAND\nShow the manual page of a command: synopsis, description, options.",
                    asyncRun: { ctx, argv in
                guard let parsed = ctx.options("man", Array(argv.dropFirst()), "k") else { return }
                guard let name = parsed.operands.last else {
                    ctx.error("What manual page do you want?\nFor example, try 'man man'.")
                    ctx.exit(1)
                    return
                }
                guard var command = ctx.resolveCommand(name) else {
                    ctx.fail("man: no manual entry for \(name)", code: 16); return
                }
                // A file on $PATH carries no help text; the built-in of the same
                // name documents the same interface.
                if command.usage == nil, let builtin = ctx.kernel.commandRegistry?.resolve(baseName(name)) {
                    command = builtin
                }
                let title = baseName(command.name)
                var page = "NAME\n    \(title) - \(command.summary)\n\n"
                page += "SYNOPSIS\n"
                // A synopsis may list several forms, one per line, each starting
                // with the command name.
                var optionLines: [Substring] = []
                var inSynopsis = true
                for line in (command.usage ?? command.synopsis).split(separator: "\n", omittingEmptySubsequences: false) {
                    if inSynopsis, line.hasPrefix(title + " ") || line == title {
                        page += "    \(line)\n"
                    } else {
                        inSynopsis = false
                        optionLines.append(line)
                    }
                }
                page += "\nDESCRIPTION\n    \(command.summary.prefix(1).uppercased() + command.summary.dropFirst()).\n"
                if !optionLines.isEmpty {
                    page += "\nOPTIONS\n"
                    for line in optionLines { page += line.isEmpty ? "\n" : "    \(line)\n" }
                }
                page += "\nSECTION\n    \(command.category.title)\n"
                await ctx.emit(page, exit: 0)
            }),

            // type NAME... — describe how each name would be interpreted.
            Command(name: "type", summary: "describe a command name", category: .system,
                    usage: "type NAME...") { ctx, argv in
                let names = Array(argv.dropFirst())
                guard !names.isEmpty else { ctx.usage("type", "type <name>..."); return }
                var status: Int32 = 0
                for name in names {
                    if let command = ctx.resolveCommand(name) {
                        if command.name.contains("/") {
                            ctx.print("\(name) is \(command.name)\n")
                        } else {
                            ctx.print("\(name) is a builtin\n")
                        }
                    } else {
                        ctx.print("\(name): not found\n")
                        status = 1
                    }
                }
                ctx.exit(status)
            },

            // xargs [-n N] [-I REPL] [-0] [-d DELIM] [-t] [-r] [CMD [args...]] — read
            // items from stdin and run CMD (default `echo`) with them appended to
            // its arguments: all at once, `-n N` at a time, or once per line with
            // `-I REPL` substituting the line for REPL.
            Command(name: "xargs", summary: "build and run command lines from stdin", category: .process,
                    usage: """
                    xargs [-n MAX] [-I REPLACE] [-0] [-d DELIM] [-t] [-r] [COMMAND [ARG]...]
                      -n MAX      use at most MAX arguments per command line
                      -I REPLACE  run once per input line, replacing REPLACE in the ARGs
                      -0          input items are terminated by NUL, not whitespace
                      -d DELIM    input items are terminated by DELIM
                      -t          print each command line on stderr before running it
                      -r          do not run the command if the input is empty
                    Exit status is 123 if any invocation failed, 127 if COMMAND is not found.
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("xargs", Array(argv.dropFirst()), "n:I:0d:trL:P:xs:",
                                               long: ["max-args": "n", "null": "0", "delimiter": "d",
                                                      "verbose": "t", "no-run-if-empty": "r"],
                                               stopAtOperand: true) else { return }
                let base = parsed.operands.isEmpty ? ["echo"] : parsed.operands
                guard let command = ctx.resolveCommand(base[0]) else {
                    ctx.fail("xargs: \(base[0]): \(SyscallError.noSuchFileOrDirectory.message)", code: 127); return
                }
                var batchSize: Int? = nil
                if let text = parsed.value("n") ?? parsed.value("L") {
                    guard let value = Int(text), value > 0 else {
                        ctx.fail("xargs: invalid number \"\(text)\" for -n option", code: 1); return
                    }
                    batchSize = value
                }
                let data = (await readInput(ctx, cmd: "xargs", files: [])).data
                let text = String(decoding: data, as: UTF8.self)
                let replace = parsed.value("I")
                var items: [String]
                if parsed.has("0") {
                    items = text.split(separator: "\0").map(String.init)
                } else if let delimiter = parsed.value("d") {
                    let expanded = BuiltinCommands.text(expandEscapes(delimiter, octalNeedsZero: false).bytes)
                    items = text.split(separator: expanded.first ?? "\n", omittingEmptySubsequences: false).map(String.init)
                    if items.last == "" || items.last == "\n" { items.removeLast() }
                } else if replace != nil {
                    items = text.split(separator: "\n").map { $0.drop(while: { $0 == " " || $0 == "\t" }) }.map(String.init)
                } else {
                    items = xargsWords(text)
                }
                var batches: [[String]]
                if let replace {
                    batches = items.map { item in base.map { $0.replacing(replace, with: item) } }
                } else if let batchSize {
                    batches = stride(from: 0, to: items.count, by: batchSize).map {
                        base + items[$0..<min($0 + batchSize, items.count)]
                    }
                } else {
                    batches = [base + items]
                }
                if items.isEmpty { batches = parsed.has("r") || replace != nil ? [] : [base] }
                var status: Int32 = 0
                for words in batches {
                    if parsed.has("t") { ctx.error(words.joined(separator: " ")) }
                    ctx.run(command, args: words)
                    guard let event = try? await ctx.wait() else { return }
                    if event.status.code == 255 {
                        ctx.fail("xargs: \(base[0]): exited with status 255; aborting", code: 124); return
                    }
                    if event.status.code != 0 { status = 123 }
                }
                ctx.exit(status)
            }),

            // timeout [-s SIGNAL] [-k DURATION] DURATION CMD [args...] — run CMD,
            // sending it SIGNAL (default TERM) if it has not finished within
            // DURATION. Exits with the command's code, or 124 if it timed out
            // (GNU coreutils convention).
            Command(name: "timeout", summary: "run a command with a time limit", category: .process,
                    usage: """
                    timeout [-s SIGNAL] [-k DURATION] DURATION COMMAND [ARG]...
                      -s SIGNAL    signal to send on timeout (name or number; default TERM)
                      -k DURATION  also send KILL if COMMAND is still running this long after
                    DURATION is a number with an optional suffix: s, m, h, or d.
                    """) { ctx, argv in
                guard let parsed = ctx.options("timeout", Array(argv.dropFirst()), "s:k:vf",
                                               long: ["signal": "s", "kill-after": "k",
                                                      "preserve-status": "f"],
                                               stopAtOperand: true) else { return }
                func duration(_ text: String) -> Double? {
                    var body = Substring(text)
                    var scale = 1.0
                    if let unit = body.last, unit.isLetter {
                        switch unit {
                        case "s": scale = 1
                        case "m": scale = 60
                        case "h": scale = 3600
                        case "d": scale = 86400
                        default: return nil
                        }
                        body = body.dropLast()
                    }
                    guard let value = Double(body), value >= 0 else { return nil }
                    return value * scale
                }
                guard parsed.operands.count >= 2 else {
                    ctx.usage("timeout", "timeout [-s signal] <seconds> <command> [args...]", code: 125); return
                }
                guard let seconds = duration(parsed.operands[0]) else {
                    ctx.fail("timeout: invalid time interval '\(parsed.operands[0])'", code: 125); return
                }
                var signal = Signal.sigterm.rawValue
                if let text = parsed.value("s") {
                    guard let named = signalNumber(forName: text) else {
                        ctx.fail("timeout: \(text): invalid signal", code: 125); return
                    }
                    signal = named
                }
                var killAfter: Double? = nil
                if let text = parsed.value("k") {
                    guard let value = duration(text) else {
                        ctx.fail("timeout: invalid time interval '\(text)'", code: 125); return
                    }
                    killAfter = value
                }
                let requested = Array(parsed.operands.dropFirst())
                guard let (command, commandArgs) = resolveProgram(ctx, requested) else {
                    ctx.fail("timeout: failed to run command '\(requested[0])': "
                             + SyscallError.noSuchFileOrDirectory.message, code: 127); return
                }
                let child = ctx.run(command, args: commandArgs)
                // A one-shot flag shared between the timer and the waiter. The
                // timer fires on the loop; if the child is still running it sends
                // the signal. If the child finished first, `done` makes the timer a
                // no-op (there is no timer cancellation).
                let timedOut = FlagBox()
                let done = FlagBox()
                if seconds > 0 {
                    ctx.sleep(seconds) {
                        guard !done.value else { return }
                        timedOut.value = true
                        ctx.kill(child, signal: signal)
                        if let killAfter {
                            ctx.sleep(killAfter) {
                                if !done.value { ctx.kill(child, signal: Signal.sigkill.rawValue) }
                            }
                        }
                    }
                }
                ctx.wait { result in
                    done.value = true
                    switch result {
                    case .success(let event):
                        ctx.exit(timedOut.value && !parsed.has("f") ? 124 : event.status.code)
                    case .failure:
                        ctx.exit(timedOut.value ? 124 : 1)
                    }
                }
            },

            // su [-] [USER] [-c COMMAND] / su USER COMMAND [ARG]... — run a shell
            // or a command as another user (default root). There are no
            // passwords: root may become anyone, anyone else only themselves.
            // USER is a login name or a numeric uid, resolved through the user
            // database. This is the privilege-drop primitive that makes file
            // permissions demonstrable: `su 1000 cat /root/secret` hits EACCES
            // when the file is not readable by uid 1000.
            Command(name: "su", summary: "run a shell or command as another user", category: .system,
                    usage: """
                    su [-] [USER] [-c COMMAND]
                    su USER COMMAND [ARG]...
                      -, -l       start a login shell: reset HOME, USER, LOGNAME, SHELL and
                                  change to the user's home directory
                      -c COMMAND  run COMMAND with sh -c instead of an interactive shell
                    USER is a login name or a numeric uid (default: root).
                    """) { ctx, argv in
                var args = Array(argv.dropFirst())
                var login = false
                var commandString: String?
                var userSpec: String?
                var direct: [String] = []
                while !args.isEmpty {
                    let arg = args.removeFirst()
                    if arg == "-" || arg == "-l" || arg == "--login" {
                        login = true
                    } else if arg == "-c" || arg == "--command" {
                        guard !args.isEmpty else {
                            ctx.fail("su: option requires an argument -- 'c'"); return
                        }
                        commandString = args.removeFirst()
                    } else if arg.hasPrefix("--command=") {
                        commandString = String(arg.dropFirst("--command=".count))
                    } else if arg == "--" {
                        if userSpec == nil, !args.isEmpty { userSpec = args.removeFirst() }
                        direct = args
                        args = []
                    } else if CommandArguments.isOptionToken(arg) {
                        ctx.error("su: invalid option -- '\(arg)'")
                        ctx.usage("su", "su [-] [USER] [-c COMMAND] | su USER COMMAND [ARG]..."); return
                    } else if userSpec == nil {
                        userSpec = arg
                    } else {
                        // `su USER COMMAND ARG…`: everything from here on is the
                        // command line, options included.
                        direct = [arg] + args
                        args = []
                    }
                }
                let database = ctx.userDatabase()
                guard let user = database.resolveUser(userSpec ?? "root") else {
                    ctx.fail("su: user \(userSpec ?? "root") does not exist", code: 1); return
                }
                guard ctx.getuid() == 0 || ctx.getuid() == user.uid else {
                    ctx.fail("su: Authentication failure", code: 1); return
                }
                let commandArgs: [String]
                if let commandString {
                    commandArgs = ["sh", "-c", commandString] + direct
                } else {
                    commandArgs = direct.isEmpty ? ["sh"] : direct
                }
                guard let command = ctx.resolveCommand(commandArgs[0]) else {
                    ctx.fail("su: \(commandArgs[0]): command not found", code: 127); return
                }
                // Switch credentials in the child before its body runs.
                runWithPreamble(ctx, command: command, args: commandArgs) { child in
                    child.switchUser(to: user, database: database, login: login)
                    if !login {
                        child.setenv("HOME", user.home)
                        child.setenv("USER", user.name)
                        child.setenv("LOGNAME", user.name)
                    }
                }
            },

            // unshare [-u|--uts] [-p|--pid] [-m|--mount] CMD [args...] — run CMD in
            // new namespace(s). `-u` detaches the child into a private UTS namespace
            // (its `hostname` changes stay invisible to the parent). `-p` runs CMD
            // in a new PID namespace as pid 1 (like `unshare --pid --fork`), so
            // inside it `ps`/`getpid` start at 1 and cannot see the host's
            // processes. `-m` gives CMD a private mount table (mounts it makes stay
            // invisible to the parent). Other flags are unsupported.
            Command(name: "unshare", summary: "run a command in new namespaces", category: .system,
                    usage: "unshare [-u] [-p] [-m] COMMAND [ARG]...\n  -u, --uts    new UTS (host name) namespace\n  -p, --pid    new PID namespace; COMMAND runs as its pid 1\n  -m, --mount  new mount namespace") { ctx, argv in
                var args = Array(argv.dropFirst())
                var newUTS = false
                var newPID = false
                var newMount = false
                while let first = args.first, CommandArguments.isOptionToken(first) {
                    if first == "--" { args.removeFirst(); break }
                    switch first {
                    case "-u", "--uts":
                        newUTS = true; args.removeFirst()
                    case "-p", "--pid":
                        newPID = true; args.removeFirst()
                    case "-m", "--mount":
                        newMount = true; args.removeFirst()
                    default:
                        ctx.error("unshare: unsupported option '\(first)' (only -u/--uts, -p/--pid, -m/--mount are modeled)")
                        ctx.exit(2); return
                    }
                }
                guard let name = args.first else {
                    ctx.usage("unshare", "unshare [-u] [-p] [-m] <command> [args...]"); return
                }
                guard let command = ctx.resolveCommand(name) else {
                    ctx.fail("unshare: \(name): command not found", code: 127); return
                }
                runWithPreamble(ctx, command: command, args: args, beforeSpawn: { parent in
                    // A new PID namespace is created for the next child (pid 1).
                    if newPID { parent.unsharePIDNamespace() }
                }, prepare: { child in
                    // UTS and mount namespaces detach in the child itself.
                    if newUTS { child.unshareUTS() }
                    if newMount { child.unshareMountNamespace() }
                })
            },

            // nsenter -t PID [-u|--uts] CMD [args...] — run CMD in the namespaces
            // of the target process. The child joins (shares) that process's UTS
            // namespace before its body runs, so it sees that host's hostname —
            // the counterpart to `unshare`. Only the UTS namespace is modeled.
            Command(name: "nsenter", summary: "run a command in another process's namespaces", category: .system,
                    usage: "nsenter -t PID [-u] COMMAND [ARG]...\n  -t PID     the process whose namespace to enter\n  -u, --uts  enter its UTS (host name) namespace") { ctx, argv in
                var args = Array(argv.dropFirst())
                var target: PID?
                var wantUTS = false
                while let first = args.first, CommandArguments.isOptionToken(first) {
                    if first == "--" { args.removeFirst(); break }
                    switch first {
                    case "-u", "--uts":
                        wantUTS = true; args.removeFirst()
                    case "-t", "--target":
                        args.removeFirst()
                        guard let raw = args.first, let pid = PID(raw) else {
                            ctx.fail("nsenter: -t requires a numeric PID"); return
                        }
                        target = pid; args.removeFirst()
                    default:
                        ctx.error("nsenter: unsupported option '\(first)' (only -t and -u/--uts are modeled)")
                        ctx.exit(2); return
                    }
                }
                guard let target else {
                    ctx.fail("nsenter: a target PID is required (-t PID)"); return
                }
                guard let name = args.first else {
                    ctx.usage("nsenter", "nsenter -t PID [-u] <command> [args...]"); return
                }
                guard let command = ctx.resolveCommand(name) else {
                    ctx.fail("nsenter: \(name): command not found", code: 127); return
                }
                // The UTS namespace is the only modeled one, so `-u` is accepted
                // but the join happens regardless (there is nothing else to enter).
                _ = wantUTS
                runWithPreamble(ctx, command: command, args: args) { child in
                    child.enterUTSNamespace(ofPID: target)
                }
            },

            // nohup CMD [args...] — run CMD ignoring interrupt signals, then exit
            // with its status. (There is no SIGHUP in the model; this makes the
            // child immune to Ctrl-C so it keeps running like `nohup`.)
            Command(name: "nohup", summary: "run a command immune to interrupts", category: .process,
                    usage: "nohup COMMAND [ARG]...") { ctx, argv in
                let requested = Array(argv.dropFirst())
                guard let name = requested.first else {
                    ctx.usage("nohup", "nohup <command> [args...]"); return
                }
                guard let (command, commandArgs) = resolveProgram(ctx, requested) else {
                    ctx.fail("nohup: \(name): command not found", code: 127); return
                }
                // Wrap the command so the child installs an ignore handler for
                // SIGINT before running the real body.
                let ignoring = Command(name: command.name, summary: command.summary, category: command.category) { child, args in
                    child.signal(Signal.sigint.rawValue) { /* ignored */ }
                    switch command.body {
                    case let .sync(body): body(child, args)
                    case .async: break   // handled below
                    }
                }
                switch command.body {
                case .sync:
                    ctx.run(ignoring, args: commandArgs)
                case let .async(body):
                    ctx.spawn(name, args: commandArgs) { (child: ProcessContext) async in
                        child.signal(Signal.sigint.rawValue) { }
                        await body(child, commandArgs)
                    }
                }
                ctx.wait { result in
                    switch result {
                    case .success(let event):
                        ctx.exit(event.status.code)
                    case .failure:
                        ctx.exit(1)
                    }
                }
            },
        ]
    }

    /// Resolve the command line `words` for a meta-program (`time`, `env`,
    /// `timeout`, `nohup`): a registered command or an executable file as usual;
    /// a name only the shell can run (a builtin such as `cd` or `umask`) becomes
    /// `sh -c '<words>'`, so `time cd /` or `timeout 5 read x` still work.
    static func resolveProgram(_ ctx: ProcessContext, _ words: [String]) -> (command: Command, argv: [String])? {
        guard let name = words.first else { return nil }
        if let command = ctx.resolveCommand(name) { return (command, words) }
        guard Programs.ShellInterpreter.builtinNames.contains(name),
              let shell = ctx.resolveCommand("sh") else { return nil }
        let line = words.map(Programs.ShellInterpreter.quoted).joined(separator: " ")
        return (shell, ["sh", "-c", line])
    }

    /// Run `command` as a child of `ctx`, invoking `prepare(child)` *before* the
    /// child's body runs, then wait for it and exit with its status. Handles both
    /// sync and async command bodies. This is the shared spine of the "wrap and
    /// run" meta-programs (`unshare`, `nsenter`): they differ only in the preamble
    /// they run in the child (unshare a namespace, enter another's).
    static func runWithPreamble(_ ctx: ProcessContext,
                                command: Command,
                                args: [String],
                                beforeSpawn: (ProcessContext) -> Void = { _ in },
                                prepare: @escaping (ProcessContext) -> Void) {
        // `beforeSpawn` runs on the *parent* (this command's process) before the
        // child is created — needed for `unshare(CLONE_NEWPID)`, which affects the
        // next child, not the caller. `prepare` runs in the child before its body.
        beforeSpawn(ctx)
        switch command.body {
        case let .sync(body):
            let wrapped = Command(name: command.name, summary: command.summary, category: command.category) { child, childArgs in
                prepare(child)
                body(child, childArgs)
            }
            ctx.run(wrapped, args: args)
        case let .async(body):
            ctx.spawn(args[0], args: args) { (child: ProcessContext) async in
                prepare(child)
                await body(child, args)
            }
        }
        ctx.wait { result in
            switch result {
            case .success(let event): ctx.exit(event.status.code)
            case .failure: ctx.exit(1)
            }
        }
    }

    /// Split `xargs` input into words: whitespace-separated, with single quotes,
    /// double quotes, and backslash protecting the next character(s).
    static func xargsWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character? = nil
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if let open = quote {
                if c == open { quote = nil } else { current.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c
                inWord = true
            } else if c == "\\", let next = chars.popFirst() {
                current.append(next)
                inWord = true
            } else if c == " " || c == "\t" || c == "\n" || c == "\r" {
                if inWord { words.append(current); current = ""; inWord = false }
            } else {
                current.append(c)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// A boxed boolean for sharing one-shot state between a timer callback and a
    /// wait callback (both run on the loop; single-threaded, no lock needed).
    final class FlagBox { var value = false }

    /// Parse a `NAME=VALUE` token (NAME a valid shell identifier), or `nil`. Used
    /// by `env` to peel leading assignments.
    static func envAssignment(_ token: String) -> (name: String, value: String)? {
        guard let eq = token.firstIndex(of: "=") else { return nil }
        let name = String(token[token.startIndex..<eq])
        guard let first = name.first, first.isLetter || first == "_",
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return (name, String(token[token.index(after: eq)...]))
    }
}
