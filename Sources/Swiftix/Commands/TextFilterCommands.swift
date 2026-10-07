/// Text built-ins (category .text): echo/printf/grep/head/tail/wc/sort/uniq/
/// rev/tac/nl/cut/paste/join/comm/tr/fold/expand/column/tee/seq/yes and the
/// pagers more/less. `sed` lives in `SedCommand.swift`; shared helpers live in
/// `CoreutilsSupport.swift` and `CommandIO.swift`.
///
/// Concurrency: `async` programs over `ProcessContext` on the single loop-bound
/// executor. Line-oriented filters read through `CommandInput` and write through
/// `put`, so they stream in pipelines, park on backpressure, and stop as soon as
/// the downstream reader goes away.
extension BuiltinCommands {

    // MARK: - Text filters (category: .text)

    static func textFilters() -> [Command] {
        [
            Command(name: "echo", summary: "print arguments", category: .text,
                    usage: """
                    echo [-neE] [STRING]...
                      -n  do not output the trailing newline
                      -e  interpret backslash escapes (\\n \\t \\\\ \\a \\b \\c \\e \\f \\r \\v \\0NNN \\xHH)
                      -E  do not interpret backslash escapes (the default)
                    """, asyncRun: { ctx, argv in
                var args = argv.dropFirst()
                var newline = true
                var escapes = false
                // Only a leading word made purely of the letters n/e/E is an
                // option; anything else (including `-x` or `--help`) is text.
                while let first = args.first, first.hasPrefix("-"), first.count > 1,
                      first.dropFirst().allSatisfy({ $0 == "n" || $0 == "e" || $0 == "E" }) {
                    for flag in first.dropFirst() {
                        if flag == "n" { newline = false } else { escapes = flag == "e" }
                    }
                    args = args.dropFirst()
                }
                let text = args.joined(separator: " ")
                var bytes: [UInt8]
                if escapes {
                    let expanded = expandEscapes(text, octalNeedsZero: true)
                    bytes = expanded.bytes
                    if expanded.stopped { newline = false }
                } else {
                    bytes = Array(text.utf8)
                }
                if newline { bytes.append(0x0A) }
                await ctx.emit(bytes, exit: 0)
            }),

            Command(name: "printf", summary: "format and print arguments", category: .text,
                    usage: """
                    printf FORMAT [ARGUMENT]...
                    Conversions: %d %i %u %o %x %X %c %s %b %e %f %g %% with the flags
                    - 0 + space #, a width, and a .precision (either may be *).
                    Escapes: \\n \\t \\\\ \\a \\b \\e \\f \\r \\v \\0NNN \\xHH \\c.
                    FORMAT is reused while arguments remain.
                    """, asyncRun: { ctx, argv in
                guard argv.count > 1 else {
                    ctx.error("printf: missing operand")
                    ctx.fail("Try 'printf --help' for more information.", code: 1); return
                }
                var args = Array(argv.dropFirst())
                if args.first == "--" { args.removeFirst() }
                guard let format = args.first else { ctx.exit(0); return }
                let result = formatPrintf(format, Array(args.dropFirst()))
                for message in result.errors { ctx.error("printf: \(message)") }
                await ctx.emit(result.bytes, exit: result.errors.isEmpty ? 0 : 1)
            }),

            Command(name: "grep", summary: "print lines that match patterns", category: .text,
                    usage: """
                    grep [OPTION]... PATTERNS [FILE]...
                      -E      PATTERNS are extended regular expressions
                      -F      PATTERNS are fixed strings
                      -G      PATTERNS are basic regular expressions (the default)
                      -e PAT  use PAT as a pattern (repeatable)
                      -f FILE take patterns from FILE, one per line
                      -i      ignore case
                      -v      select non-matching lines
                      -w      match only whole words
                      -x      match only whole lines
                      -c      print only a count of selected lines per file
                      -l      print only names of files with selected lines
                      -L      print only names of files with no selected lines
                      -o      print only the matched parts of lines
                      -q      suppress all output; exit 0 on the first match
                      -s      suppress error messages about unreadable files
                      -n      prefix each line with its line number
                      -H, -h  print / suppress the file name prefix
                      -r, -R  search directories recursively
                      -m NUM  stop after NUM selected lines
                      -A NUM  print NUM lines of trailing context
                      -B NUM  print NUM lines of leading context
                      -C NUM  print NUM lines of context
                    Exit status is 0 if a line is selected, 1 if not, 2 on error.
                    """, asyncRun: { ctx, argv in
                await grepCommand(ctx, Array(argv.dropFirst()))
            }),

            Command(name: "head", summary: "print the first lines of files", category: .text,
                    usage: """
                    head [-n [-]NUM] [-c [-]NUM] [-qv] [FILE]...
                      -n NUM   print the first NUM lines (default 10); -NUM is a shorthand
                      -n -NUM  print all but the last NUM lines
                      -c NUM   print the first NUM bytes (-c -NUM: all but the last NUM)
                      -q       never print file name headers
                      -v       always print file name headers
                    """, asyncRun: { ctx, argv in
                guard let request = parseHeadTail(ctx, "head", Array(argv.dropFirst())) else { return }
                var status: Int32 = 0
                let files = request.files.isEmpty ? ["-"] : request.files
                let headers = request.verbose || (files.count > 1 && !request.quiet)
                for (index, file) in files.enumerated() {
                    let input = CommandInput(ctx, command: "head", files: [file])
                    var out: [UInt8] = []
                    if request.fromStart {
                        // "All but the last N": needs the whole input.
                        let data = await input.all()
                        if request.bytes {
                            out = Array(data.dropLast(request.count))
                        } else {
                            let lines = splitRawLines(data)
                            out = Array(lines.dropLast(request.count).joined())
                        }
                    } else if request.bytes {
                        while out.count < request.count, let bytes = await input.chunk(max: request.count - out.count) {
                            out += bytes.prefix(request.count - out.count)
                        }
                    } else {
                        var taken = 0
                        while taken < request.count, let line = await input.line() {
                            out += line
                            out.append(0x0A)
                            taken += 1
                        }
                    }
                    if input.status != 0 { status = 1; continue }
                    if headers {
                        let name = file == "-" ? "standard input" : file
                        out = Array(((index > 0 ? "\n" : "") + "==> \(name) <==\n").utf8) + out
                    }
                    guard await ctx.put(out) else { return }
                }
                ctx.exit(status)
            }),

            Command(name: "tail", summary: "print the last lines of files", category: .text,
                    usage: """
                    tail [-n [+]NUM] [-c [+]NUM] [-f] [-s SEC] [-qv] [FILE]...
                      -n NUM   print the last NUM lines (default 10); -NUM is a shorthand
                      -n +NUM  print starting with line NUM
                      -c NUM   print the last NUM bytes (-c +NUM: starting with byte NUM)
                      -f       keep running, printing data appended to the files
                      -s SEC   with -f, check for new data every SEC seconds (default 1)
                      -q       never print file name headers
                      -v       always print file name headers
                    """, asyncRun: { ctx, argv in
                guard let request = parseHeadTail(ctx, "tail", Array(argv.dropFirst())) else { return }
                var status: Int32 = 0
                let files = request.files.isEmpty ? ["-"] : request.files
                let headers = request.verbose || (files.count > 1 && !request.quiet)
                var offsets: [String: Int] = [:]
                var lastHeader: String? = nil
                var printedHeader = false

                func select(_ data: [UInt8]) -> [UInt8] {
                    if request.bytes {
                        return request.fromStart ? Array(data.dropFirst(max(0, request.count - 1)))
                                                 : Array(data.suffix(request.count))
                    }
                    let lines = splitRawLines(data)
                    let chosen = request.fromStart ? lines.dropFirst(max(0, request.count - 1))
                                                   : lines.suffix(request.count)
                    return Array(chosen.joined())
                }
                func header(_ file: String) -> [UInt8] {
                    guard headers else { return [] }
                    let name = file == "-" ? "standard input" : file
                    defer { lastHeader = file; printedHeader = true }
                    return Array(((printedHeader ? "\n" : "") + "==> \(name) <==\n").utf8)
                }

                for file in files {
                    if file == "-", request.follow {
                        // Following a stream: show the tail of what is there at
                        // EOF... a pipe has no "now", so just copy it through.
                        let input = CommandInput(ctx, command: "tail", files: ["-"])
                        guard await ctx.put(header(file)) else { return }
                        while let bytes = await input.chunk() {
                            guard await ctx.put(bytes) else { return }
                        }
                        continue
                    }
                    let input = CommandInput(ctx, command: "tail", files: [file])
                    let data = await input.all()
                    if input.status != 0 { status = 1; continue }
                    offsets[file] = data.count
                    guard await ctx.put(header(file) + select(data)) else { return }
                }
                guard request.follow, !offsets.isEmpty else { ctx.exit(status); return }

                // Follow mode: park on the logical clock between checks. A signal
                // (Ctrl-C, SIGTERM, or SIGPIPE from a closed reader) interrupts the
                // sleep, which ends the program.
                while true {
                    do { try await ctx.sleep(request.interval) } catch { return }
                    for file in files {
                        guard let offset = offsets[file], let info = ctx.stat(file) else { continue }
                        if info.size < offset {
                            ctx.error("tail: \(file): file truncated")
                            offsets[file] = 0
                        }
                        let start = offsets[file] ?? 0
                        guard info.size > start, let fd = try? ctx.openFile(file) else { continue }
                        _ = ctx.seek(fd, to: start, whence: 0)
                        var fresh: [UInt8] = []
                        while let bytes = try? await ctx.read(fd, upTo: 65536), !bytes.isEmpty { fresh += bytes }
                        ctx.close(fd)
                        offsets[file] = start + fresh.count
                        let banner = lastHeader == file ? [] : header(file)
                        guard await ctx.put(banner + fresh) else { return }
                    }
                }
            }),

            Command(name: "wc", summary: "count lines, words, and bytes", category: .text,
                    usage: """
                    wc [-lwcmL] [FILE]...
                      -l  print the newline counts
                      -w  print the word counts
                      -c  print the byte counts
                      -m  print the character counts
                      -L  print the maximum line length
                    With no option, print lines, words, and bytes. A total line is
                    printed when more than one FILE is given.
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("wc", Array(argv.dropFirst()), "lwcmL",
                                               long: ["lines": "l", "words": "w", "bytes": "c",
                                                      "chars": "m", "max-line-length": "L"]) else { return }
                var columns: [Character] = ["l", "w", "m", "c", "L"].filter { parsed.has($0) }
                if columns.isEmpty { columns = ["l", "w", "c"] }
                func counts(_ data: [UInt8]) -> [Character: Int] {
                    var words = 0, inWord = false, longest = 0, current = 0, lines = 0, chars = 0
                    for byte in data {
                        if byte & 0xC0 != 0x80 { chars += 1 }
                        let space = byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
                        if space { inWord = false } else if !inWord { inWord = true; words += 1 }
                        if byte == 0x0A {
                            lines += 1
                            longest = max(longest, current)
                            current = 0
                        } else if byte & 0xC0 != 0x80 {
                            current += byte == 0x09 ? 8 - current % 8 : 1
                        }
                    }
                    return ["l": lines, "w": words, "c": data.count, "m": chars, "L": max(longest, current)]
                }
                var rows: [(counts: [Character: Int], name: String?)] = []
                var status: Int32 = 0
                if parsed.operands.isEmpty {
                    rows.append((counts(await readInput(ctx, cmd: "wc", files: []).data), nil))
                }
                for file in parsed.operands {
                    do {
                        rows.append((counts(try await readOperand(ctx, file)), file))
                    } catch {
                        ctx.error("wc: \(file): \(errnoText(error))")
                        status = 1
                    }
                }
                var total: [Character: Int] = [:]
                for row in rows {
                    for (key, value) in row.counts {
                        total[key] = key == "L" ? max(total[key] ?? 0, value) : (total[key] ?? 0) + value
                    }
                }
                if parsed.operands.count > 1 { rows.append((total, "total")) }
                // One number on its own needs no alignment; several line up in
                // columns at least 7 wide, like GNU wc reading a pipe.
                let single = columns.count == 1 && rows.count == 1
                let width = single ? 0 : max(7, String(total["c"] ?? 0).count)
                var out = ""
                for row in rows {
                    out += columns.map { padLeft(String(row.counts[$0] ?? 0), width) }.joined(separator: " ")
                    if let name = row.name { out += " " + name }
                    out += "\n"
                }
                await ctx.emit(out, exit: status)
            }),

            Command(name: "sort", summary: "sort lines of text", category: .text,
                    usage: """
                    sort [-nrufbs] [-t SEP] [-k KEYDEF]... [-o FILE] [FILE]...
                      -n         compare by numeric value
                      -r         reverse the result
                      -u         output only the first of equal lines
                      -f         ignore case
                      -b         ignore leading blanks
                      -s         stable: disable the last-resort whole-line comparison
                      -t SEP     use SEP as the field separator
                      -k KEYDEF  sort by a key: F[.C][nrfb][,F[.C][nrfb]]
                      -o FILE    write the result to FILE
                      -c         check whether the input is sorted
                    """, asyncRun: { ctx, argv in
                await sortCommand(ctx, Array(argv.dropFirst()))
            }),

            Command(name: "uniq", summary: "report or omit repeated adjacent lines", category: .text,
                    usage: """
                    uniq [-cdui] [-f N] [-s N] [-w N] [INPUT [OUTPUT]]
                      -c    prefix lines by the number of occurrences
                      -d    only print duplicate lines, one for each group
                      -u    only print lines that are not repeated
                      -i    ignore case when comparing
                      -f N  skip the first N fields when comparing
                      -s N  skip the first N characters when comparing
                      -w N  compare no more than N characters
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("uniq", Array(argv.dropFirst()), "cduif:s:w:",
                                               long: ["count": "c", "repeated": "d", "unique": "u",
                                                      "ignore-case": "i", "skip-fields": "f",
                                                      "skip-chars": "s", "check-chars": "w"]) else { return }
                guard parsed.operands.count <= 2 else {
                    ctx.error("uniq: extra operand '\(parsed.operands[2])'")
                    ctx.fail("Try 'uniq --help' for more information.", code: 1); return
                }
                var numbers: [Character: Int] = [:]
                for option in ["f", "s", "w"] as [Character] {
                    guard let text = parsed.value(option) else { continue }
                    guard let value = Int(text), value >= 0 else {
                        ctx.fail("uniq: \(text): invalid number", code: 1); return
                    }
                    numbers[option] = value
                }
                func key(_ line: String) -> String {
                    var rest = Substring(line)
                    for _ in 0..<(numbers["f"] ?? 0) {
                        rest = rest.drop { $0 == " " || $0 == "\t" }
                        rest = rest.drop { $0 != " " && $0 != "\t" }
                    }
                    rest = rest.dropFirst(numbers["s"] ?? 0)
                    if let width = numbers["w"] { rest = rest.prefix(width) }
                    return parsed.has("i") ? rest.lowercased() : String(rest)
                }
                let (data, status) = await readInput(ctx, cmd: "uniq", files: Array(parsed.operands.prefix(1)))
                var out = ""
                var groups: [(line: String, count: Int)] = []
                var lastKey: String? = nil
                for line in splitLines(data) {
                    let lineKey = key(line)
                    if lineKey == lastKey, !groups.isEmpty {
                        groups[groups.count - 1].count += 1
                    } else {
                        groups.append((line, 1))
                        lastKey = lineKey
                    }
                }
                for group in groups {
                    if parsed.has("d"), group.count < 2 { continue }
                    if parsed.has("u"), group.count > 1 { continue }
                    out += parsed.has("c") ? "\(padLeft(String(group.count), 7)) \(group.line)\n" : group.line + "\n"
                }
                if parsed.operands.count == 2 {
                    do {
                        let fd = try ctx.openForWriting(parsed.operands[1])
                        _ = await ctx.writeAll(fd, Array(out.utf8))
                        ctx.close(fd)
                        ctx.exit(status)
                    } catch {
                        ctx.fail("uniq: \(parsed.operands[1]): \(errnoText(error))", code: 1)
                    }
                    return
                }
                await ctx.emit(out, exit: status)
            }),

            Command(name: "rev", summary: "reverse the characters of each line", category: .text,
                    usage: "rev [FILE]...", asyncRun: { ctx, argv in
                guard let parsed = ctx.options("rev", Array(argv.dropFirst()), "") else { return }
                let input = CommandInput(ctx, command: "rev", files: parsed.operands)
                while let line = await input.line() {
                    guard await ctx.put(String(text(line).reversed()) + "\n") else { return }
                }
                ctx.exit(input.status)
            }),

            Command(name: "tac", summary: "concatenate and print files in reverse", category: .text,
                    usage: "tac [FILE]...", asyncRun: { ctx, argv in
                guard let parsed = ctx.options("tac", Array(argv.dropFirst()), "") else { return }
                var status: Int32 = 0
                var out: [UInt8] = []
                for file in parsed.operands.isEmpty ? ["-"] : parsed.operands {
                    do {
                        var lines = splitRawLines(try await readOperand(ctx, file))
                        // An unterminated last line still ends up newline-terminated.
                        if var last = lines.last, last.last != 0x0A {
                            last.append(0x0A)
                            lines[lines.count - 1] = last
                        }
                        out += lines.reversed().joined()
                    } catch {
                        ctx.error("tac: failed to open '\(file)' for reading: \(errnoText(error))")
                        status = 1
                    }
                }
                await ctx.emit(out, exit: status)
            }),

            // nl [file...] — number lines. Line numbers are right-justified in a
            // 6-character field followed by a tab, matching the default GNU nl
            // format; by default only non-empty lines are numbered.
            Command(name: "nl", summary: "number lines of files", category: .text,
                    usage: """
                    nl [-b STYLE] [-w WIDTH] [-s SEP] [-v START] [-i INCR] [-n FORMAT] [FILE]...
                      -b STYLE   a: number all lines, t: only non-empty lines (default), n: none
                      -w WIDTH   use WIDTH columns for line numbers (default 6)
                      -s SEP     add SEP after the number (default TAB)
                      -v START   first line number (default 1)
                      -i INCR    line number increment (default 1)
                      -n FORMAT  ln: left justified, rn: right justified (default), rz: zero padded
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("nl", Array(argv.dropFirst()), "b:w:s:v:i:n:",
                                               long: ["body-numbering": "b", "number-width": "w",
                                                      "number-separator": "s", "starting-line-number": "v",
                                                      "line-increment": "i", "number-format": "n"]) else { return }
                let style = parsed.value("b") ?? "t"
                let format = parsed.value("n") ?? "rn"
                guard ["a", "t", "n"].contains(style), ["ln", "rn", "rz"].contains(format),
                      let width = Int(parsed.value("w") ?? "6"), width > 0,
                      var number = Int(parsed.value("v") ?? "1"),
                      let increment = Int(parsed.value("i") ?? "1") else {
                    ctx.fail("nl: invalid option argument", code: 1); return
                }
                let separator = parsed.value("s") ?? "\t"
                let input = CommandInput(ctx, command: "nl", files: parsed.operands)
                while let raw = await input.line() {
                    let line = text(raw)
                    var out: String
                    if style == "a" || (style == "t" && !line.isEmpty) {
                        let digits = String(number)
                        switch format {
                        case "ln": out = padRight(digits, width)
                        case "rz": out = String(repeating: "0", count: max(0, width - digits.count)) + digits
                        default: out = padLeft(digits, width)
                        }
                        out += separator + line
                        number += increment
                    } else {
                        out = line.isEmpty ? String(repeating: " ", count: width + 1)
                                           : String(repeating: " ", count: width + separator.count) + line
                    }
                    guard await ctx.put(out + "\n") else { return }
                }
                ctx.exit(input.status)
            }),

            // cut -f LIST [-d DELIM] / -c LIST / -b LIST — select fields,
            // characters, or bytes of each line. The default field delimiter is a
            // tab; a line without the delimiter passes through unless -s.
            Command(name: "cut", summary: "remove sections from each line", category: .text,
                    usage: """
                    cut -f LIST [-d DELIM] [-s] [FILE]...
                    cut -c LIST [FILE]...
                    cut -b LIST [FILE]...
                      -f LIST  select only these fields (delimiter-separated)
                      -d DELIM use DELIM instead of TAB as the field delimiter
                      -s       do not print lines that contain no delimiter
                      -c LIST  select only these characters
                      -b LIST  select only these bytes
                      --complement               select everything except LIST
                      --output-delimiter=STRING  join the selected fields with STRING
                    LIST is comma-separated: N, N-M, N-, or -M (counting from 1).
                    """, asyncRun: { ctx, argv in
                // Long options with values are peeled off first so the short
                // parser sees only `-d`/`-f`/`-c`/`-b`/`-s`.
                var args: [String] = []
                var complement = false
                var outputDelimiter: String? = nil
                var rest = argv.dropFirst()
                while let arg = rest.popFirst() {
                    if arg == "--complement" { complement = true }
                    else if arg.hasPrefix("--output-delimiter=") { outputDelimiter = String(arg.dropFirst(19)) }
                    else if arg == "--output-delimiter", let value = rest.popFirst() { outputDelimiter = value }
                    else { args.append(arg) }
                }
                guard let parsed = ctx.options("cut", args, "d:f:c:b:sn",
                                               long: ["delimiter": "d", "fields": "f", "characters": "c",
                                                      "bytes": "b", "only-delimited": "s"]) else { return }
                let modes = ["f", "c", "b"].filter { parsed.has($0) } as [Character]
                guard modes.count == 1, let mode = modes.first, let listText = parsed.value(mode) else {
                    ctx.error(modes.isEmpty ? "cut: you must specify a list of bytes, characters, or fields"
                                            : "cut: only one list may be specified")
                    ctx.fail("Try 'cut --help' for more information.", code: 1); return
                }
                guard let ranges = parseRangeList(listText) else {
                    ctx.fail("cut: invalid field value '\(listText)'", code: 1); return
                }
                var delimiter: Character = "\t"
                if let text = parsed.value("d") {
                    guard text.count == 1, let first = text.first else {
                        ctx.fail("cut: the delimiter must be a single character", code: 1); return
                    }
                    delimiter = first
                }
                func selected(_ position: Int) -> Bool {
                    ranges.contains { $0.contains(position) } != complement
                }
                let input = CommandInput(ctx, command: "cut", files: parsed.operands)
                while let raw = await input.line() {
                    var out: [UInt8]
                    if mode == "b" {
                        out = raw.enumerated().filter { selected($0.offset + 1) }.map(\.element)
                    } else if mode == "c" {
                        let chars = Array(text(raw))
                        out = Array(String(chars.enumerated().filter { selected($0.offset + 1) }.map(\.element)).utf8)
                    } else {
                        let line = text(raw)
                        guard line.contains(delimiter) else {
                            if parsed.has("s") { continue }
                            guard await ctx.put(raw + [0x0A]) else { return }
                            continue
                        }
                        let fields = line.split(separator: delimiter, omittingEmptySubsequences: false)
                        let kept = fields.enumerated().filter { selected($0.offset + 1) }.map(\.element)
                        out = Array(kept.joined(separator: outputDelimiter ?? String(delimiter)).utf8)
                    }
                    out.append(0x0A)
                    guard await ctx.put(out) else { return }
                }
                ctx.exit(input.status)
            }),

            Command(name: "paste", summary: "merge lines of files", category: .text,
                    usage: """
                    paste [-s] [-d LIST] [FILE]...
                      -d LIST  reuse characters from LIST instead of TABs
                      -s       paste one file at a time instead of in parallel
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("paste", Array(argv.dropFirst()), "sd:",
                                               long: ["serial": "s", "delimiters": "d"]) else { return }
                let delimiters = Array(text(expandEscapes(parsed.value("d") ?? "\t", octalNeedsZero: false).bytes))
                let files = parsed.operands.isEmpty ? ["-"] : parsed.operands
                func delimiter(_ index: Int) -> String {
                    delimiters.isEmpty ? "" : String(delimiters[index % delimiters.count])
                }
                var status: Int32 = 0
                // Each `-` operand takes successive lines from the one stdin.
                let stdinLines = CommandInput(ctx, command: "paste", files: ["-"])
                var readers: [CommandInput?] = []
                for file in files {
                    if file == "-" { readers.append(stdinLines); continue }
                    do {
                        ctx.close(try ctx.openFile(file))
                        readers.append(CommandInput(ctx, command: "paste", files: [file]))
                    } catch {
                        ctx.error("paste: \(file): \(errnoText(error))")
                        status = 1
                        readers.append(nil)
                    }
                }
                if parsed.has("s") {
                    for reader in readers {
                        var out = ""
                        var index = 0
                        while let line = await reader?.line() {
                            if index > 0 { out += delimiter(index - 1) }
                            out += text(line)
                            index += 1
                        }
                        guard await ctx.put(out + "\n") else { return }
                    }
                    ctx.exit(status)
                    return
                }
                while true {
                    var parts: [String] = []
                    var any = false
                    for reader in readers {
                        if let line = await reader?.line() {
                            parts.append(text(line))
                            any = true
                        } else {
                            parts.append("")
                        }
                    }
                    guard any else { break }
                    var out = ""
                    for (index, part) in parts.enumerated() {
                        if index > 0 { out += delimiter(index - 1) }
                        out += part
                    }
                    guard await ctx.put(out + "\n") else { return }
                }
                ctx.exit(status)
            }),

            Command(name: "join", summary: "join lines of two files on a common field", category: .text,
                    usage: """
                    join [-t CHAR] [-1 FIELD] [-2 FIELD] [-j FIELD] [-a FILENUM] [-v FILENUM] FILE1 FILE2
                      -t CHAR     use CHAR as the input and output field separator
                      -1 FIELD    join on this field of file 1 (default 1)
                      -2 FIELD    join on this field of file 2 (default 1)
                      -j FIELD    equivalent to -1 FIELD -2 FIELD
                      -a FILENUM  also print unpairable lines from file FILENUM
                      -v FILENUM  print only unpairable lines from file FILENUM
                      -i          ignore case when comparing fields
                    Both files must be sorted on the join field.
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("join", Array(argv.dropFirst()), "t:1:2:j:a:v:i") else { return }
                guard parsed.operands.count == 2 else {
                    ctx.error("join: expected two file operands")
                    ctx.fail("Try 'join --help' for more information.", code: 1); return
                }
                let separator = parsed.value("t")?.first
                guard let field1 = Int(parsed.value("1") ?? parsed.value("j") ?? "1"), field1 > 0,
                      let field2 = Int(parsed.value("2") ?? parsed.value("j") ?? "1"), field2 > 0 else {
                    ctx.fail("join: invalid field number", code: 1); return
                }
                let unpaired = Set(parsed.all("a") + parsed.all("v"))
                let onlyUnpaired = parsed.has("v")
                func fields(_ line: String) -> [String] {
                    if let separator { return line.split(separator: separator, omittingEmptySubsequences: false).map(String.init) }
                    return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                }
                var tables: [[[String]]] = []
                for file in parsed.operands {
                    do {
                        tables.append(splitLines(try await readOperand(ctx, file)).map(fields))
                    } catch {
                        ctx.fail("join: \(file): \(errnoText(error))", code: 1); return
                    }
                }
                func key(_ row: [String], _ field: Int) -> String {
                    let value = field <= row.count ? row[field - 1] : ""
                    return parsed.has("i") ? value.lowercased() : value
                }
                let glue = separator.map(String.init) ?? " "
                func others(_ row: [String], _ field: Int) -> [String] {
                    row.enumerated().filter { $0.offset != field - 1 }.map(\.element)
                }
                var out = ""
                var i = 0, j = 0
                let left = tables[0], right = tables[1]
                while i < left.count || j < right.count {
                    if j >= right.count || (i < left.count && key(left[i], field1) < key(right[j], field2)) {
                        if unpaired.contains("1") { out += left[i].joined(separator: glue) + "\n" }
                        i += 1
                    } else if i >= left.count || key(left[i], field1) > key(right[j], field2) {
                        if unpaired.contains("2") { out += right[j].joined(separator: glue) + "\n" }
                        j += 1
                    } else {
                        // Equal keys: emit the cross product of both runs.
                        let value = key(left[i], field1)
                        var iEnd = i, jEnd = j
                        while iEnd < left.count, key(left[iEnd], field1) == value { iEnd += 1 }
                        while jEnd < right.count, key(right[jEnd], field2) == value { jEnd += 1 }
                        if !onlyUnpaired {
                            for a in i..<iEnd {
                                for b in j..<jEnd {
                                    let shown = field1 <= left[a].count ? left[a][field1 - 1] : ""
                                    out += ([shown] + others(left[a], field1) + others(right[b], field2))
                                        .joined(separator: glue) + "\n"
                                }
                            }
                        }
                        i = iEnd
                        j = jEnd
                    }
                }
                await ctx.emit(out, exit: 0)
            }),

            Command(name: "comm", summary: "compare two sorted files line by line", category: .text,
                    usage: """
                    comm [-123] FILE1 FILE2
                      -1  suppress column 1 (lines unique to FILE1)
                      -2  suppress column 2 (lines unique to FILE2)
                      -3  suppress column 3 (lines that appear in both files)
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("comm", Array(argv.dropFirst()), "123") else { return }
                guard parsed.operands.count == 2 else {
                    ctx.error(parsed.operands.count < 2 ? "comm: missing operand" : "comm: extra operand '\(parsed.operands[2])'")
                    ctx.fail("Try 'comm --help' for more information.", code: 1); return
                }
                var inputs: [[String]] = []
                for file in parsed.operands {
                    do {
                        inputs.append(splitLines(try await readOperand(ctx, file)))
                    } catch {
                        ctx.fail("comm: \(file): \(errnoText(error))", code: 1); return
                    }
                }
                let show = (1...3).map { !parsed.has(Character(String($0))) }
                func emit(_ column: Int, _ line: String) -> String {
                    guard show[column] else { return "" }
                    let indent = String(repeating: "\t", count: show[..<column].filter { $0 }.count)
                    return indent + line + "\n"
                }
                var out = ""
                var i = 0, j = 0
                let a = inputs[0], b = inputs[1]
                while i < a.count || j < b.count {
                    if j >= b.count || (i < a.count && a[i] < b[j]) { out += emit(0, a[i]); i += 1 }
                    else if i >= a.count || a[i] > b[j] { out += emit(1, b[j]); j += 1 }
                    else { out += emit(2, a[i]); i += 1; j += 1 }
                }
                await ctx.emit(out, exit: 0)
            }),

            Command(name: "tr", summary: "translate, squeeze, or delete characters", category: .text,
                    usage: """
                    tr [-cds] SET1 [SET2]
                      -d      delete characters in SET1
                      -s      squeeze repeated characters listed in the last SET
                      -c, -C  use the complement of SET1
                    SETs are character lists with ranges (a-z), classes ([:alpha:],
                    [:digit:], [:space:], [:upper:], [:lower:], [:alnum:], [:punct:]),
                    repeats ([c*n]), and escapes (\\n \\t \\\\ \\NNN).
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("tr", Array(argv.dropFirst()), "cCdst",
                                               long: ["complement": "c", "delete": "d",
                                                      "squeeze-repeats": "s", "truncate-set1": "t"]) else { return }
                let delete = parsed.has("d"), squeeze = parsed.has("s")
                let complement = parsed.has("c") || parsed.has("C")
                let minimum = delete == squeeze ? 2 : 1
                let maximum = delete && !squeeze ? 1 : 2
                guard !parsed.operands.isEmpty else {
                    ctx.error("tr: missing operand")
                    ctx.fail("Try 'tr --help' for more information.", code: 1); return
                }
                guard parsed.operands.count >= minimum else {
                    ctx.error("tr: missing operand after '\(parsed.operands[0])'")
                    ctx.fail("Try 'tr --help' for more information.", code: 1); return
                }
                guard parsed.operands.count <= maximum else {
                    ctx.error("tr: extra operand '\(parsed.operands[parsed.operands.count - 1])'")
                    ctx.fail("Try 'tr --help' for more information.", code: 1); return
                }
                var set1 = expandTrSet(parsed.operands[0])
                var set2 = parsed.operands.count > 1 ? expandTrSet(parsed.operands[1]) : []
                if complement {
                    let members = Set(set1)
                    set1 = (0...255).map { Unicode.Scalar(UInt8($0)) }.filter { !members.contains($0) }
                }
                let translating = !delete && parsed.operands.count > 1
                if translating {
                    if parsed.has("t") { set1 = Array(set1.prefix(set2.count)) }
                    // SET2 is padded with its last character to SET1's length.
                    if let last = set2.last, set2.count < set1.count {
                        set2 += [Unicode.Scalar](repeating: last, count: set1.count - set2.count)
                    }
                }
                var mapping: [Unicode.Scalar: Unicode.Scalar] = [:]
                if translating, !set2.isEmpty {
                    for (index, scalar) in set1.enumerated() { mapping[scalar] = set2[index] }
                }
                let deleteSet = delete ? Set(set1) : []
                let squeezeSet: Set<Unicode.Scalar> = squeeze
                    ? Set(parsed.operands.count > 1 ? set2 : set1) : []
                let input = CommandInput(ctx, command: "tr", files: [])
                var previous: Unicode.Scalar? = nil
                var carry: [UInt8] = []
                while let bytes = await input.chunk() {
                    // Keep a split UTF-8 sequence for the next chunk.
                    var data = carry + bytes
                    carry = []
                    for back in 1...3 where back <= data.count {
                        let lead = data[data.count - back]
                        if lead & 0xC0 == 0x80 { continue }          // continuation byte
                        if lead >= 0xC0, utf8Length(lead) > back {    // sequence cut short
                            carry = Array(data.suffix(back))
                            data.removeLast(back)
                        }
                        break
                    }
                    var out = String.UnicodeScalarView()
                    for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
                        if deleteSet.contains(scalar) { continue }
                        let mapped = mapping[scalar] ?? scalar
                        if squeezeSet.contains(mapped), previous == mapped { continue }
                        previous = mapped
                        out.append(mapped)
                    }
                    guard await ctx.put(String(out)) else { return }
                }
                ctx.exit(0)
            }),

            Command(name: "fold", summary: "wrap each line to a given width", category: .text,
                    usage: """
                    fold [-s] [-b] [-w WIDTH] [FILE]...
                      -w WIDTH  use WIDTH columns instead of 80
                      -s        break at spaces
                      -b        count bytes rather than columns
                    """, asyncRun: { ctx, argv in
                var args = Array(argv.dropFirst())
                // `fold -40` is the historical spelling of `-w 40`.
                args = args.map { $0.count > 1 && $0.hasPrefix("-") && $0.dropFirst().allSatisfy(\.isNumber) ? "-w" + $0.dropFirst() : $0 }
                guard let parsed = ctx.options("fold", args, "sbw:",
                                               long: ["spaces": "s", "bytes": "b", "width": "w"]) else { return }
                guard let width = Int(parsed.value("w") ?? "80"), width > 0 else {
                    ctx.fail("fold: invalid number of columns: '\(parsed.value("w") ?? "")'", code: 1); return
                }
                let input = CommandInput(ctx, command: "fold", files: parsed.operands)
                while let raw = await input.line() {
                    var chars = Array(text(raw))[...]
                    var out = ""
                    while chars.count > width {
                        var take = width
                        if parsed.has("s"), let space = chars.prefix(width).lastIndex(of: " ") {
                            take = space - chars.startIndex + 1
                        }
                        out += String(chars.prefix(take)) + "\n"
                        chars = chars.dropFirst(take)
                    }
                    guard await ctx.put(out + String(chars) + "\n") else { return }
                }
                ctx.exit(input.status)
            }),

            Command(name: "expand", summary: "convert tabs to spaces", category: .text,
                    usage: """
                    expand [-t N] [-i] [FILE]...
                      -t N  have tabs N characters apart instead of 8
                      -i    do not convert tabs after non-blanks
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("expand", Array(argv.dropFirst()), "t:i",
                                               long: ["tabs": "t", "initial": "i"]) else { return }
                guard let tab = Int(parsed.value("t") ?? "8"), tab > 0 else {
                    ctx.fail("expand: tab size contains invalid character(s): '\(parsed.value("t") ?? "")'", code: 1); return
                }
                let input = CommandInput(ctx, command: "expand", files: parsed.operands)
                while let raw = await input.line() {
                    var out = ""
                    var column = 0
                    var leading = true
                    for character in text(raw) {
                        if character == "\t", leading || !parsed.has("i") {
                            let spaces = tab - column % tab
                            out += String(repeating: " ", count: spaces)
                            column += spaces
                        } else {
                            if character != " " { leading = false }
                            out.append(character)
                            column += 1
                        }
                    }
                    guard await ctx.put(out + "\n") else { return }
                }
                ctx.exit(input.status)
            }),

            Command(name: "column", summary: "format input into aligned columns", category: .text,
                    usage: """
                    column [-t] [-s SEP] [-o OUTSEP] [-c WIDTH] [FILE]...
                      -t         build a table: align the whitespace-separated columns
                      -s SEP     with -t, split input on any character in SEP
                      -o OUTSEP  with -t, separate output columns with OUTSEP (default two spaces)
                      -c WIDTH   without -t, fill columns up to WIDTH (default 80)
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("column", Array(argv.dropFirst()), "ts:o:c:x",
                                               long: ["table": "t", "separator": "s",
                                                      "output-separator": "o",
                                                      "output-width": "c"]) else { return }
                let (data, status) = await readInput(ctx, cmd: "column", files: parsed.operands)
                let lines = splitLines(data).filter { !$0.isEmpty }
                guard parsed.has("t") else {
                    let width = Int(parsed.value("c") ?? "") ?? (ctx.terminalWindowSize(1)?.columns ?? 80)
                    await ctx.emit(lines.isEmpty ? "" : columnize(lines, width: max(1, width)), exit: status)
                    return
                }
                let separators = parsed.value("s").map(Set.init)
                let rows: [[String]] = lines.map { line in
                    if let separators {
                        return line.split(omittingEmptySubsequences: false, whereSeparator: { separators.contains($0) }).map(String.init)
                    }
                    return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                }
                var widths: [Int] = []
                for row in rows {
                    for (index, cell) in row.enumerated() {
                        if index == widths.count { widths.append(0) }
                        widths[index] = max(widths[index], cell.count)
                    }
                }
                let glue = parsed.value("o") ?? "  "
                var out = ""
                for row in rows {
                    out += row.enumerated().map { index, cell in
                        index == row.count - 1 ? cell : padRight(cell, widths[index])
                    }.joined(separator: glue) + "\n"
                }
                await ctx.emit(out, exit: status)
            }),

            // tee [-a] file... — copy stdin to stdout and to each file, as the
            // data arrives.
            Command(name: "tee", summary: "copy stdin to stdout and to files", category: .text,
                    usage: """
                    tee [-ai] [FILE]...
                      -a  append to the given FILEs, do not overwrite
                      -i  ignore interrupt signals (accepted for compatibility)
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("tee", Array(argv.dropFirst()), "aip",
                                               long: ["append": "a", "ignore-interrupts": "i"]) else { return }
                var status: Int32 = 0
                var descriptors: [Int] = []
                for file in parsed.operands {
                    do {
                        descriptors.append(try ctx.openForWriting(file, truncate: !parsed.has("a"),
                                                                  append: parsed.has("a")))
                    } catch {
                        ctx.error("tee: \(file): \(errnoText(error))")
                        status = 1
                    }
                }
                let input = CommandInput(ctx, command: "tee", files: [])
                while let bytes = await input.chunk() {
                    for fd in descriptors { _ = await ctx.writeAll(fd, bytes) }
                    guard await ctx.put(bytes) else { return }
                }
                for fd in descriptors { ctx.close(fd) }
                ctx.exit(status)
            }),

            // more [file...] — page through text a screen at a time. Content
            // comes from the file arguments, or from stdin (so `cmd | more`
            // works); the page-advance keypress is read from fd 2, which stays
            // wired to the terminal even in a pipeline (only fd 0 becomes the
            // pipe). Press Enter at the `--More--` prompt to show the next page.
            // Page height is `$LINES` (default 24). Content that fits on one page
            // prints without any prompt.
            Command(name: "more", summary: "page through text", category: .text,
                    usage: "more [FILE]...\nPress Enter at the --More-- prompt for the next page.",
                    asyncRun: { ctx, argv in
                let files = Array(argv.dropFirst())
                var data: [UInt8] = []
                if files.isEmpty {
                    while let chunk = try? await ctx.read(0), !chunk.isEmpty { data.append(contentsOf: chunk) }
                } else {
                    for file in files {
                        guard let fd = ctx.open(file) else {
                            ctx.error("more: \(file): No such file"); continue
                        }
                        data.append(contentsOf: readFully(ctx, fd))
                        ctx.close(fd)
                    }
                }
                let lines = splitLines(data)
                let height = max(2, Int(ctx.getenv("LINES") ?? "") ?? 24)
                let page = height - 1                 // leave a row for the prompt
                var index = 0
                while index < lines.count {
                    let end = min(index + page, lines.count)
                    ctx.print(lines[index..<end].joined(separator: "\n") + "\n")
                    index = end
                    if index < lines.count {
                        ctx.write(1, Array("--More--".utf8))
                        _ = try? await ctx.read(2)    // wait for a keypress on the terminal
                        ctx.write(1, Array("\r        \r".utf8))   // erase the prompt
                    }
                }
                ctx.exit(0)
            }),

            // less [file...] — a full-screen pager. On a terminal it switches the
            // tty to raw mode and scrolls with single keys; when stdout is not a
            // terminal (or the text fits on one screen) it just copies the text.
            Command(name: "less", summary: "page through text, forward and backward", category: .text,
                    usage: """
                    less [FILE]...
                    Keys: SPACE/f next page, b previous page, ENTER/j/DOWN one line down,
                    k/UP one line up, d/u half page, g top, G bottom, q quit.
                    """, asyncRun: { ctx, argv in
                guard let parsed = ctx.options("less", Array(argv.dropFirst()), "RFXSNneiM") else { return }
                let (data, status) = await readInput(ctx, cmd: "less", files: parsed.operands)
                let lines = splitLines(data)
                let keys = ctx.isATTY(2) ? 2 : 0
                let rows = ctx.terminalWindowSize(1)?.rows ?? 0
                let height = max(2, rows > 0 ? rows : (Int(ctx.getenv("LINES") ?? "") ?? 24))
                let page = height - 1
                guard ctx.isATTY(1), ctx.isATTY(keys), lines.count > page else {
                    await ctx.emit(data, exit: status)
                    return
                }
                ctx.setTerminalRawMode(keys, true)
                var top = 0
                let lastTop = max(0, lines.count - page)
                func draw() async -> Bool {
                    var frame = "\u{1B}[2J\u{1B}[H"
                    for line in lines[top..<min(top + page, lines.count)] {
                        frame += line + "\r\n"
                    }
                    frame += top >= lastTop ? "\u{1B}[7m(END)\u{1B}[0m" : ":"
                    return await ctx.put(frame)
                }
                var running = await draw()
                while running {
                    guard let input = try? await ctx.read(keys), !input.isEmpty else { break }
                    var bytes = input[...]
                    while let key = bytes.popFirst() {
                        if key == 0x1B, bytes.first == UInt8(ascii: "[") {
                            // Arrow / page keys: ESC [ A|B|5~|6~.
                            bytes = bytes.dropFirst()
                            let code = bytes.popFirst()
                            if code == UInt8(ascii: "A") { top -= 1 }
                            else if code == UInt8(ascii: "B") { top += 1 }
                            else if code == UInt8(ascii: "5") { top -= page; bytes = bytes.dropFirst() }
                            else if code == UInt8(ascii: "6") { top += page; bytes = bytes.dropFirst() }
                            continue
                        }
                        switch key {
                        case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x03: running = false
                        case UInt8(ascii: " "), UInt8(ascii: "f"), 0x06: top += page
                        case UInt8(ascii: "b"), 0x02: top -= page
                        case 0x0D, 0x0A, UInt8(ascii: "j"), UInt8(ascii: "e"): top += 1
                        case UInt8(ascii: "k"), UInt8(ascii: "y"): top -= 1
                        case UInt8(ascii: "d"): top += page / 2
                        case UInt8(ascii: "u"): top -= page / 2
                        case UInt8(ascii: "g"), UInt8(ascii: "<"): top = 0
                        case UInt8(ascii: "G"), UInt8(ascii: ">"): top = lastTop
                        default: break
                        }
                    }
                    top = min(max(0, top), lastTop)
                    if running { running = await draw() }
                }
                ctx.setTerminalRawMode(keys, false)
                ctx.write(1, Array("\r\u{1B}[K".utf8))
                ctx.exit(status)
            }),

            // seq [-s SEP] [-w] [FIRST [INCREMENT]] LAST — print an arithmetic
            // sequence, one number per line. Decimal operands are honored with
            // the widest fractional precision among them.
            Command(name: "seq", summary: "print a sequence of numbers", category: .text,
                    usage: """
                    seq [-w] [-s SEP] [FIRST [INCREMENT]] LAST
                      -s SEP  separate numbers with SEP (default: newline)
                      -w      equalize width by padding with leading zeros
                    """, asyncRun: { ctx, argv in
                // Operands may be negative numbers, so options are peeled by hand.
                var separator = "\n"
                var equalWidth = false
                var numbers: [String] = []
                var rest = argv.dropFirst()
                while let arg = rest.popFirst() {
                    if arg == "-w" { equalWidth = true }
                    else if arg == "-s" {
                        guard let value = rest.popFirst() else {
                            ctx.error("seq: option requires an argument -- 's'")
                            ctx.fail("Try 'seq --help' for more information.", code: 1); return
                        }
                        separator = value
                    } else if arg.hasPrefix("-s"), arg.count > 2 { separator = String(arg.dropFirst(2)) }
                    else if arg == "--" { numbers += rest; break }
                    else if arg.hasPrefix("-"), arg.count > 1, Double(arg) == nil {
                        ctx.invalidOption("seq", arg.hasPrefix("--") ? arg : String(arg.dropFirst().prefix(1))); return
                    } else { numbers.append(arg) }
                }
                guard (1...3).contains(numbers.count) else {
                    ctx.error(numbers.isEmpty ? "seq: missing operand" : "seq: extra operand '\(numbers[3])'")
                    ctx.fail("Try 'seq --help' for more information.", code: 1); return
                }
                var values: [Double] = []
                var places = 0
                for text in numbers {
                    guard let value = Double(text), value.isFinite else {
                        ctx.error("seq: invalid floating point argument: '\(text)'")
                        ctx.fail("Try 'seq --help' for more information.", code: 1); return
                    }
                    values.append(value)
                    if let dot = text.firstIndex(of: "."), !text.lowercased().contains("e") {
                        places = max(places, text.distance(from: dot, to: text.endIndex) - 1)
                    }
                }
                let first = values.count > 1 ? values[0] : 1
                let step = values.count > 2 ? values[1] : 1
                let last = values[values.count - 1]
                guard step != 0 else {
                    ctx.error("seq: invalid Zero increment value: '\(numbers[1])'")
                    ctx.fail("Try 'seq --help' for more information.", code: 1); return
                }
                func render(_ value: Double) -> String {
                    if places == 0, abs(value) < 9e15 { return String(Int64(value.rounded())) }
                    return (value < 0 ? "-" : "") + fixedPoint(abs(value), places: places)
                }
                let width = equalWidth ? max(render(first).count, render(last).count) : 0
                var out = ""
                var index = 0.0
                var emittedAny = false
                while true {
                    // Multiply rather than accumulate, so 0.1 steps do not drift.
                    let value = first + index * step
                    let epsilon = abs(step) * 1e-9
                    if step > 0 ? value > last + epsilon : value < last - epsilon { break }
                    var item = render(value)
                    if item.count < width {
                        let negative = item.hasPrefix("-")
                        let digits = negative ? String(item.dropFirst()) : item
                        item = (negative ? "-" : "") + String(repeating: "0", count: width - item.count) + digits
                    }
                    out += (emittedAny ? separator : "") + item
                    emittedAny = true
                    index += 1
                    if out.utf8.count > 32 * 1024 {
                        guard await ctx.put(out) else { return }
                        out = ""
                    }
                }
                if emittedAny { out += "\n" }
                await ctx.emit(out, exit: 0)
            }),

            // yes [STRING...] — repeat a line forever. The writer parks whenever
            // the pipe is full and dies of SIGPIPE when the reader leaves
            // (`yes | head -1`); on a sink that never fills (a terminal, a file)
            // it paces itself on the logical clock instead of spinning.
            Command(name: "yes", summary: "repeatedly output a line", category: .text,
                    usage: "yes [STRING]...\nRepeatedly output a line with all STRINGs, or 'y'.",
                    asyncRun: { ctx, argv in
                let line = argv.count > 1 ? argv.dropFirst().joined(separator: " ") : "y"
                var batch: [UInt8] = []
                while batch.count < 4096 { batch += Array((line + "\n").utf8) }
                var uninterrupted = 0
                while true {
                    let accepted: Int
                    do { accepted = try ctx.writeFile(1, batch) } catch { return }
                    if accepted < batch.count {
                        // Backpressure: finish this batch (parking until the pipe drains).
                        guard await ctx.writeAll(1, Array(batch[accepted...])) else { return }
                        uninterrupted = 0
                    } else {
                        uninterrupted += 1
                        if uninterrupted >= 32 {
                            uninterrupted = 0
                            do { try await ctx.sleep(0.01) } catch { return }
                        }
                    }
                }
            }),
        ]
    }

    // MARK: - head / tail options

    struct HeadTailRequest {
        var count = 10
        var bytes = false
        /// head: "all but the last N" (`-n -N`); tail: "starting at N" (`-n +N`).
        var fromStart = false
        var follow = false
        var interval = 1.0
        var quiet = false
        var verbose = false
        var files: [String] = []
    }

    /// Parse the option forms `head` and `tail` share: `-n N`, `-nN`, `-N`,
    /// `-c N`, a `+`/`-` sign on the count, `-f`, `-s SEC`, `-q`, `-v`, and size
    /// suffixes on counts. Reports errors and returns `nil` on a bad invocation.
    static func parseHeadTail(_ ctx: ProcessContext, _ command: String, _ arguments: [String]) -> HeadTailRequest? {
        var request = HeadTailRequest()
        var args = arguments[...]
        func setCount(_ text: String, bytes: Bool) -> Bool {
            var body = Substring(text)
            var sign: Character? = nil
            if let first = body.first, first == "+" || first == "-" { sign = first; body = body.dropFirst() }
            guard let value = parseSize(String(body)) else {
                ctx.fail("\(command): invalid number of \(bytes ? "bytes" : "lines"): '\(text)'", code: 1)
                return false
            }
            request.count = value
            request.bytes = bytes
            request.fromStart = command == "head" ? sign == "-" : sign == "+"
            return true
        }
        while let arg = args.first, CommandArguments.isOptionToken(arg) {
            args = args.dropFirst()
            if arg == "--" { break }
            if arg == "--follow" { request.follow = true; continue }
            if arg == "--quiet" || arg == "--silent" { request.quiet = true; continue }
            if arg == "--verbose" { request.verbose = true; continue }
            if arg.hasPrefix("--lines=") { guard setCount(String(arg.dropFirst(8)), bytes: false) else { return nil }; continue }
            if arg.hasPrefix("--bytes=") { guard setCount(String(arg.dropFirst(8)), bytes: true) else { return nil }; continue }
            if arg.hasPrefix("--") { ctx.invalidOption(command, arg); return nil }
            let letters = Array(arg.dropFirst())
            // `-5` / `+5`-style shorthand for `-n 5`.
            if let first = letters.first, first.isNumber {
                guard setCount(String(letters), bytes: false) else { return nil }
                continue
            }
            var offset = 0
            while offset < letters.count {
                let letter = letters[offset]
                offset += 1
                switch letter {
                case "q": request.quiet = true
                case "v": request.verbose = true
                case "f" where command == "tail", "F" where command == "tail": request.follow = true
                case "n", "c", "s":
                    if letter == "s", command != "tail" {
                        ctx.invalidOption(command, String(letter))
                        return nil
                    }
                    var value = String(letters[offset...])
                    offset = letters.count
                    if value.isEmpty {
                        guard let next = args.first else {
                            ctx.error("\(command): option requires an argument -- '\(letter)'")
                            ctx.fail("Try '\(command) --help' for more information.", code: 1)
                            return nil
                        }
                        value = next
                        args = args.dropFirst()
                    }
                    if letter == "s" {
                        guard let seconds = Double(value), seconds >= 0 else {
                            ctx.fail("\(command): invalid number of seconds: '\(value)'", code: 1)
                            return nil
                        }
                        request.interval = max(seconds, 0.001)
                    } else {
                        guard setCount(value, bytes: letter == "c") else { return nil }
                    }
                default:
                    ctx.invalidOption(command, String(letter))
                    return nil
                }
            }
        }
        request.files = Array(args)
        return request
    }

    /// Split bytes into lines that keep their terminating newline (the last line
    /// may lack one), so re-joining reproduces the input exactly.
    static func splitRawLines(_ data: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var start = 0
        for (index, byte) in data.enumerated() where byte == 0x0A {
            lines.append(Array(data[start...index]))
            start = index + 1
        }
        if start < data.count { lines.append(Array(data[start...])) }
        return lines
    }

    /// Parse a `cut`-style list (`1,3`, `2-4`, `-2`, `5-`) into closed ranges.
    static func parseRangeList(_ text: String) -> [ClosedRange<Int>]? {
        var ranges: [ClosedRange<Int>] = []
        for item in text.split(whereSeparator: { $0 == "," || $0 == " " }) {
            if let dash = item.firstIndex(of: "-") {
                let low = item[..<dash], high = item[item.index(after: dash)...]
                if low.isEmpty, high.isEmpty { return nil }
                guard let start = low.isEmpty ? 1 : Int(low), start >= 1,
                      let end = high.isEmpty ? Int.max : Int(high), end >= start else { return nil }
                ranges.append(start...end)
            } else {
                guard let value = Int(item), value >= 1 else { return nil }
                ranges.append(value...value)
            }
        }
        return ranges.isEmpty ? nil : ranges
    }

    static func utf8Length(_ lead: UInt8) -> Int {
        lead >= 0xF0 ? 4 : (lead >= 0xE0 ? 3 : (lead >= 0xC0 ? 2 : 1))
    }

    /// Expand a `tr` SET into its scalars: ranges, `[:class:]`, `[c*n]`, escapes.
    static func expandTrSet(_ spec: String) -> [Unicode.Scalar] {
        let scalars = Array(spec.unicodeScalars)
        var out: [Unicode.Scalar] = []
        var index = 0
        func classMembers(_ name: String) -> [Unicode.Scalar]? {
            let ascii = (0..<128).map { Unicode.Scalar(UInt8($0)) }
            func pick(_ test: (Character) -> Bool) -> [Unicode.Scalar] { ascii.filter { test(Character($0)) } }
            switch name {
            case "alpha": return pick { $0.isLetter }
            case "digit": return pick { $0.isNumber }
            case "alnum": return pick { $0.isLetter || $0.isNumber }
            case "upper": return pick { $0.isUppercase }
            case "lower": return pick { $0.isLowercase }
            case "space": return [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20].map { Unicode.Scalar(UInt8($0)) }
            case "blank": return [" ", "\t"]
            case "punct": return pick { $0.isPunctuation || $0.isSymbol }
            case "xdigit": return pick { $0.isHexDigit }
            case "cntrl": return ascii.filter { $0.value < 0x20 || $0.value == 0x7F }
            case "print": return ascii.filter { $0.value >= 0x20 && $0.value < 0x7F }
            case "graph": return ascii.filter { $0.value > 0x20 && $0.value < 0x7F }
            default: return nil
            }
        }
        func readOne() -> Unicode.Scalar {
            let scalar = scalars[index]
            index += 1
            guard scalar == "\\", index < scalars.count else { return scalar }
            let next = scalars[index]
            index += 1
            switch next {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "a": return "\u{07}"
            case "b": return "\u{08}"
            case "f": return "\u{0C}"
            case "v": return "\u{0B}"
            case "0"..."7":
                var value = next.value - 48
                var digits = 1
                while digits < 3, index < scalars.count, ("0"..."7").contains(scalars[index]) {
                    value = value * 8 + scalars[index].value - 48
                    index += 1
                    digits += 1
                }
                return Unicode.Scalar(UInt8(truncatingIfNeeded: value))
            default: return next
            }
        }
        while index < scalars.count {
            if scalars[index] == "[", index + 1 < scalars.count, scalars[index + 1] == ":" {
                if let close = (index + 2..<scalars.count).first(where: { scalars[$0] == ":" }),
                   close + 1 < scalars.count, scalars[close + 1] == "]",
                   let members = classMembers(String(String.UnicodeScalarView(scalars[(index + 2)..<close]))) {
                    out += members
                    index = close + 2
                    continue
                }
            }
            // `[c*n]` — n copies of c (`[c*]` is handled by SET2 padding).
            if scalars[index] == "[", index + 2 < scalars.count, scalars[index + 2] == "*",
               let close = (index + 3..<scalars.count).first(where: { scalars[$0] == "]" }) {
                let countText = String(String.UnicodeScalarView(scalars[(index + 3)..<close]))
                if let count = countText.isEmpty ? 1 : Int(countText, radix: countText.hasPrefix("0") ? 8 : 10) {
                    out += [Unicode.Scalar](repeating: scalars[index + 1], count: count)
                    index = close + 1
                    continue
                }
            }
            let low = readOne()
            if index + 1 < scalars.count, scalars[index] == "-" {
                index += 1
                let high = readOne()
                if low.value <= high.value {
                    out += (low.value...high.value).compactMap(Unicode.Scalar.init)
                } else {
                    out += [low, "-", high]
                }
            } else {
                out.append(low)
            }
        }
        return out
    }

    // MARK: - grep

    private static func grepCommand(_ ctx: ProcessContext, _ arguments: [String]) async {
        // `--color` and friends are accepted and ignored.
        let args = arguments.filter { !$0.hasPrefix("--color") && !$0.hasPrefix("--colour") && $0 != "--line-buffered" }
        guard let parsed = ctx.options(
            "grep", args, "ivncFEGPe:f:rRolLwxqhHsA:B:C:m:aIz",
            long: ["ignore-case": "i", "invert-match": "v", "line-number": "n", "count": "c",
                   "fixed-strings": "F", "extended-regexp": "E", "basic-regexp": "G", "regexp": "e",
                   "file": "f", "recursive": "r", "only-matching": "o", "files-with-matches": "l",
                   "files-without-match": "L", "word-regexp": "w", "line-regexp": "x", "quiet": "q",
                   "silent": "q", "no-filename": "h", "with-filename": "H", "no-messages": "s",
                   "after-context": "A", "before-context": "B", "context": "C",
                   "max-count": "m"]) else { return }
        var operands = parsed.operands
        var patternTexts = parsed.all("e")
        for file in parsed.all("f") {
            do {
                patternTexts += splitLines(try await readOperand(ctx, file))
            } catch {
                ctx.fail("grep: \(file): \(errnoText(error))"); return
            }
        }
        if !parsed.has("e"), !parsed.has("f") {
            guard let first = operands.first else {
                ctx.error("Usage: grep [OPTION]... PATTERNS [FILE]...")
                ctx.fail("Try 'grep --help' for more information."); return
            }
            patternTexts = [first]
            operands.removeFirst()
        }
        // A pattern operand may hold several newline-separated patterns.
        patternTexts = patternTexts.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

        let ignoreCase = parsed.has("i")
        let syntax: Regex.Syntax = parsed.has("E") || parsed.has("P") ? .extended : .basic
        var patterns: [Regex] = []
        for pattern in patternTexts {
            if parsed.has("F") {
                patterns.append(Regex.literal(pattern, ignoreCase: ignoreCase))
            } else if let compiled = Regex(pattern: pattern, ignoreCase: ignoreCase, syntax: syntax) {
                patterns.append(compiled)
            } else {
                ctx.fail("grep: invalid pattern: \(pattern)"); return
            }
        }
        var numbers: [Character: Int] = [:]
        for option in ["A", "B", "C", "m"] as [Character] {
            guard let text = parsed.value(option) else { continue }
            guard let value = Int(text), value >= 0 else {
                ctx.fail("grep: \(text): invalid \(option == "m" ? "max count" : "context length argument")"); return
            }
            numbers[option] = value
        }
        let after = numbers["A"] ?? numbers["C"] ?? 0
        let before = numbers["B"] ?? numbers["C"] ?? 0
        let invert = parsed.has("v")
        let wholeWord = parsed.has("w"), wholeLine = parsed.has("x")
        let recursive = parsed.has("r") || parsed.has("R")
        let quiet = parsed.has("q")

        func isWord(_ character: Character) -> Bool { character == "_" || character.isLetter || character.isNumber }

        /// Every match of any pattern in the line, leftmost first, non-overlapping.
        func matches(in chars: [Character], firstOnly: Bool) -> [Range<Int>] {
            if wholeLine {
                return patterns.contains { $0.matchesEntire(chars) } ? [0..<chars.count] : []
            }
            var found: [Range<Int>] = []
            var start = 0
            while start <= chars.count {
                var best: Range<Int>? = nil
                for pattern in patterns {
                    var from = start
                    while from <= chars.count, let range = pattern.firstMatch(in: chars, from: from) {
                        if wholeWord {
                            let leftOK = range.lowerBound == 0 || !isWord(chars[range.lowerBound - 1])
                            let rightOK = range.upperBound == chars.count || !isWord(chars[range.upperBound])
                            if !(leftOK && rightOK && !range.isEmpty) { from = range.lowerBound + 1; continue }
                        }
                        if best == nil || range.lowerBound < best!.lowerBound
                            || (range.lowerBound == best!.lowerBound && range.count > best!.count) {
                            best = range
                        }
                        break
                    }
                }
                guard let range = best else { break }
                found.append(range)
                if firstOnly { break }
                start = range.isEmpty ? range.upperBound + 1 : range.upperBound
            }
            return found
        }

        // Expand directory operands for -r.
        var status: Int32 = 1
        var hadError = false
        var files: [String] = []
        var visitedDirectories: Set<String> = []
        // Pre-order walk on an explicit stack (deep trees must not become deep
        // host recursion); entries are pushed in reverse so they pop in order.
        func collect(_ operand: String, explicit: Bool) {
            var pending = [(path: operand, explicit: explicit)]
            while let (path, explicit) = pending.popLast() {
                guard let info = ctx.stat(path) else {
                    if !parsed.has("s") { ctx.error("grep: \(path): \(SyscallError.noSuchFileOrDirectory.message)") }
                    hadError = true
                    continue
                }
                guard info.isDirectory else { files.append(path); continue }
                guard recursive else {
                    if !parsed.has("s") { ctx.error("grep: \(path): \(SyscallError.isADirectory.message)") }
                    hadError = true
                    continue
                }
                // -R follows links, so a link back to an ancestor (`/proc/self/cwd`)
                // must not be walked twice: each real directory is visited once.
                if parsed.has("R") {
                    let real = canonicalPath(ctx, path, allowMissing: true) ?? ctx.absolute(path)
                    guard visitedDirectories.insert(real).inserted else { continue }
                }
                do {
                    var children: [(path: String, explicit: Bool)] = []
                    for entry in try ctx.directoryEntries(path) where entry.type != .symlink || parsed.has("R") {
                        let child = path == "." && !explicit ? entry.name : ctx.join(path, entry.name)
                        // Devices and FIFOs met during recursion are skipped (GNU
                        // grep's default): reading a terminal or /dev/zero never ends.
                        let followed = parsed.has("R")
                        if entry.type == .fifo || ctx.isDeviceNode(child, follow: followed)
                            || (followed && ctx.stat(child)?.type == .fifo) { continue }
                        children.append((child, true))
                    }
                    pending.append(contentsOf: children.reversed())
                } catch {
                    if !parsed.has("s") { ctx.error("grep: \(path): \(errnoText(error))") }
                    hadError = true
                }
            }
        }
        if operands.isEmpty {
            if recursive { collect(".", explicit: false) } else { files = ["-"] }
        } else {
            for operand in operands {
                if operand == "-" { files.append("-") } else { collect(operand, explicit: true) }
            }
        }
        let withName = parsed.has("H") || (!parsed.has("h") && (operands.count > 1 || recursive))

        var out = ""
        var needsGroupSeparator = false
        for file in files {
            let label = file == "-" ? "(standard input)" : file
            let fd: Int
            do {
                fd = file == "-" ? 0 : try ctx.openFile(file)
            } catch {
                if !parsed.has("s") { ctx.error("grep: \(file): \(errnoText(error))") }
                hadError = true
                continue
            }
            let input = CommandInput(ctx, command: "grep", files: ["-"], descriptor: fd)
            let streaming = file == "-"
            var selected = 0
            var lineNumber = 0
            var history: [(number: Int, text: String)] = []      // leading context
            var trailing = 0
            var lastPrinted: Int? = nil
            func prefix(_ number: Int, _ separator: String) -> String {
                (withName ? label + separator : "") + (parsed.has("n") ? "\(number)" + separator : "")
            }
            while let raw = await input.line() {
                lineNumber += 1
                let line = text(raw)
                let chars = Array(line)
                let ranges = matches(in: chars, firstOnly: !parsed.has("o"))
                let isSelected = ranges.isEmpty == invert
                if isSelected {
                    selected += 1
                    status = 0
                    if quiet { if file != "-" { ctx.close(fd) }; ctx.exit(0); return }
                    if !parsed.has("c"), !parsed.has("l"), !parsed.has("L") {
                        if before > 0 || after > 0 {
                            // `--` separates groups that are not contiguous.
                            let first = history.first?.number ?? lineNumber
                            if needsGroupSeparator, lastPrinted.map({ first > $0 + 1 }) ?? true {
                                out += "--\n"
                            }
                            for item in history { out += prefix(item.number, "-") + item.text + "\n" }
                            history.removeAll()
                            needsGroupSeparator = true
                        }
                        if parsed.has("o") {
                            if !invert {
                                for range in ranges where !range.isEmpty {
                                    out += prefix(lineNumber, ":") + String(chars[range]) + "\n"
                                }
                            }
                        } else {
                            out += prefix(lineNumber, ":") + line + "\n"
                        }
                        lastPrinted = lineNumber
                        trailing = after
                    }
                    if let limit = numbers["m"], selected >= limit { break }
                } else if trailing > 0 {
                    trailing -= 1
                    out += prefix(lineNumber, "-") + line + "\n"
                    lastPrinted = lineNumber
                } else if before > 0 {
                    history.append((lineNumber, line))
                    if history.count > before { history.removeFirst() }
                }
                if streaming || out.utf8.count > 16 * 1024 {
                    guard await ctx.put(out) else { return }
                    out = ""
                }
            }
            if file != "-" { ctx.close(fd) }
            if parsed.has("c") { out += (withName ? label + ":" : "") + "\(selected)\n" }
            if parsed.has("l"), selected > 0 { out += label + "\n" }
            if parsed.has("L"), selected == 0 { out += label + "\n" }
        }
        // grep's exit code: 0 = a line was selected, 1 = none, 2 = error.
        await ctx.emit(out, exit: hadError && !(quiet && status == 0) ? 2 : status)
    }

    // MARK: - sort

    private struct SortKey {
        var startField = 1
        var startChar = 1
        var endField: Int? = nil
        var endChar: Int? = nil
        var numeric = false
        var reverse = false
        var foldCase = false
        var ignoreBlanks = false
        var hasOwnFlags = false
    }

    private static func sortCommand(_ ctx: ProcessContext, _ arguments: [String]) async {
        guard let parsed = ctx.options("sort", arguments, "nrufbsgchVzt:k:o:",
                                       long: ["numeric-sort": "n", "reverse": "r", "unique": "u",
                                              "ignore-case": "f", "ignore-leading-blanks": "b",
                                              "stable": "s", "field-separator": "t", "key": "k",
                                              "output": "o", "check": "c"]) else { return }
        var separator: Character? = nil
        if let text = parsed.value("t") {
            guard text.count == 1 || text == "\\t" else {
                ctx.fail("sort: multi-character tab '\(text)'"); return
            }
            separator = text == "\\t" ? "\t" : text.first
        }
        var global = SortKey()
        global.numeric = parsed.has("n") || parsed.has("g") || parsed.has("h")
        global.reverse = parsed.has("r")
        global.foldCase = parsed.has("f")
        global.ignoreBlanks = parsed.has("b")

        var keys: [SortKey] = []
        for definition in parsed.all("k") {
            var key = SortKey()
            let halves = definition.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            func parseHalf(_ text: Substring, isEnd: Bool) -> Bool {
                var digits = ""
                var rest = text
                while let c = rest.first, c.isNumber { digits.append(c); rest = rest.dropFirst() }
                guard let field = Int(digits), field > 0 else { return false }
                var char: Int? = nil
                if rest.first == "." {
                    rest = rest.dropFirst()
                    var charDigits = ""
                    while let c = rest.first, c.isNumber { charDigits.append(c); rest = rest.dropFirst() }
                    guard let value = Int(charDigits) else { return false }
                    char = value
                }
                if isEnd { key.endField = field; key.endChar = char } else { key.startField = field; key.startChar = char ?? 1 }
                for flag in rest {
                    key.hasOwnFlags = true
                    switch flag {
                    case "n", "g", "h": key.numeric = true
                    case "r": key.reverse = true
                    case "f": key.foldCase = true
                    case "b": key.ignoreBlanks = true
                    default: return false
                    }
                }
                return true
            }
            guard let first = halves.first, parseHalf(first, isEnd: false),
                  halves.count < 2 || parseHalf(halves[1], isEnd: true) else {
                ctx.fail("sort: invalid field specification '\(definition)'"); return
            }
            if !key.hasOwnFlags {
                key.numeric = global.numeric
                key.reverse = global.reverse
                key.foldCase = global.foldCase
                key.ignoreBlanks = global.ignoreBlanks
            }
            keys.append(key)
        }

        let (data, status) = await readInput(ctx, cmd: "sort", files: parsed.operands)
        let lines = splitLines(data)

        /// Character ranges of each field in a line.
        func fieldRanges(_ chars: [Character]) -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            if let separator {
                var start = 0
                for (index, c) in chars.enumerated() where c == separator {
                    ranges.append(start..<index)
                    start = index + 1
                }
                ranges.append(start..<chars.count)
                return ranges
            }
            // Fields are separated by the empty string between a non-blank and a
            // blank; each field keeps its leading blanks.
            var start = 0
            var index = 0
            while index < chars.count {
                while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
                while index < chars.count, chars[index] != " ", chars[index] != "\t" { index += 1 }
                ranges.append(start..<index)
                start = index
            }
            return ranges
        }
        func extract(_ line: String, _ key: SortKey) -> String {
            let chars = Array(line)
            let fields = fieldRanges(chars)
            guard key.startField <= fields.count else { return "" }
            var begin = fields[key.startField - 1].lowerBound
            if separator == nil || key.ignoreBlanks {
                while begin < chars.count, chars[begin] == " " || chars[begin] == "\t" { begin += 1 }
            }
            begin = min(chars.count, begin + key.startChar - 1)
            var end = chars.count
            if let endField = key.endField {
                if endField <= fields.count {
                    let range = fields[endField - 1]
                    if let endChar = key.endChar, endChar > 0 {
                        var fieldStart = range.lowerBound
                        if separator == nil {
                            while fieldStart < range.upperBound, chars[fieldStart] == " " || chars[fieldStart] == "\t" { fieldStart += 1 }
                        }
                        end = min(range.upperBound, fieldStart + endChar)
                    } else {
                        end = range.upperBound
                    }
                }
            }
            return begin < end ? String(chars[begin..<end]) : ""
        }
        func numericValue(_ text: String) -> Double {
            var prefix = ""
            var seenDigit = false, seenDot = false
            for c in text.drop(while: { $0 == " " || $0 == "\t" }) {
                if c == "-" || c == "+", prefix.isEmpty { prefix.append(c) }
                else if c.isNumber { prefix.append(c); seenDigit = true }
                else if c == ".", !seenDot { prefix.append(c); seenDot = true }
                else if c == "," { continue }
                else { break }
            }
            return seenDigit ? (Double(prefix) ?? 0) : 0
        }
        func compare(_ a: String, _ b: String, _ key: SortKey) -> Int {
            var result = 0
            if key.numeric {
                let x = numericValue(a), y = numericValue(b)
                result = x < y ? -1 : (x > y ? 1 : 0)
            } else {
                var left = a, right = b
                if key.ignoreBlanks {
                    left = String(left.drop { $0 == " " || $0 == "\t" })
                    right = String(right.drop { $0 == " " || $0 == "\t" })
                }
                if key.foldCase { left = left.uppercased(); right = right.uppercased() }
                // Byte order (the C locale), not Unicode collation.
                result = left.utf8.lexicographicallyPrecedes(right.utf8) ? -1
                    : (right.utf8.lexicographicallyPrecedes(left.utf8) ? 1 : 0)
            }
            return key.reverse ? -result : result
        }
        func keyOrder(_ a: String, _ b: String) -> Int {
            if keys.isEmpty { return compare(a, b, global) }
            for key in keys {
                let result = compare(extract(a, key), extract(b, key), key)
                if result != 0 { return result }
            }
            return 0
        }
        let lastResort = !parsed.has("s") && !parsed.has("u")
        func order(_ a: String, _ b: String) -> Int {
            let result = keyOrder(a, b)
            if result != 0 || !lastResort { return result }
            let bytes = a.utf8.lexicographicallyPrecedes(b.utf8) ? -1 : (b.utf8.lexicographicallyPrecedes(a.utf8) ? 1 : 0)
            return global.reverse ? -bytes : bytes
        }

        if parsed.has("c") {
            for index in lines.indices.dropFirst() where order(lines[index - 1], lines[index]) > 0 {
                ctx.error("sort: \(parsed.operands.first ?? "-"):\(index + 1): disorder: \(lines[index])")
                ctx.exit(1)
                return
            }
            ctx.exit(status == 0 ? 0 : 2)
            return
        }

        // Decorate with the original index so equal keys keep their input order.
        var sorted = lines.enumerated().sorted { left, right in
            let result = order(left.element, right.element)
            return result != 0 ? result < 0 : left.offset < right.offset
        }.map(\.element)
        if parsed.has("u") {
            var unique: [String] = []
            for line in sorted where unique.last.map({ keyOrder($0, line) != 0 }) ?? true { unique.append(line) }
            sorted = unique
        }
        let output = joinLines(sorted)
        if let target = parsed.value("o") {
            do {
                let fd = try ctx.openForWriting(target)
                _ = await ctx.writeAll(fd, Array(output.utf8))
                ctx.close(fd)
                ctx.exit(status == 0 ? 0 : 2)
            } catch {
                ctx.fail("sort: open failed: \(target): \(errnoText(error))")
            }
            return
        }
        await ctx.emit(output, exit: status == 0 ? 0 : 2)
    }
}
