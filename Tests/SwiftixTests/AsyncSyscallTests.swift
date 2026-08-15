import Testing
@testable import Swiftix

/// Task 14: the async/throwing syscall frontend (R1, R2, R3, R6, R10.3).
///
/// Every async syscall is a thin adapter over the existing callback syscall, so
/// it must resume with the *same* result the callback delivers, exchange the
/// same protocol messages, and preserve the park/wake accounting (R3). These
/// tests drive `async` process bodies purely on the logical-time `EventLoop`
/// (`runUntilIdle()` / `advance(by:)` interleaved with `Task.yield()`), matching
/// `SwiftixExecutorTests` — no wall-clock waits.
@Suite("Async syscall frontend")
struct AsyncSyscallTests {

    /// Shared, single-threaded observation record. Written only by process bodies
    /// while they run as jobs on the loop, read by the driver between drains.
    final class Capture: @unchecked Sendable {
        var udpReply: [UInt8] = []
        var udpReplied = false

        var tcpData: [UInt8] = []
        var tcpDone = false

        var pingReplied = false
        var pingFrom: IPv4Address?

        var waitPID: PID = 0
        var waitCode: Int32 = 0
        var waitDone = false
        var waitError: SyscallError?
        var waitNoHangWasNil = false

        var recvError: SyscallError?
        var recvThrew = false

        var sleepParked = false
        var sleepReturned = false
        var sleepInterrupted = false
        var sleepDone = false
    }

    // MARK: - Loop driver

    /// Pump the logical-time loop until `done` or a generous cap, yielding to the
    /// runtime between drains so the async task's next job lands on the loop.
    private func drive(_ loop: EventLoop, until done: @Sendable () -> Bool, max: Int = 200_000) async {
        var pumps = 0
        while !done() && pumps < max {
            loop.advance(by: 0)
            loop.runNext()
            await Task.yield()
            pumps += 1
        }
    }

    /// Drain work that is due at the current logical timestamp only. Unlike
    /// `runUntilIdle`, this does not jump to future timer deadlines.
    private func settleCurrentTime(_ loop: EventLoop, until done: () -> Bool, max: Int = 2_000) async {
        var pumps = 0
        while !done() && pumps < max {
            loop.advance(by: 0)
            await Task.yield()
            pumps += 1
        }
    }

    // MARK: - Fixtures

    private struct Pair {
        let kernelA: Kernel     // client
        let kernelB: Kernel     // server
        let ifB: NetworkStack.Interface
        let ipA: IPv4Address
        let ipB: IPv4Address
        let macA: MACAddress
        let macB: MACAddress
    }

    private func makePair(loop: EventLoop,
                          captureB: (@Sendable (PacketBuffer) -> Void)? = nil) -> Pair {
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
        if let captureB {
            kernelB.netns.stack.onPacketTrace = { frame, _, direction in
                if direction == .outbound { captureB(frame) }
            }
        }
        return Pair(kernelA: kernelA, kernelB: kernelB, ifB: ifB,
                    ipA: ipA, ipB: ipB, macA: macA, macB: macB)
    }

    private func tcpHeader(_ frame: PacketBuffer) -> TCPSegment.Header? {
        guard let eth = EthernetFrame.parseHeader(frame),
              eth.etherType == EtherType.ipv4.rawValue,
              let (ip, ipPayload) = IPv4Packet.parse(EthernetFrame.payload(frame)),
              ip.proto == IPProtocol.tcp.rawValue,
              let (header, _) = TCPSegment.parse(ipPayload) else { return nil }
        return header
    }

    private func makeRSTFrame(_ pair: Pair, sourcePort: UInt16, destinationPort: UInt16,
                              sequence: UInt32) -> PacketBuffer {
        var segment = TCPSegment.build(sourcePort: sourcePort, destinationPort: destinationPort,
                                       sequence: sequence, acknowledgment: 0,
                                       flags: [.rst], window: 0xFFFF, payload: [])
        segment[16] = 0; segment[17] = 0
        let checksum = TransportChecksum.transport(source: pair.ipA, destination: pair.ipB,
                                                    proto: IPProtocol.tcp.rawValue, segment: segment)
        segment[16] = UInt8((checksum >> 8) & 0xFF)
        segment[17] = UInt8(checksum & 0xFF)
        let ipPacket = IPv4Packet.build(source: pair.ipA, destination: pair.ipB,
                                        proto: IPProtocol.tcp.rawValue, payload: segment)
        return EthernetFrame.build(destination: pair.macB, source: pair.macA,
                                   etherType: EtherType.ipv4.rawValue, payload: ipPacket)
    }

    // MARK: - (1) Async UDP recvfrom resumes like the callback (echo)

    @Test func asyncUDPRecvfromMatchesCallback() async {
        let loop = EventLoop()
        let pair = makePair(loop: loop)
        let cap = Capture()
        let ipA = pair.ipA, ipB = pair.ipB

        pair.kernelB.spawn("udp-echo") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: ipB, port: 7000)
            while true {
                guard let datagram = try? await ctx.recvfrom(fd) else { return }
                ctx.sendto(fd, datagram.bytes, to: datagram.address, port: datagram.port)
            }
        }
        pair.kernelA.spawn("udp-client") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: ipA, port: 5000)
            ctx.sendto(fd, Array("ping".utf8), to: ipB, port: 7000)
            if let datagram = try? await ctx.recvfrom(fd) {
                cap.udpReply = datagram.bytes
                cap.udpReplied = true
            }
        }

        await drive(loop, until: { cap.udpReplied })

        #expect(cap.udpReplied)
        #expect(String(decoding: cap.udpReply, as: UTF8.self) == "ping")
    }

    // MARK: - (2) Async TCP handshake + data path matches the callback path

    @Test func asyncTCPConnectAcceptRecvMatchesCallback() async {
        let loop = EventLoop()
        let pair = makePair(loop: loop)
        let cap = Capture()
        let ipB = pair.ipB
        let payload = Array("hello async tcp".utf8)

        pair.kernelB.spawn("tcp-server") { ctx in
            guard let listenFD = ctx.tcpSocket() else { return }
            ctx.tcpListen(listenFD, port: 80)
            guard let acceptedFD = try? await ctx.tcpAccept(listenFD) else { return }
            guard let bytes = try? await ctx.tcpRecv(acceptedFD) else { return }
            cap.tcpData = bytes
            cap.tcpDone = true
        }
        pair.kernelA.spawn("tcp-client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            try? await ctx.tcpConnect(fd, to: ipB, port: 80)
            ctx.tcpSend(fd, payload)
        }

        await drive(loop, until: { cap.tcpDone })

        #expect(cap.tcpDone)
        #expect(cap.tcpData == payload)
    }

    // MARK: - (3a) Async icmpEcho resumes with a reply outcome

    @Test func asyncICMPEchoResumesWithReply() async {
        let loop = EventLoop()
        let pair = makePair(loop: loop)
        let cap = Capture()
        let ipB = pair.ipB

        pair.kernelA.spawn("ping") { ctx in
            guard let outcome = try? await ctx.icmpEcho(to: ipB, identifier: 1, sequence: 1, timeout: 1.0) else {
                return
            }
            if case let .reply(from, _, _, _, _) = outcome {
                cap.pingFrom = from
                cap.pingReplied = true
            }
        }

        await drive(loop, until: { cap.pingReplied })

        #expect(cap.pingReplied)
        #expect(cap.pingFrom == ipB)
    }

    // MARK: - (3b) Async wait() returns an exited child's (pid, code)

    @Test func asyncWaitReturnsChildExit() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let cap = Capture()

        kernel.spawn("parent") { ctx in
            ctx.spawn("child") { child in child.exit(42) }
            if let result = try? await ctx.wait() {
                cap.waitPID = result.childPID
                cap.waitCode = result.status.code
                cap.waitDone = true
            }
        }

        await drive(loop, until: { cap.waitDone })

        #expect(cap.waitDone)
        #expect(cap.waitCode == 42)
        #expect(cap.waitPID >= 1)
    }

    // MARK: - (3c) Async wait() with no children throws .noChildProcess

    @Test func asyncWaitNoChildrenThrows() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let cap = Capture()

        kernel.spawn("lonely") { ctx in
            do {
                _ = try await ctx.wait()
            } catch let error as SyscallError {
                cap.waitError = error
            } catch {}
            cap.waitDone = true
        }

        await drive(loop, until: { cap.waitDone })

        #expect(cap.waitDone)
        #expect(cap.waitError == .noChildProcess)
    }

    @Test func asyncWaitpidNoHangReturnsNilWhileChildRuns() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let cap = Capture()

        kernel.spawn("parent") { ctx in
            ctx.spawn("child") { child in
                child.sleep(1) { child.exit(0) }
            }
            do {
                let result = try await ctx.waitpid(options: [.noHang])
                cap.waitNoHangWasNil = result == nil
            } catch let error as SyscallError {
                cap.waitError = error
            } catch {}
            cap.waitDone = true
        }

        await settleCurrentTime(loop, until: { cap.waitDone })

        #expect(cap.waitDone)
        #expect(cap.waitNoHangWasNil)
        #expect(cap.waitError == nil)
        #expect(kernel.processCount == 1)

        loop.advance(by: 1)
        loop.runUntilIdle()

        #expect(kernel.processCount == 0)
    }

    // MARK: - (3d) Interruptible async sleep wakes when a signal terminates it

    @Test func interruptibleSleepThrowsWhenProcessTerminates() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let cap = Capture()

        let pid = kernel.spawn("sleeper") { ctx in
            cap.sleepParked = true
            do {
                try await ctx.sleep(10)
                cap.sleepReturned = true
            } catch SyscallError.interrupted {
                cap.sleepInterrupted = true
            } catch {}
            cap.sleepDone = true
        }

        await settleCurrentTime(loop, until: {
            cap.sleepParked && (kernel.process(pid)?.blockedOn ?? 0) > 1
        })
        kernel.kill(pid, signal: Signal.sigterm.rawValue)
        await settleCurrentTime(loop, until: { cap.sleepDone })
        loop.advance(by: 10)
        loop.runUntilIdle()
        await Task.yield()

        #expect(cap.sleepDone)
        #expect(cap.sleepInterrupted)
        #expect(!cap.sleepReturned)
        #expect(kernel.processCount == 0)
    }

    @Test func asyncWaitThrowsInterruptedWhenProcessTerminates() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box: @unchecked Sendable {
            var done = false
            var returned = false
            var error: SyscallError?
        }
        let box = Box()

        let pid = kernel.spawn("parent") { ctx in
            ctx.spawn("child") { child in child.sleep(10) { child.exit(0) } }
            do {
                _ = try await ctx.wait()
                box.returned = true
            } catch let error as SyscallError {
                box.error = error
            } catch {}
            box.done = true
        }

        await settleCurrentTime(loop, until: { (kernel.process(pid)?.blockedOn ?? 0) > 1 })
        kernel.kill(pid, signal: Signal.sigterm.rawValue)
        await settleCurrentTime(loop, until: { box.done })

        #expect(box.done)
        #expect(!box.returned)
        #expect(box.error == .interrupted)
        #expect(kernel.process(pid) == nil)
    }

    @Test func asyncReadThrowsInterruptedWhenProcessTerminates() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box: @unchecked Sendable {
            var done = false
            var returned = false
            var error: SyscallError?
        }
        let box = Box()

        let pid = kernel.spawn("reader") { ctx in
            let pipe = ctx.pipe()
            do {
                _ = try await ctx.read(pipe.read)
                box.returned = true
            } catch let error as SyscallError {
                box.error = error
            } catch {}
            box.done = true
        }

        await settleCurrentTime(loop, until: { (kernel.process(pid)?.blockedOn ?? 0) > 1 })
        kernel.kill(pid, signal: Signal.sigterm.rawValue)
        await settleCurrentTime(loop, until: { box.done })

        #expect(box.done)
        #expect(!box.returned)
        #expect(box.error == .interrupted)
        #expect(kernel.process(pid) == nil)
    }

    @Test func asyncUDPRecvfromThrowsInterruptedWhenProcessTerminates() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box: @unchecked Sendable {
            var done = false
            var returned = false
            var error: SyscallError?
        }
        let box = Box()
        let ip = IPv4Address(10, 0, 0, 1)
        _ = kernel.netns.stack.configuredInterface(address: ip, mac: MACAddress("02:00:00:00:00:11")!)

        let pid = kernel.spawn("udp-reader") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: ip, port: 9000)
            do {
                _ = try await ctx.recvfrom(fd)
                box.returned = true
            } catch let error as SyscallError {
                box.error = error
            } catch {}
            box.done = true
        }

        await settleCurrentTime(loop, until: { (kernel.process(pid)?.blockedOn ?? 0) > 1 })
        kernel.kill(pid, signal: Signal.sigterm.rawValue)
        await settleCurrentTime(loop, until: { box.done })

        #expect(box.done)
        #expect(!box.returned)
        #expect(box.error == .interrupted)
        #expect(kernel.process(pid) == nil)
    }

    @Test func asyncTCPAcceptThrowsInterruptedWhenProcessTerminates() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box: @unchecked Sendable {
            var done = false
            var returned = false
            var error: SyscallError?
        }
        let box = Box()

        let pid = kernel.spawn("tcp-listener") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpListen(fd, port: 8080)
            do {
                _ = try await ctx.tcpAccept(fd)
                box.returned = true
            } catch let error as SyscallError {
                box.error = error
            } catch {}
            box.done = true
        }

        await settleCurrentTime(loop, until: { (kernel.process(pid)?.blockedOn ?? 0) > 1 })
        kernel.kill(pid, signal: Signal.sigterm.rawValue)
        await settleCurrentTime(loop, until: { box.done })

        #expect(box.done)
        #expect(!box.returned)
        #expect(box.error == .interrupted)
        #expect(kernel.process(pid) == nil)
    }

    @Test func asyncTCPRecvThrowsInterruptedWhenProcessTerminates() async {
        let loop = EventLoop()
        let pair = makePair(loop: loop)
        final class Box: @unchecked Sendable {
            var parked = false
            var done = false
            var returned = false
            var error: SyscallError?
        }
        let box = Box()
        let ipB = pair.ipB

        let serverPID = pair.kernelB.spawn("tcp-server") { ctx in
            guard let listenFD = ctx.tcpSocket() else { return }
            ctx.tcpListen(listenFD, port: 8080)
            guard let acceptedFD = try? await ctx.tcpAccept(listenFD) else { return }
            box.parked = true
            do {
                _ = try await ctx.tcpRecv(acceptedFD)
                box.returned = true
            } catch let error as SyscallError {
                box.error = error
            } catch {}
            box.done = true
        }
        pair.kernelA.spawn("tcp-client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            try? await ctx.tcpConnect(fd, to: ipB, port: 8080)
        }

        await drive(loop, until: { box.parked })
        await settleCurrentTime(loop, until: { (pair.kernelB.process(serverPID)?.blockedOn ?? 0) > 1 })
        pair.kernelB.kill(serverPID, signal: Signal.sigterm.rawValue)
        await settleCurrentTime(loop, until: { box.done })

        #expect(box.done)
        #expect(!box.returned)
        #expect(box.error == .interrupted)
        #expect(pair.kernelB.process(serverPID) == nil)
    }

    @Test func asyncPollThrowsInterruptedWhenProcessTerminates() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box: @unchecked Sendable {
            var done = false
            var returned = false
            var error: SyscallError?
        }
        let box = Box()

        let pid = kernel.spawn("poller") { ctx in
            let pipe = ctx.pipe()
            do {
                _ = try await ctx.poll([PollRequest(fd: pipe.read, interests: .readable)])
                box.returned = true
            } catch let error as SyscallError {
                box.error = error
            } catch {}
            box.done = true
        }

        await settleCurrentTime(loop, until: { (kernel.process(pid)?.blockedOn ?? 0) > 1 })
        kernel.kill(pid, signal: Signal.sigterm.rawValue)
        await settleCurrentTime(loop, until: { box.done })

        #expect(box.done)
        #expect(!box.returned)
        #expect(box.error == .interrupted)
        #expect(kernel.process(pid) == nil)
    }

    // MARK: - (4) Non-blocking recvfrom: wouldBlock when empty, value when buffered

    @Test func nonBlockingRecvfromThrowsWouldBlockThenReturnsBuffered() async {
        let loop = EventLoop()
        let pair = makePair(loop: loop)
        let cap = Capture()
        let ipA = pair.ipA, ipB = pair.ipB

        // A server that echoes so the client has a datagram to receive.
        pair.kernelB.spawn("udp-echo") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: ipB, port: 7000)
            while true {
                guard let datagram = try? await ctx.recvfrom(fd) else { return }
                ctx.sendto(fd, datagram.bytes, to: datagram.address, port: datagram.port)
            }
        }

        pair.kernelA.spawn("udp-client") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: ipA, port: 5000)

            // Nothing buffered yet -> .wouldBlock (R6.1).
            do {
                _ = try ctx.recvfromNonBlocking(fd)
            } catch let error as SyscallError {
                cap.recvError = error
                cap.recvThrew = true
            } catch {}

            // Trigger a reply, then block-await it so it is buffered.
            ctx.sendto(fd, Array("hi".utf8), to: ipB, port: 7000)
            if let datagram = try? await ctx.recvfrom(fd) {
                cap.udpReply = datagram.bytes
                cap.udpReplied = true
            }
        }

        await drive(loop, until: { cap.udpReplied })

        #expect(cap.recvThrew)
        #expect(cap.recvError == .wouldBlock)
        #expect(String(decoding: cap.udpReply, as: UTF8.self) == "hi")
    }

    /// The buffered fast path: once several datagrams have queued on the socket,
    /// each `await recvfrom` returns the next one directly (the 2nd and 3rd are
    /// already buffered when consumed), so a whole queue drains in order without
    /// re-parking. The client requests three echoes, then drains all three.
    @Test func bufferedRecvfromDrainsQueueInOrder() async {
        let loop = EventLoop()
        let pair = makePair(loop: loop)
        let ipA = pair.ipA, ipB = pair.ipB

        final class Collected: @unchecked Sendable {
            var messages: [String] = []
            var done = false
        }
        let collected = Collected()

        pair.kernelB.spawn("udp-echo") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: ipB, port: 7000)
            while true {
                guard let datagram = try? await ctx.recvfrom(fd) else { return }
                ctx.sendto(fd, datagram.bytes, to: datagram.address, port: datagram.port)
            }
        }
        pair.kernelA.spawn("udp-client") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: ipA, port: 5000)
            // Fire three requests back-to-back; their replies queue on the socket.
            ctx.sendto(fd, Array("one".utf8), to: ipB, port: 7000)
            ctx.sendto(fd, Array("two".utf8), to: ipB, port: 7000)
            ctx.sendto(fd, Array("three".utf8), to: ipB, port: 7000)
            for _ in 0..<3 {
                guard let datagram = try? await ctx.recvfrom(fd) else { return }
                collected.messages.append(String(decoding: datagram.bytes, as: UTF8.self))
            }
            collected.done = true
        }

        await drive(loop, until: { collected.done })

        #expect(collected.done)
        #expect(collected.messages == ["one", "two", "three"])
    }

    // MARK: - (5) In-window RST surfaces as .connectionReset from async tcpRecv

    @Test func asyncTCPRecvSurfacesConnectionReset() async {
        let loop = EventLoop()
        final class FrameLog: @unchecked Sendable { var frames: [PacketBuffer] = [] }
        let log = FrameLog()
        let pair = makePair(loop: loop) { log.frames.append($0) }
        let cap = Capture()
        let ipB = pair.ipB

        final class Parked: @unchecked Sendable { var value = false }
        let parked = Parked()

        pair.kernelB.spawn("tcp-server") { ctx in
            guard let listenFD = ctx.tcpSocket() else { return }
            ctx.tcpListen(listenFD, port: 80)
            guard let acceptedFD = try? await ctx.tcpAccept(listenFD) else { return }
            parked.value = true
            do {
                _ = try await ctx.tcpRecv(acceptedFD)
            } catch let error as SyscallError {
                cap.recvError = error
                cap.recvThrew = true
            } catch {}
            cap.tcpDone = true
        }
        pair.kernelA.spawn("tcp-client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            try? await ctx.tcpConnect(fd, to: ipB, port: 80)
        }

        // Establish and park the server on recv.
        await drive(loop, until: { parked.value })

        // Learn the server's expected sequence (== its SYN-ACK acknowledgment) and
        // the client's ephemeral port off the captured handshake.
        guard let synAck = log.frames.compactMap(tcpHeader).first(where: {
            $0.flags.contains(.syn) && $0.flags.contains(.ack)
        }) else {
            Issue.record("no SYN-ACK captured from server")
            return
        }
        let serverRcvNxt = synAck.acknowledgment
        let clientPort = synAck.destinationPort

        #expect(pair.kernelB.netns.stack.snapshotTCP().contains { $0.localPort == 80 })

        // Inject an in-window RST; the parked async tcpRecv must throw .connectionReset.
        let rst = makeRSTFrame(pair, sourcePort: clientPort, destinationPort: 80, sequence: serverRcvNxt)
        pair.kernelB.netns.stack.receive(rst, on: pair.ifB)

        await drive(loop, until: { cap.tcpDone })

        #expect(cap.tcpDone)
        #expect(cap.recvThrew)
        #expect(cap.recvError == .connectionReset)
        // R10.2: the connection was removed from the table.
        #expect(pair.kernelB.netns.stack.snapshotTCP().contains { $0.localPort == 80 } == false)
    }

    @Test func asyncBodyQueuedBeforePauseCannotEnterUserCode() async {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box: @unchecked Sendable { var started = false }
        let box = Box()

        let body: (ProcessContext) async -> Void = { _ in
            box.started = true
        }
        kernel.spawn("queued-async", body)

        // Run only the owner-tagged launch step. It creates one opaque executor
        // job, then pause before that job is allowed to enter the async body.
        #expect(loop.runNext())
        #expect(loop.pendingJobCount == 1)
        kernel.pause()
        loop.runUntilIdle()

        #expect(!box.started)
        #expect(loop.pendingJobCount == 0)
        #expect(!loop.hasPendingWork)

        kernel.resume()
        await settleCurrentTime(loop, until: { box.started })
        #expect(box.started)
    }

    @Test func kernelShutdownInterruptsPermanentAsyncWaiterAndReleasesKernel() async {
        let loop = EventLoop()
        var kernel: Kernel? = Kernel(loop: loop)
        weak let weakKernel = kernel
        final class Box: @unchecked Sendable {
            var parked = false
            var done = false
            var error: SyscallError?
        }
        let box = Box()

        let pid = kernel!.spawn("permanent-reader") { context in
            let pipe = context.pipe()
            box.parked = true
            do {
                _ = try await context.read(pipe.read)
            } catch let error as SyscallError {
                box.error = error
            } catch {}
            box.done = true
        }

        await settleCurrentTime(loop, until: {
            box.parked && (kernel?.process(pid)?.blockedOn ?? 0) > 1
        })
        #expect(box.parked)

        kernel?.shutdown()
        #expect(kernel?.processCount == 0)
        #expect(loop.pendingCount == 0)

        for _ in 0..<100 where !box.done {
            loop.runUntilIdle()
            await Task.yield()
        }
        #expect(box.done)
        #expect(box.error == .interrupted)

        kernel = nil
        for _ in 0..<100 where weakKernel != nil {
            loop.runUntilIdle()
            await Task.yield()
        }
        #expect(weakKernel == nil)
        #expect(loop.pendingWorkCount == 0)
    }
}
