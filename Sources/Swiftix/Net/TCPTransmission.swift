/// TCP segment descriptions and the executor that serializes them onto IPv4.
struct TCPOutgoingSegment: Equatable {
    let sequence: UInt32
    let flags: TCPSegment.Flags
    let payload: [UInt8]
    /// TCP options to include when this segment is transmitted (typically only on
    /// SYN/SYN-ACK for window scale, MSS, etc.). Empty for data segments.
    let options: [TCPOption]
    var sentAt: Double
    var retransmitted: Bool
    /// Whether this segment has been selectively acknowledged by the receiver
    /// (SACK). SACKed segments are skipped during fast retransmit since the peer
    /// already has the data.
    var sacked: Bool

    init(sequence: UInt32, flags: TCPSegment.Flags, payload: [UInt8],
         options: [TCPOption] = [], sentAt: Double, retransmitted: Bool) {
        self.sequence = sequence
        self.flags = flags
        self.payload = payload
        self.options = options
        self.sentAt = sentAt
        self.retransmitted = retransmitted
        self.sacked = false
    }

    var length: UInt32 {
        UInt32(payload.count) + ((flags.contains(.syn) || flags.contains(.fin)) ? 1 : 0)
    }
}

struct TCPTransmitter {
    private unowned let stack: NetworkStack
    private let localPort: UInt16
    private let remoteIP: IPv4Address
    private let remotePort: UInt16

    init(stack: NetworkStack, localPort: UInt16, remoteIP: IPv4Address, remotePort: UInt16) {
        self.stack = stack
        self.localPort = localPort
        self.remoteIP = remoteIP
        self.remotePort = remotePort
    }

    func sendAcknowledgment(sequence: UInt32, acknowledgment: UInt32, window: UInt16,
                            options: [TCPOption] = []) {
        let segment = build(sequence: sequence,
                            acknowledgment: acknowledgment,
                            flags: [.ack],
                            window: window,
                            options: options,
                            payload: [])
        stack.sendTCP(segment, to: remoteIP)
    }

    func transmit(_ outgoing: TCPOutgoingSegment, acknowledgment: UInt32, window: UInt16) {
        let segment = build(sequence: outgoing.sequence,
                            acknowledgment: acknowledgment,
                            flags: outgoing.flags,
                            window: window,
                            options: outgoing.options,
                            payload: outgoing.payload)
        stack.sendTCP(segment, to: remoteIP)
    }

    private func build(sequence: UInt32,
                       acknowledgment: UInt32,
                       flags: TCPSegment.Flags,
                       window: UInt16,
                       options: [TCPOption] = [],
                       payload: [UInt8]) -> [UInt8] {
        TCPSegment.build(sourcePort: localPort,
                         destinationPort: remotePort,
                         sequence: sequence,
                         acknowledgment: acknowledgment,
                         flags: flags,
                         window: window,
                         options: options,
                         payload: payload)
    }
}
