import Testing
@testable import Swiftix

@Suite("Linux-core kernel substrate")
struct KernelTests {

    /// A file written by one process persists in the VFS and is readable by a
    /// second, independent process — proving the VFS + fd table + open/read/write
    /// syscall surface work and that state lives in the kernel, not the process.
    @Test func fileWrittenByOneProcessIsReadableByAnother() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var bytes: [UInt8] = [] }
        let captured = Capture()

        kernel.spawn("writer") { ctx in
            guard let fd = ctx.open("/tmp/msg", create: true) else { return }
            ctx.write(fd, Array("hello".utf8))
            ctx.close(fd)
        }
        kernel.spawn("reader") { ctx in
            guard let fd = ctx.open("/tmp/msg") else { return }
            captured.bytes = ctx.read(fd, max: 64)
            ctx.close(fd)
        }
        loop.runUntilIdle()

        #expect(String(decoding: captured.bytes, as: UTF8.self) == "hello")
    }

    /// A pipe round-trips bytes through file descriptors within a process.
    @Test func pipeRoundTripsThroughDescriptors() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var bytes: [UInt8] = [] }
        let captured = Capture()

        kernel.spawn("pipe-user") { ctx in
            let ends = ctx.pipe()
            ctx.write(ends.write, Array("ping".utf8))
            captured.bytes = ctx.read(ends.read, max: 64)
        }
        loop.runUntilIdle()

        #expect(String(decoding: captured.bytes, as: UTF8.self) == "ping")
    }

    /// Processes run on the shared event loop in the order they were spawned.
    @Test func processesRunInSpawnOrder() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var order: [String] = [] }
        let captured = Capture()

        kernel.spawn("first") { _ in captured.order.append("first") }
        kernel.spawn("second") { _ in captured.order.append("second") }
        kernel.spawn("third") { _ in captured.order.append("third") }
        loop.runUntilIdle()

        #expect(captured.order == ["first", "second", "third"])
        // Every process ran to completion and was reaped.
        #expect(kernel.processCount == 0)
    }

    @Test func processGroupAndSessionIdentityCanBeAssigned() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var parentPID: PID = -1
            var parentGroup: PID = -1
            var parentSession: PID = -1
            var childOne: PID = -1
            var childTwo: PID = -1
            var assignedGroup: PID?
            var childOneGroup: PID = -1
            var childTwoGroup: PID = -1
            var childOneSession: PID = -1
            var childTwoSession: PID = -1
        }
        let captured = Capture()

        kernel.spawn("parent") { ctx in
            captured.parentPID = ctx.getpid()
            captured.parentGroup = ctx.getpgrp()
            captured.parentSession = ctx.getsid()
            captured.childOne = ctx.spawn("one") { child in
                captured.childOneGroup = child.getpgrp()
                captured.childOneSession = child.getsid()
                child.sleep(10) { child.exit(0) }
            }
            captured.childTwo = ctx.spawn("two") { child in
                captured.childTwoGroup = child.getpgrp()
                captured.childTwoSession = child.getsid()
                child.sleep(10) { child.exit(0) }
            }
            captured.assignedGroup = ctx.setProcessGroup([captured.childOne, captured.childTwo])
            ctx.wait { _ in }
        }

        loop.advance(by: 0)

        #expect(captured.parentGroup == captured.parentPID)
        #expect(captured.parentSession == captured.parentPID)
        #expect(captured.assignedGroup == captured.childOne)
        #expect(captured.childOneGroup == captured.assignedGroup)
        #expect(captured.childTwoGroup == captured.assignedGroup)
        #expect(captured.childOneSession == captured.parentSession)
        #expect(captured.childTwoSession == captured.parentSession)
    }

    @Test func shutdownCancelsFutureProcessWorkAndReapsResources() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Capture { var resumed = false }
        let capture = Capture()

        kernel.spawn("long-sleeper") { context in
            context.sleep(3_600) { capture.resumed = true }
        }
        loop.runUntilIdle()

        #expect(kernel.processCount == 1)
        #expect(loop.pendingCount == 1)

        kernel.shutdown()

        #expect(kernel.isShutdown)
        #expect(kernel.processCount == 0)
        #expect(loop.pendingCount == 0)
        #expect(!loop.hasPendingWork)

        loop.advance(by: 7_200)
        #expect(!capture.resumed)
        #expect(loop.pendingCount == 0)
    }

    @Test func pauseFreezesKernelTimerRemainingDuration() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Capture { var resumedAt: Double? }
        let capture = Capture()

        kernel.spawn("sleeper") { context in
            context.sleep(5) { capture.resumedAt = loop.now }
        }
        loop.runUntilIdle()
        kernel.pause()

        #expect(kernel.isPaused)
        #expect(loop.pendingCount == 0)
        loop.advance(by: 100)
        #expect(capture.resumedAt == nil)

        kernel.resume()
        #expect(!kernel.isPaused)
        #expect(loop.nextDeadline == 105)
        loop.advance(by: 4.999)
        #expect(capture.resumedAt == nil)
        loop.advance(by: 0.001)

        #expect(capture.resumedAt == 105)
        #expect(kernel.processCount == 0)
    }
}
