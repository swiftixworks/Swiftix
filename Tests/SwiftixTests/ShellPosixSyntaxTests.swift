import Testing
@testable import Swiftix

/// POSIX shell grammar driven through a real shell: here-strings, `&` as a
/// separator, `until`, `!`, subshells, groups, `elif`, comments, line
/// continuation, and and-or lists nested in compound commands.
@Suite("Shell POSIX syntax")
struct ShellPosixSyntaxTests {

    @Test func hereStringFeedsStdinAndDoesNotHang() {
        let h = ShellScriptHarness()
        #expect(h.output("cat <<< \"x y\"") == "x y\n")
        // The shell is back at its prompt and still takes commands.
        #expect(h.output("echo after") == "after\n")
    }

    @Test func hereStringExpandsVariables() {
        let h = ShellScriptHarness()
        h.run("v=hello")
        #expect(h.output("cat <<< $v") == "hello\n")
    }

    @Test func commandAfterBackgroundOnSameLine() {
        let h = ShellScriptHarness()
        let text = h.output("sleep 1 & jobs")
        #expect(text.contains("[1]"))
        #expect(text.contains("Running"))
        #expect(!text.contains("syntax error"))
    }

    @Test func twoBackgroundCommandsOnOneLine() {
        let h = ShellScriptHarness()
        let text = h.output("sleep 1 & sleep 2 &")
        #expect(text.contains("[1]"))
        #expect(text.contains("[2]"))
    }

    @Test func untilLoopRunsUntilConditionSucceeds() {
        let h = ShellScriptHarness()
        #expect(h.output("i=0; until [ $i -ge 3 ]; do echo $i; i=$((i+1)); done") == "0\n1\n2\n")
    }

    @Test func bangNegatesPipelineStatus() {
        let h = ShellScriptHarness()
        #expect(h.output("! false; echo $?") == "0\n")
        #expect(h.output("! true; echo $?") == "1\n")
        #expect(h.output("if ! false; then echo yes; fi") == "yes\n")
        #expect(h.output("! echo a | grep b; echo $?") == "0\n")
    }

    @Test func subshellDoesNotLeakDirectoryOrVariables() {
        let h = ShellScriptHarness()
        h.run("mkdir -p /sub/dir; cd /; x=outer")
        #expect(h.output("(cd /sub/dir; x=inner; pwd; echo $x)") == "/sub/dir\ninner\n")
        #expect(h.output("pwd; echo $x") == "/\nouter\n")
    }

    @Test func subshellExitStatusAndExitAreContained() {
        let h = ShellScriptHarness()
        #expect(h.output("(exit 7); echo $?") == "7\n")
        #expect(h.shellIsRunning)
    }

    @Test func groupRunsInCurrentShell() {
        let h = ShellScriptHarness()
        #expect(h.output("{ x=1; echo a; }; echo $x") == "a\n1\n")
    }

    @Test func groupCanBeRedirectedAndPiped() {
        let h = ShellScriptHarness()
        h.run("{ echo one; echo two; } > /g")
        #expect(h.contents(of: "/g") == "one\ntwo\n")
        #expect(h.output("{ echo b; echo a; } | sort") == "a\nb\n")
        #expect(h.output("(echo y; echo x) | sort") == "x\ny\n")
    }

    @Test func compoundCommandAsPipelineStage() {
        let h = ShellScriptHarness()
        #expect(h.output("printf 'a\\nb\\n' | while read l; do echo \"<$l>\"; done") == "<a>\n<b>\n")
        #expect(h.output("for i in 1 2 3; do echo $i; done | rev | cat") == "1\n2\n3\n")
    }

    @Test func elifChain() {
        let h = ShellScriptHarness()
        let script = "if [ $n = 1 ]; then echo one; elif [ $n = 2 ]; then echo two; elif [ $n = 3 ]; then echo three; else echo many; fi"
        h.run("n=1"); #expect(h.output(script) == "one\n")
        h.run("n=2"); #expect(h.output(script) == "two\n")
        h.run("n=3"); #expect(h.output(script) == "three\n")
        h.run("n=9"); #expect(h.output(script) == "many\n")
    }

    @Test func commentsAreIgnored() {
        let h = ShellScriptHarness()
        #expect(h.output("echo a # trailing comment") == "a\n")
        #expect(h.output("# whole line") == "")
        #expect(h.output("echo a#b") == "a#b\n")
    }

    @Test func backslashNewlineContinuesTheLine() {
        let h = ShellScriptHarness()
        h.run("echo one \\")
        #expect(h.output("two") == "one two\n")
    }

    @Test func andOrListsInsideLoopsAndIfs() {
        let h = ShellScriptHarness()
        #expect(h.output("for i in 1 2 3; do [ $i = 2 ] && echo hit || echo miss; done") == "miss\nhit\nmiss\n")
        #expect(h.output("if true && false || true; then echo ok; fi") == "ok\n")
    }

    @Test func whileReadLineFromRedirectedFile() {
        let h = ShellScriptHarness()
        h.write("/lines", "alpha\nbeta gamma\n\nlast\n")
        #expect(h.output("while read line; do echo \"[$line]\"; done < /lines")
                == "[alpha]\n[beta gamma]\n[]\n[last]\n")
    }

    @Test func forWithoutInIteratesPositionalParameters() {
        let h = ShellScriptHarness()
        h.run("f() { for x; do echo \"<$x>\"; done; }")
        #expect(h.output("f a 'b c' d") == "<a>\n<b c>\n<d>\n")
    }

    @Test func backtickCommandSubstitution() {
        let h = ShellScriptHarness()
        #expect(h.output("echo `echo hi` there") == "hi there\n")
        #expect(h.output("x=`printf 'a b'`; echo \"$x\"") == "a b\n")
    }

    @Test func commandSubstitutionRunsInSubshell() {
        let h = ShellScriptHarness()
        h.run("cd /; v=1")
        #expect(h.output("echo $(mkdir -p /elsewhere; cd /elsewhere; v=2; echo in)") == "in\n")
        #expect(h.output("pwd; echo $v") == "/\n1\n")
        #expect(h.output("x=$(exit 3); echo $?") == "3\n")
    }

    @Test func multiLineCompoundAtThePrompt() {
        let h = ShellScriptHarness()
        h.run("if true")
        h.run("then")
        h.run("  echo yes")
        #expect(h.output("fi") == "yes\n")
        h.run("f() {")
        h.run("  echo body")
        h.run("}")
        #expect(h.output("f") == "body\n")
    }

    @Test func hereDocumentWithCommandAfterIt() {
        let h = ShellScriptHarness()
        h.run("v=7")
        h.run("cat <<EOF")
        h.run("value $v")
        #expect(h.output("EOF") == "value 7\n")
        h.run("cat <<'EOF' | rev")
        h.run("raw $v")
        #expect(h.output("EOF") == "v$ war\n")
    }

    @Test func redirectionOrderFollowsPosix() {
        let h = ShellScriptHarness()
        h.run("{ echo out; echo err >&2; } > /both 2>&1")
        #expect(h.contents(of: "/both") == "out\nerr\n")
    }

    @Test func caseWithQuotedAndAlternativePatterns() {
        let h = ShellScriptHarness()
        #expect(h.output("case abc in a*) echo glob;; *) echo other;; esac") == "glob\n")
        #expect(h.output("case 'a*' in 'a*') echo literal;; esac") == "literal\n")
        #expect(h.output("case abc in 'a*') echo literal;; x|abc) echo alt;; esac") == "alt\n")
    }

    @Test func whileLoopStatusIsLastBodyStatus() {
        let h = ShellScriptHarness()
        #expect(h.output("while false; do :; done; echo $?") == "0\n")
    }

    @Test func longBuiltinOnlyLoopDoesNotOverflow() {
        let h = ShellScriptHarness()
        #expect(h.output("i=0; while :; do i=$((i+1)); case $i in 20000) break;; esac; done; echo $i") == "20000\n")
    }

    @Test func syntaxErrorIsReportedAndShellSurvives() {
        let h = ShellScriptHarness()
        #expect(h.output("echo a | | echo b").contains("syntax error"))
        #expect(h.output("echo ok") == "ok\n")
    }
}

/// Pure lexer / completeness / expansion-helper behavior, without a kernel.
@Suite("Shell lexer and expansion helpers")
struct ShellLexerTests {

    @Test func completenessTracksOpenConstructs() {
        #expect(Programs.isComplete("echo hi\n"))
        #expect(!Programs.isComplete("if true; then\n"))
        #expect(Programs.isComplete("if true; then echo; fi\n"))
        #expect(!Programs.isComplete("while read x\n"))
        #expect(!Programs.isComplete("until false; do\n"))
        #expect(!Programs.isComplete("f() {\n"))
        #expect(!Programs.isComplete("( echo a\n"))
        #expect(Programs.isComplete("( echo a )\n"))
        #expect(!Programs.isComplete("echo a &&\n"))
        #expect(!Programs.isComplete("echo a |\n"))
        #expect(!Programs.isComplete("echo \"open\n"))
        #expect(!Programs.isComplete("echo $(echo a\n"))
        #expect(!Programs.isComplete("echo a \\\n"))
        #expect(!Programs.isComplete("cat <<EOF\nbody\n"))
        #expect(Programs.isComplete("cat <<EOF\nbody\nEOF\n"))
        #expect(!Programs.isComplete("case x in\n"))
        #expect(Programs.isComplete("case x in a) echo;; esac\n"))
    }

    @Test func reservedWordsAsArgumentsDoNotOpenBlocks() {
        #expect(Programs.isComplete("echo if while for case {\n"))
        #expect(Programs.isComplete("for x in if do done; do echo; done\n"))
        #expect(Programs.isComplete("echo done fi esac }\n"))
    }

    @Test func hereStringIsNotAHereDocument() {
        #expect(Programs.isComplete("cat <<< \"x\"\n"))
        #expect(Programs.lex("cat <<< x") == [.word("cat"), .hereString(fd: 0), .word("x")])
    }

    @Test func hereDocumentBodyIsCollectedIntoItsToken() {
        let tokens = Programs.lex("cat <<-E > out\n\tone\n\tE\necho next\n")
        #expect(tokens == [.word("cat"), .hereDocument(fd: 0, body: "one\n", expand: true),
                           .redirectFile(fd: 1, append: false), .word("out"), .semicolon,
                           .word("echo"), .word("next"), .semicolon])
    }

    @Test func commentsAndContinuationsAreRemoved() {
        #expect(Programs.lex("a # b c\nd \\\ne") == [.word("a"), .semicolon, .word("d"), .word("e")])
        #expect(Programs.lex("echo '#' a#b") == [.word("echo"), .word("'#'"), .word("a#b")])
    }

    @Test func substitutionsStayOneWord() {
        #expect(Programs.lex("echo $(a | b; c) `d e` ${x:-y z} \"q $(r \"s t\")\"")
                == [.word("echo"), .word("$(a | b; c)"), .word("`d e`"), .word("${x:-y z}"),
                    .word("\"q $(r \"s t\")\"")])
    }

    @Test func braceExpansionIsPure() {
        #expect(Programs.braceExpand("a{b,c}d") == ["abd", "acd"])
        #expect(Programs.braceExpand("{1..3}") == ["1", "2", "3"])
        #expect(Programs.braceExpand("{1..7..3}") == ["1", "4", "7"])
        #expect(Programs.braceExpand("${a,b}") == ["${a,b}"])
        #expect(Programs.braceExpand("\"{a,b}\"") == ["\"{a,b}\""])
        #expect(Programs.braceExpand("{a,{b,c}}") == ["a", "b", "c"])
    }

    @Test func commandSubstitutionDiscovery() {
        #expect(Programs.commandSubstitutions(in: "a$(b)c\"$(d e)\"'$(f)'`g`") == ["b", "d e", "g"])
        #expect(Programs.commandSubstitutions(in: "$((1 + $(h)))") == ["h"])
        #expect(Programs.commandSubstitutions(in: "$(outer $(inner))") == ["outer $(inner)"])
    }

    @Test func arithmeticNeverTrapsOnOverflowOrZeroDivision() {
        func eval(_ text: String) -> Int {
            Programs.evaluateArithmetic(text, lookup: { _ in nil }, assign: { _, _ in })
        }
        #expect(eval("1 / 0") == 0)
        #expect(eval("1 % 0") == 0)
        #expect(eval("9223372036854775807 + 1") == Int.min)
        #expect(eval("2 ** 64") == 0)
        #expect(eval("1 << 70") == 64)
        #expect(eval("(1 + 2) * 3 - 4 / 2") == 7)
        #expect(eval("") == 0)
        #expect(eval("1 +") == 1)
    }
}
