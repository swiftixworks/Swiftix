/// The simulation clock + ready/timer queue that drives the entire data plane.
///
/// Time is *logical*: `now` only advances when a driver tells it to. This keeps
/// the data plane independent of how time is sourced:
///
///   * Real-time emulation: a wall-clock driver in the app layer (for example, a
///     `DispatchSourceTimer` or `CADisplayLink`) repeatedly calls `advance(by:)`
///     with the elapsed wall-clock interval.
///   * Virtual-time / discrete-event driving: call `runNext()` in a loop with an
///     application-specific stopping condition to jump to successive deadlines.
///
/// Ready work comes in three kinds. Timer callbacks run in deadline order and
/// executor jobs in FIFO order; both hold the clock at their instant until
/// they have run. A *yield* is the continuation of a CPU-bound task that gave
/// up the processor (see `CancellationScope.yield`): it runs in the same order
/// as a zero-delay timer, but a task that never stops yielding must not stop
/// time, so `advance(by:)` lets later timers and the clock pass it. An `async`
/// task that yields resumes as executor jobs; those jobs are marked as yields
/// too (see `resumingYieldedTask`).
///
/// Not thread-safe by design: a topology runs on a single executor and hundreds
/// of nodes share one loop, rather than one-thread-per-node.
public final class EventLoop {

    /// The outcome of a bounded drain operation.
    public enum RunResult: Sendable, Equatable {
        /// All work eligible for this operation was processed.
        case completed
        /// Eligible work remains because the outermost operation spent its step
        /// budget. The pending work stays queued for a later drain.
        case budgetExceeded
    }

    /// The default number of timer callbacks and executor jobs one outermost
    /// `advance` or `runUntilIdle` call may execute.
    public static let defaultStepBudget = 100_000

    public init() {}

    /// Seconds since the loop started. Monotonic; only moved by a driver.
    public private(set) var now: Double = 0

    /// The one serial executor owned by this loop. It is lazy so it can safely
    /// receive `self`; every Kernel sharing the loop reads this same instance.
    internal private(set) lazy var executor = SwiftixExecutor(loop: self)

    /// A cancellation and suspension scope for timer callbacks owned by one
    /// kernel. The owner is deliberately internal and non-Sendable: it is created,
    /// paused, resumed, and cancelled on the same executor as its loop.
    final class WorkOwner {
        fileprivate enum State {
            case active
            case paused
            case cancelled
        }

        fileprivate struct PausedWork {
            let remainingDelay: Double
            let sequence: UInt64
            let token: EventToken?
            var isYield = false
            let work: () -> Void
        }

        fileprivate unowned let loop: EventLoop
        fileprivate var state: State = .active
        fileprivate var pausedWork: [PausedWork] = []

        fileprivate init(loop: EventLoop) {
            self.loop = loop
        }
    }

    /// A one-shot cancellation scope for consumer-owned timer callbacks.
    ///
    /// Topology objects use one scope per live resource generation. Calling
    /// ``cancel()`` physically removes every callback scheduled through the
    /// scope, so pending-work metrics and real-time drivers immediately become
    /// idle when that resource is torn down. A cancelled scope rejects future
    /// scheduling; create a new scope for a replacement generation.
    ///
    /// Like the loop itself, this reference type is deliberately non-Sendable
    /// and must only be created, scheduled, and cancelled on the loop's executor.
    public final class CancellationScope {
        private let loop: EventLoop
        fileprivate let owner: WorkOwner

        fileprivate init(loop: EventLoop) {
            self.loop = loop
            self.owner = WorkOwner(loop: loop)
        }

        /// Schedule a callback owned by this scope.
        public func schedule(after delay: Double, _ work: @escaping () -> Void) {
            loop.schedule(after: delay, owner: owner, work)
        }

        /// Schedule the continuation of CPU-bound work that is giving up the
        /// processor. It runs where a zero-delay callback would, but does not
        /// hold back logical time: see ``EventLoop/advance(by:stepBudget:)``.
        func yield(_ work: @escaping () -> Void) {
            loop.schedule(after: 0, owner: owner, token: nil, isYield: true, work)
        }

        /// Permanently cancel and physically remove all callbacks in this scope.
        public func cancel() {
            loop.cancel(owner)
        }

        /// Freeze/resume protocol-owned scopes with their owning network stack.
        /// Internal because consumer scopes intentionally expose one-shot
        /// scheduling + cancellation only.
        func pause() {
            loop.pause(owner)
        }

        func resume() {
            loop.resume(owner)
        }
    }

    /// A handle for one scheduled callback. Cancelling it physically removes the
    /// callback from the active heap or its owner's paused queue.
    ///
    /// This stays internal until a stable public consumer needs per-event
    /// cancellation; TCP uses it to prevent superseded RTO epochs accumulating.
    final class EventToken {
        fileprivate weak var loop: EventLoop?
        fileprivate weak var owner: WorkOwner?
        fileprivate var isPending = true

        fileprivate init(loop: EventLoop, owner: WorkOwner?) {
            self.loop = loop
            self.owner = owner
        }

        func cancel() {
            loop?.cancel(self)
        }
    }

    private struct Scheduled {
        let deadline: Double
        let seq: UInt64           // tie-breaker => stable FIFO order at equal deadlines
        let owner: WorkOwner?
        let token: EventToken?
        var isYield = false
        let work: () -> Void
    }

    /// An executor job, and whether it continues a task that yielded.
    private struct QueuedJob {
        let job: UnownedJob
        let isYield: Bool
    }

    private final class StepBudget {
        var remaining: Int
        var wasExceeded = false

        init(limit: Int) {
            remaining = max(0, limit)
        }

        func consume() -> Bool {
            guard remaining > 0 else {
                wasExceeded = true
                return false
            }
            remaining -= 1
            return true
        }
    }

    private enum StepOutcome {
        case ran
        case noWork
        case budgetExceeded
    }

    private static let maximumJobBurst = 8

    /// How many yields may run in a row inside an `advance` window before a
    /// timer that is due later in the window gets the next step.
    private static let maximumYieldBurst = 8

    private var queue: [Scheduled] = []
    private var seqCounter: UInt64 = 0

    /// Continuations of CPU-bound work, FIFO. Each carries the deadline (the
    /// instant it yielded) and sequence a zero-delay timer would have, so its
    /// place among ready timers is unchanged; keeping yields out of the heap
    /// leaves the earliest real timer at the heap root.
    private var yieldQueue = FIFOQueue<Scheduled>()

    /// FIFO queue of Swift-concurrency jobs posted by the loop-owned
    /// `SerialExecutor` (see `SwiftixExecutor`). Drained at the current logical
    /// time by `advance(by:)` / `runUntilIdle()` alongside timer events, so
    /// `await` suspension/resumption interleaves with timers on the single loop
    /// thread — no second thread, no locking (R16.4).
    private var jobQueue = FIFOQueue<QueuedJob>()

    /// How many queued jobs continue a task that yielded. The rest are
    /// ordinary jobs, which hold the clock.
    private var yieldJobCount = 0

    /// Whether a job posted right now continues a task that yielded: set
    /// while such a task is resumed and while a yield or one of its jobs
    /// runs. See `resumingYieldedTask`.
    private var isResumingYieldedTask = false

    /// Whether the step now running is yielded CPU-bound work: a yield, or a
    /// job that continues a yielded task. What such work makes ready at this
    /// instant is part of the same burst, so the kernel queues the process
    /// steps it causes as yields too (see `Kernel.runStep`).
    var isRunningYieldedWork: Bool { isResumingYieldedTask }

    /// The budget shared by reentrant `advance`, `runUntilIdle`, and `runNext`
    /// calls. Only the outermost bounded operation creates a budget.
    private var activeStepBudget: StepBudget?

    /// Scheduler fairness state. Once a small burst of jobs has run, an eligible
    /// timer gets the next step even if jobs keep reposting themselves.
    private var consecutiveJobSteps = 0

    /// Yields run since a timer last ran; see `maximumYieldBurst`.
    private var consecutiveYieldSteps = 0

    /// Called synchronously when pending work changes from empty to non-empty.
    /// There is one callback slot so a loop has a single wakeup consumer.
    public var onWorkAvailable: (() -> Void)?

    /// Whether either an active timer callback or executor job is queued. Work
    /// frozen in a paused owner is intentionally excluded: it cannot run until
    /// that owner resumes and must not keep a real-time driver awake.
    public var hasPendingWork: Bool { !queue.isEmpty || !jobQueue.isEmpty || !yieldQueue.isEmpty }

    /// Total active timer callbacks and executor jobs. Paused-owner work is not
    /// runnable and is therefore excluded from this count.
    public var pendingWorkCount: Int { queue.count + jobQueue.count + yieldQueue.count }

    /// The earliest queued logical deadline. Executor jobs and yielded
    /// CPU-bound work are ready at `now`.
    public var nextDeadline: Double? {
        let timerDeadline = queue.first?.deadline
        guard !jobQueue.isEmpty || !yieldQueue.isEmpty else { return timerDeadline }
        guard let timerDeadline else { return now }
        return min(timerDeadline, now)
    }

    /// Enqueue a Swift-concurrency `job` to run at the current logical time.
    /// Called by the loop-owned `SwiftixExecutor`. The job is drained by the next
    /// `advance(by:)` / `runUntilIdle()`.
    func enqueueJob(_ job: UnownedJob) {
        let wasIdle = !hasPendingWork
        jobQueue.append(QueuedJob(job: job, isYield: isResumingYieldedTask))
        if isResumingYieldedTask { yieldJobCount += 1 }
        if wasIdle { onWorkAvailable?() }
    }

    /// Resume an `async` task that gave up the processor. `resume` must resume
    /// that task's continuation from a yield callback (`CancellationScope.yield`).
    ///
    /// Resuming a continuation posts an executor job, and an executor job
    /// normally holds the clock. The job posted while `resume` runs is instead
    /// recorded as a yield: it keeps its FIFO place among jobs, and
    /// `advance(by:stepBudget:)` treats it as it treats a queued yield.
    ///
    /// A running task does not stay in one job. The Swift runtime posts a new
    /// job each time the task switches executor context, several times
    /// between two suspensions, so a job posted while a yield job runs is a
    /// yield job as well. The chain ends when the task waits for something:
    /// its last job posts nothing, and whatever wakes it later is ordinary
    /// work again. Timers scheduled along the way are ordinary timers. A job
    /// posted while a yield itself runs is a yield job for the same reason.
    func resumingYieldedTask(_ resume: () -> Void) {
        withJobsRecorded(asYield: true, resume)
    }

    private func withJobsRecorded(asYield: Bool, _ work: () -> Void) {
        let wasResuming = isResumingYieldedTask
        isResumingYieldedTask = asYield
        defer { isResumingYieldedTask = wasResuming }
        work()
    }

    /// Number of executor jobs still pending. Kept for compatibility; use
    /// `pendingWorkCount` when both jobs and timers matter.
    public var pendingJobCount: Int { jobQueue.count }

    /// Make a timer/post owner tied to this loop. Kernels use one owner for every
    /// process and protocol callback they schedule.
    func makeWorkOwner() -> WorkOwner {
        WorkOwner(loop: self)
    }

    /// Make a one-shot scope for consumer-owned cancellable callbacks.
    public func makeCancellationScope() -> CancellationScope {
        CancellationScope(loop: self)
    }

    /// Freeze an owner's active callbacks without leaving tombstones in the heap.
    /// Each callback retains only its remaining delay, so logical time may advance
    /// for other kernels while this owner is suspended.
    func pause(_ owner: WorkOwner) {
        guard owner.loop === self, owner.state == .active else { return }
        let removed = removeScheduled(ownedBy: owner).sorted { isEarlier($0, than: $1) }
        owner.pausedWork.append(contentsOf: removed.map {
            WorkOwner.PausedWork(
                remainingDelay: max(0, $0.deadline - now),
                sequence: $0.seq,
                token: $0.token,
                isYield: $0.isYield,
                work: $0.work)
        })
        owner.state = .paused
    }

    /// Resume a paused owner, shifting every deadline by the duration for which
    /// the owner was frozen. Relative order at equal deadlines stays FIFO.
    func resume(_ owner: WorkOwner) {
        guard owner.loop === self, owner.state == .paused else { return }
        let wasIdle = !hasPendingWork
        let paused = owner.pausedWork.sorted {
            $0.remainingDelay < $1.remainingDelay
                || ($0.remainingDelay == $1.remainingDelay && $0.sequence < $1.sequence)
        }
        owner.pausedWork.removeAll(keepingCapacity: false)
        owner.state = .active
        for item in paused {
            guard item.token?.isPending != false else { continue }
            let deadline = now + item.remainingDelay
            guard deadline.isFinite else { continue }
            enqueue(Scheduled(
                deadline: deadline,
                seq: seqCounter,
                owner: owner,
                token: item.token,
                isYield: item.isYield,
                work: item.work))
            seqCounter &+= 1
        }
        if wasIdle, hasPendingWork { onWorkAvailable?() }
    }

    /// Permanently cancel every active or paused callback for an owner. Entries
    /// are physically removed, so pending-work metrics immediately reflect the
    /// shutdown and a cancelled owner can never enqueue new work.
    func cancel(_ owner: WorkOwner) {
        guard owner.loop === self, owner.state != .cancelled else { return }
        owner.state = .cancelled
        for item in owner.pausedWork { item.token?.isPending = false }
        owner.pausedWork.removeAll(keepingCapacity: false)
        for item in removeScheduled(ownedBy: owner) { item.token?.isPending = false }
    }

    /// Schedule unowned consumer work `delay` seconds from `now`.
    public func schedule(after delay: Double, _ work: @escaping () -> Void) {
        schedule(after: delay, owner: nil, token: nil, work)
    }

    /// Schedule kernel-owned work. Paused owners hold the callback outside the
    /// runnable heap; cancelled owners reject it.
    func schedule(after delay: Double, owner: WorkOwner, _ work: @escaping () -> Void) {
        guard owner.loop === self else { return }
        schedule(after: delay, owner: Optional(owner), token: nil, work)
    }

    /// Schedule one physically cancellable unowned callback.
    func scheduleCancellable(after delay: Double, _ work: @escaping () -> Void) -> EventToken {
        let token = EventToken(loop: self, owner: nil)
        schedule(after: delay, owner: nil, token: token, work)
        return token
    }

    /// Schedule one physically cancellable callback in a kernel work owner.
    func scheduleCancellable(
        after delay: Double,
        owner: WorkOwner,
        _ work: @escaping () -> Void
    ) -> EventToken {
        let token = EventToken(loop: self, owner: owner)
        guard owner.loop === self else {
            token.isPending = false
            return token
        }
        schedule(after: delay, owner: owner, token: token, work)
        return token
    }

    private func schedule(
        after delay: Double,
        owner: WorkOwner?,
        token: EventToken?,
        isYield: Bool = false,
        _ work: @escaping () -> Void
    ) {
        guard delay.isFinite else {
            token?.isPending = false
            return
        }
        let normalizedDelay = max(0, delay)
        let deadline = now + normalizedDelay
        guard deadline.isFinite else {
            token?.isPending = false
            return
        }

        if let owner {
            switch owner.state {
            case .cancelled:
                token?.isPending = false
                return
            case .paused:
                owner.pausedWork.append(WorkOwner.PausedWork(
                    remainingDelay: normalizedDelay,
                    sequence: seqCounter,
                    token: token,
                    isYield: isYield,
                    work: work))
                seqCounter &+= 1
                return
            case .active:
                break
            }
        }

        let wasIdle = !hasPendingWork
        enqueue(Scheduled(
            deadline: deadline,
            seq: seqCounter,
            owner: owner,
            token: token,
            isYield: isYield,
            work: work))
        seqCounter &+= 1
        if wasIdle { onWorkAvailable?() }
    }

    private func enqueue(_ scheduled: Scheduled) {
        if scheduled.isYield {
            yieldQueue.append(scheduled)
        } else {
            insertScheduled(scheduled)
        }
    }

    /// Enqueue unowned consumer work as soon as possible (deadline == now).
    public func post(_ work: @escaping () -> Void) {
        schedule(after: 0, work)
    }

    /// Enqueue kernel-owned work as soon as possible.
    func post(owner: WorkOwner, _ work: @escaping () -> Void) {
        schedule(after: 0, owner: owner, work)
    }

    /// Remove every queued callback belonging to `owner`, rebuilding the small
    /// binary heap from retained entries. This avoids cancelled tombstones in
    /// pending counts and at the heap root.
    private func removeScheduled(ownedBy owner: WorkOwner) -> [Scheduled] {
        var removed = removeYields(ownedBy: owner)
        let yieldCount = removed.count
        var retained: [Scheduled] = []
        retained.reserveCapacity(queue.count)
        for item in queue {
            if item.owner === owner {
                removed.append(item)
            } else {
                retained.append(item)
            }
        }
        guard removed.count > yieldCount else { return removed }
        queue.removeAll(keepingCapacity: true)
        for item in retained { insertScheduled(item) }
        return removed
    }

    private func removeYields(ownedBy owner: WorkOwner) -> [Scheduled] {
        guard !yieldQueue.isEmpty else { return [] }
        var removed: [Scheduled] = []
        var retained = FIFOQueue<Scheduled>()
        while let item = yieldQueue.popFirst() {
            if item.owner === owner {
                removed.append(item)
            } else {
                retained.append(item)
            }
        }
        yieldQueue = retained
        return removed
    }

    /// Cancel one event by identity and rebuild the heap only when it is still
    /// pending. The same token also follows work into a paused owner queue.
    private func cancel(_ token: EventToken) {
        guard token.loop === self, token.isPending else { return }
        token.isPending = false
        if let owner = token.owner, owner.state == .paused {
            owner.pausedWork.removeAll { $0.token === token }
            return
        }
        var retained = queue.filter { $0.token !== token }
        guard retained.count != queue.count else { return }
        queue.removeAll(keepingCapacity: true)
        for item in retained { insertScheduled(item) }
        retained.removeAll(keepingCapacity: false)
    }

    /// Advance logical time by `interval`, running events whose deadlines fall
    /// within the window. Each timer callback or executor job spends one step.
    /// Reentrant drains share the outermost budget, so zero-delay reposting cannot
    /// keep a single call from returning.
    ///
    /// If the budget is exceeded, `now` remains at the last processed event and
    /// is not advanced to `target` past queued, unprocessed work. Invalid intervals
    /// return `.completed` without changing any state.
    ///
    /// Yielded CPU-bound work is the exception, because a task that yields
    /// forever would otherwise freeze the clock:
    ///
    /// - After a short burst of yields, a timer due later in the window runs
    ///   at its own deadline, so timers are not starved.
    /// - When the budget runs out and yields (queued, or resuming an `async`
    ///   task) are the only work left inside the
    ///   window, `now` still reaches `target`. The call reports
    ///   `.budgetExceeded` (ready work remains), and the interval has elapsed.
    ///
    /// The step budget is therefore the amount of CPU-bound work one interval
    /// can hold. How far such a task gets per interval depends on the budget;
    /// the order and logical times of everything else do not.
    @discardableResult
    public func advance(
        by interval: Double,
        stepBudget: Int = EventLoop.defaultStepBudget
    ) -> RunResult {
        // A driver can derive this value from wall-clock deltas, so reject bad
        // input without letting one clock glitch violate the loop's monotonic-time
        // contract or poison every future deadline with NaN/infinity.
        guard interval.isFinite, interval >= 0 else { return .completed }
        let target = now + interval
        guard target.isFinite else { return .completed }

        return withStepBudget(stepBudget) { budget in
            while true {
                switch performNextStep(dueBy: target, budget: budget, timersPreemptYields: true) {
                case .ran:
                    // A callback may have entered another drain and exhausted the
                    // shared budget. Do not advance the outer operation's clock.
                    if budget.wasExceeded { return exhausted(target) }
                case .noWork:
                    if budget.wasExceeded { return exhausted(target) }
                    // A nested run may already have advanced farther than this
                    // operation's target; logical time must never move backward.
                    now = max(now, target)
                    return .completed
                case .budgetExceeded:
                    return exhausted(target)
                }
            }
        }
    }

    /// Finish an `advance` whose budget ran out. Ordinary jobs and timers due
    /// by `target` keep the clock where it is; yielded CPU-bound work, queued
    /// or resuming as a job, does not.
    private func exhausted(_ target: Double) -> RunResult {
        let timerIsDue = queue.first.map { $0.deadline <= target } ?? false
        let hasOrdinaryJob = jobQueue.count > yieldJobCount
        let hasYield = !yieldQueue.isEmpty || yieldJobCount > 0
        if !hasOrdinaryJob, !timerIsDue, hasYield {
            now = max(now, target)
        }
        return .budgetExceeded
    }

    /// Drain executor jobs and timer callbacks whose deadline is already ≤ `now`.
    /// This method does not itself jump to a future timer deadline. Work scheduled
    /// by callbacks is eligible in the same drain, subject to the shared step
    /// budget, so callers can inspect `.budgetExceeded` instead of hanging on an
    /// unbounded cascade.
    @discardableResult
    public func runUntilIdle(
        stepBudget: Int = EventLoop.defaultStepBudget
    ) -> RunResult {
        withStepBudget(stepBudget) { budget in
            while true {
                switch performNextStep(dueBy: now, budget: budget) {
                case .ran:
                    if budget.wasExceeded { return .budgetExceeded }
                case .noWork:
                    return budget.wasExceeded ? .budgetExceeded : .completed
                case .budgetExceeded:
                    return .budgetExceeded
                }
            }
        }
    }

    /// Run exactly one ready executor job or the earliest logical timer. This is
    /// the park/wake bridge used by embedded language runtimes: they can advance
    /// the shared node loop only until one blocked task becomes runnable instead
    /// of draining unrelated future work past that wakeup.
    ///
    /// The existing `Bool` API is retained. When called from inside a bounded
    /// drain, it consumes that operation's shared budget and returns `false` if no
    /// budget remains.
    @discardableResult
    public func runNext() -> Bool {
        if let activeStepBudget {
            return performNextStep(dueBy: .infinity, budget: activeStepBudget) == .ran
        }

        // A top-level runNext is itself an outermost one-step operation, so work
        // cannot recursively bypass its "exactly one" contract.
        let budget = StepBudget(limit: 1)
        activeStepBudget = budget
        defer { activeStepBudget = nil }
        return performNextStep(dueBy: .infinity, budget: budget) == .ran
    }

    /// Number of timer callbacks still pending. Kept for compatibility; use
    /// `pendingWorkCount` when both timers and executor jobs matter.
    public var pendingCount: Int { queue.count + yieldQueue.count }

    private func withStepBudget(
        _ requestedLimit: Int,
        operation: (StepBudget) -> RunResult
    ) -> RunResult {
        if let activeStepBudget {
            let result = operation(activeStepBudget)
            return activeStepBudget.wasExceeded ? .budgetExceeded : result
        }

        let budget = StepBudget(limit: requestedLimit)
        activeStepBudget = budget
        defer { activeStepBudget = nil }
        let result = operation(budget)
        return budget.wasExceeded ? .budgetExceeded : result
    }

    /// Run one fairly selected job/timer/yield without removing it until
    /// budget is available. Timers are selected in heap order; jobs and yields
    /// stay FIFO.
    private func performNextStep(
        dueBy timerLimit: Double,
        budget: StepBudget,
        timersPreemptYields: Bool = false
    ) -> StepOutcome {
        let hasJob = !jobQueue.isEmpty
        let hasEligibleCallback = (queue.first.map { $0.deadline <= timerLimit } ?? false)
            || (yieldQueue.first.map { $0.deadline <= timerLimit } ?? false)
        guard hasJob || hasEligibleCallback else {
            if !hasPendingWork {
                consecutiveJobSteps = 0
                consecutiveYieldSteps = 0
            }
            return .noWork
        }

        let shouldRunCallback = hasEligibleCallback
            && (!hasJob || consecutiveJobSteps >= EventLoop.maximumJobBurst)

        guard budget.consume() else { return .budgetExceeded }

        if !shouldRunCallback, let queued = jobQueue.popFirst() {
            if queued.isYield { yieldJobCount -= 1 }
            consecutiveJobSteps = min(consecutiveJobSteps + 1, EventLoop.maximumJobBurst)
            withJobsRecorded(asYield: queued.isYield) {
                queued.job.runSynchronously(on: executor.asUnownedSerialExecutor())
            }
            return .ran
        }

        guard let next = dequeueCallback(dueBy: timerLimit,
                                         timersPreemptYields: timersPreemptYields) else {
            return .noWork
        }
        next.token?.isPending = false
        consecutiveJobSteps = 0
        now = max(now, next.deadline)
        withJobsRecorded(asYield: next.isYield, next.work)
        return .ran
    }

    /// Remove the next timer or yield due by `limit`. They share one order,
    /// (deadline, sequence), so a yield runs exactly where a zero-delay timer
    /// scheduled at the same moment would. With `timersPreemptYields`, a timer
    /// that is later in that order still runs once `maximumYieldBurst` yields
    /// have run in a row.
    private func dequeueCallback(dueBy limit: Double, timersPreemptYields: Bool) -> Scheduled? {
        let timer = queue.first.flatMap { $0.deadline <= limit ? $0 : nil }
        let yield = yieldQueue.first.flatMap { $0.deadline <= limit ? $0 : nil }
        var runsYield = yield != nil
        if let timer, let yield {
            let burstSpent = timersPreemptYields
                && consecutiveYieldSteps >= EventLoop.maximumYieldBurst
            runsYield = !isEarlier(timer, than: yield) && !burstSpent
        }
        guard runsYield else {
            consecutiveYieldSteps = 0
            return dequeueEarliest(dueBy: limit)
        }
        consecutiveYieldSteps = min(consecutiveYieldSteps + 1, EventLoop.maximumYieldBurst)
        return yieldQueue.popFirst()
    }

    /// Remove the earliest due timer from the binary min-heap.
    private func dequeueEarliest(dueBy limit: Double) -> Scheduled? {
        guard let first = queue.first, first.deadline <= limit else { return nil }
        if queue.count == 1 { return queue.removeLast() }
        let result = first
        queue[0] = queue.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1
            guard left < queue.count else { break }
            let right = left + 1
            let child = right < queue.count && isEarlier(queue[right], than: queue[left]) ? right : left
            guard isEarlier(queue[child], than: queue[index]) else { break }
            queue.swapAt(index, child)
            index = child
        }
        return result
    }

    private func insertScheduled(_ scheduled: Scheduled) {
        queue.append(scheduled)
        var index = queue.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard isEarlier(queue[index], than: queue[parent]) else { break }
            queue.swapAt(index, parent)
            index = parent
        }
    }

    private func isEarlier(_ lhs: Scheduled, than rhs: Scheduled) -> Bool {
        lhs.deadline < rhs.deadline || (lhs.deadline == rhs.deadline && lhs.seq < rhs.seq)
    }
}
