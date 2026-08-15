// Standard-library `_Concurrency` only — no platform / Foundation import
// (NFR-1), so the concurrency contract is identical across platforms (R16.5).

/// Runs an `async` process body as a Swift-concurrency task *bound to the
/// loop-bound `SwiftixExecutor`* (task 13), so every suspension/resumption of
/// the body is drained as a job on the logical-time `EventLoop` rather than a
/// wall-clock thread (R16.4). This is what lets `Kernel.spawn(_:parent:_ body:
/// (ProcessContext) async -> Void)` drive an async body deterministically via
/// `advance(by:)` / `runUntilIdle()`.
///
/// It is an `actor` whose isolation *is* the serial executor (see
/// `unownedExecutor`), mirroring the `LoopBoundWorker` pattern the executor
/// tests use: because the body is awaited from inside this actor's isolation,
/// the task adopts the loop-bound executor for its resumptions.
actor AsyncProcessHost {

    /// Carries the (non-`Sendable`) process body and its `ProcessContext` across
    /// the hop onto the loop-bound executor. Safe under the single-executor
    /// contract (R16.1): both are only ever created and used on the one logical
    /// loop thread, never concurrently — the same rationale that makes
    /// `SwiftixExecutor` `@unchecked Sendable`.
    ///
    /// The body is deliberately **not** `@Sendable`: a non-`Sendable` async
    /// closure called from inside this actor inherits the actor's isolation, so
    /// it (and every continuation of the async syscalls it awaits) runs as jobs
    /// on the loop-bound executor rather than the global concurrent executor.
    /// That is what keeps async process bodies on the single logical loop thread
    /// (deterministic, no wall-clock) instead of racing on background threads.
    struct Payload: @unchecked Sendable {
        let body: (ProcessContext) async -> Void
        let context: ProcessContext
        /// Strong references held for the lifetime of the async body so the
        /// kernel and the process cannot be deallocated out from under a task
        /// that is still running or suspended (`ProcessContext` references both
        /// `unowned`). Released when the task completes.
        let kernel: Kernel
        let process: Process
    }

    private let boundExecutor: UnownedSerialExecutor

    /// Bind this actor's isolation to the loop's serial executor, so awaiting the
    /// body here runs it (and its continuations) as jobs on the `EventLoop`.
    nonisolated var unownedExecutor: UnownedSerialExecutor { boundExecutor }

    init(executor: SwiftixExecutor) {
        self.boundExecutor = executor.asUnownedSerialExecutor()
    }

    /// Run the body with its `ProcessContext`, isolated to the loop-bound
    /// executor, then finalize the process (see `Kernel.finishAsyncBody`).
    func run(_ payload: Payload) async {
        guard await payload.kernel.awaitAsyncExecution(payload.process) else { return }
        await payload.body(payload.context)
        payload.kernel.finishAsyncBody(payload.process)
    }
}
