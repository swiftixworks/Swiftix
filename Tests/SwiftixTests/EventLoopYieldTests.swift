import Testing
@testable import Swiftix

/// Yielded CPU-bound work on the event loop: it keeps its place among ready
/// work, but a task that yields forever neither starves timers nor freezes the
/// clock under `advance(by:)`. Ordinary zero-delay work keeps the stricter
/// "the clock waits for it" contract covered by `EventLoopTests`.
@Suite("Event loop yielded work")
struct EventLoopYieldTests {

    /// A task that yields after every slice, like a CPU-bound process.
    final class Yielder {
        let scope: EventLoop.CancellationScope
        /// Slices still to run; `nil` never finishes.
        var remaining: Int?
        private(set) var slices = 0
        var onSlice: (() -> Void)?

        init(loop: EventLoop, slices: Int? = nil) {
            scope = loop.makeCancellationScope()
            remaining = slices
        }

        func start() {
            scope.yield { [weak self] in self?.run() }
        }

        private func run() {
            slices += 1
            onSlice?()
            if let remaining {
                self.remaining = remaining - 1
                guard remaining > 1 else { return }
            }
            scope.yield { [weak self] in self?.run() }
        }
    }

    // MARK: - Ordering at one instant

    @Test func yieldKeepsItsPlaceAmongReadyWork() {
        let loop = EventLoop()
        let scope = loop.makeCancellationScope()
        var order: [String] = []
        loop.post { order.append("a") }
        scope.yield {
            order.append("yield")
            scope.yield { order.append("yield again") }
            loop.post { order.append("d") }
        }
        loop.post { order.append("b") }
        loop.schedule(after: 1) { order.append("later") }

        #expect(loop.pendingWorkCount == 4)
        #expect(loop.nextDeadline == 0)
        #expect(loop.runUntilIdle() == .completed)

        #expect(order == ["a", "yield", "b", "yield again", "d"])
        #expect(loop.now == 0)
        #expect(loop.pendingWorkCount == 1)
    }

    @Test func drainingAtTheCurrentInstantNeverMovesTheClockPastAYielder() {
        let loop = EventLoop()
        let yielder = Yielder(loop: loop)
        var timerRan = false
        loop.schedule(after: 1) { timerRan = true }
        yielder.start()

        #expect(loop.runUntilIdle(stepBudget: 50) == .budgetExceeded)
        #expect(yielder.slices == 50)
        #expect(loop.now == 0)
        #expect(!timerRan)

        // `runNext` still takes work in strict order: ready before future.
        for _ in 0..<20 { #expect(loop.runNext()) }
        #expect(yielder.slices == 70)
        #expect(loop.now == 0)
        #expect(!timerRan)
        yielder.scope.cancel()
    }

    // MARK: - advance(by:)

    /// The reported starvation: a task that yields forever kept `advance` from
    /// ever reaching its target, so no timer could become due.
    @Test func perpetualYielderDoesNotFreezeTheClockOrStarveTimers() {
        let loop = EventLoop()
        let yielder = Yielder(loop: loop)
        var fired: [Double] = []
        loop.schedule(after: 0.5) { fired.append(loop.now) }
        loop.schedule(after: 1.5) { fired.append(loop.now) }
        loop.schedule(after: 2.5) { fired.append(loop.now) }
        yielder.start()

        #expect(loop.advance(by: 2, stepBudget: 100) == .budgetExceeded)

        #expect(fired == [0.5, 1.5])
        #expect(loop.now == 2)
        #expect(yielder.slices == 98)
        #expect(loop.hasPendingWork)

        #expect(loop.advance(by: 1, stepBudget: 100) == .budgetExceeded)
        #expect(fired == [0.5, 1.5, 2.5])
        #expect(loop.now == 3)
        #expect(yielder.slices == 197)
        yielder.scope.cancel()
        #expect(!loop.hasPendingWork)
    }

    @Test func timerInTheWindowWaitsForOnlyAShortBurstOfYields() {
        let loop = EventLoop()
        let yielder = Yielder(loop: loop)
        var slicesBeforeTimer = -1
        loop.schedule(after: 1) { slicesBeforeTimer = yielder.slices }
        yielder.start()

        _ = loop.advance(by: 1, stepBudget: 1_000)

        #expect(slicesBeforeTimer == 8)
        #expect(yielder.slices == 999)
        yielder.scope.cancel()
    }

    @Test func yielderThatFinishesLetsAdvanceComplete() {
        let loop = EventLoop()
        let yielder = Yielder(loop: loop, slices: 40)
        var fired: [Double] = []
        loop.schedule(after: 1) { fired.append(loop.now) }
        yielder.start()

        #expect(loop.advance(by: 2) == .completed)
        #expect(yielder.slices == 40)
        #expect(fired == [1])
        #expect(loop.now == 2)
        #expect(!loop.hasPendingWork)
    }

    /// Only yields are passed. Zero-delay work that is not a yield still
    /// holds the clock, with or without a yielder beside it.
    @Test func ordinaryReadyWorkStillHoldsTheClock() {
        let loop = EventLoop()
        let reposter = EventLoopTests.Reposter(loop: loop)
        let yielder = Yielder(loop: loop)
        var timerRan = false
        reposter.start()
        yielder.start()
        loop.schedule(after: 1) { timerRan = true }

        #expect(loop.advance(by: 2, stepBudget: 60) == .budgetExceeded)
        #expect(loop.now == 0)
        #expect(!timerRan)
        #expect(reposter.invocations == 30)
        #expect(yielder.slices == 30)

        // Once the ordinary work is done, the yielder alone no longer does.
        reposter.isEnabled = false
        #expect(loop.advance(by: 2, stepBudget: 60) == .budgetExceeded)
        #expect(timerRan)
        #expect(loop.now == 2)
        yielder.scope.cancel()
    }

    /// A timer the budget did not reach is never jumped over.
    @Test func exhaustedBudgetDoesNotPassAnUnprocessedTimer() {
        let loop = EventLoop()
        let yielder = Yielder(loop: loop)
        var fired: [Double] = []
        loop.schedule(after: 1) { fired.append(loop.now) }
        yielder.start()

        #expect(loop.advance(by: 2, stepBudget: 4) == .budgetExceeded)
        #expect(loop.now == 0)
        #expect(fired.isEmpty)

        // The burst carries over to the next call, so the timer is reached.
        #expect(loop.advance(by: 2, stepBudget: 6) == .budgetExceeded)
        #expect(fired == [1])
        #expect(loop.now == 2)
        yielder.scope.cancel()
    }

    /// Property: however the host slices its budget, every timer fires at
    /// exactly its own deadline, in deadline order, and the clock ends on the
    /// requested time. Only the yielder's share of the work depends on the
    /// budget. The host here does what a real-time driver does: when a call
    /// stops short of the frame's target because timers were still due, it
    /// calls again for the remainder.
    @Test func timerTimesDoNotDependOnTheBudget() {
        let delays = [0.0, 0.25, 0.25, 0.4, 1.0, 1.75, 3.0, 3.0, 4.5]
        for budget in [9, 16, 17, 64, 1_000] {
            for interval in [0.05, 0.3, 5.0] {
                let loop = EventLoop()
                let yielder = Yielder(loop: loop)
                var fired: [(index: Int, at: Double)] = []
                for (index, delay) in delays.enumerated() {
                    loop.schedule(after: delay) { fired.append((index, loop.now)) }
                }
                yielder.start()

                var target = 0.0
                var calls = 0
                while target < 5 - 1e-9 {
                    target += interval
                    while loop.now < target, calls < 10_000 {
                        #expect(loop.advance(by: target - loop.now, stepBudget: budget) == .budgetExceeded)
                        calls += 1
                    }
                }

                let comment: Comment = "budget \(budget), interval \(interval)"
                #expect(fired.map(\.index) == Array(delays.indices), comment)
                #expect(fired.map(\.at) == delays, comment)
                #expect(abs(loop.now - target) < 1e-9, comment)
                #expect(yielder.slices == calls * budget - delays.count, comment)
                yielder.scope.cancel()
            }
        }
    }

    @Test func identicalDrivingIsDeterministic() {
        func run() -> [String] {
            let loop = EventLoop()
            var log: [String] = []
            let first = Yielder(loop: loop)
            let second = Yielder(loop: loop, slices: 25)
            first.onSlice = { if first.slices % 7 == 0 { log.append("first \(first.slices) @\(loop.now)") } }
            second.onSlice = { if second.slices % 5 == 0 { log.append("second \(second.slices) @\(loop.now)") } }
            for index in 0..<6 {
                loop.schedule(after: Double(index) * 0.3) { log.append("timer \(index) @\(loop.now)") }
            }
            first.start()
            second.start()
            for _ in 0..<20 { _ = loop.advance(by: 0.1, stepBudget: 13) }
            log.append("end @\(loop.now) first=\(first.slices) second=\(second.slices)")
            first.scope.cancel()
            return log
        }
        let reference = run()
        #expect(reference.count > 10)
        #expect(run() == reference)
    }

    // MARK: - Ownership

    @Test func cancellingAScopeRemovesItsYield() {
        let loop = EventLoop()
        let yielder = Yielder(loop: loop)
        let other = Yielder(loop: loop, slices: 3)
        yielder.start()
        other.start()
        #expect(loop.pendingWorkCount == 2)

        yielder.scope.cancel()
        #expect(loop.pendingWorkCount == 1)
        #expect(loop.runUntilIdle() == .completed)
        #expect(yielder.slices == 0)
        #expect(other.slices == 3)
    }

    @Test func pausedYieldResumesAsAYield() {
        let loop = EventLoop()
        let yielder = Yielder(loop: loop)
        var timerRan = false
        yielder.start()
        loop.schedule(after: 1) { timerRan = true }

        yielder.scope.pause()
        #expect(loop.pendingWorkCount == 1)
        #expect(loop.advance(by: 0.5) == .completed)
        #expect(yielder.slices == 0)

        yielder.scope.resume()
        #expect(loop.pendingWorkCount == 2)
        // Still a yield after the round trip: the clock passes it.
        #expect(loop.advance(by: 1, stepBudget: 20) == .budgetExceeded)
        #expect(timerRan)
        #expect(loop.now == 1.5)
        #expect(yielder.slices == 19)
        yielder.scope.cancel()
    }
}
