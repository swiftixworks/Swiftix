import Testing
@testable import Swiftix

/// The pure-Swift regular-expression engine (`Regex`) and the `grep` / `man`
/// commands built on top of it. Regex behavior is checked directly; `grep` and
/// `man` are driven through a real shell and asserted on VFS output, so the
/// tests exercise the whole parse → match → filter pipeline deterministically.
@Suite("Regex engine + grep + man")
struct RegexGrepTests {

    // MARK: - Regex engine

    @Test func literalAndSubstringSearch() {
        #expect(Regex(pattern: "abc")!.matches("xabcy"))
        #expect(!Regex(pattern: "abc")!.matches("ab"))
        #expect(Regex(pattern: "abc")!.matches("abc"))
    }

    @Test func anchors() {
        #expect(Regex(pattern: "^abc")!.matches("abcdef"))
        #expect(!Regex(pattern: "^abc")!.matches("xabc"))
        #expect(Regex(pattern: "abc$")!.matches("xxabc"))
        #expect(!Regex(pattern: "abc$")!.matches("abcx"))
        #expect(Regex(pattern: "^$")!.matches(""))
        #expect(!Regex(pattern: "^$")!.matches("x"))
    }

    @Test func dotMatchesAnySingleCharacter() {
        #expect(Regex(pattern: "a.c")!.matches("axc"))
        #expect(!Regex(pattern: "^a.c$")!.matches("ac"))
    }

    @Test func quantifiers() {
        let star = Regex(pattern: "^ab*c$")!
        #expect(star.matches("ac"))
        #expect(star.matches("abc"))
        #expect(star.matches("abbbc"))
        #expect(!star.matches("adc"))

        let plus = Regex(pattern: "^ab+c$")!
        #expect(!plus.matches("ac"))
        #expect(plus.matches("abbc"))

        let optional = Regex(pattern: "^ab?c$")!
        #expect(optional.matches("ac"))
        #expect(optional.matches("abc"))
        #expect(!optional.matches("abbc"))
    }

    @Test func boundedRepetition() {
        let two = Regex(pattern: "^a{2}$")!
        #expect(two.matches("aa"))
        #expect(!two.matches("a"))
        #expect(!two.matches("aaa"))

        let range = Regex(pattern: "^a{2,3}$")!
        #expect(range.matches("aa"))
        #expect(range.matches("aaa"))
        #expect(!range.matches("aaaa"))

        let atLeast = Regex(pattern: "^a{2,}$")!
        #expect(atLeast.matches("aaaaa"))
        #expect(!atLeast.matches("a"))
    }

    @Test func characterClasses() {
        #expect(Regex(pattern: "[abc]")!.matches("x b y"))
        #expect(Regex(pattern: "^[a-z]+$")!.matches("hello"))
        #expect(!Regex(pattern: "^[a-z]+$")!.matches("Hello"))
        #expect(Regex(pattern: "[^0-9]")!.matches("12a34"))
        #expect(!Regex(pattern: "^[^0-9]+$")!.matches("12"))
    }

    @Test func predefinedClasses() {
        #expect(Regex(pattern: "\\d+")!.matches("abc123"))
        #expect(!Regex(pattern: "\\d")!.matches("abc"))
        #expect(Regex(pattern: "^\\w+$")!.matches("foo_bar9"))
        #expect(Regex(pattern: "\\s")!.matches("a b"))
        #expect(!Regex(pattern: "\\s")!.matches("ab"))
    }

    @Test func alternationAndGroups() {
        let animal = Regex(pattern: "cat|dog")!
        #expect(animal.matches("hotdog"))
        #expect(animal.matches("category"))
        #expect(!animal.matches("fish"))
        #expect(Regex(pattern: "^(ab)+$")!.matches("ababab"))
        #expect(!Regex(pattern: "^(ab)+$")!.matches("aba"))
    }

    @Test func ignoreCaseAndLiteralFactory() {
        #expect(Regex(pattern: "abc", ignoreCase: true)!.matches("XABCY"))
        #expect(Regex.literal("a.c").matches("a.c"))
        #expect(!Regex.literal("a.c").matches("axc"))     // '.' is literal here
    }

    @Test func malformedPatternsAreRejected() {
        #expect(Regex(pattern: "(") == nil)
        #expect(Regex(pattern: "[abc") == nil)
        #expect(Regex(pattern: "a)") == nil)
        #expect(Regex(pattern: "a{3,2}") == nil)
    }

    // MARK: - grep (through a real shell)

    @Test func grepFiltersByRegexIntoAFile() {
        let harness = ShellHarness()
        harness.run("seq 20 | grep '^1' > /a")
        #expect(harness.contents(of: "/a") == "1\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n")
    }

    @Test func grepAnchorAtEnd() {
        let harness = ShellHarness()
        harness.run("seq 25 | grep '2$' > /b")
        #expect(harness.contents(of: "/b") == "2\n12\n22\n")
    }

    @Test func grepInvertAndCount() {
        let harness = ShellHarness()
        harness.run("seq 5 | grep -v -c '3' > /c")     // lines NOT containing 3
        #expect(harness.contents(of: "/c") == "4\n")
    }

    @Test func grepIgnoreCaseAndLineNumbers() {
        let harness = ShellHarness()
        harness.run("printf 'Apple\\nbanana\\nAVOCADO\\n' > /fruit")
        harness.run("grep -in a /fruit > /d")
        // Lines containing 'a' (case-insensitive), prefixed with 1-based numbers.
        #expect(harness.contents(of: "/d") == "1:Apple\n2:banana\n3:AVOCADO\n")
    }

    @Test func grepFixedStringTreatsPatternLiterally() {
        let harness = ShellHarness()
        harness.run("printf 'a.c\\naxc\\n' > /fx")
        harness.run("grep -F 'a.c' /fx > /e")
        #expect(harness.contents(of: "/e") == "a.c\n")   // the regex '.' would also match axc
    }

    @Test func grepBraceRepetition() {
        let harness = ShellHarness()
        harness.run("seq 20 | grep '.{2}' > /g")         // lines with at least two characters
        #expect(harness.contents(of: "/g") == "10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n")
    }

    // MARK: - sed

    @Test func sedSubstitutesFirstMatchByDefault() {
        let harness = ShellHarness()
        harness.run("printf 'aaa\\n' | sed 's/a/b/' > /s1")
        #expect(harness.contents(of: "/s1") == "baa\n")
    }

    @Test func sedGlobalFlagReplacesAll() {
        let harness = ShellHarness()
        harness.run("printf 'aaa\\n' | sed 's/a/b/g' > /s2")
        #expect(harness.contents(of: "/s2") == "bbb\n")
    }

    @Test func sedAmpersandInsertsMatchedText() {
        let harness = ShellHarness()
        harness.run("printf 'cat\\n' | sed 's/cat/[&]/' > /s3")
        #expect(harness.contents(of: "/s3") == "[cat]\n")
    }

    @Test func sedIgnoreCaseFlag() {
        let harness = ShellHarness()
        harness.run("printf 'CAT\\n' | sed 's/cat/dog/i' > /s4")
        #expect(harness.contents(of: "/s4") == "dog\n")
    }

    @Test func sedAlternateDelimiter() {
        let harness = ShellHarness()
        harness.run("printf '/usr/bin\\n' | sed 's|/|_|g' > /s5")
        #expect(harness.contents(of: "/s5") == "_usr_bin\n")
    }

    @Test func sedRegexClassSubstitution() {
        let harness = ShellHarness()
        harness.run("printf 'a1b2c3\\n' | sed 's/[0-9]/#/g' > /s6")
        #expect(harness.contents(of: "/s6") == "a#b#c#\n")
    }

    @Test func sedSuppressedOutputPrintsOnlySubstitutedLines() {
        let harness = ShellHarness()
        harness.run("printf 'a\\nb\\na\\n' | sed -n 's/a/X/p' > /s7")
        #expect(harness.contents(of: "/s7") == "X\nX\n")
    }

    // MARK: - man

    @Test func manShowsACommandsManualPage() {
        let harness = ShellHarness()
        harness.run("man ls > /m")
        let page = harness.contents(of: "/m")
        #expect(page.contains("NAME"))
        #expect(page.contains("ls - "))
        #expect(page.contains("DESCRIPTION"))
    }

    @Test func manReportsUnknownCommand() {
        let harness = ShellHarness()
        harness.clearOutput()
        harness.run("man definitelynotacommand")     // error goes to stderr (the tty)
        #expect(harness.output().contains("no manual entry"))
    }

    // MARK: - Harness

    /// Boots a kernel + pty + interactive shell (echo off), runs command lines,
    /// and reads resulting files back out of the VFS for exact assertions.
    private final class ShellHarness {
        let loop = EventLoop()
        let kernel: Kernel
        let pty = PseudoTerminal()

        private var captured: [UInt8] = []

        init() {
            kernel = Kernel(loop: loop)
            pty.echo = false
            pty.onOutput = { [weak self, weak pty] in
                guard let self, let pty else { return }
                self.captured.append(contentsOf: pty.readForApp(max: 65_535))
            }
            kernel.spawn("sh", Programs.shell(tty: pty.slave))
            loop.runUntilIdle()
        }

        /// Reset the captured console output (drop prompts/output seen so far).
        func clearOutput() { captured.removeAll() }

        /// The console output (stdout + stderr, both wired to the tty) captured
        /// since the last `clearOutput`.
        func output() -> String { String(decoding: captured, as: UTF8.self) }

        func run(_ line: String) {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }

        func contents(of path: String) -> String {
            final class Box { var text: String? }
            let box = Box()
            kernel.spawn("read") { ctx in
                if let fd = ctx.open(path) {
                    box.text = String(decoding: ctx.read(fd, max: 1 << 20), as: UTF8.self)
                    ctx.close(fd)
                }
                ctx.exit(0)
            }
            loop.runUntilIdle()
            return box.text ?? "<missing>"
        }
    }
}
