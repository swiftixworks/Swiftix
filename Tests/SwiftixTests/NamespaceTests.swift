import Testing
@testable import Swiftix

/// UTS namespace (hostname/domainname isolation) and the `unshare`/`nsenter`
/// meta-programs built on it — the smallest concrete demonstration of the
/// container/isolation model. Two layers are covered: the shell-facing commands
/// (`hostname`, `uname -n`, `unshare -u`) and the `ProcessContext` syscall surface
/// that backs them (`unshareUTS`, `enterUTSNamespace`, per-process namespace
/// sharing).
@Suite("UTS namespace (hostname isolation)")
struct NamespaceTests {

    // MARK: - Command layer (through the shell)

    @Test func hostnameDefaultsToSwiftix() {
        let out = run(["hostname"])
        #expect(contains(out, Array("swiftix".utf8)))
    }

    /// `hostname NAME` sets the machine-wide name; a later `hostname` (a separate
    /// process sharing the same namespace) reads it back.
    @Test func hostnameSetIsVisibleToLaterCommands() {
        let out = run(["hostname box1", "hostname"])
        #expect(contains(out, Array("box1".utf8)))
    }

    /// `uname -n` reports the node name from the UTS namespace, tracking a
    /// preceding `hostname` change.
    @Test func unameNodeNameTracksHostname() {
        let out = run(["hostname web01", "uname -n"])
        #expect(contains(out, Array("web01".utf8)))
    }

    @Test func unameAllIncludesHostname() {
        let out = run(["hostname web01", "uname -a"])
        #expect(contains(out, Array("Swiftix web01".utf8)))
    }

    /// Without `unshare`, a command that changes the hostname changes it for the
    /// whole machine: the following `hostname` sees the new name. "isolatedhost"
    /// therefore appears twice — once from the child's own print, once from the
    /// trailing `hostname` reading the (now-changed) machine name. (Counting
    /// occurrences sidesteps the shell's command-line echo, which repeats typed
    /// argument text.)
    @Test func hostnameChangeLeaksWithoutUnshare() {
        let out = run(["hostname basehost", "sethost", "hostname"],
                      register: registerSetHost)
        #expect(contains(out, Array("child sees: isolatedhost".utf8)))
        let lines = String(decoding: out, as: UTF8.self).split(separator: "\n")
        #expect(lines.filter { $0 == "child sees: isolatedhost" }.count == 1)
        #expect(lines.filter { $0 == "isolatedhost" }.count == 1)
    }

    /// With `unshare -u`, the same command runs in a private UTS namespace: its
    /// hostname change stays invisible to the machine, so the following
    /// `hostname` still reports the original name. "isolatedhost" then appears
    /// exactly once — only the child's own print — and never as the machine name.
    @Test func unshareIsolatesHostnameChange() {
        let out = run(["hostname basehost", "unshare -u sethost", "hostname"],
                      register: registerSetHost)
        #expect(contains(out, Array("child sees: isolatedhost".utf8)))
        #expect(occurrences(out, of: Array("isolatedhost".utf8)) == 1)
    }

    @Test func unshareRejectsUnknownOption() {
        let out = run(["unshare -Z echo hi"])
        #expect(contains(out, Array("unsupported option".utf8)))
    }

    @Test func nsenterRequiresTarget() {
        let out = run(["nsenter echo hi"])
        #expect(contains(out, Array("target PID is required".utf8)))
    }

    // MARK: - Syscall layer (ProcessContext)

    /// A child that `unshareUTS`es gets a private copy: its hostname change is
    /// invisible to its parent's (shared, root) namespace.
    @Test func unshareGivesChildAPrivateNamespace() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        let childSaw = Box()
        let parentSaw = Box()
        kernel.spawn("parent") { ctx in
            ctx.setHostname("machine")
            ctx.spawn("child") { child in
                child.unshareUTS()
                child.setHostname("private")
                childSaw.value = child.hostname
                child.exit(0)
            }
            // Read the parent's own view only after the child has run and exited.
            ctx.wait { _ in
                parentSaw.value = ctx.hostname
                ctx.exit(0)
            }
        }
        loop.runUntilIdle()

        #expect(childSaw.value == "private")
        #expect(parentSaw.value == "machine")
    }

    /// A child inherits (shares) the parent's namespace when it does NOT unshare:
    /// a change it makes is visible to the parent.
    @Test func childSharesParentNamespaceByDefault() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        let parentSaw = Box()
        kernel.spawn("parent") { ctx in
            ctx.setHostname("start")
            ctx.spawn("child") { child in
                child.setHostname("changed")   // no unshare → shared
                child.exit(0)
            }
            // Read only after the child has run (spawn is scheduled, not immediate).
            ctx.wait { _ in
                parentSaw.value = ctx.hostname
                ctx.exit(0)
            }
        }
        loop.runUntilIdle()

        #expect(parentSaw.value == "changed")
    }

    /// `enterUTSNamespace(ofPID:)` joins a live process's namespace, so the joiner
    /// sees that process's (private) hostname — and the root namespace is
    /// untouched by that process's earlier `unshare`.
    @Test func nsenterJoinsAnotherProcessNamespace() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        // Long-lived process A: unshare, rename its host, then park forever on a
        // pipe with no writer (stays alive without advancing the clock).
        let aPID = kernel.spawn("A") { ctx in
            ctx.unshareUTS()
            ctx.setHostname("containerA")
            let pipe = ctx.pipe()
            _ = pipe.write               // keep the write end open → no EOF
            ctx.read(pipe.read) { _ in }
        }
        loop.runUntilIdle()

        let joinerSaw = Box()
        let rootSaw = Box()
        kernel.spawn("B") { ctx in
            #expect(ctx.enterUTSNamespace(ofPID: aPID))
            joinerSaw.value = ctx.hostname
            ctx.exit(0)
        }
        // A separate top-level process reads the untouched root namespace.
        kernel.spawn("C") { ctx in
            rootSaw.value = ctx.hostname
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(joinerSaw.value == "containerA")
        #expect(rootSaw.value == "swiftix")
    }

    @Test func enterUTSNamespaceFailsForUnknownPID() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let result = Box()
        kernel.spawn("p") { ctx in
            result.value = ctx.enterUTSNamespace(ofPID: 9999) ? "ok" : "fail"
            ctx.exit(0)
        }
        loop.runUntilIdle()
        #expect(result.value == "fail")
    }

    // MARK: - Helpers

    private final class Box { var value = "" }

    private func registerSetHost(_ registry: CommandRegistry) {
        // Sets the hostname in the caller's namespace and prints what it sees.
        registry.register(Command(name: "sethost", summary: "set + show hostname") { ctx, _ in
            ctx.setHostname("isolatedhost")
            ctx.print("child sees: \(ctx.hostname)\n")
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
        occurrences(haystack, of: needle) > 0
    }

    private func occurrences(_ haystack: [UInt8], of needle: [UInt8]) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var count = 0
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            count += 1
        }
        return count
    }
}
