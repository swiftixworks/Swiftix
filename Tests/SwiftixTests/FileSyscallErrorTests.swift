import Testing
@testable import Swiftix

/// Throwing file/descriptor syscalls (`openFile`/`readFile`/`writeFile`/`closeFile`)
/// surface a typed `SyscallError` for each failure cause and keep EOF distinct
/// from an error. Validates: Requirements 4.3, 4.4, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6.
@Suite("File and descriptor error reporting")
struct FileSyscallErrorTests {

    /// Opening a path that does not resolve, without `create`, throws
    /// `.noSuchFileOrDirectory` (R5.1).
    @Test func openMissingPathThrowsNoSuchFileOrDirectory() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var error: SyscallError? }
        let captured = Capture()

        kernel.spawn("open-missing") { ctx in
            do {
                _ = try ctx.openFile("/tmp/does-not-exist")
            } catch let error as SyscallError {
                captured.error = error
            } catch {}
        }
        loop.runUntilIdle()

        #expect(captured.error == .noSuchFileOrDirectory)
    }

    /// Opening a directory as a regular file throws `.isADirectory` (R5.2).
    @Test func openDirectoryAsFileThrowsIsADirectory() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var error: SyscallError? }
        let captured = Capture()

        // `/proc` is a directory created by the kernel's procfs mount.
        kernel.spawn("open-dir") { ctx in
            do {
                _ = try ctx.openFile("/proc")
            } catch let error as SyscallError {
                captured.error = error
            } catch {}
        }
        loop.runUntilIdle()

        #expect(captured.error == .isADirectory)
    }

    /// A directory target reports `.isADirectory` even when `create` is requested,
    /// rather than being mistaken for a creation failure (R5.2).
    @Test func openDirectoryWithCreateStillThrowsIsADirectory() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var error: SyscallError? }
        let captured = Capture()

        kernel.spawn("open-dir-create") { ctx in
            do {
                _ = try ctx.openFile("/proc", create: true)
            } catch let error as SyscallError {
                captured.error = error
            } catch {}
        }
        loop.runUntilIdle()

        #expect(captured.error == .isADirectory)
    }

    /// `openFile(create:)` succeeds for a new path and returns a usable descriptor
    /// that round-trips bytes through the throwing read/write variants (R4.4).
    @Test func openCreateReadWriteRoundTrips() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var bytes: [UInt8] = []; var threw = false }
        let captured = Capture()

        kernel.spawn("rw") { ctx in
            do {
                let fd = try ctx.openFile("/tmp/msg", create: true)
                _ = try ctx.writeFile(fd, Array("hello".utf8))
                try ctx.closeFile(fd)
                let rfd = try ctx.openFile("/tmp/msg")
                captured.bytes = try ctx.readFile(rfd, max: 64)
                try ctx.closeFile(rfd)
            } catch {
                captured.threw = true
            }
        }
        loop.runUntilIdle()

        #expect(!captured.threw)
        #expect(String(decoding: captured.bytes, as: UTF8.self) == "hello")
    }

    /// Reading an unallocated descriptor throws `.badFileDescriptor` (R5.3).
    @Test func readBadDescriptorThrows() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var error: SyscallError? }
        let captured = Capture()

        kernel.spawn("read-bad-fd") { ctx in
            do {
                _ = try ctx.readFile(99, max: 16)
            } catch let error as SyscallError {
                captured.error = error
            } catch {}
        }
        loop.runUntilIdle()

        #expect(captured.error == .badFileDescriptor)
    }

    /// Writing an unallocated descriptor throws `.badFileDescriptor` (R5.3).
    @Test func writeBadDescriptorThrows() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var error: SyscallError? }
        let captured = Capture()

        kernel.spawn("write-bad-fd") { ctx in
            do {
                _ = try ctx.writeFile(99, Array("x".utf8))
            } catch let error as SyscallError {
                captured.error = error
            } catch {}
        }
        loop.runUntilIdle()

        #expect(captured.error == .badFileDescriptor)
    }

    /// Closing an unallocated descriptor throws `.badFileDescriptor` (R5.3).
    @Test func closeBadDescriptorThrows() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var error: SyscallError? }
        let captured = Capture()

        kernel.spawn("close-bad-fd") { ctx in
            do {
                try ctx.closeFile(99)
            } catch let error as SyscallError {
                captured.error = error
            } catch {}
        }
        loop.runUntilIdle()

        #expect(captured.error == .badFileDescriptor)
    }

    /// A valid descriptor at end of stream returns an empty byte sequence as a
    /// SUCCESS rather than throwing — EOF is distinct from `.badFileDescriptor`
    /// and from `.wouldBlock` (R5.4, R5.6).
    @Test func validDescriptorAtEndOfStreamReturnsEmptySuccessfully() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var first: [UInt8] = []
            var atEOF: [UInt8]?
            var threw = false
        }
        let captured = Capture()

        kernel.spawn("eof") { ctx in
            do {
                let fd = try ctx.openFile("/tmp/eof", create: true)
                _ = try ctx.writeFile(fd, Array("hi".utf8))
                try ctx.closeFile(fd)

                let rfd = try ctx.openFile("/tmp/eof")
                captured.first = try ctx.readFile(rfd, max: 64)   // consumes all bytes
                // A second read on the same valid fd is at EOF: empty success.
                captured.atEOF = try ctx.readFile(rfd, max: 64)
                try ctx.closeFile(rfd)
            } catch {
                captured.threw = true
            }
        }
        loop.runUntilIdle()

        #expect(!captured.threw)
        #expect(String(decoding: captured.first, as: UTF8.self) == "hi")
        #expect(captured.atEOF == [])   // empty, and crucially NOT a thrown error
    }
}
