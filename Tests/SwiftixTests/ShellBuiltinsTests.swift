import Testing
@testable import Swiftix

/// Shell builtins driven through a real shell on a pty.
@Suite("Shell builtins")
struct ShellBuiltinsTests {

    @Test func exitEndsTheInteractiveShell() {
        let h = ShellScriptHarness()
        #expect(h.shellIsRunning)
        h.run("exit 3")
        #expect(!h.shellIsRunning)
    }

    @Test func readSplitsFieldsAndKeepsRemainder() {
        let h = ShellScriptHarness()
        #expect(h.output("echo 'one two three four' | { read a b c; echo \"$a|$b|$c\"; }") == "one|two|three four\n")
        #expect(h.output("printf 'a\\\\tb\\n' | { read -r x; echo \"$x\"; }") == "a\\tb\n")
        #expect(h.output("echo solo | { read; echo $REPLY; }") == "solo\n")
        #expect(h.output("IFS=: read u p rest <<< 'root:x:0:0'; echo $u $p $rest") == "root x 0:0\n")
    }

    @Test func readReturnsNonZeroAtEndOfInput() {
        let h = ShellScriptHarness()
        #expect(h.output("touch /empty; read v < /empty; echo $?") == "1\n")
    }

    @Test func readFromTheTerminal() {
        let h = ShellScriptHarness()
        h.run("read first second")
        h.run("typed words here")
        #expect(h.output("echo \"$first/$second\"") == "typed/words here\n")
    }

    @Test func unsetRemovesVariablesAndFunctions() {
        let h = ShellScriptHarness()
        h.run("v=1; export e=2; f() { echo f; }")
        h.run("unset v e; unset -f f")
        #expect(h.output("echo [$v][$e]") == "[][]\n")
        #expect(h.output("f").contains("command not found"))
    }

    @Test func aliasAndUnalias() {
        let h = ShellScriptHarness()
        h.run("alias hi='echo hello'")
        #expect(h.output("hi there") == "hello there\n")
        #expect(h.output("alias").contains("alias hi='echo hello'"))
        h.run("unalias hi")
        #expect(h.output("hi").contains("command not found"))
    }

    @Test func setPositionalParameters() {
        let h = ShellScriptHarness()
        h.run("set -- a 'b c' d")
        #expect(h.output("echo $# \"$2\"") == "3 b c\n")
        h.run("shift")
        #expect(h.output("echo $# $1") == "2 b c\n")
        h.run("shift 2")
        #expect(h.output("echo $#") == "0\n")
        #expect(h.output("shift; echo $?").hasSuffix("1\n"))
    }

    @Test func setNounsetAndXtrace() {
        let h = ShellScriptHarness()
        h.run("set -u")
        #expect(h.output("echo $nope").contains("nope: unbound variable"))
        h.run("set +u")
        #expect(h.output("echo [$nope]") == "[]\n")
        h.run("set -x")
        #expect(h.output("echo traced").contains("+ echo traced\n"))
        h.run("set +x")
        #expect(h.output("echo $-").contains("i"))
    }

    @Test func localScopesAVariableToItsFunction() {
        let h = ShellScriptHarness()
        h.run("v=global")
        h.run("f() { local v=inner w=temp; echo $v$w; }")
        #expect(h.output("f; echo $v[$w]") == "innertemp\nglobal[]\n")
    }

    @Test func returnStopsAFunctionWithStatus() {
        let h = ShellScriptHarness()
        h.run("f() { echo before; return 4; echo after; }")
        #expect(h.output("f; echo $?") == "before\n4\n")
        h.run("g() { for i in 1 2 3; do [ $i = 2 ] && return 9; echo $i; done; }")
        #expect(h.output("g; echo $?") == "1\n9\n")
    }

    @Test func breakAndContinueWithLevels() {
        let h = ShellScriptHarness()
        #expect(h.output("for i in 1 2 3 4; do [ $i = 2 ] && continue; [ $i = 4 ] && break; echo $i; done") == "1\n3\n")
        #expect(h.output("for a in 1 2; do for b in x y; do [ $b = y ] && continue 2; echo $a$b; done; done") == "1x\n2x\n")
        #expect(h.output("for a in 1 2; do for b in x y; do echo $a$b; break 2; done; done") == "1x\n")
    }

    @Test func waitCollectsBackgroundStatus() {
        let h = ShellScriptHarness()
        h.run("sh -c 'sleep 1; exit 5' &")
        h.run("wait $!")
        h.advance(by: 2)
        #expect(h.output("echo $?") == "5\n")
        h.run("sleep 1 &")
        h.run("wait %1")
        h.advance(by: 2)
        #expect(h.output("echo $?") == "0\n")
    }

    @Test func waitWithoutArgumentsWaitsForAllJobs() {
        let h = ShellScriptHarness()
        h.run("sleep 1 & sleep 2 &")
        h.run("wait; echo all-done > /waited")
        #expect(h.contents(of: "/waited") == "<missing>")
        h.advance(by: 3)
        #expect(h.contents(of: "/waited") == "all-done\n")
    }

    @Test func killAcceptsJobSpecs() {
        let h = ShellScriptHarness()
        h.run("sleep 100 &")
        #expect(!h.output("kill %1").contains("not a pid"))
        #expect(!h.output("jobs").contains("Running"))
        h.run("sleep 100 &")
        h.run("kill %%")
        #expect(!h.output("jobs").contains("Running"))
        #expect(h.output("kill %9").contains("no such job"))
    }

    @Test func fgAcceptsJobSpec() {
        let h = ShellScriptHarness()
        h.run("sleep 1 &")
        h.run("fg %1")
        h.advance(by: 2)
        #expect(h.output("jobs") == "")
    }

    @Test func exitTrapRunsWhenAScriptEnds() {
        let h = ShellScriptHarness()
        #expect(h.output("sh -c 'trap \"echo bye\" EXIT; echo working'") == "working\nbye\n")
        #expect(h.output("sh -c 'trap \"echo bye\" EXIT; exit 4'; echo $?") == "bye\n4\n")
    }

    @Test func signalTrapRunsItsAction() {
        let h = ShellScriptHarness()
        h.write("/trap.sh", "trap 'echo caught; exit 0' TERM\necho ready\nwhile :; do sleep 1; done\n")
        h.run("sh /trap.sh > /trap.out &")
        h.run("kill -TERM $!")
        h.advance(by: 2)
        #expect(h.contents(of: "/trap.out") == "ready\ncaught\n")
    }

    @Test func evalReparsesItsArguments() {
        let h = ShellScriptHarness()
        h.run("cmd='echo $((1+2))'")
        #expect(h.output("eval $cmd") == "3\n")
        #expect(h.output("eval 'n=4; echo $n'; echo $n") == "4\n4\n")
    }

    @Test func execReplacesTheShell() {
        let h = ShellScriptHarness()
        #expect(h.output("sh -c 'exec echo replaced; echo not-reached'") == "replaced\n")
    }

    @Test func execWithOnlyRedirectionsIsPermanent() {
        let h = ShellScriptHarness()
        h.run("sh -c 'exec > /exec.out; echo one; echo two'")
        #expect(h.contents(of: "/exec.out") == "one\ntwo\n")
    }

    @Test func colonIsANoOp() {
        let h = ShellScriptHarness()
        #expect(h.output(": ignored args; echo $?") == "0\n")
    }

    @Test func dotSourcesAFileIntoTheCurrentShell() {
        let h = ShellScriptHarness()
        h.write("/lib.sh", "sourced=yes\nhelper() { echo helped $1; }\nreturn 0\necho not-reached\n")
        #expect(h.output(". /lib.sh; echo $sourced; helper x") == "yes\nhelped x\n")
        #expect(h.output("source /lib.sh; echo $?") == "0\n")
    }

    @Test func historyListsEnteredCommands() {
        let h = ShellScriptHarness()
        h.run("echo first")
        h.run("echo second")
        let text = h.output("history")
        #expect(text.contains("1  echo first\n"))
        #expect(text.contains("2  echo second\n"))
        #expect(text.contains("3  history\n"))
    }

    @Test func historyIsVisibleInPipelinesAndSubstitutions() {
        let h = ShellScriptHarness()
        h.run("echo first")
        h.run("echo foo second")
        #expect(h.output("history | tail -1") == "    3  history | tail -1\n")
        #expect(h.output("history | grep -c foo") == "2\n")      // line 2 and this one
        #expect(h.output("n=$(history | wc -l); echo $n") == "5\n")
        #expect(h.output("echo \"$(history)\" | head -1") == "    1  echo first\n")
        #expect(h.output("(history) | head -2 | tail -1") == "    2  echo foo second\n")
        #expect(h.output("{ history; } | wc -l") == "8\n")
        // Clearing in a child shell leaves the parent's list alone.
        #expect(h.output("(history -c; history) | wc -l") == "0\n")
        #expect(h.output("history | head -1") == "    1  echo first\n")
    }

    @Test func shellStateListingsWorkInPipelinesAndSubstitutions() {
        let h = ShellScriptHarness()
        h.run("greet() { echo hi; }; alias ll='ls -l'; shellvar=42; umask 027")
        #expect(h.output("alias | cat") == "alias ll='ls -l'\n")
        #expect(h.output("echo \"$(alias)\"") == "alias ll='ls -l'\n")
        #expect(h.output("set | grep '^shellvar='") == "shellvar='42'\n")
        #expect(h.output("echo \"$(set | grep -c '^shellvar=')\"") == "1\n")
        #expect(h.output("type greet | cat") == "greet is a function\n")
        #expect(h.output("echo \"$(type greet)\"") == "greet is a function\n")
        #expect(h.output("type ll | cat") == h.output("type ll"))
        #expect(h.output("umask | cat") == "0027\n")
        #expect(h.output("echo $(umask) $(umask -S)") == "0027 u=rwx,g=rx,o=\n")
    }

    @Test func jobsListsTheParentsJobsInPipelinesAndSubstitutions() {
        let h = ShellScriptHarness()
        #expect(h.output("jobs | cat") == "")
        h.run("sleep 50 &")
        h.run("sleep 60 &")
        let listing = "[1] Running\tsleep 50\n[2] Running\tsleep 60\n"
        #expect(h.output("jobs") == listing)
        #expect(h.output("jobs | cat") == listing)
        #expect(h.output("echo \"$(jobs)\"") == listing)
        #expect(h.output("(jobs)") == listing)
        #expect(h.output("n=$(jobs | wc -l); echo $n") == "2\n")
        // A child's own background job replaces the inherited listing.
        #expect(h.output("(sleep 70 & jobs)") == "[1] Running\tsleep 70\n")
        #expect(h.output("jobs") == listing)
        h.run("kill %1 %2")
    }

    @Test func trapListingShowsTheParentsTrapsInPipelinesAndSubstitutions() {
        let h = ShellScriptHarness()
        #expect(h.output("trap | cat") == "")
        h.run("trap 'echo bye' TERM; trap '' HUP")
        let listing = "trap -- '' HUP\ntrap -- 'echo bye' TERM\n"
        #expect(h.output("trap") == listing)
        #expect(h.output("trap | cat") == listing)
        #expect(h.output("echo \"$(trap)\"") == listing)
        #expect(h.output("(trap -p)") == listing)
        // Setting a trap in the child ends the listing-only view of the parent's.
        #expect(h.output("(trap 'echo usr' USR1; trap)") == "trap -- 'echo usr' USR1\n")
        #expect(h.output("trap") == listing)
    }

    @Test func inheritedExitTrapIsListedButNotRunByAChildShell() {
        let h = ShellScriptHarness()
        h.write("/exit-trap.sh", "trap 'echo leaving' EXIT\necho \"[$(trap)]\"\n(:)\ntrap | cat\necho end\n")
        #expect(h.output("sh /exit-trap.sh")
                == "[trap -- 'echo leaving' EXIT]\ntrap -- 'echo leaving' EXIT\nend\nleaving\n")
    }

    @Test func typeReportsShellBuiltinsFunctionsAndAliases() {
        let h = ShellScriptHarness()
        for name in ["cd", "exit", "read", "unset", "alias", "unalias", "set", "local", "return",
                     "break", "continue", "shift", "wait", "trap", "eval", "exec", ":", ".",
                     "source", "history", "export", "jobs", "fg", "bg", "type"] {
            #expect(h.output("type \(name)") == "\(name) is a shell builtin\n")
        }
        h.run("f() { :; }; alias ll='ls -l'")
        #expect(h.output("type f") == "f is a function\n")
        #expect(h.output("type ll").contains("aliased"))
        #expect(h.output("type if") == "if is a shell keyword\n")
        #expect(h.output("type echo") == "echo is a builtin\n")
        #expect(h.output("type nosuchthing; echo $?") == "nosuchthing: not found\n1\n")
    }

    @Test func builtinInAPipelineRunsInASubshell() {
        let h = ShellScriptHarness()
        #expect(h.output("type cd | cat") == "cd is a shell builtin\n")
        h.run("f() { echo from-function; }")
        #expect(h.output("f | rev") == "noitcnuf-morf\n")
    }

    @Test func cdDashReturnsToPreviousDirectory() {
        let h = ShellScriptHarness()
        h.run("mkdir -p /a /b; cd /a; cd /b")
        #expect(h.output("cd -") == "/a\n")
        #expect(h.output("pwd") == "/a\n")
    }

    @Test func commandBypassesFunctions() {
        let h = ShellScriptHarness()
        h.run("echo() { printf 'shadowed\\n'; }")
        #expect(h.output("echo x") == "shadowed\n")
        #expect(h.output("command echo x") == "x\n")
        #expect(h.output("command -v cd") == "cd\n")
    }


    // MARK: - umask, $RANDOM, --help

    @Test func umaskShowsAndSetsTheCreationMask() {
        let h = ShellScriptHarness()
        #expect(h.output("umask") == "0022\n")
        #expect(h.output("umask -S") == "u=rwx,g=rx,o=rx\n")
        h.run("umask 027")
        #expect(h.output("umask") == "0027\n")
        #expect(h.output("touch /masked; mkdir /maskedDir; stat -c %a /masked /maskedDir") == "640\n750\n")
        // Symbolic modes name what stays allowed.
        h.run("umask u=rwx,g=rx,o=")
        #expect(h.output("umask") == "0027\n")
        h.run("umask g-x,o+r")
        #expect(h.output("umask; umask -S") == "0033\nu=rwx,g=r,o=r\n")
        h.run("umask a=rwx")
        #expect(h.output("umask") == "0000\n")
        #expect(h.output("umask 999; echo $?") == "umask: 999: invalid mode\n1\n")
        #expect(h.output("umask u=rwz; echo $?") == "umask: u=rwz: invalid mode\n1\n")
        #expect(h.output("umask") == "0000\n")
    }

    @Test func umaskIsInheritedButASubshellCannotChangeTheParent() {
        let h = ShellScriptHarness()
        h.run("umask 077")
        #expect(h.output("sh -c umask") == "0077\n")
        #expect(h.output("( umask 000; umask ); umask") == "0000\n0077\n")
        #expect(h.output("type umask") == "umask is a shell builtin\n")
    }

    @Test func parseUmaskHandlesOctalAndSymbolicForms() {
        typealias Shell = Programs.ShellInterpreter
        #expect(Shell.parseUmask("0", current: 0o022) == 0)
        #expect(Shell.parseUmask("0777", current: 0o022) == 0o777)
        #expect(Shell.parseUmask("1000", current: 0o022) == nil)
        #expect(Shell.parseUmask("8", current: 0o022) == nil)
        #expect(Shell.parseUmask("go-rwx", current: 0o022) == 0o077)
        #expect(Shell.parseUmask("+w", current: 0o022) == 0)
        #expect(Shell.parseUmask("u=,g=,o=", current: 0) == 0o777)
        #expect(Shell.parseUmask("u", current: 0) == nil)
    }

    @Test func randomIsInRangeDeterministicAndAssignable() {
        func draw() -> [Int] {
            let h = ShellScriptHarness()
            return h.output("echo $RANDOM $RANDOM $RANDOM").split(separator: " ").compactMap { Int($0.filter(\.isNumber)) }
        }
        let first = draw()
        #expect(first.count == 3)
        #expect(first.allSatisfy { (0...32_767).contains($0) })
        #expect(Set(first).count > 1)
        #expect(draw() == first)                     // same kernel seed, same stream
        let h = ShellScriptHarness()
        #expect(h.output("RANDOM=7; echo $RANDOM") == "7\n")
    }

    @Test func everyShellBuiltinAnswersHelp() {
        let h = ShellScriptHarness()
        for name in Programs.ShellInterpreter.builtinNames.sorted() where name != ":" && name != "exec" {
            let out = h.output("\(name) --help; echo rc=$?")
            #expect(out.hasPrefix("Usage: \(name)"), "\(name) --help printed: \(out)")
            #expect(out.hasSuffix("rc=0\n"), "\(name) --help status")
        }
        #expect(h.shellIsRunning)                    // `exit --help` did not exit
        #expect(h.output("cd --help") == "Usage: cd [DIR|-]\n")
    }

    @Test func commandVDescribesEveryOperand() {
        let h = ShellScriptHarness()
        #expect(h.output("command -v ls cd umask; echo rc=$?") == "ls\ncd\numask\nrc=0\n")
        #expect(h.output("command -v ls nosuch cd; echo rc=$?") == "ls\ncd\nrc=1\n")
    }
}
