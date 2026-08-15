/// A block device — a fixed-size, sector-addressable storage medium. This is
/// the educational abstraction beneath a filesystem: reads and writes happen in
/// whole sectors (default 512 bytes), and the device has a fixed capacity.
///
/// The core provides `RamDisk` (an in-memory implementation). A future
/// persistent-disk variant could back it with a file on the host FS, but for
/// simulation purposes the ramdisk is sufficient.
///
/// Concurrency: block devices are part of the non-Sendable kernel object graph,
/// accessed on the single serial executor. No internal locks.
public protocol BlockDevice: AnyObject {
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
    private var devices: [String: BlockDevice] = [:]

    /// Create a new ramdisk with the given name and sector count. Returns false
    /// if a device with that name already exists.
    @discardableResult
    func createRamDisk(name: String, sectorCount: Int, sectorSize: Int = 512) -> Bool {
        guard devices[name] == nil else { return false }
        devices[name] = RamDisk(sectorCount: sectorCount, sectorSize: sectorSize)
        return true
    }

    /// Look up a device by name.
    func device(_ name: String) -> BlockDevice? {
        devices[name]
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
}
