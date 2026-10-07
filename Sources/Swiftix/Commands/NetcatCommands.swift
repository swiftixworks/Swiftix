/// `nc` and `telnet`: byte relays between the terminal and a socket.
///
/// One process multiplexes stdin and the socket with `poll`, so there is no
/// helper child left reading the terminal after the peer goes away. Modes:
///
///   - `nc HOST PORT`            — TCP client
///   - `nc -l [-p] PORT [-k]`    — TCP server: accept one connection (`-k`: keep accepting)
///   - `nc -u HOST PORT`         — UDP client
///   - `nc -u -l [-p] PORT`      — UDP server: replies go to the first sender
///   - `nc -z [-v] HOST PORT[-PORT]` — connect scan, no I/O
///
/// End-of-input policy: a TCP relay ends when the peer closes. After stdin
/// reaches EOF it keeps printing what the peer sends (as OpenBSD `nc` does);
/// `-q SECONDS` ends it that long after stdin EOF, and `-w SECONDS` ends it
/// after that much inactivity (it also bounds the connect). A UDP client has no
/// "peer closed", so it ends at stdin EOF unless `-q`/`-w` ask it to linger.
///
/// Concurrency: `async` programs on the kernel's serial executor; every wait is
/// a parked syscall and every timeout a logical-time deadline.
extension BuiltinCommands {

    static func netcatCommands() -> [Command] {
        [
            Command(name: "nc", summary: "TCP/UDP client and listener: relay stdin/stdout", category: .network, asyncRun: { ctx, argv in
                await runNetcat(ctx, argv)
            }),

            // telnet <host> [port] — a TCP relay with telnet's connection banner.
            // (No option negotiation: it is `nc` with the familiar chatter.)
            Command(name: "telnet", summary: "connect to a TCP port interactively", category: .network, asyncRun: { ctx, argv in
                await runTelnet(ctx, argv)
            }),
        ]
    }

    private static let netcatUsage = networkSynopsis("nc")

    struct NetcatOptions: Equatable {
        var listen = false
        var keepListening = false
        var udp = false
        var scan = false
        var verbose = false
        /// `-d`: never read stdin.
        var detached = false
        var localPort: UInt16?
        var timeout: Double?
        var quitAfterEOF: Double?
        var operands: [String] = []
    }

    /// `"80"` → `80...80`, `"20-25"` → `20...25`.
    static func parsePortRange(_ text: String) -> ClosedRange<UInt16>? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 1, let port = UInt16(parts[0]), port != 0 { return port...port }
        guard parts.count == 2, let low = UInt16(parts[0]), let high = UInt16(parts[1]),
              low != 0, low <= high else { return nil }
        return low...high
    }

    private static func parseNetcatOptions(_ ctx: ProcessContext, _ argv: [String]) -> NetcatOptions? {
        guard let items = ctx.scanOptions(argv, command: "nc", usage: netcatUsage,
                                          flags: "lkuzvdn4t", valued: "pwq") else { return nil }
        var options = NetcatOptions()
        for item in items {
            switch item {
            case .operand(let value): options.operands.append(value)
            case .option("l", _): options.listen = true
            case .option("k", _): options.keepListening = true
            case .option("u", _): options.udp = true
            case .option("z", _): options.scan = true
            case .option("v", _): options.verbose = true
            case .option("d", _): options.detached = true
            case .option("p", let value?):
                guard let port = UInt16(value), port != 0 else {
                    ctx.invalidArgument("nc", "invalid port: '\(value)'", usage: netcatUsage); return nil
                }
                options.localPort = port
            case .option("w", let value?):
                guard let seconds = Double(value), seconds > 0 else {
                    ctx.invalidArgument("nc", "invalid timeout: '\(value)'", usage: netcatUsage); return nil
                }
                options.timeout = seconds
            case .option("q", let value?):
                guard let seconds = Double(value), seconds >= 0 else {
                    ctx.invalidArgument("nc", "invalid quit delay: '\(value)'", usage: netcatUsage); return nil
                }
                options.quitAfterEOF = seconds
            case .option: break   // -n / -4 / -t: numeric IPv4 only, no telnet negotiation
            }
        }
        return options
    }

    private static func runNetcat(_ ctx: ProcessContext, _ argv: [String]) async {
        guard let options = parseNetcatOptions(ctx, argv) else { return }
        if options.listen {
            // `nc -l PORT`, `nc -l -p PORT`, or `nc -l ADDR PORT` (the address is
            // accepted and ignored: listeners here are always wildcard).
            var port = options.localPort
            if port == nil, let last = options.operands.last { port = UInt16(last) }
            guard let port, port != 0, options.operands.count <= 2 else {
                ctx.usage("nc", netcatUsage); return
            }
            if options.udp {
                await netcatListenUDP(ctx, options, port: port)
            } else {
                await netcatListenTCP(ctx, options, port: port)
            }
            return
        }
        guard options.operands.count == 2, let ports = parsePortRange(options.operands[1]),
              options.scan || ports.count == 1 else {
            ctx.usage("nc", netcatUsage); return
        }
        let host = options.operands[0]
        guard let address = await ctx.resolve(host) else {
            ctx.fail("nc: getaddrinfo for host \"\(host)\" port \(options.operands[1]): Name or service not known", code: 1)
            return
        }
        if options.scan {
            await netcatScan(ctx, options, host: host, address: address, ports: ports)
        } else if options.udp {
            await netcatUDPClient(ctx, options, address: address, port: ports.lowerBound)
        } else {
            await netcatTCPClient(ctx, options, host: host, address: address, port: ports.lowerBound)
        }
    }

    /// Why a relay stopped.
    enum RelayEnd: Equatable {
        case peerClosed
        case timedOut
        case inputFinished
        case interrupted
    }

    /// Relay between stdin/stdout and a connected TCP descriptor until the peer
    /// closes, a deadline passes, or the process is interrupted.
    static func relayTCP(_ ctx: ProcessContext,
                         _ fd: Int,
                         readStdin: Bool,
                         idleTimeout: Double?,
                         quitAfterEOF: Double?) async -> RelayEnd {
        var stdinOpen = readStdin
        var quitAt: Double? = readStdin ? nil : quitAfterEOF.map { ctx.logicalSeconds + $0 }
        while true {
            var requests = [PollRequest(fd: fd, interests: [.readable])]
            if stdinOpen { requests.append(PollRequest(fd: 0, interests: [.readable])) }
            var wait = idleTimeout
            if let quitAt {
                let left = quitAt - ctx.logicalSeconds
                guard left > 0 else { return .inputFinished }
                wait = min(wait ?? left, left)
            }
            let ready: [PollResult]
            do {
                ready = try await ctx.poll(requests, timeout: wait)
            } catch {
                return .interrupted
            }
            if ready.isEmpty {
                if let quitAt, ctx.logicalSeconds >= quitAt { return .inputFinished }
                return .timedOut
            }
            for result in ready {
                if result.fd == fd {
                    guard let bytes = try? await ctx.tcpRecv(fd), !bytes.isEmpty else { return .peerClosed }
                    ctx.write(1, bytes)
                } else if stdinOpen {
                    if let bytes = try? await ctx.read(0), !bytes.isEmpty {
                        _ = ctx.tcpSend(fd, bytes)
                    } else {
                        stdinOpen = false
                        if let quitAfterEOF { quitAt = ctx.logicalSeconds + quitAfterEOF }
                    }
                }
            }
        }
    }

    private static func netcatTCPClient(_ ctx: ProcessContext, _ options: NetcatOptions,
                                        host: String, address: IPv4Address, port: UInt16) async {
        guard let fd = ctx.tcpSocket() else { ctx.fail("nc: socket failed", code: 1); return }
        let outcome = (try? await ctx.tcpConnect(fd, to: address, port: port, timeout: options.timeout)) ?? .timedOut
        guard outcome == .connected else {
            ctx.tcpClose(fd)
            ctx.fail("nc: connect to \(host) port \(port) (tcp) failed: \(connectFailureText(outcome))", code: 1)
            return
        }
        if options.verbose { ctx.error("Connection to \(host) \(port) port [tcp/*] succeeded!") }
        _ = await relayTCP(ctx, fd, readStdin: !options.detached,
                           idleTimeout: options.timeout, quitAfterEOF: options.quitAfterEOF)
        ctx.tcpClose(fd)
        ctx.exit(0)
    }

    static func connectFailureText(_ outcome: ProcessContext.TCPConnectOutcome) -> String {
        switch outcome {
        case .connected: return "Success"
        case .refused: return "Connection refused"
        case .unreachable: return "No route to host"
        case .timedOut: return "Operation timed out"
        }
    }

    private static func netcatScan(_ ctx: ProcessContext, _ options: NetcatOptions,
                                   host: String, address: IPv4Address, ports: ClosedRange<UInt16>) async {
        var anyOpen = false
        for port in ports {
            if options.udp {
                // UDP has no handshake: a probe that draws no ICMP error is all
                // "open" can mean, and the socket layer does not surface that
                // error — so, like `nc -zu`, report the send.
                guard let fd = ctx.socket() else { continue }
                let sent = ctx.sendto(fd, [], to: address, port: port)
                ctx.close(fd)
                if sent {
                    anyOpen = true
                    if options.verbose { ctx.error("Connection to \(host) \(port) port [udp/*] succeeded!") }
                }
                continue
            }
            guard let fd = ctx.tcpSocket() else { continue }
            let outcome = (try? await ctx.tcpConnect(fd, to: address, port: port,
                                                     timeout: options.timeout ?? 2.0)) ?? .timedOut
            ctx.tcpClose(fd)
            if outcome == .connected {
                anyOpen = true
                if options.verbose { ctx.error("Connection to \(host) \(port) port [tcp/*] succeeded!") }
            } else if options.verbose {
                ctx.error("nc: connect to \(host) port \(port) (tcp) failed: \(connectFailureText(outcome))")
            }
        }
        ctx.exit(anyOpen ? 0 : 1)
    }

    private static func netcatListenTCP(_ ctx: ProcessContext, _ options: NetcatOptions, port: UInt16) async {
        guard let listener = ctx.tcpSocket() else { ctx.fail("nc: socket failed", code: 1); return }
        guard ctx.tcpListen(listener, port: port) else {
            ctx.close(listener)
            ctx.fail("nc: Address already in use", code: 1); return
        }
        if options.verbose { ctx.error("Listening on 0.0.0.0 \(port)") }
        repeat {
            let connection: Int
            if let timeout = options.timeout {
                guard (try? await ctx.waitReadable(listener, timeout: timeout)) == true else { break }
            }
            do {
                connection = try await ctx.tcpAccept(listener)
            } catch {
                break
            }
            if options.verbose, let peer = ctx.tcpPeer(connection) {
                ctx.error("Connection received on \(peer.address) \(peer.port)")
            }
            _ = await relayTCP(ctx, connection, readStdin: !options.detached,
                               idleTimeout: options.timeout, quitAfterEOF: options.quitAfterEOF)
            ctx.tcpClose(connection)
        } while options.keepListening
        ctx.close(listener)
        ctx.exit(0)
    }

    /// Relay between stdin/stdout and a UDP socket. `peer` is where stdin goes;
    /// a listener starts without one and adopts the first sender.
    private static func relayUDP(_ ctx: ProcessContext, _ fd: Int, _ options: NetcatOptions,
                                 peer initialPeer: (address: IPv4Address, port: UInt16)?,
                                 endAtInputEOF: Bool) async {
        var peer = initialPeer
        var stdinOpen = !options.detached
        var quitAt: Double?
        if !stdinOpen, endAtInputEOF { quitAt = ctx.logicalSeconds + (options.quitAfterEOF ?? options.timeout ?? 0) }
        while true {
            var requests = [PollRequest(fd: fd, interests: [.readable])]
            if stdinOpen { requests.append(PollRequest(fd: 0, interests: [.readable])) }
            var wait = options.timeout
            if let quitAt {
                let left = quitAt - ctx.logicalSeconds
                guard left > 0 else { return }
                wait = min(wait ?? left, left)
            }
            guard let ready = try? await ctx.poll(requests, timeout: wait), !ready.isEmpty else { return }
            for result in ready {
                if result.fd == fd {
                    while let datagram = try? ctx.recvfromNonBlocking(fd) {
                        if peer == nil { peer = (datagram.address, datagram.port) }
                        ctx.write(1, datagram.bytes)
                    }
                } else if stdinOpen {
                    if let bytes = try? await ctx.read(0), !bytes.isEmpty {
                        if let peer { _ = ctx.sendto(fd, bytes, to: peer.address, port: peer.port) }
                    } else {
                        stdinOpen = false
                        if endAtInputEOF {
                            // Linger only as long as -q/-w ask; otherwise stop now.
                            guard let linger = options.quitAfterEOF ?? options.timeout else { return }
                            quitAt = ctx.logicalSeconds + linger
                        }
                    }
                }
            }
        }
    }

    private static func netcatUDPClient(_ ctx: ProcessContext, _ options: NetcatOptions,
                                        address: IPv4Address, port: UInt16) async {
        guard let fd = ctx.socket() else { ctx.fail("nc: socket failed", code: 1); return }
        if let localPort = options.localPort, !ctx.bind(fd, address: nil, port: localPort) {
            ctx.close(fd)
            ctx.fail("nc: Address already in use", code: 1); return
        }
        await relayUDP(ctx, fd, options, peer: (address, port), endAtInputEOF: true)
        ctx.close(fd)
        ctx.exit(0)
    }

    private static func netcatListenUDP(_ ctx: ProcessContext, _ options: NetcatOptions, port: UInt16) async {
        guard let fd = ctx.socket() else { ctx.fail("nc: socket failed", code: 1); return }
        guard ctx.bind(fd, address: nil, port: port) else {
            ctx.close(fd)
            ctx.fail("nc: Address already in use", code: 1); return
        }
        if options.verbose { ctx.error("Bound on 0.0.0.0 \(port)") }
        await relayUDP(ctx, fd, options, peer: nil, endAtInputEOF: false)
        ctx.close(fd)
        ctx.exit(0)
    }

    // MARK: - telnet

    private static func runTelnet(_ ctx: ProcessContext, _ argv: [String]) async {
        let usage = networkSynopsis("telnet")
        guard let items = ctx.scanOptions(argv, command: "telnet", usage: usage, flags: "4") else { return }
        let operands = items.compactMap { item -> String? in
            if case .operand(let value) = item { return value }
            return nil
        }
        guard (1...2).contains(operands.count) else { ctx.usage("telnet", usage); return }
        var port: UInt16 = 23
        if operands.count == 2 {
            guard let parsed = UInt16(operands[1]), parsed != 0 else {
                ctx.invalidArgument("telnet", "bad port: '\(operands[1])'", usage: usage); return
            }
            port = parsed
        }
        let host = operands[0]
        guard let address = await ctx.resolve(host) else {
            ctx.fail("telnet: could not resolve \(host)/\(port): Name or service not known", code: 1); return
        }
        ctx.print("Trying \(address)...\n")
        guard let fd = ctx.tcpSocket() else { ctx.fail("telnet: socket failed", code: 1); return }
        let outcome = (try? await ctx.tcpConnect(fd, to: address, port: port, timeout: nil)) ?? .timedOut
        guard outcome == .connected else {
            ctx.tcpClose(fd)
            ctx.fail("telnet: Unable to connect to remote host: \(connectFailureText(outcome))", code: 1); return
        }
        ctx.print("Connected to \(host).\nEscape character is '^]'.\n")
        // Real telnet hangs up when its input ends. A one-second grace keeps the
        // usual `echo request | telnet host port` idiom from cutting off the reply.
        let end = await relayTCP(ctx, fd, readStdin: true, idleTimeout: nil, quitAfterEOF: 1.0)
        ctx.tcpClose(fd)
        if end == .peerClosed { ctx.print("Connection closed by foreign host.\n") }
        ctx.exit(end == .peerClosed ? 1 : 0)
    }
}
