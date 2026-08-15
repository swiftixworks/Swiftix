/// Applying a plan to the filesystem — the part that must never leave the host
/// half-installed.
///
/// The VFS gives us one primitive strong enough to build on: `rename`, which
/// atomically re-parents a node and keeps open descriptors valid. Every file is
/// therefore staged next to its destination and renamed into place, and any file
/// it displaces is first moved aside to a backup. That yields a transaction with
/// real rollback semantics:
///
///   1. **Check** — all file-ownership conflicts across the whole plan, before
///      touching anything.
///   2. **Apply** — stage, back up, rename, chmod; record every effect in a
///      journal.
///   3. **Commit** — write the installed database *last*, atomically, then drop
///      the backups.
///   4. **Roll back** — on any failure, replay the journal in reverse: restore
///      backups, delete files we created, prune directories we created. The
///      database is never touched, so a failed transaction is invisible.
///
/// This is why `install` verifies digests and resolves the plan *before* it opens
/// a single destination file: by the time step 2 starts, the only remaining
/// failure mode is I/O.

import Swiftix

struct PackageTransaction {

    /// A package plus the verified archive that will be unpacked for it.
    struct Unit {
        let item: PackagePlanItem
        let archive: PackageArchive

        var name: String { item.name }
    }

    /// Effects to undo if the transaction fails, in the order they happened.
    private struct Journal {
        var createdDirectories: [String] = []
        var placedFiles: [String] = []
        var backups: [(target: String, backup: String)] = []
        var staged: [String] = []
    }

    // MARK: - Install

    /// Unpack every unit and return the updated database. Either all units are
    /// installed and the database reflects them, or nothing changed.
    static func install(
        _ context: ProcessContext,
        units: [Unit],
        database: InstalledDatabase,
        layout: PackageLayout,
        forceOverwrite: Bool,
        onProgress: (String) -> Void = { _ in }
    ) throws -> InstalledDatabase {
        try checkFileConflicts(
            context,
            units: units,
            database: database,
            forceOverwrite: forceOverwrite)

        var journal = Journal()
        var updated = database
        var installedRecords: [InstalledPackage] = []

        do {
            for unit in units {
                onProgress(unit.name)
                let record = try apply(context, unit: unit, journal: &journal)
                installedRecords.append(record)
            }

            // Obsolete content: files the previous version owned that the new one
            // no longer ships. Done after every unit is in place, so a failure
            // during unpacking never deletes the old installation.
            for unit in units {
                guard let previous = unit.item.replacing else { continue }
                let retained = Set(unit.archive.files.map(\.path))
                for path in previous.files where !retained.contains(path) {
                    PackageStore.removeIfPresent(context, path)
                }
            }

            for record in installedRecords { updated.insert(record) }
            try writeDatabase(context, updated, layout: layout)
        } catch {
            rollback(context, journal: journal)
            throw error
        }

        // Committed: the staged backups are no longer needed.
        for backup in journal.backups { PackageStore.removeIfPresent(context, backup.backup) }
        return updated
    }

    /// Place one package's directories and files, recording each effect.
    private static func apply(
        _ context: ProcessContext,
        unit: Unit,
        journal: inout Journal
    ) throws -> InstalledPackage {
        var createdByThisPackage: [String] = []

        for directory in unit.archive.directories {
            let created = try PackageStore.makeDirectories(context, directory.path)
            createdByThisPackage += created
            journal.createdDirectories += created
        }

        var installedFiles: [String] = []
        for entry in unit.archive.files {
            let parent = PackagePath.parent(of: entry.path)
            let created = try PackageStore.makeDirectories(context, parent)
            createdByThisPackage += created
            journal.createdDirectories += created

            let staged = try PackageStore.temporaryPath(
                context, in: parent, prefix: PackagePath.lastComponent(of: entry.path))
            journal.staged.append(staged)
            try PackageStore.write(context, staged, bytes: unit.archive.contents(of: entry))

            if PackageStore.exists(context, entry.path) {
                let backup = try PackageStore.temporaryPath(
                    context, in: parent, prefix: "bak-" + PackagePath.lastComponent(of: entry.path))
                try PackageStore.move(context, from: entry.path, to: backup)
                journal.backups.append((target: entry.path, backup: backup))
            }

            try PackageStore.move(context, from: staged, to: entry.path)
            journal.placedFiles.append(entry.path)
            _ = context.chmod(entry.path, mode: PackageStore.fileMode(entry.mode))
            installedFiles.append(entry.path)
        }

        // Preserve directories the previous version created and still needs, so an
        // upgrade does not lose the record of what it owns.
        var ownedDirectories = createdByThisPackage
        if let previous = unit.item.replacing {
            for directory in previous.directories where !ownedDirectories.contains(directory) {
                if PackageStore.isDirectory(context, directory) { ownedDirectories.append(directory) }
            }
        }

        return InstalledPackage(
            manifest: unit.archive.manifest,
            repository: unit.item.candidate.repository,
            files: installedFiles,
            directories: ownedDirectories,
            installedSize: unit.archive.installedSize,
            automatic: unit.item.automatic)
    }

    /// Undo everything the journal recorded, newest effect first.
    private static func rollback(_ context: ProcessContext, journal: Journal) {
        for path in journal.placedFiles.reversed() {
            PackageStore.removeIfPresent(context, path)
        }
        for backup in journal.backups.reversed() {
            // Restore the displaced original; if that fails there is nothing
            // further to try, and the backup file stays behind for inspection.
            try? PackageStore.move(context, from: backup.backup, to: backup.target)
        }
        for path in journal.staged.reversed() {
            PackageStore.removeIfPresent(context, path)
        }
        for directory in journal.createdDirectories.reversed() {
            if PackageStore.isEmptyDirectory(context, directory) {
                PackageStore.removeIfPresent(context, directory)
            }
        }
    }

    /// Refuse a plan that would have two packages own the same path, or would
    /// silently replace a file no package owns.
    private static func checkFileConflicts(
        _ context: ProcessContext,
        units: [Unit],
        database: InstalledDatabase,
        forceOverwrite: Bool
    ) throws {
        let replaced = Set(units.compactMap { $0.item.replacing?.name })
        var claimed: [String: String] = [:]  // path → package claiming it

        for unit in units {
            let previouslyOwned = Set(unit.item.replacing?.files ?? [])
            for entry in unit.archive.files {
                if let other = claimed[entry.path] {
                    throw PackageError.fileConflict(
                        path: entry.path,
                        package: unit.name,
                        owner: other)
                }
                claimed[entry.path] = unit.name

                if let owner = database.owner(ofFile: entry.path),
                    owner != unit.name, !replaced.contains(owner)
                {
                    throw PackageError.fileConflict(
                        path: entry.path,
                        package: unit.name,
                        owner: owner)
                }
                if database.owner(ofFile: entry.path) == nil,
                    !previouslyOwned.contains(entry.path),
                    PackageStore.exists(context, entry.path),
                    !forceOverwrite
                {
                    throw PackageError.unownedFileInTheWay(path: entry.path, package: unit.name)
                }
            }
        }
    }

    // MARK: - Remove

    /// Remove packages in the given order, pruning only the directories the
    /// installation itself created and only while they are empty.
    static func remove(
        _ context: ProcessContext,
        packages: [InstalledPackage],
        database: InstalledDatabase,
        layout: PackageLayout,
        onProgress: (String) -> Void = { _ in }
    ) throws -> InstalledDatabase {
        var updated = database
        for package in packages {
            onProgress(package.name)
            for path in package.files {
                // Ownership may have moved to another package (an explicit
                // takeover); never delete a file someone else now owns.
                if let owner = updated.owner(ofFile: path), owner != package.name { continue }
                PackageStore.removeIfPresent(context, path)
            }
            updated.remove(package.name)

            let deepestFirst = package.directories.sorted {
                $0.split(separator: "/").count > $1.split(separator: "/").count
            }
            for directory in deepestFirst {
                let claimedByOther = updated.sorted.contains { $0.directories.contains(directory) }
                guard !claimedByOther, PackageStore.isEmptyDirectory(context, directory) else { continue }
                PackageStore.removeIfPresent(context, directory)
            }
        }
        try writeDatabase(context, updated, layout: layout)
        return updated
    }

    // MARK: - Database

    static func writeDatabase(
        _ context: ProcessContext,
        _ database: InstalledDatabase,
        layout: PackageLayout
    ) throws {
        try PackageStore.writeAtomically(
            context,
            layout.statusFile,
            bytes: Array(database.rendered().utf8),
            mode: 0o644)
    }
}
