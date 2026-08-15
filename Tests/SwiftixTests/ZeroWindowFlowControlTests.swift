import Testing
@testable import Swiftix

/// End-to-end TCP zero-window flow control (R12). With a deliberately shrunk
/// Receive_Buffer_Capacity on the receiver, a fast sender fills the window,
/// stalls when the receiver advertises a Zero_Window, and resumes only after the
/// application drains the buffer and the receiver advertises a window > 0. The
/// sender never keeps more than `min(cwnd, peerWindow)` bytes outstanding, and the
/// transfer still completes in order. Everything runs on the logical-time
/// EventLoop over a lossless TestWire, matching the existing TCP test style.
@Suite("Zero-window flow control")
struct ZeroWindowFlowControlTests {

    /// Wire two kernels on the shared loop; return them plus B's IP.
    private func makePair(loop: EventLoop) -> (Kernel, Kernel, IPv4Address) {
        let macA = MACAddress("02:00:00:00:00:0a")!
        let macB = MACAddress("02:00:00:00:00:0b")!
        let ipA = IPv4Address(10, 0, 0, 1)
        let ipB = IPv4Address(10, 0, 0, 2)

        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let ifA = kernelA.netns.stack.configuredInterface(address: ipA, mac: macA)
        let ifB = kernelB.netns.stack.configuredInterface(address: ipB, mac: macB)
        TestWire.connect(kernelA.netns.stack, ifA, kernelB.netns.stack, ifB,
                        on: loop, latency: 0.005)
        kernelA.netns.stack.configuredNeighbor(ip: ipB, mac: macB)
        kernelB.netns.stack.configuredNeighbor(ip: ipA, mac: macA)
        return (kernelA, kernelB, ipB)
    }

    /// A full receiver advertises a Zero_Window, the sender stalls with buffered
    /// data (R12.1, R12.2), draining reopens the window (R12.3), and the transfer
    /// completes in order. Throughout, `FlightSize <= min(cwnd, peerWindow)`
    /// (R12.4).
    @Test func fullReceiverStallsSenderAndDrainingResumesIt() {
        let loop = EventLoop()
        let (kernelA, kernelB, ipB) = makePair(loop: loop)

        let listener = kernelB.netns.stack.listen(port: 80)
        let localPort: UInt16 = 50_300
        let client = kernelA.netns.stack.connect(localPort: localPort, to: ipB, remotePort: 80)

        // Complete the 3-way handshake.
        loop.advance(by: 0.5)
        guard let server = listener.dequeue() else {
            Issue.record("server connection was not accepted")
            return
        }

        // Shrink the receiver's buffer so a small payload fills it and forces a
        // Zero_Window. Set BEFORE any data flows.
        let capacity = 2_000
        server.setReceiveBufferCapacity(capacity)

        // The sender submits far more than the receiver can buffer at once.
        let total = 12_000
        let payload: [UInt8] = (0..<total).map { UInt8($0 & 0xFF) }
        client.send(payload)

        // Invariant sampler (R12.4): at every observation the sender keeps no more
        // than `min(cwnd, peerWindow)` bytes outstanding. The sender adopts each
        // freshly advertised window before deciding to transmit, and (on a lossless
        // wire) `cwnd` only grows, so this strict bound holds at every point rather
        // than only as a net-growth rule.
        var invariantHeld = true
        var worstFlight = 0
        var worstWindow = 0
        func sampleInvariant() {
            let cwnd = client.congestionControllerSnapshot.cwnd
            let peer = Int(client.peerAdvertisedWindow)
            let limit = Swift.min(cwnd, peer)
            let flight = client.flightSize
            if invariantHeld, flight > limit {
                invariantHeld = false
                worstFlight = flight
                worstWindow = limit
            }
        }

        // Phase 1: let the fast sender fill the receiver until it advertises a
        // Zero_Window (R12.1). The app never reads here, so buffered bytes pile up
        // to capacity and the sender stalls with data still to send (R12.2).
        var iterations = 0
        while server.advertisedWindow > 0 && iterations < 100_000 {
            sampleInvariant()
            loop.advance(by: 0.001)
            sampleInvariant()
            iterations += 1
            if client.sendBufferIsEmpty && client.sndFullyAcked { break }
        }
        // Let the client learn the Zero_Window (its advertising ACK is in flight).
        loop.advance(by: 0.05)
        sampleInvariant()

        let sawZeroWindow = (server.advertisedWindow == 0)          // R12.1
        let sawSenderStalled = !client.sendBufferIsEmpty            // R12.2: data still queued

        // The Zero_Window path was actually exercised (R12.1, R12.2).
        #expect(sawZeroWindow, "receiver never advertised a Zero_Window; the stall path was not exercised")
        #expect(sawSenderStalled, "sender never stalled with buffered data behind a Zero_Window")
        // Behind a Zero_Window the sender transmits no new data (R12.2): outstanding
        // data cannot exceed the (zero) advertised window the client has learned.
        #expect(client.flightSize <= Int(client.peerAdvertisedWindow))

        // Phase 2: the app drains the receiver; each drain from a full buffer emits a
        // window-update ACK that reopens the window and wakes the stalled sender
        // (R12.3), so the whole stream eventually arrives.
        var received: [UInt8] = []
        let step = 0.001
        iterations = 0
        while received.count < total && iterations < 200_000 {
            sampleInvariant()
            received.append(contentsOf: server.read(max: 700))
            loop.advance(by: step)
            sampleInvariant()
            iterations += 1
        }
        received.append(contentsOf: server.read(max: total))
        loop.advance(by: 60.0)   // drain remaining timers after transfer completes
        received.append(contentsOf: server.read(max: total))
        sampleInvariant()

        // The advertised window never exceeded the shrunk capacity (R11.4).
        #expect(server.advertisedWindow <= UInt16(capacity))

        // The stall resolved and the whole stream arrived in order (R12.3).
        #expect(received.count == total, "expected \(total) bytes, delivered \(received.count)")
        #expect(received == payload, "delivered stream did not match the sent stream")

        // The window invariant held at every sampled observation (R12.4).
        #expect(invariantHeld,
                "FlightSize \(worstFlight) exceeded min(cwnd, peerWindow) \(worstWindow)")

        // The connection is quiescent: everything acked and the Send_Buffer drained.
        #expect(client.sndFullyAcked)
        #expect(client.sendBufferIsEmpty)
    }

    /// While the peer advertises a Zero_Window the sender transmits no new data
    /// (R12.2): with the receiver never draining, the sender fills exactly the
    /// advertised window and then holds, leaving data buffered.
    @Test func senderTransmitsNothingWhilePeerWindowIsZero() {
        let loop = EventLoop()
        let (kernelA, kernelB, ipB) = makePair(loop: loop)

        let listener = kernelB.netns.stack.listen(port: 80)
        let localPort: UInt16 = 50_301
        let client = kernelA.netns.stack.connect(localPort: localPort, to: ipB, remotePort: 80)

        loop.advance(by: 0.5)
        guard let server = listener.dequeue() else {
            Issue.record("server connection was not accepted")
            return
        }

        let capacity = 1_500
        server.setReceiveBufferCapacity(capacity)

        let total = 10_000
        let payload: [UInt8] = (0..<total).map { UInt8($0 & 0xFF) }
        client.send(payload)

        // Let the sender push until it stalls; never drain the receiver. The
        // persist interval (1.0s) far exceeds the settle time, so no probe fires
        // and the sender simply parks on the Zero_Window.
        loop.advance(by: 0.5)

        // The receiver is full and advertises a Zero_Window (R12.1).
        #expect(server.advertisedWindow == 0)
        // The sender still holds unsent data (it did not push past the window, R12.2).
        #expect(!client.sendBufferIsEmpty)
        // Outstanding data never exceeds the peer's advertised window (R12.4).
        #expect(client.flightSize <= Int(client.peerAdvertisedWindow))
        // The receiver never buffered more than its capacity (R11.4).
        #expect(server.advertisedWindow <= UInt16(capacity))

        // Now drain fully: the reopened window lets the rest through (R12.3).
        var received: [UInt8] = []
        var iterations = 0
        while received.count < total && iterations < 20_000 {
            received.append(contentsOf: server.read(max: capacity))
            loop.advance(by: 0.05)
            iterations += 1
        }
        received.append(contentsOf: server.read(max: total))

        #expect(received == payload)
        #expect(client.sndFullyAcked)
        #expect(client.sendBufferIsEmpty)
    }
}
