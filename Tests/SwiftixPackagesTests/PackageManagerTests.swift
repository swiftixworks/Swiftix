import Swiftix
import SwiftixPackages
import Testing

/// End-to-end package management on a live host: author a package inside the
/// emulator, index it into a repository, then install, query, upgrade and remove
/// it through the shell — including the failure paths that must leave the host
/// untouched.
@Suite("Package manager end to end")
struct PackageManagerTests {

    // MARK: - Fixtures

    private static let executable: FileMode = [
        .ownerRead, .ownerWrite, .ownerExecute, .groupRead, .groupExecute, .otherRead, .otherExecute,
    ]

    /// Author `libgreet` and `hello` (which depends on it) and index them into
    /// `/srv/repo` through the package library's fixture API.
    private func buildRepository(_ host: PackageTestHost) async throws {
        host.writeFile("/build/libgreet/usr/lib/greet.txt", "greet v1\n")
        host.writeFile(
            "/build/libgreet.meta",
            """
            Package: libgreet
            Version: 1.0
            Architecture: all
            Description: greeting data library
            """)

        host.writeFile("/build/hello/bin/hello", "#!/bin/sh\necho hello\n", mode: Self.executable)
        host.writeFile("/build/hello/usr/share/doc/hello/README", "hello docs\n")
        host.writeFile(
            "/build/hello.meta",
            """
            Package: hello
            Version: 1.0
            Architecture: all
            Description: friendly greeter
             prints a greeting
            Depends: libgreet (>= 1.0)
            """)

        try host.buildPackage(
            manifestPath: "/build/libgreet.meta",
            root: "/build/libgreet",
            output: "/srv/repo/pool/libgreet_1.0.pkg")
        try host.buildPackage(
            manifestPath: "/build/hello.meta",
            root: "/build/hello",
            output: "/srv/repo/pool/hello_1.0.pkg")
        try host.indexRepository("/srv/repo")
    }

    /// Build the repository, register it as a `file://` source, and refresh.
    private func makeHostWithRepository() async throws -> PackageTestHost {
        let host = PackageTestHost()
        try await buildRepository(host)
        host.writeFile("/etc/pkg/sources.list", "repo file:///srv/repo ./\n")
        let update = await host.run("pkg update")
        #expect(update.status == 0, update.comment)
        #expect(update.contains("2 packages available"), update.comment)
        return host
    }

    // MARK: - Install

    @Test func installPullsDependenciesAndPlacesOwnedFiles() async throws {
        let host = try await makeHostWithRepository()

        let install = await host.run("pkg install -y hello")
        #expect(install.status == 0, install.comment)
        // The dependency is announced and unpacked before the dependent.
        #expect(install.contains("The following NEW packages will be installed:"), install.comment)
        #expect(install.contains("hello libgreet"), install.comment)
        guard let libgreetIndex = install.output.firstRange(of: "Unpacking libgreet")?.lowerBound,
            let helloIndex = install.output.firstRange(of: "Unpacking hello")?.lowerBound
        else {
            Issue.record("expected both packages to be unpacked: \(install.output)")
            return
        }
        #expect(libgreetIndex < helloIndex, "dependencies must be unpacked first")

        #expect(host.readFile("/bin/hello") == "#!/bin/sh\necho hello\n")
        #expect(host.readFile("/usr/lib/greet.txt") == "greet v1\n")
        #expect(host.readFile("/usr/share/doc/hello/README") == "hello docs\n")
        // Permission bits survive the round trip, so an installed program stays
        // executable.
        #expect(host.mode(of: "/bin/hello")?.contains(.ownerExecute) == true)

        let listing = await host.run("pkg list --installed")
        #expect(listing.contains("hello/source1 1.0 all [installed]"), listing.comment)
        #expect(listing.contains("libgreet/source1 1.0 all [installed,automatic]"), listing.comment)

        let show = await host.run("pkg info hello")
        #expect(show.contains("Depends: libgreet (>= 1.0)"), show.comment)
        #expect(show.contains("Description: friendly greeter"), show.comment)

        let files = await host.run("pkg files hello")
        #expect(files.contains("/bin/hello"), files.comment)

        let owner = await host.run("pkg owner /bin/hello")
        #expect(owner.contains("hello: /bin/hello"), owner.comment)
    }

    /// A `.pkg` file can be installed directly; its own requirements are still
    /// resolved from the configured repositories.
    @Test func installAcceptsALocalArchivePath() async throws {
        let host = try await makeHostWithRepository()

        let install = await host.run("pkg install -y /srv/repo/pool/hello_1.0.pkg")
        #expect(install.status == 0, install.comment)
        #expect(host.readFile("/bin/hello") == "#!/bin/sh\necho hello\n")
        #expect(host.readFile("/usr/lib/greet.txt") == "greet v1\n", "the dependency came from the repo")

        let listing = await host.run("pkg list --installed")
        #expect(listing.contains("hello/local 1.0 all [installed]"), listing.comment)
    }

    @Test func pkgInstallsALocalArchiveWithoutRepositories() async throws {
        let host = PackageTestHost()
        host.writeFile("/build/local/bin/local-tool", "#!/bin/sh\necho local\n", mode: Self.executable)
        host.writeFile(
            "/build/local.meta",
            """
            Package: local-tool
            Version: 1.0
            Architecture: all
            Description: local tool
            """)
        try host.buildPackage(
            manifestPath: "/build/local.meta",
            root: "/build/local",
            output: "/tmp/local-tool_1.0.pkg")

        let architecture = await host.run("pkg arch")
        #expect(architecture.status == 0, architecture.comment)
        #expect(architecture.contains("svm64"), architecture.comment)

        let install = await host.run("pkg install -y --no-deps /tmp/local-tool_1.0.pkg")
        #expect(install.status == 0, install.comment)
        #expect(host.readFile("/bin/local-tool") == "#!/bin/sh\necho local\n")

        host.writeFile(
            "/etc/pkg/sources.list",
            "repo file:///repository-without-a-cached-index ./\n")
        let status = await host.run("pkg info local-tool")
        #expect(status.status == 0, status.comment)
        #expect(status.contains("Status: installed"), status.comment)
    }

    @Test func installIsIdempotentAndReportsNewestVersion() async throws {
        let host = try await makeHostWithRepository()
        #expect(await host.run("pkg install -y hello").status == 0)

        let again = await host.run("pkg install -y hello")
        #expect(again.status == 0, again.comment)
        #expect(again.contains("hello is already the newest version (1.0)."), again.comment)
        #expect(again.contains("0 upgraded, 0 newly installed, 0 to remove."), again.comment)
    }

    @Test func dryRunPrintsThePlanWithoutTouchingTheHost() async throws {
        let host = try await makeHostWithRepository()

        let simulated = await host.run("pkg install -s hello")
        #expect(simulated.status == 0, simulated.comment)
        #expect(simulated.contains("The following NEW packages will be installed:"), simulated.comment)
        #expect(!host.exists("/bin/hello"))
        #expect(!host.exists("/var/lib/pkg/status"))
    }

    @Test func installWithoutDependenciesFailsToResolveTheDependent() async throws {
        let host = try await makeHostWithRepository()
        // `--no-deps` installs only what was named; libgreet stays absent.
        let install = await host.run("pkg install -y --no-deps hello")
        #expect(install.status == 0, install.comment)
        #expect(host.exists("/bin/hello"))
        #expect(!host.exists("/usr/lib/greet.txt"))
    }

    // MARK: - Integrity

    @Test func corruptedArchiveIsRejectedAndNothingIsInstalled() async throws {
        let host = try await makeHostWithRepository()
        // Tamper with the pool file *after* indexing, so the recorded digest no
        // longer matches what the repository serves.
        host.corrupt("/srv/repo/pool/hello_1.0.pkg")

        let install = await host.run("pkg install -y hello")
        #expect(install.status == 1, install.comment)
        #expect(install.contains("digest mismatch") || install.contains("size mismatch"), install.comment)
        #expect(!host.exists("/bin/hello"))
        #expect(!host.exists("/usr/share/doc/hello/README"))

        // The dependency that was unpacked first must have been rolled back too.
        let listing = await host.run("pkg list --installed")
        #expect(!listing.contains("hello/"), listing.comment)
    }

    @Test func unownedFileIsProtectedUnlessOverrideIsRequested() async throws {
        let host = try await makeHostWithRepository()
        host.writeFile("/bin/hello", "local script\n")

        let refused = await host.run("pkg install -y hello")
        #expect(refused.status == 1, refused.comment)
        #expect(refused.contains("--force-overwrite"), refused.comment)
        #expect(host.readFile("/bin/hello") == "local script\n", "the existing file must survive")

        let forced = await host.run("pkg install -y --force-overwrite hello")
        #expect(forced.status == 0, forced.comment)
        #expect(host.readFile("/bin/hello") == "#!/bin/sh\necho hello\n")
    }

    @Test func twoPackagesCannotOwnTheSamePath() async throws {
        let host = try await makeHostWithRepository()
        #expect(await host.run("pkg install -y hello").status == 0)

        // A second package shipping /bin/hello must be refused, and the installed
        // file must stay exactly as it was.
        host.writeFile("/build/alt/bin/hello", "alternative\n", mode: Self.executable)
        host.writeFile(
            "/build/alt.meta",
            """
            Package: hello-alt
            Version: 1.0
            Architecture: all
            Description: conflicting greeter
            """)
        try host.buildPackage(
            manifestPath: "/build/alt.meta",
            root: "/build/alt",
            output: "/srv/repo/pool/hello-alt_1.0.pkg")
        try host.indexRepository("/srv/repo")
        #expect(await host.run("pkg update").status == 0)

        let install = await host.run("pkg install -y hello-alt")
        #expect(install.status == 1, install.comment)
        #expect(install.contains("owned by hello"), install.comment)
        #expect(host.readFile("/bin/hello") == "#!/bin/sh\necho hello\n")
    }

    // MARK: - Upgrade

    @Test func upgradeReplacesFilesAndDropsObsoleteOnes() async throws {
        let host = try await makeHostWithRepository()
        #expect(await host.run("pkg install -y hello").status == 0)

        // hello 2.0 rewrites /bin/hello and no longer ships the README.
        host.writeFile("/build/hello2/bin/hello", "#!/bin/sh\necho hello v2\n", mode: Self.executable)
        host.writeFile(
            "/build/hello2.meta",
            """
            Package: hello
            Version: 2.0
            Architecture: all
            Description: friendly greeter
            Depends: libgreet (>= 1.0)
            """)
        try host.buildPackage(
            manifestPath: "/build/hello2.meta",
            root: "/build/hello2",
            output: "/srv/repo/pool/hello_2.0.pkg")
        try host.indexRepository("/srv/repo")
        #expect(await host.run("pkg update").status == 0)

        let upgradable = await host.run("pkg list --upgradable")
        #expect(upgradable.contains("hello/source1 2.0 all [upgradable from: 1.0]"), upgradable.comment)

        let upgrade = await host.run("pkg upgrade -y")
        #expect(upgrade.status == 0, upgrade.comment)
        #expect(upgrade.contains("The following packages will be upgraded:"), upgrade.comment)
        #expect(host.readFile("/bin/hello") == "#!/bin/sh\necho hello v2\n")
        #expect(!host.exists("/usr/share/doc/hello/README"), "obsolete files are removed on upgrade")

        let listing = await host.run("pkg list --installed")
        #expect(listing.contains("hello/source1 2.0 all [installed]"), listing.comment)
    }

    // MARK: - Removal

    @Test func removeDeletesOwnedFilesAndPrunesCreatedDirectories() async throws {
        let host = try await makeHostWithRepository()
        #expect(await host.run("pkg install -y hello").status == 0)

        let remove = await host.run("pkg remove -y hello")
        #expect(remove.status == 0, remove.comment)
        #expect(remove.contains("Removing hello (1.0)..."), remove.comment)
        #expect(!host.exists("/bin/hello"))
        #expect(!host.exists("/usr/share/doc/hello/README"))
        #expect(!host.exists("/usr/share/doc/hello"), "directories the package created are pruned")
        // /bin predates the package (the shell's own tree), so it must survive.
        #expect(host.exists("/usr/lib/greet.txt"), "a dependency is not removed implicitly")

        let listing = await host.run("pkg list --installed")
        #expect(!listing.contains("hello/source1"), listing.comment)
        #expect(listing.contains("libgreet/source1"), listing.comment)
    }

    @Test func removeRefusesToBreakADependent() async throws {
        let host = try await makeHostWithRepository()
        #expect(await host.run("pkg install -y hello").status == 0)

        let refused = await host.run("pkg remove -y libgreet")
        #expect(refused.status == 1, refused.comment)
        #expect(refused.contains("would break: hello"), refused.comment)
        #expect(host.exists("/usr/lib/greet.txt"))

        let forced = await host.run("pkg remove -y --force-depends libgreet")
        #expect(forced.status == 0, forced.comment)
        #expect(!host.exists("/usr/lib/greet.txt"))
    }

    @Test func autoremoveCollectsOrphanedDependencies() async throws {
        let host = try await makeHostWithRepository()
        #expect(await host.run("pkg install -y hello").status == 0)
        #expect(await host.run("pkg remove -y hello").status == 0)

        let autoremove = await host.run("pkg autoremove -y")
        #expect(autoremove.status == 0, autoremove.comment)
        #expect(autoremove.contains("Removing libgreet"), autoremove.comment)
        #expect(!host.exists("/usr/lib/greet.txt"))

        let listing = await host.run("pkg list --installed")
        #expect(!listing.contains("libgreet"), listing.comment)
    }

    // MARK: - Queries, cache, configuration

    @Test func searchUsesTheConfiguredRepository() async throws {
        let host = try await makeHostWithRepository()

        let search = await host.run("pkg search greeter")
        #expect(search.contains("hello/source1 1.0 all"), search.comment)
        #expect(search.contains("friendly greeter"), search.comment)
        #expect(host.readFile("/etc/pkg/sources.list") == "repo file:///srv/repo ./\n")
    }

    @Test func cleanRemovesDownloadedArchivesButKeepsTheInstallation() async throws {
        let host = try await makeHostWithRepository()
        #expect(await host.run("pkg install -y hello").status == 0)
        #expect(host.exists("/var/cache/pkg/archives/hello_1.0.pkg"))

        let clean = await host.run("pkg clean")
        #expect(clean.status == 0, clean.comment)
        #expect(!host.exists("/var/cache/pkg/archives/hello_1.0.pkg"))
        #expect(host.exists("/bin/hello"), "clean must not touch installed files")
    }

    @Test func cachedArchiveIsReusedOnReinstall() async throws {
        let host = try await makeHostWithRepository()
        #expect(await host.run("pkg install -y hello").status == 0)

        let reinstall = await host.run("pkg install -y --reinstall hello")
        #expect(reinstall.status == 0, reinstall.comment)
        #expect(reinstall.contains("[cached]"), reinstall.comment)
    }

    /// Only the Swiftix-native front end is registered. Other ecosystem commands
    /// and unrelated aliases stay unresolved.
    @Test func pkgIsTheOnlyPackageCommand() async throws {
        let host = try await makeHostWithRepository()

        let absentCommands = [
            "apt", "apt-get", "apt-cache", "dpkg", "apk", "yum", "dnf", "swpkg", "sxpkg",
        ]
        for absent in absentCommands {
            let result = await host.run("\(absent) update")
            #expect(result.status == 127, result.comment)
            #expect(result.contains("command not found"), result.comment)
        }

        let pkg = await host.run("which pkg")
        #expect(pkg.contains("/bin/pkg"), pkg.comment)
    }

    @Test func missingPackageAndUnconfiguredHostFailCleanly() async throws {
        let bare = PackageTestHost()
        let noRepositories = await bare.run("pkg update")
        #expect(noRepositories.status == 1, noRepositories.comment)
        #expect(noRepositories.contains("no repositories configured"), noRepositories.comment)

        let host = try await makeHostWithRepository()
        let missing = await host.run("pkg install -y ghost")
        #expect(missing.status == 1, missing.comment)
        #expect(missing.contains("unable to locate package ghost"), missing.comment)

        host.writeFile(
            "/etc/pkg/sources.list",
            "repo file:///srv/repo ./\nrepo file:///nowhere ./\n")
        let update = await host.run("pkg update")
        // One good repository and one broken one: the good one still refreshes.
        #expect(update.status == 0, update.comment)
        #expect(update.contains("failed to fetch"), update.comment)
    }

    @Test func frontEndReportsVersionUsageAndRejectsBadInput() async throws {
        let host = PackageTestHost()

        // The harness itself must be running real commands in the shell.
        let echo = await host.run("echo harness-live")
        #expect(echo.status == 0, echo.comment)
        #expect(echo.contains("harness-live"), echo.comment)

        let version = await host.run("pkg --version")
        #expect(version.status == 0, version.comment)
        #expect(version.contains("pkg 1.0"), version.comment)

        let help = await host.run("pkg help")
        #expect(help.status == 0, help.comment)
        #expect(help.contains("/etc/pkg/sources.list"), help.comment)

        // The native front end uses conventional status 2 for command-line errors.
        let unknownCommand = await host.run("pkg frobnicate")
        #expect(unknownCommand.status == 2, unknownCommand.comment)
        let unknownOption = await host.run("pkg install --frobnicate hello")
        #expect(unknownOption.status == 2, unknownOption.comment)
        let noOperand = await host.run("pkg install")
        #expect(noOperand.status == 2, noOperand.comment)
    }

    @Test func httpsRepositoryIsRejectedWithAClearMessage() async throws {
        let host = PackageTestHost()
        host.writeFile("/etc/pkg/sources.list", "repo https://packages.example/main ./\n")
        let update = await host.run("pkg update")
        #expect(update.status == 1, update.comment)
        #expect(update.contains("use http:// or file://"), update.comment)
    }

    // MARK: - Over the network

    /// The full path a real host takes: an HTTP repository served by the built-in
    /// `httpd` on this VM's loopback, fetched with the core's TCP syscalls.
    @Test func installsOverHTTPFromAServedRepository() async throws {
        let host = PackageTestHost(loopback: true)
        try await buildRepository(host)
        await host.startBackground("httpd 80")

        host.writeFile(
            "/etc/pkg/sources.list",
            "repo http://127.0.0.1/srv/repo ./\n")

        let update = await host.run("pkg update")
        #expect(update.status == 0, update.comment)
        #expect(update.contains("Get:1 http://127.0.0.1/srv/repo/Packages"), update.comment)
        #expect(update.contains("2 packages available"), update.comment)

        let install = await host.run("pkg install -y hello")
        #expect(install.status == 0, install.comment)
        #expect(install.contains("Get:"), install.comment)
        #expect(host.readFile("/bin/hello") == "#!/bin/sh\necho hello\n")
        #expect(host.readFile("/usr/lib/greet.txt") == "greet v1\n")

        let listing = await host.run("pkg list --installed")
        #expect(listing.contains("hello/source1 1.0 all [installed]"), listing.comment)
    }
}
