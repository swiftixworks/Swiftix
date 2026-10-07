/// The command layer: a uniform "program" abstraction plus the registry the
/// shell consults to run one.
///
/// This is the framework seam for *which programs exist*. The library provides
/// the mechanism — a stable program contract (`Command`), a lookup table
/// (`CommandRegistry`), and a curated set of built-ins (`CommandRegistry.builtins`,
/// a coreutils-like base) — while the *policy* of the available command set is
/// open for the consumer to extend or replace. This mirrors the rest of Swiftix,
/// where topology and UI are the consumer's job: the shell ships working, but is
/// not a closed list of hard-coded `if`/`switch` branches.
///
/// A command is just a native program: it receives a `ProcessContext` and its
/// argument vector, does its I/O through the syscall surface, and sets its exit
/// status with `ctx.exit(_:)`. The core has no native binary ABI: running `cat`,
/// running `ping`, and an image adapted by an executable loader all converge on
/// the same `Command` process contract. File-backed executable formats remain
/// optional and are supplied by consumer modules through
/// `registerExecutableLoader(_:)`.
///
/// Concurrency: `Command`/`CommandRegistry` are part of the non-Sendable
/// reference-type core (like `ProcessContext`). They are constructed and used on
/// the single serial executor that drives the kernel, so they hold no locks and
/// are not `Sendable`.

/// A runnable program: a name (how the shell resolves it), a one-line summary
/// (for `help`), a `category` (how `help` groups it), and the body to run. The
/// body owns its exit status — call `ctx.exit(code)`; a body that simply returns
/// is reaped with code 0.
public struct Command {
    public let name: String
    public let summary: String
    public let category: Category

    /// The coarse grouping a command belongs to. Purely presentational — it lets
    /// `help` print a categorized listing instead of one flat alphabetical block,
    /// which matters once the built-in set grows past a handful of names. A
    /// consumer that registers its own command may pick a category or accept the
    /// `.other` default. Cases carry a display `title` and a fixed `order` so the
    /// `help` sections always appear in the same, sensible sequence.
    public enum Category: Sendable, CaseIterable {
        case fileSystem   // ls, cat, cp, find, …
        case text         // echo, grep, wc, sort, …
        case process      // ps, kill, jobs, …
        case network      // ping, ifconfig, netstat, nc, …
        case system       // env, uname, sleep, clear, …
        case other        // consumer-registered, uncategorized

        /// Section header used by `help`.
        public var title: String {
            switch self {
            case .fileSystem: return "filesystem"
            case .text:       return "text"
            case .process:    return "process"
            case .network:    return "network"
            case .system:     return "system"
            case .other:      return "other"
            }
        }

        /// Fixed display order for `help` sections (lower comes first).
        var order: Int {
            switch self {
            case .fileSystem: return 0
            case .text:       return 1
            case .process:    return 2
            case .network:    return 3
            case .system:     return 4
            case .other:      return 5
            }
        }
    }

    /// A program body comes in two flavors: a synchronous one (continuation-style
    /// I/O, like `cat`) or an `async` one (linear `await`-driven I/O, the natural
    /// shape for servers and clients). The shell spawns each on the matching
    /// `Kernel.spawn` overload, so both run on the single loop-bound executor.
    /// `argv[0]` is the command name; `argv[1...]` are its arguments (identical to
    /// `ctx.arguments`, passed for convenience).
    enum Body {
        case sync((_ ctx: ProcessContext, _ argv: [String]) -> Void)
        case async((_ ctx: ProcessContext, _ argv: [String]) async -> Void)
    }

    let body: Body

    /// Optional long help: the synopsis on the first line (without the leading
    /// `Usage: `, e.g. `ls [-alh] [FILE]...`) followed by one line per option.
    /// `cmd --help` and `man cmd` render it; `nil` falls back to a generic
    /// synopsis built from the name and summary.
    public let usage: String?

    /// A synchronous program. It does its I/O through continuation-style syscalls
    /// and sets its exit status with `ctx.exit(_:)`; a body that simply returns is
    /// reaped with code 0.
    public init(name: String,
                summary: String,
                category: Category = .other,
                run: @escaping (_ ctx: ProcessContext, _ argv: [String]) -> Void) {
        self.init(name: name, summary: summary, category: category, usage: nil, body: .sync(run))
    }

    /// A synchronous program with long help text (see `usage`).
    public init(name: String,
                summary: String,
                category: Category = .other,
                usage: String?,
                run: @escaping (_ ctx: ProcessContext, _ argv: [String]) -> Void) {
        self.init(name: name, summary: summary, category: category, usage: usage, body: .sync(run))
    }

    /// An `async` program, written in linear `await` style over the async syscall
    /// frontend (`await ctx.tcpAccept(fd)`, `try await ctx.sleep(_:)`, …). Ideal for
    /// long-running servers and clients. Uses a distinct argument label so the
    /// sync/async overloads never collide at the call site.
    public init(name: String,
                summary: String,
                category: Category = .other,
                asyncRun: @escaping (_ ctx: ProcessContext, _ argv: [String]) async -> Void) {
        self.init(name: name, summary: summary, category: category, usage: nil, body: .async(asyncRun))
    }

    /// An `async` program with long help text (see `usage`).
    public init(name: String,
                summary: String,
                category: Category = .other,
                usage: String?,
                asyncRun: @escaping (_ ctx: ProcessContext, _ argv: [String]) async -> Void) {
        self.init(name: name, summary: summary, category: category, usage: usage, body: .async(asyncRun))
    }

    init(name: String, summary: String, category: Category, usage: String?, body: Body) {
        self.name = name
        self.summary = summary
        self.category = category
        self.usage = usage
        self.body = body
    }

    /// The same command with a different long help text (`nil` keeps it).
    func withUsage(_ usage: String?) -> Command {
        guard let usage else { return self }
        return Command(name: name, summary: summary, category: category, usage: usage, body: body)
    }

    /// The first line of the help text: `Usage: <synopsis>`.
    var synopsis: String {
        let line = usage?.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        return line ?? "\(name) [OPTION]... [ARG]..."
    }

    /// The option lines of `usage` (everything after the synopsis), or `nil`.
    var optionHelp: String? {
        guard let usage, let newline = usage.firstIndex(of: "\n") else { return nil }
        let rest = usage[usage.index(after: newline)...]
        return rest.isEmpty ? nil : String(rest)
    }

    /// What `cmd --help` prints.
    var helpText: String {
        var text = "Usage: \(synopsis)\n\(summary)\n"
        if let optionHelp { text += "\n" + optionHelp + (optionHelp.hasSuffix("\n") ? "" : "\n") }
        return text
    }

    /// The same command with `--help` handled up front: when it is the first
    /// argument the help text is printed and the command exits 0 without running.
    /// Applied to the whole built-in set in one place (`CommandRegistry.builtins`)
    /// so no command needs its own `--help` branch.
    func answeringHelp() -> Command {
        let help = helpText
        func wantsHelp(_ argv: [String]) -> Bool { argv.count > 1 && argv[1] == "--help" }
        let wrapped: Body
        switch body {
        case let .sync(run):
            wrapped = .sync { ctx, argv in
                if wantsHelp(argv) { ctx.print(help); ctx.exit(0); return }
                run(ctx, argv)
            }
        case let .async(run):
            wrapped = .async { ctx, argv in
                if wantsHelp(argv) { ctx.print(help); ctx.exit(0); return }
                await run(ctx, argv)
            }
        }
        return Command(name: name, summary: summary, category: category, usage: usage, body: wrapped)
    }
}

/// A lookup table from command name to `Command` — the shell's "PATH". It is a
/// reference type so a program set can be extended in place (and so a `help`
/// command can reflect the *live* set, including anything a consumer added).
public final class CommandRegistry {
    public typealias ExecutableLoader = (_ context: ProcessContext, _ path: String) -> Command?

    private var commands: [String: Command] = [:]
    private var executableLoaders: [ExecutableLoader] = []

    public init() {}

    /// Register (or replace) a command by its name.
    public func register(_ command: Command) {
        commands[command.name] = command
    }

    /// Add a file-backed executable format. Loaders are queried in registration
    /// order after native command lookup fails; returning `nil` means the file is
    /// not recognized by that loader. This keeps executable formats outside the
    /// core shell while preserving the same `Command` process contract.
    public func registerExecutableLoader(_ loader: @escaping ExecutableLoader) {
        executableLoaders.append(loader)
    }

    /// Resolve a command by name, or `nil` if not registered.
    public func resolve(_ name: String) -> Command? {
        commands[name]
    }

    /// Resolve a native command or a file-backed executable in `context`.
    public func resolve(_ name: String, in context: ProcessContext) -> Command? {
        if let command = commands[name] { return command }
        for loader in executableLoaders {
            if let command = loader(context, name) { return command }
        }
        return nil
    }

    /// All registered command names, sorted.
    public var names: [String] {
        commands.keys.sorted()
    }

    /// A `help`-style listing of every registered command and its summary,
    /// computed from the live set so consumer-added commands appear too. Commands
    /// are grouped by `Command.Category` (sections in a fixed order, names sorted
    /// within each), so a growing built-in set stays readable instead of
    /// collapsing into one long alphabetical block. Empty sections are omitted, so
    /// a registry that only uses a couple of categories prints only those.
    public func helpText() -> String {
        let grouped = Dictionary(grouping: commands.values, by: { $0.category })
        var text = "commands:\n"
        for category in Command.Category.allCases.sorted(by: { $0.order < $1.order }) {
            guard let group = grouped[category], !group.isEmpty else { continue }
            text += "\(category.title):\n"
            text += group
                .sorted { $0.name < $1.name }
                .map { "  \($0.name) — \($0.summary)" }
                .joined(separator: "\n")
            text += "\n"
        }
        return text
    }

    /// A fresh registry preloaded with the built-in, coreutils-like command set.
    /// Returns a new instance each time so each shell owns a registry it can
    /// extend independently. Consumers add their own commands with `register(_:)`.
    public static var builtins: CommandRegistry {
        let registry = CommandRegistry()
        for command in BuiltinCommands.all() {
            // `--help` is answered centrally. The few commands whose arguments
            // are data rather than options (`echo --help` prints `--help`) opt out.
            let literalArguments = BuiltinCommands.commandsWithoutHelpOption.contains(command.name)
            registry.register(literalArguments ? command : command.answeringHelp())
        }
        ShellCommands.register(in: registry)
        // `help` reflects the live registry (built-ins + anything registered
        // later). Weak capture avoids a retain cycle: the closure is stored in
        // `registry`, and the shell that owns `registry` keeps it alive while the
        // command runs.
        registry.register(Command(name: "help", summary: "list available commands", category: .system,
                                  usage: "help\nRun 'COMMAND --help' or 'man COMMAND' for one command.") { [weak registry] ctx, _ in
            ctx.print(registry?.helpText() ?? "")
            ctx.exit(0)
        }.answeringHelp())
        return registry
    }
}

/// The built-in command implementations (the coreutils-like base set). Kept
/// `internal`: consumers get them through `CommandRegistry.builtins`, not by
/// name. Each is a plain program using the syscall surface, so it can block,
/// stream, and set a real exit code — none of the old "return a byte buffer"
/// limitation.
enum BuiltinCommands {

    /// Build the coreutils-like base set. A function (not stored `static let`s)
    /// so no non-`Sendable` `Command` value ever becomes global mutable state —
    /// each registry gets its own freshly-built commands. Assembled from
    /// category-grouped helpers: the base set here plus the text filters,
    /// extended filesystem tools, process tools, and network diagnostics/clients
    /// defined in the sibling `*Commands.swift` files.
    static func all() -> [Command] {
        base() + textFilters() + sedCommands() + extendedFileSystem() + fileTreeCommands() + processCommands()
            + networkCommands() + metaCommands() + controlCommands()
            + controlGroupCommands() + mountCommands()
            + binaryCommands() + calculatorCommands() + archiveCommands()
            + systemCommands() + awkCommands()
    }

    /// Commands that treat every argument as data, so `--help` is not an option.
    static let commandsWithoutHelpOption: Set<String> = ["echo", "test", "[", "expr"]

    /// The original coreutils-like base (working directory, system info,
    /// exit-code stubs, and the ping/tcpecho/httpd network programs). The file
    /// and text tools that started here now live with their category
    /// (`FileSystemCommands.swift`, `TextFilterCommands.swift`, `MetaCommands.swift`).
    static func base() -> [Command] {
        [
            Command(name: "pwd", summary: "print working directory", category: .fileSystem,
                    usage: "pwd") { ctx, _ in
                ctx.print(ctx.currentDirectory + "\n")
                ctx.exit(0)
            },

            // `cd` is also handled intrinsically by the shell (it must change the
            // shell's own cwd). Registered here so it appears in `help` and works
            // when a program invokes it in its own process.
            Command(name: "cd", summary: "change working directory", category: .fileSystem,
                    usage: "cd [DIR]") { ctx, argv in
                let path = argv.count > 1 ? argv[1] : (ctx.getenv("HOME") ?? "/")
                if ctx.chdir(path) {
                    ctx.exit(0)
                } else {
                    let reason: String
                    if let info = ctx.stat(path) {
                        reason = info.isDirectory ? SyscallError.permissionDenied.message
                                                  : SyscallError.notADirectory.message
                    } else {
                        reason = SyscallError.noSuchFileOrDirectory.message
                    }
                    ctx.error("cd: \(path): \(reason)")
                    ctx.exit(1)
                }
            },

            // Async program: demonstrates a linear `await`-style body and the
            // `sleep` syscall. `sleep <seconds>` (default 1).
            Command(name: "sleep", summary: "wait for N seconds", category: .system,
                    usage: "sleep NUMBER[smhd]...\nPause for the sum of the given durations (logical time).",
                    asyncRun: { ctx, argv in
                guard argv.count > 1 else {
                    ctx.error("sleep: missing operand")
                    ctx.fail("Try 'sleep --help' for more information.", code: 1); return
                }
                var seconds = 0.0
                for token in argv.dropFirst() {
                    var text = Substring(token)
                    var scale = 1.0
                    if let unit = text.last, unit.isLetter {
                        switch unit {
                        case "s": scale = 1
                        case "m": scale = 60
                        case "h": scale = 3600
                        case "d": scale = 86400
                        default: ctx.fail("sleep: invalid time interval '\(token)'", code: 1); return
                        }
                        text = text.dropLast()
                    }
                    guard let value = Double(text), value >= 0 else {
                        ctx.fail("sleep: invalid time interval '\(token)'", code: 1); return
                    }
                    seconds += value * scale
                }
                do {
                    try await ctx.sleep(seconds)
                    ctx.exit(0)
                } catch SyscallError.interrupted {
                    // The kernel is already applying the signal exit status.
                } catch {
                    ctx.exit(1)
                }
            }),

            // `uname` prints system identity. `-s` kernel name (default), `-n`
            // node/hostname (read live from the UTS namespace), `-r` release,
            // `-m` machine, `-a` all. Honoring the UTS namespace means an
            // `unshare -u` + `hostname` change shows up in `uname -n`.
            Command(name: "uname", summary: "print system information", category: .system,
                    usage: """
                    uname [-asnrm]
                      -a  print all fields
                      -s  kernel name (default)
                      -n  network node hostname
                      -r  kernel release
                      -m  machine hardware name
                    """) { ctx, argv in
                guard let parsed = ctx.options("uname", Array(argv.dropFirst()), "asnrmvop") else { return }
                let flags = Set(parsed.flags.keys.map { "-\($0)" })
                let sysname = "Swiftix"
                let release = Swiftix.version
                let machine = "swiftvm"
                if flags.contains("-a") {
                    ctx.print("\(sysname) \(ctx.hostname) \(release) \(machine)\n")
                    ctx.exit(0)
                    return
                }
                // Assemble the requested fields in the canonical -s -n -r -m order;
                // no flags means just the kernel name.
                var fields: [String] = []
                if flags.contains("-s") || flags.isEmpty { fields.append(sysname) }
                if flags.contains("-n") { fields.append(ctx.hostname) }
                if flags.contains("-r") { fields.append(release) }
                if flags.contains("-m") { fields.append(machine) }
                ctx.print(fields.joined(separator: " ") + "\n")
                ctx.exit(0)
            },

            Command(name: "whoami", summary: "print current user", category: .system,
                    usage: "whoami") { ctx, _ in
                // The login name of the effective uid, from the user database.
                ctx.print(ctx.userName + "\n")
                ctx.exit(0)
            },

            // `hostname` with no argument prints the name from the caller's UTS
            // namespace; `hostname NAME` sets it there. Under a plain shell that
            // is the machine-wide name; under `unshare -u` it changes only the
            // private namespace — the isolation lesson.
            Command(name: "hostname", summary: "show or set the host name", category: .system,
                    usage: """
                    hostname [-s|-f|-i|-I] [NAME]
                      -s  short name (up to the first dot)
                      -f  fully qualified name
                      -i  the address the host name stands for
                      -I  every configured non-loopback address
                    With NAME, set the host name (in the caller's UTS namespace).
                    """) { ctx, argv in
                guard let parsed = ctx.options("hostname", Array(argv.dropFirst()), "sfiI",
                                               long: ["short": "s", "fqdn": "f", "long": "f",
                                                      "ip-address": "i", "all-ip-addresses": "I"]) else { return }
                let addresses = ctx.snapshotNetworkLinks().filter { !$0.isLoopback }.map { "\($0.address)" }
                if parsed.has("I") {
                    // One trailing space per address, as net-tools prints it.
                    ctx.print(addresses.map { $0 + " " }.joined() + "\n")
                } else if parsed.has("i") {
                    ctx.print((addresses.first ?? "127.0.0.1") + "\n")
                } else if parsed.has("s") {
                    ctx.print(ctx.hostname.split(separator: ".", omittingEmptySubsequences: false)[0] + "\n")
                } else if parsed.has("f") {
                    ctx.print(ctx.hostname + "\n")
                } else if let newName = parsed.operands.first {
                    guard parsed.operands.count == 1, !newName.isEmpty else {
                        ctx.usage("hostname", "hostname [-s|-f|-i|-I] [NAME]"); return
                    }
                    ctx.setHostname(newName)
                } else {
                    ctx.print(ctx.hostname + "\n")
                }
                ctx.exit(0)
            },

            Command(name: "clear", summary: "clear the screen", category: .system,
                    usage: "clear") { ctx, _ in
                // Clear screen + home cursor (the minimal ANSI subset the terminal renders).
                ctx.print("\u{1B}[2J\u{1B}[H")
                ctx.exit(0)
            },

            // `true` / `false` as real programs with meaningful exit codes.
            Command(name: "true", summary: "exit with status 0", category: .system,
                    usage: "true") { ctx, _ in
                ctx.exit(0)
            },

            Command(name: "false", summary: "exit with status 1", category: .system,
                    usage: "false") { ctx, _ in
                ctx.exit(1)
            },

            // An async TCP echo server: `tcpecho [port]` (default 7). Written in
            // linear `await` style over the async syscall frontend. It listens,
            // then loops accepting connections and echoing each until the peer
            // closes — a long-running program that never exits on its own. This is
            // the target shape for user-authored servers (HTTP, etc.): just a
            // `Command`, resolved and launched like any other.
            // An async TCP echo server built on the `serveTCP` scaffolding: it
            // only supplies the per-connection logic (echo until EOF); the accept
            // loop and per-connection concurrency come from the helper.
            Command(name: "tcpecho", summary: "TCP echo server", category: .network,
                    usage: "tcpecho [PORT]\nEcho every TCP connection on PORT (default 7).", asyncRun: { ctx, argv in
                let port = argv.count > 1 ? (UInt16(argv[1]) ?? 7) : 7
                // Announce only once the socket is actually listening; a failed
                // bind (port in use) prints an error from serveTCP and exits.
                await Programs.serveTCP(ctx, port: port, onListening: {
                    ctx.print("tcpecho: listening on \(port)\n")
                }) { conn, fd in
                    while let bytes = try? await conn.tcpRecv(fd), !bytes.isEmpty {
                        _ = conn.tcpSend(fd, bytes)
                    }
                }
            }),
        ]
    }

    /// Format a non-negative `Double` as fixed-point with `places` decimals,
    /// without Foundation (the core forbids it) — used by `ping` for `time=`,
    /// loss %, and the rtt summary. Rounds half-to-even via integer scaling; ping
    /// values (milliseconds, percentages) are small, so overflow is not a concern.
    static func fixedPoint(_ value: Double, places: Int) -> String {
        let clamped = value < 0 ? 0 : value
        var scale = 1
        for _ in 0..<max(0, places) { scale *= 10 }
        let total = Int((clamped * Double(scale)).rounded())
        let whole = total / scale
        let fraction = total % scale
        guard places > 0 else { return "\(whole)" }
        var fractionText = "\(fraction)"
        while fractionText.count < places { fractionText = "0" + fractionText }
        return "\(whole).\(fractionText)"
    }
}
