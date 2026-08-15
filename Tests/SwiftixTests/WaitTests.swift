import Testing
@testable import Swiftix

@Suite("SIGCHLD + wait()")
struct WaitTests {

    @Test func parentWaitsForChildExitCode() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var childPID: PID = -1
            var status: ProcessWaitStatus?
        }
        let captured = Capture()

        let parent = kernel.spawn("parent") { ctx in
            ctx.spawn("child") { child in child.exit(42) }
            ctx.wait { result in
                if case .success(let event) = result {
                    captured.childPID = event.childPID
                    captured.status = event.status
                }
            }
        }

        loop.runUntilIdle()

        #expect(captured.status == .exited(42))
        #expect(captured.childPID != parent)
        #expect(kernel.processCount == 0)
    }

    @Test func waitReportsSignaledChild() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var childPID: PID = -1
            var event: ChildWaitEvent?
        }
        let captured = Capture()

        kernel.spawn("parent") { ctx in
            captured.childPID = ctx.spawn("child") { child in
                child.sleep(10) { child.exit(0) }
            }
            ctx.wait { result in
                if case .success(let event) = result {
                    captured.event = event
                }
            }
        }
        loop.advance(by: 0)

        kernel.kill(captured.childPID, signal: Signal.sigterm.rawValue)
        loop.runUntilIdle()

        #expect(captured.event?.childPID == captured.childPID)
        #expect(captured.event?.status == .signaled(Signal.sigterm.rawValue))
        #expect(captured.event?.status.code == 128 + Signal.sigterm.rawValue)
        #expect(captured.event?.status.terminatingSignal == Signal.sigterm.rawValue)
    }

    @Test func waitEventReportsStoppedChild() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var childPID: PID = -1
            var event: ChildWaitEvent?
        }
        let captured = Capture()

        kernel.spawn("parent") { ctx in
            captured.childPID = ctx.spawn("child") { child in
                child.sleep(10) { child.exit(0) }
            }
            ctx.waitEvent { result in
                if case .success(let event) = result {
                    captured.event = event
                }
            }
        }
        loop.advance(by: 0)

        kernel.kill(captured.childPID, signal: Signal.sigtstp.rawValue)
        loop.runUntilIdle()

        #expect(captured.event?.childPID == captured.childPID)
        #expect(captured.event?.status == .stopped(Signal.sigtstp.rawValue))
        #expect(captured.event?.isStopped == true)
        #expect(captured.event?.status.stoppingSignal == Signal.sigtstp.rawValue)
        #expect(captured.event?.code == 128 + Signal.sigtstp.rawValue)
    }

    @Test func waitpidWaitsForSpecificChild() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var fastPID: PID = -1
            var slowPID: PID = -1
            var waitedEvent: ChildWaitEvent?
            var reapedEvent: ChildWaitEvent?
        }
        let captured = Capture()

        kernel.spawn("parent") { ctx in
            captured.slowPID = ctx.spawn("slow") { child in
                child.sleep(2) { child.exit(7) }
            }
            captured.fastPID = ctx.spawn("fast") { child in
                child.exit(3)
            }
            ctx.waitpid(captured.slowPID) { result in
                if case .success(let event?) = result {
                    captured.waitedEvent = event
                    captured.reapedEvent = ctx.reapChild()
                }
            }
        }

        loop.advance(by: 0)

        #expect(captured.waitedEvent == nil)
        #expect(kernel.processCount == 2)

        loop.advance(by: 2)
        loop.runUntilIdle()

        #expect(captured.waitedEvent?.childPID == captured.slowPID)
        #expect(captured.waitedEvent?.status == .exited(7))
        #expect(captured.reapedEvent?.childPID == captured.fastPID)
        #expect(captured.reapedEvent?.status == .exited(3))
        #expect(kernel.processCount == 0)
    }

    @Test func waitpidNoHangReturnsNilWhenChildHasNoReadyEvent() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var childPID: PID = -1
            var noReadyEvent = false
            var error: SyscallError?
        }
        let captured = Capture()

        kernel.spawn("parent") { ctx in
            captured.childPID = ctx.spawn("child") { child in
                child.sleep(2) { child.exit(9) }
            }
            ctx.waitpid(captured.childPID, options: [.noHang]) { result in
                switch result {
                case .success(nil):
                    captured.noReadyEvent = true
                case .success, .failure:
                    if case .failure(let error) = result { captured.error = error }
                }
            }
        }

        loop.advance(by: 0)

        #expect(captured.noReadyEvent)
        #expect(captured.error == nil)
        #expect(kernel.processCount == 1)

        loop.advance(by: 2)
        loop.runUntilIdle()

        #expect(kernel.processCount == 0)
    }

    @Test func waitpidNoHangReportsNoChildAsError() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var error: SyscallError? }
        let captured = Capture()

        kernel.spawn("lonely") { ctx in
            ctx.waitpid(options: [.noHang]) { result in
                if case .failure(let error) = result {
                    captured.error = error
                }
            }
        }

        loop.runUntilIdle()

        #expect(captured.error == .noChildProcess)
    }

    /// A SIGCHLD handler on the parent fires when a child exits.
    @Test func sigchldHandlerFiresOnChildExit() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture { var sigchld = false }
        let captured = Capture()

        kernel.spawn("parent") { ctx in
            ctx.signal(Signal.sigchld.rawValue) { captured.sigchld = true }
            ctx.spawn("child") { child in child.exit(0) }
            ctx.wait { _ in }                     // stay alive to receive SIGCHLD
        }

        loop.runUntilIdle()

        #expect(captured.sigchld)
    }
}
