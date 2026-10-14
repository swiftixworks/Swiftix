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
        declarations: String = "",
        machine: GoVirtualMachine = GoVirtualMachine()
    ) throws -> String {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: """
                package main
                \(goImportLines(["fmt", "strconv", "strings"], usedIn: declarations + body).joined(separator: "\n"))
                \(declarations)
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
            "import \"strings\"\nfunc main() { strings.Map(\"a b\") }",
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

    // MARK: - Case mapping, fields, and affixes
    //
    // The expected output of these three tests is what Go 1.24.5 prints for the
    // same program.

    @Test func caseMappingMapsEachCodePointLikeGo() throws {
        let output = try run(
            #"""
            fmt.Println(strings.ToUpper("hello, World 123"), strings.ToLower("HELLO, World 123"))
            fmt.Println(strings.ToUpper("straße ǆ ǅ ǰ ŉ ﬁ ΐ"), strings.ToLower("STRASSE Ǆ ǅ İ I Σ ΌΣΟΣ"))
            fmt.Println(strings.ToUpper("éàü ñ çøå ÿ µ ſ ı"), strings.ToLower("ÉÀÜ Ñ ÇØÅ Ÿ K Å Ω"))
            fmt.Println(strings.ToUpper("привет κόσμος ᾀ ᾳ ῃ ῳ"), strings.ToLower("ПРИВЕТ ΚΌΣΜΟΣ ᾈ ᾼ ῌ ῼ"))
            fmt.Println(strings.ToUpper("ɐ ⱥ ɫ ᵹ ꞵ 𐐨 𞤢 ა"), strings.ToLower("Ɐ Ⱥ Ɫ Ᵹ Ꞵ 𐐀 𞤀 Ა"))
            fmt.Println(len(strings.ToUpper("ɐɐ")), len(strings.ToLower("ȺȺ")), len(strings.ToUpper("ıı")), len(strings.ToLower("İ")))
            fmt.Println(strings.ToUpper("") == "", strings.ToLower("世界 ¡¿ 😀") == "世界 ¡¿ 😀", strings.ToUpper("ǲ ǳ Ǳ"), strings.ToLower("ǲ ǳ Ǳ"))
            """#)

        // A code point maps by itself: no `SS` for `ß`, no final sigma, and the
        // mapped text can be longer or shorter in bytes.
        #expect(
            output == """
                HELLO, WORLD 123 hello, world 123
                STRAßE Ǆ Ǆ ǰ ŉ ﬁ ΐ strasse ǆ ǆ i i σ όσοσ
                ÉÀÜ Ñ ÇØÅ Ÿ Μ S I éàü ñ çøå ÿ k å ω
                ПРИВЕТ ΚΌΣΜΟΣ ᾈ ᾼ ῌ ῼ привет κόσμοσ ᾀ ᾳ ῃ ῳ
                Ɐ Ⱥ Ɫ Ᵹ Ꞵ 𐐀 𞤀 Ა ɐ ⱥ ɫ ᵹ ꞵ 𐐨 𞤢 ა
                6 6 2 1
                true true Ǳ Ǳ Ǳ ǳ ǳ ǳ

                """)
    }

    @Test func fieldsSplitAroundGoWhiteSpace() throws {
        let output = try run(
            #"""
            fmt.Println(show(strings.Fields("  a b   c  ")), show(strings.Fields("")), show(strings.Fields("   ")), show(strings.Fields("one")))
            fmt.Println(show(strings.Fields("a\tb\nc\vd\fe\rf")), show(strings.Fields("x\u0085y\u00a0z\u1680w")))
            fmt.Println(show(strings.Fields("p\u2002q\u2028r\u2029s\u202ft\u205fu\u3000v")), show(strings.Fields("a\u200bb\ufeffc\x00d")))
            fmt.Println(show(strings.Fields("GET /index.html HTTP/1.1\r\n")), strings.Fields(" x ") == nil, len(strings.Fields(" ")))
            """#,
            declarations: #"""
                func show(parts []string) string {
                    text := ""
                    for i := 0; i < len(parts); i++ {
                        text += "<" + parts[i] + ">"
                    }
                    return text + strconv.Itoa(len(parts))
                }
                """#)

        // A zero-width space, a byte order mark, and NUL are not white space.
        #expect(
            output == """
                <a><b><c>3 0 0 <one>1
                <a><b><c><d><e><f>6 <x><y><z><w>4
                <p><q><r><s><t><u><v>7 <a​b﻿c\0d>1
                <GET></index.html><HTTP/1.1>3 false 0

                """)
    }

    @Test func trimPrefixAndSuffixRemoveOneOccurrence() throws {
        let output = try run(
            #"""
            fmt.Println(strings.TrimPrefix("prefix-body", "prefix-"), strings.TrimPrefix("body", "prefix"), strings.TrimPrefix("aaa", "a"), strings.TrimPrefix("abc", ""))
            fmt.Println(strings.TrimSuffix("body.go", ".go"), strings.TrimSuffix("body", ".go"), strings.TrimSuffix("aaa", "a"), strings.TrimSuffix("abc", ""))
            fmt.Println("["+strings.TrimPrefix("same", "same")+"]", "["+strings.TrimSuffix("same", "same")+"]", "["+strings.TrimPrefix("", "x")+"]", "["+strings.TrimSuffix("ab", "abc")+"]")
            fmt.Println(strings.TrimPrefix("éclair", "é"), strings.TrimSuffix("café", "é"), strings.TrimPrefix("世界", "世"), strings.TrimSuffix("世界", "界"), strings.TrimPrefix("Éa", "é"))
            fmt.Println(strings.TrimSuffix(strings.TrimPrefix(strings.ToLower("  Content-Length: 42  "), "  content-length:"), "  "))
            """#)

        #expect(
            output == """
                body body aa abc
                body body aa abc
                [] [] [] [ab]
                clair caf 界 世 Éa
                 42

                """)
    }

    @Test func caseTablesAreTheReferenceGoReleases() {
        // FNV-1a over every Unicode scalar value's mapping, and the counts,
        // as Go 1.24.5 (Unicode 15.0.0) computes them from `unicode.ToUpper`,
        // `unicode.ToLower`, and `strconv.IsPrint`. A host with a newer
        // Unicode version must not change any of them.
        func mix(_ hash: inout UInt64, _ value: UInt32) {
            for shift in stride(from: UInt32(0), to: 32, by: 8) {
                hash ^= UInt64((value >> shift) & 0xFF)
                hash = hash &* 1_099_511_628_211
            }
        }
        var upper: UInt64 = 14_695_981_039_346_656_037
        var lower = upper
        var printable = upper
        var changedUpper = 0
        var changedLower = 0
        var printableCount = 0
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let (up, low) = (GoUnicode.toUpper(scalar), GoUnicode.toLower(scalar))
            if up != scalar { changedUpper += 1 }
            if low != scalar { changedLower += 1 }
            mix(&upper, up.value)
            mix(&lower, low.value)
            if GoUnicode.isPrint(scalar) {
                printableCount += 1
                mix(&printable, value)
            }
        }

        #expect(changedUpper == 1_450)
        #expect(changedLower == 1_433)
        #expect(printableCount == 148_998)
        #expect(upper == 602_211_175_509_063_173)
        #expect(lower == 8_540_906_457_544_711_878)
        #expect(printable == 15_909_689_419_838_640_678)
    }

    @Test func newFunctionsAreBoundedAndTypeChecked() throws {
        // `ɐ` is two bytes and its upper case `Ɐ` three.
        let machine = GoVirtualMachine(
            resourceLimits: GoRuntimeResourceLimits(
                maximumStringBytes: 32, maximumCollectionElements: 3))
        #expect(
            try run(#"fmt.Println(strings.ToUpper("ɐɐɐɐɐɐɐɐɐɐ"))"#, machine: machine)
                == "ⱯⱯⱯⱯⱯⱯⱯⱯⱯⱯ\n")
        #expect(throws: GoRuntimeError.resourceLimitExceeded("string bytes")) {
            _ = try run(#"fmt.Println(strings.ToUpper("ɐɐɐɐɐɐɐɐɐɐɐ"))"#, machine: machine)
        }
        #expect(try run(#"fmt.Println(len(strings.Fields("a b c")))"#, machine: machine) == "3\n")
        #expect(throws: GoRuntimeError.resourceLimitExceeded("slice elements")) {
            _ = try run(#"fmt.Println(len(strings.Fields("a b c d")))"#, machine: machine)
        }

        func diagnostic(_ body: String) -> String? {
            goMainDiagnostic(body, imports: ["fmt", "strings"])
        }
        #expect(
            diagnostic("fmt.Println(strings.ToUpper())")
                == "not enough arguments in call to strings.ToUpper\n\thave ()\n\twant (string)")
        #expect(diagnostic("fmt.Println(strings.ToLower(5))") == "cannot use 5 (untyped int constant) as string value in argument to strings.ToLower")
        #expect(
            diagnostic("fmt.Println(strings.TrimPrefix(\"a\"))")
                == "not enough arguments in call to strings.TrimPrefix\n\thave (string)\n\twant (string, string)")
        #expect(diagnostic("var n int = strings.TrimSuffix(\"a\", \"b\")\nfmt.Println(n)") != nil)
        #expect(diagnostic("var s string = strings.Fields(\"a\")\nfmt.Println(s)") != nil)
        #expect(diagnostic("fmt.Println(strings.Title(\"a\"))") == "undefined: strings.Title")
        #expect(
            diagnostic(
                """
                var parts []string = strings.Fields(strings.ToUpper(" get  /x "))
                fmt.Println(len(parts), strings.TrimPrefix(parts[1], "/"))
                """) == nil)
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
