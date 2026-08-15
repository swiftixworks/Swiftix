/// Shared fixtures for the Swiftix Go test suites.
///
/// These used to be private members of one 3249-line `SwiftixGoTests` struct that
/// held all 127 tests. Splitting that file per feature area left the helpers with
/// no single owner, so they live here as a protocol with default implementations:
/// every suite conforms to `GoTestHarness` and keeps calling `runShell(...)` /
/// `Self.write(...)` exactly as before.
///
/// Concurrency: each helper builds its own `EventLoop` + `Kernel` and drives them
/// to quiescence on the calling executor, matching the single-serial-executor
/// contract. Nothing is shared between suites, so tests stay parallel-safe and
/// nothing here is (or needs to be) `Sendable`.

import Testing

@testable import Swiftix
@testable import SwiftixGoTool

protocol GoTestHarness {}

extension GoTestHarness {

    /// Runs `lines` through a real shell on a fresh kernel and returns everything
    /// the terminal emitted.
    ///
    /// `seed` runs first as its own process, which is how a test populates the VFS
    /// (Go sources, `go.mod`, module caches) before the shell starts. The loop is
    /// driven to idle after the seed and after every line, so the returned output
    /// is complete for each command.
    func runShell(
        _ lines: [String],
        seed: ((ProcessContext) -> Void)? = nil
    ) -> String {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        if let seed {
            kernel.spawn("seed") { context in
                seed(context)
                context.exit(0)
            }
            loop.runUntilIdle()
        }

        let terminal = PseudoTerminal()
        var output: [UInt8] = []
        terminal.onOutput = { [weak terminal] in
            guard let terminal else { return }
            output.append(contentsOf: terminal.readForApp(max: 65_535))
        }
        let registry = CommandRegistry.builtins
        GoToolchain.register(in: registry)
        kernel.spawn("sh", Programs.shell(tty: terminal.slave, commands: registry))
        loop.runUntilIdle()
        for line in lines {
            terminal.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Lines emitted by commands, excluding the dynamic interactive prompt and
    /// the command text echoed after it.
    func shellResultLines(_ output: String) -> [Substring] {
        output.split(separator: "\n").filter { line in
            guard let at = line.firstIndex(of: "@"),
                let colon = line[at...].firstIndex(of: ":"),
                let marker = line[colon...].firstIndex(where: { $0 == "#" || $0 == "$" })
            else { return true }
            let afterMarker = line.index(after: marker)
            return afterMarker >= line.endIndex || line[afterMarker] != " "
        }
    }

    /// Writes `contents` to `path` in the guest VFS, creating or truncating it.
    static func write(_ context: ProcessContext, path: String, contents: String) {
        writeBytes(context, path: path, contents: Array(contents.utf8))
    }

    /// Byte-level variant of ``write(_:path:contents:)``, for fixtures that must
    /// contain invalid UTF-8 or a deliberately corrupted image.
    static func writeBytes(
        _ context: ProcessContext,
        path: String,
        contents: [UInt8]
    ) {
        let descriptor = context.open(path, create: true, truncate: true)!
        context.write(descriptor, contents)
        context.close(descriptor)
    }
}
