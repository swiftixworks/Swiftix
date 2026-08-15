/// Transport-layer 16-bit one's-complement checksums (design.md §3).
///
/// TCP and UDP checksums cover an IPv4 **pseudo-header** (source address,
/// destination address, protocol, transport length) prepended to the transport
/// segment; ICMP checksums cover the message alone. All folding reuses
/// `IPv4Packet.onesComplementChecksum`, the same routine that computes and
/// verifies the IPv4 header checksum, so the round-trip property holds:
/// summing a message that already carries its correct checksum yields 0.
enum TransportChecksum {
    /// Build the IPv4 pseudo-header: src(4) | dst(4) | zero(1) | proto(1) | length(2).
    static func pseudoHeader(source: IPv4Address,
                             destination: IPv4Address,
                             proto: UInt8,
                             length: Int) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 12)
        let s = source.octets
        header[0] = s.0; header[1] = s.1; header[2] = s.2; header[3] = s.3
        let d = destination.octets
        header[4] = d.0; header[5] = d.1; header[6] = d.2; header[7] = d.3
        header[8] = 0                                   // zero
        header[9] = proto
        header[10] = UInt8((length >> 8) & 0xFF)
        header[11] = UInt8(length & 0xFF)
        return header
    }

    /// Compute the TCP/UDP checksum over pseudo-header + `segment`.
    /// The segment's own checksum field must be 0 when passed in.
    static func transport<C: Collection>(source: IPv4Address,
                                         destination: IPv4Address,
                                         proto: UInt8,
                                         segment: C) -> UInt16
    where C.Element == UInt8 {
        IPv4Packet.onesComplementChecksum(
            initialSum: pseudoHeaderWordSum(source: source,
                                            destination: destination,
                                            proto: proto,
                                            length: segment.count),
            segment)
    }

    /// Compute the ICMP checksum over the message only (no pseudo-header).
    /// The message's own checksum field must be 0 when passed in.
    static func icmp<C: Collection>(_ message: C) -> UInt16 where C.Element == UInt8 {
        IPv4Packet.onesComplementChecksum(message)
    }

    /// Verify a TCP/UDP segment that already carries its checksum: folding
    /// pseudo-header + segment yields 0 for an intact message.
    static func verifyTransport<C: Collection>(source: IPv4Address,
                                               destination: IPv4Address,
                                               proto: UInt8,
                                               segment: C) -> Bool
    where C.Element == UInt8 {
        transport(source: source,
                  destination: destination,
                  proto: proto,
                  segment: segment) == 0
    }

    /// Verify an ICMP message that already carries its checksum: folding the
    /// message yields 0 for an intact message.
    static func verifyICMP<C: Collection>(_ message: C) -> Bool where C.Element == UInt8 {
        IPv4Packet.onesComplementChecksum(message) == 0
    }

    private static func pseudoHeaderWordSum(source: IPv4Address,
                                            destination: IPv4Address,
                                            proto: UInt8,
                                            length: Int) -> UInt32 {
        let s = source.octets
        let d = destination.octets
        func word(_ high: UInt8, _ low: UInt8) -> UInt32 {
            (UInt32(high) << 8) | UInt32(low)
        }
        return word(s.0, s.1)
            + word(s.2, s.3)
            + word(d.0, d.1)
            + word(d.2, d.3)
            + UInt32(proto)
            + UInt32(length & 0xFFFF)
    }
}
