/// Hard links and nlink reference counting: multiple directory entries pointing
/// at the same inode, nlink tracking, and unlink-one-name semantics.
import Testing
@testable import Swiftix

@Suite("Hard links and nlink")
struct HardLinkTests {

    @Test func hardLinkCreatesSecondEntryToSameInode() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box {
            var linked = false
            var originalContent = ""
            var linkContent = ""
            var originalNlink = 0
            var linkNlink = 0
        }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd = ctx.open("/file", create: true)!
            ctx.write(fd, Array("hello".utf8))
            ctx.close(fd)

            box.linked = ctx.link("/file", at: "/hardlink")
            box.originalNlink = ctx.stat("/file")?.nlink ?? 0
            box.linkNlink = ctx.stat("/hardlink")?.nlink ?? 0

            if let fd2 = ctx.open("/hardlink") {
                box.linkContent = String(decoding: ctx.read(fd2, max: 99), as: UTF8.self)
                ctx.close(fd2)
            }
            if let fd3 = ctx.open("/file") {
                box.originalContent = String(decoding: ctx.read(fd3, max: 99), as: UTF8.self)
                ctx.close(fd3)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.linked)
        #expect(box.originalNlink == 2)
        #expect(box.linkNlink == 2)
        #expect(box.linkContent == "hello")
        #expect(box.originalContent == "hello")
    }

    @Test func writesThroughHardLinkVisibleThroughOriginal() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var content = "" }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd = ctx.open("/original", create: true)!
            ctx.write(fd, Array("before".utf8))
            ctx.close(fd)

            _ = ctx.link("/original", at: "/link")

            // Write through the hard link.
            let fd2 = ctx.open("/link", truncate: true)!
            ctx.write(fd2, Array("after".utf8))
            ctx.close(fd2)

            // Read through the original name.
            let fd3 = ctx.open("/original")!
            box.content = String(decoding: ctx.read(fd3, max: 99), as: UTF8.self)
            ctx.close(fd3)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.content == "after")
    }

    @Test func unlinkOneNameDecreasesNlink() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box {
            var nlinkAfterLink = 0
            var nlinkAfterUnlink = 0
            var contentAfterUnlink = ""
        }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd = ctx.open("/a", create: true)!
            ctx.write(fd, Array("data".utf8))
            ctx.close(fd)

            _ = ctx.link("/a", at: "/b")
            box.nlinkAfterLink = ctx.stat("/a")?.nlink ?? 0

            _ = ctx.remove("/a")
            box.nlinkAfterUnlink = ctx.stat("/b")?.nlink ?? 0

            // File is still accessible through /b.
            let fd2 = ctx.open("/b")!
            box.contentAfterUnlink = String(decoding: ctx.read(fd2, max: 99), as: UTF8.self)
            ctx.close(fd2)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.nlinkAfterLink == 2)
        #expect(box.nlinkAfterUnlink == 1)
        #expect(box.contentAfterUnlink == "data")
    }

    @Test func directoryEntriesKeepIndependentHardLinkNames() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var entries: [String] = [] }
        let box = Box()

        kernel.spawn("test") { ctx in
            _ = ctx.open("/original", create: true)
            _ = ctx.link("/original", at: "/alias")
            box.entries = ctx.listDirectory("/") ?? []
        }
        loop.runUntilIdle()

        #expect(box.entries.contains("original"))
        #expect(box.entries.contains("alias"))
        #expect(box.entries.filter { $0 == "original" }.count == 1)
    }

    @Test func renamingOneHardLinkDoesNotRenameItsSibling() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box {
            var entries: [String] = []
            var siblingStillResolves = false
            var renamedResolves = false
        }
        let box = Box()

        kernel.spawn("test") { ctx in
            _ = ctx.mkdir("/sandbox")
            let scope = FileSystemScope(rootPath: "/sandbox")
            _ = ctx.open("/sandbox/original", create: true)
            _ = ctx.link("/sandbox/original", at: "/sandbox/alias")
            try? ctx.rename("alias", in: scope, to: "renamed", in: scope)
            box.entries = ctx.listDirectory("/sandbox") ?? []
            box.siblingStillResolves = ctx.stat("/sandbox/original") != nil
            box.renamedResolves = ctx.stat("/sandbox/renamed") != nil
        }
        loop.runUntilIdle()

        #expect(box.entries == ["original", "renamed"])
        #expect(box.siblingStillResolves)
        #expect(box.renamedResolves)
    }

    @Test func hardLinkFailsForDirectories() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var linked = true }
        let box = Box()

        kernel.spawn("test") { ctx in
            _ = ctx.mkdir("/dir")
            box.linked = ctx.link("/dir", at: "/dirlink")
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(!box.linked)
    }

    @Test func hardLinkFailsWhenTargetDoesNotExist() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var linked = true }
        let box = Box()

        kernel.spawn("test") { ctx in
            box.linked = ctx.link("/nonexistent", at: "/link")
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(!box.linked)
    }

    @Test func directoryNlinkStartsAtTwo() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var nlink = 0 }
        let box = Box()

        kernel.spawn("test") { ctx in
            _ = ctx.mkdir("/dir")
            box.nlink = ctx.stat("/dir")?.nlink ?? 0
            ctx.exit(0)
        }
        loop.runUntilIdle()

        // Directory nlink = 2 (parent entry + implicit ".")
        #expect(box.nlink == 2)
    }
}
