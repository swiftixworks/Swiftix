/// Shell entry points: the interactive login shell (`Programs.shell`), the
/// interactive read/parse/execute loop, and the non-interactive front ends used
/// by the `sh` command and by directly executed script files. Lexing, parsing,
/// expansion, the AST interpreter, builtins, and process launching live in
/// focused `Shell/` siblings.
///
/// Concurrency: everything here runs on the kernel's single serial executor, in
/// continuation-passing style over the parked `ProcessContext` syscalls.
extension Programs {

    public static func shell(tty: PseudoTerminal.Slave,
                             commands: CommandRegistry = .builtins) -> (ProcessContext) -> Void {
        { ctx in
            // The shell owns fd 0/1/2 = the terminal; every command it launches
            // inherits them (POSIX descriptor inheritance), so a plain command
            // needs no per-child wiring — only redirection / pipes override them.
            ctx.installStandardIO(tty)
            let freshLogin = ctx.getenv("HOME") == nil
            // Identity defaults come from the user database (`/etc/passwd`, with
            // the synthetic root / userN fallback), like every other tool.
            let user = ctx.userDatabase().user(uid: ctx.getuid())
            if ctx.getenv("HOME") == nil { ctx.setenv("HOME", user.home) }
            if ctx.getenv("USER") == nil { ctx.setenv("USER", user.name) }
            if ctx.getenv("LOGNAME") == nil { ctx.setenv("LOGNAME", ctx.getenv("USER") ?? user.name) }
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
            ShellInterpreter(ctx).runInteractive()
        }
    }

    /// The body of the `sh` command: `sh [-eux] FILE [ARG…]`, `sh -c STRING
    /// [NAME [ARG…]]`, or — with no script — an interactive shell on a
    /// terminal, otherwise the script read from standard input.
    static func runShellCommand(_ ctx: ProcessContext, _ argv: [String]) {
        let shell = ShellInterpreter(ctx)
        var arguments = Array(argv.dropFirst())
        var commandString = false
        while let first = arguments.first, first.hasPrefix("-"), first.count > 1 {
            arguments.removeFirst()
            if first == "--" { break }
            for flag in first.dropFirst() {
                switch flag {
                case "c": commandString = true
                case "e": shell.errexit = true
                case "u": shell.nounset = true
                case "x": shell.xtrace = true
                case "s", "i", "l": break
                default:
                    ctx.write(2, Array("sh: -\(flag): invalid option\n".utf8))
                    ctx.exit(2)
                    return
                }
            }
        }
        if commandString {
            guard let text = arguments.first else {
                ctx.write(2, Array("sh: -c: option requires an argument\n".utf8))
                ctx.exit(2)
                return
            }
            arguments.removeFirst()
            if let name = arguments.first {
                shell.scriptName = name
                arguments.removeFirst()
            }
            shell.positional = arguments
            shell.runText(text) { shell.exitShell(shell.status.last) }
            return
        }
        if let path = arguments.first {
            guard let text = shell.readFile(path) else {
                ctx.write(2, Array("sh: \(path): No such file or directory\n".utf8))
                ctx.exit(127)
                return
            }
            shell.scriptName = path
            shell.positional = Array(arguments.dropFirst())
            shell.runText(text) { shell.exitShell(shell.status.last) }
            return
        }
        if ctx.isATTY(0) {
            shell.runInteractive()
            return
        }
        guard ctx.fileAccessMode(0)?.canRead == true else { ctx.exit(0); return }
        // A script on standard input: read it all, then run it.
        var data: [UInt8] = []
        drive({ next in
            ctx.read(0, max: 65_536) { chunk in
                data.append(contentsOf: chunk)
                next(!chunk.isEmpty)
            }
        }, done: {
            shell.runText(String(decoding: data, as: UTF8.self)) { shell.exitShell(shell.status.last) }
        })
    }

    /// Run the script file at `path` in process `ctx` (a directly executed
    /// script: `./x.sh arg`), with `$0` = `path` and `$1…` = `arguments`.
    static func runShellScript(_ ctx: ProcessContext, path: String, arguments: [String]) {
        let shell = ShellInterpreter(ctx)
        guard let text = shell.readFile(path) else {
            ctx.write(2, Array("sh: \(path): No such file or directory\n".utf8))
            ctx.exit(127)
            return
        }
        shell.scriptName = path
        shell.positional = arguments
        shell.runText(text) { shell.exitShell(shell.status.last) }
    }
}

extension Programs.ShellInterpreter {

    /// Become an interactive shell on fd 0: prompt, read a (possibly
    /// multi-line) command, run it, repeat until end of input or `exit`.
    func runInteractive() {
        interactive = true
        jobControl = true
        // An interactive shell survives Ctrl-C: a nested shell is its parent's
        // foreground job and would otherwise take SIGINT's default action. The
        // keypress itself reaches the prompt through the terminal (see
        // `readCommand`). `trap … INT` replaces this handler.
        ctx.signal(Signal.sigint.rawValue) {}
        prompt()
        readLoop()
    }

    private func displayedDirectory() -> String {
        let directory = ctx.currentDirectory
        guard let home = ctx.getenv("HOME") else { return directory }
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory
    }

    private func prompt() {
        let user = ctx.getenv("USER") ?? ctx.userName
        let marker = ctx.getuid() == 0 ? "#" : "$"
        let text = "\(user)@\(ctx.hostname):\(displayedDirectory())\(marker) "
        // A Ctrl-C that was meant for the command that just finished must not
        // interrupt the line about to be read.
        _ = ctx.takeTerminalLineInterrupt(0)
        ctx.setTerminalLinePrompt(0, text)
        out(text)
    }

    private func readLoop() {
        Programs.drive({ next in
            // Safety net: a full-screen program or pager may have switched the
            // tty to raw mode. The shell always reads cooked, line-edited input,
            // so restore canonical mode before prompting — just as a real shell
            // resets the terminal when it regains the foreground. A no-op when
            // already cooked.
            self.ctx.setTerminalRawMode(0, false)
            self.readCommand(accumulated: "") { text in
                guard let text else {
                    self.exitShell(0)               // end of input (Ctrl-D)
                    return
                }
                self.reapBackground()
                let entry = text.split(separator: "\n", omittingEmptySubsequences: true).joined(separator: "\n")
                if !entry.isEmpty { self.history.append(entry) }
                // Reject a malformed line as a whole before running any of it.
                guard Programs.parseScript(Programs.lex(text), alias: { self.aliases[$0] }) != nil else {
                    self.err("sh: syntax error\n")
                    self.status.last = 2
                    self.prompt()
                    next(true)
                    return
                }
                self.runText(text) {
                    self.flow = .none
                    self.prompt()
                    next(true)
                }
            }
        }, done: {})
    }

    /// Accumulate terminal input until the shell parser considers it complete.
    /// `nil` is canonical EOF (Ctrl-D on an empty line).
    private func readCommand(accumulated: String, done: @escaping (String?) -> Void) {
        guard ctx.fileAccessMode(0)?.canRead == true else { done(nil); return }
        ctx.read(0) { line in
            guard !line.isEmpty else {
                if self.ctx.takeTerminalLineInterrupt(0) {
                    // Ctrl-C: drop the line (and any unfinished command) and
                    // start over at a fresh prompt.
                    self.status.last = 130
                    done("")
                } else if accumulated.isEmpty {
                    done(nil)
                } else {
                    // Ctrl-D inside an unfinished command abandons it instead
                    // of leaving the shell: the way out of a continuation prompt.
                    self.err("sh: syntax error: unexpected end of file\n")
                    self.status.last = 2
                    done("")
                }
                return
            }
            let text = accumulated + String(decoding: line, as: UTF8.self)
            if Programs.isComplete(text) {
                done(text)
            } else {
                self.ctx.setTerminalLinePrompt(0, "> ")
                self.out("> ")
                self.readCommand(accumulated: text, done: done)
            }
        }
    }
}
