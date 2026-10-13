/// Raw string literals: between back quotes every character is itself, a
/// backslash and a line break included.
///
/// What each program prints is what Go 1.24.5 prints for it, and the
/// message pinned is the one its compiler has for a literal that never
/// ends. How `gofmt` keeps a raw string is in `GoEmbeddingGofmtTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go raw string literals")
struct GoRawStringTests: GoTestHarness {

    /// The lexer gives the text between the back quotes, where a backslash
    /// is a backslash; a carriage return is left out, as Go's scanner leaves it
    /// out. The token after it is where the source has it, lines later.
    @Test func aRawStringIsAStringTokenWithoutEscapes() throws {
        let tokens = try GoLexer.tokenize(
            GoSourceFile(path: "main.go", text: "x := `a\\n\r\n\tb` + y"))

        #expect(tokens.map(\.kind).prefix(5) == [
            .identifier("x"), .declare, .string("a\\n\n\tb"), .plus, .identifier("y"),
        ])
        #expect(tokens[3].position.line == 2)
        #expect(tokens[3].position.column == 5)
        // An empty one, and one that ends a statement like any string.
        #expect(try GoLexer.tokenize(GoSourceFile(path: "main.go", text: "``\n")).map(\.kind)
            == [.string(""), .semicolon, .eof])
    }

    /// As a constant, an argument, an operand, a case, a key, and a value;
    /// over several lines, with quotes and backslashes inside.
    @Test func rawStringsStandWhereStringsDo() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Print(usage)
                fmt.Println(len(usage), pattern, len(`\n`), `a`+`b`, ``, `x` == "x")
                lines := strings.Split(`one
                two
                three`, "\n")
                fmt.Println(len(lines), lines)
                s := `line1
                        indented \t
                    "end"`
                fmt.Printf("%q\n", s)
                switch `x` {
                case `x`:
                    fmt.Println("raw case")
                }
                m := map[string]string{`k`: `v\`}
                fmt.Println(m, m[`k`] == "v\\", strings.ToUpper(`shout`), []byte(`ab`))
                const greeting = `hi ` + "there"
                fmt.Printf(`%s|%d
                `, greeting, len(greeting))
                """#,
                imports: ["fmt", "strings"],
                declarations: #"""
                    const usage = `usage: tool [flags]
                        -v    verbose \n not an escape
                      "quoted" and 'single'
                    `

                    var pattern = `^\d+$`
                    """#)
                == #"""
                usage: tool [flags]
                    -v    verbose \n not an escape
                  "quoted" and 'single'
                79 ^\d+$ 2 ab  true
                3 [one two three]
                "line1\n        indented \\t\n    \"end\""
                raw case
                map[k:v\] true SHOUT [97 98]
                hi there|8

                """#)
        #expect(
            goMainDiagnostic(
                """
                s := `abc
                fmt.Println(s)
                """)
                == "string not terminated")
    }
}
