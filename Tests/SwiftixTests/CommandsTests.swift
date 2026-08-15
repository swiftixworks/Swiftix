import Testing
@testable import Swiftix

/// The unified command layer: a program is `(ProcessContext, argv) -> Void`, the
/// shell resolves names in an injectable `CommandRegistry`, and processes carry a
/// real argv + exit code. These tests cover the abstraction itself (argv, exit
/// codes, extensibility) rather than any single command's output.
@Suite("Command layer + registry")
struct CommandsTests {

    // MARK: - Process model: argv + exit codes

    /// A spawned process sees the argument vector it was launched with.
    @Test func argvIsVisibleToProcess() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var argv: [String] = [] }
        let box = Box()
        kernel.spawn("prog", args: ["prog", "a", "b"]) { ctx in
            box.argv = ctx.arguments
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.argv == ["prog", "a", "b"])
    }

    /// `true` and `false` are real programs with meaningful exit codes, observed
    /// by a parent through `wait()`. This is impossible in the old "return bytes"
    /// model, where every command exited 0.
    @Test func trueAndFalseCarryExitCodes() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let registry = CommandRegistry.builtins

        func exitCode(of name: String) -> Int32 {
            final class Box { var code: Int32 = -99 }
            let box = Box()
            kernel.spawn("runner") { ctx in
                let command = registry.resolve(name)!
                guard case let .sync(run) = command.body else { return }
                ctx.spawn(name, args: [name]) { child in run(child, [name]) }
                ctx.wait { result in
                    if case .success(let event) = result {
                        box.code = event.status.code
                    }
                }
            }
            loop.runUntilIdle()
            return box.code
        }

        #expect(exitCode(of: "true") == 0)
        #expect(exitCode(of: "false") == 1)
    }

    // MARK: - Registry extensibility (the framework seam)

    /// A consumer can register its own command; the generic shell runs it with no
    /// library change. This is the whole point of the registry.
    @Test func shellRunsConsumerRegisteredCommand() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        let captured = capture(pty)

        let registry = CommandRegistry.builtins
        registry.register(Command(name: "greet", summary: "say hi") { ctx, argv in
            let who = argv.count > 1 ? argv[1] : "world"
            ctx.print("hi \(who)\n")
            ctx.exit(0)
        })

        kernel.spawn("sh", Programs.shell(tty: pty.slave, commands: registry))
        loop.runUntilIdle()
        pty.writeFromApp(Array("greet swiftix\n".utf8))
        loop.runUntilIdle()

        #expect(contains(captured.out, Array("hi swiftix".utf8)))
    }

    /// File-backed runtimes plug into the generic registry without teaching the
    /// shell about any executable format.
    @Test func shellRunsConsumerRegisteredExecutableLoader() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        let captured = capture(pty)

        let registry = CommandRegistry.builtins
        registry.registerExecutableLoader { _, path in
            guard path == "./guest" else { return nil }
            return Command(name: path, summary: "guest executable") { context, _ in
                context.print("loaded from file\n")
                context.exit(0)
            }
        }

        kernel.spawn("sh", Programs.shell(tty: pty.slave, commands: registry))
        loop.runUntilIdle()
        pty.writeFromApp(Array("./guest\n".utf8))
        loop.runUntilIdle()

        #expect(contains(captured.out, Array("loaded from file".utf8)))
    }

    /// `help` reflects the live registry, so a consumer-added command shows up
    /// without touching the library.
    @Test func helpListsRegisteredCommands() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        let captured = capture(pty)

        let registry = CommandRegistry.builtins
        registry.register(Command(name: "frobnicate", summary: "custom") { ctx, _ in ctx.exit(0) })

        kernel.spawn("sh", Programs.shell(tty: pty.slave, commands: registry))
        loop.runUntilIdle()
        pty.writeFromApp(Array("help\n".utf8))
        loop.runUntilIdle()

        #expect(contains(captured.out, Array("frobnicate".utf8)))   // consumer command listed
        #expect(contains(captured.out, Array("echo".utf8)))         // built-ins still listed
    }

    // MARK: - Built-ins as unified programs

    /// `cat` reads a file through the syscall surface (not a special-cased shell
    /// branch) using its argv.
    @Test func catReadsFileViaArgv() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        let captured = capture(pty)

        // Seed a file in the VFS via a process.
        kernel.spawn("seed") { ctx in
            let fd = ctx.open("/greeting", create: true)!
            ctx.write(fd, Array("file body\n".utf8))
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("cat /greeting\n".utf8))
        loop.runUntilIdle()

        #expect(contains(captured.out, Array("file body".utf8)))
    }

    /// `ls` lists a directory through the syscall surface using its argv.
    @Test func lsListsDirectoryViaArgv() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        let captured = capture(pty)

        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("ls /proc/net\n".utf8))
        loop.runUntilIdle()

        #expect(contains(captured.out, Array("route".utf8)))   // /proc/net/route is listed
    }

    /// The payoff of unification: `ping` — a blocking network tool — runs from the
    /// shell exactly like `cat`, resolved from the same registry, parsing its
    /// target from argv and writing replies to stdout.
    @Test func pingRunsAsShellCommand() {
        let loop = EventLoop()
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)

        let ifA = kernelA.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 1),
                                                      mac: MACAddress("02:00:00:00:00:0a")!)
        let ifB = kernelB.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 2),
                                                      mac: MACAddress("02:00:00:00:00:0b")!)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB, on: loop, latency: 0.005)

        let pty = PseudoTerminal()
        let captured = capture(pty)

        kernelA.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("ping 10.0.0.2\n".utf8))
        loop.advance(by: 1.0)                      // ARP resolves, echo round-trips

        #expect(contains(captured.out, Array("bytes from 10.0.0.2".utf8)))
    }

    // MARK: - Helpers

    /// Accumulate everything the pty emits toward the app.
    private final class Capture { var out: [UInt8] = [] }

    private func capture(_ pty: PseudoTerminal) -> Capture {
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        return captured
    }

    /// Byte-subsequence search (avoids depending on Foundation's String.contains).
    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
