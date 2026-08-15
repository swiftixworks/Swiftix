/// Tests for the POSIX-style `select` API built on top of the existing poll
/// infrastructure. Validates non-blocking and blocking select over pipes and TCP.
import Testing
@testable import Swiftix

@Suite("select")
struct SelectTests {

    /// Non-blocking select on a pipe with data returns the read fd as readable.
    @Test func selectReturnsReadablePipeWithData() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var selected: ProcessContext.SelectResult? }
        let result = Result()

        kernel.spawn("test") { ctx in
            let (readEnd, writeEnd) = ctx.pipe()
            ctx.write(writeEnd, Array("data".utf8))

            result.selected = ctx.select(readFDs: [readEnd])
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.selected != nil)
        #expect(result.selected!.readableFDs.count == 1)
        #expect(result.selected!.writableFDs.isEmpty)
    }

    /// Non-blocking select on an empty pipe returns nothing (not ready).
    @Test func selectReturnsEmptyForEmptyPipe() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var selected: ProcessContext.SelectResult? }
        let result = Result()

        kernel.spawn("test") { ctx in
            let (readEnd, _) = ctx.pipe()
            result.selected = ctx.select(readFDs: [readEnd])
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.selected != nil)
        #expect(result.selected!.count == 0)
    }

    /// Blocking select wakes when data arrives on a pipe.
    @Test func blockingSelectWakesOnPipeData() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var woke = false }
        let result = Result()

        kernel.spawn("test") { ctx in
            let (readEnd, writeEnd) = ctx.pipe()

            // Schedule a write after a delay.
            ctx.spawn("writer", args: ["writer"]) { (child: ProcessContext) async in
                try? await child.sleep(0.1)
                child.write(writeEnd, Array("wake".utf8))
                child.exit(0)
            }

            // Blocking select should wait then wake.
            ctx.select(readFDs: [readEnd], timeout: 1.0) { selectResult in
                result.woke = selectResult.readableFDs.contains(readEnd)
                ctx.exit(0)
            }
        }
        loop.advance(by: 0.5)

        #expect(result.woke == true)
    }

    /// Async select works on a TCP connection.
    @Test func asyncSelectOnTCPSocket() {
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

        final class Result { var readable = false }
        let result = Result()

        kernelA.spawn("client") { (ctx: ProcessContext) async in
            guard let fd = ctx.tcpSocket() else { ctx.exit(1); return }
            do {
                try await ctx.tcpConnect(fd, to: ipB, port: 80)
            } catch { ctx.exit(1); return }

            // After connect, the socket should be writable (send buffer free).
            let selectResult = try? await ctx.select(writeFDs: [fd], timeout: 1.0)
            if let sr = selectResult, sr.writableFDs.contains(fd) {
                result.readable = true
            }
            ctx.exit(0)
        }

        loop.advance(by: 2.0)
        #expect(result.readable == true)
    }
}
