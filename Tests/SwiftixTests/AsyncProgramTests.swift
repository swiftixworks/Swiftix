import Testing
@testable import Swiftix

/// The "more general programs" slice: async `Command` bodies, the `sleep` and
/// `chdir` syscalls, cwd inheritance across `spawn`, and a long-running async
/// server (`tcpecho`) running as an ordinary registered command end-to-end.
///
/// Async bodies are driven purely on the logical-time `EventLoop`
/// (`runUntilIdle()` / `advance(by:)` interleaved with `Task.yield()`) — no
/// wall-clock waits, matching the existing async-syscall tests.
@Suite("Async programs + sleep/chdir syscalls")
struct AsyncProgramTests {

    /// Single-threaded observation record (written by process bodies on the loop
    /// thread, read by the driver between drains).
    final class Capture: @unchecked Sendable {
        var out: [UInt8] = []
        var reply: [UInt8] = []
        var replied = false
        var wokeAt = -1.0
    }

    /// Pump the logical-time loop until `done` or a generous cap, yielding to the
    /// runtime between drains so an async task's next job lands on the loop.
    private func drive(_ loop: EventLoop, until done: @Sendable () -> Bool, max: Int = 200_000) async {
        var pumps = 0
        while !done() && pumps < max {
            loop.advance(by: 0)
            loop.runNext()
            await Task.yield()
            pumps += 1
        }
    }

    /// Launch a `Command` as a process directly (bypassing the shell), on the
    /// overload matching its body kind. Proves a command is runnable as a program
    /// on its own, and lets a test start a server without a pty.
    private func launch(_ command: Command, on kernel: Kernel, args: [String]) {
        switch command.body {
        case let .sync(run):
            kernel.spawn(command.name, args: args) { run($0, args) }
        case let .async(run):
            kernel.spawn(command.name, args: args) { await run($0, args) }
        }
    }

    // MARK: - sleep syscall (logical time)

    /// `sleep` parks the process on a loop timer and resumes at the logical
    /// deadline — no wall-clock, no busy-wait.
    @Test func sleepParksUntilLogicalDeadline() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let cap = Capture()

        kernel.spawn("sleeper") { ctx in
            ctx.sleep(0.5) {
                cap.wokeAt = loop.now
                ctx.exit(0)
            }
        }
        loop.advance(by: 1.0)

        #expect(cap.wokeAt == 0.5)
    }

    // MARK: - chdir + cwd + relative-path resolution

    /// `chdir` resolves relative paths and `..`, and relative `open` is resolved
    /// against the new cwd.
    @Test func chdirResolvesRelativeAndParent() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        // Seed a nested directory by creating a file (parents are made as needed).
        kernel.spawn("seed") { ctx in
            _ = ctx.open("/home/user/note", create: true)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        final class Box { var ok = false; var afterCd = ""; var afterParent = ""; var readBack: [UInt8] = [] }
        let box = Box()
        kernel.spawn("p") { ctx in
            box.ok = ctx.chdir("/home/user")
            box.afterCd = ctx.currentDirectory
            // Relative open resolves against the cwd set above.
            if let fd = ctx.open("note", create: false, access: .readWrite) {
                ctx.write(fd, Array("hi".utf8))
                ctx.close(fd)
            }
            _ = ctx.chdir("..")                 // /home/user/.. -> /home
            box.afterParent = ctx.currentDirectory
            if let fd = ctx.open("user/note") { box.readBack = ctx.read(fd, max: 16); ctx.close(fd) }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.ok)
        #expect(box.afterCd == "/home/user")
        #expect(box.afterParent == "/home")
        #expect(box.readBack == Array("hi".utf8))
    }

    /// A child inherits its parent's cwd (POSIX `fork` semantics), so a `cd` in
    /// the shell is visible to the commands it launches.
    @Test func spawnInheritsWorkingDirectory() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("seed") { ctx in
            _ = ctx.open("/srv/data", create: true)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        final class Box { var childCwd = "" }
        let box = Box()
        kernel.spawn("parent") { ctx in
            _ = ctx.chdir("/srv")
            ctx.spawn("child") { child in
                box.childCwd = child.currentDirectory
                child.exit(0)
            }
            ctx.wait { _ in ctx.exit(0) }
        }
        loop.runUntilIdle()

        #expect(box.childCwd == "/srv")
    }

    // MARK: - cd + async command through the shell

    /// `cd` runs intrinsically in the shell and, thanks to cwd inheritance, a
    /// subsequent `pwd` child reports the new directory.
    /// `ls` with no argument lists the *current* directory (not `/`), so after
    /// `cd` it reflects the new cwd.
    @Test func shellLsListsCurrentDirectoryAfterCd() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("seed") { ctx in
            _ = ctx.open("/bin/tool", create: true)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        let pty = PseudoTerminal()
        let cap = capture(pty)
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()

        pty.writeFromApp(Array("cd bin\n".utf8))
        loop.runUntilIdle()
        pty.writeFromApp(Array("ls\n".utf8))
        loop.runUntilIdle()

        #expect(contains(cap.out, Array("tool".utf8)))   // listed /bin, not /
    }

    @Test func shellCdIsVisibleToPwd() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("seed") { ctx in
            _ = ctx.open("/var/log/system", create: true)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        let pty = PseudoTerminal()
        let cap = capture(pty)
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()

        pty.writeFromApp(Array("cd /var/log\n".utf8))
        loop.runUntilIdle()
        pty.writeFromApp(Array("pwd\n".utf8))
        loop.runUntilIdle()

        #expect(contains(cap.out, Array("/var/log".utf8)))
    }

    /// The shell launches an `async` command (`sleep`) on the async spawn path,
    /// and re-prompts once it completes — proving async program bodies flow
    /// through the same shell/registry mechanism as sync ones.
    @Test func shellRunsAsyncCommand() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        let cap = capture(pty)

        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("sleep 0.01\n".utf8))

        // Two prompts = initial + re-prompt after the async command finished.
        await drive(loop, until: { promptCount(cap.out) >= 2 })

        #expect(promptCount(cap.out) >= 2)
    }

    // MARK: - async TCP echo server as a registered command (end-to-end)

    /// The payoff: a long-running async server resolved from the registry and run
    /// as an ordinary program serves a real client across a two-host link.
    @Test func tcpEchoServerRunsAsCommandEndToEnd() async {
        let loop = EventLoop()
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let kernelA = Kernel(loop: loop)      // client host
        let kernelB = Kernel(loop: loop)      // server host
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB, on: loop, latency: 0.005)
        kernelA.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        kernelB.netns.stack.configuredNeighbor(ip: ipA, mac: macA)

        let cap = Capture()

        // Start the server as a registered command (proves the abstraction).
        let registry = CommandRegistry.builtins
        launch(registry.resolve("tcpecho")!, on: kernelB, args: ["tcpecho", "80"])
        loop.runUntilIdle()                    // server listening, parked on accept

        let payload = Array("hello server".utf8)
        kernelA.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            try? await ctx.tcpConnect(fd, to: ipB, port: 80)
            ctx.tcpSend(fd, payload)
            cap.reply = (try? await ctx.tcpRecv(fd)) ?? []
            cap.replied = true
            ctx.tcpClose(fd)
            ctx.exit(0)
        }

        await drive(loop, until: { cap.replied })

        #expect(cap.reply == payload)
    }

    /// The accept loop keeps running and serves connections concurrently: with
    /// per-connection children (enabled by fd inheritance), two clients that both
    /// connect before either closes are each echoed.
    @Test func tcpEchoServesMultipleConnections() async {
        let loop = EventLoop()
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB, on: loop, latency: 0.005)
        kernelA.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        kernelB.netns.stack.configuredNeighbor(ip: ipA, mac: macA)

        final class Replies: @unchecked Sendable { var got: [[UInt8]] = []; var count = 0 }
        let replies = Replies()

        launch(CommandRegistry.builtins.resolve("tcpecho")!, on: kernelB, args: ["tcpecho", "80"])
        loop.runUntilIdle()

        func client(_ text: String) {
            kernelA.spawn("client") { ctx in
                guard let fd = ctx.tcpSocket() else { return }
                try? await ctx.tcpConnect(fd, to: ipB, port: 80)
                ctx.tcpSend(fd, Array(text.utf8))
                let reply = (try? await ctx.tcpRecv(fd)) ?? []
                replies.got.append(reply)
                replies.count += 1
                ctx.tcpClose(fd)
                ctx.exit(0)
            }
        }
        client("one")
        client("two")

        await drive(loop, until: { replies.count >= 2 })

        #expect(replies.got.contains(Array("one".utf8)))
        #expect(replies.got.contains(Array("two".utf8)))
    }

    // MARK: - Helpers

    private func capture(_ pty: PseudoTerminal) -> Capture {
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        return captured
    }

    private func promptCount(_ bytes: [UInt8]) -> Int {
        let needle = Array("root@swiftix:/# ".utf8)
        guard bytes.count >= needle.count else { return 0 }
        var count = 0
        for start in 0...(bytes.count - needle.count)
        where Array(bytes[start..<start + needle.count]) == needle {
            count += 1
        }
        return count
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
