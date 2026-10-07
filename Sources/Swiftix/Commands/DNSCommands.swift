/// DNS lookup tools: `dig`, `nslookup`, `host`.
///
/// `nslookup NAME` and `host NAME` resolve the way every other client does
/// (`/etc/hosts`, then the configured nameservers). Naming a server — and `dig`
/// always — performs the raw DNS exchange with that server instead, so the tool
/// shows what the server said rather than what the local hosts table says.
///
/// Only `A` records exist in the `DNS` codec; other query types are refused
/// rather than silently answered as `A`.
///
/// Concurrency: `async` programs on the kernel's serial executor.
extension BuiltinCommands {

    static func dnsCommands() -> [Command] {
        [
            // dig [@server] [-p port] NAME [A] [+short]
            Command(name: "dig", summary: "query a DNS server", category: .network, asyncRun: { ctx, argv in
                await runDig(ctx, argv)
            }),

            // nslookup <name> [server] — resolve a name to an address and print it.
            Command(name: "nslookup", summary: "resolve a hostname", category: .network, asyncRun: { ctx, argv in
                await runLookup(ctx, argv, command: "nslookup")
            }),

            // host <name> [server] — a terser resolver: "<name> has address <ipv4>".
            Command(name: "host", summary: "resolve a hostname (terse)", category: .network, asyncRun: { ctx, argv in
                await runLookup(ctx, argv, command: "host")
            }),
        ]
    }

    static func dnsStatusName(_ code: Int) -> String {
        switch code {
        case 0: return "NOERROR"
        case 1: return "FORMERR"
        case 2: return "SERVFAIL"
        case 3: return "NXDOMAIN"
        case 4: return "NOTIMP"
        case 5: return "REFUSED"
        default: return "RCODE\(code)"
        }
    }

    static func dnsFlagNames(_ flags: UInt16) -> String {
        var names: [String] = []
        if flags & 0x8000 != 0 { names.append("qr") }
        if flags & 0x0400 != 0 { names.append("aa") }
        if flags & 0x0200 != 0 { names.append("tc") }
        if flags & 0x0100 != 0 { names.append("rd") }
        if flags & 0x0080 != 0 { names.append("ra") }
        return names.joined(separator: " ")
    }

    /// `dig`'s full report for one reply.
    static func renderDig(name: String,
                          message: DNS.Message,
                          server: IPv4Address,
                          port: UInt16,
                          queryMilliseconds: Int) -> String {
        let fqdn = name.hasSuffix(".") ? name : name + "."
        var text = "\n; <<>> DiG (swiftix) <<>> \(name)\n"
        text += ";; Got answer:\n"
        text += ";; ->>HEADER<<- opcode: QUERY, status: \(dnsStatusName(message.responseCode)), id: \(message.id)\n"
        text += ";; flags: \(dnsFlagNames(message.flags)); QUERY: \(message.questionCount), ANSWER: \(message.answers.count), AUTHORITY: 0, ADDITIONAL: 0\n"
        text += "\n;; QUESTION SECTION:\n;\(fqdn)\t\t\tIN\tA\n"
        if !message.answers.isEmpty {
            text += "\n;; ANSWER SECTION:\n"
            for answer in message.answers {
                let owner = answer.name.isEmpty ? fqdn : (answer.name.hasSuffix(".") ? answer.name : answer.name + ".")
                text += "\(owner)\t\t\(answer.ttl)\tIN\tA\t\(answer.address)\n"
            }
        }
        text += "\n;; Query time: \(queryMilliseconds) msec\n"
        text += ";; SERVER: \(server)#\(port)(\(server)) (UDP)\n\n"
        return text
    }

    private static func runDig(_ ctx: ProcessContext, _ argv: [String]) async {
        let usage = networkSynopsis("dig")
        guard let items = ctx.scanOptions(argv, command: "dig", usage: usage, flags: "4", valued: "pt") else { return }
        var serverName: String?
        var port = DNS.port
        var short = false
        var name: String?
        func requireA(_ type: String) -> Bool {
            guard type.uppercased() == "A" else {
                ctx.fail("dig: query type \(type.uppercased()) is not supported: this resolver only speaks A records", code: 1)
                return false
            }
            return true
        }
        for item in items {
            switch item {
            case .option("p", let value?):
                guard let parsed = UInt16(value), parsed != 0 else {
                    ctx.invalidArgument("dig", "invalid port: '\(value)'", usage: usage); return
                }
                port = parsed
            case .option("t", let value?):
                guard requireA(value) else { return }
            case .option:
                break
            case .operand(let word):
                if word.hasPrefix("@") {
                    serverName = String(word.dropFirst())
                } else if word.hasPrefix("+") {
                    switch word {
                    case "+short": short = true
                    case "+noall", "+answer", "+nocmd", "+nocomments", "+nostats", "+norecurse", "+recurse", "+tcp", "+notcp":
                        break   // accepted; the report is not sectioned finely enough to honor them
                    default:
                        ctx.invalidArgument("dig", "invalid option -- '\(word)'", usage: usage); return
                    }
                } else if name == nil {
                    name = word
                } else if word.uppercased() == "IN" {
                    continue
                } else {
                    guard requireA(word) else { return }
                }
            }
        }
        guard let name else { ctx.usage("dig", usage); return }

        var server: IPv4Address
        if let serverName {
            guard let resolved = await ctx.resolve(serverName) else {
                ctx.fail("dig: couldn't get address for '\(serverName)': not found", code: 10); return
            }
            server = resolved
        } else {
            guard let configured = ctx.resolverNameServers().first else {
                ctx.fail("dig: no nameserver configured (set /etc/resolv.conf or NAMESERVER, or use @server)", code: 10)
                return
            }
            server = configured
        }

        let start = ctx.logicalSeconds
        switch await ctx.dnsQuery(name, server: server, port: port) {
        case .response(let message):
            if short {
                for answer in message.answers { ctx.print("\(answer.address)\n") }
            } else {
                ctx.print(renderDig(name: name, message: message, server: server, port: port,
                                    queryMilliseconds: Int(((ctx.logicalSeconds - start) * 1000).rounded())))
            }
            ctx.exit(0)
        case .timedOut:
            ctx.print(";; communications error to \(server)#\(port): timed out\n")
            ctx.print(";; no servers could be reached\n")
            ctx.exit(9)
        case .socketUnavailable:
            ctx.fail("dig: socket failed", code: 10)
        }
    }

    /// `nslookup` / `host`: `<name> [server]`.
    private static func runLookup(_ ctx: ProcessContext, _ argv: [String], command: String) async {
        let usage = networkSynopsis(command)
        guard let items = ctx.scanOptions(argv, command: command, usage: usage, flags: "4") else { return }
        let operands = items.compactMap { item -> String? in
            if case .operand(let value) = item { return value }
            return nil
        }
        guard (1...2).contains(operands.count) else { ctx.usage(command, usage); return }
        let name = operands[0]
        let isHost = command == "host"

        func printServer(_ server: IPv4Address) {
            if isHost {
                ctx.print("Using domain server:\nName: \(server)\nAddress: \(server)#\(DNS.port)\nAliases: \n\n")
            } else {
                ctx.print("Server:\t\t\(server)\nAddress:\t\(server)#\(DNS.port)\n\n")
            }
        }
        func printAddresses(_ addresses: [IPv4Address]) {
            for address in addresses {
                ctx.print(isHost ? "\(name) has address \(address)\n" : "Name:\t\(name)\nAddress: \(address)\n")
            }
            ctx.exit(0)
        }
        func printNotFound() {
            ctx.print(isHost ? "Host \(name) not found: 3(NXDOMAIN)\n" : "** server can't find \(name): NXDOMAIN\n")
            ctx.exit(1)
        }

        if operands.count == 2 {
            guard let server = await ctx.resolve(operands[1]) else {
                ctx.fail("\(command): couldn't get address for '\(operands[1])': not found", code: 1); return
            }
            printServer(server)
            switch await ctx.dnsQuery(name, server: server) {
            case .response(let message) where !message.answers.isEmpty:
                printAddresses(message.answers.map(\.address))
            case .response:
                printNotFound()
            case .timedOut, .socketUnavailable:
                ctx.print(";; connection timed out; no servers could be reached\n")
                ctx.exit(1)
            }
            return
        }

        guard let resolved = await ctx.resolveWithSource(name) else {
            if !isHost, let server = ctx.resolverNameServers().first { printServer(server) }
            printNotFound()
            return
        }
        if !isHost, case .dns(let server) = resolved.source { printServer(server) }
        printAddresses([resolved.address])
    }
}
