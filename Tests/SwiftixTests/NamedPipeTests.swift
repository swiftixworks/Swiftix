/// Named pipes (FIFO): mkfifo creates a filesystem-visible IPC channel that
/// two unrelated processes can open by path and communicate through.
import Testing
@testable import Swiftix

@Suite("Named pipes (mkfifo)")
struct NamedPipeTests {

    @Test func mkfifoCreatesAndStatReportsFifo() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box {
            var created = false
            var type: FileType?
        }
        let box = Box()

        kernel.spawn("test") { ctx in
            box.created = ctx.mkfifo("/pipe")
            box.type = ctx.stat("/pipe")?.type
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.created)
        #expect(box.type == .fifo)
    }

    @Test func fifoIPC() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box { var received = "" }
        let box = Box()

        kernel.spawn("setup") { ctx in
            _ = ctx.mkfifo("/channel")

            // Writer process.
            ctx.spawn("writer") { writer in
                let fd = writer.open("/channel", access: .writeOnly)!
                writer.write(fd, Array("message".utf8))
                writer.close(fd)
                writer.exit(0)
            }

            // Reader process.
            ctx.spawn("reader") { reader in
                let fd = reader.open("/channel", access: .readOnly)!
                box.received = String(decoding: reader.read(fd, max: 99), as: UTF8.self)
                reader.close(fd)
                reader.exit(0)
            }

            ctx.wait { _ in ctx.exit(0) }
        }
        loop.runUntilIdle()

        #expect(box.received == "message")
    }

    @Test func fifoAlreadyExistsFails() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Box {
            var first = false
            var second = false
        }
        let box = Box()

        kernel.spawn("test") { ctx in
            box.first = ctx.mkfifo("/pipe")
            box.second = ctx.mkfifo("/pipe")
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.first)
        #expect(!box.second)
    }
}
