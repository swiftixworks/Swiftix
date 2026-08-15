/// Pure TCP transition planning separated from connection I/O side effects.
enum TCPConnectionPlanner {
    struct FINPlan: Equatable {
        let received: Bool
        let actions: [TCPConnectionAction]
    }

    static let peerWindowReopened: [TCPConnectionAction] = [.stopPersistTimer, .pumpSendBuffer]
    static let readableStateChanged: [TCPConnectionAction] = [.sendAck, .notifyReadable]
    static let outOfOrderOrDuplicateSegment: [TCPConnectionAction] = [.sendAck]

    static var finishClose: [TCPConnectionAction] {
        [.setState(.closed), .removeConnection, .notifyReadinessChanged]
    }

    static var enterTimeWait: [TCPConnectionAction] {
        [.setState(.timeWait), .scheduleTimeWaitExpiry]
    }

    static var abortAndWakeWaiters: [TCPConnectionAction] {
        finishClose + [.unblockConnectAndRead]
    }

    static var timeWaitExpired: [TCPConnectionAction] {
        finishClose
    }

    static func localClose(from state: TCPState) -> [TCPConnectionAction] {
        switch state {
        case .established:
            return [.setState(.finWait1), .sendControlled(flags: [.ack, .fin], payload: [])]
        case .closeWait:
            return [.setState(.lastAck), .sendControlled(flags: [.ack, .fin], payload: [])]
        default:
            return []
        }
    }

    static func acceptedReset(state: TCPState) -> [TCPConnectionAction] {
        guard state != .closed else { return [] }
        return [.markReset] + abortAndWakeWaiters
    }

    static func transmitAndArmTimer(_ segment: TCPOutgoingSegment) -> [TCPConnectionAction] {
        [.transmit(segment), .armRetransmitTimer]
    }

    static func acknowledgedRetransmitQueue(hasOutstandingSegments: Bool) -> [TCPConnectionAction] {
        [
            hasOutstandingSegments ? .armRetransmitTimer : .cancelRetransmitTimer,
            .pumpSendBuffer
        ]
    }

    static func duplicateAck(shouldFastRetransmit: Bool) -> [TCPConnectionAction] {
        shouldFastRetransmit ? [.fastRetransmit] : [.pumpSendBuffer]
    }

    static func peerWindowUpdate(previous: UInt32, current: UInt32) -> [TCPConnectionAction] {
        previous == 0 && current > 0 ? peerWindowReopened : []
    }

    static func inboundPayload(inOrder: Bool) -> [TCPConnectionAction] {
        inOrder ? readableStateChanged : outOfOrderOrDuplicateSegment
    }

    static func inboundFIN(flags: TCPSegment.Flags,
                           segmentSequence: UInt32,
                           payloadCount: Int,
                           receiveNext: UInt32) -> FINPlan {
        guard flags.contains(.fin) else {
            return FINPlan(received: false, actions: [])
        }
        let finSequence = segmentSequence &+ UInt32(payloadCount)
        if finSequence == receiveNext {
            return FINPlan(received: true, actions: readableStateChanged)
        }
        return FINPlan(received: false, actions: outOfOrderOrDuplicateSegment)
    }

    static func closeTransition(from state: TCPState,
                                receivedFIN: Bool,
                                ourFinAcked: Bool) -> [TCPConnectionAction] {
        let transition = TCPStateMachine.closeTransition(from: state,
                                                         receivedFIN: receivedFIN,
                                                         ourFinAcked: ourFinAcked)
        return closeTransition(transition)
    }

    static func closeTransition(_ transition: TCPStateMachine.CloseTransition) -> [TCPConnectionAction] {
        switch transition {
        case .none:
            return []
        case .set(let nextState):
            return [.setState(nextState)]
        case .enterTimeWait:
            return enterTimeWait
        case .finishClose:
            return finishClose
        }
    }
}
