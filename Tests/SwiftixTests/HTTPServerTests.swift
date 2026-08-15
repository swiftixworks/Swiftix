import Testing
@testable import Swiftix

/// End-to-end: the built-in `httpd` (a user-space program on the `serveTCP`
/// scaffolding) serves files out of the VFS to a real TCP client across a
/// two-host link — an application protocol as an ordinary program.
@Suite("httpd over TCP")
struct HTTPServerTests {

    @Test func httpdServesFileAndReports404() async {
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

        // Seed the document root, then start httpd as a registered command.
        server.spawn("seed") { ctx in
            let fd = ctx.open("/index.html", create: true)!
            ctx.write(fd, Array("<h1>hello</h1>".utf8))
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()
        launch(CommandRegistry.builtins.resolve("httpd")!, on: server, args: ["httpd", "80"])
        loop.runUntilIdle()

        // A GET / (mapped to /index.html) and a GET /missing.
        let ok = fetch(client, to: ipB, path: "/")
        let missing = fetch(client, to: ipB, path: "/missing")

        await drive(loop, until: { ok.done && missing.done })

        #expect(contains(ok.data, Array("200 OK".utf8)))
        #expect(contains(ok.data, Array("<h1>hello</h1>".utf8)))
        #expect(contains(ok.data, Array("Content-Type: text/html".utf8)))   // MIME by extension
        #expect(contains(missing.data, Array("404 Not Found".utf8)))
    }

    /// HTTP/1.1 keep-alive: two requests pipelined on a single connection each
    /// get a response (the server loops until the client closes).
    @Test func httpdKeepAliveServesTwoRequestsOnOneConnection() async {
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

        server.spawn("seed") { ctx in
            let fd = ctx.open("/index.html", create: true)!
            ctx.write(fd, Array("<h1>hi</h1>".utf8))
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()
        launch(CommandRegistry.builtins.resolve("httpd")!, on: server, args: ["httpd", "80"])
        loop.runUntilIdle()

        let reply = Reply()
        client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { reply.done = true; return }
            try? await ctx.tcpConnect(fd, to: ipB, port: 80)
            // Two keep-alive requests back to back.
            ctx.tcpSend(fd, Array("GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
            while self.occurrences(reply.data, Array("200 OK".utf8)) < 2 {
                guard let chunk = try? await ctx.tcpRecv(fd), !chunk.isEmpty else { break }
                reply.data.append(contentsOf: chunk)
            }
            reply.done = true
            ctx.tcpClose(fd)
            ctx.exit(0)
        }

        await drive(loop, until: { reply.done })

        #expect(occurrences(reply.data, Array("200 OK".utf8)) == 2)
    }

    // MARK: - Helpers

    final class Reply: @unchecked Sendable { var data: [UInt8] = []; var done = false }

    /// Spawn a client that GETs `path` and reads the whole response to EOF.
    private func fetch(_ kernel: Kernel, to address: IPv4Address, path: String) -> Reply {
        let reply = Reply()
        kernel.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { reply.done = true; return }
            try? await ctx.tcpConnect(fd, to: address, port: 80)
            ctx.tcpSend(fd, Array("GET \(path) HTTP/1.0\r\n\r\n".utf8))
            while let chunk = try? await ctx.tcpRecv(fd), !chunk.isEmpty {
                reply.data.append(contentsOf: chunk)
            }
            reply.done = true
            ctx.tcpClose(fd)
            ctx.exit(0)
        }
        return reply
    }

    private func launch(_ command: Command, on kernel: Kernel, args: [String]) {
        switch command.body {
        case let .sync(run): kernel.spawn(command.name, args: args) { run($0, args) }
        case let .async(run): kernel.spawn(command.name, args: args) { await run($0, args) }
        }
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
        occurrences(haystack, needle) > 0
    }

    private func occurrences(_ haystack: [UInt8], _ needle: [UInt8]) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var count = 0
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            count += 1
        }
        return count
    }
}
