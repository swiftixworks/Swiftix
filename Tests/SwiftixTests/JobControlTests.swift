import Testing
@testable import Swiftix

/// Background jobs (`&`) and job control (`jobs`, `fg`) in the shell. Background
/// pipelines run without blocking the prompt; the shell harvests them at the next
/// prompt (printing a Done notice) or on `fg`.
@Suite("Background jobs + job control")
struct JobControlTests {

    /// `sleep 0.05 &` returns to the prompt immediately with a `[id] pid` notice,
    /// and a completion notice is printed at the next prompt after it finishes.
    @Test func backgroundJobReportsThenCompletes() async {
        let (loop, kernel, pty, cap) = makeShell()
        _ = kernel

        pty.writeFromApp(Array("sleep 0.05 &\n".utf8))
        await settle(loop)                                      // job parks on its timer
        #expect(contains(cap.out, Array("[1]".utf8)))          // launch notice

        loop.advance(by: 0.1)                                   // fire the sleep timer
        await settle(loop)

        pty.writeFromApp(Array("jobs\n".utf8))                  // prompt harvests it
        await settle(loop)
        #expect(contains(cap.out, Array("Done".utf8)))
    }

    /// `jobs` lists a still-running background job with its command text. Uses a
    /// server (`tcpecho`) that parks on accept, so it stays running (no timer to
    /// fire) while we inspect it.
    @Test func jobsListsRunningJob() async {
        let (loop, kernel, pty, cap) = makeShell()
        _ = kernel

        pty.writeFromApp(Array("tcpecho 9100 &\n".utf8))
        await settle(loop)
        pty.writeFromApp(Array("jobs\n".utf8))
        await settle(loop)

        #expect(contains(cap.out, Array("Running".utf8)))
        #expect(contains(cap.out, Array("tcpecho 9100".utf8)))
    }

    /// `fg` waits for a background job in the foreground: the prompt does not
    /// return until the job finishes.
    @Test func fgWaitsForBackgroundJob() async {
        let (loop, kernel, pty, cap) = makeShell()
        _ = kernel

        pty.writeFromApp(Array("sleep 0.5 &\n".utf8))
        await settle(loop)                                      // job running (timer pending)
        let promptsBeforeFg = promptCount(cap.out)

        pty.writeFromApp(Array("fg 1\n".utf8))
        await settle(loop)                                      // no time advance => still blocked
        let promptsWhileBlocked = promptCount(cap.out)

        loop.advance(by: 0.6)                                   // job finishes
        await settle(loop)
        let promptsAfter = promptCount(cap.out)

        #expect(promptsWhileBlocked == promptsBeforeFg)         // fg blocked the prompt
        #expect(promptsAfter > promptsWhileBlocked)             // returned after completion
    }

    /// Ctrl-C (SIGINT) routed through the foreground group interrupts the running
    /// command — not the shell, which recovers and re-prompts. `$?` reflects the
    /// signal (128 + SIGINT).
    @Test func ctrlCInterruptsForegroundCommand() async {
        let (loop, kernel, pty, cap) = makeShell()

        // `cat` with no args blocks reading stdin (the tty) — a foreground command
        // parked waiting, exactly what Ctrl-C should interrupt.
        pty.writeFromApp(Array("cat\n".utf8))
        await settle(loop)
        let promptsBefore = promptCount(cap.out)
        #expect(foregroundProcessIDs(kernel).count == 1)        // cat is the fg job

        // Consumer wiring: Ctrl-C -> interrupt the foreground group.
        kernel.interruptForeground(signal: Signal.sigint.rawValue)
        await settle(loop)

        #expect(promptCount(cap.out) > promptsBefore)           // shell recovered
        #expect(kernel.foregroundProcessGroupID == nil)         // foreground cleared

        // `$?` is 128 + SIGINT for a signal-terminated command.
        pty.writeFromApp(Array("echo $?\n".utf8))
        await settle(loop)
        #expect(contains(cap.out, Array("\(128 + Signal.sigint.rawValue)".utf8)))
    }

    @Test func foregroundPipelineUsesOneProcessGroup() async {
        let (loop, kernel, pty, _) = makeShell()

        pty.writeFromApp(Array("cat | cat\n".utf8))
        await settle(loop)

        let foregroundGroup = kernel.foregroundProcessGroupID
        let groupMembers = foregroundGroup.map { kernel.processIDs(inProcessGroup: $0) } ?? []

        #expect(groupMembers.count == 2)
        #expect(foregroundGroup != nil)
        for pid in groupMembers {
            #expect(kernel.process(pid)?.processGroupID == foregroundGroup)
        }

        kernel.interruptForeground(signal: Signal.sigint.rawValue)
        await settle(loop)

        #expect(kernel.foregroundProcessGroupID == nil)
        #expect(foregroundProcessIDs(kernel).isEmpty)
    }

    /// Ctrl-Z (SIGTSTP) stops the foreground job: the shell recovers, the job is
    /// listed as Stopped, and `bg` resumes it (SIGCONT) to run in the background
    /// to completion.
    @Test func ctrlZStopsThenBgResumesToCompletion() async {
        let (loop, kernel, pty, cap) = makeShell()

        pty.writeFromApp(Array("sleep 5\n".utf8))          // foreground sleep (parks on a timer)
        await settle(loop)
        #expect(foregroundProcessIDs(kernel).count == 1)
        let promptsBefore = promptCount(cap.out)

        kernel.interruptForeground(signal: Signal.sigtstp.rawValue)   // Ctrl-Z
        await settle(loop)
        #expect(promptCount(cap.out) > promptsBefore)      // shell recovered
        #expect(kernel.foregroundProcessGroupID == nil)    // foreground cleared
        #expect(contains(cap.out, Array("Stopped".utf8)))

        pty.writeFromApp(Array("jobs\n".utf8))
        await settle(loop)
        #expect(contains(cap.out, Array("Stopped".utf8)))  // still listed as stopped

        pty.writeFromApp(Array("bg 1\n".utf8))             // resume in background
        await settle(loop)

        loop.advance(by: 6.0)                              // let the resumed sleep finish
        await settle(loop)
        pty.writeFromApp(Array("jobs\n".utf8))             // prompt harvests the finished job
        await settle(loop)
        #expect(contains(cap.out, Array("Done".utf8)))
    }

    /// `fg` resumes a stopped job in the foreground and blocks until it finishes.
    @Test func ctrlZThenFgResumesToCompletion() async {
        let (loop, kernel, pty, cap) = makeShell()

        pty.writeFromApp(Array("sleep 5\n".utf8))
        await settle(loop)
        kernel.interruptForeground(signal: Signal.sigtstp.rawValue)
        await settle(loop)
        #expect(contains(cap.out, Array("Stopped".utf8)))

        pty.writeFromApp(Array("fg 1\n".utf8))             // back to the foreground
        await settle(loop)
        #expect(foregroundProcessIDs(kernel).count == 1)
        let promptsBefore = promptCount(cap.out)

        loop.advance(by: 6.0)                              // sleep completes in the foreground
        await settle(loop)
        #expect(promptCount(cap.out) > promptsBefore)      // prompt returned after completion
        #expect(kernel.foregroundProcessGroupID == nil)
    }

    // MARK: - Helpers

    final class Cap: @unchecked Sendable { var out: [UInt8] = [] }

    /// Returns the kernel so the caller retains it (the shell holds it `unowned`).
    /// Echo is off so the capture holds only prompts and command output.
    private func makeShell() -> (loop: EventLoop, kernel: Kernel, pty: PseudoTerminal, cap: Cap) {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        pty.echo = false
        let cap = Cap()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            cap.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        return (loop, kernel, pty, cap)
    }

    /// Drain executor jobs and any timers due *at the current logical time*
    /// (`advance(by: 0)`), without jumping ahead to future timers — so a pending
    /// `sleep` stays pending until the test explicitly advances time. Yields
    /// between passes so async continuations land as jobs.
    private func settle(_ loop: EventLoop, max: Int = 5000) async {
        var i = 0
        repeat {
            loop.advance(by: 0)
            await Task.yield()
            i += 1
        } while loop.pendingJobCount > 0 && i < max
    }

    private func promptCount(_ bytes: [UInt8]) -> Int {
        let needle = Array("root@swiftix:/# ".utf8)
        guard bytes.count >= needle.count else { return 0 }
        var count = 0
        for start in 0...(bytes.count - needle.count)
        where Array(bytes[start..<start + needle.count]) == needle {
            count += 1
        }
        return count
    }

    private func foregroundProcessIDs(_ kernel: Kernel) -> Set<PID> {
        guard let processGroupID = kernel.foregroundProcessGroupID else { return [] }
        return kernel.processIDs(inProcessGroup: processGroupID)
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
