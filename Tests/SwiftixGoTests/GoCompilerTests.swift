/// Go compiler tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go compiler")
struct GoCompilerTests: GoTestHarness {

    @Test func compilerAndVMRunTypedExpressions() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                func main() {
                    var answer int = 6 * 7
                    greeting := "hello" + " swiftix"
                    fmt.Println(greeting, answer, answer == 42)
                }
                """)
        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "hello swiftix 42 true\n")
    }

    @Test func compilerRejectsConstantDivisionByZero() {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                func main() { fmt.Println(1 / 0) }
                """)
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [source])
        }
    }

    @Test func compilerRunsFunctionsBranchesLoopsAndAssignments() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                func announce() {
                    fmt.Println("called")
                }

                func main() {
                    announce()
                    total := 0
                    index := 0
                    for index < 4 {
                        total = total + index
                        index = index + 1
                    }
                    if total == 6 {
                        fmt.Println("sum", total)
                    } else {
                        fmt.Println("wrong")
                    }
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "called\nsum 6\n")
    }

    @Test func compilerPreservesBlockScopesAndElseIf() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                func main() {
                    value := 2
                    if value == 1 {
                        fmt.Println("one")
                    } else if value == 2 {
                        value := 20
                        fmt.Println("inner", value)
                    } else {
                        fmt.Println("other")
                    }
                    fmt.Println("outer", value)
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "inner 20\nouter 2\n")
    }

    @Test func functionsCanBeDeclaredInAnotherSourceFile() throws {
        let main = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                func main() {
                    helper()
                    fmt.Println("main")
                }
                """)
        let helper = GoSourceFile(
            path: "helper.go",
            text: """
                package main
                func helper() {}
                """)

        let executable = try GoCompiler.compile(sources: [main, helper])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "main\n")
    }

    @Test func functionsAcceptGroupedParametersAndReturnValues() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                func add(left, right int) int {
                    return left + right
                }

                func choose(condition bool, left string, right string) string {
                    if condition {
                        return left
                    } else {
                        return right
                    }
                }

                func main() {
                    fmt.Println(add(20, 22), choose(true, "yes", "no"))
                }
                """)

        let file = try GoParser.parse(source)
        #expect(file.functions[0].parameters.map(\.name) == ["left", "right"])
        #expect(
            file.functions[0].parameters.allSatisfy {
                if case .named("int", _) = $0.type { return true }
                return false
            })
        if let first = file.functions[0].resultTypes.first, case .named("int", _) = first {
            // Expected structured type syntax.
        } else {
            Issue.record("expected int result type")
        }

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "42 yes\n")
    }

    @Test func recursiveReturnValuesAndNestedCallsPreserveEvaluationOrder() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                func factorial(value int) int {
                    if value <= 1 {
                        return 1
                    }
                    return value * factorial(value - 1)
                }

                func mark(value int) int {
                    fmt.Print(value)
                    return value
                }

                func add(left, right int) int {
                    return left + right
                }

                func main() {
                    fmt.Println(add(mark(1), mark(2)))
                    fmt.Println(factorial(5))
                    factorial(1)
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "123\n120\n")
    }

    @Test func parameterizedFunctionCanReturnAcrossSourceFiles() throws {
        let main = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                func main() { fmt.Println(double(21)) }
                """)
        let helper = GoSourceFile(
            path: "helper.go",
            text: """
                package main
                func double(value int) int { return value * 2 }
                """)

        let executable = try GoCompiler.compile(sources: [main, helper])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "42\n")
    }

    @Test func multiReturnFunctionsCompileAndExecuteCorrectly() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                func swap(a, b int) (int, int) {
                    return b, a
                }

                func divide(dividend, divisor int) (int, int) {
                    return dividend / divisor, dividend - (dividend / divisor) * divisor
                }

                func minMax(a, b int) (int, int) {
                    if a < b {
                        return a, b
                    }
                    return b, a
                }

                func main() {
                    x, y := swap(1, 2)
                    fmt.Println(x, y)

                    q, r := divide(17, 5)
                    fmt.Println(q, r)

                    lo, hi := minMax(9, 3)
                    fmt.Println(lo, hi)
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "2 1\n3 2\n3 9\n")
    }

    @Test func multiReturnAssignmentUpdatesExistingVariables() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"

                func pair() (int, string) {
                    return 42, "hello"
                }

                func main() {
                    var n int
                    var s string
                    n, s = pair()
                    fmt.Println(n, s)
                }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "42 hello\n")
    }

    @Test func terminatingSwitchSatisfiesFunctionReturnRequirement() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                func classify(value int) string {
                    switch value {
                    case 0:
                        return "zero"
                    default:
                        return "other"
                    }
                }
                func main() { fmt.Println(classify(0), classify(2)) }
                """)

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "zero other\n")
    }
}
