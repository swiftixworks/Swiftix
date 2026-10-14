/// Expression switches: `fallthrough`, the cases Go allows and refuses,
/// and when a `switch`, a `select`, or a loop ends its function.
///
/// `fallthrough` is a call no program can write (`GoBranch`), which the
/// clause it ends turns into a jump to the body of the next. Whether a
/// statement ends a function is Go's rule for a terminating statement
/// (`GoTermination`).
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change. Go quotes the operand in a few of these messages, which
/// this dialect does not; those tests say so, and the place is still Go's.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go switch statements")
struct GoSwitchStatementTests: GoTestHarness {

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

    /// The body of the next clause runs without its cases being asked,
    /// `default` included, wherever it is written; several in a row chain.
    @Test func fallthroughGoesOnWithTheNextClause() throws {
        #expect(
            try runGoMain(
                """
                for x := 1; x <= 4; x++ {
                    switch x {
                    case 1:
                        fmt.Println("one")
                        fallthrough
                    case 2:
                        fmt.Println("two")
                        fallthrough
                    case 3:
                        fmt.Println("three")
                    case 4:
                        fmt.Println("four")
                    }
                }
                x := 9
                switch {
                case x > 5:
                    fmt.Println(">5")
                    fallthrough
                default:
                    fmt.Println("default")
                    fallthrough
                case x > 100:
                    fmt.Println(">100")
                }
                for i := 0; i < 4; i++ {
                    switch i {
                    case 0:
                        fallthrough
                    case 1:
                        fmt.Println("low", i)
                    default:
                        fmt.Println("high", i)
                    case 2:
                        fmt.Println("two")
                        fallthrough
                    case 7:
                        fmt.Println("seven-ish")
                    }
                }
                """)
                == """
                one
                two
                three
                two
                three
                three
                four
                >5
                default
                >100
                low 0
                low 1
                two
                seven-ish
                high 3

                """)
    }

    /// A `break` in the clause leaves the switch before its `fallthrough`
    /// is reached, in a switch that has an initializer as well.
    @Test func breakBeforeFallthroughLeavesTheSwitch() throws {
        #expect(
            try runGoMain(
                """
                switch x := 1; x {
                case 1:
                    if x > 0 {
                        break
                    }
                    fallthrough
                case 2:
                    fmt.Println("two")
                }
                fmt.Println("end")
                """)
                == "end\n")
    }

    /// It is the last statement of a clause that is not the last: not in a
    /// block of the clause, not before another statement, and not outside a switch.
    @Test func fallthroughHasOnePlace() {
        #expect(
            firstError(
                """
                switch {
                case true:
                    fallthrough
                }
                """)
                == "7:5: cannot fallthrough final case in switch")
        #expect(
            firstError(
                """
                switch {
                case true:
                    fallthrough
                    fmt.Println()
                case false:
                }
                """)
                == "7:5: fallthrough statement out of place")
        #expect(
            firstError(
                """
                switch {
                case true:
                    if true {
                        fallthrough
                    }
                case false:
                }
                """)
                == "8:9: fallthrough statement out of place")
        #expect(
            firstError("fallthrough")
                == "5:1: fallthrough statement out of place")
        #expect(
            firstError(
                """
                for {
                    fallthrough
                }
                """)
                == "6:5: fallthrough statement out of place")
        #expect(
            firstError(
                """
                select {
                default:
                    fallthrough
                }
                """)
                == "7:5: fallthrough statement out of place")
    }

    /// A switch on a pointer, an interface, or a channel has `nil` among its
    /// cases; a slice, a map, and a function compare with nil alone, and a switch on
    /// one has that one case, or none.
    @Test func nilIsACaseOfWhateverCanBeNil() throws {
        #expect(
            try runGoMain(
                """
                var p *T
                var e, f error
                var c chan int
                var s []int
                var m map[string]int
                var fn func()
                switch p {
                case nil:
                    fmt.Println("nil pointer")
                }
                switch e {
                case f:
                    fmt.Println("same error")
                case nil:
                    fmt.Println("nil error")
                }
                switch c {
                case nil:
                    fmt.Println("nil channel")
                default:
                    fmt.Println("a channel")
                }
                switch s {
                case nil:
                    fmt.Println("nil slice")
                }
                switch m {
                case nil:
                    fmt.Println("nil map")
                }
                switch fn {
                case nil:
                    fmt.Println("nil func")
                }
                switch s {
                }
                fmt.Println("ok")
                """,
                declarations: "type T struct{}")
                == "nil pointer\nsame error\nnil channel\nnil slice\nnil map\nnil func\nok\n")
        #expect(
            firstError(
                """
                switch nil {
                }
                """)
                == "5:8: use of untyped nil in switch expression")
    }

    /// Go refuses a second case with the value of an earlier one, whether
    /// written as a literal, as an expression, or by the name of a constant. It
    /// quotes the case; this dialect does not.
    @Test func aConstantIsACaseOnce() {
        #expect(
            firstError(
                """
                x := 1
                switch x {
                case 1:
                case 2, 1:
                }
                """)
                == "8:9: duplicate case 1 (constant of type int) in expression switch\n\tmain.go:7:6: previous case")
        #expect(
            firstError(
                """
                x := 1
                switch x {
                case one:
                case 2:
                case 3 - 2:
                }
                """,
                declarations: "const one = 1")
                == "9:6: duplicate case 3 - 2 (constant 1 of type int) in expression switch\n\tmain.go:7:6: previous case")
        #expect(
            firstError(
                """
                x := "a"
                switch x {
                case "a", "b", "a":
                }
                """)
                == "7:16: duplicate case \"a\" (constant of type string) in expression switch\n\tmain.go:7:6: previous case")
        #expect(
            firstError(
                """
                var b byte = 1
                switch b {
                case 'a':
                case 97:
                }
                """)
                == "8:6: duplicate case 97 (constant of type byte) in expression switch\n\tmain.go:7:6: previous case")
    }

    /// Go compares constants only: a variable may be a case twice, and so
    /// may `true`, which a switch without an expression would otherwise never allow
    /// twice.
    @Test func casesThatAreNoConstantsMayRepeat() throws {
        #expect(
            try runGoMain(
                """
                x, y := 1, 1
                switch x {
                case y:
                    fmt.Println("first")
                case y:
                    fmt.Println("second")
                }
                switch {
                case x > 5:
                case true:
                    fmt.Println("true")
                case true:
                    fmt.Println("never")
                }
                """)
                == "first\ntrue\n")
    }

    /// Go reports the second `default` of a `switch` and of a `select` with
    /// the place of the first, which is the file as the compiler was given it.
    @Test func aSwitchHasOneDefault() {
        #expect(
            firstError(
                """
                x := 1
                switch x {
                default:
                case 1:
                default:
                }
                """)
                == "9:1: multiple defaults (first at main.go:7:1)")
        #expect(
            firstError(
                """
                select {
                default:
                default:
                }
                """)
                == "7:1: multiple defaults (first at main.go:6:1)")
    }

    /// What stands before the `{` of a switch is a value. Go quotes the
    /// statement it finds there; the place is its operator.
    @Test func theHeaderIsAnExpressionNotAStatement() throws {
        #expect(
            goMainDiagnostic(
                """
                switch x := 1 {
                }
                """)
                == "cannot use := as value")
        #expect(
            try runGoMain(
                """
                switch x := 5; {
                case x > 3:
                    fmt.Println("big")
                default:
                    fmt.Println("small")
                }
                switch ; {
                case true:
                    fmt.Println("t")
                }
                switch f := func() int { return 2 }; f() {
                case 2:
                    fmt.Println("two")
                }
                """)
                == "big\nt\ntwo\n")
    }

    /// Eight type switches, each around a labeled loop over an integer and
    /// a switch that falls through: what a compiler built without optimization must
    /// manage on the stack of a test.
    @Test func statementsNestDeeply() throws {
        #expect(
            try runGoMain(
                """
                var x any = 1
                total := 0
                switch v0 := x.(type) {
                case int:
                L0:
                    for i0 := range 2 {
                        switch {
                        case i0 == 1:
                            continue L0
                        case v0 > 0:
                            total++
                            fallthrough
                        default:
                            switch v1 := x.(type) {
                            case int:
                            L1:
                                for i1 := range 2 {
                                    switch {
                                    case i1 == 1:
                                        continue L1
                                    case v1 > 0:
                                        total++
                                        fallthrough
                                    default:
                                        switch v2 := x.(type) {
                                        case int:
                                        L2:
                                            for i2 := range 2 {
                                                switch {
                                                case i2 == 1:
                                                    continue L2
                                                case v2 > 0:
                                                    total++
                                                    fallthrough
                                                default:
                                                    switch v3 := x.(type) {
                                                    case int:
                                                    L3:
                                                        for i3 := range 2 {
                                                            switch {
                                                            case i3 == 1:
                                                                continue L3
                                                            case v3 > 0:
                                                                total++
                                                                fallthrough
                                                            default:
                                                                switch v4 := x.(type) {
                                                                case int:
                                                                L4:
                                                                    for i4 := range 2 {
                                                                        switch {
                                                                        case i4 == 1:
                                                                            continue L4
                                                                        case v4 > 0:
                                                                            total++
                                                                            fallthrough
                                                                        default:
                                                                            switch v5 := x.(type) {
                                                                            case int:
                                                                            L5:
                                                                                for i5 := range 2 {
                                                                                    switch {
                                                                                    case i5 == 1:
                                                                                        continue L5
                                                                                    case v5 > 0:
                                                                                        total++
                                                                                        fallthrough
                                                                                    default:
                                                                                        switch v6 := x.(type) {
                                                                                        case int:
                                                                                        L6:
                                                                                            for i6 := range 2 {
                                                                                                switch {
                                                                                                case i6 == 1:
                                                                                                    continue L6
                                                                                                case v6 > 0:
                                                                                                    total++
                                                                                                    fallthrough
                                                                                                default:
                                                                                                    switch v7 := x.(type) {
                                                                                                    case int:
                                                                                                    L7:
                                                                                                        for i7 := range 2 {
                                                                                                            switch {
                                                                                                            case i7 == 1:
                                                                                                                continue L7
                                                                                                            case v7 > 0:
                                                                                                                total++
                                                                                                                fallthrough
                                                                                                            default:
                                                                                                                total += 100
                                                                                                            }
                                                                                                        }
                                                                                                    }
                                                                                                }
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                fmt.Println(total)
                """)
                == "108\n")
    }

    /// No `return` is missing after a switch with a `default` whose clauses
    /// all end in a `return`, a `panic`, or a `fallthrough`. A `break` that leaves
    /// the switch undoes that; a `break` of a loop inside a clause does not.
    @Test func aSwitchWithADefaultMayEndAFunction() throws {
        #expect(
            try runGoMain("fmt.Println(f(1), f(2), g(1), g(0), h(1))", declarations: """
                    func f(x int) int {
                        switch x {
                        case 1:
                            fallthrough
                        default:
                            return 2
                        }
                    }
                    func g(x int) int {
                        switch {
                        default:
                            return 2
                        case x > 3:
                            panic("big")
                        case x > 0:
                            for {
                                break
                            }
                            return 1
                        }
                    }
                    func h(x int) int {
                        for {
                            switch {
                            case true:
                                break
                            }
                            return x
                        }
                    }
                    """)
                == "2 2 1 2 1\n")
        #expect(
            firstError("fmt.Println(f(1))", declarations: """
                    func f(x int) int {
                        switch x {
                        case 1:
                            if x > 0 {
                                break
                            }
                            return 1
                        default:
                            return 2
                        }
                    }
                    """)
                == "13:1: missing return")
        #expect(
            firstError("fmt.Println(f(1))", declarations: """
                    func f(x int) int {
                        switch x {
                        case 1:
                            return 1
                        }
                    }
                    """)
                == "8:1: missing return")
    }

    /// A `select` ends its function when every clause does and no `break`
    /// leaves it; it needs no `default`, and `select {}` never goes on.
    @Test func aSelectMayEndAFunction() throws {
        #expect(
            try runGoMain(
                """
                c := make(chan int, 1)
                c <- 1
                fmt.Println(f(c), f(c))
                """,
                declarations: """
                    func f(c chan int) int {
                        select {
                        case <-c:
                            return 1
                        default:
                            return 2
                        }
                    }
                    func g(c chan int) int {
                        select {
                        case v := <-c:
                            return v
                        }
                    }
                    func h() int {
                        select {}
                    }
                    """)
                == "1 2\n")
        #expect(
            firstError("fmt.Println(f(nil))", declarations: """
                    func f(c chan int) int {
                        select {
                        case <-c:
                            break
                        default:
                            return 2
                        }
                    }
                    """)
                == "10:1: missing return")
    }
}
