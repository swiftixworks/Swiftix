/// Common EtherTypes (the protocol carried inside an Ethernet frame).
enum EtherType: UInt16 {
    case ipv4 = 0x0800
    case arp  = 0x0806
}

/// Minimal Ethernet II framing: `[ dst:6 | src:6 | ethertype:2 | payload ]`.
/// No FCS — the virtual link is lossless at the bit level, and loss is modeled
/// explicitly by `Link`, not by a CRC.
enum EthernetFrame {
    static let headerLength = 14

    struct Header {
        let destination: MACAddress
        let source: MACAddress
        let etherType: UInt16
    }

    /// Build a frame buffer from a header + payload.
    static func build(destination: MACAddress,
                      source: MACAddress,
                      etherType: UInt16,
                      payload: [UInt8]) -> PacketBuffer {
        var buffer = PacketBuffer()
        buffer.reserveCapacity(headerLength + payload.count)
        buffer.append(destination.bytes)
        buffer.append(source.bytes)
        buffer.appendUInt16(etherType)
        buffer.append(payload)
        return buffer
    }

    /// Parse the 14-byte header. Returns `nil` if the buffer is too short or the
    /// MAC fields are malformed.
    static func parseHeader(_ buffer: PacketBuffer) -> Header? {
        guard buffer.count >= headerLength,
              let destinationBytes = buffer.slice(0..<6),
              let sourceBytes = buffer.slice(6..<12),
              let etherType = buffer.uint16(at: 12),
              let destination = MACAddress([
                  destinationBytes[destinationBytes.startIndex],
                  destinationBytes[destinationBytes.startIndex + 1],
                  destinationBytes[destinationBytes.startIndex + 2],
                  destinationBytes[destinationBytes.startIndex + 3],
                  destinationBytes[destinationBytes.startIndex + 4],
                  destinationBytes[destinationBytes.startIndex + 5],
              ]),
              let source = MACAddress([
                  sourceBytes[sourceBytes.startIndex],
                  sourceBytes[sourceBytes.startIndex + 1],
                  sourceBytes[sourceBytes.startIndex + 2],
                  sourceBytes[sourceBytes.startIndex + 3],
                  sourceBytes[sourceBytes.startIndex + 4],
                  sourceBytes[sourceBytes.startIndex + 5],
              ])
        else { return nil }
        return Header(destination: destination, source: source, etherType: etherType)
    }

    /// The payload bytes following the header (empty if there are none).
    static func payload(_ buffer: PacketBuffer) -> ArraySlice<UInt8> {
        guard buffer.count > headerLength,
              let slice = buffer.slice(headerLength..<buffer.count)
        else { return ArraySlice<UInt8>() }
        return slice
    }
}
