import Testing

@testable import Swiftix

/// The `-` operand convention: a filter's file list may name standard input with a
/// bare `-`, mixed freely with real files and repeatable.
///
/// This used to be unsupported across the whole built-in filter set —
/// `CoreutilsSupport.collectInput` read stdin only when the file list was *empty*, so
/// a `-` operand fell through to `open("-")` and reported "No such file". `cut` was
/// worse: its option loop had no guard against a bare `-`, so `-` was parsed as an
/// unknown option and became a usage error.
///
/// The tests drive the real shell over a pseudo-terminal and feed stdin with a
/// pipeline, so they exercise the same path a user does.
@Suite("`-` names standard input")
struct DashStdinOperandTests {

    // MARK: - cut, the command whose option loop swallowed `-`

    @Test func cutReadsStandardInputForDashOperand() {
        let out = runShell(["echo a:b:c | cut -d : -f 2 -"])
        #expect(contains(out, Array("\nb\n".utf8)))
        // The old behaviour was a usage error rather than a read.
        #expect(!contains(out, Array("usage: cut".utf8)))
    }

    // MARK: - ordering and mixing

    /// `cmd file -` reads the file first and standard input second, so the operand
    /// order is what determines the concatenation order.
    @Test func dashIsReadInOperandOrderAfterAFile() {
        let out = runShell(["echo zzz | head -n 100 /nums -"], seed: seedNums)
        #expect(contains(out, Array("1\n2\n3\n4\n5\nzzz\n".utf8)))
    }

    /// ...and `cmd - file` reads standard input first.
    @Test func dashIsReadInOperandOrderBeforeAFile() {
        let out = runShell(["echo aaa | head -n 100 - /nums"], seed: seedNums)
        #expect(contains(out, Array("aaa\n1\n2\n3\n4\n5\n".utf8)))
    }

    /// A `-` may appear more than once; standard input is simply exhausted by the
    /// first one, and the later ones contribute nothing rather than failing.
    @Test func repeatedDashOperandsDoNotFail() {
        let out = runShell(["echo once | head -n 100 - -"])
        #expect(contains(out, Array("once\n".utf8)))
        #expect(!contains(out, Array("No such file".utf8)))
    }

    // MARK: - the whole filter set shares one input path

    @Test func everyFilterOverCollectInputAcceptsDash() {
        // grep / sort / uniq / rev / nl / tail / sed all route through
        // `CoreutilsSupport.collectInput`, so one fix covers them.
        #expect(contains(runShell(["echo banana | grep ban -"]),
                         Array("banana".utf8)))
        #expect(contains(runShell(["echo aaa | sort -"]),
                         Array("aaa".utf8)))
        #expect(contains(runShell(["echo dup | uniq -"]),
                         Array("dup".utf8)))
        #expect(contains(runShell(["echo abc | rev -"]),
                         Array("cba".utf8)))
        #expect(contains(runShell(["echo line | nl -"]),
                         Array("line".utf8)))
        #expect(contains(runShell(["echo last | tail -n 1 -"]),
                         Array("last".utf8)))
        #expect(contains(runShell(["echo x | sed s/x/y/ -"]),
                         Array("y".utf8)))
    }

    // MARK: - a real missing file is still an error

    /// `-` is special-cased, not a blanket relaxation: a genuinely missing operand
    /// still reports and still sets a non-zero status, and the `-` beside it is
    /// still read.
    @Test func missingFileStillReportsWhileDashStillReads() {
        // `rev` is used so the expected output ("cba") cannot also come from the
        // echoed command line, which contains "abc". Asserting on text that appears
        // in the typed command proves nothing here.
        let out = runShell(["echo abc | rev /absent -", "echo $?"])
        #expect(contains(out, Array("/absent: No such file".utf8)))
        #expect(contains(out, Array("cba".utf8)))
        #expect(contains(out, Array("\n1\n".utf8)))   // non-zero exit status
    }

    // MARK: - helpers

    private func seedNums(_ ctx: ProcessContext) {
        let fd = ctx.open("/nums", create: true)!
        ctx.write(fd, Array("1\n2\n3\n4\n5\n".utf8))
        ctx.close(fd)
    }

    /// Build a kernel + shell on a pty, optionally seed the VFS, write each command
    /// line, and return everything the pty emitted.
    private func runShell(_ lines: [String],
                          seed: ((ProcessContext) -> Void)? = nil) -> [UInt8] {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        if let seed {
            kernel.spawn("seed") { ctx in seed(ctx); ctx.exit(0) }
            loop.runUntilIdle()
        }
        let pty = PseudoTerminal()
        var captured: [UInt8] = []
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.append(contentsOf: pty.readForApp(max: 65535))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        for line in lines {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }
        return captured
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
