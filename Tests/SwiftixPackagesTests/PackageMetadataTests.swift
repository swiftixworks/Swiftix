import Testing

@testable import SwiftixPackages

/// The data layer: version ordering, dependency grammar, the stanza metadata used
/// by indexes and the status database, and the `.pkg` container (including the
/// integrity checks that make an HTTP repository safe to install from).
@Suite("Package metadata and archive format")
struct PackageMetadataTests {

    // MARK: - Versions

    @Test func versionOrderingFollowsDistributionRules() {
        func version(_ text: String) -> PackageVersion {
            guard let value = PackageVersion(text) else {
                Issue.record("\(text) should parse")
                return PackageVersion("0")!
            }
            return value
        }

        // Debian epochs, tilde prereleases and Debian revisions.
        let ascending = ["1.2", "1.2.1", "1.3~beta1", "1.3~rc2", "1.3", "1.3-1", "1.3-2", "2.0", "1:1.0"]
            .map(version)
        for (left, right) in zip(ascending, ascending.dropFirst()) {
            #expect(left < right, "expected \(left) < \(right)")
        }
        // Leading zeros inside a numeric run are not significant.
        #expect(version("1.02") == version("1.2"))
        #expect(version("1.02").hashValue == version("1.2").hashValue)
        #expect(version("1.2") < version("1.2.0"))
    }

    @Test func versionRejectsMalformedText() {
        #expect(PackageVersion("") == nil)
        #expect(PackageVersion("1.2/x") == nil)
        #expect(PackageVersion("1.2_3") == nil)
        #expect(PackageVersion("1.2 3") == nil)
        #expect(PackageVersion("v1.2") == nil)
    }

    // MARK: - Dependencies

    @Test func dependencyUsesDebianRelationshipSyntax() {
        let debian = PackageDependency(parsing: "libgreet (>= 1.2)")
        #expect(debian?.name == "libgreet")
        #expect(debian?.relation == .laterOrEqual)
        #expect(PackageDependency(parsing: "libgreet >= 1.2") == nil)

        let bare = PackageDependency(parsing: "coreutils")
        #expect(bare?.relation == nil)
        #expect(bare?.isUnversioned == true)

        #expect(PackageDependency(parsing: "bad name") == nil)
        #expect(PackageDependency(parsing: "libgreet (>= )") == nil)
        #expect(PackageDependency(parsing: "libgreet (~ 1.0)") == nil)
    }

    @Test func dependencySatisfactionRespectsRelation() {
        let atLeast = PackageDependency(parsing: "libgreet (>= 1.2)")!
        #expect(atLeast.isSatisfied(by: PackageVersion("1.2")!))
        #expect(atLeast.isSatisfied(by: PackageVersion("1.3")!))
        #expect(!atLeast.isSatisfied(by: PackageVersion("1.1.9")!))

        let exact = PackageDependency(parsing: "libgreet (= 1.2)")!
        #expect(!exact.isSatisfied(by: PackageVersion("1.2.0")!))
        #expect(exact.isSatisfied(by: PackageVersion("1.02")!))
        #expect(!exact.isSatisfied(by: PackageVersion("1.2-1")!))
    }

    @Test func manifestSatisfiesVirtualNameOnlyWhenUnversioned() {
        let manifest = PackageManifest(
            name: "gnu-hello",
            version: PackageVersion("2.0")!,
            provides: ["hello"])
        #expect(manifest.satisfies(PackageDependency(parsing: "hello")!))
        #expect(!manifest.satisfies(PackageDependency(parsing: "hello (>= 1.0)")!))
        #expect(manifest.satisfies(PackageDependency(parsing: "gnu-hello (>= 1.0)")!))
    }

    // MARK: - Stanza round-trips

    @Test func manifestSurvivesStanzaRoundTrip() throws {
        let manifest = PackageManifest(
            name: "hello",
            version: PackageVersion("1.2.0-2")!,
            architecture: "all",
            summary: "friendly greeter",
            details: "prints a greeting",
            dependencies: [PackageDependency(parsing: "libgreet (>= 1.0)")!],
            conflicts: [PackageDependency(parsing: "hello-legacy")!],
            provides: ["greeter"])
        let stanzas = try PackageStanza.parse(manifest.encoded().rendered())
        let decoded = try PackageManifest.decode(stanzas[0], context: "test")
        #expect(decoded == manifest)
    }

    @Test func repositoryIndexRequiresVerifiableEntries() throws {
        let good = """
            Package: hello
            Version: 1.0
            Architecture: all
            Description: greeter
            Filename: pool/hello_1.0.pkg
            Size: 12
            SHA256: \(String(repeating: "a", count: 64))
            """
        let index = try RepositoryIndex.parse(good, repository: "main", priority: 3)
        #expect(index.packages.count == 1)
        #expect(index.packages[0].priority == 3)
        #expect(index.packages[0].cacheName == "hello_1.0.pkg")

        // A missing digest, a missing size, or an escaping filename are all fatal:
        // unverifiable metadata must never reach the installer.
        let noDigest = """
            Package: hello
            Version: 1.0
            Filename: pool/hello_1.0.pkg
            Size: 12
            """
        #expect(throws: PackageError.self) {
            try RepositoryIndex.parse(noDigest, repository: "main")
        }
        let escaping = """
            Package: hello
            Version: 1.0
            Filename: ../../etc/passwd
            Size: 12
            SHA256: \(String(repeating: "a", count: 64))
            """
        #expect(throws: PackageError.self) {
            try RepositoryIndex.parse(escaping, repository: "main")
        }
    }

    @Test func installedDatabaseRoundTripsOwnershipAndFlags() throws {
        let package = InstalledPackage(
            manifest: PackageManifest(name: "hello", version: PackageVersion("1.0")!),
            repository: "main",
            files: ["/bin/hello", "/usr/share/doc/hello/README"],
            directories: ["/usr/share/doc/hello"],
            installedSize: 42,
            automatic: true)
        var database = InstalledDatabase()
        database.insert(package)

        let decoded = try InstalledDatabase.parse(database.rendered())
        #expect(decoded.package(named: "hello") == package)
        #expect(decoded.owner(ofFile: "/bin/hello") == "hello")
        #expect(decoded.owner(ofFile: "/bin/other") == nil)
        #expect(decoded.satisfies(PackageDependency(parsing: "hello (>= 1.0)")!))
        #expect(!decoded.satisfies(PackageDependency(parsing: "hello")!, excluding: ["hello"]))
    }

    @Test func sourcesListParsingRejectsUnsupportedSchemes() throws {
        let repositories = try PackageRepository.parse(
            """
            # comment
            repo http://packages.example/main/ ./
            repo file:///srv/repo ./
            """)
        #expect(repositories.map(\.name) == ["source1", "source2"])
        #expect(repositories[0].baseURL == "http://packages.example/main")
        #expect(repositories[0].indexURL == "http://packages.example/main/Packages")
        #expect(repositories[0].priority == 0)
        #expect(repositories[1].priority == 1)

        #expect(throws: PackageError.self) {
            try PackageRepository.parse("repo https://packages.example/main ./")
        }
        #expect(throws: PackageError.self) {
            try PackageRepository.parse("repo http://packages.example/main")
        }
        #expect(throws: PackageError.self) {
            try PackageRepository.parse("repo http://a/x ./\nrepo http://a/x ./")
        }
    }

    // MARK: - Archive container

    private func sampleArchive() throws -> PackageArchive {
        try PackageArchive.build(
            manifest: PackageManifest(
                name: "hello",
                version: PackageVersion("1.0")!,
                summary: "greeter"),
            files: [
                (path: "/bin/hello", mode: 0o755, bytes: Array("#!/bin/sh\necho hi\n".utf8)),
                (path: "/usr/share/doc/hello/README", mode: 0o644, bytes: Array("read me\n".utf8)),
            ])
    }

    @Test func archiveRoundTripsAndIsDeterministic() throws {
        let archive = try sampleArchive()
        let encoded = archive.encoded()
        let again = try sampleArchive().encoded()
        #expect(encoded == again, "packing identical input must be byte-identical")

        let decoded = try PackageArchive.decode(encoded)
        #expect(decoded.manifest == archive.manifest)
        #expect(decoded.files.map(\.path) == ["/bin/hello", "/usr/share/doc/hello/README"])
        #expect(String(decoding: decoded.contents(of: decoded.files[1]), as: UTF8.self) == "read me\n")
        #expect(decoded.files[0].mode == 0o755)
        #expect(decoded.installedSize == archive.installedSize)

        // Implicit parents are owned so removal can prune them.
        #expect(decoded.directories.map(\.path).contains("/usr/share/doc/hello"))
        #expect(decoded.directories.map(\.path).contains("/bin"))
    }

    @Test func archiveMatchesTheRepositoryFormatV2GoldenDigest() throws {
        let manifest = PackageManifest(
            name: "hello",
            version: PackageVersion("1.2.0-2")!,
            architecture: "all",
            summary: "friendly greeter",
            details: "prints a greeting",
            dependencies: [PackageDependency(parsing: "libgreet (>= 1.0)")!],
            conflicts: [PackageDependency(parsing: "hello-legacy")!],
            provides: ["greeter"])
        let archive = try PackageArchive.build(
            manifest: manifest,
            files: [
                (path: "/bin/hello", mode: 0o755, bytes: Array("#!/bin/sh\necho hello\n".utf8)),
                (path: "/usr/share/doc/hello/README", mode: 0o644, bytes: Array("hello docs\n".utf8)),
            ])
        #expect(
            PackageDigest.hex(archive.encoded())
                == "c875b423823eeab8d059e66cabf1dc114e3bebb465b25d3be13e08035486e6cb")
    }

    @Test func archiveDetectsTamperedPayload() throws {
        var bytes = try sampleArchive().encoded()
        // Flip a byte inside the payload (the last entry's content).
        bytes[bytes.count - 2] = bytes[bytes.count - 2] ^ 0x01
        #expect(throws: PackageError.self) { try PackageArchive.decode(bytes) }
    }

    @Test func archiveDetectsTruncation() throws {
        let bytes = try sampleArchive().encoded()
        #expect(throws: PackageError.self) { try PackageArchive.decode(Array(bytes.dropLast(3))) }
    }

    @Test func archiveRejectsPathEscapeAndSyntheticFilesystems() throws {
        let manifest = PackageManifest(name: "evil", version: PackageVersion("1.0")!)
        #expect(throws: PackageError.self) {
            try PackageArchive.build(
                manifest: manifest,
                files: [(path: "/bin/../../etc/passwd", mode: 0o644, bytes: [])])
        }
        #expect(throws: PackageError.self) {
            try PackageArchive.build(
                manifest: manifest,
                files: [(path: "/proc/self/mem", mode: 0o644, bytes: [])])
        }
        #expect(throws: PackageError.self) {
            try PackageArchive.build(
                manifest: manifest,
                files: [(path: "relative/path", mode: 0o644, bytes: [])])
        }
        // The package database itself is off limits, even for a well-formed path.
        #expect(throws: PackageError.self) {
            try PackageArchive.build(
                manifest: manifest,
                files: [(path: "/var/lib/pkg/status", mode: 0o644, bytes: [])])
        }
    }

    @Test func archiveRejectsForeignMagic() {
        #expect(throws: PackageError.self) {
            try PackageArchive.decode(Array("not an archive\n%%\n".utf8))
        }
    }

    // MARK: - Digest

    @Test func digestMatchesKnownVectors() {
        #expect(
            PackageDigest.hex([])
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(
            PackageDigest.hex(Array("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Multi-block input exercises the buffering path.
        let long = Array(String(repeating: "swiftix", count: 100).utf8)
        #expect(PackageDigest.hex(long).count == 64)
        #expect(PackageDigest.verify(long, expected: PackageDigest.hex(long).uppercased()))
    }
}
