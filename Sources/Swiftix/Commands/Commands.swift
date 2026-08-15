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

    /// A synchronous program. It does its I/O through continuation-style syscalls
    /// and sets its exit status with `ctx.exit(_:)`; a body that simply returns is
    /// reaped with code 0.
    public init(name: String,
                summary: String,
                category: Category = .other,
                run: @escaping (_ ctx: ProcessContext, _ argv: [String]) -> Void) {
        self.name = name
        self.summary = summary
        self.category = category
        self.body = .sync(run)
    }

    /// An `async` program, written in linear `await` style over the async syscall
    /// frontend (`await ctx.tcpAccept(fd)`, `try await ctx.sleep(_:)`, …). Ideal for
    /// long-running servers and clients. Uses a distinct argument label so the
    /// sync/async overloads never collide at the call site.
    public init(name: String,
                summary: String,
                category: Category = .other,
                asyncRun: @escaping (_ ctx: ProcessContext, _ argv: [String]) async -> Void) {
        self.name = name
        self.summary = summary
        self.category = category
        self.body = .async(asyncRun)
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
            registry.register(command)
        }
        // `help` reflects the live registry (built-ins + anything registered
        // later). Weak capture avoids a retain cycle: the closure is stored in
        // `registry`, and the shell that owns `registry` keeps it alive while the
        // command runs.
        registry.register(Command(name: "help", summary: "list available commands", category: .system) { [weak registry] ctx, _ in
            ctx.print(registry?.helpText() ?? "")
            ctx.exit(0)
        })
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
        base() + textFilters() + extendedFileSystem() + processCommands()
            + networkCommands() + metaCommands() + controlCommands()
            + controlGroupCommands() + mountCommands()
    }

    /// The original coreutils-like base (file I/O, environment/system info,
    /// exit-code stubs, and the ping/tcpecho/httpd network programs).
    static func base() -> [Command] {
        [
            Command(name: "echo", summary: "print arguments", category: .text) { ctx, argv in
                ctx.print(argv.dropFirst().joined(separator: " ") + "\n")
                ctx.exit(0)
            },

            Command(name: "cat", summary: "print file contents (or stdin)", category: .fileSystem) { ctx, argv in
                let paths = Array(argv.dropFirst())
                // No file arguments: copy stdin (fd 0) to stdout (fd 1) until EOF.
                // This is what makes `cat` usable as a pipeline/redirection filter
                // (`echo hi | cat`, `cat < file`).
                guard !paths.isEmpty else {
                    func pump() {
                        ctx.read(0) { bytes in
                            if bytes.isEmpty { ctx.exit(0); return }   // EOF
                            ctx.write(1, bytes)
                            pump()
                        }
                    }
                    pump()
                    return
                }
                var status: Int32 = 0
                for path in paths {
                    guard let fd = ctx.open(path) else {
                        ctx.error("cat: \(path): No such file or directory")
                        status = 1
                        continue
                    }
                    ctx.write(1, ctx.read(fd, max: 65535))
                    ctx.close(fd)
                }
                ctx.exit(status)
            },

            Command(name: "mkdir", summary: "create a directory", category: .fileSystem) { ctx, argv in
                let dirs = Array(argv.dropFirst())
                guard !dirs.isEmpty else { ctx.fail("mkdir: missing operand"); return }
                var status: Int32 = 0
                for dir in dirs where !ctx.mkdir(dir) {
                    ctx.error("mkdir: cannot create directory '\(dir)'")
                    status = 1
                }
                ctx.exit(status)
            },

            Command(name: "rm", summary: "remove a file or empty directory", category: .fileSystem) { ctx, argv in
                let paths = Array(argv.dropFirst())
                guard !paths.isEmpty else { ctx.fail("rm: missing operand"); return }
                var status: Int32 = 0
                for path in paths where !ctx.remove(path) {
                    ctx.error("rm: cannot remove '\(path)': No such file or directory")
                    status = 1
                }
                ctx.exit(status)
            },

            Command(name: "touch", summary: "create an empty file", category: .fileSystem) { ctx, argv in
                let paths = Array(argv.dropFirst())
                guard !paths.isEmpty else { ctx.fail("touch: missing operand"); return }
                var status: Int32 = 0
                for path in paths {
                    if let fd = ctx.open(path, create: true) { ctx.close(fd) } else { status = 1 }
                }
                ctx.exit(status)
            },

            Command(name: "stat", summary: "print file metadata", category: .fileSystem) { ctx, argv in
                guard argv.count > 1 else {
                    ctx.fail("stat: missing operand", code: 1); return
                }
                guard let info = ctx.stat(argv[1]) else {
                    ctx.error("stat: cannot stat '\(argv[1])': No such file or directory")
                    ctx.exit(1)
                    return
                }
                let typeStr: String
                switch info.type {
                case .directory: typeStr = "directory"
                case .symlink:   typeStr = "symbolic link"
                case .regular:   typeStr = "regular file"
                case .fifo:      typeStr = "fifo"
                }
                let octal = String(info.mode.rawValue, radix: 8)
                let rwx = BuiltinCommands.modeString(info.mode)
                var out = "  File: \(argv[1])\n"
                out += "  Size: \(info.size)\tLinks: \(info.nlink)\tType: \(typeStr)\n"
                out += "Access: (0\(octal)/\(rwx))\tUid: \(info.uid)\tGid: \(info.gid)\n"
                out += "Access: \(info.atime)\n"
                out += "Modify: \(info.mtime)\n"
                out += "Change: \(info.ctime)\n"
                ctx.print(out)
                ctx.exit(0)
            },

            Command(name: "ls", summary: "list a directory", category: .fileSystem) { ctx, argv in
                var args = Array(argv.dropFirst())
                var longFormat = false
                var showAll = false
                // Parse leading option flags (combined `-la` allowed).
                while let first = args.first, CommandArguments.isOptionToken(first) {
                    for flag in first.dropFirst() {
                        switch flag {
                        case "l": longFormat = true
                        case "a": showAll = true
                        default:
                            ctx.fail("ls: unknown option -\(flag)"); return
                        }
                    }
                    args.removeFirst()
                }
                let path = args.first ?? "."
                guard let entries = ctx.listDirectory(path) else {
                    ctx.error("ls: cannot access '\(path)': No such file or directory")
                    ctx.exit(2)
                    return
                }
                // Filter dotfiles unless -a.
                let visible = showAll ? entries : entries.filter { entry in
                    let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
                    return !name.hasPrefix(".")
                }
                if longFormat {
                    // Collect metadata for column-width calculation.
                    struct Entry {
                        let typeChar: Character
                        let mode: String
                        let nlink: String
                        let uid: String
                        let gid: String
                        let size: String
                        let name: String
                    }
                    var items: [Entry] = []
                    var maxNlink = 0, maxUid = 0, maxGid = 0, maxSize = 0
                    for entry in visible {
                        let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
                        let full = path == "/" ? "/" + name : (path == "." ? name : path + "/" + name)
                        let info = ctx.stat(full)
                        let typeChar = info.map { BuiltinCommands.fileTypeChar($0.type) } ?? "-"
                        let mode = info.map { BuiltinCommands.modeString($0.mode) } ?? "---------"
                        let nlink = "\(info?.nlink ?? 1)"
                        let uid = "\(info?.uid ?? 0)"
                        let gid = "\(info?.gid ?? 0)"
                        let size = "\(info?.size ?? 0)"
                        items.append(Entry(typeChar: typeChar, mode: mode, nlink: nlink,
                                           uid: uid, gid: gid, size: size, name: name))
                        maxNlink = max(maxNlink, nlink.count)
                        maxUid = max(maxUid, uid.count)
                        maxGid = max(maxGid, gid.count)
                        maxSize = max(maxSize, size.count)
                    }
                    ctx.print("total \(items.count)\n")
                    for item in items {
                        let line = "\(item.typeChar)\(item.mode) "
                            + "\(BuiltinCommands.padLeft(item.nlink, maxNlink)) "
                            + "\(BuiltinCommands.padLeft(item.uid, maxUid)) "
                            + "\(BuiltinCommands.padLeft(item.gid, maxGid)) "
                            + "\(BuiltinCommands.padLeft(item.size, maxSize)) "
                            + "\(item.name)\n"
                        ctx.print(line)
                    }
                } else {
                    if !visible.isEmpty {
                        // Strip trailing "/" from directory entries for plain listing.
                        // Default ls separates names with two spaces on a single line
                        // (matching the terminal-output behavior of Linux ls).
                        let names = visible.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
                        ctx.print(names.joined(separator: "  ") + "\n")
                    }
                }
                ctx.exit(0)
            },

            Command(name: "pwd", summary: "print working directory", category: .fileSystem) { ctx, _ in
                ctx.print(ctx.currentDirectory + "\n")
                ctx.exit(0)
            },

            // `cd` is also handled intrinsically by the shell (it must change the
            // shell's own cwd). Registered here so it appears in `help` and works
            // when a program invokes it in its own process.
            Command(name: "cd", summary: "change working directory", category: .fileSystem) { ctx, argv in
                let path = argv.count > 1 ? argv[1] : "/"
                if ctx.chdir(path) {
                    ctx.exit(0)
                } else {
                    ctx.error("cd: \(path): No such file or directory")
                    ctx.exit(1)
                }
            },

            // Async program: demonstrates a linear `await`-style body and the
            // `sleep` syscall. `sleep <seconds>` (default 1).
            Command(name: "sleep", summary: "wait for N seconds", category: .system, asyncRun: { ctx, argv in
                let seconds = argv.count > 1 ? (Double(argv[1]) ?? 1) : 1
                do {
                    try await ctx.sleep(seconds)
                    ctx.exit(0)
                } catch SyscallError.interrupted {
                    // The kernel is already applying the signal exit status.
                } catch {
                    ctx.exit(1)
                }
            }),

            // env [NAME=VALUE...] [CMD [args...]] — with no command, print the
            // environment; otherwise apply the assignments and run CMD in the
            // modified environment (the child inherits it), exiting with its code.
            Command(name: "env", summary: "print env, or run a command in a modified env", category: .system) { ctx, argv in
                var rest = Array(argv.dropFirst())
                while let first = rest.first, let pair = envAssignment(first) {
                    ctx.setenv(pair.name, pair.value)
                    rest.removeFirst()
                }
                guard let name = rest.first else {
                    for key in ctx.environment.keys.sorted() {
                        ctx.print("\(key)=\(ctx.environment[key] ?? "")\n")
                    }
                    ctx.exit(0)
                    return
                }
                guard let command = ctx.resolveCommand(name) else {
                    ctx.error("env: \(name): command not found")
                    ctx.exit(127)
                    return
                }
                ctx.run(command, args: rest)
                ctx.wait { result in
                    switch result {
                    case .success(let event):
                        ctx.exit(event.status.code)
                    case .failure:
                        ctx.exit(1)
                    }
                }
            },

            // `uname` prints system identity. `-s` kernel name (default), `-n`
            // node/hostname (read live from the UTS namespace), `-r` release,
            // `-m` machine, `-a` all. Honoring the UTS namespace means an
            // `unshare -u` + `hostname` change shows up in `uname -n`.
            Command(name: "uname", summary: "print system information", category: .system) { ctx, argv in
                let flags = Set(argv.dropFirst())
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

            Command(name: "whoami", summary: "print current user", category: .system) { ctx, _ in
                // Reflect the process's effective uid: root for 0, otherwise a
                // synthetic user name (there is no /etc/passwd to map names).
                let uid = ctx.getuid()
                ctx.print(uid == 0 ? "root\n" : "user\(uid)\n")
                ctx.exit(0)
            },

            // `hostname` with no argument prints the name from the caller's UTS
            // namespace; `hostname NAME` sets it there. Under a plain shell that
            // is the machine-wide name; under `unshare -u` it changes only the
            // private namespace — the isolation lesson.
            Command(name: "hostname", summary: "show or set the host name", category: .system) { ctx, argv in
                let args = Array(argv.dropFirst())
                if let newName = args.first {
                    ctx.setHostname(newName)
                } else {
                    ctx.print(ctx.hostname + "\n")
                }
                ctx.exit(0)
            },

            Command(name: "clear", summary: "clear the screen", category: .system) { ctx, _ in
                // Clear screen + home cursor (the minimal ANSI subset the terminal renders).
                ctx.print("\u{1B}[2J\u{1B}[H")
                ctx.exit(0)
            },

            // `true` / `false` as real programs with meaningful exit codes.
            Command(name: "true", summary: "exit with status 0", category: .system) { ctx, _ in
                ctx.exit(0)
            },

            Command(name: "false", summary: "exit with status 1", category: .system) { ctx, _ in
                ctx.exit(1)
            },

            // `ping [-c count] [-i interval] [-W timeout] [-s size] <ipv4> [count]`
            // — the same program that ships as `Programs.ping`, now also runnable
            // from the shell. It renders real-ping-style output: a header, one line
            // per reply/timeout *as they arrive* (paced ~`interval` apart, not all
            // at once), then a closing statistics block. The library program owns
            // the pacing, RTT, and stats; this command only parses flags and
            // formats text — a blocking network tool and `cat` are one kind of thing.
            Command(name: "ping", summary: "send ICMP echo requests", category: .network) { ctx, argv in
                func usage() {
                    ctx.error("ping: usage: ping [-c count] [-i interval] [-W timeout] [-s size] <ipv4> [count]")
                    ctx.exit(2)
                }

                var count = 1
                var interval = 1.0
                var timeout = 1.0
                var payloadSize = 56
                var explicitCount = false
                var positional: [String] = []

                // Parse `-c/-i/-W/-s <value>` flags; anything else is positional
                // (host, then an optional legacy count).
                var index = 1
                while index < argv.count {
                    let arg = argv[index]
                    let next: String? = index + 1 < argv.count ? argv[index + 1] : nil
                    switch arg {
                    case "-c":
                        guard let raw = next, let parsed = Int(raw), parsed >= 0 else { usage(); return }
                        count = parsed; explicitCount = true; index += 2
                    case "-i":
                        guard let raw = next, let parsed = Double(raw), parsed >= 0 else { usage(); return }
                        interval = parsed; index += 2
                    case "-W":
                        guard let raw = next, let parsed = Double(raw), parsed > 0 else { usage(); return }
                        timeout = parsed; index += 2
                    case "-s":
                        guard let raw = next, let parsed = Int(raw), parsed >= 0 else { usage(); return }
                        payloadSize = parsed; index += 2
                    default:
                        positional.append(arg); index += 1
                    }
                }

                guard let host = positional.first, let address = IPv4Address(host) else { usage(); return }
                // Backward-compatible positional count: `ping <ipv4> [count]`.
                if !explicitCount, positional.count > 1, let parsed = Int(positional[1]), parsed >= 0 {
                    count = parsed
                }

                // Linux header: "PING <ip> (<ip>) <data>(<total>) bytes of data.",
                // where total = data + 8 (ICMP header) + 20 (IPv4 header).
                ctx.print("PING \(address) (\(address)) \(payloadSize)(\(payloadSize + 28)) bytes of data.\n")

                // Reuse the library program body: it reports each reply/timeout
                // through the sink, delivers the summary via `onFinish`, and calls
                // `ctx.exit()` once the run completes.
                let body = Programs.ping(to: address,
                                         count: count,
                                         interval: interval,
                                         timeout: timeout,
                                         payloadSize: payloadSize,
                                         onFinish: { stats in
                    ctx.print("\n--- \(address) ping statistics ---\n")
                    let loss = BuiltinCommands.fixedPoint(stats.lossFraction * 100, places: 1)
                    let elapsedMs = Int((stats.elapsedSeconds * 1000).rounded())
                    ctx.print("\(stats.transmitted) packets transmitted, \(stats.received) received, \(loss)% packet loss, time \(elapsedMs)ms\n")
                    // The rtt line only appears when at least one reply arrived.
                    if let low = stats.minSeconds,
                       let avg = stats.averageSeconds,
                       let high = stats.maxSeconds,
                       let dev = stats.deviationSeconds {
                        func ms(_ seconds: Double) -> String { BuiltinCommands.fixedPoint(seconds * 1000, places: 3) }
                        ctx.print("rtt min/avg/max/mdev = \(ms(low))/\(ms(avg))/\(ms(high))/\(ms(dev)) ms\n")
                    }
                }) { outcome in
                    switch outcome {
                    case let .reply(from, sequence, ttl, bytes, rtt):
                        ctx.print("\(bytes) bytes from \(from): icmp_seq=\(sequence) ttl=\(ttl) time=\(BuiltinCommands.fixedPoint(rtt * 1000, places: 3)) ms\n")
                    case let .timeout(sequence):
                        ctx.print("Request timeout for icmp_seq \(sequence)\n")
                    }
                }
                body(ctx)
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
            Command(name: "tcpecho", summary: "TCP echo server", category: .network, asyncRun: { ctx, argv in
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

            // A minimal static-file HTTP server, also on `serveTCP`: it serves
            // files straight out of the VFS. `httpd [port]` (default 80); `GET /`
            // maps to `/index.html`. Shows an application protocol as an ordinary
            // user program over the TCP syscalls.
            Command(name: "httpd", summary: "serve files over HTTP", category: .network, asyncRun: { ctx, argv in
                let port = argv.count > 1 ? (UInt16(argv[1]) ?? 80) : 80
                // Announce only once the socket is actually listening; a failed
                // bind (port in use) prints an error from serveTCP and exits.
                await Programs.serveTCP(ctx, port: port, onListening: {
                    ctx.print("httpd: serving / on \(port)\n")
                }) { conn, fd in
                    var buffer: [UInt8] = []
                    // One connection may carry several requests (keep-alive).
                    while true {
                        // Accumulate until a full header block has arrived.
                        while HTTP.endOfHeaders(buffer) == nil {
                            guard let chunk = try? await conn.tcpRecv(fd), !chunk.isEmpty else { return }
                            buffer.append(contentsOf: chunk)
                        }
                        guard let request = HTTP.parseRequest(buffer) else {
                            _ = conn.tcpSend(fd, HTTP.response(status: 400, reason: "Bad Request",
                                                               body: Array("bad request\n".utf8)))
                            return
                        }
                        // Consume the request's header block; keep any pipelined bytes.
                        buffer.removeFirst(HTTP.endOfHeaders(buffer)!)

                        let path = request.path == "/" ? "/index.html" : request.path
                        let responseBytes: [UInt8]
                        if let file = conn.open(path) {
                            let body = conn.read(file, max: 1 << 20)
                            conn.close(file)
                            responseBytes = HTTP.response(status: 200, reason: "OK", body: body,
                                                          contentType: HTTP.contentType(forPath: path),
                                                          keepAlive: request.keepAlive)
                        } else {
                            responseBytes = HTTP.response(status: 404, reason: "Not Found",
                                                          body: Array("not found\n".utf8),
                                                          keepAlive: request.keepAlive)
                        }
                        _ = conn.tcpSend(fd, responseBytes)
                        if !request.keepAlive { return }
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
