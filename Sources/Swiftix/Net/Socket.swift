/// A received UDP datagram queued on a socket.
struct Datagram {
    let payload: [UInt8]
    let sourceAddress: IPv4Address
    let sourcePort: UInt16
}

/// A UDP socket — a `FileObject` so it lives in a process's descriptor table
/// like any other open file. The byte-stream `read`/`write` view is unused for
/// UDP; processes use datagram semantics via `sendTo` / `receive`, surfaced as
/// the `sendto` / `recvfrom` syscalls on `ProcessContext`.
final class UDPSocket: FileObject, ReadinessEventSource, SocketOptionStorage {
    static let maximumQueuedDatagrams = 256
    static let maximumQueuedBytes = 1 * 1_024 * 1_024

    struct QueueStatistics: Equatable {
        let datagrams: Int
        let bytes: Int
        let highWaterDatagrams: Int
        let highWaterBytes: Int
        let droppedDatagrams: Int
    }

    private(set) var localAddress: IPv4Address?
    private(set) var localPort: UInt16 = 0
    private unowned let stack: NetworkStack
    private var inbox = BoundedFIFOQueue<Datagram>(capacity: maximumQueuedDatagrams)
    private var queuedBytes = 0
    private var highWaterBytes = 0
    private var droppedDatagrams = 0
    private var nextWaiterID = 0
    private var waiters: [(id: Int, resume: (Datagram) -> Void)] = []   // parked blocking readers (FIFO)
    private let readinessBroadcaster = ReadinessBroadcaster()
    private let options = SocketOptions()
    /// Live descriptor-handle count (see `TCPSocket`): the bound port is released
    /// only when the last handle closes, so an inherited handle closing in a child
    /// never unbinds a socket still open in the parent.
    private var handleCount = 0

    init(stack: NetworkStack) {
        self.stack = stack
    }

    func opened() { handleCount += 1 }

    func closed() {
        handleCount -= 1
        guard handleCount <= 0, localPort != 0 else { return }
        // Last handle closed: free the bound port for reuse.
        stack.unregisterUDPSocket(self, port: localPort)
    }

    /// Bind to `address`/`port`. The current UDP demultiplexer has one owner per
    /// port, so duplicate binds return `false` even when SO_REUSEADDR is stored;
    /// silently replacing the incumbent would violate both sockets' lifetime.
    /// Port 0 selects an available ephemeral port.
    @discardableResult
    func bind(address: IPv4Address?, port: UInt16) -> Bool {
        guard localPort == 0 else { return false }
        let selectedPort = port == 0 ? stack.allocateEphemeralPort() : port
        guard !stack.udpPortRegistered(port: selectedPort),
              stack.registerUDPSocket(self, port: selectedPort) else { return false }
        localAddress = address
        localPort = selectedPort
        return true
    }

    @discardableResult
    func sendTo(_ payload: [UInt8], address: IPv4Address, port: UInt16) -> Bool {
        if localPort == 0 {
            // Auto-assign an ephemeral source port for an unbound socket.
            localPort = stack.allocateEphemeralPort()
            guard stack.registerUDPSocket(self, port: localPort) else {
                localPort = 0
                return false
            }
        }
        return stack.sendUDP(sourcePort: localPort,
                            destinationAddress: address,
                            destinationPort: port,
                            payload: payload)
    }

    /// Non-blocking receive: the next queued datagram, or `nil`.
    func receive() -> Datagram? {
        dequeueDatagram()
    }

    var readiness: IOReadiness {
        var mask: IOReadiness = [.writable]
        if !inbox.isEmpty { mask.insert(.readable) }
        return mask
    }

    /// Park a blocking reader. If a datagram is already queued it is delivered
    /// immediately; otherwise `resume` is held (FIFO) until one arrives. Multiple
    /// readers may be parked at once; each is woken by one datagram in order.
    @discardableResult
    func park(_ resume: @escaping (Datagram) -> Void) -> ReadinessSubscription {
        if inbox.isEmpty {
            let id = nextWaiterID
            nextWaiterID += 1
            waiters.append((id: id, resume: resume))
            return ReadinessSubscription { [weak self] in
                self?.waiters.removeAll { $0.id == id }
            }
        } else {
            if let datagram = dequeueDatagram() { resume(datagram) }
            return ReadinessSubscription()
        }
    }

    /// Called by the stack when a datagram is demultiplexed to this socket: wake
    /// the oldest parked reader if there is one, otherwise queue the datagram.
    @discardableResult
    func deliver(_ datagram: Datagram) -> Bool {
        if waiters.isEmpty {
            guard datagram.payload.count <= Self.maximumQueuedBytes - queuedBytes,
                  inbox.append(datagram) else {
                droppedDatagrams += 1
                return false
            }
            queuedBytes += datagram.payload.count
            highWaterBytes = max(highWaterBytes, queuedBytes)
            readinessBroadcaster.notify()
        } else {
            let waiter = waiters.removeFirst()
            waiter.resume(datagram)
        }
        return true
    }

    var queueStatistics: QueueStatistics {
        QueueStatistics(datagrams: inbox.count,
                        bytes: queuedBytes,
                        highWaterDatagrams: inbox.highWaterMark,
                        highWaterBytes: highWaterBytes,
                        droppedDatagrams: droppedDatagrams)
    }

    private func dequeueDatagram() -> Datagram? {
        guard let datagram = inbox.popFirst() else { return nil }
        queuedBytes -= datagram.payload.count
        return datagram
    }

    func addReadinessListener(_ listener: @escaping () -> Void) -> ReadinessSubscription {
        readinessBroadcaster.add(listener)
    }

    func setSocketOption(_ option: SocketOption, enabled: Bool) {
        options.set(option, enabled: enabled)
    }

    func socketOption(_ option: SocketOption) -> Bool {
        options.contains(option)
    }

    // FileObject byte-stream view (unused for UDP).
    func read(max: Int) -> [UInt8] { [] }
    @discardableResult func write(_ bytes: [UInt8]) -> Int { 0 }
}
