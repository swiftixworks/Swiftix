import Testing
@testable import Swiftix

/// Round-trip property for the transport-layer checksum helper (design.md §3,
/// Property 1). A message built with its computed checksum verifies to true;
/// flipping any byte makes it verify false.
@Suite("Transport checksum helper")
struct TransportChecksumTests {

    private let source = IPv4Address(10, 0, 0, 1)
    private let destination = IPv4Address(10, 0, 0, 2)

    /// The pseudo-header is src(4) | dst(4) | zero(1) | proto(1) | length(2).
    @Test func pseudoHeaderLayout() {
        let header = TransportChecksum.pseudoHeader(source: source,
                                                    destination: destination,
                                                    proto: IPProtocol.tcp.rawValue,
                                                    length: 0x1234)
        #expect(header == [10, 0, 0, 1,       // source
                           10, 0, 0, 2,       // destination
                           0,                 // zero
                           6,                 // proto (TCP)
                           0x12, 0x34])       // length
    }

    /// Build a TCP-style segment (checksum field at offset 16), stamp the
    /// computed checksum, and confirm it verifies.
    @Test func tcpChecksumRoundTrips() {
        var segment = [UInt8]((0..<24).map { UInt8($0) })
        segment[16] = 0; segment[17] = 0            // checksum field starts at 0
        let checksum = TransportChecksum.transport(source: source,
                                                   destination: destination,
                                                   proto: IPProtocol.tcp.rawValue,
                                                   segment: segment)
        segment[16] = UInt8((checksum >> 8) & 0xFF)
        segment[17] = UInt8(checksum & 0xFF)
        #expect(TransportChecksum.verifyTransport(source: source,
                                                  destination: destination,
                                                  proto: IPProtocol.tcp.rawValue,
                                                  segment: segment))
    }

    /// Build a UDP-style datagram (checksum field at offset 6) and confirm the
    /// round-trip holds for the UDP protocol number.
    @Test func udpChecksumRoundTrips() {
        var segment = [UInt8]((0..<16).map { UInt8($0 &* 3) })
        segment[6] = 0; segment[7] = 0
        let checksum = TransportChecksum.transport(source: source,
                                                   destination: destination,
                                                   proto: IPProtocol.udp.rawValue,
                                                   segment: segment)
        segment[6] = UInt8((checksum >> 8) & 0xFF)
        segment[7] = UInt8(checksum & 0xFF)
        #expect(TransportChecksum.verifyTransport(source: source,
                                                  destination: destination,
                                                  proto: IPProtocol.udp.rawValue,
                                                  segment: segment))
    }

    /// An ICMP echo built via `ICMPMessage.buildEcho` carries a checksum over
    /// the message alone (no pseudo-header) and verifies to true.
    @Test func icmpChecksumRoundTrips() {
        let message = ICMPMessage.buildEcho(type: .echoRequest,
                                            identifier: 0xABCD,
                                            sequence: 7,
                                            payload: [1, 2, 3, 4, 5])
        #expect(TransportChecksum.verifyICMP(message))
    }

    /// Flipping any single byte of a checksummed TCP segment breaks verification.
    @Test func flippingAnyByteFailsTransportVerification() {
        var base = [UInt8]((0..<24).map { UInt8($0 &+ 7) })
        base[16] = 0; base[17] = 0
        let checksum = TransportChecksum.transport(source: source,
                                                   destination: destination,
                                                   proto: IPProtocol.tcp.rawValue,
                                                   segment: base)
        base[16] = UInt8((checksum >> 8) & 0xFF)
        base[17] = UInt8(checksum & 0xFF)

        for index in base.indices {
            var corrupted = base
            corrupted[index] ^= 0xFF
            #expect(!TransportChecksum.verifyTransport(source: source,
                                                       destination: destination,
                                                       proto: IPProtocol.tcp.rawValue,
                                                       segment: corrupted),
                    "flipping byte \(index) should fail verification")
        }
    }

    /// Flipping any single byte of a checksummed ICMP message breaks verification.
    @Test func flippingAnyByteFailsICMPVerification() {
        let message = ICMPMessage.buildEcho(type: .echoReply,
                                            identifier: 0x1111,
                                            sequence: 42,
                                            payload: [9, 8, 7, 6])
        for index in message.indices {
            var corrupted = message
            corrupted[index] ^= 0xFF
            #expect(!TransportChecksum.verifyICMP(corrupted),
                    "flipping byte \(index) should fail verification")
        }
    }
}
