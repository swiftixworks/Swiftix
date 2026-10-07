/// System built-ins (category .system): wall-clock time (`date`, `cal`),
/// identity (`id`, `groups`, `who`, `w`, `logname`), terminal state (`tty`,
/// `stty`), and guest power control (`shutdown`, `reboot`, `poweroff`, `halt`).
///
/// Each is a thin presentation layer over a kernel seam: `Kernel.wallClock`
/// through `ProcessContext.currentCalendarTime`, `/etc/passwd` and `/etc/group`
/// through `ProcessContext.userDatabase`, the terminal registry, and
/// `ProcessContext.requestPower`. None of them invents state the kernel does not
/// model.
///
/// Concurrency: plain synchronous programs over `ProcessContext`, run on the
/// kernel's single serial executor like every other built-in.
extension BuiltinCommands {

    static func systemCommands() -> [Command] {
        [
            // date [-u] [-d @EPOCH | -d 'YYYY-MM-DD[ HH:MM[:SS]]'] [+FORMAT]
            Command(name: "date", summary: "print the date and time", category: .system,
                    usage: "date [-u] [-d @EPOCH|'YYYY-MM-DD[ HH:MM[:SS]]'] [+FORMAT]\n  -u         print Coordinated Universal Time\n  -d STRING  display the time described by STRING instead of now\n  +FORMAT    strftime-style output format (%Y %m %d %H %M %S %s %F %T ...)") { ctx, argv in
                var utc = false
                var format: String?
                var dateSpec: String?
                var args = Array(argv.dropFirst())
                while !args.isEmpty {
                    let arg = args.removeFirst()
                    if arg == "-u" || arg == "--utc" || arg == "--universal" {
                        utc = true
                    } else if arg == "-d" || arg == "--date" {
                        guard !args.isEmpty else {
                            ctx.fail("date: option requires an argument -- 'd'", code: 1); return
                        }
                        dateSpec = args.removeFirst()
                    } else if arg.hasPrefix("--date=") {
                        dateSpec = String(arg.dropFirst("--date=".count))
                    } else if arg.hasPrefix("+"), format == nil {
                        format = String(arg.dropFirst())
                    } else if arg == "-s" || arg == "--set" || arg.hasPrefix("--set=") {
                        ctx.fail("date: setting the clock is not supported; the host owns it", code: 1)
                        return
                    } else {
                        ctx.fail("date: invalid argument '\(arg)'\n"
                            + "usage: date [-u] [-d @EPOCH|'YYYY-MM-DD[ HH:MM[:SS]]'] [+FORMAT]", code: 1)
                        return
                    }
                }
                let clock = ctx.wallClock
                let offset = utc ? 0 : clock.utcOffsetSeconds
                let instant: Double
                if let dateSpec {
                    guard let parsed = parseDateOperand(dateSpec, utcOffsetSeconds: offset) else {
                        ctx.fail("date: invalid date '\(dateSpec)'", code: 1); return
                    }
                    instant = Double(parsed)
                } else {
                    instant = ctx.realtimeSeconds
                }
                let time = ctx.calendarTime(instant, utc: utc)
                ctx.print((format.map(time.formatted) ?? time.dateCommandString) + "\n")
                ctx.exit(0)
            },

            // cal            — the current month
            // cal YEAR       — all twelve months of YEAR
            // cal MONTH YEAR — one month
            Command(name: "cal", summary: "print a calendar", category: .system,
                    usage: "cal [[MONTH] YEAR]") { ctx, argv in
                let args = Array(argv.dropFirst())
                let now = ctx.currentCalendarTime()
                var months: [(year: Int, month: Int)] = []
                switch args.count {
                case 0:
                    months = [(now.year, now.month)]
                case 1:
                    guard let year = Int(args[0]), (1...9_999).contains(year) else {
                        ctx.fail("cal: invalid year '\(args[0])'", code: 1); return
                    }
                    months = (1...12).map { (year, $0) }
                case 2:
                    guard let month = Int(args[0]), (1...12).contains(month) else {
                        ctx.fail("cal: invalid month '\(args[0])'", code: 1); return
                    }
                    guard let year = Int(args[1]), (1...9_999).contains(year) else {
                        ctx.fail("cal: invalid year '\(args[1])'", code: 1); return
                    }
                    months = [(year, month)]
                default:
                    ctx.usage("cal", "cal [[MONTH] YEAR]", code: 1); return
                }
                let pages = months.compactMap { CalendarTime.monthCalendar(year: $0.year, month: $0.month) }
                ctx.print(pages.joined(separator: "\n"))
                ctx.exit(0)
            },

            // id [-u|-g|-G] [-n] [USER] — numeric ids, with names from the
            // passwd/group databases. Without USER it reports this process's
            // live credentials; with USER, what a login as USER would get.
            Command(name: "id", summary: "print user and group ids", category: .system,
                    usage: "id [-u|-g|-G] [-n] [USER]\n  -u  print only the effective user id\n  -g  print only the effective group id\n  -G  print all group ids\n  -n  print names instead of numbers (with -u, -g or -G)") { ctx, argv in
                var only: Character?
                var names = false
                var operand: String?
                for arg in argv.dropFirst() {
                    if CommandArguments.isOptionToken(arg) {
                        for flag in arg.dropFirst() {
                            switch flag {
                            case "u", "g", "G":
                                guard only == nil || only == flag else {
                                    ctx.fail("id: cannot print \"only\" of more than one choice", code: 1)
                                    return
                                }
                                only = flag
                            case "n": names = true
                            default: ctx.fail("id: invalid option -- '\(flag)'", code: 1); return
                            }
                        }
                    } else if operand == nil {
                        operand = arg
                    } else {
                        ctx.fail("id: extra operand '\(arg)'", code: 1); return
                    }
                }
                if names, only == nil {
                    ctx.fail("id: cannot print only names in default format", code: 1); return
                }
                let database = ctx.userDatabase()
                let uid: UInt32
                let gid: UInt32
                let groups: [UInt32]
                if let operand {
                    guard let user = database.resolveUser(operand) else {
                        ctx.fail("id: '\(operand)': no such user", code: 1); return
                    }
                    uid = user.uid
                    gid = user.gid
                    groups = database.groupIDs(for: user)
                } else {
                    uid = ctx.getuid()
                    gid = ctx.getgid()
                    groups = [gid] + ctx.getgroups().filter { $0 != gid }
                }
                let userName = database.userName(uid: uid)
                func label(_ group: UInt32) -> String {
                    names ? database.groupName(gid: group) : String(group)
                }
                switch only {
                case "u": ctx.print((names ? userName : String(uid)) + "\n")
                case "g": ctx.print(label(gid) + "\n")
                case "G": ctx.print(groups.map(label).joined(separator: " ") + "\n")
                default:
                    let groupList = groups
                        .map { "\($0)(\(database.groupName(gid: $0)))" }
                        .joined(separator: ",")
                    ctx.print("uid=\(uid)(\(userName)) gid=\(gid)(\(database.groupName(gid: gid)))"
                        + " groups=\(groupList)\n")
                }
                ctx.exit(0)
            },

            // groups [USER] — group names, primary first.
            Command(name: "groups", summary: "print group memberships", category: .system,
                    usage: "groups [USER]") { ctx, argv in
                let args = Array(argv.dropFirst())
                let database = ctx.userDatabase()
                let groups: [UInt32]
                var prefix = ""
                if let operand = args.first {
                    guard let user = database.resolveUser(operand) else {
                        ctx.fail("groups: '\(operand)': no such user", code: 1); return
                    }
                    groups = database.groupIDs(for: user)
                    prefix = "\(user.name) : "
                } else {
                    let gid = ctx.getgid()
                    groups = [gid] + ctx.getgroups().filter { $0 != gid }
                }
                ctx.print(prefix + groups.map(database.groupName).joined(separator: " ") + "\n")
                ctx.exit(0)
            },

            // logname — the user who logged in on this session (unchanged by su).
            Command(name: "logname", summary: "print the login name", category: .system,
                    usage: "logname") { ctx, _ in
                guard let uid = ctx.loginUID else {
                    ctx.fail("logname: no login name", code: 1); return
                }
                ctx.print(ctx.userDatabase().userName(uid: uid) + "\n")
                ctx.exit(0)
            },

            // who — one line per session attached to a terminal. When no
            // session owns a terminal (a headless kernel), the caller's own
            // login is reported without a terminal.
            Command(name: "who", summary: "show who is logged in", category: .system,
                    usage: "who") { ctx, _ in
                ctx.print(sessionRows(ctx).map {
                    "\(pad($0.user, 8)) \(pad($0.terminal, 12)) \($0.login.formatted("%F %R"))"
                }.joined(separator: "\n") + "\n")
                ctx.exit(0)
            },

            // w — `who` plus the uptime header and each terminal's foreground job.
            Command(name: "w", summary: "show who is logged in and what they run", category: .system,
                    usage: "w") { ctx, _ in
                let rows = sessionRows(ctx)
                let uptime = Int(ctx.monotonicNanoseconds / 1_000_000_000)
                let up = "\(uptime / 3_600):\(CalendarTime.pad((uptime % 3_600) / 60, 2))"
                var out = " \(ctx.currentCalendarTime().formatted("%T")) up \(up),"
                    + "  \(rows.count) user\(rows.count == 1 ? "" : "s")\n"
                out += "\(pad("USER", 8)) \(pad("TTY", 8)) \(pad("LOGIN@", 16)) WHAT\n"
                for row in rows {
                    out += "\(pad(row.user, 8)) \(pad(row.terminal, 8))"
                        + " \(row.login.formatted("%F %R")) \(row.command)\n"
                }
                ctx.print(out)
                ctx.exit(0)
            },

            // tty [-s] — name of the terminal on standard input.
            Command(name: "tty", summary: "print the terminal name", category: .system,
                    usage: "tty [-s]\n  -s  print nothing, only return an exit status") { ctx, argv in
                let silent = argv.dropFirst().contains("-s")
                guard let name = ctx.terminalName(0) else {
                    if !silent { ctx.print("not a tty\n") }
                    ctx.exit(1)
                    return
                }
                if !silent { ctx.print("/dev/\(name)\n") }
                ctx.exit(0)
            },

            // stty [size | -a | raw | -raw | cooked | sane | rows N | cols N]
            // Reports and changes exactly the terminal state the PTY models:
            // window size and raw vs. canonical mode. There is no line speed or
            // per-flag termios to show.
            Command(name: "stty", summary: "show or change terminal settings", category: .system,
                    usage: "stty [-a | size | raw | -raw | cooked | sane | rows N | cols N]...") { ctx, argv in
                guard let size = ctx.terminalWindowSize(0), let raw = ctx.terminalRawMode(0) else {
                    ctx.fail("stty: standard input: Inappropriate ioctl for device", code: 1); return
                }
                var args = Array(argv.dropFirst())
                if args.isEmpty || args == ["-a"] || args == ["--all"] {
                    ctx.print("rows \(size.rows); columns \(size.columns);\n"
                        + (raw ? "-icanon -isig" : "icanon isig") + "\n")
                    ctx.exit(0)
                    return
                }
                if args == ["size"] {
                    ctx.print("\(size.rows) \(size.columns)\n")
                    ctx.exit(0)
                    return
                }
                var rows = size.rows
                var columns = size.columns
                var rawMode = raw
                while !args.isEmpty {
                    let arg = args.removeFirst()
                    switch arg {
                    case "raw": rawMode = true
                    case "-raw", "cooked", "sane": rawMode = false
                    case "rows", "cols", "columns":
                        guard let value = args.first.flatMap(Int.init), value > 0 else {
                            ctx.fail("stty: invalid integer argument for '\(arg)'", code: 1); return
                        }
                        args.removeFirst()
                        if arg == "rows" { rows = value } else { columns = value }
                    default:
                        ctx.fail("stty: unsupported argument '\(arg)'", code: 1); return
                    }
                }
                ctx.setTerminalWindowSize(0, WindowSize(rows: rows, columns: columns))
                ctx.setTerminalRawMode(0, rawMode)
                ctx.exit(0)
            },

            // shutdown [-h|-P|-H|-r] [now] — only an immediate request exists:
            // there is no kernel timer service to schedule one for later.
            Command(name: "shutdown", summary: "ask the host to power off or reboot", category: .system,
                    usage: "shutdown [-h|-r] [now]\n  -h, -P  power off (default)\n  -r      reboot") { ctx, argv in
                var request = PowerRequest.shutdown
                for arg in argv.dropFirst() {
                    switch arg {
                    case "-h", "-P", "-H", "--halt", "--poweroff": request = .shutdown
                    case "-r", "--reboot": request = .reboot
                    case "now", "+0", "0": break
                    default:
                        ctx.fail("shutdown: unsupported argument '\(arg)'\n"
                            + "usage: shutdown [-h|-r] [now]", code: 1)
                        return
                    }
                }
                requestPower(ctx, "shutdown", request)
            },
            Command(name: "reboot", summary: "ask the host to reboot", category: .system,
                    usage: "reboot") { ctx, _ in
                requestPower(ctx, "reboot", .reboot)
            },
            Command(name: "poweroff", summary: "ask the host to power off", category: .system,
                    usage: "poweroff") { ctx, _ in
                requestPower(ctx, "poweroff", .shutdown)
            },
            Command(name: "halt", summary: "ask the host to halt", category: .system,
                    usage: "halt") { ctx, _ in
                requestPower(ctx, "halt", .shutdown)
            },
        ]
    }

    /// Forward a power request and report the two ways it can be refused.
    private static func requestPower(_ ctx: ProcessContext, _ command: String, _ request: PowerRequest) {
        do {
            guard try ctx.requestPower(request) else {
                ctx.fail("\(command): power control is not supported by this host", code: 1)
                return
            }
            ctx.exit(0)
        } catch {
            ctx.fail("\(command): must be superuser", code: 1)
        }
    }

    private struct SessionRow {
        let user: String
        let terminal: String
        let login: CalendarTime
        let command: String
    }

    /// Terminal sessions as `who`/`w` rows, or — when none exists — the
    /// caller's own login with `?` for the terminal.
    private static func sessionRows(_ ctx: ProcessContext) -> [SessionRow] {
        let database = ctx.userDatabase()
        let sessions = ctx.terminalSessions()
        guard sessions.isEmpty else {
            return sessions.map {
                SessionRow(user: database.userName(uid: $0.uid),
                           terminal: "pts/\($0.terminalIndex)",
                           login: ctx.calendarTime($0.startEpoch),
                           command: $0.foregroundCommand)
            }
        }
        return [SessionRow(user: database.userName(uid: ctx.loginUID ?? ctx.getuid()),
                           terminal: "?",
                           login: ctx.currentCalendarTime(),
                           command: ctx.arguments.first ?? "-")]
    }

    /// Left-justify `text` in a field `width` wide (no truncation).
    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// Parse a `date -d` operand: `@EPOCH`, or `YYYY-MM-DD` optionally followed
    /// by `HH:MM` or `HH:MM:SS` (separated by a space or `T`), interpreted in
    /// the zone `utcOffsetSeconds` east of UTC. Returns epoch seconds.
    static func parseDateOperand(_ text: String, utcOffsetSeconds: Int) -> Int64? {
        if text.hasPrefix("@") { return Int64(text.dropFirst()) }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "T" })
        guard (1...2).contains(parts.count) else { return nil }
        let date = parts[0].split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard date.count == 3, let year = date[0], let month = date[1], let day = date[2],
              (1...9_999).contains(year), (1...12).contains(month),
              (1...CalendarTime.daysInMonth(year: year, month: month)).contains(day) else { return nil }
        var clock = [0, 0, 0]
        if parts.count == 2 {
            let fields = parts[1].split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
            guard (2...3).contains(fields.count) else { return nil }
            for (index, field) in fields.enumerated() {
                guard let field else { return nil }
                clock[index] = field
            }
            guard (0...23).contains(clock[0]), (0...59).contains(clock[1]),
                  (0...59).contains(clock[2]) else { return nil }
        }
        return CalendarTime.epochSeconds(year: year, month: month, day: day,
                                         hour: clock[0], minute: clock[1], second: clock[2],
                                         utcOffsetSeconds: utcOffsetSeconds)
    }
}
