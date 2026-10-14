/// What a program that uses the errors of `os` is linked with: the
/// function it calls and what reaches the error, and nothing of the text for
/// a program that uses only what the VM has of `os`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@Suite("Go library error linking")
struct GoLibraryErrorLinkingTests: GoTestHarness {
    private func functionNames(_ body: String, imports: [String]) throws -> Set<String> {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: goMainSource(body, imports: imports))
        ])
        return Set(executable.functions.map(\.name))
    }

    /// `os.Args`, `os.Exit`, the streams, and the environment are the VM's.
    @Test func aProgramOfTheStreamsGetsNone() throws {
        let names = try functionNames(
            """
            fmt.Fprintln(os.Stderr, len(os.Args), os.Getenv("HOME") != "")
            os.Exit(0)
            """, imports: ["fmt", "os"])
        #expect(names == ["main"])
    }

    /// `os.Open` brings its error and the `Errno` it holds, not the other
    /// functions of the file system.
    @Test func aCallOfTheFileSystemBringsItsError() throws {
        let names = try functionNames(
            "_, err := os.Open(\"x\")\nfmt.Println(err)", imports: ["fmt", "os"])
        #expect(names.contains("os.Open"))
        #expect(names.contains("*io/fs.PathError.Error"))
        #expect(names.contains("syscall.Errno.Error"))
        #expect(!names.contains("os.ReadFile"))
        #expect(!names.contains("os.Rename"))
    }

    /// `runtime.Error` is an interface: naming it links no function, and
    /// `runtime.GC` stays the VM's.
    @Test func runtimeErrorIsAType() throws {
        let names = try functionNames(
            """
            runtime.GC()
            var err runtime.Error
            fmt.Println(err == nil)
            """, imports: ["fmt", "runtime"])
        #expect(names == ["main"])
    }
}
