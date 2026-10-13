/// `x := v` where the block already has every name on the left.
///
/// Go says `no new variables on left side of :=` and says it at the `:=`,
/// for one name as for several. A name written twice is reported at its
/// second place, and a constant of the block cannot be assigned. The
/// parser records where the `:=` of each short declaration is, after the
/// places of its names.
///
/// Each error is the first one Go 1.24.5 reports for the program, copied
/// without change, and each program that runs prints what Go prints.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go short declarations without a new variable")
struct GoNoNewVariablesTests: GoTestHarness {

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

    /// One name: a variable, a parameter, or a named result of the same
    /// block.
    @Test func aShortDeclarationOfAVariableOfItsBlockDeclaresNothing() {
        #expect(
            firstError(
                """
                x := 1
                x := 2
                fmt.Println(x)
                """)
                == "6:3: no new variables on left side of :=")
        #expect(
            firstError(
                """
                x := 1
                x   :=   2
                fmt.Println(x)
                """)
                == "6:5: no new variables on left side of :=")
        #expect(
            firstError(
                """
                var x int
                x := 2
                fmt.Println(x)
                """)
                == "6:3: no new variables on left side of :=")
        #expect(
            firstError(
                """
                x := 1
                x += 1
                x :=
                2
                fmt.Println(x)
                """)
                == "7:3: no new variables on left side of :=")
        #expect(
            firstError("", declarations: """
                    func f(a int) int {
                        a := 2
                        return a
                    }
                    """)
                == "4:7: no new variables on left side of :=")
        #expect(
            firstError("", declarations: """
                    func f() (r int) {
                        r := 2
                        return r
                    }
                    """)
                == "4:7: no new variables on left side of :=")
        #expect(
            firstError(
                """
                for i := 0; i < 2; i++ {
                    i := i
                    i := 5
                    fmt.Println(i)
                }
                """)
                == "7:7: no new variables on left side of :=")
    }

    /// Whatever is on the right: values, a call, a map index, a type
    /// assertion, or a receive.
    @Test func severalNamesAreReportedAtTheSamePlace() {
        #expect(
            firstError(
                """
                x, y := 1, 2
                x, y := 3, 4
                fmt.Println(x, y)
                """)
                == "6:6: no new variables on left side of :=")
        #expect(
            firstError(
                """
                x := 1
                x, _ := 2, 3
                fmt.Println(x)
                """)
                == "6:6: no new variables on left side of :=")
        #expect(
            firstError(
                """
                x := 1
                _, x := 2, 3
                fmt.Println(x)
                """)
                == "6:6: no new variables on left side of :=")
        #expect(
            firstError(
                """
                x := 1
                y := 2
                x, y := y, x
                fmt.Println(x, y)
                """)
                == "7:6: no new variables on left side of :=")
        #expect(
            firstError(
                """
                a, b := two()
                a, b := two()
                fmt.Println(a, b)
                """,
                declarations: "func two() (int, int) { return 1, 2 }")
                == "6:6: no new variables on left side of :=")
        #expect(
            firstError(
                """
                m := map[string]int{"a": 1}
                v, ok := m["a"]
                v, ok := m["b"]
                fmt.Println(v, ok)
                """)
                == "7:7: no new variables on left side of :=")
        #expect(
            firstError(
                """
                var a any = 1
                v, ok := a.(int)
                v, ok := a.(int)
                fmt.Println(v, ok)
                """)
                == "7:7: no new variables on left side of :=")
        #expect(
            firstError(
                """
                ch := make(chan int, 2)
                ch <- 1
                v, ok := <-ch
                v, ok := <-ch
                fmt.Println(v, ok)
                """)
                == "8:7: no new variables on left side of :=")
        #expect(
            firstError(
                """
                var err error
                n, err := fmt.Println("a")
                n, err := fmt.Println("b")
                fmt.Println(n, err)
                """)
                == "7:8: no new variables on left side of :=")
    }

    /// Before the `:=`, so Go reports them first.
    @Test func aNameWrittenTwiceAndAConstantAreReportedWhereTheyAre() {
        #expect(
            firstError(
                """
                a, a := 1, 2
                fmt.Println(a)
                """)
                == "5:4: a repeated on left side of :=")
        #expect(
            firstError(
                """
                x := 1
                x, x := 2, 3
                fmt.Println(x)
                """)
                == "6:4: x repeated on left side of :=")
        #expect(
            firstError("", declarations: """
                    func f(a int) {
                        a, a := 2, 3
                        fmt.Println(a)
                    }
                    """)
                == "4:8: a repeated on left side of :=")
        #expect(
            firstError(
                """
                a, a := two()
                fmt.Println(a)
                """,
                declarations: "func two() (int, int) { return 1, 2 }")
                == "5:4: a repeated on left side of :=")
        #expect(
            firstError(
                """
                const x = 1
                x := 2
                fmt.Println(x)
                """)
                == "6:1: cannot assign to x")
        #expect(
            firstError(
                """
                const x = 1
                x, y := 2, 3
                fmt.Println(x, y)
                """)
                == "6:1: cannot assign to x")
    }

    /// One new name on the left is enough, and the old variables are
    /// assigned; a block of its own declares its own.
    @Test func aNewNameOrAnotherBlockIsADeclaration() throws {
        #expect(
            try runGoMain(
                """
                x := 1
                {
                    x := 2
                    fmt.Println(x)
                }
                if x := 3; x > 2 {
                    x := 4
                    fmt.Println(x)
                }
                a, b := two()
                a, c := two()
                x, y := 5, 6
                fmt.Println(x, y, a, b, c, shadow(1))
                """,
                declarations: """
                    func two() (int, int) { return 1, 2 }

                    func shadow(a int) int {
                        a, b := 2, 3
                        return a + b
                    }
                    """)
                == "2\n4\n5 6 1 2 2 5\n")
    }
}
