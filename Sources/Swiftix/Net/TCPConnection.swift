/// One TCP connection — the TCB + state machine. Supports 3-way handshake,
/// in-order data, cumulative ACK, RTO retransmission, Reno congestion control,
/// fast retransmit/recovery, window scaling (RFC 7323), and a full close (FIN
/// handshake with TIME_WAIT).
final class TCPConnection {
    private unowned let stack: NetworkStack
    let localPort: UInt16
    let remoteIP: IPv4Address
    let remotePort: UInt16

    private(set) var state: TCPState = .closed

    /// Human-readable state name (for procfs / debugging).
    var stateDescription: String {
        TCPStateMachine.name(for: state)
    }

    // Sequence-space variables (RFC 793 §3.2).
    private var sndUna: UInt32 = 0
    private var sndNxt: UInt32 = 0
    private var rcvNxt: UInt32 = 0

    // --- Window Scaling (RFC 7323) ---
    // `sndWindowScale`: the peer's shift count (from their SYN/SYN-ACK option).
    // We left-shift the 16-bit window field they advertise by this amount to get
    // the true peer window.
    // `rcvWindowScale`: our own shift count (advertised in our SYN/SYN-ACK). We
    // right-shift our actual advertised window by this amount before placing it in
    // the 16-bit header field.
    // Both default to 0 (no scaling) and are only set during the handshake if both
    // sides include the Window Scale option. If either side omits it, both stay 0
    // (RFC 7323 §1.3).
    private var sndWindowScale: UInt8 = 0
    private var rcvWindowScale: UInt8 = 0
    /// Whether we offered window scaling in our SYN (active open). We only accept
    /// the peer's scale if we also offered one.
    private var windowScaleOffered = false

    // Last advertised receive window seen from the peer, **already scaled** by
    // `sndWindowScale`. Used by duplicate-ACK detection (R4), sender window gating
    // (R12), and persist probing.
    private var peerWindow: UInt32 = 0xFFFF

    /// The peer's most recently advertised Receive_Window (R11 observability),
    /// already scaled. Internal so `snapshotTCP()` / `/proc/net/tcp` can surface
    /// it as `peerwnd`.
    var peerAdvertisedWindow: UInt32 { peerWindow }

    // Receive buffer (in-order bytes ready for the app).
    private var receiveBuffer = TCPReceiveBuffer(capacity: 0xFFFF)
    private(set) var eofReceived = false

    /// Receiver-side SACK state: caches out-of-order segments and generates SACK
    /// blocks for outgoing ACKs. Also used sender-side to mark SACKed entries.
    private var sackState = TCPSACKReceiver()

    /// Whether this connection was aborted by an inbound RST (R10). Set by the
    /// inbound-reset action plan; additive and internal so the async `tcpRecv`
    /// frontend can distinguish a reset (surfaced as `SyscallError.connectionReset`)
    /// from a normal EOF, without changing the callback path's observable behavior.
    /// The callback `tcpRecv(resume:)` still resumes with an empty read on a reset,
    /// as before.
    private(set) var wasReset = false

    /// Test seam (internal, additive-only): shrink the Receive_Buffer_Capacity so a
    /// small transfer can drive the Zero_Window path deterministically on the
    /// logical-time loop (R12). Internal so the public API is unchanged (NFR-1).
    /// Setting it never grows the advertised window beyond the new capacity
    /// (R11.4). Intended to be called right after the handshake, before data flows.
    func setReceiveBufferCapacity(_ capacity: Int) {
        receiveBuffer.setCapacity(capacity)
    }

    /// The advertised Receive_Window (R11): the free space in the Receive_Buffer,
    /// i.e. capacity minus currently-buffered bytes, clamped to `[0, capacity]` and
    /// carried in every outgoing TCP header's window field. When window scaling is
    /// negotiated the true free space is right-shifted by `rcvWindowScale` before
    /// being placed in the 16-bit wire field; the peer left-shifts by our scale to
    /// recover the actual value.
    var advertisedWindow: UInt16 {
        let trueWindow = receiveBuffer.trueAdvertisedWindow
        return UInt16(clamping: trueWindow >> rcvWindowScale)
    }

    /// Internal diagnostics for flow-control tests and future TCP snapshots.
    var receiveBufferSnapshot: (occupancy: Int, capacity: Int) {
        (receiveBuffer.count, receiveBuffer.capacity)
    }

    // Retransmission queue + epoch-cancellable timer.
    private var retransmitQueue: [TCPOutgoingSegment] = []
    private var retransmitTimer = TCPEpochTimer()
    private let timeWaitDuration = 0.1   // shortened 2*MSL for simulation

    // Zero-window persist timer (R12.3, real-peer interop). While the peer
    // advertises a Zero_Window and we still have buffered data to send, an
    // epoch-guarded timer periodically emits a 1-byte probe so a lost
    // window-update cannot deadlock the sender. Epoch-guarded like the retransmit
    // timer so at most one probe fire is outstanding; `persisting` prevents
    // re-arming the timer on every `pump()`.
    private var persistTimer = TCPEpochTimer()
    private var persisting = false
    private let persistInterval = 1.0

    /// Count of RTO-timer-driven retransmissions (not fast retransmits). The
    /// single epoch-guarded timer fires at most once per armed RTO interval, so
    /// this can never exceed the number of elapsed RTO intervals. Internal so the
    /// property tests can assert "no retransmit storm" (R9.4, P7) without touching
    /// the public API.
    private(set) var rtoRetransmitCount = 0

    /// Consecutive RTO-timer retransmissions of the oldest unacked segment with no
    /// intervening progress (no ACK advancing `sndUna`). Reset to 0 whenever the
    /// cumulative acknowledgment advances, so a long transfer that keeps making
    /// forward progress under loss is never aborted; it only climbs when the same
    /// data is retransmitted repeatedly without being acknowledged. When it reaches
    /// `maxRetransmits` the connection is aborted rather than retransmitting forever.
    private var consecutiveRetransmits = 0

    /// Maximum number of consecutive RTO-timer-driven retransmissions of the oldest
    /// unacked segment (with no acknowledgment progress) before the connection is
    /// aborted. Without a cap the retransmit timer re-arms unconditionally after
    /// every fire, so a peer that never completes the handshake (e.g. a lone SYN
    /// that draws a SYN-ACK but is never ACKed) or that stops acknowledging data
    /// would spin the event loop forever. On reaching the cap we stop retransmitting
    /// and tear the connection down the same way an aborted connection is handled
    /// (R9.4).
    private let maxRetransmits = 6

    // Adaptive RTT/RTO state, wired into the ACK/timer path (RTT sampling in
    // `acknowledge(upTo:)`, backoff + adaptive delay in `armRetransmitTimer()`).
    private var rtoEstimator = RTOEstimator()

    /// Read-only view of the RFC 6298 estimator (srtt/rttvar/rto). Internal so
    /// tests can assert the adaptive RTO without touching the public API.
    var rtoEstimatorSnapshot: RTOEstimator { rtoEstimator }

    // Reno congestion-control state.
    private var congestion = CongestionController()

    /// Read-only view of the Reno controller (cwnd/ssthresh/phase/dupAckCount).
    /// Internal so tests can assert loss responses without touching the public
    /// API.
    var congestionControllerSnapshot: CongestionController { congestion }

    /// Read-only view of the full congestion-control state (cwnd/ssthresh from the
    /// Reno controller plus srtt/rttvar/rto from the RFC 6298 estimator), exposed
    /// for tests, `NetworkStack.snapshotTCP()`, and procfs (R10.1). Read live from
    /// the connection, so it always reflects the current state (R10.3).
    var congestionSnapshot: CongestionSnapshot {
        CongestionSnapshot(cwnd: congestion.cwnd, ssthresh: congestion.ssthresh,
                           srtt: rtoEstimator.srtt, rttvar: rtoEstimator.rttvar,
                           rto: rtoEstimator.rto)
    }

    var snapshot: TCPSnapshot {
        let buffer = receiveBufferSnapshot
        return TCPSnapshot(localPort: localPort,
                           remoteIP: remoteIP,
                           remotePort: remotePort,
                           state: stateDescription,
                           congestion: congestionSnapshot,
                           window: TCPWindowSnapshot(receiveBufferOccupancy: buffer.occupancy,
                                                     receiveBufferCapacity: buffer.capacity,
                                                     advertised: UInt32(advertisedWindow) << rcvWindowScale,
                                                     peerAdvertised: peerAdvertisedWindow))
    }

    // Sender-side byte buffer: application data not yet cut into segments (R7).
    // `send()` appends here and drives `pump()`; `pump()` emits <=SMSS segments as
    // the Send_Window allows and `acknowledge(upTo:)` re-pumps when the window opens.
    private var sendBuffer = TCPSendBuffer()

    /// Whether the Send_Buffer holds no untransmitted application bytes (R7.5).
    /// Internal so tests can observe drainage without touching the public API.
    var sendBufferIsEmpty: Bool { sendBuffer.isEmpty }

    /// FlightSize: unacknowledged bytes in sequence space (`sndNxt - sndUna`).
    /// Internal so property tests can assert `FlightSize <= Send_Window` (R9.3, P5)
    /// without touching the public API.
    var flightSize: Int { Int(sndNxt &- sndUna) }

    /// The sender's usable window (R12.4): the smaller of the congestion window
    /// (`cwnd`) and the peer's advertised Receive_Window (`peerWindow`). New data
    /// is only ever sent while `FlightSize < effectiveSendWindow`, so the sender
    /// limits outstanding data to `min(cwnd, peerWindow)` and transmits nothing new
    /// while the peer advertises a Zero_Window (R12.2). Internal so the flow-control
    /// property tests can assert `FlightSize <= min(cwnd, peerWindow)` without
    /// touching the public API.
    var effectiveSendWindow: Int { Swift.min(congestion.cwnd, Int(peerWindow)) }

    /// Whether the sender has drained all unacknowledged sequence space
    /// (`sndUna == sndNxt`). Combined with an empty Send_Buffer this indicates the
    /// sender has reached quiescence (forward progress complete, P3).
    var sndFullyAcked: Bool { sndUna == sndNxt }

    // Waiters, set by the kernel via ProcessContext (routed through runStep).
    var onEstablished: (() -> Void)? {
        get { notifications.onEstablished }
        set { notifications.onEstablished = newValue }
    }
    private weak var listener: TCPListener?
    private let notifications = TCPConnectionNotifications()
    private let transmitter: TCPTransmitter

    init(stack: NetworkStack, localPort: UInt16, remoteIP: IPv4Address, remotePort: UInt16) {
        self.stack = stack
        self.localPort = localPort
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        transmitter = TCPTransmitter(stack: stack,
                                     localPort: localPort,
                                     remoteIP: remoteIP,
                                     remotePort: remotePort)
    }

    // MARK: - Open

    func connect() {
        let iss = stack.nextISS()
        sndUna = iss
        sndNxt = iss
        state = .synSent
        windowScaleOffered = true
        sackState.enabled = true  // offered; confirmed when peer's SYN-ACK also offers
        perform(.sendControlled(flags: [.syn], payload: []))
    }

    func acceptSYN(_ segment: TCPSegment.Header, listener: TCPListener) {
        self.listener = listener
        rcvNxt = segment.sequence &+ 1
        let iss = stack.nextISS()
        sndUna = iss
        sndNxt = iss
        state = .synReceived
        // Window scale negotiation.
        if let peerScale = segment.options.firstWindowScale {
            sndWindowScale = peerScale
            windowScaleOffered = true
        }
        // SACK negotiation: enable if the peer's SYN offered SACK-Permitted.
        if segment.options.hasSACKPermitted {
            sackState.enabled = true
        }
        perform(.sendControlled(flags: [.syn, .ack], payload: []))
    }

    // MARK: - App API

    func send(_ data: [UInt8]) {
        guard state == .established, !data.isEmpty else { return }
        // Append to the Send_Buffer (R7.1) and try to drain it within the window.
        sendBuffer.append(data)
        perform(.pumpSendBuffer)
    }

    /// Read up to `max` in-order bytes (non-blocking; empty = none buffered).
    func read(max: Int) -> [UInt8] {
        guard !receiveBuffer.isEmpty else { return [] }
        // If the Receive_Buffer was full (advertising a Zero_Window), draining it
        // now frees space and reopens the window.
        let windowWasZero = (advertisedWindow == 0)
        let out = receiveBuffer.read(max: max)
        // R12.3: when the app drains a full buffer, proactively send a
        // window-update ACK advertising the reopened window so a sender stalled on
        // our Zero_Window wakes deterministically instead of waiting for a probe.
        if windowWasZero && advertisedWindow > 0 && state == .established {
            perform(.sendAck)
        }
        if !receiveBuffer.isEmpty { notifications.readable() }
        return out
    }

    var hasBufferedData: Bool { !receiveBuffer.isEmpty }

    var readiness: IOReadiness {
        var mask: IOReadiness = []
        if hasBufferedData || eofReceived || wasReset || state == .closed {
            mask.insert(.readable)
        }
        if state == .established || state == .closeWait {
            mask.insert(.writable)
        }
        if eofReceived || state == .closed {
            mask.insert(.hangup)
        }
        if wasReset {
            mask.insert(.error)
        }
        return mask
    }

    func addReadinessListener(_ listener: @escaping () -> Void) -> ReadinessSubscription {
        notifications.addReadinessListener(listener)
    }

    func addReadWaiter(_ waiter: @escaping () -> Void) -> ReadinessSubscription {
        notifications.addReadWaiter(waiter)
    }

    /// Begin (or continue) an orderly close.
    func close() {
        perform(TCPConnectionPlanner.localClose(from: state))
    }

    // MARK: - Egress helpers

    /// Segment and transmit buffered application data while the Send_Window allows.
    /// Cuts up to one SMSS per segment (R7.2) and defers transmission when
    /// FlightSize has reached the Send_Window (R7.3, R9.3). Invoked from `send()`
    /// (R7.1) and from `acknowledge(upTo:)` when an ACK opens the window (R7.4).
    private func pump() {
        while !sendBuffer.isEmpty {
            let flight = Int(sndNxt &- sndUna)                 // FlightSize in sequence space
            // Gate new data on the smaller of the congestion window and the peer's
            // advertised Receive_Window (R12.4). A Zero_Window yields `usable <= 0`,
            // so nothing new is transmitted while the peer is full (R12.2).
            let usable = effectiveSendWindow - flight          // remaining window (R9.3, R12.4)
            guard usable >= 1 else {
                // Blocked by a Zero_Window with data still to send: arm the persist
                // timer so a lost window-update cannot deadlock the sender (R12.3).
                if peerWindow == 0 { perform(.startPersistTimer) }
                break                                          // window full => defer (R7.3)
            }
            let n = Swift.min(sendBuffer.count, congestion.smss, usable)   // <= SMSS (R7.2)
            let chunk = sendBuffer.popPrefix(n)
            perform(.sendControlled(flags: [.ack, .psh], payload: chunk))
        }
    }

    // MARK: - Zero-window persist timer (R12.3)

    /// Arm the zero-window persist timer if it is not already running. Idempotent
    /// so repeated `pump()` calls during a stall do not reset the interval.
    private func startPersistTimer() {
        guard !persisting else { return }
        persisting = true
        schedulePersist()
    }

    /// Cancel any pending persist probe (called when the peer reopens its window).
    private func stopPersistTimer() {
        persisting = false
        persistTimer.cancel()
    }

    /// Schedule the next epoch-guarded persist probe. On fire, if the peer still
    /// advertises a Zero_Window and we still have buffered data, emit a 1-byte
    /// probe and re-arm; otherwise stop.
    private func schedulePersist() {
        persistTimer.schedule(on: stack, after: persistInterval) { [weak self] epoch in
            guard let self, self.persistTimer.accepts(epoch), self.persisting else { return }
            guard self.state == .established, self.peerWindow == 0, !self.sendBuffer.isEmpty else {
                self.persisting = false
                return
            }
            self.perform(.sendZeroWindowProbe)
            self.schedulePersist()   // keep probing until the window opens
        }
    }

    /// Emit a single-byte zero-window probe carrying the next buffered byte as new
    /// data, forcing the full peer to re-advertise its (still zero) window or, once
    /// it drains, a reopened one. Sent through the normal reliable path so the byte
    /// is retransmitted and delivered in order.
    private func sendZeroWindowProbe() {
        guard !sendBuffer.isEmpty else { return }
        let chunk = sendBuffer.popPrefix(1)
        perform(.sendControlled(flags: [.ack, .psh], payload: chunk))
    }

    private func sendControlled(flags: TCPSegment.Flags, payload: [UInt8]) {
        // Include options on SYN segments (active and passive open).
        var options: [TCPOption] = []
        if flags.contains(.syn) {
            if windowScaleOffered {
                options.append(.nop)
                options.append(.windowScale(rcvWindowScale))
            }
            if sackState.enabled {
                options.append(.nop)
                options.append(.sackPermitted)
            }
        }
        let out = TCPOutgoingSegment(sequence: sndNxt,
                                     flags: flags,
                                     payload: payload,
                                     options: options,
                                     sentAt: stack.loop.now,
                                     retransmitted: false)
        sndNxt = sndNxt &+ out.length
        retransmitQueue.append(out)
        perform(TCPConnectionPlanner.transmitAndArmTimer(out))
    }

    private func sendAck() {
        var options: [TCPOption] = []
        let blocks = sackState.sackBlocks(rcvNxt: rcvNxt)
        if !blocks.isEmpty {
            options.append(.nop)
            options.append(.nop)
            options.append(.sack(blocks))
        }
        transmitter.sendAcknowledgment(sequence: sndNxt,
                                       acknowledgment: rcvNxt,
                                       window: advertisedWindow,
                                       options: options)
    }

    private func transmit(_ out: TCPOutgoingSegment) {
        transmitter.transmit(out, acknowledgment: rcvNxt, window: advertisedWindow)
    }

    private func armRetransmitTimer() {
        // Schedule after the adaptive RTO (RFC 6298) rather than a fixed 0.2s.
        retransmitTimer.schedule(on: stack, after: rtoEstimator.rto) { [weak self] epoch in
            guard let self, self.retransmitTimer.accepts(epoch), !self.retransmitQueue.isEmpty else { return }
            // Retransmit cap (R9.4): once the oldest unacked segment has been
            // retransmitted `maxRetransmits` times in a row without any acknowledgment
            // progress, give up rather than re-arming forever. Tear the connection
            // down and wake any parked program instead of retransmitting again.
            guard self.consecutiveRetransmits < self.maxRetransmits else {
                self.perform(TCPConnectionPlanner.abortAndWakeWaiters)
                return
            }
            // RTO backoff (R6.6): double the timeout before retransmitting.
            self.rtoEstimator.onTimeout()
            // Infer heavy loss and collapse the congestion window before resending
            // (R3): ssthresh = max(FlightSize/2, 2*SMSS), cwnd = SMSS, slow start.
            // FlightSize is the unacked bytes in sequence space at timer fire.
            let flightSize = Int(self.sndNxt &- self.sndUna)
            self.congestion.onRTOExpiry(flightSize: flightSize)
            // Resend the oldest unacked segment (R3.3): mark it retransmitted (Karn)
            // and refresh its send time so a later ambiguous ACK is excluded from RTT sampling.
            // With SACK, skip entries that have been selectively acknowledged.
            guard let idx = self.retransmitQueue.firstIndex(where: { !$0.sacked }) else { return }
            self.retransmitQueue[idx].retransmitted = true
            self.retransmitQueue[idx].sentAt = self.stack.loop.now
            self.rtoRetransmitCount += 1
            self.consecutiveRetransmits += 1
            self.perform(TCPConnectionPlanner.transmitAndArmTimer(self.retransmitQueue[idx]))
        }
    }

    private func perform(_ action: TCPConnectionAction) {
        switch action {
        case .sendControlled(let flags, let payload):
            sendControlled(flags: flags, payload: payload)
        case .sendAck:
            sendAck()
        case .transmit(let segment):
            transmit(segment)
        case .fastRetransmit:
            perform(fastRetransmit())
        case .setState(let nextState):
            state = nextState
        case .markReset:
            wasReset = true
        case .removeConnection:
            stack.removeConnection(localPort: localPort, remoteIP: remoteIP, remotePort: remotePort)
        case .armRetransmitTimer:
            armRetransmitTimer()
        case .cancelRetransmitTimer:
            retransmitTimer.cancel()
        case .scheduleTimeWaitExpiry:
            scheduleTimeWaitExpiry()
        case .startPersistTimer:
            startPersistTimer()
        case .stopPersistTimer:
            stopPersistTimer()
        case .pumpSendBuffer:
            pump()
        case .sendZeroWindowProbe:
            sendZeroWindowProbe()
        case .notifyEstablished:
            notifications.established()
        case .notifyReadable:
            notifications.readable()
        case .notifyReadinessChanged:
            notifications.readinessChanged()
        case .unblockConnectAndRead:
            notifications.unblockConnectAndRead()
        }
    }

    private func perform(_ actions: [TCPConnectionAction]) {
        for action in actions {
            perform(action)
        }
    }

    // MARK: - Ingress

    func receiveSegment(_ header: TCPSegment.Header, _ payload: [UInt8]) {
        // R10: an inbound RST is handled before any other processing. An in-window
        // RST (sequence within `[rcvNxt, rcvNxt + advertisedWindow)`, using the
        // state machine's serial-window check) aborts the connection
        // (R10.1): transition to `.closed`, remove it from the stack's table, and
        // wake any parked program so it observes the abort (R10.3). An out-of-window
        // RST is dropped with state unchanged
        // (R10.4). Checked first so a reset takes precedence over ACK/data/FIN
        // handling in the state machine below.
        if header.flags.contains(.rst) {
            if TCPStateMachine.acceptsReset(sequence: header.sequence,
                                            receiveNext: rcvNxt,
                                            advertisedWindow: receiveBuffer.trueAdvertisedWindow) {
                perform(TCPConnectionPlanner.acceptedReset(state: state))
            }
            return
        }

        switch state {
        case .synSent:
            if TCPStateMachine.completesActiveOpen(header, sndUna: sndUna) {
                rcvNxt = header.sequence &+ 1
                // Window scale negotiation: if we offered and the peer's SYN-ACK
                // includes a Window Scale option, activate scaling. Otherwise both
                // shift counts stay 0 (RFC 7323 §1.3).
                if windowScaleOffered, let peerScale = header.options.firstWindowScale {
                    sndWindowScale = peerScale
                } else {
                    // Peer did not offer — disable our own scale as well.
                    rcvWindowScale = 0
                    sndWindowScale = 0
                }
                // SACK: confirm only if peer also offered SACK-Permitted.
                if !header.options.hasSACKPermitted {
                    sackState.enabled = false
                }
                peerWindow = UInt32(header.window) << sndWindowScale
                let ackActions = acknowledge(upTo: header.acknowledgment)
                state = .established
                congestion.onEstablished()
                perform(ackActions + [.sendAck, .notifyEstablished])
            }

        case .synReceived:
            if TCPStateMachine.completesPassiveOpen(header, sndUna: sndUna) {
                peerWindow = UInt32(header.window) << sndWindowScale
                let ackActions = acknowledge(upTo: header.acknowledgment)
                state = .established
                congestion.onEstablished()
                perform(ackActions)
                listener?.deliver(self)
            }

        case .established, .finWait1, .finWait2, .closeWait, .closing, .lastAck, .timeWait:
            if header.flags.contains(.ack) {
                handleIncomingAck(header, payloadEmpty: payload.isEmpty)
            }
            if !payload.isEmpty {
                perform(deliverData(sequence: header.sequence, payload: payload))
            }
            let finResult = consumeFINIfInOrder(header, payloadCount: payload.count)
            perform(finResult.actions)
            perform(TCPConnectionPlanner.closeTransition(from: state,
                                                         receivedFIN: finResult.received,
                                                         ourFinAcked: sndUna == sndNxt))

        default:
            break
        }
    }

    /// Route an incoming ACK to either the new-data path or the duplicate-ACK
    /// path (R4). An ACK that advances the cumulative acknowledgment number is
    /// processed by `acknowledge(upTo:)` (which feeds the congestion controller a
    /// new-data ACK and resets the dup-ACK count). Otherwise, if it carries no
    /// data, does not advance `sndUna`, leaves data in flight, and the advertised
    /// window is unchanged, it is a duplicate ACK: on the 3rd consecutive one we
    /// fast-retransmit the oldest unacked segment (R4.1); further duplicates
    /// inflate cwnd in fast recovery (R5.2).
    private func handleIncomingAck(_ header: TCPSegment.Header, payloadEmpty: Bool) {
        let flightSize = Int(sndNxt &- sndUna)
        let previousPeerWindow = peerWindow
        // Adopt the peer's freshly advertised Receive_Window BEFORE any (re)transmit
        // decision, so every `pump()` reached from here gates on the current window
        // rather than the previous (possibly larger) one (R12.4). The duplicate-ACK
        // test below compares against the previously-seen window, so capture it first.
        peerWindow = UInt32(header.window) << sndWindowScale
        var actions: [TCPConnectionAction] = []
        switch TCPStateMachine.ackDecision(acknowledgment: header.acknowledgment,
                                           sndUna: sndUna,
                                           sndNxt: sndNxt,
                                           payloadEmpty: payloadEmpty,
                                           previousPeerWindow: previousPeerWindow,
                                           currentPeerWindow: peerWindow) {
        case .advances:
            actions += acknowledge(upTo: header.acknowledgment)
        case .duplicate:
            // Duplicate ACK (R4): does not advance sndUna, no data, window unchanged.
            let shouldFastRetransmit = congestion.onDuplicateAck(flightSize: flightSize)
            // Fast-recovery inflation may have opened the window (R5.2, R5.4);
            // the 3rd dup-ACK schedules the immediate retransmit instead.
            actions += TCPConnectionPlanner.duplicateAck(shouldFastRetransmit: shouldFastRetransmit)
        case .ignore:
            break
        }
        // R12.3: the peer reopened its Receive_Window after a Zero_Window stall.
        // Confirm the advertised window is now > 0, cancel the persist probe, and
        // resume transmitting buffered data up to `min(cwnd, peerWindow)`.
        actions += TCPConnectionPlanner.peerWindowUpdate(previous: previousPeerWindow, current: peerWindow)
        // SACK: mark retransmit queue entries as SACKed so fast retransmit skips them.
        if sackState.enabled {
            for option in header.options {
                if case .sack(let blocks) = option {
                    TCPSACKReceiver.markSacked(retransmitQueue: &retransmitQueue, sackBlocks: blocks)
                    break
                }
            }
        }
        perform(actions)
    }

    /// Fast retransmit (R4.1): resend the oldest unacknowledged segment that has
    /// NOT been selectively acknowledged (SACK). If SACK is active, skip SACKed
    /// entries to find the first un-SACKed segment. The resent segment is marked
    /// retransmitted (Karn, so its ACK is excluded from RTT sampling) with a
    /// refreshed send time, and the retransmit timer is re-armed.
    private func fastRetransmit() -> [TCPConnectionAction] {
        guard !retransmitQueue.isEmpty else { return [] }
        // Find the first non-SACKed segment.
        guard let idx = retransmitQueue.firstIndex(where: { !$0.sacked }) else { return [] }
        retransmitQueue[idx].retransmitted = true
        retransmitQueue[idx].sentAt = stack.loop.now
        return TCPConnectionPlanner.transmitAndArmTimer(retransmitQueue[idx])
    }

    private func acknowledge(upTo ack: UInt32) -> [TCPConnectionAction] {
        let previousUna = sndUna
        let advanced = TCPSequence.greater(ack, than: sndUna)
        if advanced {
            sndUna = ack
            // Forward progress: the peer acknowledged new data, so the oldest
            // unacked segment changed. Reset the consecutive-retransmit cap counter
            // (R9.4) so only a genuinely stuck segment can exhaust it.
            consecutiveRetransmits = 0
        }

        // The entries this ACK fully acknowledges (end sequence <= sndUna).
        let ackedEntries = retransmitQueue.filter { entry in
            !TCPSequence.greater(entry.sequence &+ entry.length, than: sndUna)
        }

        // RTT sampling with Karn's algorithm (R6.7): when sndUna advances, take at
        // most one RTT sample from the newest (highest end-sequence) fully-acked
        // segment that was NEVER retransmitted. A retransmitted segment's ACK is
        // ambiguous, so it can never contribute a sample.
        if advanced {
            var newestSentAt: Double?
            var newestEnd: UInt32 = 0
            for entry in ackedEntries where !entry.retransmitted {
                let end = entry.sequence &+ entry.length
                if newestSentAt == nil || TCPSequence.greater(end, than: newestEnd) {
                    newestEnd = end
                    newestSentAt = entry.sentAt
                }
            }
            if let sentAt = newestSentAt {
                rtoEstimator.onRTTSample(stack.loop.now - sentAt)
            }
        }

        retransmitQueue.removeAll { entry in
            !TCPSequence.greater(entry.sequence &+ entry.length, than: sndUna)   // end <= sndUna => fully acked
        }

        // Feed the new-data ACK to the congestion controller (R1/R2 growth, and
        // fast-recovery exit R5.3). `ackedBytes` is how far sndUna advanced. This
        // also resets the duplicate-ACK counter (R4.4).
        if advanced {
            congestion.onNewAck(ackedBytes: Int(sndUna &- previousUna), now: stack.loop.now)
        }

        // The ACK may have advanced sndUna and opened the Send_Window; drain any
        // buffered application data that now fits (R7.4).
        return TCPConnectionPlanner.acknowledgedRetransmitQueue(hasOutstandingSegments: !retransmitQueue.isEmpty)
    }

    private func deliverData(sequence: UInt32, payload: [UInt8]) -> [TCPConnectionAction] {
        let inOrder = (sequence == rcvNxt)
        if inOrder {
            receiveBuffer.append(payload)
            rcvNxt = rcvNxt &+ UInt32(payload.count)
            // Reassemble any cached out-of-order segments that now follow rcvNxt.
            if sackState.hasOutOfOrderData {
                let (reassembled, newRcvNxt) = sackState.reassemble(rcvNxt: rcvNxt)
                if !reassembled.isEmpty {
                    receiveBuffer.append(reassembled)
                    rcvNxt = newRcvNxt
                }
            }
        } else if sackState.enabled {
            // Cache out-of-order segment for later reassembly and SACK reporting.
            sackState.cacheOutOfOrder(sequence: sequence, data: payload)
        }
        return TCPConnectionPlanner.inboundPayload(inOrder: inOrder)
    }

    /// Consume an in-order FIN (advancing rcvNxt, signalling EOF). Returns whether
    /// a new FIN was consumed; a duplicate FIN is simply re-ACKed.
    private func consumeFINIfInOrder(_ header: TCPSegment.Header,
                                     payloadCount: Int) -> TCPConnectionPlanner.FINPlan {
        let plan = TCPConnectionPlanner.inboundFIN(flags: header.flags,
                                                   segmentSequence: header.sequence,
                                                   payloadCount: payloadCount,
                                                   receiveNext: rcvNxt)
        if plan.received {
            rcvNxt = rcvNxt &+ 1
            eofReceived = true
        }
        return plan
    }

    private func scheduleTimeWaitExpiry() {
        stack.schedule(after: timeWaitDuration) { [weak self] in
            guard let self, self.state == .timeWait else { return }
            self.perform(TCPConnectionPlanner.timeWaitExpired)
        }
    }
}

/// A passive TCP endpoint: an accept waiter plus a backlog of established
/// connections waiting to be accepted.
final class TCPListener {
    let port: UInt16
    private var backlog = FIFOQueue<TCPConnection>()
    var onAccept: (() -> Void)?
    private let readinessBroadcaster = ReadinessBroadcaster()

    init(port: UInt16) {
        self.port = port
    }

    var hasPending: Bool { !backlog.isEmpty }

    func deliver(_ connection: TCPConnection) {
        backlog.append(connection)
        onAccept?()
        readinessBroadcaster.notify()
    }

    func dequeue() -> TCPConnection? {
        backlog.popFirst()
    }

    func addReadinessListener(_ listener: @escaping () -> Void) -> ReadinessSubscription {
        readinessBroadcaster.add(listener)
    }
}
