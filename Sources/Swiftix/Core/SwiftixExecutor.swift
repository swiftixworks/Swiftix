// Standard-library concurrency only — no platform / Foundation import (NFR-1),
// so the concurrency contract is identical on Linux, macOS, and iOS (R16.5).

/// A `SerialExecutor` bound to and owned by a single `EventLoop`.
///
/// Swift-concurrency jobs (an `async` process body, or a continuation resumed by
/// an async syscall) are posted onto the loop's executor-job queue rather than a
/// real thread. Draining the loop via `advance(by:)` / `runUntilIdle()` then runs
/// those jobs fairly alongside timer events on the single logical loop thread —
/// deterministic, with no wall-clock and no internal locking (R16.4).
///
/// The core is a graph of reference types mutated without locks, so the safe
/// model is "one executor, one logical thread": construct and drive a
/// `Kernel`/`EventLoop` from this executor and perform all public-API interaction
/// there (R16.1).
/// `@unchecked Sendable`: `SerialExecutor` refines `Sendable`, but the executor
/// deliberately holds the non-Sendable `EventLoop` (R16.3). Safety rests on the
/// single-executor contract — the loop and everything it drives are only ever
/// touched from this one executor — not on internal locking (R16.4).
final class SwiftixExecutor: SerialExecutor, @unchecked Sendable {

    /// The loop this executor drives. The loop owns this executor, so this
    /// back-reference is unowned and cannot form a retain cycle.
    unowned let loop: EventLoop

    init(loop: EventLoop) {
        self.loop = loop
    }

    /// Post a Swift-concurrency job onto the loop instead of a dispatch queue or
    /// thread. Bridges the owned `ExecutorJob` to the `UnownedJob` the loop
    /// stores until it is drained.
    func enqueue(_ job: consuming ExecutorJob) {
        loop.enqueueJob(UnownedJob(job))
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

// Also act as a `TaskExecutor` (SE-0417) so an `async` process body launched by
// `Kernel.spawn(_:parent:_ body: (ProcessContext) async -> Void)` can set this as
// its *task executor preference*. That pins the body's nonisolated `async` code
// — and the continuations of the async syscalls it awaits — onto the loop, so it
// all runs as `EventLoop` jobs on the single logical loop thread rather than the
// global concurrent executor (deterministic, no wall-clock, no background-thread
// races). `enqueue(_:)` is shared with the `SerialExecutor` conformance: both
// post the job onto the loop's job queue.
//
// Availability-gated because task-executor preference requires these runtime
// floors on Apple platforms; on Linux there is no gating, so the contract stays
// identical across platforms (R16.5). The library's own platform floors are a
// major version below these, so the gate is applied at the use site.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
extension SwiftixExecutor: TaskExecutor {
    func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}
