import Testing
@testable import Swiftix

/// Shell control flow: `;` sequencing, `&&`/`||` short-circuit, `if`/`while`
/// (single- and multi-line), and the `test`/`[`/`expr` predicates they branch
/// on. Drives the real shell over a pty.
///
/// The pty echoes typed input, so a marker like `echo YES` appears once from the
/// echo regardless of whether it ran. Assertions therefore count *occurrences*:
/// a marker that ran appears at least twice (echo + program output); one that
/// was skipped appears exactly once (the input echo only).
@Suite("Shell control flow")
struct ShellControlTests {

    // MARK: - test / [ / expr

    @Test func exprEvaluatesArithmetic() {
        #expect(count(run(["expr 2 + 3"]), "5\n") >= 1)     // "5" is not in the input
        #expect(count(run(["expr 6 / 2"]), "3\n") >= 1)
    }

    @Test func testDrivesAndOr() {
        #expect(count(run(["test 1 -eq 1 && echo EQ"]), "EQ") >= 2)     // ran
        #expect(count(run(["test 1 -eq 2 && echo EQ"]), "EQ") == 1)     // skipped
        #expect(count(run(["[ -n x ] && echo NONEMPTY"]), "NONEMPTY") >= 2)
    }

    // MARK: - && / ||

    @Test func andRunsOnlyAfterSuccess() {
        #expect(count(run(["true && echo YES"]), "YES") >= 2)
        #expect(count(run(["false && echo NO"]), "NO") == 1)
    }

    @Test func orRunsOnlyAfterFailure() {
        #expect(count(run(["false || echo RECOVER"]), "RECOVER") >= 2)
        #expect(count(run(["true || echo SKIP"]), "SKIP") == 1)
    }

    // MARK: - ; sequencing

    @Test func semicolonRunsBothStatements() {
        let out = run(["echo one ; echo two"])
        #expect(count(out, "one") >= 2)
        #expect(count(out, "two") >= 2)
    }

    // MARK: - if / then / else / fi

    @Test func ifTrueRunsThenBranch() {
        let out = run(["if true; then echo THEN; else echo ELSE; fi"])
        #expect(count(out, "THEN") >= 2)   // ran
        #expect(count(out, "ELSE") == 1)   // skipped
    }

    @Test func ifFalseRunsElseBranch() {
        let out = run(["if false; then echo THEN; else echo ELSE; fi"])
        #expect(count(out, "ELSE") >= 2)
        #expect(count(out, "THEN") == 1)
    }

    @Test func ifBranchesOnCommandStatus() {
        // Condition is a real command (`test`) whose exit status selects the branch.
        #expect(count(run(["if test 3 -gt 2; then echo BIG; fi"]), "BIG") >= 2)
    }

    @Test func multiLineIfIsBufferedUntilComplete() {
        // Each line is incomplete until `fi`; the shell keeps reading (`> `).
        #expect(count(run(["if true", "then echo MULTI", "fi"]), "MULTI") >= 2)
    }

    // MARK: - while / do / done

    @Test func whileRunsBodyThenReevaluatesCondition() {
        // Seed a flag; the loop runs once, removes it, and the re-checked
        // condition is then false — proving both body execution and re-evaluation.
        let out = run(["while [ -e /flag ]; do echo TICK; rm /flag; done"], seed: { ctx in
            let fd = ctx.open("/flag", create: true)!
            ctx.close(fd)
        })
        #expect(count(out, "TICK") >= 2)
    }

    @Test func whileFalseNeverRunsBody() {
        #expect(count(run(["while false; do echo NEVER; done"]), "NEVER") == 1)
    }

    @Test func commandAfterWhileStillRuns() {
        let out = run(["while [ -e /g ]; do rm /g; done", "echo DONE2"], seed: { ctx in
            let fd = ctx.open("/g", create: true)!
            ctx.close(fd)
        })
        #expect(count(out, "DONE2") >= 2)
    }

    // MARK: - Helpers

    private final class Capture { var out: [UInt8] = [] }

    private func run(_ lines: [String], seed: ((ProcessContext) -> Void)? = nil) -> [UInt8] {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        if let seed {
            kernel.spawn("seed") { ctx in seed(ctx); ctx.exit(0) }
            loop.runUntilIdle()
        }
        let pty = PseudoTerminal()
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        for line in lines {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }
        return captured.out
    }

    private func count(_ haystack: [UInt8], _ needleString: String) -> Int {
        let needle = Array(needleString.utf8)
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var total = 0
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            total += 1
        }
        return total
    }
}
