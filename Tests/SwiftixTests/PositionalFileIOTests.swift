/// Invariants for pager-friendly positional regular-file I/O.
import Testing
@testable import Swiftix

@Suite("Positional file I/O")
struct PositionalFileIOTests {
    @Test func preadAndPwriteDoNotChangeSharedOffset() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var positionalRead: [UInt8] = []
            var ordinaryRead: [UInt8] = []
            var finalContents: [UInt8] = []
            var error: SyscallError?
        }
        let capture = Capture()

        kernel.spawn("pager") { ctx in
            do {
                let fd = try ctx.openFile("/tmp/pages", create: true)
                _ = try ctx.writeFile(fd, Array("abcdef".utf8))
                _ = ctx.seek(fd, to: 2, whence: 0)

                capture.positionalRead = try ctx.pread(fd, max: 2, offset: 4)
                _ = try ctx.pwrite(fd, Array("ZZ".utf8), offset: 0)
                capture.ordinaryRead = try ctx.readFile(fd, max: 2)

                _ = ctx.seek(fd, to: 0, whence: 0)
                capture.finalContents = try ctx.readFile(fd, max: 16)
            } catch let error as SyscallError {
                capture.error = error
            } catch {
                capture.error = .inputOutput
            }
        }
        loop.runUntilIdle()

        #expect(capture.error == nil)
        #expect(String(decoding: capture.positionalRead, as: UTF8.self) == "ef")
        #expect(String(decoding: capture.ordinaryRead, as: UTF8.self) == "cd")
        #expect(String(decoding: capture.finalContents, as: UTF8.self) == "ZZcdef")
    }

    @Test func positionalIORejectsInvalidArgumentsAndDescriptorTypes() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var negativeOffset: SyscallError?
            var nonFileDescriptor: SyscallError?
        }
        let capture = Capture()

        kernel.spawn("pager-errors") { ctx in
            do {
                let fd = try ctx.openFile("/tmp/page", create: true)
                _ = try ctx.pread(fd, max: 1, offset: -1)
            } catch let error as SyscallError {
                capture.negativeOffset = error
            } catch {}

            let pipe = ctx.pipe()
            do {
                _ = try ctx.pwrite(pipe.write, [1], offset: 0)
            } catch let error as SyscallError {
                capture.nonFileDescriptor = error
            } catch {}
        }
        loop.runUntilIdle()

        #expect(capture.negativeOffset == .invalidArgument)
        #expect(capture.nonFileDescriptor == .badFileDescriptor)
    }
}
