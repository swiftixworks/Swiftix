/// Live interface boundary used by topology/device layers without exposing a
/// concrete network-stack implementation.
public protocol NetworkInterface: AnyObject {
    var address: IPv4Address { get }
    var mac: MACAddress { get }
    var prefixLength: Int { get }
    var onEgress: ((PacketBuffer) -> Void)? { get set }
}

/// Immutable-copy counters for one network interface.
public struct NetworkInterfaceCounters: Sendable {
    public var rxPackets = 0
    public var txPackets = 0
    public var rxBytes = 0
    public var txBytes = 0
    public var drops = 0
    public var forwarded = 0
    public var dropsByReason: [String: Int] = [:]

    public init() {}
}

/// Stable node boundary for topology/device layers. A node owns one event loop,
/// exposes interface/configuration entry points, accepts inbound frames, emits
/// outbound frames through each interface's `onEgress`, and provides snapshots
/// for procfs/diagnostics.
public protocol NetworkNode: AnyObject {
    var loop: EventLoop { get }
    var onPacketTrace: PacketTraceHook? { get set }
    var onPacketPathEvent: PacketPathEventHook? { get set }

    func configure(_ configuration: NetworkConfiguration)
    func configure(_ change: NetworkConfigurationChange)
    func configureValidated(_ configuration: NetworkConfiguration) throws
    func configureValidated(_ change: NetworkConfigurationChange) throws
    func networkInterface(at index: Int) -> (any NetworkInterface)?
    func receive(_ frame: PacketBuffer, on interface: any NetworkInterface)

    func snapshotConfiguration() -> NetworkConfiguration
    func snapshotPacketPathEvents() -> [PacketPathSnapshotEntry]
    func snapshotPacketDrops() -> [PacketPathSnapshotEntry]
    func snapshotRoutes() -> [(network: IPv4Address, prefixLength: Int, gateway: IPv4Address?, interface: String)]
    func snapshotInterfaceCounters() -> [(name: String, counters: NetworkInterfaceCounters)]
}

public extension NetworkNode {
    /// Source-compatible convenience name for consumers driving an abstract node.
    func interface(at index: Int) -> (any NetworkInterface)? {
        networkInterface(at: index)
    }
}
