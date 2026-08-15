/// The ARP neighbor cache: resolved IP→MAC bindings, the packets queued while a
/// next hop is still being resolved, and per-target resolution bookkeeping so the
/// stack can retry a lost ARP request a few times (like Linux's `mcast_solicit`)
/// and dedupe concurrent resolutions of the same target rather than broadcasting
/// one request per queued packet.
final class NetworkNeighborCache {
    static let maximumPendingPackets = 256
    static let maximumPendingPacketsPerNeighbor = 64
    static let maximumPendingBytes = 1 * 1_024 * 1_024

    struct PendingStatistics: Equatable {
        let packets: Int
        let bytes: Int
        let highWaterPackets: Int
        let highWaterBytes: Int
        let droppedPackets: Int
    }

    private var entries: [UInt32: MACAddress] = [:]
    private var pendingPackets: [UInt32: [[UInt8]]] = [:]
    private var pendingPacketCount = 0
    private var pendingByteCount = 0
    private var pendingPacketHighWater = 0
    private var pendingByteHighWater = 0
    private var droppedPendingPackets = 0
    /// Per-target resolution epoch. A target has an in-flight resolution while a
    /// non-nil epoch is present; a retry timer only acts when it still matches the
    /// current epoch, so a completed/superseded/cleared resolution silently
    /// cancels its outstanding timers. Monotonic `nextEpoch` guarantees a fresh
    /// resolution never collides with a stale timer.
    private var resolutionEpochs: [UInt32: Int] = [:]
    private var nextEpoch = 0

    /// Record a resolved binding. Learning a MAC ends any in-flight resolution for
    /// that IP, so the retry timers armed for it become no-ops.
    func set(ip: IPv4Address, mac: MACAddress) {
        entries[ip.raw] = mac
        resolutionEpochs[ip.raw] = nil
    }

    func mac(for ip: IPv4Address) -> MACAddress? {
        entries[ip.raw]
    }

    @discardableResult
    func enqueue(_ packet: [UInt8], waitingFor ip: IPv4Address) -> Bool {
        let targetCount = pendingPackets[ip.raw]?.count ?? 0
        guard pendingPacketCount < Self.maximumPendingPackets,
              targetCount < Self.maximumPendingPacketsPerNeighbor,
              packet.count <= Self.maximumPendingBytes - pendingByteCount else {
            droppedPendingPackets += 1
            return false
        }
        pendingPackets[ip.raw, default: []].append(packet)
        pendingPacketCount += 1
        pendingByteCount += packet.count
        pendingPacketHighWater = max(pendingPacketHighWater, pendingPacketCount)
        pendingByteHighWater = max(pendingByteHighWater, pendingByteCount)
        return true
    }

    func drainPending(waitingFor ip: IPv4Address) -> [[UInt8]] {
        guard let queued = pendingPackets[ip.raw] else { return [] }
        pendingPackets[ip.raw] = nil
        pendingPacketCount -= queued.count
        pendingByteCount -= queued.reduce(0) { $0 + $1.count }
        return queued
    }

    var pendingStatistics: PendingStatistics {
        PendingStatistics(packets: pendingPacketCount,
                          bytes: pendingByteCount,
                          highWaterPackets: pendingPacketHighWater,
                          highWaterBytes: pendingByteHighWater,
                          droppedPackets: droppedPendingPackets)
    }

    /// Begin resolving `ip`, returning a fresh epoch when this is the first request
    /// (the caller then broadcasts the ARP request and arms the retry timer), or
    /// `nil` when a resolution is already in flight (the caller only enqueues its
    /// packet — one broadcast serves every waiter, matching real ARP).
    func beginResolution(for ip: IPv4Address) -> Int? {
        if resolutionEpochs[ip.raw] != nil { return nil }
        nextEpoch += 1
        resolutionEpochs[ip.raw] = nextEpoch
        return nextEpoch
    }

    /// The current resolution epoch for `ip`, or `nil` if none is in flight. A
    /// retry timer compares its captured epoch against this to detect that its
    /// resolution has completed, been abandoned, or been superseded.
    func resolutionEpoch(for ip: IPv4Address) -> Int? {
        resolutionEpochs[ip.raw]
    }

    /// End resolution bookkeeping for `ip` (resolved or given up). Idempotent.
    func endResolution(for ip: IPv4Address) {
        resolutionEpochs[ip.raw] = nil
    }

    func snapshot() -> [(ip: IPv4Address, mac: MACAddress)] {
        entries
            .sorted { $0.key < $1.key }
            .map { (ip: IPv4Address(raw: $0.key), mac: $0.value) }
    }

    func snapshotConfiguration() -> [NetworkNeighborConfiguration] {
        snapshot().map { NetworkNeighborConfiguration(ip: $0.ip, mac: $0.mac) }
    }

    func removeAll() {
        entries.removeAll()
        pendingPackets.removeAll()
        pendingPacketCount = 0
        pendingByteCount = 0
        resolutionEpochs.removeAll()
    }
}
