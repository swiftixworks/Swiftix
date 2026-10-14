/// Rune literals, `'a'`: the code point of one character, written as itself
/// or as an escape.
///
/// A rune literal is an untyped constant whose default type is `rune`: a
/// variable a literal initializes is an `int32`, as in Go (see
/// `GoSizedIntegerTests`). Its value, and what it does as a `byte`, an
/// index, or an operand, are Go's.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change. How `gofmt` leaves the literals alone is compared with
/// Go's in `GoGofmtConformanceTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go rune literals")
struct GoRuneLiteralTests: GoTestHarness {

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

    /// The lexer gives a rune literal as it is spelled, which says that it
    /// is one; its value is the code point.
    @Test func aRuneLiteralIsOneToken() throws {
        let tokens = try GoLexer.tokenize(
            GoSourceFile(path: "main.go", text: #"x := 'a' + '\n' - '\x41' * '世'"#))
        let integers = tokens.compactMap { token -> Int64? in
            if case .identifier(let spelling) = token.kind { return GoLiteral.runeValue(spelling) }
            return nil
        }

        #expect(integers == [97, 10, 65, 19990])
        // A quote inside a string or a comment starts no literal.
        let quoted = try GoLexer.tokenize(
            GoSourceFile(path: "main.go", text: "s := \"it's\" // don't\n"))
        #expect(quoted.contains { $0.kind == .string("it's") })
    }

    /// One character of any length in UTF-8 is one literal.
    @Test func aRuneLiteralIsTheCodePointOfItsCharacter() throws {
        #expect(
            try runGoMain(
                """
                fmt.Println('a', 'A', '0', ' ', '~')
                fmt.Println('é', '世', '😀', '"', '{', '}', '/', '`')
                """)
                == "97 65 48 32 126\n233 19990 128512 34 123 125 47 96\n")
    }

    /// The escapes of one character, of a byte in hexadecimal or octal, and of
    /// a code point. `\'` is one in a rune literal and `\"` is not.
    @Test func escapesAreTheOnesOfGo() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Println('\a', '\b', '\f', '\n', '\r', '\t', '\v', '\\', '\'')
                fmt.Println('\x41', '\x7f', '\xff', '\101', '\000', '\377')
                fmt.Println('\u00e9', '\u4e16', '\U0001F600', '\U0010FFFF')
                """#)
                == "7 8 12 10 13 9 11 92 39\n65 127 255 65 0 255\n233 19990 128512 1114111\n")
    }

    /// It is a constant: it names one, takes part in constant arithmetic, and
    /// becomes a `byte` where one is wanted.
    @Test func aRuneLiteralIsAnUntypedConstant() throws {
        #expect(
            try runGoMain(
                #"""
                var b byte = 'q'
                codes := map[byte]string{'+': "plus", '-': "minus"}
                word := []byte{'h', 'i'}
                word[0] -= 'a' - 'A'
                fmt.Println(value("a12b3"), limit, b, codes['+'], string(word), space)
                switch b {
                case 'p', 'q':
                    fmt.Println(string('a'+1), 'a' < 'b', "x"+string('y'))
                }
                fmt.Printf("%c%c %d %q %U %x\n", 'G', 'o', 'x', 'x', 'x', 'x')
                """#,
                declarations: """
                    const (
                        zero  = '0'
                        space = ' '
                        limit = 'z' - 'a' + 1
                    )

                    func isDigit(c byte) bool { return c >= '0' && c <= '9' }

                    func value(text string) int {
                        n := 0
                        for i := 0; i < len(text); i++ {
                            if isDigit(text[i]) {
                                n = n*10 + int(text[i]-zero)
                            }
                        }
                        return n
                    }
                    """)
                == "123 26 113 plus Hi 32\nb true xy\nGo 120 'x' U+0078 78\n")
        #expect(
            try runGoMain(
                """
                line := "key=value;next"
                for i := 0; i < len(line); i++ {
                    switch line[i] {
                    case '=':
                        fmt.Print(" is ")
                    case ';':
                        fmt.Println()
                    default:
                        fmt.Print(string(line[i]))
                    }
                }
                fmt.Println()
                """)
                == "key is value\nnext\n")
    }

    /// An error about what is between the quotes is reported at the character
    /// it is about, one about the whole literal where the literal starts.
    @Test func malformedLiteralsAreReportedAsGoReportsThem() {
        #expect(
            firstError("fmt.Println('')")
                == "5:14: empty rune literal or unescaped '")
        #expect(
            firstError("fmt.Println(''')")
                == "5:14: empty rune literal or unescaped '")
        #expect(
            firstError("fmt.Println('ab')")
                == "5:13: more than one character in rune literal")
        #expect(
            firstError("fmt.Println('a)")
                == "5:16: newline in rune literal")
        #expect(
            firstError(
                """
                fmt.Println('ab
                )
                """)
                == "5:16: newline in rune literal")
        #expect(
            firstError(
                #"""
                fmt.Println('\q')
                """#)
                == "5:15: unknown escape")
        #expect(
            firstError(
                #"""
                fmt.Println('\"')
                """#)
                == "5:15: unknown escape")
        #expect(
            firstError(
                #"""
                fmt.Println('\9')
                """#)
                == "5:15: unknown escape")
        #expect(
            firstError(
                #"""
                fmt.Println('\08')
                """#)
                == "5:16: invalid character '8' in octal escape")
        #expect(
            firstError(
                #"""
                fmt.Println('\400')
                """#)
                == "5:18: octal escape value 256 > 255")
        #expect(
            firstError(
                #"""
                fmt.Println('\x4')
                """#)
                == "5:17: invalid character '\\'' in hexadecimal escape")
        #expect(
            firstError(
                #"""
                fmt.Println('\xg1')
                """#)
                == "5:16: invalid character 'g' in hexadecimal escape")
        #expect(
            firstError(
                #"""
                fmt.Println('\u12')
                """#)
                == "5:18: invalid character '\\'' in hexadecimal escape")
        #expect(
            firstError(
                #"""
                fmt.Println('\uD800')
                """#)
                == "5:20: escape is invalid Unicode code point U+D800")
        #expect(
            firstError(
                #"""
                fmt.Println('\U00110000')
                """#)
                == "5:24: escape is invalid Unicode code point U+110000")
    }

    /// A string literal has the escapes of a rune literal, with `\"` in place
    /// of `\'`, and the same errors for them.
    @Test func escapesInStringsAreReportedTheSameWay() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Println("\a\b\f\v" == "\x07\x08\x0c\x0b", "\101\x42\u0043\U00000044")
                fmt.Println("it's", "\"q\"", len("\u00e9"), len("\xc3\xa9"))
                """#)
                == "true ABCD\nit's \"q\" 2 2\n")
        #expect(
            firstError(
                #"""
                fmt.Println("\q")
                """#)
                == "5:15: unknown escape")
        #expect(
            firstError(
                #"""
                fmt.Println("\'")
                """#)
                == "5:15: unknown escape")
        #expect(
            firstError(
                #"""
                fmt.Println("\400")
                """#)
                == "5:18: octal escape value 256 > 255")
        #expect(
            firstError(
                #"""
                fmt.Println("a\x4")
                """#)
                == "5:18: invalid character '\"' in hexadecimal escape")
        #expect(
            firstError(
                #"""
                fmt.Println("\xzz")
                """#)
                == "5:16: invalid character 'z' in hexadecimal escape")
        #expect(
            firstError(
                #"""
                fmt.Println("\uD800")
                """#)
                == "5:20: escape is invalid Unicode code point U+D800")
        #expect(
            firstError(
                #"""
                fmt.Println("ok\U0011FFFFx")
                """#)
                == "5:26: escape is invalid Unicode code point U+11FFFF")
        #expect(
            firstError("fmt.Println(\"abc)")
                == "5:18: newline in string")
    }

    /// A code point above 255 is no `byte`; one that fits wraps like any other
    /// `byte` when a sum leaves the range.
    @Test func aRuneLiteralThatIsNoByteOverflowsOne() throws {
        #expect(
            firstError(
                """
                var b byte = '世'
                _ = b
                """)
                == "5:14: cannot use '世' (untyped rune constant 19990) as byte value in variable declaration (overflows)")
        #expect(
            firstError(
                """
                b := []byte{'a', '世'}
                _ = b
                """)
                == "5:18: cannot use '世' (untyped rune constant 19990) as byte value in array or slice literal (overflows)")
        #expect(
            try runGoMain(
                """
                var b byte = 'é'
                fmt.Println(b, b+'é', 'é'+'é')
                """)
                == "233 210 466\n")
    }
}
