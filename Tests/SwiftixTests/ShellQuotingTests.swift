import Testing
@testable import Swiftix

/// Shell tokenization: single/double quotes, backslash escapes, `$` expansion,
/// and quoting of metacharacters. Each test drives the real shell over a pty and
/// runs an `args` probe command that prints its argument vector as `<a,b,c>` —
/// a form that never appears in the echoed input line, so assertions are
/// unambiguous about how the line was split.
@Suite("Shell quoting + expansion")
struct ShellQuotingTests {

    @Test func doubleQuotesGroupWords() {
        #expect(contains(run(["args \"a b\" c"]), Array("<a b,c>".utf8)))
    }

    @Test func singleQuotesGroupWords() {
        #expect(contains(run(["args 'a b'"]), Array("<a b>".utf8)))
    }

    @Test func backslashEscapesSpace() {
        #expect(contains(run(["args a\\ b"]), Array("<a b>".utf8)))
    }

    @Test func doubleQuotesExpandVariables() {
        #expect(contains(run(["FOO=xy", "args \"$FOO\""]), Array("<xy>".utf8)))
    }

    @Test func singleQuotesSuppressExpansion() {
        #expect(contains(run(["FOO=xy", "args '$FOO'"]), Array("<$FOO>".utf8)))
    }

    @Test func expandedValueIsNotWordSplit() {
        // A value with a space stays one argument (no post-expansion splitting).
        #expect(contains(run(["FOO=\"a b\"", "args $FOO"]), Array("<a b>".utf8)))
    }

    @Test func quotedMetacharacterIsLiteral() {
        // A quoted ">" is a normal argument, not a redirection operator.
        #expect(contains(run(["args \">\" x"]), Array("<>,x>".utf8)))
    }

    @Test func redirectionStillWorksUnquoted() {
        // An unquoted `>` redirects: nothing on stdout, the word lands in the file.
        let out = run(["args a > /q", "cat /q"])
        #expect(contains(out, Array("<a>".utf8)))   // only `cat /q` can produce this
    }

    @Test func emptyQuotesAreAnEmptyArgument() {
        #expect(contains(run(["args \"\" x"]), Array("<,x>".utf8)))
    }

    // MARK: - Helpers

    private final class Capture { var out: [UInt8] = [] }

    /// Run shell lines with an `args` probe registered; return all pty output.
    private func run(_ lines: [String]) -> [UInt8] {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let registry = CommandRegistry.builtins
        registry.register(Command(name: "args", summary: "print argv") { ctx, argv in
            ctx.print("<" + argv.dropFirst().joined(separator: ",") + ">\n")
            ctx.exit(0)
        })
        let pty = PseudoTerminal()
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave, commands: registry))
        loop.runUntilIdle()
        for line in lines {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }
        return captured.out
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
