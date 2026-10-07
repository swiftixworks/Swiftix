/// Network built-ins: the registration point for the whole network command set,
/// plus the ICMP tools (`ping`, `traceroute`), the packet-path viewers
/// (`tcpdump`, `trace`, `drops`) and the `dnsd` server. They extend the base set
/// in `Commands.swift` and join `CommandRegistry.builtins` through
/// `BuiltinCommands.all()`.
///
/// The rest of the set lives beside this file, one feature area each:
///
///   - `NetworkConfigCommands.swift` — `ip`, `ifconfig`, `route`, `arp`
///   - `NetworkSocketCommands.swift` — `netstat`, `ss`
///   - `HTTPCommands.swift`          — `curl`, `wget`, `httpd`
///   - `NetcatCommands.swift`        — `nc`, `telnet`
///   - `DNSCommands.swift`           — `dig`, `nslookup`, `host`
///   - `NetworkCommandSupport.swift` — the shared option scanner and formatters
///
/// `ping` and `httpd` are defined here although older definitions still sit in
/// `Commands.swift`: `networkCommands()` is appended after `base()` in
/// `BuiltinCommands.all()`, and the registry keeps the last command registered
/// under a name, so these are the ones the shell runs.
///
/// Diagnostics read the synthetic `/proc/net/*` files or value snapshots obtained
/// through `ProcessContext`; mutating forms go through its network configuration
/// syscalls rather than reaching into `NetworkStack` directly.
extension BuiltinCommands {

    static func networkCommands() -> [Command] {
        let commands = icmpCommands()
            + networkConfigCommands()
            + networkSocketCommands()
            + packetPathCommands()
            + netcatCommands()
            + dnsCommands()
            + httpCommands()
        // One synopsis per command, shared by `cmd --help` (the central
        // mechanism) and the command's own usage-error diagnostics.
        return commands.map { $0.withUsage(networkUsage[$0.name]) }
    }

    // MARK: - ping / traceroute

    private static let pingUsage = networkSynopsis("ping")
    private static let tracerouteUsage = networkSynopsis("traceroute")

    private static func icmpCommands() -> [Command] {
        [
            // `ping [-c count] [-i interval] [-W timeout] [-w deadline] [-s size]
            // [-t ttl] [-q] <host> [count]` — renders real-ping-style output: a
            // header, one line per reply/timeout *as they arrive* (paced
            // ~`interval` apart, not all at once), then a closing statistics
            // block. `host` is resolved like every other client (literal,
            // /etc/hosts, DNS). Exits 0 when at least one reply arrived, 1 when
            // every request was lost, 2 on a usage or resolution error.
            Command(name: "ping", summary: "send ICMP echo requests", category: .network, asyncRun: { ctx, argv in
                await runPing(ctx, argv)
            }),

            // traceroute [-q nqueries] [-m maxhops] [-w timeout] <host> [maxhops]
            // — trace the route to a destination by sending ICMP echo requests
            // with increasing TTL. Each intermediate router decrements TTL to zero
            // and replies with ICMP time-exceeded, revealing its address. Like real
            // traceroute it sends `nqueries` probes per hop (default 3) and prints
            // one line per hop with each probe's RTT (or `*` for a probe that timed
            // out), repeating the gateway address only when it changes. Stops when
            // the destination replies or `maxhops` (default 30) is reached.
            Command(name: "traceroute", summary: "trace the route to a host", category: .network, asyncRun: { ctx, argv in
                await runTraceroute(ctx, argv)
            }),
        ]
    }

    private static func runPing(_ ctx: ProcessContext, _ argv: [String]) async {
        guard let items = ctx.scanOptions(argv, command: "ping", usage: pingUsage,
                                          flags: "qn4v", valued: "ciWwst") else { return }
        var count = 1
        var explicitCount = false
        var interval = 1.0
        var timeout = 1.0
        var deadline: Double?
        var payloadSize = 56
        var ttl: UInt8 = 64
        var quiet = false
        var positional: [String] = []

        func bad(_ option: String, _ value: String) {
            ctx.invalidArgument("ping", "invalid argument: '\(value)' for -\(option)", usage: pingUsage)
        }
        for item in items {
            switch item {
            case .operand(let value):
                positional.append(value)
            case .option("q", _):
                quiet = true
            case .option("c", let value?):
                guard let parsed = Int(value), parsed >= 0 else { bad("c", value); return }
                count = parsed; explicitCount = true
            case .option("i", let value?):
                guard let parsed = Double(value), parsed >= 0 else { bad("i", value); return }
                interval = parsed
            case .option("W", let value?):
                guard let parsed = Double(value), parsed > 0 else { bad("W", value); return }
                timeout = parsed
            case .option("w", let value?):
                guard let parsed = Double(value), parsed > 0 else { bad("w", value); return }
                deadline = parsed
            case .option("s", let value?):
                guard let parsed = Int(value), (0...65_507).contains(parsed) else { bad("s", value); return }
                payloadSize = parsed
            case .option("t", let value?):
                guard let parsed = UInt8(value), parsed > 0 else { bad("t", value); return }
                ttl = parsed
            case .option:
                break   // -n / -4 / -v: accepted, nothing to change (output is numeric IPv4)
            }
        }

        guard let host = positional.first else { ctx.usage("ping", pingUsage); return }
        // Backward-compatible positional count: `ping <host> [count]`.
        if !explicitCount, positional.count > 1 {
            guard let parsed = Int(positional[1]), parsed >= 0 else {
                ctx.invalidArgument("ping", "invalid count: '\(positional[1])'", usage: pingUsage); return
            }
            count = parsed
            explicitCount = true
        }
        // Like Linux, a deadline without a count means "until the deadline".
        if deadline != nil, !explicitCount { count = Int.max }

        guard let address = await ctx.resolve(host) else {
            ctx.fail("ping: \(host): Name or service not known", code: 2); return
        }

        // Linux header: "PING <host> (<ip>) <data>(<total>) bytes of data.",
        // where total = data + 8 (ICMP header) + 20 (IPv4 header).
        ctx.print("PING \(host) (\(address)) \(payloadSize)(\(payloadSize + 28)) bytes of data.\n")

        // Identify echoes by the global pid so concurrent pings (even across PID
        // namespaces, where local pids repeat) don't collide on the (identifier,
        // sequence) key the stack uses to match replies.
        let identifier = UInt16(truncatingIfNeeded: ctx.globalPID)
        // A deterministic filler keeps wire bytes stable; the peer echoes it back.
        let payload = [UInt8](repeating: 0, count: payloadSize)
        let start = ctx.logicalSeconds
        var transmitted = 0
        var roundTrips: [Double] = []
        var sequence: UInt16 = 0

        while transmitted < count {
            let sentAt = ctx.logicalSeconds
            var wait = timeout
            if let deadline {
                let left = deadline - (sentAt - start)
                guard left > 0 else { break }
                wait = min(wait, left)
            }
            sequence &+= 1
            transmitted += 1
            let outcome: Programs.PingOutcome
            do {
                outcome = try await ctx.icmpEcho(to: address, identifier: identifier, sequence: sequence,
                                                 payload: payload, ttl: ttl, timeout: wait)
            } catch {
                return   // interrupted by a signal; the kernel owns the exit status
            }
            switch outcome {
            case let .reply(from, replySequence, replyTTL, bytes, rtt):
                roundTrips.append(rtt)
                if !quiet {
                    ctx.print("\(bytes) bytes from \(from): icmp_seq=\(replySequence) ttl=\(replyTTL) time=\(fixedPoint(rtt * 1000, places: 3)) ms\n")
                }
            case let .timeout(lostSequence):
                if !quiet { ctx.print("Request timeout for icmp_seq \(lostSequence)\n") }
            }
            guard transmitted < count else { break }
            // Pace send-to-send: sleep only what is left of the interval after
            // this request's RTT (or its full timeout on a miss).
            var pause = interval - (ctx.logicalSeconds - sentAt)
            if let deadline { pause = min(pause, deadline - (ctx.logicalSeconds - start)) }
            if pause > 0 {
                do { try await ctx.sleep(pause) } catch { return }
            }
        }

        let stats = Programs.PingStatistics(transmitted: transmitted,
                                            received: roundTrips.count,
                                            roundTripsSeconds: roundTrips,
                                            elapsedSeconds: ctx.logicalSeconds - start)
        ctx.print("\n--- \(host) ping statistics ---\n")
        let loss = fixedPoint(stats.lossFraction * 100, places: 1)
        let elapsedMs = Int((stats.elapsedSeconds * 1000).rounded())
        ctx.print("\(stats.transmitted) packets transmitted, \(stats.received) received, \(loss)% packet loss, time \(elapsedMs)ms\n")
        // The rtt line only appears when at least one reply arrived.
        if let low = stats.minSeconds,
           let avg = stats.averageSeconds,
           let high = stats.maxSeconds,
           let dev = stats.deviationSeconds {
            func ms(_ seconds: Double) -> String { fixedPoint(seconds * 1000, places: 3) }
            ctx.print("rtt min/avg/max/mdev = \(ms(low))/\(ms(avg))/\(ms(high))/\(ms(dev)) ms\n")
        }
        ctx.exit(stats.transmitted > 0 && stats.received == 0 ? 1 : 0)
    }

    private static func runTraceroute(_ ctx: ProcessContext, _ argv: [String]) async {
        guard let items = ctx.scanOptions(argv, command: "traceroute", usage: tracerouteUsage,
                                          flags: "nI4", valued: "qmw") else { return }
        var probesPerHop = 3
        var maxHops = 30
        var maxHopsSet = false
        var probeTimeout = 3.0
        var positional: [String] = []

        for item in items {
            switch item {
            case .operand(let value):
                positional.append(value)
            case .option("q", let value?):
                guard let n = Int(value), n > 0 else {
                    ctx.invalidArgument("traceroute", "invalid probe count: '\(value)'", usage: tracerouteUsage); return
                }
                probesPerHop = n
            case .option("m", let value?):
                guard let n = Int(value), n > 0 else {
                    ctx.invalidArgument("traceroute", "invalid max hops: '\(value)'", usage: tracerouteUsage); return
                }
                maxHops = n; maxHopsSet = true
            case .option("w", let value?):
                guard let seconds = Double(value), seconds > 0 else {
                    ctx.invalidArgument("traceroute", "invalid wait time: '\(value)'", usage: tracerouteUsage); return
                }
                probeTimeout = seconds
            case .option:
                break   // -n / -I / -4: already numeric, ICMP, IPv4
            }
        }

        guard let host = positional.first else { ctx.usage("traceroute", tracerouteUsage); return }
        // Backward-compatible positional maxhops: `traceroute <host> [maxhops]`.
        if !maxHopsSet, positional.count > 1, let n = Int(positional[1]), n > 0 {
            maxHops = n
        }
        guard let address = await ctx.resolve(host) else {
            ctx.fail("traceroute: \(host): Name or service not known", code: 2); return
        }

        let identifier = UInt16(truncatingIfNeeded: ctx.globalPID)
        ctx.print("traceroute to \(host) (\(address)), \(maxHops) hops max\n")
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
                                                     timeout: probeTimeout)
                } catch {
                    // Interrupted (signal); let the kernel handle exit status.
                    return
                }
                switch outcome {
                case let .reply(from, _, _, _, rtt):
                    let ms = fixedPoint(rtt * 1000, places: 3)
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
    }

    // MARK: - trace / drops / tcpdump

    private static func packetPathCommands() -> [Command] {
        [
            // trace — recent packet-path observations: ingress/L2/L3/route/forward/drop.
            Command(name: "trace", summary: "show recent packet path events", category: .network) { ctx, argv in
                runPacketPath(ctx, argv, command: "trace", path: "/proc/net/trace")
            },

            // drops — recent packet-path observations that ended in a drop reason.
            Command(name: "drops", summary: "show recent packet drops", category: .network) { ctx, argv in
                runPacketPath(ctx, argv, command: "drops", path: "/proc/net/drop")
            },

            // tcpdump — intentionally simplified: a snapshot of the recent packet
            // path rather than a live sniffer. `-i IF`, `-c N` and a small filter
            // language select from that snapshot.
            Command(name: "tcpdump", summary: "show recent packet path events", category: .network) { ctx, argv in
                runPacketPath(ctx, argv, command: "tcpdump", path: "/proc/net/trace")
            },

            // dnsd [-p port] [port] — a DNS server (UDP) answering A queries from
            // the local /etc/hosts table. The server counterpart to the resolver:
            // DNS as an ordinary user program over the UDP syscalls, mirroring
            // httpd on TCP.
            Command(name: "dnsd", summary: "serve DNS A records from /etc/hosts", category: .network, asyncRun: { ctx, argv in
                let usage = networkSynopsis("dnsd")
                guard let items = ctx.scanOptions(argv, command: "dnsd", usage: usage, valued: "p") else { return }
                var port = DNS.port
                for item in items {
                    let value: String
                    switch item {
                    case .operand(let operand): value = operand
                    case .option(_, let optionValue): value = optionValue ?? ""
                    }
                    guard let parsed = UInt16(value), parsed != 0 else {
                        ctx.invalidArgument("dnsd", "invalid port: '\(value)'", usage: usage); return
                    }
                    port = parsed
                }
                guard let fd = ctx.socket() else { ctx.fail("dnsd: socket failed", code: 1); return }
                guard ctx.bind(fd, address: nil, port: port) else {
                    ctx.error("dnsd: cannot bind port \(port): address already in use")
                    ctx.close(fd); ctx.exit(1); return
                }
                ctx.print("dnsd: serving A records on \(port)\n")
                while let query = try? await ctx.recvfrom(fd) {
                    guard let (id, name) = DNS.parseQuery(query.bytes) else { continue }
                    let reply: [UInt8]
                    if let address = ctx.hostsFileLookup(name) {
                        reply = DNS.encodeResponse(id: id, name: name, address: address)
                    } else {
                        reply = DNS.encodeNotFound(id: id, name: name)
                    }
                    _ = ctx.sendto(fd, reply, to: query.address, port: query.port)
                }
            }),
        ]
    }

    /// A parsed `tcpdump`-style selection over packet-path event lines.
    struct PacketPathFilter: Equatable {
        var interface: String?
        /// `icmp` / `tcp` / `udp` / `arp` / `ip`; all listed must match (one per
        /// event, so more than one distinct protocol matches nothing).
        var protocols: [String] = []
        var hosts: [IPv4Address] = []
        var limit: Int?

        /// Whether one `/proc/net/trace` line
        /// (`seq direction interface stage key=value…`) passes the filter.
        func matches(_ line: String) -> Bool {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count >= 4 else { return false }
            if let interface, interface != "any", fields[2] != interface { return false }
            for name in protocols {
                let token: String
                switch name {
                case "arp": token = "ether=arp"
                case "ip": token = "ether=ipv4"
                default: token = "proto=\(name)"
                }
                if !fields.contains(token) { return false }
            }
            for host in hosts {
                // The only addresses a path event carries are its route decision's.
                let wanted = ["route=\(host)", "via=\(host)", "gateway=\(host)"]
                if !fields.contains(where: { wanted.contains($0) }) { return false }
            }
            return true
        }
    }

    enum PacketPathFilterError: Error, Equatable {
        case unsupported(String)
        case malformed(String)
    }

    /// Parse the filter expression after the options: protocol words, `host IP`
    /// and `and` joiners. `port N` is rejected explicitly — packet-path events
    /// record no port numbers, so pretending to filter on one would lie.
    static func parsePacketPathExpression(_ words: [String],
                                          into filter: inout PacketPathFilter) throws(PacketPathFilterError) {
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            switch word {
            case "icmp", "tcp", "udp", "arp", "ip":
                filter.protocols.append(word)
            case "and":
                continue
            case "host", "src", "dst":
                var target = word
                if word != "host", index < words.count, words[index] == "host" {
                    index += 1
                    target = "host"
                }
                guard index < words.count, let address = IPv4Address(words[index]) else {
                    throw .malformed("expected an IPv4 address after '\(target)'")
                }
                index += 1
                filter.hosts.append(address)
            case "port":
                throw .unsupported("'port' filters are not supported: packet path events carry no port numbers")
            case "or", "not":
                throw .unsupported("'\(word)' is not supported in filter expressions")
            default:
                throw .malformed("syntax error in filter expression near '\(word)'")
            }
        }
    }

    private static func runPacketPath(_ ctx: ProcessContext, _ argv: [String], command: String, path: String) {
        let usage = networkSynopsis(command)
        guard let items = ctx.scanOptions(argv, command: command, usage: usage,
                                          flags: "nvqeltX", valued: "ic") else { return }
        var filter = PacketPathFilter()
        var words: [String] = []
        for item in items {
            switch item {
            case .operand(let word):
                words.append(word)
            case .option("i", let value?):
                guard value == "any" || ctx.networkInterfaceIndex(named: value) != nil else {
                    ctx.fail("\(command): \(value): No such device exists", code: 1); return
                }
                filter.interface = value
            case .option("c", let value?):
                guard let limit = Int(value), limit > 0 else {
                    ctx.invalidArgument(command, "invalid packet count: '\(value)'", usage: usage); return
                }
                filter.limit = limit
            case .option:
                break   // -n and the verbosity/format flags change nothing here
            }
        }
        do {
            try parsePacketPathExpression(words, into: &filter)
        } catch {
            switch error {
            case .unsupported(let message): ctx.fail("\(command): \(message)", code: 1)
            case .malformed(let message): ctx.invalidArgument(command, message, usage: usage)
            }
            return
        }
        guard let text = readTextFile(ctx, path) else {
            ctx.fail("\(command): \(path) unavailable", code: 1); return
        }
        var lines = text.split(separator: "\n").map(String.init).filter(filter.matches)
        if let limit = filter.limit { lines = Array(lines.prefix(limit)) }
        ctx.print("seq direction interface stage details\n")
        if !lines.isEmpty { ctx.print(lines.joined(separator: "\n") + "\n") }
        ctx.exit(0)
    }
}
