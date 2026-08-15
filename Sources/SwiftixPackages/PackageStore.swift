/// Filesystem plumbing, expressed only through public syscalls.
///
/// Two rules shape this file. First, *every* write that must not be observed
/// half-finished goes through `writeAtomically`: content is written to a
/// temporary name in the destination directory and then `rename`d over the
/// target, which the VFS implements as an atomic re-parent that also keeps
/// already-open descriptors valid. Second, nothing here reaches past
/// `ProcessContext` — no VFS nodes, no mount internals — so the installer obeys
/// the same permission and namespace rules as any other program.

import Swiftix

enum PackageStore {

    /// Read a whole file, or `nil` when it does not exist. Anything larger than
    /// `maximumBytes` is a hard error rather than a truncated read.
    static func read(
        _ context: ProcessContext,
        _ path: String,
        maximumBytes: Int
    ) throws -> [UInt8]? {
        guard let status = context.stat(path) else { return nil }
        guard !status.isDirectory else {
            throw PackageError.ioFailure(path: path, operation: "read")
        }
        guard let descriptor = context.open(path) else {
            throw PackageError.ioFailure(path: path, operation: "open")
        }
        defer { context.close(descriptor) }
        var bytes: [UInt8] = []
        while bytes.count <= maximumBytes {
            let chunk = context.read(descriptor, max: 1 << 16)
            if chunk.isEmpty { break }
            bytes.append(contentsOf: chunk)
        }
        guard bytes.count <= maximumBytes else {
            throw PackageError.responseTooLarge(url: path, limit: maximumBytes)
        }
        return bytes
    }

    /// Read a file that must exist.
    static func readRequired(
        _ context: ProcessContext,
        _ path: String,
        maximumBytes: Int
    ) throws -> [UInt8] {
        guard let bytes = try read(context, path, maximumBytes: maximumBytes) else {
            throw PackageError.ioFailure(path: path, operation: "read")
        }
        return bytes
    }

    /// Write `bytes` to `path` so that observers only ever see the old or the new
    /// content: stage into the destination directory, then rename over the target.
    static func writeAtomically(
        _ context: ProcessContext,
        _ path: String,
        bytes: [UInt8],
        mode: UInt16? = nil
    ) throws {
        let directory = PackagePath.parent(of: path)
        _ = try makeDirectories(context, directory)
        let temporary = try temporaryPath(
            context,
            in: directory,
            prefix: PackagePath.lastComponent(of: path))
        try write(context, temporary, bytes: bytes)
        if let mode { _ = context.chmod(temporary, mode: fileMode(mode)) }
        try move(context, from: temporary, to: path)
    }

    /// Plain (non-atomic) write, used for staging files a transaction will rename
    /// into place itself.
    static func write(_ context: ProcessContext, _ path: String, bytes: [UInt8]) throws {
        guard let descriptor = context.open(path, create: true, truncate: true) else {
            throw PackageError.ioFailure(path: path, operation: "create")
        }
        let written = context.write(descriptor, bytes)
        context.close(descriptor)
        guard written == bytes.count else {
            throw PackageError.ioFailure(path: path, operation: "write")
        }
    }

    /// `mkdir -p`, reporting which directories it had to create so a rollback can
    /// remove exactly those and leave pre-existing ones alone.
    @discardableResult
    static func makeDirectories(_ context: ProcessContext, _ path: String) throws -> [String] {
        guard path != "/" else { return [] }
        var created: [String] = []
        for ancestor in PackagePath.ancestors(of: path) {
            if let status = context.stat(ancestor) {
                guard status.isDirectory else {
                    throw PackageError.ioFailure(path: ancestor, operation: "create directory at")
                }
                continue
            }
            guard context.mkdir(ancestor) else {
                throw PackageError.ioFailure(path: ancestor, operation: "create directory")
            }
            created.append(ancestor)
        }
        return created
    }

    /// Rename within the VFS. Uses a capability scope rooted at `/`, which is the
    /// only `rename` the syscall surface exposes; it preserves the node, so open
    /// descriptors keep working across the swap.
    static func move(_ context: ProcessContext, from source: String, to destination: String) throws {
        let scope = FileSystemScope(rootPath: "/")
        do {
            try context.rename(
                PackagePath.relativeToRoot(source), in: scope,
                to: PackagePath.relativeToRoot(destination), in: scope)
        } catch {
            throw PackageError.ioFailure(path: destination, operation: "install")
        }
    }

    /// Remove a file (or empty directory). Missing paths are not an error, so
    /// rollback and removal stay idempotent.
    static func removeIfPresent(_ context: ProcessContext, _ path: String) {
        guard context.lstat(path) != nil else { return }
        _ = context.remove(path)
    }

    static func exists(_ context: ProcessContext, _ path: String) -> Bool {
        context.lstat(path) != nil
    }

    static func isDirectory(_ context: ProcessContext, _ path: String) -> Bool {
        context.stat(path)?.isDirectory == true
    }

    /// Whether a directory holds no entries (safe on a missing path).
    static func isEmptyDirectory(_ context: ProcessContext, _ path: String) -> Bool {
        guard let entries = context.listDirectory(path) else { return false }
        return entries.isEmpty
    }

    /// Regular-file names directly inside `directory` (no recursion), sorted.
    static func fileNames(_ context: ProcessContext, in directory: String) -> [String] {
        guard let entries = context.listDirectory(directory) else { return [] }
        return entries.filter { !$0.hasSuffix("/") }.sorted()
    }

    /// Subdirectory names directly inside `directory`, sorted.
    static func directoryNames(_ context: ProcessContext, in directory: String) -> [String] {
        guard let entries = context.listDirectory(directory) else { return [] }
        return entries.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }.sorted()
    }

    /// An unused path in `directory` for staging. Derived from the process id and
    /// a bounded probe, so two concurrent package operations cannot collide.
    static func temporaryPath(
        _ context: ProcessContext,
        in directory: String,
        prefix: String
    ) throws -> String {
        let sanitized = prefix.isEmpty ? "pkg" : prefix
        for attempt in 0..<1024 {
            let candidate = PackagePath.join(
                directory, ".pkg-\(context.globalPID)-\(attempt)-\(sanitized)")
            if !exists(context, candidate) { return candidate }
        }
        throw PackageError.ioFailure(path: directory, operation: "allocate a staging file in")
    }

    /// Translate archive permission bits into the core's `FileMode`. Only the
    /// nine POSIX rwx bits are modeled by the VFS, so setuid/sticky bits in a
    /// manifest are dropped rather than silently misapplied.
    static func fileMode(_ mode: UInt16) -> FileMode {
        FileMode(rawValue: mode & 0o777)
    }
}
