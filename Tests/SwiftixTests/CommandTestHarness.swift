@testable import Swiftix

/// Shared fixture for the built-in command tests: boots a kernel, a
/// pseudo-terminal with echo off, and an interactive shell, then runs command
/// lines the way a user would. Output is asserted either on what the terminal
/// showed or — for exact comparisons — on a file the command was redirected
/// into, read back out of the VFS.
///
/// Everything runs on the logical clock: `run` drains the loop with
/// `runUntilIdle()`, and `advance(by:)` moves time forward for commands that
/// sleep (`tail -f`, `watch`, `timeout`).
final class CommandHarness {
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

    /// Drop the console output captured so far.
    func clearOutput() { captured.removeAll() }

    /// Console output (stdout and stderr share the tty) since `clearOutput`.
    func output() -> String { String(decoding: captured, as: UTF8.self) }

    /// Type one command line and let the system settle.
    func run(_ line: String) {
        pty.writeFromApp(Array((line + "\n").utf8))
        loop.runUntilIdle()
    }

    /// Type raw bytes (a key press, Ctrl-C handled by the caller) and settle.
    func type(_ bytes: [UInt8]) {
        pty.writeFromApp(bytes)
        loop.runUntilIdle()
    }

    /// Run a command line and return everything the terminal showed for it.
    func console(_ line: String) -> String {
        clearOutput()
        run(line)
        return output()
    }

    /// Run a command line with stdout redirected to a scratch file and return
    /// exactly what it wrote (pipelines redirect their last stage).
    func stdout(_ line: String) -> String {
        inProcess { ctx in ctx.remove("/.stdout") }      // never read a stale capture
        run("\(line) > /.stdout")
        return contents(of: "/.stdout")
    }

    /// Run a command line and return its exit status.
    func status(_ line: String) -> Int {
        run(line)
        run("echo $? > /.status")
        return Int(contents(of: "/.status").dropLast()) ?? -1
    }

    /// Advance logical time and settle.
    func advance(by seconds: Double) {
        loop.advance(by: seconds)
        loop.runUntilIdle()
    }

    /// Create or replace a file.
    func write(_ path: String, _ text: String) {
        writeBytes(path, Array(text.utf8))
    }

    func writeBytes(_ path: String, _ bytes: [UInt8]) {
        kernel.spawn("seed") { ctx in
            if let fd = ctx.open(path, create: true, truncate: true) {
                ctx.write(fd, bytes)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()
    }

    /// Run `body` in a throwaway process (to seed state or inspect the VFS).
    func inProcess(_ body: @escaping (ProcessContext) -> Void) {
        kernel.spawn("probe") { ctx in
            body(ctx)
            ctx.exit(0)
        }
        loop.runUntilIdle()
    }

    func bytes(of path: String) -> [UInt8]? {
        final class Box { var bytes: [UInt8]? }
        let box = Box()
        inProcess { ctx in
            guard let fd = ctx.open(path) else { return }
            var data: [UInt8] = []
            while true {
                let chunk = ctx.read(fd, max: 1 << 20)
                if chunk.isEmpty { break }
                data += chunk
            }
            box.bytes = data
            ctx.close(fd)
        }
        return box.bytes
    }

    /// The text of a file, or `<missing>`.
    func contents(of path: String) -> String {
        bytes(of: path).map { String(decoding: $0, as: UTF8.self) } ?? "<missing>"
    }

    func stat(_ path: String, follow: Bool = true) -> FileStat? {
        final class Box { var info: FileStat? }
        let box = Box()
        inProcess { ctx in box.info = follow ? ctx.stat(path) : ctx.lstat(path) }
        return box.info
    }

    func exists(_ path: String) -> Bool { stat(path, follow: false) != nil }
}
