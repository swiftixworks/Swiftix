/// Value-only network configuration types shared across node consumers and snapshots.
public struct NetworkInterfaceConfiguration: Equatable, Hashable, Sendable {
    public var address: IPv4Address
    public var mac: MACAddress
    public var prefixLength: Int

    public init(address: IPv4Address, mac: MACAddress, prefixLength: Int = 24) {
        self.address = address
        self.mac = mac
        self.prefixLength = prefixLength
    }
}

/// Typed failures produced before a network configuration mutates live state.
public enum NetworkConfigurationError: Error, Equatable, Sendable {
    case emptyHostname
    case invalidPrefixLength(Int)
    case invalidInterfaceIndex(Int)
    case duplicateAddress(IPv4Address)
    case duplicateMAC(MACAddress)
}

public struct NetworkRouteConfiguration: Equatable, Hashable, Sendable {
    public var destination: IPv4Address
    public var prefixLength: Int
    public var gateway: IPv4Address?
    public var interfaceIndex: Int

    public init(destination: IPv4Address,
                prefixLength: Int,
                gateway: IPv4Address?,
                interfaceIndex: Int = 0) {
        self.destination = destination
        self.prefixLength = prefixLength
        self.gateway = gateway
        self.interfaceIndex = interfaceIndex
    }
}

public struct NetworkNeighborConfiguration: Equatable, Hashable, Sendable {
    public var ip: IPv4Address
    public var mac: MACAddress

    public init(ip: IPv4Address, mac: MACAddress) {
        self.ip = ip
        self.mac = mac
    }
}

public struct NetworkResolverConfiguration: Equatable, Sendable {
    public var nameServers: [IPv4Address]
    public var searchDomains: [String]

    public init(nameServers: [IPv4Address] = [], searchDomains: [String] = []) {
        self.nameServers = nameServers
        self.searchDomains = searchDomains
    }
}

/// Unified network configuration surface for a Swiftix node. It is intentionally
/// value-only so Swift APIs, procfs diagnostics, commands, scripts, and future UI
/// layers can share one shape without reaching into live stack internals.
public struct NetworkConfiguration: Equatable, Sendable {
    public var hostname: String
    public var interfaces: [NetworkInterfaceConfiguration]
    public var routes: [NetworkRouteConfiguration]
    public var neighbors: [NetworkNeighborConfiguration]
    public var resolver: NetworkResolverConfiguration
    public var ipForwardingEnabled: Bool

    public init(hostname: String = "swiftix",
                interfaces: [NetworkInterfaceConfiguration] = [],
                routes: [NetworkRouteConfiguration] = [],
                neighbors: [NetworkNeighborConfiguration] = [],
                resolver: NetworkResolverConfiguration = NetworkResolverConfiguration(),
                ipForwardingEnabled: Bool = false) {
        self.hostname = hostname
        self.interfaces = interfaces
        self.routes = routes
        self.neighbors = neighbors
        self.resolver = resolver
        self.ipForwardingEnabled = ipForwardingEnabled
    }
}

/// Small, incremental configuration operations for the single network
/// configuration entry point.
public enum NetworkConfigurationChange: Equatable, Sendable {
    case addInterface(NetworkInterfaceConfiguration)
    case addRoute(NetworkRouteConfiguration)
    case addNeighbor(NetworkNeighborConfiguration)
    case setHostname(String)
    case setResolver(NetworkResolverConfiguration)
    case setIPForwarding(Bool)
}
