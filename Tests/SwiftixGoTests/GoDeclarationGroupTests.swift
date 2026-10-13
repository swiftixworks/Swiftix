/// Parenthesized declaration groups, `import ( ... )`, `var ( ... )`,
/// `const ( ... )`, and `type ( ... )`, and `iota`: what the parser makes of
/// them, the diagnostics, and how `gofmt -r` meets them. What such programs
/// print is compared with Go in `GoConformanceTests`, and how `gofmt` lays
/// them out in `GoGofmtConformanceTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go declaration groups")
struct GoDeclarationGroupTests: GoTestHarness {

    private func parse(_ text: String) throws -> GoFile {
        try GoParser.parse(GoSourceFile(path: "main.go", text: text))
    }

    private func diagnostic(_ text: String) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: text)])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.message
        } catch {
            return String(describing: error)
        }
    }

    private func output(_ text: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: text)
        ])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    @Test func aGroupIsADeclarationForEachOfItsSpecifications() throws {
        let file = try parse(
            """
            package main

            import (
                "fmt"
                "os"; "io"
            )
            import "errors"
            import ()

            type (
                color int
                pair struct {
                    a int
                }
            )

            var (
                total int
                x, y = 1, 2
            )

            const (
                red color = iota
                green
                _
                blue
            )

            var ()

            func main() {}

            """)

        #expect(file.imports.map(\.path) == ["fmt", "os", "io", "errors"])
        #expect(file.typeDeclarations.map(\.name) == ["color", "pair"])
        #expect(file.globalDeclarations.map(\.name) == ["total", "x", "y", "red", "green", "blue"])
        #expect(
            file.globalDeclarations.map(\.isConstant) == [false, false, false, true, true, true])
        // A constant that repeats the one before it has that one's type and
        // expression, with its own `iota`; the blank one only counts.
        let values = file.globalDeclarations.suffix(3).map { declaration -> Int64? in
            if case .integer(let value, _)? = declaration.expression { return value }
            return nil
        }
        #expect(values == [0, 1, 3])
        #expect(file.globalDeclarations.suffix(3).allSatisfy { $0.explicitType != nil })
    }

    @Test func groupsDeclareInFunctionsToo() throws {
        let printed = try output(
            """
            package main

            import (
                "fmt"
                "strings"
            )

            const (
                _  = iota
                kb = 1 << (10 * iota)
                mb
            )

            func main() {
                var (
                    name    = strings.ToUpper("go")
                    n, m    int
                    a, b    = 1, "b"
                )
                const (
                    first = iota + 1
                    second
                )
                const alone = iota
                fmt.Println(name, n, m, a, b, first, second, alone, kb, mb)
            }

            """)

        #expect(printed == "GO 0 0 1 b 1 2 0 1024 1048576\n")
    }

    @Test func aGroupIsChecked() {
        func program(_ declarations: String) -> String {
            "package main\n" + declarations + "\nfunc main() {}\n"
        }
        #expect(diagnostic(program("const (\n\ta\n)")) == "missing init expr for a")
        #expect(diagnostic(program("const (\n\ta = 1\n\tb int\n)")) == "missing init expr for b")
        #expect(
            diagnostic(program("var (\n\ta\n)")) == "missing variable type or initialization")
        #expect(
            diagnostic(program("var (\n\ta, b = 1\n)"))
                == "assignment mismatch: 2 variables but 1 value")
        #expect(
            diagnostic(program("const (\n\ta, b = 1, 2\n\tc\n)"))
                == "assignment mismatch: 1 variable but 2 values")
        #expect(diagnostic(program("var (\n\ta = 1\n\ta = 2\n)")) != nil)
        #expect(diagnostic(program("var (\n\ta = 1")) != nil)
        #expect(diagnostic("package main\nimport (\n\t1\n)\nfunc main() {}\n") == "expected import path")
        #expect(diagnostic("package main\nimport (\n\t\"fmt\"\nfunc main() {}\n") == "expected import path")
        #expect(diagnostic(program("type (\n\ta int\n\tb []a\n)\nvar (\n\tx b\n)")) == nil)
    }

    @Test func aRewriteRuleLeavesIotaAndRepeatedConstantsAlone() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main

                const (
                \ta = iota + 0
                \tb
                \tc = 0
                )

                func main() {
                \tuse(a, b, c, 0)
                }

                """)

        // The rule's `0` is a number of the source, not the `iota` the tree
        // holds as one; and the expression `b` repeats is rewritten once.
        let rewritten = try GoSourceRewriter.rewrite(source, rule: "0 -> zero")
        #expect(rewritten.text.contains("\ta = iota + zero\n\tb\n\tc = zero\n"))
        #expect(rewritten.text.contains("use(a, b, c, zero)"))
        let widened = try GoSourceRewriter.rewrite(source, rule: "x + 0 -> x")
        #expect(widened.text.contains("\ta = iota\n\tb\n"))
        #expect(GoExpression.identifier("iota", position: Self.position).replacingIota(with: 4)
            == .integer(4, position: Self.position))
        #expect(GoExpression.identifier("other", position: Self.position).replacingIota(with: 4)
            == .identifier("other", position: Self.position))
    }

    private static let position = GoSourcePosition(path: "main.go", offset: 0, line: 1, column: 1)
}
