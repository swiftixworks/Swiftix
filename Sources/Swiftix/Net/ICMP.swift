/// ICMP echo (RFC 792): type(1), code(1), checksum(2), identifier(2),
/// sequence(2), then payload. Checksum is computed on build; on parse it is
/// read but not enforced (consistent with IPv4Packet, so an internal datagram
/// is never dropped over a checksum bug while the stack is young).
enum ICMPMessage {
    static let headerLength = 8

    enum MessageType: UInt8 {
        case echoReply = 0
        case destinationUnreachable = 3
        case echoRequest = 8
        case timeExceeded = 11
    }

    struct Echo {
        let type: UInt8
        let identifier: UInt16
        let sequence: UInt16
        let payload: [UInt8]
    }

    static func buildEcho(type: MessageType,
                          identifier: UInt16,
                          sequence: UInt16,
                          payload: [UInt8]) -> [UInt8] {
        var message = [UInt8](repeating: 0, count: headerLength + payload.count)
        message[0] = type.rawValue
        message[4] = UInt8((identifier >> 8) & 0xFF)
        message[5] = UInt8(identifier & 0xFF)
        message[6] = UInt8((sequence >> 8) & 0xFF)
        message[7] = UInt8(sequence & 0xFF)
        message.replaceSubrange(headerLength..., with: payload)
        // Route the ICMP checksum through the shared transport-checksum helper so
        // all egress checksumming lives in one place (design.md §3, R7.3). The
        // computation is identical (one's-complement fold over the message with a
        // zero checksum field), so this does not change the emitted bytes.
        let checksum = TransportChecksum.icmp(message)
        message[2] = UInt8((checksum >> 8) & 0xFF)
        message[3] = UInt8(checksum & 0xFF)
        return message
    }

    static func buildError(type: MessageType,
                           code: UInt8,
                           originalDatagram: [UInt8]) -> [UInt8] {
        let quoteLength = min(originalDatagram.count, IPv4Packet.headerLength + 8)
        var message = [UInt8](repeating: 0, count: headerLength)
        message[0] = type.rawValue
        message[1] = code
        message.append(contentsOf: originalDatagram.prefix(quoteLength))
        let checksum = TransportChecksum.icmp(message)
        message[2] = UInt8((checksum >> 8) & 0xFF)
        message[3] = UInt8(checksum & 0xFF)
        return message
    }

    static func parseEcho(_ bytes: ArraySlice<UInt8>) -> Echo? {
        let base = bytes.startIndex
        guard bytes.count >= headerLength else { return nil }
        let type = bytes[base]
        let identifier = (UInt16(bytes[base + 4]) << 8) | UInt16(bytes[base + 5])
        let sequence = (UInt16(bytes[base + 6]) << 8) | UInt16(bytes[base + 7])
        let payload = Array(bytes[(base + headerLength)..<bytes.endIndex])
        return Echo(type: type, identifier: identifier, sequence: sequence, payload: payload)
    }
}
