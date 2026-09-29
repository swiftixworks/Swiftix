/// Go `strings` package: native semantics, type checking, resource limits,
/// and image encoding.

import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

@Suite("Go strings package")
struct GoStringsPackageTests: GoTestHarness {

    private func run(
        _ body: String,
        machine: GoVirtualMachine = GoVirtualMachine()
    ) throws -> String {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: """
                package main
                import "fmt"
                import "strings"
                func main() {
                \(body)
                }
                """)
        ])
        var output = ""
        try machine.run(executable) { output += $0 }
        return output
    }

    @Test func searchFunctionsMatchGo() throws {
        let output = try run("""
            fmt.Println(strings.Index("chicken", "ken"), strings.Index("x", "y"), strings.Index("ab", ""))
            fmt.Println(strings.Index("aé😀é", "é"), strings.LastIndex("aé😀é", "é"), strings.LastIndex("x", ""))
            fmt.Println(strings.Count("cheese", "e"), strings.Count("aaaa", "aa"), strings.Count("five", ""))
            fmt.Println(strings.Contains("seafood", "foo"), strings.Contains("", ""), strings.Contains("a", "b"))
            fmt.Println(strings.HasPrefix("golang", "go"), strings.HasPrefix("go", "golang"))
            fmt.Println(strings.HasSuffix("golang", "ng"), strings.HasSuffix("golang", ""))
            """)

        #expect(output == """
            4 -1 0
            1 7 1
            3 2 5
            true true false
            true false
            true true

            """)
    }

    @Test func splitJoinRepeatAndTrimMatchGo() throws {
        let output = try run("""
            parts := strings.Split("a,b,,c", ",")
            fmt.Println(len(parts), strings.Join(parts, "+"))
            fmt.Println(len(strings.Split("", ",")), len(strings.Split("abc", "abc")))
            letters := strings.Split("hé😀", "")
            fmt.Println(len(letters), letters[1], letters[2])
            fmt.Println(strings.Join([]string{}, ","), strings.Join([]string{"solo"}, ","))
            fmt.Println("[" + strings.Repeat("ab", 3) + strings.Repeat("x", 0) + "]")
            fmt.Println("[" + strings.TrimSpace(" \\t hi there \\n") + "]", "[" + strings.TrimSpace("  ") + "]")
            """)

        #expect(output == """
            4 a+b++c
            1 2
            3 é 😀
             solo
            [ababab]
            [hi there] []

            """)
    }

    @Test func nativeCallsCostTheSameInstructionsForAnyLength() throws {
        let body = """
            text := strings.Repeat("0123456789abcdef\\n", 8192)
            lines := strings.Split(text, "\\n")
            joined := strings.Join(lines, "\\n")
            fmt.Println(len(text), len(lines), strings.Index(joined, "f\\n0") , strings.Count(text, "\\n"))
            """

        let output = try run(body, machine: GoVirtualMachine(maximumInstructions: 200))

        #expect(output == "139264 8193 15 8192\n")
    }

    @Test func resourceLimitsBoundResults() throws {
        let limited = GoVirtualMachine(
            resourceLimits: GoRuntimeResourceLimits(
                maximumStringBytes: 64,
                maximumCollectionElements: 8))
        #expect(throws: GoRuntimeError.resourceLimitExceeded("string bytes")) {
            try run("fmt.Println(len(strings.Repeat(\"abcd\", 17)))", machine: limited)
        }
        #expect(throws: GoRuntimeError.resourceLimitExceeded("slice elements")) {
            try run("fmt.Println(len(strings.Split(\"a,b,c,d,e,f,g,h,i\", \",\")))", machine: limited)
        }
        #expect(throws: GoRuntimeError.panicError("strings: negative Repeat count")) {
            try run("""
                n := -1
                fmt.Println(strings.Repeat("a", n))
                """)
        }
    }

    @Test func typeCheckerEnforcesSignaturesAndImports() {
        let invalidPrograms = [
            "import \"strings\"\nfunc main() { strings.Index(\"a\") }",
            "import \"strings\"\nfunc main() { strings.Index(1, \"a\") }",
            "import \"strings\"\nfunc main() { strings.Repeat(\"a\", \"b\") }",
            "import \"strings\"\nfunc main() { strings.Join(\"a\", \",\") }",
            "import \"strings\"\nfunc main() { strings.Fields(\"a b\") }",
            "import \"strings\"\nfunc main() { n := strings.Split(\"a\", \",\"); n = 1 }",
            "func main() { strings.Index(\"a\", \"b\") }",
        ]
        for program in invalidPrograms {
            #expect(throws: GoDiagnostic.self, "\(program)") {
                try GoCompiler.compile(sources: [
                    GoSourceFile(path: "main.go", text: "package main\n" + program + "\n")
                ])
            }
        }
    }

    @Test func everyFunctionRoundTripsThroughImagesAndUnknownCodesAreRejected() throws {
        let executable = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: GoStringsFunction.allCases.map { .strings($0) } + [.return])
            ])
        let image = try GoExecutableImage.encode(executable)
        #expect(try GoExecutableImage.decode(image) == executable)

        let single = try GoExecutableImage.encode(GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [.strings(.trimSpace), .return])
            ]))
        let code = try #require(single.firstIndex(of: GoStringsFunction.trimSpace.rawValue))
        var corrupt = single
        corrupt[code] = 0xEE
        #expect(throws: GoExecutableImageError.invalidOpcode(0xEE)) {
            try GoExecutableImage.decode(corrupt)
        }
    }
}
