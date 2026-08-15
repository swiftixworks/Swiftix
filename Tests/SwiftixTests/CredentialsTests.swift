/// Tests for uid/gid credentials and chown/chmod (permissive-first: stored but
/// not enforced for access checks).
import Testing
@testable import Swiftix

@Suite("Process credentials & file ownership")
struct CredentialsTests {

    @Test func defaultProcessCredentialsAreRoot() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var uid: UInt32 = 99; var gid: UInt32 = 99 }
        let result = Result()

        kernel.spawn("test") { ctx in
            result.uid = ctx.getuid()
            result.gid = ctx.getgid()
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.uid == 0)
        #expect(result.gid == 0)
    }

    @Test func setuidAndSetgidChangeCredentials() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var uid: UInt32 = 0; var gid: UInt32 = 0 }
        let result = Result()

        kernel.spawn("test") { ctx in
            ctx.setuid(1000)
            ctx.setgid(1000)
            result.uid = ctx.getuid()
            result.gid = ctx.getgid()
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.uid == 1000)
        #expect(result.gid == 1000)
    }

    @Test func chownChangesFileOwnership() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var stat: FileStat? }
        let result = Result()

        kernel.spawn("test") { ctx in
            _ = ctx.open("/testfile", create: true)
            _ = ctx.chown("/testfile", uid: 500, gid: 500)
            result.stat = ctx.stat("/testfile")
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.stat?.uid == 500)
        #expect(result.stat?.gid == 500)
    }

    @Test func chmodChangesFileMode() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var stat: FileStat? }
        let result = Result()

        kernel.spawn("test") { ctx in
            _ = ctx.open("/testfile", create: true)
            _ = ctx.chmod("/testfile", mode: [.ownerRead, .ownerWrite, .ownerExecute])
            result.stat = ctx.stat("/testfile")
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.stat?.mode == [.ownerRead, .ownerWrite, .ownerExecute])
    }

    @Test func statReportsUidGid() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var stat: FileStat? }
        let result = Result()

        kernel.spawn("test") { ctx in
            _ = ctx.mkdir("/mydir")
            result.stat = ctx.stat("/mydir")
            ctx.exit(0)
        }
        loop.runUntilIdle()

        // Default ownership is root (0:0).
        #expect(result.stat?.uid == 0)
        #expect(result.stat?.gid == 0)
        #expect(result.stat?.isDirectory == true)
    }
}
