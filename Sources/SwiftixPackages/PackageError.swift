/// Every failure the package manager can report, in one place.
///
/// A single error type for the whole module means each diagnostic is written once,
/// next to the check that produces it: the command layer only ever prints
/// `error.message`.

public enum PackageError: Error, Sendable, Equatable {

    // MARK: - Configuration / metadata

    case malformedSourcesList(line: Int, reason: String)
    case noRepositoriesConfigured(path: String)
    case malformedIndex(repository: String, reason: String)
    case malformedDatabase(reason: String)
    case malformedArchive(reason: String)
    case unsupportedFormat(found: String, expected: String)

    // MARK: - Transport

    case unsupportedURLScheme(url: String)
    case malformedURL(url: String)
    case unresolvableHost(host: String)
    case connectionFailed(host: String, port: UInt16)
    case httpStatus(url: String, status: Int)
    case responseTooLarge(url: String, limit: Int)
    case tooManyRedirects(url: String)
    case indexUnavailable(repository: String)

    // MARK: - Resolution

    case packageNotFound(name: String)
    case noCandidate(dependency: String)
    case conflictingRequirement(name: String, selected: String, required: String)
    case ambiguousVirtualPackage(name: String, providers: [String])
    case conflict(package: String, with: String)
    case notInstalled(name: String)
    case dependencyBreakage(package: String, dependents: [String])
    case alreadyInstalled(name: String, version: String)

    // MARK: - Integrity / installation

    case digestMismatch(path: String, expected: String, actual: String)
    case sizeMismatch(path: String, expected: Int, actual: Int)
    case fileConflict(path: String, package: String, owner: String)
    case unownedFileInTheWay(path: String, package: String)
    case forbiddenPath(path: String)
    case ioFailure(path: String, operation: String)
    case architectureMismatch(package: String, architecture: String, host: String)

    // MARK: - CLI

    case usage(String)
    case unknownOption(String)

    /// The single-line diagnostic printed to stderr (without a trailing newline).
    public var message: String {
        switch self {
        case let .malformedSourcesList(line, reason):
            return "malformed sources list at line \(line): \(reason)"
        case let .noRepositoriesConfigured(path):
            return "no repositories configured; add one to \(path)"
        case let .malformedIndex(repository, reason):
            return "repository '\(repository)' has a malformed index: \(reason)"
        case let .malformedDatabase(reason):
            return "installed database is malformed: \(reason)"
        case let .malformedArchive(reason):
            return "malformed package archive: \(reason)"
        case let .unsupportedFormat(found, expected):
            return "unsupported format '\(found)', expected '\(expected)'"

        case let .unsupportedURLScheme(url):
            return "unsupported URL '\(url)': only http:// and file:// repositories are supported"
        case let .malformedURL(url):
            return "malformed URL '\(url)'"
        case let .unresolvableHost(host):
            return "cannot resolve '\(host)'"
        case let .connectionFailed(host, port):
            return "cannot connect to \(host):\(port)"
        case let .httpStatus(url, status):
            return "server returned HTTP \(status) for \(url)"
        case let .responseTooLarge(url, limit):
            return "\(url) exceeds the \(limit) byte limit"
        case let .tooManyRedirects(url):
            return "too many redirects fetching \(url)"
        case let .indexUnavailable(repository):
            return "no index for repository '\(repository)'; run 'pkg update' first"

        case let .packageNotFound(name):
            return "unable to locate package \(name)"
        case let .noCandidate(dependency):
            return "no candidate satisfies \(dependency)"
        case let .conflictingRequirement(name, selected, required):
            return "conflicting requirements for \(name): selected \(selected), but \(required) is required"
        case let .ambiguousVirtualPackage(name, providers):
            return "\(name) is a virtual package provided by: \(providers.joined(separator: ", "))"
        case let .conflict(package, with):
            return "\(package) conflicts with \(with)"
        case let .notInstalled(name):
            return "package \(name) is not installed"
        case let .dependencyBreakage(package, dependents):
            return "removing \(package) would break: \(dependents.joined(separator: ", "))"
        case let .alreadyInstalled(name, version):
            return "\(name) is already the newest version (\(version))"

        case let .digestMismatch(path, expected, actual):
            return "digest mismatch for \(path): expected \(expected), got \(actual)"
        case let .sizeMismatch(path, expected, actual):
            return "size mismatch for \(path): expected \(expected) bytes, got \(actual)"
        case let .fileConflict(path, package, owner):
            return "\(package) tries to overwrite \(path), which is owned by \(owner)"
        case let .unownedFileInTheWay(path, package):
            return "\(package) tries to overwrite existing \(path); pass --force-overwrite to replace it"
        case let .forbiddenPath(path):
            return "package tries to install outside the permitted tree: \(path)"
        case let .ioFailure(path, operation):
            return "cannot \(operation) \(path)"
        case let .architectureMismatch(package, architecture, host):
            return "\(package) is built for \(architecture), not \(host)"

        case let .usage(text):
            return text
        case let .unknownOption(option):
            return "unrecognized option '\(option)'"
        }
    }

    /// Process exit status: usage problems mirror the shell's `2`, everything
    /// else is a plain failure.
    public var exitCode: Int32 {
        switch self {
        case .usage, .unknownOption:
            return 2
        default:
            return 1
        }
    }
}
