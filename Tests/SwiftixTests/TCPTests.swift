import Testing
@testable import Swiftix

@Suite("TCP v1")
struct TCPTests {

    /// Full path: client connect → server accept → client send → server recv,
    /// in order, over the (test-wired) link with a 3-way handshake.
    @Test func handshakeAndDataTransfer() {
        let loop = EventLoop()
        let (kernelA, kernelB, ipB) = makePair(loop: loop, lossyFirstData: false)

        final class Capture {
            var connected = false
            var serverGot: [UInt8] = []
        }
        let captured = Capture()

        kernelB.spawn("tcp-server") { ctx in
            guard let listenFD = ctx.tcpSocket() else { return }
            ctx.tcpListen(listenFD, port: 80)
            ctx.tcpAccept(listenFD) { acceptedFD in
                ctx.tcpRecv(acceptedFD) { bytes in
                    captured.serverGot = bytes
                }
            }
        }
        kernelA.spawn("tcp-client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: ipB, port: 80) {
                captured.connected = true
                ctx.tcpSend(fd, Array("hello-tcp".utf8))
            }
        }

        loop.advance(by: 1.0)

        #expect(captured.connected)
        #expect(String(decoding: captured.serverGot, as: UTF8.self) == "hello-tcp")
    }

    /// The first data segment is dropped on the wire; the RTO timer fires and the
    /// retransmission gets the data through.
    @Test func retransmitsDroppedDataSegment() {
        let loop = EventLoop()
        let (kernelA, kernelB, ipB) = makePair(loop: loop, lossyFirstData: true)

        final class Capture { var serverGot: [UInt8] = [] }
        let captured = Capture()

        kernelB.spawn("tcp-server") { ctx in
            guard let listenFD = ctx.tcpSocket() else { return }
            ctx.tcpListen(listenFD, port: 80)
            ctx.tcpAccept(listenFD) { acceptedFD in
                ctx.tcpRecv(acceptedFD) { bytes in
                    captured.serverGot = bytes
                }
            }
        }
        kernelA.spawn("tcp-client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: ipB, port: 80) {
                ctx.tcpSend(fd, Array("retry-me".utf8))
            }
        }

        loop.advance(by: 2.0)   // > RTO (0.2s) so the retransmission happens

        #expect(String(decoding: captured.serverGot, as: UTF8.self) == "retry-me")
    }

    /// Sender-side buffering + segmentation (R7): a multi-KB payload (many SMSS
    /// worth) is submitted in one `send`, buffered, and drained across the window
    /// as ACKs open it. Over a clean link the receiver must deliver exactly the
    /// same bytes, in order, and the sender's Send_Buffer must end empty (R7.5).
    @Test func bufferedMultiSegmentSend() {
        let loop = EventLoop()
        let (kernelA, kernelB, ipB) = makePair(loop: loop, lossyFirstData: false)

        // ~8 KB: well beyond one SMSS (512), so pump() must emit many segments.
        let payload: [UInt8] = (0..<8192).map { UInt8($0 & 0xFF) }

        final class Capture {
            var serverGot: [UInt8] = []
        }
        let captured = Capture()

        kernelB.spawn("tcp-server") { ctx in
            guard let listenFD = ctx.tcpSocket() else { return }
            ctx.tcpListen(listenFD, port: 80)
            ctx.tcpAccept(listenFD) { acceptedFD in
                // Re-arm recv until the full payload has been delivered in order.
                func pump() {
                    ctx.tcpRecv(acceptedFD) { bytes in
                        guard !bytes.isEmpty else { return }   // EOF
                        captured.serverGot.append(contentsOf: bytes)
                        if captured.serverGot.count < payload.count { pump() }
                    }
                }
                pump()
            }
        }
        kernelA.spawn("tcp-client") { ctx in
            guard let fd = ctx.tcpSocket() else { return }
            ctx.tcpConnect(fd, to: ipB, port: 80) {
                ctx.tcpSend(fd, payload)
            }
        }

        loop.advance(by: 10.0)   // plenty of RTTs to drain the whole buffer

        #expect(captured.serverGot == payload)                       // R8.1 in-order, complete
        #expect(captured.serverGot.count == payload.count)
        // The sender's Send_Buffer must be fully drained (R7.5).
        let senderBuffersEmpty = kernelA.netns.stack.tcpConnectionList.allSatisfy { $0.sendBufferIsEmpty }
        #expect(senderBuffersEmpty)
    }

    /// TCP segment build/parse round-trip.
    @Test func segmentRoundTrip() {
        let segment = TCPSegment.build(sourcePort: 1234, destinationPort: 80,
                                    sequence: 1000, acknowledgment: 2000,
                                    flags: [.syn, .ack], window: 0xFFFF,
                                    payload: [7, 8, 9])
        guard let (header, payload) = TCPSegment.parse(segment[...]) else {
            Issue.record("TCP parse failed")
            return
        }
        #expect(header.sourcePort == 1234)
        #expect(header.destinationPort == 80)
        #expect(header.sequence == 1000)
        #expect(header.acknowledgment == 2000)
        #expect(header.flags.contains(.syn))
        #expect(header.flags.contains(.ack))
        #expect(Array(payload) == [7, 8, 9])
    }

    // MARK: - Helpers

    private func makePair(loop: EventLoop, lossyFirstData: Bool) -> (Kernel, Kernel, IPv4Address) {
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)

        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB,
                        on: loop, latency: 0.005, dropFirstTCPData: lossyFirstData)
        kernelA.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        kernelB.netns.stack.configuredNeighbor(ip: ipA, mac: macA)
        return (kernelA, kernelB, ipB)
    }
}
