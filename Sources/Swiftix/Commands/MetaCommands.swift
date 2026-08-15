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
            // which NAME... — report whether each name resolves to a command.
            // Exits 1 if any name is unresolved.
            Command(name: "which", summary: "locate a command by name", category: .system) { ctx, argv in
                let names = Array(argv.dropFirst())
                guard !names.isEmpty else { ctx.usage("which", "which <name>..."); return }
                var status: Int32 = 0
                for name in names {
                    if let command = ctx.resolveCommand(name) {
                        ctx.print(command.name.contains("/") ? command.name + "\n" : "/bin/\(name)\n")
                    } else {
                        status = 1
                    }
                }
                ctx.exit(status)
            },

            // man NAME — show a command's manual page, synthesized from the live
            // command registry (its name, one-line summary, and category). There
            // are no on-disk man pages; this makes the built-in set self-documenting
            // so a learner can look a command up without leaving the shell.
            Command(name: "man", summary: "show a command's manual page", category: .system) { ctx, argv in
                guard argv.count > 1 else {
                    ctx.usage("man", "man <command>"); return
                }
                let name = argv[1]
                guard let command = ctx.resolveCommand(name) else {
                    ctx.fail("man: no manual entry for \(name)", code: 1); return
                }
                var page = "NAME\n    \(command.name) - \(command.summary)\n\n"
                page += "DESCRIPTION\n    \(command.summary).\n\n"
                page += "SECTION\n    \(command.category.title)\n"
                ctx.print(page)
                ctx.exit(0)
            },

            // type NAME... — describe how each name would be interpreted.
            Command(name: "type", summary: "describe a command name", category: .system) { ctx, argv in
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

            // xargs CMD [args...] — read stdin, split on whitespace, and run CMD
            // once with those words appended to its argument list.
            Command(name: "xargs", summary: "build a command line from stdin", category: .process, asyncRun: { ctx, argv in
                let base = Array(argv.dropFirst())
                guard let name = base.first else {
                    ctx.usage("xargs", "xargs <command> [args...]"); return
                }
                guard let command = ctx.resolveCommand(name) else {
                    ctx.fail("xargs: \(name): command not found", code: 127); return
                }
                var data: [UInt8] = []
                while let chunk = try? await ctx.read(0), !chunk.isEmpty { data.append(contentsOf: chunk) }
                let words = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
                    .map(String.init)
                ctx.run(command, args: base + words)
                if let event = try? await ctx.wait() {
                    ctx.exit(event.status.code)
                } else {
                    ctx.exit(0)
                }
            }),

            // timeout SECONDS CMD [args...] — run CMD, terminating it (SIGTERM) if
            // it has not finished within SECONDS. Exits with the command's code, or
            // 124 if it was timed out (GNU coreutils convention).
            Command(name: "timeout", summary: "run a command with a time limit", category: .process) { ctx, argv in
                guard argv.count >= 3, let seconds = Double(argv[1]) else {
                    ctx.usage("timeout", "timeout <seconds> <command> [args...]"); return
                }
                let commandArgs = Array(argv.dropFirst(2))
                guard let command = ctx.resolveCommand(commandArgs[0]) else {
                    ctx.fail("timeout: \(commandArgs[0]): command not found", code: 127); return
                }
                let child = ctx.run(command, args: commandArgs)
                // A one-shot flag shared between the timer and the waiter. The
                // timer fires on the loop; if the child is still running it sends
                // SIGTERM. If the child finished first, `done` makes the timer a
                // no-op (there is no timer cancellation).
                let timedOut = FlagBox()
                let done = FlagBox()
                ctx.sleep(seconds) {
                    if !done.value {
                        timedOut.value = true
                        ctx.kill(child, signal: Signal.sigterm.rawValue)
                    }
                }
                ctx.wait { result in
                    done.value = true
                    switch result {
                    case .success(let event):
                        ctx.exit(timedOut.value ? 124 : event.status.code)
                    case .failure:
                        ctx.exit(timedOut.value ? 124 : 1)
                    }
                }
            },

            // su UID CMD [args...] — run CMD as user UID (a simplified `su`: no
            // password, credentials are numeric since there is no /etc/passwd).
            // This is the privilege-drop primitive that makes file permissions
            // demonstrable: `su 1000 cat /root/secret` hits EACCES when the file
            // is not readable by uid 1000.
            Command(name: "su", summary: "run a command as another user (by uid)", category: .system) { ctx, argv in
                let args = Array(argv.dropFirst())
                guard args.count >= 2, let uid = UInt32(args[0]) else {
                    ctx.usage("su", "su <uid> <command> [args...]"); return
                }
                let commandArgs = Array(args.dropFirst())
                guard let command = ctx.resolveCommand(commandArgs[0]) else {
                    ctx.fail("su: \(commandArgs[0]): command not found", code: 127); return
                }
                // Drop to the target credentials in the child before its body runs.
                switch command.body {
                case let .sync(body):
                    let wrapped = Command(name: command.name, summary: command.summary, category: command.category) { child, childArgs in
                        child.setgid(uid); child.setuid(uid)
                        body(child, childArgs)
                    }
                    ctx.run(wrapped, args: commandArgs)
                case let .async(body):
                    ctx.spawn(commandArgs[0], args: commandArgs) { (child: ProcessContext) async in
                        child.setgid(uid); child.setuid(uid)
                        await body(child, commandArgs)
                    }
                }
                ctx.wait { result in
                    switch result {
                    case .success(let event): ctx.exit(event.status.code)
                    case .failure: ctx.exit(1)
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
            Command(name: "unshare", summary: "run a command in new namespaces", category: .system) { ctx, argv in
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
            Command(name: "nsenter", summary: "run a command in another process's namespaces", category: .system) { ctx, argv in
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
            Command(name: "nohup", summary: "run a command immune to interrupts", category: .process) { ctx, argv in
                let commandArgs = Array(argv.dropFirst())
                guard let name = commandArgs.first else {
                    ctx.usage("nohup", "nohup <command> [args...]"); return
                }
                guard let command = ctx.resolveCommand(name) else {
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
