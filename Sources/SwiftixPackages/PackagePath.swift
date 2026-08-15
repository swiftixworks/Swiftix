/// Path handling for install targets.
///
/// Package payloads are attacker-controlled data, so path validation is a
/// security boundary, not a convenience: a manifest may not escape the tree with
/// `..`, may not touch synthetic filesystems (`/proc`, `/dev`, `/sys`), and may
/// not rewrite the package manager's own database out from under a running
/// transaction. Everything else in the module works with the normalized absolute
/// form produced here.

enum PackagePath {

    /// Directory prefixes a package may never write to. `/proc`, `/dev` and
    /// `/sys` are kernel-synthesized; package-manager state is owned by the manager
    /// database, and letting a payload replace it would defeat every other check.
    static let forbiddenPrefixes = [
        "/proc", "/dev", "/sys", "/var/lib/pkg", "/var/cache/pkg",
    ]

    /// Normalize an absolute path: collapse `//`, resolve `.` and reject any
    /// attempt to climb above the root. Returns `nil` for relative or malformed
    /// paths, so callers can turn it straight into `PackageError.forbiddenPath`.
    static func normalizeAbsolute(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.count <= 4096 else { return nil }
        guard !path.contains("\n"), !path.contains("\t"), !path.contains("\0") else { return nil }
        var components: [String] = []
        for raw in path.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(raw)
            switch part {
            case ".":
                continue
            case "..":
                return nil  // never resolve upward: reject outright
            default:
                components.append(part)
            }
        }
        guard !components.isEmpty else { return nil }
        return "/" + components.joined(separator: "/")
    }

    /// Whether a *normalized* path may be created or replaced by a package.
    static func isInstallable(_ normalized: String) -> Bool {
        for prefix in forbiddenPrefixes {
            if normalized == prefix || normalized.hasPrefix(prefix + "/") { return false }
        }
        return true
    }

    /// Normalize and authorize in one step.
    static func validateInstallTarget(_ path: String) throws -> String {
        guard let normalized = normalizeAbsolute(path), isInstallable(normalized) else {
            throw PackageError.forbiddenPath(path: path)
        }
        return normalized
    }

    /// Parent directory of an absolute path (`/bin/hello` → `/bin`, `/bin` → `/`).
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        if slash == path.startIndex { return "/" }
        return String(path[path.startIndex..<slash])
    }

    /// Final component of a path (`/bin/hello` → `hello`).
    static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Join a directory with a relative component.
    static func join(_ directory: String, _ component: String) -> String {
        if directory.isEmpty || directory == "/" { return "/" + component }
        if directory.hasSuffix("/") { return directory + component }
        return directory + "/" + component
    }

    /// Every ancestor of `path` from the shallowest to the deepest, excluding
    /// `/` itself: `/usr/share/doc` → `["/usr", "/usr/share", "/usr/share/doc"]`.
    /// Used to record which directories a transaction created so a rollback can
    /// take them back out.
    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            result.append(current)
        }
        return result
    }

    /// Drop the leading `/` so the path can be used with a `FileSystemScope`
    /// rooted at `/` (capability-scoped calls reject absolute paths by design).
    static func relativeToRoot(_ absolute: String) -> String {
        absolute.hasPrefix("/") ? String(absolute.dropFirst()) : absolute
    }
}
