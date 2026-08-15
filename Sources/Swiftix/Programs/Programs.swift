/// Library-provided programs that run as processes on a `Kernel`. They have no
/// UI: results are reported through a caller-supplied sink, so a host app (or a
/// test) decides how to render them. Each returns a process body to hand to
/// `Kernel.spawn`.
public enum Programs: Sendable {

    public enum PingOutcome: Sendable {
        /// A matching echo reply arrived: `from` is the responder, `ttl` the TTL
        /// of the reply packet, `bytes` the size of the received ICMP message
        /// (echoed payload + 8-byte header, what Linux prints as "N bytes from …"),
        /// and `rttSeconds` the round-trip time.
        case reply(from: IPv4Address, sequence: UInt16, ttl: UInt8, bytes: Int, rttSeconds: Double)
        /// No reply arrived within the per-request timeout.
        case timeout(sequence: UInt16)
    }

    /// Aggregate results of a whole `ping` run, mirroring the block Linux `ping`
    /// prints after the last reply. Delivered once, through `ping`'s `onFinish`,
    /// right before the process exits.
    public struct PingStatistics: Sendable {
        /// Echo requests sent.
        public let transmitted: Int
        /// Replies received.
        public let received: Int
        /// Round-trip times of the received replies, in seconds, in arrival order.
        public let roundTripsSeconds: [Double]
        /// Logical time from the first request to the final outcome.
        public let elapsedSeconds: Double

        public init(transmitted: Int, received: Int,
                    roundTripsSeconds: [Double], elapsedSeconds: Double) {
            self.transmitted = transmitted
            self.received = received
            self.roundTripsSeconds = roundTripsSeconds
            self.elapsedSeconds = elapsedSeconds
        }

        /// Requests that never got a reply.
        public var lost: Int { max(0, transmitted - received) }

        /// Packet loss as a fraction in `0...1` (0 when nothing was transmitted).
        public var lossFraction: Double {
            transmitted == 0 ? 0 : Double(lost) / Double(transmitted)
        }

        public var minSeconds: Double? { roundTripsSeconds.min() }
        public var maxSeconds: Double? { roundTripsSeconds.max() }

        /// Mean round-trip time over the received replies.
        public var averageSeconds: Double? {
            guard !roundTripsSeconds.isEmpty else { return nil }
            return roundTripsSeconds.reduce(0, +) / Double(roundTripsSeconds.count)
        }

        /// Mean deviation of the RTTs — Linux's `mdev`, defined as
        /// `sqrt(avg(rtt²) − avg(rtt)²)`.
        public var deviationSeconds: Double? {
            guard let average = averageSeconds else { return nil }
            let meanSquare = roundTripsSeconds.reduce(0) { $0 + $1 * $1 } / Double(roundTripsSeconds.count)
            return max(0, meanSquare - average * average).squareRoot()
        }
    }

    /// A Linux-flavored `ping`: send `count` ICMP echo requests to `address`,
    /// pacing them `interval` seconds apart (send-to-send, like real `ping` —
    /// *not* back-to-back), each waiting up to `timeout` seconds for its reply.
    /// Every reply/timeout is reported through `report`; when the run ends, the
    /// aggregate `PingStatistics` is delivered through `onFinish` just before the
    /// process exits.
    ///
    /// Pacing is what makes `ping <host> 10` take ~10 s and stream one line per
    /// second, instead of firing all ten echoes as fast as replies return. The
    /// wait before the next request is `interval` minus the time this request
    /// already spent (its RTT, or the full timeout on a miss), so a slow reply or
    /// a timeout does not stack an extra idle second on top.
    public static func ping(to address: IPv4Address,
                     count: Int = 1,
                     interval: Double = 1.0,
                     timeout: Double = 1.0,
                     payloadSize: Int = 56,
                     onFinish: ((PingStatistics) -> Void)? = nil,
                     report: @escaping (PingOutcome) -> Void) -> (ProcessContext) -> Void {
        { ctx in
            // Identify echoes by the global pid so concurrent pings (even across
            // PID namespaces, where local pids repeat) don't collide on the
            // (identifier, sequence) key the stack uses to match replies.
            let identifier = UInt16(truncatingIfNeeded: ctx.globalPID)
            // Linux sends a fixed data payload (default 56 bytes) that the peer
            // echoes back; the reported packet size is that payload plus the
            // 8-byte ICMP header. A deterministic filler keeps wire bytes stable.
            let payload = [UInt8](repeating: 0, count: max(0, payloadSize))
            let replyBytes = payload.count + ICMPMessage.headerLength
            let startNanoseconds = ctx.monotonicNanoseconds

            // A ping process runs alone on the single executor, so these captured
            // accumulators need no lock — that is the concurrency contract, not a
            // race. They ride along the recursive `sendOne`/`finish` continuations.
            var received = 0
            var roundTrips: [Double] = []

            func finish() {
                let elapsed = Double(ctx.monotonicNanoseconds &- startNanoseconds) / 1_000_000_000
                onFinish?(PingStatistics(transmitted: count,
                                         received: received,
                                         roundTripsSeconds: roundTrips,
                                         elapsedSeconds: elapsed))
                ctx.exit()
            }

            func sendOne(_ sequence: UInt16) {
                ctx.icmpEcho(to: address, identifier: identifier, sequence: sequence,
                             payload: payload, timeout: timeout) { from, replyTTL, elapsed in
                    if let from {
                        received += 1
                        roundTrips.append(elapsed)
                        report(.reply(from: from, sequence: sequence, ttl: replyTTL,
                                      bytes: replyBytes, rttSeconds: elapsed))
                    } else {
                        report(.timeout(sequence: sequence))
                    }
                    guard Int(sequence) < count else { finish(); return }
                    // Pace to the next request: `elapsed` is this request's RTT (or
                    // the full timeout on a miss), so sleep only the remainder of
                    // the interval — matching real ping's send-to-send cadence.
                    let remaining = interval - elapsed
                    if remaining > 0 {
                        ctx.sleep(remaining) { sendOne(sequence &+ 1) }
                    } else {
                        sendOne(sequence &+ 1)
                    }
                }
            }

            guard count > 0 else { finish(); return }
            sendOne(1)
        }
    }

    /// Reusable TCP server scaffolding: listen on `port`, then loop accepting
    /// connections and running `handle` for each in its own child process (which
    /// inherits the accepted descriptor). The connection is closed automatically
    /// when `handle` returns. This is the building block user servers (echo, HTTP,
    /// …) sit on, so they only write the per-connection logic — never the accept
    /// loop or the fork/close bookkeeping.
    ///
    /// Runs until the process is killed. Call from an `async` `Command` body:
    /// `await Programs.serveTCP(ctx, port: 80) { c, conn in … }`.
    ///
    /// If the port is already taken by another listener, the passive open fails
    /// (EADDRINUSE): `serveTCP` writes a diagnostic to stderr and exits non-zero
    /// without entering the accept loop, so a second server on the same port does
    /// not silently displace the first. `onListening` fires exactly once, only
    /// after the socket is successfully listening — the place for a caller's
    /// "serving on <port>" banner so it never prints on a bind failure.
    public static func serveTCP(_ ctx: ProcessContext,
                                port: UInt16,
                                onListening: (() -> Void)? = nil,
                                handle: @escaping (_ ctx: ProcessContext, _ connection: Int) async -> Void) async {
        guard let listener = ctx.tcpSocket() else { ctx.exit(1); return }
        guard ctx.tcpListen(listener, port: port) else {
            ctx.write(2, Array("serveTCP: cannot listen on port \(port): address already in use\n".utf8))
            ctx.close(listener)
            ctx.exit(1)
            return
        }
        onListening?()
        while true {
            guard let connection = try? await ctx.tcpAccept(listener) else { break }
            ctx.spawn("conn", args: ["conn"]) { (child: ProcessContext) async in
                await handle(child, connection)
                child.tcpClose(connection)
                child.exit(0)
            }
            // Server drops its own handle; the child owns the connection now.
            ctx.close(connection)
        }
    }

    /// A minimal interactive shell, run as a process. It uses `tty` as stdin +
    /// stdout, and runs **each command as a real child process**, waiting for it
    /// before re-prompting.
    ///
    /// The shell contains *no* per-command logic: it tokenizes the line, resolves
    /// `argv[0]` in `commands`, spawns a child with the argument vector, wires the
    /// child's stdin/stdout/stderr to the terminal, and runs the resolved program.
    /// The command set is therefore open — a consumer can pass a registry extended
    /// with its own commands (`CommandRegistry.builtins` then `register(_:)`) and
    /// executable loaders, or a completely custom one. An unresolved name reports
    /// "command not found".
}
