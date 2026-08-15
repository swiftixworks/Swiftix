import Testing
@testable import Swiftix

/// Meta-programs that resolve and launch other commands through the command-table
/// seam (`ProcessContext.resolveCommand` / `run(_:args:)`, backed by
/// `Kernel.commandRegistry`, which the shell installs at start): `which`, `type`,
/// `env CMD`, `xargs`, `timeout`.
@Suite("Meta commands (command-table seam)")
struct MetaCommandsTests {

    @Test func whichLocatesBuiltins() {
        let out = run(["which echo"])
        #expect(contains(out, Array("/bin/echo".utf8)))
    }

    @Test func typeDescribesBuiltins() {
        let out = run(["type echo"])
        #expect(contains(out, Array("echo is a builtin".utf8)))
    }

    @Test func typeReportsUnknown() {
        let out = run(["type nosuchcmd"])
        #expect(contains(out, Array("nosuchcmd: not found".utf8)))
    }

    /// `env NAME=VALUE CMD` sets the variable, then runs CMD in that environment;
    /// the child observes the value.
    @Test func envRunsCommandInModifiedEnvironment() {
        let out = run(["env MYVAR=hello showvar"], register: { registry in
            registry.register(Command(name: "showvar", summary: "print $MYVAR") { ctx, _ in
                ctx.print("[\(ctx.getenv("MYVAR") ?? "")]\n")
                ctx.exit(0)
            })
        })
        #expect(contains(out, Array("[hello]".utf8)))
    }

    /// `xargs` turns stdin words into arguments for the given command.
    @Test func xargsBuildsArgumentsFromStdin() {
        let out = run(["echo a b c | xargs args"], register: registerArgs)
        #expect(contains(out, Array("<a,b,c>".utf8)))
    }

    /// A command that finishes within the limit runs normally.
    @Test func timeoutPassesThroughFastCommand() {
        let out = run(["timeout 5 echo done"])
        #expect(contains(out, Array("done".utf8)))
    }

    /// A command that exceeds the limit is terminated, and the shell returns to
    /// the prompt so a following command runs.
    @Test func timeoutTerminatesSlowCommand() {
        let out = run(["timeout 0.1 sleep 10", "echo after"], advance: 1.0)
        #expect(contains(out, Array("after".utf8)))
    }

    // MARK: - Helpers

    private final class Capture { var out: [UInt8] = [] }

    private func registerArgs(_ registry: CommandRegistry) {
        registry.register(Command(name: "args", summary: "print argv") { ctx, argv in
            ctx.print("<" + argv.dropFirst().joined(separator: ",") + ">\n")
            ctx.exit(0)
        })
    }

    private func run(_ lines: [String],
                     advance: Double = 0,
                     register: ((CommandRegistry) -> Void)? = nil) -> [UInt8] {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let registry = CommandRegistry.builtins
        register?(registry)
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
        if advance > 0 {
            loop.advance(by: advance)
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
