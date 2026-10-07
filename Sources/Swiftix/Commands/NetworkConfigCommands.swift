/// Network configuration front-ends: the iproute2-style `ip` and the classic
/// `ifconfig` / `route` / `arp`.
///
/// Show forms render value snapshots (`NetworkLinkSnapshot`, the route and
/// neighbor tables of `NetworkConfiguration`) in Linux-like text; the renderers
/// are pure functions so the output shape is testable without a shell. Mutating
/// forms go through `ProcessContext`'s network configuration syscalls.
///
/// What the single-node stack does not model is reported, not faked:
///
///   - There is one IPv4 address per interface and an interface *is* its
///     address, so `ip addr add` creates an interface (and needs `lladdr`), and
///     `ip addr del` is refused.
///   - There is no administrative link state, so `ip link set … up|down` is
///     refused. `LOWER_UP`/`NO-CARRIER` reflect whether a link has claimed the
///     interface's egress seam.
///   - There is no MTU; `mtu` shows the nominal Ethernet (1500) and loopback
///     (65536) values.
///   - The neighbor cache keeps no per-entry state, so every listed entry is
///     shown as `REACHABLE`.
///
/// Concurrency: plain synchronous programs on the kernel's serial executor.
extension BuiltinCommands {

    static func networkConfigCommands() -> [Command] {
        [
            // ifconfig [-a] [interface] | ifconfig add <ip>/<prefix> <mac>
            Command(name: "ifconfig", summary: "show or add interfaces", category: .network) { ctx, argv in
                runIfconfig(ctx, argv)
            },

            // route [-n] | route add|del <cidr|default> [via|gw <gateway>] [dev ethN]
            Command(name: "route", summary: "show, add or delete routes", category: .network) { ctx, argv in
                runRoute(ctx, argv)
            },

            // arp [-a] [-n] | arp -s|add <ip> <mac> | arp -d|del <ip>
            Command(name: "arp", summary: "show, add or delete ARP entries", category: .network) { ctx, argv in
                runARP(ctx, argv)
            },

            // ip — iproute2-style frontend: addr / route / neigh / link show forms
            // plus add/del, and the `forwarding` extension.
            Command(name: "ip", summary: "show or configure addresses, routes, neighbors, links", category: .network) { ctx, argv in
                runIP(ctx, argv)
            },
        ]
    }

    // MARK: - Linux-like renderers (pure)

    struct IPDisplayOptions: Equatable {
        var brief = false
        var oneline = false
        var statistics = false
        /// `-4` (the default) or `-6`; IPv6 is not implemented, so `-6` lists nothing.
        var family = 4
    }

    static let nominalEthernetMTU = 1500
    static let nominalLoopbackMTU = 65536

    static func linkMTU(_ link: NetworkLinkSnapshot) -> Int {
        link.isLoopback ? nominalLoopbackMTU : nominalEthernetMTU
    }

    static func linkFlags(_ link: NetworkLinkSnapshot) -> String {
        if link.isLoopback { return "LOOPBACK,UP,LOWER_UP" }
        return link.hasCarrier ? "BROADCAST,MULTICAST,UP,LOWER_UP" : "NO-CARRIER,BROADCAST,MULTICAST,UP"
    }

    static func linkOperationalState(_ link: NetworkLinkSnapshot) -> String {
        if link.isLoopback { return "UNKNOWN" }
        return link.hasCarrier ? "UP" : "DOWN"
    }

    private static func linkHeader(_ link: NetworkLinkSnapshot) -> String {
        "\(link.index + 1): \(link.name): <\(linkFlags(link))> mtu \(linkMTU(link)) state \(linkOperationalState(link))"
    }

    private static func linkLayerLine(_ link: NetworkLinkSnapshot) -> String {
        link.isLoopback
            ? "link/loopback \(link.mac) brd 00:00:00:00:00:00"
            : "link/ether \(link.mac) brd ff:ff:ff:ff:ff:ff"
    }

    private static func inetLine(_ link: NetworkLinkSnapshot) -> String {
        if link.isLoopback || link.prefixLength >= 31 {
            return "inet \(link.address)/\(link.prefixLength) scope \(link.isLoopback ? "host" : "global") \(link.name)"
        }
        let mask = NetworkRouteTable.mask(link.prefixLength)
        let broadcast = IPv4Address(raw: (link.address.raw & mask) | ~mask)
        return "inet \(link.address)/\(link.prefixLength) brd \(broadcast) scope global \(link.name)"
    }

    private static func statisticsLines(_ link: NetworkLinkSnapshot) -> [String] {
        let c = link.counters
        return [
            "    RX:  bytes packets dropped",
            "    \(padLeft(String(c.rxBytes), 10)) \(padLeft(String(c.rxPackets), 7)) \(padLeft(String(c.drops), 7))",
            "    TX:  bytes packets",
            "    \(padLeft(String(c.txBytes), 10)) \(padLeft(String(c.txPackets), 7))",
        ]
    }

    /// `ip addr show`.
    static func renderAddresses(_ links: [NetworkLinkSnapshot], options: IPDisplayOptions = IPDisplayOptions()) -> String {
        guard options.family == 4 else { return "" }
        var lines: [String] = []
        for link in links {
            if options.brief {
                lines.append("\(padRight(link.name, 16)) \(padRight(linkOperationalState(link), 14)) \(link.address)/\(link.prefixLength) ")
            } else if options.oneline {
                lines.append("\(link.index + 1): \(padRight(link.name, 4))    \(inetLine(link))")
            } else {
                lines.append(linkHeader(link))
                lines.append("    " + linkLayerLine(link))
                lines.append("    " + inetLine(link))
                lines.append("       valid_lft forever preferred_lft forever")
                if options.statistics { lines.append(contentsOf: statisticsLines(link)) }
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// `ip link show`.
    static func renderLinks(_ links: [NetworkLinkSnapshot], options: IPDisplayOptions = IPDisplayOptions()) -> String {
        var lines: [String] = []
        for link in links {
            if options.brief {
                lines.append("\(padRight(link.name, 16)) \(padRight(linkOperationalState(link), 14)) \(link.mac) <\(linkFlags(link))> ")
            } else if options.oneline {
                lines.append(linkHeader(link) + "\\    " + linkLayerLine(link))
            } else {
                lines.append(linkHeader(link))
                lines.append("    " + linkLayerLine(link))
                if options.statistics { lines.append(contentsOf: statisticsLines(link)) }
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func interfaceName(_ index: Int, in links: [NetworkLinkSnapshot]) -> String {
        links.first { $0.index == index }?.name ?? "eth\(index)"
    }

    /// One `ip route` line: `default via G dev IF`, or `NET/LEN dev IF scope link`
    /// (with `proto kernel … src ADDR` for an interface's own connected route).
    static func routeLine(_ route: NetworkRouteConfiguration, links: [NetworkLinkSnapshot]) -> String {
        let device = interfaceName(route.interfaceIndex, in: links)
        let destination = route.prefixLength == 0 && route.destination.raw == 0
            ? "default"
            : (route.prefixLength == 32 ? "\(route.destination)" : "\(route.destination)/\(route.prefixLength)")
        if let gateway = route.gateway {
            return "\(destination) via \(gateway) dev \(device)"
        }
        if let link = links.first(where: { $0.index == route.interfaceIndex }),
           link.prefixLength == route.prefixLength,
           link.address.raw & NetworkRouteTable.mask(link.prefixLength) == route.destination.raw {
            return "\(destination) dev \(device) proto kernel scope \(link.isLoopback ? "host" : "link") src \(link.address)"
        }
        return "\(destination) dev \(device) scope link"
    }

    /// `ip route show`: default routes first (as Linux lists them), then the
    /// table in insertion order.
    static func renderRoutes(_ routes: [NetworkRouteConfiguration], links: [NetworkLinkSnapshot]) -> String {
        let ordered = routes.filter { $0.prefixLength == 0 } + routes.filter { $0.prefixLength != 0 }
        let lines = ordered.map { routeLine($0, links: links) }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Longest-prefix match over a route table snapshot (what the stack does on
    /// egress), for `ip route get` and for naming a neighbor's device.
    static func lookupRoute(_ destination: IPv4Address,
                            in routes: [NetworkRouteConfiguration]) -> NetworkRouteConfiguration? {
        routes
            .filter { destination.raw & NetworkRouteTable.mask($0.prefixLength) == $0.destination.raw }
            .max { $0.prefixLength < $1.prefixLength }
    }

    /// `ip neigh show`: `IP dev IF lladdr MAC REACHABLE`.
    static func renderNeighbors(_ neighbors: [NetworkNeighborConfiguration],
                                routes: [NetworkRouteConfiguration],
                                links: [NetworkLinkSnapshot],
                                device: String? = nil) -> String {
        var lines: [String] = []
        for neighbor in neighbors {
            let name = neighborDevice(neighbor.ip, routes: routes, links: links)
            if let device, device != name { continue }
            lines.append("\(neighbor.ip) dev \(name ?? "?") lladdr \(neighbor.mac) REACHABLE")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func neighborDevice(_ ip: IPv4Address,
                               routes: [NetworkRouteConfiguration],
                               links: [NetworkLinkSnapshot]) -> String? {
        lookupRoute(ip, in: routes).map { interfaceName($0.interfaceIndex, in: links) }
    }

    // MARK: - ifconfig / route / arp

    private static func runIfconfig(_ ctx: ProcessContext, _ argv: [String]) {
        let usage = networkSynopsis("ifconfig")
        if argv.count >= 2, argv[1] == "add" {
            guard argv.count == 4,
                  let (address, prefixLength) = parseCIDR(argv[2]),
                  let mac = MACAddress(argv[3]) else {
                ctx.usage("ifconfig", usage); return
            }
            addInterface(ctx, command: "ifconfig", address: address, prefixLength: prefixLength, mac: mac)
            return
        }
        guard let items = ctx.scanOptions(argv, command: "ifconfig", usage: usage, flags: "as") else { return }
        let names = items.compactMap { item -> String? in
            if case .operand(let name) = item { return name }
            return nil
        }
        guard names.count <= 1 else { ctx.usage("ifconfig", usage); return }
        guard let text = readTextFile(ctx, "/proc/net/dev") else {
            ctx.fail("ifconfig: /proc/net/dev unavailable", code: 1); return
        }
        guard let name = names.first else {
            ctx.print(text)
            ctx.exit(0)
            return
        }
        let lines = text.split(separator: "\n").filter { $0.split(separator: " ").first.map(String.init) == name }
        guard !lines.isEmpty else {
            ctx.fail("ifconfig: \(name): error fetching interface information: Device not found", code: 1); return
        }
        ctx.print(lines.joined(separator: "\n") + "\n")
        ctx.exit(0)
    }

    private static func runRoute(_ ctx: ProcessContext, _ argv: [String]) {
        let usage = networkSynopsis("route")
        if argv.count >= 2, argv[1] == "add" || argv[1] == "del" || argv[1] == "delete" {
            let rest = Array(argv.dropFirst(2)).filter { $0 != "-net" && $0 != "-host" }
            guard let spec = parseRouteArguments(rest, context: ctx) else {
                ctx.usage("route", usage); return
            }
            if argv[1] == "add" {
                addRoute(ctx, command: "route", spec)
            } else {
                deleteRoute(ctx, command: "route", spec)
            }
            return
        }
        guard let items = ctx.scanOptions(argv, command: "route", usage: usage, flags: "ne") else { return }
        guard !items.contains(where: { if case .operand = $0 { return true } else { return false } }) else {
            ctx.usage("route", usage); return
        }
        guard let text = readTextFile(ctx, "/proc/net/route") else {
            ctx.fail("route: /proc/net/route unavailable", code: 1); return
        }
        ctx.print("destination gateway interface\n" + text)
        ctx.exit(0)
    }

    private static func runARP(_ ctx: ProcessContext, _ argv: [String]) {
        let usage = networkSynopsis("arp")
        var arguments = argv
        // Word forms kept from the original command: `arp add IP MAC`, `arp del IP`.
        if arguments.count >= 2 {
            if arguments[1] == "add" { arguments[1] = "-s" }
            if arguments[1] == "del" || arguments[1] == "delete" { arguments[1] = "-d" }
        }
        guard let items = ctx.scanOptions(arguments, command: "arp", usage: usage, flags: "anesd", valued: "i") else { return }
        var bsdStyle = false
        var set = false
        var delete = false
        var operands: [String] = []
        for item in items {
            switch item {
            case .operand(let value): operands.append(value)
            case .option("a", _): bsdStyle = true
            case .option("s", _): set = true
            case .option("d", _): delete = true
            case .option: break   // -n / -e / -i: numeric table is the only form
            }
        }
        if set {
            guard !delete, operands.count == 2,
                  let ip = IPv4Address(operands[0]),
                  let mac = MACAddress(operands[1]) else {
                ctx.usage("arp", usage); return
            }
            ctx.configureNetwork(.addNeighbor(NetworkNeighborConfiguration(ip: ip, mac: mac)))
            ctx.exit(0)
            return
        }
        if delete {
            guard operands.count == 1, let ip = IPv4Address(operands[0]) else {
                ctx.usage("arp", usage); return
            }
            guard ctx.removeNetworkNeighbor(ip: ip) else {
                ctx.fail("arp: no ARP entry for \(ip)", code: 1); return
            }
            ctx.exit(0)
            return
        }
        guard operands.count <= 1 else { ctx.usage("arp", usage); return }
        var only: IPv4Address?
        if let operand = operands.first {
            guard let ip = IPv4Address(operand) else { ctx.usage("arp", usage); return }
            only = ip
        }
        let configuration = ctx.snapshotNetworkConfiguration()
        let links = ctx.snapshotNetworkLinks()
        let neighbors = configuration.neighbors.filter { only == nil || $0.ip == only }
        if let only, neighbors.isEmpty {
            ctx.print("\(only) -- no entry\n")
            ctx.exit(1)
            return
        }
        if bsdStyle {
            for neighbor in neighbors {
                let device = neighborDevice(neighbor.ip, routes: configuration.routes, links: links)
                ctx.print("? (\(neighbor.ip)) at \(neighbor.mac) [ether] on \(device ?? "?")\n")
            }
        } else {
            ctx.print("address hwaddress\n")
            for neighbor in neighbors {
                ctx.print("\(neighbor.ip) \(neighbor.mac)\n")
            }
        }
        ctx.exit(0)
    }

    // MARK: - ip

    private static let ipUsageText = "usage: " + ipUsageLines.joined(separator: "\n       ")

    private static func ipUsage(_ ctx: ProcessContext) {
        ctx.fail("ip: " + ipUsageText)
    }

    private static func ipFail(_ ctx: ProcessContext, _ message: String, code: Int32 = 1) {
        ctx.fail("ip: \(message)", code: code)
    }

    /// iproute2 accepts any unambiguous-by-order prefix of an object or command
    /// name (`ip a`, `ip r s`, `ip n sh`).
    private static func abbreviates(_ word: String, _ candidates: String...) -> Bool {
        !word.isEmpty && candidates.contains { $0.hasPrefix(word) }
    }

    private static func runIP(_ ctx: ProcessContext, _ argv: [String]) {
        var options = IPDisplayOptions()
        var args = Array(argv.dropFirst())
        while let first = args.first, first.hasPrefix("-") {
            args.removeFirst()
            let name = first.hasPrefix("--") ? String(first.dropFirst(2)) : String(first.dropFirst())
            switch name {
            case "4": options.family = 4
            case "6": options.family = 6
            case "br", "brief": options.brief = true
            case "o", "oneline": options.oneline = true
            case "s", "stats", "statistics": options.statistics = true
            case "d", "details", "c", "color", "h", "human", "human-readable", "n", "numeric":
                break
            case "help":
                ctx.print("U" + ipUsageText.dropFirst() + "\n")
                ctx.exit(0)
                return
            default:
                ctx.error("ip: invalid option -- '\(first)'")
                ipUsage(ctx)
                return
            }
        }
        guard let object = args.first else { ipUsage(ctx); return }
        let rest = Array(args.dropFirst())

        // Order matters, as in iproute2: `a` is address, `r` route, `n` neigh, `l` link.
        if abbreviates(object, "address") {
            runIPAddress(ctx, rest, options)
        } else if abbreviates(object, "route") {
            runIPRoute(ctx, rest)
        } else if abbreviates(object, "neighbor", "neighbour") {
            runIPNeighbor(ctx, rest)
        } else if abbreviates(object, "link") {
            runIPLink(ctx, rest, options)
        } else if abbreviates(object, "forwarding") {
            runIPForwarding(ctx, rest)
        } else if object == "help" {
            ctx.print("U" + ipUsageText.dropFirst() + "\n")
            ctx.exit(0)
        } else {
            ctx.error("ip: Object \"\(object)\" is unknown, try \"ip help\".")
            ctx.exit(1)
        }
    }

    /// Resolve the optional `[dev] IF` selector of a show form. Returns `nil`
    /// after reporting when the device does not exist or the syntax is wrong.
    private static func selectLinks(_ ctx: ProcessContext, _ selector: [String]) -> [NetworkLinkSnapshot]? {
        let links = ctx.snapshotNetworkLinks()
        var words = selector
        if words.first == "dev" { words.removeFirst() }
        if words.first == "up" { words.removeFirst() }   // every interface is up
        guard let name = words.first else {
            guard selector.first != "dev" else { ipFail(ctx, "Command line is not complete. Try option \"help\"", code: 2); return nil }
            return links
        }
        guard words.count == 1 else { ipUsage(ctx); return nil }
        let selected = links.filter { $0.name == name }
        guard !selected.isEmpty else {
            ipFail(ctx, "Device \"\(name)\" does not exist."); return nil
        }
        return selected
    }

    private static func runIPAddress(_ ctx: ProcessContext, _ args: [String], _ options: IPDisplayOptions) {
        let command = args.first ?? "show"
        if abbreviates(command, "show", "list", "lst") || args.isEmpty {
            guard let links = selectLinks(ctx, Array(args.dropFirst())) else { return }
            ctx.print(renderAddresses(links, options: options))
            ctx.exit(0)
        } else if abbreviates(command, "add") {
            let rest = Array(args.dropFirst())
            guard let first = rest.first, let (address, prefixLength) = parseCIDR(first) else {
                ipUsage(ctx); return
            }
            var mac: MACAddress?
            var index = 1
            while index < rest.count {
                switch rest[index] {
                case "lladdr", "mac", "ether":
                    guard index + 1 < rest.count, let parsed = MACAddress(rest[index + 1]) else { ipUsage(ctx); return }
                    mac = parsed
                    index += 2
                case "dev", "brd", "broadcast", "scope", "label":
                    guard index + 1 < rest.count else { ipUsage(ctx); return }
                    index += 2
                default:
                    ipUsage(ctx); return
                }
            }
            guard let mac else {
                ipFail(ctx, "addr add: this stack has one address per interface, so adding an address "
                    + "creates an interface: ip addr add <ip>/<prefix> lladdr <mac>", code: 2)
                return
            }
            addInterface(ctx, command: "ip", address: address, prefixLength: prefixLength, mac: mac)
        } else if abbreviates(command, "delete") || command == "flush" {
            ipFail(ctx, "addr \(command): not supported: an interface is its address in this stack, "
                + "and interfaces are attached by the host topology")
        } else {
            ipFail(ctx, "Command \"\(command)\" is unknown, try \"ip address help\".")
        }
    }

    private static func runIPLink(_ ctx: ProcessContext, _ args: [String], _ options: IPDisplayOptions) {
        let command = args.first ?? "show"
        if abbreviates(command, "show", "list", "lst") || args.isEmpty {
            guard let links = selectLinks(ctx, Array(args.dropFirst())) else { return }
            ctx.print(renderLinks(links, options: options))
            ctx.exit(0)
        } else if command == "set" {
            var words = Array(args.dropFirst())
            if words.first == "dev" { words.removeFirst() }
            guard let name = words.first else { ipUsage(ctx); return }
            guard ctx.networkInterfaceIndex(named: name) != nil else {
                ipFail(ctx, "Cannot find device \"\(name)\""); return
            }
            ipFail(ctx, "link set: not supported: this stack does not model link state "
                + "(interfaces are always up; carrier follows the attached link)")
        } else {
            ipFail(ctx, "Command \"\(command)\" is unknown, try \"ip link help\".")
        }
    }

    private static func runIPRoute(_ ctx: ProcessContext, _ args: [String]) {
        let command = args.first ?? "show"
        let rest = Array(args.dropFirst())
        if abbreviates(command, "show", "list", "lst") || args.isEmpty {
            let links = ctx.snapshotNetworkLinks()
            var routes = ctx.snapshotNetworkConfiguration().routes
            var words = rest
            while let word = words.first {
                words.removeFirst()
                switch word {
                case "dev":
                    guard let name = words.first else { ipUsage(ctx); return }
                    words.removeFirst()
                    guard let index = ctx.networkInterfaceIndex(named: name) else {
                        ipFail(ctx, "Cannot find device \"\(name)\""); return
                    }
                    routes = routes.filter { $0.interfaceIndex == index }
                case "default":
                    routes = routes.filter { $0.prefixLength == 0 }
                case "table", "proto", "scope", "type":
                    if !words.isEmpty { words.removeFirst() }
                default:
                    guard let (address, prefixLength) = parseCIDR(word, allowBareHost: true) else { ipUsage(ctx); return }
                    routes = routes.filter { $0.destination == address && $0.prefixLength == prefixLength }
                }
            }
            ctx.print(renderRoutes(routes, links: links))
            ctx.exit(0)
        } else if abbreviates(command, "get") {
            guard let first = rest.first, let destination = IPv4Address(first) else { ipUsage(ctx); return }
            let links = ctx.snapshotNetworkLinks()
            guard let route = lookupRoute(destination, in: ctx.snapshotNetworkConfiguration().routes) else {
                ipFail(ctx, "RTNETLINK answers: Network is unreachable", code: 2); return
            }
            let device = interfaceName(route.interfaceIndex, in: links)
            var line = "\(destination)"
            if let gateway = route.gateway { line += " via \(gateway)" }
            line += " dev \(device)"
            if let source = links.first(where: { $0.index == route.interfaceIndex })?.address {
                line += " src \(source)"
            }
            ctx.print(line + "\n")
            ctx.exit(0)
        } else if abbreviates(command, "add", "append") {
            guard let spec = parseRouteArguments(rest, context: ctx) else { ipUsage(ctx); return }
            addRoute(ctx, command: "ip", spec)
        } else if abbreviates(command, "replace", "change") {
            guard let spec = parseRouteArguments(rest, context: ctx) else { ipUsage(ctx); return }
            _ = ctx.removeNetworkRoute(destination: spec.destination, prefixLength: spec.prefixLength,
                                       gateway: nil, interfaceIndex: nil)
            addRoute(ctx, command: "ip", spec)
        } else if abbreviates(command, "delete") {
            guard let spec = parseRouteArguments(rest, context: ctx) else { ipUsage(ctx); return }
            deleteRoute(ctx, command: "ip", spec)
        } else {
            ipFail(ctx, "Command \"\(command)\" is unknown, try \"ip route help\".")
        }
    }

    private static func runIPNeighbor(_ ctx: ProcessContext, _ args: [String]) {
        let command = args.first ?? "show"
        let rest = Array(args.dropFirst())
        if abbreviates(command, "show", "list", "lst") || args.isEmpty {
            var device: String?
            if !rest.isEmpty {
                guard rest.count == 2, rest[0] == "dev" else { ipUsage(ctx); return }
                guard ctx.networkInterfaceIndex(named: rest[1]) != nil else {
                    ipFail(ctx, "Cannot find device \"\(rest[1])\""); return
                }
                device = rest[1]
            }
            let configuration = ctx.snapshotNetworkConfiguration()
            ctx.print(renderNeighbors(configuration.neighbors, routes: configuration.routes,
                                      links: ctx.snapshotNetworkLinks(), device: device))
            ctx.exit(0)
        } else if abbreviates(command, "add", "replace", "change") {
            guard let neighbor = parseNeighborArguments(rest) else { ipUsage(ctx); return }
            let exists = ctx.snapshotNetworkConfiguration().neighbors.contains { $0.ip == neighbor.ip }
            if exists, abbreviates(command, "add") {
                ipFail(ctx, "RTNETLINK answers: File exists", code: 2); return
            }
            ctx.configureNetwork(.addNeighbor(neighbor))
            ctx.exit(0)
        } else if abbreviates(command, "delete") {
            guard let first = rest.first, let address = IPv4Address(first) else { ipUsage(ctx); return }
            guard ctx.removeNetworkNeighbor(ip: address) else {
                ipFail(ctx, "RTNETLINK answers: No such file or directory", code: 2); return
            }
            ctx.exit(0)
        } else {
            ipFail(ctx, "Command \"\(command)\" is unknown, try \"ip neigh help\".")
        }
    }

    private static func runIPForwarding(_ ctx: ProcessContext, _ args: [String]) {
        if args.isEmpty {
            let enabled = ctx.snapshotNetworkConfiguration().ipForwardingEnabled
            ctx.print("forwarding: \(enabled ? "on" : "off")\n")
            ctx.exit(0)
            return
        }
        guard args.count == 1, let enabled = parseSwitch(args[0]) else {
            ipUsage(ctx)
            return
        }
        ctx.configureNetwork(.setIPForwarding(enabled))
        ctx.print("forwarding: \(enabled ? "on" : "off")\n")
        ctx.exit(0)
    }

    // MARK: - Mutations

    private static func addInterface(_ ctx: ProcessContext,
                                     command: String,
                                     address: IPv4Address,
                                     prefixLength: Int,
                                     mac: MACAddress) {
        do {
            try ctx.configureNetworkValidated(.addInterface(
                NetworkInterfaceConfiguration(address: address, mac: mac, prefixLength: prefixLength)))
            ctx.exit(0)
        } catch NetworkConfigurationError.duplicateAddress(let duplicate) {
            ctx.fail("\(command): address \(duplicate) is already assigned", code: 2)
        } catch NetworkConfigurationError.duplicateMAC(let duplicate) {
            ctx.fail("\(command): link-layer address \(duplicate) is already in use", code: 2)
        } catch {
            ctx.fail("\(command): invalid interface configuration", code: 2)
        }
    }

    /// A route as typed on a command line, before the egress interface is settled.
    struct RouteArguments: Equatable {
        var destination: IPv4Address
        var prefixLength: Int
        var gateway: IPv4Address?
        var interfaceIndex: Int?
    }

    private static func parseRouteArguments(_ args: [String], context: ProcessContext) -> RouteArguments? {
        guard let first = args.first else { return nil }
        let destination: (address: IPv4Address, prefixLength: Int)
        if first == "default" {
            destination = (IPv4Address(0, 0, 0, 0), 0)
        } else if let parsed = parseCIDR(first, allowBareHost: true) {
            destination = parsed
        } else {
            return nil
        }
        var spec = RouteArguments(destination: destination.address, prefixLength: destination.prefixLength)
        var index = 1
        while index < args.count {
            guard index + 1 < args.count else { return nil }
            let value = args[index + 1]
            switch args[index] {
            case "via", "gw":
                guard let address = IPv4Address(value) else { return nil }
                spec.gateway = address
            case "dev":
                if let named = context.networkInterfaceIndex(named: value) {
                    spec.interfaceIndex = named
                } else if let numeric = Int(value), numeric >= 0 {
                    spec.interfaceIndex = numeric
                } else {
                    return nil
                }
            case "proto", "metric", "scope", "src", "table", "netmask":
                break   // accepted for iproute2/net-tools compatibility; not modeled
            default:
                return nil
            }
            index += 2
        }
        return spec
    }

    /// Choose the egress interface for a route typed without `dev`: the
    /// interface whose subnet contains the gateway, else the first non-loopback
    /// interface, else interface 0.
    static func inferRouteInterface(gateway: IPv4Address?, links: [NetworkLinkSnapshot]) -> Int {
        if let gateway,
           let onLink = links.first(where: {
               let mask = NetworkRouteTable.mask($0.prefixLength)
               return gateway.raw & mask == $0.address.raw & mask
           }) {
            return onLink.index
        }
        return links.first { !$0.isLoopback }?.index ?? 0
    }

    private static func addRoute(_ ctx: ProcessContext, command: String, _ spec: RouteArguments) {
        let links = ctx.snapshotNetworkLinks()
        let route = NetworkRouteConfiguration(
            destination: IPv4Address(raw: spec.destination.raw & NetworkRouteTable.mask(spec.prefixLength)),
            prefixLength: spec.prefixLength,
            gateway: spec.gateway,
            interfaceIndex: spec.interfaceIndex ?? inferRouteInterface(gateway: spec.gateway, links: links))
        guard !ctx.snapshotNetworkConfiguration().routes.contains(route) else {
            ctx.fail("\(command): RTNETLINK answers: File exists", code: 2); return
        }
        do {
            try ctx.configureNetworkValidated(.addRoute(route))
            ctx.exit(0)
        } catch {
            ctx.fail("\(command): RTNETLINK answers: No such device", code: 2)
        }
    }

    private static func deleteRoute(_ ctx: ProcessContext, command: String, _ spec: RouteArguments) {
        guard ctx.removeNetworkRoute(destination: spec.destination,
                                     prefixLength: spec.prefixLength,
                                     gateway: spec.gateway,
                                     interfaceIndex: spec.interfaceIndex) else {
            ctx.fail("\(command): RTNETLINK answers: No such process", code: 2); return
        }
        ctx.exit(0)
    }

    private static func parseNeighborArguments(_ args: [String]) -> NetworkNeighborConfiguration? {
        guard let first = args.first, let ip = IPv4Address(first) else { return nil }
        var mac: MACAddress?
        var index = 1
        while index < args.count {
            guard index + 1 < args.count else { return nil }
            switch args[index] {
            case "lladdr", "mac", "ether":
                guard let parsed = MACAddress(args[index + 1]) else { return nil }
                mac = parsed
            case "dev", "nud":
                break   // the cache is per-stack and stateless
            default:
                return nil
            }
            index += 2
        }
        return mac.map { NetworkNeighborConfiguration(ip: ip, mac: $0) }
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
}
