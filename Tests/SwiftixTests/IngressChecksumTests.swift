import Testing
@testable import Swiftix

/// Ingress transport-checksum verification (R8). Task 4 proved the stack stamps a
/// correct checksum onto every emitted TCP/UDP/ICMP frame; this suite proves the
/// receive path *verifies* those checksums and drops corrupted segments before they
/// touch protocol state:
///
///   - a clean wired transfer (TCP + ping + UDP) still succeeds with verification on,
///     because egress now stamps valid checksums (R8.1, R8.6);
///   - a corrupted TCP segment is dropped without altering connection state and the
///     receiving interface's `drops` counter increments (R8.1, R8.2, R13.4);
///   - a UDP datagram whose checksum field is zero is accepted without verification
///     (R8.4), and every datagram reaches a binary accept/drop decision (R8.5);
///   - a corrupted UDP datagram (non-zero checksum) and a corrupted ICMP echo are
///     dropped (R8.3, R8.6).
///
/// All scenarios run on the logical-time `EventLoop` with a wire that can mutate a
/// chosen frame's bytes before delivery, so corruption is injected deterministically.
@Suite("Ingress transport checksums")
struct IngressChecksumTests {

    // MARK: - Frame helpers (test-only, via @testable parsing)

    private func ipProto(_ frame: PacketBuffer) -> UInt8? {
        guard let eth = EthernetFrame.parseHeader(frame),
              eth.etherType == EtherType.ipv4.rawValue,
              let (ip, _) = IPv4Packet.parse(EthernetFrame.payload(frame)) else { return nil }
        return ip.proto
    }

    /// True when the frame carries a data-bearing TCP segment (non-empty payload).
    private func isTCPData(_ frame: PacketBuffer) -> Bool {
        guard let eth = EthernetFrame.parseHeader(frame),
              eth.etherType == EtherType.ipv4.rawValue,
              let (ip, ipPayload) = IPv4Packet.parse(EthernetFrame.payload(frame)),
              ip.proto == IPProtocol.tcp.rawValue,
              let (_, payload) = TCPSegment.parse(ipPayload) else { return false }
        return !payload.isEmpty
    }

    /// Offset of the transport segment within the raw frame (eth header + IPv4 IHL).
    private func transportOffset(_ bytes: [UInt8]) -> Int? {
        guard bytes.count > EthernetFrame.headerLength else { return nil }
        let ihl = Int(bytes[EthernetFrame.headerLength] & 0x0F) * 4
        return EthernetFrame.headerLength + ihl
    }

    /// Flip the last byte of the frame — for a data-bearing transport message this
    /// mutates the payload, so the stamped transport checksum no longer verifies.
    private func corruptLastByte(_ frame: PacketBuffer) -> PacketBuffer {
        var bytes = frame.bytes
        guard !bytes.isEmpty else { return frame }
        bytes[bytes.count - 1] ^= 0xFF
        return PacketBuffer(bytes)
    }

    /// Zero the UDP checksum field (offset 6-7 of the UDP datagram) so the receiver
    /// must accept the datagram without verification (R8.4).
    private func zeroUDPChecksum(_ frame: PacketBuffer) -> PacketBuffer {
        var bytes = frame.bytes
        guard let off = transportOffset(bytes), bytes.count >= off + 8 else { return frame }
        bytes[off + 6] = 0
        bytes[off + 7] = 0
        return PacketBuffer(bytes)
    }

    // MARK: - Wire

    /// A controllable stand-in for the topology layer: A→B frames pass through
    /// `interceptAtoB`, which may return the frame unchanged, a mutated copy, or
    /// `nil` to drop it; B→A frames are delivered verbatim. Both directions schedule
    /// delivery after `latency` on the logical loop.
    private func connect(_ stackA: NetworkStack, _ ifA: NetworkStack.Interface,
                         _ stackB: NetworkStack, _ ifB: NetworkStack.Interface,
                         on loop: EventLoop, latency: Double,
                         interceptAtoB: @escaping (PacketBuffer) -> PacketBuffer?) {
        ifA.onEgress = { frame in
            guard let out = interceptAtoB(frame) else { return }
            loop.schedule(after: latency) { stackB.receive(out, on: ifB) }
        }
        ifB.onEgress = { frame in
            loop.schedule(after: latency) { stackA.receive(frame, on: ifA) }
        }
    }

    private struct Pair {
        let kernelA: Kernel, kernelB: Kernel
        let stackA: NetworkStack, stackB: NetworkStack
        let ifA: NetworkStack.Interface, ifB: NetworkStack.Interface
        let ipA: IPv4Address, ipB: IPv4Address
    }

    private func makePair(loop: EventLoop, latency: Double = 0.01,
                          interceptAtoB: @escaping (PacketBuffer) -> PacketBuffer? = { $0 }) -> Pair {
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let stackA = kernelA.netns.stack
        let stackB = kernelB.netns.stack
        let ifA = stackA.configuredInterface(address: ipA, mac: macA)
        let ifB = stackB.configuredInterface(address: ipB, mac: macB)
        connect(stackA, ifA, stackB, ifB, on: loop, latency: latency, interceptAtoB: interceptAtoB)
        stackA.configuredNeighbor(ip: ipB, mac: macB)
        stackB.configuredNeighbor(ip: ipA, mac: macA)
        return Pair(kernelA: kernelA, kernelB: kernelB, stackA: stackA, stackB: stackB,
                    ifA: ifA, ifB: ifB, ipA: ipA, ipB: ipB)
    }

    // MARK: - (a) Clean transfer still succeeds with verification on

    @Test func cleanTCPTransferSucceedsWithVerification() {
        let loop = EventLoop()
        let p = makePair(loop: loop)

        final class Capture { var serverGot: [UInt8] = [] }
        let captured = Capture()
        p.kernelB.spawn("tcp-server") { ctx in
            guard let listenFD = ctx.tcpSocket() else { return }
            ctx.tcpListen(listenFD, port: 80)
            ctx.tcpAccept(listenFD) { acceptedFD in
                ctx.tcpRecv(acceptedFD) { bytes in captured.serverGot = bytes }
            }
        }
        p.kernelA.spawn("tcp-client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: p.ipB, port: 80) {
                ctx.tcpSend(fd, Array("hello-tcp".utf8))
            }
        }

        loop.advance(by: 1.0)
        #expect(String(decoding: captured.serverGot, as: UTF8.self) == "hello-tcp")
        #expect(p.ifB.counters.drops == 0)   // nothing dropped when checksums are valid
    }

    @Test func cleanPingSucceedsWithVerification() {
        let loop = EventLoop()
        let p = makePair(loop: loop)

        final class Capture { var replies: [Programs.PingOutcome] = [] }
        let captured = Capture()
        p.kernelA.spawn("ping", Programs.ping(to: p.ipB, count: 1) { outcome in
            captured.replies.append(outcome)
        })

        loop.advance(by: 1.0)
        #expect(captured.replies.count == 1)
        if case .reply = captured.replies.first { } else {
            Issue.record("expected a ping reply, got \(String(describing: captured.replies.first))")
        }
        #expect(p.ifA.counters.drops == 0)
        #expect(p.ifB.counters.drops == 0)
    }

    @Test func cleanUDPExchangeSucceedsWithVerification() {
        let loop = EventLoop()
        let p = makePair(loop: loop)

        final class Capture { var reply: [UInt8] = []; var replied = false }
        let captured = Capture()
        p.kernelB.spawn("udp-echo") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: p.ipB, port: 7000)
            func serve() {
                ctx.recvfrom(fd) { bytes, address, port in
                    ctx.sendto(fd, bytes, to: address, port: port)
                    serve()
                }
            }
            serve()
        }
        p.kernelA.spawn("udp-client") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: p.ipA, port: 5000)
            ctx.sendto(fd, Array("ping".utf8), to: p.ipB, port: 7000)
            ctx.recvfrom(fd) { bytes, _, _ in
                captured.reply = bytes
                captured.replied = true
            }
        }

        loop.advance(by: 0.5)
        #expect(captured.replied)
        #expect(String(decoding: captured.reply, as: UTF8.self) == "ping")
        #expect(p.ifB.counters.drops == 0)
    }

    // MARK: - (b) Corrupted TCP segment dropped, connection state unchanged

    @Test func corruptedTCPSegmentDroppedAndStateUnchanged() {
        let loop = EventLoop()
        // Corrupt exactly the first data-bearing TCP segment A→B (flip a payload
        // byte). Its stamped checksum then fails verification on ingress.
        var corruptArmed = true
        let p = makePair(loop: loop, latency: 0.01) { [self] frame in
            if corruptArmed, isTCPData(frame) {
                corruptArmed = false
                return corruptLastByte(frame)
            }
            return frame
        }

        let listener = p.stackB.listen(port: 80)
        let client = p.stackA.connect(localPort: 50_000, to: p.ipB, remotePort: 80)
        loop.advance(by: 0.5)   // handshake

        guard let server = listener.dequeue() else {
            Issue.record("server connection was not established")
            return
        }
        let windowBefore = server.advertisedWindow
        let dropsBefore = p.ifB.counters.drops

        let payload = Array("state-must-not-change".utf8)
        client.send(payload)

        // Deliver the corrupted segment but stop before the retransmit timer (RTO
        // >= 0.2s after handshake RTT sampling) can fire.
        loop.advance(by: 0.05)

        // The corrupted segment was dropped: counted as a drop, no bytes buffered,
        // and the advertised window (a proxy for rcvNxt/buffer state) is unchanged.
        #expect(p.ifB.counters.drops == dropsBefore + 1)
        #expect(server.hasBufferedData == false)
        #expect(server.read(max: 1 << 16) == [])
        #expect(server.advertisedWindow == windowBefore)

        // The connection state was genuinely untouched, so the sender's retransmit
        // (uncorrupted this time) delivers the payload in order and intact.
        loop.advance(by: 2.0)
        loop.runUntilIdle()
        #expect(server.read(max: 1 << 16) == payload)
    }

    // MARK: - (c) UDP zero-checksum datagram is accepted

    @Test func udpZeroChecksumDatagramAccepted() {
        let loop = EventLoop()
        // Zero the UDP checksum field on the client's datagram before delivery.
        let p = makePair(loop: loop) { [self] frame in
            if ipProto(frame) == IPProtocol.udp.rawValue { return zeroUDPChecksum(frame) }
            return frame
        }

        final class Capture { var got: [UInt8] = []; var received = false }
        let captured = Capture()
        p.kernelB.spawn("udp-sink") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: p.ipB, port: 7000)
            ctx.recvfrom(fd) { bytes, _, _ in
                captured.got = bytes
                captured.received = true
            }
        }
        p.kernelA.spawn("udp-client") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: p.ipA, port: 5000)
            ctx.sendto(fd, Array("no-checksum".utf8), to: p.ipB, port: 7000)
        }

        loop.advance(by: 0.5)
        #expect(captured.received)
        #expect(String(decoding: captured.got, as: UTF8.self) == "no-checksum")
        // Accepted without verification => not counted as a drop (R8.4, R8.5).
        #expect(p.ifB.counters.drops == 0)
    }

    // MARK: - (d) Corrupted UDP (non-zero checksum) and corrupted ICMP are dropped

    @Test func corruptedUDPDatagramDropped() {
        let loop = EventLoop()
        // Flip a payload byte of the client's UDP datagram; its stamped (non-zero)
        // checksum then fails verification.
        let p = makePair(loop: loop) { [self] frame in
            if ipProto(frame) == IPProtocol.udp.rawValue { return corruptLastByte(frame) }
            return frame
        }

        final class Capture { var received = false }
        let captured = Capture()
        p.kernelB.spawn("udp-sink") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: p.ipB, port: 7000)
            ctx.recvfrom(fd) { _, _, _ in captured.received = true }
        }
        p.kernelA.spawn("udp-client") { ctx in
            guard let fd = ctx.socket() else { return }
            ctx.bind(fd, address: p.ipA, port: 5000)
            ctx.sendto(fd, Array("corrupt-me".utf8), to: p.ipB, port: 7000)
        }

        loop.advance(by: 0.5)
        #expect(captured.received == false)          // dropped, never delivered (R8.3)
        #expect(p.ifB.counters.drops == 1)           // counted as a drop (R13.4)
    }

    @Test func corruptedICMPEchoDropped() {
        let loop = EventLoop()
        // Flip a byte of the ICMP echo request A→B so its checksum fails.
        let p = makePair(loop: loop) { [self] frame in
            if ipProto(frame) == IPProtocol.icmp.rawValue { return corruptLastByte(frame) }
            return frame
        }

        final class Capture { var outcomes: [Programs.PingOutcome] = [] }
        let captured = Capture()
        p.kernelA.spawn("ping", Programs.ping(to: p.ipB, count: 1, timeout: 0.5) { outcome in
            captured.outcomes.append(outcome)
        })

        loop.advance(by: 1.0)
        #expect(captured.outcomes.count == 1)
        if case .timeout = captured.outcomes.first { } else {
            Issue.record("expected a ping timeout after the request was dropped, got \(String(describing: captured.outcomes.first))")
        }
        #expect(p.ifB.counters.drops >= 1)           // the corrupted echo request was dropped (R8.6)
    }
}
