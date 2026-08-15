/// Owns the concrete interfaces attached to one single-executor network stack.
final class NetworkInterfaceTable {
    private var storage: [NetworkStack.Interface] = []

    var all: [NetworkStack.Interface] { storage }
    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }

    @discardableResult
    func attach(_ configuration: NetworkInterfaceConfiguration) -> (index: Int, interface: NetworkStack.Interface) {
        let interface = NetworkStack.Interface(address: configuration.address,
                                               mac: configuration.mac,
                                               prefixLength: configuration.prefixLength)
        storage.append(interface)
        return (storage.count - 1, interface)
    }

    func interface(at index: Int) -> NetworkStack.Interface? {
        guard storage.indices.contains(index) else { return nil }
        return storage[index]
    }

    func index(of interface: NetworkStack.Interface) -> Int? {
        storage.firstIndex { $0 === interface }
    }

    func contains(address: IPv4Address) -> Bool {
        storage.contains { $0.address == address }
    }

    func name(for index: Int) -> String {
        guard storage.indices.contains(index) else { return "eth\(index)" }
        if isLoopback(storage[index]) { return "lo" }
        let ethernetIndex = storage[..<index].filter { !isLoopback($0) }.count
        return "eth\(ethernetIndex)"
    }

    func index(named name: String) -> Int? {
        storage.indices.first { self.name(for: $0) == name }
    }

    private func isLoopback(_ interface: NetworkStack.Interface) -> Bool {
        interface.address.raw & 0xFF00_0000 == 0x7F00_0000
            && interface.mac.bytes.allSatisfy { $0 == 0 }
    }

    func snapshotInterfaces() -> [(name: String, address: IPv4Address, mac: MACAddress)] {
        storage.enumerated().map { index, interface in
            (name: name(for: index), address: interface.address, mac: interface.mac)
        }
    }

    func snapshotCounters() -> [(name: String, counters: NetworkStack.InterfaceCounters)] {
        storage.enumerated().map { index, interface in
            (name: name(for: index), counters: interface.counters)
        }
    }

    func snapshotConfiguration() -> [NetworkInterfaceConfiguration] {
        storage.map {
            NetworkInterfaceConfiguration(address: $0.address,
                                          mac: $0.mac,
                                          prefixLength: $0.prefixLength)
        }
    }

    func removeAll() {
        storage.removeAll()
    }
}
