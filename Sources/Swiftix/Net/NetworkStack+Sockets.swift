/// Socket and echo entry points: UDP sockets, ICMP echo (ping), and TCP
/// listen / connect / teardown.
///
/// These are what a program reaches through `ProcessContext`; the bytes they
/// produce leave through `NetworkStack+Egress`.
///
/// Split out of `NetworkStack.swift`; see that file for the type's role and its
/// concurrency contract. Everything here runs on the single serial executor that
/// drives the stack and holds no locks.

extension NetworkStack {

    // MARK: - UDP sockets

    func openUDPSocket() -> UDPSocket {
        UDPSocket(stack: self)
    }

    /// Install a single-owner UDP binding. Shared-port fanout is intentionally
    /// deferred until the stack has an explicit delivery policy; never replace a
    /// live incumbent silently.
    @discardableResult
    func registerUDPSocket(_ socket: UDPSocket, port: UInt16) -> Bool {
        if let incumbent = transport.udpSockets[port], incumbent !== socket {
            return false
        }
        transport.udpSockets[port] = socket
        return true
    }

    func allocateEphemeralPort() -> UInt16 {
        transport.allocateEphemeralPort()
    }

    @discardableResult
    public func sendUDP(sourcePort: UInt16,
                destinationAddress: IPv4Address,
                destinationPort: UInt16,
                payload: [UInt8]) -> Bool {
        let udp = UDPDatagram.build(sourcePort: sourcePort,
                                    destinationPort: destinationPort,
                                    payload: payload)
        // The UDP checksum covers the IPv4 pseudo-header, whose source address is
        // the egress interface chosen by routing — unknown until `sendIPv4`
        // resolves it. Patch the checksum field (offset 6) once `source` is known
        // (R7.2). A computed value of 0 is transmitted as 0xFFFF so it is not
        // mistaken for "no checksum".
        return sendIPv4(proto: IPProtocol.udp.rawValue, to: destinationAddress) { source in
            Self.transportChecksummed(udp, source: source, destination: destinationAddress,
                                      proto: IPProtocol.udp.rawValue, checksumOffset: 6)
        }
    }

    // MARK: - ICMP echo (ping)

    func sendEcho(to destination: IPv4Address,
                  identifier: UInt16,
                  sequence: UInt16,
                  payload: [UInt8],
                  ttl: UInt8 = 64,
                  timeout: Double? = nil,
                  onReply: @escaping (_ from: IPv4Address, _ replyTTL: UInt8) -> Void,
                  onTimeout: (() -> Void)? = nil) {
        guard !interfaceTable.isEmpty else { return }
        let key = Self.echoKey(identifier, sequence)
        transport.echoWaiters[key] = onReply
        let icmp = ICMPMessage.buildEcho(type: .echoRequest,
                                        identifier: identifier,
                                        sequence: sequence,
                                        payload: payload)
        _ = sendIPv4(proto: IPProtocol.icmp.rawValue, to: destination, ttl: ttl, payload: icmp)
        if let timeout {
            schedule(after: timeout) { [weak self] in
                guard let self, self.transport.echoWaiters[key] != nil else { return }   // reply already handled
                self.transport.echoWaiters[key] = nil
                onTimeout?()
            }
        }
    }

    func cancelEcho(identifier: UInt16, sequence: UInt16) {
        transport.echoWaiters[Self.echoKey(identifier, sequence)] = nil
    }

    static func echoKey(_ identifier: UInt16, _ sequence: UInt16) -> UInt32 {
        (UInt32(identifier) << 16) | UInt32(sequence)
    }

    // MARK: - TCP

    func nextISS() -> UInt32 {
        transport.nextISS()
    }

    /// Register a passive TCP endpoint on `port`. This is a low-level primitive:
    /// it does **not** guard against a second listener on the same port — that
    /// duplicate protection is enforced one layer up, in the `tcpListen` syscall
    /// (`ProcessContext`), which rejects an already-bound port with EADDRINUSE.
    /// Internal scaffolding (tests) that call this directly own the port and never
    /// double-register, so the primitive stays a plain install.
    func listen(port: UInt16) -> TCPListener {
        let listener = TCPListener(port: port)
        transport.tcpListeners[port] = listener
        return listener
    }

    /// True when a passive TCP listener is already registered on `port`. The
    /// `tcpListen` syscall consults this to reject a duplicate passive open with
    /// EADDRINUSE instead of silently replacing the incumbent listener.
    func tcpListenerExists(port: UInt16) -> Bool {
        transport.tcpListeners[port] != nil
    }

    /// True when a UDP socket is already bound to `port`.
    func udpPortRegistered(port: UInt16) -> Bool {
        transport.udpSockets[port] != nil
    }

    /// Release a passive TCP listener when the last descriptor handle to its
    /// socket closes (see `TCPSocket.closed()`), freeing the port for reuse. The
    /// identity check (`===`) makes this a no-op if a newer listener has already
    /// taken the port, so an inherited handle closing in a child never evicts the
    /// parent's still-open listener.
    func removeListener(_ listener: TCPListener) {
        if transport.tcpListeners[listener.port] === listener {
            transport.tcpListeners[listener.port] = nil
        }
    }

    /// Release a UDP binding when the last descriptor handle to `socket` closes,
    /// freeing the port for reuse. The identity check keeps an inherited handle
    /// closing in a child from evicting a socket still open in the parent.
    func unregisterUDPSocket(_ socket: UDPSocket, port: UInt16) {
        if transport.udpSockets[port] === socket {
            transport.udpSockets[port] = nil
        }
    }

    func connect(localPort: UInt16, to remoteIP: IPv4Address, remotePort: UInt16) -> TCPConnection {
        let connection = TCPConnection(stack: self, localPort: localPort, remoteIP: remoteIP, remotePort: remotePort)
        transport.tcpConnections[TCPKey(localPort: localPort, remoteIP: remoteIP.raw, remotePort: remotePort)] = connection
        connection.connect()
        return connection
    }

    func sendTCP(_ segment: [UInt8], to destination: IPv4Address) {
        // The TCP checksum covers the IPv4 pseudo-header, whose source address is
        // the egress interface chosen by routing. The connection builds the segment
        // with a zero checksum field (offset 16); finalize it here once `source` is
        // known so a real peer accepts the segment (R7.1).
        _ = sendIPv4(proto: IPProtocol.tcp.rawValue, to: destination) { source in
            Self.transportChecksummed(segment, source: source, destination: destination,
                                      proto: IPProtocol.tcp.rawValue, checksumOffset: 16)
        }
    }

    /// Emit a RST segment to `destination` for a segment that matched no connection
    /// or listener (R9). The reset is built with a zero receive window and routed
    /// through `sendTCP`, so it is checksummed over the IPv4 pseudo-header exactly
    /// like any other segment (R7.1). `localPort`/`remotePort` are this host's port
    /// (the triggering segment's destination) and the peer's port (its source); the
    /// `seq`/`ack`/`ackFlag` values are chosen by the caller per R9.3/R9.4.
    func sendRST(to destination: IPv4Address,
                 localPort: UInt16,
                 remotePort: UInt16,
                 seq: UInt32,
                 ack: UInt32,
                 ackFlag: Bool) {
        let flags: TCPSegment.Flags = ackFlag ? [.rst, .ack] : [.rst]
        let segment = TCPSegment.build(sourcePort: localPort,
                                       destinationPort: remotePort,
                                       sequence: seq,
                                       acknowledgment: ack,
                                       flags: flags,
                                       window: 0,
                                       payload: [])
        sendTCP(segment, to: destination)
    }

    /// Remove a fully-closed TCP connection from the table.
    func removeConnection(localPort: UInt16, remoteIP: IPv4Address, remotePort: UInt16) {
        transport.tcpConnections[TCPKey(localPort: localPort, remoteIP: remoteIP.raw, remotePort: remotePort)] = nil
    }
}
