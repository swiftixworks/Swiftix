/// `iota` is the constant generator only where nothing else is called
/// `iota`, and a constant has a value Go can compute.
///
/// The parser replaces `iota` by the index of its specification, so it is
/// the parser that keeps count of the blocks that are open and of the first
/// of them that declares the name: a variable, a constant, a parameter, a
/// result, or a function. Inside that block `iota` is left a name, and what
/// it names is no constant unless it is one.
///
/// What each program prints is what Go 1.24.5 prints for it. An error pinned
/// with its place is at the place of the first one Go's compiler reports;
/// where the message is Go's too it was copied without change, and otherwise
/// it is this dialect's, which names a value by its type.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go iota and constant values")
struct GoIotaScopeTests: GoTestHarness {

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

    /// From its own specification on, to the end of its block; in the
    /// package, for the whole file.
    @Test func aConstantNamedIotaHidesTheGenerator() throws {
        #expect(
            try runGoMain(
                """
                const (
                    c = iota
                    d
                )
                {
                    const iota = 9
                    const (
                        e = iota
                        f
                    )
                    {
                        const (
                            g = iota + 1
                            h
                        )
                        fmt.Println(e, f, g, h)
                    }
                }
                const (
                    i = iota
                    j
                )
                const iota = iota + 4
                const k = iota
                const (
                    l = iota
                    m
                )
                fmt.Println(a, b, c, d, i, j, k, l, m, iota)
                """,
                declarations: """
                    const (
                        a = iota
                        b
                    )
                    """)
                == "9 9 10 10\n0 1 0 1 0 1 4 4 4 4\n")
        #expect(
            try runGoMain(
                """
                const (
                    iota = iota + 4
                    b
                    c = iota
                )
                const iota2 = "s"
                fmt.Println(iota, b, c, x, y, z)
                """,
                declarations: """
                    const (
                        x = iota
                        y
                        z = iota + 1
                    )

                    const iota = 5
                    """)
                == "9 13 9 5 5 6\n")
    }

    /// Go's report is of the name, where the `const` uses it.
    @Test func aVariableOrAFunctionNamedIotaIsNoConstant() {
        #expect(
            firstError(
                """
                iota := 5
                const c = iota
                fmt.Println(c, iota)
                """)
                == "6:11: iota (variable of type int) is not constant")
        #expect(
            firstError("", declarations: """
                    func f(iota int) int {
                        const c = iota
                        return c
                    }
                    """)
                == "4:15: iota (variable of type int) is not constant")
        #expect(
            firstError(
                """
                if iota := 3; iota > 2 {
                    const c = iota
                    fmt.Println(c)
                }
                """)
                == "6:15: iota (variable of type int) is not constant")
        #expect(
            firstError("", declarations: """
                    func iota() int { return 7 }

                    const c = iota
                    """)
                == "5:11: iota (value of type func() int) is not constant")
        #expect(
            firstError("", declarations: """
                    const c = iota

                    var iota = 3
                    """)
                == "3:11: iota (variable of type int) is not constant")
    }

    /// A name that is out of scope hides nothing, and a `const` that does
    /// not use the name does not care what it is.
    @Test func elsewhereTheNameIsFree() throws {
        #expect(
            try runGoMain(
                """
                {
                    const iota = 4
                    _ = iota
                }
                for iota := 0; iota < 2; iota++ {
                    fmt.Print(iota, " ")
                }
                for _, iota := range []int{7} {
                    fmt.Print(iota, " ")
                }
                double := func(iota int) int { return iota * 2 }
                const (
                    a = iota
                    b
                )
                fmt.Println(a, b, double(4), sum(10), named())
                """,
                declarations: """
                    func sum(iota int) int {
                        const (
                            one = 1
                            two = 2
                        )
                        return iota + one + two
                    }

                    func named() (iota int) {
                        const c = 2
                        iota = c
                        return
                    }
                    """)
                == "0 1 7 0 1 8 13 2\n")
        #expect(
            firstError(
                """
                x := iota
                fmt.Println(x)
                """)
                == "5:6: cannot use iota outside constant declaration")
    }

    /// A variable, a call, and what is built at run time are refused where
    /// the value begins. Go's report of a variable is kept; of another expression
    /// this dialect says the type of its value.
    @Test func theValueOfAConstantIsOne() throws {
        #expect(
            try runGoMain(
                """
                const c = len("abc")
                const d = "a" + "b"
                const e = 1 << 3
                const f = c + e*2
                const g = c > 2
                const h = !g
                const i = byte(65)
                const j = string(i)
                const k = -c
                const l = ^c
                type number int
                const m = number(4)
                const n number = 5
                var list [4]int
                const o = len(list)
                fmt.Println(c, d, e, f, g, h, i, j, k, l, m, n, o, big, text, size)
                """,
                declarations: """
                    const big = 1 << 40
                    const text = "x" + "y"
                    const size = len(text)
                    """)
                == "3 ab 8 19 true false 65 A -3 -4 4 5 4 1099511627776 xy 2\n")
        #expect(
            firstError("", declarations: """
                    var v = 3

                    const c = v
                    """)
                == "5:11: v (variable of type int) is not constant")
        #expect(
            firstError(
                """
                x := 3
                const a, b = 1, x
                fmt.Println(a, b)
                """)
                == "6:17: x (variable of type int) is not constant")
        #expect(
            firstError("", declarations: """
                    var v = 3

                    const c = v + 1
                    """)
                == "5:11: v + 1 (value of type int) is not constant")
        #expect(
            firstError("", declarations: """
                    func f() int { return 1 }

                    const c = f()
                    """)
                == "5:11: f() (value of type int) is not constant")
        #expect(
            firstError(
                """
                s := "abc"
                const c = len(s)
                fmt.Println(c)
                """)
                == "6:11: len(s) (value of type int) is not constant")
        #expect(
            firstError(
                """
                const a = []int{1}
                fmt.Println(a)
                """)
                == "5:11: []int{…} (value of type []int) is not constant")
        #expect(
            firstError(
                """
                const c = "abc"[1]
                fmt.Println(c)
                """)
                == "5:11: \"abc\"[1] (value of type byte) is not constant")
        #expect(
            firstError(
                """
                var p *int
                const c = p == nil
                fmt.Println(c)
                """)
                == "6:11: p == nil (untyped bool value) is not constant")
        #expect(
            firstError("", declarations: """
                    type t struct{ n int }

                    var v = t{1}

                    const c = v.n
                    """)
                == "7:11: v.n (variable of type int) is not constant")
    }
}
