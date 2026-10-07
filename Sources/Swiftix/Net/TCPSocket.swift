/// A TCP socket — a `FileObject`. It is either unbound, a passive listener, or
/// bound to an active/accepted connection. The blocking operations (connect,
/// accept, recv) are driven from `ProcessContext` via the kernel's park/wake;
/// this type just holds the references.
final class TCPSocket: FileObject, ReadinessEventSource, SocketOptionStorage {
    let stack: NetworkStack
    var connection: TCPConnection?
    var listener: TCPListener?
    /// Port bound via `bind()` for later use by `listen()`.
    var boundPort: UInt16?
    private let options = SocketOptions()
    /// Open-file descriptions referencing this socket. `dup` and spawn
    /// inheritance share one description (see `FileDescriptorTable`), so this
    /// reaches zero only when the *last* descriptor anywhere closes — by an
    /// explicit close, or by its process exiting or being killed. Nothing is
    /// released before that: a listener fd inherited by a child that later exits
    /// does not evict the parent's still-open listener, and a connected socket
    /// shared with a child stays open until both are done with it.
    private var handleCount = 0

    init(stack: NetworkStack) {
        self.stack = stack
    }

    func opened() { handleCount += 1 }

    func closed() {
        handleCount -= 1
        guard handleCount <= 0 else { return }
        // Last handle closed: free the passive-listen port for reuse (EADDRINUSE
        // no longer applies once the server that held it is gone).
        if let listener {
            stack.removeListener(listener)
            listener.closeBacklog()
            self.listener = nil
        }
        // Last handle on a connected socket: `close(2)`. The connection decides
        // between an orderly FIN and a reset (see
        // `TCPConnectionPlanner.lastDescriptorClosed`) and then lives on only as
        // long as its close handshake needs.
        connection?.lastDescriptorClosed()
    }

    func read(max: Int) -> [UInt8] {
        connection?.read(max: max) ?? []
    }

    var readiness: IOReadiness {
        if let listener {
            return listener.hasPending ? [.readable] : []
        }
        return connection?.readiness ?? []
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Int {
        guard let connection else { return 0 }
        connection.send(bytes)
        return bytes.count
    }

    func addReadinessListener(_ listener: @escaping () -> Void) -> ReadinessSubscription {
        if let tcpListener = self.listener {
            return tcpListener.addReadinessListener(listener)
        }
        if let connection {
            return connection.addReadinessListener(listener)
        }
        return ReadinessSubscription()
    }

    func setSocketOption(_ option: SocketOption, enabled: Bool) {
        options.set(option, enabled: enabled)
    }

    func socketOption(_ option: SocketOption) -> Bool {
        options.contains(option)
    }
}
