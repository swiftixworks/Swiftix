import Swiftix
import SwiftixPackages
import Testing

/// A single Swiftix host wired for package-manager tests: a kernel on a
/// deterministic loop, the built-in command set plus the package commands, an
/// optional loopback interface, and a shell on a pty so commands are exercised
/// exactly the way a user would type them.
///
/// Everything is driven by logical time (`advance`/`runNext`), so the tests never
/// depend on the wall clock: an HTTP download over the emulated stack completes
/// because the loop was pumped, not because a sleep was long enough.
final class PackageTestHost {

    let loop = EventLoop()
    let kernel: Kernel
    let registry: CommandRegistry

    /// Output collected from the console boundary.
    private final class Sink { var bytes: [UInt8] = [] }

    private let pty = PseudoTerminal()
    private let sink = Sink()
    private var commandCounter = 0

    /// Result of one shell command.
    struct CommandResult {
        let status: Int32
        let output: String

        func contains(_ needle: String) -> Bool { output.contains(needle) }

        /// The captured console text as an `#expect` message, so a failing
        /// expectation shows what the command actually printed.
        var comment: Comment { Comment(rawValue: output) }
    }

    init(loopback: Bool = false) {
        kernel = Kernel(loop: loop)
        registry = CommandRegistry.builtins
        SwiftixPackages.register(in: registry)

        if loopback { configureLoopback() }

        let sink = self.sink
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            sink.bytes.append(contentsOf: pty.readForApp(max: 1 << 20))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave, commands: registry))
        loop.runUntilIdle()
    }

    /// 127.0.0.1/8 with egress looped straight back into ingress — the same wiring
    /// the app's `TerminalHost` installs, so `httpd` and `pkg` can talk on one host.
    private func configureLoopback() {
        kernel.netns.stack.configure(
            .addInterface(
                NetworkInterfaceConfiguration(
                    address: IPv4Address(127, 0, 0, 1),
                    mac: MACAddress("00:00:00:00:00:00")!,
                    prefixLength: 8)))
        guard let lo = kernel.netns.stack.interface(at: 0) else { return }
        let loop = self.loop
        lo.onEgress = { [weak kernel, weak lo] frame in
            guard let kernel, let lo else { return }
            loop.schedule(after: 0) { kernel.netns.stack.receive(frame, on: lo) }
        }
    }

    // MARK: - Filesystem helpers

    /// Run a short synchronous body in its own process and pump to idle.
    func perform(_ body: @escaping (ProcessContext) -> Void) {
        kernel.spawn("test-helper") { context in
            body(context)
            context.exit(0)
        }
        loop.runUntilIdle()
    }

    func writeFile(_ path: String, _ text: String, mode: FileMode = .regularDefault) {
        perform { context in
            _ = context.mkdir(PackageTestHost.parent(of: path))
            guard let descriptor = context.open(path, create: true, truncate: true) else { return }
            _ = context.write(descriptor, Array(text.utf8))
            context.close(descriptor)
            _ = context.chmod(path, mode: mode)
        }
    }

    func readFile(_ path: String) -> String? {
        final class Box { var text: String? }
        let box = Box()
        perform { context in
            guard let descriptor = context.open(path) else { return }
            var bytes: [UInt8] = []
            while true {
                let chunk = context.read(descriptor, max: 1 << 16)
                if chunk.isEmpty { break }
                bytes.append(contentsOf: chunk)
            }
            context.close(descriptor)
            box.text = String(decoding: bytes, as: UTF8.self)
        }
        return box.text
    }

    func exists(_ path: String) -> Bool {
        final class Box { var value = false }
        let box = Box()
        perform { context in box.value = context.lstat(path) != nil }
        return box.value
    }

    func mode(of path: String) -> FileMode? {
        final class Box { var mode: FileMode? }
        let box = Box()
        perform { context in box.mode = context.stat(path)?.mode }
        return box.mode
    }

    /// Repository authoring is deliberately not a user-facing package-manager
    /// command. Tests call the library API directly to prepare fixture archives.
    func buildPackage(manifestPath: String, root: String, output: String) throws {
        final class Box { var error: Error? }
        let box = Box()
        perform { context in
            do {
                try PackageManager(context: context).pack(
                    manifestPath: manifestPath,
                    root: root,
                    output: output)
            } catch {
                box.error = error
            }
        }
        if let error = box.error { throw error }
    }

    func indexRepository(_ directory: String) throws {
        final class Box { var error: Error? }
        let box = Box()
        perform { context in
            do {
                try PackageManager(context: context).makeIndex(directory: directory)
            } catch {
                box.error = error
            }
        }
        if let error = box.error { throw error }
    }

    /// Corrupt one byte of a file — used to prove digest verification actually
    /// prevents an installation.
    func corrupt(_ path: String) {
        perform { context in
            guard let descriptor = context.open(path) else { return }
            var bytes: [UInt8] = []
            while true {
                let chunk = context.read(descriptor, max: 1 << 16)
                if chunk.isEmpty { break }
                bytes.append(contentsOf: chunk)
            }
            context.close(descriptor)
            guard bytes.count > 4 else { return }
            bytes[bytes.count - 2] ^= 0x01
            guard let writer = context.open(path, create: true, truncate: true) else { return }
            _ = context.write(writer, bytes)
            context.close(writer)
        }
    }

    // MARK: - Command execution

    /// Type `command` at the shell, wait for it to finish, and return its exit
    /// status and output. Completion is detected with a marker echo, which also
    /// carries `$?` — no timing assumptions.
    @discardableResult
    func run(_ command: String) async -> CommandResult {
        commandCounter += 1
        let marker = "@@rc\(commandCounter)="
        sink.bytes.removeAll(keepingCapacity: true)
        pty.writeFromApp(Array("\(command); echo \(marker)$?\n".utf8))
        loop.runUntilIdle()

        await drive { Self.status(in: self.text, marker: marker) != nil }
        let output = text
        return CommandResult(status: Self.status(in: output, marker: marker) ?? -1, output: output)
    }

    /// Start a long-running command in the background (`httpd &`) and let it reach
    /// its listening state.
    func startBackground(_ command: String) async {
        sink.bytes.removeAll(keepingCapacity: true)
        pty.writeFromApp(Array("\(command) &\n".utf8))
        loop.runUntilIdle()
        await drive(maxIterations: 4_000) { false }
    }

    var text: String { String(decoding: sink.bytes, as: UTF8.self) }

    /// Pump the loop until `done()` or the iteration budget runs out. Time is
    /// nudged forward periodically so TCP timers can fire.
    private func drive(maxIterations: Int = 200_000, until done: () -> Bool) async {
        var iterations = 0
        while !done(), iterations < maxIterations {
            loop.advance(by: 0)
            loop.runNext()
            if iterations % 256 == 255 { loop.advance(by: 0.01) }
            await Task.yield()
            iterations += 1
        }
    }

    /// Extract the exit status that follows `marker` in the captured output. The
    /// echoed input line also contains the marker, so only an occurrence followed
    /// by digits counts.
    private static func status(in text: String, marker: String) -> Int32? {
        var remainder = Substring(text)
        while let found = remainder.firstRange(of: marker) {
            let after = remainder[found.upperBound...]
            let digits = after.prefix { $0.isNumber }
            if !digits.isEmpty, let value = Int32(digits) { return value }
            remainder = after
        }
        return nil
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[path.startIndex..<slash])
    }
}
