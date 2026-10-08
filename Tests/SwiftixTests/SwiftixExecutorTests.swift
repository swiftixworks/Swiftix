import Testing
@testable import Swiftix

/// Loop-owned serial executor, executor-job queue, and scheduler fairness tests.
@Suite("Loop-bound serial executor")
struct SwiftixExecutorTests {

    /// Observable, single-threaded progress record. Written only by worker code
    /// while it runs on the loop and read by the driver between drains.
    final class Progress: @unchecked Sendable {
        private(set) var steps = 0
        private(set) var done = false
        private(set) var notifications = 0
        private(set) var timerStep: Int?
        private(set) var events: [String] = []

        func tick() { steps += 1 }
        func finish() { done = true }
        func notify() { notifications += 1 }
        func markTimer() { timerStep = steps }
        func record(_ event: String) { events.append(event) }
        func hasEvent(_ event: String) -> Bool { events.contains(event) }
    }

    /// An actor whose isolation is the loop-owned serial executor, so every
    /// resumption of its `async` body is posted as an `EventLoop` job.
    actor LoopBoundWorker {
        private let progress: Progress
        private let boundExecutor: UnownedSerialExecutor

        nonisolated var unownedExecutor: UnownedSerialExecutor { boundExecutor }

        init(executor: SwiftixExecutor, progress: Progress) {
            self.progress = progress
            self.boundExecutor = executor.asUnownedSerialExecutor()
        }

        func run(steps: Int) async {
            for _ in 0..<steps {
                progress.tick()
                await Task.yield()
            }
            progress.finish()
        }
    }

    /// A task bound to the executor advances only when the loop is drained and,
    /// once complete, leaves zero pending jobs.
    @Test func executorBoundTaskProgressesPurelyViaLoopDraining() async {
        let loop = EventLoop()
        let progress = Progress()
        let worker = LoopBoundWorker(executor: loop.executor, progress: progress)

        Task { await worker.run(steps: 3) }

        var pumps = 0
        while !progress.done && pumps < 1_000 {
            loop.runUntilIdle()
            await Task.yield()
            pumps += 1
        }

        #expect(progress.done)
        #expect(progress.steps == 3)
        #expect(loop.pendingJobCount == 0)
        #expect(loop.pendingCount == 0)
        #expect(loop.pendingWorkCount == 0)
    }

    /// Enqueued jobs run at the current logical time inside `advance(by:)` too.
    @Test func executorBoundTaskProgressesViaAdvance() async {
        let loop = EventLoop()
        let progress = Progress()
        let worker = LoopBoundWorker(executor: loop.executor, progress: progress)

        Task { await worker.run(steps: 2) }

        var pumps = 0
        while !progress.done && pumps < 1_000 {
            loop.advance(by: 0)
            await Task.yield()
            pumps += 1
        }

        #expect(progress.done)
        #expect(progress.steps == 2)
        #expect(loop.pendingJobCount == 0)
        #expect(loop.now == 0)
    }

    @Test func twoKernelsOnOneLoopShareExecutorAndAsyncBodiesInterleave() async throws {
        let loop = EventLoop()
        let kernelA = Kernel(loop: loop)
        let kernelB = Kernel(loop: loop)
        let sharedExecutor = loop.executor
        let progress = Progress()

        #expect(kernelA.asyncExecutor === sharedExecutor)
        #expect(kernelB.asyncExecutor === sharedExecutor)

        kernelA.spawn("async-a") { _ in
            progress.record("a-start")
            while !progress.hasEvent("b-start") {
                await Task.yield()
            }
            progress.record("a-end")
        }
        kernelB.spawn("async-b") { _ in
            progress.record("b-start")
            while !progress.hasEvent("a-start") {
                await Task.yield()
            }
            progress.record("b-end")
        }

        var pumps = 0
        while (kernelA.processCount > 0 || kernelB.processCount > 0) && pumps < 1_000 {
            loop.runUntilIdle(stepBudget: 256)
            await Task.yield()
            pumps += 1
        }

        let events = progress.events
        let aStart = try #require(events.firstIndex(of: "a-start"))
        let aEnd = try #require(events.firstIndex(of: "a-end"))
        let bStart = try #require(events.firstIndex(of: "b-start"))
        let bEnd = try #require(events.firstIndex(of: "b-end"))
        #expect(aStart < aEnd)
        #expect(bStart < bEnd)
        #expect(aStart < bEnd && bStart < aEnd)
        #expect(kernelA.processCount == 0)
        #expect(kernelB.processCount == 0)
    }

    @Test func workAvailableCallbackOnlyFiresForAggregateIdleTransitions() async {
        let loop = EventLoop()
        let progress = Progress()
        loop.onWorkAvailable = { progress.notify() }

        loop.schedule(after: 1) {}
        loop.schedule(after: 2) {}

        #expect(progress.notifications == 1)
        #expect(loop.hasPendingWork)
        #expect(loop.pendingWorkCount == 2)
        #expect(loop.nextDeadline == 1)

        loop.advance(by: 2)
        #expect(!loop.hasPendingWork)

        let worker = LoopBoundWorker(executor: loop.executor, progress: progress)
        Task { await worker.run(steps: 0) }
        var yields = 0
        while loop.pendingJobCount == 0 && yields < 1_000 {
            await Task.yield()
            yields += 1
        }

        #expect(loop.pendingJobCount == 1)
        #expect(progress.notifications == 2)
        #expect(loop.pendingWorkCount == 1)
        #expect(loop.nextDeadline == loop.now)

        // A timer added while the job already makes the loop non-idle must not
        // generate another wakeup.
        loop.post {}
        #expect(progress.notifications == 2)
        #expect(loop.pendingWorkCount == 2)

        loop.runUntilIdle()
        #expect(progress.done)
        #expect(!loop.hasPendingWork)
        #expect(loop.nextDeadline == nil)
    }

    @Test func dueTimerRunsDuringExecutorJobFlood() async {
        let loop = EventLoop()
        let progress = Progress()
        let worker = LoopBoundWorker(executor: loop.executor, progress: progress)
        Task { await worker.run(steps: 50) }

        var yields = 0
        while loop.pendingJobCount == 0 && yields < 1_000 {
            await Task.yield()
            yields += 1
        }
        #expect(loop.pendingJobCount == 1)

        loop.schedule(after: 0) { progress.markTimer() }
        let result = loop.runUntilIdle(stepBudget: 20)

        #expect(result == .completed || result == .budgetExceeded)
        #expect(progress.timerStep != nil)
        #expect((progress.timerStep ?? .max) <= 8)
        if result == .budgetExceeded {
            #expect(loop.hasPendingWork)
        }

        var pumps = 0
        while !progress.done && pumps < 1_000 {
            loop.runUntilIdle()
            await Task.yield()
            pumps += 1
        }
        #expect(progress.done)
    }

    // MARK: - Async process bodies

    final class Recursion {
        func depth(_ remaining: Int) async -> Int {
            remaining == 0 ? 0 : 1 + (await depth(remaining - 1))
        }
    }

    /// Loop steps an async process body takes from spawn to exit.
    static func steps(_ body: @escaping (ProcessContext) async -> Void) -> Int {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("body", body)
        var steps = 0
        while steps < 100_000, loop.runNext() { steps += 1 }
        #expect(kernel.snapshotProcesses().isEmpty)
        return steps
    }

    /// An `async` call that never suspends is not a trip through the loop. A
    /// body run as a job of the wrong executor re-posted itself at every call
    /// and return, so its step count grew with the calls it made.
    @Test func asyncCallsThatDoNotSuspendCostNoLoopSteps() {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        let empty = Self.steps { _ in }
        let calls = Self.steps { ctx in
            let recursion = Recursion()
            for _ in 0..<200 { _ = await recursion.depth(20) }
            _ = await ctx.kernel.awaitAsyncExecution(ctx.process)
        }
        #expect(calls == empty)
    }

    /// Each real suspension is a fixed, small number of steps.
    @Test func eachSuspensionCostsAFixedNumberOfLoopSteps() {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        func yields(_ count: Int) -> Int {
            Self.steps { ctx in
                for _ in 0..<count { try? await ctx.yield() }
            }
        }
        func sleeps(_ count: Int) -> Int {
            Self.steps { ctx in
                for _ in 0..<count { try? await ctx.sleep(0) }
            }
        }
        let base = yields(0)
        // The queued step, then the job that resumes the body.
        #expect(yields(10) - base == 20)
        #expect(yields(50) - base == 100)
        // The timer, the step it queues, then the job.
        #expect(sleeps(10) - base == 30)
    }
}
