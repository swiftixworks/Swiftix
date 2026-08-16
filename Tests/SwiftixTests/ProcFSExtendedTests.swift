import Testing
@testable import Swiftix

/// The expanded observability surface (assessment A2): the static `/proc`
/// information files, live per-process `/proc/<pid>/` directories, and the
/// `/dev/null` device. Read directly through `ProcessContext` so the tests are
/// deterministic and shell-independent.
@Suite("Extended /proc + /dev")
struct ProcFSExtendedTests {

    // MARK: - Static /proc information files

    @Test func meminfoReportsMemTotal() {
        #expect(readFile("/proc/meminfo").contains("MemTotal:"))
    }

    @Test func cpuinfoReportsAModel() {
        let text = readFile("/proc/cpuinfo")
        #expect(text.contains("processor"))
        #expect(text.contains("model name"))
    }

    @Test func uptimeIsNumeric() {
        let text = readFile("/proc/uptime").trimmingNewline()
        let fields = text.split(separator: " ")
        #expect(fields.count == 2)
        #expect(Double(fields.first ?? "") != nil)
    }

    @Test func mountsListsTmpfsAndProc() {
        let text = readFile("/proc/mounts")
        #expect(text.contains("tmpfs / tmpfs"))
        #expect(text.contains("proc /proc proc"))
    }

    @Test func versionIdentifiesSwiftix() {
        #expect(readFile("/proc/version").contains("Swiftix version"))
    }

    @Test func swiftixContractVersionsTeachingSchemas() {
        let text = readFile("/proc/swiftix")
        #expect(text.contains("Version:\t\(Swiftix.version)"))
        #expect(text.contains("ProcSchema:\t\(Swiftix.teachingProcfsSchemaVersion)"))
        #expect(text.contains("MemoryModel:\tmanaged-runtime"))
        #expect(text.contains("SyscallModel:\tswift-native-completed"))
        #expect(text.contains("SyscallHistory:\t128"))
    }

    // MARK: - Per-process directories

    @Test func perProcessStatusAndCmdline() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var pid: PID = 0; var status = ""; var cmdline = "" }
        let box = Box()

        // A worker with a known argv, parked on a pipe read with no writer, so it
        // stays alive in the process table (no timer for runUntilIdle to fire).
        kernel.spawn("worker", args: ["worker", "alpha", "beta"]) { ctx in
            box.pid = ctx.getpid()
            let pipe = ctx.pipe()
            ctx.read(pipe.read) { _ in }
        }
        loop.runUntilIdle()

        kernel.spawn("reader") { ctx in
            if let fd = ctx.open("/proc/\(box.pid)/status") {
                box.status = String(decoding: ctx.read(fd, max: 65_535), as: UTF8.self); ctx.close(fd)
            }
            if let fd = ctx.open("/proc/\(box.pid)/cmdline") {
                box.cmdline = String(decoding: ctx.read(fd, max: 65_535), as: UTF8.self); ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.status.contains("Name:\tworker"))
        #expect(box.status.contains("Pid:\t\(box.pid)"))
        #expect(box.status.contains("State:\tS"))       // parked → sleeping
        #expect(box.status.contains("RuntimeMemory:\t0 bytes"))
        #expect(box.cmdline == "worker alpha beta")
    }

    @Test func perProcessFdinfoDescribesFilesPipesAndSockets() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var pid: PID = 0; var fdinfo = "" }
        let box = Box()

        kernel.spawn("worker") { ctx in
            box.pid = ctx.getpid()
            let file = ctx.open("/data", create: true)!
            _ = ctx.write(file, Array("hi".utf8))
            _ = ctx.pipe()
            let udp = ctx.socket()!
            _ = ctx.bind(udp, address: nil, port: 9_999)
            ctx.sleep(10) { ctx.exit(0) }
        }
        loop.advance(by: 0)

        kernel.spawn("reader") { ctx in
            if let fd = ctx.open("/proc/\(box.pid)/fdinfo") {
                box.fdinfo = String(decoding: ctx.read(fd, max: 65_535), as: UTF8.self)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.advance(by: 0)

        #expect(box.fdinfo.contains("FD TYPE ACCESS FLAGS OFFSET SIZE DETAIL"))
        #expect(box.fdinfo.contains("0 file read-write - 2 2 -"))
        #expect(box.fdinfo.contains("1 pipe read - - - read-end"))
        #expect(box.fdinfo.contains("2 pipe write - - - write-end"))
        #expect(box.fdinfo.contains("3 udp read-write - - - local=:9999"))
    }

    @Test func perProcessSyscallsExposeCompletedSwiftixCalls() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var pid: PID = 0; var syscalls = "" }
        let box = Box()

        kernel.spawn("worker") { ctx in
            box.pid = ctx.getpid()
            let file = ctx.open("/file with space", create: true)!
            _ = ctx.write(file, Array("hi".utf8))
            _ = ctx.seek(file, to: 0, whence: 0)
            _ = ctx.read(file, max: 2)
            let udp = ctx.socket()!
            _ = ctx.bind(udp, address: nil, port: 8_080)
            ctx.sleep(10) { ctx.exit(0) }
        }
        loop.advance(by: 0)

        kernel.spawn("reader") { ctx in
            if let fd = ctx.open("/proc/\(box.pid)/syscalls") {
                box.syscalls = String(decoding: ctx.read(fd, max: 65_535), as: UTF8.self)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.advance(by: 0)

        #expect(box.syscalls.contains("SEQ TICKS SYSCALL RESULT DETAIL"))
        #expect(box.syscalls.contains(" open 0 path=/file%20with%20space"))
        #expect(box.syscalls.contains(" write 2 fd=0,count=2"))
        #expect(box.syscalls.contains(" seek 0 fd=0,offset=0,whence=0"))
        #expect(box.syscalls.contains(" read 2 fd=0,max=2"))
        #expect(box.syscalls.contains(" socket 1 type=udp"))
        #expect(box.syscalls.contains(" bind 0 fd=1,port=8080"))
    }

    @Test func perProcessSyscallHistoryIsBounded() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var pid: PID = 0; var syscalls = "" }
        let box = Box()

        kernel.spawn("worker") { ctx in
            box.pid = ctx.getpid()
            for index in 0..<140 {
                _ = ctx.stat("/missing-\(index)")
            }
            ctx.sleep(10) { ctx.exit(0) }
        }
        loop.advance(by: 0)

        kernel.spawn("reader") { ctx in
            if let fd = ctx.open("/proc/\(box.pid)/syscalls") {
                box.syscalls = String(decoding: ctx.read(fd, max: 65_535), as: UTF8.self)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.advance(by: 0)

        let lines = box.syscalls.split(separator: "\n")
        #expect(lines.count == Process.syscallTraceCapacity + 1)
        #expect(lines[1].hasPrefix("13 "))
        #expect(lines.last?.hasPrefix("140 ") == true)
    }

    @Test func procDirectoryListsLivePids() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var pid: PID = 0; var entries: [String] = [] }
        let box = Box()

        kernel.spawn("worker") { ctx in
            box.pid = ctx.getpid()
            let pipe = ctx.pipe()
            ctx.read(pipe.read) { _ in }
        }
        loop.runUntilIdle()

        kernel.spawn("reader") { ctx in
            box.entries = ctx.listDirectory("/proc") ?? []
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.entries.contains("\(box.pid)/"))     // the live pid appears as a dir
        #expect(box.entries.contains("net/"))            // static entries still present
    }

    // MARK: - /dev/null

    @Test func devNullDiscardsWritesAndReadsEmpty() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var written = -1; var readEmpty = false }
        let box = Box()

        kernel.spawn("t") { ctx in
            guard let fd = ctx.open("/dev/null") else { ctx.exit(1); return }
            box.written = ctx.write(fd, Array("discard me".utf8))   // accepted + dropped
            box.readEmpty = ctx.read(fd, max: 100).isEmpty          // reads as EOF
            ctx.close(fd)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(box.written == 10)
        #expect(box.readEmpty)
    }

    @Test func devNullRedirectionThroughShell() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        pty.echo = false
        pty.onOutput = { [weak pty] in _ = pty?.readForApp(max: 65_535) }
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        // Writing to /dev/null must succeed (not hang or error); the marker proves
        // the shell moved on to the next command.
        pty.writeFromApp(Array("echo hidden > /dev/null; echo ok > /marker\n".utf8))
        loop.runUntilIdle()

        final class Box { var text = "" }
        let box = Box()
        kernel.spawn("read") { ctx in
            if let fd = ctx.open("/marker") {
                box.text = String(decoding: ctx.read(fd, max: 65_535), as: UTF8.self); ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()
        #expect(box.text == "ok\n")
    }

    // MARK: - Helper

    /// Read a whole file's contents (as text) through a one-shot process.
    private func readFile(_ path: String) -> String {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Box { var text = "" }
        let box = Box()
        kernel.spawn("reader") { ctx in
            if let fd = ctx.open(path) {
                box.text = String(decoding: ctx.read(fd, max: 65_535), as: UTF8.self)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()
        return box.text
    }
}

private extension String {
    func trimmingNewline() -> String {
        hasSuffix("\n") ? String(dropLast()) : self
    }
}
