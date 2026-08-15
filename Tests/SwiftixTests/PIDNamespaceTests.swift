import Testing
@testable import Swiftix

/// PID namespaces: namespace-local process ids (the first process in a new
/// namespace is pid 1), `unshare -p`, and the isolation a contained process
/// observes — it sees only its own namespace's processes and cannot signal the
/// host's. The kernel keeps one global pid per process as the internal source of
/// truth; these tests exercise the namespace-local projection layered on top.
@Suite("PID namespace (process id isolation)")
struct PIDNamespaceTests {

    // MARK: - Local pid assignment

    /// At the root (no container), the namespace-local pid equals the global pid.
    @Test func rootNamespacePidIsGlobalPid() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let seen = Counter()
        let spawned = kernel.spawn("p") { ctx in
            seen.value = ctx.getpid()
            ctx.exit(0)
        }
        loop.runUntilIdle()
        #expect(seen.value == spawned)
    }

    /// The first process created in a new PID namespace sees itself as pid 1,
    /// while its global pid is something else entirely.
    @Test func firstProcessInNewNamespaceIsPidOne() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let local = Counter()
        let global = Counter()
        kernel.spawn("launcher") { ctx in
            ctx.unsharePIDNamespace()
            ctx.spawn("init") { child in
                local.value = child.getpid()
                global.value = child.globalPID
                child.exit(0)
            }
            ctx.wait { _ in ctx.exit(0) }
        }
        loop.runUntilIdle()
        #expect(local.value == 1)
        #expect(global.value != local.value)   // real (global) pid is not 1
    }

    /// Descendants of the namespace's pid 1 get the next local pids (2, 3, …).
    @Test func descendantsGetSequentialLocalPids() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let initLocal = Counter()
        let workerLocal = Counter()
        kernel.spawn("launcher") { ctx in
            ctx.unsharePIDNamespace()
            ctx.spawn("init") { initProc in
                initLocal.value = initProc.getpid()          // 1
                initProc.spawn("worker") { worker in
                    workerLocal.value = worker.getpid()      // 2
                    worker.exit(0)
                }
                initProc.wait { _ in initProc.exit(0) }
            }
            ctx.wait { _ in ctx.exit(0) }
        }
        loop.runUntilIdle()
        #expect(initLocal.value == 1)
        #expect(workerLocal.value == 2)
    }

    // MARK: - Visibility / isolation

    /// A contained process sees only the processes in its own namespace — not the
    /// host's — and they are numbered from 1.
    @Test func containedProcessSeesOnlyItsNamespace() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        // A host process parked in the root namespace.
        kernel.spawn("hostproc") { ctx in
            let pipe = ctx.pipe(); _ = pipe.write
            ctx.read(pipe.read) { _ in }
        }
        loop.runUntilIdle()

        let listing = Box()
        kernel.spawn("launcher") { ctx in
            ctx.unsharePIDNamespace()
            ctx.spawn("initproc") { child in
                listing.value = String(decoding: child.namespaceProcessListing(), as: UTF8.self)
                child.exit(0)
            }
            ctx.wait { _ in ctx.exit(0) }
        }
        loop.runUntilIdle()

        // Header + exactly one row (the contained pid 1); the host is invisible.
        let lines = listing.value.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("PID"))          // header
        #expect(lines[1].hasPrefix("1 "))           // local pid 1
        #expect(!listing.value.contains("hostproc"))
    }

    /// From the host (root namespace), the contained process IS visible — with its
    /// global pid — alongside the launcher.
    @Test func hostNamespaceSeesContainedProcess() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        kernel.spawn("launcher") { ctx in
            ctx.unsharePIDNamespace()
            ctx.spawn("initproc") { child in
                let pipe = child.pipe(); _ = pipe.write
                child.read(pipe.read) { _ in }
            }
            let pipe = ctx.pipe(); _ = pipe.write
            ctx.read(pipe.read) { _ in }
        }
        loop.runUntilIdle()

        let listing = Box()
        kernel.spawn("reader") { ctx in
            listing.value = String(decoding: ctx.namespaceProcessListing(), as: UTF8.self)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(listing.value.contains("initproc"))   // host sees the contained process
        #expect(listing.value.contains("launcher"))
    }

    /// Inside a namespace, `resolveVisiblePID` maps a local pid to a global one,
    /// and rejects a pid that is not a member of the namespace (the basis for
    /// `kill` isolation).
    @Test func visiblePidResolutionRespectsNamespace() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let ownGlobal = OptionalCounter()
        let unknown = OptionalCounter()
        kernel.spawn("launcher") { ctx in
            ctx.unsharePIDNamespace()
            ctx.spawn("initproc") { child in
                ownGlobal.value = child.resolveVisiblePID(1)     // local 1 → its global
                unknown.value = child.resolveVisiblePID(999)     // no such local pid → nil
                child.exit(0)
            }
            ctx.wait { _ in ctx.exit(0) }
        }
        loop.runUntilIdle()
        #expect(ownGlobal.value != nil)
        #expect(unknown.value == nil)
    }

    // MARK: - Command layer (through the shell)

    /// `unshare -p CMD` runs CMD as pid 1 in a fresh namespace.
    @Test func unsharePidRunsCommandAsPidOne() {
        let out = run(["unshare -p showpid"], register: registerShowPID)
        #expect(contains(out, Array("pid=1".utf8)))
    }

    /// Without `unshare -p`, a command keeps its ordinary (non-1) pid — the shell
    /// itself is pid 1 in the test harness.
    @Test func withoutUnshareCommandKeepsGlobalPid() {
        let out = run(["showpid"], register: registerShowPID)
        #expect(!contains(out, Array("pid=1".utf8)))
    }

    // MARK: - Helpers

    private final class Counter { var value: PID = 0 }
    private final class OptionalCounter { var value: PID? }
    private final class Box { var value = "" }

    private func registerShowPID(_ registry: CommandRegistry) {
        registry.register(Command(name: "showpid", summary: "print pid") { ctx, _ in
            ctx.print("pid=\(ctx.getpid())\n")
            ctx.exit(0)
        })
    }

    private final class Capture { var out: [UInt8] = [] }

    private func run(_ lines: [String],
                     register: ((CommandRegistry) -> Void)? = nil) -> [UInt8] {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let registry = CommandRegistry.builtins
        register?(registry)
        let pty = PseudoTerminal()
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave, commands: registry))
        loop.runUntilIdle()
        for line in lines {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }
        return captured.out
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
