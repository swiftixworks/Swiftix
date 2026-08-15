import Testing
@testable import Swiftix

/// Environment variables and shell expansion: `export`, bare `NAME=VALUE`,
/// per-command `NAME=VALUE cmd`, `$VAR` / `${VAR}` / `$?` expansion, and `env`.
@Suite("Environment + variable expansion")
struct EnvironmentTests {

    @Test func exportAndExpand() {
        let (loop, kernel, pty, cap) = makeShell()
        _ = kernel
        pty.writeFromApp(Array("export FOO=bar\n".utf8)); loop.runUntilIdle()
        pty.writeFromApp(Array("echo $FOO\n".utf8)); loop.runUntilIdle()
        pty.writeFromApp(Array("echo ${FOO}baz\n".utf8)); loop.runUntilIdle()

        #expect(contains(cap.out, Array("bar\n".utf8)))
        #expect(contains(cap.out, Array("barbaz".utf8)))
    }

    @Test func bareAssignmentSetsShellEnv() {
        let (loop, kernel, pty, cap) = makeShell()
        _ = kernel
        pty.writeFromApp(Array("X=hello\n".utf8)); loop.runUntilIdle()
        pty.writeFromApp(Array("echo $X world\n".utf8)); loop.runUntilIdle()
        #expect(contains(cap.out, Array("hello world".utf8)))
    }

    @Test func perCommandEnvVisibleToChildOnly() {
        let (loop, kernel, pty, cap) = makeShell()
        _ = kernel
        pty.writeFromApp(Array("GREETING=hi env\n".utf8)); loop.runUntilIdle()
        #expect(contains(cap.out, Array("GREETING=hi".utf8)))

        // Not exported to the shell: a later echo sees it empty.
        pty.writeFromApp(Array("echo [$GREETING]\n".utf8)); loop.runUntilIdle()
        #expect(contains(cap.out, Array("[]".utf8)))
    }

    @Test func lastStatusExpands() {
        let (loop, kernel, pty, cap) = makeShell()
        _ = kernel
        pty.writeFromApp(Array("false\n".utf8)); loop.runUntilIdle()
        pty.writeFromApp(Array("echo $?\n".utf8)); loop.runUntilIdle()
        #expect(contains(cap.out, Array("1\n".utf8)))

        pty.writeFromApp(Array("true\n".utf8)); loop.runUntilIdle()
        pty.writeFromApp(Array("echo $?\n".utf8)); loop.runUntilIdle()
        #expect(contains(cap.out, Array("0\n".utf8)))
    }

    @Test func spawnInheritsEnvironment() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var childValue: String? }
        let box = Box()
        kernel.spawn("parent") { ctx in
            ctx.setenv("SHARED", "yes")
            ctx.spawn("child") { child in
                box.childValue = child.getenv("SHARED")
                child.exit(0)
            }
            ctx.wait { _ in ctx.exit(0) }
        }
        loop.runUntilIdle()
        #expect(box.childValue == "yes")
    }

    // MARK: - Helpers

    final class Cap: @unchecked Sendable { var out: [UInt8] = [] }

    private func makeShell() -> (loop: EventLoop, kernel: Kernel, pty: PseudoTerminal, cap: Cap) {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        pty.echo = false
        let cap = Cap()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            cap.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        return (loop, kernel, pty, cap)
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
