/// The installed-package database: what is on this host, and which file belongs
/// to whom.
///
/// This is the record that makes the manager a package *manager* rather than a
/// downloader. It answers the three questions every operation needs:
///
///   * is `X` installed, and at which version (install / upgrade decisions)
///   * which files did `X` put on disk (clean removal)
///   * who owns `/bin/hello` (overwrite conflicts between packages)
///
/// It lives at `/var/lib/pkg/status` in stanza format, is rewritten
/// atomically, and is written *last* in a transaction — so a failure mid-install
/// leaves a database that still describes reality.

/// One installed package: its manifest, provenance, and the exact objects it owns.
public struct InstalledPackage: Sendable, Equatable {

    public let manifest: PackageManifest
    /// Repository the archive came from, or `"local"` for a direct file install.
    public let repository: String
    /// Files owned by this package, in install order.
    public let files: [String]
    /// Directories this package created (deepest-last), pruned on removal when
    /// they end up empty.
    public let directories: [String]
    public let installedSize: Int
    /// `true` when the package was pulled in as a dependency rather than asked
    /// for by name — the input `autoremove` needs.
    public let automatic: Bool

    public init(
        manifest: PackageManifest,
        repository: String,
        files: [String],
        directories: [String],
        installedSize: Int,
        automatic: Bool
    ) {
        self.manifest = manifest
        self.repository = repository
        self.files = files
        self.directories = directories
        self.installedSize = installedSize
        self.automatic = automatic
    }

    public var name: String { manifest.name }
    public var version: PackageVersion { manifest.version }

    func encoded() -> PackageStanza {
        var stanza = manifest.encoded()
        stanza.set("Status", "install ok installed")
        stanza.set("Repository", repository)
        stanza.set("InstalledSize", "\(installedSize)")
        stanza.set("Automatic", automatic ? "yes" : "no")
        stanza.append("Directory", directories)
        stanza.append("File", files)
        return stanza
    }

    /// Copy with a different `automatic` flag (installing a package explicitly
    /// promotes an already-present automatic one to manual).
    func marking(automatic newValue: Bool) -> InstalledPackage {
        InstalledPackage(
            manifest: manifest,
            repository: repository,
            files: files,
            directories: directories,
            installedSize: installedSize,
            automatic: newValue)
    }
}

public struct InstalledDatabase: Sendable {

    /// Installed packages keyed by name.
    public private(set) var packages: [String: InstalledPackage]

    public init(packages: [String: InstalledPackage] = [:]) {
        self.packages = packages
    }

    public var isEmpty: Bool { packages.isEmpty }

    /// Installed packages sorted by name — the order every listing uses.
    public var sorted: [InstalledPackage] {
        packages.values.sorted { $0.name < $1.name }
    }

    public func package(named name: String) -> InstalledPackage? { packages[name] }

    /// Name of the package owning `path`, or `nil` when no package claims it.
    public func owner(ofFile path: String) -> String? {
        for package in sorted where package.files.contains(path) { return package.name }
        return nil
    }

    /// Installed packages satisfying `dependency` (directly or via `Provides`).
    public func providers(of dependency: PackageDependency) -> [InstalledPackage] {
        sorted.filter { $0.manifest.satisfies(dependency) }
    }

    /// Whether some installed package satisfies `dependency`, ignoring the names
    /// in `excluding` (used when planning a removal: the packages on their way out
    /// no longer count as providers).
    public func satisfies(_ dependency: PackageDependency, excluding: Set<String> = []) -> Bool {
        providers(of: dependency).contains { !excluding.contains($0.name) }
    }

    public mutating func insert(_ package: InstalledPackage) {
        packages[package.name] = package
    }

    public mutating func remove(_ name: String) {
        packages[name] = nil
    }

    // MARK: - Encoding

    public static func parse(_ text: String) throws -> InstalledDatabase {
        var database = InstalledDatabase()
        for stanza in try PackageStanza.parse(text) {
            let manifest = try PackageManifest.decode(stanza, context: "status")
            let files = stanza.values(of: "File")
            let directories = stanza.values(of: "Directory")
            for path in files + directories {
                guard PackagePath.normalizeAbsolute(path) == path else {
                    throw PackageError.malformedDatabase(
                        reason: "package \(manifest.name) records a non-normalized path '\(path)'")
                }
            }
            let size = Int(stanza.value(of: "InstalledSize") ?? "0") ?? 0
            database.insert(
                InstalledPackage(
                    manifest: manifest,
                    repository: stanza.value(of: "Repository") ?? "local",
                    files: files,
                    directories: directories,
                    installedSize: size,
                    automatic: (stanza.value(of: "Automatic") ?? "no") == "yes"))
        }
        return database
    }

    public func rendered() -> String {
        PackageStanza.render(sorted.map { $0.encoded() })
    }
}
