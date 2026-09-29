/// Go parser tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go parser")
struct GoParserTests: GoTestHarness {

    @Test func parserInsertsSemicolonsAndBuildsMainPackage() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main

                import "fmt"

                func main() {
                    fmt.Println("hello")
                }
                """)

        let file = try GoParser.parse(source)
        #expect(file.packageName == "main")
        #expect(file.imports.map(\.path) == ["fmt"])
        #expect(file.functions.map(\.name) == ["main"])
    }

    @Test func forHeaderIdentifierBeforeBraceOpensTheLoopBody() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: """
                package main
                import "fmt"
                type Limit struct { n int }
                func main() {
                    limit := 3
                    step := 2
                    i := 0
                    for i < limit {
                        i++
                    }
                    total := 0
                    for j := 0; j < limit; j = j + step {
                        total = total + j
                    }
                    for k := (Limit{n: 1}).n; k < limit; k++ {
                        total = total + k
                    }
                    fmt.Println(i, total)
                }
                """)
        ])
        var output = ""

        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "3 5\n")
    }

    @Test func parserReportsGoStyleSourcePosition() {
        let source = GoSourceFile(path: "broken.go", text: "package main\nfunc main( {\n")
        do {
            _ = try GoParser.parse(source)
            Issue.record("invalid source unexpectedly parsed")
        } catch let diagnostic as GoDiagnostic {
            #expect(diagnostic.position.path == "broken.go")
            #expect(diagnostic.position.line == 2)
            #expect(diagnostic.description.hasPrefix("broken.go:2:"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
