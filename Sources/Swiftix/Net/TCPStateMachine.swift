/// Pure TCP state-transition decisions with no packet or timer side effects.
enum TCPStateMachine {
    enum ACKDecision: Equatable {
        case advances
        case duplicate
        case ignore
    }

    enum CloseTransition: Equatable {
        case none
        case set(TCPState)
        case enterTimeWait
        case finishClose
    }

    static func name(for state: TCPState) -> String {
        switch state {
        case .closed: return "CLOSED"
        case .listen: return "LISTEN"
        case .synSent: return "SYN_SENT"
        case .synReceived: return "SYN_RECEIVED"
        case .established: return "ESTABLISHED"
        case .finWait1: return "FIN_WAIT_1"
        case .finWait2: return "FIN_WAIT_2"
        case .closeWait: return "CLOSE_WAIT"
        case .closing: return "CLOSING"
        case .lastAck: return "LAST_ACK"
        case .timeWait: return "TIME_WAIT"
        }
    }

    static func completesActiveOpen(_ header: TCPSegment.Header, sndUna: UInt32) -> Bool {
        header.flags.contains(.syn)
            && header.flags.contains(.ack)
            && header.acknowledgment == sndUna &+ 1
    }

    static func completesPassiveOpen(_ header: TCPSegment.Header, sndUna: UInt32) -> Bool {
        header.flags.contains(.ack) && header.acknowledgment == sndUna &+ 1
    }

    static func ackDecision(acknowledgment: UInt32,
                            sndUna: UInt32,
                            sndNxt: UInt32,
                            payloadEmpty: Bool,
                            previousPeerWindow: UInt32,
                            currentPeerWindow: UInt32) -> ACKDecision {
        if TCPSequence.greater(acknowledgment, than: sndUna) {
            return .advances
        }
        let flightSize = Int(sndNxt &- sndUna)
        if payloadEmpty, flightSize > 0, currentPeerWindow == previousPeerWindow {
            return .duplicate
        }
        return .ignore
    }

    /// Whether `sequence` lies within `[receiveNext, receiveNext + advertisedWindow)`.
    /// When the advertised window is zero the window is empty except for
    /// `receiveNext` itself, so a RST exactly at `receiveNext` is still accepted.
    static func acceptsReset(sequence: UInt32, receiveNext: UInt32, advertisedWindow: UInt32) -> Bool {
        let offset = sequence &- receiveNext
        if advertisedWindow == 0 { return offset == 0 }
        return offset < advertisedWindow
    }

    static func closeTransition(from state: TCPState, receivedFIN: Bool, ourFinAcked: Bool) -> CloseTransition {
        switch state {
        case .established:
            return receivedFIN ? .set(.closeWait) : .none
        case .finWait1:
            if receivedFIN && ourFinAcked { return .enterTimeWait }
            if receivedFIN { return .set(.closing) }
            if ourFinAcked { return .set(.finWait2) }
            return .none
        case .finWait2:
            return receivedFIN ? .enterTimeWait : .none
        case .closing:
            return ourFinAcked ? .enterTimeWait : .none
        case .lastAck:
            return ourFinAcked ? .finishClose : .none
        default:
            return .none
        }
    }
}
