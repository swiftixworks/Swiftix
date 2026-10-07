/// File-backed Go processes: cooperative scheduling, park/wake sleep, pipe
/// backpressure, and the instruction policy of `GoExecutableLoader`.
///
/// Concurrency: every fixture builds its own `EventLoop` + `Kernel` and drives
/// it on the calling executor; nothing is shared between tests.

import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

/// A shell on a pty with compiled Go programs installed as executables, driven
/// the way a terminal consumer drives it.
final class GoProcessSession {
    let loop = EventLoop()
    let kernel: Kernel
    let terminal = PseudoTerminal()
    private var output: [UInt8] = []

    /// `programs` maps an absolute guest path to Go source.
    init(_ programs: [String: String], files: [String: [UInt8]] = [:]) throws {
        kernel = Kernel(loop: loop)
        var images: [(String, [UInt8])] = []
        for (path, source) in programs.sorted(by: { $0.key < $1.key }) {
            images.append((path, try GoExecutableImage.encode(
                GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)]))))
        }
        kernel.spawn("seed") { context in
            for (path, image) in images {
                let descriptor = context.open(path, create: true, truncate: true)!
                context.write(descriptor, image)
                context.close(descriptor)
                _ = context.chmod(path, mode: [.ownerRead, .ownerWrite, .ownerExecute])
            }
            for (path, contents) in files.sorted(by: { $0.key < $1.key }) {
                let descriptor = context.open(path, create: true, truncate: true)!
                context.write(descriptor, contents)
                context.close(descriptor)
            }
            context.exit(0)
        }
        loop.runUntilIdle()
        terminal.onOutput = { [unowned self] in
            output.append(contentsOf: terminal.readForApp(max: 65_535))
        }
        terminal.onControlC = { [unowned self] in
            kernel.interruptProcessGroup(
                terminal.foregroundProcessGroupID, signal: Signal.sigint.rawValue)
        }
        let registry = CommandRegistry.builtins
        GoExecutableLoader.register(in: registry)
        kernel.spawn("sh", Programs.shell(tty: terminal.slave, commands: registry))
        settle()
        _ = takeOutput()
    }

    /// Run everything that is ready at the current logical time. A long guest
    /// computation spans many event-loop steps, so drain until the loop is idle.
    func settle() {
        var rounds = 0
        while loop.runUntilIdle() == .budgetExceeded, rounds < 10_000 { rounds += 1 }
    }

    func type(_ text: String) {
        terminal.writeFromApp(Array(text.utf8))
        settle()
    }

    func send(_ bytes: [UInt8]) {
        terminal.writeFromApp(bytes)
        settle()
    }

    /// Advance logical time and run what became due.
    func advance(by seconds: Double) {
        var remaining = 10_000
        let target = loop.now + seconds
        while loop.advance(by: max(0, target - loop.now)) == .budgetExceeded, remaining > 0 {
            remaining -= 1
        }
        settle()
    }

    /// Terminal output since the previous call.
    func takeOutput() -> String {
        defer { output.removeAll() }
        return String(decoding: output, as: UTF8.self)
    }

    /// Type one command line and return what it printed, without the echo of
    /// the command or the following prompt.
    func run(_ line: String) -> String {
        type(line + "\n")
        return commandOutput()
    }

    /// Output of the command typed last: everything between the echoed command
    /// line and the next prompt.
    func commandOutput() -> String {
        let text = takeOutput().replacingOccurrences(of: "\r\n", with: "\n")
        guard let firstNewline = text.firstIndex(of: "\n") else { return "" }
        var lines = text[text.index(after: firstNewline)...].split(
            separator: "\n", omittingEmptySubsequences: false)
        if !lines.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

extension String {
    fileprivate func replacingOccurrences(of target: String, with replacement: String) -> String {
        var result = ""
        var rest = self[...]
        while let range = rest.firstRange(of: target) {
            result += rest[..<range.lowerBound]
            result += replacement
            rest = rest[range.upperBound...]
        }
        result += rest
        return result
    }
}

@Suite("Go file-backed processes")
struct GoProcessExecutionTests {

    // MARK: - Instruction policy

    @Test func longComputationIsNotCutOffByATotalInstructionCap() throws {
        let session = try GoProcessSession([
            "/spin": """
                package main
                import "fmt"
                func main() {
                    total := 0
                    for index := 0; index < 400000; index++ {
                        total = total + index
                    }
                    fmt.Println(total)
                }
                """,
        ])
        #expect(session.run("/spin") == "79999800000")
        #expect(session.run("echo status=$?") == "status=0")
    }

    @Test func cpuBoundProcessSharesTheEventLoopWithOtherProcesses() throws {
        let session = try GoProcessSession([
            "/spin": """
                package main
                import "fmt"
                func main() {
                    total := 0
                    for index := 0; index < 200000; index++ {
                        total = total + index
                    }
                    fmt.Println("spun")
                }
                """,
        ])
        // The background spinner needs hundreds of quanta; the foreground echo
        // must not wait for it.
        session.type("/spin & echo first\n")
        let text = session.takeOutput()
        let first = try #require(text.firstRange(of: "\nfirst"))
        let spun = try #require(text.firstRange(of: "spun"))
        #expect(first.lowerBound < spun.lowerBound)
    }

    @Test func runawayProcessCanBeInterrupted() throws {
        let session = try GoProcessSession([
            "/forever": """
                package main
                func main() {
                    for {
                    }
                }
                """,
        ])
        session.terminal.writeFromApp(Array("/forever\n".utf8))
        #expect(session.loop.runUntilIdle(stepBudget: 2_000) == .budgetExceeded)
        session.terminal.writeFromApp([0x03])
        #expect(session.loop.runUntilIdle(stepBudget: 2_000) == .completed)
        _ = session.takeOutput()
        #expect(session.run("echo status=$?") == "status=130")
    }

    @Test func hostCanStillBoundAProcessWithAnInstructionBudget() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: """
                package main
                func main() {
                    for {
                    }
                }
                """)
        ])
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var outcome: Result<GoProcessResult, any Error>?
        kernel.spawn("bounded") { context in
            GoVirtualMachine().startProcess(
                executable, processContext: context, instructionBudget: 50_000
            ) { result in
                outcome = result
                context.exit(1)
            }
        }
        while loop.runUntilIdle() == .budgetExceeded {}
        guard case .failure(let error) = outcome else {
            Issue.record("the run did not fail: \(String(describing: outcome))")
            return
        }
        #expect(error as? GoRuntimeError == .instructionLimitExceeded)
    }

    @Test func completionReportsTheExitCodeOfAProcessThatParked() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(path: "main.go", text: """
                package main
                import "os"
                import "time"
                func main() {
                    time.Sleep(time.Second)
                    os.Exit(7)
                }
                """)
        ])
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var exitCode: Int32?
        var completions = 0
        kernel.spawn("napper") { context in
            GoVirtualMachine().startProcess(executable, processContext: context) { result in
                completions += 1
                exitCode = try? result.get().exitCode
                context.exit(exitCode ?? 1)
            }
        }
        loop.runUntilIdle()
        #expect(completions == 0)
        loop.advance(by: 1)
        #expect(completions == 1)
        #expect(exitCode == 7)
    }

    @Test func deadlockIsStillReported() throws {
        let session = try GoProcessSession([
            "/stuck": """
                package main
                func main() {
                    gate := make(chan int)
                    <-gate
                }
                """,
        ])
        #expect(session.run("/stuck").contains("all goroutines are asleep"))
        #expect(session.run("echo status=$?") == "status=1")
    }

    // MARK: - Sleep

    @Test func sleepParksTheProcessUntilLogicalTimeAdvances() throws {
        let session = try GoProcessSession([
            "/nap": """
                package main
                import "fmt"
                import "time"
                func main() {
                    fmt.Println("down")
                    time.Sleep(2 * time.Second)
                    fmt.Println("up")
                }
                """,
        ])
        let start = session.loop.now
        session.type("/nap\n")
        let before = session.takeOutput()
        #expect(before.contains("down"))
        #expect(!before.contains("up"))
        #expect(session.loop.now == start)

        session.advance(by: 1)
        #expect(!session.takeOutput().contains("up"))
        session.advance(by: 1)
        #expect(session.takeOutput().contains("up"))
    }

    @Test func pollingLoopDoesNotSpinWhileItSleeps() throws {
        let session = try GoProcessSession([
            "/poll": """
                package main
                import "fmt"
                import "time"
                func main() {
                    for round := 0; round < 100000; round++ {
                        time.Sleep(time.Second)
                        fmt.Println("tick", round)
                    }
                }
                """,
        ])
        session.type("/poll\n")
        #expect(!session.takeOutput().contains("tick"))
        session.advance(by: 3)
        let text = session.takeOutput()
        #expect(text.contains("tick 2"))
        #expect(!text.contains("tick 3"))
        session.send([0x03])
        _ = session.takeOutput()
        #expect(session.run("echo status=$?") == "status=130")
    }

    @Test func sleepingProcessIsReportedAsWaiting() throws {
        let session = try GoProcessSession([
            "/nap": """
                package main
                import "time"
                func main() {
                    time.Sleep(60 * time.Second)
                }
                """,
        ])
        session.type("/nap &\n")
        _ = session.takeOutput()
        let napping = session.kernel.snapshotProcesses().first { $0.name == "/nap" }
        #expect(napping?.state == "S")
        #expect(napping?.waitReasons.contains { $0.contains("sleep") } == true)
    }

    // MARK: - Pipes

    @Test func outputLargerThanAPipeIsDeliveredInFull() throws {
        let session = try GoProcessSession([
            "/gen": """
                package main
                import "fmt"
                import "strings"
                func main() {
                    line := strings.Repeat("x", 99) + "\\n"
                    for index := 0; index < 3000; index++ {
                        fmt.Print(line)
                    }
                }
                """,
        ])
        #expect(session.run("/gen | wc -c").trimmingWhitespace() == "300000")
    }

    @Test func oneWriteLargerThanAPipeIsDeliveredInFull() throws {
        let session = try GoProcessSession([
            "/gen": """
                package main
                import "fmt"
                import "strings"
                func main() {
                    fmt.Print(strings.Repeat("0123456789", 50000))
                    fmt.Println()
                    fmt.Println("end")
                }
                """,
        ])
        #expect(session.run("/gen | wc -c").trimmingWhitespace() == "500005")
        #expect(session.run("/gen | tail -n 1") == "end")
    }

    @Test func goReaderAndGoWriterStreamThroughAPipe() throws {
        let session = try GoProcessSession([
            "/gen": """
                package main
                import "fmt"
                import "strings"
                func main() {
                    line := strings.Repeat("y", 49) + "\\n"
                    for index := 0; index < 8000; index++ {
                        fmt.Print(line)
                    }
                }
                """,
            "/count": """
                package main
                import "fmt"
                import "swiftix/userland"
                func main() {
                    total := 0
                    for {
                        chunk, status := userland.ReadStdin()
                        if status != 0 {
                            break
                        }
                        total = total + len(chunk)
                    }
                    fmt.Println(total)
                }
                """,
            "/slurp": """
                package main
                import "fmt"
                import "swiftix/userland"
                func main() {
                    data, _ := userland.ReadInput("slurp", []string{})
                    fmt.Println(len(data))
                }
                """,
        ])
        #expect(session.run("/gen | /count") == "400000")
        #expect(session.run("/gen | /slurp") == "400000")
        #expect(session.run("/gen | /count | /count") == "7")
    }

    @Test func writerStopsWhenTheReaderGoesAway() throws {
        let session = try GoProcessSession([
            "/gen": """
                package main
                import "fmt"
                import "strings"
                func main() {
                    line := strings.Repeat("z", 99) + "\\n"
                    for {
                        fmt.Print(line)
                    }
                }
                """,
        ])
        #expect(session.run("/gen | head -n 2 | wc -c").trimmingWhitespace() == "200")
        #expect(session.run("echo alive") == "alive")
    }

    @Test func goroutinesWritingConcurrentlyKeepEachWriteWhole() throws {
        let session = try GoProcessSession([
            "/duo": """
                package main
                import "fmt"
                import "strings"
                import "sync"
                func emit(mark string, group *sync.WaitGroup) {
                    line := strings.Repeat(mark, 4095) + "\\n"
                    for index := 0; index < 40; index++ {
                        fmt.Print(line)
                    }
                    group.Done()
                }
                func main() {
                    var group sync.WaitGroup
                    group.Add(2)
                    go emit("a", &group)
                    go emit("b", &group)
                    group.Wait()
                }
                """,
        ])
        #expect(session.run("/duo | wc -c").trimmingWhitespace() == "327680")
        #expect(session.run("/duo | grep -c ab") == "0")
        #expect(session.run("/duo | grep -c ba") == "0")
    }
}

extension String {
    fileprivate func trimmingWhitespace() -> String {
        String(self.drop(while: { $0 == " " || $0 == "\n" }).reversed()
            .drop(while: { $0 == " " || $0 == "\n" }).reversed())
    }
}
