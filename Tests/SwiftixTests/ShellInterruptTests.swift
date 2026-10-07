import Testing
@testable import Swiftix

/// Ctrl-C at the interactive shell: at an idle prompt, at a continuation
/// prompt, during a shell loop, and against a foreground job.
///
/// The host's `onControlC` hook only signals the terminal's foreground job, so
/// the shell itself learns of the keypress from the terminal (see
/// `PseudoTerminal.takeLineInterrupt`). Both paths are exercised here with the
/// hook wired the way a console integration wires it.
@Suite("Shell Ctrl-C handling")
struct ShellInterruptTests {

    private let prompt = "root@swiftix:/# "

    private func session(echo: Bool = false) -> SystemSession {
        let session = SystemSession()
        session.pty.echo = echo
        session.pty.onControlC = { [weak session] in
            guard let session else { return }
            session.kernel.interruptProcessGroup(session.pty.foregroundProcessGroupID,
                                                 sessionID: session.shellPID,
                                                 signal: Signal.sigint.rawValue)
        }
        return session
    }

    /// Type raw bytes and return what the terminal showed in response.
    private func type(_ session: SystemSession, _ bytes: [UInt8]) -> String {
        var shown: [UInt8] = []
        let previous = session.pty.onOutput
        session.pty.onOutput = { [unowned pty = session.pty] in shown += pty.readForApp(max: 65_535) }
        session.pty.writeFromApp(bytes)
        session.loop.runUntilIdle()
        session.pty.onOutput = previous
        return String(decoding: shown, as: UTF8.self)
    }

    @Test func idlePromptDiscardsTheLineAndPromptsAgain() {
        let s = session()
        #expect(type(s, Array("echo never-run".utf8)) == "")
        #expect(type(s, [0x03]) == prompt)
        #expect(s.pty.currentInputLine == "")
        #expect(s.lines("echo ok; echo $?") == ["ok", "0"])
        #expect(s.shellIsAlive)
    }

    @Test func idlePromptWithEchoShowsCaretC() {
        let s = session(echo: true)
        _ = type(s, Array("partial".utf8))
        #expect(type(s, [0x03]) == "^C\n" + prompt)
        // An empty line too: the prompt is simply redrawn.
        #expect(type(s, [0x03]) == "^C\n" + prompt)
    }

    @Test func statusAfterAnInterruptedLineIs130() {
        let s = session()
        _ = type(s, [0x03])
        #expect(s.lines("echo $?") == ["130"])
    }

    @Test func continuationPromptAbandonsThePendingCommand() {
        let s = session()
        #expect(type(s, Array("if true; then\n".utf8)) == "> ")
        #expect(type(s, Array("echo inside\n".utf8)) == "> ")
        #expect(type(s, [0x03]) == prompt)
        // The abandoned `if` is gone: this line is a complete command.
        #expect(s.lines("echo fresh") == ["fresh"])
        // An open quote is abandoned the same way.
        #expect(type(s, Array("echo 'open\n".utf8)) == "> ")
        #expect(type(s, [0x03]) == prompt)
        #expect(s.lines("echo closed") == ["closed"])
    }

    @Test func controlDStillMeansEndOfFile() {
        let s = session()
        _ = type(s, [0x03])
        #expect(s.shellIsAlive)
        _ = type(s, [0x04])
        #expect(!s.shellIsAlive)
    }

    @Test func foregroundJobIsInterruptedAndTheRestOfTheLineIsDropped() {
        let s = session()
        s.pty.writeFromApp(Array("sleep 1000; echo not-reached\n".utf8))
        s.loop.runUntilIdle()
        #expect(s.kernel.snapshotProcesses().contains { $0.name == "sleep" })
        #expect(type(s, [0x03]) == prompt)
        #expect(!s.kernel.snapshotProcesses().contains { $0.name == "sleep" })
        #expect(s.lines("echo $?") == ["130"])
    }

    @Test func shellLoopIsInterrupted() {
        let s = session()
        s.pty.writeFromApp(Array("while true; do :; done; echo not-reached\n".utf8))
        #expect(s.loop.runUntilIdle(stepBudget: 5_000) == .budgetExceeded)
        #expect(type(s, [0x03]) == prompt)
        #expect(s.lines("echo back") == ["back"])
    }

    @Test func nestedInteractiveShellSurvivesControlC() {
        let s = session()
        s.run("sh")
        #expect(s.lines("echo $$") != ["1"])
        #expect(type(s, [0x03]) == prompt)
        #expect(s.kernel.snapshotProcesses().filter { $0.name == "sh" }.count == 2)
        s.run("exit")
        #expect(s.lines("echo $$") == ["1"])
    }

    @Test func aTrapOnIntReplacesAndRestoresTheDefault() {
        let s = session()
        s.run("sh")
        let nested = s.kernel.snapshotProcesses().filter { $0.name == "sh" }.map(\.pid).max()!
        s.run("trap 'echo trapped' INT")
        s.kernel.kill(nested, signal: Signal.sigint.rawValue)
        #expect(s.lines("true") == ["trapped"])
        s.run("trap - INT")
        s.kernel.kill(nested, signal: Signal.sigint.rawValue)
        s.loop.runUntilIdle()
        #expect(s.kernel.snapshotProcesses().contains { $0.pid == nested })   // ignored again
    }

    /// A cooked reader that publishes no prompt (a program the host runs
    /// directly on a PTY) is unaffected: Ctrl-C only clears its line.
    @Test func readersWithoutAPromptSeeNoEndOfFile() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        pty.echo = false
        let lines = ResultBox<[String]>()
        lines.value = []
        kernel.spawn("reader") { ctx in
            ctx.installStandardIO(pty.slave)
            func next() {
                ctx.read(0) { bytes in
                    lines.value?.append(String(decoding: bytes, as: UTF8.self))
                    if bytes.isEmpty { ctx.exit(0) } else { next() }
                }
            }
            next()
        }
        loop.runUntilIdle()
        pty.writeFromApp(Array("dropped".utf8))
        pty.writeFromApp([0x03])
        loop.runUntilIdle()
        #expect(lines.value == [])
        pty.writeFromApp(Array("kept\n".utf8))
        loop.runUntilIdle()
        #expect(lines.value == ["kept\n"])
    }
}
