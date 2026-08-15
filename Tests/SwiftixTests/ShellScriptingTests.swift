import Testing
@testable import Swiftix

/// Stage-3 shell scripting features driven through a real shell: standard-error
/// redirection (`2>`, `2>&1`), arithmetic expansion `$((…))`, pathname globbing
/// (`*`, `?`, `[…]`), `for` loops, and command substitution `$(…)`. Each program
/// writes to a file that is read back for an exact assertion.
@Suite("Shell scripting (redirection, arithmetic, glob, for, $() )")
struct ShellScriptingTests {

    // MARK: - Redirection

    @Test func stderrRedirectToFile() {
        let h = ShellHarness()
        h.run("cat /nope 2> /err")
        #expect(h.contents(of: "/err").contains("No such file or directory"))
    }

    @Test func stderrMergedToStdoutWith2gt1() {
        let h = ShellHarness()
        h.run("cat /nope > /out 2>&1")
        #expect(h.contents(of: "/out").contains("No such file or directory"))
    }

    @Test func separateStdoutAndStderrStreams() {
        let h = ShellHarness()
        h.run("printf 'hello\\n' > /a")
        h.run("cat /a /nope > /out 2> /err")
        #expect(h.contents(of: "/out") == "hello\n")
        #expect(h.contents(of: "/err").contains("No such file or directory"))
    }

    // MARK: - Arithmetic $(( ))

    @Test func arithmeticPrecedenceAndParens() {
        let h = ShellHarness()
        h.run("echo $((2 + 3 * 4)) > /o1")
        h.run("echo $(( (2 + 3) * 4 )) > /o2")
        #expect(h.contents(of: "/o1") == "14\n")
        #expect(h.contents(of: "/o2") == "20\n")
    }

    @Test func arithmeticWithVariables() {
        let h = ShellHarness()
        h.run("x=5; echo $((x * 2 + 1)) > /o")
        #expect(h.contents(of: "/o") == "11\n")
    }

    @Test func arithmeticComparisons() {
        let h = ShellHarness()
        h.run("echo $((3 > 2)) $((2 > 3)) $((4 == 4)) > /o")
        #expect(h.contents(of: "/o") == "1 0 1\n")
    }

    // MARK: - Glob

    @Test func globStarMatchesAndSorts() {
        let h = ShellHarness()
        h.run("touch b.txt a.txt c.log")
        h.run("echo *.txt > /o")
        #expect(h.contents(of: "/o") == "a.txt b.txt\n")
    }

    @Test func globNoMatchStaysLiteral() {
        let h = ShellHarness()
        h.run("echo *.md > /o")
        #expect(h.contents(of: "/o") == "*.md\n")
    }

    @Test func globQuotedStarIsLiteral() {
        let h = ShellHarness()
        h.run("touch a.txt")
        h.run("echo \"*.txt\" > /o")
        #expect(h.contents(of: "/o") == "*.txt\n")
    }

    @Test func globCharacterClass() {
        let h = ShellHarness()
        h.run("touch a.txt b.txt c.txt")
        h.run("echo [ab].txt > /o")
        #expect(h.contents(of: "/o") == "a.txt b.txt\n")
    }

    // MARK: - for loops

    @Test func forOverLiteralWords() {
        let h = ShellHarness()
        h.run("for i in 1 2 3; do echo n$i; done > /o")
        #expect(h.contents(of: "/o") == "n1\nn2\nn3\n")
    }

    @Test func forOverGlob() {
        let h = ShellHarness()
        h.run("touch x.c y.c")
        h.run("for f in *.c; do echo file $f; done > /o")
        #expect(h.contents(of: "/o") == "file x.c\nfile y.c\n")
    }

    // MARK: - Command substitution $( )

    @Test func commandSubstitutionInlineArgument() {
        let h = ShellHarness()
        h.run("echo result: $(echo hello) > /o")
        #expect(h.contents(of: "/o") == "result: hello\n")
    }

    @Test func commandSubstitutionWordSplitsWhenUnquoted() {
        let h = ShellHarness()
        h.run("for i in $(seq 3); do echo v$i; done > /o")
        #expect(h.contents(of: "/o") == "v1\nv2\nv3\n")
    }

    @Test func commandSubstitutionQuotedPreservesWhitespace() {
        let h = ShellHarness()
        h.run("echo \"$(seq 2)\" > /o")
        #expect(h.contents(of: "/o") == "1\n2\n")
    }

    @Test func commandSubstitutionIntoAssignment() {
        let h = ShellHarness()
        h.run("name=$(basename /usr/bin/tool); echo $name > /o")
        #expect(h.contents(of: "/o") == "tool\n")
    }

    @Test func commandSubstitutionNestedInArithmetic() {
        let h = ShellHarness()
        h.run("echo $(( $(echo 3) + 4 )) > /o")
        #expect(h.contents(of: "/o") == "7\n")
    }

    // MARK: - case

    @Test func caseMatchesExactPattern() {
        let h = ShellHarness()
        h.run("x=banana; case $x in apple) echo A;; banana) echo B;; *) echo other;; esac > /o")
        #expect(h.contents(of: "/o") == "B\n")
    }

    @Test func caseMatchesGlobPattern() {
        let h = ShellHarness()
        h.run("case hello.txt in *.txt) echo text;; *) echo no;; esac > /o")
        #expect(h.contents(of: "/o") == "text\n")
    }

    @Test func caseMatchesAlternatives() {
        let h = ShellHarness()
        h.run("case cat in dog|cat|fish) echo pet;; *) echo no;; esac > /o")
        #expect(h.contents(of: "/o") == "pet\n")
    }

    @Test func caseFallsThroughToDefault() {
        let h = ShellHarness()
        h.run("case xyz in a) echo a;; b) echo b;; *) echo default;; esac > /o")
        #expect(h.contents(of: "/o") == "default\n")
    }

    // MARK: - functions

    @Test func functionDefinitionAndCall() {
        let h = ShellHarness()
        h.run("greet() { echo hello; }; greet > /o")
        #expect(h.contents(of: "/o") == "hello\n")
    }

    @Test func functionPositionalParameters() {
        let h = ShellHarness()
        h.run("pair() { echo $1 and $2; }; pair foo bar > /o")
        #expect(h.contents(of: "/o") == "foo and bar\n")
    }

    @Test func functionArgumentCount() {
        let h = ShellHarness()
        h.run("count() { echo $#; }; count a b c > /o")
        #expect(h.contents(of: "/o") == "3\n")
    }

    @Test func functionContainingControlFlow() {
        let h = ShellHarness()
        h.run("nums() { for i in 1 2 3; do echo v$i; done; }; nums > /o")
        #expect(h.contents(of: "/o") == "v1\nv2\nv3\n")
    }

    @Test func functionParametersRestoreAfterCall() {
        let h = ShellHarness()
        // The inner call must not clobber the outer function's $1 permanently.
        h.run("inner() { echo inner:$1; }; outer() { inner X; echo outer:$1; }; outer Y > /o")
        #expect(h.contents(of: "/o") == "inner:X\nouter:Y\n")
    }

    // MARK: - here-documents

    @Test func heredocFeedsBodyAsStdin() {
        let h = ShellHarness()
        h.run("cat <<EOF > /o\nline one\nline two\nEOF")
        #expect(h.contents(of: "/o") == "line one\nline two\n")
    }

    @Test func heredocExpandsParameters() {
        let h = ShellHarness()
        h.run("name=World")                       // sets shell env for the next command
        h.run("cat <<EOF > /o\nHello $name\nEOF")
        #expect(h.contents(of: "/o") == "Hello World\n")
    }

    @Test func heredocQuotedDelimiterIsLiteral() {
        let h = ShellHarness()
        h.run("cat <<'EOF' > /o\nliteral $name value\nEOF")
        #expect(h.contents(of: "/o") == "literal $name value\n")
    }

    @Test func heredocDashStripsLeadingTabs() {
        let h = ShellHarness()
        h.run("cat <<-EOF > /o\n\tindented\n\tEOF")
        #expect(h.contents(of: "/o") == "indented\n")
    }

    // MARK: - Harness

    private final class ShellHarness {
        let loop = EventLoop()
        let kernel: Kernel
        let pty = PseudoTerminal()

        init() {
            kernel = Kernel(loop: loop)
            pty.echo = false
            pty.onOutput = { [weak pty] in _ = pty?.readForApp(max: 65_535) }
            kernel.spawn("sh", Programs.shell(tty: pty.slave))
            loop.runUntilIdle()
        }

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
