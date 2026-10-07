import Testing
@testable import Swiftix

/// CPU-bound `async` processes and logical time. A process that loops through
/// `try await ctx.yield()` (awk, bc), reads an endless device, or runs a shell
/// loop of builtins is always ready; a real-time host that keeps calling
/// `EventLoop.advance(by:stepBudget:)` must still see the clock follow it and
/// every timer fire on time.
///
/// Concurrency: every test builds its own loop and kernel and drives them on
/// the calling executor. The "host" is a deterministic stand-in for a
/// display-link driver: fixed ticks, fixed budgets, no wall clock.
@Suite("Async CPU-bound processes and logical time")
struct AsyncYieldTests {

    static let frame = 1.0 / 60.0

    /// One frame of a real-time host: advance toward the frame's own target,
    /// spending at most `budget` steps in chunks.
    static func tick(_ loop: EventLoop, interval: Double = frame, budget: Int = 100, chunk: Int = 20) {
        let target = loop.now + interval
        var remaining = budget
        while remaining > 0 {
            let steps = min(chunk, remaining)
            remaining -= steps
            if loop.advance(by: max(0, target - loop.now), stepBudget: steps) == .completed { break }
        }
    }

    static func drive(_ loop: EventLoop, frames: Int, interval: Double = frame,
                      budget: Int = 100, chunk: Int = 20) {
        for _ in 0..<frames { tick(loop, interval: interval, budget: budget, chunk: chunk) }
    }

    final class Counter { var value = 0 }

    /// Spawn a process that yields after every slice until it is terminated.
    @discardableResult
    static func spawnSpinner(_ kernel: Kernel, name: String = "spin",
                             slices: Counter = Counter(),
                             onSlice: (() -> Void)? = nil) -> PID {
        kernel.spawn(name) { (ctx: ProcessContext) async in
            while true {
                slices.value += 1
                onSlice?()
                do { try await ctx.yield() } catch { return }
            }
        }
    }

    // MARK: - Ordering at one instant

    @Test func yieldReturnsToTheLoopAndLetsOtherProcessesRun() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var order: [String] = []
        for name in ["a", "b"] {
            kernel.spawn(name) { (ctx: ProcessContext) async in
                for slice in 0..<3 {
                    order.append("\(name)\(slice)")
                    do { try await ctx.yield() } catch { return }
                }
            }
        }
        #expect(loop.runUntilIdle() == .completed)
        #expect(order == ["a0", "b0", "a1", "b1", "a2", "b2"])
        #expect(loop.now == 0)
        #expect(kernel.snapshotProcesses().isEmpty)
    }

    @Test func drainingAtTheCurrentInstantNeverMovesTheClockPastASpinner() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let slices = Counter()
        Self.spawnSpinner(kernel, slices: slices)
        var timerRan = false
        kernel.schedule(after: 0.5) { timerRan = true }

        #expect(loop.runUntilIdle(stepBudget: 200) == .budgetExceeded)
        #expect(loop.now == 0)
        #expect(!timerRan)
        #expect(slices.value > 10)
    }

    // MARK: - Real-time driving

    @Test func spinnerDoesNotFreezeTheClockOrDelayTimers() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let slices = Counter()
        Self.spawnSpinner(kernel, slices: slices)
        var fired: [Double] = []
        for delay in [0.25, 0.5, 0.5, 1.0] {
            kernel.schedule(after: delay) { fired.append(loop.now) }
        }

        Self.drive(loop, frames: 90)

        #expect(fired == [0.25, 0.5, 0.5, 1.0])
        #expect(abs(loop.now - 1.5) < 1e-9)
        #expect(slices.value > 90)
    }

    /// Whichever half of a turn the budget stops on — the queued yield or the
    /// job that resumes the task — the interval still elapses.
    @Test(arguments: 1...9)
    func clockReachesTheTargetWhereverTheBudgetRunsOut(budget: Int) {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        Self.spawnSpinner(kernel)
        loop.runUntilIdle(stepBudget: 7)

        for frame in 1...12 {
            #expect(loop.advance(by: 0.25, stepBudget: budget) == .budgetExceeded)
            #expect(loop.now == 0.25 * Double(frame))
        }
    }

    @Test func sleepInAnotherProcessWakesOnTime() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        Self.spawnSpinner(kernel)
        var wokeAt: Double?
        kernel.spawn("sleeper") { (ctx: ProcessContext) async in
            try? await ctx.sleep(1)
            wokeAt = loop.now
        }

        Self.drive(loop, frames: 59)
        #expect(wokeAt == nil)
        Self.drive(loop, frames: 2)
        #expect(wokeAt == 1.0)
    }

    /// The contract yields are the exception to: a process that takes
    /// zero-length sleeps is ordinary ready work and still holds the clock.
    @Test func zeroLengthSleepStillHoldsTheClock() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("sleeper") { (ctx: ProcessContext) async in
            while true {
                do { try await ctx.sleep(0) } catch { return }
            }
        }

        Self.drive(loop, frames: 30)

        #expect(loop.now == 0)
    }

    /// A job posted by anything but a yield still holds the clock, also
    /// while a spinner's own job is queued next to it.
    @Test func ordinaryJobNextToAYieldedTaskHoldsTheClock() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        Self.spawnSpinner(kernel)
        loop.runUntilIdle(stepBudget: 6)
        kernel.spawn("worker") { (ctx: ProcessContext) async in
            for _ in 0..<40 { await Task.yield() }
        }

        var held = 0
        while kernel.snapshotProcesses().contains(where: { $0.name == "worker" }) {
            let before = loop.now
            loop.advance(by: 0.25, stepBudget: 3)
            if loop.now == before { held += 1 }
            if held > 1_000 { break }
        }
        // The worker's plain suspensions stopped the clock at least once…
        #expect(held > 0)
        // …and once it is gone the spinner alone no longer does.
        let before = loop.now
        loop.advance(by: 0.25, stepBudget: 3)
        #expect(loop.now == before + 0.25)
    }

    @Test func timerTimesDoNotDependOnTheBudget() {
        let delays = [0.0, 0.25, 0.25, 0.4, 1.0, 1.75, 3.0]
        for budget in [18, 20, 33, 64, 500] {
            for interval in [0.05, 0.3] {
                let loop = EventLoop()
                let kernel = Kernel(loop: loop)
                Self.spawnSpinner(kernel)
                var fired: [Double] = []
                for delay in delays {
                    kernel.schedule(after: delay) { fired.append(loop.now) }
                }
                Self.drive(loop, frames: Int((3.5 / interval).rounded(.up)),
                           interval: interval, budget: budget, chunk: budget)
                #expect(fired == delays, "budget \(budget), interval \(interval)")
            }
        }
    }

    @Test func identicalDrivingIsDeterministic() {
        func run() -> [String] {
            let loop = EventLoop()
            let kernel = Kernel(loop: loop)
            var log: [String] = []
            let slices = Counter()
            Self.spawnSpinner(kernel, name: "a", slices: slices)
            Self.spawnSpinner(kernel, name: "b") {
                if slices.value % 50 == 0 { log.append("b@\(loop.now)/\(slices.value)") }
            }
            for delay in [0.1, 0.1, 0.35, 0.8] {
                kernel.schedule(after: delay) { log.append("t\(delay)@\(loop.now)/\(slices.value)") }
            }
            Self.drive(loop, frames: 60, budget: 37, chunk: 11)
            log.append("end@\(loop.now)/\(slices.value)")
            return log
        }
        let first = run()
        #expect(first.count > 5)
        #expect(run() == first)
    }

    // MARK: - Process state and signals

    /// `ps` shows a spinning async process as running at every frame, in
    /// whichever half of a turn the frame ends, and as sleeping once it
    /// really waits.
    @Test(arguments: [3, 7, 20, 100])
    func yieldingProcessIsReportedRunnableUntilItWaits(budget: Int) {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        var spinning = true
        let pid = kernel.spawn("spin") { (ctx: ProcessContext) async in
            while spinning {
                do { try await ctx.yield() } catch { return }
            }
            try? await ctx.sleep(10)
        }
        func state() -> String? { kernel.snapshotProcesses().first { $0.pid == pid }?.state }
        Self.drive(loop, frames: 2, budget: budget, chunk: budget)

        for _ in 0..<40 {
            Self.tick(loop, budget: budget, chunk: budget)
            #expect(state() == "R")
        }

        spinning = false
        Self.drive(loop, frames: 5)
        #expect(state() == "S")
    }

    /// An async process that never yields keeps the existing report: it is
    /// sleeping whenever it waits, also for a zero-length sleep.
    @Test func sleepingAsyncProcessIsStillReportedSleeping() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pid = kernel.spawn("sleeper") { (ctx: ProcessContext) async in
            try? await ctx.sleep(10)
        }
        Self.drive(loop, frames: 5)
        #expect(kernel.snapshotProcesses().first { $0.pid == pid }?.state == "S")
    }

    @Test(arguments: ["awk 'BEGIN{while(1){x++}}' &", "cat /dev/zero > /dev/null &"])
    func spinningCommandIsReportedRunnable(_ line: String) {
        let h = CommandHarness()
        h.pty.writeFromApp(Array((line + "\n").utf8))
        Self.drive(h.loop, frames: 6, budget: 40)
        let name = String(line.prefix { $0 != " " })
        for _ in 0..<10 {
            Self.tick(h.loop, budget: 40)
            #expect(h.kernel.snapshotProcesses().first { $0.name == name }?.state == "R")
        }
    }

    @Test func yieldingProcessCanBeKilled() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let slices = Counter()
        let pid = Self.spawnSpinner(kernel, slices: slices)
        Self.drive(loop, frames: 3)
        #expect(kernel.snapshotProcesses().contains { $0.pid == pid })

        kernel.kill(pid, signal: 9)
        Self.drive(loop, frames: 3)

        #expect(!kernel.snapshotProcesses().contains { $0.pid == pid })
        let stopped = slices.value
        #expect(loop.advance(by: 1) == .completed)
        #expect(slices.value == stopped)
        #expect(!loop.hasPendingWork)
    }

    @Test func pausedKernelHoldsAYieldedProcess() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let slices = Counter()
        Self.spawnSpinner(kernel, slices: slices)
        Self.drive(loop, frames: 3)

        kernel.pause()
        Self.drive(loop, frames: 3)
        let paused = slices.value
        Self.drive(loop, frames: 3)
        #expect(slices.value == paused)
        #expect(abs(loop.now - 9 * Self.frame) < 1e-9)

        kernel.resume()
        Self.drive(loop, frames: 3)
        #expect(slices.value > paused)
        #expect(abs(loop.now - 12 * Self.frame) < 1e-9)
    }

    // MARK: - Built-in commands

    /// A `sleep` typed after the spinner starts wakes after one second of
    /// frames, and the clock followed the host throughout.
    @Test(arguments: [
        "awk 'BEGIN{while(1){x++}}' &",
        "echo 'while(1){x=x+1}' | bc &",
        "cat /dev/zero > /dev/null &",
        "dd if=/dev/urandom of=/dev/null &",
        "while :; do :; done &",
        "yes | cat > /dev/null &",
        "cat /dev/zero | cat > /dev/null &",
        "while :; do echo y; done | cat > /dev/null &",
    ])
    func sleepWakesWhileABackgroundCommandSpins(_ line: String) {
        let h = CommandHarness()
        h.pty.writeFromApp(Array((line + "\n").utf8))
        Self.drive(h.loop, frames: 6, budget: 40)
        h.clearOutput()
        h.pty.writeFromApp(Array("sleep 1; echo woke-$?\n".utf8))
        let started = h.loop.now

        Self.drive(h.loop, frames: 57, budget: 40)
        #expect(!h.output().contains("woke-0"))
        Self.drive(h.loop, frames: 9, budget: 40)
        #expect(h.output().contains("woke-0"))
        #expect(abs(h.loop.now - started - 66 * Self.frame) < 1e-9)
    }

    /// A loop of builtins used to run as one endless step, so the call that
    /// started it never returned.
    @Test func shellLoopOfBuiltinsReturnsToTheEventLoop() {
        let h = CommandHarness()
        h.pty.writeFromApp(Array("while :; do :; done &\n".utf8))
        #expect(h.loop.advance(by: 0.05, stepBudget: 500) == .budgetExceeded)
        #expect(h.loop.now == 0.05)
        #expect(h.loop.runUntilIdle(stepBudget: 500) == .budgetExceeded)

        // The interactive shell is still responsive next to it.
        h.clearOutput()
        h.pty.writeFromApp(Array("echo still-here; kill %1\n".utf8))
        Self.drive(h.loop, frames: 10)
        #expect(h.output().contains("still-here"))
        #expect(h.loop.runUntilIdle() == .completed)
    }

    @Test func foregroundShellLoopOfBuiltinsIsInterruptedByControlC() {
        let h = CommandHarness()
        h.pty.writeFromApp(Array("while :; do :; done; echo not-reached\n".utf8))
        #expect(h.loop.runUntilIdle(stepBudget: 500) == .budgetExceeded)
        h.pty.writeFromApp([0x03])
        #expect(h.loop.runUntilIdle() == .completed)
        #expect(h.console("echo back").contains("back"))
        #expect(!h.output().contains("not-reached"))
    }
}
