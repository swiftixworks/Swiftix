/// Go terminal ABI tests: `swiftix/userland` stdin, file, raw-mode, and
/// window-size calls, and the resumable run that lets an interactive program
/// wait for terminal input across host turns.
///
/// Concurrency: every fixture builds its own `EventLoop` + `Kernel` and drives
/// it to quiescence on the calling executor; nothing is shared between tests.

import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

@Suite("Go terminal ABI")
struct GoTerminalABITests: GoTestHarness {

    /// A shell on a pty whose `/app` is the compiled program, driven one host
    /// turn at a time the way a terminal consumer drives it.
    final class InteractiveSession {
        let loop = EventLoop()
        let kernel: Kernel
        let terminal = PseudoTerminal()
        private var output: [UInt8] = []

        init(_ source: String, windowSize: WindowSize? = nil) throws {
            kernel = Kernel(loop: loop)
            let image = try GoExecutableImage.encode(
                GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)]))
            kernel.spawn("seed") { context in
                GoTerminalABITests.writeBytes(context, path: "/app", contents: image)
                _ = context.chmod("/app", mode: [.ownerRead, .ownerWrite, .ownerExecute])
                context.exit(0)
            }
            loop.runUntilIdle()
            if let windowSize { terminal.windowSize = windowSize }
            terminal.onOutput = { [unowned self] in
                output.append(contentsOf: terminal.readForApp(max: 65_535))
            }
            let registry = CommandRegistry.builtins
            GoExecutableLoader.register(in: registry)
            kernel.spawn("sh", Programs.shell(tty: terminal.slave, commands: registry))
            loop.runUntilIdle()
            _ = takeOutput()
        }

        func type(_ text: String) { send(Array(text.utf8)) }

        func send(_ bytes: [UInt8]) {
            terminal.writeFromApp(bytes)
            loop.runUntilIdle()
        }

        /// Terminal output since the previous call.
        func takeOutput() -> String {
            defer { output.removeAll() }
            return String(decoding: output, as: UTF8.self)
        }
    }

    // MARK: - ReadStdin

    @Test func readStdinWaitsForTerminalInputAcrossHostTurns() throws {
        let session = try InteractiveSession("""
            package main
            import "fmt"
            import "swiftix/userland"
            func main() {
                for {
                    data, status := userland.ReadStdin()
                    if status != 0 {
                        break
                    }
                    fmt.Print("[" + data + "]")
                }
                fmt.Println("done")
            }
            """)

        session.type("/app\n")
        #expect(!session.takeOutput().contains("done"))

        session.type("first\n")
        #expect(session.takeOutput().contains("[first\n]"))
        session.type("second\n")
        #expect(session.takeOutput().contains("[second\n]"))

        session.send([0x04])
        #expect(session.takeOutput().contains("done\n"))
        session.type("echo status=$?\n")
        #expect(session.takeOutput().contains("status=0"))
    }

    @Test func readStdinDeliversInputAndEndOfFileQueuedInOneTurn() throws {
        let session = try InteractiveSession("""
            package main
            import "fmt"
            import "swiftix/userland"
            func main() {
                for {
                    data, status := userland.ReadStdin()
                    if status != 0 {
                        break
                    }
                    fmt.Print("[" + data + "]")
                }
                fmt.Println("done")
            }
            """)

        session.type("/app\n")
        session.terminal.writeFromApp(Array("queued\n".utf8))
        session.terminal.writeFromApp([0x04])
        session.loop.runUntilIdle()

        let output = session.takeOutput()
        #expect(output.contains("[queued\n]done\n"))
        session.type("echo status=$?\n")
        #expect(session.takeOutput().contains("status=0"))
    }

    @Test func readStdinReadsPipedInputToEndOfFile() throws {
        let session = try InteractiveSession("""
            package main
            import "fmt"
            import "swiftix/userland"
            func main() {
                for {
                    data, status := userland.ReadStdin()
                    if status != 0 {
                        break
                    }
                    fmt.Print("[" + data + "]")
                }
                fmt.Println("done")
            }
            """)

        session.type("echo piped | /app\n")

        #expect(session.takeOutput().contains("[piped\n]done\n"))
    }

    @Test func readStdinKeepsMultiByteCharactersWhole() throws {
        let session = try InteractiveSession("""
            package main
            import "fmt"
            import "swiftix/userland"
            func main() {
                userland.SetRawMode(true)
                data, _ := userland.ReadStdin()
                userland.SetRawMode(false)
                fmt.Println(len(data), data)
            }
            """)

        session.type("/app\n")
        _ = session.takeOutput()
        session.send([0xC3])
        #expect(session.takeOutput().isEmpty)
        session.send([0xA9, 0x21])

        #expect(session.takeOutput().contains("3 é!\n"))
    }

    @Test func completeUTF8PrefixHoldsBackOnlyAnUnfinishedSequence() {
        #expect(GoVirtualMachine.completeUTF8PrefixLength([]) == 0)
        #expect(GoVirtualMachine.completeUTF8PrefixLength(Array("ab".utf8)) == 2)
        #expect(GoVirtualMachine.completeUTF8PrefixLength([0x61, 0xE4, 0xB8]) == 1)
        #expect(GoVirtualMachine.completeUTF8PrefixLength([0xE4, 0xB8, 0xAD]) == 3)
        #expect(GoVirtualMachine.completeUTF8PrefixLength([0xF0, 0x9F, 0x98]) == 0)
        // Invalid input is passed through rather than held forever.
        #expect(GoVirtualMachine.completeUTF8PrefixLength([0x80, 0x80, 0x80, 0x80]) == 4)
        #expect(GoVirtualMachine.completeUTF8PrefixLength([0x61, 0x80]) == 2)
    }

    // MARK: - Raw mode and window size

    @Test func rawModeDeliversEscapeSequencesUnbuffered() throws {
        let session = try InteractiveSession("""
            package main
            import "fmt"
            import "swiftix/userland"
            func main() {
                ok := userland.SetRawMode(true)
                data, _ := userland.ReadStdin()
                userland.SetRawMode(false)
                fmt.Println(ok, len(data), data[0], data[1], data[2])
            }
            """)

        session.type("/app\n")
        #expect(session.terminal.rawMode)

        session.send([0x1B, 0x5B, 0x41])
        #expect(session.takeOutput().contains("true 3 27 91 65\n"))
        #expect(!session.terminal.rawMode)
    }

    @Test func windowSizeFollowsTheTerminalGrid() throws {
        let session = try InteractiveSession(
            """
            package main
            import "fmt"
            import "swiftix/userland"
            func main() {
                rows, columns := userland.WindowSize()
                fmt.Println("size", rows, columns)
                userland.ReadStdin()
                rows, columns = userland.WindowSize()
                fmt.Println("size", rows, columns)
            }
            """,
            windowSize: WindowSize(rows: 40, columns: 120))

        session.type("/app\n")
        #expect(session.takeOutput().contains("size 40 120\n"))

        session.terminal.windowSize = WindowSize(rows: 30, columns: 100)
        session.type("\n")
        #expect(session.takeOutput().contains("size 30 100\n"))
    }

    @Test func terminalCallsDegradeWithoutATerminal() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: """
                package main
                import "fmt"
                import "swiftix/userland"
                func main() {
                    rows, columns := userland.WindowSize()
                    data, status := userland.ReadStdin()
                    fmt.Println(userland.SetRawMode(true), rows, columns, len(data), status,
                        userland.WriteFile("/out", "x"))
                }
                """)
        ])
        var output = ""

        try GoVirtualMachine().run(executable) { output += $0 }

        #expect(output == "false 0 0 0 1 1\n")
    }

    @Test func synchronousRunReportsAnUnansweredTerminalReadAsDeadlock() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: """
                package main
                import "fmt"
                import "swiftix/userland"
                func main() {
                    fmt.Println("waiting")
                    userland.ReadStdin()
                }
                """)
        ])
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let terminal = PseudoTerminal()
        var output = ""
        var failure: (any Error)?
        kernel.spawn("app") { context in
            context.installStandardIO(terminal.slave)
            do {
                try GoVirtualMachine().run(
                    executable, eventLoop: loop, processContext: context
                ) { output += $0 }
            } catch {
                failure = error
            }
            context.exit(0)
        }
        loop.runUntilIdle()
        // Input arriving after the run ended must not reach the finished VM.
        terminal.writeFromApp(Array("late\n".utf8))
        loop.runUntilIdle()

        #expect(output == "waiting\n")
        #expect(failure as? GoRuntimeError == .deadlock)
    }

    // MARK: - WriteFile

    @Test func writeFileCreatesTruncatesAndReportsFailures() throws {
        let session = try InteractiveSession("""
            package main
            import "fmt"
            import "swiftix/userland"
            func main() {
                created := userland.WriteFile("/notes.txt", "a longer first version\\n")
                replaced := userland.WriteFile("/notes.txt", "é second\\n")
                directory := userland.WriteFile("/", "x")
                data, _ := userland.ReadInput("app", []string{"/notes.txt"})
                fmt.Print(created, replaced, directory, " ", data)
            }
            """)

        session.type("/app\n")

        #expect(session.takeOutput().contains("001 é second\n"))
    }

    // MARK: - Terminal restoration

    @Test func failingProgramRestoresCookedModeButNormalExitKeepsItsChoice() throws {
        func run(_ body: String) throws -> (outcome: Result<GoProcessResult, any Error>?, raw: Bool) {
            let executable = try GoCompiler.compile(sources: [
                GoSourceFile(path: "main.go", text: """
                    package main
                    import "swiftix/userland"
                    func main() {
                        userland.SetRawMode(true)
                        \(body)
                    }
                    """)
            ])
            let loop = EventLoop()
            let kernel = Kernel(loop: loop)
            let terminal = PseudoTerminal()
            var outcome: Result<GoProcessResult, any Error>?
            kernel.spawn("app") { context in
                context.installStandardIO(terminal.slave)
                GoVirtualMachine().startProgram(
                    executable,
                    eventLoop: loop,
                    processContext: context,
                    write: { _ in },
                    completion: { result in
                        outcome = result
                        context.exit(0)
                    })
            }
            loop.runUntilIdle()
            return (outcome, terminal.rawMode)
        }

        let failed = try run("panic(\"boom\")")
        #expect(throws: GoRuntimeError.self) { try failed.outcome?.get() }
        #expect(!failed.raw)

        let exited = try run("")
        #expect(try exited.outcome?.get().exitCode == 0)
        #expect(exited.raw)
    }

    // MARK: - Resumable budgets

    @Test func resumableInstructionBudgetBoundsEachSliceNotTheSession() throws {
        func run(lines: Int, iterations: Int) throws -> Result<GoProcessResult, any Error>? {
            let executable = try GoCompiler.compile(sources: [
                GoSourceFile(path: "main.go", text: """
                    package main
                    import "swiftix/userland"
                    func main() {
                        for {
                            _, status := userland.ReadStdin()
                            if status != 0 {
                                break
                            }
                            total := 0
                            for i := 0; i < \(iterations); i++ {
                                total = total + i
                            }
                        }
                    }
                    """)
            ])
            let loop = EventLoop()
            let kernel = Kernel(loop: loop)
            let terminal = PseudoTerminal()
            var outcome: Result<GoProcessResult, any Error>?
            kernel.spawn("app") { context in
                context.installStandardIO(terminal.slave)
                GoVirtualMachine(maximumInstructions: 50_000).startProgram(
                    executable,
                    eventLoop: loop,
                    processContext: context,
                    write: { _ in },
                    completion: { result in
                        outcome = result
                        context.exit(0)
                    })
            }
            loop.runUntilIdle()
            for _ in 0..<lines {
                terminal.writeFromApp(Array("line\n".utf8))
                loop.runUntilIdle()
            }
            terminal.writeFromApp([0x04])
            loop.runUntilIdle()
            return outcome
        }

        // Ten slices of a few thousand instructions exceed the budget in total.
        #expect(try run(lines: 10, iterations: 1_000)?.get().exitCode == 0)
        #expect(throws: GoRuntimeError.instructionLimitExceeded) {
            try run(lines: 1, iterations: 50_000)?.get()
        }
    }

    // MARK: - Type checking and image encoding

    @Test func typeCheckerEnforcesTerminalCallSignatures() {
        let invalidCalls = [
            "userland.ReadStdin(1)",
            "userland.WriteFile(\"/out\")",
            "userland.WriteFile(1, \"x\")",
            "userland.SetRawMode(1)",
            "userland.WindowSize(0)",
        ]
        for call in invalidCalls {
            #expect(throws: GoDiagnostic.self) {
                try GoCompiler.compile(sources: [
                    GoSourceFile(path: "main.go", text: """
                        package main
                        import "swiftix/userland"
                        func main() {
                            \(call)
                        }
                        """)
                ])
            }
        }
    }

    @Test func terminalInstructionsRoundTripThroughExecutableImages() throws {
        let executable = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main",
                    localCount: 0,
                    instructions: [
                        .readStdin, .writeFile, .setTerminalRawMode, .terminalWindowSize,
                        .return,
                    ])
            ])

        let image = try GoExecutableImage.encode(executable)

        #expect(try GoExecutableImage.decode(image) == executable)
    }
}
