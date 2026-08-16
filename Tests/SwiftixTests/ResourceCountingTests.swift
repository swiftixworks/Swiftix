/// Tests for system-wide resource counting (Kernel.snapshotResources and
/// /proc/resources synthetic file).
import Testing
@testable import Swiftix

@Suite("Resource counting")
struct ResourceCountingTests {

    @Test func snapshotReflectsLiveState() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.netns.stack.configure(.addInterface(NetworkInterfaceConfiguration(
            address: IPv4Address(10, 0, 0, 1), mac: MACAddress("02:00:00:00:00:01")!)))

        // Before any processes.
        let before = kernel.snapshotResources()
        #expect(before.processes == 0)
        #expect(before.networkInterfaces == 1)
        #expect(before.vfsNodeCount > 0)   // at least root + /proc tree
        #expect(before.vfsFileBytes == 0)
        #expect(before.runtimeMemoryBytes == 0)
        #expect(before.runtimeMemoryLimitBytes == Kernel.defaultRuntimeMemoryLimitBytes)

        // Spawn a process that opens a file and then blocks on a pipe read (stays alive).
        kernel.spawn("test") { ctx in
            _ = ctx.open("/testfile", create: true)
            let (readEnd, _) = ctx.pipe()
            // Block on the pipe read — keeps the process alive.
            ctx.read(readEnd) { _ in ctx.exit(0) }
        }
        loop.runUntilIdle()

        let during = kernel.snapshotResources()
        #expect(during.processes >= 1)
        #expect(during.openFileDescriptors >= 1)
        // The file we created adds a VFS node.
        #expect(during.vfsNodeCount > before.vfsNodeCount)
    }

    @Test func runtimeMemoryReportsAreAtomicBoundedAndReleasedAtExit() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop, runtimeMemoryLimitBytes: 1_000)
        final class Capture {
            var firstAccepted = false
            var rejected = false
        }
        let capture = Capture()

        let first = kernel.spawn("first") { ctx in
            capture.firstAccepted = ctx.reportRuntimeMemory(
                bytes: 400, limitBytes: 800, heapCells: 4, garbageCollections: 1)
            ctx.sleep(10) { ctx.exit(0) }
        }
        kernel.spawn("second") { ctx in
            capture.rejected = !ctx.reportRuntimeMemory(
                bytes: 700, limitBytes: 800, heapCells: 7, garbageCollections: 0)
            ctx.sleep(10) { ctx.exit(0) }
        }
        loop.advance(by: 0)

        #expect(capture.firstAccepted)
        #expect(capture.rejected)
        #expect(kernel.snapshotResources().runtimeMemoryBytes == 400)
        let firstSnapshot = kernel.snapshotProcesses().first { $0.pid == first }
        #expect(firstSnapshot?.runtimeMemoryBytes == 400)
        #expect(firstSnapshot?.runtimeMemoryLimitBytes == 800)
        #expect(firstSnapshot?.runtimeHeapCells == 4)
        #expect(firstSnapshot?.runtimeGarbageCollections == 1)

        kernel.kill(first, signal: Signal.sigkill.rawValue)
        loop.runUntilIdle()
        #expect(kernel.snapshotResources().runtimeMemoryBytes == 0)
    }

    @Test func procResourcesFileIsReadable() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.netns.stack.configure(.addInterface(NetworkInterfaceConfiguration(
            address: IPv4Address(10, 0, 0, 1), mac: MACAddress("02:00:00:00:00:01")!)))

        final class Result { var output = "" }
        let result = Result()

        kernel.spawn("test") { ctx in
            if let fd = ctx.open("/proc/resources") {
                let bytes = ctx.read(fd, max: 65535)
                result.output = String(decoding: bytes, as: UTF8.self)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.output.contains("processes="))
        #expect(result.output.contains("fds="))
        #expect(result.output.contains("tcp="))
        #expect(result.output.contains("interfaces="))
        #expect(result.output.contains("vnodes="))
        #expect(result.output.contains("vfs_bytes="))
        #expect(result.output.contains("runtime_memory="))
    }

    @Test func procMeminfoSeparatesManagedRuntimeMemoryFromVFSStorage() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop, runtimeMemoryLimitBytes: 2 * 1_024 * 1_024)
        final class Capture { var output = "" }
        let capture = Capture()

        kernel.spawn("reporter") { ctx in
            _ = ctx.reportRuntimeMemory(
                bytes: 512 * 1_024,
                limitBytes: 1 * 1_024 * 1_024,
                heapCells: 32,
                garbageCollections: 2)
            if let fd = ctx.open("/data", create: true) {
                _ = ctx.write(fd, Array(repeating: 1, count: 2 * 1_024))
                ctx.close(fd)
            }
            if let fd = ctx.open("/proc/meminfo") {
                capture.output = String(decoding: ctx.read(fd, max: 65_535), as: UTF8.self)
                ctx.close(fd)
            }
            ctx.sleep(10) { ctx.exit(0) }
        }
        loop.advance(by: 0)

        #expect(capture.output.contains("MemTotal:       2048 kB"))
        #expect(capture.output.contains("RuntimeHeap:    512 kB"))
        #expect(capture.output.contains("VFSFileBytes:   2048 B"))
        #expect(capture.output.contains("MemModel:       managed-runtime"))
    }

    @Test func tcpConnectionCountReflectsActiveConnections() {
        let loop = EventLoop()
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)

        let ipB = IPv4Address(10, 0, 0, 2)
        kernelA.netns.stack.configure(.addInterface(NetworkInterfaceConfiguration(
            address: IPv4Address(10, 0, 0, 1), mac: MACAddress("02:00:00:00:00:0a")!)))
        kernelB.netns.stack.configure(.addInterface(NetworkInterfaceConfiguration(
            address: ipB, mac: MACAddress("02:00:00:00:00:0b")!)))
        let ifA = kernelA.netns.stack.interface(at: 0)!
        let ifB = kernelB.netns.stack.interface(at: 0)!
        ifA.onEgress = { [weak kernelB, weak ifB] frame in
            guard let kernelB, let ifB else { return }
            loop.schedule(after: 0.005) { kernelB.netns.stack.receive(frame, on: ifB) }
        }
        ifB.onEgress = { [weak kernelA, weak ifA] frame in
            guard let kernelA, let ifA else { return }
            loop.schedule(after: 0.005) { kernelA.netns.stack.receive(frame, on: ifA) }
        }

        _ = kernelB.netns.stack.listen(port: 80)
        _ = kernelA.netns.stack.connect(localPort: 5000, to: ipB, remotePort: 80)
        loop.advance(by: 0.5)

        // Client has 1 TCP connection.
        let snap = kernelA.snapshotResources()
        #expect(snap.tcpConnections == 1)
    }
}
