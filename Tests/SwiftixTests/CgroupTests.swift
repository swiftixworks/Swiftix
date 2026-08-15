import Testing
@testable import Swiftix

/// Control groups (cgroups "pids" controller): hierarchy, live `pids.current`
/// accounting, and `pids.max` enforcement — the grouping/limiting pillar of the
/// container model, alongside the UTS-namespace isolation pillar. Two layers are
/// covered: the `ProcessContext`/kernel surface (admission, move, accounting) and
/// the shell commands (`cgcreate`/`cgset`/`cgexec`/`cgdelete`) plus the synthetic
/// `/sys/fs/cgroup` files.
@Suite("Control groups (pids controller)")
struct CgroupTests {

    // MARK: - Kernel / syscall layer

    /// A process moved into a group, plus its (admitted) children, count toward
    /// the group's `pids.current`.
    @Test func pidsCurrentCountsSubtreeMembers() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.createCgroup("/demo")

        // One long-lived process joins /demo and parks (no writer → never wakes).
        kernel.spawn("member") { ctx in
            _ = ctx.joinCgroup("/demo")
            let pipe = ctx.pipe()
            _ = pipe.write
            ctx.read(pipe.read) { _ in }
        }
        loop.runUntilIdle()

        #expect(kernel.cgroupPidsCurrent("/demo") == 1)
    }

    /// `pids.max` refuses the spawn that would exceed it before a PID or child
    /// lifecycle is allocated. The non-throwing Swiftix spawn surface returns 0.
    @Test func pidsMaxRefusesSpawnBeyondLimit() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.createCgroup("/demo")
        kernel.setCgroupPidsMax("/demo", 1)   // room for exactly one process

        let childRan = Flag()
        let childPID = Counter()
        kernel.spawn("parent") { ctx in
            _ = ctx.joinCgroup("/demo")        // parent occupies the single slot
            childPID.value = ctx.spawn("child") { c in
                childRan.value = true          // must NOT run — admission is refused
                c.exit(0)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(childRan.value == false)
        #expect(childPID.value == 0)
    }

    /// Migration is organizational and may put a group above pids.max; the
    /// over-limit group then refuses subsequent process creation.
    @Test func joinMayMoveExistingProcessAboveLimit() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.createCgroup("/g")
        kernel.setCgroupPidsMax("/g", 1)

        // Occupy the one slot with a parked process.
        kernel.spawn("first") { ctx in
            _ = ctx.joinCgroup("/g")
            let pipe = ctx.pipe(); _ = pipe.write
            ctx.read(pipe.read) { _ in }
        }
        loop.runUntilIdle()

        let joined = Flag()
        let where0 = Box()
        kernel.spawn("second") { ctx in
            joined.value = ctx.joinCgroup("/g")
            where0.value = ctx.cgroupPath
            let pipe = ctx.pipe(); _ = pipe.write
            ctx.read(pipe.read) { _ in }
        }
        loop.runUntilIdle()

        #expect(joined.value)
        #expect(where0.value == "/g")
        #expect(kernel.cgroupPidsCurrent("/g") == 2)
    }

    /// An empty group can be removed; a group with a live member cannot.
    @Test func removeRefusesNonEmptyGroup() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.createCgroup("/empty")
        #expect(kernel.removeCgroup("/empty") == true)

        kernel.createCgroup("/busy")
        kernel.spawn("member") { ctx in
            _ = ctx.joinCgroup("/busy")
            let pipe = ctx.pipe(); _ = pipe.write
            ctx.read(pipe.read) { _ in }
        }
        loop.runUntilIdle()
        #expect(kernel.removeCgroup("/busy") == false)
    }

    // MARK: - Command layer (through the shell)

    @Test func cgcreateMakesSysfsEntry() {
        let out = run(["cgcreate demo", "cat /sys/fs/cgroup/demo/pids.max"])
        #expect(contains(out, Array("max".utf8)))
    }

    @Test func cgsetUpdatesPidsMax() {
        let out = run(["cgcreate demo", "cgset demo pids.max 5", "cat /sys/fs/cgroup/demo/pids.max"])
        #expect(contains(out, Array("5".utf8)))
    }

    /// `cgexec` runs a command inside the group; a fork past `pids.max` from
    /// inside that command is refused (the containment demo).
    @Test func cgexecContainsForkBeyondLimit() {
        let out = run(["cgcreate demo", "cgset demo pids.max 1", "cgexec demo forkone"],
                      register: { registry in
            registry.register(Command(name: "forkone", summary: "spawn one child") { ctx, _ in
                let pid = ctx.spawn("kid") { kid in kid.print("kid ran\n"); kid.exit(0) }
                guard pid != 0 else {
                    ctx.print("kid denied\n")
                    ctx.exit(11)
                    return
                }
                ctx.wait { result in
                    if case .success(let event) = result { ctx.exit(event.status.code) }
                    else { ctx.exit(1) }
                }
            })
        })
        #expect(contains(out, Array("kid denied".utf8)))
        #expect(!contains(out, Array("kid ran".utf8)))
    }

    @Test func cgdeleteRemovesEmptyGroup() {
        let out = run(["cgcreate demo", "cgdelete demo", "cat /sys/fs/cgroup/demo/pids.max"])
        // After deletion the sysfs file is gone, so `cat` fails.
        #expect(contains(out, Array("No such file".utf8)))
    }

    @Test func cgexecRejectsUnknownGroup() {
        let out = run(["cgexec nope echo hi"])
        #expect(contains(out, Array("does not exist".utf8)))
    }

    // MARK: - Helpers

    private final class Flag { var value = false }
    private final class Counter { var value = 0 }
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
