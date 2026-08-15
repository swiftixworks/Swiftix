// Swiftix — a pure-Swift, user-space "OS + TCP/IP stack" for one host, for iOS.
//
// Scope of THIS library: a single instance = a lightweight, Linux-like host:
//   * a user-space kernel (process model, VFS, file descriptors, syscalls,
//     blocking I/O, signals, namespaces), and
//   * its user-space network stack (Ethernet/ARP/IPv4/ICMP/UDP/TCP/DNS)
//     exposed to programs through a BSD-like socket API.
//
// Explicitly OUT of scope (it belongs to the consuming app / a separate package):
//   * topology — links, switches, routers, the multi-host fabric, and any UI
//     (terminal rendering, keyboard, multi-instance views).
//
// The boundary: `NetworkNode` exposes abstract `NetworkInterface` values with
// `onEgress` (outbound frames) and `receive(_:on:)` (inbound frames). The consumer wires interfaces together
// however it likes (with latency/loss, switches, etc.) and renders terminals by
// driving a console byte-stream. See README.md.
//
// Locked decisions: real-time emulation on a clock-agnostic event loop; native
// Swift programs (no JIT/fork/exec); POSIX-semantics Swift API (not a binary
// syscall ABI); continuation-style blocking I/O. The core is pure Swift with no
// platform/UI imports, so it builds on Linux/macOS/iOS alike.
//
// PUBLIC API: the consumer-facing surface is `public` — EventLoop, Kernel,
// NetworkNode/NetworkInterface, NetworkNamespace/NetworkStack, ProcessContext, PseudoTerminal
// (+ Slave), Programs, Signal, IPv4Address, MACAddress, PacketBuffer. The
// protocol parsers, sockets, VFS, and process internals stay `internal`. See
// `Example/` for a from-another-module usage example.
//
// ── CONCURRENCY CONTRACT (Swift 6 strict concurrency) ────────────────────────
//
// Swiftix runs on ONE serial executor. Construct and drive a `Kernel` and its
// `EventLoop` from a single executor (in the simplest case, one thread), and make
// EVERY public-API call — spawning processes, wiring interfaces, feeding inbound
// frames via `receive(_:on:)`, and pumping logical time with `advance(by:)` /
// `runUntilIdle()` — from that same executor. The core is a graph of reference
// types mutated without locks; the single-executor rule, not internal locking, is
// what keeps it data-race free.
//
// Swift's non-Sendable checking helps enforce this at concurrency boundaries:
//   * Value types (IPv4Address, MACAddress, PacketBuffer, InterfaceCounters,
//     PacketDirection, Signal, SyscallError, PingOutcome) are `Sendable` — they
//     may cross isolation boundaries freely.
//   * The reference-type core (EventLoop, Kernel, NetworkNamespace, NetworkStack
//     + Interface, ProcessContext, PseudoTerminal + Slave) is deliberately
//     NON-Sendable. Swift 6 strict concurrency therefore rejects, at compile time,
//     ordinary attempts to share these across executors. Direct synchronous API
//     calls remain a caller obligation and must stay on the owning executor.
//
// The async syscall frontend and process bodies resume on the loop-bound
// `SwiftixExecutor`, so `await` never leaves the single logical thread. Because
// the whole model uses only the standard-library `_Concurrency` module (no
// Foundation / platform imports), the contract is IDENTICAL on Linux, macOS, and
// iOS. See README.md for a worked example.

public enum Swiftix: Sendable {
    /// Semantic version of the core.
    public static let version = "0.9.0"
}
