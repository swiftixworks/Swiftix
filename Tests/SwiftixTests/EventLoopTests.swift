import Testing
@testable import Swiftix

/// Logical-clock, bounded-drain, and pending-work contract tests.
@Suite("Event loop clock contract")
struct EventLoopTests {

    /// Generates zero-delay work without making the queued closure retain the
    /// helper. Tests can stop it and drain the final post for clean teardown.
    final class Reposter {
        let loop: EventLoop
        var isEnabled = true
        private(set) var invocations = 0

        init(loop: EventLoop) {
            self.loop = loop
        }

        func start() {
            loop.post { [weak self] in self?.run() }
        }

        private func run() {
            invocations += 1
            if isEnabled {
                loop.post { [weak self] in self?.run() }
            }
        }
    }

    @Test func invalidAdvanceIntervalsLeaveClockAndDeadlinesUntouched() {
        let loop = EventLoop()
        var fired = false
        loop.schedule(after: 1) { fired = true }
        loop.advance(by: 0.5)

        loop.advance(by: -1)
        loop.advance(by: .nan)
        loop.advance(by: .infinity)

        #expect(loop.now == 0.5)
        #expect(!fired)
        #expect(loop.pendingCount == 1)
        #expect(loop.pendingWorkCount == 1)
        #expect(loop.nextDeadline == 1)

        loop.advance(by: 0.5)
        #expect(fired)
        #expect(loop.now == 1)
    }

    @Test func overflowingAdvanceDoesNotPoisonClock() {
        let loop = EventLoop()
        loop.advance(by: Double.greatestFiniteMagnitude)
        let stable = loop.now

        loop.advance(by: Double.greatestFiniteMagnitude)

        #expect(loop.now == stable)
        #expect(loop.now.isFinite)
    }

    @Test func timerHeapPreservesDeadlineAndEqualDeadlineFIFOOrderAtScale() {
        let loop = EventLoop()
        var fired: [Int] = []
        let count = 10_000
        for value in (0..<count).reversed() {
            loop.schedule(after: Double(value % 100)) { fired.append(value) }
        }

        let result = loop.advance(by: 100)   // advance past all deadlines (0...99)

        #expect(result == .completed)
        #expect(fired.count == count)
        #expect(zip(fired, fired.dropFirst()).allSatisfy { lhs, rhs in
            let lhsDeadline = lhs % 100
            let rhsDeadline = rhs % 100
            return lhsDeadline < rhsDeadline || (lhsDeadline == rhsDeadline && lhs > rhs)
        })
        #expect(loop.pendingCount == 0)
        #expect(!loop.hasPendingWork)
        #expect(loop.nextDeadline == nil)
    }

    @Test func nonFiniteTimerDelayIsRejected() {
        let loop = EventLoop()
        loop.schedule(after: .nan) { Issue.record("NaN timer fired") }
        loop.schedule(after: .infinity) { Issue.record("infinite timer fired") }

        #expect(loop.pendingCount == 0)
        #expect(loop.runUntilIdle() == .completed)
        #expect(loop.now == 0)
    }

    @Test func runNextStopsAtEachLogicalWakeup() {
        let loop = EventLoop()
        var fired: [Int] = []
        loop.schedule(after: 2) { fired.append(2) }
        loop.schedule(after: 1) { fired.append(1) }

        #expect(loop.runNext())
        #expect(fired == [1])
        #expect(loop.now == 1)
        #expect(loop.pendingCount == 1)

        #expect(loop.runNext())
        #expect(fired == [1, 2])
        #expect(loop.now == 2)
        #expect(!loop.runNext())
    }

    @Test func nestedRunNextCannotMoveNowBackwardWhenOuterAdvanceReturns() {
        let loop = EventLoop()
        var nestedTimerRan = false
        var nestedRunReturned = false

        loop.schedule(after: 1) {
            loop.schedule(after: 4) { nestedTimerRan = true }
            nestedRunReturned = loop.runNext()
        }

        let result = loop.advance(by: 2)

        #expect(result == .completed)
        #expect(nestedRunReturned)
        #expect(nestedTimerRan)
        #expect(loop.now == 5)
    }

    @Test func zeroDelaySelfPostStopsAtBudgetAndKeepsPendingWork() {
        let loop = EventLoop()
        let reposter = Reposter(loop: loop)
        reposter.start()

        let result = loop.runUntilIdle(stepBudget: 7)

        #expect(result == .budgetExceeded)
        #expect(reposter.invocations == 7)
        #expect(loop.hasPendingWork)
        #expect(loop.pendingWorkCount == 1)
        #expect(loop.nextDeadline == loop.now)

        reposter.isEnabled = false
        #expect(loop.runUntilIdle() == .completed)
        #expect(!loop.hasPendingWork)
    }

    @Test func exhaustedAdvanceBudgetDoesNotJumpPastUnprocessedEvent() {
        let loop = EventLoop()
        let reposter = Reposter(loop: loop)
        var futureTimerRan = false
        reposter.start()
        loop.schedule(after: 1) { futureTimerRan = true }

        let result = loop.advance(by: 2, stepBudget: 5)

        #expect(result == .budgetExceeded)
        #expect(loop.now == 0)
        #expect(!futureTimerRan)
        #expect(loop.pendingWorkCount == 2)
        #expect(loop.nextDeadline == 0)

        reposter.isEnabled = false
        loop.runUntilIdle()
        loop.advance(by: 1)
        #expect(futureTimerRan)
    }

    @Test func pausedOwnerPreservesRemainingDelayWithoutBlockingOtherWork() {
        let loop = EventLoop()
        let owner = loop.makeWorkOwner()
        var ownedFired = false
        var unownedFired = false

        loop.schedule(after: 5, owner: owner) { ownedFired = true }
        loop.schedule(after: 1) { unownedFired = true }
        loop.pause(owner)

        // Paused work is outside the runnable heap and pending metrics.
        #expect(loop.pendingCount == 1)
        #expect(loop.nextDeadline == 1)
        loop.advance(by: 10)
        #expect(unownedFired)
        #expect(!ownedFired)
        #expect(loop.now == 10)
        #expect(!loop.hasPendingWork)

        // The owner resumes with the original five seconds still remaining.
        loop.resume(owner)
        #expect(loop.nextDeadline == 15)
        loop.advance(by: 4.999)
        #expect(!ownedFired)
        loop.advance(by: 15 - loop.now)
        #expect(ownedFired)
    }

    @Test func cancellingOwnerPhysicallyRemovesActiveAndPausedWork() {
        let loop = EventLoop()
        let owner = loop.makeWorkOwner()
        var callbacks = 0

        loop.schedule(after: 100, owner: owner) { callbacks += 1 }
        loop.post(owner: owner) { callbacks += 1 }
        #expect(loop.pendingCount == 2)

        loop.pause(owner)
        #expect(loop.pendingCount == 0)
        #expect(!loop.hasPendingWork)

        loop.cancel(owner)
        loop.resume(owner)
        loop.schedule(after: 0, owner: owner) { callbacks += 1 }
        loop.advance(by: 1_000)

        #expect(callbacks == 0)
        #expect(loop.pendingCount == 0)
        #expect(!loop.hasPendingWork)
    }
}
