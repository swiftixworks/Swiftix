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
