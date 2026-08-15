/// Failures reported by an asynchronous block-volume operation. Keeping these
/// independent from host errno values lets a pure-Swift volume implementation
/// expose the same stable contract on every platform.
public enum BlockVolumeError: Error, Equatable, Sendable {
    /// The requested sector is outside the fixed volume geometry.
    case outOfRange
    /// A write did not contain exactly one sector of data.
    case invalidTransferSize
    /// The volume has no capacity for the requested durable operation.
    case noSpace
    /// The volume does not permit writes.
    case readOnly
    /// The backing store failed to complete an otherwise valid operation.
    case inputOutput
}

/// Immutable guest-visible geometry for an attached volume.
public struct BlockVolumeInfo: Sendable, Equatable {
    public let name: String
    public let sectorSize: Int
    public let sectorCount: Int
    public let capacity: Int

    public init(name: String, sectorSize: Int, sectorCount: Int, capacity: Int) {
        self.name = name
        self.sectorSize = sectorSize
        self.sectorCount = sectorCount
        self.capacity = capacity
    }
}

/// An asynchronously completed, fixed-size, sector-addressable storage volume.
///
/// A volume may complete inline (as `RamDisk` does) or later (for example after
/// a platform adapter has persisted bytes). A completion is invoked exactly once
/// on the same serial executor that submitted the operation. This rule keeps the
/// core object graph lock-free: an adapter doing work elsewhere must hop back to
/// its Swiftix-driving executor before invoking the completion.
///
/// `flush` is the durability barrier. A successful completion guarantees that
/// every write completed before it survives the backing store's documented crash
/// model. The core deliberately does not prescribe a host file or database.
public protocol BlockVolume: AnyObject {
    var sectorSize: Int { get }
    var sectorCount: Int { get }
    var capacity: Int { get }

    func read(
        sector: Int,
        completion: @escaping (Result<[UInt8], BlockVolumeError>) -> Void
    )

    func write(
        sector: Int,
        data: [UInt8],
        completion: @escaping (Result<Void, BlockVolumeError>) -> Void
    )

    func flush(
        completion: @escaping (Result<Void, BlockVolumeError>) -> Void
    )
}

/// A synchronously accessible block volume. This compatibility surface remains
/// useful for deterministic in-core devices. Durable/platform devices should
/// implement `BlockVolume` directly so they never block the Kernel executor.
///
/// Concurrency: block devices are part of the non-Sendable kernel object graph,
/// accessed on the single serial executor. No internal locks.
public protocol BlockDevice: BlockVolume {
    /// Sector size in bytes (typically 512).
    var sectorSize: Int { get }
    /// Total number of sectors.
    var sectorCount: Int { get }
    /// Total capacity in bytes.
    var capacity: Int { get }
    /// Read one sector. Returns nil if `sector` is out of range.
    func read(sector: Int) -> [UInt8]?
    /// Write one sector. Returns false if `sector` is out of range or data size
    /// doesn't match `sectorSize`.
    @discardableResult
    func write(sector: Int, data: [UInt8]) -> Bool
}

public extension BlockDevice {
    func read(
        sector: Int,
        completion: @escaping (Result<[UInt8], BlockVolumeError>) -> Void
    ) {
        guard sector >= 0, sector < sectorCount else {
            completion(.failure(.outOfRange))
            return
        }
        guard let bytes = read(sector: sector) else {
            completion(.failure(.inputOutput))
            return
        }
        completion(.success(bytes))
    }

    func write(
        sector: Int,
        data: [UInt8],
        completion: @escaping (Result<Void, BlockVolumeError>) -> Void
    ) {
        guard sector >= 0, sector < sectorCount else {
            completion(.failure(.outOfRange))
            return
        }
        guard data.count == sectorSize else {
            completion(.failure(.invalidTransferSize))
            return
        }
        guard write(sector: sector, data: data) else {
            completion(.failure(.inputOutput))
            return
        }
        completion(.success(()))
    }

    /// A synchronous in-memory device has no volatile backing cache, so all
    /// writes are already durable within that device's lifetime.
    func flush(
        completion: @escaping (Result<Void, BlockVolumeError>) -> Void
    ) {
        completion(.success(()))
    }
}

/// An in-memory block device (ramdisk). Fixed size, zero-initialized.
public final class RamDisk: BlockDevice {
    public let sectorSize: Int
    public let sectorCount: Int
    public var capacity: Int { sectorSize * sectorCount }
    private var storage: [UInt8]

    /// Create a ramdisk with the given number of sectors (each `sectorSize` bytes).
    public init(sectorCount: Int, sectorSize: Int = 512) {
        self.sectorSize = sectorSize
        self.sectorCount = sectorCount
        self.storage = [UInt8](repeating: 0, count: sectorCount * sectorSize)
    }

    public func read(sector: Int) -> [UInt8]? {
        guard sector >= 0, sector < sectorCount else { return nil }
        let offset = sector * sectorSize
        return Array(storage[offset..<(offset + sectorSize)])
    }

    @discardableResult
    public func write(sector: Int, data: [UInt8]) -> Bool {
        guard sector >= 0, sector < sectorCount else { return false }
        guard data.count == sectorSize else { return false }
        let offset = sector * sectorSize
        storage.replaceSubrange(offset..<(offset + sectorSize), with: data)
        return true
    }
}

/// Registry of named block devices managed by the kernel. Provides create, list,
/// and lookup operations.
final class BlockDeviceTable {
    private var devices: [String: any BlockVolume] = [:]

    private static func valid(name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    private static func valid(_ volume: any BlockVolume) -> Bool {
        guard volume.sectorSize > 0, volume.sectorCount >= 0 else { return false }
        let (capacity, overflow) = volume.sectorSize.multipliedReportingOverflow(by: volume.sectorCount)
        return !overflow && capacity == volume.capacity
    }

    /// Attach a host- or product-supplied volume without coupling the core to its
    /// persistence implementation. Names are stable guest-visible identifiers.
    @discardableResult
    func attach(name: String, volume: any BlockVolume) -> Bool {
        guard Self.valid(name: name), Self.valid(volume), devices[name] == nil else { return false }
        devices[name] = volume
        return true
    }

    /// Create a new ramdisk with the given name and sector count. Returns false
    /// if a device with that name already exists.
    @discardableResult
    func createRamDisk(name: String, sectorCount: Int, sectorSize: Int = 512) -> Bool {
        guard sectorCount >= 0, sectorSize > 0,
              !sectorCount.multipliedReportingOverflow(by: sectorSize).overflow else { return false }
        return attach(name: name, volume: RamDisk(sectorCount: sectorCount, sectorSize: sectorSize))
    }

    /// Look up a device by name.
    func volume(_ name: String) -> (any BlockVolume)? {
        devices[name]
    }

    /// Compatibility lookup for the old synchronous guest helpers. An
    /// asynchronous durable volume intentionally does not satisfy this surface.
    func synchronousDevice(_ name: String) -> (any BlockDevice)? {
        devices[name] as? any BlockDevice
    }

    /// All registered device names, sorted.
    var names: [String] { devices.keys.sorted() }

    /// Summary for each device (name, sectorCount, sectorSize, capacity).
    var summaries: [(name: String, sectorCount: Int, sectorSize: Int, capacity: Int)] {
        names.compactMap { name in
            guard let dev = devices[name] else { return nil }
            return (name, dev.sectorCount, dev.sectorSize, dev.capacity)
        }
    }

    func info(_ name: String) -> BlockVolumeInfo? {
        guard let volume = devices[name] else { return nil }
        return BlockVolumeInfo(name: name,
                               sectorSize: volume.sectorSize,
                               sectorCount: volume.sectorCount,
                               capacity: volume.capacity)
    }
}
