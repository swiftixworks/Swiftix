/// The goroutine trace that follows the first line of an unrecovered panic,
/// as Go prints it: `goroutine 1 [running]:`, then each frame from the
/// innermost out as its Go name and, after a tab, its file and line.
///
/// Go prints the arguments of a frame and the offset of its return address
/// in machine code; neither exists here. Each frame is printed as Go prints
/// one it inlined, `main.f(...)` (`main.main()` without parameters), and the
/// offset is that of the instruction in the VM's function, which is stable
/// from run to run. The first line, the names, the files, the lines, and the
/// exit status are Go's: for this module Go 1.24.5 prints the same names and
/// lines (`main.go:8`, `:13`, `:19`, `:20`), with its own offsets.

import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

@Suite("Go panic traces")
struct GoPanicTraceTests: GoTestHarness {
    private static let program = """
        package main

        import "fmt"

        type T struct{ a []int }

        func (t *T) get(i int) int {
            return t.a[i]
        }

        func f(i int) int {
            t := &T{a: []int{1}}
            return t.get(i)
        }

        func main() {
            fmt.Println("start")
            func() {
                fmt.Println(f(3))
            }()
        }
        """

    private func write(_ context: ProcessContext, _ path: String, _ text: String) {
        let descriptor = context.open(path, create: true, truncate: true)!
        context.write(descriptor, Array(text.utf8))
        context.close(descriptor)
    }

    /// What `commands` print in `/m`, a module whose `main.go` is `program`.
    private func run(_ program: String, _ commands: [String]) -> String {
        let output = runShell(["cd /m"] + commands) { context in
            _ = context.mkdir("/m")
            write(context, "/m/go.mod", "module example/m\n\ngo 1.24\n")
            write(context, "/m/main.go", program)
        }
        return shellResultLines(output).joined(separator: "\n")
    }

    @Test func goRunPrintsTheTraceAndTheExitStatus() {
        #expect(
            run(Self.program, ["GOCACHE=off go run .", "echo status=$?"]) == """
                start
                panic: runtime error: index out of range [3] with length 1
                goroutine 1 [running]:
                main.(*T).get(...)
                \t/m/main.go:8 +0x6
                main.f(...)
                \t/m/main.go:13 +0x8
                main.main.func1()
                \t/m/main.go:19 +0x1
                main.main()
                \t/m/main.go:20 +0x4
                exit status 2
                status=1
                """)
    }

    /// The lines are not part of the image; the build cache keeps them beside
    /// it, so a run from the cache prints the same trace.
    @Test func aCachedBuildKeepsItsLines() {
        let output = run(Self.program, ["go run .", "go run ."])
        let traces = output.split(separator: "start\n", omittingEmptySubsequences: true)
        #expect(traces.count == 2)
        #expect(traces.first?.trimmingSuffix() == traces.last?.trimmingSuffix())
        #expect(output.contains("\t/m/main.go:8 +0x6"))
    }

    /// A panic in another goroutine names it (Go numbers its goroutines
    /// otherwise: this one is its 33), and the trace of a deferred call
    /// that panicked while its function panicked shows both, as Go's does
    /// besides its own `panic` frame. Go ends it with the line that says
    /// where the goroutine was created, which this trace has not.
    @Test func theTraceIsOfTheGoroutineThatPanicked() {
        let output = run(
            """
            package main

            import "time"

            type failure struct{ code int }

            func (f failure) Error() string { return "failure" }

            func work() {
                defer func() {
                    panic("again")
                }()
                panic(failure{3})
            }

            func main() {
                go work()
                time.Sleep(time.Second)
            }
            """, ["GOCACHE=off go run ."])
        #expect(
            output == """
                panic: failure
                \tpanic: again
                goroutine 2 [running]:
                main.work.func1()
                \t/m/main.go:11 +0x1
                main.work()
                \t/m/main.go:13 +0x4
                exit status 2
                """)
    }

    /// A built program run as a process prints Go's first line, with no
    /// name before it, and exits with status 2. Its image has no lines, so
    /// each frame is placed at `?:0`, and a literal is named by where its
    /// text begins.
    @Test func aBuiltProgramNamesItsFrames() {
        let output = run(Self.program, ["GOCACHE=off go build -o prog .", "./prog", "echo status=$?"])
        #expect(
            output.contains("""
                start
                panic: runtime error: index out of range [3] with length 1
                goroutine 1 [running]:
                main.(*T).get(...)
                \t?:0 +0x6
                main.f(...)
                \t?:0 +0x8
                """))
        #expect(output.contains("main.func·215()\n\t?:0 +0x1\nmain.main()\n\t?:0 +0x4\nstatus=2"))
    }

    /// The names Go gives the functions of an image without lines.
    @Test func namesWithoutATable() {
        #expect(GoTraceback.goName(of: "main") == "main.main")
        #expect(GoTraceback.goName(of: "f") == "main.f")
        #expect(GoTraceback.goName(of: "*T.get") == "main.(*T).get")
        #expect(GoTraceback.goName(of: "os.Open") == "os.Open")
        #expect(GoTraceback.goName(of: "*io/fs.PathError.Error") == "io/fs.(*PathError).Error")
    }

    /// The table survives its text, and never makes two executables differ.
    @Test func theTableIsNotPartOfTheExecutable() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: Self.program)
        ])
        #expect(!executable.sourceLines.isEmpty)
        let lines = try #require(GoSourceLines(encoded: executable.sourceLines.encoded))
        #expect(lines.encoded == executable.sourceLines.encoded)
        let decoded = try GoExecutableImage.decode(GoExecutableImage.encode(executable))
        #expect(decoded.sourceLines.isEmpty)
        #expect(decoded == executable)
        #expect(lines.functions["*T.get"]?.goName == "main.(*T).get")
        #expect(lines.functions["main"]?.lines == [17, 20])
    }

    /// Without being asked, the VM reports only what panicked.
    @Test func aMachineThatIsNotAskedPrintsNoTrace() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: Self.program)
        ])
        #expect(throws: GoRuntimeError.panicError("runtime error: index out of range [3] with length 1")) {
            try GoVirtualMachine().run(executable) { _ in }
        }
    }
}

extension Substring {
    fileprivate func trimmingSuffix() -> Substring {
        var text = self
        while text.last == "\n" { text = text.dropLast() }
        return text
    }
}
