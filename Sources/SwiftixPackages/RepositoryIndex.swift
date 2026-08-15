/// Repositories: where packages come from, and the index that describes them.
///
/// A repository is just a directory tree served over HTTP (or present in the
/// VFS): an index file named `Packages` at its root, plus the archives it points
/// at. That is enough to host one from any Swiftix VM with `httpd`, which makes
/// the whole distribution mechanism observable inside the emulator instead of
/// depending on an external service.
///
///     http://packages.example/main/Packages          ← index
///     http://packages.example/main/pool/hello_1.0.pkg
///
/// The index is stanza-format metadata (`PackageManifest` fields) plus the three
/// fields the fetcher needs: `Filename`, `Size` and `SHA256`. Size and digest are
/// mandatory — a package whose bytes are not pinned by the index cannot be
/// verified, and unverified bytes are never written to the filesystem.

/// One configured repository. `priority` is the position in the sources list;
/// lower wins ties between equal versions, so the operator controls precedence
/// by ordering the file.
public struct PackageRepository: Sendable, Equatable {

    public let name: String
    /// Base URL without a trailing slash (`http://host/main`, `file:///srv/repo`).
    public let baseURL: String
    public let priority: Int

    public init(name: String, baseURL: String, priority: Int) {
        self.name = name
        self.baseURL = baseURL
        self.priority = priority
    }

    /// URL of the repository index.
    public var indexURL: String { PackageURL.join(baseURL, "Packages") }

    /// URL of a package file named relative to the repository root.
    public func url(forFilename filename: String) -> String {
        PackageURL.join(baseURL, filename)
    }

    /// Parse `/etc/pkg/sources.list`. Swiftix uses a flat repository layout:
    ///
    ///     # comments and blank lines are ignored
    ///     repo http://packages.example/repo ./
    ///     repo file:///srv/repo ./
    ///
    public static func parse(_ text: String) throws -> [PackageRepository] {
        var repositories: [PackageRepository] = []
        var lineNumber = 0
        var seen = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = PackageText.trim(String(rawLine))
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = PackageText.whitespaceSeparated(line)
            guard fields.count == 3, fields[0] == "repo", fields[2] == "./" else {
                throw PackageError.malformedSourcesList(
                    line: lineNumber, reason: "expected 'repo <base-url> ./'")
            }
            let url = fields[1]
            guard seen.insert(url).inserted else {
                throw PackageError.malformedSourcesList(
                    line: lineNumber, reason: "duplicate source '\(url)'")
            }
            guard PackageURL.isSupported(url) else {
                throw PackageError.malformedSourcesList(
                    line: lineNumber,
                    reason: "unsupported URL '\(url)' (use http:// or file://)")
            }
            repositories.append(
                PackageRepository(
                    name: "source\(repositories.count + 1)",
                    baseURL: PackageURL.trimmingTrailingSlash(url),
                    priority: repositories.count))
        }
        return repositories
    }
}

/// An available package: its manifest plus how to fetch and verify it.
public struct RepositoryPackage: Sendable, Equatable {

    public let manifest: PackageManifest
    /// Path relative to the repository root.
    public let filename: String
    public let size: Int
    public let digest: String
    /// Repository this entry came from (filled in when the index is loaded).
    public let repository: String
    public let priority: Int

    public init(
        manifest: PackageManifest,
        filename: String,
        size: Int,
        digest: String,
        repository: String,
        priority: Int = 0
    ) {
        self.manifest = manifest
        self.filename = filename
        self.size = size
        self.digest = digest
        self.repository = repository
        self.priority = priority
    }

    public var name: String { manifest.name }
    public var version: PackageVersion { manifest.version }

    /// Cache filename for the downloaded archive.
    public var cacheName: String { "\(manifest.identifier)\(SwiftixPackages.archiveExtension)" }

    func encoded() -> PackageStanza {
        var stanza = manifest.encoded()
        stanza.set("Filename", filename)
        stanza.set("Size", "\(size)")
        stanza.set("SHA256", digest)
        return stanza
    }
}

/// The parsed `Packages` file of one repository.
public struct RepositoryIndex: Sendable {

    public let repository: String
    public let packages: [RepositoryPackage]

    public init(repository: String, packages: [RepositoryPackage]) {
        self.repository = repository
        self.packages = packages
    }

    /// Parse an index. `repository`/`priority` tag each entry with its origin, so
    /// merged views can report which repository a candidate came from.
    public static func parse(
        _ text: String,
        repository: String,
        priority: Int = 0
    ) throws -> RepositoryIndex {
        let stanzas: [PackageStanza]
        do {
            stanzas = try PackageStanza.parse(text)
        } catch {
            throw PackageError.malformedIndex(
                repository: repository,
                reason: "not stanza-formatted metadata")
        }
        var packages: [RepositoryPackage] = []
        for stanza in stanzas {
            let manifest = try PackageManifest.decode(stanza, context: repository)
            guard let filename = stanza.value(of: "Filename"), !filename.isEmpty,
                !filename.hasPrefix("/"), !filename.contains("..")
            else {
                throw PackageError.malformedIndex(
                    repository: repository,
                    reason: "package \(manifest.name) has a missing or unsafe Filename")
            }
            guard let sizeText = stanza.value(of: "Size"), let size = Int(sizeText), size >= 0,
                size <= PackageLimits.maximumArchiveBytes
            else {
                throw PackageError.malformedIndex(
                    repository: repository,
                    reason: "package \(manifest.name) has a missing or invalid Size")
            }
            guard let digest = stanza.value(of: "SHA256")?.lowercased(), digest.count == 64,
                digest.allSatisfy({ $0.isHexDigit && $0.isASCII })
            else {
                throw PackageError.malformedIndex(
                    repository: repository,
                    reason: "package \(manifest.name) has a missing or invalid SHA256")
            }
            packages.append(
                RepositoryPackage(
                    manifest: manifest,
                    filename: filename,
                    size: size,
                    digest: digest,
                    repository: repository,
                    priority: priority))
        }
        return RepositoryIndex(repository: repository, packages: packages)
    }

    /// Render an index file for a directory of archives.
    public static func render(_ packages: [RepositoryPackage]) -> String {
        PackageStanza.render(
            packages
                .sorted { ($0.name, $0.version) < ($1.name, $1.version) }
                .map { $0.encoded() })
    }
}

/// URL handling for the two supported schemes. Small and explicit rather than a
/// general parser: the package manager only ever needs "join a base and a
/// relative name" and "split into host/port/path".
enum PackageURL {

    static func isSupported(_ url: String) -> Bool {
        url.hasPrefix("http://") || url.hasPrefix("file://")
    }

    static func trimmingTrailingSlash(_ url: String) -> String {
        var value = url
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func join(_ base: String, _ component: String) -> String {
        trimmingTrailingSlash(base) + "/" + component
    }

    /// `http://host[:port]/path` split into its parts, defaulting port 80 and
    /// path `/`.
    static func parseHTTP(_ url: String) -> (host: String, port: UInt16, path: String)? {
        guard url.hasPrefix("http://") else { return nil }
        var rest = Substring(url.dropFirst("http://".count))
        let authority: Substring
        let path: String
        if let slash = rest.firstIndex(of: "/") {
            authority = rest[rest.startIndex..<slash]
            path = String(rest[slash...])
        } else {
            authority = rest
            path = "/"
        }
        rest = authority
        var port: UInt16 = 80
        let host: String
        if let colon = authority.firstIndex(of: ":") {
            host = String(authority[authority.startIndex..<colon])
            guard let parsed = UInt16(authority[authority.index(after: colon)...]) else { return nil }
            port = parsed
        } else {
            host = String(authority)
        }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return (host, port, path)
    }

    /// VFS path behind a `file://` URL (`file:///srv/repo/Packages` → `/srv/repo/Packages`).
    static func parseFile(_ url: String) -> String? {
        guard url.hasPrefix("file://") else { return nil }
        let path = String(url.dropFirst("file://".count))
        guard path.hasPrefix("/") else { return nil }
        return PackagePath.normalizeAbsolute(path)
    }
}
