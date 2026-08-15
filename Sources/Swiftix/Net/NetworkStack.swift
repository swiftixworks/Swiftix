/// A per-instance (per network-namespace) user-space network stack — the "OS"
/// side of networking for ONE host. MVP scope: interfaces, a routing table with
/// longest-prefix match, an ARP cache with dynamic resolution, IPv4, ICMP echo
/// (ping), UDP, and TCP.
///
/// The stack does NOT know about links, switches, or topology — connecting hosts
/// is the consuming layer's job. Each `Interface` is the boundary: `onEgress` is
/// called with every outbound frame, and the consumer calls `receive(_:on:)` to
/// inject inbound frames.

/// Direction of a frame passed to a `Packet_Trace_Hook`: `outbound` for frames the
/// stack transmits, `inbound` for frames handed to `receive(_:on:)` (R14.2, R14.3).
public enum PacketDirection: String, Sendable { case inbound, outbound }

public final class NetworkStack: NetworkNode {

    /// Per-interface running totals of received/transmitted packets and bytes plus
    /// dropped inbound frames (R13.1). A value type so a `snapshotInterfaceCounters()`
    /// caller gets an immutable copy of the live counters.
    public typealias InterfaceCounters = NetworkInterfaceCounters

    /// An attached network interface: this host's L2/L3 identity on one wire,
    /// plus the egress hook the consumer wires to its link/switch/topology.
    public final class Interface: NetworkInterface {
        /// Opaque ownership token returned by ``installEgress(_:)``. A topology
        /// object must present the same token when detaching, so stale teardown
        /// cannot erase a newer link or switch that has since claimed the seam.
        public struct EgressBinding: Equatable, Sendable {
            fileprivate let interfaceID: ObjectIdentifier
            fileprivate let generation: UInt64
        }

        public let address: IPv4Address
        public let mac: MACAddress
        public let prefixLength: Int

        private var egressGeneration: UInt64 = 0
        private var egressHandler: ((PacketBuffer) -> Void)?

        /// Set by simple consumers to put outbound frames on a wire. Assigning
        /// this property invalidates any ownership token previously returned by
        /// ``installEgress(_:)``.
        public var onEgress: ((PacketBuffer) -> Void)? {
            get { egressHandler }
            set {
                egressGeneration &+= 1
                egressHandler = newValue
            }
        }

        /// Atomically installs an egress handler and returns its ownership token.
        /// Topology implementations should retain the token and detach with
        /// ``removeEgress(_:)`` instead of unconditionally assigning `nil`.
        @discardableResult
        public func installEgress(
            _ handler: @escaping (PacketBuffer) -> Void
        ) -> EgressBinding {
            egressGeneration &+= 1
            egressHandler = handler
            return EgressBinding(interfaceID: ObjectIdentifier(self),
                                 generation: egressGeneration)
        }

        /// Removes the egress handler only when `binding` still owns this seam.
        /// A stale or foreign-interface token is a no-op, preserving any newer
        /// topology connection.
        public func removeEgress(_ binding: EgressBinding) {
            guard binding.interfaceID == ObjectIdentifier(self),
                  binding.generation == egressGeneration else { return }
            egressGeneration &+= 1
            egressHandler = nil
        }

        /// Whether `binding` is still the current owner of this egress seam.
        public func ownsEgress(_ binding: EgressBinding) -> Bool {
            binding.interfaceID == ObjectIdentifier(self)
                && binding.generation == egressGeneration
                && egressHandler != nil
        }

        /// Live per-interface traffic counters (R13.1); updated by `transmit`/`receive`.
        public var counters = InterfaceCounters()

        init(address: IPv4Address, mac: MACAddress, prefixLength: Int) {
            self.address = address
            self.mac = mac
            self.prefixLength = prefixLength
        }
    }

    /// A routing-table entry: a destination network + prefix, an optional gateway
    /// (next hop; nil = directly connected), and the egress interface.
    struct Route {
        let network: UInt32
        let prefixLength: Int
        let gateway: IPv4Address?
        let interfaceIndex: Int
    }

    /// 4-tuple key for a TCP connection (local IP is implied by the interface).
    struct TCPKey: Hashable {
        let localPort: UInt16
        let remoteIP: UInt32
        let remotePort: UInt16
    }

    /// The shared scheduler/clock — also drives TCP retransmission + TIME_WAIT timers.
    public let loop: EventLoop

    /// Kernel-owned stacks bind every protocol timer to the kernel's work scope.
    /// Standalone stacks (used by focused network tests/consumers) leave this nil
    /// and retain the ordinary unowned EventLoop behavior.
    private let workOwner: EventLoop.WorkOwner?

    /// Internal rather than `private` because the egress and ingress paths gate on
    /// it and now live in `NetworkStack+Egress.swift` / `NetworkStack+Ingress.swift`.
    /// `private` is file-scoped in Swift, so a type split across files cannot keep
    /// its shared state private — widening the property alone is not enough, its
    /// type has to widen with it.
    enum LifecycleState {
        case active
        case paused
        case shutdown
    }

    var lifecycleState: LifecycleState = .active

    /// Optional per-frame trace callback a consumer may install (R14.1). Invoked
    /// with the frame (by value — `PacketBuffer` is a value type, so the hook cannot
    /// mutate transmitted/delivered bytes, R14.5), the egress/ingress interface index,
    /// and the direction. No-op when unset (R14.4); its result is ignored so the call
    /// is best-effort and cannot alter or block frame processing (R14.6).
    public var onPacketTrace: PacketTraceHook? {
        get { observability.onPacketTrace }
        set { observability.onPacketTrace = newValue }
    }

    /// Structured packet-path events for route/drop/local-delivery diagnostics.
    public var onPacketPathEvent: PacketPathEventHook? {
        get { observability.onPacketPathEvent }
        set { observability.onPacketPathEvent = newValue }
    }

    let interfaceTable = NetworkInterfaceTable()
    let routeTable = NetworkRouteTable()
    let neighborCache = NetworkNeighborCache()
    let observability = NetworkObservability()
    let ipv4 = NetworkIPv4Layer()
    let transport = NetworkTransportDemux()
    private var hostname = "swiftix"
    private var resolver = NetworkResolverConfiguration()
    public private(set) var ipForwardingEnabled = false

    /// The optional user-mode NAT engine (SLIRP-style real-network uplink). When
    /// installed via ``installUplink(_:)``, non-local IPv4 traffic is terminated
    /// and relayed to the real network through it instead of being L3-forwarded.
    /// Non-Sendable; only touched on the stack's executor (see Uplink.swift).
    var uplink: UplinkNAT?

    /// ARP resolution retry policy (Linux-like): re-broadcast an unanswered
    /// request `arpRetryInterval` seconds apart, up to `arpMaxAttempts` total
    /// broadcasts, before discarding the packets queued behind the unresolved next
    /// hop. Defaults mirror Linux's `mcast_solicit=3` / `retrans_time_ms=1000`.
    let arpMaxAttempts = 3
    let arpRetryInterval = 1.0

    var interfaces: [Interface] { interfaceTable.all }

    init(loop: EventLoop, workOwner: EventLoop.WorkOwner? = nil) {
        self.loop = loop
        self.workOwner = workOwner
    }

    /// Freeze ingress/egress while the owning kernel is suspended. Protocol
    /// timers are frozen separately by the EventLoop owner scope.
    func pause() {
        guard lifecycleState == .active else { return }
        lifecycleState = .paused
        uplink?.pause()
    }

    func resume() {
        guard lifecycleState == .paused else { return }
        uplink?.resume()
        lifecycleState = .active
    }

    /// Permanently detach the data plane and release transport callbacks. The
    /// owning Kernel closes process descriptors first; this final sweep prevents
    /// consumer-held interfaces from keeping a dead network seam operational.
    func shutdown() {
        guard lifecycleState != .shutdown else { return }
        lifecycleState = .shutdown
        uplink?.shutdown()
        uplink = nil
        for interface in interfaces { interface.onEgress = nil }
        interfaceTable.removeAll()
        routeTable.removeAll()
        neighborCache.removeAll()
        transport.udpSockets.removeAll()
        transport.echoWaiters.removeAll()
        transport.tcpListeners.removeAll()
        transport.tcpConnections.removeAll()
        onPacketTrace = nil
        onPacketPathEvent = nil
    }

    /// Schedule protocol work in the owning Kernel's cancellation/pause scope.
    /// Standalone stacks have no owner and use the ordinary EventLoop API.
    func schedule(after delay: Double, _ work: @escaping () -> Void) {
        if let workOwner {
            loop.schedule(after: delay, owner: workOwner, work)
        } else {
            loop.schedule(after: delay, work)
        }
    }

    /// Schedule one protocol timer that can be physically removed when
    /// superseded while preserving the owning kernel's pause/cancel scope.
    func scheduleCancellable(
        after delay: Double,
        _ work: @escaping () -> Void
    ) -> EventLoop.EventToken {
        if let workOwner {
            return loop.scheduleCancellable(after: delay, owner: workOwner, work)
        }
        return loop.scheduleCancellable(after: delay, work)
    }

    // MARK: - Configuration

    /// Replace the node's configured network identity, routes, neighbors, resolver,
    /// and forwarding flag. Callers that hold `Interface` references should re-read
    /// them with `interface(at:)` after replacement.
    public func configure(_ configuration: NetworkConfiguration) {
        try? configureValidated(configuration)
    }

    /// Validate and atomically replace network configuration. Invalid input leaves
    /// all live tables unchanged and reports the precise configuration error.
    public func configureValidated(_ configuration: NetworkConfiguration) throws {
        try validate(configuration)
        interfaceTable.removeAll()
        routeTable.removeAll()
        neighborCache.removeAll()
        hostname = configuration.hostname
        resolver = configuration.resolver
        ipForwardingEnabled = configuration.ipForwardingEnabled

        var autoConnectedRoutes: Set<NetworkRouteConfiguration> = []
        for interface in configuration.interfaces {
            let attached = installInterface(interface)
            autoConnectedRoutes.insert(connectedRoute(for: interface, interfaceIndex: attached.index))
        }

        for route in configuration.routes where !autoConnectedRoutes.contains(normalizedRoute(route)) {
            installRoute(route)
        }

        for neighbor in configuration.neighbors {
            installNeighbor(neighbor)
        }
    }

    public func configure(_ change: NetworkConfigurationChange) {
        try? configureValidated(change)
    }

    /// Validate and apply one incremental network configuration change.
    public func configureValidated(_ change: NetworkConfigurationChange) throws {
        try validate(change)
        switch change {
        case .addInterface(let interface):
            _ = installInterface(interface)
        case .addRoute(let route):
            installRoute(route)
        case .addNeighbor(let neighbor):
            installNeighbor(neighbor)
        case .setHostname(let value):
            hostname = value
        case .setResolver(let value):
            resolver = value
        case .setIPForwarding(let enabled):
            ipForwardingEnabled = enabled
        }
    }

    private func validate(_ configuration: NetworkConfiguration) throws {
        guard !configuration.hostname.isEmpty else { throw NetworkConfigurationError.emptyHostname }
        var addresses: Set<IPv4Address> = []
        var macs: Set<MACAddress> = []
        for interface in configuration.interfaces {
            try validatePrefix(interface.prefixLength)
            guard addresses.insert(interface.address).inserted else {
                throw NetworkConfigurationError.duplicateAddress(interface.address)
            }
            guard macs.insert(interface.mac).inserted else {
                throw NetworkConfigurationError.duplicateMAC(interface.mac)
            }
        }
        for route in configuration.routes {
            try validatePrefix(route.prefixLength)
            guard configuration.interfaces.indices.contains(route.interfaceIndex) else {
                throw NetworkConfigurationError.invalidInterfaceIndex(route.interfaceIndex)
            }
        }
    }

    private func validate(_ change: NetworkConfigurationChange) throws {
        switch change {
        case .addInterface(let interface):
            try validatePrefix(interface.prefixLength)
            if interfaces.contains(where: { $0.address == interface.address }) {
                throw NetworkConfigurationError.duplicateAddress(interface.address)
            }
            if interfaces.contains(where: { $0.mac == interface.mac }) {
                throw NetworkConfigurationError.duplicateMAC(interface.mac)
            }
        case .addRoute(let route):
            try validatePrefix(route.prefixLength)
            guard (0..<interfaceTable.count).contains(route.interfaceIndex) else {
                throw NetworkConfigurationError.invalidInterfaceIndex(route.interfaceIndex)
            }
        case .setHostname(let value):
            guard !value.isEmpty else { throw NetworkConfigurationError.emptyHostname }
        case .addNeighbor, .setResolver, .setIPForwarding:
            break
        }
    }

    private func validatePrefix(_ prefixLength: Int) throws {
        guard (0...32).contains(prefixLength) else {
            throw NetworkConfigurationError.invalidPrefixLength(prefixLength)
        }
    }

    public func snapshotConfiguration() -> NetworkConfiguration {
        NetworkConfiguration(hostname: hostname,
                             interfaces: interfaceTable.snapshotConfiguration(),
                             routes: routeTable.snapshotConfiguration(),
                             neighbors: neighborCache.snapshotConfiguration(),
                             resolver: resolver,
                             ipForwardingEnabled: ipForwardingEnabled)
    }

    public func interface(at index: Int) -> Interface? {
        interfaceTable.interface(at: index)
    }

    public func networkInterface(at index: Int) -> (any NetworkInterface)? {
        interfaceTable.interface(at: index)
    }

    func interfaceIndex(named name: String) -> Int? {
        interfaceTable.index(named: name)
    }

    /// Number of attached network interfaces.
    public var interfaceCount: Int { interfaceTable.count }

    // MARK: - Introspection (procfs)

    func snapshotInterfaces() -> [(name: String, address: IPv4Address, mac: MACAddress)] {
        interfaceTable.snapshotInterfaces()
    }

    /// Current ARP neighbor cache: resolved IP→MAC bindings visible to this
    /// host's network stack. Consumed by the app's network-status panel (R10).
    public func snapshotARP() -> [(ip: IPv4Address, mac: MACAddress)] {
        neighborCache.snapshot()
    }

    /// Current routing table, one entry per route: the destination network, its
    /// prefix length, the optional gateway (next hop; `nil` = directly connected),
    /// and the egress interface name (R15.1). Computed from live state so a reader
    /// (e.g. `/proc/net/route`) always sees the current table.
    public func snapshotRoutes() -> [(network: IPv4Address, prefixLength: Int, gateway: IPv4Address?, interface: String)] {
        routeTable.snapshot { interfaceTable.name(for: $0) }
    }

    /// Current per-interface traffic counters, one entry per attached interface (R13.5).
    public func snapshotInterfaceCounters() -> [(name: String, counters: InterfaceCounters)] {
        interfaceTable.snapshotCounters()
    }

    func snapshotUDPPorts() -> [UInt16] {
        transport.udpSockets.keys.sorted()
    }

    func snapshotTCP() -> [TCPSnapshot] {
        transport.tcpConnections.values.map(\.snapshot).sorted {
            if $0.localPort != $1.localPort { return $0.localPort < $1.localPort }
            if $0.remoteIP.raw != $1.remoteIP.raw { return $0.remoteIP.raw < $1.remoteIP.raw }
            return $0.remotePort < $1.remotePort
        }
    }

    public func snapshotPacketPathEvents() -> [PacketPathSnapshotEntry] {
        observability.snapshotPacketPathEvents()
    }

    public func snapshotPacketDrops() -> [PacketPathSnapshotEntry] {
        observability.snapshotPacketDrops()
    }

    /// All live TCP connections. Internal so tests can observe per-connection
    /// sender state (e.g. Send_Buffer drainage) without touching the public API.
    var tcpConnectionList: [TCPConnection] { Array(transport.tcpConnections.values) }

}
