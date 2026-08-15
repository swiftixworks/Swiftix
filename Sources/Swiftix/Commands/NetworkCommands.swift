/// Network built-ins: diagnostics/configuration tools that surface the stack's
/// state, plus two TCP clients. They extend the base set in `Commands.swift` and join
/// `CommandRegistry.builtins` through `BuiltinCommands.all()`.
///
/// Diagnostics (`ifconfig`, `route`, `arp`, `netstat`) read the synthetic
/// `/proc/net/*` files the kernel already exposes. Mutating forms (`ifconfig add`,
/// `route add`, `arp add`, and `ip ... add`) go through `ProcessContext`'s network
/// configuration syscalls rather than reaching into `NetworkStack` directly. The
/// clients (`nc`, `curl`) are `async` programs over the TCP syscall frontend -- the
/// client-side counterparts to the `tcpecho`/`httpd` servers.
extension BuiltinCommands {

    static func networkCommands() -> [Command] {
        [
            // traceroute [-q nqueries] [-m maxhops] <host> [maxhops] — trace the
            // route to a destination by sending ICMP echo requests with increasing
            // TTL. Each intermediate router decrements TTL to zero and replies with
            // ICMP time-exceeded, revealing its address. Like real traceroute it
            // sends `nqueries` probes per hop (default 3) and prints one line per
            // hop with each probe's RTT (or `*` for a probe that timed out),
            // repeating the gateway address only when it changes. Stops when the
            // destination replies or `maxhops` (default 30) is reached.
            Command(name: "traceroute", summary: "trace the route to a host", category: .network, asyncRun: { ctx, argv in
                func usage() {
                    ctx.error("traceroute: usage: traceroute [-q nqueries] [-m maxhops] <host> [maxhops]")
                    ctx.exit(2)
                }

                var probesPerHop = 3
                var maxHops = 30
                var maxHopsSet = false
                var positional: [String] = []

                var index = 1
                while index < argv.count {
                    let arg = argv[index]
                    let next: String? = index + 1 < argv.count ? argv[index + 1] : nil
                    switch arg {
                    case "-q":
                        guard let raw = next, let n = Int(raw), n > 0 else { usage(); return }
                        probesPerHop = n; index += 2
                    case "-m":
                        guard let raw = next, let n = Int(raw), n > 0 else { usage(); return }
                        maxHops = n; maxHopsSet = true; index += 2
                    default:
                        positional.append(arg); index += 1
                    }
                }

                guard let host = positional.first else { usage(); return }
                // Backward-compatible positional maxhops: `traceroute <host> [maxhops]`.
                if !maxHopsSet, positional.count > 1, let n = Int(positional[1]), n > 0 {
                    maxHops = n
                }
                guard let address = await ctx.resolve(host) else {
                    ctx.error("traceroute: cannot resolve \(host)")
                    ctx.exit(1)
                    return
                }

                let identifier = UInt16(truncatingIfNeeded: ctx.globalPID)
                ctx.print("traceroute to \(address), \(maxHops) hops max\n")
                // Every probe needs a unique sequence number: the stack matches echo
                // replies by (identifier, sequence), so reusing a number across the
                // hop's probes would cross the waiters.
                var sequence: UInt16 = 0
                for hop in 1...maxHops {
                    let ttl = UInt8(clamping: hop)
                    var line = " \(hop)"
                    var lastPrinted: IPv4Address?
                    var reachedDestination = false
                    for _ in 0..<probesPerHop {
                        sequence &+= 1
                        let outcome: Programs.PingOutcome
                        do {
                            outcome = try await ctx.icmpEcho(to: address,
                                                             identifier: identifier,
                                                             sequence: sequence,
                                                             ttl: ttl,
                                                             timeout: 3.0)
                        } catch {
                            // Interrupted (signal); let the kernel handle exit status.
                            return
                        }
                        switch outcome {
                        case let .reply(from, _, _, _, rtt):
                            let ms = BuiltinCommands.fixedPoint(rtt * 1000, places: 3)
                            // Repeat the gateway only when it differs from the last
                            // one printed on this line (real traceroute behavior).
                            if from == lastPrinted {
                                line += "  \(ms) ms"
                            } else {
                                line += "  \(from)  \(ms) ms"
                                lastPrinted = from
                            }
                            if from == address { reachedDestination = true }
                        case .timeout:
                            line += "  *"
                        }
                    }
                    ctx.print(line + "\n")
                    if reachedDestination { ctx.exit(0); return }
                }
                ctx.exit(0)
            }),

            // ifconfig [add <ip>/<prefix> <mac>] — interface identities and counters.
            Command(name: "ifconfig", summary: "show or add interfaces", category: .network) { ctx, argv in
                runIfconfig(ctx, argv)
            },

            // route [add <cidr> [via <gateway>] [dev ethN]] — IPv4 routes.
            Command(name: "route", summary: "show or add routes", category: .network) { ctx, argv in
                runRoute(ctx, argv)
            },

            // arp [add <ip> <mac>] — ARP cache: IP -> MAC bindings.
            Command(name: "arp", summary: "show or add ARP entries", category: .network) { ctx, argv in
                runARP(ctx, argv)
            },

            // ip — lightweight Linux-style network configuration frontend.
            Command(name: "ip", summary: "configure addresses, routes, neighbors", category: .network) { ctx, argv in
                runIP(ctx, argv)
            },

            // trace — recent packet-path observations: ingress/L2/L3/route/forward/drop.
            Command(name: "trace", summary: "show recent packet path events", category: .network) { ctx, _ in
                catProcFile(ctx, cmd: "trace", path: "/proc/net/trace",
                            header: "seq direction interface stage details\n")
            },

            // drops — recent packet-path observations that ended in a drop reason.
            Command(name: "drops", summary: "show recent packet drops", category: .network) { ctx, _ in
                catProcFile(ctx, cmd: "drops", path: "/proc/net/drop",
                            header: "seq direction interface stage details\n")
            },

            // tcpdump — intentionally simplified: a snapshot of the recent packet
            // path rather than a live sniffer.
            Command(name: "tcpdump", summary: "show recent packet path events", category: .network) { ctx, _ in
                catProcFile(ctx, cmd: "tcpdump", path: "/proc/net/trace",
                            header: "seq direction interface stage details\n")
            },

            // netstat — active TCP connections and bound UDP ports. Reads both
            // /proc/net/tcp and /proc/net/udp so one command shows the sockets.
            Command(name: "netstat", summary: "show TCP connections and UDP ports", category: .network) { ctx, _ in
                ctx.print("Active TCP connections:\n")
                if let fd = ctx.open("/proc/net/tcp") {
                    ctx.write(1, readFully(ctx, fd)); ctx.close(fd)
                }
                ctx.print("Bound UDP ports:\n")
                if let fd = ctx.open("/proc/net/udp") {
                    ctx.write(1, readFully(ctx, fd)); ctx.close(fd)
                }
                ctx.exit(0)
            },

            // nc <host> <port> — TCP client. Resolves `host` (literal, /etc/hosts,
            // or DNS), connects, relays stdin to the socket in a child, and prints
            // socket bytes to stdout until the peer closes. Pairs with servers that
            // reply and then close (e.g. `httpd`).
            Command(name: "nc", summary: "TCP client: relay stdin/stdout", category: .network, asyncRun: { ctx, argv in
                guard argv.count >= 3, let port = UInt16(argv[2]) else {
                    ctx.usage("nc", "nc <host> <port>"); return
                }
                guard let address = await ctx.resolve(argv[1]) else {
                    ctx.fail("nc: cannot resolve \(argv[1])", code: 1); return
                }
                guard let fd = ctx.tcpSocket() else { ctx.fail("nc: socket failed", code: 1); return }
                do {
                    try await ctx.tcpConnect(fd, to: address, port: port)
                } catch {
                    ctx.fail("nc: connect to \(address):\(port) failed", code: 1); return
                }
                // Child pumps stdin -> socket (the accepted fd is inherited).
                ctx.spawn("nc-tx", args: ["nc-tx"]) { (child: ProcessContext) async in
                    while let bytes = try? await child.read(0), !bytes.isEmpty {
                        _ = child.tcpSend(fd, bytes)
                    }
                    child.exit(0)
                }
                // Parent pumps socket -> stdout until the peer closes (EOF).
                while let bytes = try? await ctx.tcpRecv(fd), !bytes.isEmpty {
                    ctx.write(1, bytes)
                }
                ctx.tcpClose(fd)
                ctx.exit(0)
            }),

            // nslookup <name> — resolve a name to an address (literal, /etc/hosts,
            // or DNS via the NAMESERVER env var) and print it.
            Command(name: "nslookup", summary: "resolve a hostname", category: .network, asyncRun: { ctx, argv in
                guard argv.count > 1 else {
                    ctx.usage("nslookup", "nslookup <name>"); return
                }
                if let address = await ctx.resolve(argv[1]) {
                    if let server = ctx.getenv("NAMESERVER") { ctx.print("Server: \(server)\n") }
                    ctx.print("Name:\t\(argv[1])\nAddress: \(address)\n")
                    ctx.exit(0)
                } else {
                    ctx.print("** server can't find \(argv[1]): NXDOMAIN\n")
                    ctx.exit(1)
                }
            }),

            // host <name> — a terser resolver: "<name> has address <ipv4>".
            Command(name: "host", summary: "resolve a hostname (terse)", category: .network, asyncRun: { ctx, argv in
                guard argv.count > 1 else {
                    ctx.usage("host", "host <name>"); return
                }
                if let address = await ctx.resolve(argv[1]) {
                    ctx.print("\(argv[1]) has address \(address)\n")
                    ctx.exit(0)
                } else {
                    ctx.print("Host \(argv[1]) not found: 3(NXDOMAIN)\n")
                    ctx.exit(1)
                }
            }),

            // dnsd [port] — a DNS server (UDP) answering A queries from the local
            // /etc/hosts table. The server counterpart to the resolver: DNS as an
            // ordinary user program over the UDP syscalls, mirroring httpd on TCP.
            Command(name: "dnsd", summary: "serve DNS A records from /etc/hosts", category: .network, asyncRun: { ctx, argv in
                let port = argv.count > 1 ? (UInt16(argv[1]) ?? DNS.port) : DNS.port
                guard let fd = ctx.socket() else { ctx.fail("dnsd: socket failed", code: 1); return }
                guard ctx.bind(fd, address: nil, port: port) else {
                    ctx.error("dnsd: cannot bind port \(port): address already in use")
                    ctx.close(fd); ctx.exit(1); return
                }
                ctx.print("dnsd: serving A records on \(port)\n")
                while let query = try? await ctx.recvfrom(fd) {
                    guard let (id, name) = DNS.parseQuery(query.bytes) else { continue }
                    let reply: [UInt8]
                    if let address = hostsLookup(ctx, name: name) {
                        reply = DNS.encodeResponse(id: id, name: name, address: address)
                    } else {
                        reply = DNS.encodeNotFound(id: id, name: name)
                    }
                    _ = ctx.sendto(fd, reply, to: query.address, port: query.port)
                }
            }),

            // curl <url> — fetch an http:// URL over TCP and print the body. The
            // host may be an IPv4 literal or a name resolved via /etc/hosts or DNS.
            // Use -i to include the response headers.
            Command(name: "curl", summary: "fetch an http:// URL", category: .network, asyncRun: { ctx, argv in
                var args = Array(argv.dropFirst())
                var includeHeaders = false
                if args.first == "-i" { includeHeaders = true; args.removeFirst() }
                guard let urlString = args.first, let url = parseHTTPURL(urlString) else {
                    ctx.usage("curl", "curl [-i] http://<host>[:port]/path"); return
                }
                guard let address = await ctx.resolve(url.host) else {
                    ctx.fail("curl: cannot resolve \(url.host)", code: 1); return
                }
                guard let fd = ctx.tcpSocket() else { ctx.fail("curl: socket failed", code: 1); return }
                do {
                    try await ctx.tcpConnect(fd, to: address, port: url.port)
                } catch {
                    ctx.fail("curl: connect to \(url.host):\(url.port) failed", code: 1); return
                }
                let request = "GET \(url.path) HTTP/1.0\r\nHost: \(url.host)\r\nConnection: close\r\n\r\n"
                _ = ctx.tcpSend(fd, Array(request.utf8))
                var response: [UInt8] = []
                while let bytes = try? await ctx.tcpRecv(fd), !bytes.isEmpty {
                    response.append(contentsOf: bytes)
                }
                ctx.tcpClose(fd)
                if includeHeaders {
                    ctx.write(1, response)
                } else if let bodyStart = headerBodySplit(response) {
                    ctx.write(1, Array(response[bodyStart...]))
                } else {
                    ctx.write(1, response)   // no header terminator seen; print as-is
                }
                ctx.exit(0)
            }),

            // wget [-O file] <url> — fetch an http:// URL and save the body to a
            // file (default: the last path component, or `index.html`). Uses the
            // same TCP/HTTP path as `curl`, but writes to disk instead of stdout
            // and prints a short progress line, like the real `wget`.
            Command(name: "wget", summary: "download an http:// URL to a file", category: .network, asyncRun: { ctx, argv in
                var args = Array(argv.dropFirst())
                var output: String?
                if args.first == "-O" {
                    args.removeFirst()
                    guard let name = args.first else {
                        ctx.fail("wget: option -O requires an argument"); return
                    }
                    output = name; args.removeFirst()
                }
                guard let urlString = args.first, let url = parseHTTPURL(urlString) else {
                    ctx.usage("wget", "wget [-O file] http://<host>[:port]/path"); return
                }
                // Default output file: the URL's last path component, or index.html.
                let destination = output ?? {
                    let component = url.path.split(separator: "/").last.map(String.init) ?? ""
                    return component.isEmpty ? "index.html" : component
                }()
                guard let address = await ctx.resolve(url.host) else {
                    ctx.fail("wget: cannot resolve \(url.host)", code: 1); return
                }
                guard let fd = ctx.tcpSocket() else { ctx.fail("wget: socket failed", code: 1); return }
                do {
                    try await ctx.tcpConnect(fd, to: address, port: url.port)
                } catch {
                    ctx.fail("wget: connect to \(url.host):\(url.port) failed", code: 1); return
                }
                let request = "GET \(url.path) HTTP/1.0\r\nHost: \(url.host)\r\nConnection: close\r\n\r\n"
                _ = ctx.tcpSend(fd, Array(request.utf8))
                var response: [UInt8] = []
                while let bytes = try? await ctx.tcpRecv(fd), !bytes.isEmpty {
                    response.append(contentsOf: bytes)
                }
                ctx.tcpClose(fd)
                let body = headerBodySplit(response).map { Array(response[$0...]) } ?? response
                guard let outFD = ctx.open(destination, create: true, truncate: true) else {
                    ctx.fail("wget: cannot write to \(destination)", code: 1); return
                }
                ctx.write(outFD, body)
                ctx.close(outFD)
                ctx.error("wget: saved \(body.count) bytes to \(destination)")
                ctx.exit(0)
            }),
        ]
    }

    // MARK: - Helpers

    private static func runIfconfig(_ ctx: ProcessContext, _ argv: [String]) {
        if argv.count == 1 {
            catProcFile(ctx, cmd: "ifconfig", path: "/proc/net/dev")
            return
        }
        guard argv.count == 4,
              argv[1] == "add",
              let (address, prefixLength) = parseCIDR(argv[2]),
              let mac = MACAddress(argv[3]) else {
            usage(ctx, command: "ifconfig", text: "ifconfig [add <ip>/<prefix> <mac>]")
            return
        }
        ctx.configureNetwork(.addInterface(NetworkInterfaceConfiguration(address: address,
                                                                         mac: mac,
                                                                         prefixLength: prefixLength)))
        ctx.exit(0)
    }

    private static func runRoute(_ ctx: ProcessContext, _ argv: [String]) {
        if argv.count == 1 {
            catProcFile(ctx, cmd: "route", path: "/proc/net/route",
                        header: "destination gateway interface\n")
            return
        }
        guard argv.count >= 3,
              argv[1] == "add",
              let route = parseRouteArguments(Array(argv.dropFirst(2)), context: ctx) else {
            usage(ctx, command: "route", text: "route [add <cidr|default> [via <gateway>] [dev ethN]]")
            return
        }
        ctx.configureNetwork(.addRoute(route))
        ctx.exit(0)
    }

    private static func runARP(_ ctx: ProcessContext, _ argv: [String]) {
        if argv.count == 1 {
            catProcFile(ctx, cmd: "arp", path: "/proc/net/arp",
                        header: "address hwaddress\n")
            return
        }
        guard argv.count == 4,
              (argv[1] == "add" || argv[1] == "-s"),
              let ip = IPv4Address(argv[2]),
              let mac = MACAddress(argv[3]) else {
            usage(ctx, command: "arp", text: "arp [add <ip> <mac>]")
            return
        }
        ctx.configureNetwork(.addNeighbor(NetworkNeighborConfiguration(ip: ip, mac: mac)))
        ctx.exit(0)
    }

    private static func runIP(_ ctx: ProcessContext, _ argv: [String]) {
        guard argv.count >= 2 else {
            ipUsage(ctx)
            return
        }

        switch argv[1] {
        case "addr", "address":
            guard argv.count >= 6,
                  argv[2] == "add",
                  let (address, prefixLength) = parseCIDR(argv[3]),
                  let mac = parseLinkLayerAddress(Array(argv.dropFirst(4))) else {
                ipUsage(ctx)
                return
            }
            ctx.configureNetwork(.addInterface(NetworkInterfaceConfiguration(address: address,
                                                                             mac: mac,
                                                                             prefixLength: prefixLength)))
            ctx.exit(0)

        case "route":
            guard argv.count >= 4,
                  argv[2] == "add",
                  let route = parseRouteArguments(Array(argv.dropFirst(3)), context: ctx) else {
                ipUsage(ctx)
                return
            }
            ctx.configureNetwork(.addRoute(route))
            ctx.exit(0)

        case "neigh", "neighbor":
            guard argv.count >= 6,
                  argv[2] == "add",
                  let neighbor = parseNeighborArguments(Array(argv.dropFirst(3))) else {
                ipUsage(ctx)
                return
            }
            ctx.configureNetwork(.addNeighbor(neighbor))
            ctx.exit(0)

        case "forwarding":
            if argv.count == 2 {
                let enabled = ctx.snapshotNetworkConfiguration().ipForwardingEnabled
                ctx.print("forwarding: \(enabled ? "on" : "off")\n")
                ctx.exit(0)
                return
            }
            guard argv.count == 3, let enabled = parseSwitch(argv[2]) else {
                ipUsage(ctx)
                return
            }
            ctx.configureNetwork(.setIPForwarding(enabled))
            ctx.print("forwarding: \(enabled ? "on" : "off")\n")
            ctx.exit(0)

        default:
            ipUsage(ctx)
        }
    }

    private static func parseCIDR(_ value: String) -> (address: IPv4Address, prefixLength: Int)? {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let address = IPv4Address(String(parts[0])),
              let prefixLength = Int(parts[1]),
              (0...32).contains(prefixLength) else { return nil }
        return (address, prefixLength)
    }

    private static func parseRouteDestination(_ value: String) -> (address: IPv4Address, prefixLength: Int)? {
        if value == "default" {
            return (IPv4Address(0, 0, 0, 0), 0)
        }
        return parseCIDR(value)
    }

    private static func parseRouteArguments(
        _ args: [String],
        context: ProcessContext
    ) -> NetworkRouteConfiguration? {
        guard let first = args.first,
              let destination = parseRouteDestination(first) else { return nil }

        var gateway: IPv4Address?
        var interfaceIndex = 0
        var index = 1
        while index < args.count {
            switch args[index] {
            case "via":
                guard index + 1 < args.count,
                      let address = IPv4Address(args[index + 1]) else { return nil }
                gateway = address
                index += 2
            case "dev":
                guard index + 1 < args.count,
                      let parsedIndex = parseInterfaceIndex(args[index + 1], context: context) else { return nil }
                interfaceIndex = parsedIndex
                index += 2
            default:
                return nil
            }
        }

        return NetworkRouteConfiguration(destination: destination.address,
                                         prefixLength: destination.prefixLength,
                                         gateway: gateway,
                                         interfaceIndex: interfaceIndex)
    }

    private static func parseNeighborArguments(_ args: [String]) -> NetworkNeighborConfiguration? {
        guard let first = args.first,
              let ip = IPv4Address(first),
              let mac = parseLinkLayerAddress(Array(args.dropFirst())) else { return nil }
        return NetworkNeighborConfiguration(ip: ip, mac: mac)
    }

    private static func parseLinkLayerAddress(_ args: [String]) -> MACAddress? {
        guard args.count == 2,
              ["lladdr", "mac", "ether"].contains(args[0]) else { return nil }
        return MACAddress(args[1])
    }

    private static func parseInterfaceIndex(_ value: String, context: ProcessContext) -> Int? {
        if let index = context.networkInterfaceIndex(named: value) { return index }
        guard let index = Int(value), index >= 0 else { return nil }
        return index
    }

    private static func parseSwitch(_ value: String) -> Bool? {
        switch value {
        case "on", "1", "true", "yes":
            return true
        case "off", "0", "false", "no":
            return false
        default:
            return nil
        }
    }

    private static func usage(_ ctx: ProcessContext, command: String, text: String) {
        ctx.error("\(command): usage: \(text)")
        ctx.exit(2)
    }

    private static func ipUsage(_ ctx: ProcessContext) {
        let text = """
        ip: usage: ip addr add <ip>/<prefix> lladdr <mac>
                  ip route add <cidr|default> [via <gateway>] [dev ethN]
                  ip neigh add <ip> lladdr <mac>
                  ip forwarding [on|off]
        """
        ctx.fail(text)
    }

    /// Print a synthetic /proc file's contents to stdout, optionally prefixed with
    /// a friendly header line. Exits 1 if the file cannot be opened.
    private static func catProcFile(_ ctx: ProcessContext, cmd: String, path: String, header: String? = nil) {
        guard let fd = ctx.open(path) else {
            ctx.fail("\(cmd): \(path) unavailable", code: 1); return
        }
        if let header { ctx.print(header) }
        ctx.write(1, readFully(ctx, fd))
        ctx.close(fd)
        ctx.exit(0)
    }

    /// Server-side `/etc/hosts` lookup for `dnsd`: find the first entry whose
    /// name (or an alias) matches `name`. Lines are `<ip> <name> [aliases…]`;
    /// blank lines and `#` comments are ignored.
    private static func hostsLookup(_ ctx: ProcessContext, name: String) -> IPv4Address? {
        guard let fd = ctx.open("/etc/hosts") else { return nil }
        let data = readFully(ctx, fd)
        ctx.close(fd)
        for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let line = rawLine.split(separator: "#", maxSplits: 1)[0]
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
            guard fields.count >= 2, let ip = IPv4Address(fields[0]) else { continue }
            if fields.dropFirst().contains(name) { return ip }
        }
        return nil
    }

    /// Parse an `http://<host>[:port]/path` URL. `host` may be a name (resolved
    /// later) or an IPv4 literal. Defaults: port 80, path "/".
    static func parseHTTPURL(_ string: String) -> (host: String, port: UInt16, path: String)? {
        var rest = Substring(string)
        if rest.hasPrefix("http://") { rest = rest.dropFirst("http://".count) }
        // Split authority from path at the first "/".
        let authority: Substring
        let path: String
        if let slash = rest.firstIndex(of: "/") {
            authority = rest[rest.startIndex..<slash]
            path = String(rest[slash...])
        } else {
            authority = rest
            path = "/"
        }
        // Split host from optional ":port".
        let host: String
        var port: UInt16 = 80
        if let colon = authority.firstIndex(of: ":") {
            host = String(authority[authority.startIndex..<colon])
            guard let p = UInt16(authority[authority.index(after: colon)...]) else { return nil }
            port = p
        } else {
            host = String(authority)
        }
        guard !host.isEmpty else { return nil }
        return (host, port, path)
    }

    /// Index of the response body: the byte just past the first CRLFCRLF header
    /// terminator, or `nil` if none is present.
    static func headerBodySplit(_ response: [UInt8]) -> Int? {
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]   // \r\n\r\n
        guard response.count >= terminator.count else { return nil }
        for start in 0...(response.count - terminator.count)
        where Array(response[start..<start + terminator.count]) == terminator {
            return start + terminator.count
        }
        return nil
    }
}
