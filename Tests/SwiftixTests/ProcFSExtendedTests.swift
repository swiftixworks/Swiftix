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
        #expect(box.cmdline == "worker alpha beta")
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
