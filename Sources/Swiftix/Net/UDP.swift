/// Minimal UDP datagram build/parse. The checksum is set to 0 (legal for IPv4,
/// which makes it optional) until the stack needs to interoperate with peers
/// that require it.
enum UDPDatagram {
    static let headerLength = 8

    struct Header {
        let sourcePort: UInt16
        let destinationPort: UInt16
        let length: Int
    }

    static func build(sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8]) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(headerLength + payload.count)
        bytes.append(UInt8((sourcePort >> 8) & 0xFF))
        bytes.append(UInt8(sourcePort & 0xFF))
        bytes.append(UInt8((destinationPort >> 8) & 0xFF))
        bytes.append(UInt8(destinationPort & 0xFF))
        let length = headerLength + payload.count
        bytes.append(UInt8((length >> 8) & 0xFF))
        bytes.append(UInt8(length & 0xFF))
        bytes.append(0)   // checksum high (0 = unused in IPv4)
        bytes.append(0)   // checksum low
        bytes.append(contentsOf: payload)
        return bytes
    }

    static func parse(_ bytes: ArraySlice<UInt8>) -> (header: Header, payload: ArraySlice<UInt8>)? {
        let base = bytes.startIndex
        guard bytes.count >= headerLength else { return nil }
        let sourcePort = (UInt16(bytes[base]) << 8) | UInt16(bytes[base + 1])
        let destinationPort = (UInt16(bytes[base + 2]) << 8) | UInt16(bytes[base + 3])
        let length = (Int(bytes[base + 4]) << 8) | Int(bytes[base + 5])
        let payloadStart = base + headerLength
        let payloadEnd = min(base + max(length, headerLength), bytes.endIndex)
        guard payloadEnd >= payloadStart else { return nil }
        let header = Header(sourcePort: sourcePort, destinationPort: destinationPort, length: length)
        return (header, bytes[payloadStart..<payloadEnd])
    }
}
