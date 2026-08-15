import Swiftix

extension NetworkNode {
    @discardableResult
    func configuredInterface(address: IPv4Address,
                             mac: MACAddress,
                             prefixLength: Int = 24) -> NetworkStack.Interface {
        let index = snapshotConfiguration().interfaces.count
        configure(.addInterface(NetworkInterfaceConfiguration(address: address,
                                                              mac: mac,
                                                              prefixLength: prefixLength)))
        guard let interface = networkInterface(at: index) as? NetworkStack.Interface else {
            fatalError("configured interface missing at index \(index)")
        }
        return interface
    }

    func configuredRoute(destination: IPv4Address,
                         prefixLength: Int,
                         gateway: IPv4Address?,
                         interfaceIndex: Int = 0) {
        configure(.addRoute(NetworkRouteConfiguration(destination: destination,
                                                      prefixLength: prefixLength,
                                                      gateway: gateway,
                                                      interfaceIndex: interfaceIndex)))
    }

    func configuredNeighbor(ip: IPv4Address, mac: MACAddress) {
        configure(.addNeighbor(NetworkNeighborConfiguration(ip: ip, mac: mac)))
    }
}
