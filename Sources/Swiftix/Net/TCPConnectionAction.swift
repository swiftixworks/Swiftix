/// Explicit side-effect actions emitted by pure TCP planners and state machines.
enum TCPConnectionAction: Equatable {
    case sendControlled(flags: TCPSegment.Flags, payload: [UInt8])
    case sendAck
    /// Emit an RST|ACK at `sndNxt`: the local side is aborting the connection.
    case sendReset
    /// The FIN is owed but application bytes are still unsent; it follows them.
    case deferFIN
    case transmit(TCPOutgoingSegment)
    case fastRetransmit
    case setState(TCPState)
    case markReset
    case removeConnection
    case armRetransmitTimer
    case cancelRetransmitTimer
    case scheduleTimeWaitExpiry
    case scheduleOrphanTimeout
    case startPersistTimer
    case stopPersistTimer
    case pumpSendBuffer
    case sendZeroWindowProbe
    case notifyEstablished
    case notifyReadable
    case notifyReadinessChanged
    case unblockConnectAndRead
}
