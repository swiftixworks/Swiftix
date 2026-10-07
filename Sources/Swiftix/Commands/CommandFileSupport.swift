/// Path-level helpers shared by the filesystem built-ins: throwing wrappers that
/// report *why* an operation failed (ENOENT / EACCES / ENOTDIR / EISDIR / EEXIST /
/// ENOTEMPTY) instead of collapsing every failure to `nil`/`false`, plus the
/// formatting helpers (`ls -l` / `stat` mode and size columns) and the tree
/// walker used by `find`, `du`, `rm -r`, `cp -r`, `tree`, and `tar`.
///
/// The typed errors come from the capability-scoped syscall frontend
/// (`listDirectory(_:in:)`, `mkdir(_:in:)`, `unlinkFile(_:in:)`,
/// `removeDirectory(_:in:)`, `rename(_:in:to:in:)`): each helper scopes the call
/// to the path's parent directory and names the final component, so no new
/// kernel entry points are needed.
///
/// Concurrency: pure extensions over `ProcessContext`, used on the single
/// loop-bound executor like every other command helper. No state, no locks.

extension ProcessContext {

    /// Split a path into its (absolute, normalized) parent directory and final
    /// component. `nil` for the root directory, which has neither.
    func splitPath(_ path: String) -> (parent: String, name: String)? {
        let resolved = absolute(path)
        guard resolved != "/", let slash = resolved.lastIndex(of: "/") else { return nil }
        let parent = resolved[..<slash]
        let name = resolved[resolved.index(after: slash)...]
        return (parent.isEmpty ? "/" : String(parent), String(name))
    }

    /// A scoped call reports a non-directory scope root as EINVAL; for a path
    /// operation that is ENOTDIR.
    private func pathError(_ error: Error) -> SyscallError {
        guard let error = error as? SyscallError else { return .inputOutput }
        return error == .invalidArgument ? .notADirectory : error
    }

    /// Metadata without following a final symlink, or the reason there is none:
    /// EACCES when a directory on the way refuses search, ENOTDIR when an
    /// intermediate component is not a directory, else ENOENT.
    func lstatOrThrow(_ path: String) throws -> FileStat {
        if let info = lstat(path) { return info }
        throw missingReason(path)
    }

    /// Metadata following symlinks, or the reason there is none.
    func statOrThrow(_ path: String) throws -> FileStat {
        if let info = stat(path) { return info }
        throw missingReason(path)
    }

    /// Why `path` has no metadata: EACCES, ENOTDIR, or ENOENT.
    func missingReason(_ path: String) -> SyscallError {
        if case .searchDenied = resolvePath(path, follow: false) { return .permissionDenied }
        var prefix = ""
        for part in absolute(path).split(separator: "/") {
            guard let info = stat(prefix.isEmpty ? "/" : prefix) else { return .noSuchFileOrDirectory }
            if !info.isDirectory { return .notADirectory }
            prefix += "/" + part
        }
        return .noSuchFileOrDirectory
    }

    /// The entries of the directory at `path` (name + type, sorted by name;
    /// symlinks are reported as symlinks). Throws ENOENT, ENOTDIR, or EACCES.
    func directoryEntries(_ path: String) throws -> [FileSystemDirectoryEntry] {
        do {
            return try listDirectory(".", in: FileSystemScope(rootPath: absolute(path)))
        } catch {
            throw pathError(error)
        }
    }

    /// Create exactly one directory (no implicit parents). Throws EEXIST, ENOENT
    /// (missing parent), ENOTDIR, or EACCES.
    func makeDirectory(_ path: String) throws {
        guard let (parent, name) = splitPath(path) else { throw SyscallError.fileExists }
        do {
            try mkdir(name, in: FileSystemScope(rootPath: parent))
        } catch {
            throw pathError(error)
        }
    }

    /// Remove a non-directory. Throws ENOENT, EISDIR, ENOTDIR, or EACCES.
    func unlinkOrThrow(_ path: String) throws {
        guard let (parent, name) = splitPath(path) else { throw SyscallError.isADirectory }
        do {
            try unlinkFile(name, in: FileSystemScope(rootPath: parent))
        } catch {
            throw pathError(error)
        }
    }

    /// Remove an empty directory. Throws ENOENT, ENOTDIR, ENOTEMPTY, or EACCES.
    func removeDirectoryOrThrow(_ path: String) throws {
        guard let (parent, name) = splitPath(path) else { throw SyscallError.permissionDenied }
        do {
            try removeDirectory(name, in: FileSystemScope(rootPath: parent))
        } catch {
            throw pathError(error)
        }
    }

    /// Rename `source` to `destination` (same node, so open descriptors and hard
    /// links survive). Throws ENOENT, EACCES, EISDIR/ENOTDIR on a type clash,
    /// ENOTEMPTY, or EINVAL for a move into the source's own subtree.
    func renameOrThrow(_ source: String, to destination: String) throws {
        guard let (sourceParent, sourceName) = splitPath(source),
              let (destinationParent, destinationName) = splitPath(destination) else {
            throw SyscallError.invalidArgument
        }
        guard lstat(source) != nil else { throw missingReason(source) }
        guard let parentInfo = stat(destinationParent) else { throw missingReason(destination) }
        guard parentInfo.isDirectory else { throw SyscallError.notADirectory }
        try rename(sourceName, in: FileSystemScope(rootPath: sourceParent),
                   to: destinationName, in: FileSystemScope(rootPath: destinationParent))
    }

    /// Open `path` for writing, creating it when missing. Unlike the legacy
    /// convenience `open(create:)`, a missing parent directory is ENOENT rather
    /// than being created on the fly.
    func openForWriting(_ path: String, truncate: Bool = true, append: Bool = false) throws -> Int {
        if lstat(path) == nil, let (parent, _) = splitPath(path) {
            guard let parentInfo = stat(parent) else { throw missingReason(path) }
            guard parentInfo.isDirectory else { throw SyscallError.notADirectory }
        }
        var flags: OpenFlags = [.create]
        if truncate, !append { flags.insert(.truncate) }
        if append { flags.insert(.append) }
        return try openFile(path, flags: flags, access: .readWrite)
    }

    /// Join a directory path and an entry name without doubling the slash.
    func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}

extension BuiltinCommands {

    // MARK: - Formatting hooks

    /// The permission bits above `rwxrwxrwx`.
    static let setuidBit: UInt16 = 0o4000
    static let setgidBit: UInt16 = 0o2000
    static let stickyBit: UInt16 = 0o1000

    /// `rwxrwxrwx` with the setuid/setgid/sticky bits folded into the execute
    /// columns the way `ls -l` shows them (`s`/`S`, `t`/`T`).
    static func permissionString(_ mode: FileMode) -> String {
        var chars = Array(modeString(mode))
        let raw = mode.rawValue
        if raw & setuidBit != 0 { chars[2] = chars[2] == "x" ? "s" : "S" }
        if raw & setgidBit != 0 { chars[5] = chars[5] == "x" ? "s" : "S" }
        if raw & stickyBit != 0 { chars[8] = chars[8] == "x" ? "t" : "T" }
        return String(chars)
    }

    /// The type character `ls -l` leads a mode string with.
    static func typeCharacter(_ type: FileType) -> Character {
        if type == .directory { return "d" }
        if type == .symlink { return "l" }
        if type == .fifo { return "p" }
        return "-"
    }

    /// Zero-padded 4-digit octal mode (`0644`, `1777`).
    static func octalMode(_ mode: FileMode) -> String {
        let digits = String(mode.rawValue & 0o7777, radix: 8)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    /// Size with a unit suffix the way `ls -h` / `du -h` print it (`512`, `1.5K`,
    /// `12K`, `3.4M`): one decimal below 10 units, none above, rounded up.
    static func humanSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes)" }
        var value = Double(bytes)
        var unit = 0
        let units: [Character] = ["K", "M", "G", "T", "P"]
        value /= 1024
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if value < 10 {
            let tenths = Int((value * 10).rounded(.up))
            if tenths < 100 { return "\(tenths / 10).\(tenths % 10)\(units[unit])" }
            return "10\(units[unit])"
        }
        return "\(Int(value.rounded(.up)))\(units[unit])"
    }

    // MARK: - Paths

    /// The final component of a path (`/` for the root, trailing slashes ignored).
    static func baseName(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if let last = parts.last { return String(last) }
        return path.isEmpty ? "" : "/"
    }

    /// The directory portion of a path, as `dirname(1)` prints it.
    static func directoryName(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        var head = trimmed[..<slash]
        while head.count > 1, head.hasSuffix("/") { head = head.dropLast() }
        return head.isEmpty ? "/" : String(head)
    }

    /// Shell-style wildcard match (`*`, `?`, `[abc]`, `[a-z]`, `[!x]`, `\x`) of a
    /// whole string, used by `find -name` / `-path` and `tar` member selection.
    static func wildcardMatch(_ pattern: String, _ text: String, ignoreCase: Bool = false) -> Bool {
        let p = Array(ignoreCase ? pattern.lowercased() : pattern)
        let t = Array(ignoreCase ? text.lowercased() : text)
        func matchClass(_ start: Int, _ ch: Character) -> (matched: Bool, next: Int)? {
            var i = start + 1
            var negated = false
            if i < p.count, p[i] == "!" || p[i] == "^" { negated = true; i += 1 }
            var matched = false
            var first = true
            while i < p.count, first || p[i] != "]" {
                first = false
                let low = p[i]
                if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]" {
                    if low <= ch, ch <= p[i + 2] { matched = true }
                    i += 3
                } else {
                    if low == ch { matched = true }
                    i += 1
                }
            }
            guard i < p.count else { return nil }   // unterminated: not a class
            return (matched != negated, i + 1)
        }
        func match(_ pi: Int, _ ti: Int) -> Bool {
            var pi = pi, ti = ti
            while pi < p.count {
                let c = p[pi]
                if c == "*" {
                    while pi < p.count, p[pi] == "*" { pi += 1 }
                    if pi == p.count { return true }
                    var k = ti
                    while k <= t.count {
                        if match(pi, k) { return true }
                        k += 1
                    }
                    return false
                }
                guard ti < t.count else { return false }
                if c == "?" {
                    pi += 1; ti += 1
                } else if c == "[", let (ok, next) = matchClass(pi, t[ti]) {
                    if !ok { return false }
                    pi = next; ti += 1
                } else if c == "\\", pi + 1 < p.count {
                    if p[pi + 1] != t[ti] { return false }
                    pi += 2; ti += 1
                } else {
                    if c != t[ti] { return false }
                    pi += 1; ti += 1
                }
            }
            return ti == t.count
        }
        return match(0, 0)
    }
}
