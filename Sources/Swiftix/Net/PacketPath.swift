/// Value-only packet path events and drop reasons exposed for diagnostics.
public typealias PacketTraceHook = (PacketBuffer, Int, PacketDirection) -> Void
public typealias PacketPathEventHook = (PacketPathEvent) -> Void

/// Coarse packet-path stages. The enum deliberately uses Linux-like layer names
/// while staying generic enough for future host/router/switch roles.
public enum PacketPathStage: String, Sendable {
    case ingress
    case layer2
    case layer3
    case route
    case forward
    case localDeliver
    case layer4
    case egress
}

/// Stable reasons a frame/datagram can leave the packet path without delivery.
public enum PacketDropReason: String, Equatable, Sendable {
    case noEgressInterface
    case noRoute
    case ttlExpired
    case malformedEthernet
    case wrongDestinationMAC
    case malformedARP
    case malformedIPv4
    /// IPv4 destination is not assigned to this host and forwarding is disabled.
    case notLocalDestination
    case malformedICMP
    case malformedUDP
    case malformedTCP
    case invalidICMPChecksum
    case invalidUDPChecksum
    case invalidTCPChecksum
    /// A valid datagram was dropped because the destination UDP socket's bounded
    /// receive queue was full. The queue keeps older datagrams and drops newest.
    case udpReceiveQueueFull
    /// An outbound datagram could not wait for neighbor discovery because the
    /// bounded ARP pending queue was full. Existing queued packets are retained.
    case arpPendingQueueFull
    /// The packet was otherwise valid, but admitting it would exceed a bounded
    /// protocol resource (for example, the NAT flow table).
    case resourceLimit
    /// No matching socket/connection for a delivered transport segment.
    case noMatchingSocket
    /// Destination port unreachable (UDP with no bound socket).
    case portUnreachable
    /// A queued outbound packet was discarded because ARP never resolved the next
    /// hop after the configured number of retries (the next hop is unreachable at
    /// L2).
    case arpResolutionFailed
}

/// Route lookup result for a packet. This is intentionally value-only so it can
/// be snapshotted by trace tools without exposing live stack internals.
public struct PacketRouteDecision: Equatable, Sendable {
    public let destination: IPv4Address
    public let nextHop: IPv4Address
    public let interfaceName: String
    public let network: IPv4Address
    public let prefixLength: Int
    public let gateway: IPv4Address?

    public init(destination: IPv4Address,
                nextHop: IPv4Address,
                interfaceName: String,
                network: IPv4Address,
                prefixLength: Int,
                gateway: IPv4Address?) {
        self.destination = destination
        self.nextHop = nextHop
        self.interfaceName = interfaceName
        self.network = network
        self.prefixLength = prefixLength
        self.gateway = gateway
    }
}

/// A structured observation emitted as a packet moves through the stack. The old
/// byte-level trace hook remains available; this event adds enough metadata for
/// future drop explanations, route tracing, and simplified tcpdump-style tools.
public struct PacketPathEvent: Sendable {
    public let stage: PacketPathStage
    public let direction: PacketDirection
    public let interfaceIndex: Int
    public let interfaceName: String
    public let packetLength: Int
    public let etherType: UInt16?
    public let ipProtocol: UInt8?
    public let routeDecision: PacketRouteDecision?
    public let dropReason: PacketDropReason?

    public init(stage: PacketPathStage,
                direction: PacketDirection,
                interfaceIndex: Int,
                interfaceName: String,
                packetLength: Int,
                etherType: UInt16? = nil,
                ipProtocol: UInt8? = nil,
                routeDecision: PacketRouteDecision? = nil,
                dropReason: PacketDropReason? = nil) {
        self.stage = stage
        self.direction = direction
        self.interfaceIndex = interfaceIndex
        self.interfaceName = interfaceName
        self.packetLength = packetLength
        self.etherType = etherType
        self.ipProtocol = ipProtocol
        self.routeDecision = routeDecision
        self.dropReason = dropReason
    }
}

public struct PacketPathSnapshotEntry: Sendable {
    public let sequence: UInt64
    public let event: PacketPathEvent

    public init(sequence: UInt64, event: PacketPathEvent) {
        self.sequence = sequence
        self.event = event
    }
}
