/// Go `fmt.Sprintf`, `fmt.Errorf`, `fmt.Printf`, and `fmt.Fprintf`: verbs,
/// flags, width and precision, Go's markers for a mistake, type checking, and
/// resource limits. Every expected string is what Go 1.24.5 prints for the
/// same call, checked by running both, unless a comment says otherwise.

import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

@Suite("Go fmt verbs")
struct GoFormatVerbTests: GoTestHarness {

    private static let declarations = #"""
        type point struct {
            x    int
            name string
        }
        type pair struct {
            first  point
            second []int
        }
        var errBoom = errors.New("boom")
        """#

    /// Runs one `fmt.Println(call)` per case and compares line by line, so a
    /// failure names the call.
    private func expectLines(_ cases: [(call: String, expected: String)]) throws {
        let body = cases.map { "fmt.Println(\($0.call))" }.joined(separator: "\n")
        let output = try runGoMain(
            body, imports: ["errors", "fmt"], declarations: Self.declarations,
            machine: GoVirtualMachine(maximumInstructions: 10_000_000))
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == cases.count)
        for (line, test) in zip(lines, cases) {
            #expect(String(line) == test.expected, "\(test.call)")
        }
    }

    // MARK: - Integers

    @Test func integerVerbsFlagsWidthAndPrecision() throws {
        try expectLines([
            (#"fmt.Sprintf("%d|%5d|%-5d|%05d|%+d|% d", 42, 42, 42, 42, 42, 42)"#,
             "42|   42|42   |00042|+42| 42"),
            (#"fmt.Sprintf("%d %d %v %+v", -7, 0, -7, 7)"#, "-7 0 -7 7"),
            (#"fmt.Sprintf("%05d|%+05d|% 05d|%-05d|", -42, 42, 42, 42)"#,
             "-0042|+0042| 0042|42   |"),
            (#"fmt.Sprintf("%.3d|%8.3d|%-8.3d|%08.3d|", 7, 7, 7, 7)"#,
             "007|     007|007     |     007|"),
            (#"fmt.Sprintf("[%.0d][%3.0d][%.0d]", 0, 0, 5)"#, "[][   ][5]"),
            (#"fmt.Sprintf("%x %X %#x %#X %08x %#08x", 255, 255, 255, 255, 255, 255)"#,
             "ff FF 0xff 0XFF 000000ff 0x000000ff"),
            (#"fmt.Sprintf("%x %#x %d", -255, -255, -9223372036854775807-1)"#,
             "-ff -0xff -9223372036854775808"),
            (#"fmt.Sprintf("%b %o %#o %O %#b %8b|", 10, 10, 10, 10, 10, 5)"#,
             "1010 12 012 0o12 0b1010      101|"),
            (#"fmt.Sprintf("%c%c|%3c|%-3c|%q %q %+q", 72, 19990, 65, 65, 65, 10, 233)"#,
             #"H世|  A|A  |'A' '\n' '\u00e9'"#),
            (#"fmt.Sprintf("%U %#U %U %.6U", 65, 65, 128512, 65)"#,
             "U+0041 U+0041 'A' U+1F600 U+000041"),
            (#"fmt.Sprintf("%c|%c", -1, 1114112)"#, "\u{FFFD}|\u{FFFD}"),
        ])
    }

    @Test func bytesAreIntegersUnlessTheSliceIsFormattedAsText() throws {
        let output = try runGoMain(
            #"""
            var letter byte = 65
            data := []byte("hi")
            numbers := []int{104, 105}
            fmt.Println(fmt.Sprintf("%c %d %v %x", letter, letter, letter, letter))
            fmt.Println(fmt.Sprintf("%v %d %s %x %X %q %c", data, data, data, data, data, data, data))
            fmt.Println(fmt.Sprintf("%v %x %c", numbers, numbers, numbers))
            fmt.Println(fmt.Sprintf("% x|%# x|%#x|%.1x|%5s|%-5s|", data, data, data, data, data, data))
            var none []byte
            fmt.Println(fmt.Sprintf("[%s][%x][%v][%d]", none, none, none, none))
            fmt.Println(fmt.Sprintf("%s %x", data[1:], []byte{0, 171, 255}))
            """#)

        #expect(
            output == #"""
                A 65 65 41
                [104 105] [104 105] hi 6869 6869 "hi" [h i]
                [104 105] [68 69] [h i]
                68 69|0x68 0x69|0x6869|68|   hi|hi   |
                [][][[]][[]]
                i 00abff

                """#)
    }

    // MARK: - Strings and bools

    @Test func stringAndBooleanVerbs() throws {
        try expectLines([
            (#"fmt.Sprintf("%s|%10s|%-10s|%.2s|%v|%6v|", "hello", "hello", "hello", "hello", "hi", "ab")"#,
             "hello|     hello|hello     |he|hi|    ab|"),
            (#"fmt.Sprintf("%x|%X|% x|%#x|%.2x|[%5x]|[%x]", "hello", "hello", "hello", "hello", "hello", "", "")"#,
             "68656c6c6f|68656C6C6F|68 65 6c 6c 6f|0x68656c6c6f|6865|[     ]|[]"),
            (#"fmt.Sprintf("%05s|%-05s|%05t", "ab", "ab", true)"#, "000ab|ab   |0true"),
            (#"fmt.Sprintf("%q %q %q", "a\tb\"c\n", "\x00\x7f", "é世")"#,
             #""a\tb\"c\n" "\x00\x7f" "é世""#),
            (#"fmt.Sprintf("%+q %#q %#q %8q|%.2q", "é", "hi", "a`b", "x", "hello")"#,
             #""\u00e9" `hi` "a`b"      "x"|"he""#),
            (#"fmt.Sprintf("%5s|%-4s|%.1s|%3c|", "世界", "é", "世界", 19990)"#,
             "   世界|é   |世|  世|"),
            (#"fmt.Sprintf("%t %v %5t|%-6t|", true, false, true, false)"#,
             "true false  true|false |"),
            (#"fmt.Sprintf("100%% %5% %d%%", 7)"#, "100% % 7%"),
        ])
    }

    // MARK: - Composite values and errors

    @Test func aggregatesApplyTheVerbToEveryElement() throws {
        try expectLines([
            (#"fmt.Sprintf("%v %d %3d %x %s", []int{1, 2, 3}, []int{1, 2, 3}, []int{1, 2, 3}, []int{10, 255}, []int{7})"#,
             "[1 2 3] [1 2 3] [  1   2   3] [a ff] [%!s(int=7)]"),
            (#"fmt.Sprintf("%s %q %v %5s|", []string{"a", "b"}, []string{"a", "b"}, []string{}, []string{"ab"})"#,
             #"[a b] ["a" "b"] [] [   ab]|"#),
            (#"fmt.Sprintf("%v %+v %d %s", point{x: 1, name: "a"}, point{x: 1, name: "a"}, point{x: 1, name: "a"}, point{x: 1, name: "a"})"#,
             "{1 a} {x:1 name:a} {1 %!d(string=a)} {%!s(int=1) a}"),
            (#"fmt.Sprintf("%v|%+v", pair{first: point{x: 2, name: "b"}, second: []int{3, 4}}, pair{first: point{x: 2, name: "b"}, second: []int{3, 4}})"#,
             "{{2 b} [3 4]}|{first:{x:2 name:b} second:[3 4]}"),
            (#"fmt.Sprintf("%v %d %x", map[string]int{"a": 1, "b": 20}, map[string]int{"k": 7}, map[int]string{255: "hi"})"#,
             "map[a:1 b:20] map[%!d(string=k):7] map[ff:6869]"),
            (#"fmt.Sprintf("%v %t %v", [][]int{[]int{1}, []int{2, 3}}, []bool{true, false}, [2]int{4, 5})"#,
             "[[1] [2 3]] [true false] [4 5]"),
        ])
    }

    @Test func libraryErrorsAndNilFollowGo() throws {
        let output = try runGoMain(
            #"""
            var none error
            var boxed any = 12
            fmt.Println(fmt.Sprintf("%v|%s|%q|%x|%10v|%-6s|", errBoom, errBoom, errBoom, errBoom, errBoom, errBoom))
            fmt.Println(fmt.Sprintf("%d %t", errBoom, errBoom))
            fmt.Println(fmt.Sprintf("%v|%6v|%s|%d|%+v", none, none, none, nil, nil))
            fmt.Println(fmt.Sprintf("%v %d %05d %s", boxed, boxed, boxed, boxed))
            wrapped := fmt.Errorf("open %s: %w (try %d)", "/data", errBoom, 2)
            fmt.Println(wrapped.Error(), wrapped != nil, wrapped)
            fmt.Println(fmt.Sprintf("%w", errBoom), fmt.Errorf("plain").Error())
            """#,
            imports: ["errors", "fmt"], declarations: Self.declarations)

        #expect(
            output == #"""
                boom|boom|"boom"|626f6f6d|      boom|boom  |
                &{%!d(string=boom)} &{%!t(string=boom)}
                <nil>| <nil>|%!s(<nil>)|%!d(<nil>)|<nil>
                12 12 00012 %!s(int=12)
                open /data: boom (try 2) true open /data: boom (try 2)
                %!w(*errors.errorString=&{boom}) plain

                """#)
    }

    @Test func furtherFlagCombinationsMatchGo() throws {
        try expectLines([
            (#"fmt.Sprintf("%08U|%-8U|%#x|%#o|%+x|% x|%+c|%05c", 65, 65, 0, 0, 255, 255, 65, 65)"#,
             "  U+0041|U+0041  |0x0|0|+ff| ff|A|0000A"),
            (#"fmt.Sprintf("%+.3d|% .3d|%+5.2d|%-+6d|%- 6d|%+-6d|", 7, 7, 7, 7, 7, 7)"#,
             "+007| 007|  +07|+7    | 7    |+7    |"),
            (#"fmt.Sprintf("%3q|%-5q|%05q|%#q|%#U|%#U", 65, 65, 65, 65, 10, 233)"#,
             "'A'|'A'  |00'A'|'A'|U+000A|U+00E9 'é'"),
            (#"fmt.Sprintf("%3d|%03d|%-3d|%+d|%o|%b", []byte("hi"), []byte("hi"), []byte("hi"), []byte("hi"), []byte("hi"), []byte("hi"))"#,
             "[104 105]|[104 105]|[104 105]|[+104 +105]|[150 151]|[1101000 1101001]"),
            (#"fmt.Sprintf("%8x|%-8x|%08x|% X|%#X|%.0x|", []byte("hi"), []byte("hi"), []byte("hi"), []byte("hi"), []byte("hi"), []byte("hi"))"#,
             "    6869|6869    |00006869|68 69|0X6869||"),
            (#"fmt.Sprintf("%8x|%-8x|%08x|% X|%# X|%#.1x|%+q|%#+q|%-8q|", "ab", "ab", "ab", "ab", "ab", "ab", "a\u00e9\x01", "é", "x")"#,
             #"    6162|6162    |00006162|61 62|0X61 0X62|0x61|"a\u00e9\x01"|`é`|"x"     |"#),
            (#"fmt.Sprintf("%q|%q|%q|%+q", "\u2028\ufeff", "\u00a0\u00ad", "😀\U0010ffff", "😀")"#,
             #""\u2028\ufeff"|"\u00a0\u00ad"|"😀\U0010ffff"|"\U0001f600""#),
            (#"fmt.Sprintf("%.0s|%.10s|%2.1s|%-2.1s|%c", "abc", "abc", "abc", "abc", 233)"#,
             "|abc| a|a |é"),
            (#"fmt.Sprintf("%5v|%-5v|%05v|%x|%X|%q", []int{1, 22}, []int{1, 22}, []int{1, 22}, []string{"a", "bc"}, point{x: 255, name: "z"}, point{x: 65, name: "z"})"#,
             #"[    1    22]|[1     22   ]|[00001 00022]|[61 6263]|{FF 7A}|{'A' "z"}"#),
            (#"fmt.Sprintf("%v %v %s %d", []bool{}, [0]int{}, []string{"x", ""}, [][]int{[]int{}, []int{1}})"#,
             "[] [] [x ] [[] [1]]"),
            (#"fmt.Sprintf("%+v|%.2v|%.2s|%X|%+q|%5q|", errBoom, errBoom, errBoom, errBoom, errBoom, errBoom)"#,
             #"boom|bo|bo|626F6F6D|"boom"|"boom"|"#),
            (#"fmt.Sprintf("%5.d|%.d|%5.s|%+s|% s|%#s|%0s|", 0, 3, "abc", "p", "q", "r", "s")"#,
             "     |3|     |p|q|r|s|"),
            (#"fmt.Sprintf("%é %世 %d", 1, 2, 3)"#, "%!é(int=1) %!世(int=2) 3"),
            (#"fmt.Sprintf("%t %s %q %x %U", 5, true, true, true, "a")"#,
             "%!t(int=5) %!s(bool=true) %!q(bool=true) %!x(bool=true) %!U(string=a)"),
            (#"fmt.Sprintf("%c %b %o %U %O", "a", "a", "a", true, "a")"#,
             "%!c(string=a) %!b(string=a) %!o(string=a) %!U(bool=true) %!O(string=a)"),
            (#"fmt.Sprintf("%0*d|%-0*d|%*s|%.*x|", 5, 42, 5, 42, -4, "ab", 1, "abc")"#,
             "00042|42   |ab  |61|"),
            (#"fmt.Sprintf("%*", 3)"#, "%!(NOVERB)"),
            (#"fmt.Sprintf("%.*", 3)"#, "%!(NOVERB)"),
            (#"fmt.Sprintf("%*.*d", 4)"#, "%!(BADPREC)%!d(MISSING)"),
        ])
    }

    // MARK: - Mistakes

    @Test func mistakesUseGoMarkers() throws {
        try expectLines([
            (#"fmt.Sprintf("%d %s %t %z %f %!", "hi", 5, 1, 1, 3, 1)"#,
             "%!d(string=hi) %!s(int=5) %!t(int=1) %!z(int=1) %!f(int=3) %!!(int=1)"),
            (#"fmt.Sprintf("%d %x %c", true, false, true)"#,
             "%!d(bool=true) %!x(bool=false) %!c(bool=true)"),
            (#"fmt.Sprintf("%d %d|%s", 1)"#, "1 %!d(MISSING)|%!s(MISSING)"),
            (#"fmt.Sprintf("%d", 1, 2)"#, "1%!(EXTRA int=2)"),
            (#"fmt.Sprintf("hi", "x", 3, true, nil, errBoom)"#,
             "hi%!(EXTRA string=x, int=3, bool=true, <nil>, *errors.errorString=boom)"),
            (#"fmt.Sprintf("100%")"#, "100%!(NOVERB)"),
            (#"fmt.Sprintf("%5")"#, "%!(NOVERB)"),
            (#"fmt.Sprintf("%-")"#, "%!(NOVERB)"),
            (#"fmt.Sprintf("%.")"#, "%!.(MISSING)"),
            (#"fmt.Sprintf("%5.")"#, "%!.(MISSING)"),
            (#"fmt.Sprintf("%10000011d|tail", 1)"#, "%!(NOVERB)%!(EXTRA int=1)"),
            (#"fmt.Sprintf("%.10000011d|tail", 1)"#, "%!(NOVERB)%!(EXTRA int=1)"),
            (#"len(fmt.Sprintf("%1000001d", 1))"#, "1000001"),
        ])
    }

    @Test func starTakesWidthAndPrecisionFromOperands() throws {
        try expectLines([
            (#"fmt.Sprintf("%*d|%-*d|%.*s|%*.*s|", 5, 42, 5, 42, 2, "hello", 6, 3, "hello")"#,
             "   42|42   |he|   hel|"),
            (#"fmt.Sprintf("%*d|%.*d|", -5, 42, -1, 7)"#, "42   |%!(BADPREC)7|"),
            (#"fmt.Sprintf("%*d", "x", 42)"#, "%!(BADWIDTH)42"),
            (#"fmt.Sprintf("%.*d", "x", 42)"#, "%!(BADPREC)42"),
            (#"fmt.Sprintf("%*d")"#, "%!(BADWIDTH)%!d(MISSING)"),
            (#"fmt.Sprintf("%*d", 1000001, 3)"#, "%!(BADWIDTH)3"),
        ])
    }

    @Test func goSyntaxTypeNamesAndArgumentIndexes() throws {
        try expectLines([
            (#"fmt.Sprintf("%#v %#v %#v", 5, "a", nil)"#, #"5 "a" <nil>"#),
            (#"fmt.Sprintf("%T %T %T", 5, "a", nil)"#, "int string <nil>"),
            (#"fmt.Sprintf("%[1]d", 5)"#, "5"),
            (#"fmt.Sprintf("%[2]*[1]d", 5, 3)"#, "  5"),
            (#"fmt.Sprintf("%[2]d %[1]d %d", 1, 2)"#, "2 1 2"),
            (#"fmt.Sprintf("%[3]d", 1)"#, "%!d(BADINDEX)"),
        ])
    }

    // MARK: - Output

    @Test func printfAndFprintfWriteTheFormattedText() throws {
        let output = try runGoMain(
            #"""
            fmt.Printf("%d-%s\n", 1, "a")
            fmt.Printf("no operands\n")
            fmt.Printf("%5.1s|%v\n", "xyz", []byte("ab"))
            fmt.Fprintf(os.Stdout, "%s=%d\n", "n", 2)
            fmt.Fprintf(os.Stderr, "warn %q\n", "x")
            defer fmt.Printf("deferred %d\n", 3)
            defer fmt.Fprintf(os.Stdout, "deferred %s\n", []byte("bytes"))
            """#,
            imports: ["fmt", "os"])

        // A run without a process sends standard error to the same sink.
        #expect(
            output == """
                1-a
                no operands
                    x|[97 98]
                n=2
                warn "x"
                deferred bytes
                deferred 3

                """)
    }

    @Test func fprintfWritesToAnOpenedFileAndSkipsAClosedOne() throws {
        let session = try GoProcessSession([
            "/report": #"""
                package main
                import "fmt"
                import "os"
                func main() {
                    f, err := os.Create("/report.txt")
                    if err != nil {
                        fmt.Printf("create: %v\n", err)
                        return
                    }
                    for i := 1; i <= 3; i++ {
                        fmt.Fprintf(f, "%02d|%-4s|%x\n", i, "ab", []byte{byte(i)})
                    }
                    f.Close()
                    fmt.Fprintf(f, "late %d\n", 4)
                    _, missing := os.Open("/absent")
                    fmt.Printf("%v\n%s\n", missing, fmt.Errorf("wrapped: %w", missing))
                }
                """#
        ])

        #expect(
            session.run("/report")
                == "open /absent: no such file or directory\n"
                + "wrapped: open /absent: no such file or directory")
        #expect(session.fileText("/report.txt") == "01|ab  |01\n02|ab  |02\n03|ab  |03\n")
    }

    // MARK: - Limits and typing

    @Test func aResultIsBoundedLikeAnyString() throws {
        let machine = GoVirtualMachine(
            resourceLimits: GoRuntimeResourceLimits(maximumStringBytes: 64, maximumOutputBytes: 64))
        let fits = try runGoMain(
            #"fmt.Println(len(fmt.Sprintf("%60d", 1)), len(fmt.Sprintf("%s%s", "ab", "cd")))"#,
            machine: machine)
        #expect(fits == "60 4\n")

        for body in [
            #"fmt.Println(len(fmt.Sprintf("%65d", 1)))"#,
            #"fmt.Println(len(fmt.Sprintf("%s|%s", "0123456789012345678901234567890123456789", "0123456789012345678901234")))"#,
            #"fmt.Println(fmt.Errorf("%100s", "x") != nil)"#,
            #"fmt.Println(len(fmt.Sprintf("%20d", []int{1, 2, 3, 4})))"#,
        ] {
            #expect(throws: GoRuntimeError.resourceLimitExceeded("string bytes")) {
                _ = try runGoMain(body, machine: machine)
            }
        }
        #expect(throws: GoRuntimeError.resourceLimitExceeded("output bytes")) {
            _ = try runGoMain(#"fmt.Printf("%100d\n", 1)"#, machine: machine)
        }
    }

    @Test func aLongFormatCostsOneInstruction() throws {
        let output = try runGoMain(
            #"""
            total := 0
            for round := 0; round < 200; round++ {
                total += len(fmt.Sprintf("%4096d|%v", round, []int{1, 2, 3, 4, 5, 6, 7, 8}))
            }
            fmt.Println(total)
            """#,
            machine: GoVirtualMachine(maximumInstructions: 20_000))

        #expect(output == "\(200 * (4096 + 1 + 17))\n")
    }

    @Test func formatCallsAreTypeChecked() {
        func diagnostic(_ body: String) -> String? {
            goMainDiagnostic(body, imports: ["fmt", "os"])
        }
        #expect(
            diagnostic("fmt.Println(fmt.Sprintf())")
                == "wrong number of arguments in call to fmt.Sprintf")
        #expect(diagnostic("fmt.Println(fmt.Sprintf(5))") == "cannot use int as string value")
        #expect(
            diagnostic("fmt.Fprintf(\"%d\", 1)") == "cannot use string as io.Writer value in argument to fmt.Fprintf")
        #expect(
            diagnostic("fmt.Fprintf(os.Stdout)")
                == "wrong number of arguments in call to fmt.Fprintf")
        #expect(
            diagnostic("n := fmt.Printf(\"a\")\nfmt.Println(n)")
                == "multiple-value fmt.Printf() in single-value context")
        #expect(
            diagnostic("n, err, more := fmt.Fprintf(os.Stdout, \"a\")\nfmt.Println(n, err, more)")
                != nil)
        #expect(diagnostic("var n string\nn, _ := fmt.Println()\nfmt.Println(n)") != nil)
        #expect(diagnostic("var n int = fmt.Sprintf(\"a\")\nfmt.Println(n)") != nil)
        #expect(diagnostic("var text string = fmt.Errorf(\"a\")\nfmt.Println(text)") != nil)
        #expect(diagnostic("fmt.Println(fmt.Sprintf(\"%d\", fmt.Println()))") != nil)
        #expect(diagnostic("fmt.Println(fmt.Sscan(1))") == "undefined: fmt.Sscan")
        #expect(diagnostic("var n int = fmt.Sprint(1)\nfmt.Println(n)") != nil)
        #expect(
            diagnostic(
                """
                var text string = fmt.Sprintf("%d", 1) + fmt.Sprint(1, 2) + fmt.Sprintln()
                var failure error = fmt.Errorf("%s", text)
                fmt.Printf("%v\\n", failure)
                fmt.Fprintf(os.Stderr, "%s\\n", text)
                n, err := fmt.Fprintf(os.Stdout, "a")
                n, err = fmt.Println(n, err)
                n, err = fmt.Printf("%d", n)
                """) == nil)
    }

    // MARK: - Scalar functions

    @Test func quotingFollowsStrconv() {
        #expect(GoFormat.quote("plain", asciiOnly: false) == #""plain""#)
        #expect(GoFormat.quote("\u{07}\u{08}\u{0C}\n\r\t\u{0B}\\\"'", asciiOnly: false)
            == #""\a\b\f\n\r\t\v\\\"'""#)
        #expect(GoFormat.quote("\u{1B}\u{7F}\u{80}\u{2028}\u{E000}", asciiOnly: false)
            == #""\x1b\x7f\u0080\u2028\ue000""#)
        #expect(GoFormat.quote("é😀", asciiOnly: false) == #""é😀""#)
        #expect(GoFormat.quote("é😀", asciiOnly: true) == #""\u00e9\U0001f600""#)
        #expect(GoFormat.quote(Unicode.Scalar("'"), asciiOnly: false) == #"'\''"#)
        #expect(GoFormat.quote(Unicode.Scalar("\""), asciiOnly: false) == #"'"'"#)
        #expect(GoUnicode.isPrint(" "))
        #expect(!GoUnicode.isPrint("\u{A0}"))
        #expect(!GoUnicode.isPrint("\t"))
    }

    @Test func paddingCountsCodePoints() {
        var directive = GoFormat.Directive(verb: "s")
        directive.width = 4
        #expect(GoFormat.pad("é", directive) == "   é")
        directive.zero = true
        #expect(GoFormat.pad("é", directive) == "000é")
        directive.minus = true
        #expect(GoFormat.pad("é", directive) == "é   ")
        #expect(GoFormat.pad("abcde", directive) == "abcde")
        directive.width = nil
        #expect(GoFormat.pad("é", directive) == "é")
    }
}
