/// Mutable UDP/TCP/ICMP demultiplexing tables owned by one network stack.
final class NetworkTransportDemux {
    var udpSockets: [UInt16: UDPSocket] = [:]
    // The reply callback carries the responder's address and the IPv4 TTL of the
    // reply packet, so `ping` can surface a real `ttl=` like Linux (an echo reply
    // from a directly-attached peer arrives with its default TTL; one relayed
    // through routers arrives decremented).
    var echoWaiters: [UInt32: (IPv4Address, UInt8) -> Void] = [:]
    var tcpListeners: [UInt16: TCPListener] = [:]
    var tcpConnections: [NetworkStack.TCPKey: TCPConnection] = [:]

    private var nextEphemeralPort: UInt16 = 49152
    private var nextISSValue: UInt32 = 1000

    func allocateEphemeralPort() -> UInt16 {
        for _ in 0..<16384 {
            let port = nextEphemeralPort
            nextEphemeralPort = (nextEphemeralPort == UInt16.max) ? 49152 : nextEphemeralPort + 1
            if !isPortInUse(port) { return port }
        }
        return nextEphemeralPort
    }

    func nextISS() -> UInt32 {
        let value = nextISSValue
        nextISSValue = nextISSValue &+ 1000
        return value
    }

    private func isPortInUse(_ port: UInt16) -> Bool {
        if udpSockets[port] != nil || tcpListeners[port] != nil { return true }
        return tcpConnections.keys.contains { $0.localPort == port }
    }
}
