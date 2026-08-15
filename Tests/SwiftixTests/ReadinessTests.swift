import Testing
@testable import Swiftix

@Suite("fd I/O readiness")
struct ReadinessTests {

    @Test func regularFilesAndPipesReportReadiness() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var regular: IOReadiness?
            var pipeReadEmpty: IOReadiness?
            var pipeWriteOpen: IOReadiness?
            var pipeReadData: IOReadiness?
            var pipeReadEOF: IOReadiness?
            var pipeWriteNoReader: IOReadiness?
            var pipeWriteFD: Int?
            var pollReady: [PollResult] = []
        }
        let captured = Capture()

        kernel.spawn("ready") { ctx in
            let file = ctx.open("/tmp/data", create: true)!
            captured.regular = ctx.readiness(file)

            let pipe = ctx.pipe()
            captured.pipeWriteFD = pipe.write
            captured.pipeReadEmpty = ctx.readiness(pipe.read)
            captured.pipeWriteOpen = ctx.readiness(pipe.write)
            captured.pollReady = ctx.poll([
                PollRequest(fd: pipe.read, interests: .readable),
                PollRequest(fd: pipe.write, interests: .writable),
                PollRequest(fd: 99, interests: .readable),
            ])

            ctx.write(pipe.write, Array("x".utf8))
            captured.pipeReadData = ctx.readiness(pipe.read)
            _ = ctx.read(pipe.read, max: 16)
            ctx.close(pipe.write)
            captured.pipeReadEOF = ctx.readiness(pipe.read)

            let second = ctx.pipe()
            ctx.close(second.read)
            captured.pipeWriteNoReader = ctx.readiness(second.write)
        }
        loop.runUntilIdle()

        #expect(captured.regular?.contains(.readable) == true)
        #expect(captured.regular?.contains(.writable) == true)
        #expect(captured.pipeReadEmpty?.isEmpty == true)
        #expect(captured.pipeWriteOpen == [.writable])
        #expect(captured.pipeReadData?.contains(.readable) == true)
        #expect(captured.pipeReadEOF?.contains(.readable) == true)
        #expect(captured.pipeReadEOF?.contains(.hangup) == true)
        #expect(captured.pipeWriteNoReader == [.hangup])
        #expect(captured.pollReady.contains(PollResult(fd: 99, readiness: .error)))
        #expect(captured.pollReady.contains { $0.fd == captured.pipeWriteFD && $0.readiness == .writable })
    }

    @Test func blockingPollWakesWhenPipeBecomesReadable() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var results: [PollResult] = []
            var bytes: [UInt8] = []
        }
        let captured = Capture()

        kernel.spawn("poll-pipe") { ctx in
            let pipe = ctx.pipe()
            ctx.spawn("pipe-writer") { child in
                child.sleep(0.01) {
                    child.write(pipe.write, Array("ready".utf8))
                }
            }
            ctx.poll([PollRequest(fd: pipe.read, interests: .readable)], timeout: 1.0) { results in
                captured.results = results
                captured.bytes = ctx.read(pipe.read, max: 64)
            }
        }

        loop.advance(by: 0.1)

        #expect(captured.results.count == 1)
        #expect(captured.results.first?.readiness.contains(.readable) == true)
        #expect(String(decoding: captured.bytes, as: UTF8.self) == "ready")
    }

    @Test func blockingPollTimeoutReturnsEmptySnapshot() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var results: [PollResult]? }
        let captured = Capture()

        kernel.spawn("poll-timeout") { ctx in
            let pipe = ctx.pipe()
            ctx.poll([PollRequest(fd: pipe.read, interests: .readable)], timeout: 0.01) { results in
                captured.results = results
            }
        }

        loop.advance(by: 0.1)

        #expect(captured.results == [])
    }

    @Test func blockingPollWithoutEventSourcesReturnsEmptySnapshot() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class SilentFile: FileObject {
            func read(max: Int) -> [UInt8] { [] }
            @discardableResult func write(_ bytes: [UInt8]) -> Int { 0 }
        }
        final class Capture { var results: [PollResult]? }
        let captured = Capture()

        kernel.spawn("poll-silent") { ctx in
            let fd = ctx.install(SilentFile())
            ctx.poll([PollRequest(fd: fd, interests: .readable)]) { results in
                captured.results = results
            }
        }
        loop.runUntilIdle()

        #expect(captured.results == [])
    }

    @Test func asyncPollWaitsForPipeReadiness() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture: @unchecked Sendable {
            var results: [PollResult] = []
            var bytes: [UInt8] = []
        }
        let captured = Capture()

        kernel.spawn("async-poll") { ctx in
            let pipe = ctx.pipe()
            ctx.spawn("async-pipe-writer") { child in
                child.sleep(0.01) {
                    child.write(pipe.write, Array("async".utf8))
                }
            }
            captured.results = (try? await ctx.poll([PollRequest(fd: pipe.read, interests: .readable)], timeout: 1.0)) ?? []
            captured.bytes = ctx.read(pipe.read, max: 64)
        }

        await drive(loop, until: { !captured.bytes.isEmpty })

        #expect(captured.results.first?.readiness.contains(.readable) == true)
        #expect(String(decoding: captured.bytes, as: UTF8.self) == "async")
    }

    @Test func ptySlaveReadinessTracksCommittedInput() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()

        final class Capture {
            var initial: IOReadiness?
            var afterInput: IOReadiness?
            var afterRead: IOReadiness?
        }
        let captured = Capture()

        kernel.spawn("pty-ready") { ctx in
            let fd = ctx.install(pty.slave)
            captured.initial = ctx.readiness(fd)
            ctx.sleep(0.01) {
                captured.afterInput = ctx.readiness(fd)
                _ = ctx.read(fd, max: 64)
                captured.afterRead = ctx.readiness(fd)
            }
        }
        loop.advance(by: 0)
        pty.writeFromApp(Array("echo hi\n".utf8))
        loop.advance(by: 0.02)

        #expect(captured.initial == [.writable])
        #expect(captured.afterInput?.contains(.readable) == true)
        #expect(captured.afterInput?.contains(.writable) == true)
        #expect(captured.afterRead == [.writable])
    }

    @Test func udpSocketReadinessTracksDatagramQueue() {
        let loop = EventLoop()
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB, on: loop, latency: 0.005)
        kernelA.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        kernelB.netns.stack.configuredNeighbor(ip: ipA, mac: macA)

        final class Capture {
            var initial: IOReadiness?
            var afterDatagram: IOReadiness?
            var afterReceive: IOReadiness?
        }
        let captured = Capture()

        kernelB.spawn("udp-ready") { ctx in
            let fd = ctx.socket()!
            ctx.bind(fd, address: ipB, port: 7000)
            captured.initial = ctx.readiness(fd)
            ctx.sleep(0.02) {
                captured.afterDatagram = ctx.readiness(fd)
                _ = ctx.recvfrom(fd)
                captured.afterReceive = ctx.readiness(fd)
            }
        }
        kernelA.spawn("udp-send") { ctx in
            let fd = ctx.socket()!
            ctx.bind(fd, address: ipA, port: 5000)
            ctx.sendto(fd, Array("ping".utf8), to: ipB, port: 7000)
        }

        loop.advance(by: 0.1)

        #expect(captured.initial == [.writable])
        #expect(captured.afterDatagram?.contains(.readable) == true)
        #expect(captured.afterDatagram?.contains(.writable) == true)
        #expect(captured.afterReceive == [.writable])
    }

    @Test func blockingPollWakesForQueuedUDPDatagram() {
        let loop = EventLoop()
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB, on: loop, latency: 0.005)
        kernelA.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        kernelB.netns.stack.configuredNeighbor(ip: ipA, mac: macA)

        final class Capture {
            var results: [PollResult] = []
            var payload: [UInt8] = []
        }
        let captured = Capture()

        kernelB.spawn("udp-poll") { ctx in
            let fd = ctx.socket()!
            ctx.bind(fd, address: ipB, port: 7000)
            ctx.poll([PollRequest(fd: fd, interests: .readable)], timeout: 1.0) { results in
                captured.results = results
                captured.payload = ctx.recvfrom(fd)?.bytes ?? []
            }
        }
        kernelA.spawn("udp-send") { ctx in
            let fd = ctx.socket()!
            ctx.bind(fd, address: ipA, port: 5000)
            ctx.sleep(0.01) {
                ctx.sendto(fd, Array("datagram".utf8), to: ipB, port: 7000)
            }
        }

        loop.advance(by: 0.1)

        #expect(captured.results.first?.readiness.contains(.readable) == true)
        #expect(String(decoding: captured.payload, as: UTF8.self) == "datagram")
    }

    @Test func tcpReadinessTracksListenBacklogDataAndEOF() {
        let loop = EventLoop()
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let clientKernel = Kernel(loop: loop)
        let serverKernel = Kernel(loop: loop)
        let ifA = clientKernel.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = serverKernel.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(clientKernel.netns.stack, ifA, serverKernel.netns.stack, ifB, on: loop, latency: 0.005)
        clientKernel.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        serverKernel.netns.stack.configuredNeighbor(ip: ipA, mac: macA)

        final class Capture {
            var listenInitial: IOReadiness?
            var listenPending: IOReadiness?
            var acceptedReady: IOReadiness?
            var afterRead: IOReadiness?
        }
        let captured = Capture()

        serverKernel.spawn("tcp-ready-server") { ctx in
            let listen = ctx.tcpSocket()!
            ctx.tcpListen(listen, port: 8080)
            captured.listenInitial = ctx.readiness(listen)
            ctx.sleep(0.03) {
                captured.listenPending = ctx.readiness(listen)
                ctx.tcpAccept(listen) { accepted in
                    captured.acceptedReady = ctx.readiness(accepted)
                    _ = ctx.read(accepted, max: 16)
                    captured.afterRead = ctx.readiness(accepted)
                }
            }
        }

        clientKernel.spawn("tcp-ready-client") { ctx in
            let fd = ctx.tcpSocket()!
            ctx.tcpConnect(fd, to: ipB, port: 8080) {
                ctx.tcpSend(fd, Array("hi".utf8))
                ctx.tcpClose(fd)
            }
        }

        loop.advance(by: 0.2)

        #expect(captured.listenInitial?.isEmpty == true)
        #expect(captured.listenPending == [.readable])
        #expect(captured.acceptedReady?.contains(.readable) == true)
        #expect(captured.acceptedReady?.contains(.writable) == true)
        #expect(captured.afterRead?.contains(.hangup) == true)
    }

    @Test func blockingPollWakesForTCPListenBacklog() {
        let loop = EventLoop()
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let clientKernel = Kernel(loop: loop)
        let serverKernel = Kernel(loop: loop)
        let ifA = clientKernel.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = serverKernel.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(clientKernel.netns.stack, ifA, serverKernel.netns.stack, ifB, on: loop, latency: 0.005)
        clientKernel.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        serverKernel.netns.stack.configuredNeighbor(ip: ipA, mac: macA)

        final class Capture {
            var results: [PollResult] = []
            var accepted = false
        }
        let captured = Capture()

        serverKernel.spawn("tcp-poll-listen") { ctx in
            let listen = ctx.tcpSocket()!
            ctx.tcpListen(listen, port: 8080)
            ctx.poll([PollRequest(fd: listen, interests: .readable)], timeout: 1.0) { results in
                captured.results = results
                ctx.tcpAccept(listen) { _ in captured.accepted = true }
            }
        }
        clientKernel.spawn("tcp-client") { ctx in
            let fd = ctx.tcpSocket()!
            ctx.sleep(0.01) {
                ctx.tcpConnect(fd, to: ipB, port: 8080) {}
            }
        }

        loop.advance(by: 0.2)

        #expect(captured.results.first?.readiness.contains(.readable) == true)
        #expect(captured.accepted)
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
