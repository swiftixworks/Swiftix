/// ARP for IPv4-over-Ethernet (RFC 826). 28-byte payload.
enum ARPPacket {
    static let length = 28

    enum Opcode: UInt16 {
        case request = 1
        case reply = 2
    }

    struct Packet {
        let opcode: UInt16
        let senderMAC: MACAddress
        let senderIP: IPv4Address
        let targetMAC: MACAddress
        let targetIP: IPv4Address
    }

    static func build(opcode: Opcode,
                      senderMAC: MACAddress,
                      senderIP: IPv4Address,
                      targetMAC: MACAddress,
                      targetIP: IPv4Address) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        bytes.append(contentsOf: [0x00, 0x01])   // HTYPE = Ethernet
        bytes.append(contentsOf: [0x08, 0x00])   // PTYPE = IPv4
        bytes.append(6)                          // HLEN
        bytes.append(4)                          // PLEN
        bytes.append(UInt8((opcode.rawValue >> 8) & 0xFF))
        bytes.append(UInt8(opcode.rawValue & 0xFF))
        bytes.append(contentsOf: senderMAC.bytes)
        let sip = senderIP.octets
        bytes.append(sip.0); bytes.append(sip.1); bytes.append(sip.2); bytes.append(sip.3)
        bytes.append(contentsOf: targetMAC.bytes)
        let tip = targetIP.octets
        bytes.append(tip.0); bytes.append(tip.1); bytes.append(tip.2); bytes.append(tip.3)
        return bytes
    }

    static func parse(_ bytes: ArraySlice<UInt8>) -> Packet? {
        let base = bytes.startIndex
        guard bytes.count >= length else { return nil }
        let opcode = (UInt16(bytes[base + 6]) << 8) | UInt16(bytes[base + 7])
        guard let senderMAC = MACAddress(Array(bytes[(base + 8)..<(base + 14)])) else { return nil }
        let senderIP = IPv4Address(bytes[base + 14], bytes[base + 15], bytes[base + 16], bytes[base + 17])
        guard let targetMAC = MACAddress(Array(bytes[(base + 18)..<(base + 24)])) else { return nil }
        let targetIP = IPv4Address(bytes[base + 24], bytes[base + 25], bytes[base + 26], bytes[base + 27])
        return Packet(opcode: opcode,
                      senderMAC: senderMAC,
                      senderIP: senderIP,
                      targetMAC: targetMAC,
                      targetIP: targetIP)
    }
}
