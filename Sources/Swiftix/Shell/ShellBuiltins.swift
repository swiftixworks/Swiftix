/// The shell's builtin commands — the ones that must run inside the shell
/// process because they read or change its state (variables, options,
/// positional parameters, control flow, jobs, traps, descriptors).
///
/// Concurrency: extension of the executor-confined `ShellInterpreter`; each
/// builtin sets `$?` and calls its continuation exactly once, except those that
/// end the shell process.
extension Programs.ShellInterpreter {

    /// POSIX "special" builtins: a function may not shadow them.
    static let specialBuiltinNames: Set<String> = [
        ":", ".", "break", "continue", "eval", "exec", "exit", "export", "return",
        "set", "shift", "trap", "unset",
    ]

    /// Every name the shell runs itself rather than resolving as a program.
    static let builtinNames: Set<String> = specialBuiltinNames.union([
        "alias", "bg", "cd", "command", "fg", "history", "jobs", "local", "read",
        "source", "type", "umask", "unalias", "wait",
    ])

    /// One-line synopsis per builtin, printed by `BUILTIN --help` in the same
    /// `Usage: …` shape the registry commands use. `:` takes any arguments.
    static let builtinUsage: [String: String] = [
        ".": ". FILE [ARG]...", "source": "source FILE [ARG]...",
        "alias": "alias [NAME[=VALUE]]...", "unalias": "unalias [-a] NAME...",
        "bg": "bg [%JOB]", "fg": "fg [%JOB]", "jobs": "jobs",
        "break": "break [N]", "continue": "continue [N]",
        "cd": "cd [DIR|-]", "command": "command [-v] NAME [ARG]...",
        "eval": "eval [ARG]...", "exit": "exit [N]",
        "export": "export [-p] [NAME[=VALUE]]...", "history": "history [-c]",
        "local": "local NAME[=VALUE]...", "read": "read [-r] [-p PROMPT] [NAME]...",
        "return": "return [N]", "set": "set [-eux] [+eux] [-o OPTION] [--] [ARG]...",
        "shift": "shift [N]", "trap": "trap [ACTION] [SIGNAL]...", "type": "type NAME...",
        "umask": "umask [-S] [MODE]", "unset": "unset [-fv] NAME...", "wait": "wait [%JOB|PID]",
    ]

    func runBuiltin(_ argv: [String], done: @escaping () -> Void) {
        let arguments = Array(argv.dropFirst())
        if arguments.first == "--help", let usage = Self.builtinUsage[argv[0]] {
            out("Usage: \(usage)\n")
            status.last = 0
            done()
            return
        }
        switch argv[0] {
        case ":":
            status.last = 0
            done()
        case "cd":
            builtinChangeDirectory(arguments)
            done()
        case "export":
            builtinExport(arguments)
            done()
        case "unset":
            var unsetFunctions = false
            for argument in arguments {
                if argument == "-f" { unsetFunctions = true; continue }
                if argument == "-v" { unsetFunctions = false; continue }
                if unsetFunctions { functions[argument] = nil } else { unsetVariable(argument) }
            }
            status.last = 0
            done()
        case "alias":
            builtinAlias(arguments)
            done()
        case "unalias":
            status.last = 0
            for argument in arguments {
                if argument == "-a" { aliases.removeAll() }
                else if aliases.removeValue(forKey: argument) == nil {
                    err("unalias: \(argument): not found\n")
                    status.last = 1
                }
            }
            done()
        case "set":
            builtinSet(arguments)
            done()
        case "shift":
            let count = arguments.first.flatMap { Int($0) } ?? 1
            if count < 0 || count > positional.count {
                err("shift: shift count out of range\n")
                status.last = 1
            } else {
                positional.removeFirst(count)
                status.last = 0
            }
            done()
        case "local":
            builtinLocal(arguments)
            done()
        case "return":
            guard functionDepth > 0 || sourceDepth > 0 else {
                err("return: can only return from a function or sourced script\n")
                status.last = 1
                done()
                return
            }
            if let code = arguments.first.flatMap({ Int($0) }) { status.last = Int32(truncatingIfNeeded: code & 0xFF) }
            flow = .returning
            done()
        case "break", "continue":
            let levels = max(1, arguments.first.flatMap { Int($0) } ?? 1)
            status.last = 0
            if loopDepth > 0 {
                let bounded = min(levels, loopDepth)
                flow = argv[0] == "break" ? .breakLoop(bounded) : .continueLoop(bounded)
            }
            done()
        case "exit":
            let code = arguments.first.flatMap { Int($0) }.map { Int32(truncatingIfNeeded: $0 & 0xFF) }
            exitShell(code ?? status.last)
        case "eval":
            let text = arguments.joined(separator: " ")
            status.last = 0
            runText(text, done: done)
        case ".", "source":
            builtinSource(arguments, done: done)
        case "read":
            builtinRead(arguments, done: done)
        case "wait":
            builtinWait(arguments, done: done)
        case "trap":
            builtinTrap(arguments)
            done()
        case "history":
            if arguments.first == "-c" {
                history.removeAll()
            } else {
                for (index, line) in history.enumerated() {
                    let number = String(index + 1)
                    out(String(repeating: " ", count: max(0, 5 - number.count)) + number + "  " + line + "\n")
                }
            }
            status.last = 0
            done()
        case "jobs":
            for job in listedJobs {
                let state = job.stopped ? "Stopped" : "Running"
                out("[\(job.id)] \(state)\t\(job.command)\n")
            }
            status.last = 0
            done()
        case "fg":
            resumeJob(arguments, inBackground: false, done: done)
        case "bg":
            resumeJob(arguments, inBackground: true, done: done)
        case "type":
            builtinType(arguments)
            done()
        case "command":
            builtinCommand(arguments, done: done)
        case "umask":
            builtinUmask(arguments)
            done()
        default:
            err("sh: \(argv[0]): not a shell builtin\n")
            status.last = 1
            done()
        }
    }

    // MARK: - Directory and variables

    private func builtinChangeDirectory(_ arguments: [String]) {
        var target = arguments.first ?? (value(of: "HOME") ?? "/")
        var announce = false
        if target == "-" {
            guard let previous = value(of: "OLDPWD") else {
                err("cd: OLDPWD not set\n")
                status.last = 1
                return
            }
            target = previous
            announce = true
        }
        let previous = ctx.currentDirectory
        if ctx.chdir(target) {
            setVariable("OLDPWD", previous)
            setVariable("PWD", ctx.currentDirectory)
            if announce { out(ctx.currentDirectory + "\n") }
            status.last = 0
        } else {
            err("cd: \(target): No such directory\n")
            status.last = 1
        }
    }

    /// `umask [-S] [MODE]`: show or set the file-mode creation mask. MODE is
    /// octal (`027`) or symbolic (`u=rwx,g=rx,o=`), where the symbolic form
    /// names the permissions that stay *allowed*, as POSIX defines it.
    private func builtinUmask(_ arguments: [String]) {
        var symbolic = false
        var operands = arguments
        while let first = operands.first, first == "-S" || first == "-p" || first == "--" {
            if first == "-S" { symbolic = true }
            operands.removeFirst()
        }
        let current = ctx.fileCreationMask.rawValue & 0o777
        guard let operand = operands.first else {
            if symbolic {
                let allowed = ~current & 0o777
                func bits(_ shift: UInt16) -> String {
                    let value = (allowed >> shift) & 7
                    return (value & 4 != 0 ? "r" : "") + (value & 2 != 0 ? "w" : "") + (value & 1 != 0 ? "x" : "")
                }
                out("u=\(bits(6)),g=\(bits(3)),o=\(bits(0))\n")
            } else {
                let digits = String(current, radix: 8)
                out(String(repeating: "0", count: max(0, 4 - digits.count)) + digits + "\n")
            }
            status.last = 0
            return
        }
        guard let mask = Self.parseUmask(operand, current: current) else {
            err("umask: \(operand): invalid mode\n")
            status.last = 1
            return
        }
        ctx.umask(FileMode(rawValue: mask))
        status.last = 0
    }

    /// The mask an `umask` operand asks for, or `nil` when it is malformed.
    static func parseUmask(_ text: String, current: UInt16) -> UInt16? {
        if let first = text.first, first.isASCII, first.isNumber {
            guard text.count <= 4, let value = UInt16(text, radix: 8), value <= 0o777 else { return nil }
            return value
        }
        var allowed = ~current & 0o777
        for clause in text.split(separator: ",", omittingEmptySubsequences: false) {
            var who: UInt16 = 0
            var rest = Substring(clause)
            while let ch = rest.first, "ugoa".contains(ch) {
                switch ch {
                case "u": who |= 0o700
                case "g": who |= 0o070
                case "o": who |= 0o007
                default: who |= 0o777
                }
                rest.removeFirst()
            }
            if who == 0 { who = 0o777 }
            guard let op = rest.first, "+-=".contains(op) else { return nil }
            rest.removeFirst()
            var bits: UInt16 = 0
            for ch in rest {
                switch ch {
                case "r": bits |= 0o444
                case "w": bits |= 0o222
                case "x": bits |= 0o111
                default: return nil
                }
            }
            bits &= who
            switch op {
            case "+": allowed |= bits
            case "-": allowed &= ~bits
            default: allowed = (allowed & ~who) | bits
            }
        }
        return ~allowed & 0o777
    }

    private func builtinExport(_ arguments: [String]) {
        status.last = 0
        let names = arguments.filter { $0 != "-p" }
        if names.isEmpty {
            for (name, value) in ctx.environment.sorted(by: { $0.key < $1.key }) {
                out("export \(name)=\(Self.quoted(value))\n")
            }
            return
        }
        for token in names {
            if let pair = Programs.assignment(token) {
                exportVariable(pair.name, value: pair.value)
            } else if Programs.ScriptParser.isValidFunctionName(token) {
                exportVariable(token)
            } else {
                err("export: \(token): not a valid identifier\n")
                status.last = 1
            }
        }
    }

    /// A value in single quotes, safe to read back as shell input.
    static func quoted(_ value: String) -> String {
        "'" + value.split(separator: "'", omittingEmptySubsequences: false).joined(separator: "'\\''") + "'"
    }

    private func builtinAlias(_ arguments: [String]) {
        status.last = 0
        if arguments.isEmpty {
            for (name, value) in aliases.sorted(by: { $0.key < $1.key }) {
                out("alias \(name)=\(Self.quoted(value))\n")
            }
            return
        }
        for argument in arguments {
            if let eq = argument.firstIndex(of: "="), eq != argument.startIndex {
                aliases[String(argument[..<eq])] = String(argument[argument.index(after: eq)...])
            } else if let value = aliases[argument] {
                out("alias \(argument)=\(Self.quoted(value))\n")
            } else {
                err("alias: \(argument): not found\n")
                status.last = 1
            }
        }
    }

    private func builtinSet(_ arguments: [String]) {
        status.last = 0
        if arguments.isEmpty {
            var all = ctx.environment
            for (name, value) in variables { all[name] = value }
            for (name, value) in all.sorted(by: { $0.key < $1.key }) {
                out("\(name)=\(Self.quoted(value))\n")
            }
            return
        }
        func setOption(_ flag: Character, _ enabled: Bool) -> Bool {
            switch flag {
            case "e": errexit = enabled
            case "u": nounset = enabled
            case "x": xtrace = enabled
            case "f", "h", "m", "b", "a", "v", "n", "C": break      // accepted, not implemented
            default: return false
            }
            return true
        }
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                positional = Array(arguments[(index + 1)...])
                return
            }
            guard argument.count > 1, argument.hasPrefix("-") || argument.hasPrefix("+") else {
                positional = Array(arguments[index...])
                return
            }
            let enabled = argument.hasPrefix("-")
            if argument.dropFirst() == "o" {
                index += 1
                let name = index < arguments.count ? arguments[index] : ""
                let flag: Character? = ["errexit": "e", "nounset": "u", "xtrace": "x"][name]
                if let flag { _ = setOption(flag, enabled) }
                else {
                    err("set: \(name): invalid option name\n")
                    status.last = 2
                    return
                }
            } else {
                for flag in argument.dropFirst() where !setOption(flag, enabled) {
                    err("set: -\(flag): invalid option\n")
                    status.last = 2
                    return
                }
            }
            index += 1
        }
    }

    private func builtinLocal(_ arguments: [String]) {
        guard !localScopes.isEmpty else {
            err("local: can only be used in a function\n")
            status.last = 1
            return
        }
        status.last = 0
        for argument in arguments {
            let pair = Programs.assignment(argument)
            let name = pair?.name ?? argument
            guard Programs.ScriptParser.isValidFunctionName(name) else {
                err("local: \(argument): not a valid identifier\n")
                status.last = 1
                continue
            }
            if localScopes[localScopes.count - 1][name] == nil {
                localScopes[localScopes.count - 1][name] = saveVariable(name)
            }
            if let pair {
                setVariable(name, pair.value)
            } else if value(of: name) == nil {
                variables[name] = ""
            }
        }
    }

    // MARK: - Source files

    /// Read a whole file, or `nil` if it cannot be opened.
    func readFile(_ path: String) -> String? {
        guard ctx.stat(path)?.isDirectory == false, let fd = ctx.open(path) else { return nil }
        var data: [UInt8] = []
        while true {
            let chunk = ctx.read(fd, max: 65_536)
            if chunk.isEmpty { break }
            data.append(contentsOf: chunk)
        }
        ctx.close(fd)
        return String(decoding: data, as: UTF8.self)
    }

    private func builtinSource(_ arguments: [String], done: @escaping () -> Void) {
        guard let name = arguments.first else {
            err(".: filename argument required\n")
            status.last = 2
            done()
            return
        }
        var candidates = [name]
        if !name.contains("/") {
            let path = value(of: "PATH") ?? ""
            candidates = path.split(separator: ":").map { "\($0)/\(name)" } + [name]
        }
        guard let text = candidates.lazy.compactMap({ self.readFile($0) }).first else {
            err("sh: \(name): No such file or directory\n")
            status.last = 1
            if interactive { done() } else { exitShell(1) }
            return
        }
        let savedPositional = positional
        let overridePositional = arguments.count > 1
        if overridePositional { positional = Array(arguments.dropFirst()) }
        sourceDepth += 1
        status.last = 0
        runText(text) {
            self.sourceDepth -= 1
            if overridePositional { self.positional = savedPositional }
            if self.flow == .returning { self.flow = .none }
            done()
        }
    }

    // MARK: - read

    private func builtinRead(_ arguments: [String], done: @escaping () -> Void) {
        var raw = false
        var names: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-r" { raw = true }
            else if argument == "-p" {
                index += 1
                if index < arguments.count, ctx.isATTY(0) { err(arguments[index]) }
            } else if argument.hasPrefix("-"), argument.count > 1, names.isEmpty {
                // Other options are accepted and ignored.
            } else {
                names.append(argument)
            }
            index += 1
        }
        if names.isEmpty { names = ["REPLY"] }
        guard ctx.fileAccessMode(0)?.canRead == true else {
            for name in names { setVariable(name, "") }
            status.last = 1
            done()
            return
        }
        // One byte at a time, so nothing past the newline is consumed and the
        // next reader of fd 0 (the loop's next `read`, or a command) sees it.
        var line: [UInt8] = []
        var sawEOF = false
        var escaped = false
        Programs.drive({ next in
            self.ctx.read(0, max: 1) { chunk in
                guard let byte = chunk.first else { sawEOF = true; next(false); return }
                if !raw, escaped {
                    escaped = false
                    if byte != 0x0A { line.append(byte) }       // backslash-newline joins lines
                    next(true)
                } else if !raw, byte == 0x5C {
                    escaped = true
                    next(true)
                } else if byte == 0x0A {
                    next(false)
                } else {
                    line.append(byte)
                    next(true)
                }
            }
        }, done: {
            self.assignReadFields(String(decoding: line, as: UTF8.self), to: names)
            self.status.last = sawEOF ? 1 : 0
            done()
        })
    }

    /// Split a line on `$IFS` across `names`; the last name takes the rest.
    private func assignReadFields(_ text: String, to names: [String]) {
        let ifs = value(of: "IFS") ?? " \t\n"
        func isBlank(_ ch: Character) -> Bool { ifs.contains(ch) && (ch == " " || ch == "\t" || ch == "\n") }
        var chars = Array(text)
        while let first = chars.first, isBlank(first) { chars.removeFirst() }
        while let last = chars.last, isBlank(last) { chars.removeLast() }
        var position = 0
        for (index, name) in names.enumerated() {
            if index == names.count - 1 {
                setVariable(name, String(chars[position...]))
                break
            }
            var field = ""
            while position < chars.count, !ifs.contains(chars[position]) {
                field.append(chars[position]); position += 1
            }
            // Consume the delimiter: blanks, at most one non-blank, blanks.
            while position < chars.count, isBlank(chars[position]) { position += 1 }
            if position < chars.count, ifs.contains(chars[position]), !isBlank(chars[position]) {
                position += 1
                while position < chars.count, isBlank(chars[position]) { position += 1 }
            }
            setVariable(name, field)
        }
    }

    // MARK: - Jobs

    private func builtinWait(_ arguments: [String], done: @escaping () -> Void) {
        reapBackground()
        guard let spec = arguments.first else {
            // Wait for every running job.
            Programs.drive({ next in
                guard self.jobs.list().contains(where: { !$0.stopped }) else { next(false); return }
                self.ctx.waitEvent { result in
                    guard case .success(let event) = result else { next(false); return }
                    if event.status.isStopped { _ = self.jobs.markStopped(pid: event.childPID) }
                    else { self.noteExit(event) }
                    next(true)
                }
            }, done: {
                self.status.last = 0
                done()
            })
            return
        }
        let target: PID?
        if spec.hasPrefix("%") {
            target = jobs.id(forSpec: spec).flatMap { jobs.job(id: $0)?.lastPID }
        } else {
            target = PID(spec)
        }
        guard let pid = target else {
            err("wait: \(spec): no such job\n")
            status.last = 127
            done()
            return
        }
        Programs.drive({ next in
            if self.exitStatuses[pid] != nil || self.jobs.job(containing: pid) == nil { next(false); return }
            self.ctx.waitEvent { result in
                guard case .success(let event) = result else { next(false); return }
                if event.status.isStopped { _ = self.jobs.markStopped(pid: event.childPID) }
                else { self.noteExit(event) }
                next(true)
            }
        }, done: {
            self.status.last = self.exitStatuses.removeValue(forKey: pid) ?? 127
            done()
        })
    }

    /// `fg` / `bg`: resume the selected job in the foreground or background.
    private func resumeJob(_ arguments: [String], inBackground: Bool, done: @escaping () -> Void) {
        let name = inBackground ? "bg" : "fg"
        let jobID = arguments.first.map { jobs.id(forSpec: $0) } ?? jobs.list().last?.id
        guard let jobID, let job = jobs.job(id: jobID) else {
            err("\(name): no such job\n")
            status.last = 1
            done()
            return
        }
        for pid in job.pids {
            ctx.kill(pid, signal: Signal.sigcont.rawValue)
        }
        jobs.setRunning(id: jobID)
        if inBackground {
            out("[\(jobID)]\t\(job.command) &\n")
            status.last = 0
            done()
            return
        }
        backgroundPIDs.subtract(job.pids)
        ctx.setForegroundJob(Array(job.pids))
        waitForJob(jobID, lastPID: job.lastPID, commandText: job.command, done: done)
    }

    // MARK: - Traps

    private static let signalNumbers: [String: Int32] = [
        "HUP": 1, "INT": 2, "QUIT": 3, "USR1": 10, "USR2": 12, "PIPE": 13, "ALRM": 14, "TERM": 15,
    ]

    /// Canonical trap name (`EXIT`, `INT`, …) for `0`, `2`, `SIGINT`, `int`.
    private static func trapName(_ spec: String) -> String? {
        var text = spec.uppercased()
        if text.hasPrefix("SIG") { text.removeFirst(3) }
        if text == "EXIT" || text == "0" { return "EXIT" }
        if signalNumbers[text] != nil { return text }
        if let number = Int32(text) { return signalNumbers.first { $0.value == number }?.key }
        return nil
    }

    private func builtinTrap(_ arguments: [String]) {
        status.last = 0
        var arguments = arguments
        if arguments.first == "--" { arguments.removeFirst() }
        if arguments.isEmpty || arguments == ["-p"] {
            for (name, action) in listedTraps.sorted(by: { $0.key < $1.key }) {
                out("trap -- \(Self.quoted(action)) \(name)\n")
            }
            return
        }
        // `trap ACTION SIG…`; a lone signal list (first word is a signal number
        // or `-`) resets those traps.
        inheritedTraps.removeAll()           // changing a trap ends the listing-only view
        var action: String?
        if arguments[0] == "-" {
            arguments.removeFirst()
        } else if arguments.count == 1 || Int(arguments[0]) != nil {
            // reset form: every argument is a signal
        } else {
            action = arguments.removeFirst()
        }
        for spec in arguments {
            guard let name = Self.trapName(spec) else {
                err("trap: \(spec): invalid signal specification\n")
                status.last = 1
                continue
            }
            if let action {
                traps[name] = action
                if let number = Self.signalNumbers[name] {
                    ctx.signal(number) { [weak self] in
                        guard let self, let current = self.traps[name], !current.isEmpty else { return }
                        self.pendingTraps.append(name)
                    }
                }
            } else {
                traps[name] = nil
                if let number = Self.signalNumbers[name] {
                    ctx.process.signalHandlers[number] = nil
                    // An interactive shell goes back to ignoring SIGINT.
                    if interactive, name == "INT" { ctx.signal(number) {} }
                }
            }
        }
    }

    // MARK: - Command lookup

    private static let keywordNames: Set<String> = [
        "if", "then", "else", "elif", "fi", "while", "until", "for", "do", "done",
        "case", "in", "esac", "{", "}", "!", "function",
    ]

    private func builtinType(_ arguments: [String]) {
        status.last = 0
        for name in arguments {
            if let value = aliases[name] {
                out("\(name) is aliased to `\(value)'\n")
            } else if Self.keywordNames.contains(name) {
                out("\(name) is a shell keyword\n")
            } else if functions[name] != nil {
                out("\(name) is a function\n")
            } else if Self.builtinNames.contains(name) {
                out("\(name) is a shell builtin\n")
            } else if let command = ctx.resolveCommand(name) {
                out(command.name.contains("/") ? "\(name) is \(command.name)\n" : "\(name) is a builtin\n")
            } else {
                out("\(name): not found\n")
                status.last = 1
            }
        }
    }

    private func builtinCommand(_ arguments: [String], done: @escaping () -> Void) {
        var arguments = arguments
        var describe = false
        while let first = arguments.first, first.hasPrefix("-"), first.count > 1 {
            if first == "-v" || first == "-V" { describe = true }
            arguments.removeFirst()
            if first == "--" { break }
        }
        guard !arguments.isEmpty else { status.last = 0; done(); return }
        if describe {
            // `command -v NAME…`: how each name would be run; 1 if any is unknown.
            status.last = 0
            for name in arguments {
                if aliases[name] != nil || functions[name] != nil || Self.builtinNames.contains(name) {
                    out(name + "\n")
                } else if let command = ctx.resolveCommand(name) {
                    out((command.name.contains("/") ? command.name : name) + "\n")
                } else {
                    status.last = 1
                }
            }
            done()
            return
        }
        var prepared = Programs.PreparedCommand()
        prepared.argv = arguments
        execute(prepared, background: false, skipFunctions: true, done: done)
    }

    /// `exec`: with a command, run it and leave the shell with its status (the
    /// kernel has no in-place image replacement); with only redirections, make
    /// them permanent for this shell.
    func builtinExec(_ prepared: Programs.PreparedCommand, done: @escaping () -> Void) {
        var command = prepared
        command.argv.removeFirst()
        guard let name = command.argv.first else {
            if let error = Self.applyRedirections(ctx, prepared.redirections) {
                err("sh: \(error)\n")
                status.last = 1
            } else {
                status.last = 0
            }
            done()
            return
        }
        guard !runsInShell(name), resolveExternal(command) != nil else {
            if runsInShell(name) {
                execute(command, background: false) { self.exitShell(self.status.last) }
                return
            }
            reportUnresolved(name)
            if interactive { done() } else { exitShell(status.last) }
            return
        }
        execute(command, background: false) { self.exitShell(self.status.last) }
    }
}
