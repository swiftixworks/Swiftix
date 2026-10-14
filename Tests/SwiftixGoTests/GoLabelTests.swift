/// Labels, `break L`, `continue L`, and `goto L`.
///
/// The tree has no statement for a label or a `goto`, and its `break` and
/// `continue` take no label, so each is a call no program can write, with
/// the label in the name of its callee (`GoBranch`). A label stands before
/// the statement it names in the same list. Labels are the function's own:
/// they are in no scope of variables, and a function literal has its own.
///
/// Go's compiler checks labels and jumps on the syntax tree, and so does
/// this one (`GoBranchChecker`, which follows `checkBranches` of Go's
/// `syntax` package); what it finds is reported with the errors of the type
/// checker, the first in the source first.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change. A message that holds a second place is this dialect's
/// in that it names the file as the compiler was given it, `main.go` here,
/// where Go writes `./main.go`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go labels and jumps")
struct GoLabelTests: GoTestHarness {

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

    /// `continue outer` goes on with the next iteration of the labeled loop
    /// and `break outer` leaves it, from any depth of loops inside it; the loops are
    /// three-clause, `range` over a slice, a string, a map, and an integer.
    @Test func breakAndContinueNameAnOuterLoop() throws {
        #expect(
            try runGoMain(
                """
                outer:
                    for i := 0; i < 3; i++ {
                        for j := 0; j < 3; j++ {
                            if j == 2 {
                                continue outer
                            }
                            if i == 2 {
                                break outer
                            }
                            fmt.Println(i, j)
                        }
                    }
                letters:
                    for _, s := range []string{"ab", "cd", "ef"} {
                        for _, c := range s {
                            if c == 'd' {
                                continue letters
                            }
                            if c == 'f' {
                                break letters
                            }
                            fmt.Println(string(c))
                        }
                    }
                    m := map[string][]int{"a": []int{1, 2}, "b": []int{3, 4}}
                    total := 0
                rows:
                    for _, k := range []string{"a", "b"} {
                        for _, v := range m[k] {
                            if v == 4 {
                                break rows
                            }
                            total += v
                        }
                    }
                    fmt.Println(total)
                count:
                    for i := range 3 {
                        for j := range 3 {
                            if j > i {
                                continue count
                            }
                            fmt.Println(i, j)
                        }
                    }
                """)
                == "0 0\n0 1\n1 0\n1 1\na\nb\nc\ne\n6\n0 0\n1 0\n1 1\n2 0\n2 1\n2 2\n")
    }

    /// `break L` leaves a labeled `switch` or `select` from a loop inside
    /// it, and a labeled loop from a `switch` or `select` inside that, where a
    /// `break` alone would leave only the innermost.
    @Test func aLabelNamesASwitchAndASelect() throws {
        #expect(
            try runGoMain(
                """
                x := 3
                sw:
                    switch {
                    case x > 1:
                        for {
                            break sw
                        }
                        fmt.Println("unreached")
                    }
                    fmt.Println("after switch")

                    c := make(chan int, 3)
                    c <- 1
                    c <- 2
                    c <- 3
                    n := 0
                loop:
                    for {
                        select {
                        case v := <-c:
                            n += v
                            if n >= 3 {
                                break loop
                            }
                            continue loop
                        default:
                            break loop
                        }
                    }
                    fmt.Println(n)

                    d := make(chan int, 1)
                sel:
                    select {
                    case d <- 1:
                        if len(d) == 1 {
                            break sel
                        }
                        fmt.Println("unreached")
                    }
                    fmt.Println(<-d)

                    i := 0
                both:
                    for {
                        i++
                        switch {
                        case i < 3:
                            continue both
                        case i == 5:
                            break both
                        }
                        fmt.Println(i)
                    }
                    var y any = 1
                ts:
                    switch y.(type) {
                    case int:
                        for {
                            break ts
                        }
                    }
                    fmt.Println("after type switch")
                """)
                == "after switch\n3\n1\n3\n4\nafter type switch\n")
    }

    /// Two labeled loops inside one another, each named by the jumps of the
    /// innermost; and a label with the name of a variable, which is another thing.
    @Test func labelsNestAndAreNoVariables() throws {
        #expect(
            try runGoMain(
                """
                outer:
                    for i := 0; i < 2; i++ {
                    inner:
                        for j := 0; j < 3; j++ {
                            switch j {
                            case 1:
                                continue inner
                            case 2:
                                continue outer
                            }
                            fmt.Println(i, j)
                        }
                    }
                    L := 1
                L:
                    for {
                        fmt.Println(L)
                        break L
                    }
                """)
                == "0 0\n1 0\n1\n")
    }

    /// `continue L` ends an iteration as its end does: the variables of the
    /// loops are new ones in the next, and a literal keeps those it captured.
    @Test func eachIterationHasItsVariablesUnderALabeledContinue() throws {
        #expect(
            try runGoMain(
                """
                var fs []func() int
                outer:
                    for i := 0; i < 4; i++ {
                        for j := 0; j < 2; j++ {
                            if j == 1 {
                                continue outer
                            }
                            fs = append(fs, func() int { return i*10 + j })
                        }
                    }
                    for _, f := range fs {
                        fmt.Println(f())
                    }
                """)
                == "0\n10\n20\n30\n")
    }

    /// A `defer` in a labeled loop runs when the function returns, whatever
    /// left the loop; a loop in a function literal is left by its own `break`.
    @Test func deferredCallsAndLiteralsKeepTheirOwnControlFlow() throws {
        #expect(
            try runGoMain(
                """
                fmt.Println(work())
                for i := 0; i < 2; i++ {
                    func() {
                    inner:
                        for j := 0; j < 3; j++ {
                            for {
                                if j == 1 {
                                    break inner
                                }
                                break
                            }
                            fmt.Println(i, j)
                        }
                    }()
                }
                """,
                declarations: """
                    func work() (n int) {
                    loop:
                        for i := 0; i < 5; i++ {
                            defer func() { n += i }()
                            if i == 3 {
                                break loop
                            }
                        }
                        return 100
                    }
                    """)
                == "106\n0 0\n1 0\n")
    }

    /// `goto` jumps to a label of its block or of a block around it: out of
    /// loops and blocks, forward over statements, and back, which makes a loop.
    @Test func gotoJumpsForwardAndBack() throws {
        #expect(
            try runGoMain(
                """
                i := 0
                loop:
                    if i < 3 {
                        fmt.Println(i)
                        i++
                        goto loop
                    }
                    fmt.Println(find([]int{1, 2, 3}, 2), find([]int{1}, 5))
                    n := 0
                    for i := 0; i < 3; i++ {
                        for j := 0; j < 3; j++ {
                            {
                                if j == 1 {
                                    goto next
                                }
                            }
                            n += 10
                        next:
                            n++
                        }
                    }
                    fmt.Println(n)
                    goto end
                end:
                    fmt.Println("end")
                """,
                declarations: """
                    func find(xs []int, want int) int {
                        for _, x := range xs {
                            if x == want {
                                goto found
                            }
                        }
                        return -1
                    found:
                        return want * 2
                    }
                    """)
                == "0\n1\n2\n4 -1\n69\nend\n")
    }

    /// A variable declared after a label that a `goto` jumps back to is a
    /// new variable each time, as in a loop: a literal and a pointer keep theirs.
    @Test func aDeclarationReachedAgainByGotoIsANewVariable() throws {
        #expect(
            try runGoMain(
                """
                var fs []func() int
                var ps []*int
                i := 0
                again:
                    x := i * 2
                    v := i
                    fs = append(fs, func() int { return x })
                    ps = append(ps, &v)
                    i++
                    if i < 3 {
                        goto again
                    }
                    for k, f := range fs {
                        fmt.Println(f(), *ps[k])
                    }
                """)
                == "0 0\n2 1\n4 2\n")
    }

    /// Only the declaration of a variable is in the way of a `goto`: a
    /// constant and a type declared between are there after the label.
    @Test func gotoMayJumpOverConstantsAndTypes() throws {
        #expect(
            try runGoMain(
                """
                const before = 1
                x := 0
                goto L
                const skipped = 7
                const (
                    a = iota + 1
                    b
                )
                type T struct{ n int }
                L:
                    fmt.Println(before, skipped, a, b, T{x + 1}.n)
                """)
                == "1 7 1 2 1\n")
    }

    /// A label nothing names, a second label of one name, and a label that
    /// no statement defines.
    @Test func aLabelMustBeUsedAndDefinedOnce() {
        #expect(
            firstError(
                """
                L:
                    for {
                        break
                    }
                """)
                == "5:1: label L defined and not used")
        #expect(
            firstError(
                """
                for {
                    break L
                }
                """)
                == "6:11: break label not defined: L")
        #expect(
            firstError(
                """
                for {
                    continue L
                }
                """)
                == "6:14: continue label not defined: L")
        #expect(
            firstError("goto L")
                == "5:6: label L not defined")
        #expect(
            firstError(
                """
                L:
                    for {
                        break L
                    }
                L:
                    for {
                        break L
                    }
                """)
                == "9:1: label L already defined at main.go:5:1")
        #expect(
            goMainDiagnostic(
                """
                x := 1
                switch x {
                case 1:
                L:
                case 2:
                }
                """)
                == "missing statement after label")
    }

    /// `break L` wants a loop, a `switch`, or a `select` around it that `L`
    /// names, and `continue L` a loop: a label of a block, of an `if`, or of a
    /// statement that is not around the jump is refused.
    @Test func aLabeledJumpNeedsAStatementItCanLeave() {
        #expect(
            firstError(
                """
                L:
                    {
                        break L
                    }
                """)
                == "7:15: invalid break label L")
        #expect(
            firstError(
                """
                L:
                    if true {
                        break L
                    }
                """)
                == "7:15: invalid break label L")
        #expect(
            firstError(
                """
                L:
                    for i := 0; i < 2; i++ {
                    }
                    for {
                        break L
                    }
                """)
                == "9:15: invalid break label L")
        #expect(
            firstError(
                """
                L:
                    switch {
                    case true:
                        continue L
                    }
                """)
                == "8:18: invalid continue label L")
        #expect(
            firstError(
                """
                L:
                    select {
                    default:
                        continue L
                    }
                """)
                == "8:18: invalid continue label L")
    }

    /// A literal is a function of its own: the labels around it are not
    /// its, and an unlabeled `break` in it has no loop.
    @Test func aLabelDoesNotCrossAFunctionLiteral() {
        #expect(
            firstError(
                """
                L:
                    for {
                        func() {
                            break L
                        }()
                        break L
                    }
                """)
                == "8:19: break label not defined: L")
        #expect(
            firstError(
                """
                for {
                    func() {
                        goto L
                    }()
                }
                L:
                """)
                == "7:14: label L not defined")
        #expect(
            firstError(
                """
                for {
                    func() {
                        continue
                    }()
                }
                """)
                == "7:9: continue is not in a loop")
    }

    /// A `goto` may not jump into a block, nor over the declaration of a
    /// variable into its scope. Go says where the block starts and what is declared.
    @Test func gotoMustNotEnterABlockOrAScope() throws {
        #expect(
            firstError(
                """
                goto L
                x := 1
                _ = x
                L:
                    fmt.Println("x")
                """)
                == "5:6: goto L jumps over declaration of x at main.go:6:3")
        #expect(
            firstError(
                """
                goto L
                var a, b = 1, 2
                _, _ = a, b
                L:
                """)
                == "5:6: goto L jumps over declaration of a at main.go:6:5")
        #expect(
            firstError(
                """
                goto L
                {
                L:
                    fmt.Println("x")
                }
                """)
                == "5:6: goto L jumps into block starting at main.go:6:1")
        #expect(
            firstError(
                """
                x := 1
                switch x {
                case 1:
                    goto L
                case 2:
                L:
                    fmt.Println()
                }
                """)
                == "8:10: goto L jumps into block starting at main.go:9:1")
        #expect(
            try runGoMain(
                """
                goto L
                L:
                    x := 1
                    {
                        y := x
                        _ = y
                    }
                    fmt.Println(x)
                """)
                == "1\n")
    }

    /// Go lists these errors with those of its type checker, in the order
    /// of the source: the first one of a function is whichever comes first.
    @Test func anErrorOfALabelIsReportedInItsTurn() {
        #expect(
            firstError(
                """
                var s string = 1
                L:
                    for {
                    }
                """)
                == "5:5: declared and not used: s")
        #expect(
            firstError(
                """
                L:
                    for {
                    }
                    var s string = 1
                """)
                == "5:1: label L defined and not used")
        #expect(
            firstError(
                """
                x := 1
                L:
                    for {
                    }
                """)
                == "5:1: declared and not used: x")
    }

    /// A `for` without a condition ends its function when no `break` leaves
    /// it, a `break` of a loop inside that names its label included; and a `goto`
    /// ends the list it is the last statement of.
    @Test func aLabeledLoopEndsAFunctionUnlessABreakNamesIt() throws {
        #expect(
            try runGoMain("fmt.Println(g(1))", declarations: """
                    func g(x int) int {
                        if x > 0 {
                            goto done
                        }
                        for {
                        }
                    done:
                        return x + 1
                    }
                    func h(x int) int {
                    L:
                        goto L
                    }
                    """)
                == "2\n")
        #expect(
            firstError("fmt.Println(f(1))", declarations: """
                    func f(x int) int {
                    L:
                        for {
                            for {
                                break L
                            }
                        }
                    }
                    """)
                == "10:1: missing return")
    }
}
