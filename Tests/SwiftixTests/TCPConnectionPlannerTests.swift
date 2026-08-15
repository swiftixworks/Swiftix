import Testing
@testable import Swiftix

@Suite("TCP connection planner")
struct TCPConnectionPlannerTests {
    @Test func reusablePlansKeepCommonSideEffectsExplicit() {
        #expect(TCPConnectionPlanner.peerWindowReopened == [.stopPersistTimer, .pumpSendBuffer])
        #expect(TCPConnectionPlanner.readableStateChanged == [.sendAck, .notifyReadable])
        #expect(TCPConnectionPlanner.outOfOrderOrDuplicateSegment == [.sendAck])
        #expect(TCPConnectionPlanner.finishClose
            == [.setState(.closed), .removeConnection, .notifyReadinessChanged])
        #expect(TCPConnectionPlanner.abortAndWakeWaiters
            == [.setState(.closed), .removeConnection, .notifyReadinessChanged, .unblockConnectAndRead])
        #expect(TCPConnectionPlanner.acceptedReset(state: .established)
            == [.markReset, .setState(.closed), .removeConnection, .notifyReadinessChanged, .unblockConnectAndRead])
        #expect(TCPConnectionPlanner.acceptedReset(state: .closed) == [])
    }

    @Test func transmitActionCarriesTheExactOutgoingSegment() {
        let segment = TCPOutgoingSegment(sequence: 42,
                                         flags: [.ack, .psh],
                                         payload: [1, 2, 3],
                                         sentAt: 0.25,
                                         retransmitted: true)

        #expect(TCPConnectionAction.transmit(segment) == .transmit(segment))
    }

    @Test func retransmitPlansKeepTimerBehaviorExplicit() {
        let segment = TCPOutgoingSegment(sequence: 100,
                                         flags: [.ack],
                                         payload: [9],
                                         sentAt: 1.5,
                                         retransmitted: false)

        #expect(TCPConnectionPlanner.transmitAndArmTimer(segment) == [.transmit(segment), .armRetransmitTimer])
        #expect(TCPConnectionPlanner.acknowledgedRetransmitQueue(hasOutstandingSegments: true)
            == [.armRetransmitTimer, .pumpSendBuffer])
        #expect(TCPConnectionPlanner.acknowledgedRetransmitQueue(hasOutstandingSegments: false)
            == [.cancelRetransmitTimer, .pumpSendBuffer])
    }

    @Test func duplicateAckPlanSelectsFastRetransmitOnlyOnThreshold() {
        #expect(TCPConnectionPlanner.duplicateAck(shouldFastRetransmit: true) == [.fastRetransmit])
        #expect(TCPConnectionPlanner.duplicateAck(shouldFastRetransmit: false) == [.pumpSendBuffer])
    }

    @Test func closeTransitionPlansMapPureDecisionsToExecutorActions() {
        #expect(TCPConnectionPlanner.closeTransition(.none) == [])
        #expect(TCPConnectionPlanner.closeTransition(.set(.closeWait)) == [.setState(.closeWait)])
        #expect(TCPConnectionPlanner.closeTransition(.enterTimeWait)
            == [.setState(.timeWait), .scheduleTimeWaitExpiry])
        #expect(TCPConnectionPlanner.closeTransition(.finishClose)
            == [.setState(.closed), .removeConnection, .notifyReadinessChanged])
        #expect(TCPConnectionPlanner.timeWaitExpired
            == [.setState(.closed), .removeConnection, .notifyReadinessChanged])
    }

    @Test func localClosePlansTransitionAndFinTransmission() {
        #expect(TCPConnectionPlanner.localClose(from: .established)
            == [.setState(.finWait1), .sendControlled(flags: [.ack, .fin], payload: [])])
        #expect(TCPConnectionPlanner.localClose(from: .closeWait)
            == [.setState(.lastAck), .sendControlled(flags: [.ack, .fin], payload: [])])
        #expect(TCPConnectionPlanner.localClose(from: .closed) == [])
    }

    @Test func inboundPayloadAndFinPlansSeparateStateDecisionFromMutation() {
        #expect(TCPConnectionPlanner.peerWindowUpdate(previous: 0, current: 1024)
            == [.stopPersistTimer, .pumpSendBuffer])
        #expect(TCPConnectionPlanner.peerWindowUpdate(previous: 0, current: 0) == [])
        #expect(TCPConnectionPlanner.inboundPayload(inOrder: true) == [.sendAck, .notifyReadable])
        #expect(TCPConnectionPlanner.inboundPayload(inOrder: false) == [.sendAck])

        #expect(TCPConnectionPlanner.inboundFIN(flags: [.ack], segmentSequence: 10, payloadCount: 0, receiveNext: 10)
            == TCPConnectionPlanner.FINPlan(received: false, actions: []))
        #expect(TCPConnectionPlanner.inboundFIN(flags: [.ack, .fin], segmentSequence: 10, payloadCount: 3, receiveNext: 13)
            == TCPConnectionPlanner.FINPlan(received: true, actions: [.sendAck, .notifyReadable]))
        #expect(TCPConnectionPlanner.inboundFIN(flags: [.ack, .fin], segmentSequence: 10, payloadCount: 3, receiveNext: 12)
            == TCPConnectionPlanner.FINPlan(received: false, actions: [.sendAck]))
    }
}
