/// The timer of a `context` deadline, which cancelling the context stops.
///
/// A context made by `WithTimeout` or `WithDeadline` is cancelled by a
/// `time.AfterFunc` timer, and its cancel function stops that timer, so a
/// server that gives each request a timeout and cancels it on time leaves
/// nothing behind. The expected output is what Go 1.24.5 printed.

import Testing

@testable import SwiftixGo
@testable import SwiftixGoRuntime

@Suite("Go context deadlines")
struct GoContextDeadlineTests: GoTestHarness {

    /// More contexts with an hour-long timeout, each cancelled at once,
    /// than the VM is allowed goroutines or timers at a time: each one's
    /// timer is stopped and gone when its context is cancelled. (A deadline
    /// that waited in a goroutine of its own stopped this program at the
    /// limit.)
    @Test func cancellingATimeoutStopsItsTimer() throws {
        let output = try runGoMain(
            """
                for i := 0; i < 1000; i++ {
                    ctx, cancel := context.WithTimeout(context.Background(), time.Hour)
                    cancel()
                    if i%250 == 0 {
                        fmt.Println(i, ctx.Err(), context.Cause(ctx))
                    }
                }
                ctx, cancel := context.WithTimeoutCause(context.Background(), time.Millisecond, errors.New("slow"))
                defer cancel()
                <-ctx.Done()
                _, ok := ctx.Deadline()
                fmt.Println(ctx.Err(), context.Cause(ctx), ok)
            """,
            imports: ["context", "errors", "fmt", "time"],
            machine: GoVirtualMachine(
                maximumInstructions: 10_000_000,
                resourceLimits: GoRuntimeResourceLimits(maximumGoroutines: 64, maximumTimers: 64)))
        #expect(
            output == """
                0 context canceled context canceled
                250 context canceled context canceled
                500 context canceled context canceled
                750 context canceled context canceled
                context deadline exceeded slow true

                """)
    }
}
