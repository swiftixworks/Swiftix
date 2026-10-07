/// The `sh` command and the file-backed loader that lets shell scripts run as
/// programs (`./x.sh arg`, or by name through `$PATH`).
///
/// Both are thin adapters onto the interpreter in `Shell/`: a script runs in its
/// own process, so `exit` ends only that script. Concurrency: like every
/// `Command`, constructed and run on the kernel's single serial executor.
enum ShellCommands {

    /// Register `sh` and the script loader in `registry`.
    static func register(in registry: CommandRegistry) {
        registry.register(Command(name: "sh", summary: "run a shell script, command string, or nested shell",
                                  category: .system,
                                  usage: """
                                  sh [-eux] [FILE [ARG]...] | sh -c STRING [NAME [ARG]...]
                                    -c STRING  run the commands in STRING
                                    -e         exit when a command fails
                                    -u         treat an unset variable as an error
                                    -x         trace commands as they run
                                  With no FILE, read commands from the terminal or standard input.
                                  """) { ctx, argv in
            Programs.runShellCommand(ctx, argv)
        }.answeringHelp())
        registry.registerExecutableLoader { context, path in
            scriptCommand(context, path: path)
        }
    }

    private static let shellNames: Set<String> = ["sh", "bash", "dash", "ash"]

    /// A command for the executable file at `path` when it is a script: one
    /// starting with `#!` (run by the named interpreter — the shell itself for
    /// `sh`/`bash`, any registered command otherwise) or a plain text file with
    /// no shebang (run by the shell). Files without an execute bit, empty
    /// files, and binary images are left to other loaders.
    private static func scriptCommand(_ context: ProcessContext, path: String) -> Command? {
        guard path.contains("/"), let info = context.stat(path), info.type == .regular,
              info.size > 0, context.canExecute(path),
              let descriptor = context.open(path) else {
            return nil
        }
        let head = context.read(descriptor, max: 256)
        context.close(descriptor)
        guard !head.isEmpty else { return nil }

        let shellScript = Command(name: path, summary: "shell script") { child, argv in
            Programs.runShellScript(child, path: path, arguments: Array(argv.dropFirst()))
        }
        guard head.starts(with: Array("#!".utf8)) else {
            // No shebang: only a text file is taken to be a shell script.
            let isText = !head.contains { $0 == 0 || ($0 < 0x09) || ($0 > 0x0D && $0 < 0x20 && $0 != 0x1B) }
            return isText ? shellScript : nil
        }
        let line = String(decoding: head.dropFirst(2).prefix { $0 != 0x0A }, as: UTF8.self)
        var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
        guard !words.isEmpty else { return shellScript }
        func baseName(_ word: String) -> String { String(word.split(separator: "/").last ?? "") }
        if baseName(words[0]) == "env", words.count > 1 { words.removeFirst() }
        let interpreter = words[0]
        let name = baseName(interpreter)
        if shellNames.contains(name) { return shellScript }
        guard interpreter != path,
              let program = context.resolveCommand(interpreter) ?? context.resolveCommand(name) else {
            return Command(name: path, summary: "script with a missing interpreter") { child, _ in
                child.fail("\(path): \(interpreter): bad interpreter: No such file or directory", code: 126)
            }
        }
        let interpreterArguments = [name] + words.dropFirst() + [path]
        switch program.body {
        case let .sync(run):
            return Command(name: path, summary: "script") { child, argv in
                run(child, interpreterArguments + argv.dropFirst())
            }
        case let .async(run):
            return Command(name: path, summary: "script", asyncRun: { child, argv in
                await run(child, interpreterArguments + argv.dropFirst())
            })
        }
    }
}
