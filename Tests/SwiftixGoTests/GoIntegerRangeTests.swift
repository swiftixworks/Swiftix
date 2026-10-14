/// `for i := range n`, the integers below `n` (Go 1.22).
///
/// It is the `range` statement of the tree over an expression whose type is
/// an integer, lowered as a counting loop: `n` is read once, and `i` is a
/// variable of each iteration that takes the count, so nothing the body
/// does to `i` or to `n` changes how often it runs.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change, but for one that names its operand, which this dialect
/// names by its type.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go range over an integer")
struct GoIntegerRangeTests: GoTestHarness {

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

    /// With a variable, and without one; over a literal, a constant, a
    /// variable, and an expression; never for a count that is not positive.
    @Test func itCountsFromZeroBelowTheInteger() throws {
        #expect(
            try runGoMain(
                #"""
                for i := range 3 {
                    fmt.Println(i)
                }
                x := 0
                for range 3 {
                    x++
                }
                fmt.Println(x)
                const n = 4
                for i := range n {
                    fmt.Printf("%T %v\n", i, i)
                }
                for i := range len("ab") + 1 {
                    fmt.Println("len", i)
                }
                for i := range -2 {
                    fmt.Println("never", i)
                }
                for range 0 {
                    fmt.Println("never")
                }
                fmt.Println("done")
                """#)
                == "0\n1\n2\n3\nint 0\nint 1\nint 2\nint 3\nlen 0\nlen 1\nlen 2\ndone\n")
    }

    /// The operand is evaluated before the first iteration and not again:
    /// a call runs once, and the body may change the variable it came from.
    @Test func theIntegerIsReadOnce() throws {
        #expect(
            try runGoMain(
                """
                f := func() int { fmt.Println("once"); return 2 }
                for i := range f() {
                    fmt.Println(i)
                }
                n := 3
                for i := range n {
                    n--
                    fmt.Println(i, n)
                }
                """)
                == "once\n0\n1\n0 2\n1 1\n2 0\n")
    }

    /// Over a named integer type or a `byte` the variable has that type.
    @Test func theVariableHasTheTypeOfTheInteger() throws {
        #expect(
            try runGoMain(
                #"""
                var n myint = 2
                for i := range n {
                    fmt.Printf("%T %v\n", i, i)
                }
                var b byte = 2
                for i := range b {
                    fmt.Printf("%T %v\n", i, i)
                }
                for i := range myint(2) {
                    fmt.Printf("%T %v\n", i, i)
                }
                """#,
                declarations: "type myint int")
                == "main.myint 0\nmain.myint 1\nuint8 0\nuint8 1\nmain.myint 0\nmain.myint 1\n")
    }

    /// Assigning to it changes this iteration only, and a literal or a
    /// pointer keeps the variable of the iteration that made it.
    @Test func theVariableIsNewInEachIteration() throws {
        #expect(
            try runGoMain(
                """
                for i := range 3 {
                    i = i * 10
                    fmt.Println(i)
                }
                var fs []func() int
                var ps []*int
                for i := range 3 {
                    fs = append(fs, func() int { return i })
                    ps = append(ps, &i)
                }
                for k, f := range fs {
                    fmt.Println(f(), *ps[k])
                }
                """)
                == "0\n10\n20\n0 0\n1 1\n2 2\n")
    }

    /// `break` and `continue`, loops inside one another, and a loop that
    /// does not end its function.
    @Test func itIsALoopLikeAnyOther() throws {
        #expect(
            try runGoMain(
                """
                for i := range 10 {
                    if i == 2 {
                        continue
                    }
                    if i == 5 {
                        break
                    }
                    fmt.Println(i)
                }
                for i := range 2 {
                    for j := range i + 1 {
                        fmt.Println(i, j)
                    }
                }
                """)
                == "0\n1\n3\n4\n0 0\n1 0\n1 1\n")
        #expect(
            firstError("fmt.Println(f(1))", declarations: """
                    func f(x int) int {
                        for i := range 3 {
                            _ = i
                        }
                    }
                    """)
                == "7:1: missing return")
    }

    /// The variable must be used; an integer gives one value, not two; and
    /// a `bool` is nothing to range over. Go quotes the operand in the last two.
    @Test func whatItRefuses() {
        #expect(
            firstError(
                """
                for i := range 3 {
                }
                """)
                == "5:5: declared and not used: i")
        #expect(
            firstError(
                """
                for i, v := range 10 {
                    _, _ = i, v
                }
                """)
                == "5:8: range over 10 (untyped int constant) permits only one iteration variable")
        #expect(
            firstError(
                """
                c := make(chan int)
                for i, v := range c {
                    _, _ = i, v
                }
                """)
                == "6:8: range over c (variable of type chan int) permits only one iteration variable")
        #expect(
            firstError(
                """
                for i := range true {
                    fmt.Println(i)
                }
                """)
                == "5:16: cannot range over true (untyped bool constant)")
    }
}
