/// How the Go text of `strings` and `strconv` is linked: what a program that
/// uses it is made of, that a program that uses only the natives of the two
/// packages is made of what it was, and that the text is reached through
/// every way of naming a package.
///
/// What the functions do is in `GoStringsBuilderTests`, `GoStringsTextTests`,
/// and `GoStrconvTextTests`. The module below prints what Go 1.24.5 prints
/// for it.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go strings and strconv linking")
struct GoStringsLinkingTests: GoTestHarness {

    /// The names of the functions of the image `body` compiles to, as the
    /// body of `func main`.
    private func functionNames(_ body: String, imports: [String]) throws -> Set<String> {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: goMainSource(body, imports: imports))
        ])
        return Set(executable.functions.map(\.name))
    }

    /// The natives of the two packages bring none of their text.
    @Test func aProgramOfTheNativesGetsNoText() throws {
        let names = try functionNames(
            """
            n, err := strconv.Atoi(strings.TrimSpace(" 42 "))
            parts := strings.Split(strings.ToUpper("a,b"), ",")
            fmt.Println(n, err, strings.Join(parts, "-"), strconv.Itoa(n), strings.Index("abc", "c"))
            fmt.Println(strconv.FormatInt(255, 16), strings.HasPrefix("abc", "a"), strings.Fields(" a b "))
            """, imports: ["fmt", "strconv", "strings"])

        #expect(names == ["main"])
    }

    /// Only what a program names is linked, with what that reaches: a
    /// `ReplaceAll` brings `Replace` and nothing of `Builder`, a `Builder`
    /// its methods and no function, `FormatBool` nothing of quoting.
    @Test func onlyWhatAProgramUsesIsLinked() throws {
        let replace = try functionNames(
            "fmt.Println(strings.ReplaceAll(\"a-b\", \"-\", \"+\"))", imports: ["fmt", "strings"])
        #expect(replace == ["main", "strings.ReplaceAll", "strings.Replace"])

        let builder = try functionNames(
            """
            var b strings.Builder
            b.WriteString("x")
            fmt.Println(b.String())
            """, imports: ["fmt", "strings"])
        #expect(builder.contains("*strings.Builder.WriteString"))
        #expect(builder.contains("*strings.Builder.written"))
        #expect(!builder.contains { $0.contains("Reader") || $0.contains("Replace") })
        #expect(builder.filter { !$0.hasPrefix("*strings.Builder.") } == ["main"])

        let trim = try functionNames(
            "fmt.Println(strings.Trim(\"xax\", \"x\"))", imports: ["fmt", "strings"])
        #expect(
            trim == ["main", "strings.Trim", "strings.TrimLeft", "strings.TrimRight", "strings.lastRune"])

        let bool = try functionNames(
            "fmt.Println(strconv.FormatBool(true), strconv.Itoa(1))", imports: ["fmt", "strconv"])
        #expect(bool == ["main", "strconv.FormatBool"])
    }

    /// A write costs the same VM instructions whatever its length, and so
    /// do a replacement and a split of a long text: they are natives
    /// underneath.
    @Test func theTextCostsInstructionsForPiecesNotBytes() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(
                    """
                    line := strings.Repeat("0123456789abcdef", 4096)
                    var b strings.Builder
                    b.WriteString(line)
                    b.WriteString(line)
                    text := b.String()
                    replaced := strings.ReplaceAll(text, "f0", "f\\n0")
                    head, tail, _ := strings.Cut(replaced, "\\n")
                    fmt.Println(len(text), len(replaced), len(head), len(tail), len(strings.SplitN(replaced, "\\n", 3)[2]))
                    """, imports: ["fmt", "strings"]))
        ])
        var output = ""
        try GoVirtualMachine(maximumInstructions: 1000).run(executable) { output += $0 }

        #expect(output == "131072 139263 16 139246 139229\n")
    }

    /// The text is reached through an import under another name, from two
    /// packages of one module, as the type of a field, behind an alias, and
    /// as a package-level variable with an initializer.
    @Test func theTextIsReachedFromEveryPackageUnderAnyName() throws {
        let packages = [
            GoPackageSource(
                importPath: "example/m",
                sources: [
                    GoSourceFile(
                        path: "/m/main.go",
                        text: #"""
                            package main

                            import (
                                f "fmt"
                                s "strings"

                                "example/m/lib"
                            )

                            func main() {
                                var page lib.Page
                                page.Line("keep_alive", true)
                                page.Line("no_cache", false)
                                f.Fprintf(&page.Body, "%d lines\n", s.Count(page.Body.String(), "\n"))
                                f.Print(page.Body.String())
                                var text lib.Text
                                text.WriteString(lib.Escape.Replace("<b>bold</b>"))
                                f.Println(text.String(), lib.Quoted("a", "b\n").String())
                                before, after, _ := s.Cut(text.String(), "bold")
                                f.Println(s.EqualFold(before, "&LT;B&GT;"), s.TrimFunc(after, func(r rune) bool { return r != 'b' }))
                            }
                            """#)
                ]),
            GoPackageSource(
                importPath: "example/m/lib",
                sources: [
                    GoSourceFile(
                        path: "/m/lib/lib.go",
                        text: #"""
                            package lib

                            import (
                                conv "strconv"
                                str "strings"
                            )

                            type Page struct {
                                Body str.Builder
                            }

                            type Text = str.Builder

                            var Escape = str.NewReplacer("<", "&lt;", ">", "&gt;")

                            func (p *Page) Line(key string, on bool) {
                                p.Body.WriteString(str.ReplaceAll(key, "_", "-"))
                                p.Body.WriteString(": ")
                                p.Body.WriteString(conv.FormatBool(on))
                                p.Body.WriteByte('\n')
                            }

                            func Quoted(parts ...string) *str.Builder {
                                b := &str.Builder{}
                                for _, part := range parts {
                                    b.WriteString(conv.Quote(part))
                                }
                                return b
                            }
                            """#)
                ]),
        ]
        let executable = try GoCompiler.compile(packages: packages, root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(
            output == #"""
                keep-alive: true
                no-cache: false
                2 lines
                &lt;b&gt;bold&lt;/b&gt; "a""b\n"
                true b

                """#)
    }
}
