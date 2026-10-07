import Testing
@testable import Swiftix

/// The pure-Swift MD5 / SHA-1 / SHA-256 implementations, checked against the
/// RFC 1321 and NIST FIPS 180 published vectors, plus the padding boundaries
/// where a one-shot block driver is most likely to be wrong.
@Suite("Message digests")
struct DigestTests {

    private func md5(_ text: String) -> String { Digest.hex(Digest.md5(Array(text.utf8))) }
    private func sha1(_ text: String) -> String { Digest.hex(Digest.sha1(Array(text.utf8))) }
    private func sha256(_ text: String) -> String { Digest.hex(Digest.sha256(Array(text.utf8))) }

    private let message448 = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"

    @Test func emptyInput() {
        #expect(md5("") == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(sha1("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func abc() {
        #expect(md5("abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(sha1("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// The 448-bit message: its padding spills into a second block.
    @Test func twoBlockMessage() {
        #expect(md5(message448) == "8215ef0796a20bcaaae116d3876c664a")
        #expect(sha1(message448) == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        #expect(sha256(message448) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func millionLetterA() {
        let data = [UInt8](repeating: 0x61, count: 1_000_000)
        #expect(Digest.hex(Digest.md5(data)) == "7707d6ae4e027c70eea2a935c2296f21")
        #expect(Digest.hex(Digest.sha1(data)) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
        #expect(Digest.hex(Digest.sha256(data))
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func rfc1321Suite() {
        #expect(md5("a") == "0cc175b9c0f1b6a831c399e269772661")
        #expect(md5("message digest") == "f96b697d7cb7938d525a2f31aaf161d0")
        #expect(md5("abcdefghijklmnopqrstuvwxyz") == "c3fcd3d76192e4007dfb496cca67e13b")
        #expect(md5("12345678901234567890123456789012345678901234567890123456789012345678901234567890")
                == "57edf4a22be3c955ac49da2e2107b67a")
    }

    @Test func wellKnownSentence() {
        let text = "The quick brown fox jumps over the lazy dog"
        #expect(md5(text) == "9e107d9d372bb6826bd81d3542a419d6")
        #expect(sha1(text) == "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
        #expect(sha256(text) == "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
    }

    /// Lengths around the 55/56/64-byte padding boundaries must each produce a
    /// distinct, stable digest of the right size, and agree with hashing the
    /// same bytes held in a differently-shaped (sliced) buffer.
    @Test func paddingBoundariesAreConsistent() {
        var seen: Set<String> = []
        for length in [0, 1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129] {
            let data = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            let padded = [0xEE] + data + [0xEE]
            let sliced = Array(padded[1..<(padded.count - 1)])
            for algorithm in [Digest.Algorithm.md5, .sha1, .sha256] {
                let digest = algorithm.hash(data)
                #expect(digest.count * 2 == algorithm.hexLength)
                #expect(digest == algorithm.hash(sliced))
                #expect(seen.insert("\(algorithm):" + Digest.hex(digest)).inserted)
            }
        }
    }

    @Test func hexRendering() {
        #expect(Digest.hex([0x00, 0x0F, 0xA5, 0xFF]) == "000fa5ff")
        #expect(Digest.hex([]) == "")
    }
}
