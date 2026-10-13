/// Go wall-clock time: `time.Now`, `time.Since`, `time.Unix`, and the
/// `time.Time` methods `Unix`, `UnixMilli`, `UnixNano`, `Sub`, `Add`, `Before`,
/// `After`, and `Equal`.
///
/// Concurrency: every fixture builds its own `EventLoop` (and `Kernel`) and
/// drives it on the calling executor. Nothing reads the host's clock.

import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

@Suite("Go wall-clock time")
struct GoWallClockTests: GoTestHarness {

    @Test func aRunWithoutAProcessCountsFromLogicalZero() throws {
        let output = try runGoMain(
            """
            start := time.Now()
            fmt.Println(start.Unix(), start.UnixMilli(), start.UnixNano())
            time.Sleep(1500 * time.Millisecond)
            now := time.Now()
            fmt.Println(now.Unix(), now.UnixMilli(), now.UnixNano())
            fmt.Println(time.Since(start), now.Sub(start), start.Sub(now))
            fmt.Println(now.After(start), now.Before(start), now.Equal(start), now.Equal(now))
            """,
            imports: ["fmt", "time"])

        #expect(
            output == """
                0 0 0
                1 1500 1500000000
                1500000000 1500000000 -1500000000
                true false false true

                """)
    }

    @Test func nowFollowsTheKernelWallClock() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(
                    """
                    start := time.Now()
                    fmt.Println(start.Unix(), start.UnixMilli())
                    time.Sleep(2 * time.Second)
                    fmt.Println(time.Now().Unix(), time.Since(start) == 2*time.Second)
                    """,
                    imports: ["fmt", "time"]))
        ])
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.setWallClock(epochSeconds: 1_760_000_000.25, utcOffsetSeconds: 8 * 3600)
        var output = ""

        kernel.spawn("go-clock") { context in
            _ = try? GoVirtualMachine().run(executable, eventLoop: loop, processContext: context) {
                output += $0
            }
            context.exit(0)
        }
        loop.runUntilIdle()

        // The zone offset shifts how a time prints, never the instant.
        #expect(output == "1760000000 1760000000250\n1760000002 true\n")
    }

    @Test func timerChannelsDeliverTheInstantTheyFired() throws {
        let output = try runGoMain(
            """
            start := time.Now()
            fired := <-time.After(250 * time.Millisecond)
            fmt.Println(fired.Sub(start), fired.Equal(time.Now()), fired.UnixMilli())
            """,
            imports: ["fmt", "time"])

        #expect(output == "250000000 true 250\n")
    }

    @Test func instantsConvertToAndFromUnixTime() throws {
        let output = try runGoMain(
            """
            moment := time.Unix(1760000000, 123456789)
            fmt.Println(moment.Unix(), moment.UnixMilli(), moment.UnixNano())
            later := moment.Add(90 * time.Second)
            fmt.Println(later.Unix(), later.Sub(moment) == 90*time.Second, later.After(moment))
            early := time.Unix(-1, -1)
            fmt.Println(early.Unix(), early.UnixMilli(), early.UnixNano())
            var zero time.Time
            fmt.Println(zero.Unix(), zero.Equal(time.Unix(0, 0)), expired(moment, later))
            """,
            imports: ["fmt", "time"],
            declarations: """
                func expired(deadline time.Time, now time.Time) bool {
                    return !now.Before(deadline)
                }
                """)

        // Seconds and milliseconds before the epoch round down, as in Go.
        #expect(
            output == """
                1760000000 1760000000123 1760000000123456789
                1760000090 true true
                -2 -1001 -1000000001
                0 true true

                """)
    }

    @Test func timeNativesArePureFunctionsOfTheirOperands() {
        #expect(GoNative.time("$time.Now", [], now: 42) == .int(42))
        #expect(GoNative.time("$time.Since", [40], now: 42) == .int(2))
        #expect(GoNative.time("$time.Time.Unix", [-1], now: 0) == .int(-1))
        #expect(GoNative.time("$time.Time.Unix", [-1_000_000_000], now: 0) == .int(-1))
        #expect(GoNative.time("$time.Time.Unix", [1_999_999_999], now: 0) == .int(1))
        #expect(GoNative.time("$time.Time.UnixMilli", [-1_000_001], now: 0) == .int(-2))
        #expect(GoNative.time("$time.Time.Add", [Int64.max, 1], now: 0) == .int(Int64.min))
        #expect(GoNative.time("$time.Time.Sub", [Int64.min, 1], now: 0) == .int(Int64.max))
        #expect(GoNative.time("$time.Unix", [Int64.max, 0], now: 0) != nil)
        #expect(GoNative.time("$time.Sleep", [1], now: 0) == nil)
        for name in GoNative.timeArgumentCounts.keys {
            let operands = [Int64](repeating: 7, count: GoNative.timeArgumentCounts[name]!)
            #expect(GoNative.time(name, operands, now: 0) != nil)
        }
    }

    @Test func timeCallsAreTypeChecked() {
        func diagnostic(_ body: String) -> String? {
            goMainDiagnostic(body, imports: ["fmt", "time"])
        }
        #expect(
            diagnostic("fmt.Println(time.Now(1))")
                == "wrong number of arguments in call to time.Now")
        #expect(
            diagnostic("fmt.Println(time.Now().Unix(1))")
                == "wrong number of arguments in call to time.Time.Unix")
        #expect(diagnostic("fmt.Println(time.Now().Sub(5))") != nil)
        #expect(diagnostic("fmt.Println(time.Now().Add(time.Now()))") != nil)
        #expect(diagnostic("var seconds string = time.Now().Unix()\nfmt.Println(seconds)") != nil)
        #expect(diagnostic("fmt.Println(time.Now().Format(\"2006\"))") != nil)
        #expect(diagnostic("fmt.Println(time.Since(5))") != nil)
        #expect(
            diagnostic(
                """
                var deadline time.Time = time.Now().Add(time.Second)
                var left int = deadline.Sub(time.Now())
                fmt.Println(left, deadline.After(time.Now()))
                """) == nil)
    }
}
