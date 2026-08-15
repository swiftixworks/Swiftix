import Testing
@testable import Swiftix

@Suite("process introspection")
struct ProcessIntrospectionTests {

    @Test func snapshotProcessesReturnsStableIdentityRows() {
        let table = ProcessTable()
        let parent = table.allocate(name: "parent", args: ["parent"], parent: 0)
        let child = table.allocate(name: "child", args: ["child"], parent: parent.pid)
        child.processGroupID = parent.pid
        child.sessionID = parent.sessionID
        child.state = .blocked

        let rows = ProcessIntrospection(processTable: table).snapshotProcesses()

        #expect(rows.map(\.pid) == [parent.pid, child.pid])
        #expect(rows[0].ppid == 0)
        #expect(rows[0].pgid == parent.pid)
        #expect(rows[0].sid == parent.pid)
        #expect(rows[0].name == "parent")
        #expect(rows[0].state == "R")
        #expect(rows[1].ppid == parent.pid)
        #expect(rows[1].pgid == parent.pid)
        #expect(rows[1].sid == parent.pid)
        #expect(rows[1].name == "child")
        #expect(rows[1].state == "S")
        // Freshly allocated (never scheduled, no descriptors opened): both the
        // CPU-activity proxy and the descriptor count start at zero.
        #expect(rows[0].ticks == 0)
        #expect(rows[0].fds == 0)
        #expect(rows[1].ticks == 0)
        #expect(rows[1].fds == 0)
    }

    /// End to end: the scheduler bumps a process's tick count each time it runs
    /// it, and open descriptors show up in the `FDS` column — the deterministic
    /// CPU/footprint proxies surfaced by `/proc/processes` (and thus `ps`/`top`).
    @Test func procProcessesReportsTicksAndOpenDescriptors() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        kernel.spawn("worker") { ctx in
            _ = ctx.open("/proc/processes")   // hold one descriptor open
            ctx.sleep(10) { ctx.exit(0) }     // park so the reader sees it live
        }
        final class Box { var line = "" }
        let box = Box()
        kernel.spawn("reader") { ctx in
            guard let fd = ctx.open("/proc/processes") else { return }
            let text = String(decoding: ctx.read(fd, max: 65535), as: UTF8.self)
            ctx.close(fd)
            for row in text.split(separator: "\n") where row.hasSuffix(" worker") {
                box.line = String(row)
            }
        }
        loop.advance(by: 0)

        // Columns: PID PPID PGID SID STATE TICKS FDS NAME
        let cols = box.line.split(separator: " ").map(String.init)
        #expect(cols.count == 8)
        #expect((Int(cols[5]) ?? 0) >= 1)   // TICKS: worker ran at least its body step
        #expect((Int(cols[6]) ?? 0) >= 1)   // FDS: the descriptor it left open
    }

    @Test func stateNamesMatchLinuxProcConventions() {
        #expect(ProcessIntrospection.stateName(.runnable) == "R")
        #expect(ProcessIntrospection.stateName(.running) == "R")
        #expect(ProcessIntrospection.stateName(.blocked) == "S")
        #expect(ProcessIntrospection.stateName(.stopped) == "T")
        #expect(ProcessIntrospection.stateName(.zombie(status: .exited(0))) == "Z")
    }
}
