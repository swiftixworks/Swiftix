/// Tests for injectable asynchronous block volumes and durability barriers.
import Testing
@testable import Swiftix

@Suite("Block volumes")
struct BlockVolumeTests {
    /// A platform-adapter stand-in: every operation completes on a later logical
    /// event-loop turn, proving the guest parks instead of requiring synchronous
    /// access to the backing store.
    private final class DeferredVolume: BlockVolume {
        let sectorSize = 8
        let sectorCount = 4
        var capacity: Int { sectorSize * sectorCount }

        private let loop: EventLoop
        private var sectors = [[UInt8]](repeating: [UInt8](repeating: 0, count: 8), count: 4)
        private(set) var flushCount = 0

        init(loop: EventLoop) {
            self.loop = loop
        }

        func read(
            sector: Int,
            completion: @escaping (Result<[UInt8], BlockVolumeError>) -> Void
        ) {
            loop.schedule(after: 0.25) { [self] in
                guard sectors.indices.contains(sector) else {
                    completion(.failure(.outOfRange))
                    return
                }
                completion(.success(sectors[sector]))
            }
        }

        func write(
            sector: Int,
            data: [UInt8],
            completion: @escaping (Result<Void, BlockVolumeError>) -> Void
        ) {
            loop.schedule(after: 0.25) { [self] in
                guard sectors.indices.contains(sector) else {
                    completion(.failure(.outOfRange))
                    return
                }
                guard data.count == sectorSize else {
                    completion(.failure(.invalidTransferSize))
                    return
                }
                sectors[sector] = data
                completion(.success(()))
            }
        }

        func flush(
            completion: @escaping (Result<Void, BlockVolumeError>) -> Void
        ) {
            loop.schedule(after: 0.25) { [self] in
                flushCount += 1
                completion(.success(()))
            }
        }
    }

    private final class Capture: @unchecked Sendable {
        var bytes: [UInt8] = []
        var info: BlockVolumeInfo?
        var error: SyscallError?
        var done = false
    }

    private func drive(_ loop: EventLoop, until done: @Sendable () -> Bool) async {
        var steps = 0
        while !done(), steps < 10_000 {
            _ = loop.runNext()
            await Task.yield()
            steps += 1
        }
    }

    @Test func injectedVolumeCompletesWriteFlushReadAsynchronously() async throws {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let volume = DeferredVolume(loop: loop)
        try kernel.attachBlockVolume(volume, named: "data")
        let capture = Capture()
        let payload = Array("database".utf8)

        kernel.spawn("volume-client") { ctx in
            do {
                capture.info = ctx.blockVolumeInfo("data")
                try await ctx.writeBlock(device: "data", sector: 2, data: payload)
                try await ctx.flushBlockVolume("data")
                capture.bytes = try await ctx.readBlock(device: "data", sector: 2)
            } catch let error as SyscallError {
                capture.error = error
            } catch {
                capture.error = .inputOutput
            }
            capture.done = true
        }

        await drive(loop, until: { capture.done })

        #expect(capture.done)
        #expect(capture.error == nil)
        #expect(capture.bytes == payload)
        #expect(volume.flushCount == 1)
        #expect(kernel.blockVolumeNames == ["data"])
        #expect(capture.info == BlockVolumeInfo(name: "data", sectorSize: 8,
                                               sectorCount: 4, capacity: 32))
    }

    @Test func volumeErrorsMapToStableSyscallErrors() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let capture = Capture()

        kernel.spawn("missing-volume") { ctx in
            do {
                _ = try await ctx.readBlock(device: "missing", sector: 0)
            } catch let error as SyscallError {
                capture.error = error
            } catch {
                capture.error = .inputOutput
            }
            capture.done = true
        }

        await drive(loop, until: { capture.done })

        #expect(capture.done)
        #expect(capture.error == .noSuchDevice)
    }

    @Test func attachmentRejectsDuplicateAndInvalidGeometry() throws {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let volume = DeferredVolume(loop: loop)

        try kernel.attachBlockVolume(volume, named: "data")
        #expect(throws: SyscallError.fileExists) {
            try kernel.attachBlockVolume(volume, named: "data")
        }
        #expect(throws: SyscallError.invalidArgument) {
            try kernel.attachBlockVolume(volume, named: "bad/name")
        }
    }
}
