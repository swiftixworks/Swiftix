import Testing
@testable import Swiftix

/// Directory trees nested thousands of levels deep, which a guest can build
/// with `mkdir -p`. Releasing, counting, snapshotting, and walking such a tree
/// must use explicit worklists: one host stack frame group per directory level
/// overflows a 512 KiB secondary-thread stack (the one these tests run on)
/// somewhere between 1,200 and 2,000 levels.
@Suite("Deep directory trees")
struct DeepDirectoryTreeTests {

    /// Depth for the VFS-level tests, well past the old overflow point.
    private static let depth = 5_000
    /// Depth for the tests that drive guest commands. Every path-level syscall
    /// re-resolves its path, so a walk is quadratic in depth; this keeps the
    /// debug-build run time reasonable while staying past the overflow point.
    private static let commandDepth = 2_200

    /// `/deep/d/d/…`: a chain of `depth` nested directories.
    private static func chain(_ depth: Int) -> String {
        "/deep" + String(repeating: "/d", count: depth - 1)
    }

    private static func harness() -> CommandHarness {
        let h = CommandHarness()
        h.kernel.vfs.makeDirectories(chain(commandDepth))
        h.kernel.vfs.createFile(chain(commandDepth) + "/leaf")?.setFileContents(Array("needle\n".utf8))
        return h
    }

    // MARK: - VFS

    @Test func countsAndReleasesADeepTree() {
        let vfs = VirtualFileSystem()
        vfs.makeDirectories(Self.chain(Self.depth))
        vfs.createFile(Self.chain(Self.depth) + "/leaf")?.setFileContents([1, 2, 3])

        #expect(vfs.nodeCount == Self.depth + 2)          // root + chain + leaf
        #expect(vfs.totalFileBytes == 3)
        // The tree is released when `vfs` goes out of scope here.
    }

    /// Teardown drains only what the dying node is the last owner of: a
    /// directory something else still references keeps its whole subtree, and a
    /// hard-linked file survives the removal of one of its names.
    @Test func releaseLeavesSharedNodesIntact() throws {
        let half = Self.depth / 2
        var retained: VNode?
        var linked: VNode?
        do {
            let vfs = VirtualFileSystem()
            vfs.makeDirectories(Self.chain(Self.depth))
            let leaf = Self.chain(Self.depth) + "/leaf"
            vfs.createFile(leaf)?.setFileContents([7])
            #expect(vfs.link(leaf, at: "/alias"))
            retained = vfs.lookup(Self.chain(half))
            linked = vfs.lookup("/alias")
        }

        var node = try #require(retained)
        var levels = 0
        while let next = node.child("d") {
            node = next
            levels += 1
        }
        #expect(levels == Self.depth - half)
        #expect(node.child("leaf") === linked)
        #expect(linked?.fileContents == [7])

        retained = nil                                    // releases the kept half
        #expect(linked?.fileContents == [7])
    }

    @Test func renameIntoOwnDeepSubtreeIsRejected() throws {
        let vfs = VirtualFileSystem()
        vfs.makeDirectories(Self.chain(Self.depth))
        let bottom = String(Self.chain(Self.depth).dropFirst())

        #expect(throws: VirtualFileSystem.RenameError.self) {
            try vfs.rename("deep", beneath: vfs.root, to: bottom + "/moved", beneath: vfs.root)
        }
        try vfs.rename("deep", beneath: vfs.root, to: "moved", beneath: vfs.root)
        #expect(vfs.lookup("/moved" + Self.chain(Self.depth).dropFirst(5)) != nil)
    }

    // MARK: - Snapshot

    @Test func snapshotRoundTripsADeepTree() {
        let source = Kernel(loop: EventLoop())
        source.vfs.makeDirectories(Self.chain(Self.depth))
        source.vfs.createFile(Self.chain(Self.depth) + "/leaf")?.setFileContents([9])

        let snapshot = source.snapshotFileSystem()
        #expect(snapshot.isValid)

        let restored = Kernel(loop: EventLoop())
        #expect(restored.restoreFileSystem(snapshot))
        #expect(restored.vfs.lookup(Self.chain(Self.depth) + "/leaf")?.fileContents == [9])
        #expect(restored.vfs.nodeCount == source.vfs.nodeCount)
        #expect(restored.snapshotFileSystem() == snapshot)
    }

    /// The legacy `root` projection is a recursive value, so a capture stops it
    /// at `legacyProjectionDepthLimit`; the inode table still holds every level.
    @Test func legacyProjectionOfADeepTreeIsBounded() {
        let kernel = Kernel(loop: EventLoop())
        kernel.vfs.makeDirectories(Self.chain(Self.depth))
        let snapshot = kernel.snapshotFileSystem()

        var level = 0
        var node = snapshot.root
        while case let .directory(children) = node, let next = children[level == 0 ? "deep" : "d"] {
            node = next
            level += 1
        }
        #expect(level == FilesystemSnapshot.legacyProjectionDepthLimit)
        #expect(node == .directory(children: [:]))

        let directories = (snapshot.inodes ?? []).filter {
            if case .directory = $0.contents { return true }
            return false
        }
        #expect(directories.count >= Self.depth + 1)
    }

    /// Releases that did not bound the projection wrote every level into
    /// `root`; such an image is still accepted, and a projection that disagrees
    /// with the inode table below the bound is still rejected.
    @Test func fullLegacyProjectionBelowTheBoundStillValidates() {
        let levels = FilesystemSnapshot.legacyProjectionDepthLimit + 40
        let kernel = Kernel(loop: EventLoop())
        kernel.vfs.makeDirectories(Self.chain(levels))
        let snapshot = kernel.snapshotFileSystem()

        func withChain(bottom: FilesystemSnapshot.Node) -> FilesystemSnapshot {
            var node = bottom
            for _ in 1..<levels { node = .directory(children: ["d": node]) }
            guard case var .directory(children) = snapshot.root else { return snapshot }
            children["deep"] = node
            var copy = snapshot
            copy.root = .directory(children: children)
            return copy
        }

        let full = withChain(bottom: .directory(children: [:]))
        #expect(full != snapshot)
        #expect(full.isValid)
        #expect(Kernel(loop: EventLoop()).restoreFileSystem(full))

        #expect(!withChain(bottom: .file(bytes: [])).isValid)
        #expect(!withChain(bottom: .directory(children: ["extra": .fifo])).isValid)
    }

    // MARK: - Guest commands

    @Test func recursiveRemoveDeletesADeepTree() {
        let h = Self.harness()
        let before = h.kernel.vfs.nodeCount

        h.run("rm -r /deep")
        #expect(h.kernel.vfs.lookup("/deep") == nil)
        #expect(h.kernel.vfs.nodeCount == before - Self.commandDepth - 1)   // chain + leaf
    }

    /// The other whole-tree walkers that used host recursion per level.
    @Test(arguments: [
        ("du -s /deep", "1\t/deep\n"),
        ("tree /deep | tail -n 1", "\(commandDepth - 1) directories, 1 file\n"),
        ("grep -rc needle /deep | cut -d: -f2", "1\n"),
        ("df / > /dev/null; cat /proc/meminfo > /dev/null; echo ok", "ok\n"),
    ])
    func treeWalkingCommandsSurviveADeepTree(line: String, expected: String) {
        let h = Self.harness()
        #expect(h.stdout(line) == expected)
    }

    @Test func recursiveModeAndOwnerChangesReachTheBottom() throws {
        let h = Self.harness()
        h.run("chmod -R 700 /deep")
        h.run("chown -R 7:7 /deep")

        let leaf = try #require(h.kernel.vfs.lookup(Self.chain(Self.commandDepth) + "/leaf"))
        #expect(leaf.mode.rawValue & 0o7777 == 0o700)
        #expect(leaf.uid == 7)
        #expect(leaf.gid == 7)
    }
}
