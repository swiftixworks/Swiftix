import Testing
@testable import Swiftix

/// Linux's protection of a PID namespace's init: PID 1 ignores guest signals it
/// has no handler for — SIGKILL and SIGSTOP included when sent from inside its
/// own namespace — while host signals and ancestor SIGKILL/SIGSTOP still work.
@Suite("Signals to init (PID 1)")
struct InitSignalTests {

    private func state(_ kernel: Kernel, _ pid: PID) -> String? {
        kernel.snapshotProcesses().first { $0.pid == pid }?.state
    }

    // MARK: - The interactive session

    @Test func killNineOneFromTheShellLeavesTheSessionAlive() {
        let session = SystemSession()
        #expect(session.shellPID == 1)
        for line in ["kill -9 1", "kill 1", "kill -STOP 1", "kill -INT 1", "kill -KILL 1"] {
            session.run(line)
            #expect(session.shellIsAlive, "shell died after: \(line)")
        }
        #expect(state(session.kernel, 1) != "T")
        #expect(session.lines("echo still-here") == ["still-here"])
    }

    @Test func hostCanStillSignalTheSessionShell() {
        let session = SystemSession()
        session.kernel.kill(session.shellPID, signal: Signal.sigkill.rawValue)
        session.loop.runUntilIdle()
        #expect(!session.shellIsAlive)
    }

    @Test func ctrlCStillInterruptsTheForegroundJobOnly() {
        let session = SystemSession()
        session.pty.onControlC = { [weak session] in
            guard let session else { return }
            session.kernel.interruptProcessGroup(session.pty.foregroundProcessGroupID,
                                                 sessionID: session.shellPID,
                                                 signal: Signal.sigint.rawValue)
        }
        session.pty.writeFromApp(Array("sleep 1000\n".utf8))
        session.loop.runUntilIdle()
        #expect(session.kernel.snapshotProcesses().contains { $0.name == "sleep" })
        session.pty.writeFromApp([0x03])
        session.loop.runUntilIdle()
        #expect(!session.kernel.snapshotProcesses().contains { $0.name == "sleep" })
        #expect(session.shellIsAlive)
        #expect(session.lines("echo ok") == ["ok"])
    }

    /// A second terminal's shell is an ordinary process: it is not init.
    @Test func onlyPidOneIsProtected() {
        let session = SystemSession()
        let other = session.kernel.spawn("other") { ctx in ctx.sleep(1000) { ctx.exit(0) } }
        session.loop.runUntilIdle()
        session.run("kill -9 \(other)")
        #expect(!session.kernel.snapshotProcesses().contains { $0.pid == other })
    }

    // MARK: - Dispositions

    @Test func initReceivesSignalsItInstalledAHandlerFor() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var handled: [Int32] = [] }
        let box = Box()
        let initPID = kernel.spawn("init") { ctx in
            ctx.signal(Signal.sigterm.rawValue) { box.handled.append(Signal.sigterm.rawValue) }
            ctx.signal(Signal.sigkill.rawValue) { box.handled.append(Signal.sigkill.rawValue) }
            ctx.sleep(100) { ctx.exit(0) }
        }
        loop.advance(by: 0)
        kernel.spawn("sender") { ctx in
            ctx.kill(initPID, signal: Signal.sigterm.rawValue)   // handled
            ctx.kill(initPID, signal: Signal.sigint.rawValue)    // no handler: dropped
            ctx.kill(initPID, signal: Signal.sigkill.rawValue)   // uncatchable: dropped
        }
        loop.advance(by: 0)
        #expect(initPID == 1)
        #expect(box.handled == [Signal.sigterm.rawValue])
        #expect(state(kernel, initPID) == "S")
        #expect(kernel.snapshotProcesses().first { $0.pid == initPID }?.pendingSignals == [])
        kernel.shutdown()
    }

    @Test func droppedSignalsAreNotLeftPendingBehindAMask() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let initPID = kernel.spawn("init") { ctx in
            ctx.blockSignal(Signal.sigterm.rawValue)
            ctx.sleep(1) {
                ctx.unblockSignal(Signal.sigterm.rawValue)
                ctx.sleep(100) { ctx.exit(0) }
            }
        }
        loop.advance(by: 0)
        kernel.spawn("sender") { ctx in ctx.kill(initPID, signal: Signal.sigterm.rawValue) }
        loop.advance(by: 2)
        #expect(state(kernel, initPID) == "S")
        kernel.shutdown()
    }

    @Test func stoppedInitCanStillBeContinuedByAGuest() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let initPID = kernel.spawn("init") { ctx in ctx.sleep(100) { ctx.exit(0) } }
        loop.advance(by: 0)
        kernel.kill(initPID, signal: Signal.sigstop.rawValue)      // host authority
        #expect(state(kernel, initPID) == "T")
        kernel.spawn("sender") { ctx in ctx.kill(initPID, signal: Signal.sigcont.rawValue) }
        loop.advance(by: 0)
        #expect(state(kernel, initPID) == "S")
        kernel.shutdown()
    }

    @Test func nonInitProcessesKeepDefaultDispositions() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("init") { ctx in ctx.sleep(100) { ctx.exit(0) } }
        let victim = kernel.spawn("victim") { ctx in ctx.sleep(100) { ctx.exit(0) } }
        loop.advance(by: 0)
        kernel.spawn("sender") { ctx in ctx.kill(victim, signal: Signal.sigterm.rawValue) }
        loop.advance(by: 0)
        #expect(state(kernel, victim) == nil)
        kernel.shutdown()
    }

    // MARK: - Nested PID namespaces

    /// Builds: launcher (root ns) -> init (pid 1 of a child ns) -> worker.
    private final class Nested {
        let loop = EventLoop()
        let kernel: Kernel
        var launcher: PID = 0
        var initGlobal: PID = 0
        var workerGlobal: PID = 0
        var fromWorker: [Int32] = []
        var fromLauncher: [Int32] = []
        var handled: [Int32] = []

        init(initHandlesTerm: Bool = false) {
            kernel = Kernel(loop: loop)
            kernel.spawn("host-init") { ctx in ctx.sleep(1000) { ctx.exit(0) } }
            launcher = kernel.spawn("launcher") { [unowned self] ctx in
                ctx.unsharePIDNamespace()
                self.initGlobal = ctx.spawn("ns-init") { initProcess in
                    if initHandlesTerm {
                        initProcess.signal(Signal.sigterm.rawValue) {
                            self.handled.append(Signal.sigterm.rawValue)
                        }
                    }
                    self.workerGlobal = initProcess.spawn("worker") { worker in
                        worker.sleep(1) {
                            // `kill` takes a global pid; ns-init is pid 1 only inside the namespace.
                            for signal in self.fromWorker { worker.kill(self.initGlobal, signal: signal) }
                            worker.sleep(1000) { worker.exit(0) }
                        }
                    }
                    initProcess.sleep(1000) { initProcess.exit(0) }
                }
                ctx.sleep(2) {
                    for signal in self.fromLauncher { ctx.kill(self.initGlobal, signal: signal) }
                    ctx.sleep(1000) { ctx.exit(0) }
                }
            }
        }

        func isLive(_ pid: PID) -> Bool {
            kernel.snapshotProcesses().contains { $0.pid == pid && $0.lifecycle == .live }
        }
    }

    @Test func namespaceInitIgnoresKillFromInsideItsNamespace() {
        let nested = Nested()
        nested.fromWorker = [Signal.sigkill.rawValue, Signal.sigterm.rawValue, Signal.sigstop.rawValue]
        nested.loop.advance(by: 1.5)
        #expect(nested.isLive(nested.initGlobal))
        #expect(state(nested.kernel, nested.initGlobal) == "S")
        nested.kernel.shutdown()
    }

    @Test func ancestorNamespaceCanForceKillButNotTermWithoutHandler() {
        let term = Nested()
        term.fromLauncher = [Signal.sigterm.rawValue, Signal.sigint.rawValue]
        term.loop.advance(by: 3)
        #expect(term.isLive(term.initGlobal))
        term.kernel.shutdown()

        let kill = Nested()
        kill.fromLauncher = [Signal.sigkill.rawValue]
        kill.loop.advance(by: 3)
        #expect(!kill.isLive(kill.initGlobal))
        kill.kernel.shutdown()

        let stop = Nested()
        stop.fromLauncher = [Signal.sigstop.rawValue]
        stop.loop.advance(by: 3)
        #expect(state(stop.kernel, stop.initGlobal) == "T")
        stop.kernel.shutdown()
    }

    @Test func namespaceInitHandlerRunsForSignalsFromBothSides() {
        let nested = Nested(initHandlesTerm: true)
        nested.fromWorker = [Signal.sigterm.rawValue]
        nested.fromLauncher = [Signal.sigterm.rawValue]
        nested.loop.advance(by: 3)
        #expect(nested.handled == [Signal.sigterm.rawValue, Signal.sigterm.rawValue])
        #expect(nested.isLive(nested.initGlobal))
        nested.kernel.shutdown()
    }

    /// The host is above every namespace: its signals are never filtered.
    @Test func hostKillTerminatesANamespaceInit() {
        let nested = Nested()
        nested.loop.advance(by: 0.5)
        nested.kernel.kill(nested.initGlobal, signal: Signal.sigterm.rawValue)
        nested.loop.advance(by: 0)
        #expect(!nested.isLive(nested.initGlobal))
        nested.kernel.shutdown()
    }
}
