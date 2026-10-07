/// Creation and directory-entry timestamps: every way of making a node stamps
/// it through the kernel wall clock, and a directory's mtime/ctime follow the
/// entries added to, removed from, or renamed in it. The clock is always
/// injected; nothing here reads host time.
import Testing
@testable import Swiftix

@Suite("Node creation and directory entry timestamps")
struct NodeCreationTimestampTests {

    /// 2026-10-07T12:34:56Z.
    static let epoch: Double = 1_791_376_496

    /// A shell on a kernel whose wall clock was injected at logical zero.
    private static func harness() -> CommandHarness {
        let h = CommandHarness()
        h.kernel.setWallClock(epochSeconds: epoch)
        return h
    }

    private static func lstat(_ h: CommandHarness, _ path: String) -> FileStat? {
        final class Box { var stat: FileStat? }
        let box = Box()
        h.inProcess { ctx in box.stat = ctx.lstat(path) }
        return box.stat
    }

    private static func expectAllTimes(_ stat: FileStat?, _ expected: Double,
                                       _ comment: Comment,
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(stat != nil, comment, sourceLocation: sourceLocation)
        #expect(stat?.atime == expected, comment, sourceLocation: sourceLocation)
        #expect(stat?.mtime == expected, comment, sourceLocation: sourceLocation)
        #expect(stat?.ctime == expected, comment, sourceLocation: sourceLocation)
    }

    // MARK: - Creation

    /// The reported bug: `mkdir` left the directory at the epoch while `touch`
    /// stamped the file.
    @Test func mkdirStampsTheDirectoryLikeANewFile() {
        let h = Self.harness()
        h.run("mkdir /tmp")
        h.advance(by: 60)
        h.run("mkdir /tmp/d; touch /tmp/f")
        let now = Self.epoch + 60
        Self.expectAllTimes(Self.lstat(h, "/tmp/d"), now, "mkdir")
        Self.expectAllTimes(Self.lstat(h, "/tmp/f"), now, "touch")

        let listing = h.stdout("ls -ld /tmp/d /tmp/f")
        #expect(!listing.contains("1970"))
        #expect(listing.split(separator: "\n").allSatisfy { $0.contains("Oct  7 12:35") })
    }

    @Test func everyCreatingCommandStampsItsNode() {
        let h = Self.harness()
        h.advance(by: 10)
        h.run("mkdir /w")
        h.advance(by: 10)
        h.run("cd /w; mkdir -p a/b/c; mkfifo pipe; ln -s a link; echo hi > file; cp file copy")
        let now = Self.epoch + 20
        for path in ["/w/a", "/w/a/b", "/w/a/b/c", "/w/pipe", "/w/link", "/w/file", "/w/copy"] {
            Self.expectAllTimes(Self.lstat(h, path), now, "\(path)")
        }
    }

    @Test func syscallCreationPathsStampTheirNodes() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.setWallClock(epochSeconds: Self.epoch)
        loop.advance(by: 30)
        final class Box { var stats: [String: FileStat] = [:] }
        let box = Box()
        kernel.spawn("p") { ctx in
            let scope = FileSystemScope(rootPath: "/")
            #expect(ctx.mkdir("/plain/deep"))
            #expect((try? ctx.mkdir("scoped", in: scope)) != nil)
            #expect(ctx.mkfifo("/fifo"))
            #expect(ctx.symlink("/plain", at: "/links/one"))
            if let fd = try? ctx.openFile("made", in: scope, flags: [.create], access: .writeOnly) {
                ctx.close(fd)
            }
            for path in ["/plain", "/plain/deep", "/scoped", "/fifo", "/links", "/links/one", "/made"] {
                box.stats[path] = ctx.lstat(path)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()
        #expect(box.stats.count == 7)
        for (path, stat) in box.stats {
            Self.expectAllTimes(stat, Self.epoch + 30, "\(path)")
        }
    }

    /// `symlink` used to restamp every existing directory on the way to the
    /// link, as though each had just been created.
    @Test func symlinkLeavesExistingAncestorsAlone() {
        let h = Self.harness()
        h.run("mkdir -p /s/inner")
        h.advance(by: 100)
        h.run("ln -s target /s/inner/link")
        Self.expectAllTimes(Self.lstat(h, "/s"), Self.epoch, "/s")
        let inner = Self.lstat(h, "/s/inner")
        #expect(inner?.atime == Self.epoch)
        #expect(inner?.mtime == Self.epoch + 100)
        #expect(inner?.ctime == Self.epoch + 100)
    }

    @Test func hardLinkChangesOnlyCtimeOfTheInode() {
        let h = Self.harness()
        h.run("echo data > /orig")
        h.advance(by: 40)
        h.run("ln /orig /alias")
        let stat = Self.lstat(h, "/alias")
        #expect(stat?.nlink == 2)
        #expect(stat?.mtime == Self.epoch)
        #expect(stat?.atime == Self.epoch)
        #expect(stat?.ctime == Self.epoch + 40)

        // Removing one name is a status change too, and gives the link back.
        h.advance(by: 5)
        h.run("rm /alias")
        let remaining = Self.lstat(h, "/orig")
        #expect(remaining?.nlink == 1)
        #expect(remaining?.mtime == Self.epoch)
        #expect(remaining?.ctime == Self.epoch + 45)
    }

    @Test func tmpfsMountRootIsStamped() {
        let h = Self.harness()
        h.run("mkdir /mnt")
        h.advance(by: 15)
        h.run("mount -t tmpfs tmpfs /mnt")
        Self.expectAllTimes(Self.lstat(h, "/mnt"), Self.epoch + 15, "tmpfs root")
    }

    // MARK: - Directory entries

    @Test func directoryTimesFollowItsEntries() {
        let h = Self.harness()
        h.run("mkdir /d")
        func times() -> (mtime: Double, ctime: Double, atime: Double) {
            let stat = Self.lstat(h, "/d")
            return (stat?.mtime ?? -1, stat?.ctime ?? -1, stat?.atime ?? -1)
        }
        var expected = Self.epoch
        let steps = [
            "touch /d/a",             // entry added (file)
            "mkdir /d/sub",           // entry added (directory)
            "mv /d/a /d/b",           // entry renamed in place
            "ln /d/b /d/hard",        // entry added (hard link)
            "ln -s b /d/soft",        // entry added (symlink)
            "mkfifo /d/pipe",         // entry added (fifo)
            "rm /d/hard",             // entry removed (file)
            "rmdir /d/sub",           // entry removed (directory)
        ]
        for step in steps {
            h.advance(by: 7)
            expected += 7
            h.run(step)
            let now = times()
            #expect(now.mtime == expected, "mtime after \(step)")
            #expect(now.ctime == expected, "ctime after \(step)")
            #expect(now.atime == Self.epoch, "atime after \(step)")
        }

        // Changing a file's contents is not a change to the directory.
        h.advance(by: 7)
        h.run("echo more >> /d/b")
        #expect(times().mtime == expected)
    }

    @Test func renameAcrossDirectoriesStampsBothAndOnlyCtimeOfTheNode() {
        let h = Self.harness()
        h.run("mkdir /from /to; echo x > /from/f; echo old > /to/g")
        h.advance(by: 50)
        h.run("mv /from/f /to/g")
        let now = Self.epoch + 50
        for directory in ["/from", "/to"] {
            let stat = Self.lstat(h, directory)
            #expect(stat?.mtime == now, "\(directory)")
            #expect(stat?.ctime == now, "\(directory)")
        }
        let moved = Self.lstat(h, "/to/g")
        #expect(moved?.mtime == Self.epoch)
        #expect(moved?.ctime == now)
        #expect(h.contents(of: "/to/g") == "x\n")
    }

    // MARK: - Kernel-provided and restored nodes

    @Test func kernelProvidedNodesAreDatedAtBootOnTheInjectedClock() {
        let h = Self.harness()
        h.advance(by: 500)
        for path in ["/dev/null", "/dev/urandom", "/dev/stdin", "/proc/uptime", "/proc/meminfo"] {
            Self.expectAllTimes(Self.lstat(h, path), Self.epoch, "\(path)")
        }
        // Computed nodes are built on lookup, so they read as "now".
        Self.expectAllTimes(Self.lstat(h, "/proc/1"), Self.epoch + 500, "/proc/1")
        Self.expectAllTimes(Self.lstat(h, "/proc/1/status"), Self.epoch + 500, "/proc/1/status")
    }

    /// Restoring a snapshot keeps every persisted time exactly as stored, even
    /// though the restoring kernel runs on a different clock and mounts its
    /// own `/proc` and `/dev` over the restored tree.
    @Test func restoreAndClockInjectionDoNotRestampPersistedNodes() {
        let source = Self.harness()
        source.advance(by: 20)
        source.run("mkdir -p /keep/dir; echo x > /keep/file; ln -s file /keep/link; mkfifo /keep/pipe")
        let paths = ["/", "/keep", "/keep/dir", "/keep/file", "/keep/link", "/keep/pipe",
                     "/dev", "/proc", "/tmp"]
        var before: [String: FileStat] = [:]
        for path in paths { before[path] = Self.lstat(source, path) }
        let snapshot = source.kernel.snapshotFileSystem()

        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        loop.advance(by: 1_000)
        #expect(kernel.restoreFileSystem(snapshot))
        kernel.setWallClock(epochSeconds: Self.epoch + 86_400)
        final class Box { var stats: [String: FileStat] = [:] }
        let box = Box()
        kernel.spawn("p") { ctx in
            for path in paths { box.stats[path] = ctx.lstat(path) }
            ctx.exit(0)
        }
        loop.runUntilIdle()
        for path in paths {
            #expect(box.stats[path]?.atime == before[path]?.atime, "\(path) atime")
            #expect(box.stats[path]?.mtime == before[path]?.mtime, "\(path) mtime")
            #expect(box.stats[path]?.ctime == before[path]?.ctime, "\(path) ctime")
        }
        #expect(kernel.snapshotFileSystem() == snapshot)
    }
}
