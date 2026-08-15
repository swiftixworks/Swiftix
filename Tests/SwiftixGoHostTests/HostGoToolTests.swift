/// macOS/Linux host-tool integration tests.
///
/// Each test owns a temporary host workspace. The generated image is still a
/// Swiftix/svm64 artifact and execution goes through a real Swiftix Kernel.

import Foundation
import SwiftixGo
import SwiftixGoHost
import SwiftixGoRuntime
import SwiftixGoTool
import Testing

@Suite("Swiftix Go host tools")
struct HostGoToolTests {
    @Test func hostBuildIsDeterministicAndReportsSeparateHostAndTarget() throws {
        try withTemporaryWorkspace { workspace in
            try writeModule(
                workspace,
                source: """
                    package main
                    import "fmt"
                    import "os"
                    func main() { fmt.Println("hello", os.Args[1]) }
                    """)
            let capture = Capture()
            let context = makeContext(workspace, capture: capture)

            GoToolchain.run(
                context,
                arguments: ["go", "env", "GOHOSTOS", "GOHOSTARCH", "GOOS", "GOARCH"])
            #expect(context.exitCode == 0)
            #if os(macOS)
                #expect(capture.stdout.contains("darwin\n"))
            #elseif os(Linux)
                #expect(capture.stdout.contains("linux\n"))
            #endif
            #expect(capture.stdout.contains("swiftix\nsvm64\n"))

            GoToolchain.run(
                context,
                arguments: ["go", "build", "-o", "first", "."])
            #expect(context.exitCode == 0)
            GoToolchain.run(
                context,
                arguments: ["go", "build", "-o", "second", "."])
            #expect(context.exitCode == 0)

            let first = try Data(contentsOf: workspace.appendingPathComponent("first"))
            let second = try Data(contentsOf: workspace.appendingPathComponent("second"))
            #expect(first == second)
            #expect(throws: Never.self) {
                _ = try GoExecutableImage.decode(Array(first))
            }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: workspace.appendingPathComponent("first").path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            #expect(permissions & 0o111 == 0o111)
        }
    }

    @Test func hostRunAndImageRunnerUseTheSwiftixKernel() throws {
        try withTemporaryWorkspace { workspace in
            try writeModule(
                workspace,
                source: """
                    package main
                    import "fmt"
                    import "os"
                    func main() { fmt.Println("hello", os.Args[1]) }
                    """)
            let buildCapture = Capture()
            let buildContext = makeContext(workspace, capture: buildCapture)
            GoToolchain.run(
                buildContext,
                arguments: ["go", "build", "-o", "hello", "."])
            #expect(buildContext.exitCode == 0)

            let runCapture = Capture()
            let runContext = makeContext(workspace, capture: runCapture)
            let exitCode = try runContext.runImage(at: "hello", arguments: ["host"])
            #expect(exitCode == 0)
            #expect(runCapture.stdout == "hello host\n")
        }
    }

    @Test func hostRuntimeStagesTheExplicitWorkspaceIntoGuestVFS() throws {
        try withTemporaryWorkspace { workspace in
            try writeModule(
                workspace,
                source: """
                    package main
                    import "fmt"
                    import "os"
                    import "swiftix/userland"
                    func main() {
                        data, status := userland.ReadInput("read", os.Args[1:])
                        fmt.Print(data)
                        if status != 0 { os.Exit(status) }
                    }
                    """)
            try Data("from host workspace\n".utf8).write(
                to: workspace.appendingPathComponent("input.txt"))
            let capture = Capture()
            let context = makeContext(workspace, capture: capture)

            GoToolchain.run(
                context,
                arguments: ["go", "run", ".", "input.txt"])

            #expect(capture.stderr.isEmpty, Comment(rawValue: capture.stderr))
            #expect(context.exitCode == 0)
            #expect(capture.stdout == "from host workspace\n")
        }
    }

    @Test func hostFormattingWritesTheHostFileAndIsIdempotent() throws {
        try withTemporaryWorkspace { workspace in
            try writeModule(
                workspace,
                source: "package main\nfunc main(){println(\"hi\")}\n")
            let capture = Capture()
            let context = makeContext(workspace, capture: capture)

            GoToolchain.run(context, arguments: ["go", "fmt", "main.go"])
            #expect(context.exitCode == 0)
            let once = try String(
                contentsOf: workspace.appendingPathComponent("main.go"),
                encoding: .utf8)
            GoToolchain.run(context, arguments: ["go", "fmt", "main.go"])
            let twice = try String(
                contentsOf: workspace.appendingPathComponent("main.go"),
                encoding: .utf8)
            #expect(once == twice)
            #expect(once.contains("func main() {"))
        }
    }

    @Test func workspaceImportDoesNotFollowHostSymlinks() throws {
        try withTemporaryWorkspace { workspace in
            try writeModule(
                workspace,
                source: """
                    package main
                    import "fmt"
                    import "os"
                    import "swiftix/userland"
                    func main() {
                        data, status := userland.ReadInput("read", os.Args[1:])
                        fmt.Print(data)
                        if status != 0 { os.Exit(status) }
                    }
                    """)
            try Data("must not cross link\n".utf8).write(
                to: workspace.appendingPathComponent("secret.txt"))
            try FileManager.default.createSymbolicLink(
                at: workspace.appendingPathComponent("linked.txt"),
                withDestinationURL: workspace.appendingPathComponent("secret.txt"))
            let capture = Capture()
            let context = makeContext(workspace, capture: capture)
            #expect(context.lstat("linked.txt")?.type == .symlink)

            GoToolchain.run(
                context,
                arguments: ["go", "run", ".", "linked.txt"])

            #expect(context.exitCode == 1)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains("No such file"))
        }
    }

    @Test func hostGoTestRunsPackagesInsideSwiftix() throws {
        try withTemporaryWorkspace { workspace in
            try writeModule(
                workspace,
                source: """
                    package main
                    func answer() int { return 42 }
                    """)
            try Data(
                """
                package main
                import "testing"
                func TestAnswer(t *testing.T) {
                    if answer() != 42 { t.Fatal("wrong answer") }
                }
                """.utf8
            ).write(to: workspace.appendingPathComponent("main_test.go"))
            let capture = Capture()
            let context = makeContext(workspace, capture: capture)

            GoToolchain.run(context, arguments: ["go", "test", "./..."])

            #expect(capture.stderr.isEmpty, Comment(rawValue: capture.stderr))
            #expect(context.exitCode == 0)
            #expect(capture.stdout.contains("--- PASS: TestAnswer"))
            #expect(capture.stdout.contains("ok  \texample/host"))
        }
    }

    private final class Capture {
        var stdout = ""
        var stderr = ""
    }

    private func makeContext(
        _ workspace: URL,
        capture: Capture
    ) -> HostGoToolContext {
        HostGoToolContext(
            currentDirectory: workspace.path,
            environment: [
                "HOME": workspace.path,
                "GOPATH": workspace.appendingPathComponent("go").path,
                "GOCACHE": workspace.appendingPathComponent("cache").path,
            ],
            inputReader: { _ in [] },
            standardOutput: { bytes in
                capture.stdout += String(decoding: bytes, as: UTF8.self)
                return bytes.count
            },
            standardError: { bytes in
                capture.stderr += String(decoding: bytes, as: UTF8.self)
                return bytes.count
            })
    }

    private func writeModule(_ workspace: URL, source: String) throws {
        try Data("module example/host\n\ngo 1.24\n".utf8).write(
            to: workspace.appendingPathComponent("go.mod"))
        try Data(source.utf8).write(
            to: workspace.appendingPathComponent("main.go"))
    }

    private func withTemporaryWorkspace(
        _ body: (URL) throws -> Void
    ) throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftix-go-host-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try body(workspace)
    }
}
