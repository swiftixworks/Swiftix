import Foundation
import Testing
@testable import Swiftix

/// Filesystem persistence: `Kernel.snapshotFileSystem()` captures the tmpfs tree
/// (files, directories, symlinks) as a serializable `FilesystemSnapshot`, and
/// `restoreFileSystem(_:)` rebuilds it on a fresh kernel. Synthetic `/proc`
/// files are excluded from the snapshot and re-mounted on restore.
@Suite("Filesystem snapshot + restore")
struct FilesystemSnapshotTests {

    /// A snapshot taken on one kernel, restored on a brand-new kernel, makes the
    /// captured files and directories readable there.
    @Test func restoresFilesAndDirectoriesOntoFreshKernel() {
        let loop = EventLoop()
        let source = Kernel(loop: loop)
        source.spawn("seed") { ctx in
            _ = ctx.mkdir("/data")
            let fd = ctx.open("/data/notes.txt", create: true)!
            ctx.write(fd, Array("persisted body\n".utf8))
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        let snapshot = source.snapshotFileSystem()

        // A fresh kernel starts empty; after restore the file is present.
        let restored = Kernel(loop: loop)
        restored.restoreFileSystem(snapshot)

        final class Box { var body = ""; var isDir = false }
        let box = Box()
        restored.spawn("reader") { ctx in
            box.isDir = ctx.stat("/data")?.isDirectory == true
            if let fd = ctx.open("/data/notes.txt") {
                box.body = String(decoding: ctx.read(fd, max: 4096), as: UTF8.self)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.isDir)
        #expect(box.body == "persisted body\n")
    }

    /// Symbolic links survive a snapshot/restore round-trip and still resolve.
    @Test func restoresSymlinks() {
        let loop = EventLoop()
        let source = Kernel(loop: loop)
        source.spawn("seed") { ctx in
            let fd = ctx.open("/target.txt", create: true)!
            ctx.write(fd, Array("via link\n".utf8))
            ctx.close(fd)
            _ = ctx.symlink("/target.txt", at: "/link.txt")
            ctx.exit(0)
        }
        loop.runUntilIdle()

        let snapshot = source.snapshotFileSystem()
        let restored = Kernel(loop: loop)
        restored.restoreFileSystem(snapshot)

        final class Box { var body = ""; var target: String? }
        let box = Box()
        restored.spawn("reader") { ctx in
            box.target = ctx.readlink("/link.txt")
            if let fd = ctx.open("/link.txt") {   // follows the link
                box.body = String(decoding: ctx.read(fd, max: 4096), as: UTF8.self)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.target == "/target.txt")
        #expect(box.body == "via link\n")
    }

    /// Synthetic `/proc` files are excluded from the snapshot but still work
    /// after restore (the kernel re-mounts them).
    @Test func procIsExcludedButWorksAfterRestore() {
        let loop = EventLoop()
        let source = Kernel(loop: loop)
        source.spawn("seed") { ctx in
            let fd = ctx.open("/keep.txt", create: true)!
            ctx.write(fd, Array("x".utf8))
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        let snapshot = source.snapshotFileSystem()

        // The snapshot may capture the /proc (and /proc/net) directory nodes,
        // but never the synthetic *files* — those are filtered out.
        if case let .directory(children) = snapshot.root,
           case let .directory(proc)? = children["proc"] {
            #expect(proc["processes"] == nil)               // synthetic file excluded
            if case let .directory(net)? = proc["net"] {
                #expect(net["tcp"] == nil)                  // synthetic file excluded
                #expect(net["dev"] == nil)
            }
        }

        let restored = Kernel(loop: loop)
        restored.restoreFileSystem(snapshot)

        final class Box { var proc = ""; var keep = "" }
        let box = Box()
        restored.spawn("reader") { ctx in
            if let fd = ctx.open("/proc/processes") {   // re-mounted, computed live
                box.proc = String(decoding: ctx.read(fd, max: 4096), as: UTF8.self)
                ctx.close(fd)
            }
            if let fd = ctx.open("/keep.txt") {
                box.keep = String(decoding: ctx.read(fd, max: 4096), as: UTF8.self)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.proc.contains("PID"))   // procfs works again after restore
        #expect(box.keep == "x")            // real file restored
    }

    /// The snapshot is a value type with structural equality — a stable basis
    /// for the consumer's Codable persistence.
    @Test func snapshotIsValueEquatable() {
        let loop = EventLoop()
        let a = Kernel(loop: loop)
        // Mountpoint metadata starts at zero. Capturing at a later logical time
        // verifies re-mounting synthetic files does not perturb persisted times.
        loop.advance(by: 7)
        a.spawn("seed") { ctx in
            let fd = ctx.open("/f", create: true)!; ctx.write(fd, Array("hi".utf8)); ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()
        let snapshot = a.snapshotFileSystem()

        let b = Kernel(loop: loop)
        #expect(b.restoreFileSystem(snapshot))
        // Re-snapshotting the restored kernel yields an equal canonical inode
        // image, including mountpoint metadata and deterministic inode IDs.
        #expect(b.snapshotFileSystem() == snapshot)
    }

    /// Format v2 retains every persisted metadata field and represents two hard
    /// links with one inode. Mutating either restored path changes the other.
    @Test func preservesMetadataHardLinksSymlinksAndFifos() throws {
        let loop = EventLoop()
        let source = Kernel(loop: loop)
        let directory = try #require(source.vfs.createDirectory("/data"))
        let file = try #require(source.vfs.createFile("/data/original"))
        file.setFileContents([1, 2, 3])
        #expect(source.vfs.link("/data/original", at: "/data/alias"))
        let symlink = try #require(source.vfs.createSymlink("/data/link", target: "original"))
        let fifo = try #require(source.vfs.createFifo("/data/pipe"))

        setMetadata(source.vfs.root, mode: 0o751, uid: 1, gid: 2, base: 10)
        setMetadata(directory, mode: 0o750, uid: 3, gid: 4, base: 20)
        setMetadata(file, mode: 0o640, uid: 5, gid: 6, base: 30)
        setMetadata(symlink, mode: 0o777, uid: 7, gid: 8, base: 40)
        setMetadata(fifo, mode: 0o620, uid: 9, gid: 10, base: 50)

        let snapshot = source.snapshotFileSystem()
        #expect(snapshot.formatVersion == FilesystemSnapshot.currentFormatVersion)
        #expect(snapshot.isValid)

        let restored = Kernel(loop: loop)
        let originalRoot = restored.vfs.root
        #expect(restored.restoreFileSystem(snapshot))
        #expect(restored.vfs.root === originalRoot, "restore must preserve root identity")

        let restoredDirectory = try #require(restored.vfs.lookup("/data"))
        let restoredFile = try #require(restored.vfs.lookup("/data/original"))
        let restoredAlias = try #require(restored.vfs.lookup("/data/alias"))
        let restoredSymlink = try #require(restored.vfs.lookup("/data/link", follow: false))
        let restoredFifo = try #require(restored.vfs.lookup("/data/pipe"))

        #expect(restoredFile === restoredAlias)
        #expect(restoredFile.nlink == 2)
        assertMetadata(restored.vfs.root, mode: 0o751, uid: 1, gid: 2, base: 10)
        assertMetadata(restoredDirectory, mode: 0o750, uid: 3, gid: 4, base: 20)
        assertMetadata(restoredFile, mode: 0o640, uid: 5, gid: 6, base: 30)
        assertMetadata(restoredSymlink, mode: 0o777, uid: 7, gid: 8, base: 40)
        assertMetadata(restoredFifo, mode: 0o620, uid: 9, gid: 10, base: 50)

        #expect(restoredFile.writeFileContents([9], at: 0) == 1)
        #expect(restoredAlias.fileContents == [9, 2, 3])
        #expect(restored.snapshotFileSystem().isValid)
    }

    /// A root-only payload encoded with the old shape still decodes and restores
    /// through the legacy path, without requiring an archive schema migration.
    @Test func decodesLegacyRootOnlyJSON() throws {
        struct LegacySnapshot: Codable {
            var root: FilesystemSnapshot.Node
        }

        let legacy = LegacySnapshot(root: .directory(children: [
            "old.txt": .file(bytes: Array("legacy".utf8)),
            "link": .symlink(target: "/old.txt"),
        ]))
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(FilesystemSnapshot.self, from: data)

        #expect(decoded.formatVersion == nil)
        #expect(decoded.rootInodeID == nil)
        #expect(decoded.inodes == nil)
        #expect(decoded.isValid)

        let kernel = Kernel(loop: EventLoop())
        #expect(kernel.restoreFileSystem(decoded))
        #expect(kernel.vfs.lookup("/old.txt")?.fileContents == Array("legacy".utf8))
        #expect(kernel.vfs.lookup("/link", follow: false)?.linkTarget == "/old.txt")
    }

    /// Every validation failure is non-destructive: missing references,
    /// non-finite metadata, cycles, divergent dual representations, and a legacy
    /// non-directory root all leave the prior bytes and metadata untouched.
    @Test func rejectsMalformedSnapshotsWithoutChangingExistingTree() throws {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let keep = try #require(kernel.vfs.createFile("/keep"))
        keep.setFileContents([4, 2])
        setMetadata(keep, mode: 0o600, uid: 12, gid: 13, base: 60)
        let before = kernel.snapshotFileSystem()

        let rootMetadata = FilesystemSnapshot.Metadata(
            mode: FileMode.directoryDefault.rawValue,
            uid: 0,
            gid: 0,
            atime: 0,
            mtime: 0,
            ctime: 0)
        let fileMetadata = FilesystemSnapshot.Metadata(
            mode: FileMode.regularDefault.rawValue,
            uid: 0,
            gid: 0,
            atime: 0,
            mtime: 0,
            ctime: 0)

        let missingInode = FilesystemSnapshot(
            root: .directory(children: ["missing": .file(bytes: [1])]),
            formatVersion: 2,
            rootInodeID: 1,
            inodes: [
                .init(id: 1,
                      metadata: rootMetadata,
                      contents: .directory(entries: [.init(name: "missing", inodeID: 2)])),
            ])
        var nonFiniteMetadata = rootMetadata
        nonFiniteMetadata.mtime = .infinity
        let nonFinite = FilesystemSnapshot(
            root: .directory(children: [:]),
            formatVersion: 2,
            rootInodeID: 1,
            inodes: [.init(id: 1, metadata: nonFiniteMetadata, contents: .directory(entries: []))])
        let cycle = FilesystemSnapshot(
            root: .directory(children: ["child": .directory(children: [:])]),
            formatVersion: 2,
            rootInodeID: 1,
            inodes: [
                .init(id: 1,
                      metadata: rootMetadata,
                      contents: .directory(entries: [.init(name: "child", inodeID: 2)])),
                .init(id: 2,
                      metadata: rootMetadata,
                      contents: .directory(entries: [.init(name: "back", inodeID: 1)])),
            ])
        let divergentProjection = FilesystemSnapshot(
            root: .directory(children: ["value": .file(bytes: [1])]),
            formatVersion: 2,
            rootInodeID: 1,
            inodes: [
                .init(id: 1,
                      metadata: rootMetadata,
                      contents: .directory(entries: [.init(name: "value", inodeID: 2)])),
                .init(id: 2, metadata: fileMetadata, contents: .file(bytes: [2])),
            ])
        let nonDirectoryLegacy = FilesystemSnapshot(root: .file(bytes: [9]))

        for malformed in [missingInode, nonFinite, cycle, divergentProjection, nonDirectoryLegacy] {
            #expect(!malformed.isValid)
            #expect(!kernel.restoreFileSystem(malformed))
            #expect(kernel.snapshotFileSystem() == before)
        }
    }

    private func setMetadata(_ node: VNode,
                             mode: UInt16,
                             uid: UInt32,
                             gid: UInt32,
                             base: Double) {
        node.mode = FileMode(rawValue: mode)
        node.uid = uid
        node.gid = gid
        node.atime = base + 1
        node.mtime = base + 2
        node.ctime = base + 3
    }

    private func assertMetadata(_ node: VNode,
                                mode: UInt16,
                                uid: UInt32,
                                gid: UInt32,
                                base: Double) {
        #expect(node.mode.rawValue == mode)
        #expect(node.uid == uid)
        #expect(node.gid == gid)
        #expect(node.atime == base + 1)
        #expect(node.mtime == base + 2)
        #expect(node.ctime == base + 3)
    }
}
