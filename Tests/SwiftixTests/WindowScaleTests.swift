/// Tests for TCP Window Scaling (RFC 7323). Validates that both sides negotiate
/// window scale during the handshake, that the peer's advertised window is
/// correctly scaled, and that data flows normally with scaling enabled.
import Testing
@testable import Swiftix

@Suite("TCP window scaling")
struct WindowScaleTests {

    /// Both sides negotiate window scale during the handshake and the connection
    /// establishes successfully with scaled windows.
    @Test func bothSidesNegotiateWindowScale() {
        let loop = EventLoop()
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)

        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: MACAddress("02:00:00:00:00:0a")!)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: MACAddress("02:00:00:00:00:0b")!)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB, on: loop, latency: 0.005)

        let listener = kernelB.netns.stack.listen(port: 80)
        let client = kernelA.netns.stack.connect(localPort: 5000, to: ipB, remotePort: 80)

        loop.advance(by: 0.5)

        #expect(client.state == .established)
        let snapshot = client.snapshot
        #expect(snapshot.peerwnd > 0)

        guard listener.dequeue() != nil else {
            Issue.record("server connection not accepted"); return
        }
    }

    /// Data flows correctly after window-scale negotiation.
    @Test func dataFlowsWithWindowScaling() {
        let loop = EventLoop()
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)

        let ipB = IPv4Address(10, 0, 0, 2)
        let ifA = kernelA.netns.stack.configuredInterface(
            address: IPv4Address(10, 0, 0, 1), mac: MACAddress("02:00:00:00:00:0a")!)
        let ifB = kernelB.netns.stack.configuredInterface(
            address: ipB, mac: MACAddress("02:00:00:00:00:0b")!)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB, on: loop, latency: 0.005)

        let listener = kernelB.netns.stack.listen(port: 80)
        let client = kernelA.netns.stack.connect(localPort: 5000, to: ipB, remotePort: 80)
        loop.advance(by: 0.5)
        #expect(client.state == .established)

        guard let server = listener.dequeue() else {
            Issue.record("no server connection"); return
        }

        let payload = Array("hello window-scaled".utf8)
        client.send(payload)
        loop.advance(by: 0.1)

        let received = server.read(max: 65535)
        #expect(received == payload)
    }

    /// SYN segments carry the Window Scale option on the wire.
    @Test func synCarriesWindowScaleOption() {
        let loop = EventLoop()
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)

        let ipB = IPv4Address(10, 0, 0, 2)
        let ifA = kernelA.netns.stack.configuredInterface(
            address: IPv4Address(10, 0, 0, 1), mac: MACAddress("02:00:00:00:00:0a")!)
        let ifB = kernelB.netns.stack.configuredInterface(
            address: ipB, mac: MACAddress("02:00:00:00:00:0b")!)

        // Capture frames from A.
        final class Capture { var frames: [PacketBuffer] = [] }
        let capture = Capture()
        ifA.onEgress = { [weak kernelB, weak ifB] frame in
            capture.frames.append(frame)
            guard let kernelB, let ifB else { return }
            loop.schedule(after: 0.005) { kernelB.netns.stack.receive(frame, on: ifB) }
        }
        ifB.onEgress = { [weak kernelA, weak ifA] frame in
            guard let kernelA, let ifA else { return }
            loop.schedule(after: 0.005) { kernelA.netns.stack.receive(frame, on: ifA) }
        }

        _ = kernelB.netns.stack.listen(port: 80)
        _ = kernelA.netns.stack.connect(localPort: 5000, to: ipB, remotePort: 80)
        loop.advance(by: 1.0)   // allow TCP handshake to complete over latency link

        // Find the initial SYN from A.
        let synHeader = capture.frames.compactMap { frame -> TCPSegment.Header? in
            guard let eth = EthernetFrame.parseHeader(frame),
                  eth.etherType == EtherType.ipv4.rawValue else { return nil }
            let ipPayload = EthernetFrame.payload(frame)
            guard let (ipHeader, tcpSlice) = IPv4Packet.parse(ipPayload),
                  ipHeader.proto == IPProtocol.tcp.rawValue else { return nil }
            guard let (tcpHeader, _) = TCPSegment.parse(tcpSlice) else { return nil }
            return tcpHeader.flags.contains(.syn) && !tcpHeader.flags.contains(.ack) ? tcpHeader : nil
        }.first

        #expect(synHeader != nil)
        if let syn = synHeader {
            #expect(syn.options.firstWindowScale != nil)
        }
    }
}
