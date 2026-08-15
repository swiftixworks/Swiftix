/// The package manager itself: the operations `pkg` exposes, wired to the
/// repository index, the resolver and the transactional installer.
///
/// State lives entirely in the VFS (`PackageLayout`), so a host's software
/// inventory survives in a filesystem snapshot exactly like the rest of its disk
/// — power a VM off and back on and it is still the machine you configured.
///
/// The operation order mirrors a real distribution tool, and the order matters:
/// resolve first (cheap, no side effects), then fetch and verify every archive,
/// then apply one transaction. Nothing touches the destination tree until every
/// byte has been checked against the digest in the index.
///
/// Concurrency: one manager belongs to one running command on the kernel's serial
/// executor. It is not `Sendable`, holds no locks, and performs its I/O through
/// the process's own descriptors.

import Swiftix

/// Per-invocation flags, shared by all front-ends.
public struct PackageOptions: Sendable {

    /// Skip the confirmation prompt (`-y`).
    public var assumeYes: Bool = false
    /// Print the plan and stop (`--dry-run` / `-s`).
    public var dryRun: Bool = false
    /// Resolve and install dependencies (cleared by `--no-deps`).
    public var withDependencies: Bool = true
    /// Replace files that no package owns (`--force-overwrite`).
    public var forceOverwrite: Bool = false
    /// Reinstall even when the version already matches (`--reinstall`).
    public var reinstall: Bool = false
    /// Remove even when it breaks dependents (`--force-depends`).
    public var forceDepends: Bool = false
    /// Suppress progress chatter (`-q`).
    public var quiet: Bool = false

    public init() {}
}

public final class PackageManager {

    /// Shared with the query/authoring half of the manager (`PackageQueries`),
    /// which is an extension in a sibling file — hence `internal` rather than
    /// `private`.
    let context: ProcessContext
    let layout: PackageLayout

    public init(context: ProcessContext, layout: PackageLayout = .default) {
        self.context = context
        self.layout = layout
    }

    /// Host architecture used to reject foreign packages. Swiftix currently has
    /// one native bytecode architecture.
    var hostArchitecture: String {
        "svm64"
    }

    // MARK: - Output

    func emit(_ text: String, quiet: Bool = false) {
        guard !quiet else { return }
        context.print(text + "\n")
    }

    func warn(_ text: String) {
        _ = context.write(2, Array("W: \(text)\n".utf8))
    }

    // MARK: - State

    /// Configured repositories, in sources-list order.
    func repositories() throws -> [PackageRepository] {
        guard
            let bytes = try PackageStore.read(
                context,
                layout.sourcesList,
                maximumBytes: PackageLimits.maximumIndexBytes)
        else {
            throw PackageError.noRepositoriesConfigured(path: layout.sourcesList)
        }
        let repositories = try PackageRepository.parse(String(decoding: bytes, as: UTF8.self))
        guard !repositories.isEmpty else {
            throw PackageError.noRepositoriesConfigured(path: layout.sourcesList)
        }
        return repositories
    }

    func installedDatabase() throws -> InstalledDatabase {
        guard
            let bytes = try PackageStore.read(
                context,
                layout.statusFile,
                maximumBytes: PackageLimits.maximumDatabaseBytes)
        else {
            return InstalledDatabase()
        }
        return try InstalledDatabase.parse(String(decoding: bytes, as: UTF8.self))
    }

    /// Cached index path for a repository.
    func listPath(for repository: PackageRepository) -> String {
        PackagePath.join(layout.listsDirectory, "\(repository.name).Packages")
    }

    /// Merged view of every cached index. Repositories without a cached index are
    /// reported once and skipped, so the manager still works with the lists it
    /// does have.
    func availablePackages(warnMissing: Bool = true) throws -> [RepositoryPackage] {
        let repositories = try repositories()
        var packages: [RepositoryPackage] = []
        var haveAnyIndex = false
        for repository in repositories {
            guard
                let bytes = try PackageStore.read(
                    context,
                    listPath(for: repository),
                    maximumBytes: PackageLimits.maximumIndexBytes)
            else {
                if warnMissing {
                    warn("no index for repository '\(repository.name)'; run 'pkg update'")
                }
                continue
            }
            haveAnyIndex = true
            let index = try RepositoryIndex.parse(
                String(decoding: bytes, as: UTF8.self),
                repository: repository.name,
                priority: repository.priority)
            packages += index.packages
        }
        guard haveAnyIndex else {
            throw PackageError.indexUnavailable(repository: repositories.map(\.name).joined(separator: ", "))
        }
        return packages
    }

    func resolver() throws -> PackageResolver {
        PackageResolver(
            available: try availablePackages(),
            installed: try installedDatabase(),
            architecture: hostArchitecture)
    }

    // MARK: - update

    /// Refresh every repository index (`pkg update`).
    public func update(options: PackageOptions = PackageOptions()) async throws {
        let repositories = try repositories()
        _ = try PackageStore.makeDirectories(context, layout.listsDirectory)

        var failures = 0
        var total = 0
        for (number, repository) in repositories.enumerated() {
            let url = repository.indexURL
            let verb = PackageTransport.isLocal(url) ? "Hit" : "Get"
            emit("\(verb):\(number + 1) \(url)", quiet: options.quiet)
            do {
                let bytes = try await PackageTransport.fetch(
                    context,
                    url: url,
                    maximumBytes: PackageLimits.maximumIndexBytes)
                // Parse before storing: a malformed index never replaces a good
                // cached one.
                let index = try RepositoryIndex.parse(
                    String(decoding: bytes, as: UTF8.self),
                    repository: repository.name,
                    priority: repository.priority)
                try PackageStore.writeAtomically(
                    context,
                    listPath(for: repository),
                    bytes: bytes,
                    mode: 0o644)
                total += index.packages.count
            } catch let error as PackageError {
                failures += 1
                warn("failed to fetch \(url): \(error.message)")
            }
        }
        emit("Reading package lists... Done", quiet: options.quiet)
        emit(
            "\(total) packages available from \(repositories.count - failures) repositories",
            quiet: options.quiet)
        if failures == repositories.count {
            throw PackageError.indexUnavailable(repository: repositories.map(\.name).joined(separator: ", "))
        }
    }

    // MARK: - install

    /// Install packages by name (optionally version-constrained) or from a local
    /// `.pkg` file path.
    public func install(_ specs: [String], options: PackageOptions) async throws {
        guard !specs.isEmpty else {
            throw PackageError.usage("install requires at least one package name")
        }
        let suffix = SwiftixPackages.archiveExtension
        let localPaths = specs.filter { $0.hasSuffix(suffix) }
        let names = specs.filter { !$0.hasSuffix(suffix) }

        var requests: [PackageDependency] = []
        for spec in names {
            guard let dependency = PackageDependency(parsing: normalizeSpec(spec)) else {
                throw PackageError.usage("cannot parse package specification '\(spec)'")
            }
            requests.append(dependency)
        }

        var localUnits: [PackageTransaction.Unit] = []
        for path in localPaths {
            let unit = try localUnit(at: path)
            localUnits.append(unit)
            // `pkg install ./package.pkg` resolves dependencies by default;
            // `--no-deps` deliberately skips that resolution.
            if options.withDependencies {
                requests += unit.archive.manifest.dependencies
            }
        }

        emit("Reading package lists... Done", quiet: options.quiet)
        emit("Building dependency tree... Done", quiet: options.quiet)

        var plan: PackagePlan
        if requests.isEmpty {
            // A local install with `--no-deps` must work without configured
            // repositories because dependency resolution was not requested.
            plan = PackagePlan(items: [], unchanged: [], promoteToManual: [])
        } else {
            plan = try resolver().plan(
                for: requests,
                withDependencies: options.withDependencies,
                allowUpgrade: true,
                reinstall: options.reinstall)
        }
        // A local archive is not in any index, so it is appended after its
        // resolved dependencies rather than selected by the resolver.
        let localNames = Set(localUnits.map(\.name))
        plan = PackagePlan(
            items: plan.items.filter { !localNames.contains($0.name) },
            unchanged: plan.unchanged,
            promoteToManual: plan.promoteToManual)

        let before = try installedDatabase()
        for name in plan.unchanged {
            let version = before.package(named: name)?.version.text ?? "installed"
            emit("\(name) is already the newest version (\(version)).", quiet: options.quiet)
        }
        guard !plan.isEmpty || !localUnits.isEmpty else {
            try promote(plan.promoteToManual, database: before)
            emit("0 upgraded, 0 newly installed, 0 to remove.", quiet: options.quiet)
            return
        }

        summarize(plan, localUnits: localUnits, quiet: options.quiet)
        if options.dryRun { return }
        guard await confirm(options: options) else {
            emit("Abort.")
            return
        }

        var units = try await download(plan, options: options)
        units += localUnits

        // Re-read the database after the (possibly blocking) download, so the
        // transaction starts from the state the filesystem is actually in.
        let database = try PackageTransaction.install(
            context,
            units: units,
            database: try installedDatabase(),
            layout: layout,
            forceOverwrite: options.forceOverwrite
        ) { name in
            guard let unit = units.first(where: { $0.name == name }) else { return }
            let verb = unit.item.isUpgrade ? "Upgrading" : "Unpacking"
            emit("\(verb) \(name) (\(unit.archive.manifest.version))...", quiet: options.quiet)
        }
        for unit in units {
            emit("Setting up \(unit.name) (\(unit.archive.manifest.version))...", quiet: options.quiet)
        }
        try promote(plan.promoteToManual, database: database)
        emit(
            countLine(
                upgraded: plan.upgrades.count,
                installed: plan.newInstalls.count + localUnits.count,
                removed: 0),
            quiet: options.quiet)
    }

    /// Upgrade every installed package that has a newer candidate.
    public func upgrade(options: PackageOptions) async throws {
        emit("Reading package lists... Done", quiet: options.quiet)
        emit("Building dependency tree... Done", quiet: options.quiet)
        let plan = try resolver().upgradePlan()
        guard !plan.isEmpty else {
            emit("0 upgraded, 0 newly installed, 0 to remove.", quiet: options.quiet)
            return
        }
        summarize(plan, localUnits: [], quiet: options.quiet)
        if options.dryRun { return }
        guard await confirm(options: options) else {
            emit("Abort.")
            return
        }

        let units = try await download(plan, options: options)
        _ = try PackageTransaction.install(
            context,
            units: units,
            database: try installedDatabase(),
            layout: layout,
            forceOverwrite: options.forceOverwrite
        ) { name in
            guard let unit = units.first(where: { $0.name == name }) else { return }
            let verb = unit.item.isUpgrade ? "Upgrading" : "Unpacking"
            emit("\(verb) \(name) (\(unit.archive.manifest.version))...", quiet: options.quiet)
        }
        emit(
            countLine(
                upgraded: plan.upgrades.count,
                installed: plan.newInstalls.count,
                removed: 0),
            quiet: options.quiet)
    }

    // MARK: - remove

    /// Remove installed packages (`pkg remove`).
    public func remove(_ names: [String], options: PackageOptions) async throws {
        guard !names.isEmpty else {
            throw PackageError.usage("remove requires at least one package name")
        }
        let database = try installedDatabase()
        let resolver = PackageResolver(available: [], installed: database, architecture: hostArchitecture)
        let ordered = try resolver.removalPlan(for: names, force: options.forceDepends)
        emit("The following packages will be REMOVED:", quiet: options.quiet)
        emit("  " + ordered.map(\.name).joined(separator: " "), quiet: options.quiet)
        emit(countLine(upgraded: 0, installed: 0, removed: ordered.count), quiet: options.quiet)
        if options.dryRun { return }
        guard await confirm(options: options) else {
            emit("Abort.")
            return
        }
        _ = try PackageTransaction.remove(
            context,
            packages: ordered,
            database: database,
            layout: layout
        ) { name in
            let version = ordered.first { $0.name == name }?.version.text ?? ""
            emit("Removing \(name) (\(version))...", quiet: options.quiet)
        }
    }

    /// Remove automatically-installed packages nothing depends on any more.
    public func autoremove(options: PackageOptions) async throws {
        let database = try installedDatabase()
        let resolver = PackageResolver(available: [], installed: database, architecture: hostArchitecture)
        let doomed = resolver.autoremovable()
        guard !doomed.isEmpty else {
            emit("0 upgraded, 0 newly installed, 0 to remove.", quiet: options.quiet)
            return
        }
        try await remove(doomed.map(\.name), options: options)
    }

    // MARK: - Fetching

    /// Download (or reuse from cache) and verify every archive in the plan.
    private func download(_ plan: PackagePlan, options: PackageOptions) async throws -> [PackageTransaction.Unit] {
        guard !plan.items.isEmpty else { return [] }
        let repositories = try repositories()
        _ = try PackageStore.makeDirectories(context, layout.archivesDirectory)

        var units: [PackageTransaction.Unit] = []
        for (number, item) in plan.items.enumerated() {
            let candidate = item.candidate
            guard let repository = repositories.first(where: { $0.name == candidate.repository }) else {
                throw PackageError.indexUnavailable(repository: candidate.repository)
            }
            let cachePath = PackagePath.join(layout.archivesDirectory, candidate.cacheName)
            let url = repository.url(forFilename: candidate.filename)

            var bytes: [UInt8]
            if let cached = try PackageStore.read(
                context,
                cachePath,
                maximumBytes: PackageLimits.maximumArchiveBytes),
                cached.count == candidate.size,
                PackageDigest.verify(cached, expected: candidate.digest)
            {
                emit("Hit:\(number + 1) \(url) [cached]", quiet: options.quiet)
                bytes = cached
            } else {
                emit(
                    "Get:\(number + 1) \(url) [\(PackageText.humanBytes(candidate.size))]",
                    quiet: options.quiet)
                bytes = try await PackageTransport.fetch(
                    context,
                    url: url,
                    maximumBytes: PackageLimits.maximumArchiveBytes)
                guard bytes.count == candidate.size else {
                    throw PackageError.sizeMismatch(
                        path: candidate.filename,
                        expected: candidate.size,
                        actual: bytes.count)
                }
                let digest = PackageDigest.hex(bytes)
                guard digest == candidate.digest else {
                    throw PackageError.digestMismatch(
                        path: candidate.filename,
                        expected: candidate.digest,
                        actual: digest)
                }
                try PackageStore.writeAtomically(context, cachePath, bytes: bytes, mode: 0o644)
            }

            // Decoding re-verifies every file digest inside the archive, and the
            // manifest must agree with the index that advertised it.
            let archive = try PackageArchive.decode(bytes)
            guard archive.manifest.name == candidate.name,
                archive.manifest.version == candidate.version
            else {
                throw PackageError.malformedArchive(
                    reason: "\(candidate.filename) contains \(archive.manifest.identifier), "
                        + "but the index advertises \(candidate.manifest.identifier)")
            }
            try archive.manifest.checkArchitecture(host: hostArchitecture)
            units.append(PackageTransaction.Unit(item: item, archive: archive))
        }
        return units
    }

    /// Load and verify a `.pkg` file from the VFS as an installable unit.
    private func localUnit(at path: String) throws -> PackageTransaction.Unit {
        let bytes = try PackageStore.readRequired(
            context,
            path,
            maximumBytes: PackageLimits.maximumArchiveBytes)
        let archive = try PackageArchive.decode(bytes)
        try archive.manifest.checkArchitecture(host: hostArchitecture)
        let entry = RepositoryPackage(
            manifest: archive.manifest,
            filename: PackagePath.lastComponent(of: path),
            size: bytes.count,
            digest: PackageDigest.hex(bytes),
            repository: "local")
        let item = PackagePlanItem(
            candidate: entry,
            replacing: try installedDatabase().package(named: archive.manifest.name),
            automatic: false)
        return PackageTransaction.Unit(item: item, archive: archive)
    }

    // MARK: - Helpers

    /// Accept the pinned `name=1.2.0` form alongside the relational ones.
    private func normalizeSpec(_ spec: String) -> String {
        guard let equals = spec.firstIndex(of: "="), !spec.contains("("), !spec.contains(" ") else {
            return spec
        }
        let name = String(spec[spec.startIndex..<equals])
        let version = String(spec[spec.index(after: equals)...])
        return "\(name) = \(version)"
    }

    private func summarize(_ plan: PackagePlan, localUnits: [PackageTransaction.Unit], quiet: Bool) {
        let newNames = (plan.newInstalls.map(\.name) + localUnits.filter { !$0.item.isUpgrade }.map(\.name)).sorted()
        let upgradeNames = (plan.upgrades.map(\.name) + localUnits.filter(\.item.isUpgrade).map(\.name)).sorted()
        if !newNames.isEmpty {
            emit("The following NEW packages will be installed:", quiet: quiet)
            emit("  " + newNames.joined(separator: " "), quiet: quiet)
        }
        if !upgradeNames.isEmpty {
            emit("The following packages will be upgraded:", quiet: quiet)
            emit("  " + upgradeNames.joined(separator: " "), quiet: quiet)
        }
        if plan.downloadSize > 0 {
            emit("Need to get \(PackageText.humanBytes(plan.downloadSize)) of archives.", quiet: quiet)
        }
    }

    private func countLine(upgraded: Int, installed: Int, removed: Int) -> String {
        "\(upgraded) upgraded, \(installed) newly installed, \(removed) to remove."
    }

    /// Ask before changing the system, unless `-y` was given. An empty line (or
    /// EOF, as in a script) means yes.
    private func confirm(options: PackageOptions) async -> Bool {
        guard !options.assumeYes, !options.quiet else { return true }
        context.print("Do you want to continue? [Y/n] ")
        guard let bytes = try? await context.read(0), !bytes.isEmpty else { return true }
        let answer = PackageText.trim(String(decoding: bytes, as: UTF8.self)).lowercased()
        return answer.isEmpty || answer == "y" || answer == "yes"
    }

    /// Clear the `automatic` mark on packages that were explicitly requested.
    private func promote(_ names: [String], database: InstalledDatabase? = nil) throws {
        guard !names.isEmpty else { return }
        var updated = try database ?? installedDatabase()
        var changed = false
        for name in names {
            guard let package = updated.package(named: name), package.automatic else { continue }
            updated.insert(package.marking(automatic: false))
            changed = true
        }
        guard changed else { return }
        try PackageTransaction.writeDatabase(context, updated, layout: layout)
    }
}
