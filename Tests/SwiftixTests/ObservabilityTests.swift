import Testing
@testable import Swiftix

/// Congestion state observability (R10). The congestion window and slow-start
/// threshold must be visible through `NetworkStack.snapshotTCP()` (R10.2) and the
/// `/proc/net/tcp` synthetic file (R10.4), and — because the snapshot is read live
/// from the connection — must reflect state changes on the next read (R10.3),
/// including the ssthresh reduction that follows a loss episode.
@Suite("Congestion state observability")
struct ObservabilityTests {

    /// Locate the client connection's row in a `snapshotTCP()` result by local port.
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

    @Test func snapshotAndProcFSExposeCwndSsthreshAndReflectPostLossChange() {
        let loop = EventLoop()
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
        // Drop the 4th data-bearing A->B segment (a middle segment) so the receiver
        // emits >=3 duplicate ACKs and the sender fast-retransmits, reducing ssthresh.
        TestWire.connect(stackA, ifA, stackB, ifB, on: loop, latency: 0.01,
                        dropData: { index, _ in index == 3 })
        stackA.configuredNeighbor(ip: ipB, mac: macB)
        stackB.configuredNeighbor(ip: ipA, mac: macA)

        let localPort: UInt16 = 50_100
        let listener = stackB.listen(port: 80)
        let client = stackA.connect(localPort: localPort, to: ipB, remotePort: 80)

        // Complete the 3-way handshake.
        loop.advance(by: 0.5)

        // --- Baseline: snapshotTCP() exposes cwnd/ssthresh (R10.1, R10.2). ---
        let before = row(stackA, localPort: localPort)
        #expect(before != nil)
        guard let before else { return }
        let smss = client.congestionControllerSnapshot.smss
        #expect(before.state == "ESTABLISHED")
        #expect(before.cwnd == 2 * smss)          // initial window (R1.1)
        #expect(before.ssthresh == 0xFFFF)        // starts high => slow start
        #expect(before.srtt == client.congestionSnapshot.srtt)
        #expect(before.rttvar == client.congestionSnapshot.rttvar)
        #expect(before.rto == client.congestionSnapshot.rto)
        let ssthreshBeforeLoss = before.ssthresh

        // --- procfs exposes cwnd/ssthresh plus RFC 6298 timing (R10.4). ---
        let procBefore = readProcNetTCP(kernelA, loop: loop)
        #expect(procBefore.contains("cwnd=\(before.cwnd)"))
        #expect(procBefore.contains("ssthresh=\(before.ssthresh)"))
        #expect(procBefore.contains("srtt=\(before.srtt)"))
        #expect(procBefore.contains("rttvar=\(before.rttvar)"))
        #expect(procBefore.contains("rto=\(before.rto)"))

        // --- Trigger a loss episode: ~6 KB with a dropped middle segment. ---
        let payload: [UInt8] = (0..<6144).map { UInt8($0 & 0xFF) }
        client.send(payload)
        loop.advance(by: 1.0)   // run through fast retransmit / recovery to quiescence

        // --- Post-loss: the live snapshot reflects the reduced ssthresh (R10.3). ---
        let after = row(stackA, localPort: localPort)
        #expect(after != nil)
        guard let after else { return }
        #expect(after.ssthresh < ssthreshBeforeLoss)   // ssthresh halved by the loss
        #expect(after.ssthresh >= 2 * smss)            // floored at 2*SMSS (R9.2)
        #expect(after.cwnd >= smss)                    // cwnd stays >= SMSS (R9.1)
        // The live snapshot equals the connection's own accessor (single source of truth).
        #expect(after.cwnd == client.congestionSnapshot.cwnd)
        #expect(after.ssthresh == client.congestionSnapshot.ssthresh)
        #expect(after.srtt == client.congestionSnapshot.srtt)
        #expect(after.rttvar == client.congestionSnapshot.rttvar)
        #expect(after.rto == client.congestionSnapshot.rto)

        // --- procfs reflects the post-loss congestion/timing state too (R10.3, R10.4). ---
        let procAfter = readProcNetTCP(kernelA, loop: loop)
        #expect(procAfter.contains("cwnd=\(after.cwnd)"))
        #expect(procAfter.contains("ssthresh=\(after.ssthresh)"))
        #expect(procAfter.contains("srtt=\(after.srtt)"))
        #expect(procAfter.contains("rttvar=\(after.rttvar)"))
        #expect(procAfter.contains("rto=\(after.rto)"))

        // Sanity: the data was reliably delivered in order despite the drop.
        let server = listener.dequeue()
        #expect(server != nil)
        let delivered = server?.read(max: 1 << 20) ?? []
        #expect(Array(payload.prefix(delivered.count)) == delivered)
    }
}
