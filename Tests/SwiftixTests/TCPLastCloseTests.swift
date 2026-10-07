import Testing
@testable import Swiftix

/// Last-close semantics for connected TCP sockets: the connection closes when
/// the last descriptor referencing its open-file description goes away — by an
/// explicit close, a process exit, or a kill — and not before.
///
///   - No unread data: an orderly FIN, sent after any bytes still unsent.
///   - Unread data: a reset, since those bytes can never be delivered.
///   - `dup` and inherited descriptors share one description, so the connection
///     outlives every close but the last.
///   - Afterwards the connection is an orphan: new data is answered with a
///     reset, and a peer that never closes cannot pin it forever.
///
/// Pure decisions are asserted on `TCPConnectionPlanner`/`TCPStateMachine`; the
/// rest runs two wired kernels on the logical-time loop.
@Suite("TCP last close")
struct TCPLastCloseTests {

    // MARK: - Fixtures

    private final class Wire {
        var fromClient: [TCPSegment.Header] = []
        var fromServer: [TCPSegment.Header] = []

        func sent(_ flag: TCPSegment.Flags, in segments: [TCPSegment.Header]) -> Bool {
            segments.contains { $0.flags.contains(flag) }
        }
    }

    private struct Pair {
        let loop = EventLoop()
        let client: Kernel
        let server: Kernel
        let serverIP = IPv4Address(10, 0, 0, 2)
        let wire = Wire()

        init() {
            let macA = MACAddress("02:00:00:00:00:0a")!
            let macB = MACAddress("02:00:00:00:00:0b")!
            let ipA = IPv4Address(10, 0, 0, 1)
            client = Kernel(loop: loop)
            server = Kernel(loop: loop)
            let ifA = client.netns.stack.configuredInterface(address: ipA, mac: macA)
            let ifB = server.netns.stack.configuredInterface(address: serverIP, mac: macB)
            TestWire.connect(client.netns.stack, ifA, server.netns.stack, ifB, on: loop, latency: 0.005)
            client.netns.stack.configuredNeighbor(ip: serverIP, mac: macB)
            server.netns.stack.configuredNeighbor(ip: ipA, mac: macA)
            let wire = self.wire
            client.netns.stack.onPacketTrace = { frame, _, direction in
                if direction == .outbound, let header = Self.tcpHeader(frame) { wire.fromClient.append(header) }
            }
            server.netns.stack.onPacketTrace = { frame, _, direction in
                if direction == .outbound, let header = Self.tcpHeader(frame) { wire.fromServer.append(header) }
            }
        }

        private static func tcpHeader(_ frame: PacketBuffer) -> TCPSegment.Header? {
            guard let eth = EthernetFrame.parseHeader(frame),
                  eth.etherType == EtherType.ipv4.rawValue,
                  let (ip, ipPayload) = IPv4Packet.parse(EthernetFrame.payload(frame)),
                  ip.proto == IPProtocol.tcp.rawValue,
                  let (header, _) = TCPSegment.parse(ipPayload) else { return nil }
            return header
        }

        /// State names of the connections each side still has in its table.
        var clientStates: [String] { client.netns.stack.snapshotTCP().map(\.state) }
        var serverStates: [String] { server.netns.stack.snapshotTCP().map(\.state) }

        func settle(_ seconds: Double = 0.5) { loop.advance(by: seconds) }
    }

    /// What a server that reads until EOF observed.
    private final class Received {
        var bytes: [UInt8] = []
        var sawEOF = false
        var accepted = false
    }

    /// Keep a process alive without touching its TCP socket.
    private static func parkForever(_ ctx: ProcessContext) {
        guard let idle = ctx.socket() else { return }
        ctx.recvfrom(idle) { _, _, _ in }
    }

    private static func readUntilEOF(_ ctx: ProcessContext, _ fd: Int, into received: Received,
                                     then finish: @escaping () -> Void = {}) {
        ctx.tcpRecv(fd) { bytes in
            if bytes.isEmpty {
                received.sawEOF = true
                finish()
            } else {
                received.bytes += bytes
                readUntilEOF(ctx, fd, into: received, then: finish)
            }
        }
    }

    /// A server on port 80 that accepts one connection and reads it to EOF. It
    /// then exits (closing its side) unless `lingers`, in which case it keeps
    /// the accepted descriptor open.
    @discardableResult
    private func spawnReadingServer(_ pair: Pair, _ received: Received, lingers: Bool = false) -> PID {
        pair.server.spawn("server") { ctx in
            guard let listener = ctx.tcpSocket() else { return }
            ctx.tcpListen(listener, port: 80)
            ctx.tcpAccept(listener) { fd in
                received.accepted = true
                Self.readUntilEOF(ctx, fd, into: received) {
                    if lingers { Self.parkForever(ctx) }
                }
            }
        }
    }

    // MARK: - Pure decisions

    @Test func lastCloseOfAnOpenConnectionIsAnOrderlyFIN() {
        let fin = TCPConnectionAction.sendControlled(flags: [.ack, .fin], payload: [])
        #expect(TCPConnectionPlanner.lastDescriptorClosed(from: .established,
                                                          hasUnreadData: false, hasUnsentData: false)
                == [.setState(.finWait1), fin])
        #expect(TCPConnectionPlanner.lastDescriptorClosed(from: .closeWait,
                                                          hasUnreadData: false, hasUnsentData: false)
                == [.setState(.lastAck), fin])
    }

    @Test func finIsDeferredBehindUnsentData() {
        #expect(TCPConnectionPlanner.lastDescriptorClosed(from: .established,
                                                          hasUnreadData: false, hasUnsentData: true)
                == [.setState(.finWait1), .deferFIN])
        #expect(TCPConnectionPlanner.localClose(from: .closeWait, hasUnsentData: true)
                == [.setState(.lastAck), .deferFIN])
    }

    @Test(arguments: [TCPState.established, .closeWait, .finWait1, .finWait2, .closing, .lastAck])
    func unreadDataTurnsLastCloseIntoAReset(state: TCPState) {
        let plan = TCPConnectionPlanner.lastDescriptorClosed(from: state,
                                                             hasUnreadData: true, hasUnsentData: false)
        #expect(plan == TCPConnectionPlanner.abortWithReset)
        #expect(plan.first == .sendReset)
        #expect(plan.contains(.removeConnection))
        #expect(plan.contains(.cancelRetransmitTimer))
        #expect(!plan.contains(.markReset))   // `wasReset` means the *peer* reset us
    }

    @Test func lastCloseLeavesAnInProgressCloseAlone() {
        for state in [TCPState.finWait1, .closing, .lastAck, .timeWait, .closed] {
            #expect(TCPConnectionPlanner.lastDescriptorClosed(from: state,
                                                              hasUnreadData: false, hasUnsentData: false) == [])
        }
        #expect(TCPConnectionPlanner.lastDescriptorClosed(from: .finWait2,
                                                          hasUnreadData: false, hasUnsentData: false)
                == [.scheduleOrphanTimeout])
    }

    @Test func lastCloseBeforeTheHandshakeCompletesSendsNoFIN() {
        let unanswered = TCPConnectionPlanner.lastDescriptorClosed(from: .synSent,
                                                                   hasUnreadData: false, hasUnsentData: false)
        #expect(unanswered == TCPConnectionPlanner.abandon)
        #expect(!unanswered.contains(.sendReset))
        #expect(TCPConnectionPlanner.lastDescriptorClosed(from: .synReceived,
                                                          hasUnreadData: false, hasUnsentData: false)
                == TCPConnectionPlanner.abortWithReset)
    }

    @Test func orphanEnteringFinWait2ArmsItsTimeout() {
        #expect(TCPConnectionPlanner.closeTransition(from: .finWait1, receivedFIN: false,
                                                     ourFinAcked: true, orphaned: true)
                == [.setState(.finWait2), .scheduleOrphanTimeout])
        #expect(TCPConnectionPlanner.closeTransition(from: .finWait1, receivedFIN: false,
                                                     ourFinAcked: true, orphaned: false)
                == [.setState(.finWait2)])
        #expect(TCPConnectionPlanner.closeTransition(from: .finWait1, receivedFIN: true,
                                                     ourFinAcked: true, orphaned: true)
                == TCPConnectionPlanner.enterTimeWait)
    }

    @Test func onlyNewPayloadIsRejectedAndOnlyForAnOrphan() {
        // New bytes past rcvNxt.
        #expect(TCPStateMachine.orphanRejectsPayload(orphaned: true, segmentSequence: 100,
                                                     payloadCount: 10, receiveNext: 100))
        #expect(TCPStateMachine.orphanRejectsPayload(orphaned: true, segmentSequence: 95,
                                                     payloadCount: 10, receiveNext: 100))
        // A retransmission of bytes already received, or a bare ACK/FIN.
        #expect(!TCPStateMachine.orphanRejectsPayload(orphaned: true, segmentSequence: 90,
                                                      payloadCount: 10, receiveNext: 100))
        #expect(!TCPStateMachine.orphanRejectsPayload(orphaned: true, segmentSequence: 100,
                                                      payloadCount: 0, receiveNext: 100))
        // A connection somebody can still read.
        #expect(!TCPStateMachine.orphanRejectsPayload(orphaned: false, segmentSequence: 100,
                                                      payloadCount: 10, receiveNext: 100))
        // Across sequence wraparound.
        #expect(TCPStateMachine.orphanRejectsPayload(orphaned: true, segmentSequence: 0xFFFF_FFFC,
                                                     payloadCount: 8, receiveNext: 0xFFFF_FFFE))
    }

    // MARK: - Process kill and exit

    @Test(arguments: [Signal.sigkill, .sigterm, .sigint])
    func killedProcessClosesItsConnectionWithAFIN(signal: Signal) {
        let pair = Pair()
        let received = Received()
        spawnReadingServer(pair, received)
        let client = pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) {
                ctx.tcpSend(fd, Array("hello".utf8))
                ctx.tcpRecv(fd) { _ in }   // parked, like an interactive `nc`
            }
        }
        pair.settle()
        #expect(pair.clientStates == ["ESTABLISHED"])
        #expect(pair.serverStates == ["ESTABLISHED"])
        #expect(!received.sawEOF)

        pair.client.kill(client, signal: signal.rawValue)
        pair.settle()

        #expect(pair.client.process(client) == nil)
        #expect(received.bytes == Array("hello".utf8))
        #expect(received.sawEOF, "the server never learned its peer was killed")
        #expect(pair.wire.sent(.fin, in: pair.wire.fromClient))
        #expect(!pair.wire.sent(.rst, in: pair.wire.fromClient))
        // The server exits on EOF; both ends of the handshake finish and vanish.
        #expect(pair.clientStates == [])
        #expect(pair.serverStates == [])
    }

    @Test func exitWithAnOpenSocketClosesIt() {
        let pair = Pair()
        let received = Received()
        spawnReadingServer(pair, received)
        pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) {
                ctx.tcpSend(fd, Array("bye".utf8))
                ctx.exit(0)   // never closes fd
            }
        }
        pair.settle()

        #expect(received.bytes == Array("bye".utf8))
        #expect(received.sawEOF)
        #expect(pair.clientStates == [])
        #expect(pair.serverStates == [])
    }

    @Test func returningFromTheProcessBodyClosesItsSocket() {
        let pair = Pair()
        let received = Received()
        spawnReadingServer(pair, received)
        pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) { }
        }
        pair.settle()

        #expect(received.accepted)
        #expect(received.sawEOF)
        #expect(pair.clientStates == [])
        #expect(pair.serverStates == [])
    }

    @Test func kernelSideOfAKilledServerIsClosedToo() {
        // The mirror image: the *server* dies; the client must see EOF.
        let pair = Pair()
        let received = Received()
        let server = pair.server.spawn("server") { ctx in
            guard let listener = ctx.tcpSocket() else { return }
            ctx.tcpListen(listener, port: 80)
            ctx.tcpAccept(listener) { fd in ctx.tcpRecv(fd) { _ in } }
        }
        pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) {
                Self.readUntilEOF(ctx, fd, into: received)
            }
        }
        pair.settle()
        pair.server.kill(server, signal: Signal.sigkill.rawValue)
        pair.settle()

        #expect(received.sawEOF)
        #expect(pair.clientStates == [])
        #expect(pair.serverStates == [])
        // The listening port went with it.
        #expect(!pair.server.netns.stack.tcpListenerExists(port: 80))
    }

    // MARK: - Unread data

    @Test func closingWithUnreadDataResetsThePeer() async {
        let pair = Pair()
        final class Outcome: @unchecked Sendable {
            var error: SyscallError?
            var bytes: [UInt8]?
        }
        let outcome = Outcome()
        pair.server.spawn("server") { (ctx: ProcessContext) async in
            guard let listener = ctx.tcpSocket() else { return }
            ctx.tcpListen(listener, port: 80)
            guard let fd = try? await ctx.tcpAccept(listener) else { return }
            ctx.tcpSend(fd, Array("you will never read this".utf8))
            do {
                outcome.bytes = try await ctx.tcpRecv(fd)
            } catch let error as SyscallError {
                outcome.error = error
            } catch {}
        }
        let client = pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) { Self.parkForever(ctx) }
        }
        for _ in 0..<50 { pair.settle(0.01); await Task.yield() }
        #expect(pair.client.netns.stack.snapshotTCP().first?.receiveBufferOccupancy == 24)

        pair.client.kill(client, signal: Signal.sigkill.rawValue)
        for _ in 0..<50 { pair.settle(0.01); await Task.yield() }

        #expect(pair.wire.sent(.rst, in: pair.wire.fromClient))
        #expect(!pair.wire.sent(.fin, in: pair.wire.fromClient))
        #expect(outcome.error == .connectionReset)
        #expect(outcome.bytes == nil)
        #expect(pair.clientStates == [])
        #expect(pair.serverStates == [])
    }

    @Test func dataReadBeforeCloseStillGetsAnOrderlyFIN() {
        let pair = Pair()
        let received = Received()
        pair.server.spawn("server") { ctx in
            guard let listener = ctx.tcpSocket() else { return }
            ctx.tcpListen(listener, port: 80)
            ctx.tcpAccept(listener) { fd in
                ctx.tcpSend(fd, Array("greeting".utf8))
                Self.readUntilEOF(ctx, fd, into: received)
            }
        }
        final class Got { var bytes: [UInt8] = [] }
        let got = Got()
        pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) {
                ctx.tcpRecv(fd) { bytes in
                    got.bytes = bytes
                    ctx.tcpClose(fd)
                    ctx.exit(0)
                }
            }
        }
        pair.settle()

        #expect(got.bytes == Array("greeting".utf8))
        #expect(received.sawEOF)
        #expect(!pair.wire.sent(.rst, in: pair.wire.fromClient))
    }

    // MARK: - Pending output

    @Test func finFollowsDataStillWaitingForTheWindow() {
        // 20 KB is far beyond the initial congestion window, so most of it is
        // still unsent when the process exits. Every byte must arrive, in order,
        // before the EOF.
        let pair = Pair()
        let received = Received()
        spawnReadingServer(pair, received)
        let payload = (0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) {
                ctx.tcpSend(fd, payload)
                ctx.exit(0)
            }
        }
        pair.settle(5)

        #expect(received.bytes == payload)
        #expect(received.sawEOF)
        let fins = pair.wire.fromClient.filter { $0.flags.contains(.fin) }
        let lastData = pair.wire.fromClient.last { $0.flags.contains(.psh) }
        #expect(fins.count == 1)
        if let fin = fins.first, let lastData {
            #expect(TCPSequence.greater(fin.sequence, than: lastData.sequence),
                    "the FIN was sequenced ahead of application data")
        }
        #expect(pair.clientStates == [])
        #expect(pair.serverStates == [])
    }

    // MARK: - Shared descriptions

    @Test func dupKeepsTheConnectionOpenUntilTheLastDescriptor() {
        let pair = Pair()
        let received = Received()
        spawnReadingServer(pair, received)
        final class Steps { var closeFirst: (() -> Void)?; var closeSecond: (() -> Void)? }
        let steps = Steps()
        pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) {
                guard let copy = ctx.dup(fd) else { return }
                steps.closeFirst = {
                    ctx.tcpClose(fd)
                    ctx.tcpSend(copy, Array("still open".utf8))
                }
                steps.closeSecond = { ctx.close(copy) }
                Self.parkForever(ctx)
            }
        }
        pair.settle()

        steps.closeFirst?()
        pair.settle()
        #expect(!received.sawEOF, "closing one of two descriptors closed the connection")
        #expect(received.bytes == Array("still open".utf8))
        #expect(pair.clientStates == ["ESTABLISHED"])
        #expect(!pair.wire.sent(.fin, in: pair.wire.fromClient))

        steps.closeSecond?()
        pair.settle()
        #expect(received.sawEOF)
        #expect(pair.clientStates == [])
    }

    @Test func dup2OverAConnectedSocketClosesIt() {
        let pair = Pair()
        let received = Received()
        spawnReadingServer(pair, received)
        pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) {
                let pipe = ctx.pipe()
                _ = ctx.dup2(pipe.read, onto: fd)   // implicit close of the socket
                Self.parkForever(ctx)
            }
        }
        pair.settle()

        #expect(received.sawEOF)
        #expect(pair.clientStates == [])
    }

    @Test func inheritedDescriptorKeepsTheConnectionOpenAfterTheParentExits() {
        let pair = Pair()
        let received = Received()
        spawnReadingServer(pair, received)
        final class Child { var pid: PID = 0 }
        let child = Child()
        let parent = pair.client.spawn("parent") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) {
                child.pid = ctx.spawn("child") { inherited in
                    inherited.tcpSend(fd, Array("from child".utf8))
                    inherited.tcpRecv(fd) { _ in }
                }
                ctx.exit(0)
            }
        }
        pair.settle()

        #expect(pair.client.process(parent) == nil)
        #expect(pair.client.process(child.pid)?.isLive == true)
        #expect(received.bytes == Array("from child".utf8))
        #expect(!received.sawEOF, "the parent's exit closed a socket its child still holds")
        #expect(pair.clientStates == ["ESTABLISHED"])

        pair.client.kill(child.pid, signal: Signal.sigkill.rawValue)
        pair.settle()
        #expect(received.sawEOF)
        #expect(pair.clientStates == [])
        #expect(pair.serverStates == [])
    }

    @Test func childExitDoesNotCloseAConnectionItsParentHolds() {
        let pair = Pair()
        let received = Received()
        spawnReadingServer(pair, received)
        final class Parent { var send: (() -> Void)? }
        let hook = Parent()
        let parent = pair.client.spawn("parent") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) {
                // The child closes its copy explicitly, then exits.
                ctx.spawn("child") { inherited in
                    inherited.tcpClose(fd)
                    inherited.exit(0)
                }
                hook.send = { ctx.tcpSend(fd, Array("from parent".utf8)) }
                ctx.tcpRecv(fd) { _ in }
            }
        }
        pair.settle()
        #expect(!received.sawEOF, "a child's close tore down its parent's connection")
        #expect(pair.clientStates == ["ESTABLISHED"])

        hook.send?()
        pair.settle()
        #expect(received.bytes == Array("from parent".utf8))

        pair.client.kill(parent, signal: Signal.sigterm.rawValue)
        pair.settle()
        #expect(received.sawEOF)
        #expect(pair.clientStates == [])
    }

    // MARK: - Orphans

    @Test func dataSentToAClosedPeerIsAnsweredWithAReset() {
        let pair = Pair()
        final class Server { var send: (() -> Void)?; var states: [String] = [] }
        let hook = Server()
        pair.server.spawn("server") { ctx in
            guard let listener = ctx.tcpSocket() else { return }
            ctx.tcpListen(listener, port: 80)
            ctx.tcpAccept(listener) { fd in
                hook.send = { ctx.tcpSend(fd, Array("anyone there?".utf8)) }
                Self.parkForever(ctx)
            }
        }
        pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) { ctx.exit(0) }
        }
        pair.settle()
        // Half-closed: the client is gone, the server has not closed yet.
        #expect(pair.clientStates == ["FIN_WAIT_2"])
        #expect(pair.serverStates == ["CLOSE_WAIT"])

        hook.send?()
        pair.settle()
        #expect(pair.wire.sent(.rst, in: pair.wire.fromClient))
        #expect(pair.clientStates == [])
        #expect(pair.serverStates == [], "the server kept a connection its peer reset")
    }

    @Test func orphanDoesNotWaitForeverForAPeerThatNeverCloses() {
        let pair = Pair()
        pair.server.spawn("server") { ctx in
            guard let listener = ctx.tcpSocket() else { return }
            ctx.tcpListen(listener, port: 80)
            ctx.tcpAccept(listener) { _ in Self.parkForever(ctx) }
        }
        pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) { ctx.exit(0) }
        }
        pair.settle()
        #expect(pair.clientStates == ["FIN_WAIT_2"])

        pair.settle(30)
        #expect(pair.clientStates == ["FIN_WAIT_2"])
        pair.settle(31)
        #expect(pair.clientStates == [])
        // The server still holds its descriptor; nothing forced it closed.
        #expect(pair.serverStates == ["CLOSE_WAIT"])
    }

    @Test func aHalfClosedConnectionWithADescriptorIsNotTimedOut() {
        // Only orphans are bounded: a process that closed its sending half but
        // can still read keeps FIN_WAIT_2 for as long as it likes.
        let pair = Pair()
        pair.server.spawn("server") { ctx in
            guard let listener = ctx.tcpSocket() else { return }
            ctx.tcpListen(listener, port: 80)
            ctx.tcpAccept(listener) { _ in Self.parkForever(ctx) }
        }
        pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) {
                (ctx.process.fileDescriptors.object(fd) as? TCPSocket)?.connection?.close()
                ctx.tcpRecv(fd) { _ in }
            }
        }
        pair.settle(120)
        #expect(pair.clientStates == ["FIN_WAIT_2"])
    }

    // MARK: - Orphans stalled on a zero window

    /// A connection whose peer buffers 2 KB and never reads, with 12 KB queued:
    /// the sender stalls on a Zero_Window with most of it unsent.
    private func stalledOnZeroWindow(_ pair: Pair) -> (client: TCPConnection, server: TCPConnection)? {
        let listener = pair.server.netns.stack.listen(port: 80)
        let client = pair.client.netns.stack.connect(localPort: 50_400, to: pair.serverIP, remotePort: 80)
        pair.settle()
        guard let server = listener.dequeue() else { return nil }
        server.setReceiveBufferCapacity(2_000)
        client.send((0..<12_000).map { UInt8($0 & 0xFF) })
        pair.settle(3)
        return (client, server)
    }

    @Test func persistProbePlanGivesUpOnlyForAnOrphanOutOfProbes() {
        let limit = TCPConnectionPlanner.orphanProbeLimit
        #expect(limit == 8)
        #expect(TCPConnectionPlanner.persistProbe(orphaned: true, probesSent: limit - 1) == [.sendZeroWindowProbe])
        #expect(TCPConnectionPlanner.persistProbe(orphaned: true, probesSent: limit)
                == TCPConnectionPlanner.abortWithReset)
        #expect(TCPConnectionPlanner.persistProbe(orphaned: false, probesSent: limit * 100) == [.sendZeroWindowProbe])
    }

    @Test func orphanStalledOnAZeroWindowGivesUpAfterItsProbes() {
        let pair = Pair()
        guard let (client, server) = stalledOnZeroWindow(pair) else {
            Issue.record("no connection"); return
        }
        #expect(client.peerAdvertisedWindow == 0)
        #expect(!client.sendBufferIsEmpty)

        client.lastDescriptorClosed()
        #expect(client.stateDescription == "FIN_WAIT_1")   // FIN deferred behind the data
        #expect(!pair.wire.sent(.fin, in: pair.wire.fromClient))

        // Still probing partway through its allowance…
        pair.settle(Double(TCPConnectionPlanner.orphanProbeLimit) / 2)
        #expect(pair.clientStates == ["FIN_WAIT_1"])
        #expect(!pair.wire.sent(.rst, in: pair.wire.fromClient))

        // …and gone, with the peer told, once it is spent.
        pair.settle(Double(TCPConnectionPlanner.orphanProbeLimit) + 2)
        #expect(pair.clientStates == [])
        #expect(pair.wire.sent(.rst, in: pair.wire.fromClient))
        #expect(!pair.wire.sent(.fin, in: pair.wire.fromClient))
        #expect(server.wasReset)
        #expect(pair.serverStates == [])
    }

    @Test func orphanWhoseWindowReopensFinishesNormally() {
        let pair = Pair()
        guard let (client, server) = stalledOnZeroWindow(pair) else {
            Issue.record("no connection"); return
        }
        client.lastDescriptorClosed()
        pair.settle(3)

        // The reader wakes up and drains everything: all 12 KB, then the FIN.
        var received = 0
        for _ in 0..<200 where !server.eofReceived || server.hasBufferedData {
            received += server.read(max: 65_535).count
            pair.settle(0.2)
        }
        #expect(received == 12_000)
        #expect(server.eofReceived)
        #expect(pair.wire.sent(.fin, in: pair.wire.fromClient))
        #expect(!pair.wire.sent(.rst, in: pair.wire.fromClient))
    }

    @Test func ownedConnectionKeepsProbingAZeroWindow() {
        let pair = Pair()
        guard let (client, _) = stalledOnZeroWindow(pair) else {
            Issue.record("no connection"); return
        }
        pair.settle(Double(TCPConnectionPlanner.orphanProbeLimit) * 5)
        #expect(pair.clientStates == ["ESTABLISHED"])
        #expect(!client.sendBufferIsEmpty)
        #expect(!pair.wire.sent(.rst, in: pair.wire.fromClient))
    }

    // MARK: - Listeners

    @Test func closingAListenerResetsConnectionsNobodyAccepted() async {
        let pair = Pair()
        final class Outcome: @unchecked Sendable { var error: SyscallError? }
        let outcome = Outcome()
        let server = pair.server.spawn("server") { ctx in
            guard let listener = ctx.tcpSocket() else { return }
            ctx.tcpListen(listener, port: 80)
            Self.parkForever(ctx)   // listens, never accepts
        }
        pair.client.spawn("client") { (ctx: ProcessContext) async in
            guard let fd = ctx.tcpSocket() else { return }
            try? await ctx.tcpConnect(fd, to: pair.serverIP, port: 80)
            do {
                _ = try await ctx.tcpRecv(fd)
            } catch let error as SyscallError {
                outcome.error = error
            } catch {}
        }
        for _ in 0..<50 { pair.settle(0.01); await Task.yield() }
        #expect(pair.serverStates == ["ESTABLISHED"])

        pair.server.kill(server, signal: Signal.sigkill.rawValue)
        for _ in 0..<50 { pair.settle(0.01); await Task.yield() }

        #expect(pair.wire.sent(.rst, in: pair.wire.fromServer))
        #expect(outcome.error == .connectionReset)
        #expect(pair.serverStates == [])
        #expect(pair.clientStates == [])
    }

    // MARK: - After a reset

    @Test func receiveAfterAResetDoesNotPark() {
        // A second receive on a connection the peer already reset must return
        // at once rather than wait for bytes that cannot come.
        let pair = Pair()
        final class Reads { var count = 0 }
        let reads = Reads()
        pair.server.spawn("server") { ctx in
            guard let listener = ctx.tcpSocket() else { return }
            ctx.tcpListen(listener, port: 80)
            ctx.tcpAccept(listener) { fd in
                ctx.tcpSend(fd, Array("unread".utf8))
                ctx.tcpRecv(fd) { _ in
                    reads.count += 1
                    ctx.tcpRecv(fd) { _ in
                        reads.count += 1
                        Self.parkForever(ctx)
                    }
                }
            }
        }
        pair.client.spawn("client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: pair.serverIP, port: 80) {
                ctx.schedule(after: 0.1) { ctx.exit(0) }
                Self.parkForever(ctx)
            }
        }
        pair.settle()
        #expect(reads.count == 2)
    }

    // MARK: - Through the shell

    @Test func interruptingNetcatClosesTheServerSide() {
        let sh = NetworkShell(ethernet: true)
        let peer = sh.attachPeer()
        let received = Received()
        peer.spawn("server") { ctx in
            guard let listener = ctx.tcpSocket() else { return }
            ctx.tcpListen(listener, port: 9000)
            ctx.tcpAccept(listener) { fd in
                received.accepted = true
                Self.readUntilEOF(ctx, fd, into: received) { Self.parkForever(ctx) }
            }
        }
        sh.loop.runUntilIdle()

        sh.run("nc 10.0.0.2 9000")
        #expect(received.accepted)
        #expect(!received.sawEOF)
        #expect(peer.netns.stack.snapshotTCP().map(\.state) == ["ESTABLISHED"])

        sh.kernel.interruptForeground(signal: Signal.sigint.rawValue)   // Ctrl-C
        sh.advance(0.5)

        #expect(received.sawEOF, "Ctrl-C on nc left the server side open")
        #expect(peer.netns.stack.snapshotTCP().map(\.state) == ["CLOSE_WAIT"])
        #expect(sh.kernel.netns.stack.snapshotTCP().map(\.state) == ["FIN_WAIT_2"])
        // The peer never closes its half; the orphan timeout releases ours.
        sh.advance(61)
        #expect(sh.kernel.netns.stack.snapshotTCP().isEmpty)
    }
}
