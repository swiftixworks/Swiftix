//
//  Uplink.swift
//  Swiftix
//
//  The consumer-facing seam for "user-mode NAT" (SLIRP-style): the abstraction
//  that lets a Swiftix host reach a REAL network without the core ever creating
//  a real socket or importing Foundation.
//
//  How it fits the architecture:
//    - A Swiftix node keeps modeling one Linux-like host. When it is configured
//      as a NAT gateway, non-local IPv4 traffic that would otherwise be
//      forwarded (`NetworkStack.forwardIPv4`) is instead handed to an in-core
//      NAT engine (`UplinkNAT`). The engine TERMINATES the guest's TCP flows and
//      UDP associations (it plays the role of the remote peer) and relays payloads
//      over ordinary real transport channels — exactly how QEMU user-mode
//      networking and gVisor reach the host network. No IP packets ever leave the
//      process; only application-level streams and datagrams do, so no raw sockets /
//      packet tunnels / elevated entitlements are required (works on iOS and macOS).
//    - The core defines only this seam. The concrete transport (opening real
//      sockets via `Network.framework`) lives in a consumer target
//      (`SwiftixBridge`) or the app, mirroring how `Interface.onEgress` is an
//      abstract closure the consumer wires to a link/switch. The core never
//      depends on the transport, preserving its "no Foundation, no platform
//      deps" contract.
//
//  Concurrency contract (R16/R17): these are reference-type protocols and are
//  deliberately NOT `Sendable`, exactly like the rest of the core network graph
//  (`EventLoop`, `NetworkStack`, `Interface`). A concrete `UplinkTransport` (e.g.
//  SwiftixBridge's `Network.framework` backend) MUST be constructed and used
//  from the single executor that drives the owning `EventLoop`, and MUST marshal
//  any real-socket callbacks back onto that executor BEFORE invoking an
//  `UplinkTCPObserver` or `UplinkUDPObserver` method — mirroring how
//  `ClockDriver` bridges a `CADisplayLink` via `MainActor.assumeIsolated`.
//  Never reach for `@unchecked Sendable` or locks to escape this.

/// A real-network transport endpoint a guest flow wants to reach: the upstream
/// host address and port the guest addressed. A pure `Sendable` value type so it
/// can be logged / snapshotted without touching live state.
public struct UplinkEndpoint: Equatable, Sendable {
    /// The upstream IPv4 address the guest addressed (the real peer).
    public var host: IPv4Address
    /// The upstream TCP/UDP port the guest addressed.
    public var port: UInt16

    public init(host: IPv4Address, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// Why a real transport channel failed to open, or was torn down by the peer or
/// the transport. Mapped by the NAT engine onto the appropriate guest-facing
/// signal (a refused connect becomes a RST toward the guest, and so on).
public enum UplinkFailure: Equatable, Sendable {
    /// The upstream actively refused the connection (e.g. TCP RST on connect).
    case connectionRefused
    /// The connect attempt exceeded the transport's timeout.
    case timedOut
    /// The upstream host/network was unreachable (no route, DNS failure, etc.).
    case networkUnreachable
    /// An established connection was reset by the upstream peer.
    case reset
    /// The transport cancelled the channel (e.g. app teardown).
    case cancelled
    /// Any other transport error not captured above.
    case other
}

/// The handle the core's NAT engine uses to drive ONE real TCP connection. The
/// consumer's `UplinkTransport` returns a channel from `openTCP`; the engine
/// calls it as the guest produces data or closes its side of the connection.
///
/// All methods are invoked on the stack's executor. Implementations must be
/// safe against being called after `cancel()` (later calls are no-ops).
public protocol UplinkTCPChannel: AnyObject {
    /// Relay `bytes` (ordered, non-empty) from the guest toward the real peer.
    /// The transport is responsible for buffering / backpressure.
    func send(_ bytes: [UInt8])

    /// The guest half-closed its send side (FIN): no more guest→peer bytes will
    /// follow. The peer→guest direction stays open until the peer closes, so the
    /// transport must keep delivering `uplinkDidReceive`/`uplinkDidFinish`.
    func finish()

    /// Abort the connection immediately (guest RST, retransmit exhaustion, or
    /// engine teardown). Idempotent; releases the transport's per-channel state.
    func cancel()
}

/// Lifecycle + inbound-data callbacks from ONE real TCP connection, implemented
/// by the core NAT engine (`UplinkTCPFlow`). The consumer's transport invokes
/// these as the real socket connects, delivers data, or closes.
///
/// Every callback MUST be delivered on the stack's executor (the transport
/// marshals real-socket completion handlers back onto it first). The engine uses
/// them to complete the guest handshake and to synthesize segments toward the
/// guest on the real peer's behalf.
public protocol UplinkTCPObserver: AnyObject {
    /// The real connection is established. The engine completes the guest
    /// handshake (SYN-ACK) and begins relaying. Called at most once, before any
    /// `uplinkDidReceive`.
    func uplinkDidOpen()

    /// `bytes` (ordered, non-empty) arrived from the real peer, destined for the
    /// guest. May be called many times after `uplinkDidOpen`.
    func uplinkDidReceive(_ bytes: [UInt8])

    /// The real peer closed its send side (EOF). No more peer→guest bytes will
    /// follow; the engine sends a FIN toward the guest. The guest→peer direction
    /// may still be open.
    func uplinkDidFinish()

    /// The channel could not be opened, or an established connection was reset /
    /// cancelled. The engine translates this into a RST toward the guest and
    /// tears the flow down. Terminal: no further callbacks follow.
    func uplinkDidFail(_ failure: UplinkFailure)
}

/// Handle for one connected UDP association. Each `send` preserves one datagram
/// boundary; `cancel` releases the host socket and is idempotent.
public protocol UplinkUDPChannel: AnyObject {
    func send(_ bytes: [UInt8])
    func cancel()
}

/// Callbacks from one connected real UDP association. A channel is keyed to one
/// remote endpoint, so every delivered datagram has that endpoint as its source.
/// All callbacks obey the same single-executor rule as TCP observers.
public protocol UplinkUDPObserver: AnyObject {
    func uplinkUDPDidReceive(_ bytes: [UInt8])
    func uplinkUDPDidFail(_ failure: UplinkFailure)
}

/// The consumer-provided factory for real transport channels — the single seam
/// the core uses to reach the real network. The core never creates real sockets;
/// a consumer target (`SwiftixBridge` / the app) implements this and injects it
/// via `NetworkStack.installUplink(_:)`.
///
/// Not `Sendable` and not actor-isolated (see the file header): construct and
/// use it only from the executor that drives the owning `EventLoop`.
public protocol UplinkTransport: AnyObject {
    /// Open a real TCP connection to `endpoint`, reporting its lifecycle to
    /// `observer`. Returns the channel the engine drives for the guest→peer
    /// direction. The transport MUST deliver every `observer` callback on the
    /// stack's executor, and SHOULD release its reference to `observer` once the
    /// channel is cancelled / failed / fully closed so the per-flow cycle breaks.
    func openTCP(to endpoint: UplinkEndpoint, observer: any UplinkTCPObserver) -> any UplinkTCPChannel

    /// Open a connected real UDP association. Datagram boundaries passed to and
    /// received from the channel must be preserved exactly.
    func openUDP(to endpoint: UplinkEndpoint, observer: any UplinkUDPObserver) -> any UplinkUDPChannel
}

/// Source-compatible fallback for transports that have not implemented UDP yet.
/// TCP remains usable, while UDP fails deterministically instead of disappearing.
public extension UplinkTransport {
    func openUDP(to endpoint: UplinkEndpoint,
                 observer: any UplinkUDPObserver) -> any UplinkUDPChannel {
        observer.uplinkUDPDidFail(.networkUnreachable)
        return UnsupportedUplinkUDPChannel()
    }
}

private final class UnsupportedUplinkUDPChannel: UplinkUDPChannel {
    func send(_ bytes: [UInt8]) {}
    func cancel() {}
}
