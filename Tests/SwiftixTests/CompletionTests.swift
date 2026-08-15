import Testing
@testable import Swiftix

/// Tab-completion (`Kernel.complete`): the library computes *what* completes —
/// the first word against the command registry, later words against VFS entries
/// resolved relative to a shell process's current directory. Pure logical-time;
/// completion itself is synchronous, so most cases need no loop driving. File
/// cases seed the VFS and park a "holder" process to own a cwd.
@Suite("Tab completion")
struct CompletionTests {

    /// Advance the loop by zero logical time, yielding so a just-spawned async
    /// body runs up to its first suspension — without firing any timers.
    private func settle(_ loop: EventLoop) async {
        for _ in 0..<50 {
            loop.advance(by: 0)
            await Task.yield()
        }
    }

    /// Park a live process with the given cwd so `complete` has a shell to read a
    /// working directory from. It `chdir`s, then sleeps far into the future
    /// (never woken, since the tests never advance logical time), so the process
    /// stays alive with a stable cwd.
    private func holder(_ kernel: Kernel, cwd: String) -> PID {
        kernel.spawn("holder") { ctx in
            _ = ctx.chdir(cwd)
            try? await ctx.sleep(1_000_000)
        }
    }

    // MARK: - Command completion (first word)

    @Test func completesCommandNameUniquely() {
        let kernel = Kernel(loop: EventLoop())
        let registry = CommandRegistry.builtins

        let result = kernel.complete(line: "hel", commands: registry, shellPID: 0)

        #expect(result.candidates == ["help"])
        #expect(result.insertion == "p ")   // completes "help" and adds a space
    }

    @Test func ambiguousCommandExtendsCommonPrefixOnly() {
        let kernel = Kernel(loop: EventLoop())
        let registry = CommandRegistry.builtins

        // "cat", "cd", "clear" all start with "c": common prefix is just "c",
        // so nothing unambiguous can be added.
        let result = kernel.complete(line: "c", commands: registry, shellPID: 0)

        #expect(result.candidates.contains("cat"))
        #expect(result.candidates.contains("cd"))
        #expect(result.candidates.contains("clear"))
        #expect(result.insertion == "")   // ambiguous: no single completion
    }

    @Test func noMatchingCommandYieldsEmpty() {
        let kernel = Kernel(loop: EventLoop())
        let registry = CommandRegistry.builtins

        let result = kernel.complete(line: "zzz", commands: registry, shellPID: 0)

        #expect(result.candidates.isEmpty)
        #expect(result.insertion == "")
    }

    @Test func completesExecutableDiscoveredThroughPath() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let registry = CommandRegistry.builtins

        kernel.spawn("seed") { context in
            if let fd = context.open("/usr/bin/tool", create: true) { context.close(fd) }
            _ = context.chmod(
                "/usr/bin/tool",
                mode: [
                    .ownerRead, .ownerWrite, .ownerExecute,
                    .groupRead, .groupExecute,
                    .otherRead, .otherExecute,
                ])
            context.exit(0)
        }
        loop.runUntilIdle()
        let shell = holder(kernel, cwd: "/")
        await settle(loop)

        let result = kernel.complete(line: "to", commands: registry, shellPID: shell)

        #expect(result.candidates == ["tool", "top", "touch"])
        #expect(result.insertion == "")
    }

    // MARK: - Filesystem completion (later words)

    @Test func completesFileRelativeToCwd() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let registry = CommandRegistry.builtins

        kernel.spawn("seed") { ctx in
            _ = ctx.mkdir("/bin")
            if let fd = ctx.open("/bin/hello.txt", create: true) { ctx.close(fd) }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        let shell = holder(kernel, cwd: "/bin")
        await settle(loop)

        // Completing the argument of `cat` against the cwd (/bin).
        let result = kernel.complete(line: "cat h", commands: registry, shellPID: shell)

        #expect(result.candidates == ["hello.txt"])
        #expect(result.insertion == "ello.txt ")   // unique file gets a trailing space
    }

    @Test func directoryCompletionGetsTrailingSlashNoSpace() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let registry = CommandRegistry.builtins

        kernel.spawn("seed") { ctx in
            _ = ctx.mkdir("/bin")
            _ = ctx.mkdir("/bin/sub")
            ctx.exit(0)
        }
        loop.runUntilIdle()

        let shell = holder(kernel, cwd: "/bin")
        await settle(loop)

        let result = kernel.complete(line: "cat s", commands: registry, shellPID: shell)

        #expect(result.candidates == ["sub/"])
        #expect(result.insertion == "ub/")   // directory: trailing "/", no space
    }

    @Test func ambiguousFilesExtendCommonPrefixOnly() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let registry = CommandRegistry.builtins

        kernel.spawn("seed") { ctx in
            _ = ctx.mkdir("/data")
            for name in ["report.txt", "readme.md"] {
                if let fd = ctx.open("/data/\(name)", create: true) { ctx.close(fd) }
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        let shell = holder(kernel, cwd: "/data")
        await settle(loop)

        let result = kernel.complete(line: "cat re", commands: registry, shellPID: shell)

        #expect(result.candidates == ["readme.md", "report.txt"])
        #expect(result.insertion == "")   // "re" is already the common prefix
    }

    @Test func completesIntoNamedSubdirectory() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let registry = CommandRegistry.builtins

        kernel.spawn("seed") { ctx in
            _ = ctx.mkdir("/etc")
            if let fd = ctx.open("/etc/hosts", create: true) { ctx.close(fd) }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        let shell = holder(kernel, cwd: "/")
        await settle(loop)

        // A path with a directory portion resolves that dir and completes the name.
        let result = kernel.complete(line: "cat /etc/h", commands: registry, shellPID: shell)

        #expect(result.candidates == ["hosts"])
        #expect(result.insertion == "osts ")
    }
}
