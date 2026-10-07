/// Socket listings: `netstat` and `ss`.
///
/// Both render the same value snapshot (`NetworkSocketSnapshot`: TCP listeners,
/// TCP connections and bound UDP sockets of the caller's network namespace), so
/// a listening server is visible the moment it binds — the old `netstat` read
/// only `/proc/net/tcp`, which lists connections, and so showed nothing for an
/// idle `httpd`.
///
/// Process attribution (`-p`) is not guessed: it is read from the same
/// `/proc/<pid>/fdinfo` descriptor table `lsof`-style tools use, and a socket
/// with no visible owning descriptor simply has an empty process column.
///
/// Addresses and ports are always numeric (there is no services database), so
/// `-n` is accepted and changes nothing.
///
/// Concurrency: plain synchronous programs on the kernel's serial executor.
extension BuiltinCommands {

    static func networkSocketCommands() -> [Command] {
        [
            // netstat [-tulanp] | netstat -r | netstat -i
            Command(name: "netstat", summary: "show sockets, routes or interface counters", category: .network) { ctx, argv in
                runNetstat(ctx, argv)
            },

            // ss [-tulanpH]
            Command(name: "ss", summary: "show sockets", category: .network) { ctx, argv in
                runSS(ctx, argv)
            },
        ]
    }

    // MARK: - Selection

    struct SocketSelection: Equatable {
        var tcp = false
        var udp = false
        var listening = false
        var all = false
        var processes = false

        /// Neither `-t` nor `-u` means both protocols.
        var showsTCP: Bool { tcp || !udp }
        var showsUDP: Bool { udp || !tcp }
    }

    /// A process holding a descriptor for a socket.
    struct SocketOwner: Equatable {
        let pid: Int
        let name: String
        let descriptor: Int
    }

    /// The key a socket is known by in `/proc/<pid>/fdinfo`'s DETAIL column.
    static func socketOwnerKey(_ socket: NetworkSocketSnapshot) -> String {
        switch socket.kind {
        case .tcpListener:
            return "tcp listen=:\(socket.localPort)"
        case .tcpConnection:
            let remote = socket.remoteAddress.map { "\($0)" } ?? "*"
            return "tcp local=:\(socket.localPort),remote=\(remote):\(socket.remotePort)"
        case .udp:
            return "udp local=:\(socket.localPort)"
        }
    }

    /// Parse one process's `fdinfo` text (`FD TYPE ACCESS FLAGS OFFSET SIZE
    /// DETAIL`) into `(socket key, descriptor)` pairs for its TCP/UDP sockets.
    static func socketKeys(inDescriptorTable text: String) -> [(key: String, descriptor: Int)] {
        var keys: [(key: String, descriptor: Int)] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count >= 7, let descriptor = Int(fields[0]),
                  fields[1] == "tcp" || fields[1] == "udp" else { continue }
            var detail = fields[6]
            // A connection's detail ends in `,state=…`, which changes over its
            // life; the endpoint pair alone identifies it.
            if let state = detail.firstRange(of: ",state=") {
                detail = String(detail[detail.startIndex..<state.lowerBound])
            }
            keys.append(("\(fields[1]) \(detail)", descriptor))
        }
        return keys
    }

    /// Map every socket key to the processes holding it, from procfs.
    static func socketOwners(_ ctx: ProcessContext) -> [String: [SocketOwner]] {
        guard let table = readTextFile(ctx, "/proc/processes") else { return [:] }
        var owners: [String: [SocketOwner]] = [:]
        for line in table.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            // pid ppid pgid sid state ticks fds mem name…
            guard fields.count >= 9, let pid = Int(fields[0]) else { continue }
            let name = fields[8...].joined(separator: " ")
            guard let descriptors = readTextFile(ctx, "/proc/\(pid)/fdinfo") else { continue }
            for (key, descriptor) in socketKeys(inDescriptorTable: descriptors) {
                owners[key, default: []].append(SocketOwner(pid: pid, name: name, descriptor: descriptor))
            }
        }
        return owners
    }

    private static func endpoint(_ address: IPv4Address?, _ port: UInt16?) -> String {
        "\(address.map { "\($0)" } ?? "0.0.0.0"):\(port.map { "\($0)" } ?? "*")"
    }

    private static func localEndpoint(_ socket: NetworkSocketSnapshot) -> String {
        endpoint(socket.localAddress, socket.localPort)
    }

    private static func peerEndpoint(_ socket: NetworkSocketSnapshot) -> String {
        socket.kind == .tcpConnection ? endpoint(socket.remoteAddress, socket.remotePort) : endpoint(nil, nil)
    }

    // MARK: - netstat

    /// `netstat`'s spelling of a TCP state.
    static func netstatState(_ socket: NetworkSocketSnapshot) -> String {
        switch socket.kind {
        case .udp: return ""
        case .tcpListener: return "LISTEN"
        case .tcpConnection:
            switch socket.state {
            case "SYN_RECEIVED": return "SYN_RECV"
            case "FIN_WAIT_1": return "FIN_WAIT1"
            case "FIN_WAIT_2": return "FIN_WAIT2"
            default: return socket.state
            }
        }
    }

    /// The socket table as `netstat` prints it. With no `-l`/`-a` this lists
    /// servers *and* connections — Linux hides servers by default, but a listing
    /// that omits the listener you just started is the less useful default here.
    static func renderNetstat(_ sockets: [NetworkSocketSnapshot],
                              selection: SocketSelection,
                              owners: [String: [SocketOwner]] = [:]) -> String {
        var title = "Active Internet connections "
        title += selection.listening && !selection.all ? "(only servers)" : "(servers and established)"
        var header = "Proto Recv-Q Send-Q Local Address           Foreign Address         State      "
        if selection.processes { header += " PID/Program name" }
        var lines = [title, header]
        for socket in sockets {
            let isTCP = socket.kind != .udp
            guard isTCP ? selection.showsTCP : selection.showsUDP else { continue }
            if selection.listening, !selection.all, socket.kind == .tcpConnection { continue }
            var line = padRight(isTCP ? "tcp" : "udp", 5)
                + " " + padLeft(String(socket.receiveQueue), 6)
                + " " + padLeft(String(socket.sendQueue), 6)
                + " " + padRight(localEndpoint(socket), 23)
                + " " + padRight(peerEndpoint(socket), 23)
                + " " + padRight(netstatState(socket), 11)
            if selection.processes {
                let owner = owners[socketOwnerKey(socket)]?.min { $0.pid < $1.pid }
                line += " " + (owner.map { "\($0.pid)/\($0.name)" } ?? "-")
            }
            lines.append(trimTrailingSpaces(line))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `netstat -r`: the kernel routing table in net-tools columns.
    static func renderNetstatRoutes(_ routes: [NetworkRouteConfiguration], links: [NetworkLinkSnapshot]) -> String {
        var lines = ["Kernel IP routing table",
                     "Destination     Gateway         Genmask         Flags Iface"]
        for route in routes {
            let flags = "U" + (route.gateway != nil ? "G" : "") + (route.prefixLength == 32 ? "H" : "")
            lines.append(padRight("\(route.destination)", 15)
                + " " + padRight(route.gateway.map { "\($0)" } ?? "0.0.0.0", 15)
                + " " + padRight("\(netmask(route.prefixLength))", 15)
                + " " + padRight(flags, 5)
                + " " + interfaceName(route.interfaceIndex, in: links))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `netstat -i`: per-interface counters. Only the columns the stack counts
    /// are shown (no error/overrun columns, which it does not track).
    static func renderNetstatInterfaces(_ links: [NetworkLinkSnapshot]) -> String {
        var lines = ["Kernel Interface table",
                     "Iface             MTU    RX-OK RX-DRP    TX-OK Flg"]
        for link in links {
            let flags = link.isLoopback ? "LRU" : (link.hasCarrier ? "BMRU" : "BMU")
            lines.append(padRight(link.name, 15)
                + " " + padLeft(String(linkMTU(link)), 5)
                + " " + padLeft(String(link.counters.rxPackets), 8)
                + " " + padLeft(String(link.counters.drops), 6)
                + " " + padLeft(String(link.counters.txPackets), 8)
                + " " + flags)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func trimTrailingSpaces(_ line: String) -> String {
        var characters = Array(line)
        while characters.last == " " { characters.removeLast() }
        return String(characters)
    }

    private static func runNetstat(_ ctx: ProcessContext, _ argv: [String]) {
        let usage = networkSynopsis("netstat")
        guard let items = ctx.scanOptions(argv, command: "netstat", usage: usage, flags: "tulanpriWev4") else { return }
        var selection = SocketSelection()
        var routes = false
        var interfaces = false
        for item in items {
            switch item {
            case .operand:
                ctx.usage("netstat", usage); return
            case .option("t", _): selection.tcp = true
            case .option("u", _): selection.udp = true
            case .option("l", _): selection.listening = true
            case .option("a", _): selection.all = true
            case .option("p", _): selection.processes = true
            case .option("r", _): routes = true
            case .option("i", _): interfaces = true
            case .option: break   // -n / -W / -e / -v / -4: output is already numeric IPv4
            }
        }
        if routes {
            ctx.print(renderNetstatRoutes(ctx.snapshotNetworkConfiguration().routes, links: ctx.snapshotNetworkLinks()))
        } else if interfaces {
            ctx.print(renderNetstatInterfaces(ctx.snapshotNetworkLinks()))
        } else {
            ctx.print(renderNetstat(ctx.snapshotNetworkSockets(), selection: selection,
                                    owners: selection.processes ? socketOwners(ctx) : [:]))
        }
        ctx.exit(0)
    }

    // MARK: - ss

    /// `ss`'s spelling of a socket state.
    static func ssState(_ socket: NetworkSocketSnapshot) -> String {
        switch socket.kind {
        case .udp: return "UNCONN"
        case .tcpListener: return "LISTEN"
        case .tcpConnection:
            switch socket.state {
            case "ESTABLISHED": return "ESTAB"
            case "SYN_SENT": return "SYN-SENT"
            case "SYN_RECEIVED": return "SYN-RECV"
            case "FIN_WAIT_1": return "FIN-WAIT-1"
            case "FIN_WAIT_2": return "FIN-WAIT-2"
            case "CLOSE_WAIT": return "CLOSE-WAIT"
            case "LAST_ACK": return "LAST-ACK"
            case "TIME_WAIT": return "TIME-WAIT"
            default: return socket.state
            }
        }
    }

    /// The socket table as `ss` prints it. Like Linux: by default only
    /// connected sockets, `-l` only listening/unconnected ones, `-a` both.
    static func renderSS(_ sockets: [NetworkSocketSnapshot],
                         selection: SocketSelection,
                         owners: [String: [SocketOwner]] = [:],
                         header: Bool = true) -> String {
        var rows: [[String]] = []
        for socket in sockets {
            let isTCP = socket.kind != .udp
            guard isTCP ? selection.showsTCP : selection.showsUDP else { continue }
            let connected = socket.kind == .tcpConnection
            if !selection.all, selection.listening == connected { continue }
            var row = [isTCP ? "tcp" : "udp",
                       ssState(socket),
                       String(socket.receiveQueue),
                       String(socket.sendQueue),
                       localEndpoint(socket),
                       peerEndpoint(socket)]
            if selection.processes {
                let users = (owners[socketOwnerKey(socket)] ?? [])
                    .sorted { ($0.pid, $0.descriptor) < ($1.pid, $1.descriptor) }
                    .map { "(\"\($0.name)\",pid=\($0.pid),fd=\($0.descriptor))" }
                row.append(users.isEmpty ? "" : "users:(\(users.joined(separator: ",")))")
            }
            rows.append(row)
        }
        var titles = ["Netid", "State", "Recv-Q", "Send-Q", "Local Address:Port", "Peer Address:Port"]
        if selection.processes { titles.append("Process") }
        let table = (header ? [titles] : []) + rows
        guard !table.isEmpty else { return "" }
        var widths = [Int](repeating: 0, count: titles.count)
        for row in table {
            for (column, cell) in row.enumerated() { widths[column] = max(widths[column], cell.count) }
        }
        let lines = table.map { row in
            trimTrailingSpaces(row.enumerated().map { column, cell in
                // Endpoints are right-aligned so the ports line up, as in iproute2.
                column == 4 || column == 5 ? padLeft(cell, widths[column]) : padRight(cell, widths[column])
            }.joined(separator: " "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func runSS(_ ctx: ProcessContext, _ argv: [String]) {
        let usage = networkSynopsis("ss")
        guard let items = ctx.scanOptions(argv, command: "ss", usage: usage, flags: "tulanpH4eO",
                                          long: ["tcp": .init("t"), "udp": .init("u"),
                                                 "listening": .init("l"), "all": .init("a"),
                                                 "numeric": .init("n"), "processes": .init("p"),
                                                 "no-header": .init("H")]) else { return }
        var selection = SocketSelection()
        var header = true
        for item in items {
            switch item {
            case .operand:
                ctx.usage("ss", usage); return
            case .option("t", _): selection.tcp = true
            case .option("u", _): selection.udp = true
            case .option("l", _): selection.listening = true
            case .option("a", _): selection.all = true
            case .option("p", _): selection.processes = true
            case .option("H", _): header = false
            case .option: break   // -n / -4 / -e / -O: already numeric IPv4, one line each
            }
        }
        ctx.print(renderSS(ctx.snapshotNetworkSockets(), selection: selection,
                           owners: selection.processes ? socketOwners(ctx) : [:], header: header))
        ctx.exit(0)
    }
}
