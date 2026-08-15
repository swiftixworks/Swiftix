import Testing
@testable import Swiftix

@Suite("TCP transmission helpers")
struct TCPTransmissionTests {
    @Test func outgoingSegmentLengthAccountsForSequenceConsumingFlags() {
        #expect(TCPOutgoingSegment(sequence: 1,
                                   flags: [.ack],
                                   payload: [1, 2, 3],
                                   sentAt: 0,
                                   retransmitted: false).length == 3)
        #expect(TCPOutgoingSegment(sequence: 1,
                                   flags: [.syn],
                                   payload: [],
                                   sentAt: 0,
                                   retransmitted: false).length == 1)
        #expect(TCPOutgoingSegment(sequence: 1,
                                   flags: [.fin, .ack],
                                   payload: [1, 2],
                                   sentAt: 0,
                                   retransmitted: false).length == 3)
    }
}
