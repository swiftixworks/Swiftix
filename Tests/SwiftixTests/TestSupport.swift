@testable import Swiftix

/// A tiny, deterministic pseudo-random number generator (SplitMix64).
///
/// Test-only. Seeded runs are fully reproducible, which is what the congestion
/// control property-style tests rely on (log the seed, reproduce on failure).
/// Conforms to `RandomNumberGenerator` so it can drive both drop decisions and
/// random payload generation.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// A uniform Double in [0, 1).
    mutating func nextUnitDouble() -> Double {
        // Use the top 53 bits for a well-distributed double in [0, 1).
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}

/// Test-only stand-in for the topology layer (which lives OUTSIDE this library):
/// connect two stack interfaces with a one-way latency, scheduling delivery on
/// the shared event loop. In the real product the app/topology package plays
/// this role.
///
/// Data-segment loss in the A→B direction can be configured three ways (they
/// compose; a segment is dropped if any of them says so):
///   - `dropFirstTCPData`: drop exactly the first data-bearing TCP segment
///     (the original MVP behavior, preserved).
///   - `dropData`: a predicate `(segmentIndex, payloadLen) -> Bool` evaluated for
///     each data-bearing segment, where `segmentIndex` counts only data-bearing
///     segments (0-based). Lets tests drop a specific middle segment to force
///     duplicate-ACK / fast-retransmit scenarios.
///   - `dropSeed` + `dropProbability`: a deterministic, seeded pseudo-random
///     dropper for property-style loss loops. Each data-bearing segment is
///     dropped with the given probability, driven by a `SplitMix64` seeded from
///     `dropSeed` so runs are reproducible.
enum TestWire {
    static func connect(_ stackA: NetworkStack, _ ifA: NetworkStack.Interface,
                        _ stackB: NetworkStack, _ ifB: NetworkStack.Interface,
                        on loop: EventLoop, latency: Double,
                        dropFirstTCPData: Bool = false,
                        dropData: ((_ segmentIndex: Int, _ payloadLen: Int) -> Bool)? = nil,
                        dropSeed: UInt64? = nil,
                        dropProbability: Double = 0.0) {
        var dropFirstArmed = dropFirstTCPData
        var dataSegmentIndex = 0
        var prng: SplitMix64? = dropSeed.map { SplitMix64(seed: $0) }

        ifA.onEgress = { [weak stackB, weak ifB] frame in
            guard let stackB, let ifB else { return }

            if let payloadLen = tcpDataPayloadLength(frame) {
                let index = dataSegmentIndex
                dataSegmentIndex += 1

                var drop = false

                // 1) Preserve the original "drop the first data segment" behavior.
                if dropFirstArmed {
                    dropFirstArmed = false
                    drop = true
                }

                // 2) Explicit per-segment predicate.
                if !drop, let dropData, dropData(index, payloadLen) {
                    drop = true
                }

                // 3) Seeded pseudo-random dropper.
                if !drop, prng != nil, dropProbability > 0 {
                    if prng!.nextUnitDouble() < dropProbability {
                        drop = true
                    }
                }

                if drop { return }
            }

            loop.schedule(after: latency) { stackB.receive(frame, on: ifB) }
        }
        ifB.onEgress = { [weak stackA, weak ifA] frame in
            guard let stackA, let ifA else { return }
            loop.schedule(after: latency) { stackA.receive(frame, on: ifA) }
        }
    }

    /// Whether the frame carries a data-bearing TCP segment (non-empty payload).
    private static func isTCPData(_ frame: PacketBuffer) -> Bool {
        tcpDataPayloadLength(frame) != nil
    }

    /// Returns the TCP payload length if the frame is a data-bearing TCP segment,
    /// otherwise `nil` (control-only segments and non-TCP frames are not counted).
    private static func tcpDataPayloadLength(_ frame: PacketBuffer) -> Int? {
        guard let eth = EthernetFrame.parseHeader(frame), eth.etherType == EtherType.ipv4.rawValue,
              let (ipHeader, ipPayload) = IPv4Packet.parse(EthernetFrame.payload(frame)),
              ipHeader.proto == IPProtocol.tcp.rawValue,
              let (_, tcpPayload) = TCPSegment.parse(ipPayload) else { return nil }
        return tcpPayload.isEmpty ? nil : tcpPayload.count
    }
}

// MARK: - Frame capture (test-support only)

extension TestWire {
    /// Which end emitted a captured frame.
    enum Direction: Sendable, Equatable, CustomStringConvertible {
        case aToB, bToA
        var description: String { self == .aToB ? "A→B" : "B→A" }
    }

    /// One frame as it appeared on the wire, tagged with its emission direction.
    /// Bytes are copied out of the `PacketBuffer` so the record is a stable value.
    struct CapturedFrame: Sendable, Equatable {
        let direction: Direction
        let bytes: [UInt8]
    }

    /// Records every frame handed to either interface's `onEgress` (in global
    /// emission order — i.e. the on-wire frame sequence) and every frame actually
    /// delivered to each stack's `receive` (after any wire drop/corruption). Used
    /// by the cross-cutting property tests for:
    ///   - async ⇄ callback equivalence (identical `frames` sequences), and
    ///   - counter conservation (`txPackets == frames handed to onEgress`,
    ///     `rxPackets + drops == frames passed to receive`).
    ///
    /// Single-threaded by contract (mutated only from loop jobs on the one logical
    /// thread), so `@unchecked Sendable` is safe here.
    final class Capture: @unchecked Sendable {
        /// On-wire frame sequence in emission order (both directions interleaved).
        private(set) var frames: [CapturedFrame] = []
        /// Frames actually passed to `stackA.receive` / `stackB.receive`.
        private(set) var deliveredToA: [PacketBuffer] = []
        private(set) var deliveredToB: [PacketBuffer] = []

        func recordEgress(_ direction: Direction, _ frame: PacketBuffer) {
            frames.append(CapturedFrame(direction: direction, bytes: frame.bytes))
        }

        func recordDeliveredToA(_ frame: PacketBuffer) { deliveredToA.append(frame) }
        func recordDeliveredToB(_ frame: PacketBuffer) { deliveredToB.append(frame) }

        /// Count of frames handed to each interface's `onEgress` (== `txPackets`).
        var egressAtoBCount: Int { frames.lazy.filter { $0.direction == .aToB }.count }
        var egressBtoACount: Int { frames.lazy.filter { $0.direction == .bToA }.count }
    }

    /// A capturing stand-in for `connect`: records the on-wire frame sequence and
    /// per-side deliveries into `capture`, delivering each frame to the peer after
    /// `latency` on the shared loop. `interceptAtoB` may return the frame unchanged,
    /// a mutated copy (to corrupt it), or `nil` to drop it on the wire before it
    /// reaches B's `receive`; B→A is always delivered verbatim. Recording of egress
    /// happens on the sending side, so captured bytes are exactly what the stack
    /// emitted (checksums included).
    static func connectCapturing(_ stackA: NetworkStack, _ ifA: NetworkStack.Interface,
                                 _ stackB: NetworkStack, _ ifB: NetworkStack.Interface,
                                 on loop: EventLoop, latency: Double,
                                 capture: Capture,
                                 interceptAtoB: @escaping (PacketBuffer) -> PacketBuffer? = { $0 }) {
        ifA.onEgress = { [weak stackB, weak ifB] frame in
            capture.recordEgress(.aToB, frame)
            guard let stackB, let ifB else { return }
            guard let out = interceptAtoB(frame) else { return }   // nil => wire drop
            loop.schedule(after: latency) {
                capture.recordDeliveredToB(out)
                stackB.receive(out, on: ifB)
            }
        }
        ifB.onEgress = { [weak stackA, weak ifA] frame in
            capture.recordEgress(.bToA, frame)
            guard let stackA, let ifA else { return }
            loop.schedule(after: latency) {
                capture.recordDeliveredToA(frame)
                stackA.receive(frame, on: ifA)
            }
        }
    }
}
