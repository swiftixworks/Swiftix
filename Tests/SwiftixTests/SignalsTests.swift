import Testing
@testable import Swiftix

@Suite("Signals + job control")
struct SignalsTests {

    /// Ctrl-C on the pty sends SIGINT to the foreground job, which (no handler)
    /// is terminated by the default disposition.
    @Test func ctrlCTerminatesForegroundJob() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()

        let jobPID = kernel.spawn("job") { ctx in
            let fd = ctx.install(pty.slave)
            func readLoop() { ctx.read(fd) { _ in readLoop() } }
            readLoop()
        }
        pty.onControlC = { [weak kernel] in
            kernel?.kill(jobPID, signal: Signal.sigint.rawValue)
        }

        loop.runUntilIdle()                        // job blocks on read
        #expect(kernel.processCount == 1)

        pty.writeFromApp([0x03])                   // Ctrl-C
        loop.runUntilIdle()
        #expect(kernel.processCount == 0)          // SIGINT default-terminated it
    }

    /// An installed SIGINT handler runs instead of terminating the process.
    @Test func installedHandlerRunsInsteadOfTerminating() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()

        final class Capture { var caught = false }
        let captured = Capture()

        let pid = kernel.spawn("job") { ctx in
            ctx.signal(Signal.sigint.rawValue) { captured.caught = true }
            let fd = ctx.install(pty.slave)
            func readLoop() { ctx.read(fd) { _ in readLoop() } }
            readLoop()
        }

        loop.runUntilIdle()
        #expect(kernel.processCount == 1)

        kernel.kill(pid, signal: Signal.sigint.rawValue)
        loop.runUntilIdle()                        // handler runs as a scheduled step

        #expect(captured.caught)
        #expect(kernel.processCount == 1)          // still alive (handled, not terminated)
    }

    /// Ctrl-Z suspends the foreground job (SIGTSTP): while stopped, input it would
    /// otherwise consume is held; SIGCONT resumes it and the deferred work runs.
    @Test func ctrlZStopsAndSigcontResumes() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()

        final class Capture { var lines = 0 }
        let captured = Capture()

        let jobPID = kernel.spawn("job") { ctx in
            let fd = ctx.install(pty.slave)
            func readLoop() {
                ctx.read(fd) { bytes in
                    if !bytes.isEmpty { captured.lines += 1 }
                    readLoop()
                }
            }
            readLoop()
        }
        pty.onControlZ = { [weak kernel] in
            kernel?.kill(jobPID, signal: Signal.sigtstp.rawValue)
        }

        loop.runUntilIdle()                        // job blocks on read
        #expect(captured.lines == 0)

        pty.writeFromApp([0x1A])                    // Ctrl-Z -> SIGTSTP
        loop.runUntilIdle()
        #expect(kernel.process(jobPID)?.isStopped == true)

        pty.writeFromApp(Array("hello\n".utf8))     // typed while stopped: deferred, not consumed yet
        loop.runUntilIdle()
        #expect(captured.lines == 0)                // still stopped, work held

        kernel.kill(jobPID, signal: Signal.sigcont.rawValue)   // resume
        loop.runUntilIdle()
        #expect(captured.lines == 1)                // deferred read now processed the line
    }

    /// SIGKILL terminates even when a handler is installed (uncatchable).
    @Test func sigkillTerminatesEvenWithHandler() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()

        let pid = kernel.spawn("job") { ctx in
            ctx.signal(Signal.sigint.rawValue) { /* would catch SIGINT, not SIGKILL */ }
            let fd = ctx.install(pty.slave)
            func readLoop() { ctx.read(fd) { _ in readLoop() } }
            readLoop()
        }

        loop.runUntilIdle()
        #expect(kernel.processCount == 1)

        kernel.kill(pid, signal: Signal.sigkill.rawValue)
        #expect(kernel.processCount == 0)
    }

    @Test func maskedSignalHandlerRunsOnlyAfterUnblock() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()

        final class Capture {
            var caught = 0
            var pendingBeforeUnblock: [Int32] = []
        }
        let captured = Capture()

        let pid = kernel.spawn("job") { ctx in
            ctx.signal(Signal.sigint.rawValue) { captured.caught += 1 }
            ctx.blockSignal(Signal.sigint.rawValue)
            let fd = ctx.install(pty.slave)
            ctx.read(fd) { _ in
                captured.pendingBeforeUnblock = ctx.pendingSignals
                ctx.unblockSignal(Signal.sigint.rawValue)
                ctx.read(fd) { _ in }
            }
        }

        loop.runUntilIdle()
        kernel.kill(pid, signal: Signal.sigint.rawValue)
        loop.runUntilIdle()

        #expect(captured.caught == 0)
        #expect(kernel.processCount == 1)

        pty.writeFromApp(Array("go\n".utf8))
        loop.runUntilIdle()

        #expect(captured.pendingBeforeUnblock == [Signal.sigint.rawValue])
        #expect(captured.caught == 1)
        #expect(kernel.processCount == 1)
    }

    @Test func maskedDefaultTerminationIsPendingUntilUnblock() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()

        final class Capture { var pendingBeforeUnblock: [Int32] = [] }
        let captured = Capture()

        let pid = kernel.spawn("job") { ctx in
            ctx.blockSignal(Signal.sigterm.rawValue)
            let fd = ctx.install(pty.slave)
            ctx.read(fd) { _ in
                captured.pendingBeforeUnblock = ctx.pendingSignals
                ctx.unblockSignal(Signal.sigterm.rawValue)
            }
        }

        loop.runUntilIdle()
        kernel.kill(pid, signal: Signal.sigterm.rawValue)
        loop.runUntilIdle()

        #expect(kernel.processCount == 1)

        pty.writeFromApp(Array("die\n".utf8))
        loop.runUntilIdle()

        #expect(captured.pendingBeforeUnblock == [Signal.sigterm.rawValue])
        #expect(kernel.processCount == 0)
    }

    @Test func sigkillIgnoresSignalMask() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()

        final class Capture { var mask: Set<Int32> = [] }
        let captured = Capture()

        let pid = kernel.spawn("job") { ctx in
            ctx.blockSignal(Signal.sigkill.rawValue)
            captured.mask = ctx.signalMask
            let fd = ctx.install(pty.slave)
            ctx.read(fd) { _ in }
        }

        loop.runUntilIdle()
        #expect(captured.mask.contains(Signal.sigkill.rawValue) == false)

        kernel.kill(pid, signal: Signal.sigkill.rawValue)

        #expect(kernel.processCount == 0)
    }

    @Test func maskedSIGCHLDIsPendingUntilUnblocked() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var sigchld = false
            var pendingBeforeUnblock: [Int32] = []
            var waitedCode: Int32 = -1
        }
        let captured = Capture()

        kernel.spawn("parent") { ctx in
            ctx.signal(Signal.sigchld.rawValue) { captured.sigchld = true }
            ctx.blockSignal(Signal.sigchld.rawValue)
            ctx.spawn("child") { child in child.exit(42) }
            ctx.wait { result in
                if case .success(let event) = result {
                    captured.waitedCode = event.status.code
                }
                captured.pendingBeforeUnblock = ctx.pendingSignals
                ctx.unblockSignal(Signal.sigchld.rawValue)
            }
        }

        loop.runUntilIdle()

        #expect(captured.waitedCode == 42)
        #expect(captured.pendingBeforeUnblock == [Signal.sigchld.rawValue])
        #expect(captured.sigchld)
        #expect(kernel.processCount == 0)
    }
}
