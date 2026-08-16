/// `ProcessContext` networking syscalls: network configuration plus the UDP,
/// ICMP (ping), and TCP socket surface.
extension ProcessContext {

    // MARK: - Network configuration

    /// Apply a complete network configuration to this process's network namespace.
    public func configureNetwork(_ configuration: NetworkConfiguration) {
        kernel.netns.stack.configure(configuration)
    }

    /// Apply one incremental network configuration change.
    public func configureNetwork(_ change: NetworkConfigurationChange) {
        kernel.netns.stack.configure(change)
    }

    /// Snapshot the current network configuration.
    public func snapshotNetworkConfiguration() -> NetworkConfiguration {
        kernel.netns.stack.snapshotConfiguration()
    }

    /// Resolve a Linux-style interface name (`lo`, `eth0`, …) to the stack's
    /// internal route index.
    public func networkInterfaceIndex(named name: String) -> Int? {
        kernel.netns.stack.interfaceIndex(named: name)
    }

    /// Spawn `command` as a child process with argument vector `args`
    /// (`args[0]` is the program name). Descriptor inheritance means the child
    /// already sees this process's stdin/stdout/stderr, so a meta-program that
    /// launches another command need do no wiring. Returns the child's pid.
    @discardableResult
    public func run(_ command: Command, args: [String]) -> PID {
        let name = args.first ?? command.name
        switch command.body {
        case let .sync(body):
            return spawn(name, args: args) { child in body(child, args) }
        case let .async(body):
            return spawn(name, args: args) { (child: ProcessContext) async in await body(child, args) }
        }
    }

    // MARK: - Sockets (UDP)

    /// Create a UDP socket and return its descriptor.
    public func socket() -> Int? {
        let socket = kernel.netns.stack.openUDPSocket()
        let descriptor = process.fileDescriptors.allocate(socket)
        recordSyscall("socket", result: String(descriptor), detail: "type=udp")
        return descriptor
    }

    /// Bind a socket to a local address (nil = any) and port.
    @discardableResult
    public func bind(_ fd: Int, address: IPv4Address?, port: UInt16) -> Bool {
        let result: Bool
        if let udp = process.fileDescriptors.object(fd) as? UDPSocket {
            // Propagate EADDRINUSE from the stack's explicit single-owner UDP
            // binding model; options never authorize silent table replacement.
            result = udp.bind(address: address, port: port)
        } else if let tcp = process.fileDescriptors.object(fd) as? TCPSocket {
            tcp.boundPort = port
            result = true
        } else {
            result = false
        }
        recordSyscall("bind", result: result ? "0" : "-1", detail: "fd=\(fd),port=\(port)")
        return result
    }

    /// Set a socket option on a UDP/TCP socket descriptor.
    public func setSocketOption(_ fd: Int, _ option: SocketOption, enabled: Bool) throws {
        guard let socket = process.fileDescriptors.object(fd) as? SocketOptionStorage else {
            throw SyscallError.badFileDescriptor
        }
        socket.setSocketOption(option, enabled: enabled)
    }

    /// Read a socket option from a UDP/TCP socket descriptor.
    public func socketOption(_ fd: Int, _ option: SocketOption) throws -> Bool {
        guard let socket = process.fileDescriptors.object(fd) as? SocketOptionStorage else {
            throw SyscallError.badFileDescriptor
        }
        return socket.socketOption(option)
    }

    /// Send a datagram from a socket to a destination address/port.
    @discardableResult
    public func sendto(_ fd: Int, _ bytes: [UInt8], to address: IPv4Address, port: UInt16) -> Bool {
        guard let socket = process.fileDescriptors.object(fd) as? UDPSocket else {
            recordSyscall("sendto", result: "-1", detail: "fd=\(fd),count=\(bytes.count),port=\(port)")
            return false
        }
        let result = socket.sendTo(bytes, address: address, port: port)
        recordSyscall("sendto", result: result ? String(bytes.count) : "-1",
                      detail: "fd=\(fd),count=\(bytes.count),port=\(port)")
        return result
    }

    /// Non-blocking receive of the next datagram on a socket (nil if none).
    public func recvfrom(_ fd: Int) -> (bytes: [UInt8], address: IPv4Address, port: UInt16)? {
        guard let socket = process.fileDescriptors.object(fd) as? UDPSocket,
              let datagram = socket.receive() else {
            recordSyscall("recvfrom", result: "-1", detail: "fd=\(fd)")
            return nil
        }
        recordSyscall("recvfrom", result: String(datagram.payload.count), detail: "fd=\(fd)")
        return (datagram.payload, datagram.sourceAddress, datagram.sourcePort)
    }

    /// Blocking receive: park the process until a datagram arrives on the socket,
    /// then resume it with the datagram. Call this as the tail of a step — code
    /// "after the blocking call" goes inside `resume`. (A linear async/await
    /// front-end can be layered on top of this later.)
    public func recvfrom(_ fd: Int,
                  resume: @escaping (_ bytes: [UInt8], _ address: IPv4Address, _ port: UInt16) -> Void) {
        guard let socket = process.fileDescriptors.object(fd) as? UDPSocket else { return }
        let kernel = self.kernel
        let process = self.process
        var completed = false
        var subscription: ReadinessSubscription?
        let waitID = process.beginWait(.datagram(fd: fd)) {
            guard !completed else { return }
            completed = true
            subscription?.cancel()
        }
        subscription = socket.park { [weak kernel, weak process] datagram in
            guard let kernel, let process else { return }
            guard !completed else { return }
            completed = true
            subscription?.cancel()
            process.disarmWaitCancellation(waitID)
            kernel.runStep(process) {
                process.endWait(waitID)
                resume(datagram.payload, datagram.sourceAddress, datagram.sourcePort)
            }
        }
    }

    // MARK: - ICMP (ping)

    /// Send an ICMP echo request and park the process until the matching echo
    /// reply arrives (or `timeout` seconds elapse), then resume. On reply `from`
    /// is the responder, `replyTTL` the IPv4 TTL of the reply packet (what `ping`
    /// prints as `ttl=`), and `rttSeconds` the round-trip time; on timeout `from`
    /// is nil and `replyTTL` is 0. Exactly one of the two outcomes fires. Call as
    /// the tail of a step. `payload` is echoed back by the peer, so its size sets
    /// the reported packet size (Linux's default is 56 data bytes). The `ttl`
    /// parameter sets the IP time-to-live for the outgoing packet (default 64);
    /// intermediate routers that decrement it to zero reply with ICMP
    /// time-exceeded, which the stack matches back to this waiter — enabling
    /// traceroute.
    public func icmpEcho(to address: IPv4Address,
                  identifier: UInt16,
                  sequence: UInt16,
                  payload: [UInt8] = [],
                  ttl: UInt8 = 64,
                  timeout: Double = 1.0,
                  resume: @escaping (_ from: IPv4Address?, _ replyTTL: UInt8, _ rttSeconds: Double) -> Void) {
        let kernel = self.kernel
        let process = self.process
        let sentAt = kernel.loop.now
        var completed = false
        let waitID = process.beginWait(.icmp(identifier: identifier, sequence: sequence)) { [weak kernel] in
            guard !completed else { return }
            completed = true
            kernel?.netns.stack.cancelEcho(identifier: identifier, sequence: sequence)
        }
        kernel.netns.stack.sendEcho(
            to: address,
            identifier: identifier,
            sequence: sequence,
            payload: payload,
            ttl: ttl,
            timeout: timeout,
            onReply: { [weak kernel, weak process] from, replyTTL in
                guard let kernel, let process else { return }
                guard !completed else { return }
                completed = true
                process.disarmWaitCancellation(waitID)
                kernel.runStep(process) {
                    process.endWait(waitID)
                    resume(from, replyTTL, kernel.loop.now - sentAt)
                }
            },
            onTimeout: { [weak kernel, weak process] in
                guard let kernel, let process else { return }
                guard !completed else { return }
                completed = true
                process.disarmWaitCancellation(waitID)
                kernel.runStep(process) {
                    process.endWait(waitID)
                    resume(nil, 0, kernel.loop.now - sentAt)
                }
            })
    }

    // MARK: - TCP

    /// Create a TCP socket and return its descriptor.
    public func tcpSocket() -> Int? {
        let descriptor = process.fileDescriptors.allocate(TCPSocket(stack: kernel.netns.stack))
        recordSyscall("socket", result: String(descriptor), detail: "type=tcp")
        return descriptor
    }

    /// Start listening on a local port (passive open). Returns `false` when the
    /// descriptor is not a TCP socket, when no port is available (port 0 and the
    /// socket was never bound), or when the port is already taken by another
    /// passive listener (EADDRINUSE) — so a second `httpd`/`tcpecho` on the same
    /// port fails rather than silently stealing the incumbent's connections.
    @discardableResult
    public func tcpListen(_ fd: Int, port: UInt16) -> Bool {
        guard let socket = process.fileDescriptors.object(fd) as? TCPSocket else {
            recordSyscall("listen", result: "-1", detail: "fd=\(fd),port=\(port)")
            return false
        }
        // If port is 0 and the socket was previously bound, use the bound port.
        let listenPort = port != 0 ? port : (socket.boundPort ?? 0)
        guard listenPort != 0 else {
            recordSyscall("listen", result: "-1", detail: "fd=\(fd),port=\(port)")
            return false
        }
        // Reject a duplicate passive open: the port is already in use (EADDRINUSE).
        guard !kernel.netns.stack.tcpListenerExists(port: listenPort) else {
            recordSyscall("listen", result: "-1", detail: "fd=\(fd),port=\(listenPort)")
            return false
        }
        socket.listener = kernel.netns.stack.listen(port: listenPort)
        recordSyscall("listen", result: "0", detail: "fd=\(fd),port=\(listenPort)")
        return true
    }

    /// Block until a connection is accepted; resume with a NEW descriptor bound
    /// to the accepted connection.
    public func tcpAccept(_ fd: Int, resume: @escaping (_ acceptedFD: Int) -> Void) {
        guard let socket = process.fileDescriptors.object(fd) as? TCPSocket,
              let listener = socket.listener else { return }
        let kernel = self.kernel
        let process = self.process
        var completed = false
        let waitID = process.beginWait(.tcpAccept(fd: fd)) { [weak listener] in
            guard !completed else { return }
            completed = true
            listener?.onAccept = nil
        }
        let deliver: () -> Void = { [weak kernel, weak process, weak listener] in
            guard let kernel, let process, let listener, let connection = listener.dequeue() else { return }
            guard !completed else { return }
            completed = true
            listener.onAccept = nil
            process.disarmWaitCancellation(waitID)
            kernel.runStep(process) {
                process.endWait(waitID)
                let accepted = TCPSocket(stack: kernel.netns.stack)
                accepted.connection = connection
                resume(process.fileDescriptors.allocate(accepted))
            }
        }
        listener.onAccept = deliver
        if listener.hasPending { deliver() }
    }

    /// Active open: block until the connection is established.
    public func tcpConnect(_ fd: Int, to address: IPv4Address, port: UInt16, resume: @escaping () -> Void) {
        guard let socket = process.fileDescriptors.object(fd) as? TCPSocket else { return }
        let kernel = self.kernel
        let process = self.process
        let localPort = kernel.netns.stack.allocateEphemeralPort()
        let connection = kernel.netns.stack.connect(localPort: localPort, to: address, remotePort: port)
        socket.connection = connection
        var completed = false
        let waitID = process.beginWait(.tcpConnect(fd: fd)) { [weak connection] in
            guard !completed else { return }
            completed = true
            connection?.onEstablished = nil
        }
        connection.onEstablished = { [weak kernel, weak process, weak connection] in
            guard let kernel, let process, let connection else { return }
            guard !completed else { return }
            completed = true
            connection.onEstablished = nil
            process.disarmWaitCancellation(waitID)
            kernel.runStep(process) {
                process.endWait(waitID)
                resume()
            }
        }
    }

    /// Send data on a connected socket (non-blocking; assumes window available).
    @discardableResult
    public func tcpSend(_ fd: Int, _ bytes: [UInt8]) -> Bool {
        guard let socket = process.fileDescriptors.object(fd) as? TCPSocket,
              let connection = socket.connection else {
            recordSyscall("send", result: "-1", detail: "fd=\(fd),count=\(bytes.count)")
            return false
        }
        connection.send(bytes)
        recordSyscall("send", result: String(bytes.count), detail: "fd=\(fd),count=\(bytes.count)")
        return true
    }

    /// Block until in-order data is available, then resume with it.
    public func tcpRecv(_ fd: Int, resume: @escaping (_ bytes: [UInt8]) -> Void) {
        tcpRecv(fd, max: 65_535, resume: resume)
    }

    /// Block until in-order data is available, then resume with at most
    /// `maxBytes`, retaining any remainder for a later receive.
    public func tcpRecv(_ fd: Int,
                        max maxBytes: Int,
                        resume: @escaping (_ bytes: [UInt8]) -> Void) {
        guard let socket = process.fileDescriptors.object(fd) as? TCPSocket,
              let connection = socket.connection else { return }
        let limit = Swift.max(0, maxBytes)
        let kernel = self.kernel
        let process = self.process
        // Fast path: bytes already buffered, or EOF already arrived (a FIN can be
        // consumed before the app ever calls recv — resume immediately with an
        // empty read so the caller observes EOF instead of blocking forever).
        if connection.hasBufferedData || connection.eofReceived {
            let waitID = process.beginWait(.tcpReceive(fd: fd))
            kernel.runStep(process) {
                process.endWait(waitID)
                resume(connection.read(max: limit))
            }
            return
        }
        var completed = false
        var subscription: ReadinessSubscription?
        let waitID = process.beginWait(.tcpReceive(fd: fd)) {
            guard !completed else { return }
            completed = true
            subscription?.cancel()
            subscription = nil
        }
        subscription = connection.addReadWaiter { [weak kernel, weak process, weak connection] in
            guard let kernel, let process, let connection else { return }
            guard !completed else { return }
            completed = true
            subscription?.cancel()
            subscription = nil
            process.disarmWaitCancellation(waitID)
            kernel.runStep(process) {
                process.endWait(waitID)
                resume(connection.read(max: limit))
            }
        }
    }

    public func tcpClose(_ fd: Int) {
        let wasOpen = process.fileDescriptors.object(fd) != nil
        if let socket = process.fileDescriptors.object(fd) as? TCPSocket {
            socket.connection?.close()
        }
        process.fileDescriptors.close(fd)
        recordSyscall("close", result: wasOpen ? "0" : "-1", detail: "fd=\(fd)")
    }

}
