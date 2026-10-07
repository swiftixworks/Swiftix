/// Name resolution for user programs: a `resolve` syscall that turns a hostname
/// into an `IPv4Address`. It layers three sources, in order:
///
///   1. an IPv4 literal (`"10.0.0.2"`) — returned as-is;
///   2. a static `/etc/hosts` table in the VFS (`"<ip> <name> [aliases…]"`),
///      with `localhost` answering `127.0.0.1` when the table does not list it;
///   3. DNS over UDP, using the `DNS` wire codec. The nameservers come from, in
///      order of precedence: the `NAMESERVER` environment variable (a
///      per-process override), the `nameserver` lines of `/etc/resolv.conf`, and
///      finally the stack's `NetworkResolverConfiguration` — the behavior when
///      no `resolv.conf` exists.
///
/// This is the client half of DNS-as-a-program: the matching server is the
/// `dnsd` command. The DNS path is `async` (it parks on a UDP receive). Like a
/// real stub resolver it retransmits the query when a reply does not arrive
/// within the per-attempt timeout — up to `dnsMaxAttempts` times — so a single
/// lost UDP datagram does not fail resolution; an unreachable nameserver still
/// gives up after the last attempt instead of hanging, and the next configured
/// nameserver (if any) is tried. A *definitive* reply (an address, or an
/// NXDOMAIN that matches our query id) resolves immediately and is never
/// retried. Standard-library concurrency only, resumed on the loop-bound
/// executor like every other syscall.
extension ProcessContext {

    /// Number of times the DNS query is sent before giving up, and how long each
    /// send waits for a reply. Mirror a stub resolver's `attempts`/`timeout`
    /// (glibc's `RES_DFLRETRY`), kept short for the logical-time simulation.
    private var dnsMaxAttempts: Int { 3 }
    private var dnsAttemptTimeout: Double { 1.0 }

    /// What one DNS exchange with one nameserver produced.
    enum DNSQueryOutcome: Equatable {
        /// A reply matching our transaction id (it may carry no answers).
        case response(DNS.Message)
        /// No matching reply after every retransmission.
        case timedOut
        /// No UDP socket could be opened.
        case socketUnavailable
    }

    /// Where a successful resolution came from — what `nslookup`/`ping -v`-style
    /// tools report alongside the address.
    enum ResolutionSource: Equatable {
        case literal
        case hostsFile
        case dns(server: IPv4Address)
    }

    /// Resolve `host` to an IPv4 address, or `nil` if it cannot be resolved.
    public func resolve(_ host: String) async -> IPv4Address? {
        await resolveWithSource(host)?.address
    }

    /// `resolve`, also reporting which source answered.
    func resolveWithSource(_ host: String) async -> (address: IPv4Address, source: ResolutionSource)? {
        if let literal = IPv4Address(host) { return (literal, .literal) }
        if let fromHosts = hostsFileLookup(host) { return (fromHosts, .hostsFile) }
        if host == "localhost" { return (IPv4Address(127, 0, 0, 1), .hostsFile) }
        for server in resolverNameServers() {
            switch await dnsQuery(host, server: server) {
            case .response(let message):
                // Definitive, even when empty (NXDOMAIN): do not ask another server.
                return message.answers.first.map { ($0.address, .dns(server: server)) }
            case .timedOut:
                continue
            case .socketUnavailable:
                return nil
            }
        }
        return nil
    }

    /// The nameservers a lookup consults, in order. `NAMESERVER` in the
    /// environment overrides everything; otherwise `/etc/resolv.conf` is used
    /// when it lists at least one server; otherwise the stack's configured
    /// resolver (the behavior before `resolv.conf` support).
    func resolverNameServers() -> [IPv4Address] {
        if let fromEnvironment = getenv("NAMESERVER").flatMap({ IPv4Address($0) }) {
            return [fromEnvironment]
        }
        let fromFile = resolvConfNameServers()
        if !fromFile.isEmpty { return fromFile }
        return kernel.netns.stack.snapshotConfiguration().resolver.nameServers
    }

    /// Send one A query for `name` to `server` and await the matching reply,
    /// retransmitting on loss. Does not consult `/etc/hosts` — this is the raw
    /// DNS exchange behind `resolve` and the `dig`/`nslookup`/`host` tools.
    func dnsQuery(_ name: String, server: IPv4Address, port: UInt16 = DNS.port) async -> DNSQueryOutcome {
        guard let fd = socket() else { return .socketUnavailable }
        defer { close(fd) }

        let id = UInt16(truncatingIfNeeded: globalPID)
        let query = DNS.encodeQuery(id: id, name: name)
        let attempts = max(1, dnsMaxAttempts)
        let timeout = dnsAttemptTimeout

        // One persistent receiver runs for the whole exchange; the retransmit
        // chain only re-sends the query. Keeping a single parked `recvfrom` (rather
        // than one per attempt) means a timed-out attempt never leaves a stale
        // reader behind to swallow a later attempt's reply. Exactly one of {a
        // matching reply, the final give-up} resumes the continuation, guarded by
        // `once`.
        return await withCheckedContinuation { (continuation: CheckedContinuation<DNSQueryOutcome, Never>) in
            let once = ResumeGuard()

            func listen() {
                recvfrom(fd) { bytes, _, _ in
                    guard !once.isClaimed else { return }
                    // Only a reply that matches our transaction id is authoritative
                    // (address, or NXDOMAIN → no answers). Anything else is a
                    // stray/late datagram: keep listening without consuming an
                    // attempt.
                    if let parsed = DNS.parseMessage(bytes), parsed.id == id {
                        guard once.claim() else { return }
                        continuation.resume(returning: .response(parsed))
                    } else {
                        listen()
                    }
                }
            }

            func attempt(_ n: Int) {
                _ = sendto(fd, query, to: server, port: port)
                sleep(timeout) {
                    guard !once.isClaimed else { return }
                    if n + 1 < attempts {
                        attempt(n + 1)                 // retransmit
                    } else if once.claim() {
                        continuation.resume(returning: .timedOut)   // out of attempts
                    }
                }
            }

            listen()
            attempt(0)
        }
    }

    /// Look `host` up in `/etc/hosts` (if present). Each line is
    /// `<ip> <name> [aliases…]`; blank lines and `#` comments are ignored.
    func hostsFileLookup(_ host: String) -> IPv4Address? {
        guard let fd = open("/etc/hosts") else { return nil }
        let data = read(fd, max: 1 << 16)
        close(fd)
        for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]   // strip comments
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
            guard fields.count >= 2, let ip = IPv4Address(fields[0]) else { continue }
            if fields.dropFirst().contains(host) { return ip }
        }
        return nil
    }

    /// The `nameserver` entries of `/etc/resolv.conf`, in file order. Missing
    /// file, unreadable file, or no valid entry all yield `[]`. `#` and `;` start
    /// comments; non-IPv4 servers (IPv6 is out of scope) are skipped.
    func resolvConfNameServers() -> [IPv4Address] {
        guard let fd = open("/etc/resolv.conf") else { return [] }
        let data = read(fd, max: 1 << 16)
        close(fd)
        return Self.parseResolvConf(String(decoding: data, as: UTF8.self))
    }

    static func parseResolvConf(_ text: String) -> [IPv4Address] {
        var servers: [IPv4Address] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.split(maxSplits: 1, omittingEmptySubsequences: false,
                                     whereSeparator: { $0 == "#" || $0 == ";" })[0]
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            guard fields.count >= 2, fields[0] == "nameserver",
                  let server = IPv4Address(String(fields[1])),
                  !servers.contains(server) else { continue }
            servers.append(server)
        }
        return servers
    }
}

/// A one-shot latch so the race between a matching reply and the final give-up
/// (after the last retransmit times out) resumes the continuation exactly once.
/// Single-threaded by contract (every callback runs on the loop), so a plain flag
/// suffices.
final class ResumeGuard {
    private var used = false
    /// Whether the one allowed resumption has been claimed. A peek that does not
    /// itself claim — used to short-circuit retransmit/relisten work once the
    /// resolution is already settled.
    var isClaimed: Bool { used }
    func claim() -> Bool {
        if used { return false }
        used = true
        return true
    }
}
