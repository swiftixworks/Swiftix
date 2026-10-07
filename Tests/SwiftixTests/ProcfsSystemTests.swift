import Testing
@testable import Swiftix

/// Contract tests for the userland-baseline procfs additions: `/proc/self`, the
/// per-process `stat`/`comm`/`environ`/`fd` entries, and the system-wide
/// `loadavg`, `stat`, `filesystems`, and `sys/kernel` files. Each value asserted
/// here has a real source of truth in the kernel.
@Suite("procfs system and per-process entries")
struct ProcfsSystemTests {

    private func read(_ ctx: ProcessContext, _ path: String) -> String? {
        guard let fd = ctx.open(path) else { return nil }
        defer { ctx.close(fd) }
        return String(decoding: ctx.read(fd, max: 65_535), as: UTF8.self)
    }

    // MARK: - /proc/self

    @Test func procSelfResolvesToTheReadingProcess() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var links: [PID: String?] = [:]; var comm: [PID: String?] = [:] }
        let box = Box()
        var pids: [PID] = []
        for name in ["alpha", "beta"] {
            pids.append(kernel.spawn(name) { ctx in
                box.links[ctx.globalPID] = ctx.readlink("/proc/self")
                box.comm[ctx.globalPID] = self.read(ctx, "/proc/self/comm")
            })
        }
        loop.runUntilIdle()
        #expect(box.links[pids[0]] == "\(pids[0])")
        #expect(box.links[pids[1]] == "\(pids[1])")
        #expect(box.comm[pids[0]] == "alpha\n")
        #expect(box.comm[pids[1]] == "beta\n")
    }

    @Test func procSelfIsListedAsALinkAndWorksAsWorkingDirectory() {
        let result = runInFreshKernel { ctx -> ([String], Bool, String?, FileType?) in
            let listing = ctx.listDirectory("/proc") ?? []
            let entered = ctx.chdir("/proc/self")
            return (listing, entered, self.read(ctx, "comm"), ctx.lstat("/proc/self")?.type)
        }
        #expect(result?.0.contains("self") == true)        // a link, so no trailing slash
        #expect(result?.0.contains("1/") == true)
        #expect(result?.1 == true)
        #expect(result?.2 == "probe\n")
        #expect(result?.3 == .symlink)
    }

    // MARK: - /proc/<pid>

    @Test func pidDirectoryListsTheContractEntries() {
        let listing = runInFreshKernel { ctx in ctx.listDirectory("/proc/\(ctx.globalPID)") ?? [] }
        #expect(listing == ["cmdline", "comm", "cwd", "environ", "fd/", "fdinfo",
                            "stat", "status", "syscalls"])
        #expect(listing?.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
                == ProcfsSchema.PidDirectory.entries)
    }

    @Test func pidStatUsesLinuxOrderedLeadingFields() {
        #expect(ProcfsSchema.PidStat.fields == ["PID", "COMM", "STATE", "PPID", "PGRP", "SESSION", "TTY_NR", "TPGID"])
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let box = ResultBox<[String?]>()
        let parent = kernel.spawn("parent") { ctx in
            let child = ctx.spawn("child proc") { child in child.sleep(5) { child.exit(0) } }
            ctx.sleep(1) {
                box.value = [self.read(ctx, "/proc/self/stat"), self.read(ctx, "/proc/\(child)/stat")]
                ctx.wait { _ in ctx.exit(0) }
            }
        }
        loop.advance(by: 2)
        #expect(box.value?[0] == "\(parent) (parent) R 0 \(parent) \(parent) 0 -1\n")
        #expect(box.value?[1] == "\(parent + 1) (child proc) S \(parent) \(parent) \(parent) 0 -1\n")
        loop.advance(by: 10)
    }

    @Test func pidStatReportsControllingTerminalAndForegroundGroup() {
        let session = SystemSession()
        let row = session.lines("cat /proc/self/stat").first?.split(separator: " ").map(String.init) ?? []
        #expect(row.count == ProcfsSchema.PidStat.fields.count)
        #expect(row[1] == "(cat)")
        #expect(row[5] == "\(session.shellPID)")            // session
        #expect(row[6] == "\((136 << 8) | 0)")              // pts/0
        #expect(row[7] == row[4])                           // cat's group is the foreground job
    }

    @Test func environIsNulSeparatedSortedAndOwnerOnly() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var own: [UInt8]?; var denied = false; var mode: FileMode? }
        let box = Box()
        let owner = kernel.spawn("owner") { ctx in
            ctx.setenv("ZED", "last")
            ctx.setenv("ALPHA", "a b")
            if let fd = ctx.open("/proc/self/environ") { box.own = ctx.read(fd, max: 4096) }
            box.mode = ctx.stat("/proc/self/environ")?.mode
            ctx.sleep(10) { ctx.exit(0) }
        }
        loop.advance(by: 0)
        kernel.spawn("other") { ctx in
            ctx.setgid(1000); ctx.setuid(1000)
            box.denied = ctx.open("/proc/\(owner)/environ") == nil
        }
        loop.advance(by: 0)
        #expect(box.own == Array("ALPHA=a b\u{0}ZED=last\u{0}".utf8))
        #expect(box.mode == [.ownerRead])
        #expect(box.denied)
        kernel.shutdown()
    }

    @Test func fdDirectoryListsOpenDescriptors() {
        let result = runInFreshKernel { ctx -> [String] in
            let a = ctx.open("/a", create: true)!
            let pipe = ctx.pipe()
            let listing = ctx.listDirectory("/proc/self/fd") ?? []
            ctx.close(pipe.read)
            let after = ctx.listDirectory("/proc/self/fd") ?? []
            return [listing.joined(separator: ","), after.joined(separator: ","), "\(a),\(pipe.read),\(pipe.write)"]
        }
        #expect(result == ["0,1,2", "0,2", "0,1,2"])
    }

    /// `cwd` links to the process's working directory. `exe` has no source of
    /// truth (processes are closures) and is not exposed.
    @Test func cwdLinksToTheWorkingDirectoryAndExeIsAbsent() {
        let result = runInFreshKernel { ctx -> [String] in
            ctx.mkdir("/work/sub")
            _ = ctx.chdir("/work/sub")
            return [
                ctx.lstat("/proc/self/exe") == nil ? "no-exe" : "exe",
                ctx.lstat("/proc/self/cwd")?.type == .symlink ? "link" : "other",
                ctx.readlink("/proc/self/cwd") ?? "<none>",
                ctx.stat("/proc/self/cwd")?.isDirectory == true ? "dir" : "not-dir",
            ]
        }
        #expect(result == ["no-exe", "link", "/work/sub", "dir"])
        let session = SystemSession()
        #expect(session.lines("mkdir /tmp; cd /tmp; readlink /proc/self/cwd") == ["/tmp"])
        #expect(session.lines("readlink /proc/$$/cwd") == ["/tmp"])
    }

    /// The tree walkers do not follow the links they meet (`/proc/self`,
    /// `/proc/<pid>/cwd` -> an ancestor), and the ones that read file contents
    /// skip device nodes (`/proc/<pid>/fd/0` is the terminal), so a walk of the
    /// whole tree terminates.
    @Test func wholeTreeWalksTerminate() {
        let session = SystemSession()
        let found = session.lines("find /")
        #expect(found.contains("/dev/zero"))
        #expect(found.contains("/proc/self"))
        #expect(found.contains("/proc/1/cwd"))
        #expect(found.contains("/proc/1/fd/0"))
        #expect(found.contains("/proc/sys/kernel/hostname"))
        // Links are listed, never descended into.
        #expect(!found.contains { $0.hasPrefix("/proc/self/") || $0.hasPrefix("/proc/1/cwd/") })
        #expect(session.lines("du -s / > /dev/null; echo rc=$?") == ["rc=0"])
        #expect(session.lines("du / | tail -n 1 | cut -f2") == ["/"])
        #expect(session.lines("tree / > /dev/null; echo rc=$?") == ["rc=0"])
        #expect(session.lines("ls -R / > /dev/null; echo rc=$?") == ["rc=0"])
        #expect(session.lines("grep -r Swiftix /proc/version /proc/sys > /dev/null; echo rc=$?") == ["rc=0"])
        // No file under /proc contains this needle; the point is that the
        // search ends instead of blocking on the terminal behind fd/0.
        #expect(session.lines("grep -r zz-no-such-needle-zz /proc > /dev/null 2>&1; echo done") == ["done"])
        #expect(session.lines("grep -R zz-no-such-needle-zz /proc > /dev/null 2>&1; echo done") == ["done"])
        #expect(session.lines("echo alive") == ["alive"])
    }

    // MARK: - System-wide files

    @Test func loadavgReportsLiveCountsAndExactZeroAverages() {
        #expect(ProcfsSchema.LoadAverage.fields.count == 5)
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        kernel.spawn("sleeper") { ctx in ctx.sleep(10) { ctx.exit(0) } }
        loop.advance(by: 0)
        let box = ResultBox<String?>()
        let reader = kernel.spawn("reader") { ctx in box.value = self.read(ctx, ProcfsSchema.LoadAverage.path) }
        loop.advance(by: 0)
        // One running (the reader), two retained, last pid = the reader's.
        #expect(box.value == "0.00 0.00 0.00 1/2 \(reader)\n")
        kernel.shutdown()
    }

    @Test func statExposesOnlyMaintainedCounters() {
        let loop = EventLoop()
        loop.advance(by: 30)                       // the shared loop is already "old"
        let kernel = Kernel(loop: loop)
        kernel.setWallClock(epochSeconds: 1_791_376_496)
        loop.advance(by: 5)
        kernel.spawn("waiter") { ctx in ctx.sleep(100) { ctx.exit(0) } }
        loop.advance(by: 0)
        let box = ResultBox<String?>()
        kernel.spawn("reader") { ctx in box.value = self.read(ctx, ProcfsSchema.Stat.path) }
        loop.advance(by: 0)
        let text = (box.value ?? nil) ?? ""
        let rows = text.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        #expect(rows.map { $0[0] } == ProcfsSchema.Stat.keys)
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0[0], Int($0[1]) ?? -1) })
        #expect(values["ctxt"] == 2)               // waiter's body + reader's body
        #expect(values["btime"] == 1_791_376_496)  // the kernel was created at that instant
        #expect(values["processes"] == 2)
        #expect(values["procs_running"] == 1)
        #expect(values["procs_blocked"] == 1)
        #expect(!text.contains("cpu"))
        kernel.shutdown()
    }

    @Test func filesystemsListsTheVirtualTypes() {
        let text = runInFreshKernel { self.read($0, ProcfsSchema.Filesystems.path) }
        #expect(text == "nodev\ttmpfs\nnodev\tproc\n")
    }

    @Test func sysKernelIdentityIsReadOnlyAndFollowsTheUTSNamespace() {
        let result = runInFreshKernel { ctx -> [String?] in
            ctx.setHostname("lab")
            let shared = self.read(ctx, ProcfsSchema.SysKernel.hostnamePath)
            ctx.unshareUTS()
            ctx.setHostname("private")
            let own = self.read(ctx, ProcfsSchema.SysKernel.hostnamePath)
            let fd = ctx.open(ProcfsSchema.SysKernel.hostnamePath)!
            let wrote = ctx.write(fd, Array("nope".utf8))
            return [shared, own, "\(wrote)",
                    self.read(ctx, ProcfsSchema.SysKernel.ostypePath),
                    self.read(ctx, ProcfsSchema.SysKernel.osreleasePath),
                    ctx.listDirectory("/proc/sys/kernel")?.joined(separator: ",")]
        }
        #expect(result == ["lab\n", "private\n", "0", "Swiftix\n", Swiftix.version + "\n",
                           "hostname,osrelease,ostype"])
    }

    /// The additions leave the versioned teaching schema untouched.
    @Test func teachingSchemaVersionIsUnchanged() {
        #expect(Swiftix.teachingProcfsSchemaVersion == 1)
        #expect(ProcfsSchema.Processes.fields == ["PID", "PPID", "PGID", "SID", "STATE", "TICKS", "FDS", "MEM", "NAME"])
    }
}
