/// IPv4 packet construction and parsing isolated from routing and transport state.
final class NetworkIPv4Layer {
    func build(source: IPv4Address,
               destination: IPv4Address,
               proto: UInt8,
               ttl: UInt8 = 64,
               ecn: UInt8 = 0,
               payload: [UInt8]) -> [UInt8] {
        IPv4Packet.build(source: source, destination: destination, proto: proto, ttl: ttl, ecn: ecn, payload: payload)
    }

    func parse(_ payload: ArraySlice<UInt8>) -> (IPv4Packet.Header, ArraySlice<UInt8>)? {
        IPv4Packet.parse(payload)
    }
}
