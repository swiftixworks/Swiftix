/// Name resolution for user programs: a `resolve` syscall that turns a hostname
/// into an `IPv4Address`. It layers three sources, in order:
///
///   1. an IPv4 literal (`"10.0.0.2"`) — returned as-is;
///   2. a static `/etc/hosts` table in the VFS (`"<ip> <name> [aliases…]"`);
///   3. DNS over UDP — a query to the nameserver named by the `NAMESERVER`
///      environment variable, falling back to the stack's
///      `NetworkResolverConfiguration`, using the `DNS` wire codec.
///
/// This is the client half of DNS-as-a-program: the matching server is the
/// `dnsd` command. The DNS path is `async` (it parks on a UDP receive). Like a
/// real stub resolver it retransmits the query when a reply does not arrive
/// within the per-attempt timeout — up to `dnsMaxAttempts` times — so a single
/// lost UDP datagram does not fail resolution; an unreachable nameserver still
/// returns `nil` after the last attempt instead of hanging. A *definitive* reply
/// (an address, or an NXDOMAIN that matches our query id) resolves immediately
/// and is never retried. Standard-library concurrency only, resumed on the
/// loop-bound executor like every other syscall.
extension ProcessContext {

    /// Number of times the DNS query is sent before giving up, and how long each
    /// send waits for a reply. Mirror a stub resolver's `attempts`/`timeout`
    /// (glibc's `RES_DFLRETRY`), kept short for the logical-time simulation.
    private var dnsMaxAttempts: Int { 3 }
    private var dnsAttemptTimeout: Double { 1.0 }

    /// Resolve `host` to an IPv4 address, or `nil` if it cannot be resolved.
    public func resolve(_ host: String) async -> IPv4Address? {
        if let literal = IPv4Address(host) { return literal }
        if let fromHosts = hostsFileLookup(host) { return fromHosts }
        let environmentServer = getenv("NAMESERVER").flatMap { IPv4Address($0) }
        let configuredServer = kernel.netns.stack
            .snapshotConfiguration().resolver.nameServers.first
        guard let nameserver = environmentServer ?? configuredServer,
              let fd = socket() else { return nil }
        defer { close(fd) }

        let id = UInt16(truncatingIfNeeded: globalPID)
        let query = DNS.encodeQuery(id: id, name: host)
        let attempts = max(1, dnsMaxAttempts)
        let timeout = dnsAttemptTimeout

        // One persistent receiver runs for the whole resolution; the retransmit
        // chain only re-sends the query. Keeping a single parked `recvfrom` (rather
        // than one per attempt) means a timed-out attempt never leaves a stale
        // reader behind to swallow a later attempt's reply. Exactly one of {a
        // matching reply, the final give-up} resumes the continuation, guarded by
        // `once`.
        return await withCheckedContinuation { (continuation: CheckedContinuation<IPv4Address?, Never>) in
            let once = ResumeGuard()

            func listen() {
                recvfrom(fd) { bytes, _, _ in
                    guard !once.isClaimed else { return }
                    // Only a reply that matches our transaction id is authoritative
                    // (address, or NXDOMAIN → nil). Anything else is a stray/late
                    // datagram: keep listening without consuming an attempt.
                    if let parsed = DNS.parseResponse(bytes), parsed.id == id {
                        guard once.claim() else { return }
                        continuation.resume(returning: parsed.address)
                    } else {
                        listen()
                    }
                }
            }

            func attempt(_ n: Int) {
                _ = sendto(fd, query, to: nameserver, port: DNS.port)
                sleep(timeout) {
                    guard !once.isClaimed else { return }
                    if n + 1 < attempts {
                        attempt(n + 1)                 // retransmit
                    } else if once.claim() {
                        continuation.resume(returning: nil)   // out of attempts
                    }
                }
            }

            listen()
            attempt(0)
        }
    }

    /// Look `host` up in `/etc/hosts` (if present). Each line is
    /// `<ip> <name> [aliases…]`; blank lines and `#` comments are ignored.
    private func hostsFileLookup(_ host: String) -> IPv4Address? {
        guard let fd = open("/etc/hosts") else { return nil }
        let data = read(fd, max: 1 << 16)
        close(fd)
        for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let line = rawLine.split(separator: "#", maxSplits: 1)[0]   // strip comments
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
            guard fields.count >= 2, let ip = IPv4Address(fields[0]) else { continue }
            if fields.dropFirst().contains(host) { return ip }
        }
        return nil
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
