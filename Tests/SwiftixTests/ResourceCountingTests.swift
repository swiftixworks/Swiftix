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
