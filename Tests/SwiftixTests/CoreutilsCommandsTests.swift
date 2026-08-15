import Testing
@testable import Swiftix

/// The extended built-in command set: text filters, more filesystem tools,
/// process utilities, and network diagnostics/clients. These drive the real
/// shell over a pseudo-terminal (so pipelines and redirection are exercised the
/// same way a user would), then assert on what the terminal emitted.
@Suite("Coreutils + network commands")
struct CoreutilsCommandsTests {

    // MARK: - help grouping

    /// `help` now prints category sections, not one flat list. The built-in set
    /// spans several categories, so their headers must appear.
    @Test func helpIsGroupedByCategory() {
        let out = runShell(["help"])
        #expect(contains(out, Array("filesystem:".utf8)))
        #expect(contains(out, Array("text:".utf8)))
        #expect(contains(out, Array("network:".utf8)))
        #expect(contains(out, Array("process:".utf8)))
        #expect(contains(out, Array("grep".utf8)))   // a newly added command is listed
    }

    // MARK: - text filters

    @Test func grepSelectsMatchingLines() {
        let out = runShell(["grep ban /words"], seed: seedWords)
        #expect(contains(out, Array("banana".utf8)))
        #expect(!contains(out, Array("apple".utf8)))
    }

    @Test func grepInvertAndIgnoreCase() {
        let out = runShell(["grep -v a /words"], seed: seedWords)
        // Only "cherry" has no 'a'.
        #expect(contains(out, Array("cherry".utf8)))
        #expect(!contains(out, Array("banana".utf8)))
    }

    @Test func headTakesFirstLines() {
        let out = runShell(["head -n 2 /nums"], seed: seedNums)
        #expect(contains(out, Array("1\n2".utf8)))
        #expect(!contains(out, Array("3".utf8)))
    }

    @Test func tailTakesLastLines() {
        let out = runShell(["tail -n 2 /nums"], seed: seedNums)
        #expect(contains(out, Array("4\n5".utf8)))
        // "3" appears in neither the echoed command nor the two-line output.
        #expect(!contains(out, Array("3".utf8)))
    }

    @Test func wcCountsLinesWordsBytes() {
        // /nums is "1\n2\n3\n4\n5\n" = 5 lines, 5 words, 10 bytes.
        let out = runShell(["wc /nums"], seed: seedNums)
        #expect(contains(out, Array("5".utf8)))
        #expect(contains(out, Array("10 /nums".utf8)))
    }

    @Test func sortThenUniqThroughPipe() {
        let out = runShell(["sort /dupes | uniq"], seed: { ctx in
            let fd = ctx.open("/dupes", create: true)!
            ctx.write(fd, Array("b\na\nb\na\n".utf8))
            ctx.close(fd)
        })
        #expect(contains(out, Array("a\nb".utf8)))
    }

    @Test func seqGeneratesRange() {
        let out = runShell(["seq 3"])
        #expect(contains(out, Array("1\n2\n3".utf8)))
    }

    // MARK: - filesystem

    @Test func cpCopiesFileContents() {
        let out = runShell(["cp /src /dst", "cat /dst"], seed: { ctx in
            let fd = ctx.open("/src", create: true)!
            ctx.write(fd, Array("copied body\n".utf8))
            ctx.close(fd)
        })
        #expect(contains(out, Array("copied body".utf8)))
    }

    @Test func findWalksTree() {
        let out = runShell(["mkdir /d", "touch /d/f", "find /d"])
        #expect(contains(out, Array("/d/f".utf8)))
    }

    // MARK: - process

    /// `top -n 1` emits a single plain frame: the summary header (logical uptime +
    /// task-state breakdown), the column header, and the process table — which
    /// includes the shell and `top` itself.
    @Test func topBatchShowsSummaryAndProcessTable() {
        let out = runShell(["top -n 1"])
        #expect(contains(out, Array("top - up".utf8)))
        #expect(contains(out, Array("Tasks:".utf8)))
        #expect(contains(out, Array("TICKS".utf8)))   // CPU-activity proxy column
        #expect(contains(out, Array("FDS".utf8)))     // open-descriptor column
        #expect(contains(out, Array("sh".utf8)))      // the shell process
        #expect(contains(out, Array("top".utf8)))     // top itself
    }

    /// Interactive `top` must PARK on input, never self-schedule a refresh timer.
    /// `runShell` drives the loop with `runUntilIdle` after each line — exactly the
    /// app's interactive fast path. A timer-driven top would spin `runUntilIdle`
    /// forever (jumping from one refresh deadline to the next) and hang; parking on
    /// input keeps the queue empty between keys, so this returns. `q` then quits.
    @Test func topInteractiveParksAndQuitsUnderRunUntilIdle() {
        let out = runShell(["top", "q"])
        #expect(contains(out, Array("Tasks:".utf8)))
        #expect(contains(out, Array("[auto-refresh".utf8)))
    }

    @Test func psListsTheShell() {
        let out = runShell(["ps"])
        #expect(contains(out, Array("PID".utf8)))   // header from /proc/processes
        #expect(contains(out, Array("sh".utf8)))    // the shell process itself
    }

    // MARK: - network diagnostics

    @Test func ifconfigShowsConfiguredInterface() {
        let out = runShell(["ifconfig"], configureInterface: true)
        #expect(contains(out, Array("eth0".utf8)))
        #expect(contains(out, Array("10.0.0.1".utf8)))
    }

    @Test func networkCommandsConfigureProcfsViews() {
        let out = runShell([
            "ifconfig add 10.0.5.7/24 02:00:00:00:05:07",
            "route add default via 10.0.5.1 dev eth0",
            "arp add 10.0.5.1 02:00:00:00:05:01",
            "ifconfig",
            "route",
            "arp",
        ])
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("eth0 10.0.5.7 02:00:00:00:05:07"))
        #expect(text.contains("10.0.5.0/24 * eth0"))
        #expect(text.contains("0.0.0.0/0 10.0.5.1 eth0"))
        #expect(text.contains("10.0.5.1 02:00:00:00:05:01"))
    }

    @Test func ipCommandConfiguresNetworkState() {
        let out = runShell([
            "ip addr add 192.168.9.2/24 lladdr 02:00:00:00:09:02",
            "ip route add default via 192.168.9.1 dev eth0",
            "ip neigh add 192.168.9.1 lladdr 02:00:00:00:09:01",
            "ip forwarding on",
            "ip forwarding",
            "ifconfig",
            "route",
            "arp",
        ])
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("forwarding: on"))
        #expect(text.contains("eth0 192.168.9.2 02:00:00:00:09:02"))
        #expect(text.contains("192.168.9.0/24 * eth0"))
        #expect(text.contains("0.0.0.0/0 192.168.9.1 eth0"))
        #expect(text.contains("192.168.9.1 02:00:00:00:09:01"))
    }

    // MARK: - network client (curl over TCP)

    /// `curl` is the client counterpart to `httpd`: it connects over a real
    /// two-host link, sends a GET, and prints the response body (headers stripped
    /// by default).
    @Test func curlFetchesBodyFromHttpd() async {
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
            ctx.write(fd, Array("<h1>hello</h1>".utf8))
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
                let body = Array("<h1>hello</h1>".utf8)
                let head = "HTTP/1.0 200 OK\r\nContent-Length: \(body.count)\r\n\r\n"
                _ = conn.tcpSend(fd, Array(head.utf8) + body)
            }
        }
        loop.runUntilIdle()

        let pty = PseudoTerminal()
        let captured = NetCapture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        client.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("curl http://10.0.0.2/\n".utf8))

        await drive(loop, until: { contains(captured.out, Array("<h1>hello</h1>".utf8)) })

        #expect(contains(captured.out, Array("<h1>hello</h1>".utf8)))
        // Body only: the status line header must not be printed.
        #expect(!contains(captured.out, Array("200 OK".utf8)))
    }

    // MARK: - du / df / free

    @Test func duSummarizesTreeBytes() {
        let out = runShell(["du -sb /data"], seed: { ctx in
            _ = ctx.mkdir("/data")
            let a = ctx.open("/data/a", create: true)!; ctx.write(a, Array("hello".utf8)); ctx.close(a)  // 5
            let b = ctx.open("/data/b", create: true)!; ctx.write(b, Array("hi\n".utf8)); ctx.close(b)   // 3
        })
        #expect(contains(out, Array("8\t/data".utf8)))
    }

    @Test func duOnAFilePrintsItsSize() {
        let out = runShell(["du -b /nums"], seed: seedNums)   // /nums is 10 bytes
        #expect(contains(out, Array("10\t/nums".utf8)))
    }

    @Test func dfReportsTmpfsMountedOnRoot() {
        let out = runShell(["df"])
        #expect(contains(out, Array("tmpfs".utf8)))
        #expect(contains(out, Array("Mounted on".utf8)))
    }

    @Test func freeReportsMemoryLine() {
        let out = runShell(["free"])
        #expect(contains(out, Array("Mem:".utf8)))
        #expect(contains(out, Array("total".utf8)))
    }

    // MARK: - diff

    @Test func diffReportsChangedLine() {
        let out = runShell(["diff /f1 /f2"], seed: { ctx in
            let f1 = ctx.open("/f1", create: true)!; ctx.write(f1, Array("a\nb\nc\n".utf8)); ctx.close(f1)
            let f2 = ctx.open("/f2", create: true)!; ctx.write(f2, Array("a\nx\nc\n".utf8)); ctx.close(f2)
        })
        #expect(contains(out, Array("2c2".utf8)))
        #expect(contains(out, Array("< b".utf8)))
        #expect(contains(out, Array("> x".utf8)))
    }

    @Test func diffReportsDeletionAndAddition() {
        let deletion = runShell(["diff /a /b"], seed: { ctx in
            let a = ctx.open("/a", create: true)!; ctx.write(a, Array("a\nb\nc\n".utf8)); ctx.close(a)
            let b = ctx.open("/b", create: true)!; ctx.write(b, Array("a\nc\n".utf8)); ctx.close(b)
        })
        #expect(contains(deletion, Array("2d1".utf8)))     // line 2 (b) deleted

        let addition = runShell(["diff /a /b"], seed: { ctx in
            let a = ctx.open("/a", create: true)!; ctx.write(a, Array("a\nc\n".utf8)); ctx.close(a)
            let b = ctx.open("/b", create: true)!; ctx.write(b, Array("a\nb\nc\n".utf8)); ctx.close(b)
        })
        #expect(contains(addition, Array("1a2".utf8)))     // add after line 1
    }

    // MARK: - wget (reuses the HTTP client over a real link)

    @Test func wgetDownloadsBodyToDefaultFile() async {
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

        server.spawn("httpd", args: ["httpd", "80"]) { ctx in
            await Programs.serveTCP(ctx, port: 80) { conn, fd in
                while let chunk = try? await conn.tcpRecv(fd), !chunk.isEmpty {
                    if chunk.contains(0x0A) { break }
                }
                let body = Array("<h1>hello</h1>".utf8)
                let head = "HTTP/1.0 200 OK\r\nContent-Length: \(body.count)\r\n\r\n"
                _ = conn.tcpSend(fd, Array(head.utf8) + body)
            }
        }
        loop.runUntilIdle()

        let pty = PseudoTerminal()
        let captured = NetCapture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        client.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("wget http://10.0.0.2/\n".utf8))
        await drive(loop, until: { contains(captured.out, Array("saved".utf8)) })

        // The default output file is index.html; read it back on the client.
        final class Box: @unchecked Sendable { var text = "" }
        let box = Box()
        client.spawn("read") { ctx in
            if let fd = ctx.open("/index.html") {
                box.text = String(decoding: ctx.read(fd, max: 65535), as: UTF8.self)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()
        #expect(box.text == "<h1>hello</h1>")
    }

    @Test func wgetWithoutArgumentsReportsUsage() {
        let out = runShell(["wget"])
        #expect(contains(out, Array("usage".utf8)))
    }

    // MARK: - Helpers

    final class Capture { var out: [UInt8] = [] }
    final class NetCapture: @unchecked Sendable { var out: [UInt8] = [] }

    private func seedWords(_ ctx: ProcessContext) {
        let fd = ctx.open("/words", create: true)!
        ctx.write(fd, Array("apple\nbanana\ncherry\n".utf8))
        ctx.close(fd)
    }

    private func seedNums(_ ctx: ProcessContext) {
        let fd = ctx.open("/nums", create: true)!
        ctx.write(fd, Array("1\n2\n3\n4\n5\n".utf8))
        ctx.close(fd)
    }

    /// Build a kernel + shell on a pty, optionally seed the VFS and configure an
    /// interface, write each command line, and return everything the pty emitted.
    /// Synchronous commands complete within `runUntilIdle`.
    private func runShell(_ lines: [String],
                          configureInterface: Bool = false,
                          seed: ((ProcessContext) -> Void)? = nil) -> [UInt8] {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        if configureInterface {
            _ = kernel.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 1),
                                                   mac: MACAddress("02:00:00:00:00:0a")!)
        }
        if let seed {
            kernel.spawn("seed") { ctx in seed(ctx); ctx.exit(0) }
            loop.runUntilIdle()
        }
        let pty = PseudoTerminal()
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        for line in lines {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }
        return captured.out
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
