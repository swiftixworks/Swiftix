/// Go formatter tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go formatter")
struct GoFormatterTests: GoTestHarness {

    @Test func formatterProducesStableGoStyleSourceAndPreservesComments() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                // Package main is executable.
                package   main
                import   "fmt" // used for output
                func message(name string)string{
                /* Keep this comment. */
                return "hello "+name
                }
                // Main runs the example.
                func main(){if -1<0{fmt.Println("negative")};for index:=0;index<2;index++{switch index{case 0:
                fmt.Println(message("go"))
                default:continue
                }}}
                """)
        let expected = [
            "// Package main is executable.",
            "package main",
            "",
            "import \"fmt\" // used for output",
            "",
            "func message(name string) string {",
            "\t/* Keep this comment. */",
            "\treturn \"hello \" + name",
            "}",
            "",
            "// Main runs the example.",
            "func main() {",
            "\tif -1 < 0 {",
            "\t\tfmt.Println(\"negative\")",
            "\t}",
            "\tfor index := 0; index < 2; index++ {",
            "\t\tswitch index {",
            "\t\tcase 0:",
            "\t\t\tfmt.Println(message(\"go\"))",
            "\t\tdefault:",
            "\t\t\tcontinue",
            "\t\t}",
            "\t}",
            "}",
            "",
        ].joined(separator: "\n")

        let formatted = try GoFormatter.format(source)
        #expect(formatted == expected)
        #expect(
            try GoFormatter.format(GoSourceFile(path: "main.go", text: formatted)) == formatted)
    }

    @Test func gofmtRewriteAndSimplifyUseASTPatterns() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                func main() {
                    values := []int{1, 2, 3}
                    result := values[0] + 0
                    tail := values[1:len(values)]
                    fmt.Println(result, tail)
                }
                """)
        let rewritten = try GoSourceRewriter.rewrite(source, rule: "a + 0 -> a")
        let simplified = try GoSourceRewriter.simplify(rewritten)
        let formatted = try GoFormatter.format(simplified)

        #expect(formatted.contains("result := values[0]"))
        #expect(formatted.contains("tail := values[1:]"))

        let output = runShell(
            [
                "cd /rewrite",
                "gofmt -w -r 'a + 0 -> a' -s main.go",
                "cat main.go",
            ],
            seed: { context in
                _ = context.mkdir("/rewrite")
                Self.write(context, path: "/rewrite/main.go", contents: source.text)
            })
        #expect(output.contains("result := values[0]"))
        #expect(output.contains("tail := values[1:]"))
    }

    @Test func gofmtUnifiedDiffMatchesGoHeadersAndMissingNewlineMarker() {
        let changed = GoSourceDiff.unified(
            original: "package main\nfunc main(){}\n",
            formatted: "package main\n\nfunc main() {}\n",
            path: "<standard input>")
        let expectedChanged = [
            "diff <standard input>.orig <standard input>",
            "--- <standard input>.orig",
            "+++ <standard input>",
            "@@ -1,2 +1,3 @@",
            " package main",
            "-func main(){}",
            "+",
            "+func main() {}",
            "",
        ].joined(separator: "\n")
        #expect(changed == expectedChanged)

        let missingNewline = GoSourceDiff.unified(
            original: "package main",
            formatted: "package main\n",
            path: "<standard input>")
        let expectedMissingNewline = [
            "diff <standard input>.orig <standard input>",
            "--- <standard input>.orig",
            "+++ <standard input>",
            "@@ -1,1 +1,1 @@",
            "-package main",
            "\\ No newline at end of file",
            "+package main",
            "",
        ].joined(separator: "\n")
        #expect(missingNewline == expectedMissingNewline)
    }

    @Test func gofmtPreservesChannelArrowsAndIndentsSelectCases() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nfunc send(out chan<- int){out<-1}\nfunc main(){\nvalues:=make(chan int)\ngo send(values)\nselect{\ncase value:=<-values:\nvalue++\ndefault:\n}\n}\n")

        let formatted = try GoFormatter.format(source)

        #expect(formatted.contains("func send(out chan<- int)"))
        #expect(formatted.contains("\tout <- 1"))
        #expect(formatted.contains("\tselect {\n\tcase value := <-values:\n\t\tvalue++\n\tdefault:"))
        #expect(try GoFormatter.format(GoSourceFile(path: source.path, text: formatted)) == formatted)
    }
}
