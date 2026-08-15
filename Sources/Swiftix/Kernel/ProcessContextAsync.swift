// The async/throwing syscall frontend (R1, R2, R3, R6).
//
// Each method here is a thin adapter that bridges to the existing callback
// (`resume:`-style) syscall on `ProcessContext` via a checked continuation, so
// the underlying park/wake primitives (`runStep`, `blockedOn`, and the
// connection/stream waiters) — and therefore the protocol behavior and message
// ordering — are unchanged (R3.1, R3.2, R3.4). The async methods are new
// overloads layered on top; every existing callback syscall keeps its exact
// signature and behavior.
//
// Standard-library `_Concurrency` only — no platform / Foundation import
// (R3.5, NFR-1). `withCheckedContinuation` / `withCheckedThrowingContinuation`
// come from the concurrency runtime, available identically on every platform.
//
// Single-resume discipline: a fast path returns/throws *before* suspending;
// otherwise the single underlying callback (which is dispatched exactly once
// through `runStep`) resumes the continuation exactly once. Where a hard error
// must be surfaced (a bad descriptor), it is detected and thrown before the
// continuation is created, so the continuation is never created-then-abandoned.

private final class InterruptibleSleepState {
    var didFinish = false
    var cancellationID: Int?
}

private final class InterruptibleAsyncWaitState {
    var didFinish = false
    var cancellationID: Int?
}

extension ProcessContext {

    private func awaitInterruptible<Value: Sendable>(_ register: (@escaping (Value) -> Void) -> Void) async throws -> Value {
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            let state = InterruptibleAsyncWaitState()
            let process = self.process
            state.cancellationID = process.addWaitCancellation {
                guard !state.didFinish else { return }
                state.didFinish = true
                continuation.resume(throwing: SyscallError.interrupted)
            }
            register { [weak process] value in
                guard !state.didFinish else { return }
                state.didFinish = true
                if let process, let cancellationID = state.cancellationID {
                    process.removeWaitCancellation(cancellationID)
                }
                continuation.resume(returning: value)
            }
        }
        guard await kernel.awaitAsyncExecution(process) else {
            throw SyscallError.interrupted
        }
        return value
    }

    // MARK: - R1: datagram receive / stream read / TCP receive

    /// Await the next datagram on a UDP socket (R1.2, R1.3).
    ///
    /// - Fast path (R1.3): a datagram already buffered is returned directly
    ///   without parking the calling process.
    /// - Otherwise the calling process is parked until a datagram arrives, then
    ///   resumed with the datagram bytes, source address, and source port (R1.2).
    /// - Throws `SyscallError.badFileDescriptor` when `fd` is not a UDP socket
    ///   (R5.3) — checked before suspending so the continuation is not abandoned.
    public func recvfrom(_ fd: Int) async throws -> (bytes: [UInt8], address: IPv4Address, port: UInt16) {
        guard let socket = udpSocket(fd) else { throw SyscallError.badFileDescriptor }
        // Fast path: a buffered datagram returns without parking (R1.3). Read it
        // straight off the socket to avoid re-dispatching to this async overload.
        if let datagram = socket.receive() {
            return (bytes: datagram.payload, address: datagram.sourceAddress, port: datagram.sourcePort)
        }
        if isNonBlocking(fd) {
            throw SyscallError.wouldBlock
        }
        return try await awaitInterruptible { finish in
            recvfrom(fd) { bytes, address, port in
                finish((bytes: bytes, address: address, port: port))
            }
        }
    }

    /// Non-blocking datagram receive with typed errors (R6.1, R6.4, R6.5).
    ///
    /// - Returns the datagram bytes, source address, and source port when one is
    ///   buffered (R6.4).
    /// - Throws `SyscallError.wouldBlock` when no datagram is buffered (R6.1) —
    ///   an explicit "no data yet" rather than the ambiguous `nil` of the
    ///   non-throwing `recvfrom(_:) -> …?`.
    /// - Throws `SyscallError.badFileDescriptor` when `fd` is not a UDP socket.
    public func recvfromNonBlocking(_ fd: Int) throws -> (bytes: [UInt8], address: IPv4Address, port: UInt16) {
        guard let socket = udpSocket(fd) else { throw SyscallError.badFileDescriptor }
        guard let datagram = socket.receive() else { throw SyscallError.wouldBlock }
        return (bytes: datagram.payload, address: datagram.sourceAddress, port: datagram.sourcePort)
    }

    /// Await bytes from a readable stream (R1.4). Parks the calling process until
    /// the stream has bytes, then resumes with the available bytes.
    ///
    /// - Throws `SyscallError.badFileDescriptor` when `fd` is not a readable
    ///   stream (R5.3), checked before suspending.
    public func read(_ fd: Int) async throws -> [UInt8] {
        try await read(fd, upTo: 4096)
    }

    /// Await at most `maxBytes` from a descriptor without consuming more than the
    /// caller can accept.
    public func read(_ fd: Int, upTo maxBytes: Int) async throws -> [UInt8] {
        // Any open descriptor is readable: streams (pipe/tty) may park; regular
        // files resume immediately (the callback form handles both).
        guard let object = process.fileDescriptors.object(fd),
              process.fileDescriptors.access(fd)?.canRead == true else {
            throw SyscallError.badFileDescriptor
        }
        guard maxBytes > 0 else { return [] }
        if isNonBlocking(fd),
           let stream = object as? ReadableStream,
           !stream.hasBytesAvailable {
            throw SyscallError.wouldBlock
        }
        return try await awaitInterruptible { finish in
            read(fd, max: maxBytes, resume: finish)
        }
    }

    /// Await in-order TCP data (R1.5, R10.3). Parks the calling process until
    /// in-order data is available (or the connection is torn down), then resumes.
    ///
    /// - Throws `SyscallError.connectionReset` when the connection was aborted by
    ///   an inbound RST (R10.3): the parked recv is woken by `abortByReset()`, and
    ///   the reset is surfaced as a typed error rather than an ambiguous empty read.
    /// - Throws `SyscallError.badFileDescriptor` when `fd` is not a connected TCP
    ///   socket, checked before suspending.
    public func tcpRecv(_ fd: Int) async throws -> [UInt8] {
        try await tcpRecv(fd, max: 65_535)
    }

    /// Await at most `maxBytes` of in-order TCP data, leaving the remainder in the
    /// receive buffer for the next call.
    public func tcpRecv(_ fd: Int, max maxBytes: Int) async throws -> [UInt8] {
        guard let connection = tcpConnection(fd) else { throw SyscallError.badFileDescriptor }
        guard maxBytes > 0 else { return [] }
        if isNonBlocking(fd), !connection.readiness.contains(.readable) {
            throw SyscallError.wouldBlock
        }
        let bytes: [UInt8] = try await awaitInterruptible { finish in
            tcpRecv(fd, max: maxBytes, resume: finish)
        }
        // A reset wakes the parked recv with an empty read; surface it as a typed
        // error so the caller distinguishes an abort from a normal EOF (R10.3).
        if connection.wasReset { throw SyscallError.connectionReset }
        return bytes
    }

    // MARK: - R2: connect / accept / icmpEcho / wait

    /// Await an active open (R2.1). Parks the calling process until the
    /// connection reaches the established state, then resumes.
    ///
    /// - Throws `SyscallError.badFileDescriptor` when `fd` is not a TCP socket,
    ///   checked before suspending.
    public func tcpConnect(_ fd: Int, to address: IPv4Address, port: UInt16) async throws {
        guard isTCPSocket(fd) else { throw SyscallError.badFileDescriptor }
        try await awaitInterruptible { finish in
            tcpConnect(fd, to: address, port: port) { finish(()) }
        }
    }

    /// Await a passive open (R2.2). Parks the calling process until a connection
    /// is accepted, then resumes with a new descriptor bound to it.
    ///
    /// - Throws `SyscallError.badFileDescriptor` when `fd` is not a listening TCP
    ///   socket, checked before suspending.
    public func tcpAccept(_ fd: Int) async throws -> Int {
        guard isTCPListener(fd) else { throw SyscallError.badFileDescriptor }
        if isNonBlocking(fd), tcpSocket(fd)?.listener?.hasPending != true {
            throw SyscallError.wouldBlock
        }
        return try await awaitInterruptible { finish in
            tcpAccept(fd, resume: finish)
        }
    }

    /// Await an ICMP echo exchange (R2.3, R2.4). Resumes with a reply outcome
    /// (responder address + round-trip time) when a matching reply arrives before
    /// the timeout, or a timeout outcome when the timeout elapses first.
    /// The `ttl` parameter controls the IP time-to-live; a TTL-expired intermediate
    /// router's ICMP time-exceeded is treated as a reply (enabling traceroute).
    public func icmpEcho(to address: IPv4Address,
                         identifier: UInt16,
                         sequence: UInt16,
                         ttl: UInt8 = 64,
                         timeout: Double = 1.0) async throws -> Programs.PingOutcome {
        try await awaitInterruptible { finish in
            icmpEcho(to: address, identifier: identifier, sequence: sequence, ttl: ttl, timeout: timeout) { from, replyTTL, rtt in
                if let from {
                    // This front-end sends no payload, so the echoed reply is just
                    // the 8-byte ICMP header.
                    finish(.reply(from: from, sequence: sequence, ttl: replyTTL,
                                  bytes: ICMPMessage.headerLength, rttSeconds: rtt))
                } else {
                    finish(.timeout(sequence: sequence))
                }
            }
        }
    }

    /// Await a child's exit. Throws `.noChildProcess` when no living or queued
    /// child event exists.
    public func wait() async throws -> ChildWaitEvent {
        let result: Result<ChildWaitEvent, SyscallError> = try await awaitInterruptible { finish in
            wait(resume: finish)
        }
        return try result.get()
    }

    /// Await a child event, optionally narrowed to one child pid. Returns `nil`
    /// only for `.noHang` when a matching child exists but no event is ready.
    public func waitpid(_ childPID: PID? = nil,
                        options: ProcessWaitOptions = []) async throws -> ChildWaitEvent? {
        let result: Result<ChildWaitEvent?, SyscallError> = try await awaitInterruptible { finish in
            waitpid(childPID, options: options, resume: finish)
        }
        return try result.get()
    }

    /// Await a child exit/signaled/stopped event.
    public func waitEvent() async throws -> ChildWaitEvent {
        let result: Result<ChildWaitEvent, SyscallError> = try await awaitInterruptible { finish in
            waitEvent(resume: finish)
        }
        return try result.get()
    }

    /// Await descriptor readiness. This is the async façade over callback
    /// `poll(_:timeout:resume:)`; an empty result means the timeout expired.
    public func poll(_ requests: [PollRequest], timeout: Double? = nil) async throws -> [PollResult] {
        try await awaitInterruptible { finish in
            poll(requests, timeout: timeout, resume: finish)
        }
    }

    /// Async `select`: await until at least one fd is ready or timeout expires.
    public func select(readFDs: [Int] = [], writeFDs: [Int] = [], exceptFDs: [Int] = [],
                       timeout: Double? = nil) async throws -> SelectResult {
        try await awaitInterruptible { finish in
            select(readFDs: readFDs, writeFDs: writeFDs, exceptFDs: exceptFDs,
                   timeout: timeout, resume: finish)
        }
    }

    // MARK: - Timers

    /// Await `seconds` of logical time, throwing `.interrupted` if the process is
    /// terminated while parked.
    public func sleep(_ seconds: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let state = InterruptibleSleepState()
            let kernel = self.kernel
            let process = self.process

            process.blockedOn += 1
            state.cancellationID = process.addWaitCancellation {
                guard !state.didFinish else { return }
                state.didFinish = true
                if process.blockedOn > 0 { process.blockedOn -= 1 }
                continuation.resume(throwing: SyscallError.interrupted)
            }

            kernel.schedule(after: seconds) { [weak kernel, weak process] in
                guard let kernel, let process else {
                    guard !state.didFinish else { return }
                    state.didFinish = true
                    continuation.resume(throwing: SyscallError.interrupted)
                    return
                }
                kernel.runStep(process) {
                    guard !state.didFinish else { return }
                    state.didFinish = true
                    if let cancellationID = state.cancellationID {
                        process.removeWaitCancellation(cancellationID)
                    }
                    process.blockedOn -= 1
                    continuation.resume()
                }
            }
        }
        guard await kernel.awaitAsyncExecution(process) else {
            throw SyscallError.interrupted
        }
    }

    // MARK: - Descriptor probes (pre-suspend validation)

    private func udpSocket(_ fd: Int) -> UDPSocket? {
        process.fileDescriptors.object(fd) as? UDPSocket
    }

    private func isNonBlocking(_ fd: Int) -> Bool {
        process.fileDescriptors.flags(fd)?.contains(.nonBlocking) == true
    }

    private func isUDPSocket(_ fd: Int) -> Bool { udpSocket(fd) != nil }

    private func isReadableStream(_ fd: Int) -> Bool {
        process.fileDescriptors.object(fd) is ReadableStream
    }

    private func tcpSocket(_ fd: Int) -> TCPSocket? {
        process.fileDescriptors.object(fd) as? TCPSocket
    }

    private func isTCPSocket(_ fd: Int) -> Bool { tcpSocket(fd) != nil }

    private func isTCPListener(_ fd: Int) -> Bool { tcpSocket(fd)?.listener != nil }

    private func tcpConnection(_ fd: Int) -> TCPConnection? { tcpSocket(fd)?.connection }
}
