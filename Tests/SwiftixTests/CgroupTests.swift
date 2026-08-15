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

    /// `pids.max` refuses the spawn that would exceed it: the child is born
    /// already exited (resource-limit status) and never runs its body. This is
    /// the fork-bomb containment.
    @Test func pidsMaxRefusesSpawnBeyondLimit() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.createCgroup("/demo")
        kernel.setCgroupPidsMax("/demo", 1)   // room for exactly one process

        let childRan = Flag()
        let childStatus = Counter()
        kernel.spawn("parent") { ctx in
            _ = ctx.joinCgroup("/demo")        // parent occupies the single slot
            ctx.spawn("child") { c in
                childRan.value = true          // must NOT run — admission is refused
                c.exit(0)
            }
            ctx.wait { result in
                if case .success(let event) = result { childStatus.value = Int(event.status.code) }
                ctx.exit(0)
            }
        }
        loop.runUntilIdle()

        #expect(childRan.value == false)
        #expect(childStatus.value == Int(Kernel.cgroupDeniedStatus))
    }

    /// Moving a live process into a full group is refused, leaving it where it was.
    @Test func joinRefusedWhenGroupFull() {
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
            joined.value = ctx.joinCgroup("/g")     // should fail
            where0.value = ctx.cgroupPath           // still root
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(joined.value == false)
        #expect(where0.value == "/")
        #expect(kernel.cgroupPidsCurrent("/g") == 1)
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
                ctx.spawn("kid") { kid in kid.print("kid ran\n"); kid.exit(0) }
                ctx.wait { result in
                    if case .success(let event) = result, event.status.code != 0 {
                        ctx.print("kid denied code=\(event.status.code)\n")
                    }
                    ctx.exit(0)
                }
            })
        })
        #expect(contains(out, Array("kid denied code=11".utf8)))
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
