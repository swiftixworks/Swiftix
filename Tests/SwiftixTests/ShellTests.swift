import Testing
@testable import Swiftix

@Suite("PTY + minimal shell")
struct ShellTests {

    /// Drive the pty like a terminal: the shell prints a prompt, blocks on read,
    /// and after a line is "typed" it runs the built-in and prints output.
    @Test func shellRunsEchoCommand() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()

        final class Capture { var out: [UInt8] = [] }
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }

        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()                              // prints prompt, blocks on read

        pty.writeFromApp(Array("echo hello world\n".utf8))
        loop.runUntilIdle()                              // reads line, runs echo, prints output

        #expect(contains(captured.out, Array("root@swiftix:/# ".utf8))) // prompt shown
        #expect(contains(captured.out, Array("hello world".utf8)))  // echo output
    }

    @Test func unknownCommandReports() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()

        final class Capture { var out: [UInt8] = [] }
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }

        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("nope\n".utf8))
        loop.runUntilIdle()

        #expect(contains(captured.out, Array("command not found".utf8)))
    }

    @Test func shellSearchesPathBeforeNativeFallbackAndHonorsAssignedPath() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()

        final class Capture { var out: [UInt8] = [] }
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65_535))
        }

        let registry = CommandRegistry.builtins
        registry.register(Command(name: "probe", summary: "native fallback") { ctx, _ in
            ctx.print("native\n")
            ctx.exit(0)
        })
        registry.registerExecutableLoader { context, path in
            guard path == "/usr/bin/probe" || path == "/custom/probe",
                context.canExecute(path)
            else { return nil }
            return Command(name: path, summary: "file-backed probe") { child, _ in
                child.print(path == "/custom/probe" ? "custom\n" : "system\n")
                child.exit(0)
            }
        }
        kernel.spawn("seed") { context in
            for path in ["/usr/bin/probe", "/custom/probe"] {
                if let fd = context.open(path, create: true) { context.close(fd) }
                _ = context.chmod(
                    path,
                    mode: [
                        .ownerRead, .ownerWrite, .ownerExecute,
                        .groupRead, .groupExecute,
                        .otherRead, .otherExecute,
                    ])
            }
            context.exit(0)
        }
        loop.runUntilIdle()

        kernel.spawn("sh", Programs.shell(tty: pty.slave, commands: registry))
        loop.runUntilIdle()
        for line in [
            "probe",
            "PATH=/custom probe",
            "/usr/bin/probe",
            "which probe",
            "type probe",
        ] {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }

        let output = String(decoding: captured.out, as: UTF8.self)
        #expect(output.contains("system\n"))
        #expect(output.contains("custom\n"))
        #expect(output.contains("/usr/bin/probe"))
        #expect(output.contains("probe is /usr/bin/probe"))
        #expect(!output.contains("native\n"))
    }

    /// Backspace (DEL) erases from the line buffer before it is committed, so the
    /// shell receives the corrected command. Typing "ecX", DEL, "ho hi" yields
    /// "echo hi".
    @Test func backspaceErasesBeforeCommit() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()

        final class Capture { var out: [UInt8] = [] }
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }

        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()

        pty.writeFromApp(Array("ecX".utf8))
        pty.writeFromApp([0x7F])                  // erase the 'X'
        pty.writeFromApp(Array("ho hi\n".utf8))   // -> "echo hi"
        loop.runUntilIdle()

        #expect(contains(captured.out, Array("hi".utf8)))                    // echo ran
        #expect(!contains(captured.out, Array("command not found".utf8)))    // line was corrected
    }

    /// Byte-subsequence search (avoids depending on Foundation's String.contains).
    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
