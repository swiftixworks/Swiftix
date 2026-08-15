/// TCP connection states (RFC 793 / 9293).
enum TCPState {
    case closed
    case listen
    case synSent
    case synReceived
    case established
    case finWait1
    case finWait2
    case closeWait
    case closing
    case lastAck
    case timeWait
}

/// TCP options (RFC 793 / 1323 / 2018 / 7323). Each case represents a parsed
/// option that Swiftix understands. Unknown options are preserved as raw bytes
/// so they can be round-tripped without loss.
enum TCPOption: Equatable {
    /// A SACK block: a contiguous received byte range [left, right).
    struct SACKBlock: Equatable {
        let left: UInt32
        let right: UInt32
    }

    /// Maximum Segment Size (kind 2, length 4). Advertised on SYN only.
    case mss(UInt16)
    /// Window Scale (kind 3, length 3). Advertised on SYN only. Shift count 0–14.
    case windowScale(UInt8)
    /// SACK Permitted (kind 4, length 2). Advertised on SYN only.
    case sackPermitted
    /// Selective Acknowledgment (kind 5, variable length).
    case sack([SACKBlock])
    /// Timestamps (kind 8, length 10). TSval and TSecr.
    case timestamps(value: UInt32, echoReply: UInt32)
    /// No-Operation padding (kind 1). Used to align options to 4-byte boundaries.
    case nop
    /// Unknown option preserved as raw bytes (kind, data excluding kind+length).
    case unknown(kind: UInt8, data: [UInt8])

    // MARK: - Wire format constants

    static let kindEnd: UInt8 = 0
    static let kindNOP: UInt8 = 1
    static let kindMSS: UInt8 = 2
    static let kindWindowScale: UInt8 = 3
    static let kindSACKPermitted: UInt8 = 4
    static let kindSACK: UInt8 = 5
    static let kindTimestamps: UInt8 = 8

    /// Encode this option to wire bytes (kind + length + data). NOP is a single
    /// byte; End-of-Options is not encoded here (handled by the padding logic).
    var wireBytes: [UInt8] {
        switch self {
        case .nop:
            return [Self.kindNOP]
        case .mss(let value):
            return [Self.kindMSS, 4,
                    UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        case .windowScale(let shift):
            return [Self.kindWindowScale, 3, shift]
        case .sackPermitted:
            return [Self.kindSACKPermitted, 2]
        case .sack(let blocks):
            let length = UInt8(2 + blocks.count * 8)
            var bytes: [UInt8] = [Self.kindSACK, length]
            for block in blocks {
                bytes.append(UInt8((block.left >> 24) & 0xFF))
                bytes.append(UInt8((block.left >> 16) & 0xFF))
                bytes.append(UInt8((block.left >> 8) & 0xFF))
                bytes.append(UInt8(block.left & 0xFF))
                bytes.append(UInt8((block.right >> 24) & 0xFF))
                bytes.append(UInt8((block.right >> 16) & 0xFF))
                bytes.append(UInt8((block.right >> 8) & 0xFF))
                bytes.append(UInt8(block.right & 0xFF))
            }
            return bytes
        case .timestamps(let value, let echoReply):
            return [Self.kindTimestamps, 10,
                    UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                    UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
                    UInt8((echoReply >> 24) & 0xFF), UInt8((echoReply >> 16) & 0xFF),
                    UInt8((echoReply >> 8) & 0xFF), UInt8(echoReply & 0xFF)]
        case .unknown(let kind, let data):
            if data.isEmpty { return [kind] }
            return [kind, UInt8(2 + data.count)] + data
        }
    }

    /// Parse all options from a raw option bytes region. Returns an array of
    /// parsed options; stops at End-of-Options (kind 0) or when bytes are
    /// exhausted.
    static func parseAll(from bytes: ArraySlice<UInt8>) -> [TCPOption] {
        var options: [TCPOption] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let kind = bytes[index]
            if kind == kindEnd { break }
            if kind == kindNOP {
                options.append(.nop)
                index += 1
                continue
            }
            // All other options have a length byte at index+1.
            guard index + 1 < bytes.endIndex else { break }
            let length = Int(bytes[index + 1])
            guard length >= 2, index + length <= bytes.endIndex else { break }
            let optionData = bytes[(index + 2)..<(index + length)]
            switch kind {
            case kindMSS where length == 4:
                let value = (UInt16(optionData[optionData.startIndex]) << 8)
                          | UInt16(optionData[optionData.startIndex + 1])
                options.append(.mss(value))
            case kindWindowScale where length == 3:
                options.append(.windowScale(optionData[optionData.startIndex]))
            case kindSACKPermitted where length == 2:
                options.append(.sackPermitted)
            case kindSACK where length >= 10 && (length - 2) % 8 == 0:
                var blocks: [SACKBlock] = []
                var bi = optionData.startIndex
                while bi + 8 <= optionData.endIndex {
                    let left = (UInt32(optionData[bi]) << 24) | (UInt32(optionData[bi+1]) << 16)
                             | (UInt32(optionData[bi+2]) << 8) | UInt32(optionData[bi+3])
                    let right = (UInt32(optionData[bi+4]) << 24) | (UInt32(optionData[bi+5]) << 16)
                              | (UInt32(optionData[bi+6]) << 8) | UInt32(optionData[bi+7])
                    blocks.append(SACKBlock(left: left, right: right))
                    bi += 8
                }
                options.append(.sack(blocks))
            case kindTimestamps where length == 10:
                let base = optionData.startIndex
                let value = (UInt32(optionData[base]) << 24) | (UInt32(optionData[base+1]) << 16)
                          | (UInt32(optionData[base+2]) << 8) | UInt32(optionData[base+3])
                let echoReply = (UInt32(optionData[base+4]) << 24) | (UInt32(optionData[base+5]) << 16)
                              | (UInt32(optionData[base+6]) << 8) | UInt32(optionData[base+7])
                options.append(.timestamps(value: value, echoReply: echoReply))
            default:
                options.append(.unknown(kind: kind, data: Array(optionData)))
            }
            index += length
        }
        return options
    }
}

/// TCP segment build/parse. Supports variable-length headers (options). Checksum
/// is set to 0 on build and not enforced on parse (consistent with the rest of
/// the young stack — internal segments are never dropped over a checksum bug).
enum TCPSegment {
    /// Minimum header length (no options).
    static let headerLength = 20

    struct Flags: OptionSet, Equatable, Sendable {
        let rawValue: UInt8
        static let fin = Flags(rawValue: 0x01)
        static let syn = Flags(rawValue: 0x02)
        static let rst = Flags(rawValue: 0x04)
        static let psh = Flags(rawValue: 0x08)
        static let ack = Flags(rawValue: 0x10)
        static let ece = Flags(rawValue: 0x40)  // ECN-Echo (RFC 3168)
        static let cwr = Flags(rawValue: 0x80)  // Congestion Window Reduced (RFC 3168)
    }

    struct Header {
        let sourcePort: UInt16
        let destinationPort: UInt16
        let sequence: UInt32
        let acknowledgment: UInt32
        let flags: Flags
        let window: UInt16
        /// Parsed options (empty when no options present).
        let options: [TCPOption]

        init(sourcePort: UInt16,
             destinationPort: UInt16,
             sequence: UInt32,
             acknowledgment: UInt32,
             flags: Flags,
             window: UInt16,
             options: [TCPOption] = []) {
            self.sourcePort = sourcePort
            self.destinationPort = destinationPort
            self.sequence = sequence
            self.acknowledgment = acknowledgment
            self.flags = flags
            self.window = window
            self.options = options
        }
    }

    /// Build a TCP segment with optional TCP options. Options are serialized after
    /// the fixed 20-byte header and padded to a 4-byte boundary with NOP/End. The
    /// data offset field reflects the total header length.
    static func build(sourcePort: UInt16,
                      destinationPort: UInt16,
                      sequence: UInt32,
                      acknowledgment: UInt32,
                      flags: Flags,
                      window: UInt16,
                      options: [TCPOption] = [],
                      payload: [UInt8]) -> [UInt8] {
        // Serialize options.
        var optionBytes: [UInt8] = []
        for option in options {
            optionBytes.append(contentsOf: option.wireBytes)
        }
        // Pad to 4-byte boundary.
        let remainder = optionBytes.count % 4
        if remainder != 0 {
            optionBytes.append(contentsOf: [UInt8](repeating: 0, count: 4 - remainder))
        }
        let totalHeaderLength = headerLength + optionBytes.count
        let dataOffsetValue = UInt8(totalHeaderLength / 4)

        var bytes = [UInt8](repeating: 0, count: totalHeaderLength + payload.count)
        bytes[0] = UInt8((sourcePort >> 8) & 0xFF); bytes[1] = UInt8(sourcePort & 0xFF)
        bytes[2] = UInt8((destinationPort >> 8) & 0xFF); bytes[3] = UInt8(destinationPort & 0xFF)
        bytes[4] = UInt8((sequence >> 24) & 0xFF); bytes[5] = UInt8((sequence >> 16) & 0xFF)
        bytes[6] = UInt8((sequence >> 8) & 0xFF); bytes[7] = UInt8(sequence & 0xFF)
        bytes[8] = UInt8((acknowledgment >> 24) & 0xFF); bytes[9] = UInt8((acknowledgment >> 16) & 0xFF)
        bytes[10] = UInt8((acknowledgment >> 8) & 0xFF); bytes[11] = UInt8(acknowledgment & 0xFF)
        bytes[12] = (dataOffsetValue << 4)    // data offset + reserved
        bytes[13] = flags.rawValue
        bytes[14] = UInt8((window >> 8) & 0xFF); bytes[15] = UInt8(window & 0xFF)
        // checksum (16-17) = 0; urgent pointer (18-19) = 0
        // Copy options into the header.
        for i in 0..<optionBytes.count {
            bytes[headerLength + i] = optionBytes[i]
        }
        bytes.replaceSubrange(totalHeaderLength..., with: payload)
        return bytes
    }

    /// Parse a TCP segment, decoding any options present in the header. The
    /// returned `Header.options` array is empty when data offset equals 5 (no
    /// options). Unknown options are preserved as `.unknown` so higher layers can
    /// inspect them if needed.
    static func parse(_ bytes: ArraySlice<UInt8>) -> (header: Header, payload: ArraySlice<UInt8>)? {
        let base = bytes.startIndex
        guard bytes.count >= headerLength else { return nil }
        let sourcePort = (UInt16(bytes[base]) << 8) | UInt16(bytes[base + 1])
        let destinationPort = (UInt16(bytes[base + 2]) << 8) | UInt16(bytes[base + 3])
        let sequence = (UInt32(bytes[base + 4]) << 24) | (UInt32(bytes[base + 5]) << 16)
                     | (UInt32(bytes[base + 6]) << 8) | UInt32(bytes[base + 7])
        let acknowledgment = (UInt32(bytes[base + 8]) << 24) | (UInt32(bytes[base + 9]) << 16)
                           | (UInt32(bytes[base + 10]) << 8) | UInt32(bytes[base + 11])
        let dataOffset = Int(bytes[base + 12] >> 4) * 4
        guard dataOffset >= headerLength, bytes.count >= dataOffset else { return nil }
        let flags = Flags(rawValue: bytes[base + 13])
        let window = (UInt16(bytes[base + 14]) << 8) | UInt16(bytes[base + 15])

        // Parse options from the region between the fixed header and data offset.
        let options: [TCPOption]
        if dataOffset > headerLength {
            let optionRegion = bytes[(base + headerLength)..<(base + dataOffset)]
            options = TCPOption.parseAll(from: optionRegion)
        } else {
            options = []
        }

        let header = Header(sourcePort: sourcePort,
                            destinationPort: destinationPort,
                            sequence: sequence,
                            acknowledgment: acknowledgment,
                            flags: flags,
                            window: window,
                            options: options)
        return (header, bytes[(base + dataOffset)..<bytes.endIndex])
    }
}


// MARK: - Option query helpers

extension Array where Element == TCPOption {
    /// Extract the Window Scale shift count from this option list, if present.
    var firstWindowScale: UInt8? {
        for option in self {
            if case .windowScale(let shift) = option { return shift }
        }
        return nil
    }

    /// Extract the MSS value from this option list, if present.
    var firstMSS: UInt16? {
        for option in self {
            if case .mss(let value) = option { return value }
        }
        return nil
    }

    /// Whether this option list includes SACK Permitted.
    var hasSACKPermitted: Bool {
        contains(.sackPermitted)
    }
}
