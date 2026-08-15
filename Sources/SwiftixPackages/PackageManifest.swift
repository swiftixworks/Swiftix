/// What a package *is*: its identity, its relations to other packages, and the
/// stanza encoding of both.
///
/// The manifest is the unit every other layer agrees on — the repository index
/// carries one per available package, the archive embeds its own, and the
/// installed database stores the one that was committed. Keeping a single type
/// (and a single parser) for all three is what makes `pkg info`, dependency
/// resolution and upgrade comparison operate on identical data.

import Swiftix

/// A Debian package relation: a name, optionally constrained to a version.
public struct PackageDependency: Sendable, Hashable, CustomStringConvertible {

    public enum Relation: String, Sendable, Hashable {
        case earlier = "<<"
        case earlierOrEqual = "<="
        case equal = "="
        case laterOrEqual = ">="
        case later = ">>"
    }

    public let name: String
    public let relation: Relation?
    public let version: PackageVersion?

    public init(name: String, relation: Relation? = nil, version: PackageVersion? = nil) {
        self.name = name
        self.relation = relation
        self.version = version
    }

    /// Parse one dependency term. Returns `nil` on malformed input so the caller
    /// can attribute the error to the file and line it came from.
    public init?(parsing text: String) {
        let trimmed = PackageText.trim(text)
        guard !trimmed.isEmpty else { return nil }

        // Debian form: name (op version)
        if let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") {
            let name = PackageText.trim(String(trimmed[trimmed.startIndex..<open]))
            let inner = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            guard PackageManifest.isValidName(name),
                let constraint = Self.parseConstraint(inner)
            else { return nil }
            self.init(name: name, relation: constraint.relation, version: constraint.version)
            return
        }

        // An unconstrained Debian relation is a bare package name.
        let fields = PackageText.whitespaceSeparated(trimmed)
        switch fields.count {
        case 1:
            guard PackageManifest.isValidName(fields[0]) else { return nil }
            self.init(name: fields[0])
        default:
            return nil
        }
    }

    private static func parseConstraint(_ text: String) -> (relation: Relation, version: PackageVersion)? {
        let trimmed = PackageText.trim(text)
        // Debian relationship operators, longest first.
        let operators: [(token: String, relation: Relation)] = [
            ("<<", .earlier), (">>", .later),
            ("<=", .earlierOrEqual), (">=", .laterOrEqual),
            ("=", .equal),
        ]
        for candidate in operators where trimmed.hasPrefix(candidate.token) {
            let rest = PackageText.trim(String(trimmed.dropFirst(candidate.token.count)))
            guard let version = PackageVersion(rest) else { return nil }
            return (candidate.relation, version)
        }
        return nil
    }

    /// Whether a concrete version satisfies this term. An unconstrained term is
    /// satisfied by any version — that is also what lets a virtual `Provides`
    /// (which carries no version) satisfy it.
    public func isSatisfied(by candidate: PackageVersion) -> Bool {
        guard let relation, let version else { return true }
        switch relation {
        case .earlier: return candidate < version
        case .earlierOrEqual: return candidate <= version
        case .equal: return candidate == version
        case .laterOrEqual: return candidate >= version
        case .later: return candidate > version
        }
    }

    /// True when the term names a package without restricting its version.
    public var isUnversioned: Bool { relation == nil || version == nil }

    public var description: String {
        guard let relation, let version else { return name }
        return "\(name) (\(relation.rawValue) \(version))"
    }
}

/// Identity plus relations. Payload layout lives in `PackageArchive`; where a
/// package can be downloaded lives in `RepositoryIndex`.
public struct PackageManifest: Sendable, Hashable {

    /// Architecture value meaning "runs anywhere", used by pure data and
    /// documentation packages that contain no executable image.
    public static let architectureIndependent = "all"

    public let name: String
    public let version: PackageVersion
    public let architecture: String
    public let summary: String
    public let details: String
    public let dependencies: [PackageDependency]
    public let conflicts: [PackageDependency]
    public let provides: [String]

    public init(
        name: String,
        version: PackageVersion,
        architecture: String = PackageManifest.architectureIndependent,
        summary: String = "",
        details: String = "",
        dependencies: [PackageDependency] = [],
        conflicts: [PackageDependency] = [],
        provides: [String] = []
    ) {
        self.name = name
        self.version = version
        self.architecture = architecture
        self.summary = summary
        self.details = details
        self.dependencies = dependencies
        self.conflicts = conflicts
        self.provides = provides
    }

    /// `name_version` — the canonical archive filename stem and cache key.
    public var identifier: String { "\(name)_\(version)" }

    /// Package names are also filename components and shell words, so the
    /// grammar is restrictive on purpose: no slashes, no spaces, no leading
    /// punctuation.
    public static func isValidName(_ name: String) -> Bool {
        guard name.count >= 2, name.count <= 128 else { return false }
        guard let first = name.first, first.isASCII, first.isLowercase || first.isNumber else { return false }
        return name.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLowercase || character.isNumber
                || character == "-" || character == "+" || character == "."
        }
    }

    /// Whether this package satisfies `dependency`, directly or by `Provides`.
    /// A virtual name has no version, so it can only satisfy an unversioned term.
    public func satisfies(_ dependency: PackageDependency) -> Bool {
        if dependency.name == name { return dependency.isSatisfied(by: version) }
        if provides.contains(dependency.name) { return dependency.isUnversioned }
        return false
    }

    // MARK: - Stanza encoding

    /// Decode a manifest from a stanza. `context` names the file for diagnostics.
    static func decode(_ stanza: PackageStanza, context: String) throws -> PackageManifest {
        guard let name = stanza.value(of: "Package"), isValidName(name) else {
            throw PackageError.malformedIndex(
                repository: context,
                reason: "missing or invalid Package field")
        }
        guard let versionText = stanza.value(of: "Version"), let version = PackageVersion(versionText) else {
            throw PackageError.malformedIndex(
                repository: context,
                reason: "package \(name) has a missing or invalid Version")
        }
        let architecture = stanza.value(of: "Architecture") ?? architectureIndependent

        func relations(_ field: String) throws -> [PackageDependency] {
            var result: [PackageDependency] = []
            for term in stanza.values(of: field).flatMap(PackageText.commaSeparated) {
                guard let dependency = PackageDependency(parsing: term) else {
                    throw PackageError.malformedIndex(
                        repository: context,
                        reason: "package \(name) has an invalid \(field) term '\(term)'")
                }
                result.append(dependency)
            }
            return result
        }

        let provides = stanza.values(of: "Provides").flatMap(PackageText.commaSeparated)
        for virtualName in provides where !isValidName(virtualName) {
            throw PackageError.malformedIndex(
                repository: context,
                reason: "package \(name) provides an invalid name '\(virtualName)'")
        }

        let description = stanza.value(of: "Description") ?? ""
        let descriptionLines = description.split(
            separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)

        return PackageManifest(
            name: name,
            version: version,
            architecture: architecture,
            summary: descriptionLines.first ?? "",
            details: descriptionLines.count > 1 ? descriptionLines[1] : "",
            dependencies: try relations("Depends"),
            conflicts: try relations("Conflicts"),
            provides: provides)
    }

    /// Encode the identity/relation fields. Callers add their own fields
    /// (`Filename`, `SHA256`, `Status`, …) to the returned stanza.
    func encoded() -> PackageStanza {
        var stanza = PackageStanza()
        stanza.set("Package", name)
        stanza.set("Version", version.text)
        stanza.set("Architecture", architecture)
        let description = details.isEmpty ? summary : summary + "\n" + details
        stanza.set("Description", description)
        if !dependencies.isEmpty {
            stanza.set("Depends", dependencies.map(\.description).joined(separator: ", "))
        }
        if !conflicts.isEmpty {
            stanza.set("Conflicts", conflicts.map(\.description).joined(separator: ", "))
        }
        if !provides.isEmpty {
            stanza.set("Provides", provides.joined(separator: ", "))
        }
        return stanza
    }

    /// Reject a package built for a different architecture. `all` matches every
    /// host. Swiftix's current native host architecture is `svm64`.
    func checkArchitecture(host: String) throws {
        guard architecture == Self.architectureIndependent || architecture == host else {
            throw PackageError.architectureMismatch(
                package: name,
                architecture: architecture,
                host: host)
        }
    }
}
