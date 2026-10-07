import Testing
@testable import Swiftix

/// Running shell scripts: the `sh` command (`sh FILE`, `sh -c`, script on
/// stdin), directly executed script files (shebang or plain text, by path or
/// through `$PATH`), whole-file parsing, `exit`, and `set -e`.
@Suite("Shell script execution")
struct ShellScriptExecutionTests {

    @Test func shRunsAFileWithPositionalParameters() {
        let h = ShellScriptHarness()
        h.write("/s.sh", "echo \"$0 $# $1 $2\"\n")
        #expect(h.output("sh /s.sh one 'two three'") == "/s.sh 2 one two three\n")
    }

    @Test func shDashCRunsAStringWithArguments() {
        let h = ShellScriptHarness()
        #expect(h.output("sh -c 'echo $0-$1-$2' name a b") == "name-a-b\n")
        #expect(h.output("sh -c 'exit 6'; echo $?") == "6\n")
        #expect(h.output("sh -c 'echo $$'") != h.output("echo $$"))
    }

    @Test func shReadsAScriptFromStandardInput() {
        let h = ShellScriptHarness()
        #expect(h.output("echo 'echo piped $((2+3))' | sh") == "piped 5\n")
        h.write("/in.sh", "x=4\necho stdin $x\n")
        #expect(h.output("sh < /in.sh") == "stdin 4\n")
    }

    @Test func missingScriptFileFails() {
        let h = ShellScriptHarness()
        let text = h.output("sh /nope.sh; echo $?")
        #expect(text.contains("No such file"))
        #expect(text.hasSuffix("127\n"))
    }

    @Test func executableScriptRunsByPathWithShebang() {
        let h = ShellScriptHarness()
        h.write("/x.sh", "#!/bin/sh\necho \"ran $1 as $0\"\n")
        let denied = h.output("/x.sh arg; echo $?")
        #expect(denied.contains("Permission denied"))
        #expect(denied.hasSuffix("126\n"))
        h.run("chmod 755 /x.sh")
        #expect(h.output("/x.sh arg") == "ran arg as /x.sh\n")
        #expect(h.output("cd /; ./x.sh rel") == "ran rel as ./x.sh\n")
    }

    @Test func otherShellShebangsAndNoShebangRunThroughTheShell() {
        let h = ShellScriptHarness()
        h.write("/env.sh", "#!/usr/bin/env sh\necho env-sh\n", executable: true)
        h.write("/bash.sh", "#!/bin/bash\necho bash-sh\n", executable: true)
        h.write("/plain", "echo plain-text $1\n", executable: true)
        #expect(h.output("/env.sh") == "env-sh\n")
        #expect(h.output("/bash.sh") == "bash-sh\n")
        #expect(h.output("/plain x") == "plain-text x\n")
    }

    @Test func shebangNamingAnotherCommandRunsThatCommand() {
        let h = ShellScriptHarness()
        h.write("/show", "#!/bin/cat\nbody line\n", executable: true)
        #expect(h.output("/show") == "#!/bin/cat\nbody line\n")
    }

    @Test func scriptIsFoundThroughPath() {
        let h = ShellScriptHarness()
        h.run("mkdir -p /opt/bin")
        h.write("/opt/bin/greet", "#!/bin/sh\necho hello $1\n", executable: true)
        h.run("PATH=/opt/bin:$PATH")
        #expect(h.output("greet world") == "hello world\n")
        #expect(h.output("type greet") == "greet is /opt/bin/greet\n")
    }

    @Test func multiLineScriptWithCompoundCommandsFunctionsAndHereDocs() {
        let h = ShellScriptHarness()
        h.write("/multi.sh", """
        #!/bin/sh
        # A whole-file script.
        greet() {
            echo "hi $1"
        }

        count=0
        for name in a b \\
                    c
        do
            if [ "$name" = b ]; then
                continue
            elif [ "$name" = c ]; then
                greet "$name"
            else
                greet first
            fi
            count=$((count + 1))
        done

        while [ $count -lt 4 ]
        do
            count=$((count + 1))
        done

        case "$1" in
            start|go)
                echo starting
                ;;
            *)
                echo unknown
                ;;
        esac

        cat <<EOF
        count=$count
        literal \\$HOME
        EOF
        cat <<'RAW'
        $count stays
        RAW
        echo done

        """)
        #expect(h.output("sh /multi.sh go")
                == "hi first\nhi c\nstarting\ncount=4\nliteral $HOME\n$count stays\ndone\n")
    }

    @Test func exitEndsOnlyTheScript() {
        let h = ShellScriptHarness()
        h.write("/e.sh", "echo before\nexit 9\necho after\n")
        #expect(h.output("sh /e.sh; echo $?") == "before\n9\n")
        #expect(h.shellIsRunning)
    }

    @Test func scriptStateDoesNotLeakIntoTheCaller() {
        let h = ShellScriptHarness()
        h.write("/leak.sh", "cd /\nleaked=1\n")
        h.run("mkdir -p /here; cd /here")
        h.run("sh /leak.sh")
        #expect(h.output("pwd; echo [$leaked]") == "/here\n[]\n")
    }

    @Test func errexitStopsAtTheFirstFailingCommand() {
        let h = ShellScriptHarness()
        h.write("/e.sh", "set -e\necho one\nfalse\necho two\n")
        #expect(h.output("sh /e.sh; echo $?") == "one\n1\n")
        #expect(h.output("sh -e -c 'echo a; false; echo b'; echo $?") == "a\n1\n")
    }

    @Test func errexitIgnoresTestedCommands() {
        let h = ShellScriptHarness()
        h.write("/t.sh", """
        set -e
        if false; then echo no; fi
        false || echo recovered
        ! true
        false && echo skipped
        while false; do :; done
        echo survived

        """)
        #expect(h.output("sh /t.sh; echo $?") == "recovered\nsurvived\n0\n")
    }

    @Test func syntaxErrorInAScriptRunsEarlierCommandsThenFails() {
        let h = ShellScriptHarness()
        h.write("/bad.sh", "echo early\nif true; then\n")
        let text = h.output("sh /bad.sh; echo $?")
        #expect(text.hasPrefix("early\n"))
        #expect(text.contains("syntax error"))
        #expect(text.hasSuffix("2\n"))
    }

    @Test func nestedScriptsAndFunctionsShareNothingButExports() {
        let h = ShellScriptHarness()
        h.write("/inner.sh", "echo inner:$SHARED:$private\n")
        h.write("/outer.sh", "export SHARED=yes\nprivate=no\nsh /inner.sh\n")
        #expect(h.output("sh /outer.sh") == "inner:yes:\n")
    }

    @Test func nestedInteractiveShellReturnsToTheParent() {
        let h = ShellScriptHarness()
        h.run("outer=1")
        h.run("sh")
        #expect(h.output("echo [$outer]") == "[]\n")
        h.run("exit")
        #expect(h.shellIsRunning)
        #expect(h.output("echo [$outer]") == "[1]\n")
    }

    @Test func shIsListedAsACommand() {
        let h = ShellScriptHarness()
        #expect(h.output("type sh") == "sh is a builtin\n")
    }
}

/// Edge cases around launching, redirection errors, and large substitutions.
@Suite("Shell script execution edge cases")
struct ShellScriptEdgeCaseTests {

    @Test func controlDAbandonsAnUnfinishedCommand() {
        let h = ShellScriptHarness()
        h.run("echo \"never closed")
        h.pty.writeFromApp([0x04])
        h.loop.runUntilIdle()
        #expect(h.shellIsRunning)
        #expect(h.output("echo back") == "back\n")
    }

    @Test func multiChunkCommandSubstitutionIsCapturedWhole() {
        let h = ShellScriptHarness()
        // ~24 KB of output: several reads of the capture pipe.
        #expect(h.output("x=$(seq 1 5000); echo ${#x}") == "23892\n")
        #expect(h.output("for i in $(seq 1 300); do n=$i; done; echo $n") == "300\n")
    }

    @Test func missingInputFileFailsTheCommand() {
        let h = ShellScriptHarness()
        let text = h.output("cat < /no/such/file; echo $?")
        #expect(text.contains("/no/such/file: No such file or directory"))
        #expect(text.hasSuffix("1\n"))
    }

    @Test func binaryAndEmptyExecutablesAreNotRunAsScripts() {
        let h = ShellScriptHarness()
        h.write("/empty", "", executable: true)
        h.write("/binary", "\u{0}\u{1}\u{2}ELF", executable: true)
        #expect(h.output("/empty; echo $?").hasSuffix("126\n"))
        #expect(h.output("/binary; echo $?").hasSuffix("126\n"))
        #expect(h.output("/missing; echo $?").hasSuffix("127\n"))
    }

    @Test func badInterpreterIsReported() {
        let h = ShellScriptHarness()
        h.write("/odd", "#!/no/such/interp\necho no\n", executable: true)
        let text = h.output("/odd; echo $?")
        #expect(text.contains("bad interpreter"))
        #expect(text.hasSuffix("126\n"))
    }

    @Test func xtraceOptionOnTheCommandLine() {
        let h = ShellScriptHarness()
        #expect(h.output("sh -x -c 'v=1; echo $v'") == "+ v=1\n+ echo 1\n1\n")
    }

    @Test func nounsetEndsAScript() {
        let h = ShellScriptHarness()
        let text = h.output("sh -u -c 'echo $nope; echo not-reached'; echo $?")
        #expect(text.contains("nope: unbound variable"))
        #expect(!text.contains("not-reached"))
        #expect(text.hasSuffix("1\n"))
    }

    @Test func interruptTrapInAScript() {
        let h = ShellScriptHarness()
        h.write("/int.sh", "trap 'echo interrupted; exit 3' INT\necho ready\nwhile :; do sleep 1; done\n")
        h.run("sh /int.sh > /int.out &")
        h.run("kill -INT $!")
        h.advance(by: 2)
        #expect(h.contents(of: "/int.out") == "ready\ninterrupted\n")
    }

    @Test func recursiveFunctionAndHereDocInsideFunction() {
        let h = ShellScriptHarness()
        h.write("/fact.sh", """
        fact() {
            if [ $1 -le 1 ]; then
                echo 1
            else
                echo $(( $1 * $(fact $(( $1 - 1 ))) ))
            fi
        }
        show() {
            cat <<EOF
        fact($1)=$(fact $1)
        EOF
        }
        show 5
        show 10

        """)
        #expect(h.output("sh /fact.sh") == "fact(5)=120\nfact(10)=3628800\n")
    }

    @Test func backgroundJobsInAScriptAndWait() {
        let h = ShellScriptHarness()
        h.write("/bg.sh", "sleep 2 &\nfirst=$!\nsleep 1 &\nwait $first\necho waited $?\nwait\necho all\n")
        h.run("sh /bg.sh > /bg.out &")
        h.advance(by: 3)
        #expect(h.contents(of: "/bg.out") == "waited 0\nall\n")
    }

    @Test func aliasDefinedEarlierInAScriptApplies() {
        let h = ShellScriptHarness()
        h.write("/alias.sh", "alias say='echo said'\nsay it\n")
        #expect(h.output("sh /alias.sh") == "said it\n")
    }
}
