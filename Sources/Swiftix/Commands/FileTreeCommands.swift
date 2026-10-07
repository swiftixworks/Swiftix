/// Tree-walking and file-inspection built-ins (category .fileSystem): find, du,
/// tree, file, diff. They share the typed directory enumeration in
/// `CommandFileSupport.swift`, so an unreadable directory is reported with its
/// real errno text instead of being skipped silently.
///
/// Concurrency: `async` programs over `ProcessContext` on the single loop-bound
/// executor. `find -exec` awaits each child through the wait syscall; nothing
/// here blocks or spins.
/// A directory `du` is summing, on its explicit walk stack. File scope for the
/// same reason as `RemovalStep`.
private struct UsageWalkDirectory {
    let path: String
    let depth: Int
    let entries: [FileSystemDirectoryEntry]
    var next = 0
    var total: Int64 = 0
}

/// A directory `tree` is listing, on its explicit walk stack.
private struct TreeWalkDirectory {
    let path: String
    let prefix: String
    let level: Int
    let entries: [FileSystemDirectoryEntry]
    var next = 0
}

extension BuiltinCommands {

    static func fileTreeCommands() -> [Command] {
        [
            Command(name: "find", summary: "search a directory tree", category: .fileSystem,
                    usage: """
                    find [PATH...] [EXPRESSION]
                    Tests:
                      -name PATTERN    base name matches the shell PATTERN (-iname: ignore case)
                      -path PATTERN    whole path matches PATTERN (-ipath: ignore case)
                      -type f|d|l|p    regular file, directory, symbolic link, or fifo
                      -size [+-]N[ckMG]  size in 512-byte blocks, or bytes/KiB/MiB/GiB
                      -newer FILE      modified more recently than FILE
                      -mmin [+-]N      modified N minutes ago (-mtime: days)
                      -empty           empty file or directory
                      -perm MODE       permission bits are exactly MODE (-MODE: all set)
                      -user NAME|UID   owned by the user
                    Options:
                      -maxdepth N      descend at most N levels below the start points
                      -mindepth N      do not apply tests above level N
                      -depth           process a directory's contents before the directory
                    Actions:
                      -print           print the path (the default action)
                      -print0          print the path followed by a NUL
                      -delete          remove the file (implies -depth)
                      -exec CMD {} ;   run CMD once per file ({} is the path)
                      -exec CMD {} +   run CMD with as many paths as possible
                      -prune           do not descend into the directory
                      -quit            exit immediately
                    Operators: ( EXPR )  ! EXPR  EXPR -a EXPR  EXPR -o EXPR
                    """, asyncRun: { ctx, argv in
                await findCommand(ctx, Array(argv.dropFirst()))
            }),

            // du [-s] [-h] [-a] [-b] [-c] [-d N] [path...] — summarize disk usage of
            // directory trees. Sizes are the summed bytes of regular files
            // (directories add nothing themselves). Default reports one line per
            // directory in post-order plus the total; `-s` prints only each
            // operand's total, `-a` also lists files, `-d N` limits the depth of
            // reported lines, `-h` uses human units, `-b` exact bytes (default is
            // 1K blocks), `-c` adds a grand total.
            Command(name: "du", summary: "summarize disk usage of a tree", category: .fileSystem,
                    usage: """
                    du [-sahbkc] [-d N] [FILE]...
                      -s    display only a total for each argument
                      -a    write counts for all files, not just directories
                      -d N  print totals only for directories N or fewer levels deep
                      -h    print sizes in human readable format (e.g. 1.0K)
                      -b    print sizes in bytes
                      -k    print sizes in 1K blocks (the default)
                      -c    produce a grand total
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("du", Array(argv.dropFirst()), "sahbkcd:xL",
                                               long: ["summarize": "s", "all": "a", "human-readable": "h",
                                                      "bytes": "b", "total": "c",
                                                      "max-depth": "d"]) else { return }
                var maxDepth = Int.max
                if let text = parsed.value("d") {
                    guard let depth = Int(text), depth >= 0 else {
                        ctx.fail("du: invalid maximum depth '\(text)'", code: 1); return
                    }
                    maxDepth = depth
                }
                if parsed.has("s") {
                    if parsed.has("a") {
                        ctx.fail("du: cannot both summarize and show all entries", code: 1); return
                    }
                    maxDepth = 0
                }
                func format(_ n: Int64) -> String {
                    if parsed.has("h") { return humanBytes(n) }
                    if parsed.has("b") { return "\(n)" }
                    return "\((n + 1023) / 1024)"           // default: 1K blocks, rounded up
                }
                var out = ""
                var status: Int32 = 0
                // Post-order walk: subdirectories print before their parent. The
                // directories being summed sit on an explicit stack, innermost
                // last, so nesting depth does not consume host stack.
                func walk(_ root: String) -> Int64 {
                    var open: [UsageWalkDirectory] = []
                    /// The size of a non-directory, or `nil` after opening a directory.
                    func enter(_ path: String, depth: Int) -> Int64? {
                        guard let info = ctx.lstat(path) else { return 0 }
                        guard info.isDirectory else {
                            let size = info.type == .regular ? Int64(info.size) : 0
                            if parsed.has("a") || depth == 0, depth <= maxDepth { out += "\(format(size))\t\(path)\n" }
                            return size
                        }
                        var entries: [FileSystemDirectoryEntry] = []
                        do {
                            entries = try ctx.directoryEntries(path)
                        } catch {
                            ctx.error("du: cannot read directory '\(path)': \(errnoText(error))")
                            status = 1
                        }
                        open.append(UsageWalkDirectory(path: path, depth: depth, entries: entries))
                        return nil
                    }
                    if let size = enter(root, depth: 0) { return size }
                    while true {
                        let top = open.count - 1
                        let directory = open[top]
                        if directory.next < directory.entries.count {
                            open[top].next += 1
                            let child = ctx.join(directory.path, directory.entries[directory.next].name)
                            if let size = enter(child, depth: directory.depth + 1) { open[top].total += size }
                            continue
                        }
                        open.removeLast()
                        if directory.depth <= maxDepth { out += "\(format(directory.total))\t\(directory.path)\n" }
                        guard !open.isEmpty else { return directory.total }
                        open[open.count - 1].total += directory.total
                    }
                }
                var grandTotal: Int64 = 0
                for root in parsed.operands.isEmpty ? ["."] : parsed.operands {
                    guard ctx.lstat(root) != nil else {
                        ctx.error("du: cannot access '\(root)': \(ctx.missingReason(root).message)")
                        status = 1
                        continue
                    }
                    grandTotal += walk(root)
                }
                if parsed.has("c") { out += "\(format(grandTotal))\ttotal\n" }
                await ctx.emit(out, exit: status)
            }),

            Command(name: "tree", summary: "list a directory tree", category: .fileSystem,
                    usage: """
                    tree [-adf] [-L LEVEL] [DIRECTORY]...
                      -a        include hidden files
                      -d        list directories only
                      -f        print the full path prefix for each file
                      -L LEVEL  descend only LEVEL directories deep
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("tree", Array(argv.dropFirst()), "adfL:",
                                               long: [:]) else { return }
                var maxLevel = Int.max
                if let text = parsed.value("L") {
                    guard let level = Int(text), level > 0 else {
                        ctx.fail("tree: Invalid level, must be greater than 0.", code: 1); return
                    }
                    maxLevel = level
                }
                var out = ""
                var directories = 0, files = 0
                var status: Int32 = 0
                // The directories being listed sit on an explicit stack,
                // innermost last, so nesting depth does not consume host stack.
                func walk(_ root: String) {
                    var open: [TreeWalkDirectory] = []
                    func enter(_ path: String, prefix: String, level: Int) {
                        guard level <= maxLevel else { return }
                        let entries: [FileSystemDirectoryEntry]
                        do {
                            entries = try ctx.directoryEntries(path).filter {
                                (parsed.has("a") || !$0.name.hasPrefix(".")) && (!parsed.has("d") || $0.type == .directory)
                            }
                        } catch {
                            out += "\(prefix)[error opening dir: \(errnoText(error))]\n"
                            return
                        }
                        open.append(TreeWalkDirectory(path: path, prefix: prefix, level: level, entries: entries))
                    }
                    enter(root, prefix: "", level: 1)
                    while let directory = open.last {
                        guard directory.next < directory.entries.count else { open.removeLast(); continue }
                        open[open.count - 1].next += 1
                        let entry = directory.entries[directory.next]
                        let last = directory.next == directory.entries.count - 1
                        let full = ctx.join(directory.path, entry.name)
                        var label = parsed.has("f") ? full : entry.name
                        if entry.type == .symlink, let target = ctx.readlink(full) { label += " -> " + target }
                        out += directory.prefix + (last ? "└── " : "├── ") + label + "\n"
                        if entry.type == .directory {
                            directories += 1
                            enter(full, prefix: directory.prefix + (last ? "    " : "│   "), level: directory.level + 1)
                        } else {
                            files += 1
                        }
                    }
                }
                for root in parsed.operands.isEmpty ? ["."] : parsed.operands {
                    guard ctx.stat(root)?.isDirectory == true else {
                        out += "\(root)  [error opening dir]\n"
                        status = 2
                        continue
                    }
                    out += root + "\n"
                    walk(root)
                }
                out += "\n\(directories) director\(directories == 1 ? "y" : "ies")"
                if !parsed.has("d") { out += ", \(files) file\(files == 1 ? "" : "s")" }
                out += "\n"
                await ctx.emit(out, exit: status)
            }),

            Command(name: "file", summary: "determine file type", category: .fileSystem,
                    usage: """
                    file [-bL] FILE...
                      -b  brief: do not prepend file names
                      -L  follow symbolic links
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("file", Array(argv.dropFirst()), "bLhi",
                                               long: ["brief": "b", "dereference": "L"]) else { return }
                guard !parsed.operands.isEmpty else {
                    ctx.fail("Usage: file [-bL] FILE...", code: 1); return
                }
                var out = ""
                let nameWidth = (parsed.operands.map(\.count).max() ?? 0) + 1
                for path in parsed.operands {
                    let description: String
                    if let info = parsed.has("L") ? ctx.stat(path) : ctx.lstat(path) {
                        if info.isDirectory {
                            description = "directory"
                        } else if info.type == .symlink {
                            let target = ctx.readlink(path) ?? "?"
                            description = (ctx.stat(path) == nil ? "broken symbolic link to " : "symbolic link to ") + target
                        } else if info.type == .fifo {
                            description = "fifo (named pipe)"
                        } else if info.size == 0 {
                            description = "empty"
                        } else if let fd = try? ctx.openFile(path) {
                            let head = (try? await ctx.read(fd, upTo: 4096)) ?? []
                            ctx.close(fd)
                            description = describeContents(head)
                        } else {
                            description = "regular file, no read permission"
                        }
                    } else {
                        description = "cannot open '\(path)' (\(SyscallError.noSuchFileOrDirectory.message))"
                    }
                    out += parsed.has("b") ? description + "\n"
                                           : padRight(path + ":", nameWidth) + " " + description + "\n"
                }
                await ctx.emit(out, exit: 0)
            }),

            // diff [-u] [-q] FILE1 FILE2 — compare two files line by line, printing
            // the classic normal-diff edit script (`a`/`d`/`c` hunks with `<`/`>`
            // lines) or, with -u, unified hunks with three lines of context.
            // Exit 0 when identical, 1 when they differ, 2 on error.
            Command(name: "diff", summary: "compare two files line by line", category: .fileSystem,
                    usage: """
                    diff [-uqs] [-U NUM] FILE1 FILE2
                      -u      output unified diff with 3 lines of context
                      -U NUM  output unified diff with NUM lines of context
                      -q      report only whether the files differ
                      -s      report when two files are identical
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("diff", Array(argv.dropFirst()), "uqsU:",
                                               long: ["unified": "u", "brief": "q",
                                                      "report-identical-files": "s"]) else { return }
                let args = parsed.operands
                guard args.count == 2 else {
                    ctx.error(args.count < 2 ? "diff: missing operand after '\(args.last ?? "diff")'"
                                             : "diff: extra operand '\(args[2])'")
                    ctx.fail("Try 'diff --help' for more information."); return
                }
                var context = 3
                if let text = parsed.value("U") {
                    guard let value = Int(text), value >= 0 else {
                        ctx.fail("diff: invalid context length '\(text)'"); return
                    }
                    context = value
                }
                var contents: [[UInt8]] = []
                for path in args {
                    do {
                        contents.append(try await readOperand(ctx, path))
                    } catch {
                        ctx.fail("diff: \(path): \(errnoText(error))"); return
                    }
                }
                if contents[0] == contents[1] {
                    if parsed.has("s") { ctx.print("Files \(args[0]) and \(args[1]) are identical\n") }
                    ctx.exit(0)
                    return
                }
                if parsed.has("q") {
                    await ctx.emit("Files \(args[0]) and \(args[1]) differ\n", exit: 1)
                    return
                }
                let a = splitLines(contents[0]), b = splitLines(contents[1])
                let output: String
                if parsed.has("u") || parsed.has("U") {
                    output = "--- \(args[0])\n+++ \(args[1])\n" + unifiedDiff(a, b, context: context)
                } else {
                    output = normalDiff(a, b)
                }
                await ctx.emit(output, exit: 1)
            }),
        ]
    }

    /// A one-line description of file contents from their leading bytes — the
    /// magic-number and text heuristics behind `file`.
    static func describeContents(_ head: [UInt8]) -> String {
        func starts(_ magic: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + magic.count && Array(head[offset..<(offset + magic.count)]) == magic
        }
        if starts(Array("\u{7f}SWIFTIXGO".utf8)) { return "Swiftix Go executable" }
        if starts([0x7F, 0x45, 0x4C, 0x46]) { return "ELF executable" }
        if starts([0x1F, 0x8B]) { return "gzip compressed data" }
        if starts(Array("ustar".utf8), at: 257) { return "POSIX tar archive" }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "PNG image data" }
        if starts([0xFF, 0xD8, 0xFF]) { return "JPEG image data" }
        if starts(Array("%PDF-".utf8)) { return "PDF document" }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return "Zip archive data" }
        if starts(Array("GIF8".utf8)) { return "GIF image data" }
        // Text: no NUL or stray control bytes; UTF-8 when it decodes cleanly.
        let isBinary = head.contains { $0 == 0 || ($0 < 0x20 && ![0x09, 0x0A, 0x0D, 0x0C, 0x1B, 0x08].contains($0)) }
        if isBinary { return "data" }
        let ascii = head.allSatisfy { $0 < 0x80 }
        if !ascii {
            // A truncated multi-byte sequence at the 4K boundary is not an error.
            var copy = head
            var valid = false
            for _ in 0..<4 {
                if Array(String(decoding: copy, as: UTF8.self).utf8) == copy { valid = true; break }
                if copy.isEmpty { break }
                copy.removeLast()
            }
            if !valid { return "data" }
        }
        let kind = ascii ? "ASCII text" : "UTF-8 Unicode text"
        if starts(Array("#!".utf8)) {
            let firstLine = String(decoding: head.prefix { $0 != 0x0A }, as: UTF8.self)
            let interpreter = firstLine.dropFirst(2).split(separator: " ").first.map(String.init) ?? ""
            return "\(interpreter) script, \(kind) executable"
        }
        let text = String(decoding: head, as: UTF8.self)
        if text.hasPrefix("{") || text.hasPrefix("[") , text.contains("\""), text.contains(":") { return "JSON text data" }
        if text.hasPrefix("<?xml") { return "XML 1.0 document, \(kind)" }
        if text.hasPrefix("<!DOCTYPE html") || text.hasPrefix("<html") { return "HTML document, \(kind)" }
        if text.hasPrefix("package ") , text.contains("\nfunc ") { return "Go source, \(kind)" }
        return head.contains(0x0D) && text.contains("\r\n") ? "\(kind), with CRLF line terminators" : kind
    }

    // MARK: - diff

    enum DiffOperation { case same, delete, insert }

    /// The edit script turning `a` into `b`, from a longest-common-subsequence
    /// alignment (deletions before insertions within a change).
    static func diffOperations(_ a: [String], _ b: [String]) -> [DiffOperation] {
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var ops: [DiffOperation] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { ops.append(.same); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { ops.append(.delete); i += 1 }
            else { ops.append(.insert); j += 1 }
        }
        while i < n { ops.append(.delete); i += 1 }
        while j < m { ops.append(.insert); j += 1 }
        return ops
    }

    /// Unified-format hunks (`@@ -l,s +l,s @@`) for `a` → `b` with `context`
    /// lines around each change; empty when the inputs are identical.
    static func unifiedDiff(_ a: [String], _ b: [String], context: Int) -> String {
        let ops = diffOperations(a, b)
        // Lines of each side consumed before every operation.
        var aBefore: [Int] = [], bBefore: [Int] = []
        var i = 0, j = 0
        for op in ops {
            aBefore.append(i)
            bBefore.append(j)
            if op != .insert { i += 1 }
            if op != .delete { j += 1 }
        }
        let changes = ops.indices.filter { ops[$0] != .same }
        guard let first = changes.first else { return "" }
        // Group changes whose context windows touch into one hunk.
        var hunks: [Range<Int>] = []
        var start = max(0, first - context)
        var end = min(ops.count, first + 1 + context)
        for change in changes.dropFirst() {
            if change - context <= end {
                end = min(ops.count, change + 1 + context)
            } else {
                hunks.append(start..<end)
                start = max(0, change - context)
                end = min(ops.count, change + 1 + context)
            }
        }
        hunks.append(start..<end)

        func range(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
        var out = ""
        for hunk in hunks {
            var body = ""
            var count1 = 0, count2 = 0
            for index in hunk {
                switch ops[index] {
                case .same:
                    body += " \(a[aBefore[index]])\n"; count1 += 1; count2 += 1
                case .delete:
                    body += "-\(a[aBefore[index]])\n"; count1 += 1
                case .insert:
                    body += "+\(b[bBefore[index]])\n"; count2 += 1
                }
            }
            let start1 = aBefore[hunk.lowerBound] + (count1 == 0 ? 0 : 1)
            let start2 = bBefore[hunk.lowerBound] + (count2 == 0 ? 0 : 1)
            out += "@@ -\(range(start1, count1)) +\(range(start2, count2)) @@\n" + body
        }
        return out
    }

    // MARK: - find

    /// A parsed `find` expression.
    private indirect enum FindExpression {
        case and(FindExpression, FindExpression)
        case or(FindExpression, FindExpression)
        case not(FindExpression)
        case always(Bool)
        case name(String, ignoreCase: Bool)
        case path(String, ignoreCase: Bool)
        case type(Character)
        case size(comparison: Character, amount: Int, unit: Int)
        case newer(Double)
        case age(comparison: Character, amount: Double, unit: Double)
        case empty
        case perm(bits: UInt16, allOf: Bool)
        case user(UInt32)
        case print(terminator: UInt8)
        case delete
        case exec(words: [String], batch: Bool)
        case prune
        case quit

        var hasAction: Bool {
            switch self {
            case let .and(a, b), let .or(a, b): return a.hasAction || b.hasAction
            case let .not(a): return a.hasAction
            case .print, .delete, .exec, .quit: return true
            default: return false
            }
        }

        var hasDelete: Bool {
            switch self {
            case let .and(a, b), let .or(a, b): return a.hasDelete || b.hasDelete
            case let .not(a): return a.hasDelete
            case .delete: return true
            default: return false
            }
        }
    }

    private struct FindParseError: Error { let message: String }

    /// Recursive-descent parser over the expression words: `or` → `and` → `not`
    /// → primary, with implicit `-a` between adjacent primaries.
    private struct FindParser {
        var words: ArraySlice<String>
        let ctx: ProcessContext
        var maxDepth = Int.max
        var minDepth = 0
        var depthFirst = false

        mutating func parse() throws -> FindExpression? {
            guard !words.isEmpty else { return nil }
            let expression = try parseOr()
            if let extra = words.first {
                throw FindParseError(message: extra == ")" ? "invalid expression; you have too many ')'"
                                                           : "paths must precede expression: `\(extra)'")
            }
            return expression
        }

        private mutating func parseOr() throws -> FindExpression {
            var left = try parseAnd()
            while let word = words.first, word == "-o" || word == "-or" {
                words = words.dropFirst()
                left = .or(left, try parseAnd())
            }
            return left
        }

        private mutating func parseAnd() throws -> FindExpression {
            var left = try parseNot()
            while let word = words.first, word != "-o", word != "-or", word != ")" {
                if word == "-a" || word == "-and" { words = words.dropFirst() }
                left = .and(left, try parseNot())
            }
            return left
        }

        private mutating func parseNot() throws -> FindExpression {
            guard let word = words.first else { throw FindParseError(message: "expected an expression") }
            if word == "!" || word == "-not" {
                words = words.dropFirst()
                return .not(try parseNot())
            }
            if word == "(" {
                words = words.dropFirst()
                let inner = try parseOr()
                guard words.first == ")" else {
                    throw FindParseError(message: "invalid expression; expected to find a ')' but didn't see one")
                }
                words = words.dropFirst()
                return inner
            }
            return try parsePrimary()
        }

        private mutating func argument(_ primary: String) throws -> String {
            guard let value = words.first else {
                throw FindParseError(message: "missing argument to `\(primary)'")
            }
            words = words.dropFirst()
            return value
        }

        private func signed(_ text: String, _ primary: String) throws -> (Character, Substring) {
            var body = Substring(text)
            var comparison: Character = "="
            if let first = body.first, first == "+" || first == "-" {
                comparison = first
                body = body.dropFirst()
            }
            guard !body.isEmpty else { throw FindParseError(message: "invalid argument `\(text)' to `\(primary)'") }
            return (comparison, body)
        }

        private mutating func parsePrimary() throws -> FindExpression {
            let word = words.removeFirst()
            switch word {
            case "-name": return .name(try argument(word), ignoreCase: false)
            case "-iname": return .name(try argument(word), ignoreCase: true)
            case "-path", "-wholename": return .path(try argument(word), ignoreCase: false)
            case "-ipath": return .path(try argument(word), ignoreCase: true)
            case "-type":
                let kind = try argument(word)
                guard kind.count == 1, let letter = kind.first, "fdlp".contains(letter) else {
                    throw FindParseError(message: "Unknown argument to -type: \(kind)")
                }
                return .type(letter)
            case "-maxdepth", "-mindepth":
                let text = try argument(word)
                guard let depth = Int(text), depth >= 0 else {
                    throw FindParseError(message: "Expected a positive decimal integer argument to \(word), but got `\(text)'")
                }
                if word == "-maxdepth" { maxDepth = depth } else { minDepth = depth }
                return .always(true)
            case "-depth":
                depthFirst = true
                return .always(true)
            case "-size":
                let text = try argument(word)
                var (comparison, body) = try signed(text, word)
                var unit = 512
                if let suffix = body.last, !suffix.isNumber {
                    switch suffix {
                    case "c": unit = 1
                    case "w": unit = 2
                    case "b": unit = 512
                    case "k": unit = 1024
                    case "M": unit = 1 << 20
                    case "G": unit = 1 << 30
                    default: throw FindParseError(message: "invalid -size type `\(suffix)'")
                    }
                    body = body.dropLast()
                }
                guard let amount = Int(body) else {
                    throw FindParseError(message: "invalid argument `\(text)' to `-size'")
                }
                return .size(comparison: comparison, amount: amount, unit: unit)
            case "-newer":
                let reference = try argument(word)
                guard let info = ctx.stat(reference) else {
                    throw FindParseError(message: "'\(reference)': \(SyscallError.noSuchFileOrDirectory.message)")
                }
                return .newer(info.mtime)
            case "-mmin", "-mtime":
                let text = try argument(word)
                let (comparison, body) = try signed(text, word)
                guard let amount = Double(body) else {
                    throw FindParseError(message: "invalid argument `\(text)' to `\(word)'")
                }
                return .age(comparison: comparison, amount: amount, unit: word == "-mmin" ? 60 : 86400)
            case "-empty": return .empty
            case "-perm":
                var text = Substring(try argument(word))
                var allOf = false
                if text.hasPrefix("-") { allOf = true; text = text.dropFirst() }
                guard let bits = UInt16(text, radix: 8) else {
                    throw FindParseError(message: "invalid mode `\(text)'")
                }
                return .perm(bits: bits, allOf: allOf)
            case "-user":
                let text = try argument(word)
                guard let uid = ctx.userDatabase().resolveUser(text)?.uid else {
                    throw FindParseError(message: "`\(text)' is not the name of a known user")
                }
                return .user(uid)
            case "-print": return .print(terminator: 0x0A)
            case "-print0": return .print(terminator: 0)
            case "-delete": return .delete
            case "-prune": return .prune
            case "-quit": return .quit
            case "-true": return .always(true)
            case "-false": return .always(false)
            case "-exec", "-ok":
                var command: [String] = []
                var batch = false
                var terminated = false
                while let next = words.first {
                    words = words.dropFirst()
                    if next == ";" { terminated = true; break }
                    if next == "+", command.last == "{}" { terminated = true; batch = true; break }
                    command.append(next)
                }
                guard terminated, !command.isEmpty else {
                    throw FindParseError(message: "missing argument to `\(word)'")
                }
                return .exec(words: command, batch: batch)
            default:
                throw FindParseError(message: word.hasPrefix("-") ? "unknown predicate `\(word)'"
                                                                  : "paths must precede expression: `\(word)'")
            }
        }
    }

    private static func findCommand(_ ctx: ProcessContext, _ args: [String]) async {
        // Start points are the words before the expression begins.
        var roots: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            if word.hasPrefix("-") && word.count > 1 || word == "(" || word == "!" { break }
            roots.append(word)
            index += 1
        }
        if roots.isEmpty { roots = ["."] }
        var parser = FindParser(words: args[index...], ctx: ctx)
        var expression: FindExpression
        do {
            expression = try parser.parse() ?? .print(terminator: 0x0A)
        } catch {
            ctx.error("find: \((error as? FindParseError)?.message ?? "invalid expression")")
            ctx.exit(1)
            return
        }
        if !expression.hasAction { expression = .and(expression, .print(terminator: 0x0A)) }
        let depthFirst = parser.depthFirst || expression.hasDelete
        let now = ctx.realtimeSeconds

        var out: [UInt8] = []
        var status: Int32 = 0
        var pruned = false
        var quit = false
        var alive = true
        var batches: [(words: [String], paths: [String])] = []

        func flush() async {
            guard !out.isEmpty else { return }
            if !(await ctx.put(out)) { alive = false }
            out = []
        }

        func runCommand(_ words: [String]) async -> Bool {
            await flush()
            guard alive else { return false }
            guard let command = ctx.resolveCommand(words[0]) else {
                ctx.error("find: '\(words[0])': \(SyscallError.noSuchFileOrDirectory.message)")
                status = 1
                return false
            }
            ctx.run(command, args: words)
            guard let event = try? await ctx.wait() else { alive = false; return false }
            return event.status.code == 0
        }

        func compare(_ value: Int, _ comparison: Character, _ amount: Int) -> Bool {
            comparison == "+" ? value > amount : (comparison == "-" ? value < amount : value == amount)
        }

        func evaluate(_ expression: FindExpression, _ path: String, _ info: FileStat) async -> Bool {
            switch expression {
            case let .and(a, b):
                guard await evaluate(a, path, info) else { return false }
                return await evaluate(b, path, info)
            case let .or(a, b):
                if await evaluate(a, path, info) { return true }
                return await evaluate(b, path, info)
            case let .not(a):
                return !(await evaluate(a, path, info))
            case let .always(value):
                return value
            case let .name(pattern, ignoreCase):
                return wildcardMatch(pattern, baseName(path), ignoreCase: ignoreCase)
            case let .path(pattern, ignoreCase):
                return wildcardMatch(pattern, path, ignoreCase: ignoreCase)
            case let .type(letter):
                if letter == "d" { return info.isDirectory }
                if letter == "l" { return info.type == .symlink }
                if letter == "p" { return info.type == .fifo }
                return info.type == .regular
            case let .size(comparison, amount, unit):
                return compare((info.size + unit - 1) / unit, comparison, amount)
            case let .newer(reference):
                return info.mtime > reference
            case let .age(comparison, amount, unit):
                let age = ((now - info.mtime) / unit).rounded(.down)
                return comparison == "+" ? age > amount : (comparison == "-" ? age < amount : age == amount)
            case .empty:
                if info.isDirectory { return (try? ctx.directoryEntries(path))?.isEmpty == true }
                return info.type == .regular && info.size == 0
            case let .perm(bits, allOf):
                let mode = info.mode.rawValue & 0o7777
                return allOf ? mode & bits == bits : mode == bits
            case let .user(uid):
                return info.uid == uid
            case let .print(terminator):
                out.append(contentsOf: Array(path.utf8))
                out.append(terminator)
                if out.count > 16 * 1024 { await flush() }
                return true
            case .delete:
                do {
                    if info.isDirectory { try ctx.removeDirectoryOrThrow(path) } else { try ctx.unlinkOrThrow(path) }
                    return true
                } catch {
                    ctx.error("find: cannot delete '\(path)': \(errnoText(error))")
                    status = 1
                    return false
                }
            case let .exec(words, batch):
                if batch {
                    if let slot = batches.firstIndex(where: { $0.words == words }) {
                        batches[slot].paths.append(path)
                    } else {
                        batches.append((words, [path]))
                    }
                    return true
                }
                return await runCommand(words.map { $0.replacing("{}", with: path) })
            case .prune:
                pruned = true
                return true
            case .quit:
                quit = true
                return true
            }
        }

        func visit(_ path: String, depth: Int) async {
            guard alive, !quit, let info = ctx.lstat(path) else { return }
            let applies = depth >= parser.minDepth
            if !depthFirst, applies {
                pruned = false
                _ = await evaluate(expression, path, info)
            }
            if info.isDirectory, depth < parser.maxDepth, !(pruned && !depthFirst), !quit {
                pruned = false
                do {
                    for entry in try ctx.directoryEntries(path) {
                        await visit(ctx.join(path, entry.name), depth: depth + 1)
                        if quit || !alive { return }
                    }
                } catch {
                    ctx.error("find: '\(path)': \(errnoText(error))")
                    status = 1
                }
            }
            pruned = false
            if depthFirst, applies, !quit { _ = await evaluate(expression, path, info) }
        }

        for root in roots {
            guard ctx.lstat(root) != nil else {
                ctx.error("find: '\(root)': \(SyscallError.noSuchFileOrDirectory.message)")
                status = 1
                continue
            }
            await visit(root, depth: 0)
            if quit || !alive { break }
        }
        for batch in batches where alive {
            var words: [String] = []
            for word in batch.words {
                if word == "{}" { words += batch.paths } else { words.append(word) }
            }
            if !(await runCommand(words)) { status = 1 }
        }
        await flush()
        if alive { ctx.exit(status) }
    }
}
