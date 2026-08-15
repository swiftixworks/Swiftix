/// File timestamps (atime/mtime/ctime): the VFS tracks logical clock ticks
/// from EventLoop.now on access, modification, and metadata change — the
/// three POSIX timestamp fields that `stat` exposes.
import Testing
@testable import Swiftix

@Suite("File timestamps (atime/mtime/ctime)")
struct TimestampTests {

    @Test func newFileGetsTimestampAtCreationTime() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var stat: FileStat? }
        let box = Box()

        // Advance time before creating the file so timestamps are non-zero.
        loop.advance(by: 5.0)
        kernel.spawn("test") { ctx in
            _ = ctx.open("/file", create: true)
            box.stat = ctx.stat("/file")
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.stat?.atime == 5.0)
        #expect(box.stat?.mtime == 5.0)
        #expect(box.stat?.ctime == 5.0)
    }

    @Test func readUpdatesAtime() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var atimeAfterRead: Double = 0 }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd = ctx.open("/file", create: true)!
            ctx.write(fd, Array("data".utf8))
            ctx.close(fd)

            // Advance time, then read.
            ctx.eventLoop.advance(by: 3.0)
            let fd2 = ctx.open("/file")!
            _ = ctx.read(fd2, max: 99)
            ctx.close(fd2)

            box.atimeAfterRead = ctx.stat("/file")?.atime ?? 0
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.atimeAfterRead == 3.0)
    }

    @Test func writeUpdatesMtime() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box {
            var mtimeBefore: Double = 0
            var mtimeAfter: Double = 0
        }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd = ctx.open("/file", create: true)!
            ctx.write(fd, Array("initial".utf8))
            ctx.close(fd)
            box.mtimeBefore = ctx.stat("/file")?.mtime ?? -1

            ctx.eventLoop.advance(by: 2.0)
            let fd2 = ctx.open("/file", access: .readWrite)!
            ctx.write(fd2, Array("more".utf8))
            ctx.close(fd2)
            box.mtimeAfter = ctx.stat("/file")?.mtime ?? -1
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.mtimeBefore == 0.0)
        #expect(box.mtimeAfter == 2.0)
    }

    @Test func chmodUpdatesCtime() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var ctimeAfterChmod: Double = 0 }
        let box = Box()

        kernel.spawn("test") { ctx in
            _ = ctx.open("/file", create: true)
            ctx.eventLoop.advance(by: 4.0)
            _ = ctx.chmod("/file", mode: [.ownerRead, .ownerWrite])
            box.ctimeAfterChmod = ctx.stat("/file")?.ctime ?? 0
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.ctimeAfterChmod == 4.0)
    }

    @Test func utimesOverridesTimestamps() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var stat: FileStat? }
        let box = Box()

        kernel.spawn("test") { ctx in
            _ = ctx.open("/file", create: true)
            _ = ctx.utimes("/file", atime: 100.0, mtime: 200.0)
            box.stat = ctx.stat("/file")
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.stat?.atime == 100.0)
        #expect(box.stat?.mtime == 200.0)
    }

    @Test func hardLinkUpdatesCtime() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var ctimeAfterLink: Double = 0 }
        let box = Box()

        kernel.spawn("test") { ctx in
            _ = ctx.open("/file", create: true)
            ctx.eventLoop.advance(by: 7.0)
            _ = ctx.link("/file", at: "/link")
            box.ctimeAfterLink = ctx.stat("/file")?.ctime ?? 0
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.ctimeAfterLink == 7.0)
    }
}
