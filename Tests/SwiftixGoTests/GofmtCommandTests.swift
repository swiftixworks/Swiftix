/// gofmt and go fmt commands tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("gofmt and go fmt commands")
struct GofmtCommandTests: GoTestHarness {

    @Test func gofmtSupportsFilesStandardInputAndWriteBack() {
        let output = runShell(
            [
                "cd /format",
                "gofmt main.go",
                "echo file=$?",
                "cat main.go | gofmt",
                "echo stdin=$?",
                "gofmt -w main.go",
                "echo write=$?",
                "cat main.go",
            ],
            seed: { context in
                _ = context.mkdir("/format")
                Self.write(
                    context,
                    path: "/format/main.go",
                    contents: """
                        package   main
                        import "fmt"
                        func main(){fmt.Println("formatted")}
                        """)
            })

        #expect(output.contains("func main() {\n\tfmt.Println(\"formatted\")\n}"))
        #expect(output.contains("file=0"))
        #expect(output.contains("stdin=0"))
        #expect(output.contains("write=0"))
        #expect(!output.contains("func main(){fmt.Println"))
    }

    @Test func gofmtDiffsFilesAndStandardInputAndCanAlsoWrite() {
        let output = runShell(
            [
                "cd /format-diff",
                "gofmt -d .",
                "echo file=$?",
                "cat main.go | gofmt -d",
                "echo stdin=$?",
                "gofmt -d -w main.go",
                "echo write=$?",
                "cat main.go",
            ],
            seed: { context in
                _ = context.mkdir("/format-diff/sub")
                Self.write(
                    context,
                    path: "/format-diff/main.go",
                    contents: "package main\nfunc main(){}\n")
                Self.write(
                    context,
                    path: "/format-diff/sub/other.go",
                    contents: "package other\nfunc Other(){}\n")
            })

        #expect(output.contains("diff main.go.orig main.go"))
        #expect(output.contains("diff sub/other.go.orig sub/other.go"))
        #expect(output.contains("diff <standard input>.orig <standard input>"))
        #expect(output.contains("--- main.go.orig\n+++ main.go\n@@ -1,2 +1,4 @@"))
        #expect(output.contains("-func main(){}"))
        #expect(output.contains("+func main() {"))
        #expect(output.contains("file=0"))
        #expect(output.contains("stdin=0"))
        #expect(output.contains("write=0"))
        #expect(output.contains("func main() {\n}"))
    }

    @Test func gofmtListsOnlyChangedSourcesAndCombinesWithWrite() {
        let output = runShell(
            [
                "cd /format-list",
                "gofmt -l .",
                "echo list=$?",
                "gofmt -l -d sub/other.go",
                "echo diff=$?",
                "cat stdin.go | gofmt -l",
                "echo stdin=$?",
                "gofmt -l -w main.go",
                "echo write=$?",
                "gofmt -l main.go clean.go",
                "echo clean=$?",
                "cat main.go",
            ],
            seed: { context in
                _ = context.mkdir("/format-list/sub")
                Self.write(
                    context,
                    path: "/format-list/main.go",
                    contents: "package main\nfunc main(){}\n")
                Self.write(
                    context,
                    path: "/format-list/clean.go",
                    contents: "package main\n\nfunc clean() {\n}\n")
                Self.write(
                    context,
                    path: "/format-list/stdin.go",
                    contents: "package main\nfunc stdin(){}\n")
                Self.write(
                    context,
                    path: "/format-list/sub/other.go",
                    contents: "package other\nfunc Other(){}\n")
            })

        let resultLines = shellResultLines(output)
        #expect(Array(resultLines.prefix(4)) == ["main.go", "stdin.go", "sub/other.go", "list=0"])
        #expect(resultLines.filter { $0 == "sub/other.go" }.count == 2)
        #expect(output.contains("diff sub/other.go.orig sub/other.go"))
        #expect(resultLines.contains("diff=0"))
        #expect(resultLines.contains("<standard input>"))
        #expect(resultLines.contains("stdin=0"))
        #expect(resultLines.filter { $0 == "main.go" }.count == 2)
        #expect(resultLines.contains("write=0"))
        #expect(resultLines.contains("clean=0"))
        #expect(output.contains("func main() {\n}"))
        #expect(!resultLines.contains("clean.go"))
    }

    @Test func goFmtFormatsPackageAndTestFiles() {
        let output = runShell(
            ["cd /format-package", "go fmt .", "cat main.go", "cat main_test.go"],
            seed: { context in
                _ = context.mkdir("/format-package")
                Self.write(
                    context,
                    path: "/format-package/go.mod",
                    contents: "module example/format\n\ngo 1.24\n")
                Self.write(
                    context,
                    path: "/format-package/main.go",
                    contents: "package main\nfunc main(){}\n")
                Self.write(
                    context,
                    path: "/format-package/main_test.go",
                    contents: "package main\nfunc helper(){return}\n")
            })

        #expect(output.contains("example/format\n"))
        #expect(output.contains("func main() {\n}"))
        #expect(output.contains("func helper() {\n\treturn\n}"))
    }

    @Test func goFmtRecursesWithinModuleAndSkipsGoPackageBoundaries() {
        let output = runShell(
            [
                "cd /recursive-format",
                "go fmt ./...",
                "echo status=$?",
                "cat main.go",
                "cat cmd/tool.go",
                "cat internal/lib.go",
                "cat nested/main.go",
                "cat vendor/dep.go",
                "cat testdata/sample.go",
                "cat _hidden/ignored.go",
                "cat .cache/ignored.go",
                "cat _ignored.go",
            ],
            seed: { context in
                _ = context.mkdir("/recursive-format/cmd")
                _ = context.mkdir("/recursive-format/internal")
                _ = context.mkdir("/recursive-format/nested")
                _ = context.mkdir("/recursive-format/vendor")
                _ = context.mkdir("/recursive-format/testdata")
                _ = context.mkdir("/recursive-format/_hidden")
                _ = context.mkdir("/recursive-format/.cache")
                Self.write(
                    context,
                    path: "/recursive-format/go.mod",
                    contents: "module example/recursive\n\ngo 1.24\n")
                Self.write(
                    context,
                    path: "/recursive-format/main.go",
                    contents: "package main\nfunc main(){}\n")
                Self.write(
                    context,
                    path: "/recursive-format/cmd/tool.go",
                    contents: "package tool\nfunc Tool(){return}\n")
                Self.write(
                    context,
                    path: "/recursive-format/internal/lib.go",
                    contents: "package internal\nfunc Library(){}\n")
                Self.write(
                    context,
                    path: "/recursive-format/nested/go.mod",
                    contents: "module example/nested\n\ngo 1.24\n")
                for (path, name) in [
                    ("/recursive-format/nested/main.go", "Nested"),
                    ("/recursive-format/vendor/dep.go", "Vendor"),
                    ("/recursive-format/testdata/sample.go", "Sample"),
                    ("/recursive-format/_hidden/ignored.go", "Hidden"),
                    ("/recursive-format/.cache/ignored.go", "Cache"),
                    ("/recursive-format/_ignored.go", "Ignored"),
                ] {
                    Self.write(
                        context,
                        path: path,
                        contents: "package ignored\nfunc \(name)(){}\n")
                }
            })

        #expect(output.contains("example/recursive\n"))
        #expect(output.contains("example/recursive/cmd\n"))
        #expect(output.contains("example/recursive/internal\n"))
        #expect(!output.contains("example/recursive/nested\n"))
        #expect(output.contains("status=0"))
        #expect(output.contains("func main() {\n}"))
        #expect(output.contains("func Tool() {\n\treturn\n}"))
        #expect(output.contains("func Library() {\n}"))
        for name in ["Nested", "Vendor", "Sample", "Hidden", "Cache", "Ignored"] {
            #expect(output.contains("func \(name)(){}"))
        }
    }

    @Test func recursiveGoFmtDoesNotPartiallyWriteAcrossPackages() {
        let output = runShell(
            ["cd /recursive-invalid", "go fmt ./...", "echo status=$?", "cat main.go"],
            seed: { context in
                _ = context.mkdir("/recursive-invalid/sub")
                Self.write(
                    context,
                    path: "/recursive-invalid/go.mod",
                    contents: "module example/invalid\n\ngo 1.24\n")
                Self.write(
                    context,
                    path: "/recursive-invalid/main.go",
                    contents: "package main\nfunc main(){}\n")
                Self.write(
                    context,
                    path: "/recursive-invalid/sub/broken.go",
                    contents: "package broken\nfunc broken( {\n")
            })

        #expect(output.contains("sub/broken.go:2:"))
        #expect(output.contains("status=1"))
        #expect(output.contains("func main(){}"))
    }

    @Test func goFmtDoesNotPartiallyWriteWhenAnySourceIsInvalid() {
        let output = runShell(
            ["cd /invalid-format", "go fmt .", "cat a.go"],
            seed: { context in
                _ = context.mkdir("/invalid-format")
                Self.write(
                    context,
                    path: "/invalid-format/a.go",
                    contents: "package main\nfunc main(){}\n")
                Self.write(
                    context,
                    path: "/invalid-format/z.go",
                    contents: "package main\nfunc broken( {\n")
            })

        #expect(output.contains("z.go:2:"))
        #expect(output.contains("func main(){}"))
    }

    @Test func gofmtRejectsInvalidUTF8WithoutWriting() {
        let output = runShell(
            [
                "cd /invalid-utf8",
                "gofmt -w invalid.go",
                "echo first=$?",
                "gofmt -w invalid.go",
                "echo second=$?",
            ],
            seed: { context in
                _ = context.mkdir("/invalid-utf8")
                Self.writeBytes(
                    context,
                    path: "/invalid-utf8/invalid.go",
                    contents: [0xFF])
            })

        #expect(output.contains("invalid.go: invalid UTF-8 encoding"))
        #expect(output.contains("first=2"))
        #expect(output.contains("second=2"))
        #expect(!output.contains("expected 'package'"))
    }
}
