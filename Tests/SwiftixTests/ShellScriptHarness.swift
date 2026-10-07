import Testing
@testable import Swiftix

/// A real interactive shell on a pty for the POSIX-shell behavior suites: lines
/// are typed at the terminal, everything the terminal shows is captured, and
/// files are read back through a throwaway process. Logical time only.
final class ShellScriptHarness {
    let loop = EventLoop()
    let kernel: Kernel
    let pty = PseudoTerminal()
    private(set) var transcript: [UInt8] = []

    init() {
        kernel = Kernel(loop: loop)
        pty.echo = false
        pty.onOutput = { [weak self] in
            guard let self else { return }
            self.transcript += self.pty.readForApp(max: 65_535)
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
    }

    /// Type `line` and return what the terminal printed in response.
    @discardableResult
    func run(_ line: String) -> String {
        let start = transcript.count
        pty.writeFromApp(Array((line + "\n").utf8))
        loop.runUntilIdle()
        return String(decoding: transcript[start...], as: UTF8.self)
    }

    /// The output of `line` with the trailing prompt removed.
    func output(_ line: String) -> String {
        let text = run(line)
        let chars = Array(text)
        let marker = Array("root@")
        var index = chars.count - marker.count
        while index >= 0 {
            if Array(chars[index..<(index + marker.count)]) == marker { return String(chars[..<index]) }
            index -= 1
        }
        return text
    }

    func advance(by seconds: Double) {
        loop.advance(by: seconds)
        loop.runUntilIdle()
    }

    func write(_ path: String, _ text: String, executable: Bool = false) {
        kernel.spawn("write") { ctx in
            if let fd = ctx.open(path, create: true, truncate: true) {
                ctx.write(fd, Array(text.utf8))
                ctx.close(fd)
            }
            if executable { _ = ctx.chmod(path, mode: FileMode(rawValue: 0o755)) }
            ctx.exit(0)
        }
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

    /// Whether the shell process is still alive.
    var shellIsRunning: Bool {
        kernel.snapshotProcesses().contains { $0.name == "sh" && $0.exitStatus == nil }
    }
}
