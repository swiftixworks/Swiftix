/// SwiftixPackages: the distribution package manager for a Swiftix host — the
/// package-management layer of the system.
///
/// This target is the *policy* half of software distribution, kept out of the
/// core exactly like the Go toolchain: the core owns the VFS, the socket API and
/// the command registry, while this module adds
/// a repository protocol, a package format, dependency resolution and a
/// transactional installer on top of the public syscall surface. Nothing here
/// reaches into VFS nodes, sockets or process internals; every effect goes
/// through `ProcessContext`.
///
/// Layering: `SwiftixPackages` → `Swiftix` (public API only). The core never
/// depends on this target, so a consumer that does not want a package manager
/// simply does not link it.
///
/// Concurrency: the manager is an ordinary user program. It is constructed and
/// driven from the single serial executor that runs the kernel, holds no locks,
/// and is deliberately non-`Sendable` — the same contract as `ProcessContext`.
///
/// Network: repositories are plain HTTP (`http://`) or VFS-local (`file:///`).
/// Downloads use the core's TCP syscalls and resolver, so a repository can live
/// on any host reachable from the emulated topology, including a `httpd` running
/// on another Swiftix VM.

import Swiftix

public enum SwiftixPackages {

    /// On-disk format revision for the `.pkg` archive container. Repository
    /// indexes and the installed database use validated control stanzas but do
    /// not currently carry an independent format-version field.
    public static let formatVersion = 2

    /// Version string reported by `pkg --version`.
    public static let toolVersion = "pkg 1.0 (SwiftixPackages format v2)"

    /// Filename suffix of a package archive. Single source of truth: the
    /// installer, the repository indexer and `pkg install ./file` all derive the
    /// name from here rather than spelling it out.
    public static let archiveExtension = ".pkg"

    /// Register the `pkg` package-management command into `registry`.
    ///
    /// It is an ordinary `Command` value, so it resolves through the shell exactly
    /// like a built-in.
    public static func register(in registry: CommandRegistry) {
        PackageCommands.register(in: registry)
    }
}

/// Where the package manager keeps its state inside the VFS. The paths follow
/// the same FHS-shaped layout a Linux distribution uses, so the file tree is
/// recognizable (`/etc` configuration, `/var/lib` state, `/var/cache` transient
/// downloads).
public struct PackageLayout: Sendable, Equatable {

    /// Package repository source list.
    public let sourcesList: String
    /// Installed-package database (stanza format, one stanza per package).
    public let statusFile: String
    /// Cached repository indexes fetched by `update`.
    public let listsDirectory: String
    /// Downloaded `.pkg` archives.
    public let archivesDirectory: String
    /// Scratch area for in-flight transactions.
    public let stagingDirectory: String

    public init(
        sourcesList: String,
        statusFile: String,
        listsDirectory: String,
        archivesDirectory: String,
        stagingDirectory: String
    ) {
        self.sourcesList = sourcesList
        self.statusFile = statusFile
        self.listsDirectory = listsDirectory
        self.archivesDirectory = archivesDirectory
        self.stagingDirectory = stagingDirectory
    }

    public static let `default` = PackageLayout(
        sourcesList: "/etc/pkg/sources.list",
        statusFile: "/var/lib/pkg/status",
        listsDirectory: "/var/lib/pkg/lists",
        archivesDirectory: "/var/cache/pkg/archives",
        stagingDirectory: "/var/lib/pkg/updates")

    /// Directory holding the installed database; created on demand.
    public var stateDirectory: String { PackagePath.parent(of: statusFile) }
}

/// Hard limits. A package manager parses untrusted bytes off the network, so
/// every reader is bounded: an oversized or absurdly-shaped input is rejected
/// with a diagnostic instead of being allowed to exhaust memory.
public enum PackageLimits {
    /// Largest repository index accepted from a remote (4 MiB).
    public static let maximumIndexBytes = 4 << 20
    /// Largest `.pkg` archive accepted (32 MiB).
    public static let maximumArchiveBytes = 32 << 20
    /// Largest single file inside an archive (16 MiB).
    public static let maximumEntryBytes = 16 << 20
    /// Largest installed database accepted (8 MiB).
    public static let maximumDatabaseBytes = 8 << 20
    /// Largest number of entries in one archive.
    public static let maximumEntryCount = 4096
    /// Redirects followed while fetching one URL.
    public static let maximumRedirects = 3
}
