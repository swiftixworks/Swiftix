/// Tests for TCP options encode/decode (TCPOption + TCPSegment options support).
/// Validates that options round-trip through build→parse, that data offset is
/// computed correctly, and that unknown options are preserved.
import Testing
@testable import Swiftix

@Suite("TCP options")
struct TCPOptionsTests {

    // MARK: - Individual option encoding

    @Test func mssEncodesCorrectly() {
        let bytes = TCPOption.mss(1460).wireBytes
        #expect(bytes == [2, 4, 0x05, 0xB4])
    }

    @Test func windowScaleEncodesCorrectly() {
        let bytes = TCPOption.windowScale(7).wireBytes
        #expect(bytes == [3, 3, 7])
    }

    @Test func sackPermittedEncodesCorrectly() {
        let bytes = TCPOption.sackPermitted.wireBytes
        #expect(bytes == [4, 2])
    }

    @Test func timestampsEncodesCorrectly() {
        let bytes = TCPOption.timestamps(value: 0x12345678, echoReply: 0xAABBCCDD).wireBytes
        #expect(bytes == [8, 10, 0x12, 0x34, 0x56, 0x78, 0xAA, 0xBB, 0xCC, 0xDD])
    }

    @Test func sackBlockEncodesCorrectly() {
        let block = TCPOption.SACKBlock(left: 1000, right: 2000)
        let bytes = TCPOption.sack([block]).wireBytes
        #expect(bytes.count == 10)   // kind(1) + length(1) + 1 block(8)
        #expect(bytes[0] == 5)       // kind
        #expect(bytes[1] == 10)      // length
    }

    @Test func nopEncodesAsSingleByte() {
        #expect(TCPOption.nop.wireBytes == [1])
    }

    // MARK: - Parsing

    @Test func parseAllDecodesKnownOptions() {
        // NOP + MSS(1460) + Window Scale(7) + SACK Permitted + End
        let raw: [UInt8] = [
            1,          // NOP
            2, 4, 0x05, 0xB4,  // MSS 1460
            3, 3, 7,           // Window Scale 7
            4, 2,              // SACK Permitted
            0                  // End
        ]
        let options = TCPOption.parseAll(from: raw[raw.startIndex..<raw.endIndex])
        #expect(options.count == 4)
        #expect(options[0] == .nop)
        #expect(options[1] == .mss(1460))
        #expect(options[2] == .windowScale(7))
        #expect(options[3] == .sackPermitted)
    }

    @Test func parseAllHandlesTimestamps() {
        let raw: [UInt8] = [8, 10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02]
        let options = TCPOption.parseAll(from: raw[...])
        #expect(options == [.timestamps(value: 1, echoReply: 2)])
    }

    @Test func parseAllHandlesSACKBlocks() {
        // 2 blocks
        let raw: [UInt8] = [
            5, 18,   // kind=5, length=18 (2 + 2*8)
            0, 0, 0x03, 0xE8,   // left = 1000
            0, 0, 0x07, 0xD0,   // right = 2000
            0, 0, 0x0B, 0xB8,   // left = 3000
            0, 0, 0x0F, 0xA0,   // right = 4000
        ]
        let options = TCPOption.parseAll(from: raw[...])
        #expect(options.count == 1)
        if case .sack(let blocks) = options.first {
            #expect(blocks.count == 2)
            #expect(blocks[0] == TCPOption.SACKBlock(left: 1000, right: 2000))
            #expect(blocks[1] == TCPOption.SACKBlock(left: 3000, right: 4000))
        } else {
            Issue.record("expected .sack")
        }
    }

    @Test func unknownOptionPreserved() {
        // kind=99, length=5, data=[0xAA, 0xBB, 0xCC]
        let raw: [UInt8] = [99, 5, 0xAA, 0xBB, 0xCC]
        let options = TCPOption.parseAll(from: raw[...])
        #expect(options == [.unknown(kind: 99, data: [0xAA, 0xBB, 0xCC])])
    }

    // MARK: - Segment build + parse round-trip

    @Test func segmentWithNoOptionsHasDataOffset5() {
        let segment = TCPSegment.build(sourcePort: 1234,
                                       destinationPort: 80,
                                       sequence: 100,
                                       acknowledgment: 0,
                                       flags: [.syn],
                                       window: 65535,
                                       payload: [])
        // Data offset is byte 12, upper nibble.
        #expect(segment[12] >> 4 == 5)
        #expect(segment.count == 20)
    }

    @Test func segmentWithOptionsRoundTrips() {
        let options: [TCPOption] = [.mss(1460), .nop, .windowScale(7), .sackPermitted]
        let segment = TCPSegment.build(sourcePort: 1234,
                                       destinationPort: 80,
                                       sequence: 100,
                                       acknowledgment: 200,
                                       flags: [.syn, .ack],
                                       window: 32768,
                                       options: options,
                                       payload: Array("hello".utf8))
        // Options: MSS(4) + NOP(1) + WS(3) + SACK-P(2) = 10 bytes → padded to 12.
        // Total header = 20 + 12 = 32 → data offset = 8.
        let dataOffset = Int(segment[12] >> 4)
        #expect(dataOffset == 8)
        #expect(segment.count == 32 + 5)   // header + "hello"

        // Parse it back.
        guard let parsed = TCPSegment.parse(segment[...]) else {
            Issue.record("parse failed"); return
        }
        #expect(parsed.header.sourcePort == 1234)
        #expect(parsed.header.destinationPort == 80)
        #expect(parsed.header.sequence == 100)
        #expect(parsed.header.acknowledgment == 200)
        #expect(parsed.header.flags == [.syn, .ack])
        #expect(parsed.header.window == 32768)
        #expect(parsed.header.options.contains(.mss(1460)))
        #expect(parsed.header.options.contains(.windowScale(7)))
        #expect(parsed.header.options.contains(.sackPermitted))
        #expect(Array(parsed.payload) == Array("hello".utf8))
    }

    @Test func segmentWithTimestampsRoundTrips() {
        let options: [TCPOption] = [.nop, .nop, .timestamps(value: 12345, echoReply: 67890)]
        let segment = TCPSegment.build(sourcePort: 80,
                                       destinationPort: 1234,
                                       sequence: 1,
                                       acknowledgment: 1,
                                       flags: [.ack],
                                       window: 16384,
                                       options: options,
                                       payload: [])
        guard let parsed = TCPSegment.parse(segment[...]) else {
            Issue.record("parse failed"); return
        }
        #expect(parsed.header.options.contains(.timestamps(value: 12345, echoReply: 67890)))
    }

    @Test func existingSegmentsWithoutOptionsStillParse() {
        // A bare 20-byte SYN (no options) — the format Swiftix has been emitting.
        let segment = TCPSegment.build(sourcePort: 5000,
                                       destinationPort: 80,
                                       sequence: 1000,
                                       acknowledgment: 0,
                                       flags: [.syn],
                                       window: 65535,
                                       payload: [])
        guard let parsed = TCPSegment.parse(segment[...]) else {
            Issue.record("parse failed"); return
        }
        #expect(parsed.header.options.isEmpty)
        #expect(parsed.header.flags == [.syn])
        #expect(parsed.header.window == 65535)
        #expect(parsed.payload.isEmpty)
    }
}
