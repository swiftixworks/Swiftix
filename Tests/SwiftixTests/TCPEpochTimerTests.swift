import Testing
@testable import Swiftix

@Suite("TCP epoch timer")
struct TCPEpochTimerTests {
    @Test func scheduledEpochIsRejectedAfterCancel() {
        let loop = EventLoop()
        var timer = TCPEpochTimer()
        final class Capture { var accepted = false }
        let captured = Capture()

        timer.schedule(on: loop, after: 1.0) { epoch in
            captured.accepted = timer.accepts(epoch)
        }
        timer.cancel()

        #expect(loop.pendingCount == 0)

        loop.advance(by: 1.0)

        #expect(!captured.accepted)
    }

    @Test func newerSchedulePhysicallyReplacesOlderOne() {
        let loop = EventLoop()
        var timer = TCPEpochTimer()
        final class Capture { var accepted: [Bool] = [] }
        let captured = Capture()

        timer.schedule(on: loop, after: 1.0) { epoch in
            captured.accepted.append(timer.accepts(epoch))
        }
        timer.schedule(on: loop, after: 1.0) { epoch in
            captured.accepted.append(timer.accepts(epoch))
        }

        #expect(loop.pendingCount == 1)

        loop.advance(by: 1.0)

        #expect(captured.accepted == [true])
        #expect(loop.pendingCount == 0)
    }
}
