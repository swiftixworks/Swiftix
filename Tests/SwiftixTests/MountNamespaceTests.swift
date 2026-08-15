import Testing
@testable import Swiftix

/// Mount namespaces: an isolated view of the mount table (the last container
/// pillar). Covers the two modeled mount types — a fresh tmpfs and a bind mount —
/// their effect on path resolution (shadowing, shared data), and `unshare -m`
/// isolation. Two layers: the `ProcessContext`/kernel surface and the
/// `mount`/`umount`/`unshare -m` shell commands.
@Suite("Mount namespace (mount table isolation)")
struct MountNamespaceTests {

    // MARK: - Syscall layer

    /// A tmpfs mount shadows the mountpoint's base contents and holds its own
    /// files; unmounting restores the base view.
    @Test func tmpfsMountShadowsBaseAndHoldsFiles() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        let baseShadowed = Flag()
        let mountFilePresent = Flag()
        let baseBackAfterUmount = Flag()
        let mountFileGoneAfterUmount = Flag()

        kernel.spawn("p") { ctx in
            ctx.mkdir("/mnt")
            if let fd = ctx.open("/mnt/base", create: true) { ctx.write(fd, Array("B".utf8)); ctx.close(fd) }

            _ = ctx.mountTmpfs(at: "/mnt")
            baseShadowed.value = (ctx.stat("/mnt/base") == nil)        // base file hidden
            if let fd = ctx.open("/mnt/m", create: true) { ctx.write(fd, Array("M".utf8)); ctx.close(fd) }
            mountFilePresent.value = (ctx.stat("/mnt/m") != nil)       // lives in the mount

            _ = ctx.unmount("/mnt")
            baseBackAfterUmount.value = (ctx.stat("/mnt/base") != nil) // base visible again
            mountFileGoneAfterUmount.value = (ctx.stat("/mnt/m") == nil)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(baseShadowed.value)
        #expect(mountFilePresent.value)
        #expect(baseBackAfterUmount.value)
        #expect(mountFileGoneAfterUmount.value)
    }

    /// A bind mount makes two paths refer to the same subtree: reads and writes
    /// are visible through both.
    @Test func bindMountSharesData() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        let readThroughBind = Box()
        let readBackThroughSource = Box()
        kernel.spawn("p") { ctx in
            ctx.mkdir("/src"); ctx.mkdir("/dst")
            if let fd = ctx.open("/src/a", create: true) { ctx.write(fd, Array("hello".utf8)); ctx.close(fd) }

            _ = ctx.mountBind(source: "/src", at: "/dst")
            if let fd = ctx.open("/dst/a") { readThroughBind.value = String(decoding: ctx.read(fd, max: 99), as: UTF8.self); ctx.close(fd) }
            if let fd = ctx.open("/dst/b", create: true) { ctx.write(fd, Array("world".utf8)); ctx.close(fd) }
            if let fd = ctx.open("/src/b") { readBackThroughSource.value = String(decoding: ctx.read(fd, max: 99), as: UTF8.self); ctx.close(fd) }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(readThroughBind.value == "hello")     // source data seen through the bind
        #expect(readBackThroughSource.value == "world") // write through the bind seen at the source
    }

    /// After `unshare`-ing its mount namespace, a process's mounts are invisible to
    /// its parent.
    @Test func mountNamespaceIsolatesMounts() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        let childSees = Flag()
        let parentSees = Flag()
        kernel.spawn("parent") { ctx in
            ctx.mkdir("/mnt")
            ctx.spawn("child") { child in
                child.unshareMountNamespace()
                _ = child.mountTmpfs(at: "/mnt")
                if let fd = child.open("/mnt/private", create: true) { child.close(fd) }
                childSees.value = (child.stat("/mnt/private") != nil)
                child.exit(0)
            }
            ctx.wait { _ in
                parentSees.value = (ctx.stat("/mnt/private") != nil)
                ctx.exit(0)
            }
        }
        loop.runUntilIdle()

        #expect(childSees.value)          // the child sees its own mounted file
        #expect(!parentSees.value)        // the parent's namespace never saw the mount
    }

    /// A mount performed WITHOUT unsharing is shared with the parent (the global
    /// mount table) — the contrast that makes the isolation test meaningful.
    @Test func mountWithoutUnshareIsSharedWithParent() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        let parentSees = Flag()
        kernel.spawn("parent") { ctx in
            ctx.mkdir("/mnt")
            ctx.spawn("child") { child in
                _ = child.mountTmpfs(at: "/mnt")               // no unshare → shared table
                if let fd = child.open("/mnt/shared", create: true) { child.close(fd) }
                child.exit(0)
            }
            ctx.wait { _ in
                parentSees.value = (ctx.stat("/mnt/shared") != nil)
                ctx.exit(0)
            }
        }
        loop.runUntilIdle()

        #expect(parentSees.value)
    }

    // MARK: - Command layer (through the shell)

    @Test func mountTmpfsAndListThroughShell() {
        let out = run(["mkdir /mnt", "mount -t tmpfs tmpfs /mnt", "echo hi > /mnt/f", "cat /mnt/f", "mount"])
        #expect(contains(out, Array("hi".utf8)))               // file readable in the mount
        #expect(contains(out, Array("tmpfs on /mnt".utf8)))    // shown in the mount table
    }

    @Test func umountThroughShell() {
        let out = run(["mkdir /mnt", "mount -t tmpfs tmpfs /mnt", "umount /mnt", "mount"])
        #expect(!contains(out, Array("tmpfs on /mnt".utf8)))   // gone after umount
    }

    /// `unshare -m CMD` runs CMD with a private mount table: a mount it makes is
    /// invisible to the shell afterwards.
    @Test func unshareMountIsolatesInShell() {
        let out = run(["mkdir /mnt", "unshare -m mountmaker", "cat /mnt/marker"], register: { registry in
            registry.register(Command(name: "mountmaker", summary: "mount + write in a private ns") { ctx, _ in
                _ = ctx.mountTmpfs(at: "/mnt")
                if let fd = ctx.open("/mnt/marker", create: true) { ctx.write(fd, Array("X".utf8)); ctx.close(fd) }
                ctx.print("made\n")
                ctx.exit(0)
            })
        })
        #expect(contains(out, Array("made".utf8)))
        #expect(contains(out, Array("No such file".utf8)))     // shell can't see the private mount's file
    }

    // MARK: - Helpers

    private final class Flag { var value = false }
    private final class Box { var value = "" }
    private final class Capture { var out: [UInt8] = [] }

    private func run(_ lines: [String],
                     register: ((CommandRegistry) -> Void)? = nil) -> [UInt8] {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let registry = CommandRegistry.builtins
        register?(registry)
        let pty = PseudoTerminal()
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave, commands: registry))
        loop.runUntilIdle()
        for line in lines {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }
        return captured.out
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
