/// Tab-completion for a shell prompt. The library owns the information a
/// completion needs — the command set (`CommandRegistry`), the filesystem
/// (VFS), and a process's working directory — so it computes *what* completes;
/// the consumer (terminal UI) decides *how* to insert/display it.
///
/// Completes the first word against command names, and later words against VFS
/// entries relative to the shell's current directory (directories get a trailing
/// "/"). Pure Swift, no platform deps.

/// The result of a completion request.
public struct ShellCompletion: Sendable, Equatable {
    /// Text to append after the current partial token. Empty when there is
    /// nothing unambiguous to add (e.g. several candidates share no longer
    /// prefix, or there are no matches).
    public let insertion: String

    /// All matching candidates (command names or entry names, dirs suffixed
    /// with "/"). Useful for listing when the completion is ambiguous.
    public let candidates: [String]

    public init(insertion: String, candidates: [String]) {
        self.insertion = insertion
        self.candidates = candidates
    }
}

extension Kernel {

    /// Compute a tab-completion for `line` typed at `shellPID`'s prompt.
    ///
    /// - The first word (or an empty line) completes against `commands`' names.
    /// - A later word completes against VFS entries, resolved relative to the
    ///   shell process's current directory; matching directories carry a
    ///   trailing "/".
    public func complete(line: String, commands: CommandRegistry, shellPID: PID) -> ShellCompletion {
        let endsWithSpace = line.last == " "
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let completingCommand = tokens.isEmpty || (tokens.count == 1 && !endsWithSpace)

        if completingCommand {
            let partial = endsWithSpace ? "" : (tokens.first ?? "")
            var names = Set(commands.names)
            names.formUnion(pathCommandNames(shellPID: shellPID))
            let candidates = names.filter { $0.hasPrefix(partial) }.sorted()
            return Self.finish(partial: partial, candidates: candidates)
        }

        // Completing a filesystem argument: split the token into a directory
        // portion (resolved against the cwd) and the name being completed.
        let token = endsWithSpace ? "" : (tokens.last ?? "")
        let cwd = process(shellPID)?.cwd ?? "/"
        let dirPart: String
        let namePart: String
        if let slash = token.lastIndex(of: "/") {
            dirPart = String(token[token.startIndex...slash])   // keeps the trailing "/"
            namePart = String(token[token.index(after: slash)...])
        } else {
            dirPart = ""
            namePart = token
        }
        let dirPath = Self.resolve(dirPart.isEmpty ? "." : dirPart, cwd: cwd)
        let entries = directoryEntries(dirPath) ?? []
        let candidates = entries.filter { $0.hasPrefix(namePart) }.sorted()
        return Self.finish(partial: namePart, candidates: candidates)
    }

    /// VFS entries at an absolute path (names, dirs suffixed with "/"), or `nil`
    /// if the path is not a directory.
    private func directoryEntries(_ absolutePath: String) -> [String]? {
        guard let node = vfs.lookup(absolutePath), node.kind == .directory else { return nil }
        return node.children.values.map { $0.kind == .directory ? $0.name + "/" : $0.name }
    }

    /// Executable regular files visible through the shell process's `$PATH`.
    /// This is completion-only discovery; actual format validation remains the
    /// responsibility of `CommandRegistry`'s executable loaders at launch time.
    private func pathCommandNames(shellPID: PID) -> Set<String> {
        guard let shell = process(shellPID) else { return [] }
        let path = shell.environment["PATH"] ?? ProcessContext.defaultExecutablePath
        var names: Set<String> = []
        for entry in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = Self.resolve(entry.isEmpty ? "." : String(entry), cwd: shell.cwd)
            guard let node = vfs.lookup(directory), node.kind == .directory else { continue }
            for child in node.children.values where child.kind == .file {
                let executable: FileMode = [
                    .ownerExecute, .groupExecute, .otherExecute,
                ]
                if !child.mode.intersection(executable).isEmpty {
                    names.insert(child.name)
                }
            }
        }
        return names
    }

    /// Build the insertion from the candidates: extend by their longest common
    /// prefix beyond the partial, and add a trailing space for a unique non-dir
    /// match (so the user can move on to the next word).
    private static func finish(partial: String, candidates: [String]) -> ShellCompletion {
        guard !candidates.isEmpty else { return ShellCompletion(insertion: "", candidates: []) }
        let common = longestCommonPrefix(candidates)
        var insertion = String(common.dropFirst(partial.count))
        if candidates.count == 1, !candidates[0].hasSuffix("/") {
            insertion += " "
        }
        return ShellCompletion(insertion: insertion, candidates: candidates)
    }

    private static func longestCommonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for string in strings.dropFirst() {
            while !string.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
                if prefix.isEmpty { return "" }
            }
        }
        return prefix
    }

    /// Resolve `path` against `cwd`, collapsing `.`/`..` — mirrors the syscall
    /// path resolution so completion sees the same tree.
    private static func resolve(_ path: String, cwd: String) -> String {
        let joined = path.hasPrefix("/")
            ? path
            : (cwd == "/" ? "/" + path : cwd + "/" + path)
        var stack: [Substring] = []
        for part in joined.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(part)
            }
        }
        return "/" + stack.joined(separator: "/")
    }
}
