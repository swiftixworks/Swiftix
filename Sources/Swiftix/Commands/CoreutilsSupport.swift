/// Shared helpers for the coreutils-style built-ins: input collection, line
/// splitting, disk-usage/byte formatting, the LCS diff, the `sed` substitution
/// parser/applier, `top` rendering, and small parsing utilities.
extension BuiltinCommands {

    // MARK: - Shared helpers

    /// Sum the bytes of every regular file under `path` (recursively). Synthetic
    /// `/proc` is skipped by default so `df`/`free` report real disk content, not
    /// computed procfs sizes.
    static func totalFileBytes(_ ctx: ProcessContext, under path: String, skipProc: Bool = true) -> Int64 {
        guard let entries = ctx.listDirectory(path) else {
            return Int64(ctx.stat(path)?.size ?? 0)
        }
        var total: Int64 = 0
        for entry in entries {
            let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            let child = path == "/" ? "/" + name : path + "/" + name
            if skipProc, child == "/proc" { continue }
            if entry.hasSuffix("/") {
                total += totalFileBytes(ctx, under: child, skipProc: skipProc)
            } else {
                total += Int64(ctx.stat(child)?.size ?? 0)
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
        // LCS length table.
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        // Forward walk producing same / delete / insert operations.
        enum Op { case same, delete, insert }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { ops.append(.same); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { ops.append(.delete); i += 1 }
            else { ops.append(.insert); j += 1 }
        }
        while i < n { ops.append(.delete); i += 1 }
        while j < m { ops.append(.insert); j += 1 }

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

    /// Drain stdin (fd 0) to EOF via the blocking read pump, then deliver it. The
    /// process parks between reads (no busy-wait); EOF is an empty read (a closed
    /// pipe's write end, e.g. the upstream stage of a pipeline exiting).
    static func pumpStdin(_ ctx: ProcessContext, _ done: @escaping (_ data: [UInt8]) -> Void) {
        var buffer: [UInt8] = []
        func step() {
            ctx.read(0) { bytes in
                if bytes.isEmpty { done(buffer); return }
                buffer.append(contentsOf: bytes)
                step()
            }
        }
        step()
    }

    /// The standard filter input rule: read each named file (in order), or, with
    /// no files, read stdin. A `-` operand names standard input, so it can be mixed
    /// with files and appear more than once. Missing files report to stderr and set
    /// a non-zero status but do not abort. Delivers the concatenated bytes plus the
    /// status.
    static func collectInput(_ ctx: ProcessContext,
                             cmd: String,
                             files: [String],
                             _ done: @escaping (_ data: [UInt8], _ status: Int32) -> Void) {
        if files.isEmpty {
            pumpStdin(ctx) { done($0, 0) }
            return
        }
        var data: [UInt8] = []
        var status: Int32 = 0
        var remaining = files[...]

        // Operands are consumed in order so `cmd a - b` reads `a`, then standard
        // input, then `b`, the way coreutils does. Runs of ordinary files are read
        // in a loop and only a `-` yields to a continuation, so the recursion depth
        // tracks the number of `-` operands rather than the number of files.
        func consume() {
            while let file = remaining.first {
                remaining = remaining.dropFirst()
                if file == "-" {
                    pumpStdin(ctx) { bytes in
                        data.append(contentsOf: bytes)
                        consume()
                    }
                    return
                }
                guard let fd = ctx.open(file) else {
                    ctx.error("\(cmd): \(file): No such file")
                    status = 1
                    continue
                }
                data.append(contentsOf: readFully(ctx, fd))
                ctx.close(fd)
            }
            done(data, status)
        }
        consume()
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

    /// A parsed `sed` substitution command (`s/pattern/replacement/flags`).
    struct SedSubstitution {
        let pattern: String
        let replacement: String
        let global: Bool
        let ignoreCase: Bool
        let print: Bool
    }

    /// Parse an `s<delim>pattern<delim>replacement<delim>flags` script. The
    /// delimiter is whatever character follows `s`; a `\`-escaped delimiter inside
    /// the pattern or replacement is treated as a literal. Returns `nil` if the
    /// script is not a well-formed substitution.
    static func parseSedSubstitution(_ script: String) -> SedSubstitution? {
        let chars = Array(script)
        guard chars.count >= 2, chars[0] == "s" else { return nil }
        let delimiter = chars[1]

        // Split into the three delimiter-separated fields, honoring `\<delim>`.
        var fields: [String] = []
        var current = ""
        var index = 2
        while index < chars.count {
            let character = chars[index]
            if character == "\\", index + 1 < chars.count, chars[index + 1] == delimiter {
                current.append(delimiter)      // escaped delimiter → literal
                index += 2
                continue
            }
            if character == delimiter {
                fields.append(current)
                current = ""
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        fields.append(current)                 // trailing field (flags)

        guard fields.count == 3 else { return nil }   // need pattern, replacement, flags
        let pattern = fields[0]
        let replacement = fields[1]
        guard !pattern.isEmpty else { return nil }

        var global = false, ignoreCase = false, printLine = false
        for flag in fields[2] {
            switch flag {
            case "g": global = true
            case "i", "I": ignoreCase = true
            case "p": printLine = true
            default: return nil                // unknown flag
            }
        }
        return SedSubstitution(pattern: pattern, replacement: replacement,
                               global: global, ignoreCase: ignoreCase, print: printLine)
    }

    /// Apply a substitution to one line, returning the edited line and whether any
    /// match was replaced. `&` in the replacement expands to the matched text;
    /// `\&` and `\\` are literal.
    static func applySed(regex: Regex, replacement: String, global: Bool, line: String) -> (String, Bool) {
        let chars = Array(line)
        var result = ""
        var index = 0
        var didSubstitute = false
        while index <= chars.count {
            guard let range = regex.firstMatch(in: chars, from: index) else { break }
            result += String(chars[index..<range.lowerBound])            // text before the match
            result += expandSedReplacement(replacement, matched: String(chars[range]))
            didSubstitute = true
            if range.isEmpty {
                // Zero-width match: emit one character so the scan makes progress.
                if range.upperBound < chars.count { result.append(chars[range.upperBound]) }
                index = range.upperBound + 1
            } else {
                index = range.upperBound
            }
            if !global { break }
        }
        if index < chars.count { result += String(chars[index...]) }     // untouched remainder
        return (result, didSubstitute)
    }

    /// Expand a `sed` replacement string: `&` → the matched text, `\&` → literal
    /// `&`, `\\` → literal backslash, other `\x` → `x`.
    static func expandSedReplacement(_ replacement: String, matched: String) -> String {
        var out = ""
        let chars = Array(replacement)
        var index = 0
        while index < chars.count {
            let character = chars[index]
            if character == "\\", index + 1 < chars.count {
                out.append(chars[index + 1])   // \x → x (covers \& and \\)
                index += 2
            } else if character == "&" {
                out += matched
                index += 1
            } else {
                out.append(character)
                index += 1
            }
        }
        return out
    }

    /// Parse a leading `-n N` (or `-N`) line-count option; returns the count and
    /// the remaining file arguments. Used by `head`/`tail`.
    static func parseLineCount(_ argv: [String], default defaultCount: Int) -> (count: Int, files: [String]) {
        var args = Array(argv.dropFirst())
        var count = defaultCount
        if args.first == "-n", args.count >= 2, let n = Int(args[1]) {
            count = max(0, n)
            args.removeFirst(2)
        } else if let first = args.first, first.hasPrefix("-"), let n = Int(first.dropFirst()) {
            count = max(0, n)
            args.removeFirst()
        }
        return (count, args)
    }

    /// Map a signal name (without the `SIG` prefix, case-insensitive) to its
    /// number, for `kill -NAME`.
    static func signalNumber(forName name: String) -> Int32? {
        switch name.uppercased() {
        case "INT", "SIGINT":   return Signal.sigint.rawValue
        case "KILL", "SIGKILL": return Signal.sigkill.rawValue
        case "PIPE", "SIGPIPE": return Signal.sigpipe.rawValue
        case "TERM", "SIGTERM": return Signal.sigterm.rawValue
        case "CHLD", "SIGCHLD": return Signal.sigchld.rawValue
        case "CONT", "SIGCONT": return Signal.sigcont.rawValue
        case "STOP", "SIGSTOP": return Signal.sigstop.rawValue
        case "TSTP", "SIGTSTP": return Signal.sigtstp.rawValue
        default: return nil
        }
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

    /// The single-character type prefix for `ls -l` (`d`, `l`, `p`, or `-`).
    static func fileTypeChar(_ type: FileType) -> Character {
        switch type {
        case .directory: return "d"
        case .symlink:   return "l"
        case .regular:   return "-"
        case .fifo:      return "p"
        }
    }

    /// Right-pad `text` to at least `width` characters.
    static func padRight(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// Right-justify `text` to at least `width` characters (left-pad with spaces).
    static func padLeft(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    /// A minimal printf: `%s`, `%d`, `%%`, and `\n` `\t` `\\` escapes. Extra
    /// arguments are ignored; missing ones expand to empty / 0.
    static func formatPrintf(_ format: String, _ args: [String]) -> String {
        var out = ""
        var argIndex = 0
        let chars = Array(format)
        var i = 0
        func nextArg() -> String { defer { argIndex += 1 }; return argIndex < args.count ? args[argIndex] : "" }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                switch chars[i + 1] {
                case "n": out += "\n"
                case "t": out += "\t"
                case "\\": out += "\\"
                default: out.append(chars[i + 1])
                }
                i += 2
            } else if c == "%", i + 1 < chars.count {
                switch chars[i + 1] {
                case "s": out += nextArg()
                case "d": out += "\(Int(nextArg()) ?? 0)"
                case "%": out += "%"
                default: out.append(chars[i + 1])
                }
                i += 2
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }
}
