/// Read-only socket/link snapshots plus the two incremental removals (`route
/// del`, `neigh del`) the command-line tools need.
///
/// Everything here is value-typed and `internal`: `ss`/`netstat`/`ip` reach it
/// through `ProcessContext`, never by holding live stack objects. The removals
/// deliberately stay out of the public `NetworkConfigurationChange` enum so the
/// consumer-facing configuration surface is unchanged.
///
/// Split out of `NetworkStack.swift`; see that file for the type's role and its
/// concurrency contract. Everything here runs on the single serial executor that
/// drives the stack and holds no locks.

/// One transport endpoint as `ss`/`netstat` list it.
struct NetworkSocketSnapshot: Equatable {
    enum Kind: Equatable { case tcpListener, tcpConnection, udp }

    let kind: Kind
    /// `nil` is the wildcard address (`0.0.0.0`).
    let localAddress: IPv4Address?
    let localPort: UInt16
    /// `nil` for endpoints with no peer (listeners, unconnected UDP).
    let remoteAddress: IPv4Address?
    let remotePort: UInt16
    /// `TCPStateMachine` state name for connections, `LISTEN` for listeners and
    /// `UNCONN` for UDP sockets (UDP here is never connected).
    let state: String
    /// Bytes buffered for the application and not yet read.
    let receiveQueue: Int
    /// Bytes sent and not yet acknowledged (TCP FlightSize); 0 otherwise.
    let sendQueue: Int
}

/// One attached interface as `ip link`/`ip addr` list it.
struct NetworkLinkSnapshot {
    let index: Int
    let name: String
    let address: IPv4Address
    let prefixLength: Int
    let mac: MACAddress
    let isLoopback: Bool
    /// Whether a link/switch has claimed the egress seam — the closest thing the
    /// single-node core has to carrier. Administrative state is not modeled.
    let hasCarrier: Bool
    let counters: NetworkInterfaceCounters
}

extension NetworkStack {

    func snapshotLinks() -> [NetworkLinkSnapshot] {
        interfaces.enumerated().map { index, interface in
            let name = interfaceTable.name(for: index)
            return NetworkLinkSnapshot(index: index,
                                       name: name,
                                       address: interface.address,
                                       prefixLength: interface.prefixLength,
                                       mac: interface.mac,
                                       isLoopback: name == "lo",
                                       hasCarrier: interface.onEgress != nil,
                                       counters: interface.counters)
        }
    }

    /// Every TCP listener, TCP connection and bound UDP socket, ordered by
    /// protocol kind, then local port, then peer.
    func snapshotSockets() -> [NetworkSocketSnapshot] {
        var sockets: [NetworkSocketSnapshot] = []
        for port in transport.tcpListeners.keys.sorted() {
            sockets.append(NetworkSocketSnapshot(kind: .tcpListener,
                                                 localAddress: nil,
                                                 localPort: port,
                                                 remoteAddress: nil,
                                                 remotePort: 0,
                                                 state: "LISTEN",
                                                 receiveQueue: 0,
                                                 sendQueue: 0))
        }
        let connections = transport.tcpConnections.values.sorted {
            if $0.localPort != $1.localPort { return $0.localPort < $1.localPort }
            if $0.remoteIP.raw != $1.remoteIP.raw { return $0.remoteIP.raw < $1.remoteIP.raw }
            return $0.remotePort < $1.remotePort
        }
        for connection in connections {
            let snapshot = connection.snapshot
            sockets.append(NetworkSocketSnapshot(kind: .tcpConnection,
                                                 localAddress: sourceAddress(toward: connection.remoteIP),
                                                 localPort: snapshot.localPort,
                                                 remoteAddress: snapshot.remoteIP,
                                                 remotePort: snapshot.remotePort,
                                                 state: snapshot.state,
                                                 receiveQueue: snapshot.receiveBufferOccupancy,
                                                 sendQueue: connection.flightSize))
        }
        for port in transport.udpSockets.keys.sorted() {
            guard let socket = transport.udpSockets[port] else { continue }
            sockets.append(NetworkSocketSnapshot(kind: .udp,
                                                 localAddress: socket.localAddress,
                                                 localPort: port,
                                                 remoteAddress: nil,
                                                 remotePort: 0,
                                                 state: "UNCONN",
                                                 receiveQueue: socket.queueStatistics.bytes,
                                                 sendQueue: 0))
        }
        return sockets
    }

    /// The local address a packet to `destination` would leave from: the address
    /// of the interface the routing table selects. A TCP connection does not
    /// store its local address (it is implied by the egress interface), so the
    /// socket listing derives it the same way the egress path does.
    func sourceAddress(toward destination: IPv4Address) -> IPv4Address? {
        if let own = interfaces.first(where: { $0.address == destination }) { return own.address }
        guard let route = routeTable.lookup(destination: destination) else { return nil }
        return interfaceTable.interface(at: route.interfaceIndex)?.address
    }

    /// Remove the first route matching `destination/prefixLength` and, when
    /// given, the gateway and interface. Returns whether a route was removed.
    @discardableResult
    func removeRoute(destination: IPv4Address,
                     prefixLength: Int,
                     gateway: IPv4Address?,
                     interfaceIndex: Int?) -> Bool {
        routeTable.remove(destination: destination,
                          prefixLength: prefixLength,
                          gateway: gateway,
                          interfaceIndex: interfaceIndex)
    }

    /// Forget a resolved neighbor binding. Returns whether one existed.
    @discardableResult
    func removeNeighbor(ip: IPv4Address) -> Bool {
        neighborCache.remove(ip: ip)
    }
}
