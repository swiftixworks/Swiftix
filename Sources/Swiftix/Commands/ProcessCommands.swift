/// Process built-ins (category .process): ps/kill/uptime/top.
extension BuiltinCommands {

    // MARK: - Process tools (category: .process)

    static func processCommands() -> [Command] {
        [
            // ps — list the processes visible in the caller's PID namespace, with
            // pids translated to that namespace's local numbering (in the root
            // namespace this is the whole table, unchanged; inside `unshare -p` it
            // is just the contained processes, starting at pid 1). Output is
            // column-aligned like Linux ps(1): PID, PPID, STAT, CMD.
            Command(name: "ps", summary: "list processes", category: .process) { ctx, _ in
                let text = String(decoding: ctx.namespaceProcessListing(), as: UTF8.self)
                // Parse the raw listing (columns: PID PPID PGID SID STATE TICKS FDS NAME).
                struct Row { let pid: String; let ppid: String; let state: String; let name: String }
                var rows: [Row] = []
                var maxPid = 3, maxPpid = 4, maxName = 7  // min header widths
                for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
                    if index == 0 { continue }   // skip raw header
                    let cols = rawLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                    guard cols.count >= 8 else { continue }
                    let name = cols[7...].joined(separator: " ")
                    rows.append(Row(pid: cols[0], ppid: cols[1], state: cols[4], name: name))
                    maxPid = max(maxPid, cols[0].count)
                    maxPpid = max(maxPpid, cols[1].count)
                    maxName = max(maxName, name.count)
                }
                var out = "\(padLeft("PID", maxPid)) \(padLeft("PPID", maxPpid)) STAT COMMAND\n"
                for row in rows {
                    out += "\(padLeft(row.pid, maxPid)) \(padLeft(row.ppid, maxPpid))    \(row.state) \(row.name)\n"
                }
                ctx.print(out)
                ctx.exit(0)
            },

            // kill [-SIG] pid... — send a signal (default TERM). SIG may be a
            // number (`-9`) or a name (`-KILL`, `-TERM`, `-INT`, `-STOP`, `-CONT`).
            Command(name: "kill", summary: "send a signal to a process", category: .process) { ctx, argv in
                var args = Array(argv.dropFirst())
                var signal = Signal.sigterm.rawValue
                if let first = args.first, CommandArguments.isOptionToken(first) {
                    let spec = String(first.dropFirst())
                    if let number = Int32(spec) {
                        signal = number
                    } else if let named = signalNumber(forName: spec) {
                        signal = named
                    } else {
                        ctx.fail("kill: \(first): invalid signal"); return
                    }
                    args.removeFirst()
                }
                guard !args.isEmpty else {
                    ctx.usage("kill", "kill [-signal] <pid>..."); return
                }
                var status: Int32 = 0
                for token in args {
                    guard let pid = Int(token) else {
                        ctx.error("kill: \(token): not a pid"); status = 1; continue
                    }
                    // Translate the (namespace-local) pid the user typed to the
                    // global pid the kernel signals. In the root namespace this is
                    // the identity; inside a container a pid outside the caller's
                    // namespace is not visible (isolation) and is rejected.
                    guard let target = ctx.resolveVisiblePID(PID(pid)) else {
                        ctx.error("kill: (\(pid)) - No such process"); status = 1; continue
                    }
                    ctx.kill(target, signal: signal)
                }
                ctx.exit(status)
            },

            // uptime — logical time since boot, formatted like Linux uptime(1).
            // (Deterministic and wall-clock-free, matching the core's design; this
            // is why there is no `date`.)
            Command(name: "uptime", summary: "print logical time since start", category: .process) { ctx, _ in
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
            Command(name: "top", summary: "display and update process activity", category: .process, asyncRun: { ctx, argv in
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
                        ctx.fail("top: unknown option \(arg)"); return
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

}
