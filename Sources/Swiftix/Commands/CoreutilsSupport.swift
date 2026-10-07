/// Shared helpers for the coreutils-style built-ins: line splitting,
/// disk-usage/byte formatting, the normal-format diff, `top` rendering, the
/// signal table, and small formatting utilities. Input/output plumbing lives in
/// `CommandIO.swift`; `printf`-style formatting in `PrintfSupport.swift`.
extension BuiltinCommands {

    // MARK: - Shared helpers

    /// Sum the bytes of every regular file under `path` (the whole subtree,
    /// walked on an explicit worklist). Synthetic `/proc` is skipped by default
    /// so `df`/`free` report real disk content, not computed procfs sizes.
    static func totalFileBytes(_ ctx: ProcessContext, under path: String, skipProc: Bool = true) -> Int64 {
        guard let entries = ctx.listDirectory(path) else {
            return Int64(ctx.stat(path)?.size ?? 0)
        }
        var total: Int64 = 0
        var pending = [(path: path, entries: entries)]
        while let (path, entries) = pending.popLast() {
            for entry in entries {
                let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
                let child = path == "/" ? "/" + name : path + "/" + name
                if skipProc, child == "/proc" { continue }
                if entry.hasSuffix("/"), let listing = ctx.listDirectory(child) {
                    pending.append((child, listing))
                } else {
                    total += Int64(ctx.stat(child)?.size ?? 0)
                }
            }
        }
        return total
    }

    /// Human-readable byte count (e.g. `4.0K`, `1.2M`), used by `du`/`df`/`free`.
    static func humanBytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        let gib = 1024.0 * 1024 * 1024, mib = 1024.0 * 1024, kib = 1024.0
        if value >= gib { return fixedPoint(value / gib, places: 1) + "G" }
        if value >= mib { return fixedPoint(value / mib, places: 1) + "M" }
        if value >= kib { return fixedPoint(value / kib, places: 1) + "K" }
        return "\(bytes)"
    }

    /// Produce a classic normal-diff edit script comparing `a` to `b`, or the
    /// empty string when they are identical. Uses a longest-common-subsequence
    /// alignment, then groups the deletions/insertions into `a`/`d`/`c` hunks.
    static func normalDiff(_ a: [String], _ b: [String]) -> String {
        let ops = diffOperations(a, b)

        func range(_ start: Int, _ end: Int) -> String { start == end ? "\(start)" : "\(start),\(end)" }

        var out = ""
        var line1 = 0, line2 = 0          // 1-based counts of lines consumed
        var index = 0
        while index < ops.count {
            if ops[index] == .same { line1 += 1; line2 += 1; index += 1; continue }
            // Gather a maximal run of deletes then inserts (a change when both).
            var deleted: [String] = []
            var inserted: [String] = []
            let delStart = line1 + 1, insStart = line2 + 1
            while index < ops.count, ops[index] == .delete { deleted.append(a[line1]); line1 += 1; index += 1 }
            while index < ops.count, ops[index] == .insert { inserted.append(b[line2]); line2 += 1; index += 1 }
            if !deleted.isEmpty, !inserted.isEmpty {
                out += "\(range(delStart, line1))c\(range(insStart, line2))\n"
                for line in deleted { out += "< \(line)\n" }
                out += "---\n"
                for line in inserted { out += "> \(line)\n" }
            } else if !deleted.isEmpty {
                out += "\(range(delStart, line1))d\(line2)\n"
                for line in deleted { out += "< \(line)\n" }
            } else {
                out += "\(line1)a\(range(insStart, line2))\n"
                for line in inserted { out += "> \(line)\n" }
            }
        }
        return out
    }

    /// Read a whole regular-file descriptor to EOF. Synchronous: a regular file
    /// never blocks, and returns an empty read at end of file.
    static func readFully(_ ctx: ProcessContext, _ fd: Int) -> [UInt8] {
        var out: [UInt8] = []
        while true {
            let chunk = ctx.read(fd, max: 65536)
            if chunk.isEmpty { break }
            out.append(contentsOf: chunk)
        }
        return out
    }

    /// Render one `top` frame: a summary header (logical uptime + a task-state
    /// breakdown) followed by the process table, sourced live from the same
    /// synthetic /proc/processes file `ps` reads. Returns plain text with no
    /// screen-clearing escapes — the interactive loop prepends those itself.
    static func renderTop(_ ctx: ProcessContext) -> String {
        // Namespace-aware listing (same columns as /proc/processes), so `top`
        // inside an `unshare -p` namespace shows only the contained processes.
        let text = String(decoding: ctx.namespaceProcessListing(), as: UTF8.self)

        // Columns: PID PPID PGID SID STATE TICKS FDS MEM NAME (NAME is the
        // space-tolerant tail). MEM is exact managed-runtime memory, not RSS.
        var rows: [(pid: String, ppid: String, state: String, ticks: String,
                   fds: String, memory: String, name: String)] = []
        var counts: [String: Int] = [:]
        for (lineIndex, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            if lineIndex == 0 { continue }   // skip the header row
            let cols = rawLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 9 else { continue }
            let state = cols[4]
            rows.append((pid: cols[0], ppid: cols[1], state: state,
                         ticks: cols[5], fds: cols[6], memory: cols[7],
                         name: cols[8...].joined(separator: " ")))
            counts[state, default: 0] += 1
        }

        let uptime = Double(ctx.monotonicNanoseconds) / 1_000_000_000
        var out = "top - up \(uptime)s\n"
        out += "Tasks: \(rows.count) total, "
             + "\(counts["R"] ?? 0) running, "
             + "\(counts["S"] ?? 0) sleeping, "
             + "\(counts["T"] ?? 0) stopped, "
             + "\(counts["Z"] ?? 0) zombie\n\n"
        out += "\(topPad("PID", 5)) \(topPad("PPID", 5)) S \(topPad("TICKS", 6)) "
            + "\(topPad("FDS", 4)) \(topPad("MEM", 8)) NAME\n"
        for row in rows {
            out += "\(topPad(row.pid, 5)) \(topPad(row.ppid, 5)) \(row.state) "
                 + "\(topPad(row.ticks, 6)) \(topPad(row.fds, 4)) "
                 + "\(topPad(row.memory, 8)) \(row.name)\n"
        }
        return out
    }

    /// Right-justify `text` in a field `width` wide (no truncation when longer),
    /// so `top`'s PID/PPID columns line up.
    static func topPad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    /// Split raw bytes into lines, dropping a single trailing newline so a file
    /// ending in "\n" does not yield a spurious empty final line.
    static func splitLines(_ data: [UInt8]) -> [String] {
        var text = Substring(String(decoding: data, as: UTF8.self))
        if text.hasSuffix("\n") { text = text.dropLast() }
        if text.isEmpty { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Join lines back into text with a trailing newline (empty input -> "").
    static func joinLines(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// The Linux signal table (number, name without the `SIG` prefix) used by
    /// `kill -l` and for name lookup. The kernel acts on the job-control and
    /// termination signals it models; the remaining numbers are accepted and
    /// delivered with the default (terminating) disposition.
    static let signalTable: [(number: Int32, name: String)] = [
        (1, "HUP"), (2, "INT"), (3, "QUIT"), (4, "ILL"), (5, "TRAP"), (6, "ABRT"), (7, "BUS"),
        (8, "FPE"), (9, "KILL"), (10, "USR1"), (11, "SEGV"), (12, "USR2"), (13, "PIPE"),
        (14, "ALRM"), (15, "TERM"), (16, "STKFLT"), (17, "CHLD"), (18, "CONT"), (19, "STOP"),
        (20, "TSTP"), (21, "TTIN"), (22, "TTOU"), (23, "URG"), (24, "XCPU"), (25, "XFSZ"),
        (26, "VTALRM"), (27, "PROF"), (28, "WINCH"), (29, "IO"), (30, "PWR"), (31, "SYS"),
    ]

    /// Map a signal specification to its number: a name with or without the
    /// `SIG` prefix (case-insensitive), or a decimal number. For `kill -NAME`,
    /// `kill -s NAME`, `timeout -s`, `pkill -NAME`.
    static func signalNumber(forName name: String) -> Int32? {
        if let number = Int32(name) { return (0...64).contains(number) ? number : nil }
        var upper = name.uppercased()
        if upper.hasPrefix("SIG") { upper.removeFirst(3) }
        return signalTable.first { $0.name == upper }?.number
    }

    /// The name (without `SIG`) of a signal number, if it has one.
    static func signalName(_ number: Int32) -> String? {
        signalTable.first { $0.number == number }?.name
    }

    // MARK: - Formatting helpers (Linux coreutils style)

    /// Format a `FileMode` as a `rwxrwxrwx` string (9 characters), used by
    /// `ls -l` and `stat`.
    static func modeString(_ mode: FileMode) -> String {
        var s = ""
        s += mode.contains(.ownerRead)    ? "r" : "-"
        s += mode.contains(.ownerWrite)   ? "w" : "-"
        s += mode.contains(.ownerExecute) ? "x" : "-"
        s += mode.contains(.groupRead)    ? "r" : "-"
        s += mode.contains(.groupWrite)   ? "w" : "-"
        s += mode.contains(.groupExecute) ? "x" : "-"
        s += mode.contains(.otherRead)    ? "r" : "-"
        s += mode.contains(.otherWrite)   ? "w" : "-"
        s += mode.contains(.otherExecute) ? "x" : "-"
        return s
    }

    /// Right-pad `text` to at least `width` characters.
    static func padRight(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// Right-justify `text` to at least `width` characters (left-pad with spaces).
    static func padLeft(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

}
