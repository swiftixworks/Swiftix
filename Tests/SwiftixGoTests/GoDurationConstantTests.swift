/// The units of `time` are constants of type `time.Duration` to the
/// compiler, as in Go: `const timeout = 5 * time.Second` is a constant, an
/// expression of them folds exactly, and one its type cannot hold is Go's
/// compile error, as an overflowing constant of a type the program defines
/// over an integer is.
///
/// A duration is an `int64`, which the VM computes exactly, so a program
/// that compiled before compiles to the same image. Every expected output
/// and error here was taken from Go 1.24.5.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go duration constants")
struct GoDurationConstantTests: GoTestHarness {

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

    /// Constants made of the units, at package level and in a function, in a
    /// `switch` case, and as the length of an array.
    @Test func theUnitsAreConstants() throws {
        #expect(
            try runGoMain(
                #"""
                const local = 3 * time.Minute
                const x = time.Hour * 24
                fmt.Println(timeout, half, local, len(arr), len(lengths))
                fmt.Printf("%T %v %T\n", x, x, half)
                switch time.Duration(5e9) {
                case timeout:
                    fmt.Println("timeout")
                }
                d := 2 * time.Hour
                var e time.Duration = 7
                fmt.Println(d, e*time.Millisecond, time.Duration(3)*time.Microsecond, time.Second/3)
                """#,
                imports: ["fmt", "time"],
                declarations: """
                    const timeout = 5 * time.Second
                    const half = timeout / 2

                    var arr [int64(time.Second / time.Millisecond)]byte
                    var lengths [time.Minute / time.Second]int
                    """)
                == """
                5s 2.5s 3m0s 1000 60
                time.Duration 24h0m0s time.Duration
                timeout
                2h0m0s 7ms 3µs 333.333333ms

                """)
    }

    /// What `time.Duration`, an `int64`, cannot hold, at package level, in a
    /// function, and where an untyped operand would fit and the product does not.
    @Test func anOverflowingDurationIsAnError() {
        #expect(
            firstError("fmt.Println(big)", imports: ["fmt", "time"],
                declarations: "const big = 1000000 * time.Hour * 1000")
                == "4:13: 1000000 * time.Hour * 1000 (constant 3600000000000000000000 of int64 type time.Duration) overflows int64")
        #expect(
            firstError(
                """
                const c = 300 * time.Hour * 100000
                fmt.Println(c)
                """,
                imports: ["fmt", "time"])
                == "6:11: 300 * time.Hour * 100000 (constant 108000000000000000000 of int64 type time.Duration) overflows int64")
        #expect(
            firstError("fmt.Println(time.Hour * 1e10)", imports: ["fmt", "time"])
                == "6:13: time.Hour * 1e10 (constant 36000000000000000000000 of int64 type time.Duration) overflows int64")
        #expect(
            firstError("fmt.Println(x)", imports: ["fmt", "time"],
                declarations: "var x = 1e7 * time.Hour")
                == "4:9: 1e7 * time.Hour (constant 36000000000000000000 of int64 type time.Duration) overflows int64")
        #expect(
            firstError("fmt.Println(time.Duration(1<<63-1) + time.Nanosecond)", imports: ["fmt", "time"])
                == "6:13: time.Duration(1 << 63 - 1) + time.Nanosecond (constant 9223372036854775808 of int64 type time.Duration) overflows int64")
        #expect(
            firstError("fmt.Println(2.5 * time.Second)", imports: ["fmt", "time"])
                == "6:13: 2.5 (untyped float constant) truncated to int64")
        #expect(
            firstError(
                """
                var d time.Duration = 1 << 63
                fmt.Println(d)
                """,
                imports: ["fmt", "time"])
                == "6:23: cannot use 1 << 63 (untyped int constant 9223372036854775808) as time.Duration value in variable declaration (overflows)")
        #expect(
            firstError(
                """
                const s = time.Second
                var f float64 = s
                fmt.Println(f)
                """,
                imports: ["fmt", "time"])
                == "7:17: cannot use s (constant 1000000000 of int64 type time.Duration) as float64 value in variable declaration")
    }

    /// Go names the basic type underneath a defined one where a constant of it
    /// does not fit, at package level as in a function.
    @Test func anOverflowNamesTheBasicType() {
        #expect(
            firstError("fmt.Println(b)", imports: ["fmt"],
                declarations: """
                    type D int64

                    const a D = 1 << 62
                    const b = a * 4
                    """)
                == "6:11: a * 4 (constant 18446744073709551616 of int64 type D) overflows int64")
        #expect(
            firstError("fmt.Println(a * 2.5)", imports: ["fmt"],
                declarations: """
                    type D int64

                    const a D = 1 << 62
                    """)
                == "7:17: 2.5 (untyped float constant) truncated to int64")
        #expect(
            firstError("fmt.Println(a * 2)", imports: ["fmt"],
                declarations: """
                    type D int8

                    const a D = 100
                    """)
                == "7:13: a * 2 (constant 200 of int8 type D) overflows int8")
        #expect(
            firstError("fmt.Println(-a)", imports: ["fmt"],
                declarations: """
                    type D uint8

                    const a D = 100
                    """)
                == "7:13: -a (constant -100 of uint8 type D) overflows uint8")
        #expect(
            firstError("fmt.Println(y)", imports: ["fmt"],
                declarations: """
                    const x int8 = 100
                    const y = x + 100
                    """)
                == "4:11: x + 100 (constant 200 of type int8) overflows int8")
    }
}
