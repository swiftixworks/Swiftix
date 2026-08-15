/// Go type checker tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go type checker")
struct GoTypeCheckerTests: GoTestHarness {

    @Test func typeCheckerRejectsMismatchedAssignment() throws {
        let source = GoSourceFile(
            path: "bad.go",
            text: """
                package main
                func main() {
                    value := 1
                    value = "wrong"
                }
                """)
        let file = try GoParser.parse(source)
        #expect(throws: GoDiagnostic.self) {
            try GoTypeChecker.check([file])
        }
    }

    @Test func typeCheckerRejectsInvalidStructPrograms() throws {
        let invalidPrograms = [
            """
            package main
            type Point struct { X int }
            func main() { point := Point{Missing: 1}; _ = point }
            """,
            """
            package main
            type Point struct { X int }
            func main() { point := Point{X: 1, X: 2}; _ = point }
            """,
            """
            package main
            type Node struct { Next Node }
            func main() {}
            """,
            """
            package main
            type Point struct { X int }
            func main() { point := Point{X: "wrong"}; point.X = 1 }
            """,
        ]

        for (index, text) in invalidPrograms.enumerated() {
            let file = try GoParser.parse(
                GoSourceFile(path: "invalid-\(index).go", text: text))
            #expect(throws: GoDiagnostic.self) {
                try GoTypeChecker.check([file])
            }
        }
    }

    @Test func typeCheckerRejectsDuplicateMethodsAcrossValueAndPointerReceivers() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "duplicate-method.go",
                text: """
                    package main
                    type Counter struct {}
                    func (counter Counter) Read() int { return 1 }
                    func (counter *Counter) Read() int { return 2 }
                    func main() {}
                    """))

        #expect(throws: GoDiagnostic.self) {
            try GoTypeChecker.check([file])
        }
    }

    @Test func multiReturnTypeCheckerRejectsCountMismatch() {
        let tooFew = GoSourceFile(
            path: "few.go",
            text: """
                package main
                func pair() (int, int) { return 1, 2 }
                func main() { x := pair() }
                """)
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [tooFew])
        }

        let tooMany = GoSourceFile(
            path: "many.go",
            text: """
                package main
                func single() int { return 1 }
                func main() { a, b := single() }
                """)
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [tooMany])
        }

        let wrongReturnCount = GoSourceFile(
            path: "wrong.go",
            text: """
                package main
                func pair() (int, int) { return 1 }
                func main() {}
                """)
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [wrongReturnCount])
        }
    }

    @Test func typeCheckerRejectsInvalidFunctionArgumentsAndReturns() {
        let invalidPrograms = [
            """
            package main
            func value(flag bool) int { if flag { return 1 } }
            func main() {}
            """,
            """
            package main
            func value() int { return }
            func main() {}
            """,
            """
            package main
            func value() int { return "wrong" }
            func main() {}
            """,
            """
            package main
            func value(input int) int { return input }
            func main() { value() }
            """,
            """
            package main
            func value(input int) int { return input }
            func main() { value(1, 2) }
            """,
            """
            package main
            func value(input int) int { return input }
            func main() { value("wrong") }
            """,
            """
            package main
            func main(input int) {}
            """,
            """
            package main
            func value(input int, input int) int { return input }
            func main() {}
            """,
        ]

        for (index, text) in invalidPrograms.enumerated() {
            let source = GoSourceFile(path: "invalid\(index).go", text: text)
            #expect(throws: GoDiagnostic.self) {
                try GoCompiler.compile(sources: [source])
            }
        }
    }

    @Test func typeCheckerRejectsUnknownFunctionAndVoidValueUse() {
        let unknownFunction = GoSourceFile(
            path: "unknown.go",
            text: """
                package main
                func main() { missing() }
                """)
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [unknownFunction])
        }

        let voidValue = GoSourceFile(
            path: "void.go",
            text: """
                package main
                func helper() {}
                func main() { value := helper() }
                """)
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [voidValue])
        }
    }

    @Test func interfaceMethodSetRejectsValueWithPointerOnlyMethod() {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\ntype Closer interface { Close() }\ntype resource struct{}\nfunc (r *resource) Close() {}\nfunc use(value Closer) {}\nfunc main() {\n\tvalue := resource{}\n\tuse(value)\n}\n")

        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [source])
        }
    }

    @Test func mapTypeRejectsNonComparableKeys() {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nfunc main() {\n\tvalues := map[[]int]string{}\n\t_ = values\n}\n")

        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [source])
        }
    }

    @Test func typeCheckerRejectsInvalidControlFlowContexts() {
        let outsideLoop = GoSourceFile(
            path: "outside.go",
            text: """
                package main
                func main() { break }
                """)
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [outsideLoop])
        }

        let leakedInitializer = GoSourceFile(
            path: "scope.go",
            text: """
                package main
                import "fmt"
                func main() {
                    for index := 0; index < 1; index++ {}
                    fmt.Println(index)
                }
                """)
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [leakedInitializer])
        }
    }

    @Test func typeCheckerRejectsInvalidSwitchCasesAndDefaults() {
        let mismatchedCase = GoSourceFile(
            path: "case.go",
            text: """
                package main
                func main() {
                    switch 1 { case "one": return }
                }
                """)
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [mismatchedCase])
        }

        let duplicateDefault = GoSourceFile(
            path: "default.go",
            text: """
                package main
                func main() {
                    switch { default: return; default: return }
                }
                """)
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [duplicateDefault])
        }

        let duplicateCase = GoSourceFile(
            path: "duplicate.go",
            text: """
                package main
                func main() {
                    switch 1 { case 1: return; case 1: return }
                }
                """)
        #expect(throws: GoDiagnostic.self) {
            try GoCompiler.compile(sources: [duplicateCase])
        }
    }

    // MARK: - M5: net (type checking)

    @Test func netDialAndListenTypeCheckSuccessfully() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"net\"\nfunc main() {\n\tconn, err := net.Dial(\"tcp\", \"10.0.0.1:80\")\n\tfmt.Println(conn, err)\n}\n")

        let file = try GoParser.parse(source)
        _ = try GoTypeChecker.check([file])
    }

    // MARK: - M5: net/http (type checking)

    @Test func httpGetAndResponseFieldsTypeCheck() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"net/http\"\nfunc main() {\n\tresp, err := http.Get(\"http://10.0.0.1:80/hello\")\n\tif err != nil {\n\t\treturn\n\t}\n\tfmt.Println(resp.StatusCode)\n\tfmt.Println(resp.Body)\n}\n")

        let file = try GoParser.parse(source)
        _ = try GoTypeChecker.check([file])
    }

    @Test func channelDirectionsAndSelectCasesTypeCheck() throws {
        let valid = GoSourceFile(
            path: "main.go",
            text: "package main\nfunc send(out chan<- int) { out <- 1 }\nfunc receive(in <-chan int) int { return <-in }\nfunc use(value int, ok bool) {}\nfunc main() {\n\tvalues := make(chan int, 1)\n\tgo send(values)\n\tselect {\n\tcase value, ok := <-values:\n\t\tuse(value, ok)\n\tdefault:\n\t}\n}\n")
        let file = try GoParser.parse(valid)
        _ = try GoTypeChecker.check([file])

        let invalid = GoSourceFile(
            path: "main.go",
            text: "package main\nfunc bad(in <-chan int) { in <- 1 }\nfunc main() {}\n")
        #expect(throws: GoDiagnostic.self) {
            try GoTypeChecker.check([GoParser.parse(invalid)])
        }
    }
}
