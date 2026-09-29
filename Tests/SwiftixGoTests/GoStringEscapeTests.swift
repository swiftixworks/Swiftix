/// Go interpreted string literal escapes: lexing, diagnostics, execution, and
/// re-quoting by `gofmt -r`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go string escapes")
struct GoStringEscapeTests: GoTestHarness {

    private func literal(_ text: String) throws -> String? {
        let tokens = try GoLexer.tokenize(GoSourceFile(path: "main.go", text: "x := \(text)\n"))
        for token in tokens {
            if case .string(let value) = token.kind { return value }
        }
        return nil
    }

    @Test func escapesDecodeToTheirBytes() throws {
        #expect(try literal(#""\a\b\f\n\r\t\v""#) == "\u{07}\u{08}\u{0C}\n\r\t\u{0B}")
        #expect(try literal(#""\x1b[2J""#) == "\u{1B}[2J")
        #expect(try literal(#""\033[H\x7F""#) == "\u{1B}[H\u{7F}")
        #expect(try literal(#""é\U0001F600""#) == "é😀")
        #expect(try literal(#""\xc3\xa9""#) == "é")
        #expect(try literal(#""\"\\""#) == "\"\\")
    }

    @Test func malformedEscapesAreDiagnosed() {
        for text in [
            #""\q""#,
            #""\x1""#,
            #""\xg0""#,
            #""\08""#,
            #""\400""#,
            #""\u12""#,
            #""\uD800""#,
            #""\U00110000""#,
            #""\xff""#,
            #""\'""#,
        ] {
            #expect(throws: GoDiagnostic.self, "\(text)") {
                try literal(text)
            }
        }
    }

    @Test func escapedControlBytesReachProgramOutput() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: #"""
                package main
                import "fmt"
                func main() {
                    s := "\x1b[7m\033[0m"
                    fmt.Println(len(s), s[0], s[4])
                }
                """#)
        ])
        var output = ""

        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "8 27 27\n")
    }

    @Test func rewriteRequotesControlCharactersAsEscapes() throws {
        let source = GoSourceFile(path: "main.go", text: """
            package main

            func main() {
            \tprintln("a")
            }

            """)

        let rewritten = try GoSourceRewriter.rewrite(source, rule: #""a" -> "\x1b[H\r\n""#)

        #expect(rewritten.text.contains(#"println("\x1b[H\r\n")"#))
    }
}
