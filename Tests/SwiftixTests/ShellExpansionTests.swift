import Testing
@testable import Swiftix

/// Word expansion through a real shell: special parameters, `${…}` operators,
/// tilde and brace expansion, multi-component globbing, field splitting, and
/// arithmetic. `args` prints its argument vector as `<a,b,c>`.
@Suite("Shell expansion")
struct ShellExpansionTests {

    private func harness() -> ShellScriptHarness {
        let h = ShellScriptHarness()
        // A shell function probe: prints its arguments as `<a,b,c>`.
        h.run("args() { out=; sep=; for a; do out=\"$out$sep$a\"; sep=,; done; echo \"<$out>\"; }")
        return h
    }

    // MARK: - Special parameters

    @Test func processIdentifiers() {
        let h = harness()
        let pid = h.output("echo $$").dropLast()
        #expect(Int(pid) != nil)
        #expect(h.output("echo $0") == "sh\n")
        h.run("sleep 5 &")
        let background = h.output("echo $!").dropLast()
        #expect(Int(background) != nil)
        #expect(background != pid)
        // `$$` is the shell's pid even inside a subshell.
        #expect(h.output("(echo $$)").dropLast() == pid)
    }

    @Test func statusParameterIsThePreviousCommandsDespiteSubstitutions() {
        let h = harness()
        // Every `$?` of a command is the status of the command before it,
        // wherever command substitutions sit among the same words.
        #expect(h.output("false; echo \"rc=$? $(true)\"") == "rc=1 \n")
        #expect(h.output("true; echo \"rc=$? $(false)\"") == "rc=0 \n")
        #expect(h.output("true; echo \"$(false)$?\"") == "0\n")
        #expect(h.output("false; echo \"$(true)$?\"") == "1\n")
        #expect(h.output("true; echo \"$? $(false) $?\"") == "0  0\n")
        #expect(h.output("false; echo \"$? $(true) $?\"") == "1  1\n")
        #expect(h.output("false; echo $? `true` $?") == "1 1\n")
        #expect(h.output("false; echo \"$? $(true)\" | cat") == "1 \n")
        #expect(h.output("false; args $? $(echo a b) \"$?\"") == "<1,a,b,1>\n")
    }

    @Test func statusParameterInNestedExpansionsDespiteSubstitutions() {
        let h = harness()
        #expect(h.output("unset x; false; echo \"${x:-$?}$(true)\"") == "1\n")
        #expect(h.output("unset x; false; echo \"$(true)${x:-$?}\"") == "1\n")
        #expect(h.output("false; echo $(( $? + $(echo 1) ))") == "2\n")
        #expect(h.output("true; echo $(( $(false; echo 4) + $? ))") == "4\n")
        #expect(h.output("false; for w in $? $(echo a) $?; do echo $w; done") == "1\na\n1\n")
        #expect(h.output("false; case $?$(true) in 1) echo one;; *) echo other;; esac") == "one\n")
        #expect(h.output("false; case 1 in $(true)$?) echo one;; *) echo other;; esac") == "one\n")
        #expect(h.output("false; echo hi > /status-$?-$(true); ls /status-*") == "/status-1-\n")
        #expect(h.output("false; cat <<< \"$? $(true) $?\"") == "1  1\n")
        h.write("/heredoc.sh", "false\ncat <<EOF\n$? $(true) $?\nEOF\ntrue\ncat <<EOF\n$(false)$?\nEOF\n")
        #expect(h.output("sh /heredoc.sh") == "1  1\n0\n")
    }

    @Test func substitutionStatusBecomesTheStatusOnlyWithoutACommandName() {
        let h = harness()
        #expect(h.output("x=$(false); echo $?") == "1\n")
        #expect(h.output("false; x=$(true); echo $?") == "0\n")
        #expect(h.output("x=$(exit 3)$(exit 7); echo $?") == "7\n")
        #expect(h.output("true; x=$?$(exit 5); echo $x $?") == "0 5\n")
        #expect(h.output("$(false); echo $?") == "1\n")
        #expect(h.output("echo $(false); echo $?") == "\n0\n")
        #expect(h.output("false; x=plain; echo $?") == "0\n")
        // A substitution that runs no command succeeds.
        #expect(h.output("false; x=$(); echo $?") == "0\n")
        #expect(h.output("false; x=$(exit); echo $?") == "1\n")
        #expect(h.output("if x=$(false); then echo yes; else echo no; fi") == "no\n")
    }

    @Test func childShellsInheritStatusAndBackgroundPid() {
        let h = harness()
        #expect(h.output("false; echo $(echo $?)") == "1\n")
        #expect(h.output("false; (echo $?)") == "1\n")
        #expect(h.output("false; { echo $?; } | cat") == "1\n")
        #expect(h.output("false; echo $? | cat") == "1\n")
        #expect(h.output("false; echo $(true) $(echo $?)") == "1\n")
        h.run("sleep 5 &")
        let background = h.output("echo $!")
        #expect(Int(background.dropLast()) != nil)
        #expect(h.output("echo $(echo $!)") == background)
        #expect(h.output("(echo $!)") == background)
    }

    @Test func positionalParametersInFunctions() {
        let h = harness()
        h.run("f() { echo \"$# $1 $2 $*\"; }")
        #expect(h.output("f a b c") == "3 a b a b c\n")
        #expect(h.output("true; echo $?") == "0\n")
        #expect(h.output("false; echo $?") == "1\n")
    }

    @Test func quotedAtPreservesArgumentBoundaries() {
        let h = harness()
        h.run("f() { args \"$@\"; }; g() { args $@; }; s() { args \"$*\"; }")
        #expect(h.output("f 'a b' c") == "<a b,c>\n")
        #expect(h.output("g 'a b' c") == "<a,b,c>\n")
        #expect(h.output("s 'a b' c") == "<a b c>\n")
        #expect(h.output("f") == "<>\n")
        h.run("p() { args \"x$@y\"; }")
        #expect(h.output("p 1 2") == "<x1,2y>\n")
    }

    // MARK: - ${…}

    @Test func defaultAndAlternativeValues() {
        let h = harness()
        h.run("set=v; empty=")
        #expect(h.output("echo ${unset:-def} ${empty:-def} ${set:-def}") == "def def v\n")
        #expect(h.output("echo [${empty-def}] [${unset-def}]") == "[] [def]\n")
        #expect(h.output("echo [${set:+alt}] [${unset:+alt}] [${empty:+alt}]") == "[alt] [] []\n")
    }

    @Test func assignDefault() {
        let h = harness()
        #expect(h.output("echo ${fresh:=made}; echo $fresh") == "made\nmade\n")
    }

    @Test func errorIfUnset() {
        let h = harness()
        let text = h.output("echo ${missing:?is required}; echo not-reached")
        #expect(text.contains("missing: is required"))
        #expect(!text.contains("not-reached"))
        #expect(h.output("echo $?") == "1\n")
        #expect(h.shellIsRunning)
    }

    @Test func lengthOfValue() {
        let h = harness()
        h.run("word=hello")
        #expect(h.output("echo ${#word} ${#unset}") == "5 0\n")
        h.run("f() { echo ${#}; }")
        #expect(h.output("f a b") == "2\n")
    }

    @Test func prefixAndSuffixRemoval() {
        let h = harness()
        h.run("p=/usr/local/lib/libfoo.tar.gz")
        #expect(h.output("echo ${p#*/}") == "usr/local/lib/libfoo.tar.gz\n")
        #expect(h.output("echo ${p##*/}") == "libfoo.tar.gz\n")
        #expect(h.output("echo ${p%.*}") == "/usr/local/lib/libfoo.tar\n")
        #expect(h.output("echo ${p%%.*}") == "/usr/local/lib/libfoo\n")
        #expect(h.output("echo ${p%/*}") == "/usr/local/lib\n")
    }

    @Test func substringAndReplacement() {
        let h = harness()
        h.run("s=hello-world")
        #expect(h.output("echo ${s:6} ${s:0:5} ${s/o/0} ${s//o/0}") == "world hello hell0-world hell0-w0rld\n")
    }

    // MARK: - Tilde, braces, globs

    @Test func tildeExpansion() {
        let h = harness()
        #expect(h.output("echo ~ ~/x '~' a~") == "/root /root/x ~ a~\n")
        #expect(h.output("d=~/y; echo $d") == "/root/y\n")
    }

    @Test func braceExpansion() {
        let h = harness()
        #expect(h.output("echo {a,b,c}") == "a b c\n")
        #expect(h.output("echo x{1,2}y") == "x1y x2y\n")
        #expect(h.output("echo {1..3} {3..1} {a..c}") == "1 2 3 3 2 1 a b c\n")
        #expect(h.output("echo {a,b}{1,2}") == "a1 a2 b1 b2\n")
        #expect(h.output("echo '{a,b}' {} {x}") == "{a,b} {} {x}\n")
    }

    @Test func globInNonFinalComponents() {
        let h = harness()
        h.run("mkdir -p /g/one /g/two /g/tre; touch /g/one/hit /g/two/hit /g/two/miss /g/file")
        #expect(h.output("echo /g/*/hit") == "/g/one/hit /g/two/hit\n")
        #expect(h.output("echo /g/t*/h*") == "/g/two/hit\n")
        #expect(h.output("cd /g; echo */") == "one/ tre/ two/\n")
        #expect(h.output("echo /g/*/nothing") == "/g/*/nothing\n")
        #expect(h.output("echo /g/o?e/[gh]it") == "/g/one/hit\n")
    }

    @Test func unquotedExpansionIsFieldSplitQuotedIsNot() {
        let h = harness()
        h.run("v='a  b c'")
        #expect(h.output("args $v") == "<a,b,c>\n")
        #expect(h.output("args \"$v\"") == "<a  b c>\n")
        #expect(h.output("args $(echo x y) \"$(echo x y)\"") == "<x,y,x y>\n")
        #expect(h.output("e=; args $e \"$e\" ''") == "<,>\n")
    }

    @Test func customFieldSeparator() {
        let h = harness()
        h.run("v=a:b:c")
        #expect(h.output("IFS=:; args $v; unset IFS") == "<a,b,c>\n")
    }

    @Test func dollarSingleQuotes() {
        let h = harness()
        #expect(h.output("printf '%s' $'a\\tb\\n'") == "a\tb\n")
    }

    // MARK: - Arithmetic

    @Test func powerAndBitwiseOperators() {
        let h = harness()
        #expect(h.output("echo $((2**10)) $((2**3**2)) $((-2**2))") == "1024 512 4\n")
        #expect(h.output("echo $((6 & 3)) $((6 | 3)) $((6 ^ 3)) $((~5)) $((1 << 4)) $((256 >> 2))")
                == "2 7 5 -6 16 64\n")
        #expect(h.output("echo $((0x10 + 010))") == "24\n")
    }

    @Test func ternaryAndLogical() {
        let h = harness()
        #expect(h.output("echo $((3 > 2 ? 10 : 20)) $((0 ? 10 : 20)) $((1 && 0)) $((1 || 0))") == "10 20 0 1\n")
    }

    @Test func assignmentForms() {
        let h = harness()
        #expect(h.output("echo $((n = 5)) $((n += 2)) $((n++)) $((++n)) $n") == "5 7 7 9 9\n")
        #expect(h.output("x=4; echo $(($x * 2)) $((x * x))") == "8 16\n")
        // The untaken ternary arm has no side effects.
        #expect(h.output("k=1; echo $((1 ? 2 : (k = 9))) $k") == "2 1\n")
    }

    // MARK: - Variables vs. environment

    @Test func plainAssignmentIsNotExported() {
        let h = harness()
        h.run("plain=1; export shown=2")
        #expect(h.output("env | grep -c -e '^plain=' -e '^shown='") == "1\n")
        #expect(h.output("sh -c 'echo [$plain][$shown]'") == "[][2]\n")
        h.run("export plain")
        #expect(h.output("sh -c 'echo [$plain]'") == "[1]\n")
        // Assigning an exported variable keeps it exported.
        h.run("shown=3")
        #expect(h.output("sh -c 'echo $shown'") == "3\n")
    }

    @Test func prefixAssignmentReachesOnlyThatCommand() {
        let h = harness()
        #expect(h.output("TEMP=1 sh -c 'echo [$TEMP]'; echo [$TEMP]") == "[1]\n[]\n")
    }
}
