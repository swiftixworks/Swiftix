//
//  NetworkUplinkTransport.swift
//  SwiftixBridge
//
//  Apple-platform implementation of Swiftix's `UplinkTransport` seam. Each
//  guest TCP flow or UDP association becomes one ordinary `Network.framework`
//  `NWConnection` to the real destination; stream bytes or complete datagrams
//  are relayed between that connection and the in-core SLIRP-style NAT endpoint.
//  No raw sockets, utun device, packet-tunnel entitlement, or L2 access is
//  required, so the same mechanism works in the sandbox on iOS and macOS.
//
//  Architecture boundary: this target may import Foundation / Network and
//  depends on Swiftix; the Swiftix core never imports or depends on this target.
//  On platforms without Network.framework the public type remains available but
//  opens fail immediately with `.networkUnreachable`, keeping the package graph
//  buildable on Linux while accurately reporting that this backend is absent.
//
//  Concurrency contract: the embedding host drives every core and its shared
//  EventLoop on `MainActor`. NWConnection callbacks arrive on `DispatchQueue.main`
//  and use `MainActor.assumeIsolated` before invoking the deliberately
//  non-Sendable core observer. Channel methods are nonisolated protocol witnesses
//  that make the same checked hop; invoking this backend away from MainActor is a
//  contract violation and traps rather than racing. There are no locks and no
//  `@unchecked Sendable` escape hatch.

import Swiftix

#if canImport(Network)
import Foundation
import Network

/// A real-network TCP/UDP backend for Swiftix's user-mode NAT engine.
///
/// Construct it on `MainActor`, install it with `NetworkStack.installUplink(_:)`,
/// and keep every call into that stack on MainActor. One instance is stateless
/// and may back any number of flows on one or more stacks, provided all of them
/// obey that same executor contract.
@MainActor
public final class NetworkUplinkTransport: @preconcurrency UplinkTransport {
    public init() {}

    public func openTCP(to endpoint: UplinkEndpoint,
                        observer: any UplinkTCPObserver) -> any UplinkTCPChannel {
        // This actor-isolated witness is exposed through the executor-agnostic
        // core protocol using @preconcurrency. The embedding host invokes it only
        // from MainActor; the generated synchronous witness enforces that runtime
        // contract without pretending the non-Sendable observer is Sendable.
        let channel = NetworkTCPChannel(endpoint: endpoint, observer: observer)
        channel.start()
        return channel
    }

    public func openUDP(to endpoint: UplinkEndpoint,
                        observer: any UplinkUDPObserver) -> any UplinkUDPChannel {
        let channel = NetworkUDPChannel(endpoint: endpoint, observer: observer)
        channel.start()
        return channel
    }
}

/// One NWConnection and its bridge to a single in-core NAT TCP flow.
@MainActor
private final class NetworkTCPChannel: UplinkTCPChannel {
    private static let maxPendingSendBytes = 1_048_576

    private enum Phase {
        case preparing
        case ready
        case terminal
    }

    private let connection: NWConnection
    private weak var observer: (any UplinkTCPObserver)?
    private var phase: Phase = .preparing
    private var guestFinished = false
    private var peerFinished = false
    private var cancelledLocally = false
    private var pendingSendBytes = 0

    init(endpoint: UplinkEndpoint, observer: any UplinkTCPObserver) {
        let host = NWEndpoint.Host(endpoint.host.description)
        // Every UInt16 is representable as an NWEndpoint.Port raw value.
        let port = NWEndpoint.Port(rawValue: endpoint.port)!
        self.connection = NWConnection(host: host, port: port, using: .tcp)
        self.observer = observer
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            // This handler is delivered on the queue passed to start (main).
            // Convert that runtime fact into the static actor contract before
            // touching the non-Sendable flow observer.
            MainActor.assumeIsolated {
                self?.handleState(state)
            }
        }
        connection.start(queue: .main)
    }

    // UplinkTCPChannel is executor-agnostic, while this implementation is
    // explicitly MainActor-backed. These nonisolated witnesses assert the
    // documented call-site contract and then perform the mutation in isolation.
    nonisolated func send(_ bytes: [UInt8]) {
        MainActor.assumeIsolated {
            self.sendOnMain(bytes)
        }
    }

    nonisolated func finish() {
        MainActor.assumeIsolated {
            self.finishOnMain()
        }
    }

    nonisolated func cancel() {
        MainActor.assumeIsolated {
            self.cancelOnMain()
        }
    }

    private func handleState(_ state: NWConnection.State) {
        guard phase != .terminal else { return }
        switch state {
        case .ready:
            guard phase == .preparing else { return }
            phase = .ready
            observer?.uplinkDidOpen()
            receiveNext()
        case .failed(let error):
            fail(Self.failure(for: error))
        case .cancelled:
            if !cancelledLocally {
                fail(.cancelled)
            }
        case .setup, .preparing, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func sendOnMain(_ bytes: [UInt8]) {
        guard phase == .ready, !guestFinished, !bytes.isEmpty else { return }
        guard bytes.count <= Self.maxPendingSendBytes,
              pendingSendBytes <= Self.maxPendingSendBytes - bytes.count else {
            fail(.other)
            return
        }
        pendingSendBytes += bytes.count
        connection.send(content: Data(bytes),
                        completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                self?.completeSend(byteCount: bytes.count, error: error)
            }
        })
    }

    private func completeSend(byteCount: Int, error: NWError?) {
        guard phase != .terminal else { return }
        pendingSendBytes = max(0, pendingSendBytes - byteCount)
        if let error { fail(Self.failure(for: error)) }
    }

    private func finishOnMain() {
        guard phase == .ready, !guestFinished else { return }
        guestFinished = true
        // isComplete on TCP half-closes the outbound byte stream (FIN) while the
        // receive loop remains active until the real peer reaches EOF.
        connection.send(content: nil,
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.fail(Self.failure(for: error))
            }
        })
    }

    private func cancelOnMain() {
        guard phase != .terminal else { return }
        cancelledLocally = true
        phase = .terminal
        pendingSendBytes = 0
        observer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receiveNext() {
        guard phase == .ready, !peerFinished else { return }
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            MainActor.assumeIsolated {
                self?.handleReceive(content: content,
                                    isComplete: isComplete,
                                    error: error)
            }
        }
    }

    private func handleReceive(content: Data?,
                               isComplete: Bool,
                               error: NWError?) {
        guard phase == .ready else { return }
        if let content, !content.isEmpty {
            observer?.uplinkDidReceive(Array(content))
        }
        if let error {
            fail(Self.failure(for: error))
            return
        }
        if isComplete {
            peerFinished = true
            observer?.uplinkDidFinish()
            return
        }
        receiveNext()
    }

    private func fail(_ failure: UplinkFailure) {
        guard phase != .terminal else { return }
        phase = .terminal
        pendingSendBytes = 0
        let currentObserver = observer
        observer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        currentObserver?.uplinkDidFail(failure)
    }

    fileprivate static func failure(for error: NWError) -> UplinkFailure {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                return .connectionRefused
            case .ETIMEDOUT:
                return .timedOut
            case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN:
                return .networkUnreachable
            case .ECONNRESET, .EPIPE:
                return .reset
            case .ECANCELED:
                return .cancelled
            default:
                return .other
            }
        case .dns:
            return .networkUnreachable
        case .tls, .wifiAware:
            return .other
        @unknown default:
            return .other
        }
    }
}

/// One connected NWConnection/UDP association. Sends made while Network.framework
/// is preparing are queued as distinct datagrams and flushed in order at `.ready`.
@MainActor
private final class NetworkUDPChannel: UplinkUDPChannel {
    private static let maxPendingDatagrams = 256
    private static let maxPendingSendBytes = 1_048_576

    private enum Phase {
        case preparing
        case ready
        case terminal
    }

    private let connection: NWConnection
    private weak var observer: (any UplinkUDPObserver)?
    private var phase: Phase = .preparing
    private var pendingDatagrams: [[UInt8]] = []
    private var pendingDatagramCount = 0
    private var pendingSendBytes = 0
    private var cancelledLocally = false

    init(endpoint: UplinkEndpoint, observer: any UplinkUDPObserver) {
        let host = NWEndpoint.Host(endpoint.host.description)
        let port = NWEndpoint.Port(rawValue: endpoint.port)!
        self.connection = NWConnection(host: host, port: port, using: .udp)
        self.observer = observer
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                self?.handleState(state)
            }
        }
        connection.start(queue: .main)
    }

    nonisolated func send(_ bytes: [UInt8]) {
        MainActor.assumeIsolated {
            self.sendOnMain(bytes)
        }
    }

    nonisolated func cancel() {
        MainActor.assumeIsolated {
            self.cancelOnMain()
        }
    }

    private func handleState(_ state: NWConnection.State) {
        guard phase != .terminal else { return }
        switch state {
        case .ready:
            guard phase == .preparing else { return }
            phase = .ready
            let queued = pendingDatagrams
            pendingDatagrams.removeAll(keepingCapacity: false)
            for datagram in queued {
                sendReadyDatagram(datagram)
            }
            receiveNext()
        case .failed(let error):
            fail(NetworkTCPChannel.failure(for: error))
        case .cancelled:
            if !cancelledLocally {
                fail(.cancelled)
            }
        case .setup, .preparing, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func sendOnMain(_ bytes: [UInt8]) {
        guard phase != .terminal else { return }
        guard pendingDatagramCount < Self.maxPendingDatagrams,
              bytes.count <= Self.maxPendingSendBytes,
              pendingSendBytes <= Self.maxPendingSendBytes - bytes.count else {
            fail(.other)
            return
        }
        pendingDatagramCount += 1
        pendingSendBytes += bytes.count
        switch phase {
        case .preparing:
            pendingDatagrams.append(bytes)
        case .ready:
            sendReadyDatagram(bytes)
        case .terminal:
            break
        }
    }

    private func sendReadyDatagram(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes),
                        completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                self?.completeDatagram(byteCount: bytes.count, error: error)
            }
        })
    }

    private func completeDatagram(byteCount: Int, error: NWError?) {
        guard phase != .terminal else { return }
        pendingDatagramCount = max(0, pendingDatagramCount - 1)
        pendingSendBytes = max(0, pendingSendBytes - byteCount)
        if let error { fail(NetworkTCPChannel.failure(for: error)) }
    }

    private func receiveNext() {
        guard phase == .ready else { return }
        connection.receiveMessage { [weak self] content, _, _, error in
            MainActor.assumeIsolated {
                self?.handleReceive(content: content, error: error)
            }
        }
    }

    private func handleReceive(content: Data?, error: NWError?) {
        guard phase == .ready else { return }
        if let error {
            fail(NetworkTCPChannel.failure(for: error))
            return
        }
        if let content {
            observer?.uplinkUDPDidReceive(Array(content))
        }
        receiveNext()
    }

    private func cancelOnMain() {
        guard phase != .terminal else { return }
        cancelledLocally = true
        phase = .terminal
        pendingDatagrams.removeAll()
        pendingDatagramCount = 0
        pendingSendBytes = 0
        observer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func fail(_ failure: UplinkFailure) {
        guard phase != .terminal else { return }
        phase = .terminal
        pendingDatagrams.removeAll()
        pendingDatagramCount = 0
        pendingSendBytes = 0
        let currentObserver = observer
        observer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        currentObserver?.uplinkUDPDidFail(failure)
    }
}

#else

/// Placeholder on platforms where Network.framework is unavailable. The core
/// and its deterministic NAT engine remain fully portable; only the concrete
/// real-socket backend is absent.
public final class NetworkUplinkTransport: UplinkTransport {
    public init() {}

    public func openTCP(to endpoint: UplinkEndpoint,
                        observer: any UplinkTCPObserver) -> any UplinkTCPChannel {
        observer.uplinkDidFail(.networkUnreachable)
        return UnavailableTCPChannel()
    }
}

private final class UnavailableTCPChannel: UplinkTCPChannel {
    func send(_ bytes: [UInt8]) {}
    func finish() {}
    func cancel() {}
}

#endif
