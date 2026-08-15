/// go mod and the module cache tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("go mod and the module cache")
struct GoModuleTests: GoTestHarness {

    @Test func goModInitCreatesGoModuleFile() {
        let output = runShell(
            ["mkdir /module", "cd /module", "go mod init example/module", "cat go.mod"])

        #expect(output.contains("module example/module"))
        #expect(output.contains("go 1.24"))
    }

    /// An import outside the main module resolves through `GOMODCACHE`, which the
    /// system package manager populates. The toolchain performs no download of its
    /// own, but it no longer refuses to look beyond the main module.
    @Test func goRunResolvesExternalModuleFromModuleCache() {
        let output = runShell(
            ["cd /app", "go run ."],
            seed: { context in
                _ = context.mkdir("/app")
                Self.write(
                    context, path: "/app/go.mod",
                    contents: "module example/app\n\ngo 1.24\n")
                Self.write(
                    context, path: "/app/main.go",
                    contents: "package main\nimport \"fmt\"\nimport \"example.com/greet/text\"\n"
                        + "func main() {\n\tfmt.Println(text.Message())\n}\n")

                let cached = "/root/go/pkg/mod/example.com/greet/text"
                _ = context.mkdir(cached)
                Self.write(
                    context, path: cached + "/text.go",
                    contents: "package text\nfunc Message() string {\n\treturn \"from the module cache\"\n}\n")
            })

        #expect(output.contains("from the module cache"))
    }

    /// A module that is not installed reports where the toolchain looked and how
    /// to get it, instead of the old blanket "downloads are disabled".
    @Test func goRunReportsMissingModuleWithInstallHint() {
        let output = runShell(
            ["cd /app", "go run ."],
            seed: { context in
                _ = context.mkdir("/app")
                Self.write(
                    context, path: "/app/go.mod",
                    contents: "module example/app\n\ngo 1.24\n")
                Self.write(
                    context, path: "/app/main.go",
                    contents: "package main\nimport \"example.com/missing\"\nfunc main() {\n\t_ = missing.X\n}\n")
            })

        #expect(output.contains("example.com/missing is not available"))
        #expect(output.contains("/root/go/pkg/mod"))
        #expect(output.contains("pkg install"))
    }

    @Test func goRunRejectsNewerModuleLanguageVersion() {
        let output = runShell(
            ["cd /future", "go run ."],
            seed: { context in
                _ = context.mkdir("/future")
                Self.write(
                    context, path: "/future/go.mod",
                    contents: "module example/future\n\ngo 1.25\n")
                Self.write(
                    context, path: "/future/main.go",
                    contents: "package main\nfunc main() {}\n")
            })

        #expect(output.contains("requires go >= 1.25 (running go 1.24)"))
    }
}
