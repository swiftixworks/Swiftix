/// A deterministic L2 learning switch for topology/device simulations.
///
/// The switch is intentionally outside `NetworkStack`: stacks keep modeling one
/// Linux-like node, while this device connects multiple node interfaces on one
/// LAN. It learns source MAC addresses, floods broadcasts/unknown unicasts, and
/// forwards known unicasts to the learned port. Ports have explicit lifetimes:
/// removing one cancels queued delivery, removes learned entries, and releases
/// its interface egress binding without disturbing a newer owner of that seam.
public final class EthernetSwitch {
    public final class Port {
        public let index: Int
        public var onEgress: ((PacketBuffer) -> Void)?

        fileprivate let deliveryScope: EventLoop.CancellationScope
        fileprivate weak var connectedInterface: NetworkStack.Interface?
        fileprivate var egressBinding: NetworkStack.Interface.EgressBinding?

        fileprivate init(index: Int, deliveryScope: EventLoop.CancellationScope) {
            self.index = index
            self.deliveryScope = deliveryScope
        }
    }

    public struct ForwardingEntry: Equatable, Sendable {
        public let mac: MACAddress
        public let port: Int
        public let age: Double
    }

    private struct LearnedEntry {
        var portIndex: Int
        var learnedAt: Double
    }

    public let loop: EventLoop
    public let forwardingDelay: Double
    public let agingTime: Double?

    private var ports: [Int: Port] = [:]
    private var reusablePortIndices: [Int] = []
    private var nextPortIndex = 0
    private var table: [MACAddress: LearnedEntry] = [:]

    public init(loop: EventLoop, forwardingDelay: Double = 0, agingTime: Double? = 300) {
        self.loop = loop
        self.forwardingDelay = max(0, forwardingDelay)
        self.agingTime = agingTime.map { max(0, $0) }
    }

    /// Number of ports currently participating in forwarding.
    public var activePortCount: Int { ports.count }

    @discardableResult
    public func addPort() -> Port {
        let index: Int
        if let reusable = reusablePortIndices.popLast() {
            index = reusable
        } else {
            index = nextPortIndex
            // Reaching Int.max active ports is impossible before exhausting host
            // memory. Keep the API additive/non-throwing while avoiding wrapping.
            if nextPortIndex < Int.max {
                nextPortIndex += 1
            }
        }
        let port = Port(index: index,
                        deliveryScope: loop.makeCancellationScope())
        ports[index] = port
        return port
    }

    /// Remove an active port and all state owned by it.
    ///
    /// A stale or foreign `Port` is a no-op. Any delayed frame targeting this
    /// port is invalidated, learned MAC entries on it are discarded, and a
    /// connected interface is detached only if this port still owns its egress
    /// binding. This makes repeated host power cycles resource-stable.
    @discardableResult
    public func removePort(_ port: Port) -> Bool {
        guard ports[port.index] === port else { return false }

        ports[port.index] = nil
        reusablePortIndices.append(port.index)
        table = table.filter { $0.value.portIndex != port.index }
        port.deliveryScope.cancel()

        if let interface = port.connectedInterface,
           let binding = port.egressBinding {
            interface.removeEgress(binding)
        }
        port.connectedInterface = nil
        port.egressBinding = nil
        port.onEgress = nil
        return true
    }

    /// Remove every active port. Primarily used when a consumer tears down an
    /// entire topology; each port receives the same ownership-safe cleanup as
    /// ``removePort(_:)``.
    public func removeAllPorts() {
        for port in ports.values.sorted(by: { $0.index < $1.index }) {
            _ = removePort(port)
        }
    }

    /// Attach one switch port to a stack interface. Frames emitted by the stack
    /// enter the switch; frames emitted by the switch are delivered to the stack.
    @discardableResult
    public func connect(_ stack: NetworkStack, interface: NetworkStack.Interface) -> Port {
        let port = addPort()
        let binding = interface.installEgress { [weak self, weak port] frame in
            guard let self, let port else { return }
            self.receive(frame, on: port)
        }
        port.connectedInterface = interface
        port.egressBinding = binding
        port.onEgress = { [weak stack, weak interface] frame in
            guard let stack, let interface else { return }
            stack.receive(frame, on: interface)
        }
        return port
    }

    /// Whether `port` is still the exact active lease for `interface` and still
    /// owns that interface's egress seam. Consumers use this to distinguish an
    /// idempotent reconciliation from a retained port whose handler was replaced.
    public func ownsConnection(
        _ port: Port,
        interface: NetworkStack.Interface
    ) -> Bool {
        guard ports[port.index] === port,
              port.connectedInterface === interface,
              let binding = port.egressBinding else { return false }
        return interface.ownsEgress(binding)
    }

    public func receive(_ frame: PacketBuffer, on ingress: Port) {
        expireStaleEntries()
        guard ports[ingress.index] === ingress,
              let header = EthernetFrame.parseHeader(frame) else { return }

        learn(header.source, on: ingress)
        for port in egressPorts(for: header.destination, ingress: ingress) {
            forward(frame, to: port)
        }
    }

    public func snapshotForwardingTable() -> [ForwardingEntry] {
        expireStaleEntries()
        return table
            .compactMap { mac, entry in
                guard ports[entry.portIndex] != nil else { return nil }
                return ForwardingEntry(
                    mac: mac,
                    port: entry.portIndex,
                    age: loop.now - entry.learnedAt)
            }
            .sorted {
                if $0.port != $1.port { return $0.port < $1.port }
                return $0.mac.description < $1.mac.description
            }
    }

    private func learn(_ mac: MACAddress, on port: Port) {
        guard !mac.isGroupAddress else { return }
        table[mac] = LearnedEntry(portIndex: port.index, learnedAt: loop.now)
    }

    private func egressPorts(for destination: MACAddress, ingress: Port) -> [Port] {
        if destination.isGroupAddress {
            return floodPorts(except: ingress)
        }
        guard let entry = table[destination],
              let port = ports[entry.portIndex] else {
            return floodPorts(except: ingress)
        }
        guard entry.portIndex != ingress.index else { return [] }
        return [port]
    }

    private func floodPorts(except ingress: Port) -> [Port] {
        ports.values
            .filter { $0.index != ingress.index }
            .sorted { $0.index < $1.index }
    }

    private func forward(_ frame: PacketBuffer, to port: Port) {
        port.deliveryScope.schedule(after: forwardingDelay) { [weak self, weak port] in
            guard let self, let port,
                  self.ports[port.index] === port else { return }
            port.onEgress?(frame)
        }
    }

    private func expireStaleEntries() {
        guard let agingTime else { return }
        let now = loop.now
        table = table.filter { _, entry in
            ports[entry.portIndex] != nil && now - entry.learnedAt < agingTime
        }
    }
}

private extension MACAddress {
    var isGroupAddress: Bool {
        guard let first = bytes.first else { return false }
        return (first & 0x01) != 0
    }
}
