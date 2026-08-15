import Testing
@testable import Swiftix

/// Symbolic links in the VFS: `lookup` follows links (absolute and relative,
/// with a hop limit against cycles), and the `ln`/`readlink` commands plus the
/// `symlink`/`readlink` syscalls expose them. Shell tests seed file contents via
/// a spawned process (not typed input) so the pty echo never masks the assertion.
@Suite("Symbolic links")
struct SymlinkTests {

    // MARK: - Shell-level

    @Test func catFollowsSymlinkToFile() {
        let out = runShell(["ln -s /f /l", "cat /l"], seed: { ctx in
            let fd = ctx.open("/f", create: true)!
            ctx.write(fd, Array("linkbody\n".utf8))
            ctx.close(fd)
        })
        #expect(contains(out, Array("linkbody".utf8)))
    }

    @Test func lsFollowsSymlinkToDirectory() {
        let out = runShell(["ln -s /d /dl", "ls /dl"], seed: { ctx in
            _ = ctx.mkdir("/d")
            let fd = ctx.open("/d/inside", create: true)!
            ctx.close(fd)
        })
        #expect(contains(out, Array("inside".utf8)))
    }

    @Test func relativeSymlinkResolvesFromLinkDirectory() {
        let out = runShell(["ln -s b /a/link", "cat /a/link"], seed: { ctx in
            _ = ctx.mkdir("/a")
            let fd = ctx.open("/a/b", create: true)!
            ctx.write(fd, Array("relbody\n".utf8))
            ctx.close(fd)
        })
        #expect(contains(out, Array("relbody".utf8)))
    }

    // MARK: - Syscall-level

    @Test func readlinkReturnsStoredTarget() {
        final class Box { var target: String? = "unset" }
        let box = Box()
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("t") { ctx in
            _ = ctx.symlink("/some/target", at: "/l")
            box.target = ctx.readlink("/l")
            ctx.exit(0)
        }
        loop.runUntilIdle()
        #expect(box.target == "/some/target")
    }

    @Test func cyclicSymlinksAreRejectedNotHung() {
        final class Box { var opened = true }
        let box = Box()
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("t") { ctx in
            _ = ctx.symlink("/y", at: "/x")
            _ = ctx.symlink("/x", at: "/y")
            box.opened = ctx.open("/x") != nil   // must terminate (hop limit), returning nil
            ctx.exit(0)
        }
        loop.runUntilIdle()
        #expect(box.opened == false)
    }

    // MARK: - Helpers

    private final class Capture { var out: [UInt8] = [] }

    private func runShell(_ lines: [String], seed: @escaping (ProcessContext) -> Void) -> [UInt8] {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("seed") { ctx in seed(ctx); ctx.exit(0) }
        loop.runUntilIdle()
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

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
