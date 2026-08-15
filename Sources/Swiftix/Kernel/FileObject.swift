/// Everything-is-a-file: the kernel manipulates open files, pipes, ttys, and
/// sockets through one object interface. The object methods are immediate;
/// blocking syscall frontends park through readiness/wait queues around them.
public struct IOReadiness: OptionSet, Sendable, Equatable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let readable = IOReadiness(rawValue: 1 << 0)
    public static let writable = IOReadiness(rawValue: 1 << 1)
    public static let hangup = IOReadiness(rawValue: 1 << 2)
    public static let error = IOReadiness(rawValue: 1 << 3)

    public var description: String {
        var names: [String] = []
        if contains(.readable) { names.append("readable") }
        if contains(.writable) { names.append("writable") }
        if contains(.hangup) { names.append("hangup") }
        if contains(.error) { names.append("error") }
        return names.isEmpty ? "none" : names.joined(separator: "|")
    }
}

public struct PollRequest: Equatable, Sendable {
    public let fd: Int
    public let interests: IOReadiness

    public init(fd: Int, interests: IOReadiness) {
        self.fd = fd
        self.interests = interests
    }
}

public struct PollResult: Equatable, Sendable {
    public let fd: Int
    public let readiness: IOReadiness

    public init(fd: Int, readiness: IOReadiness) {
        self.fd = fd
        self.readiness = readiness
    }
}

public struct FileStatusFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// POSIX-style O_NONBLOCK: typed throwing/async syscalls return
    /// `.wouldBlock` instead of parking when no data/connection is ready.
    public static let nonBlocking = FileStatusFlags(rawValue: 1 << 0)
}

final class ReadinessSubscription {
    private var cancelAction: (() -> Void)?

    init(_ cancelAction: @escaping () -> Void = {}) {
        self.cancelAction = cancelAction
    }

    func cancel() {
        guard let action = cancelAction else { return }
        cancelAction = nil
        action()
    }

    deinit {
        cancel()
    }
}

protocol ReadinessEventSource: AnyObject {
    func addReadinessListener(_ listener: @escaping () -> Void) -> ReadinessSubscription
}

final class ReadinessBroadcaster {
    private var nextID = 0
    private var listeners: [Int: () -> Void] = [:]

    func add(_ listener: @escaping () -> Void) -> ReadinessSubscription {
        let id = nextID
        nextID += 1
        listeners[id] = listener
        return ReadinessSubscription { [weak self] in
            self?.listeners[id] = nil
        }
    }

    func notify() {
        for listener in Array(listeners.values) {
            listener()
        }
    }
}

/// FIFO wait queue for one-shot blocking operations. Readiness listeners are
/// broadcast snapshots for `poll`; operation waiters are different: one unit of
/// newly available data normally wakes one reader, while EOF/teardown wakes all.
/// Keeping this tiny distinction prevents multiple blocked reads from overwriting
/// one callback or all consuming the same readiness edge.
final class WaitQueue {
    private var nextID = 0
    private var waiters: [(id: Int, action: () -> Void)] = []

    func add(_ waiter: @escaping () -> Void) -> ReadinessSubscription {
        let id = nextID
        nextID += 1
        waiters.append((id: id, action: waiter))
        return ReadinessSubscription { [weak self] in
            self?.waiters.removeAll { $0.id == id }
        }
    }

    func notifyOne() {
        guard !waiters.isEmpty else { return }
        let waiter = waiters.removeFirst().action
        waiter()
    }

    func notifyAll() {
        let actions = waiters.map(\.action)
        waiters.removeAll(keepingCapacity: true)
        for action in actions { action() }
    }
}

public protocol FileObject: AnyObject {
    func read(max: Int) -> [UInt8]
    @discardableResult func write(_ bytes: [UInt8]) -> Int

    /// Current non-blocking readiness for `poll`/`select`-style frontends.
    var readiness: IOReadiness { get }

    /// A new open-file description owns this object. `dup` and inheritance share
    /// that description and do not call this again. Types with endpoint state
    /// (pipes and sockets) use this to count independently opened descriptions.
    func opened()

    /// The last descriptor referring to this open-file description was removed.
    /// Paired with `opened()`; the underlying resource may now release endpoint
    /// state, locks, or deferred file data.
    func closed()
}

extension FileObject {
    public var readiness: IOReadiness { [] }
    public func opened() {}
    public func closed() {}
}

/// A byte stream a process can *block* on: a blocking `read` parks the process
/// until `hasBytesAvailable` becomes true, then resumes. Pipes and ttys conform;
/// sockets use their own datagram/connection receive instead.
protocol ReadableStream: FileObject {
    var hasBytesAvailable: Bool { get }
    func addReadWaiter(_ waiter: @escaping () -> Void) -> ReadinessSubscription
}

/// A stream write endpoint that can lose every reader. The syscall layer uses
/// this narrow capability to translate the condition into EPIPE + SIGPIPE
/// without teaching unrelated `FileObject` implementations about signals.
protocol BrokenPipeDetecting: AnyObject {
    var hasBrokenPipe: Bool { get }
}

/// A descriptor with a random-access read offset (POSIX `lseek`). Regular files
/// conform; streams (pipes, ttys, sockets) do not.
protocol Seekable: AnyObject {
    var seekOffset: Int { get set }
    var byteSize: Int { get }
}

/// Shared FIFO byte buffer behind a pipe's two ends. It reference-counts the open
/// write and read handles across *all* processes (fds are inherited on `spawn`),
/// so the write side is considered closed — and a blocked reader observes EOF —
/// only when the last write handle goes away. Parked readers are woken in FIFO
/// order when data arrives, and all are woken when the write side reaches EOF.
final class PipeBuffer {
    static let capacity = 64 * 1_024
    private var bytes = BoundedFIFOQueue<UInt8>(capacity: capacity)
    private var writeHandles = 0
    private var readHandles = 0
    private let readinessBroadcaster = ReadinessBroadcaster()
    private let readWaiters = WaitQueue()

    /// True once every write handle has been closed (EOF for the reader).
    var writeClosed: Bool { writeHandles <= 0 }
    var hasReaders: Bool { readHandles > 0 && !readClosed }
    var hasWriteCapacity: Bool { bytes.count < bytes.capacity }
    private(set) var readClosed = false

    func openWriteHandle() { writeHandles += 1 }
    func openReadHandle() {
        readHandles += 1
        readClosed = false
    }

    func closeWriteHandle() {
        writeHandles -= 1
        if writeHandles <= 0 {
            readWaiters.notifyAll()   // last writer gone => every reader sees EOF
            readinessBroadcaster.notify()
        }
    }

    func closeReadHandle() {
        readHandles -= 1
        if readHandles <= 0 {
            readClosed = true
            readinessBroadcaster.notify()
        }
    }

    @discardableResult
    func enqueue(_ data: [UInt8]) -> Int {
        guard !readClosed, !data.isEmpty else { return 0 }
        let accepted = bytes.append(contentsOf: data)
        if accepted > 0 {
            readWaiters.notifyOne()
            readinessBroadcaster.notify()
        }
        return accepted
    }

    func dequeue(max maxBytes: Int) -> [UInt8] {
        let wasFull = !hasWriteCapacity
        let result = bytes.popFirst(maxBytes)
        if !bytes.isEmpty { readWaiters.notifyOne() }
        if wasFull, !result.isEmpty { readinessBroadcaster.notify() }
        return result
    }

    var count: Int { bytes.count }

    func addReadinessListener(_ listener: @escaping () -> Void) -> ReadinessSubscription {
        readinessBroadcaster.add(listener)
    }

    func addReadWaiter(_ waiter: @escaping () -> Void) -> ReadinessSubscription {
        readWaiters.add(waiter)
    }
}

/// One end of a unidirectional pipe. The write end appends; the read end drains
/// and can be blocked on (`ReadableStream`). Handle open/close are counted on the
/// shared buffer so EOF fires only after the last writer closes — across process
/// boundaries, since `spawn` inherits descriptors.
final class PipeEndpoint: FileObject, ReadableStream, ReadinessEventSource, BrokenPipeDetecting {
    private let buffer: PipeBuffer
    let isWriteEnd: Bool

    init(buffer: PipeBuffer, isWriteEnd: Bool) {
        self.buffer = buffer
        self.isWriteEnd = isWriteEnd
    }

    /// The read end has bytes to hand out, or has reached EOF (all writers closed)
    /// — in both cases a blocked reader should resume (EOF resolves to an empty
    /// successful read). The write end is never readable.
    var hasBytesAvailable: Bool {
        !isWriteEnd && (buffer.count > 0 || buffer.writeClosed)
    }

    var hasBrokenPipe: Bool { isWriteEnd && !buffer.hasReaders }

    var readiness: IOReadiness {
        if isWriteEnd {
            var mask: IOReadiness = buffer.hasReaders && buffer.hasWriteCapacity ? [.writable] : []
            if buffer.readClosed { mask.insert(.hangup) }
            return mask
        }
        var mask: IOReadiness = []
        if buffer.count > 0 || buffer.writeClosed { mask.insert(.readable) }
        if buffer.writeClosed { mask.insert(.hangup) }
        return mask
    }

    func addReadWaiter(_ waiter: @escaping () -> Void) -> ReadinessSubscription {
        buffer.addReadWaiter(waiter)
    }

    func read(max maxBytes: Int) -> [UInt8] {
        isWriteEnd ? [] : buffer.dequeue(max: maxBytes)
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Int {
        isWriteEnd ? buffer.enqueue(bytes) : 0
    }

    func opened() {
        isWriteEnd ? buffer.openWriteHandle() : buffer.openReadHandle()
    }

    func closed() {
        isWriteEnd ? buffer.closeWriteHandle() : buffer.closeReadHandle()
    }

    func addReadinessListener(_ listener: @escaping () -> Void) -> ReadinessSubscription {
        buffer.addReadinessListener(listener)
    }
}

/// The bit-bucket device (`/dev/null`): reads always report end-of-file (an
/// empty read) and writes are accepted and discarded. Always ready for both.
final class NullDeviceHandle: FileObject {
    func read(max: Int) -> [UInt8] { [] }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Int { bytes.count }

    var readiness: IOReadiness { [.readable, .writable] }
}

/// An open handle to a regular file in the VFS, carrying its own shared
/// read/write offset. Ordinary writes are positional; append-mode writes select
/// EOF immediately before each write. Tracks open-handle count on the underlying
/// VNode for deferred-deletion semantics.
final class RegularFileHandle: FileObject, Seekable {
    private let vnode: VNode
    private let snapshot: [UInt8]?   // synthetic (procfs) contents captured at open; read-only
    private let appendWrites: Bool
    private var offset = 0
    /// Logical clock provider for timestamp updates (from VFS).
    private let clock: () -> Double

    init(vnode: VNode, appendWrites: Bool = false, clock: @escaping () -> Double = { 0 }) {
        self.vnode = vnode
        self.snapshot = vnode.provider?()
        self.appendWrites = appendWrites
        self.clock = clock
        if appendWrites { self.offset = vnode.fileContents.count }
    }

    /// `Seekable`: the read offset and current byte size (for SEEK_END / lseek).
    var seekOffset: Int {
        get { offset }
        set { offset = Swift.max(0, newValue) }
    }
    var byteSize: Int { (snapshot ?? vnode.fileContents).count }
    var readiness: IOReadiness {
        snapshot == nil ? [.readable, .writable] : [.readable]
    }

    func read(max maxBytes: Int) -> [UInt8] {
        let data = snapshot ?? vnode.fileContents
        guard maxBytes > 0, offset < data.count else { return [] }
        let (requestedEnd, overflow) = offset.addingReportingOverflow(maxBytes)
        let end = overflow ? data.count : min(requestedEnd, data.count)
        let out = Array(data[offset..<end])
        offset = end
        vnode.touchAccess(clock())
        return out
    }

    /// Read without observing or changing the shared open-file-description
    /// offset. Database pagers use this in place of a seek/read pair.
    func read(at position: Int, max maxBytes: Int) -> [UInt8] {
        let data = snapshot ?? vnode.fileContents
        guard position >= 0, maxBytes > 0, position < data.count else { return [] }
        let (requestedEnd, overflow) = position.addingReportingOverflow(maxBytes)
        let end = overflow ? data.count : min(requestedEnd, data.count)
        let out = Array(data[position..<end])
        vnode.touchAccess(clock())
        return out
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Int {
        guard snapshot == nil else { return 0 }   // synthetic files are read-only
        if appendWrites { offset = vnode.fileContents.count }
        let written = vnode.writeFileContents(bytes, at: offset)
        offset = offset.addingReportingOverflow(written).partialValue
        vnode.touchModify(clock())
        return written
    }

    /// Write without observing or changing the shared open-file-description
    /// offset. Append mode affects ordinary writes only; positional writes always
    /// target the caller-supplied location, matching `pwrite`.
    @discardableResult
    func write(_ bytes: [UInt8], at position: Int) -> Int {
        guard snapshot == nil, position >= 0 else { return 0 }
        let written = vnode.writeFileContents(bytes, at: position)
        if written > 0 { vnode.touchModify(clock()) }
        return written
    }

    func opened() {
        vnode.openHandles += 1
    }

    func closed() {
        vnode.openHandles -= 1
        // Deferred deletion: if unlinked and this was the last handle, release data.
        if vnode.unlinked, vnode.openHandles <= 0 {
            vnode.truncate()
        }
        // Release any advisory lock this handle held.
        vnode.releaseLock(holder: ObjectIdentifier(self).hashValue)
    }

    /// The underlying VNode (for lock operations that need the inode).
    var underlyingNode: VNode { vnode }
}

/// One end (reader or writer) of a named pipe (FIFO). Like `PipeEndpoint` but
/// backed by the VNode's shared `PipeBuffer` — two unrelated processes that open
/// the same FIFO path get endpoints of the same buffer, enabling IPC through the
/// filesystem namespace.
final class FifoEndpoint: FileObject, ReadableStream, ReadinessEventSource, BrokenPipeDetecting {
    private let buffer: PipeBuffer
    let isWriteEnd: Bool
    private let vnode: VNode

    init(buffer: PipeBuffer, isWriteEnd: Bool, vnode: VNode) {
        self.buffer = buffer
        self.isWriteEnd = isWriteEnd
        self.vnode = vnode
    }

    var hasBytesAvailable: Bool {
        !isWriteEnd && (buffer.count > 0 || buffer.writeClosed)
    }

    var hasBrokenPipe: Bool { isWriteEnd && !buffer.hasReaders }

    var readiness: IOReadiness {
        if isWriteEnd {
            var mask: IOReadiness = buffer.hasReaders && buffer.hasWriteCapacity ? [.writable] : []
            if buffer.readClosed { mask.insert(.hangup) }
            return mask
        }
        var mask: IOReadiness = []
        if buffer.count > 0 || buffer.writeClosed { mask.insert(.readable) }
        if buffer.writeClosed { mask.insert(.hangup) }
        return mask
    }

    func addReadWaiter(_ waiter: @escaping () -> Void) -> ReadinessSubscription {
        buffer.addReadWaiter(waiter)
    }

    func read(max maxBytes: Int) -> [UInt8] {
        isWriteEnd ? [] : buffer.dequeue(max: maxBytes)
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Int {
        isWriteEnd ? buffer.enqueue(bytes) : 0
    }

    func opened() {
        if isWriteEnd { buffer.openWriteHandle() } else { buffer.openReadHandle() }
        vnode.openHandles += 1
    }

    func closed() {
        if isWriteEnd { buffer.closeWriteHandle() } else { buffer.closeReadHandle() }
        vnode.openHandles -= 1
    }

    func addReadinessListener(_ listener: @escaping () -> Void) -> ReadinessSubscription {
        buffer.addReadinessListener(listener)
    }
}
