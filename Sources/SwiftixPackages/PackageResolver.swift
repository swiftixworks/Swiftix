/// Dependency resolution: turning "install hello" into an ordered, checked plan.
///
/// The resolver is intentionally a *deterministic, minimal-change* solver rather
/// than a full SAT engine, because that is what makes its behavior explainable:
///
///   * candidate selection is "highest version that satisfies the term, earliest
///     repository on a tie", so the same inputs always yield the same plan;
///   * an already-satisfied dependency is left alone — dependencies are never
///     gratuitously upgraded, only an explicitly named package is;
///   * a requirement that cannot be met is reported as an error naming the term,
///     instead of being silently dropped or backtracked around.
///
/// Everything the resolver reads is pure data (`RepositoryPackage`,
/// `InstalledDatabase`), so planning is fully testable without a kernel, a
/// network, or a filesystem.

/// One package the plan will put on disk.
public struct PackagePlanItem: Sendable, Equatable {

    public let candidate: RepositoryPackage
    /// The version being replaced, when this is an upgrade or reinstall.
    public let replacing: InstalledPackage?
    /// Pulled in as a dependency rather than requested by name.
    public let automatic: Bool

    public var name: String { candidate.name }
    public var isUpgrade: Bool { replacing != nil }
}

/// The full outcome of planning: what to install, plus what needs no work.
public struct PackagePlan: Sendable {

    /// Dependencies first, so a package is never installed before something it
    /// needs.
    public let items: [PackagePlanItem]
    /// Requested packages that are already at the newest available version.
    public let unchanged: [String]
    /// Already-installed packages that were requested by name and should stop
    /// being marked as automatically installed.
    public let promoteToManual: [String]

    public var isEmpty: Bool { items.isEmpty }
    public var newInstalls: [PackagePlanItem] { items.filter { !$0.isUpgrade } }
    public var upgrades: [PackagePlanItem] { items.filter(\.isUpgrade) }
    /// Bytes that must be fetched if nothing is cached.
    public var downloadSize: Int { items.reduce(0) { $0 + $1.candidate.size } }
}

struct PackageResolver {

    /// Available packages grouped by name, each list sorted best-first.
    private let candidatesByName: [String: [RepositoryPackage]]
    /// Virtual name → providing packages, sorted best-first.
    private let providersByVirtualName: [String: [RepositoryPackage]]
    private let installed: InstalledDatabase
    private let architecture: String

    init(available: [RepositoryPackage], installed: InstalledDatabase, architecture: String) {
        // Best-first: highest version, then the earliest repository in the
        // sources list, then name for a fully stable order.
        let ordered = available.sorted { left, right in
            if left.version != right.version { return left.version > right.version }
            if left.priority != right.priority { return left.priority < right.priority }
            return left.repository < right.repository
        }
        var byName: [String: [RepositoryPackage]] = [:]
        var byVirtual: [String: [RepositoryPackage]] = [:]
        for package in ordered {
            byName[package.name, default: []].append(package)
            for virtualName in package.manifest.provides {
                byVirtual[virtualName, default: []].append(package)
            }
        }
        self.candidatesByName = byName
        self.providersByVirtualName = byVirtual
        self.installed = installed
        self.architecture = architecture
    }

    /// All available names (for `search` / `list`).
    var availableNames: [String] { candidatesByName.keys.sorted() }

    /// Best available version of `name`, or `nil` when the repositories do not
    /// carry it.
    func candidate(named name: String) -> RepositoryPackage? {
        candidatesByName[name]?.first
    }

    // MARK: - Install planning

    /// Plan the installation of `requests`.
    ///
    /// - Parameters:
    ///   - withDependencies: when `false` (`--no-deps`), only the named packages
    ///     are considered — their requirements are still recorded but not pulled.
    ///   - allowUpgrade: whether an explicitly requested package that is already
    ///     installed may be replaced by a newer candidate.
    ///   - reinstall: force re-selection even when the installed version already
    ///     matches, so a damaged installation can be repaired.
    func plan(
        for requests: [PackageDependency],
        withDependencies: Bool = true,
        allowUpgrade: Bool = true,
        reinstall: Bool = false
    ) throws -> PackagePlan {
        var selected: [String: PackagePlanItem] = [:]
        var unchanged: [String] = []
        var promote: [String] = []
        var pending: [(dependency: PackageDependency, automatic: Bool)] =
            requests.map { ($0, false) }
        var cursor = 0

        while cursor < pending.count {
            let (dependency, automatic) = pending[cursor]
            cursor += 1

            // Already covered by something this plan selects.
            if let existing = selected.values.first(where: { $0.candidate.manifest.satisfies(dependency) }) {
                if !automatic, existing.automatic {
                    selected[existing.name] = PackagePlanItem(
                        candidate: existing.candidate,
                        replacing: existing.replacing,
                        automatic: false)
                }
                continue
            }
            // A different version of the same name is already selected: the two
            // requirements cannot both hold.
            if let conflicting = selected[dependency.name] {
                throw PackageError.conflictingRequirement(
                    name: dependency.name,
                    selected: conflicting.candidate.version.text,
                    required: dependency.description)
            }

            // Already satisfied by the system.
            if let present = installed.providers(of: dependency).first(where: { selected[$0.name] == nil }) {
                let upgradeCandidate =
                    allowUpgrade && !automatic
                    ? candidate(named: present.name).flatMap { $0.version > present.version ? $0 : nil }
                    : nil
                if let upgradeCandidate {
                    selected[upgradeCandidate.name] = PackagePlanItem(
                        candidate: upgradeCandidate,
                        replacing: present,
                        automatic: false)
                    if withDependencies {
                        pending += upgradeCandidate.manifest.dependencies.map { ($0, true) }
                    }
                    continue
                }
                if reinstall, !automatic, let same = candidate(named: present.name) {
                    selected[same.name] = PackagePlanItem(
                        candidate: same,
                        replacing: present,
                        automatic: false)
                    if withDependencies {
                        pending += same.manifest.dependencies.map { ($0, true) }
                    }
                    continue
                }
                if !automatic {
                    unchanged.append(present.name)
                    if present.automatic { promote.append(present.name) }
                }
                continue
            }

            let choice = try select(dependency)
            try choice.manifest.checkArchitecture(host: architecture)
            selected[choice.name] = PackagePlanItem(
                candidate: choice,
                replacing: installed.package(named: choice.name),
                automatic: automatic)
            if withDependencies {
                pending += choice.manifest.dependencies.map { ($0, true) }
            }
        }

        try checkConflicts(selected)
        return PackagePlan(
            items: order(selected),
            unchanged: unchanged.sorted(),
            promoteToManual: promote.sorted())
    }

    /// Plan an upgrade of every installed package that has a newer candidate.
    func upgradePlan() throws -> PackagePlan {
        var requests: [PackageDependency] = []
        for package in installed.sorted {
            guard let candidate = candidate(named: package.name),
                candidate.version > package.version
            else { continue }
            requests.append(PackageDependency(name: package.name))
        }
        guard !requests.isEmpty else {
            return PackagePlan(items: [], unchanged: [], promoteToManual: [])
        }
        // Upgrades keep their existing manual/automatic marking rather than being
        // promoted just because `upgrade` touched them.
        let plan = try plan(for: requests, withDependencies: true, allowUpgrade: true)
        let items = plan.items.map { item in
            PackagePlanItem(
                candidate: item.candidate,
                replacing: item.replacing,
                automatic: item.replacing?.automatic ?? item.automatic)
        }
        return PackagePlan(items: items, unchanged: [], promoteToManual: [])
    }

    /// Choose the best candidate for one term, or explain why none fits.
    private func select(_ dependency: PackageDependency) throws -> RepositoryPackage {
        if let candidates = candidatesByName[dependency.name] {
            if let match = candidates.first(where: { dependency.isSatisfied(by: $0.version) }) {
                return match
            }
            throw PackageError.noCandidate(dependency: dependency.description)
        }
        // Virtual name: usable only when exactly one package provides it, so the
        // resolver never silently picks a provider on the user's behalf.
        if let providers = providersByVirtualName[dependency.name] {
            guard dependency.isUnversioned else {
                throw PackageError.noCandidate(dependency: dependency.description)
            }
            let names = Set(providers.map(\.name)).sorted()
            guard names.count == 1, let provider = providers.first else {
                throw PackageError.ambiguousVirtualPackage(name: dependency.name, providers: names)
            }
            return provider
        }
        throw PackageError.packageNotFound(name: dependency.name)
    }

    /// Reject a plan whose members conflict with each other or with packages that
    /// are staying installed.
    private func checkConflicts(_ selected: [String: PackagePlanItem]) throws {
        let items = selected.values.sorted { $0.name < $1.name }
        for item in items {
            for conflict in item.candidate.manifest.conflicts {
                if let other = items.first(where: {
                    $0.name != item.name && $0.candidate.manifest.satisfies(conflict)
                }) {
                    throw PackageError.conflict(package: item.name, with: other.name)
                }
                if let present = installed.sorted.first(where: {
                    selected[$0.name] == nil && $0.manifest.satisfies(conflict)
                }) {
                    throw PackageError.conflict(package: item.name, with: present.name)
                }
            }
        }
        for present in installed.sorted where selected[present.name] == nil {
            for conflict in present.manifest.conflicts {
                if let item = items.first(where: { $0.candidate.manifest.satisfies(conflict) }) {
                    throw PackageError.conflict(package: item.name, with: present.name)
                }
            }
        }
    }

    /// Depth-first topological order over the selected set: a package appears
    /// after everything in the plan it depends on. Names are visited in sorted
    /// order, and a dependency cycle degrades to that stable name order rather
    /// than failing — installation is file placement, so a cycle is harmless.
    private func order(_ selected: [String: PackagePlanItem]) -> [PackagePlanItem] {
        var result: [PackagePlanItem] = []
        var visited = Set<String>()
        var visiting = Set<String>()

        func visit(_ name: String) {
            guard let item = selected[name], !visited.contains(name) else { return }
            guard visiting.insert(name).inserted else { return }  // cycle: stop descending
            let dependencyNames = item.candidate.manifest.dependencies.compactMap { dependency in
                selected.values.first { $0.candidate.manifest.satisfies(dependency) }?.name
            }
            for dependencyName in Set(dependencyNames).sorted() where dependencyName != name {
                visit(dependencyName)
            }
            visiting.remove(name)
            visited.insert(name)
            result.append(item)
        }

        for name in selected.keys.sorted() { visit(name) }
        return result
    }

    // MARK: - Removal planning

    /// Order the named packages for removal, dependents first, and refuse a
    /// removal that would break a package staying behind (unless `force`).
    func removalPlan(for names: [String], force: Bool) throws -> [InstalledPackage] {
        var targets: [String: InstalledPackage] = [:]
        for name in names {
            guard let package = installed.package(named: name) else {
                throw PackageError.notInstalled(name: name)
            }
            targets[name] = package
        }
        let removing = Set(targets.keys)

        if !force {
            for package in installed.sorted where !removing.contains(package.name) {
                for dependency in package.manifest.dependencies {
                    // Only a dependency that *is* currently satisfied and would
                    // stop being satisfied counts as breakage.
                    guard installed.satisfies(dependency),
                        !installed.satisfies(dependency, excluding: removing)
                    else { continue }
                    let broken = installed.providers(of: dependency)
                        .filter { removing.contains($0.name) }
                        .map(\.name)
                        .sorted()
                    throw PackageError.dependencyBreakage(
                        package: broken.joined(separator: ", "),
                        dependents: [package.name])
                }
            }
        }

        // Dependents first: emit a package only after everything in the set that
        // depends on it has already been emitted.
        var result: [InstalledPackage] = []
        var visited = Set<String>()
        var visiting = Set<String>()

        func visit(_ name: String) {
            guard let package = targets[name], !visited.contains(name) else { return }
            guard visiting.insert(name).inserted else { return }
            let dependents = targets.values.filter { candidate in
                candidate.name != name
                    && candidate.manifest.dependencies.contains { package.manifest.satisfies($0) }
            }
            for dependent in dependents.map(\.name).sorted() { visit(dependent) }
            visiting.remove(name)
            visited.insert(name)
            result.append(package)
        }

        for name in removing.sorted() { visit(name) }
        return result
    }

    /// Automatically-installed packages nothing depends on any more — the input
    /// to `autoremove`. Computed to a fixed point, so removing a leaf exposes the
    /// dependency it was the last user of.
    func autoremovable() -> [InstalledPackage] {
        var doomed = Set<String>()
        var changed = true
        while changed {
            changed = false
            for package in installed.sorted where package.automatic && !doomed.contains(package.name) {
                let stillNeeded = installed.sorted.contains { other in
                    guard other.name != package.name, !doomed.contains(other.name) else { return false }
                    return other.manifest.dependencies.contains { package.manifest.satisfies($0) }
                }
                if !stillNeeded {
                    doomed.insert(package.name)
                    changed = true
                }
            }
        }
        return doomed.sorted().compactMap { installed.package(named: $0) }
    }
}
