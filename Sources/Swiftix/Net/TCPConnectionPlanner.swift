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

    /// Abort from the local side: tell the peer with a reset, stop every timer,
    /// drop the TCB, and wake whoever is still parked on it.
    static var abortWithReset: [TCPConnectionAction] {
        [.sendReset, .cancelRetransmitTimer, .stopPersistTimer] + abortAndWakeWaiters
    }

    /// Drop a TCB the peer has no state for (or has given up on) without a
    /// segment on the wire.
    static var abandon: [TCPConnectionAction] {
        [.cancelRetransmitTimer, .stopPersistTimer] + abortAndWakeWaiters
    }

    /// An orphan in FIN_WAIT_2 whose peer never closed its half.
    static var orphanTimeoutExpired: [TCPConnectionAction] { abandon }

    /// Begin an orderly close. The FIN occupies the sequence number after the
    /// last application byte, so with bytes still unsent it is deferred until
    /// the Send_Buffer drains rather than emitted ahead of them.
    static func localClose(from state: TCPState, hasUnsentData: Bool = false) -> [TCPConnectionAction] {
        let fin: TCPConnectionAction = hasUnsentData
            ? .deferFIN
            : .sendControlled(flags: [.ack, .fin], payload: [])
        switch state {
        case .established:
            return [.setState(.finWait1), fin]
        case .closeWait:
            return [.setState(.lastAck), fin]
        default:
            return []
        }
    }

    /// The last descriptor referencing the connection's open-file description
    /// closed — explicitly, or because its process exited or was killed. This
    /// is `close(2)` on a connected socket, as Linux decides it:
    ///
    /// - bytes the application never read cannot be acknowledged as delivered,
    ///   so the connection is reset (RFC 2525 §2.17) whatever state it is in;
    /// - otherwise an open connection closes in order, FIN after pending data;
    /// - a connection already closing keeps its handshake, now as an orphan;
    /// - an active open the peer never answered is simply dropped.
    static func lastDescriptorClosed(from state: TCPState,
                                     hasUnreadData: Bool,
                                     hasUnsentData: Bool) -> [TCPConnectionAction] {
        switch state {
        case .closed, .listen:
            return []
        case .synSent:
            return abandon
        case .synReceived:
            return abortWithReset
        case .timeWait:
            return []
        case .established, .closeWait:
            return hasUnreadData
                ? abortWithReset
                : localClose(from: state, hasUnsentData: hasUnsentData)
        case .finWait1, .closing, .lastAck:
            return hasUnreadData ? abortWithReset : []
        case .finWait2:
            return hasUnreadData ? abortWithReset : [.scheduleOrphanTimeout]
        }
    }

    /// A listener closed with this connection still waiting in its backlog (or
    /// still completing its handshake): no descriptor will ever exist for it.
    static func listenerClosed(state: TCPState) -> [TCPConnectionAction] {
        state == .closed ? [] : abortWithReset
    }

    /// Zero-window probes an orphan sends before giving up on a peer that never
    /// reopens its window (Linux's effective `tcp_orphan_retries`).
    static let orphanProbeLimit = 8

    /// The persist timer fired with the peer's window still shut. A connection
    /// somebody holds keeps probing for as long as its owner cares to wait; an
    /// orphan is only there to flush its last bytes and FIN, so once it has
    /// spent its probes it resets the peer and goes away.
    static func persistProbe(orphaned: Bool, probesSent: Int) -> [TCPConnectionAction] {
        orphaned && probesSent >= orphanProbeLimit ? abortWithReset : [.sendZeroWindowProbe]
    }

    /// New payload reached a connection no descriptor references.
    static var orphanReceivedData: [TCPConnectionAction] { abortWithReset }

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

    /// `orphaned` bounds the one close state that waits on the peer alone: a
    /// descriptor-less connection entering FIN_WAIT_2 arms the orphan timeout.
    static func closeTransition(from state: TCPState,
                                receivedFIN: Bool,
                                ourFinAcked: Bool,
                                orphaned: Bool = false) -> [TCPConnectionAction] {
        let transition = TCPStateMachine.closeTransition(from: state,
                                                         receivedFIN: receivedFIN,
                                                         ourFinAcked: ourFinAcked)
        let actions = closeTransition(transition)
        return orphaned && transition == .set(.finWait2) ? actions + [.scheduleOrphanTimeout] : actions
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
