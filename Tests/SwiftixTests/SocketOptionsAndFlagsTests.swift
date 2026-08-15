import Testing
@testable import Swiftix

@Suite("fd flags + socket options")
struct SocketOptionsAndFlagsTests {

    @Test func nonblockingFlagSurvivesDupAndSpawnAndReadFileWouldBlock() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var parentFlags: FileStatusFlags?
            var dupFlags: FileStatusFlags?
            var childFlags: FileStatusFlags?
            var readError: SyscallError?
            var eof: [UInt8]?
        }
        let captured = Capture()

        kernel.spawn("parent") { ctx in
            let pipe = ctx.pipe()
            ctx.setNonBlocking(pipe.read)
            captured.parentFlags = ctx.fileStatusFlags(pipe.read)

            let duplicate = ctx.dup(pipe.read)!
            captured.dupFlags = ctx.fileStatusFlags(duplicate)

            do {
                _ = try ctx.readFile(pipe.read, max: 1)
            } catch let error as SyscallError {
                captured.readError = error
            } catch {}

            ctx.close(pipe.write)
            captured.eof = try? ctx.readFile(pipe.read, max: 1)

            ctx.spawn("child") { child in
                captured.childFlags = child.fileStatusFlags(pipe.read)
            }
        }
        loop.runUntilIdle()

        #expect(captured.parentFlags?.contains(.nonBlocking) == true)
        #expect(captured.dupFlags?.contains(.nonBlocking) == true)
        #expect(captured.childFlags?.contains(.nonBlocking) == true)
        #expect(captured.readError == .wouldBlock)
        #expect(captured.eof == [])
    }

    @Test func socketOptionsRoundTripAndRejectNonSockets() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var udpBefore = true
            var udpAfter = false
            var tcpAfter = false
            var nonSocketError: SyscallError?
        }
        let captured = Capture()

        kernel.spawn("sockopt") { ctx in
            let udp = ctx.socket()!
            let tcp = ctx.tcpSocket()!
            let file = ctx.open("/tmp/file", create: true)!

            captured.udpBefore = (try? ctx.socketOption(udp, .reuseAddress)) ?? true
            try? ctx.setSocketOption(udp, .reuseAddress, enabled: true)
            try? ctx.setSocketOption(tcp, .reuseAddress, enabled: true)
            captured.udpAfter = (try? ctx.socketOption(udp, .reuseAddress)) ?? false
            captured.tcpAfter = (try? ctx.socketOption(tcp, .reuseAddress)) ?? false

            do {
                try ctx.setSocketOption(file, .reuseAddress, enabled: true)
            } catch let error as SyscallError {
                captured.nonSocketError = error
            } catch {}
        }
        loop.runUntilIdle()

        #expect(captured.udpBefore == false)
        #expect(captured.udpAfter == true)
        #expect(captured.tcpAfter == true)
        #expect(captured.nonSocketError == .badFileDescriptor)
    }

    @Test func asyncUDPRecvHonorsNonblockingFlag() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture: @unchecked Sendable {
            var error: SyscallError?
            var done = false
        }
        let captured = Capture()

        kernel.spawn("udp-nonblock") { ctx in
            let fd = ctx.socket()!
            ctx.bind(fd, address: nil, port: 7000)
            ctx.setNonBlocking(fd)
            do {
                _ = try await ctx.recvfrom(fd)
            } catch let error as SyscallError {
                captured.error = error
            } catch {}
            captured.done = true
        }

        await drive(loop, until: { captured.done })

        #expect(captured.error == .wouldBlock)
    }

    @Test func asyncTCPAcceptHonorsNonblockingFlag() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture: @unchecked Sendable {
            var error: SyscallError?
            var done = false
        }
        let captured = Capture()

        kernel.spawn("tcp-listen-nonblock") { ctx in
            let fd = ctx.tcpSocket()!
            ctx.tcpListen(fd, port: 8080)
            ctx.setNonBlocking(fd)
            do {
                _ = try await ctx.tcpAccept(fd)
            } catch let error as SyscallError {
                captured.error = error
            } catch {}
            captured.done = true
        }

        await drive(loop, until: { captured.done })

        #expect(captured.error == .wouldBlock)
    }

    private func drive(_ loop: EventLoop, until done: @Sendable () -> Bool, max: Int = 200_000) async {
        var pumps = 0
        while !done() && pumps < max {
            loop.advance(by: 0)
            loop.runNext()
            await Task.yield()
            pumps += 1
        }
    }
}
