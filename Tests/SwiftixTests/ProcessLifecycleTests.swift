import Testing
@testable import Swiftix

@Suite("process lifecycle model")
struct ProcessLifecycleTests {

    @Test func exitedChildRemainsZombieUntilWaitAndOwnsNoRuntimeWork() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var childPID: PID = -1
            var delayedWorkRan = false
            var reaped: ChildWaitEvent?
            var postExitFD: Int?
            var postExitChildPID: PID = -1
        }
        let captured = Capture()

        kernel.spawn("parent") { parent in
            captured.childPID = parent.spawn("child") { child in
                _ = child.open("/proc/processes")
                child.schedule(after: 5) { captured.delayedWorkRan = true }
                child.exit(23)
                captured.postExitFD = child.open("/proc/processes")
                captured.postExitChildPID = child.spawn("too-late") { _ in }
            }
            parent.sleep(1) {
                captured.reaped = parent.reapChild()
            }
        }

        loop.advance(by: 0)

        let zombie = kernel.snapshotProcesses().first { $0.pid == captured.childPID }
        #expect(zombie?.state == "Z")
        #expect(zombie?.lifecycle == .zombie)
        #expect(zombie?.exitStatus == .exited(23))
        #expect(zombie?.openFileDescriptors == 0)
        #expect(zombie?.waitReasons.isEmpty == true)
        #expect(captured.postExitFD == -1)
        #expect(captured.postExitChildPID == 0)
        #expect(kernel.snapshotResources().liveProcesses == 1)
        #expect(kernel.snapshotResources().zombieProcesses == 1)

        loop.advance(by: 1)
        loop.advance(by: 10)

        #expect(captured.reaped?.status == .exited(23))
        #expect(!captured.delayedWorkRan)
        #expect(kernel.snapshotProcesses().isEmpty)
    }

    @Test func waitpidCanObserveContinuedTransition() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var childPID: PID = -1
            var event: ChildWaitEvent?
        }
        let captured = Capture()

        kernel.spawn("parent") { parent in
            captured.childPID = parent.spawn("child") { child in
                child.sleep(10) { child.exit(0) }
            }
            parent.waitpid(captured.childPID, options: [.continued]) { result in
                if case .success(let event?) = result { captured.event = event }
            }
        }
        loop.advance(by: 0)

        kernel.kill(captured.childPID, signal: Signal.sigstop.rawValue)
        loop.runUntilIdle()
        #expect(captured.event == nil)

        kernel.kill(captured.childPID, signal: Signal.sigcont.rawValue)
        loop.runUntilIdle()

        #expect(captured.event?.childPID == captured.childPID)
        #expect(captured.event?.status == .continued)
        #expect(captured.event?.status.isContinued == true)
        kernel.shutdown()
    }

    @Test func sigstopCannotBeCaughtOrMasked() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var handlerRan = false
            var mask: Set<Int32> = []
        }
        let captured = Capture()

        let pid = kernel.spawn("worker") { process in
            process.signal(Signal.sigstop.rawValue) { captured.handlerRan = true }
            process.blockSignal(Signal.sigstop.rawValue)
            captured.mask = process.signalMask
            process.sleep(10) { process.exit(0) }
        }
        loop.advance(by: 0)

        kernel.kill(pid, signal: Signal.sigstop.rawValue)
        loop.runUntilIdle()

        #expect(!captured.mask.contains(Signal.sigstop.rawValue))
        #expect(!captured.handlerRan)
        #expect(kernel.snapshotProcesses().first { $0.pid == pid }?.state == "T")
        kernel.shutdown()
    }

    @Test func exitingParentReparentsZombieChildToNamespaceInit() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var parentPID: PID = -1
            var childPID: PID = -1
        }
        let captured = Capture()

        let initPID = kernel.spawn("init") { initProcess in
            captured.parentPID = initProcess.spawn("parent") { parent in
                captured.childPID = parent.spawn("child") { child in child.exit(4) }
            }
            initProcess.sleep(10) { initProcess.exit(0) }
        }
        loop.advance(by: 0)

        let snapshots = kernel.snapshotProcesses()
        let parent = snapshots.first { $0.pid == captured.parentPID }
        let child = snapshots.first { $0.pid == captured.childPID }
        #expect(parent?.lifecycle == .zombie)
        #expect(parent?.parentPID == initPID)
        #expect(child?.lifecycle == .zombie)
        #expect(child?.parentPID == initPID)
        kernel.shutdown()
    }

    @Test func snapshotExplainsSleepingStateWithStructuredWaitReason() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        let pid = kernel.spawn("sleeper") { process in
            process.sleep(12) { process.exit(0) }
        }
        loop.advance(by: 0)

        let snapshot = kernel.snapshotProcesses().first { $0.pid == pid }
        #expect(snapshot?.state == "S")
        #expect(snapshot?.lifecycle == .live)
        #expect(snapshot?.waitReasons.count == 1)
        #expect(snapshot?.waitReasons.first?.hasPrefix("sleep-until:") == true)
        kernel.shutdown()
    }

    @Test func processSpawnedWhileKernelPausedDoesNotRunUntilResume() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Capture { var ran = false }
        let captured = Capture()

        kernel.pause()
        let pid = kernel.spawn("queued") { _ in captured.ran = true }
        loop.runUntilIdle()

        #expect(!captured.ran)
        #expect(kernel.snapshotProcesses().first { $0.pid == pid }?.queuedSteps == 1)

        kernel.resume()
        loop.runUntilIdle()
        #expect(captured.ran)
        #expect(kernel.snapshotProcesses().isEmpty)
    }

    @Test func terminalReapDiscardsOlderStopAndContinueEvents() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Capture {
            var childPID: PID = -1
            var exitEvent: ChildWaitEvent?
            var secondWaitError: SyscallError?
        }
        let captured = Capture()

        kernel.spawn("parent") { parent in
            captured.childPID = parent.spawn("child") { child in
                child.sleep(10) { child.exit(0) }
            }
            parent.wait { result in
                if case .success(let event) = result { captured.exitEvent = event }
                parent.waitpid(captured.childPID, options: [.untraced, .continued, .noHang]) {
                    if case .failure(let error) = $0 { captured.secondWaitError = error }
                }
            }
        }
        loop.advance(by: 0)

        kernel.kill(captured.childPID, signal: Signal.sigstop.rawValue)
        kernel.kill(captured.childPID, signal: Signal.sigcont.rawValue)
        kernel.kill(captured.childPID, signal: Signal.sigterm.rawValue)
        loop.runUntilIdle()

        #expect(captured.exitEvent?.status == .signaled(Signal.sigterm.rawValue))
        #expect(captured.secondWaitError == .noChildProcess)
        #expect(kernel.snapshotProcesses().isEmpty)
    }
}
