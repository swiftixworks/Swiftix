import Testing
@testable import Swiftix

/// The text filters: echo/printf, head/tail, wc, sort/uniq, cut/paste/join/comm,
/// tr/fold/expand/column/nl/tac/rev, seq, yes, and tee.
@Suite("Text commands")
struct TextCommandsTests {

    // MARK: - echo

    @Test func echoOptions() {
        let h = CommandHarness()
        #expect(h.stdout("echo -n x") == "x")
        #expect(h.stdout(#"echo -e 'a\tb\n'"#) == "a\tb\n\n")
        #expect(h.stdout(#"echo 'a\tb'"#) == "a\\tb\n")
        #expect(h.stdout(#"echo -E 'a\tb'"#) == "a\\tb\n")
        #expect(h.stdout(#"echo -ne 'a\x41\0101\\'"#) == "aAA\\")
        #expect(h.stdout(#"echo -e 'stop\chere'"#) == "stop")
        #expect(h.stdout("echo -x -n") == "-x -n\n")
        #expect(h.stdout("echo - n") == "- n\n")
        #expect(h.stdout("echo --help") == "--help\n")
        #expect(h.stdout("echo") == "\n")
    }

    // MARK: - printf

    @Test func printfWidthPrecisionAndFlags() {
        let h = CommandHarness()
        #expect(h.stdout(#"printf '%5d|%-5s|%x\n' 42 ab 255"#) == "   42|ab   |ff\n")
        #expect(h.stdout(#"printf '%05d %+d %X %o %u\n' 42 7 255 8 3"#) == "00042 +7 FF 10 3\n")
        #expect(h.stdout(#"printf '%.2s|%c|%5.1f|%%\n' abcdef xyz 3.14159"#) == "ab|x|  3.1|%\n")
        #expect(h.stdout(#"printf '%*d|%-*d|\n' 4 7 4 7"#) == "   7|7   |\n")
        #expect(h.stdout(#"printf '%#x %#o\n' 255 8"#) == "0xff 010\n")
        #expect(h.stdout(#"printf '%i\n' -12"#) == "-12\n")
    }

    @Test func printfReusesTheFormat() {
        let h = CommandHarness()
        #expect(h.stdout(#"printf '%s-%s\n' a b c d e"#) == "a-b\nc-d\ne-\n")
        #expect(h.stdout(#"printf '%d\n' 1 2 3"#) == "1\n2\n3\n")
        #expect(h.stdout(#"printf 'plain\n' ignored"#) == "plain\n")
        #expect(h.stdout(#"printf '%s|%d|\n'"#) == "|0|\n")
    }

    @Test func printfEscapes() {
        let h = CommandHarness()
        #expect(h.stdout(#"printf 'a\tb\\c\n'"#) == "a\tb\\c\n")
        #expect(h.stdout(#"printf '\101\x42\103\n'"#) == "ABC\n")
        #expect(h.stdout(#"printf '%b\n' '\0101'"#) == "A\n")
        #expect(h.stdout(#"printf '%b' 'x\ny\n'"#) == "x\ny\n")
        #expect(h.stdout(#"printf '%s' 'x\ny'"#) == "x\\ny")
        #expect(h.bytes(of: "/.stdout") == Array("x\\ny".utf8))
        h.run(#"printf '\xff\x00\x01' > /raw"#)
        #expect(h.bytes(of: "/raw") == [0xFF, 0x00, 0x01])
    }

    @Test func printfNumberForms() {
        let h = CommandHarness()
        #expect(h.stdout(#"printf '%d %d %d\n' 0x1f 010 "'A""#) == "31 8 65\n")
        #expect(h.console("printf '%d\\n' abc").contains("printf: 'abc': expected a numeric value"))
        #expect(h.status("printf '%d\\n' abc") == 1)
        #expect(h.status("printf '%d\\n' 5") == 0)
    }

    @Test func floatFormatting() {
        func f(_ value: Double, _ conversion: Character, _ precision: Int? = nil) -> String {
            BuiltinCommands.formatFloat(value, conversion: conversion, precision: precision)
        }
        #expect(f(3.14159, "f", 2) == "3.14")
        #expect(f(2.5, "f", 0) == "2")              // half to even on the exact value
        #expect(f(3.5, "f", 0) == "4")
        #expect(f(0.1, "f", 20) == "0.10000000000000000555")
        #expect(f(1e21, "f", 0) == "1000000000000000000000")
        #expect(f(-0.5, "f", 1) == "-0.5")
        #expect(f(1234.5678, "e", 3) == "1.235e+03")
        #expect(f(0.00012345, "E", 2) == "1.23E-04")
        #expect(f(0, "e") == "0.000000e+00")
        #expect(f(100000, "g") == "100000")
        #expect(f(1000000, "g") == "1e+06")
        #expect(f(0.0001, "g") == "0.0001")
        #expect(f(0.00001, "g") == "1e-05")
        #expect(f(3.14159265, "g") == "3.14159")
        #expect(f(9.9999999, "g", 3) == "10")
        #expect(f(.infinity, "f") == "inf")
        #expect(f(.nan, "F") == "NAN")
    }

    // MARK: - head / tail

    @Test func headLinesAndBytes() {
        let h = CommandHarness()
        h.write("/n", "1\n2\n3\n4\n5\n")
        #expect(h.stdout("head -n 2 /n") == "1\n2\n")
        #expect(h.stdout("head -2 /n") == "1\n2\n")
        #expect(h.stdout("head -n2 /n") == "1\n2\n")
        #expect(h.stdout("head -n -2 /n") == "1\n2\n3\n")
        #expect(h.stdout("head -c 3 /n") == "1\n2")
        #expect(h.stdout("head -c -4 /n") == "1\n2\n3\n")
        #expect(h.stdout("seq 30 | head | wc -l") == "10\n")
        #expect(h.stdout("head -n 1 /n /n") == "==> /n <==\n1\n\n==> /n <==\n1\n")
        #expect(h.stdout("head -q -n 1 /n /n") == "1\n1\n")
        #expect(h.console("head /missing").contains("head: /missing: No such file or directory"))
        #expect(h.console("head -n x /n").contains("head: invalid number of lines: 'x'"))
    }

    @Test func tailLinesAndBytes() {
        let h = CommandHarness()
        h.write("/n", "1\n2\n3\n4\n5\n")
        #expect(h.stdout("tail -n 2 /n") == "4\n5\n")
        #expect(h.stdout("tail -2 /n") == "4\n5\n")
        #expect(h.stdout("tail -n +4 /n") == "4\n5\n")
        #expect(h.stdout("tail -c 4 /n") == "4\n5\n")
        #expect(h.stdout("tail -c +9 /n") == "5\n")
        #expect(h.stdout("seq 30 | tail -n 3") == "28\n29\n30\n")
        #expect(h.stdout("tail -n 1 /n /n") == "==> /n <==\n5\n\n==> /n <==\n5\n")
    }

    @Test func tailFollowPrintsAppendedDataAndIsInterruptible() {
        let h = CommandHarness()
        h.write("/log", "one\n")
        h.clearOutput()
        h.run("tail -f /log")
        #expect(h.output().contains("one\n"))
        // Nothing new yet: the process is parked on the clock, not spinning.
        h.advance(by: 5)
        h.inProcess { ctx in
            let fd = ctx.open("/log", access: .readWrite)!
            _ = ctx.seek(fd, to: 0, whence: 2)
            ctx.write(fd, Array("two\n".utf8))
            ctx.close(fd)
        }
        #expect(!h.output().contains("two"))
        h.advance(by: 1)
        #expect(h.output().contains("two\n"))
        // Ctrl-C ends it and the shell takes the next command.
        h.kernel.interruptForeground(signal: Signal.sigint.rawValue)
        h.loop.runUntilIdle()
        #expect(h.console("echo back").contains("back"))
    }

    @Test func tailFollowReportsTruncation() {
        let h = CommandHarness()
        h.write("/log", "a long first line\n")
        h.clearOutput()
        h.run("tail -f -s 0.5 /log")
        h.write("/log", "new\n")
        h.advance(by: 0.5)
        #expect(h.output().contains("tail: /log: file truncated"))
        #expect(h.output().contains("new\n"))
        h.kernel.interruptForeground(signal: Signal.sigint.rawValue)
        h.loop.runUntilIdle()
    }

    // MARK: - wc

    @Test func wcSelectsCountsAndTotals() {
        let h = CommandHarness()
        h.write("/a", "one two\nthree\n")
        h.write("/b", "héllo\n")
        #expect(h.stdout("wc -l /a") == "2 /a\n")
        #expect(h.stdout("wc -w /a") == "3 /a\n")
        #expect(h.stdout("wc -c /a") == "14 /a\n")
        #expect(h.stdout("wc -c /b") == "7 /b\n")
        #expect(h.stdout("wc -m /b") == "6 /b\n")
        #expect(h.stdout("wc -L /a") == "7 /a\n")
        #expect(h.stdout("wc /a") == "      2       3      14 /a\n")
        #expect(h.stdout("wc -l /a /b") == "      2 /a\n      1 /b\n      3 total\n")
        #expect(h.stdout("wc /a /b") == "      2       3      14 /a\n      1       1       7 /b\n      3       4      21 total\n")
        #expect(h.stdout("cat /a | wc -l") == "2\n")
        #expect(h.stdout("cat /a | wc") == "      2       3      14\n")
        #expect(h.stdout("wc -lw /a") == "      2       3 /a\n")
        #expect(h.console("wc /nope").contains("wc: /nope: No such file or directory"))
    }

    // MARK: - sort / uniq

    @Test func sortFlags() {
        let h = CommandHarness()
        h.write("/n", "10\n9\n100\n9\n-1\n")
        h.write("/w", "banana\nApple\ncherry\napple\n")
        #expect(h.stdout("sort /n") == "-1\n10\n100\n9\n9\n")
        #expect(h.stdout("sort -n /n") == "-1\n9\n9\n10\n100\n")
        #expect(h.stdout("sort -rn /n") == "100\n10\n9\n9\n-1\n")
        #expect(h.stdout("sort -n -r -u /n") == "100\n10\n9\n-1\n")
        #expect(h.stdout("sort -nu /n") == "-1\n9\n10\n100\n")
        #expect(h.stdout("sort /w") == "Apple\napple\nbanana\ncherry\n")
        #expect(h.stdout("sort -f /w") == "Apple\napple\nbanana\ncherry\n")
        #expect(h.stdout("sort -fu /w") == "Apple\nbanana\ncherry\n")
        #expect(h.stdout("sort -r /w") == "cherry\nbanana\napple\nApple\n")
    }

    @Test func sortKeysAndSeparators() {
        let h = CommandHarness()
        h.write("/t", "bob:30:x\nalice:4:y\ncarol:30:a\ndave:100:z\n")
        #expect(h.stdout("sort -t : -k 2 -n /t") == "alice:4:y\nbob:30:x\ncarol:30:a\ndave:100:z\n")
        #expect(h.stdout("sort -t: -k2,2nr -k1,1 /t") == "dave:100:z\nbob:30:x\ncarol:30:a\nalice:4:y\n")
        #expect(h.stdout("sort -t: -k3 /t") == "carol:30:a\nbob:30:x\nalice:4:y\ndave:100:z\n")
        h.write("/s", "x 3\ny 1\nz 2\n")
        #expect(h.stdout("sort -k 2 /s") == "y 1\nz 2\nx 3\n")
        #expect(h.stdout("sort -k2nr /s") == "x 3\nz 2\ny 1\n")
        // A key with its own flags does not inherit the global ones.
        #expect(h.stdout("sort -k2n -r /s") == "y 1\nz 2\nx 3\n")
        h.run("sort -o /out -k 2 /s")
        #expect(h.contents(of: "/out") == "y 1\nz 2\nx 3\n")
        #expect(h.status("sort -c /out") == 1)
        #expect(h.status("sort -c -k2 /out") == 0)
        #expect(h.console("sort -k 0 /s").contains("sort: invalid field specification"))
    }

    @Test func uniqFlags() {
        let h = CommandHarness()
        h.write("/u", "a\na\nb\nA\nc\nc\nc\n")
        #expect(h.stdout("uniq /u") == "a\nb\nA\nc\n")
        #expect(h.stdout("uniq -c /u") == "      2 a\n      1 b\n      1 A\n      3 c\n")
        #expect(h.stdout("uniq -d /u") == "a\nc\n")
        #expect(h.stdout("uniq -u /u") == "b\nA\n")
        h.write("/i", "x\nX\ny\n")
        #expect(h.stdout("uniq -i /i") == "x\ny\n")
        #expect(h.stdout("uniq -ic /i") == "      2 x\n      1 y\n")
        h.write("/f", "1 same\n2 same\n3 other\n")
        #expect(h.stdout("uniq -f 1 /f") == "1 same\n3 other\n")
        h.run("uniq /u /uout")
        #expect(h.contents(of: "/uout") == "a\nb\nA\nc\n")
    }

    // MARK: - cut / paste / join / comm

    @Test func cutFieldsCharactersAndBytes() {
        let h = CommandHarness()
        h.write("/c", "a,b,c,d\nno-delimiter\n1,2,3,4\n")
        #expect(h.stdout("cut -d, -f2 /c") == "b\nno-delimiter\n2\n")
        #expect(h.stdout("cut -d , -f 2 /c") == "b\nno-delimiter\n2\n")
        #expect(h.stdout("cut -d, -f1,3 /c") == "a,c\nno-delimiter\n1,3\n")
        #expect(h.stdout("cut -d, -f2-4 /c") == "b,c,d\nno-delimiter\n2,3,4\n")
        #expect(h.stdout("cut -d, -f-2 /c") == "a,b\nno-delimiter\n1,2\n")
        #expect(h.stdout("cut -d, -f3- -s /c") == "c,d\n3,4\n")
        #expect(h.stdout("cut -c1-2 /c") == "a,\nno\n1,\n")
        #expect(h.stdout("cut -c 2,4- /c") == ",,c,d\nodelimiter\n,,3,4\n")
        #expect(h.stdout("cut -b 1 /c") == "a\nn\n1\n")
        #expect(h.stdout("echo 'one two three' | cut -d' ' -f2") == "two\n")
        #expect(h.stdout("printf 'a\\tb\\tc\\n' | cut -f 2") == "b\n")
        #expect(h.stdout("cut -d, -f1,3 --output-delimiter=: /c") == "a:c\nno-delimiter\n1:3\n")
        #expect(h.stdout("cut -d, --complement -f1 -s /c") == "b,c,d\n2,3,4\n")
        #expect(h.console("cut /c").contains("cut: you must specify a list"))
        #expect(h.console("cut -f 0 /c").contains("cut: invalid field value '0'"))
    }

    @Test func pasteJoinComm() {
        let h = CommandHarness()
        h.write("/a", "1\n2\n3\n")
        h.write("/b", "x\ny\n")
        #expect(h.stdout("paste /a /b") == "1\tx\n2\ty\n3\t\n")
        #expect(h.stdout("paste -d, /a /b") == "1,x\n2,y\n3,\n")
        #expect(h.stdout("paste -s -d+ /a") == "1+2+3\n")
        #expect(h.stdout("seq 4 | paste - -") == "1\t2\n3\t4\n")
        h.write("/l", "1 apple\n2 banana\n4 date\n")
        h.write("/r", "1 red\n2 yellow\n3 green\n")
        #expect(h.stdout("join /l /r") == "1 apple red\n2 banana yellow\n")
        #expect(h.stdout("join -a 1 /l /r") == "1 apple red\n2 banana yellow\n4 date\n")
        #expect(h.stdout("join -v 2 /l /r") == "3 green\n")
        h.write("/k", "apple:1\nbanana:2\n")
        h.write("/m", "1:red\n2:yellow\n")
        #expect(h.stdout("join -t : -1 2 -2 1 /k /m") == "1:apple:red\n2:banana:yellow\n")
        h.write("/c1", "a\nb\nc\n")
        h.write("/c2", "b\nc\nd\n")
        #expect(h.stdout("comm /c1 /c2") == "a\n\t\tb\n\t\tc\n\td\n")
        #expect(h.stdout("comm -12 /c1 /c2") == "b\nc\n")
        #expect(h.stdout("comm -23 /c1 /c2") == "a\n")
        #expect(h.stdout("comm -3 /c1 /c2") == "a\n\td\n")
    }

    // MARK: - tr / fold / expand / column / nl / tac / rev

    @Test func trTranslatesDeletesAndSqueezes() {
        let h = CommandHarness()
        #expect(h.stdout("echo hello | tr a-z A-Z") == "HELLO\n")
        #expect(h.stdout("echo hello | tr '[:lower:]' '[:upper:]'") == "HELLO\n")
        #expect(h.stdout("echo hello | tr -d l") == "heo\n")
        #expect(h.stdout("echo 'a   b  c' | tr -s ' '") == "a b c\n")
        #expect(h.stdout("echo 'a b c' | tr ' ' '\\n'") == "a\nb\nc\n")
        #expect(h.stdout("echo abc123 | tr -cd '0-9\\n'") == "123\n")
        #expect(h.stdout("echo abcdef | tr a-f x") == "xxxxxx\n")
        #expect(h.stdout("echo aabbcc | tr -s ab xy") == "xycc\n")
        #expect(h.stdout("echo 'x-y' | tr -d '[:punct:]'") == "xy\n")
        #expect(h.console("echo x | tr").contains("tr: missing operand"))
        #expect(h.console("echo x | tr a").contains("tr: missing operand after 'a'"))
        #expect(BuiltinCommands.expandTrSet("a-e").count == 5)
        #expect(BuiltinCommands.expandTrSet("[x*3]") == ["x", "x", "x"])
        #expect(BuiltinCommands.expandTrSet("\\101\\n") == ["A", "\n"])
    }

    @Test func foldExpandColumn() {
        let h = CommandHarness()
        #expect(h.stdout("echo abcdefghij | fold -w 4") == "abcd\nefgh\nij\n")
        #expect(h.stdout("echo abcdefghij | fold -4") == "abcd\nefgh\nij\n")
        #expect(h.stdout("echo 'aa bb cc dd' | fold -s -w 6") == "aa bb \ncc dd\n")
        #expect(h.stdout("printf 'a\\tb\\n' | expand") == "a       b\n")
        #expect(h.stdout("printf 'ab\\tc\\n' | expand -t 4") == "ab  c\n")
        h.write("/tbl", "name size\nalpha 1\nb 22222\n")
        #expect(h.stdout("column -t /tbl") == "name   size\nalpha  1\nb      22222\n")
        h.write("/csv", "a,bb\nccc,d\n")
        #expect(h.stdout("column -t -s , /csv") == "a    bb\nccc  d\n")
        #expect(h.stdout("column -t -s , -o ' | ' /csv") == "a   | bb\nccc | d\n")
    }

    @Test func nlTacRev() {
        let h = CommandHarness()
        h.write("/x", "a\n\nb\n")
        #expect(h.stdout("nl /x") == "     1\ta\n       \n     2\tb\n")
        #expect(h.stdout("nl -ba /x") == "     1\ta\n     2\t\n     3\tb\n")
        #expect(h.stdout("nl -w 2 -s ': ' -v 10 -i 5 /x") == "10: a\n   \n15: b\n")
        #expect(h.stdout("nl -n rz -w 3 /x") == "001\ta\n    \n002\tb\n")
        #expect(h.stdout("tac /x") == "b\n\na\n")
        #expect(h.stdout("seq 3 | tac") == "3\n2\n1\n")
        #expect(h.stdout("echo 'abc def' | rev") == "fed cba\n")
    }

    // MARK: - seq / yes / tee

    @Test func seqForms() {
        let h = CommandHarness()
        #expect(h.stdout("seq 3") == "1\n2\n3\n")
        #expect(h.stdout("seq 2 4") == "2\n3\n4\n")
        #expect(h.stdout("seq 10 -3 1") == "10\n7\n4\n1\n")
        #expect(h.stdout("seq -1 1") == "-1\n0\n1\n")
        #expect(h.stdout("seq 0 0.5 2") == "0.0\n0.5\n1.0\n1.5\n2.0\n")
        #expect(h.stdout("seq 0.1 0.1 0.5") == "0.1\n0.2\n0.3\n0.4\n0.5\n")
        #expect(h.stdout("seq -s , 4") == "1,2,3,4\n")
        #expect(h.stdout("seq -w 8 10") == "08\n09\n10\n")
        #expect(h.stdout("seq 3 1") == "")
        #expect(h.console("seq 1 0 5").contains("seq: invalid Zero increment value"))
        #expect(h.console("seq x").contains("seq: invalid floating point argument: 'x'"))
    }

    @Test func yesStopsWhenItsReaderLeaves() {
        let h = CommandHarness()
        #expect(h.stdout("yes | head -1") == "y\n")
        #expect(h.stdout("yes abc def | head -n 3") == "abc def\nabc def\nabc def\n")
        // The shell is back at its prompt: `yes` was killed by SIGPIPE.
        #expect(h.stdout("echo alive") == "alive\n")
        #expect(h.stdout("ps -o comm=").split(separator: "\n").contains("yes") == false)
    }

    @Test func yesOnATerminalParksAndCanBeInterrupted() {
        let h = CommandHarness()
        h.clearOutput()
        h.run("yes")                      // returns: the writer paces itself on the clock
        #expect(h.output().contains("y\ny\n"))
        h.kernel.interruptForeground(signal: Signal.sigint.rawValue)
        h.loop.runUntilIdle()
        #expect(h.stdout("echo done") == "done\n")
    }

    @Test func teeCopiesAndAppends() {
        let h = CommandHarness()
        #expect(h.stdout("echo one | tee /t1 /t2") == "one\n")
        #expect(h.contents(of: "/t1") == "one\n")
        #expect(h.contents(of: "/t2") == "one\n")
        h.run("echo two | tee -a /t1")
        #expect(h.contents(of: "/t1") == "one\ntwo\n")
        h.run("echo three | tee /t1")
        #expect(h.contents(of: "/t1") == "three\n")
        #expect(h.console("echo x | tee /no/dir/f").contains("tee: /no/dir/f: No such file or directory"))
    }

    // MARK: - less

    @Test func lessPagesForwardAndBackAndQuits() {
        let h = CommandHarness()
        h.pty.windowSize = WindowSize(rows: 5, columns: 80)
        h.write("/long", (1...20).map { "line\($0)" }.joined(separator: "\n") + "\n")
        h.clearOutput()
        h.run("less /long")
        #expect(h.output().contains("line1\r\nline2\r\nline3\r\nline4\r\n:"))
        #expect(!h.output().contains("line5"))
        h.clearOutput()
        h.type(Array(" ".utf8))                          // next page
        #expect(h.output().contains("line5\r\nline6\r\nline7\r\nline8\r\n:"))
        h.clearOutput()
        h.type(Array("b".utf8))                          // back
        #expect(h.output().contains("line1\r\n"))
        h.clearOutput()
        h.type(Array("G".utf8))                          // end
        #expect(h.output().contains("line20\r\n"))
        #expect(h.output().contains("(END)"))
        h.type(Array("q".utf8))
        #expect(h.console("echo after").contains("after"))
    }

    @Test func lessCopiesWhenNotOnATerminal() {
        let h = CommandHarness()
        h.write("/long", (1...100).map(String.init).joined(separator: "\n") + "\n")
        #expect(h.stdout("less /long | wc -l") == "100\n")
        #expect(h.stdout("seq 3 | less") == "1\n2\n3\n")
    }

    // MARK: - parsing helpers

    @Test func rangeListParsing() {
        #expect(BuiltinCommands.parseRangeList("1,3") == [1...1, 3...3])
        #expect(BuiltinCommands.parseRangeList("2-4") == [2...4])
        #expect(BuiltinCommands.parseRangeList("-2") == [1...2])
        #expect(BuiltinCommands.parseRangeList("5-") == [5...Int.max])
        #expect(BuiltinCommands.parseRangeList("0") == nil)
        #expect(BuiltinCommands.parseRangeList("4-2") == nil)
        #expect(BuiltinCommands.parseRangeList("a") == nil)
    }
}
