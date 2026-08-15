/// Tests for TCP Selective Acknowledgment (RFC 2018). Validates SACK negotiation
/// during the handshake, out-of-order buffering and reassembly on the receiver,
/// SACK block generation in ACKs, and sender-side SACK scoreboard marking.
import Testing
@testable import Swiftix

@Suite("TCP SACK")
struct SACKTests {

    // MARK: - Receiver reassembly

    @Test func receiverReassemblesOutOfOrderSegments() {
        var sack = TCPSACKReceiver()
        sack.enabled = true

        // Simulate segments arriving out of order with a gap at 200.
        // rcvNxt is assumed to be at 200 (previous in-order data consumed).
        sack.cacheOutOfOrder(sequence: 300, data: [3, 3, 3, 3, 3])  // 5 bytes at 300
        sack.cacheOutOfOrder(sequence: 200, data: Array(repeating: 2, count: 100))  // 100 bytes at 200

        // Reassemble from rcvNxt=200: both the segment at 200 (100 bytes) and the
        // now-contiguous segment at 300 (5 bytes) should come out together.
        let (data, newRcvNxt) = sack.reassemble(rcvNxt: 200)
        #expect(data.count == 105)   // 100 + 5
        #expect(newRcvNxt == 305)
        #expect(!sack.hasOutOfOrderData)
    }

    @Test func sackBlocksReflectOutOfOrderRanges() {
        var sack = TCPSACKReceiver()
        sack.enabled = true

        // rcvNxt = 100, out-of-order segment at 200 (length 50).
        sack.cacheOutOfOrder(sequence: 200, data: Array(repeating: 0xAA, count: 50))

        let blocks = sack.sackBlocks(rcvNxt: 100)
        #expect(blocks.count == 1)
        #expect(blocks[0].left == 200)
        #expect(blocks[0].right == 250)
    }

    @Test func sackBlocksMergeAdjacentSegments() {
        var sack = TCPSACKReceiver()
        sack.enabled = true

        sack.cacheOutOfOrder(sequence: 200, data: Array(repeating: 0, count: 50))
        sack.cacheOutOfOrder(sequence: 250, data: Array(repeating: 0, count: 50))

        let blocks = sack.sackBlocks(rcvNxt: 100)
        #expect(blocks.count == 1)
        #expect(blocks[0].left == 200)
        #expect(blocks[0].right == 300)
    }

    @Test func noSackBlocksWhenDisabled() {
        var sack = TCPSACKReceiver()
        sack.enabled = false
        sack.cacheOutOfOrder(sequence: 200, data: [1, 2, 3])
        let blocks = sack.sackBlocks(rcvNxt: 100)
        #expect(blocks.isEmpty)
    }

    // MARK: - Sender scoreboard

    @Test func markSackedIdentifiesFullyCoveredSegments() {
        var queue: [TCPOutgoingSegment] = [
            TCPOutgoingSegment(sequence: 100, flags: [.ack], payload: Array(repeating: 0, count: 50),
                               sentAt: 0, retransmitted: false),
            TCPOutgoingSegment(sequence: 150, flags: [.ack], payload: Array(repeating: 0, count: 50),
                               sentAt: 0, retransmitted: false),
            TCPOutgoingSegment(sequence: 200, flags: [.ack], payload: Array(repeating: 0, count: 50),
                               sentAt: 0, retransmitted: false),
        ]

        // SACK block covers segment at 150–200.
        let blocks = [TCPOption.SACKBlock(left: 150, right: 200)]
        let marked = TCPSACKReceiver.markSacked(retransmitQueue: &queue, sackBlocks: blocks)

        #expect(marked == true)
        #expect(queue[0].sacked == false)  // 100–150 not covered
        #expect(queue[1].sacked == true)   // 150–200 fully covered
        #expect(queue[2].sacked == false)  // 200–250 not covered
    }

    // MARK: - End-to-end negotiation

    @Test func sackPermittedNegotiatedInHandshake() {
        let loop = EventLoop()
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)

        let ipB = IPv4Address(10, 0, 0, 2)
        let ifA = kernelA.netns.stack.configuredInterface(
            address: IPv4Address(10, 0, 0, 1), mac: MACAddress("02:00:00:00:00:0a")!)
        let ifB = kernelB.netns.stack.configuredInterface(
            address: ipB, mac: MACAddress("02:00:00:00:00:0b")!)

        // Capture SYN from A to verify SACK-Permitted option.
        final class Capture { var synOptions: [TCPOption] = [] }
        let capture = Capture()
        ifA.onEgress = { [weak kernelB, weak ifB] frame in
            // Parse TCP options from SYN.
            if let eth = EthernetFrame.parseHeader(frame),
               eth.etherType == EtherType.ipv4.rawValue {
                let ipPayload = EthernetFrame.payload(frame)
                if let (ipHeader, tcpSlice) = IPv4Packet.parse(ipPayload),
                   ipHeader.proto == IPProtocol.tcp.rawValue,
                   let (tcpHeader, _) = TCPSegment.parse(tcpSlice),
                   tcpHeader.flags.contains(.syn), !tcpHeader.flags.contains(.ack) {
                    capture.synOptions = tcpHeader.options
                }
            }
            guard let kernelB, let ifB else { return }
            loop.schedule(after: 0.005) { kernelB.netns.stack.receive(frame, on: ifB) }
        }
        ifB.onEgress = { [weak kernelA, weak ifA] frame in
            guard let kernelA, let ifA else { return }
            loop.schedule(after: 0.005) { kernelA.netns.stack.receive(frame, on: ifA) }
        }

        _ = kernelB.netns.stack.listen(port: 80)
        _ = kernelA.netns.stack.connect(localPort: 5000, to: ipB, remotePort: 80)
        loop.advance(by: 0.1)

        #expect(capture.synOptions.hasSACKPermitted)
    }

    // MARK: - End-to-end out-of-order delivery with SACK

    @Test func outOfOrderDataReassembledWithSACK() {
        let loop = EventLoop()
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)

        let ipB = IPv4Address(10, 0, 0, 2)
        let ifA = kernelA.netns.stack.configuredInterface(
            address: IPv4Address(10, 0, 0, 1), mac: MACAddress("02:00:00:00:00:0a")!)
        let ifB = kernelB.netns.stack.configuredInterface(
            address: ipB, mac: MACAddress("02:00:00:00:00:0b")!)
        // Drop the first data segment (simulating loss), so the second arrives OOO.
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB,
                         on: loop, latency: 0.005, dropFirstTCPData: true)

        let listener = kernelB.netns.stack.listen(port: 80)
        let client = kernelA.netns.stack.connect(localPort: 5000, to: ipB, remotePort: 80)
        loop.advance(by: 0.5)
        #expect(client.state == .established)

        guard let server = listener.dequeue() else {
            Issue.record("no server connection"); return
        }

        // Send two segments worth of data.
        let seg1 = Array(repeating: UInt8(0xAA), count: 100)
        let seg2 = Array(repeating: UInt8(0xBB), count: 100)
        client.send(seg1 + seg2)

        // Advance enough for the retransmit to fire (the first segment was dropped).
        loop.advance(by: 5.0)

        // After retransmit + reassembly, server should have all 200 bytes in order.
        let received = server.read(max: 65535)
        #expect(received == seg1 + seg2)
    }
}
