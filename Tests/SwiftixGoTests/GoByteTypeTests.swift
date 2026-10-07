/// Go `byte`/`uint8`: string indexing, untyped constants, modulo-256
/// arithmetic, `[]byte` slices, and the numeric types that stay unsupported.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go byte type")
struct GoByteTypeTests: GoTestHarness {

    @Test func stringIndexingYieldsBytesUsableWithUntypedConstants() throws {
        let output = try runGoMain(
            """
            s := "A-z9"
            var b byte = 65
            var u uint8 = b
            fmt.Println(s[0] == b, s[1] == 45, 45 == s[1], s[3] - 48, 48 + s[3] - 96, u == s[0])
            fmt.Println(s[2] > 96, s[0] < limit, s[2] - lower, digit(s[3]), isDash(s[1]))
            switch s[1] {
            case 43:
                fmt.Println("plus")
            case 45, dash:
                fmt.Println("dash")
            }
            total := 0
            for i := 0; i < len(s); i++ {
                total = total + int(s[i])
            }
            fmt.Println(total)
            """,
            declarations: """
                const limit = 91
                const lower = 97
                const dash = 126
                func digit(c byte) int { return int(c - 48) }
                func isDash(c byte) bool { return c == 45 }
                """)

        #expect(output == "true true true 9 9 true\ntrue true 25 9 true\ndash\n289\n")
    }

    @Test func arithmeticWrapsModulo256() throws {
        let output = try runGoMain("""
            var b byte = 200
            b = b + 100
            fmt.Println(b, b - 45, b * 7, b / 3, b % 5, -b, +b)
            var z uint8
            z--
            fmt.Println(z)
            z++
            fmt.Println(z, z - 1, 0 - z - 2)
            var m byte = 65
            fmt.Println(^m, m << 4, m >> 1, m << 8, m & 15, m | 128, m ^ 255, m &^ 1)
            one := 1
            fmt.Println(m << one, m >> one, 1 + m + 255, 255 * m)
            """)

        #expect(output == """
            44 255 52 14 4 212 44
            255
            0 255 254
            190 16 32 0 1 193 190 64
            130 32 65 191

            """)
    }

    @Test func byteSlicesSupportTheSliceOperations() throws {
        let output = try runGoMain(
            """
            bs := []byte{104, 105}
            bs = append(bs, 33, 10)
            bs[0] = bs[0] - 32
            fmt.Println(len(bs), cap(bs) >= 4, bs[0], bs[1:3], bs)
            zeros := make([]byte, 2, 8)
            zeros[1] = 255
            zeros[1]++
            fmt.Println(zeros, len(zeros), cap(zeros))
            sum := 0
            for i, v := range bs {
                sum = sum + i + int(v)
            }
            fmt.Println(sum)
            var none []uint8
            fmt.Println(len(none), none == nil)
            var grid [2]byte
            grid[1] = 7
            fmt.Println(grid)
            describe(bs[0])
            """,
            declarations: """
                func describe(boxed any) {
                    asByte, isByte := boxed.(byte)
                    _, isInt := boxed.(int)
                    fmt.Println(asByte, isByte, isInt)
                }
                """)

        #expect(output == """
            4 true 72 [105 33] [72 105 33 10]
            [0 0] 2 8
            226
            0 true
            [0 7]
            72 true false

            """)
    }

    @Test func byteResultsOfMethodsAndInterfacesKeepWrapping() throws {
        let output = try runGoMain(
            """
            var source Source = Fixed{}
            fixed := Fixed{}
            fmt.Println(200 + source.Next(), source.Next() * 3, 200 + fixed.Next(), -source.Next())
            fmt.Println(source.Size() + 1, int(source.Next()) + 200, byte(source.Size()))
            """,
            declarations: """
                type Source interface {
                    Next() byte
                    Size() int
                }
                type Fixed struct {}
                func (f Fixed) Next() byte { return 100 }
                func (f Fixed) Size() int { return 300 }
                """)

        #expect(output == "44 44 44 156\n301 300 44\n")
    }

    @Test func byteAndIntDoNotMixWithoutConversion() {
        let prelude = "s := \"ab\"\ni := 1\nvar b byte = 1\n"
        #expect(goMainDiagnostic(prelude + "var n int = s[0]\nfmt.Println(n, i, b)") == "cannot use byte as int value")
        #expect(goMainDiagnostic(prelude + "fmt.Println(i + s[0], b)") == "mismatched types int and byte")
        #expect(goMainDiagnostic(prelude + "fmt.Println(b == i)") == "mismatched types byte and int")
        #expect(goMainDiagnostic(prelude + "b = i\nfmt.Println(b)") == "cannot use int as byte value")
        #expect(goMainDiagnostic(prelude + "i = b\nfmt.Println(i)") == "cannot use byte as int value")
        #expect(
            goMainDiagnostic(prelude + "fmt.Println(take(b), i)", declarations: "func take(n int) int { return n }")
                == "cannot use byte as int value in argument to take")
        #expect(
            goMainDiagnostic(prelude + "bs := []byte{1}\nbs = append(bs, i)\nfmt.Println(b)")
                == "cannot use int as byte value")
        #expect(
            goMainDiagnostic(
                prelude + "switch b {\ncase i:\n}\nfmt.Println(s)") == "invalid case int in switch on byte")
        #expect(
            goMainDiagnostic(prelude + "fmt.Println(b + typed, i)", declarations: "const typed int = 1")
                == "mismatched types byte and int")
    }

    @Test func constantsMustFitInAByte() {
        #expect(goMainDiagnostic("var b byte = 256\nfmt.Println(b)") == "constant 256 overflows byte")
        #expect(goMainDiagnostic("var b uint8 = -1\nfmt.Println(b)") == "constant -1 overflows byte")
        #expect(goMainDiagnostic("s := \"a\"\nfmt.Println(s[0] == 300)") == "constant 300 overflows byte")
        #expect(goMainDiagnostic("s := \"a\"\nfmt.Println(s[0] + 128 * 2)") == "constant 256 overflows byte")
        #expect(goMainDiagnostic("bs := []byte{1, 999}\nfmt.Println(bs)") == "constant 999 overflows byte")
        #expect(
            goMainDiagnostic("var b byte = big\nfmt.Println(b)", declarations: "const big = 1 << 8")
                == "constant 256 overflows byte")
        #expect(goMainDiagnostic("var b byte = 255\nfmt.Println(b)") == nil)
    }

    @Test func otherNumericTypesAreReportedAsUnsupported() {
        for name in ["int8", "int16", "int32", "int64", "uint", "uint16", "uint32", "uint64",
            "uintptr", "float32", "float64", "rune"]
        {
            let expected = "type \(name) is not supported; the integer types are int, byte, and uint8"
            #expect(goMainDiagnostic("var x \(name)\nfmt.Println(x)") == expected)
            #expect(goMainDiagnostic("fmt.Println(\(name)(1))") == expected)
            #expect(
                goMainDiagnostic("fmt.Println(1)", declarations: "func f(x []\(name)) {}") == expected)
        }
        #expect(
            goMainDiagnostic("fmt.Println(1)", declarations: "type byte int")
                == "cannot redeclare predeclared type byte")
        #expect(
            goMainDiagnostic("fmt.Println('a')")
                == "rune literals are not supported; use the integer code point")
        // A user declaration still takes the name.
        #expect(goMainDiagnostic("var x int64 = 3\nfmt.Println(x)", declarations: "type int64 int") == nil)
    }

    @Test func namedIntegerTypesAcceptUntypedConstants() throws {
        let output = try runGoMain(
            """
            var c Celsius = 20
            c = c + 5
            c++
            var d Digit = 250
            d = d + 10
            fmt.Println(c, c == 26, c > limit, d, d == 4)
            """,
            declarations: """
                type Celsius int
                type Digit byte
                const limit = 10
                """)

        #expect(output == "26 true true 4 true\n")
    }
}
