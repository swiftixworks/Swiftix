/// Deferred deletion (unlink-while-open): removing a file's directory entry
/// while file descriptors are still open keeps the data accessible through
/// those descriptors until the last one closes — POSIX unlink semantics.
import Testing
@testable import Swiftix

@Suite("Deferred deletion")
struct DeferredDeletionTests {

    @Test func unlinkWhileOpenKeepsDataAccessibleThroughFD() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box {
            var pathGoneAfterUnlink = false
            var readAfterUnlink = ""
        }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd = ctx.open("/ephemeral", create: true)!
            ctx.write(fd, Array("precious data".utf8))
            _ = ctx.seek(fd, to: 0, whence: 0)

            // Unlink: path disappears but fd still works.
            _ = ctx.remove("/ephemeral")
            box.pathGoneAfterUnlink = (ctx.stat("/ephemeral") == nil)
            box.readAfterUnlink = String(decoding: ctx.read(fd, max: 99), as: UTF8.self)
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.pathGoneAfterUnlink)
        #expect(box.readAfterUnlink == "precious data")
    }

    @Test func writeAfterUnlinkStillWorks() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var content = "" }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd = ctx.open("/file", create: true)!
            _ = ctx.remove("/file")

            // Write to the orphaned fd.
            ctx.write(fd, Array("orphaned write".utf8))
            _ = ctx.seek(fd, to: 0, whence: 0)
            box.content = String(decoding: ctx.read(fd, max: 99), as: UTF8.self)
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.content == "orphaned write")
    }
}
