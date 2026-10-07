/// Process built-ins (category .process): ps/kill/pgrep/pkill/killall/pidof/
/// uptime/top/time/watch, plus the small system tools env/printenv/nproc/sync.
///
/// Concurrency: plain programs over `ProcessContext` on the single loop-bound
/// executor; the ones that run a child (`env`, `time`, `watch`) await it through
/// the wait syscall and park on the logical clock between runs.
extension BuiltinCommands {

    // MARK: - Process tools (category: .process)

    static func processCommands() -> [Command] {
        [
            // ps — list the processes visible in the caller's PID namespace, with
            // pids translated to that namespace's local numbering (in the root
            // namespace this is the whole table, unchanged; inside `unshare -p` it
            // is just the contained processes, starting at pid 1). Output is
            // column-aligned like Linux ps(1). With no options: PID, PPID, STAT,
            // COMMAND. `aux`, `-f`, and `-ef` add the owner and CPU-time columns;
            // `-o` picks the columns.
            Command(name: "ps", summary: "report a snapshot of processes", category: .process,
                    usage: """
                    ps [aux] [-eAf] [-o FORMAT] [-p PIDLIST] [-u USERLIST] [--no-headers]
                      a, x, -e, -A  select all processes (always the case here)
                      u, -f, -ef    full format: USER PID PPID STAT TIME COMMAND
                      -o FORMAT     choose columns: user uid pid ppid pgid sid stat time
                                    fds mem comm args (NAME=HEADER renames; NAME= hides it)
                      -p PIDLIST    only these process IDs
                      -u USERLIST   only processes of these users (name or uid)
                      --no-headers  do not print the header line
                    """) { ctx, argv in
                var full = false
                var columns: [(field: String, header: String)] = []
                var pidFilter: Set<Int>? = nil
                var userFilter: Set<UInt32>? = nil
                var headers = true
                let names = ctx.userDatabase()
                var args = argv.dropFirst()
                func list(_ text: String) -> [String] {
                    text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                }
                func addColumns(_ text: String) -> Bool {
                    for item in list(text) {
                        let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        let field = parts[0].lowercased()
                        guard let standard = psHeader(field) else {
                            ctx.error("ps: unknown user-defined format specifier \"\(parts[0])\"")
                            ctx.exit(1)
                            return false
                        }
                        columns.append((field, parts.count > 1 ? String(parts[1]) : standard))
                    }
                    return true
                }
                while let arg = args.popFirst() {
                    if arg == "--no-headers" || arg == "--no-heading" { headers = false; continue }
                    if arg.hasPrefix("--") { ctx.invalidOption("ps", arg); return }
                    // BSD-style words (`aux`) and UNIX-style groups (`-ef`) share letters.
                    var letters = (arg.hasPrefix("-") ? arg.dropFirst() : arg[...])[...]
                    let bsd = !arg.hasPrefix("-")
                    while let letter = letters.popFirst() {
                        switch letter {
                        case "a", "x", "e", "A", "w", "H", "l", "j": break
                        case "u" where bsd, "f", "F": full = true
                        case "o", "p", "u", "U":
                            var value = String(letters)
                            letters = ""
                            if value.isEmpty {
                                guard let next = args.popFirst() else {
                                    ctx.error("ps: option requires an argument -- '\(letter)'")
                                    ctx.fail("Try 'ps --help' for more information.", code: 1); return
                                }
                                value = next
                            }
                            if letter == "o" {
                                guard addColumns(value) else { return }
                            } else if letter == "p" {
                                var pids = pidFilter ?? []
                                for item in list(value) {
                                    guard let pid = Int(item) else {
                                        ctx.fail("ps: process ID list syntax error", code: 1); return
                                    }
                                    pids.insert(pid)
                                }
                                pidFilter = pids
                            } else {
                                var users = userFilter ?? []
                                for item in list(value) {
                                    guard let uid = names.resolveUser(item)?.uid
                                            ?? (item == "root" ? 0 : nil) else {
                                        ctx.fail("ps: user name does not exist", code: 1); return
                                    }
                                    users.insert(uid)
                                }
                                userFilter = users
                            }
                        default:
                            ctx.invalidOption("ps", String(letter)); return
                        }
                    }
                }
                if columns.isEmpty {
                    let fields = full ? ["user", "pid", "ppid", "stat", "time", "args"]
                                      : ["pid", "ppid", "stat", "args"]
                    columns = fields.map { ($0, psHeader($0) ?? $0.uppercased()) }
                }

                var table: [[String]] = []
                for row in ctx.kernel.processRows(visibleTo: ctx.globalPID) {
                    if let pidFilter, !pidFilter.contains(Int(row.pid)) { continue }
                    let global = ctx.resolveVisiblePID(row.pid) ?? row.pid
                    let credentials = ctx.kernel.processCredentials(global) ?? (0, 0)
                    if let userFilter, !userFilter.contains(credentials.uid) { continue }
                    table.append(columns.map { column in
                        switch column.field {
                        case "user", "euser", "ruser":
                            let name = names.userName(uid: credentials.uid)
                            return name == "0" ? "root" : name
                        case "uid", "euid": return "\(credentials.uid)"
                        case "gid", "egid": return "\(credentials.gid)"
                        case "pid": return "\(row.pid)"
                        case "ppid": return "\(row.ppid)"
                        case "pgid", "pgrp": return "\(row.pgid)"
                        case "sid", "sess": return "\(row.sid)"
                        case "stat", "state", "s": return row.state
                        case "time", "cputime":
                            // Scheduler steps, shown as M:SS at 100 steps a second.
                            let seconds = row.ticks / 100
                            return "\(seconds / 60):\(seconds % 60 < 10 ? "0" : "")\(seconds % 60)"
                        case "fds": return "\(row.fds)"
                        case "mem", "rss", "vsz": return "\(row.memoryBytes / 1024)"
                        case "tty", "tt": return "?"
                        case "comm", "ucmd": return row.name
                        default: return row.command
                        }
                    })
                }
                // Numeric columns are right-aligned; the last column is not padded.
                let leftAligned: Set<String> = ["user", "euser", "ruser", "stat", "state", "s", "tty", "tt",
                                                "comm", "ucmd", "args", "cmd", "command"]
                var widths = columns.map { headers ? $0.header.count : 0 }
                for line in table {
                    for (index, cell) in line.enumerated() { widths[index] = max(widths[index], cell.count) }
                }
                func render(_ cells: [String]) -> String {
                    var parts: [String] = []
                    for (index, cell) in cells.enumerated() {
                        let left = leftAligned.contains(columns[index].field)
                        if index == cells.count - 1, left { parts.append(cell) }
                        else { parts.append(left ? padRight(cell, widths[index]) : padLeft(cell, widths[index])) }
                    }
                    return parts.joined(separator: " ") + "\n"
                }
                var out = ""
                if headers, columns.contains(where: { !$0.header.isEmpty }) { out += render(columns.map(\.header)) }
                for line in table { out += render(line) }
                ctx.print(out)
                ctx.exit(pidFilter != nil && table.isEmpty ? 1 : 0)
            },

            // kill [-s SIGNAL | -SIGNAL] pid... — send a signal (default TERM).
            // SIGNAL may be a number (`-9`), a name (`-KILL`, `-SIGKILL`), or given
            // with `-s` / `-n`. `kill -l` lists the signal names.
            Command(name: "kill", summary: "send a signal to a process", category: .process,
                    usage: """
                    kill [-s SIGNAL | -n SIGNUM | -SIGNAL] PID...
                    kill -l [SIGNAL]...
                      -s SIGNAL  send the named or numbered signal
                      -n SIGNUM  send the numbered signal
                      -SIGNAL    the same, e.g. -9, -KILL, -SIGKILL
                      -l         list signal names, or convert between names and numbers
                    """) { ctx, argv in
                var args = Array(argv.dropFirst())
                var signal = Signal.sigterm.rawValue
                if let first = args.first, first == "-l" || first == "-L" || first == "--list" || first == "--table" {
                    let operands = args.dropFirst()
                    if operands.isEmpty {
                        var out = ""
                        for (index, entry) in signalTable.enumerated() {
                            out += padLeft("\(entry.number)", 2) + ") " + padRight("SIG" + entry.name, 11)
                            out += (index + 1) % 5 == 0 || index == signalTable.count - 1 ? "\n" : " "
                        }
                        ctx.print(out)
                        ctx.exit(0)
                        return
                    }
                    var status: Int32 = 0
                    for operand in operands {
                        if let number = Int32(operand) {
                            // An exit status above 128 names the signal that caused it.
                            if let name = signalName(number > 128 ? number - 128 : number) { ctx.print(name + "\n") }
                            else { ctx.error("kill: \(operand): invalid signal specification"); status = 1 }
                        } else if let number = signalNumber(forName: operand) {
                            ctx.print("\(number)\n")
                        } else {
                            ctx.error("kill: \(operand): invalid signal specification")
                            status = 1
                        }
                    }
                    ctx.exit(status)
                    return
                }
                if let first = args.first, first == "-s" || first == "-n" || first == "--signal" {
                    guard args.count >= 2 else {
                        ctx.fail("kill: option requires an argument -- '\(first.dropFirst())'"); return
                    }
                    guard let named = signalNumber(forName: args[1]) else {
                        ctx.fail("kill: \(args[1]): invalid signal specification", code: 1); return
                    }
                    signal = named
                    args.removeFirst(2)
                } else if let first = args.first, first == "--" {
                    args.removeFirst()
                } else if let first = args.first, CommandArguments.isOptionToken(first) {
                    guard let named = signalNumber(forName: String(first.dropFirst())) else {
                        ctx.fail("kill: \(first.dropFirst()): invalid signal specification", code: 1); return
                    }
                    signal = named
                    args.removeFirst()
                    if args.first == "--" { args.removeFirst() }
                }
                guard !args.isEmpty else {
                    ctx.usage("kill", "kill [-s signal | -signal] <pid>... | kill -l [signal]"); return
                }
                let visible = Set(ctx.kernel.processRows(visibleTo: ctx.globalPID).map { Int($0.pid) })
                var status: Int32 = 0
                for token in args {
                    guard let pid = Int(token), pid > 0 else {
                        ctx.error("kill: \(token): arguments must be process or job IDs"); status = 1; continue
                    }
                    // Translate the (namespace-local) pid the user typed to the
                    // global pid the kernel signals. In the root namespace this is
                    // the identity; inside a container a pid outside the caller's
                    // namespace is not visible (isolation) and is rejected.
                    guard visible.contains(pid), let target = ctx.resolveVisiblePID(PID(pid)) else {
                        ctx.error("kill: (\(pid)) - No such process"); status = 1; continue
                    }
                    // Signal 0 only checks that the process exists.
                    if signal != 0 { ctx.kill(target, signal: signal) }
                }
                ctx.exit(status)
            },

            Command(name: "pgrep", summary: "list processes by name", category: .process,
                    usage: """
                    pgrep [-flxvc] [-u UID] PATTERN
                      -l  list the process name as well as the process ID
                      -a  list the full command line as well as the process ID
                      -f  match against the full command line
                      -x  require an exact match of the whole name
                      -v  negate the matching
                      -c  print only a count of matching processes
                      -n, -o  select only the newest / oldest match
                      -u UID  match only processes owned by UID
                    """) { ctx, argv in
                guard let parsed = ctx.options("pgrep", Array(argv.dropFirst()), "flaxvcnou:d:") else { return }
                guard let matches = matchProcesses(ctx, "pgrep", parsed) else { return }
                if parsed.has("c") {
                    ctx.print("\(matches.count)\n")
                } else {
                    let delimiter = parsed.value("d") ?? "\n"
                    let lines = matches.map { row -> String in
                        if parsed.has("a") || (parsed.has("l") && parsed.has("f")) { return "\(row.pid) \(row.command)" }
                        return parsed.has("l") ? "\(row.pid) \(row.name)" : "\(row.pid)"
                    }
                    if !lines.isEmpty { ctx.print(lines.joined(separator: delimiter) + "\n") }
                }
                ctx.exit(matches.isEmpty ? 1 : 0)
            },

            Command(name: "pkill", summary: "signal processes by name", category: .process,
                    usage: """
                    pkill [-SIGNAL] [-fxvno] [-u UID] PATTERN
                      -SIGNAL  signal to send (name or number; default TERM)
                      -f  match against the full command line
                      -x  require an exact match of the whole name
                      -n, -o  select only the newest / oldest match
                      -u UID  match only processes owned by UID
                    """) { ctx, argv in
                var args = Array(argv.dropFirst())
                var signal = Signal.sigterm.rawValue
                if let first = args.first, first.hasPrefix("-"), first.count > 1,
                   let named = signalNumber(forName: String(first.dropFirst())),
                   first.dropFirst().first.map({ $0.isNumber || $0.isUppercase }) == true {
                    signal = named
                    args.removeFirst()
                }
                guard let parsed = ctx.options("pkill", args, "fxvnou:es:") else { return }
                if let text = parsed.value("s") {
                    guard let named = signalNumber(forName: text) else {
                        ctx.fail("pkill: invalid signal '\(text)'"); return
                    }
                    signal = named
                }
                guard let matches = matchProcesses(ctx, "pkill", parsed) else { return }
                for row in matches {
                    if let target = ctx.resolveVisiblePID(row.pid) { ctx.kill(target, signal: signal) }
                    if parsed.has("e") { ctx.print("\(row.name) killed (pid \(row.pid))\n") }
                }
                ctx.exit(matches.isEmpty ? 1 : 0)
            },

            Command(name: "killall", summary: "signal processes by exact name", category: .process,
                    usage: """
                    killall [-SIGNAL | -s SIGNAL] [-q] [-v] NAME...
                      -SIGNAL, -s SIGNAL  signal to send (default TERM)
                      -q  do not complain if no process was found
                      -v  report each signal sent
                    """) { ctx, argv in
                var args = Array(argv.dropFirst())
                var signal = Signal.sigterm.rawValue
                if let first = args.first, first.hasPrefix("-"), first.count > 1, first != "-s", first != "-q", first != "-v",
                   let named = signalNumber(forName: String(first.dropFirst())) {
                    signal = named
                    args.removeFirst()
                }
                guard let parsed = ctx.options("killall", args, "s:qvew") else { return }
                if let text = parsed.value("s") {
                    guard let named = signalNumber(forName: text) else {
                        ctx.fail("killall: \(text): unknown signal", code: 1); return
                    }
                    signal = named
                }
                guard !parsed.operands.isEmpty else {
                    ctx.fail("Usage: killall [-SIGNAL] [-qv] NAME...", code: 1); return
                }
                let rows = ctx.kernel.processRows(visibleTo: ctx.globalPID)
                let own = ctx.getpid()
                var status: Int32 = 0
                for name in parsed.operands {
                    let targets = rows.filter { processMatchesName($0, name) && $0.pid != own && $0.state != "Z" }
                    if targets.isEmpty {
                        if !parsed.has("q") { ctx.error("\(name): no process found") }
                        status = 1
                    }
                    for row in targets {
                        if let target = ctx.resolveVisiblePID(row.pid) { ctx.kill(target, signal: signal) }
                        if parsed.has("v") {
                            ctx.print("Killed \(row.name)(\(row.pid)) with signal \(signal)\n")
                        }
                    }
                }
                ctx.exit(status)
            },

            Command(name: "pidof", summary: "find the process IDs of a running program", category: .process,
                    usage: """
                    pidof [-s] NAME...
                      -s  single shot: print only one process ID
                    """) { ctx, argv in
                guard let parsed = ctx.options("pidof", Array(argv.dropFirst()), "sxo:") else { return }
                let rows = ctx.kernel.processRows(visibleTo: ctx.globalPID)
                let own = ctx.getpid()
                var pids: [PID] = []
                for name in parsed.operands {
                    // Newest first, like pidof(8).
                    pids += rows.filter { processMatchesName($0, name) && $0.pid != own && $0.state != "Z" }
                        .map(\.pid).reversed()
                }
                if parsed.has("s") { pids = Array(pids.prefix(1)) }
                if !pids.isEmpty { ctx.print(pids.map { "\($0)" }.joined(separator: " ") + "\n") }
                ctx.exit(pids.isEmpty ? 1 : 0)
            },

            Command(name: "nproc", summary: "print the number of processing units", category: .system,
                    usage: "nproc\nSwiftix runs every process on one logical CPU.") { ctx, argv in
                guard ctx.options("nproc", Array(argv.dropFirst()), "", long: ["all": "a"]) != nil else { return }
                ctx.print("1\n")
                ctx.exit(0)
            },

            Command(name: "sync", summary: "flush filesystem buffers", category: .system,
                    usage: "sync\nThe in-memory filesystem has no write-back cache, so this returns at once.") { ctx, _ in
                ctx.exit(0)
            },

            // env [-i] [-u NAME] [NAME=VALUE...] [CMD [args...]] — with no command,
            // print the environment; otherwise apply the changes and run CMD in
            // the modified environment (the child inherits it), exiting with its
            // code.
            Command(name: "env", summary: "print env, or run a command in a modified env", category: .system,
                    usage: """
                    env [-i] [-u NAME]... [NAME=VALUE]... [COMMAND [ARG]...]
                      -i, -    start with an empty environment
                      -u NAME  remove NAME from the environment
                    """, asyncRun: { ctx, argv in
                var rest = argv.dropFirst()
                while let first = rest.first, first.hasPrefix("-") {
                    rest = rest.dropFirst()
                    if first == "--" { break }
                    if first == "-" || first == "-i" || first == "--ignore-environment" {
                        ctx.process.environment.removeAll()
                    } else if first == "-u" || first == "--unset" {
                        guard let name = rest.popFirst() else {
                            ctx.error("env: option requires an argument -- 'u'")
                            ctx.fail("Try 'env --help' for more information.", code: 125); return
                        }
                        ctx.process.environment.removeValue(forKey: name)
                    } else if first.hasPrefix("-u"), !first.hasPrefix("--") {
                        ctx.process.environment.removeValue(forKey: String(first.dropFirst(2)))
                    } else if first.hasPrefix("--unset=") {
                        ctx.process.environment.removeValue(forKey: String(first.dropFirst(8)))
                    } else {
                        ctx.invalidOption("env", first.hasPrefix("--") ? first : String(first.dropFirst().prefix(1)))
                        return
                    }
                }
                while let first = rest.first, let pair = envAssignment(first) {
                    ctx.setenv(pair.name, pair.value)
                    rest = rest.dropFirst()
                }
                guard let name = rest.first else {
                    var out = ""
                    for key in ctx.environment.keys.sorted() {
                        out += "\(key)=\(ctx.environment[key] ?? "")\n"
                    }
                    await ctx.emit(out, exit: 0)
                    return
                }
                guard let (command, commandArgs) = resolveProgram(ctx, Array(rest)) else {
                    ctx.error("env: '\(name)': \(SyscallError.noSuchFileOrDirectory.message)")
                    ctx.exit(127)
                    return
                }
                ctx.run(command, args: commandArgs)
                guard let event = try? await ctx.wait() else { return }
                ctx.exit(event.status.code)
            }),

            Command(name: "printenv", summary: "print environment variables", category: .system,
                    usage: "printenv [NAME]...\nPrint the values of the named variables, or the whole environment.",
                    asyncRun: { ctx, argv in
                guard let parsed = ctx.options("printenv", Array(argv.dropFirst()), "0") else { return }
                var out = ""
                var status: Int32 = 0
                if parsed.operands.isEmpty {
                    for key in ctx.environment.keys.sorted() { out += "\(key)=\(ctx.environment[key] ?? "")\n" }
                }
                for name in parsed.operands {
                    if let value = ctx.getenv(name) { out += value + "\n" } else { status = 1 }
                }
                await ctx.emit(out, exit: status)
            }),

            // time CMD [args...] — run CMD and report how much logical time passed.
            // There is no CPU accounting, so user/sys are always zero.
            Command(name: "time", summary: "run a command and report elapsed logical time", category: .process,
                    usage: """
                    time [-p] COMMAND [ARG]...
                      -p  print the POSIX format (seconds with two decimals)
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("time", Array(argv.dropFirst()), "p", stopAtOperand: true) else { return }
                let start = ctx.monotonicNanoseconds
                var code: Int32 = 0
                if let name = parsed.operands.first {
                    guard let (command, commandArgs) = resolveProgram(ctx, parsed.operands) else {
                        ctx.error("time: cannot run \(name): \(SyscallError.noSuchFileOrDirectory.message)")
                        ctx.exit(127)
                        return
                    }
                    ctx.run(command, args: commandArgs)
                    guard let event = try? await ctx.wait() else { return }
                    code = event.status.code
                }
                let elapsed = Double(ctx.monotonicNanoseconds - start) / 1_000_000_000
                if parsed.has("p") {
                    ctx.error("real \(fixedPoint(elapsed, places: 2))\nuser 0.00\nsys 0.00")
                } else {
                    let minutes = Int(elapsed / 60)
                    let seconds = fixedPoint(elapsed - Double(minutes * 60), places: 3)
                    ctx.error("\nreal\t\(minutes)m\(seconds)s\nuser\t0m0.000s\nsys\t0m0.000s")
                }
                ctx.exit(code)
            }),

            // watch [-n SEC] CMD [args...] — run CMD repeatedly, redrawing the
            // screen each time, until interrupted. The pause between runs is a
            // logical-clock sleep, so the program parks on the event loop.
            Command(name: "watch", summary: "run a command repeatedly, showing its output", category: .process,
                    usage: """
                    watch [-n SECONDS] [-t] COMMAND [ARG]...
                      -n SECONDS  seconds to wait between updates (default 2)
                      -t          turn off the header line
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("watch", Array(argv.dropFirst()), "n:tdbex",
                                               long: ["interval": "n", "no-title": "t"],
                                               stopAtOperand: true) else { return }
                guard let interval = Double(parsed.value("n") ?? "2"), interval >= 0 else {
                    ctx.fail("watch: failed to parse argument: '\(parsed.value("n") ?? "")'", code: 1); return
                }
                guard let name = parsed.operands.first else {
                    ctx.error("Usage: watch [-n SECONDS] [-t] COMMAND [ARG]...")
                    ctx.exit(1)
                    return
                }
                // Several words go through `sh -c` when a shell command exists, so
                // pipelines work; otherwise the words are the command line.
                var words = parsed.operands
                if let shell = ctx.resolveCommand("sh"), words.count > 1 || name.contains(" ") {
                    _ = shell
                    words = ["sh", "-c", parsed.operands.joined(separator: " ")]
                }
                guard let command = ctx.resolveCommand(words[0]) else {
                    ctx.fail("watch: \(name): command not found", code: 127); return
                }
                let pause = Swift.max(interval, 0.1)
                while true {
                    var frame = "\u{1B}[2J\u{1B}[H"
                    if !parsed.has("t") {
                        frame += "Every \(fixedPoint(pause, places: 1))s: \(parsed.operands.joined(separator: " "))\n\n"
                    }
                    guard await ctx.put(frame) else { return }
                    ctx.run(command, args: words)
                    guard (try? await ctx.wait()) != nil else { return }
                    do { try await ctx.sleep(pause) } catch { return }
                }
            }),

            // uptime — logical time since boot, formatted like Linux uptime(1).
            // (Deterministic and wall-clock-free, matching the core's design; this
            // is why there is no `date`.)
            Command(name: "uptime", summary: "print logical time since start", category: .process,
                    usage: "uptime") { ctx, _ in
                let totalSeconds = Int(ctx.monotonicNanoseconds / 1_000_000_000)
                let hours = totalSeconds / 3600
                let minutes = (totalSeconds % 3600) / 60
                let seconds = totalSeconds % 60
                func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
                var upStr: String
                if hours > 0 {
                    upStr = "up \(hours):\(pad2(minutes)):\(pad2(seconds))"
                } else if minutes > 0 {
                    upStr = "up \(minutes) min, \(seconds) sec"
                } else {
                    upStr = "up \(seconds) sec"
                }
                ctx.print(" \(upStr)\n")
                ctx.exit(0)
            },

            // top — a process monitor. It reads the same synthetic /proc/processes
            // file `ps` uses and adds a summary header (logical uptime + a
            // task-state breakdown).
            //
            // Two modes, so the same program serves an interactive terminal and a
            // deterministic pipeline/test:
            //   * interactive (default): auto-refresh via poll-with-timeout. Paints
            //     a frame, then polls stdin with `delay` (default 1s) as timeout.
            //     If the timeout expires with no input, repaints automatically. If
            //     input arrives, `q`/`Q` quits; anything else repaints immediately.
            //     Safe with `runUntilIdle()`: the poll timeout is a future timer,
            //     and `runUntilIdle()` only drains work at `now`, so the loop
            //     converges immediately.
            //   * batch (`-n N`): emit N plain frames `-d` seconds apart (bounded,
            //     so it always terminates) without screen-clearing escapes —
            //     friendly to `top -n 1`, pipes, and the logical clock (time
            //     advances via the event loop, never wall time).
            Command(name: "top", summary: "display and update process activity", category: .process,
                    usage: """
                    top [-n COUNT] [-d SECONDS]
                      -n COUNT    batch mode: print COUNT frames and exit
                      -d SECONDS  delay between refreshes (default 1)
                    Interactive mode refreshes until q is pressed.
                    """, asyncRun: { ctx, argv in
                var iterations: Int? = nil            // nil ⇒ interactive (unbounded)
                var delay = 1.0
                var index = 1
                while index < argv.count {
                    let arg = argv[index]
                    switch arg {
                    case "-n":
                        index += 1
                        guard index < argv.count, let n = Int(argv[index]), n > 0 else {
                            ctx.fail("top: -n requires a positive count"); return
                        }
                        iterations = n
                    case "-d":
                        index += 1
                        guard index < argv.count, let d = Double(argv[index]), d >= 0 else {
                            ctx.fail("top: -d requires a non-negative delay"); return
                        }
                        delay = d
                    default:
                        ctx.invalidOption("top", arg.hasPrefix("--") ? arg : String(arg.dropFirst().prefix(1))); return
                    }
                    index += 1
                }

                if let count = iterations {
                    // Batch mode: N plain frames, `delay` apart. Bounded, so the
                    // loop always drains and `runUntilIdle`-style consumers return.
                    for frame in 0..<count {
                        ctx.write(1, Array(renderTop(ctx).utf8))
                        if frame < count - 1, delay > 0 { try? await ctx.sleep(delay) }
                    }
                    ctx.exit(0)
                    return
                }

                // Interactive mode: auto-refresh via poll-with-timeout. Paint a
                // frame, then poll stdin with `delay` as timeout. If the timeout
                // expires (empty result), repaint automatically. If input arrives,
                // check for `q`/`Q` to quit — anything else repaints immediately.
                // Safe with the new `runUntilIdle()` semantics: the poll timer is
                // scheduled in the future so `runUntilIdle()` (which only drains at
                // `now`) ignores it — no infinite spin.
                func paint() {
                    ctx.write(1, Array("\u{1b}[2J\u{1b}[H".utf8))   // clear + home
                    ctx.write(1, Array(renderTop(ctx).utf8))
                    ctx.write(1, Array("\n[auto-refresh \(delay)s, q to quit]\n".utf8))
                }
                paint()
                while true {
                    let ready = try? await ctx.poll(
                        [PollRequest(fd: 0, interests: .readable)],
                        timeout: delay
                    )
                    if let results = ready, !results.isEmpty {
                        // stdin is readable — consume the input.
                        guard let input = try? await ctx.read(0), !input.isEmpty else { break }
                        if input.contains(where: { $0 == UInt8(ascii: "q") || $0 == UInt8(ascii: "Q") }) { break }
                    }
                    // Timeout expired or non-quit key: repaint.
                    paint()
                }
                ctx.exit(0)
            }),
        ]
    }

    /// The default header of a `ps -o` field, or `nil` for an unknown field.
    static func psHeader(_ field: String) -> String? {
        switch field {
        case "user", "euser", "ruser": return "USER"
        case "uid", "euid": return "UID"
        case "gid", "egid": return "GID"
        case "pid": return "PID"
        case "ppid": return "PPID"
        case "pgid", "pgrp": return "PGID"
        case "sid", "sess": return "SID"
        case "stat", "state", "s": return "STAT"
        case "time", "cputime": return "TIME"
        case "fds": return "FDS"
        case "mem": return "MEM"
        case "rss": return "RSS"
        case "vsz": return "VSZ"
        case "tty", "tt": return "TTY"
        case "comm", "ucmd": return "COMMAND"
        case "args", "cmd", "command": return "COMMAND"
        default: return nil
        }
    }

    /// Whether a process is "named" `name` for `killall` / `pidof`: its process
    /// name, the base name of its program, or the first word of its command line.
    static func processMatchesName(_ row: ProcessSnapshotRow, _ name: String) -> Bool {
        if row.name == name || baseName(row.name) == name { return true }
        let first = row.command.split(separator: " ").first.map(String.init) ?? ""
        return first == name || baseName(first) == name
    }

    /// The processes selected by the `pgrep` / `pkill` options in `parsed`
    /// (pattern operand, `-f`, `-x`, `-v`, `-u`, `-n`, `-o`), never including the
    /// caller. Reports a usage or pattern error (exit 2) and returns `nil`.
    static func matchProcesses(_ ctx: ProcessContext, _ command: String,
                               _ parsed: CommandOptions) -> [ProcessSnapshotRow]? {
        guard parsed.operands.count == 1 || (parsed.operands.isEmpty && parsed.has("u")) else {
            ctx.error(parsed.operands.isEmpty ? "\(command): no matching criteria specified"
                                              : "\(command): only one pattern can be provided")
            ctx.fail("Try '\(command) --help' for more information.")
            return nil
        }
        var regex: Regex? = nil
        if let pattern = parsed.operands.first {
            guard let compiled = Regex(pattern: pattern) else {
                ctx.fail("\(command): invalid regular expression: \(pattern)")
                return nil
            }
            regex = compiled
        }
        var owner: UInt32? = nil
        if let text = parsed.value("u") {
            guard let uid = ctx.userDatabase().resolveUser(text)?.uid else {
                ctx.fail("\(command): invalid user name: \(text)")
                return nil
            }
            owner = uid
        }
        let own = ctx.getpid()
        var matches = ctx.kernel.processRows(visibleTo: ctx.globalPID).filter { row in
            guard row.pid != own, row.state != "Z" else { return false }
            if let owner {
                let global = ctx.resolveVisiblePID(row.pid) ?? row.pid
                guard ctx.kernel.processCredentials(global)?.uid == owner else { return false }
            }
            guard let regex else { return true }
            let subject = Array(parsed.has("f") ? row.command : row.name)
            let hit = parsed.has("x") ? regex.matchesEntire(subject) : regex.match(in: subject, from: 0) != nil
            return hit != parsed.has("v")
        }
        if parsed.has("n") { matches = Array(matches.suffix(1)) }
        if parsed.has("o") { matches = Array(matches.prefix(1)) }
        return matches
    }
}
