/// File-backed command loader for precompiled Swiftix Go executable images.
///
/// Keeping this in the runtime target lets applications execute checked-in
/// images without linking the Go parser, type checker, or compiler.

import Swiftix

public enum GoExecutableLoader {
    public static func register(in registry: CommandRegistry) {
        registry.registerExecutableLoader { context, path in
            executableCommand(context, path: path)
        }
    }

    private static func executableCommand(
        _ context: ProcessContext,
        path: String
    ) -> Command? {
        guard path.contains("/"), let stat = context.stat(path), !stat.isDirectory,
            stat.size <= GoExecutableImage.maximumImageSize
        else {
            return nil
        }

        let bytes: [UInt8]
        do {
            let descriptor = try context.openFile(path, access: .readOnly)
            defer { try? context.closeFile(descriptor) }
            bytes = try context.readFile(
                descriptor,
                max: GoExecutableImage.maximumImageSize + 1)
        } catch {
            return nil
        }
        guard bytes.count <= GoExecutableImage.maximumImageSize,
            GoExecutableImage.recognizes(bytes)
        else {
            return nil
        }
        guard context.canExecute(path) else {
            return failingExecutable(path: path, message: "permission denied", status: 126)
        }

        let executable: GoExecutable
        do {
            executable = try GoExecutableImage.decode(bytes)
        } catch {
            return failingExecutable(
                path: path,
                message: "exec format error: \(String(describing: error))",
                status: 126)
        }

        return Command(name: path, summary: "Swiftix Go executable") { child, arguments in
            do {
                let exitCode = try GoVirtualMachine().run(
                    executable,
                    eventLoop: child.eventLoop,
                    processContext: child,
                    arguments: arguments
                ) { text in
                    _ = child.write(1, Array(text.utf8))
                }
                child.exit(exitCode)
            } catch {
                writeError(child, "\(path): \(String(describing: error))\n")
                child.exit(1)
            }
        }
    }

    private static func failingExecutable(
        path: String,
        message: String,
        status: Int32
    ) -> Command {
        Command(name: path, summary: "invalid Swiftix Go executable") { context, _ in
            writeError(context, "\(path): \(message)\n")
            context.exit(status)
        }
    }

    private static func writeError(_ context: ProcessContext, _ message: String) {
        _ = context.write(2, Array(message.utf8))
    }
}
