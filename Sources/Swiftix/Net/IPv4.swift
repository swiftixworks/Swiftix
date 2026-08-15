/// IPv4 protocol numbers we care about.
enum IPProtocol: UInt8 {
    case icmp = 1
    case tcp = 6
    case udp = 17
}

/// Minimal IPv4 packet build/parse. No options (IHL fixed at 5 → 20 bytes) and
/// no fragmentation. The header checksum is computed on build and **verified on
/// parse** — a datagram with a bad header checksum is dropped (parse returns nil).
enum IPv4Packet {
    static let headerLength = 20

    struct Header {
        let totalLength: Int
        let proto: UInt8
        let ttl: UInt8
        let ecn: UInt8     // ECN field (bottom 2 bits of TOS byte): 0=Not-ECT, 1/2=ECT, 3=CE
        let source: IPv4Address
        let destination: IPv4Address

        /// Whether this packet was marked Congestion Experienced by a router.
        var isCongestionExperienced: Bool { ecn == 3 }
        /// Whether this packet is ECN-Capable Transport (ECT(0) or ECT(1)).
        var isECNCapable: Bool { ecn == 1 || ecn == 2 }
    }

    /// ECN codepoints (RFC 3168).
    static let ecnNotECT: UInt8 = 0
    static let ecnECT0: UInt8 = 2
    static let ecnECT1: UInt8 = 1
    static let ecnCE: UInt8 = 3

    static func build(source: IPv4Address,
                      destination: IPv4Address,
                      proto: UInt8,
                      ttl: UInt8 = 64,
                      ecn: UInt8 = 0,
                      payload: [UInt8]) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: headerLength + payload.count)
        packet[0] = 0x45                       // version 4, IHL 5
        packet[1] = ecn & 0x03                 // TOS: DSCP=0, ECN in bottom 2 bits
        let total = headerLength + payload.count
        packet[2] = UInt8((total >> 8) & 0xFF)
        packet[3] = UInt8(total & 0xFF)
        packet[8] = ttl
        packet[9] = proto
        let s = source.octets
        packet[12] = s.0; packet[13] = s.1; packet[14] = s.2; packet[15] = s.3
        let d = destination.octets
        packet[16] = d.0; packet[17] = d.1; packet[18] = d.2; packet[19] = d.3
        let checksum = onesComplementChecksum(packet[..<headerLength])
        packet[10] = UInt8((checksum >> 8) & 0xFF)
        packet[11] = UInt8(checksum & 0xFF)
        packet.replaceSubrange(headerLength..., with: payload)
        return packet
    }

    static func parse(_ bytes: ArraySlice<UInt8>) -> (header: Header, payload: ArraySlice<UInt8>)? {
        let base = bytes.startIndex
        guard bytes.count >= headerLength else { return nil }
        let versionIHL = bytes[base]
        guard versionIHL >> 4 == 4 else { return nil }
        let ihl = Int(versionIHL & 0x0F) * 4
        guard ihl >= headerLength, bytes.count >= ihl else { return nil }
        // Verify the header checksum: summing the whole header (checksum field
        // included) must yield 0 for an intact header. Drop on mismatch.
        guard onesComplementChecksum(bytes[base..<(base + ihl)]) == 0 else { return nil }
        let total = (Int(bytes[base + 2]) << 8) | Int(bytes[base + 3])
        let ecn = bytes[base + 1] & 0x03
        let ttl = bytes[base + 8]
        let proto = bytes[base + 9]
        let source = IPv4Address(bytes[base + 12], bytes[base + 13], bytes[base + 14], bytes[base + 15])
        let destination = IPv4Address(bytes[base + 16], bytes[base + 17], bytes[base + 18], bytes[base + 19])
        let payloadStart = base + ihl
        let payloadEnd = min(base + total, bytes.endIndex)
        guard payloadEnd >= payloadStart else { return nil }
        let header = Header(totalLength: total, proto: proto, ttl: ttl, ecn: ecn, source: source, destination: destination)
        return (header, bytes[payloadStart..<payloadEnd])
    }

    /// Standard 16-bit one's-complement checksum over a byte buffer.
    static func onesComplementChecksum<C: Collection>(_ bytes: C) -> UInt16
    where C.Element == UInt8 {
        onesComplementChecksum(initialSum: 0, bytes)
    }

    /// Fold `bytes` onto an already word-aligned partial checksum. Transport
    /// pseudo-headers are an even number of bytes, so this avoids materializing
    /// and concatenating a temporary pseudo-header with every segment.
    static func onesComplementChecksum<C: Collection>(
        initialSum: UInt32,
        _ bytes: C
    ) -> UInt16 where C.Element == UInt8 {
        var sum = initialSum
        var highByte: UInt8?
        for byte in bytes {
            if let high = highByte {
                sum += (UInt32(high) << 8) | UInt32(byte)
                highByte = nil
            } else {
                highByte = byte
            }
        }
        if let highByte { sum += UInt32(highByte) << 8 }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }
}
