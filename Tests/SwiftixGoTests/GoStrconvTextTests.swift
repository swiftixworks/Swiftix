/// The functions of `strconv` that are Go text of the library
/// (`Sources/SwiftixGoLibrary/strconv`): `Quote`, `QuoteToASCII`, `Unquote`,
/// `FormatBool`, `ParseBool`, `AppendInt`, `AppendQuote`, and with them
/// `ErrSyntax`, `ErrRange`, and `NumError`, which `ParseBool` returns as Go
/// does. The numbers stay natives, and their errors stay texts.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports. The text
/// itself is held to Go's `strconv` with random inputs by
/// `Scripts/go-library-harness/run.sh strconv`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go strconv in Go text")
struct GoStrconvTextTests: GoTestHarness {

    /// The first error of compiling `body` as the body of `func main`, as
    /// `line:column: message`: what Go prints after the name of the file.
    private func firstError(
        _ body: String, imports: [String] = ["fmt"], declarations: String = ""
    ) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [
                GoSourceFile(
                    path: "main.go",
                    text: goMainSource(body, imports: imports, declarations: declarations))
            ])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return String(diagnostic.description.dropFirst("main.go:".count))
        } catch {
            return String(describing: error)
        }
    }

    /// `Quote` and `QuoteToASCII` write a string as a literal of Go, and
    /// `AppendQuote` appends one.
    @Test func quoting() throws {
        #expect(
            try runGoMain(
                #"""
                for _, s := range []string{"", "plain", "tab\there", "line\n", `back\slash "quoted" 'single'`, "héllo 世界", "\u00a0nbsp \u2028 \u200b", "bell\a\b\f\r\v", "nul\x00del\x7f", "😀", "\ufffd"} {
                    fmt.Println(strconv.Quote(s), strconv.QuoteToASCII(s), string(strconv.AppendQuote([]byte("x="), s)))
                }
                """#,
                imports: ["fmt", "strconv"])
                == #"""
                "" "" x=""
                "plain" "plain" x="plain"
                "tab\there" "tab\there" x="tab\there"
                "line\n" "line\n" x="line\n"
                "back\\slash \"quoted\" 'single'" "back\\slash \"quoted\" 'single'" x="back\\slash \"quoted\" 'single'"
                "héllo 世界" "h\u00e9llo \u4e16\u754c" x="héllo 世界"
                "\u00a0nbsp \u2028 \u200b" "\u00a0nbsp \u2028 \u200b" x="\u00a0nbsp \u2028 \u200b"
                "bell\a\b\f\r\v" "bell\a\b\f\r\v" x="bell\a\b\f\r\v"
                "nul\x00del\x7f" "nul\x00del\x7f" x="nul\x00del\x7f"
                "😀" "\U0001f600" x="😀"
                "�" "\ufffd" x="�"

                """#)
    }

    /// `Unquote` reads the three kinds of literal with every escape, and gives
    /// `strconv.ErrSyntax` itself for anything else.
    @Test func unquoting() throws {
        #expect(
            try runGoMain(
                #"""
                literals := []string{
                    `"plain"`, `""`, `"tab\there"`, `"\a\b\f\n\r\t\v\\\""`, `"\u00e9 \U0001F600 \x41 \101 \000"`, `"héllo 世界"`,
                    "`raw \\n text`", "`with\rreturn`", "``", `'a'`, `'\n'`, `'世'`, `'\''`, `'\\u4e16'`, `'\x41'`, `''`,
                    `"`, ``, `x`, `"abc`, `abc"`, `"a"b"`, `"\q"`, `"\x4"`, `"\xzz"`, `"\\ud800"`, `"\U00110000"`, `"\400"`, `"\08"`, `"\'"`,
                    `'ab'`, `'\"'`, `'a`, "`a`b`", "\"line\nbreak\"", `"a" `, ` "a"`, `"\`, `"\"`, `"\\u12"`, `'\101'`, `"😀"`,
                }
                for _, s := range literals {
                    got, err := strconv.Unquote(s)
                    fmt.Printf("%q -> %q %v %v\n", s, got, err, err == strconv.ErrSyntax)
                }
                for _, s := range []string{"round trip", "with \"quotes\" and \\", "世界\t\x00"} {
                    back, err := strconv.Unquote(strconv.Quote(s))
                    ascii, _ := strconv.Unquote(strconv.QuoteToASCII(s))
                    fmt.Println(back == s, ascii == s, err)
                }
                """#,
                imports: ["fmt", "strconv"])
                == #"""
                "\"plain\"" -> "plain" <nil> false
                "\"\"" -> "" <nil> false
                "\"tab\\there\"" -> "tab\there" <nil> false
                "\"\\a\\b\\f\\n\\r\\t\\v\\\\\\\"\"" -> "\a\b\f\n\r\t\v\\\"" <nil> false
                "\"\\u00e9 \\U0001F600 \\x41 \\101 \\000\"" -> "é 😀 A A \x00" <nil> false
                "\"héllo 世界\"" -> "héllo 世界" <nil> false
                "`raw \\n text`" -> "raw \\n text" <nil> false
                "`with\rreturn`" -> "withreturn" <nil> false
                "``" -> "" <nil> false
                "'a'" -> "a" <nil> false
                "'\\n'" -> "\n" <nil> false
                "'世'" -> "世" <nil> false
                "'\\''" -> "'" <nil> false
                "'\\\\u4e16'" -> "" invalid syntax true
                "'\\x41'" -> "A" <nil> false
                "''" -> "" <nil> false
                "\"" -> "" invalid syntax true
                "" -> "" invalid syntax true
                "x" -> "" invalid syntax true
                "\"abc" -> "" invalid syntax true
                "abc\"" -> "" invalid syntax true
                "\"a\"b\"" -> "" invalid syntax true
                "\"\\q\"" -> "" invalid syntax true
                "\"\\x4\"" -> "" invalid syntax true
                "\"\\xzz\"" -> "" invalid syntax true
                "\"\\\\ud800\"" -> "\\ud800" <nil> false
                "\"\\U00110000\"" -> "" invalid syntax true
                "\"\\400\"" -> "" invalid syntax true
                "\"\\08\"" -> "" invalid syntax true
                "\"\\'\"" -> "" invalid syntax true
                "'ab'" -> "" invalid syntax true
                "'\\\"'" -> "" invalid syntax true
                "'a" -> "" invalid syntax true
                "`a`b`" -> "" invalid syntax true
                "\"line\nbreak\"" -> "" invalid syntax true
                "\"a\" " -> "" invalid syntax true
                " \"a\"" -> "" invalid syntax true
                "\"\\" -> "" invalid syntax true
                "\"\\\"" -> "" invalid syntax true
                "\"\\\\u12\"" -> "\\u12" <nil> false
                "'\\101'" -> "A" <nil> false
                "\"😀\"" -> "😀" <nil> false
                true true <nil>
                true true <nil>
                true true <nil>

                """#)
    }

    /// `FormatBool`, and `ParseBool` with the twelve spellings Go reads. Its
    /// error is a `*strconv.NumError` that wraps `ErrSyntax`.
    @Test func booleans() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Println(strconv.FormatBool(true), strconv.FormatBool(false), strconv.FormatBool(1 < 2))
                for _, s := range []string{"1", "t", "T", "TRUE", "true", "True", "0", "f", "F", "FALSE", "false", "False", "", "yes", "tRUE", " true", "2", "x\"y"} {
                    b, err := strconv.ParseBool(s)
                    fmt.Println(b, err)
                }
                _, err := strconv.ParseBool("maybe")
                fmt.Printf("%T %v\n", err, errors.Is(err, strconv.ErrSyntax))
                var numError *strconv.NumError
                if errors.As(err, &numError) {
                    fmt.Println(numError.Func, numError.Num, numError.Err, numError.Unwrap() == strconv.ErrSyntax)
                }
                if e, ok := err.(*strconv.NumError); ok {
                    fmt.Println(e.Error())
                }
                fmt.Println(strconv.ErrSyntax, strconv.ErrRange)
                made := &strconv.NumError{Func: "Atoi", Num: "9x", Err: strconv.ErrRange}
                fmt.Println(made, errors.Is(made, strconv.ErrRange))
                """#,
                imports: ["errors", "fmt", "strconv"])
                == #"""
                true false true
                true <nil>
                true <nil>
                true <nil>
                true <nil>
                true <nil>
                true <nil>
                false <nil>
                false <nil>
                false <nil>
                false <nil>
                false <nil>
                false <nil>
                false strconv.ParseBool: parsing "": invalid syntax
                false strconv.ParseBool: parsing "yes": invalid syntax
                false strconv.ParseBool: parsing "tRUE": invalid syntax
                false strconv.ParseBool: parsing " true": invalid syntax
                false strconv.ParseBool: parsing "2": invalid syntax
                false strconv.ParseBool: parsing "x\"y": invalid syntax
                *strconv.NumError true
                ParseBool maybe invalid syntax true
                strconv.ParseBool: parsing "maybe": invalid syntax
                invalid syntax value out of range
                strconv.Atoi: parsing "9x": value out of range true

                """#)
    }

    /// `AppendInt` in any base, and its panic for a base that is none.
    @Test func appending() throws {
        #expect(
            try runGoMain(
                """
                b := []byte("n=")
                b = strconv.AppendInt(b, -42, 10)
                b = append(b, ' ')
                b = strconv.AppendInt(b, 255, 16)
                b = append(b, ' ')
                b = strconv.AppendInt(b, 1<<62, 36)
                b = strconv.AppendInt(b, 0, 2)
                fmt.Println(string(b), string(strconv.AppendInt(nil, -9223372036854775808, 2)))
                var i int64 = 7
                fmt.Println(string(strconv.AppendQuote(strconv.AppendInt(nil, i, 10), "x")))
                defer func() { fmt.Println(recover()) }()
                strconv.AppendInt(nil, 1, 37)
                """,
                imports: ["fmt", "strconv"])
                == """
                n=-42 ff z1ci99jj74740 -1000000000000000000000000000000000000000000000000000000000000000
                7"x"
                strconv: illegal AppendInt/FormatInt base

                """)
    }

    /// A wrong argument is Go's error at Go's place.
    @Test func theTextIsCheckedLikeGo() {
        #expect(
            firstError("fmt.Println(strconv.Quote(1))", imports: ["fmt", "strconv"])
                == "6:27: cannot use 1 (untyped int constant) as string value in argument to strconv.Quote")
        #expect(
            firstError("fmt.Println(strconv.FormatBool(\"true\"))", imports: ["fmt", "strconv"])
                == "6:32: cannot use \"true\" (untyped string constant) as bool value in argument to strconv.FormatBool")
        #expect(
            firstError(
                """
                b := strconv.ParseBool("true")
                fmt.Println(b)
                """,
                imports: ["fmt", "strconv"])
                == "6:6: assignment mismatch: 1 variable but strconv.ParseBool returns 2 values")
        #expect(
            firstError("fmt.Println(strconv.AppendInt(nil, \"1\", 10))", imports: ["fmt", "strconv"])
                == "6:36: cannot use \"1\" (untyped string constant) as int64 value in argument to strconv.AppendInt")
        #expect(
            firstError(
                """
                var s string = strconv.Unquote("x")
                fmt.Println(s)
                """,
                imports: ["fmt", "strconv"])
                == "6:16: multiple-value strconv.Unquote(\"x\") (value of type (string, error)) in single-value context")
        #expect(
            firstError("fmt.Println(strconv.NoSuchThing(1))", imports: ["fmt", "strconv"])
                == "6:21: undefined: strconv.NoSuchThing")
    }
}
