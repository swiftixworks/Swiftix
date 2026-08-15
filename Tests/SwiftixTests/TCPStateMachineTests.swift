import Testing
@testable import Swiftix

@Suite("TCP state machine decisions")
struct TCPStateMachineTests {

    @Test func stateNamesMatchProcfsConventions() {
        #expect(TCPStateMachine.name(for: .closed) == "CLOSED")
        #expect(TCPStateMachine.name(for: .listen) == "LISTEN")
        #expect(TCPStateMachine.name(for: .synSent) == "SYN_SENT")
        #expect(TCPStateMachine.name(for: .synReceived) == "SYN_RECEIVED")
        #expect(TCPStateMachine.name(for: .established) == "ESTABLISHED")
        #expect(TCPStateMachine.name(for: .finWait1) == "FIN_WAIT_1")
        #expect(TCPStateMachine.name(for: .finWait2) == "FIN_WAIT_2")
        #expect(TCPStateMachine.name(for: .closeWait) == "CLOSE_WAIT")
        #expect(TCPStateMachine.name(for: .closing) == "CLOSING")
        #expect(TCPStateMachine.name(for: .lastAck) == "LAST_ACK")
        #expect(TCPStateMachine.name(for: .timeWait) == "TIME_WAIT")
    }

    @Test func resetAcceptanceUsesReceiveWindow() {
        #expect(TCPStateMachine.acceptsReset(sequence: 100, receiveNext: 100, advertisedWindow: 0))
        #expect(!TCPStateMachine.acceptsReset(sequence: 101, receiveNext: 100, advertisedWindow: 0))
        #expect(TCPStateMachine.acceptsReset(sequence: 104, receiveNext: 100, advertisedWindow: 5))
        #expect(!TCPStateMachine.acceptsReset(sequence: 105, receiveNext: 100, advertisedWindow: 5))
        #expect(!TCPStateMachine.acceptsReset(sequence: 99, receiveNext: 100, advertisedWindow: 5))
    }

    @Test func openCompletionGuardsMatchHandshakeAcks() {
        let sndUna: UInt32 = 42
        let goodSynAck = header(sequence: 10, acknowledgment: sndUna &+ 1, flags: [.syn, .ack])
        let missingSyn = header(sequence: 10, acknowledgment: sndUna &+ 1, flags: [.ack])
        let wrongAck = header(sequence: 10, acknowledgment: sndUna, flags: [.syn, .ack])

        #expect(TCPStateMachine.completesActiveOpen(goodSynAck, sndUna: sndUna))
        #expect(!TCPStateMachine.completesActiveOpen(missingSyn, sndUna: sndUna))
        #expect(!TCPStateMachine.completesActiveOpen(wrongAck, sndUna: sndUna))
        #expect(TCPStateMachine.completesPassiveOpen(missingSyn, sndUna: sndUna))
        #expect(!TCPStateMachine.completesPassiveOpen(wrongAck, sndUna: sndUna))
    }

    @Test func ackDecisionClassifiesAdvancingDuplicateAndIgnoredAcks() {
        #expect(TCPStateMachine.ackDecision(acknowledgment: 105,
                                            sndUna: 100,
                                            sndNxt: 120,
                                            payloadEmpty: true,
                                            previousPeerWindow: 4096,
                                            currentPeerWindow: 4096) == .advances)
        #expect(TCPStateMachine.ackDecision(acknowledgment: 100,
                                            sndUna: 100,
                                            sndNxt: 120,
                                            payloadEmpty: true,
                                            previousPeerWindow: 4096,
                                            currentPeerWindow: 4096) == .duplicate)
        #expect(TCPStateMachine.ackDecision(acknowledgment: 100,
                                            sndUna: 100,
                                            sndNxt: 120,
                                            payloadEmpty: false,
                                            previousPeerWindow: 4096,
                                            currentPeerWindow: 4096) == .ignore)
        #expect(TCPStateMachine.ackDecision(acknowledgment: 100,
                                            sndUna: 100,
                                            sndNxt: 120,
                                            payloadEmpty: true,
                                            previousPeerWindow: 4096,
                                            currentPeerWindow: 2048) == .ignore)
        #expect(TCPStateMachine.ackDecision(acknowledgment: 100,
                                            sndUna: 100,
                                            sndNxt: 100,
                                            payloadEmpty: true,
                                            previousPeerWindow: 4096,
                                            currentPeerWindow: 4096) == .ignore)
    }

    @Test func closeTransitionsArePureDecisions() {
        #expect(TCPStateMachine.closeTransition(from: .established, receivedFIN: true, ourFinAcked: false) == .set(.closeWait))
        #expect(TCPStateMachine.closeTransition(from: .finWait1, receivedFIN: false, ourFinAcked: true) == .set(.finWait2))
        #expect(TCPStateMachine.closeTransition(from: .finWait1, receivedFIN: true, ourFinAcked: false) == .set(.closing))
        #expect(TCPStateMachine.closeTransition(from: .finWait1, receivedFIN: true, ourFinAcked: true) == .enterTimeWait)
        #expect(TCPStateMachine.closeTransition(from: .finWait2, receivedFIN: true, ourFinAcked: false) == .enterTimeWait)
        #expect(TCPStateMachine.closeTransition(from: .closing, receivedFIN: false, ourFinAcked: true) == .enterTimeWait)
        #expect(TCPStateMachine.closeTransition(from: .lastAck, receivedFIN: false, ourFinAcked: true) == .finishClose)
        #expect(TCPStateMachine.closeTransition(from: .synSent, receivedFIN: true, ourFinAcked: true) == .none)
    }

    private func header(sequence: UInt32,
                        acknowledgment: UInt32,
                        flags: TCPSegment.Flags,
                        window: UInt16 = 0xFFFF) -> TCPSegment.Header {
        TCPSegment.Header(sourcePort: 1,
                          destinationPort: 2,
                          sequence: sequence,
                          acknowledgment: acknowledgment,
                          flags: flags,
                          window: window)
    }
}
