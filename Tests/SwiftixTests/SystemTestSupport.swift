@testable import Swiftix

/// Test-only fixture for the userland-baseline suites: one kernel whose PID 1 is
/// an interactive shell on a PTY, like a terminal session in a host app.
///
/// Everything is driven on the logical clock (`runUntilIdle`), so the suites
/// that use it are deterministic and wall-clock free.
final class SystemSession {
    let loop = EventLoop()
    let kernel: Kernel
    let pty = PseudoTerminal()
    /// PID of the session shell (PID 1 unless `beforeShell` spawned something).
    private(set) var shellPID: PID = 0
    private var output: [UInt8] = []

    init(configure: (Kernel) -> Void = { _ in },
         register: (CommandRegistry) -> Void = { _ in }) {
        kernel = Kernel(loop: loop)
        configure(kernel)
        let registry = CommandRegistry.builtins
        register(registry)
        pty.echo = false
        pty.onOutput = { [weak self] in
            guard let self else { return }
            self.output.append(contentsOf: self.pty.readForApp(max: 1 << 20))
        }
        shellPID = kernel.spawn("sh", Programs.shell(tty: pty.slave, commands: registry))
        loop.runUntilIdle()
        output.removeAll()
    }

    /// Type one line at the shell and return everything it printed in response
    /// (command output followed by the next prompt).
    @discardableResult
    func run(_ line: String) -> String {
        output.removeAll()
        pty.writeFromApp(Array((line + "\n").utf8))
        loop.runUntilIdle()
        return String(decoding: output, as: UTF8.self)
    }

    /// The lines a command printed, without the trailing prompt line.
    func lines(_ line: String) -> [String] {
        var rows = run(line).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !rows.isEmpty { rows.removeLast() }   // the prompt that follows the output
        return rows
    }

    /// Create (or replace) a file as root, outside the shell.
    func write(_ path: String, _ text: String) {
        kernel.spawn("write") { ctx in
            guard let fd = ctx.open(path, create: true, truncate: true) else { return }
            ctx.write(fd, Array(text.utf8))
            ctx.close(fd)
        }
        loop.runUntilIdle()
    }

    /// Run `body` as a fresh top-level root process and return its result.
    func inProcess<T>(_ body: @escaping (ProcessContext) -> T) -> T? {
        let box = ResultBox<T>()
        kernel.spawn("probe") { ctx in box.value = body(ctx) }
        loop.runUntilIdle()
        return box.value
    }

    var shellIsAlive: Bool {
        kernel.snapshotProcesses().contains { $0.pid == shellPID && $0.lifecycle == .live }
    }
}

/// Run `body` as a top-level root process on a fresh kernel and return its result.
func runInFreshKernel<T>(configure: (Kernel) -> Void = { _ in },
                         _ body: @escaping (ProcessContext) -> T) -> T? {
    let loop = EventLoop()
    let kernel = Kernel(loop: loop)
    configure(kernel)
    let box = ResultBox<T>()
    kernel.spawn("probe") { ctx in box.value = body(ctx) }
    loop.runUntilIdle()
    return box.value
}

/// Single-executor result holder for values captured from a process body.
final class ResultBox<T> {
    var value: T?
}
