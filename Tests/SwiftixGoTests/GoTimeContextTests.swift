/// Go time and context packages tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go time and context packages")
struct GoTimeContextTests: GoTestHarness {

    // MARK: - M5: time.Sleep / time.Tick

    @Test func timeSleepParksGoroutineAndAdvancesLogicalClock() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"time\"\nfunc main() {\n\tfmt.Println(\"before\")\n\ttime.Sleep(10 * time.Millisecond)\n\tfmt.Println(\"after\")\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        let loop = EventLoop()
        var output = ""
        try GoVirtualMachine().run(executable, eventLoop: loop) { output += $0 }

        #expect(output == "before\nafter\n")
        #expect(abs(loop.now - 0.010) < 0.000_000_001)
    }

    @Test func timeTickDelivesPeriodicTimestampsOnChannel() throws {
        // time.Tick returns a channel; verify it type-checks and compiles
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"time\"\nfunc main() {\n\tfmt.Println(\"before\")\n\ttime.Sleep(5 * time.Millisecond)\n\ttime.Sleep(5 * time.Millisecond)\n\tfmt.Println(\"after\")\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        let loop = EventLoop()
        var output = ""
        try GoVirtualMachine().run(executable, eventLoop: loop) { output += $0 }

        #expect(output == "before\nafter\n")
        #expect(abs(loop.now - 0.010) < 0.000_000_001)
    }

    @Test func timerChannelsCarryTimeValues() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: """
                package main
                import "fmt"
                import "time"
                func wait(c <-chan time.Time) time.Time { return <-c }
                func main() {
                    var after <-chan time.Time = time.After(2 * time.Millisecond)
                    tick := time.Tick(time.Millisecond)
                    first := <-tick
                    var last time.Time
                    last = wait(after)
                    select {
                    case stamp, ok := <-time.After(time.Millisecond):
                        last = stamp
                        fmt.Println("timer", ok)
                    }
                    stamps := []time.Time{first, last}
                    fmt.Println(len(stamps))
                }

                """)

        let executable = try GoCompiler.compile(sources: [source])
        let loop = EventLoop()
        var output = ""
        try GoVirtualMachine().run(executable, eventLoop: loop) { output += $0 }

        #expect(output == "timer true\n2\n")
        #expect(abs(loop.now - 0.003) < 0.000_000_001)
    }

    @Test func timeValuesAreOpaqueRatherThanIntegers() {
        func diagnostic(_ body: String) -> String? {
            goMainDiagnostic(body, imports: ["fmt", "time"])
        }
        // Go's `time.After` and `time.Tick` return `<-chan time.Time`.
        #expect(
            diagnostic("var c <-chan int = time.After(time.Millisecond)\nfmt.Println(len(c))")
                == "cannot use time.After(time.Millisecond) (value of type <-chan time.Time) as <-chan int value in variable declaration")
        #expect(
            diagnostic("var c <-chan int = time.Tick(time.Millisecond)\nfmt.Println(len(c))")
                == "cannot use time.Tick(time.Millisecond) (value of type <-chan time.Time) as <-chan int value in variable declaration")
        #expect(
            diagnostic("var n int = <-time.After(time.Millisecond)\nfmt.Println(n)")
                == "cannot use <-time.After(time.Millisecond) (comma, ok expression of struct type time.Time) as int value in variable declaration")
        #expect(
            diagnostic("t := <-time.After(time.Millisecond)\nfmt.Println(t + 1)")
                == "cannot convert 1 (untyped int constant) to type time.Time")
        #expect(
            diagnostic("t := <-time.After(time.Millisecond)\nfmt.Println(t - t)")
                == "invalid operation: operator - not defined on t (variable of struct type time.Time)")
        #expect(
            diagnostic("t := <-time.After(time.Millisecond)\ntime.Sleep(t)")
                == "cannot use t (variable of struct type time.Time) as time.Duration value in argument to time.Sleep")
        #expect(
            diagnostic("t := <-time.After(time.Millisecond)\nfmt.Println(int(t))")
                == "cannot convert t (variable of struct type time.Time) to type int")
        #expect(
            diagnostic("c := make(chan int, 1)\nc <- <-time.After(time.Millisecond)")
                == "cannot use <-time.After(time.Millisecond) (comma, ok expression of struct type time.Time) as int value in send")
    }

    // MARK: - M5: context

    @Test func contextWithCancelCloseDoneChannelOnCancel() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"context\"\nfunc use(v interface{}) {}\nfunc main() {\n\tctx, cancel := context.WithCancel(context.Background())\n\tuse(ctx)\n\tcancel()\n\tfmt.Println(\"ok\")\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "ok\n")
    }

    @Test func contextWithTimeoutAutoCancelsAfterDeadline() throws {
        let source = GoSourceFile(
            path: "main.go",
            text: "package main\nimport \"fmt\"\nimport \"context\"\nimport \"time\"\nfunc use(v interface{}) {}\nfunc main() {\n\tctx, cancel := context.WithTimeout(context.Background(), 5 * time.Millisecond)\n\tuse(ctx)\n\tcancel()\n\tfmt.Println(\"ok\")\n}\n")

        let executable = try GoCompiler.compile(sources: [source])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "ok\n")
    }
}
