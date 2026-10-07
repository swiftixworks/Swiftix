import Testing
@testable import Swiftix

/// `/etc/resolv.conf` support in the resolver, and the lookup tools built on
/// the raw DNS exchange: `dig`, `nslookup`, `host`.
@Suite("resolv.conf and DNS lookup tools")
struct ResolverConfigurationTests {

    /// A host running `dnsd` on loopback whose zone (its `/etc/hosts`) knows
    /// `web` and `db`.
    private func hostWithDNS() -> NetworkShell {
        let sh = NetworkShell()
        sh.write("/etc/hosts", "10.1.2.3 web www\n10.1.2.4 db\n")
        sh.run("dnsd &")
        return sh
    }

    private func resolve(_ name: String, on sh: NetworkShell, environment: [String: String] = [:]) -> IPv4Address? {
        final class Box { var address: IPv4Address?; var done = false }
        let box = Box()
        sh.kernel.spawn("resolver") { (ctx: ProcessContext) async in
            for (key, value) in environment { ctx.setenv(key, value) }
            box.address = await ctx.resolve(name)
            box.done = true
            ctx.exit(0)
        }
        sh.loop.runUntilIdle()
        sh.loop.advance(by: 10)
        sh.loop.runUntilIdle()
        #expect(box.done)
        return box.address
    }

    // MARK: - resolv.conf

    @Test func parsesNameserverLines() {
        let text = """
            # comment
            ; another
            search example.test
            nameserver 10.0.0.53   # trailing
            nameserver 10.0.0.53
            nameserver not-an-address
            nameserver fe80::1
            options ndots:1
            nameserver\t10.0.0.54
            """
        #expect(ProcessContext.parseResolvConf(text) == [IPv4Address(10, 0, 0, 53), IPv4Address(10, 0, 0, 54)])
        #expect(ProcessContext.parseResolvConf("") == [])
    }

    /// A client whose only way to learn `web` is the DNS server on the peer
    /// (10.0.0.2): the zone lives in the *peer's* `/etc/hosts`.
    private func clientWithRemoteDNS() -> NetworkShell {
        let sh = NetworkShell(ethernet: true)
        let peer = sh.attachPeer()
        sh.write("/etc/hosts", "10.1.2.3 web\n", on: peer)
        sh.launch(["dnsd"], on: peer)
        return sh
    }

    @Test func resolvConfSuppliesTheNameserver() {
        let sh = clientWithRemoteDNS()
        #expect(resolve("web", on: sh) == nil)                 // nothing configured yet
        sh.write("/etc/resolv.conf", "nameserver 10.0.0.2\n")
        #expect(resolve("web", on: sh) == IPv4Address(10, 1, 2, 3))
        #expect(resolve("absent", on: sh) == nil)              // NXDOMAIN is definitive
    }

    @Test func withoutResolvConfTheStackResolverIsStillUsed() {
        let sh = clientWithRemoteDNS()
        sh.kernel.netns.stack.configure(.setResolver(
            NetworkResolverConfiguration(nameServers: [IPv4Address(10, 0, 0, 2)])))
        #expect(resolve("web", on: sh) == IPv4Address(10, 1, 2, 3))
    }

    @Test func resolvConfTakesPrecedenceOverTheStackResolver() {
        let sh = clientWithRemoteDNS()
        // The stack resolver points at a host that does not exist.
        sh.kernel.netns.stack.configure(.setResolver(
            NetworkResolverConfiguration(nameServers: [IPv4Address(10, 0, 0, 99)])))
        #expect(resolve("web", on: sh) == nil)
        sh.write("/etc/resolv.conf", "nameserver 10.0.0.2\n")
        #expect(resolve("web", on: sh) == IPv4Address(10, 1, 2, 3))
    }

    @Test func resolvConfWithoutServersFallsBackToTheStackResolver() {
        let sh = clientWithRemoteDNS()
        sh.kernel.netns.stack.configure(.setResolver(
            NetworkResolverConfiguration(nameServers: [IPv4Address(10, 0, 0, 2)])))
        sh.write("/etc/resolv.conf", "# no servers here\nsearch example.test\n")
        #expect(resolve("web", on: sh) == IPv4Address(10, 1, 2, 3))
    }

    @Test func environmentOverridesResolvConf() {
        let sh = clientWithRemoteDNS()
        sh.write("/etc/resolv.conf", "nameserver 10.0.0.99\n")
        #expect(resolve("web", on: sh) == nil)
        #expect(resolve("web", on: sh, environment: ["NAMESERVER": "10.0.0.2"]) == IPv4Address(10, 1, 2, 3))
    }

    /// A nameserver that never answers costs its retries, then the next listed
    /// server is asked.
    @Test func resolveFallsThroughToTheNextNameserver() {
        let sh = clientWithRemoteDNS()
        sh.write("/etc/resolv.conf", "nameserver 10.0.0.99\nnameserver 10.0.0.2\n")
        #expect(resolve("web", on: sh) == IPv4Address(10, 1, 2, 3))
    }

    @Test func toolsResolveThroughResolvConf() {
        let sh = clientWithRemoteDNS()
        sh.write("/etc/resolv.conf", "nameserver 10.0.0.2\n")
        let lookup = sh.run("nslookup web")
        #expect(lookup.contains("Server:\t\t10.0.0.2\nAddress:\t10.0.0.2#53\n\nName:\tweb\nAddress: 10.1.2.3\n"))
        #expect(sh.run("host web").contains("web has address 10.1.2.3"))
        #expect(sh.run("dig +short web").contains("\n10.1.2.3\n"))
        let missing = sh.run("nslookup absent; echo rc=$?")
        #expect(missing.contains("Server:\t\t10.0.0.2"))
        #expect(missing.contains("** server can't find absent: NXDOMAIN"))
        #expect(missing.contains("rc=1"))
    }

    @Test func localhostResolvesWithoutAHostsFile() {
        let sh = NetworkShell()
        #expect(resolve("localhost", on: sh) == IPv4Address(127, 0, 0, 1))
        #expect(resolve("nosuch.invalid", on: sh) == nil)
    }

    @Test func hostsFileCommentLinesAreIgnored() {
        let sh = NetworkShell()
        sh.write("/etc/hosts", "#\n# 10.9.9.9 ghost\n\n10.1.2.3 web  # inline\n")
        #expect(resolve("web", on: sh) == IPv4Address(10, 1, 2, 3))
        #expect(resolve("ghost", on: sh) == nil)
    }

    // MARK: - DNS message parsing

    @Test func parseMessageReadsAnswersAndStatus() {
        let ok = DNS.parseMessage(DNS.encodeResponse(id: 9, name: "web.test", address: IPv4Address(10, 1, 2, 3)))
        #expect(ok?.id == 9)
        #expect(ok?.responseCode == 0)
        #expect(ok?.questionCount == 1)
        #expect(ok?.answers == [DNS.Message.Answer(name: "web.test", ttl: 60, address: IPv4Address(10, 1, 2, 3))])
        let missing = DNS.parseMessage(DNS.encodeNotFound(id: 9, name: "nope.test"))
        #expect(missing?.responseCode == 3)
        #expect(missing?.answers.isEmpty == true)
        #expect(DNS.parseMessage([0, 1, 2]) == nil)
    }

    // MARK: - dig

    @Test func digPrintsAnAnswerSection() {
        let sh = hostWithDNS()
        let out = sh.run("dig @127.0.0.1 web; echo rc=$?")
        #expect(out.contains(";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: "))
        #expect(out.contains(";; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0"))
        #expect(out.contains(";; QUESTION SECTION:\n;web.\t\t\tIN\tA\n"))
        #expect(out.contains(";; ANSWER SECTION:\nweb.\t\t60\tIN\tA\t10.1.2.3\n"))
        #expect(out.contains(";; SERVER: 127.0.0.1#53(127.0.0.1) (UDP)"))
        #expect(out.contains("rc=0"))
    }

    @Test func digShortAndExplicitType() {
        let sh = hostWithDNS()
        for line in ["dig +short @127.0.0.1 web", "dig @127.0.0.1 web A +short", "dig -t A @localhost db +short"] {
            let out = sh.run(line)
            #expect(out.contains(line.contains("db") ? "\n10.1.2.4\n" : "\n10.1.2.3\n"), "\(line): \(out)")
            #expect(!out.contains("ANSWER SECTION"), "\(line): \(out)")
        }
    }

    @Test func digReportsNXDOMAINAndStillSucceeds() {
        let sh = hostWithDNS()
        let out = sh.run("dig @127.0.0.1 nope; echo rc=$?")
        #expect(out.contains("status: NXDOMAIN"))
        #expect(out.contains("ANSWER: 0"))
        #expect(!out.contains("ANSWER SECTION"))
        #expect(out.contains("rc=0"))
    }

    @Test func digFailureModes() {
        let sh = hostWithDNS()
        let none = sh.run("dig web; echo rc=$?")
        #expect(none.contains("dig: no nameserver configured"))
        #expect(none.contains("rc=10"))

        let unsupported = sh.run("dig @127.0.0.1 web MX; echo rc=$?")
        #expect(unsupported.contains("dig: query type MX is not supported"))
        #expect(unsupported.contains("rc=1"))

        var silent = sh.run("dig @127.0.0.77 web; echo rc=$?")
        silent += sh.advance(5)
        #expect(silent.contains(";; no servers could be reached"))
        #expect(silent.contains("rc=9"))
    }

    // MARK: - nslookup / host

    @Test func nslookupWithAndWithoutServer() {
        let sh = hostWithDNS()
        let direct = sh.run("nslookup db 127.0.0.1; echo rc=$?")
        #expect(direct.contains("Server:\t\t127.0.0.1\nAddress:\t127.0.0.1#53\n\nName:\tdb\nAddress: 10.1.2.4\n"))
        #expect(direct.contains("rc=0"))

        let local = sh.run("nslookup web")          // answered by /etc/hosts
        #expect(local.contains("Name:\tweb\nAddress: 10.1.2.3\n"))

        let missing = sh.run("nslookup nope 127.0.0.1; echo rc=$?")
        #expect(missing.contains("** server can't find nope: NXDOMAIN"))
        #expect(missing.contains("rc=1"))
    }

    @Test func hostWithAndWithoutServer() {
        let sh = hostWithDNS()
        #expect(sh.run("host web").contains("web has address 10.1.2.3"))
        let direct = sh.run("host www 127.0.0.1")
        #expect(direct.contains("Using domain server:\nName: 127.0.0.1\nAddress: 127.0.0.1#53"))
        #expect(direct.contains("www has address 10.1.2.3"))
        let missing = sh.run("host nope 127.0.0.1; echo rc=$?")
        #expect(missing.contains("Host nope not found: 3(NXDOMAIN)"))
        #expect(missing.contains("rc=1"))
        #expect(sh.run("host; echo rc=$?").contains("rc=2"))
    }
}
