import Testing
@testable import Swiftix

/// The binary-data built-ins (`cmp`, `dd`, `base64`, `od`, `xxd`, `hexdump`,
/// `strings`, `split`, `md5sum`, `sha1sum`, `sha256sum`), driven through a real
/// shell. Output formats are part of the contract (scripts parse them), so each
/// command's stdout / stderr / exit status is redirected into the VFS and
/// compared exactly.
@Suite("Binary-data commands")
struct BinaryCommandsTests {

    // MARK: - cmp

    @Test func cmpIdenticalFilesIsSilentAndExitsZero() {
        let shell = Shell()
        shell.write("/a", "one\ntwo\n")
        shell.write("/b", "one\ntwo\n")
        let result = shell.capture("cmp /a /b")
        #expect(result.out == "")
        #expect(result.err == "")
        #expect(result.status == 0)
    }

    @Test func cmpReportsFirstDifferenceWithByteAndLine() {
        let shell = Shell()
        shell.write("/a", "one\ntwo\nthree\n")
        shell.write("/b", "one\ntwo\nthrEe\n")
        let result = shell.capture("cmp /a /b")
        #expect(result.out == "/a /b differ: byte 12, line 3\n")
        #expect(result.status == 1)
    }

    @Test func cmpReportsEndOfFileOnTheShorterOperand() {
        let shell = Shell()
        shell.write("/a", "abc")
        shell.write("/b", "abcdef")
        let result = shell.capture("cmp /a /b")
        #expect(result.out == "")
        #expect(result.err == "cmp: EOF on /a after byte 3\n")
        #expect(result.status == 1)
    }

    @Test func cmpSilentOnlySetsTheStatus() {
        let shell = Shell()
        shell.write("/a", "abc")
        shell.write("/b", "abd")
        let result = shell.capture("cmp -s /a /b")
        #expect(result.out == "")
        #expect(result.err == "")
        #expect(result.status == 1)
    }

    @Test func cmpVerboseListsEveryDifferingByteInOctal() {
        let shell = Shell()
        shell.write("/a", "abcdefghijkl")
        shell.write("/b", "abXdefghijkY")
        let result = shell.capture("cmp -l /a /b")
        // Byte numbers are right-aligned to the width of the common length (12).
        #expect(result.out == " 3 143 130\n12 154 131\n")
        #expect(result.status == 1)
    }

    @Test func cmpReadsStandardInputForDash() {
        let shell = Shell()
        shell.write("/a", "same\n")
        #expect(shell.capture("echo same | cmp - /a").status == 0)
        #expect(shell.capture("echo diff | cmp /a -").out == "/a - differ: byte 1, line 1\n")
    }

    @Test func cmpMissingFileExitsTwo() {
        let shell = Shell()
        shell.write("/a", "x")
        let result = shell.capture("cmp /a /missing")
        #expect(result.err == "cmp: /missing: No such file or directory\n")
        #expect(result.status == 2)
    }

    // MARK: - dd

    @Test func ddCopiesAFileAndReportsRecords() {
        let shell = Shell()
        shell.write("/in", [UInt8](repeating: 0x41, count: 1300))
        let result = shell.capture("dd if=/in of=/out")
        #expect(shell.bytes(of: "/out") == [UInt8](repeating: 0x41, count: 1300))
        #expect(result.out == "")
        #expect(result.err == "2+1 records in\n2+1 records out\n1300 bytes copied\n")
        #expect(result.status == 0)
    }

    @Test func ddHonorsBlockSizeCountAndSkip() {
        let shell = Shell()
        shell.write("/in", "0123456789abcdefghij")
        let result = shell.capture("dd if=/in of=/out bs=4 skip=1 count=2")
        #expect(shell.text(of: "/out") == "456789ab")
        #expect(result.err == "2+0 records in\n2+0 records out\n8 bytes copied\n")
    }

    @Test func ddUsesStandardStreamsByDefault() {
        let shell = Shell()
        let result = shell.capture("echo hello | dd status=none")
        #expect(result.out == "hello\n")
        #expect(result.err == "")
    }

    @Test func ddSeekWithNotruncOverwritesInPlace() {
        let shell = Shell()
        shell.write("/in", "XY")
        shell.write("/out", "0123456789")
        _ = shell.capture("dd if=/in of=/out bs=1 seek=3 conv=notrunc")
        #expect(shell.text(of: "/out") == "012XY56789")
    }

    @Test func ddSeekWithoutNotruncTruncatesAtTheSeekOffset() {
        let shell = Shell()
        shell.write("/in", "XY")
        shell.write("/out", "0123456789")
        _ = shell.capture("dd if=/in of=/out bs=1 seek=3")
        #expect(shell.text(of: "/out") == "012XY")
    }

    @Test func ddSeekPastTheEndZeroFills() {
        let shell = Shell()
        shell.write("/in", "Z")
        _ = shell.capture("dd if=/in of=/out bs=2 seek=2 status=none")
        #expect(shell.bytes(of: "/out") == [0, 0, 0, 0, 0x5A])
    }

    @Test func ddAcceptsSizeSuffixes() {
        #expect(BuiltinCommands.parseByteCount("1k") == 1024)
        #expect(BuiltinCommands.parseByteCount("2K") == 2048)
        #expect(BuiltinCommands.parseByteCount("1kB") == 1000)
        #expect(BuiltinCommands.parseByteCount("3b") == 1536)
        #expect(BuiltinCommands.parseByteCount("4w") == 8)
        #expect(BuiltinCommands.parseByteCount("5c") == 5)
        #expect(BuiltinCommands.parseByteCount("1M") == 1 << 20)
        #expect(BuiltinCommands.parseByteCount("1G") == 1 << 30)
        #expect(BuiltinCommands.parseByteCount("2x512") == 1024)
        #expect(BuiltinCommands.parseByteCount("0x10", allowHex: true) == 16)
        #expect(BuiltinCommands.parseByteCount("12q") == nil)

        let shell = Shell()
        shell.write("/in", [UInt8](repeating: 7, count: 5000))
        let result = shell.capture("dd if=/in of=/out bs=1k count=3")
        #expect(shell.bytes(of: "/out")?.count == 3072)
        #expect(result.err == "3+0 records in\n3+0 records out\n3072 bytes copied\n")
    }

    @Test func ddReadsDeviceFilesUntilEndOfFile() {
        let shell = Shell()
        let result = shell.capture("dd if=/dev/null of=/out")
        #expect(shell.bytes(of: "/out") == [])
        #expect(result.err == "0+0 records in\n0+0 records out\n0 bytes copied\n")
    }

    @Test func ddReportsBadOperandsAndMissingInput() {
        let shell = Shell()
        var result = shell.capture("dd if=/missing")
        #expect(result.err == "dd: failed to open '/missing': No such file or directory\n")
        #expect(result.status == 1)
        result = shell.capture("dd bogus")
        #expect(result.err == "dd: unrecognized operand 'bogus'\nTry 'dd --help' for more information.\n")
        #expect(result.status == 1)
        result = shell.capture("dd bs=zz")
        #expect(result.err == "dd: invalid number: 'zz'\n")
    }

    // MARK: - base64

    @Test func base64EncodesWithPadding() {
        let shell = Shell()
        #expect(shell.capture("printf a | base64").out == "YQ==\n")
        #expect(shell.capture("printf ab | base64").out == "YWI=\n")
        #expect(shell.capture("printf abc | base64").out == "YWJj\n")
        #expect(shell.capture("echo hello | base64").out == "aGVsbG8K\n")
    }

    @Test func base64WrapsAtSeventySixColumnsByDefault() {
        let shell = Shell()
        shell.write("/in", [UInt8](repeating: 0x61, count: 60))
        let line = String(repeating: "YWFh", count: 19)
        #expect(shell.capture("base64 /in").out == line + "\nYWFh\n")
        #expect(shell.capture("base64 -w 0 /in").out == String(repeating: "YWFh", count: 20))
        #expect(shell.capture("base64 -w 8 /in").out
                == String(repeating: "YWFhYWFh\n", count: 10))
    }

    @Test func base64DecodesIgnoringNewlines() {
        let shell = Shell()
        shell.write("/in", "aGVs\nbG8K\n")
        #expect(shell.capture("base64 -d /in").out == "hello\n")
    }

    @Test func base64RoundTripsThroughAPipeline() {
        let shell = Shell()
        #expect(shell.capture("echo hello | base64 | base64 -d").out == "hello\n")
        let binary = (0..<256).map { UInt8($0) }
        shell.write("/bin.dat", binary)
        shell.run("base64 /bin.dat > /enc")
        shell.run("base64 -d /enc > /dec")
        #expect(shell.bytes(of: "/dec") == binary)
    }

    @Test func base64RejectsInvalidInput() {
        let shell = Shell()
        shell.write("/bad", "aGVs!bG8K\n")
        let result = shell.capture("base64 -d /bad")
        #expect(result.out == "hel")
        #expect(result.err == "base64: invalid input\n")
        #expect(result.status == 1)
        // -i skips the garbage instead.
        #expect(shell.capture("base64 -d -i /bad").out == "hello\n")
        #expect(shell.capture("base64 -d /missing").err == "base64: /missing: No such file or directory\n")
    }

    // MARK: - od

    @Test func odDefaultsToOctalWords() {
        let shell = Shell()
        shell.write("/in", "hello\n")
        #expect(shell.capture("od /in").out == "0000000 062550 066154 005157\n0000006\n")
        // An odd trailing byte is shown as a zero-extended word.
        shell.write("/odd", "abc")
        #expect(shell.capture("od /odd").out == "0000000 061141 000143\n0000003\n")
    }

    @Test func odCharacterFormatUsesEscapes() {
        let shell = Shell()
        shell.write("/in", [0x68, 0x69, 0x0A, 0x09, 0x00, 0x7F, 0xFF])
        #expect(shell.capture("od -c /in").out == "0000000   h   i  \\n  \\t  \\0 177 377\n0000007\n")
    }

    @Test func odHexBytesAndWords() {
        let shell = Shell()
        shell.write("/in", "hello\n")
        #expect(shell.capture("od -t x1 /in").out == "0000000 68 65 6c 6c 6f 0a\n0000006\n")
        #expect(shell.capture("od -x /in").out == "0000000 6568 6c6c 0a6f\n0000006\n")
        #expect(shell.capture("od -A x -t x1 /in").out == "000000 68 65 6c 6c 6f 0a\n000006\n")
        #expect(shell.capture("od -A d -t x1 /in").out == "0000000 68 65 6c 6c 6f 0a\n0000006\n")
        #expect(shell.capture("od -A n -t x1 /in").out == " 68 65 6c 6c 6f 0a\n")
    }

    @Test func odOctalBytesAndDecimalForms() {
        let shell = Shell()
        shell.write("/in", "hello\n")
        #expect(shell.capture("od -b /in").out == "0000000 150 145 154 154 157 012\n0000006\n")
        #expect(shell.capture("od -d /in").out == "0000000 25960 27756  2671\n0000006\n")
        #expect(shell.capture("od -t u1 /in").out == "0000000 104 101 108 108 111  10\n0000006\n")
        #expect(shell.capture("od -t o1 /in").out == "0000000 150 145 154 154 157 012\n0000006\n")
        shell.write("/neg", [0xFF, 0x80, 0x7F])
        #expect(shell.capture("od -t d1 /neg").out == "0000000   -1 -128  127\n0000003\n")
    }

    @Test func odMultipleTypesShareAlignedColumns() {
        let shell = Shell()
        shell.write("/in", "hello\n")
        #expect(shell.capture("od -t x1 -c /in").out
                == "0000000  68  65  6c  6c  6f  0a\n          h   e   l   l   o  \\n\n0000006\n")
        #expect(shell.capture("od -x -c /in").out
                == "0000000    6568    6c6c    0a6f\n          h   e   l   l   o  \\n\n0000006\n")
    }

    @Test func odSkipAndCount() {
        let shell = Shell()
        shell.write("/in", "0123456789")
        #expect(shell.capture("od -c -j 2 -N 3 /in").out == "0000002   2   3   4\n0000005\n")
        let result = shell.capture("od -j 99 /in")
        #expect(result.err == "od: cannot skip past end of combined input\n")
        #expect(result.status == 1)
    }

    @Test func odSqueezesRepeatedLinesUnlessVerbose() {
        let shell = Shell()
        shell.write("/in", [UInt8](repeating: 0, count: 48) + [1])
        #expect(shell.capture("od -t x1 /in").out == """
            0000000 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            *
            0000060 01
            0000061

            """)
        let zeros = " 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n"
        #expect(shell.capture("od -v -t x1 /in").out
                == "0000000" + zeros + "0000020" + zeros + "0000040" + zeros + "0000060 01\n0000061\n")
    }

    @Test func odConcatenatesOperandsAndReportsMissingOnes() {
        let shell = Shell()
        shell.write("/a", "ab")
        shell.write("/b", "cd")
        #expect(shell.capture("od -c /a /b").out == "0000000   a   b   c   d\n0000004\n")
        #expect(shell.capture("printf xy | od -c").out == "0000000   x   y\n0000002\n")
        let result = shell.capture("od /missing")
        #expect(result.err == "od: /missing: No such file or directory\n")
        #expect(result.status == 1)
        #expect(shell.capture("od -t q /a").err == "od: invalid type string 'q'\n")
    }

    // MARK: - xxd

    @Test func xxdCanonicalDump() {
        let shell = Shell()
        shell.write("/in", "hello\n")
        #expect(shell.capture("xxd /in").out == "00000000: 6865 6c6c 6f0a                           hello.\n")
        shell.write("/long", "The quick brown fox jumps\n")
        #expect(shell.capture("xxd /long").out == """
            00000000: 5468 6520 7175 6963 6b20 6272 6f77 6e20  The quick brown\u{20}
            00000010: 666f 7820 6a75 6d70 730a                 fox jumps.

            """)
    }

    @Test func xxdColumnsGroupsAndUppercase() {
        let shell = Shell()
        shell.write("/in", "hello\n")
        #expect(shell.capture("xxd -g 1 -c 4 -u /in").out
                == "00000000: 68 65 6C 6C  hell\n00000004: 6F 0A        o.\n")
        #expect(shell.capture("xxd -g0 /in").out == "00000000: 68656c6c6f0a                      hello.\n")
    }

    @Test func xxdSeekAndLength() {
        let shell = Shell()
        shell.write("/in", "hello\n")
        #expect(shell.capture("xxd -s 2 -l 3 /in").out
                == "00000002: 6c6c 6f                                  llo\n")
        shell.write("/alpha", "abcdefghijklmnopqrstuvwxyz")
        #expect(shell.capture("xxd -s -4 /alpha").out
                == "00000016: 7778 797a                                wxyz\n")
    }

    @Test func xxdPlainDump() {
        let shell = Shell()
        shell.write("/in", "hello world, this is a test of plain\n")
        #expect(shell.capture("xxd -p /in").out
                == "68656c6c6f20776f726c642c207468697320697320612074657374206f66\n20706c61696e0a\n")
        #expect(shell.capture("printf hi | xxd -p").out == "6869\n")
    }

    @Test func xxdReverseRestoresBothFormats() {
        let shell = Shell()
        let binary = (0..<100).map { UInt8(($0 * 7) & 0xFF) }
        shell.write("/bin.dat", binary)
        shell.run("xxd /bin.dat > /dump")
        shell.run("xxd -r /dump > /back")
        #expect(shell.bytes(of: "/back") == binary)
        shell.run("xxd -p /bin.dat > /plain")
        shell.run("xxd -r -p /plain /back2")
        #expect(shell.bytes(of: "/back2") == binary)
        #expect(shell.capture("echo 68656c6c6f | xxd -r -p").out == "hello")
        // Addresses position the bytes; gaps are zero-filled.
        shell.write("/sparse", "00000002: 4142\n")
        shell.run("xxd -r /sparse > /sparse.out")
        #expect(shell.bytes(of: "/sparse.out") == [0, 0, 0x41, 0x42])
    }

    @Test func xxdMissingFileFails() {
        let shell = Shell()
        let result = shell.capture("xxd /missing")
        #expect(result.err == "xxd: /missing: No such file or directory\n")
        #expect(result.status == 2)
    }

    // MARK: - hexdump

    @Test func hexdumpCanonical() {
        let shell = Shell()
        shell.write("/in", "hello\n")
        #expect(shell.capture("hexdump -C /in").out
                == "00000000  68 65 6c 6c 6f 0a                                 |hello.|\n00000006\n")
        shell.write("/full", "0123456789abcdefXYZ")
        #expect(shell.capture("hexdump -C /full").out == """
            00000000  30 31 32 33 34 35 36 37  38 39 61 62 63 64 65 66  |0123456789abcdef|
            00000010  58 59 5a                                          |XYZ|
            00000013

            """)
    }

    @Test func hexdumpDefaultShowsLittleEndianWords() {
        let shell = Shell()
        shell.write("/in", "hello\n")
        // Like the real tool, a short line is blank-padded to full width.
        #expect(shell.capture("hexdump /in").out
                == "0000000 6568 6c6c 0a6f" + String(repeating: " ", count: 25) + "\n0000006\n")
        shell.write("/odd", "hello")
        #expect(shell.capture("hexdump /odd").out
                == "0000000 6568 6c6c 006f" + String(repeating: " ", count: 25) + "\n0000005\n")
    }

    @Test func hexdumpSqueezesRepeatedLines() {
        let shell = Shell()
        shell.write("/zeros", [UInt8](repeating: 0, count: 64))
        #expect(shell.capture("hexdump -C /zeros").out == """
            00000000  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
            *
            00000040

            """)
        #expect(shell.capture("hexdump /zeros").out
                == "0000000 0000 0000 0000 0000 0000 0000 0000 0000\n*\n0000040\n")
        let lines = shell.capture("hexdump -v -C /zeros").out.split(separator: "\n")
        #expect(lines.count == 5)
        #expect(!lines.contains("*"))
    }

    @Test func hexdumpSkipLengthAndEmptyInput() {
        let shell = Shell()
        shell.write("/in", "0123456789")
        #expect(shell.capture("hexdump -C -s 2 -n 4 /in").out
                == "00000002  32 33 34 35                                       |2345|\n00000006\n")
        shell.write("/empty", "")
        #expect(shell.capture("hexdump -C /empty").out == "")
        let result = shell.capture("hexdump /missing")
        #expect(result.err == "hexdump: /missing: No such file or directory\n")
        #expect(result.status == 1)
    }

    // MARK: - strings

    @Test func stringsFindsPrintableRuns() {
        let shell = Shell()
        shell.write("/in", [0, 1] + Array("hello".utf8) + [0, 0xFF] + Array("abc".utf8) + [0]
                        + Array("world wide".utf8) + [0x0A] + Array("tail".utf8))
        #expect(shell.capture("strings /in").out == "hello\nworld wide\ntail\n")
        #expect(shell.capture("strings -a /in").out == "hello\nworld wide\ntail\n")
        #expect(shell.capture("strings -n 3 /in").out == "hello\nabc\nworld wide\ntail\n")
        #expect(shell.capture("strings -n 6 /in").out == "world wide\n")
        #expect(shell.capture("strings -t d /in").out == "      2 hello\n     13 world wide\n     24 tail\n")
    }

    @Test func stringsReadsStandardInputAndReportsMissingFiles() {
        let shell = Shell()
        #expect(shell.capture("echo printable | strings").out == "printable\n")
        let result = shell.capture("strings /missing")
        #expect(result.err == "strings: /missing: No such file or directory\n")
        #expect(result.status == 1)
    }

    // MARK: - split

    @Test func splitByLines() {
        let shell = Shell()
        shell.run("mkdir /w")
        shell.run("cd /w")
        shell.write("/w/in", "1\n2\n3\n4\n5\n")
        #expect(shell.capture("split -l 2 in").status == 0)
        #expect(shell.text(of: "/w/xaa") == "1\n2\n")
        #expect(shell.text(of: "/w/xab") == "3\n4\n")
        #expect(shell.text(of: "/w/xac") == "5\n")
        #expect(shell.bytes(of: "/w/xad") == nil)
    }

    @Test func splitDefaultsToAThousandLines() {
        let shell = Shell()
        shell.run("mkdir /w")
        shell.run("cd /w")
        shell.write("/w/in", String(repeating: "line\n", count: 1001))
        _ = shell.capture("split in")
        #expect(shell.bytes(of: "/w/xaa")?.count == 5000)
        #expect(shell.text(of: "/w/xab") == "line\n")
    }

    @Test func splitByBytesWithPrefixAndNumericSuffixes() {
        let shell = Shell()
        shell.write("/in", "abcdefghij")
        _ = shell.capture("split -b 4 -d /in /part.")
        #expect(shell.text(of: "/part.00") == "abcd")
        #expect(shell.text(of: "/part.01") == "efgh")
        #expect(shell.text(of: "/part.02") == "ij")
        shell.write("/big", [UInt8](repeating: 1, count: 2500))
        _ = shell.capture("split -b 1K -a 3 /big /k")
        #expect(shell.bytes(of: "/kaaa")?.count == 1024)
        #expect(shell.bytes(of: "/kaab")?.count == 1024)
        #expect(shell.bytes(of: "/kaac")?.count == 452)
    }

    @Test func splitReadsStandardInputAndReportsErrors() {
        let shell = Shell()
        shell.run("mkdir /w")
        shell.run("cd /w")
        _ = shell.capture("printf 'a\\nb\\nc\\n' | split -l 1 - p")
        #expect(shell.text(of: "/w/paa") == "a\n")
        #expect(shell.text(of: "/w/pac") == "c\n")
        var result = shell.capture("split /missing")
        #expect(result.err == "split: cannot open '/missing' for reading: No such file or directory\n")
        #expect(result.status == 1)
        result = shell.capture("split -l 0 /w/paa")
        #expect(result.err == "split: invalid number of lines: '0'\n")
        // One-character suffixes run out after 26 pieces.
        shell.write("/w/many", String(repeating: "x\n", count: 27))
        result = shell.capture("split -l 1 -a 1 many q")
        #expect(result.err == "split: output file suffixes exhausted\n")
        #expect(result.status == 1)
    }

    @Test func splitSuffixSequence() {
        #expect(BuiltinCommands.splitSuffix(0, length: 2, numeric: false) == "aa")
        #expect(BuiltinCommands.splitSuffix(27, length: 2, numeric: false) == "bb")
        #expect(BuiltinCommands.splitSuffix(675, length: 2, numeric: false) == "zz")
        #expect(BuiltinCommands.splitSuffix(676, length: 2, numeric: false) == nil)
        #expect(BuiltinCommands.splitSuffix(42, length: 3, numeric: true) == "042")
    }

    // MARK: - checksums

    @Test func checksumsOfAFile() {
        let shell = Shell()
        shell.write("/abc", "abc")
        #expect(shell.capture("md5sum /abc").out == "900150983cd24fb0d6963f7d28e17f72  /abc\n")
        #expect(shell.capture("sha1sum /abc").out == "a9993e364706816aba3e25717850c26c9cd0d89d  /abc\n")
        #expect(shell.capture("sha256sum /abc").out
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  /abc\n")
    }

    @Test func checksumsOfStandardInputAndSeveralFiles() {
        let shell = Shell()
        #expect(shell.capture("printf abc | sha256sum").out
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  -\n")
        #expect(shell.capture("printf abc | md5sum -").out == "900150983cd24fb0d6963f7d28e17f72  -\n")
        shell.write("/abc", "abc")
        shell.write("/empty", "")
        #expect(shell.capture("sha1sum /abc /empty").out == """
            a9993e364706816aba3e25717850c26c9cd0d89d  /abc
            da39a3ee5e6b4b0d3255bfef95601890afd80709  /empty

            """)
    }

    @Test func checksumMissingFileAndDirectory() {
        let shell = Shell()
        shell.write("/abc", "abc")
        shell.run("mkdir /d")
        let result = shell.capture("md5sum /missing /abc /d")
        #expect(result.out == "900150983cd24fb0d6963f7d28e17f72  /abc\n")
        #expect(result.err == "md5sum: /missing: No such file or directory\nmd5sum: /d: Is a directory\n")
        #expect(result.status == 1)
    }

    @Test func checksumCheckModeAcceptsMatchingFiles() {
        let shell = Shell()
        shell.write("/abc", "abc")
        shell.write("/empty", "")
        shell.run("sha256sum /abc /empty > /sums")
        let result = shell.capture("sha256sum -c /sums")
        #expect(result.out == "/abc: OK\n/empty: OK\n")
        #expect(result.err == "")
        #expect(result.status == 0)
    }

    @Test func checksumCheckModeReportsMismatchesAndUnreadableFiles() {
        let shell = Shell()
        shell.write("/abc", "abc")
        shell.write("/other", "other")
        shell.run("md5sum /abc /other > /sums")
        shell.write("/other", "changed")
        var result = shell.capture("md5sum -c /sums")
        #expect(result.out == "/abc: OK\n/other: FAILED\n")
        #expect(result.err == "md5sum: WARNING: 1 computed checksum did NOT match\n")
        #expect(result.status == 1)

        shell.write("/list", "900150983cd24fb0d6963f7d28e17f72  /abc\nnot a checksum line\n"
                        + "900150983cd24fb0d6963f7d28e17f72  /gone\n")
        result = shell.capture("md5sum -c /list")
        #expect(result.out == "/abc: OK\n/gone: FAILED open or read\n")
        #expect(result.err == """
            md5sum: /gone: No such file or directory
            md5sum: WARNING: 1 line is improperly formatted
            md5sum: WARNING: 1 listed file could not be read

            """)
        #expect(result.status == 1)

        shell.write("/junk", "nothing useful\n")
        result = shell.capture("sha1sum -c /junk")
        #expect(result.err == "sha1sum: /junk: no properly formatted checksum lines found\n")
        #expect(result.status == 1)
    }

    @Test func checksumCheckModeReadsStandardInput() {
        let shell = Shell()
        shell.write("/abc", "abc")
        #expect(shell.capture("sha1sum /abc | sha1sum -c").out == "/abc: OK\n")
    }

    // MARK: - option errors

    @Test func invalidOptionsUseTheStandardDiagnostic() {
        let shell = Shell()
        let result = shell.capture("base64 -Z")
        #expect(result.err == "base64: invalid option -- 'Z'\nTry 'base64 --help' for more information.\n")
        #expect(result.status == 2)
        #expect(shell.capture("hexdump --help").out.hasPrefix("Usage: hexdump [-C]"))
    }

    // MARK: - Harness

    /// Boots a kernel + pty + interactive shell (echo off), runs command lines,
    /// and reads the files they produce back out of the VFS.
    private final class Shell {
        let loop = EventLoop()
        let kernel: Kernel
        let pty = PseudoTerminal()

        init() {
            kernel = Kernel(loop: loop)
            pty.echo = false
            pty.onOutput = { [weak pty] in
                guard let pty else { return }
                _ = pty.readForApp(max: 65_535)
            }
            kernel.spawn("sh", Programs.shell(tty: pty.slave))
            loop.runUntilIdle()
        }

        func run(_ line: String) {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }

        /// Run `command` with stdout and stderr redirected to files, and return
        /// both along with the exit status.
        func capture(_ command: String) -> (out: String, err: String, status: Int32) {
            run("\(command) > /.out 2> /.err")
            run("echo $? > /.status")
            let status = Int32(text(of: "/.status").split(separator: "\n").first ?? "") ?? -1
            return (text(of: "/.out"), text(of: "/.err"), status)
        }

        func write(_ path: String, _ text: String) { write(path, Array(text.utf8)) }

        func write(_ path: String, _ bytes: [UInt8]) {
            kernel.spawn("seed") { ctx in
                if let fd = ctx.open(path, create: true, truncate: true) {
                    ctx.write(fd, bytes)
                    ctx.close(fd)
                }
                ctx.exit(0)
            }
            loop.runUntilIdle()
        }

        func bytes(of path: String) -> [UInt8]? {
            final class Box { var bytes: [UInt8]? }
            let box = Box()
            kernel.spawn("read") { ctx in
                if ctx.stat(path)?.type == .regular, let fd = ctx.open(path) {
                    var data: [UInt8] = []
                    while true {
                        let chunk = ctx.read(fd, max: 1 << 16)
                        if chunk.isEmpty { break }
                        data.append(contentsOf: chunk)
                    }
                    box.bytes = data
                    ctx.close(fd)
                }
                ctx.exit(0)
            }
            loop.runUntilIdle()
            return box.bytes
        }

        func text(of path: String) -> String {
            bytes(of: path).map { String(decoding: $0, as: UTF8.self) } ?? "<missing>"
        }
    }
}
