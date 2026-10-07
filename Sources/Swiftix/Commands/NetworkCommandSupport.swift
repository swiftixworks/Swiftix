/// Shared plumbing for the network built-ins: a getopt-style option scanner, the
/// uniform "invalid option" diagnostic, and small text/number formatters.
///
/// Before this, each network command hand-rolled its option loop and treated any
/// token it did not recognize as an operand — which is how `curl -I url` came to
/// report "cannot resolve -I". Every network command now scans its arguments
/// through `NetworkOptions.scan`, so an unknown option is always a usage error
/// and never a hostname.
///
/// Concurrency: pure value types and static helpers over `ProcessContext`; like
/// the rest of `Commands/` they run only on the kernel's single serial executor
/// and hold no state or locks.

/// A getopt-style scanner. Short options may be clustered (`-sS`), a valued
/// option may be attached (`-c1`) or separate (`-c 1`), long options accept
/// `--name value` and `--name=value`, options and operands may be interleaved,
/// and `--` ends option parsing. A bare `-` is an operand (stdin/stdout).
enum NetworkOptions {

    enum Item: Equatable {
        /// A recognized option under its canonical name, with its value if it
        /// takes one.
        case option(String, String?)
        case operand(String)
    }

    enum Failure: Error, Equatable {
        case unknown(String)
        case missingValue(String)
        /// `--help` was given and the command does not define it itself.
        case help
    }

    /// A long option: the canonical name it reports as, and whether it takes a
    /// value.
    struct Long {
        let name: String
        let takesValue: Bool

        init(_ name: String, value: Bool = false) {
            self.name = name
            self.takesValue = value
        }
    }

    /// - Parameters:
    ///   - flags: short options that take no value, e.g. `"sSL"`.
    ///   - valued: short options that take a value, e.g. `"oXd"`.
    ///   - long: long option spellings (without the leading `--`).
    static func scan(_ arguments: [String],
                     flags: String = "",
                     valued: String = "",
                     long: [String: Long] = [:]) throws(Failure) -> [Item] {
        let flagSet = Set(flags)
        let valuedSet = Set(valued)
        var items: [Item] = []
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if optionsEnded || !CommandArguments.isOptionToken(argument) {
                items.append(.operand(argument))
                continue
            }
            if argument == "--" {
                optionsEnded = true
                continue
            }
            if argument.hasPrefix("--") {
                let body = argument.dropFirst(2)
                let name: String
                var inlineValue: String?
                if let equals = body.firstIndex(of: "=") {
                    name = String(body[body.startIndex..<equals])
                    inlineValue = String(body[body.index(after: equals)...])
                } else {
                    name = String(body)
                }
                guard let spec = long[name] else {
                    if name == "help" { throw .help }
                    throw .unknown("--" + name)
                }
                if spec.takesValue {
                    if let inlineValue {
                        items.append(.option(spec.name, inlineValue))
                    } else if index < arguments.count {
                        items.append(.option(spec.name, arguments[index]))
                        index += 1
                    } else {
                        throw .missingValue("--" + name)
                    }
                } else {
                    guard inlineValue == nil else { throw .unknown(argument) }
                    items.append(.option(spec.name, nil))
                }
                continue
            }
            // A cluster of short options: `-sS`, `-c1`, `-o file`.
            let characters = Array(argument.dropFirst())
            var position = 0
            while position < characters.count {
                let character = characters[position]
                position += 1
                if flagSet.contains(character) {
                    items.append(.option(String(character), nil))
                } else if valuedSet.contains(character) {
                    if position < characters.count {
                        items.append(.option(String(character), String(characters[position...])))
                    } else if index < arguments.count {
                        items.append(.option(String(character), arguments[index]))
                        index += 1
                    } else {
                        throw .missingValue(String(character))
                    }
                    position = characters.count
                } else {
                    throw .unknown(String(character))
                }
            }
        }
        return items
    }
}

extension ProcessContext {

    /// Scan `argv[1...]`, reporting a scan failure in the network built-ins'
    /// uniform shape and returning `nil` (the caller just returns):
    ///
    ///     cmd: invalid option -- 'x'
    ///     cmd: usage: <synopsis>
    ///
    /// with exit status 2. `--help` as the first argument is answered centrally
    /// (`Command.answeringHelp`); given later on the line it prints the same
    /// `Usage: <synopsis>` line to stdout and exits 0.
    func scanOptions(_ argv: [String],
                     command: String,
                     usage synopsis: String,
                     flags: String = "",
                     valued: String = "",
                     long: [String: NetworkOptions.Long] = [:]) -> [NetworkOptions.Item]? {
        do {
            return try NetworkOptions.scan(Array(argv.dropFirst()), flags: flags, valued: valued, long: long)
        } catch {
            switch error {
            case .help:
                print("Usage: \(synopsis)\n")
                exit(0)
            case .unknown(let option):
                self.error("\(command): invalid option -- '\(option)'")
                usage(command, synopsis)
            case .missingValue(let option):
                self.error("\(command): option requires an argument -- '\(option)'")
                usage(command, synopsis)
            }
            return nil
        }
    }

    /// Report a bad option *value* (`ping -c abc`) in the same two-line shape.
    func invalidArgument(_ command: String, _ message: String, usage synopsis: String) {
        error("\(command): \(message)")
        usage(command, synopsis)
    }

    /// Logical seconds since boot, for deadlines and elapsed-time reporting.
    var logicalSeconds: Double {
        Double(monotonicNanoseconds) / 1_000_000_000
    }
}

extension BuiltinCommands {

    /// The network built-ins' help text, keyed by command name: the synopsis on
    /// the first line (what a usage error repeats after `cmd: usage: `), then
    /// option lines shown only by `cmd --help` / `man cmd`.
    static let networkUsage: [String: String] = [
        "ping": """
            ping [-c count] [-i interval] [-W timeout] [-w deadline] [-s size] [-t ttl] [-q] [-n] <host> [count]
              -c COUNT     stop after COUNT requests
              -i SECONDS   wait SECONDS between requests
              -W SECONDS   time to wait for each reply
              -w SECONDS   overall deadline
              -s SIZE      payload bytes
              -t TTL       IP time to live
              -q           quiet: summary only
              -n           numeric output (no name lookups)
            """,
        "traceroute": """
            traceroute [-q nqueries] [-m maxhops] [-w timeout] [-n] <host> [maxhops]
              -q N   probes per hop
              -m N   maximum number of hops
              -w S   seconds to wait for each reply
              -n     numeric output
            """,
        "dnsd": "dnsd [-p port] [port]",
        "trace": "trace [-i interface] [-c count] [-n] [icmp|tcp|udp|arp|ip] [host <ipv4>]",
        "drops": "drops [-i interface] [-c count] [-n] [icmp|tcp|udp|arp|ip] [host <ipv4>]",
        "tcpdump": "tcpdump [-i interface] [-c count] [-n] [icmp|tcp|udp|arp|ip] [host <ipv4>]",
        "ifconfig": "ifconfig [-a] [interface] | ifconfig add <ip>/<prefix> <mac>",
        "route": "route [-n] | route add|del <cidr|default> [via|gw <gateway>] [dev ethN]",
        "arp": "arp [-a] [-n] | arp -s|add <ip> <mac> | arp -d|del <ip>",
        "ip": ipUsageLines[0] + "\n" + ipUsageLines.dropFirst().map { "  " + $0 }.joined(separator: "\n"),
        "curl": """
            curl [-I] [-i] [-s] [-S] [-f] [-L] [-v] [-o file] [-O] [-X method] [-d data] [-H header] [-A agent] [-w format] [-m seconds] <url>...
              -I         fetch the headers only (HEAD)
              -i         include response headers in the output
              -s / -S    silent / show errors even when silent
              -f         fail (exit 22) on HTTP errors
              -L         follow redirects
              -v         verbose
              -o FILE    write the body to FILE;  -O  name it after the URL
              -X METHOD  request method;  -d DATA  request body (POST)
              -H HEADER  extra request header;  -A AGENT  User-Agent
              -w FORMAT  print FORMAT after the transfer
              -m SECONDS maximum time for the transfer
            """,
        "wget": "wget [-q] [-O file|-] [-T seconds] http://<host>[:port]/path",
        "httpd": "httpd [-p port] [port] [docroot]",
        "dig": "dig [@server] [-p port] <name> [A] [+short]",
        "nslookup": "nslookup <name> [server]",
        "host": "host <name> [server]",
        "nc": "nc [-u] [-v] [-z] [-d] [-w secs] [-q secs] <host> <port[-port]> | nc -l [-u] [-k] [-v] [-p] <port>",
        "telnet": "telnet <host> [port]",
        "netstat": "netstat [-t] [-u] [-l] [-a] [-n] [-p] | netstat -r | netstat -i",
        "ss": "ss [-t] [-u] [-l] [-a] [-n] [-p] [-H]",
    ]

    /// The forms `ip` accepts, one per line; the first is its synopsis.
    static let ipUsageLines = [
        "ip [-4] [-br] [-o] [-s] OBJECT [COMMAND]",
        "ip addr [show [dev] IF]",
        "ip addr add <ip>/<prefix> lladdr <mac>",
        "ip link [show [dev] IF]",
        "ip route [show] | ip route get <ip>",
        "ip route add|del <cidr|default> [via <gateway>] [dev IF]",
        "ip neigh [show [dev IF]]",
        "ip neigh add|replace <ip> lladdr <mac> | ip neigh del <ip>",
        "ip forwarding [on|off]",
    ]

    /// The one-line synopsis a network command reports in a usage error.
    static func networkSynopsis(_ command: String) -> String {
        let usage = networkUsage[command] ?? "\(command) [OPTION]... [ARG]..."
        return String(usage.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    /// Dotted-quad netmask for a prefix length (`24` → `255.255.255.0`).
    static func netmask(_ prefixLength: Int) -> IPv4Address {
        IPv4Address(raw: NetworkRouteTable.mask(prefixLength))
    }

    /// Parse `a.b.c.d/len`; a bare address is `/32` when `allowBareHost` is set.
    static func parseCIDR(_ value: String, allowBareHost: Bool = false) -> (address: IPv4Address, prefixLength: Int)? {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 1, allowBareHost, let address = IPv4Address(String(parts[0])) {
            return (address, 32)
        }
        guard parts.count == 2,
              let address = IPv4Address(String(parts[0])),
              let prefixLength = Int(parts[1]),
              (0...32).contains(prefixLength) else { return nil }
        return (address, prefixLength)
    }

    /// Read a whole (small) VFS file as text, or `nil` if it cannot be opened.
    static func readTextFile(_ ctx: ProcessContext, _ path: String) -> String? {
        guard let fd = ctx.open(path) else { return nil }
        let data = readFully(ctx, fd)
        ctx.close(fd)
        return String(decoding: data, as: UTF8.self)
    }
}
