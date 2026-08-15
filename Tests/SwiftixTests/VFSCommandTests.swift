/// Shell command integration tests for the new VFS mechanisms: `ln` (hard link),
/// `mkfifo`, `touch`, and `stat` with nlink/timestamps.
import Testing
@testable import Swiftix

@Suite("Shell commands for VFS mechanisms")
struct VFSCommandTests {

    // Helper: run shell commands and capture output.
    private func run(_ lines: [String]) -> [UInt8] {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let registry = CommandRegistry.builtins
        let pty = PseudoTerminal()
        final class Capture { var out: [UInt8] = [] }
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

    private func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
        let n = Array(needle.utf8)
        guard !n.isEmpty, haystack.count >= n.count else { return false }
        for start in 0...(haystack.count - n.count)
        where Array(haystack[start..<start + n.count]) == n {
            return true
        }
        return false
    }

    @Test func lnWithoutSCreatesHardLink() {
        let out = run(["echo hello > /file", "ln /file /link", "cat /link"])
        #expect(contains(out, "hello"))
    }

    @Test func lnSCreatesSymlink() {
        let out = run(["echo world > /target", "ln -s /target /slink", "cat /slink"])
        #expect(contains(out, "world"))
    }

    @Test func mkfifoCommandCreates() {
        let out = run(["mkfifo /p", "stat /p"])
        #expect(contains(out, "fifo"))
    }

    @Test func touchCreatesFile() {
        let out = run(["touch /newfile", "stat /newfile"])
        #expect(contains(out, "regular file"))
    }

    @Test func statShowsNlink() {
        let out = run(["echo x > /f", "ln /f /g", "stat /f"])
        #expect(contains(out, "Links: 2"))
    }
}
