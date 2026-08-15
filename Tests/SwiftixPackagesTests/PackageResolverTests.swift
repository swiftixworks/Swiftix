import Testing

@testable import SwiftixPackages

/// Dependency resolution as pure data: closure, ordering, version constraints,
/// conflicts, virtual packages, upgrades, removal safety and `autoremove`.
///
/// No kernel and no network appear here, which is the point — planning is
/// separable from applying, so the decision logic can be pinned down exactly.
@Suite("Dependency resolution")
struct PackageResolverTests {

    // MARK: - Fixtures

    private func available(
        _ name: String,
        _ version: String,
        depends: [String] = [],
        conflicts: [String] = [],
        provides: [String] = [],
        repository: String = "main",
        priority: Int = 0,
        architecture: String = PackageManifest.architectureIndependent
    ) -> RepositoryPackage {
        RepositoryPackage(
            manifest: PackageManifest(
                name: name,
                version: PackageVersion(version)!,
                architecture: architecture,
                summary: "\(name) package",
                dependencies: depends.map { PackageDependency(parsing: $0)! },
                conflicts: conflicts.map { PackageDependency(parsing: $0)! },
                provides: provides),
            filename: "pool/\(name)_\(version).pkg",
            size: 100,
            digest: String(repeating: "b", count: 64),
            repository: repository,
            priority: priority)
    }

    private func installed(_ packages: [(name: String, version: String, depends: [String], automatic: Bool)])
        -> InstalledDatabase
    {
        var database = InstalledDatabase()
        for entry in packages {
            database.insert(
                InstalledPackage(
                    manifest: PackageManifest(
                        name: entry.name,
                        version: PackageVersion(entry.version)!,
                        dependencies: entry.depends.map { PackageDependency(parsing: $0)! }),
                    repository: "main",
                    files: ["/bin/\(entry.name)"],
                    directories: [],
                    installedSize: 10,
                    automatic: entry.automatic))
        }
        return database
    }

    private func resolver(
        available packages: [RepositoryPackage],
        installed database: InstalledDatabase = InstalledDatabase()
    )
        -> PackageResolver
    {
        PackageResolver(available: packages, installed: database, architecture: "svm64")
    }

    private func request(_ text: String) -> PackageDependency {
        PackageDependency(parsing: text)!
    }

    // MARK: - Install planning

    @Test func planInstallsDependenciesBeforeDependents() throws {
        let resolver = resolver(available: [
            available("hello", "1.0", depends: ["libgreet (>= 1.0)"]),
            available("libgreet", "1.1", depends: ["libc"]),
            available("libc", "2.0"),
        ])
        let plan = try resolver.plan(for: [request("hello")])
        #expect(plan.items.map(\.name) == ["libc", "libgreet", "hello"])
        // Only the requested package is manual; the rest are automatic.
        #expect(plan.items.filter { !$0.automatic }.map(\.name) == ["hello"])
        #expect(plan.downloadSize == 300)
    }

    @Test func planPicksHighestSatisfyingVersion() throws {
        let resolver = resolver(available: [
            available("libgreet", "1.0"),
            available("libgreet", "2.0"),
            available("libgreet", "1.5"),
        ])
        let newest = try resolver.plan(for: [request("libgreet")])
        #expect(newest.items.first?.candidate.version == PackageVersion("2.0")!)

        let constrained = try resolver.plan(for: [request("libgreet (<< 2.0)")])
        #expect(constrained.items.first?.candidate.version == PackageVersion("1.5")!)
    }

    @Test func planPrefersEarlierRepositoryOnEqualVersions() throws {
        let resolver = resolver(available: [
            available("tool", "1.0", repository: "extra", priority: 1),
            available("tool", "1.0", repository: "main", priority: 0),
        ])
        let plan = try resolver.plan(for: [request("tool")])
        #expect(plan.items.first?.candidate.repository == "main")
    }

    @Test func planFailsWhenNoCandidateSatisfiesConstraint() throws {
        let resolver = resolver(available: [available("libgreet", "1.0")])
        #expect(throws: PackageError.noCandidate(dependency: "libgreet (>= 2.0)")) {
            try resolver.plan(for: [request("libgreet (>= 2.0)")])
        }
        #expect(throws: PackageError.packageNotFound(name: "ghost")) {
            try resolver.plan(for: [request("ghost")])
        }
    }

    @Test func planFailsOnIncompatibleRequirements() throws {
        let resolver = resolver(available: [
            available("app", "1.0", depends: ["lib (>= 2.0)"]),
            available("lib", "1.0"),
            available("lib", "2.0"),
        ])
        // Asking for the old lib while app demands the new one is contradictory.
        #expect(throws: PackageError.self) {
            try resolver.plan(for: [request("app"), request("lib (= 1.0)")])
        }
    }

    @Test func planResolvesVirtualPackageWithOneProvider() throws {
        let resolver = resolver(available: [
            available("app", "1.0", depends: ["greeter"]),
            available("gnu-hello", "2.0", provides: ["greeter"]),
        ])
        let plan = try resolver.plan(for: [request("app")])
        #expect(plan.items.map(\.name) == ["gnu-hello", "app"])
    }

    @Test func planRefusesAmbiguousVirtualPackage() throws {
        let resolver = resolver(available: [
            available("app", "1.0", depends: ["greeter"]),
            available("gnu-hello", "2.0", provides: ["greeter"]),
            available("mini-hello", "1.0", provides: ["greeter"]),
        ])
        #expect(
            throws: PackageError.ambiguousVirtualPackage(
                name: "greeter",
                providers: ["gnu-hello", "mini-hello"])
        ) {
            try resolver.plan(for: [request("app")])
        }
    }

    @Test func planRejectsConflicts() throws {
        let mutual = resolver(available: [
            available("hello", "1.0", conflicts: ["hello-legacy"]),
            available("hello-legacy", "0.9"),
        ])
        #expect(throws: PackageError.self) {
            try mutual.plan(for: [request("hello"), request("hello-legacy")])
        }

        // A conflict with something already installed is equally fatal.
        let withInstalled = resolver(
            available: [available("hello", "1.0", conflicts: ["hello-legacy"])],
            installed: installed([(name: "hello-legacy", version: "0.9", depends: [], automatic: false)]))
        #expect(throws: PackageError.conflict(package: "hello", with: "hello-legacy")) {
            try withInstalled.plan(for: [request("hello")])
        }
    }

    @Test func planRejectsForeignArchitecture() throws {
        let resolver = resolver(available: [available("hello", "1.0", architecture: "riscv64")])
        #expect(
            throws: PackageError.architectureMismatch(
                package: "hello",
                architecture: "riscv64",
                host: "svm64")
        ) {
            try resolver.plan(for: [request("hello")])
        }
    }

    @Test func planLeavesSatisfiedPackagesAloneAndReportsThem() throws {
        let resolver = resolver(
            available: [available("hello", "1.0")],
            installed: installed([(name: "hello", version: "1.0", depends: [], automatic: true)]))
        let plan = try resolver.plan(for: [request("hello")])
        #expect(plan.isEmpty)
        #expect(plan.unchanged == ["hello"])
        // Explicitly asking for an automatically-installed package makes it manual.
        #expect(plan.promoteToManual == ["hello"])
    }

    @Test func planUpgradesExplicitlyRequestedPackage() throws {
        let resolver = resolver(
            available: [available("hello", "2.0", depends: ["libgreet"]), available("libgreet", "1.0")],
            installed: installed([(name: "hello", version: "1.0", depends: [], automatic: false)]))
        let plan = try resolver.plan(for: [request("hello")])
        #expect(plan.upgrades.map(\.name) == ["hello"])
        #expect(plan.items.map(\.name) == ["libgreet", "hello"])
        #expect(plan.items.last?.replacing?.version == PackageVersion("1.0")!)
    }

    @Test func planDoesNotUpgradeSatisfiedDependencies() throws {
        // `app` needs `lib (>= 1.0)`; 1.0 is installed and 2.0 exists. Minimal
        // change means the installed lib stays.
        let resolver = resolver(
            available: [available("app", "1.0", depends: ["lib (>= 1.0)"]), available("lib", "2.0")],
            installed: installed([(name: "lib", version: "1.0", depends: [], automatic: false)]))
        let plan = try resolver.plan(for: [request("app")])
        #expect(plan.items.map(\.name) == ["app"])
    }

    @Test func planWithoutDependenciesInstallsOnlyTheNamedPackage() throws {
        let resolver = resolver(available: [
            available("hello", "1.0", depends: ["libgreet"]),
            available("libgreet", "1.0"),
        ])
        let plan = try resolver.plan(for: [request("hello")], withDependencies: false)
        #expect(plan.items.map(\.name) == ["hello"])
    }

    @Test func planReinstallSelectsSameVersion() throws {
        let resolver = resolver(
            available: [available("hello", "1.0")],
            installed: installed([(name: "hello", version: "1.0", depends: [], automatic: false)]))
        let plan = try resolver.plan(for: [request("hello")], reinstall: true)
        #expect(plan.items.map(\.name) == ["hello"])
        #expect(plan.items.first?.isUpgrade == true)
    }

    @Test func planToleratesDependencyCycle() throws {
        let resolver = resolver(available: [
            available("aa", "1.0", depends: ["bb"]),
            available("bb", "1.0", depends: ["aa"]),
        ])
        let plan = try resolver.plan(for: [request("aa")])
        #expect(Set(plan.items.map(\.name)) == ["aa", "bb"])
    }

    // MARK: - Upgrade planning

    @Test func upgradePlanCoversEveryOutdatedPackage() throws {
        let resolver = resolver(
            available: [available("hello", "2.0"), available("libgreet", "1.0")],
            installed: installed([
                (name: "hello", version: "1.0", depends: [], automatic: false),
                (name: "libgreet", version: "1.0", depends: [], automatic: true),
            ]))
        let plan = try resolver.upgradePlan()
        #expect(plan.items.map(\.name) == ["hello"])
        #expect(plan.items.first?.isUpgrade == true)
    }

    @Test func upgradePlanPreservesAutomaticMarking() throws {
        let resolver = resolver(
            available: [available("libgreet", "2.0")],
            installed: installed([(name: "libgreet", version: "1.0", depends: [], automatic: true)]))
        let plan = try resolver.upgradePlan()
        #expect(plan.items.first?.automatic == true)
    }

    // MARK: - Removal planning

    @Test func removalOrdersDependentsFirst() throws {
        let resolver = resolver(
            available: [],
            installed: installed([
                (name: "hello", version: "1.0", depends: ["libgreet"], automatic: false),
                (name: "libgreet", version: "1.0", depends: [], automatic: true),
            ]))
        let ordered = try resolver.removalPlan(for: ["libgreet", "hello"], force: false)
        #expect(ordered.map(\.name) == ["hello", "libgreet"])
    }

    @Test func removalRefusesToBreakDependents() throws {
        let resolver = resolver(
            available: [],
            installed: installed([
                (name: "hello", version: "1.0", depends: ["libgreet"], automatic: false),
                (name: "libgreet", version: "1.0", depends: [], automatic: true),
            ]))
        #expect(throws: PackageError.dependencyBreakage(package: "libgreet", dependents: ["hello"])) {
            try resolver.removalPlan(for: ["libgreet"], force: false)
        }
        // --force-depends acknowledges the breakage.
        let forced = try resolver.removalPlan(for: ["libgreet"], force: true)
        #expect(forced.map(\.name) == ["libgreet"])
    }

    @Test func removalRejectsPackagesThatAreNotInstalled() throws {
        let resolver = resolver(available: [], installed: InstalledDatabase())
        #expect(throws: PackageError.notInstalled(name: "hello")) {
            try resolver.removalPlan(for: ["hello"], force: false)
        }
    }

    // MARK: - autoremove

    @Test func autoremoveCollectsOrphansTransitively() throws {
        // hello (manual) is gone; libgreet and libc were only its dependencies.
        let resolver = resolver(
            available: [],
            installed: installed([
                (name: "libgreet", version: "1.0", depends: ["libc"], automatic: true),
                (name: "libc", version: "1.0", depends: [], automatic: true),
                (name: "tool", version: "1.0", depends: [], automatic: false),
            ]))
        #expect(resolver.autoremovable().map(\.name) == ["libc", "libgreet"])
    }

    @Test func autoremoveKeepsPackagesWithManualDependents() throws {
        let resolver = resolver(
            available: [],
            installed: installed([
                (name: "hello", version: "1.0", depends: ["libgreet"], automatic: false),
                (name: "libgreet", version: "1.0", depends: [], automatic: true),
            ]))
        #expect(resolver.autoremovable().isEmpty)
    }
}
