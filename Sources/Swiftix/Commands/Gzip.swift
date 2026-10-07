/// gzip container (RFC 1952), DEFLATE decoder (RFC 1951), and CRC-32 for the
/// archive built-ins (`tar -z`, `gzip`, `gunzip`, `zcat`).
///
/// Reading is complete: stored, fixed-Huffman, and dynamic-Huffman blocks,
/// optional header fields (FEXTRA / FNAME / FCOMMENT / FHCRC), concatenated
/// members, and the CRC-32 + ISIZE trailer check. Writing deliberately emits
/// DEFLATE *stored* blocks only — a valid gzip stream any real `gunzip` reads,
/// with no compression — because a match finder and Huffman encoder would be a
/// lot of code for a simulated node whose files live in memory anyway.
///
/// Concurrency: pure functions over value types; the only shared state is the
/// immutable CRC table.

enum Gzip {

    enum Failure: Error, Equatable {
        /// The input does not start with the gzip magic / deflate method.
        case notGzip
        /// The stream ended before the deflate data or trailer was complete.
        case unexpectedEnd
        /// The deflate stream is malformed (bad block type, code, or distance).
        case invalidData
        /// The trailer CRC-32 does not match the decompressed bytes.
        case crcMismatch
        /// The trailer length does not match the decompressed byte count.
        case lengthMismatch

        /// The text `gzip` prints after `gzip: name: `.
        var message: String {
            switch self {
            case .notGzip: return "not in gzip format"
            case .unexpectedEnd: return "unexpected end of file"
            case .invalidData: return "invalid compressed data--format violated"
            case .crcMismatch: return "invalid compressed data--crc error"
            case .lengthMismatch: return "invalid compressed data--length error"
            }
        }
    }

    /// Whether `data` begins with the gzip magic number.
    static func hasMagic(_ data: [UInt8]) -> Bool {
        data.count >= 2 && data[0] == 0x1F && data[1] == 0x8B
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    /// CRC-32 (IEEE 802.3, reflected) of `data`.
    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        crcTable.withUnsafeBufferPointer { table in
            data.withUnsafeBufferPointer { bytes in
                for byte in bytes {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return ~crc
    }

    // MARK: - Writing (stored blocks)

    /// Wrap `data` in a gzip member whose deflate stream consists of stored
    /// (uncompressed) blocks.
    static func compressStored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]
        out.reserveCapacity(data.count + data.count / 65535 * 5 + 32)
        var offset = 0
        repeat {
            let length = Swift.min(65535, data.count - offset)
            let isFinal = offset + length == data.count
            out.append(isFinal ? 0x01 : 0x00)
            out.append(UInt8(length & 0xFF))
            out.append(UInt8(length >> 8))
            out.append(UInt8(~length & 0xFF))
            out.append(UInt8((~length >> 8) & 0xFF))
            out.append(contentsOf: data[offset..<(offset + length)])
            offset += length
        } while offset < data.count
        appendLittleEndian(&out, crc32(data))
        appendLittleEndian(&out, UInt32(truncatingIfNeeded: data.count))
        return out
    }

    private static func appendLittleEndian(_ out: inout [UInt8], _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            out.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    // MARK: - Reading

    /// Decompress a gzip stream (one or more concatenated members; trailing
    /// zero padding, as left by tape-style blocking, is ignored).
    static func decompress(_ data: [UInt8]) throws -> [UInt8] {
        guard hasMagic(data) else { throw Failure.notGzip }
        var out: [UInt8] = []
        var position = 0
        while position + 1 < data.count, data[position] == 0x1F, data[position + 1] == 0x8B {
            position = try skipHeader(data, at: position)
            let memberStart = out.count
            var reader = BitReader(data: data, position: position)
            try inflate(&reader, into: &out)
            position = reader.byteAlignedPosition
            guard position + 8 <= data.count else { throw Failure.unexpectedEnd }
            let crc = littleEndian(data, position)
            let size = littleEndian(data, position + 4)
            position += 8
            let member = memberStart == 0 ? out : Array(out[memberStart...])
            guard crc32(member) == crc else { throw Failure.crcMismatch }
            guard UInt32(truncatingIfNeeded: member.count) == size else { throw Failure.lengthMismatch }
        }
        return out
    }

    private static func littleEndian(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    /// Validate the member header at `start` and return the offset of the
    /// deflate data.
    private static func skipHeader(_ data: [UInt8], at start: Int) throws -> Int {
        guard start + 10 <= data.count else { throw Failure.unexpectedEnd }
        guard data[start + 2] == 8 else { throw Failure.notGzip }
        let flags = data[start + 3]
        var position = start + 10
        if flags & 0x04 != 0 {                       // FEXTRA
            guard position + 2 <= data.count else { throw Failure.unexpectedEnd }
            position += 2 + Int(data[position]) + Int(data[position + 1]) << 8
        }
        for bit in [UInt8(0x08), 0x10] where flags & bit != 0 {   // FNAME, FCOMMENT
            while true {
                guard position < data.count else { throw Failure.unexpectedEnd }
                position += 1
                if data[position - 1] == 0 { break }
            }
        }
        if flags & 0x02 != 0 { position += 2 }       // FHCRC
        guard position <= data.count else { throw Failure.unexpectedEnd }
        return position
    }

    // MARK: - Inflate

    /// LSB-first bit cursor over the compressed bytes.
    private struct BitReader {
        let data: [UInt8]
        var position: Int
        var bitBuffer: UInt32 = 0
        var bitCount = 0

        init(data: [UInt8], position: Int) {
            self.data = data
            self.position = position
        }

        mutating func bits(_ count: Int) throws -> Int {
            while bitCount < count {
                guard position < data.count else { throw Failure.unexpectedEnd }
                bitBuffer |= UInt32(data[position]) << UInt32(bitCount)
                position += 1
                bitCount += 8
            }
            let value = Int(bitBuffer & ((1 << UInt32(count)) - 1))
            bitBuffer >>= UInt32(count)
            bitCount -= count
            return value
        }

        mutating func bit() throws -> Int {
            if bitCount == 0 {
                guard position < data.count else { throw Failure.unexpectedEnd }
                bitBuffer = UInt32(data[position])
                position += 1
                bitCount = 8
            }
            let value = Int(bitBuffer & 1)
            bitBuffer >>= 1
            bitCount -= 1
            return value
        }

        /// Drop the bits left in the current byte (stored blocks start on a
        /// byte boundary).
        mutating func alignToByte() {
            let whole = bitCount / 8
            position -= whole
            bitBuffer = 0
            bitCount = 0
        }

        /// The offset of the first byte not consumed by the bit cursor.
        var byteAlignedPosition: Int { position - bitCount / 8 }
    }

    /// A canonical Huffman code: `counts[n]` codes of length `n`, with the
    /// symbols listed in code order.
    private struct HuffmanCode {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]

        /// Build from per-symbol code lengths. Throws when the lengths
        /// over-subscribe the code space; an incomplete code is allowed (a
        /// single distance code is legal), and an unused code fails at decode.
        init(lengths: [Int]) throws {
            symbols = [Int](repeating: 0, count: lengths.count)
            for length in lengths { counts[length] += 1 }
            counts[0] = 0
            var left = 1
            for length in 1..<16 {
                left <<= 1
                left -= counts[length]
                if left < 0 { throw Failure.invalidData }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }

        func decode(_ reader: inout BitReader) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for length in 1..<16 {
                code |= try reader.bit()
                let count = counts[length]
                if code - count < first { return symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.invalidData
        }
    }

    private static let lengthBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    private static let lengthExtra: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    private static let distanceBase: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    ]
    private static let distanceExtra: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]
    private static let codeLengthOrder: [Int] = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]

    /// Decode one complete deflate stream, appending to `out`. Back-references
    /// never reach before `out.count` at entry (each gzip member has its own
    /// window).
    private static func inflate(_ reader: inout BitReader, into out: inout [UInt8]) throws {
        let windowStart = out.count
        var isFinal = false
        while !isFinal {
            isFinal = try reader.bits(1) == 1
            let type = try reader.bits(2)
            if type == 0 {
                reader.alignToByte()
                let data = reader.data
                guard reader.position + 4 <= data.count else { throw Failure.unexpectedEnd }
                let length = Int(data[reader.position]) | Int(data[reader.position + 1]) << 8
                let inverse = Int(data[reader.position + 2]) | Int(data[reader.position + 3]) << 8
                guard length == (~inverse & 0xFFFF) else { throw Failure.invalidData }
                reader.position += 4
                guard reader.position + length <= data.count else { throw Failure.unexpectedEnd }
                out.append(contentsOf: data[reader.position..<(reader.position + length)])
                reader.position += length
            } else if type == 1 {
                var lengths = [Int](repeating: 8, count: 288)
                for symbol in 144..<256 { lengths[symbol] = 9 }
                for symbol in 256..<280 { lengths[symbol] = 7 }
                let literals = try HuffmanCode(lengths: lengths)
                let distances = try HuffmanCode(lengths: [Int](repeating: 5, count: 30))
                try inflateBlock(&reader, literals, distances, windowStart, &out)
            } else if type == 2 {
                let literalCount = try reader.bits(5) + 257
                let distanceCount = try reader.bits(5) + 1
                let codeLengthCount = try reader.bits(4) + 4
                guard literalCount <= 286, distanceCount <= 30 else { throw Failure.invalidData }
                var codeLengths = [Int](repeating: 0, count: 19)
                for index in 0..<codeLengthCount {
                    codeLengths[codeLengthOrder[index]] = try reader.bits(3)
                }
                let lengthCode = try HuffmanCode(lengths: codeLengths)
                var lengths: [Int] = []
                lengths.reserveCapacity(literalCount + distanceCount)
                while lengths.count < literalCount + distanceCount {
                    let symbol = try lengthCode.decode(&reader)
                    if symbol < 16 {
                        lengths.append(symbol)
                        continue
                    }
                    var value = 0
                    var repeatCount: Int
                    if symbol == 16 {
                        guard let last = lengths.last else { throw Failure.invalidData }
                        value = last
                        repeatCount = 3 + (try reader.bits(2))
                    } else if symbol == 17 {
                        repeatCount = 3 + (try reader.bits(3))
                    } else {
                        repeatCount = 11 + (try reader.bits(7))
                    }
                    guard lengths.count + repeatCount <= literalCount + distanceCount else {
                        throw Failure.invalidData
                    }
                    while repeatCount > 0 {
                        lengths.append(value)
                        repeatCount -= 1
                    }
                }
                guard lengths[256] != 0 else { throw Failure.invalidData }
                let literals = try HuffmanCode(lengths: Array(lengths[..<literalCount]))
                let distances = try HuffmanCode(lengths: Array(lengths[literalCount...]))
                try inflateBlock(&reader, literals, distances, windowStart, &out)
            } else {
                throw Failure.invalidData
            }
        }
    }

    private static func inflateBlock(_ reader: inout BitReader,
                                     _ literals: HuffmanCode,
                                     _ distances: HuffmanCode,
                                     _ windowStart: Int,
                                     _ out: inout [UInt8]) throws {
        while true {
            let symbol = try literals.decode(&reader)
            if symbol < 256 {
                out.append(UInt8(symbol))
                continue
            }
            if symbol == 256 { return }
            let lengthIndex = symbol - 257
            guard lengthIndex < lengthBase.count else { throw Failure.invalidData }
            let length = lengthBase[lengthIndex] + (try reader.bits(lengthExtra[lengthIndex]))
            let distanceSymbol = try distances.decode(&reader)
            guard distanceSymbol < distanceBase.count else { throw Failure.invalidData }
            let distance = distanceBase[distanceSymbol] + (try reader.bits(distanceExtra[distanceSymbol]))
            guard distance <= out.count - windowStart else { throw Failure.invalidData }
            var source = out.count - distance
            // Byte-at-a-time so an overlapping copy (distance < length) repeats
            // the bytes it has just produced.
            for _ in 0..<length {
                out.append(out[source])
                source += 1
            }
        }
    }
}
