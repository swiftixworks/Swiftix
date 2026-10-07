/// Logical time under a CPU-bound Go process: a real-time host keeps calling
/// `EventLoop.advance(by:stepBudget:)` with elapsed time and a bounded amount
/// of work, and the kernel's timers (another process's `sleep`, network
/// retransmission) must fire on that clock while the Go program keeps running.
///
/// Concurrency: every test builds its own loop and kernel and drives them on
/// the calling executor. The "host" below is a deterministic stand-in for a
/// display-link driver: fixed ticks, fixed budgets, no wall clock.

import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime

@Suite("Go CPU-bound processes and kernel timers")
struct GoTimerFairnessTests {

    static let spinner = """
        package main
        func main() {
            for {
            }
        }
        """

    /// One frame of a real-time host: advance by the elapsed interval, spending
    /// at most `budget` steps in chunks, exactly as a host that bounds each
    /// slice by work and by its own deadline does.
    static func tick(_ loop: EventLoop, interval: Double, budget: Int, chunk: Int = 64) {
        let target = loop.now + interval
        var remaining = budget
        while remaining > 0 {
            let steps = min(chunk, remaining)
            remaining -= steps
            if loop.advance(by: max(0, target - loop.now), stepBudget: steps) == .completed { break }
        }
    }

    static func drive(_ session: GoProcessSession, seconds: Double,
                      interval: Double = 1.0 / 60.0, budget: Int = 16) {
        let ticks = Int((seconds / interval).rounded(.up))
        for _ in 0..<ticks { tick(session.loop, interval: interval, budget: budget) }
    }

    @Test func sleepInAnotherProcessWakesWhileAGoProgramSpins() throws {
        let session = try GoProcessSession(["/spin": Self.spinner])
        session.terminal.writeFromApp(Array("/spin &\n".utf8))
        Self.drive(session, seconds: 0.1)
        session.terminal.writeFromApp(Array("sleep 1; echo woke-$?\n".utf8))
        let started = session.loop.now

        Self.drive(session, seconds: 0.9)
        #expect(!session.takeOutput().contains("woke-0"))
        Self.drive(session, seconds: 0.3)
        #expect(session.takeOutput().contains("woke-0"))
        // The clock followed the host: 1.2 s of frames is 1.2 s of logical time.
        #expect(abs(session.loop.now - started - 1.2) < 1e-9)
    }

    /// A timer owned by the kernel itself fires at exactly its deadline.
    @Test func kernelTimerFiresAtItsDeadlineWhileAGoProgramSpins() throws {
        let session = try GoProcessSession(["/spin": Self.spinner])
        session.terminal.writeFromApp(Array("/spin &\n".utf8))
        Self.drive(session, seconds: 0.1)
        let loop = session.loop
        let scheduledAt = loop.now
        var firedAt: [Double] = []
        session.kernel.schedule(after: 0.5) { firedAt.append(loop.now) }
        session.kernel.schedule(after: 0.75) { firedAt.append(loop.now) }

        Self.drive(session, seconds: 1)

        #expect(firedAt == [scheduledAt + 0.5, scheduledAt + 0.75])
    }

    /// Network timers run on the same clock: with nothing answering ARP, the
    /// echo request times out and `ping` reports the loss.
    @Test func networkTimeoutExpiresWhileAGoProgramSpins() throws {
        let session = try GoProcessSession(["/spin": Self.spinner])
        session.kernel.netns.stack.configure(.addInterface(NetworkInterfaceConfiguration(
            address: IPv4Address(10, 0, 0, 1),
            mac: MACAddress("02:00:00:00:00:0a")!,
            prefixLength: 24)))
        session.terminal.writeFromApp(Array("/spin &\n".utf8))
        Self.drive(session, seconds: 0.1)
        session.terminal.writeFromApp(Array("ping -c 2 -i 0.5 -W 0.5 10.0.0.99\n".utf8))

        Self.drive(session, seconds: 3)

        #expect(session.takeOutput().contains("2 packets transmitted, 0 received, 100.0% packet loss, time 1000ms"))
    }

    /// Timers interleave with the program instead of replacing it: a program
    /// with a fixed amount of work finishes while other processes sleep.
    @Test func goProgramKeepsRunningBetweenTimers() throws {
        let session = try GoProcessSession([
            "/work": """
                package main
                import "fmt"
                func main() {
                    total := 0
                    for index := 0; index < 150000; index++ {
                        total = total + index
                    }
                    fmt.Println("worked", total)
                }
                """,
        ])
        session.terminal.writeFromApp(Array(
            "/work & for n in 1 2 3 4 5 6 7 8; do sleep 0.05; done; echo slept-$?\n".utf8))

        Self.drive(session, seconds: 3)

        let text = session.takeOutput()
        #expect(text.contains("worked 11249925000"))
        #expect(text.contains("slept-0"))
    }

    @Test func spinningProgramIsRunnableAndStillAnswersSignals() throws {
        let session = try GoProcessSession(["/spin": Self.spinner])
        session.terminal.writeFromApp(Array("/spin &\n".utf8))
        Self.drive(session, seconds: 0.2)
        func spinner() -> Kernel.ProcessSnapshot? {
            session.kernel.snapshotProcesses().first { $0.name == "/spin" }
        }
        // Yielding, not sleeping: `ps` shows a CPU-bound process as running.
        #expect(spinner()?.state == "R")
        let stepsBefore = session.kernel.schedulerStepCount

        // A paused kernel holds the yielded slice like any other work.
        session.kernel.pause()
        #expect(session.loop.pendingWorkCount == 0)
        Self.drive(session, seconds: 0.2)
        #expect(session.kernel.schedulerStepCount == stepsBefore)
        session.kernel.resume()
        Self.drive(session, seconds: 0.2)
        #expect(session.kernel.schedulerStepCount > stepsBefore)

        session.terminal.writeFromApp(Array("kill $!; sleep 0.1; echo killed-$?\n".utf8))
        Self.drive(session, seconds: 0.5)
        #expect(session.takeOutput().contains("killed-0"))
        #expect(spinner() == nil)
        // Nothing is left to run, so the host can go idle again.
        #expect(session.loop.advance(by: 1) == .completed)
    }

    /// Identical driving gives an identical run: same output, same clock, and
    /// the same number of scheduler steps.
    @Test func identicalDrivingIsDeterministic() throws {
        func run() throws -> String {
            let session = try GoProcessSession(["/spin": Self.spinner])
            session.terminal.writeFromApp(Array("/spin &\n".utf8))
            Self.drive(session, seconds: 0.1)
            session.terminal.writeFromApp(Array(
                "sleep 0.3; date +%s.%N; sleep 0.2; echo woke-$?; cat /proc/uptime\n".utf8))
            Self.drive(session, seconds: 1)
            return session.takeOutput()
                + "|now=\(session.loop.now)|steps=\(session.kernel.schedulerStepCount)"
        }
        let reference = try run()
        #expect(reference.contains("woke-0"))
        #expect(try run() == reference)
    }
}
