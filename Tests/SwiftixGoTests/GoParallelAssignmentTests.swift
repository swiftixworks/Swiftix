/// Several names on the left of `:=`, `=`, and `var`: a value for each, the
/// order in which Go reads and stores them, the blank identifier, and the
/// diagnostics. What such programs print is compared with Go in
/// `GoConformanceTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go parallel assignment")
struct GoParallelAssignmentTests: GoTestHarness {

    private static let declarations = """
        func two() (int, string) {
            return 1, "a"
        }
        """

    private func diagnostic(_ body: String, declarations: String = "") -> String? {
        goMainDiagnostic(body, declarations: Self.declarations + "\n" + declarations)
    }

    @Test func everyValueIsReadBeforeAnyIsStored() throws {
        let output = try runGoMain(
            """
            a, b := 1, 2
            a, b = b, a
            a, b, c := b, a, a+b
            fmt.Println(a, b, c)
            list := []int{10, 20, 30}
            list[0], list[2] = list[2], list[0]
            i := 0
            i, list[i] = 2, 99
            fmt.Println(i, list)
            list, list[1] = []int{7, 8}, 55
            fmt.Println(list)
            for lo, hi := 0, 3; lo < hi; lo, hi = lo+1, hi-1 {
                fmt.Println(lo, hi)
            }
            """)

        // `list[i]` and `list[1]` name the element chosen before `i` and
        // `list` were assigned, as in Go.
        #expect(output == "1 2 3\n2 [99 20 10]\n[7 8]\n0 3\n1 2\n")
    }

    @Test func aVarDeclaresSeveralNames() throws {
        let output = try runGoMain(
            """
            var a, b int
            var c, d = "c", 4
            var e, f byte = 1, 2
            var n, text = two()
            const big, small = 100, 1
            fmt.Println(a, b, c, d, e, f, n, text, big, small, total, name, limit, scale)
            fmt.Printf("%T %T %T\\n", e, d, text)
            """,
            declarations: Self.declarations + """

                var total, limit int = 5, 6
                var name, scale = "n", 3
                """)

        #expect(output == "0 0 c 4 1 2 1 a 100 1 5 n 6 3\nuint8 int string\n")
    }

    @Test func theBlankIdentifierTakesAValueAndKeepsNone() throws {
        let output = try runGoMain(
            """
            n, text := two()
            _ = n
            _, _ = text, n
            n, _ = two()
            _, text = two()
            var _, kept = two()
            fmt.Println(n, text, kept, count)
            """,
            declarations: Self.declarations + """

                var count = 0
                func bump() int {
                    count++
                    return count
                }
                """)

        #expect(output == "1 a a 0\n")
        // The value is evaluated even though nothing keeps it.
        #expect(
            try runGoMain(
                "_ = bump()\n_, _ = bump(), bump()\nfmt.Println(count)",
                declarations: "var count = 0\nfunc bump() int {\n\tcount++\n\treturn count\n}")
                == "3\n")
    }

    @Test func countsAndTypesAreChecked() {
        #expect(
            diagnostic("a, b := 1, 2, 3\nfmt.Println(a, b)")
                == "assignment mismatch: 2 variables but 3 values")
        #expect(
            diagnostic("a, b := 1\nfmt.Println(a, b)")
                == "assignment mismatch: 2 variables but 1 value")
        #expect(
            diagnostic("a := 1, 2\nfmt.Println(a)")
                == "assignment mismatch: 1 variable but 2 values")
        #expect(
            diagnostic("a, b := 1, 2\na, b = 3\nfmt.Println(a, b)")
                == "assignment mismatch: 2 variables but 1 value")
        #expect(
            diagnostic("a, b := 1, 2\na, b := 3, 4\nfmt.Println(a, b)")
                == "no new variables on left side of :=")
        #expect(diagnostic("a, a := 1, 2\nfmt.Println(a)") == "a repeated on left side of :=")
        #expect(
            diagnostic("a, b := 1, 2\na, b = \"x\", 4\nfmt.Println(a, b)")
                == "cannot use \"x\" (untyped string constant) as int value in assignment")
        #expect(
            diagnostic("var a, b int = 1, \"x\"\nfmt.Println(a, b)")
                == "cannot use \"x\" (untyped string constant) as int value in variable declaration")
        #expect(
            diagnostic("var a, b = 1\nfmt.Println(a, b)")
                == "assignment mismatch: 2 variables but 1 value")
        #expect(
            diagnostic("a := 1\nvar a, b = 2, 3\nfmt.Println(a, b)")
                == "a redeclared in this block\n\tmain.go:8:1: other declaration of a")
        // A call with several results is not one value of a list.
        #expect(diagnostic("a, b := two(), 3\nfmt.Println(a, b)") != nil)
        #expect(diagnostic("_ = nil") == "use of untyped nil in assignment to _ identifier")
        #expect(diagnostic("a, b := 1, \"x\"\na, c := 2, true\nfmt.Println(a, b, c)") == nil)
    }

    @Test func aListIsTheValuesTheSourceHolds() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "main.go",
                text: """
                    package main
                    func main() {
                        a, b := 1, f(2)
                        var c, d int = 3, 4
                        a, b = f(a), b
                    }

                    """))
        let statements = file.functions[0].body.statements

        guard case .multiDeclaration(let names, let expression, _) = statements[0] else {
            Issue.record("unexpected statement")
            return
        }
        #expect(names == ["a", "b"])
        #expect(expression.valueList?.count == 2)
        #expect(expression.variables == nil)
        guard case .multiDeclaration(_, let variables, _) = statements[1] else {
            Issue.record("unexpected statement")
            return
        }
        #expect(variables.variables?.values.count == 2)
        #expect(variables.variables?.type != nil)
        #expect(variables.variables?.isConstant == false)
        #expect(variables.valueList == nil)
        // An ordinary call is neither.
        guard case .multiAssignment(_, let assigned, _) = statements[2],
            let first = assigned.valueList?.first
        else {
            Issue.record("unexpected statement")
            return
        }
        #expect(first.valueList == nil)
        #expect(first.variables == nil)

        // A rule rewrites inside the values and leaves the statement's shape.
        let rewritten = try GoSourceRewriter.rewrite(
            GoSourceFile(
                path: "main.go",
                text: "package main\nfunc main() {\n\ta, b = old(a), old(b)\n}\n"),
            rule: "old(x) -> fresh(x)")
        #expect(rewritten.text.contains("a, b = fresh(a), fresh(b)"))
    }
}
