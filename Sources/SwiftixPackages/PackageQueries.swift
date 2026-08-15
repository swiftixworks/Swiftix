/// The read-only half of the manager (`list`, `search`, `info`) plus library
/// authoring APIs that produce package archives and repository indexes.
///
/// Being able to build a package from inside the emulator matters: it closes the
/// loop for the whole design. A VM can pack a program, another VM can serve the
/// directory with the built-in `httpd`, and a third can install from it — all
/// over the emulated network, with no external service and no host tooling.

import Swiftix

extension PackageManager {

    /// Selector for `list`.
    public enum ListFilter: Sendable {
        case all
        case installed
        case upgradable
    }

    // MARK: - Queries

    /// `pkg list`. Lines read `name/repository version [state]` — one record per
    /// line, so text-processing pipelines stay simple.
    public func list(_ filter: ListFilter) throws {
        let installed = try installedDatabase()

        switch filter {
        case .installed:
            emitListing(
                installed.sorted.map { package in
                    "\(package.name)/\(package.repository) \(package.version) \(package.manifest.architecture) "
                        + "[installed\(package.automatic ? ",automatic" : "")]"
                })

        case .upgradable:
            let resolver = try resolver()
            var lines: [String] = []
            for package in installed.sorted {
                guard let candidate = resolver.candidate(named: package.name),
                    candidate.version > package.version
                else { continue }
                lines.append(
                    "\(package.name)/\(candidate.repository) \(candidate.version) \(candidate.manifest.architecture) "
                        + "[upgradable from: \(package.version)]")
            }
            emitListing(lines)

        case .all:
            let resolver = try resolver()
            var lines: [String] = []
            for name in resolver.availableNames {
                guard let candidate = resolver.candidate(named: name) else { continue }
                var state = ""
                if let present = installed.package(named: name) {
                    state =
                        present.version < candidate.version
                        ? " [installed: \(present.version), upgradable]"
                        : " [installed]"
                }
                lines.append(
                    "\(name)/\(candidate.repository) \(candidate.version) "
                        + "\(candidate.manifest.architecture)\(state)")
            }
            // Installed packages whose repository no longer lists them still exist
            // on the host and must not vanish from `list`.
            for package in installed.sorted where resolver.candidate(named: package.name) == nil {
                lines.append(
                    "\(package.name)/\(package.repository) \(package.version) "
                        + "\(package.manifest.architecture) [installed,local]")
            }
            emitListing(lines.sorted())
        }
    }

    /// `pkg search`: case-insensitive substring match over names
    /// and summaries.
    public func search(_ term: String) throws {
        let needle = term.lowercased()
        let resolver = try resolver()
        let installed = try installedDatabase()
        var lines: [String] = []
        for name in resolver.availableNames {
            guard let candidate = resolver.candidate(named: name) else { continue }
            let haystack = (name + " " + candidate.manifest.summary).lowercased()
            guard haystack.contains(needle) else { continue }
            let marker = installed.package(named: name) != nil ? " [installed]" : ""
            lines.append(
                "\(name)/\(candidate.repository) \(candidate.version) "
                    + "\(candidate.manifest.architecture)\(marker)")
            if !candidate.manifest.summary.isEmpty {
                lines.append("  \(candidate.manifest.summary)")
            }
        }
        emitListing(lines)
    }

    /// `pkg info`: full metadata for each named package, preferring
    /// the installed record (which knows the file list) and falling back to the
    /// repository candidate.
    public func show(_ names: [String]) throws {
        guard !names.isEmpty else {
            throw PackageError.usage("info requires at least one package name")
        }
        let installed = try installedDatabase()
        // Installed packages remain inspectable before the first `pkg update`
        // and while a repository is unavailable. A query containing any
        // uninstalled name still requires repository metadata so misspellings
        // and unavailable indexes retain their normal diagnostics.
        let availableResolver: PackageResolver?
        if names.allSatisfy({ installed.package(named: $0) != nil }) {
            availableResolver = try? resolver()
        } else {
            availableResolver = try resolver()
        }
        var blocks: [String] = []

        for name in names {
            let present = installed.package(named: name)
            let candidate = availableResolver?.candidate(named: name)
            guard present != nil || candidate != nil else {
                throw PackageError.packageNotFound(name: name)
            }
            let manifest = present?.manifest ?? candidate!.manifest

            var text = ""
            text += "Package: \(manifest.name)\n"
            text += "Version: \(manifest.version)\n"
            if let candidate, candidate.version != manifest.version {
                text += "Candidate: \(candidate.version)\n"
            }
            text += "Architecture: \(manifest.architecture)\n"
            text += "Status: \(present == nil ? "not installed" : "installed")\n"
            if let present {
                text += "Origin: \(present.repository)\n"
                text += "Automatically-Installed: \(present.automatic ? "yes" : "no")\n"
                text += "Installed-Size: \(PackageText.humanBytes(present.installedSize))\n"
            } else if let candidate {
                text += "Origin: \(candidate.repository)\n"
                text += "Download-Size: \(PackageText.humanBytes(candidate.size))\n"
            }
            if !manifest.dependencies.isEmpty {
                text += "Depends: \(manifest.dependencies.map(\.description).joined(separator: ", "))\n"
            }
            if !manifest.conflicts.isEmpty {
                text += "Conflicts: \(manifest.conflicts.map(\.description).joined(separator: ", "))\n"
            }
            if !manifest.provides.isEmpty {
                text += "Provides: \(manifest.provides.joined(separator: ", "))\n"
            }
            if !manifest.summary.isEmpty {
                text += "Description: \(manifest.summary)\n"
                for line in manifest.details.split(
                    separator: "\n", omittingEmptySubsequences: false)
                {
                    text += " \(line.isEmpty ? "." : String(line))\n"
                }
            }
            blocks.append(text)
        }
        context.print(blocks.joined(separator: "\n"))
    }

    /// `pkg files <name>`: the paths a package owns, for auditing an install.
    public func files(_ name: String) throws {
        guard let package = try installedDatabase().package(named: name) else {
            throw PackageError.notInstalled(name: name)
        }
        emitListing(package.files)
    }

    /// Delete downloaded archives (`pkg clean`). Indexes are kept
    /// so the host can still resolve; `update` refreshes them.
    public func clean() throws {
        var removed = 0
        var bytes = 0
        for directory in [layout.archivesDirectory, layout.stagingDirectory] {
            for name in PackageStore.fileNames(context, in: directory) {
                let path = PackagePath.join(directory, name)
                bytes += context.stat(path)?.size ?? 0
                PackageStore.removeIfPresent(context, path)
                removed += 1
            }
        }
        emit("Deleted \(removed) archives, freeing \(PackageText.humanBytes(bytes)).")
    }

    // MARK: - Authoring

    /// Build a `.pkg` archive from a metadata stanza file and a staging root.
    ///
    /// Every regular file under `root` becomes an entry whose install path is its
    /// path relative to `root` (`root/bin/hello` → `/bin/hello`), carrying the
    /// mode it has in the VFS. Output is deterministic, so packing the same tree
    /// twice yields identical bytes.
    public func pack(manifestPath: String, root: String, output: String?) throws {
        let metadata = try PackageStore.readRequired(
            context,
            manifestPath,
            maximumBytes: PackageLimits.maximumIndexBytes)
        let stanzas = try PackageStanza.parse(String(decoding: metadata, as: UTF8.self))
        guard stanzas.count == 1, let stanza = stanzas.first else {
            throw PackageError.malformedArchive(
                reason: "\(manifestPath) must hold exactly one metadata stanza")
        }
        let manifest = try PackageManifest.decode(stanza, context: manifestPath)
        guard PackageStore.isDirectory(context, root) else {
            throw PackageError.ioFailure(path: root, operation: "read directory")
        }

        var files: [(path: String, mode: UInt16, bytes: [UInt8])] = []
        var directories: [String] = []
        try collect(root: root, relative: "", files: &files, directories: &directories)
        guard !files.isEmpty else {
            throw PackageError.malformedArchive(reason: "\(root) holds no files to package")
        }

        let archive = try PackageArchive.build(
            manifest: manifest,
            files: files,
            directories: directories)
        let bytes = archive.encoded()
        let destination = output ?? "\(manifest.identifier)\(SwiftixPackages.archiveExtension)"
        try PackageStore.writeAtomically(context, absolute(destination), bytes: bytes, mode: 0o644)
        emit("Built \(destination) (\(files.count) files, \(PackageText.humanBytes(bytes.count)))")
    }

    /// Scan a directory of `.pkg` files and write the `Packages` index that
    /// turns it into a repository.
    public func makeIndex(directory: String) throws {
        let root = absolute(directory)
        guard PackageStore.isDirectory(context, root) else {
            throw PackageError.ioFailure(path: root, operation: "read directory")
        }
        var packages: [RepositoryPackage] = []
        var scanned: [(relative: String, path: String)] = []

        // The repository root plus one conventional level (`pool/`), which is
        // enough structure for a readable layout without an unbounded walk.
        let suffix = SwiftixPackages.archiveExtension
        for name in PackageStore.fileNames(context, in: root) where name.hasSuffix(suffix) {
            scanned.append((name, PackagePath.join(root, name)))
        }
        for subdirectory in PackageStore.directoryNames(context, in: root) {
            let child = PackagePath.join(root, subdirectory)
            for name in PackageStore.fileNames(context, in: child) where name.hasSuffix(suffix) {
                scanned.append(("\(subdirectory)/\(name)", PackagePath.join(child, name)))
            }
        }

        for candidate in scanned.sorted(by: { $0.relative < $1.relative }) {
            let bytes = try PackageStore.readRequired(
                context,
                candidate.path,
                maximumBytes: PackageLimits.maximumArchiveBytes)
            let archive = try PackageArchive.decode(bytes)
            packages.append(
                RepositoryPackage(
                    manifest: archive.manifest,
                    filename: candidate.relative,
                    size: bytes.count,
                    digest: PackageDigest.hex(bytes),
                    repository: "local"))
        }
        guard !packages.isEmpty else {
            throw PackageError.malformedIndex(
                repository: root,
                reason: "no \(suffix) files found")
        }
        let text = RepositoryIndex.render(packages)
        try PackageStore.writeAtomically(
            context,
            PackagePath.join(root, "Packages"),
            bytes: Array(text.utf8),
            mode: 0o644)
        emit("Indexed \(packages.count) packages in \(root)")
    }

    /// Recursively gather a staging tree's files, recording their VFS modes.
    private func collect(
        root: String,
        relative: String,
        files: inout [(path: String, mode: UInt16, bytes: [UInt8])],
        directories: inout [String]
    ) throws {
        let directory = relative.isEmpty ? root : PackagePath.join(root, relative)
        for name in PackageStore.directoryNames(context, in: directory) {
            let child = relative.isEmpty ? name : "\(relative)/\(name)"
            directories.append("/" + child)
            try collect(root: root, relative: child, files: &files, directories: &directories)
        }
        for name in PackageStore.fileNames(context, in: directory) {
            let child = relative.isEmpty ? name : "\(relative)/\(name)"
            let path = PackagePath.join(directory, name)
            let bytes = try PackageStore.readRequired(
                context,
                path,
                maximumBytes: PackageLimits.maximumEntryBytes)
            let mode = context.stat(path)?.mode.rawValue ?? 0o644
            files.append(("/" + child, mode, bytes))
        }
    }

    // MARK: - Small shared helpers

    /// Resolve a user-supplied path against the process's working directory, so
    /// relative arguments behave like they do for every other command.
    private func absolute(_ path: String) -> String {
        if path.hasPrefix("/") { return PackagePath.normalizeAbsolute(path) ?? path }
        let joined = PackagePath.join(context.currentDirectory, path)
        return PackagePath.normalizeAbsolute(joined) ?? joined
    }

    private func emitListing(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        context.print(lines.joined(separator: "\n") + "\n")
    }
}
