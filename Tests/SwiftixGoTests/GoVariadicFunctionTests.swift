/// Variadic functions: declaration rules, argument checking, and formatting.
/// What they do at run time is compared with Go in `GoConformanceTests`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go variadic functions")
struct GoVariadicFunctionTests: GoTestHarness {

    private static let declarations = """
        func sum(values ...int) int {
            total := 0
            for _, value := range values {
                total += value
            }
            return total
        }
        func join(separator string, parts ...string) string {
            return separator + strconv.Itoa(len(parts))
        }
        type box struct {
            items []string
        }
        func (b *box) add(items ...string) int {
            b.items = append(b.items, items...)
            return len(b.items)
        }
        """

    private func diagnostic(_ body: String, declarations: String = "") -> String? {
        goMainDiagnostic(
            body, imports: ["fmt", "strconv"],
            declarations: Self.declarations + "\n" + declarations)
    }

    @Test func argumentsAreCheckedAgainstTheElementType() {
        #expect(diagnostic("fmt.Println(sum(1, \"a\"))") == "cannot use \"a\" (untyped string constant) as int value in argument to sum")
        #expect(
            diagnostic("fmt.Println(sum([]string{\"a\"}...))")
                == "cannot use []string{…} (value of type []string) as []int value in argument to sum")
        #expect(diagnostic("fmt.Println(sum(1, []int{2}...))") == "too many arguments in call to sum\n\thave (number, []int...)\n\twant (...int)")
        #expect(diagnostic("fmt.Println(join())") == "not enough arguments in call to join\n\thave ()\n\twant (string, ...string)")
        #expect(diagnostic("fmt.Println(join(1))") == "cannot use 1 (untyped int constant) as string value in argument to join")
        #expect(diagnostic("var b box\nfmt.Println(b.add(1))") != nil)
        #expect(diagnostic("var text string = sum()\nfmt.Println(text)") != nil)
        #expect(
            diagnostic(
                """
                var b box
                fmt.Println(sum(), sum(1), sum(1, 2), sum([]int{3}...), join("a"), join("a", "b"))
                fmt.Println(b.add(), b.add("x"), b.add([]string{"y", "z"}...))
                """) == nil)
    }

    @Test func onlyTheFinalParameterCanBeVariadic() {
        #expect(
            diagnostic("", declarations: "func bad(values ...int, last int) {\n}")
                == "can only use ... with final parameter in list")
        #expect(
            diagnostic("", declarations: "func bad(first, rest ...int) {\n}")
                == "can only use ... with final parameter in list")
        #expect(diagnostic("", declarations: "func good(first int, rest ...int) {\n}") == nil)
    }

    @Test func aVariadicParameterIsASliceInsideItsFunction() throws {
        let output = try runGoMain(
            """
            fmt.Println(sum(), sum(1, 2, 3), join("-"), join("-", "a", "b"))
            var b box
            fmt.Println(b.add("x"), b.add(), b.add("y", "z"), b.items)
            go show("spawned", 1, 2)
            defer show("deferred", 3)
            """,
            imports: ["fmt", "strconv"],
            declarations: Self.declarations + """

                func show(label string, values ...int) {
                    fmt.Println(label, len(values), values)
                }
                """)

        #expect(output.hasPrefix("0 6 -0 -2\n1 1 3 [x y z]\n"))
        #expect(output.contains("deferred 1 [3]\n"))
    }

    @Test func gofmtSpacesAVariadicParameterAndASpread() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                func sum(values   ...int) int {
                return len(values)
                }

                func pointers(values ... *int) {
                }

                func lists(prefix string,values ...[]byte) {
                }

                func main() {
                x:=sum( []int{1} ... )
                }

                """)

        #expect(
            try GoFormatter.format(source) == """
                package main

                func sum(values ...int) int {
                \treturn len(values)
                }

                func pointers(values ...*int) {
                }

                func lists(prefix string, values ...[]byte) {
                }

                func main() {
                \tx := sum([]int{1}...)
                }

                """)
    }
}
