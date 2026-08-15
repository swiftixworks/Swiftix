/// A minimal DNS wire codec (RFC 1035 subset): a single question, `A`/`IN`
/// records only, no recursion state. It is the format shared by the resolver
/// client (`ProcessContext.resolve`) and the `dnsd` server program — DNS as one
/// more application protocol carried over the user-space UDP stack, the same way
/// `httpd` rides TCP.
///
/// Pure standard library, `internal` like the other protocol codecs. Names are
/// encoded as length-prefixed labels; the parser understands compression
/// pointers on decode (so it can read replies from stricter servers), while the
/// encoders here never compress, keeping the emitted bytes trivial to reason
/// about.
enum DNS {

    /// Standard DNS server port.
    static let port: UInt16 = 53

    // MARK: - Encoding

    /// Build a query for `name` (recursion-desired, one A/IN question).
    static func encodeQuery(id: UInt16, name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        appendHeader(&bytes, id: id, flags: 0x0100, qd: 1, an: 0)   // RD=1
        appendQuestion(&bytes, name: name)
        return bytes
    }

    /// Build a response echoing the question and answering with `address`
    /// (one A/IN record, TTL 60).
    static func encodeResponse(id: UInt16, name: String, address: IPv4Address) -> [UInt8] {
        var bytes: [UInt8] = []
        appendHeader(&bytes, id: id, flags: 0x8180, qd: 1, an: 1)   // QR=1, RD=1, RA=1
        appendQuestion(&bytes, name: name)
        // Answer: NAME (repeated, uncompressed), TYPE=A, CLASS=IN, TTL=60, RDATA.
        appendName(&bytes, name)
        appendUInt16(&bytes, 1)          // TYPE A
        appendUInt16(&bytes, 1)          // CLASS IN
        appendUInt32(&bytes, 60)         // TTL
        appendUInt16(&bytes, 4)          // RDLENGTH
        let o = address.octets
        bytes.append(contentsOf: [o.0, o.1, o.2, o.3])
        return bytes
    }

    /// Build an NXDOMAIN response (name not found) echoing the question.
    static func encodeNotFound(id: UInt16, name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        appendHeader(&bytes, id: id, flags: 0x8183, qd: 1, an: 0)   // QR=1, RD=1, RA=1, RCODE=3
        appendQuestion(&bytes, name: name)
        return bytes
    }

    // MARK: - Decoding

    /// Parse a query: returns the transaction id and the questioned name.
    static func parseQuery(_ bytes: [UInt8]) -> (id: UInt16, name: String)? {
        guard bytes.count >= 12 else { return nil }
        let id = uint16(bytes, 0)
        let qd = uint16(bytes, 4)
        guard qd >= 1 else { return nil }
        let offset = 12
        guard let (name, _) = readName(bytes, offset) else { return nil }
        return (id, name)
    }

    /// Parse a response: returns the transaction id and the first A record's
    /// address (or `nil` address when the name was not resolved / NXDOMAIN).
    static func parseResponse(_ bytes: [UInt8]) -> (id: UInt16, address: IPv4Address?)? {
        guard bytes.count >= 12 else { return nil }
        let id = uint16(bytes, 0)
        let qd = uint16(bytes, 4)
        let an = uint16(bytes, 6)
        var offset = 12
        // Skip the question section.
        for _ in 0..<qd {
            guard let next = skipName(bytes, offset) else { return nil }
            offset = next + 4   // QTYPE + QCLASS
        }
        // Walk answers; return the first A record.
        for _ in 0..<an {
            guard let afterName = skipName(bytes, offset) else { return nil }
            var o = afterName
            guard o + 10 <= bytes.count else { return nil }
            let type = uint16(bytes, o)
            let rdlength = Int(uint16(bytes, o + 8))
            o += 10
            guard o + rdlength <= bytes.count else { return nil }
            if type == 1, rdlength == 4 {
                return (id, IPv4Address(bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]))
            }
            o += rdlength
            offset = o
        }
        return (id, nil)
    }

    // MARK: - Header / question builders

    private static func appendHeader(_ bytes: inout [UInt8], id: UInt16, flags: UInt16, qd: UInt16, an: UInt16) {
        appendUInt16(&bytes, id)
        appendUInt16(&bytes, flags)
        appendUInt16(&bytes, qd)
        appendUInt16(&bytes, an)
        appendUInt16(&bytes, 0)   // NSCOUNT
        appendUInt16(&bytes, 0)   // ARCOUNT
    }

    private static func appendQuestion(_ bytes: inout [UInt8], name: String) {
        appendName(&bytes, name)
        appendUInt16(&bytes, 1)   // QTYPE A
        appendUInt16(&bytes, 1)   // QCLASS IN
    }

    /// Encode a domain name as length-prefixed labels ending in a zero byte.
    private static func appendName(_ bytes: inout [UInt8], _ name: String) {
        for label in name.split(separator: ".") {
            let utf8 = Array(label.utf8)
            bytes.append(UInt8(min(utf8.count, 63)))
            bytes.append(contentsOf: utf8.prefix(63))
        }
        bytes.append(0)
    }

    // MARK: - Name readers

    /// Read a (possibly compressed) name at `offset`; returns the decoded name
    /// and the offset just past the name *in the record stream* (i.e. past the
    /// pointer, if one was used).
    private static func readName(_ bytes: [UInt8], _ offset: Int) -> (name: String, next: Int)? {
        var labels: [String] = []
        var o = offset
        var next = -1
        var hops = 0
        while o < bytes.count {
            let len = Int(bytes[o])
            if len == 0 { o += 1; if next < 0 { next = o }; break }
            if len & 0xC0 == 0xC0 {                       // compression pointer
                guard o + 1 < bytes.count else { return nil }
                if next < 0 { next = o + 2 }
                o = Int(uint16(bytes, o)) & 0x3FFF
                hops += 1
                if hops > 20 { return nil }
                continue
            }
            guard o + 1 + len <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[(o + 1)..<(o + 1 + len)], as: UTF8.self))
            o += 1 + len
        }
        return (labels.joined(separator: "."), next < 0 ? o : next)
    }

    /// Return the offset just past the name starting at `offset`, or `nil`.
    private static func skipName(_ bytes: [UInt8], _ offset: Int) -> Int? {
        readName(bytes, offset)?.next
    }

    // MARK: - Integer helpers (big-endian)

    private static func appendUInt16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(value >> 8)); bytes.append(UInt8(value & 0xFF))
    }
    private static func appendUInt32(_ bytes: inout [UInt8], _ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF)); bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF));  bytes.append(UInt8(value & 0xFF))
    }
    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
}
