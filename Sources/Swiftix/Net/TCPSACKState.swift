/// Receiver-side SACK state: tracks out-of-order segments and generates SACK
/// blocks for inclusion in outgoing ACKs (RFC 2018). Also provides reassembly:
/// when in-order data fills a gap, buffered out-of-order bytes can be delivered
/// and rcvNxt advanced past the cached ranges.
///
/// Sender-side: marks retransmit queue entries as SACKed so fast retransmit only
/// resends segments NOT covered by SACK blocks.
struct TCPSACKReceiver {
    /// An out-of-order segment cached for reassembly.
    private struct CachedSegment {
        let sequence: UInt32
        let data: [UInt8]
        var endSequence: UInt32 { sequence &+ UInt32(data.count) }
    }

    /// Out-of-order segments sorted by sequence number.
    private var outOfOrder: [CachedSegment] = []

    /// Whether SACK was negotiated (both sides sent SACK-Permitted in the SYN).
    var enabled = false

    /// Cache an out-of-order segment for later reassembly.
    mutating func cacheOutOfOrder(sequence: UInt32, data: [UInt8]) {
        guard !data.isEmpty else { return }
        // Insert maintaining sorted order; merge overlapping/adjacent entries.
        let segment = CachedSegment(sequence: sequence, data: data)
        outOfOrder.append(segment)
        outOfOrder.sort { !TCPSequence.greater($0.sequence, than: $1.sequence) && $0.sequence != $1.sequence }
        merge()
    }

    /// After rcvNxt advances (in-order data received), try to reassemble buffered
    /// out-of-order segments that now start at or before rcvNxt. Returns the
    /// reassembled bytes and the new rcvNxt.
    mutating func reassemble(rcvNxt: UInt32) -> (data: [UInt8], newRcvNxt: UInt32) {
        var current = rcvNxt
        var assembled: [UInt8] = []
        while let idx = outOfOrder.firstIndex(where: {
            !TCPSequence.greater($0.sequence, than: current)
        }) {
            let seg = outOfOrder[idx]
            // How much of this segment is new (starts after current)?
            let overlap = Int(current &- seg.sequence)
            if overlap < seg.data.count {
                assembled.append(contentsOf: seg.data.dropFirst(overlap))
                current = current &+ UInt32(seg.data.count - overlap)
            }
            outOfOrder.remove(at: idx)
        }
        return (assembled, current)
    }

    /// Generate SACK blocks to include in an outgoing ACK. Returns up to 3 blocks
    /// (limited to keep option space reasonable). Each block is [left, right)
    /// representing a contiguous received range above rcvNxt.
    func sackBlocks(rcvNxt: UInt32) -> [TCPOption.SACKBlock] {
        guard enabled, !outOfOrder.isEmpty else { return [] }
        var blocks: [TCPOption.SACKBlock] = []
        for seg in outOfOrder where TCPSequence.greater(seg.sequence, than: rcvNxt) {
            let block = TCPOption.SACKBlock(left: seg.sequence, right: seg.endSequence)
            // Merge with previous if adjacent.
            if let last = blocks.last, last.right == block.left {
                blocks[blocks.count - 1] = TCPOption.SACKBlock(left: last.left, right: block.right)
            } else {
                blocks.append(block)
            }
            if blocks.count >= 3 { break }
        }
        return blocks
    }

    var hasOutOfOrderData: Bool { !outOfOrder.isEmpty }

    /// Merge overlapping or adjacent cached segments.
    private mutating func merge() {
        guard outOfOrder.count > 1 else { return }
        var merged: [CachedSegment] = [outOfOrder[0]]
        for i in 1..<outOfOrder.count {
            let current = outOfOrder[i]
            let last = merged[merged.count - 1]
            // If current starts at or before the end of last, merge.
            if !TCPSequence.greater(current.sequence, than: last.endSequence) {
                let overlap = Int(last.endSequence &- current.sequence)
                if overlap < current.data.count {
                    let combined = Array(last.data) + Array(current.data.dropFirst(overlap))
                    merged[merged.count - 1] = CachedSegment(sequence: last.sequence, data: combined)
                }
                // else current is entirely within last, drop it.
            } else {
                merged.append(current)
            }
        }
        outOfOrder = merged
    }
}

// MARK: - Sender-side SACK processing

extension TCPSACKReceiver {
    /// Mark retransmit queue entries as SACKed based on incoming SACK blocks.
    /// Entries whose byte range is fully covered by a SACK block are marked so
    /// fast retransmit skips them. Returns whether any new entries were marked.
    @discardableResult
    static func markSacked(retransmitQueue: inout [TCPOutgoingSegment],
                           sackBlocks: [TCPOption.SACKBlock]) -> Bool {
        guard !sackBlocks.isEmpty, !retransmitQueue.isEmpty else { return false }
        var anyMarked = false
        for i in 0..<retransmitQueue.count {
            let seg = retransmitQueue[i]
            let segEnd = seg.sequence &+ UInt32(seg.payload.count)
            for block in sackBlocks {
                // Segment is fully within this SACK block.
                if !TCPSequence.greater(block.left, than: seg.sequence)
                    && !TCPSequence.greater(segEnd, than: block.right) {
                    if !retransmitQueue[i].sacked {
                        retransmitQueue[i].sacked = true
                        anyMarked = true
                    }
                    break
                }
            }
        }
        return anyMarked
    }
}
