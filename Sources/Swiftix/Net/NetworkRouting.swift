/// IPv4 longest-prefix routing table for one network node.
final class NetworkRouteTable {
    private var routes: [NetworkStack.Route] = []

    func addConnected(address: IPv4Address, prefixLength: Int, interfaceIndex: Int) {
        add(NetworkRouteConfiguration(destination: address,
                                      prefixLength: prefixLength,
                                      gateway: nil,
                                      interfaceIndex: interfaceIndex))
    }

    func add(_ configuration: NetworkRouteConfiguration) {
        routes.append(NetworkStack.Route(network: configuration.destination.raw & Self.mask(configuration.prefixLength),
                                         prefixLength: configuration.prefixLength,
                                         gateway: configuration.gateway,
                                         interfaceIndex: configuration.interfaceIndex))
    }

    func lookup(destination: IPv4Address) -> NetworkStack.Route? {
        routes
            .filter { (destination.raw & Self.mask($0.prefixLength)) == $0.network }
            .max { $0.prefixLength < $1.prefixLength }
    }

    func snapshot(interfaceName: (Int) -> String) -> [(network: IPv4Address, prefixLength: Int, gateway: IPv4Address?, interface: String)] {
        routes.map { route in
            (network: IPv4Address(raw: route.network),
             prefixLength: route.prefixLength,
             gateway: route.gateway,
             interface: interfaceName(route.interfaceIndex))
        }
    }

    func snapshotConfiguration() -> [NetworkRouteConfiguration] {
        routes.map {
            NetworkRouteConfiguration(destination: IPv4Address(raw: $0.network),
                                      prefixLength: $0.prefixLength,
                                      gateway: $0.gateway,
                                      interfaceIndex: $0.interfaceIndex)
        }
    }

    func removeAll() {
        routes.removeAll()
    }

    static func mask(_ prefixLength: Int) -> UInt32 {
        prefixLength <= 0 ? 0 : (prefixLength >= 32 ? ~UInt32(0) : ~UInt32(0) << (32 - prefixLength))
    }
}
