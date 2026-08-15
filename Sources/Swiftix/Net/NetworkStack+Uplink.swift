/// Uplink attachment: the user-mode NAT / real-network bridge seam.
///
/// Installing an uplink also installs the interface, route, and neighbour
/// entries the NAT gateway needs, which is why the low-level install helpers
/// live here alongside it.
///
/// Split out of `NetworkStack.swift`; see that file for the type's role and its
/// concurrency contract. Everything here runs on the single serial executor that
/// drives the stack and holds no locks.

extension NetworkStack {

    // MARK: - Uplink (user-mode NAT / real-network bridge)

    /// Install a real-network uplink so this host acts as a SLIRP-style NAT
    /// gateway. Once installed, inbound IPv4 traffic whose destination is not
    /// local is TERMINATED and relayed to the real network through `transport`
    /// (the consumer provides the concrete real sockets) instead of being
    /// L3-forwarded. Replacing an existing uplink tears the previous one down.
    /// See Uplink.swift for the seam and the concurrency contract.
    public func installUplink(_ transport: any UplinkTransport) {
        uplink?.shutdown()
        uplink = UplinkNAT(stack: self, transport: transport)
    }

    /// Remove and tear down the real-network uplink, aborting every relayed flow.
    public func removeUplink() {
        uplink?.shutdown()
        uplink = nil
    }

    /// Whether a real-network uplink is currently installed.
    public var hasUplink: Bool { uplink != nil }

    /// Cancel every real transport association owned by `guest`. A multi-VM
    /// consumer calls this before releasing that guest's interface/kernel
    /// generation, preventing delayed host callbacks or reused tuples from
    /// crossing a VM power cycle.
    public func removeUplinkFlows(for guest: IPv4Address) {
        uplink?.removeFlows(for: guest)
    }

    /// Install an uplink with a deterministic initial sequence number. Internal:
    /// used by tests so relayed handshakes are reproducible.
    func installUplink(_ transport: any UplinkTransport, initialISN: UInt32) {
        uplink?.shutdown()
        uplink = UplinkNAT(stack: self, transport: transport, initialISN: initialISN)
    }

    /// Number of live NAT flows currently being relayed. Internal — observed by
    /// tests / diagnostics.
    var uplinkFlowCount: Int { uplink?.flowCount ?? 0 }

    /// Number of active TCP connections.
    var tcpConnectionCount: Int { transport.tcpConnections.count }

    @discardableResult
    func installInterface(_ configuration: NetworkInterfaceConfiguration) -> (index: Int, interface: Interface) {
        let attached = interfaceTable.attach(configuration)
        routeTable.addConnected(address: configuration.address,
                                prefixLength: configuration.prefixLength,
                                interfaceIndex: attached.index)
        return attached
    }

    func installRoute(_ configuration: NetworkRouteConfiguration) {
        routeTable.add(configuration)
    }

    func installNeighbor(_ configuration: NetworkNeighborConfiguration) {
        neighborCache.set(ip: configuration.ip, mac: configuration.mac)
    }

    func connectedRoute(for interface: NetworkInterfaceConfiguration, interfaceIndex: Int) -> NetworkRouteConfiguration {
        NetworkRouteConfiguration(destination: IPv4Address(raw: interface.address.raw & NetworkRouteTable.mask(interface.prefixLength)),
                                  prefixLength: interface.prefixLength,
                                  gateway: nil,
                                  interfaceIndex: interfaceIndex)
    }

    func normalizedRoute(_ route: NetworkRouteConfiguration) -> NetworkRouteConfiguration {
        NetworkRouteConfiguration(destination: IPv4Address(raw: route.destination.raw & NetworkRouteTable.mask(route.prefixLength)),
                                  prefixLength: route.prefixLength,
                                  gateway: route.gateway,
                                  interfaceIndex: route.interfaceIndex)
    }
}
