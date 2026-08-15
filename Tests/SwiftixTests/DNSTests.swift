import Testing
@testable import Swiftix

/// DNS as a program over the user-space stack: the `DNS` wire codec, the
/// `resolve` syscall (literal → /etc/hosts → DNS-over-UDP), and the `dnsd`
/// server. Wire-level tests are synchronous; the end-to-end tests run a resolver
/// client against a `dnsd` server across a two-host link.
@Suite("DNS resolver + dnsd")
struct DNSTests {

    // MARK: - Wire codec

    @Test func queryRoundTrips() {
        let bytes = DNS.encodeQuery(id: 0x1234, name: "example.com")
        let parsed = DNS.parseQuery(bytes)
        #expect(parsed?.id == 0x1234)
        #expect(parsed?.name == "example.com")
    }

    @Test func responseRoundTripsAnAddress() {
        let bytes = DNS.encodeResponse(id: 0x2222, name: "host.local", address: IPv4Address(10, 0, 0, 5))
        let parsed = DNS.parseResponse(bytes)
        #expect(parsed?.id == 0x2222)
        #expect(parsed?.address == IPv4Address(10, 0, 0, 5))
    }

    @Test func notFoundHasNoAddress() {
        let parsed = DNS.parseResponse(DNS.encodeNotFound(id: 7, name: "nope.local"))
        #expect(parsed?.id == 7)
        #expect(parsed?.address == nil)
    }

    // MARK: - Local /etc/hosts

    @Test func nslookupResolvesFromHostsFile() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("seed") { ctx in
            let fd = ctx.open("/etc/hosts", create: true)!
            ctx.write(fd, Array("10.0.0.9 example\n".utf8))
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        let captured = Sink()
        let pty = pty(into: captured)
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("nslookup example\n".utf8))
        await drive(loop, until: { contains(captured.out, Array("10.0.0.9".utf8)) })

        #expect(contains(captured.out, Array("10.0.0.9".utf8)))
    }

    // MARK: - DNS over UDP (two hosts)

    @Test func resolvesOverUDPViaDnsd() async {
        let (loop, client, server, serverIP) = twoHosts()
        client.netns.stack.configure(.setResolver(
            NetworkResolverConfiguration(nameServers: [serverIP])))
        // Server's zone: webhost -> 10.0.0.42.
        server.spawn("seed") { ctx in
            let fd = ctx.open("/etc/hosts", create: true)!
            ctx.write(fd, Array("10.0.0.42 webhost\n".utf8))
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()
        server.spawn("dnsd", args: ["dnsd"]) { ctx in
            await runCommand("dnsd", on: ctx, args: ["dnsd"])
        }
        loop.runUntilIdle()

        let captured = Sink()
        let pty = pty(into: captured)
        client.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("nslookup webhost\n".utf8))
        await drive(loop, until: { contains(captured.out, Array("10.0.0.42".utf8)) })

        #expect(contains(captured.out, Array("10.0.0.42".utf8)))
    }

    // MARK: - Retry on a lost query

    /// The resolver retransmits when a query goes unanswered: a nameserver that
    /// drops the first query but answers the retransmit still resolves (a single
    /// lost UDP datagram no longer fails resolution).
    @Test func resolveRetriesAfterLosingFirstQuery() async {
        let (loop, client, server, serverIP) = twoHosts()
        // A flaky nameserver: ignore the first query, answer every one after.
        server.spawn("flaky-dns") { ctx in
            guard let fd = ctx.socket() else { return }
            _ = ctx.bind(fd, address: serverIP, port: DNS.port)
            var seen = 0
            while let query = try? await ctx.recvfrom(fd) {
                seen += 1
                if seen == 1 { continue }   // drop the first → force a retransmit
                guard let (id, name) = DNS.parseQuery(query.bytes) else { continue }
                _ = ctx.sendto(fd,
                               DNS.encodeResponse(id: id, name: name, address: IPv4Address(10, 0, 0, 77)),
                               to: query.address, port: query.port)
            }
        }
        loop.runUntilIdle()

        let box = Outcome()
        client.spawn("resolver") { ctx in
            ctx.setenv("NAMESERVER", "\(serverIP)")
            box.address = await ctx.resolve("flaky")
            box.done = true
        }
        await drive(loop, until: { box.done })

        #expect(box.address == IPv4Address(10, 0, 0, 77))
    }

    /// With a nameserver that never answers, the resolver retransmits up to its
    /// attempt limit and then returns `nil` (instead of hanging or failing on the
    /// first timeout).
    @Test func resolveReturnsNilAfterAllAttemptsTimeOut() async {
        // Server exists (so the query is delivered) but runs no `dnsd`, so nothing
        // ever replies.
        let (loop, client, _, serverIP) = twoHosts()

        let box = Outcome()
        box.address = IPv4Address(9, 9, 9, 9)   // sentinel so `nil` is meaningful
        client.spawn("resolver") { ctx in
            ctx.setenv("NAMESERVER", "\(serverIP)")
            box.address = await ctx.resolve("ghost")
            box.done = true
        }
        await drive(loop, until: { box.done })

        #expect(box.address == nil)
    }

    // MARK: - curl by hostname (via /etc/hosts)

    @Test func curlResolvesHostnameThenFetches() async {
        let (loop, client, server, serverIP) = twoHosts()
        server.spawn("seed") { ctx in
            let fd = ctx.open("/index.html", create: true)!
            ctx.write(fd, Array("<h1>named</h1>".utf8))
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()
        server.spawn("httpd", args: ["httpd", "80"]) { ctx in
            await Programs.serveTCP(ctx, port: 80) { conn, fd in
                var buffer: [UInt8] = []
                while let chunk = try? await conn.tcpRecv(fd), !chunk.isEmpty {
                    buffer.append(contentsOf: chunk)
                    if buffer.contains(0x0A) { break }
                }
                let body = Array("<h1>named</h1>".utf8)
                _ = conn.tcpSend(fd, Array("HTTP/1.0 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body)
            }
        }
        loop.runUntilIdle()

        // Client maps `site` -> the server's IP via /etc/hosts.
        client.spawn("seed") { ctx in
            let fd = ctx.open("/etc/hosts", create: true)!
            ctx.write(fd, Array("\(serverIP) site\n".utf8))
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        let captured = Sink()
        let pty = pty(into: captured)
        client.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("curl http://site/\n".utf8))
        await drive(loop, until: { contains(captured.out, Array("<h1>named</h1>".utf8)) })

        #expect(contains(captured.out, Array("<h1>named</h1>".utf8)))
    }

    // MARK: - Helpers

    /// Single-threaded (loop-driven) capture of an async `resolve` result.
    final class Outcome: @unchecked Sendable { var address: IPv4Address?; var done = false }

    final class Sink: @unchecked Sendable { var out: [UInt8] = [] }

    private func pty(into sink: Sink) -> PseudoTerminal {
        let pty = PseudoTerminal()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            sink.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        return pty
    }

    /// Build a client + server on one loop, wired with static neighbors.
    private func twoHosts() -> (loop: EventLoop, client: Kernel, server: Kernel, serverIP: IPv4Address) {
        let loop = EventLoop()
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let client = Kernel(loop: loop)
        let server = Kernel(loop: loop)
        let ifA = client.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = server.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(client.netns.stack, ifA, server.netns.stack, ifB, on: loop, latency: 0.005)
        client.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        server.netns.stack.configuredNeighbor(ip: ipA, mac: macA)
        return (loop, client, server, ipB)
    }

    /// Run a registered built-in command's body on `ctx` (async flavor).
    private func runCommand(_ name: String, on ctx: ProcessContext, args: [String]) async {
        let command = CommandRegistry.builtins.resolve(name)!
        guard case let .async(body) = command.body else { return }
        await body(ctx, args)
    }

    private func drive(_ loop: EventLoop, until done: @Sendable () -> Bool, max: Int = 200_000) async {
        var pumps = 0
        while !done() && pumps < max {
            loop.advance(by: 0)
            loop.runNext()
            await Task.yield()
            pumps += 1
        }
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
