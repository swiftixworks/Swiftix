/// Advisory file locking (flock): shared/exclusive locks on inodes, contention
/// semantics, release-on-close, and lock sharing through hard links.
import Testing
@testable import Swiftix

@Suite("Advisory file locking (flock)")
struct FlockTests {

    @Test func exclusiveLockSucceeds() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var locked = false; var unlocked = false }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd = ctx.open("/lockfile", create: true)!
            box.locked = ctx.flock(fd, operation: .exclusive)
            box.unlocked = ctx.flock(fd, operation: .unlock)
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.locked)
        #expect(box.unlocked)
    }

    @Test func sharedLockAllowsMultipleHolders() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var lock1 = false; var lock2 = false }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd1 = ctx.open("/lockfile", create: true)!
            let fd2 = ctx.open("/lockfile")!
            box.lock1 = ctx.flock(fd1, operation: .shared)
            box.lock2 = ctx.flock(fd2, operation: .shared)
            ctx.close(fd1)
            ctx.close(fd2)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.lock1)
        #expect(box.lock2)
    }

    @Test func exclusiveLockBlockedByShared() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var sharedOk = false; var exclusiveFailed = false }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd1 = ctx.open("/lockfile", create: true)!
            let fd2 = ctx.open("/lockfile")!
            box.sharedOk = ctx.flock(fd1, operation: .shared)
            box.exclusiveFailed = !ctx.flock(fd2, operation: .exclusive)
            ctx.close(fd1)
            ctx.close(fd2)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.sharedOk)
        #expect(box.exclusiveFailed)
    }

    @Test func exclusiveLockBlockedByExclusive() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var first = false; var secondFailed = false }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd1 = ctx.open("/lockfile", create: true)!
            let fd2 = ctx.open("/lockfile")!
            box.first = ctx.flock(fd1, operation: .exclusive)
            box.secondFailed = !ctx.flock(fd2, operation: .exclusive)
            ctx.close(fd1)
            ctx.close(fd2)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.first)
        #expect(box.secondFailed)
    }

    @Test func closingFDReleasesLock() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var relocked = false }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd1 = ctx.open("/lockfile", create: true)!
            _ = ctx.flock(fd1, operation: .exclusive)
            ctx.close(fd1)  // should release the lock

            let fd2 = ctx.open("/lockfile")!
            box.relocked = ctx.flock(fd2, operation: .exclusive)
            ctx.close(fd2)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.relocked)
    }

    @Test func hardLinkedPathsShareLockState() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var blockedByLink = false }
        let box = Box()

        kernel.spawn("test") { ctx in
            let fd1 = ctx.open("/file", create: true)!
            _ = ctx.link("/file", at: "/alias")
            _ = ctx.flock(fd1, operation: .exclusive)

            // Open through the hard link — same inode, same lock.
            let fd2 = ctx.open("/alias")!
            box.blockedByLink = !ctx.flock(fd2, operation: .exclusive)
            ctx.close(fd1)
            ctx.close(fd2)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.blockedByLink)
    }
}
