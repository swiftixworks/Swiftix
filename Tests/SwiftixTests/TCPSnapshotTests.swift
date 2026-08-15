import Testing
@testable import Swiftix

@Suite("TCP snapshot model")
struct TCPSnapshotTests {
    @Test func snapshotAliasesExposeCongestionTimingAndWindows() {
        let snapshot = TCPSnapshot(localPort: 1000,
                                   remoteIP: IPv4Address(10, 0, 0, 2),
                                   remotePort: 80,
                                   state: "ESTABLISHED",
                                   congestion: CongestionSnapshot(cwnd: 1024,
                                                                  ssthresh: 4096,
                                                                  srtt: 0.12,
                                                                  rttvar: 0.03,
                                                                  rto: 0.24),
                                   window: TCPWindowSnapshot(receiveBufferOccupancy: 7,
                                                             receiveBufferCapacity: 64,
                                                             advertised: 57,
                                                             peerAdvertised: 512))

        #expect(snapshot.cwnd == 1024)
        #expect(snapshot.ssthresh == 4096)
        #expect(snapshot.srtt == 0.12)
        #expect(snapshot.rttvar == 0.03)
        #expect(snapshot.rto == 0.24)
        #expect(snapshot.rwnd == 57)
        #expect(snapshot.peerwnd == 512)
        #expect(snapshot.receiveBufferOccupancy == 7)
        #expect(snapshot.receiveBufferCapacity == 64)
    }
}
