/// Collects bounded packet-path history and invokes consumer trace hooks.
final class NetworkObservability {
    var onPacketTrace: PacketTraceHook?
    var onPacketPathEvent: PacketPathEventHook?
    private var packetPathEvents = RingBuffer<PacketPathSnapshotEntry>(capacity: 256)
    private var nextPacketPathSequence: UInt64 = 0

    func emitTrace(_ frame: PacketBuffer,
                   on interface: NetworkStack.Interface,
                   direction: PacketDirection,
                   interfaces: NetworkInterfaceTable) {
        guard let hook = onPacketTrace else { return }
        let index = interfaces.index(of: interface) ?? 0
        hook(frame, index, direction)
    }

    func emitPath(stage: PacketPathStage,
                  frameLength: Int,
                  on interface: NetworkStack.Interface,
                  direction: PacketDirection,
                  interfaces: NetworkInterfaceTable,
                  etherType: UInt16? = nil,
                  ipProtocol: UInt8? = nil,
                  routeDecision: PacketRouteDecision? = nil,
                  dropReason: PacketDropReason? = nil) {
        let index = interfaces.index(of: interface) ?? 0
        let event = PacketPathEvent(stage: stage,
                                    direction: direction,
                                    interfaceIndex: index,
                                    interfaceName: interfaces.name(for: index),
                                    packetLength: frameLength,
                                    etherType: etherType,
                                    ipProtocol: ipProtocol,
                                    routeDecision: routeDecision,
                                    dropReason: dropReason)
        packetPathEvents.append(PacketPathSnapshotEntry(sequence: nextPacketPathSequence, event: event))
        nextPacketPathSequence += 1
        onPacketPathEvent?(event)
    }

    func snapshotPacketPathEvents() -> [PacketPathSnapshotEntry] {
        packetPathEvents.elements()
    }

    func snapshotPacketDrops() -> [PacketPathSnapshotEntry] {
        packetPathEvents.elements().filter { $0.event.dropReason != nil }
    }
}
