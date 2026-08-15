import Testing
@testable import Swiftix

/// Buffer-derived receive-window advertisement (R11). The advertised
/// Receive_Window carried in every outgoing TCP header must equal the free space
/// in the Receive_Buffer (capacity minus buffered bytes): it falls as data lands
/// in the buffer (R11.3), rises as the app consumes it (R11.2), never exceeds the
/// capacity (R11.4), and is surfaced through `snapshotTCP()` / `/proc/net/tcp` as
/// `rwnd` (local) and `peerwnd` (peer). Everything runs on the logical-time
/// EventLoop over a TestWire, matching the existing TCP test style.
@Suite("Receive window advertisement")
struct ReceiveWindowTests {

    private let capacity = 0xFFFF

    /// Wire two kernels together on the shared loop and return them plus B's IP.
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

    /// Locate a `snapshotTCP()` row by local port.
    private func row(_ stack: NetworkStack, localPort: UInt16) -> TCPSnapshot? {
        stack.snapshotTCP().first { $0.localPort == localPort }
    }

    /// Read `/proc/net/tcp` as text from a process spawned on `kernel`.
    private func readProcNetTCP(_ kernel: Kernel, loop: EventLoop) -> String {
        final class Capture { var text = "" }
        let captured = Capture()
        kernel.spawn("reader") { ctx in
            guard let fd = ctx.open("/proc/net/tcp") else { return }
            captured.text = String(decoding: ctx.read(fd, max: 65535), as: UTF8.self)
            ctx.close(fd)
        }
        loop.runUntilIdle()
        return captured.text
    }

    /// The advertised window tracks Receive_Buffer occupancy: it starts at full
    /// capacity, shrinks by exactly the number of buffered-but-unconsumed bytes as
    /// data is delivered (R11.1, R11.3), and returns to capacity once the app
    /// drains the buffer (R11.2). It is never greater than capacity (R11.4).
    @Test func advertisedWindowTracksBufferOccupancy() {
        let loop = EventLoop()
        let (kernelA, kernelB, ipB) = makePair(loop: loop)

        let listener = kernelB.netns.stack.listen(port: 80)
        let localPort: UInt16 = 50_200
        let client = kernelA.netns.stack.connect(localPort: localPort, to: ipB, remotePort: 80)

        // Complete the 3-way handshake.
        loop.advance(by: 0.5)
        guard let server = listener.dequeue() else {
            Issue.record("server connection was not accepted")
            return
        }

        // Empty receive buffer => full window on both ends (R11.1, R11.4).
        #expect(server.advertisedWindow == UInt16(capacity))
        #expect(server.advertisedWindow <= UInt16(capacity))

        // Send data but DO NOT let the server app read it: the bytes sit in the
        // Receive_Buffer, so the server's advertised window must drop by exactly
        // that many bytes (R11.3).
        let chunk = 1000
        let payload: [UInt8] = (0..<chunk).map { UInt8($0 & 0xFF) }
        client.send(payload)
        loop.advance(by: 0.5)

        #expect(server.hasBufferedData)
        #expect(server.advertisedWindow == UInt16(capacity - chunk))   // R11.3

        // The client learns the server's shrunken window via the ACKs (peerwnd).
        #expect(client.peerAdvertisedWindow == UInt16(capacity - chunk))

        // The app consumes half the buffered bytes: the window must rise by that
        // many on the next segment the receiver sends (R11.2). Force a segment by
        // sending one more byte from the client and letting the server ACK it.
        let consumed = 400
        _ = server.read(max: consumed)
        #expect(server.advertisedWindow == UInt16(capacity - (chunk - consumed)))   // R11.2

        // Drain the rest: window returns to full capacity (R11.2, R11.4).
        _ = server.read(max: chunk)
        #expect(!server.hasBufferedData)
        #expect(server.advertisedWindow == UInt16(capacity))
    }

    /// `snapshotTCP()` and `/proc/net/tcp` surface the local advertised window as
    /// `rwnd` and the peer's advertised window as `peerwnd`, reflecting live buffer
    /// occupancy at read time (R11, R15.3).
    @Test func snapshotAndProcFSExposeRwndAndPeerwnd() {
        let loop = EventLoop()
        let (kernelA, kernelB, ipB) = makePair(loop: loop)
        let stackA = kernelA.netns.stack
        let stackB = kernelB.netns.stack

        let listener = stackB.listen(port: 80)
        let localPort: UInt16 = 50_201
        let client = stackA.connect(localPort: localPort, to: ipB, remotePort: 80)

        loop.advance(by: 0.5)
        guard let server = listener.dequeue() else {
            Issue.record("server connection was not accepted")
            return
        }

        // Client sends data that the server buffers but does not read.
        let chunk = 1500
        client.send((0..<chunk).map { UInt8($0 & 0xFF) })
        loop.advance(by: 0.5)

        // --- snapshotTCP() on the server: rwnd shrank by the buffered bytes. ---
        guard let serverRow = row(stackB, localPort: 80) else {
            Issue.record("server row missing from snapshotTCP()")
            return
        }
        #expect(serverRow.rwnd == UInt16(capacity - chunk))
        #expect(serverRow.rwnd == server.advertisedWindow)
        #expect(serverRow.receiveBufferOccupancy == chunk)
        #expect(serverRow.receiveBufferCapacity == capacity)

        // --- snapshotTCP() on the client: peerwnd equals the server's rwnd. ---
        guard let clientRow = row(stackA, localPort: localPort) else {
            Issue.record("client row missing from snapshotTCP()")
            return
        }
        #expect(clientRow.peerwnd == UInt16(capacity - chunk))
        #expect(clientRow.rwnd == UInt16(capacity))          // client buffered nothing
        #expect(clientRow.receiveBufferOccupancy == 0)
        #expect(clientRow.receiveBufferCapacity == capacity)

        // --- /proc/net/tcp shows the rwnd/peerwnd fields (R15.3). ---
        let procServer = readProcNetTCP(kernelB, loop: loop)
        #expect(procServer.contains("rwnd=\(serverRow.rwnd)"))
        #expect(procServer.contains("peerwnd=\(serverRow.peerwnd)"))

        let procClient = readProcNetTCP(kernelA, loop: loop)
        #expect(procClient.contains("rwnd=\(clientRow.rwnd)"))
        #expect(procClient.contains("peerwnd=\(clientRow.peerwnd)"))

        // After the app drains the buffer, the next read of procfs reflects the
        // recovered window (read live at open time, R15.4 / R11.2).
        _ = server.read(max: chunk)
        let procAfter = readProcNetTCP(kernelB, loop: loop)
        #expect(procAfter.contains("rwnd=\(UInt16(capacity))"))
    }
}
