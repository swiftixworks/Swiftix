import Testing
@testable import Swiftix

/// Directory search (execute) permission on every component of a path, not
/// only the last one: a non-root process must be able to search each directory
/// it walks through, whichever syscall does the walking.
///
/// Covered: the root bypass, the owner/group/other triad on directories, read
/// versus search, symlink targets, cwd-relative resolution, mount namespaces,
/// the capability-scoped frontend, and the cost of a deep walk.
@Suite("Path search permission")
struct PathSearchPermissionTests {

    // MARK: - Fixtures

    private static let rwx: FileMode = [.ownerRead, .ownerWrite, .ownerExecute]          // 0700
    private static let world: FileMode = .directoryDefault                               // 0755
    private static let searchOnly: FileMode = [.ownerRead, .ownerWrite, .ownerExecute,
                                               .groupExecute, .otherExecute]             // 0711
    private static let readOnly: FileMode = [.ownerRead, .ownerWrite, .ownerExecute,
                                             .groupRead, .otherRead]                     // 0744

    private final class ResultBox<T> { var value: T? }

    private final class System {
        let loop = EventLoop()
        let kernel: Kernel

        init() { kernel = Kernel(loop: loop) }

        /// Run `body` as root and settle.
        func asRoot(_ body: @escaping (ProcessContext) -> Void) {
            kernel.spawn("root") { ctx in
                body(ctx)
                ctx.exit(0)
            }
            loop.runUntilIdle()
        }

        /// Run `body` as uid/gid 1000 (optionally from `cwd`, entered while
        /// still root) and return what it produced.
        func asUser<T>(cwd: String? = nil, groups: [UInt32] = [],
                       _ body: @escaping (ProcessContext) -> T) -> T {
            let box = ResultBox<T>()
            kernel.spawn("user") { ctx in
                if let cwd { ctx.chdir(cwd) }
                ctx.setgroups(groups)
                ctx.setgid(1000)
                ctx.setuid(1000)
                box.value = body(ctx)
                ctx.exit(0)
            }
            loop.runUntilIdle()
            guard let value = box.value else { fatalError("the user process never ran") }
            return value
        }

        func directory(_ path: String, mode: FileMode, uid: UInt32 = 0, gid: UInt32 = 0) {
            asRoot { ctx in
                ctx.mkdir(path)
                _ = ctx.chown(path, uid: uid, gid: gid)
                _ = ctx.chmod(path, mode: mode)
            }
        }

        func file(_ path: String, _ text: String = "data", mode: FileMode = .regularDefault) {
            asRoot { ctx in
                guard let fd = ctx.open(path, create: true, truncate: true) else { return }
                ctx.write(fd, Array(text.utf8))
                ctx.close(fd)
                _ = ctx.chmod(path, mode: mode)
            }
        }
    }

    /// The errno of a throwing open, or `nil` when it succeeded.
    private static func openError(_ ctx: ProcessContext, _ path: String) -> SyscallError? {
        do {
            ctx.close(try ctx.openFile(path))
            return nil
        } catch {
            return error as? SyscallError
        }
    }

    /// `/root` (0700) holding a world-readable file: the reported bug.
    private func lockedRoot() -> System {
        let system = System()
        system.directory("/root", mode: Self.rwx)
        system.file("/root/x", "secret")
        return system
    }

    // MARK: - The reported case

    @Test func worldReadableFileBehindAPrivateDirectoryIsUnreachable() {
        let system = lockedRoot()
        #expect(system.asUser { Self.openError($0, "/root/x") } == .permissionDenied)
        #expect(system.asUser { $0.open("/root/x") == nil } == true)
        #expect(system.asUser { $0.stat("/root/x") == nil } == true)
        // Not "no such file": the refusal is distinguishable from a missing path.
        #expect(system.asUser { Self.openError($0, "/root/missing") } == .permissionDenied)
        #expect(system.asUser { Self.openError($0, "/nowhere/x") } == .noSuchFileOrDirectory)
    }

    @Test func rootBypassesSearchPermission() {
        let system = lockedRoot()
        system.asRoot { ctx in
            _ = ctx.chmod("/root", mode: [])   // 0000: not even the owner bits
        }
        final class Box { var error: SyscallError?; var listed: [String]? }
        let box = Box()
        system.asRoot { ctx in
            box.error = Self.openError(ctx, "/root/x")
            box.listed = ctx.listDirectory("/root")
        }
        #expect(box.error == nil)
        #expect(box.listed == ["x"])
    }

    @Test func shellReportsPermissionDenied() {
        let h = CommandHarness()
        h.run("mkdir /root")
        h.run("chmod 700 /root")
        h.write("/root/x", "secret\n")
        #expect(h.console("cat /root/x").contains("secret"))
        let denied = h.console("su 1000 cat /root/x")
        #expect(denied.contains("cat: /root/x: Permission denied"))
        #expect(!denied.contains("secret"))
        #expect(h.console("su 1000 ls -l /root/x").contains("Permission denied"))
        #expect(h.console("su 1000 stat /root/x").contains("Permission denied"))
        #expect(h.console("su 1000 sh -c 'cd /root'").contains("cd"))
        #expect(h.status("su 1000 sh -c 'cd /root'") != 0)
        #expect(h.console("su 1000 sh -c 'echo hi > /root/new'").contains("Permission denied") ||
                !h.exists("/root/new"))
        #expect(!h.exists("/root/new"))
    }

    // MARK: - Every path syscall

    @Test func everyPathSyscallHonorsAnUnsearchableAncestor() {
        let system = lockedRoot()
        system.asRoot { ctx in
            ctx.mkdir("/root/dir")
            _ = ctx.symlink("x", at: "/root/link")
            _ = ctx.mkfifo("/root/fifo")
            _ = ctx.chmod("/root/x", mode: [.ownerRead, .ownerWrite, .ownerExecute,
                                              .groupRead, .groupExecute, .otherRead, .otherExecute])
        }
        system.directory("/tmp", mode: [.ownerRead, .ownerWrite, .ownerExecute,
                                         .groupRead, .groupWrite, .groupExecute,
                                         .otherRead, .otherWrite, .otherExecute])

        let outcomes = system.asUser { ctx -> [String: Bool] in
            var allowed: [String: Bool] = [:]
            allowed["open"] = ctx.open("/root/x") != nil
            allowed["open-create"] = ctx.open("/root/new", create: true) != nil
            allowed["stat"] = ctx.stat("/root/x") != nil
            allowed["lstat"] = ctx.lstat("/root/link") != nil
            allowed["readlink"] = ctx.readlink("/root/link") != nil
            allowed["listDirectory"] = ctx.listDirectory("/root/dir") != nil
            allowed["chdir"] = ctx.chdir("/root/dir")
            allowed["mkdir"] = ctx.mkdir("/root/dir/sub")
            allowed["remove"] = ctx.remove("/root/x")
            allowed["symlink"] = ctx.symlink("/tmp", at: "/root/s")
            allowed["link-from"] = ctx.link("/root/x", at: "/tmp/stolen")
            allowed["link-into"] = ctx.link("/tmp", at: "/root/l")
            allowed["mkfifo"] = ctx.mkfifo("/root/f")
            allowed["chmod"] = ctx.chmod("/root/x", mode: .regularDefault)
            allowed["utimes"] = ctx.utimes("/root/x", mtime: 1)
            allowed["canExecute"] = ctx.canExecute("/root/x")
            allowed["fifo-open"] = ctx.open("/root/fifo") != nil
            allowed["mount-bind"] = ctx.mountBind(source: "/root/dir", at: "/tmp")
            return allowed
        }

        #expect(outcomes.count == 18)
        for (call, allowed) in outcomes.sorted(by: { $0.key < $1.key }) {
            #expect(!allowed, "\(call) reached through a 0700 directory")
        }
        // Nothing was created, removed, or linked out.
        final class Seen { var names: [String]?; var stolen = true }
        let seen = Seen()
        system.asRoot { ctx in
            seen.names = ctx.listDirectory("/root")
            seen.stolen = ctx.lstat("/tmp/stolen") != nil
        }
        #expect(seen.names == ["dir/", "fifo", "link", "x"])
        #expect(!seen.stolen)
    }

    @Test func refusalComesFromAnyAncestorNotJustTheParent() {
        let system = System()
        system.directory("/a", mode: Self.rwx)
        system.directory("/a/b", mode: Self.world)
        system.directory("/a/b/c", mode: Self.world)
        system.file("/a/b/c/file")
        #expect(system.asUser { Self.openError($0, "/a/b/c/file") } == .permissionDenied)

        system.asRoot { _ = $0.chmod("/a", mode: Self.world) }
        #expect(system.asUser { Self.openError($0, "/a/b/c/file") } == nil)

        system.asRoot { _ = $0.chmod("/a/b/c", mode: Self.rwx) }
        #expect(system.asUser { Self.openError($0, "/a/b/c/file") } == .permissionDenied)
    }

    // MARK: - Which bits

    @Test func ownerGroupAndOtherBitsSelectDirectorySearch() {
        let system = System()
        // 0710 root:staff(50) — group may search, others may not.
        system.directory("/team", mode: [.ownerRead, .ownerWrite, .ownerExecute, .groupExecute], gid: 50)
        system.file("/team/notes")
        #expect(system.asUser { Self.openError($0, "/team/notes") } == .permissionDenied)
        #expect(system.asUser(groups: [50]) { Self.openError($0, "/team/notes") } == nil)

        // 0700 owned by uid 1000 — the owner bits apply, not "other".
        system.directory("/home", mode: Self.world)
        system.directory("/home/u", mode: Self.rwx, uid: 1000, gid: 1000)
        system.file("/home/u/mine")
        #expect(system.asUser { Self.openError($0, "/home/u/mine") } == nil)

        // 0077 owned by uid 1000 — the owner is refused even though others pass.
        system.asRoot { _ = $0.chmod("/home/u", mode: [.groupRead, .groupWrite, .groupExecute,
                                                         .otherRead, .otherWrite, .otherExecute]) }
        #expect(system.asUser { Self.openError($0, "/home/u/mine") } == .permissionDenied)
    }

    @Test func searchWithoutReadTraversesButDoesNotList() {
        let system = System()
        system.directory("/drop", mode: Self.searchOnly)   // 0711
        system.file("/drop/known")
        #expect(system.asUser { Self.openError($0, "/drop/known") } == nil)
        #expect(system.asUser { $0.listDirectory("/drop") == nil } == true)
    }

    @Test func readWithoutSearchListsNamesButReachesNothing() {
        let system = System()
        system.directory("/shown", mode: Self.readOnly)    // 0744
        system.file("/shown/entry")
        #expect(system.asUser { Self.openError($0, "/shown/entry") } == .permissionDenied)
        #expect(system.asUser { $0.stat("/shown/entry") == nil } == true)
        // The directory node itself is reachable (its parent is searchable).
        #expect(system.asUser { $0.stat("/shown")?.isDirectory } == true)
    }

    // MARK: - Symbolic links

    @Test func symlinkCannotTunnelIntoAnUnsearchableDirectory() {
        let system = lockedRoot()
        system.directory("/tmp", mode: Self.world)
        system.asRoot { ctx in
            _ = ctx.symlink("/root/x", at: "/tmp/absolute")
            _ = ctx.symlink("../root/x", at: "/tmp/relative")
            _ = ctx.symlink("/root", at: "/tmp/dir")
        }
        #expect(system.asUser { Self.openError($0, "/tmp/absolute") } == .permissionDenied)
        #expect(system.asUser { Self.openError($0, "/tmp/relative") } == .permissionDenied)
        #expect(system.asUser { Self.openError($0, "/tmp/dir/x") } == .permissionDenied)
        // The links themselves live in a searchable directory.
        #expect(system.asUser { $0.readlink("/tmp/absolute") } == "/root/x")
        #expect(system.asUser { $0.lstat("/tmp/dir")?.type } == .symlink)
    }

    @Test func symlinkStoredInAnUnsearchableDirectoryIsUnreachable() {
        let system = lockedRoot()
        system.directory("/pub", mode: Self.world)
        system.file("/pub/open")
        system.asRoot { _ = $0.symlink("/pub/open", at: "/root/out") }
        #expect(system.asUser { Self.openError($0, "/root/out") } == .permissionDenied)
        #expect(system.asUser { $0.readlink("/root/out") == nil } == true)
    }

    @Test func symlinkThroughSearchableDirectoriesStillWorks() {
        let system = System()
        system.directory("/pub", mode: Self.world)
        system.directory("/pub/deep", mode: Self.searchOnly)
        system.file("/pub/deep/target", "ok")
        system.asRoot { ctx in
            _ = ctx.symlink("deep/target", at: "/pub/short")
            _ = ctx.symlink("/pub/short", at: "/pub/chain")
        }
        #expect(system.asUser { Self.openError($0, "/pub/chain") } == nil)
    }

    @Test func dotDotInALinkTargetNeedsSearchOnTheDirectoryItLeaves() {
        let system = System()
        system.directory("/pub", mode: Self.world)
        system.file("/pub/file")
        system.directory("/pub/closed", mode: Self.rwx)
        // /pub/hop -> closed/../file : resolving ".." means searching /pub/closed.
        system.asRoot { _ = $0.symlink("closed/../file", at: "/pub/hop") }
        #expect(system.asUser { Self.openError($0, "/pub/hop") } == .permissionDenied)
        system.asRoot { _ = $0.chmod("/pub/closed", mode: Self.world) }
        #expect(system.asUser { Self.openError($0, "/pub/hop") } == nil)
    }

    // MARK: - Working directory

    @Test func relativePathsResolveFromTheWorkingDirectory() {
        // A process already inside a tree keeps reaching it by relative path
        // after an ancestor is closed, as on Linux, where a relative walk
        // starts at the cwd inode. The cwd itself and everything below it are
        // still checked.
        let system = lockedRoot()
        system.directory("/root/work", mode: Self.world)
        system.file("/root/work/job")
        system.directory("/root/work/private", mode: Self.rwx)
        system.file("/root/work/private/key")

        #expect(system.asUser(cwd: "/root/work") { Self.openError($0, "job") } == nil)
        #expect(system.asUser(cwd: "/root/work") { Self.openError($0, "./job") } == nil)
        #expect(system.asUser(cwd: "/root/work") { $0.listDirectory(".") } == ["job", "private/"])
        #expect(system.asUser(cwd: "/root/work") { Self.openError($0, "private/key") } == .permissionDenied)
        // Leaving the cwd upward is a fresh walk from the root.
        #expect(system.asUser(cwd: "/root/work") { Self.openError($0, "../x") } == .permissionDenied)
        #expect(system.asUser(cwd: "/root/work") { Self.openError($0, "/root/x") } == .permissionDenied)
        // And once out, the process cannot get back in.
        #expect(system.asUser(cwd: "/root/work") { ctx in ctx.chdir("/") && !ctx.chdir("/root/work") } == true)
    }

    @Test func workingDirectoryItselfMustBeSearchable() {
        // `su` in a 0700 directory: the new uid sits in a cwd it cannot search.
        let system = lockedRoot()
        #expect(system.asUser(cwd: "/root") { Self.openError($0, "x") } == .permissionDenied)
        #expect(system.asUser(cwd: "/root") { $0.listDirectory(".") == nil } == true)
        #expect(system.asUser(cwd: "/root") { $0.stat("x") == nil } == true)
    }

    @Test func chdirNeedsSearchOnEveryComponentAndTheTarget() {
        let system = lockedRoot()
        system.directory("/root/work", mode: Self.world)
        system.directory("/pub", mode: Self.world)
        system.directory("/pub/closed", mode: Self.readOnly)
        #expect(system.asUser { $0.chdir("/root/work") } == false)
        #expect(system.asUser { $0.chdir("/pub/closed") } == false)
        #expect(system.asUser { $0.chdir("/pub") && $0.currentDirectory == "/pub" } == true)
    }

    @Test func childInheritsTheWorkingDirectoryAnchor() {
        let system = lockedRoot()
        system.directory("/root/work", mode: Self.world)
        system.file("/root/work/job")
        final class Box { var relative: SyscallError?; var absolute: SyscallError?; var ran = false }
        let box = Box()
        system.kernel.spawn("parent") { ctx in
            ctx.chdir("/root/work")
            ctx.setgid(1000); ctx.setuid(1000)
            ctx.spawn("child") { child in
                box.ran = true
                box.relative = Self.openError(child, "job")
                box.absolute = Self.openError(child, "/root/x")
                child.exit(0)
            }
            ctx.exit(0)
        }
        system.loop.runUntilIdle()
        #expect(box.ran)
        #expect(box.relative == nil)
        #expect(box.absolute == .permissionDenied)
    }

    // MARK: - Mount namespaces

    @Test func mountBeneathAnUnsearchableDirectoryIsUnreachable() {
        let system = lockedRoot()
        system.directory("/root/mnt", mode: Self.world)
        final class Box { var user: SyscallError?; var root: SyscallError?; var parent: Bool? }
        let box = Box()
        system.kernel.spawn("mounter") { ctx in
            ctx.unshareMountNamespace()
            ctx.mountTmpfs(at: "/root/mnt")
            if let fd = ctx.open("/root/mnt/inside", create: true) { ctx.close(fd) }
            box.root = Self.openError(ctx, "/root/mnt/inside")
            ctx.spawn("user") { child in
                child.setgid(1000); child.setuid(1000)
                box.user = Self.openError(child, "/root/mnt/inside")
                box.parent = child.mkdir("/root/mnt/new")
                child.exit(0)
            }
            ctx.exit(0)
        }
        system.loop.runUntilIdle()
        #expect(box.root == nil)
        #expect(box.user == .permissionDenied)
        #expect(box.parent == false)
    }

    @Test func mountedRootReplacesTheDirectoryItCovers() {
        // The mountpoint directory is 0700, but what is mounted on it is 0755:
        // the mounted root is what gets searched, as on Linux. And the reverse.
        let system = System()
        system.directory("/mnt", mode: Self.rwx)
        system.directory("/open", mode: Self.world)
        final class Box { var covered: SyscallError?; var closedRoot: SyscallError? }
        let box = Box()
        system.kernel.spawn("mounter") { ctx in
            ctx.unshareMountNamespace()
            ctx.mountTmpfs(at: "/mnt")
            if let fd = ctx.open("/mnt/a", create: true) { ctx.close(fd) }
            ctx.mountTmpfs(at: "/open")
            if let fd = ctx.open("/open/b", create: true) { ctx.close(fd) }
            _ = ctx.chmod("/open", mode: Self.rwx)   // the mounted root, not the covered dir
            ctx.spawn("user") { child in
                child.setgid(1000); child.setuid(1000)
                box.covered = Self.openError(child, "/mnt/a")
                box.closedRoot = Self.openError(child, "/open/b")
                child.exit(0)
            }
            ctx.exit(0)
        }
        system.loop.runUntilIdle()
        #expect(box.covered == nil)
        #expect(box.closedRoot == .permissionDenied)
    }

    /// Mounting is reserved for uid 0, so a user cannot give an unreachable tree
    /// a second, reachable path.
    @Test func bindMountCannotBeUsedToEnterAnUnsearchableTree() {
        let system = lockedRoot()
        system.directory("/root/dir", mode: Self.world)
        system.file("/root/dir/inner")
        system.directory("/tmp", mode: [.ownerRead, .ownerWrite, .ownerExecute,
                                         .groupRead, .groupWrite, .groupExecute,
                                         .otherRead, .otherWrite, .otherExecute])
        system.directory("/tmp/view", mode: Self.world, uid: 1000, gid: 1000)
        let result = system.asUser { ctx -> (Bool, SyscallError?) in
            ctx.unshareMountNamespace()
            let mounted = ctx.mountBind(source: "/root/dir", at: "/tmp/view")
            return (mounted, Self.openError(ctx, "/tmp/view/inner"))
        }
        #expect(result.0 == false)
        #expect(result.1 == .noSuchFileOrDirectory)
    }

    @Test func bindMountMadeByRootExposesItsSubtreeAtTheNewPath() {
        // Root deliberately publishes /root/dir at /srv: the new path has its
        // own ancestors, exactly like a Linux bind mount.
        let system = lockedRoot()
        system.directory("/root/dir", mode: Self.world)
        system.file("/root/dir/inner")
        system.directory("/srv", mode: Self.world)
        final class Box { var viaBind: SyscallError?; var viaSource: SyscallError? }
        let box = Box()
        system.kernel.spawn("mounter") { ctx in
            ctx.unshareMountNamespace()
            ctx.mountBind(source: "/root/dir", at: "/srv")
            ctx.spawn("user") { child in
                child.setgid(1000); child.setuid(1000)
                box.viaBind = Self.openError(child, "/srv/inner")
                box.viaSource = Self.openError(child, "/root/dir/inner")
                child.exit(0)
            }
            ctx.exit(0)
        }
        system.loop.runUntilIdle()
        #expect(box.viaBind == nil)
        #expect(box.viaSource == .permissionDenied)
    }

    // MARK: - Capability scopes

    @Test func scopedOperationsEnforceSearchBelowAndAboveTheScopeRoot() {
        let system = lockedRoot()
        system.directory("/pub", mode: Self.world)
        system.directory("/pub/closed", mode: Self.rwx)
        system.file("/pub/closed/inner")
        system.file("/pub/top")

        func error(_ body: @escaping (ProcessContext) throws -> Void) -> SyscallError? {
            system.asUser { ctx -> SyscallError? in
                do { try body(ctx); return nil } catch { return error as? SyscallError }
            }
        }
        let pub = FileSystemScope(rootPath: "/pub")
        #expect(error { $0.close(try $0.openFile("top", in: pub)) } == nil)
        #expect(error { $0.close(try $0.openFile("closed/inner", in: pub)) } == .permissionDenied)
        #expect(error { _ = try $0.stat("closed/inner", in: pub) } == .permissionDenied)
        #expect(error { try $0.mkdir("closed/new", in: pub) } == .permissionDenied)
        #expect(error { try $0.unlinkFile("closed/inner", in: pub) } == .permissionDenied)
        // A scope rooted somewhere the caller cannot reach is itself refused.
        #expect(error { _ = try $0.stat("x", in: FileSystemScope(rootPath: "/root")) } == .permissionDenied)
        #expect(error { _ = try $0.listDirectory(".", in: FileSystemScope(rootPath: "/root")) } == .permissionDenied)
    }

    // MARK: - Completion

    @Test func completionDoesNotRevealNamesBehindAnUnsearchableDirectory() {
        let system = lockedRoot()
        system.directory("/pub", mode: Self.world)
        system.file("/pub/visible")
        final class Box { var pid: PID = 0 }
        let box = Box()
        system.kernel.spawn("sh") { ctx in
            ctx.setgid(1000); ctx.setuid(1000)
            box.pid = ctx.process.pid
            guard let idle = ctx.socket() else { return }
            ctx.recvfrom(idle) { _, _, _ in }
        }
        system.loop.runUntilIdle()
        let registry = CommandRegistry.builtins
        #expect(system.kernel.complete(line: "cat /root/", commands: registry, shellPID: box.pid).candidates.isEmpty)
        #expect(system.kernel.complete(line: "cat /pub/", commands: registry, shellPID: box.pid).candidates == ["visible"])
    }

    // MARK: - Property: the walk agrees with a reference model

    /// Random trees with random directory modes and owners: resolving any file
    /// succeeds exactly when every directory on the way grants search to the
    /// caller — computed independently here from the modes that were set.
    @Test func resolutionMatchesTheReferenceModelOnRandomTrees() {
        for seed in UInt64(1)...40 {
            var prng = SplitMix64(seed: seed)
            let system = System()
            struct Dir { let path: String; let mode: FileMode; let uid: UInt32; let gid: UInt32 }
            var dirs: [Dir] = []
            var files: [String] = []
            func searchable(_ dir: Dir) -> Bool {
                if dir.uid == 1000 { return dir.mode.contains(.ownerExecute) }
                if dir.gid == 1000 { return dir.mode.contains(.groupExecute) }
                return dir.mode.contains(.otherExecute)
            }
            // A chain of 1...6 nested directories with a file in each.
            let depth = 1 + Int(prng.next() % 6)
            var path = ""
            for level in 0..<depth {
                path += "/d\(level)"
                let mode = FileMode(rawValue: UInt16(prng.next() % 0o1000))
                let uid: UInt32 = prng.next() % 3 == 0 ? 1000 : 0
                let gid: UInt32 = prng.next() % 3 == 0 ? 1000 : 0
                dirs.append(Dir(path: path, mode: mode, uid: uid, gid: gid))
                files.append(path + "/f")
            }
            system.asRoot { ctx in
                for dir in dirs { ctx.mkdir(dir.path) }
                for file in files {
                    if let fd = ctx.open(file, create: true) { ctx.close(fd) }
                }
                for dir in dirs {
                    _ = ctx.chown(dir.path, uid: dir.uid, gid: dir.gid)
                    _ = ctx.chmod(dir.path, mode: dir.mode)
                }
            }
            let observed = system.asUser { ctx in files.map { ctx.stat($0) != nil } }
            for (index, file) in files.enumerated() {
                let expected = dirs.prefix(index + 1).allSatisfy(searchable)
                #expect(observed[index] == expected,
                        "seed \(seed): \(file) expected reachable=\(expected)")
            }
            // Root reaches everything regardless.
            final class Box { var all = false }
            let box = Box()
            system.asRoot { ctx in box.all = files.allSatisfy { ctx.stat($0) != nil } }
            #expect(box.all, "seed \(seed): root was refused")
        }
    }

    // MARK: - Cost on deep trees

    /// One permission decision per traversed directory, none for the final
    /// node, and none at all without a policy (the uid-0 path): the check adds
    /// O(depth) work to a walk that is already O(depth).
    @Test func deepWalkAsksOncePerDirectory() {
        let vfs = VirtualFileSystem()
        let depth = 800
        let path = (0..<depth).map { "d\($0)" }.joined(separator: "/")
        vfs.makeDirectories("/" + path)
        vfs.createFile("/" + path + "/leaf")

        final class Counter { var asked = 0 }
        let counter = Counter()
        let search = VirtualFileSystem.PathSearch(permits: { _ in
            counter.asked += 1
            return true
        })
        let resolution = vfs.resolve("/" + path + "/leaf", search: search)
        #expect(resolution.node?.kind == .file)
        #expect(counter.asked == depth + 1)   // the root plus each of the `depth` directories

        // A refusal stops the walk where it happens.
        counter.asked = 0
        let stopAt = 10
        let refusing = VirtualFileSystem.PathSearch(permits: { _ in
            counter.asked += 1
            return counter.asked <= stopAt
        })
        if case .searchDenied = vfs.resolve("/" + path + "/leaf", search: refusing) {} else {
            Issue.record("expected the walk to be refused")
        }
        #expect(counter.asked == stopAt + 1)

        // Trusted (cwd) components are not asked about.
        counter.asked = 0
        var anchored = search
        anchored.trustedComponents = depth
        #expect(vfs.resolve("/" + path + "/leaf", search: anchored).node != nil)
        #expect(counter.asked == 1)           // only the cwd itself

        // No policy, no questions.
        counter.asked = 0
        #expect(vfs.lookup("/" + path + "/leaf") != nil)
        #expect(counter.asked == 0)
    }

    @Test func deepTreeIsUsableByANonRootProcess() {
        let system = System()
        let depth = 300
        let path = "/" + (0..<depth).map { "n\($0)" }.joined(separator: "/")
        system.asRoot { ctx in
            ctx.mkdir(path)
            if let fd = ctx.open(path + "/leaf", create: true) { ctx.close(fd) }
        }
        #expect(system.asUser { Self.openError($0, path + "/leaf") } == nil)
        // Closing the directory halfway down cuts off everything beneath it.
        let middle = "/" + (0..<150).map { "n\($0)" }.joined(separator: "/")
        system.asRoot { _ = $0.chmod(middle, mode: Self.rwx) }
        #expect(system.asUser { Self.openError($0, path + "/leaf") } == .permissionDenied)
        #expect(system.asUser { $0.stat(middle)?.isDirectory } == true)
    }
}
