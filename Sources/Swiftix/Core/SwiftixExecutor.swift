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

/// The loop's `TaskExecutor` (SE-0417). An `async` process body launched by
/// `Kernel.spawn(_:parent:_ body: (ProcessContext) async -> Void)` sets this as
/// its *task executor preference*. That pins the body's nonisolated `async` code
/// — and the continuations of the async syscalls it awaits — onto the loop, so it
/// all runs as `EventLoop` jobs on the single logical loop thread rather than the
/// global concurrent executor (deterministic, no wall-clock, no background-thread
/// races).
///
/// It is a separate object from `SwiftixExecutor` so the loop can tell which
/// kind of job it holds. A job posted here belongs to a task that is not
/// isolated to any serial executor, and must be run as such
/// (`runSynchronously(on: UnownedTaskExecutor)`). Run as a job of the serial
/// executor instead, the task finds itself on the wrong executor at every
/// `async` call and return and re-posts itself each time: one or two loop
/// steps per call, with no suspension in the source.
///
/// Availability-gated because task-executor preference requires these runtime
/// floors on Apple platforms; on Linux there is no gating, so the contract stays
/// identical across platforms (R16.5). The library's own platform floors are a
/// major version below these, so the gate is applied at the use site.
///
/// `@unchecked Sendable` for the same reason as `SwiftixExecutor`: the protocol
/// refines `Sendable`, and safety rests on the single-executor contract.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
final class SwiftixTaskExecutor: TaskExecutor, @unchecked Sendable {

    /// The loop this executor posts to. The loop owns this executor, so the
    /// back-reference is unowned and cannot form a retain cycle.
    unowned let loop: EventLoop

    init(loop: EventLoop) {
        self.loop = loop
    }

    /// Post a job of a task that prefers this executor onto the loop.
    func enqueue(_ job: consuming ExecutorJob) {
        loop.enqueueJob(UnownedJob(job), onTaskExecutor: true)
    }

    func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}
