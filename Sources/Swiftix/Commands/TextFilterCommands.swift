/// Text-filter built-ins (category .text): grep/sed/head/tail/wc/sort/uniq/
/// rev/nl/cut/tee/printf/more/seq. Plain programs over the syscall surface;
/// shared helpers live in `CoreutilsSupport.swift`.
extension BuiltinCommands {

    // MARK: - Text filters (category: .text)

    static func textFilters() -> [Command] {
        [
            // grep [-i] [-v] [-n] [-c] [-F] [-E] [-e PAT] PATTERN [file...] —
            // select lines matching a regular expression (see `Regex`). `-i`
            // ignore case, `-v` invert, `-n` prefix line numbers, `-c` print only
            // the match count, `-F` treat the pattern as a fixed string, `-E`
            // extended regex (the default; accepted for familiarity), `-e PAT`
            // supply the pattern (so a pattern may start with `-`). Exits 0 if any
            // line matched, 1 if none, 2 on a usage or pattern error.
            Command(name: "grep", summary: "select lines matching a regular expression", category: .text) { ctx, argv in
                var args = Array(argv.dropFirst())
                var ignoreCase = false
                var invert = false
                var showLineNumbers = false
                var countOnly = false
                var fixedString = false
                var pattern: String? = nil

                // Parse leading options. Combined single letters (`-in`) are
                // allowed; `-e` takes the next argument as the pattern.
                parseLoop: while let first = args.first, CommandArguments.isOptionToken(first) {
                    let flags = Array(first.dropFirst())
                    var consumedNext = false
                    for (offset, flag) in flags.enumerated() {
                        switch flag {
                        case "i": ignoreCase = true
                        case "v": invert = true
                        case "n": showLineNumbers = true
                        case "c": countOnly = true
                        case "F": fixedString = true
                        case "E": break                       // extended regex is the default
                        case "e":
                            // The rest of this token, or the next argument, is the pattern.
                            let inline = String(flags[(offset + 1)...])
                            if !inline.isEmpty {
                                pattern = inline
                            } else if args.count >= 2 {
                                pattern = args[1]
                                consumedNext = true
                            } else {
                                ctx.fail("grep: option -e requires an argument"); return
                            }
                            args.removeFirst(consumedNext ? 2 : 1)
                            continue parseLoop
                        default:
                            ctx.fail("grep: unknown option -\(flag)"); return
                        }
                    }
                    args.removeFirst()
                }

                // With no `-e`, the first positional argument is the pattern.
                if pattern == nil {
                    guard let first = args.first else {
                        ctx.error("grep: usage: grep [-ivncFE] [-e pat] <pattern> [file...]")
                        ctx.exit(2)
                        return
                    }
                    pattern = first
                    args.removeFirst()
                }

                // Compile the pattern (a fixed string with `-F`, otherwise a regex).
                let regex: Regex
                if fixedString {
                    regex = Regex.literal(pattern!, ignoreCase: ignoreCase)
                } else if let compiled = Regex(pattern: pattern!, ignoreCase: ignoreCase) {
                    regex = compiled
                } else {
                    ctx.error("grep: invalid pattern: \(pattern!)")
                    ctx.exit(2)
                    return
                }

                let files = args
                collectInput(ctx, cmd: "grep", files: files) { data, status in
                    var matchCount = 0
                    var out = ""
                    for (offset, line) in splitLines(data).enumerated() {
                        if regex.matches(line) != invert {
                            matchCount += 1
                            if !countOnly {
                                out += showLineNumbers ? "\(offset + 1):\(line)\n" : line + "\n"
                            }
                        }
                    }
                    if countOnly {
                        ctx.print("\(matchCount)\n")
                    } else {
                        ctx.print(out)
                    }
                    // grep's exit code: 0 = matched, 1 = no match (unless a file
                    // error already set a non-zero status).
                    ctx.exit(matchCount > 0 ? status : (status == 0 ? 1 : status))
                }
            },

            // sed [-n] s/PATTERN/REPLACEMENT/[gip] [file...] — stream editor,
            // substitution only. Flags: `g` replace all matches on a line (not
            // just the first), `i` case-insensitive, `p` print the line when a
            // substitution happened. `-n` suppresses the default line printing
            // (pair with `p` to print only changed lines). In the replacement,
            // `&` stands for the matched text; `\&` and `\\` are literal. Any
            // single character after `s` may be the delimiter (e.g. `s|a|b|`).
            Command(name: "sed", summary: "stream editor (substitution)", category: .text) { ctx, argv in
                var args = Array(argv.dropFirst())
                var suppressAuto = false
                while args.first == "-n" { suppressAuto = true; args.removeFirst() }
                guard let script = args.first else {
                    ctx.error("sed: usage: sed [-n] s/pattern/replacement/[gip] [file...]")
                    ctx.exit(2); return
                }
                args.removeFirst()
                guard let substitution = parseSedSubstitution(script) else {
                    ctx.error("sed: -e expression: unknown or malformed command")
                    ctx.exit(2); return
                }
                guard let regex = Regex(pattern: substitution.pattern, ignoreCase: substitution.ignoreCase) else {
                    ctx.error("sed: invalid pattern: \(substitution.pattern)")
                    ctx.exit(2); return
                }
                collectInput(ctx, cmd: "sed", files: args) { data, status in
                    var out = ""
                    for line in splitLines(data) {
                        let (edited, didSubstitute) = applySed(regex: regex,
                                                               replacement: substitution.replacement,
                                                               global: substitution.global,
                                                               line: line)
                        if !suppressAuto {
                            out += edited + "\n"                    // default: print every line
                        } else if substitution.print, didSubstitute {
                            out += edited + "\n"                    // -n with p: only changed lines
                        }
                    }
                    ctx.print(out)
                    ctx.exit(status)
                }
            },

            // head [-n N] [file...] — first N lines (default 10).
            Command(name: "head", summary: "print the first lines", category: .text) { ctx, argv in
                let (count, files) = parseLineCount(argv, default: 10)
                collectInput(ctx, cmd: "head", files: files) { data, status in
                    let lines = splitLines(data)
                    ctx.print(joinLines(Array(lines.prefix(count))))
                    ctx.exit(status)
                }
            },

            // tail [-n N] [file...] — last N lines (default 10).
            Command(name: "tail", summary: "print the last lines", category: .text) { ctx, argv in
                let (count, files) = parseLineCount(argv, default: 10)
                collectInput(ctx, cmd: "tail", files: files) { data, status in
                    let lines = splitLines(data)
                    ctx.print(joinLines(Array(lines.suffix(count))))
                    ctx.exit(status)
                }
            },

            // wc [file...] — line, word, and byte counts. With multiple files,
            // prints a total line. Columns are right-aligned like GNU wc.
            Command(name: "wc", summary: "count lines, words, and bytes", category: .text) { ctx, argv in
                let files = Array(argv.dropFirst())
                if files.isEmpty {
                    // Stdin mode: single aggregate line, no filename.
                    pumpStdin(ctx) { data in
                        let lineCount = data.lazy.filter { $0 == 0x0A }.count
                        let text = String(decoding: data, as: UTF8.self)
                        let wordCount = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).count
                        let w = max(String(data.count).count, 7)
                        ctx.print("\(padLeft(String(lineCount), w)) \(padLeft(String(wordCount), w)) \(padLeft(String(data.count), w))\n")
                        ctx.exit(0)
                    }
                    return
                }
                // Multi-file mode: per-file lines + optional total.
                struct Counts { let lines: Int; let words: Int; let bytes: Int; let name: String }
                var results: [Counts] = []
                var totalLines = 0, totalWords = 0, totalBytes = 0
                var status: Int32 = 0
                for file in files {
                    guard let fd = ctx.open(file) else {
                        ctx.error("wc: \(file): No such file or directory")
                        status = 1; continue
                    }
                    let data = readFully(ctx, fd); ctx.close(fd)
                    let lineCount = data.lazy.filter { $0 == 0x0A }.count
                    let text = String(decoding: data, as: UTF8.self)
                    let wordCount = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).count
                    results.append(Counts(lines: lineCount, words: wordCount, bytes: data.count, name: file))
                    totalLines += lineCount; totalWords += wordCount; totalBytes += data.count
                }
                // Column width: widest value across all entries (including total).
                let w = max(String(totalBytes).count, 7)
                for r in results {
                    ctx.print("\(padLeft(String(r.lines), w)) \(padLeft(String(r.words), w)) \(padLeft(String(r.bytes), w)) \(r.name)\n")
                }
                if results.count > 1 {
                    ctx.print("\(padLeft(String(totalLines), w)) \(padLeft(String(totalWords), w)) \(padLeft(String(totalBytes), w)) total\n")
                }
                ctx.exit(status)
            },

            // sort [-r] [file...] — lexicographic sort of lines.
            Command(name: "sort", summary: "sort lines", category: .text) { ctx, argv in
                var args = Array(argv.dropFirst())
                var reverse = false
                if args.first == "-r" { reverse = true; args.removeFirst() }
                collectInput(ctx, cmd: "sort", files: args) { data, status in
                    var lines = splitLines(data)
                    lines.sort()
                    if reverse { lines.reverse() }
                    ctx.print(joinLines(lines))
                    ctx.exit(status)
                }
            },

            // uniq [file...] — collapse adjacent duplicate lines.
            Command(name: "uniq", summary: "collapse adjacent duplicate lines", category: .text) { ctx, argv in
                let files = Array(argv.dropFirst())
                collectInput(ctx, cmd: "uniq", files: files) { data, status in
                    var out: [String] = []
                    for line in splitLines(data) where out.last != line {
                        out.append(line)
                    }
                    ctx.print(joinLines(out))
                    ctx.exit(status)
                }
            },

            // rev [file...] — reverse the characters of each line.
            Command(name: "rev", summary: "reverse each line", category: .text) { ctx, argv in
                let files = Array(argv.dropFirst())
                collectInput(ctx, cmd: "rev", files: files) { data, status in
                    ctx.print(joinLines(splitLines(data).map { String($0.reversed()) }))
                    ctx.exit(status)
                }
            },

            // nl [file...] — number non-empty lines. Line numbers are
            // right-justified in a 6-character field followed by a tab, matching
            // the default GNU nl format.
            Command(name: "nl", summary: "number lines", category: .text) { ctx, argv in
                let files = Array(argv.dropFirst())
                collectInput(ctx, cmd: "nl", files: files) { data, status in
                    var out = ""
                    var n = 1
                    for line in splitLines(data) {
                        if line.isEmpty {
                            out += "       \n"
                        } else {
                            out += "\(padLeft(String(n), 6))\t\(line)\n"
                            n += 1
                        }
                    }
                    ctx.print(out)
                    ctx.exit(status)
                }
            },

            // cut -d DELIM -f N [file...] — print field N of each line (1-based).
            // Default delimiter is a tab. A line without the delimiter is passed
            // through unchanged (like GNU cut).
            Command(name: "cut", summary: "select a field from each line", category: .text) { ctx, argv in
                var args = Array(argv.dropFirst())
                var delimiter: Character = "\t"
                var field = 1
                while let first = args.first, CommandArguments.isOptionToken(first) {
                    switch first {
                    case "-d":
                        args.removeFirst()
                        if let d = args.first?.first { delimiter = d }
                        args.removeFirst()
                    case "-f":
                        args.removeFirst()
                        if let f = args.first.flatMap({ Int($0) }), f >= 1 { field = f }
                        args.removeFirst()
                    default:
                        ctx.error("cut: usage: cut -d <c> -f <n> [file...]")
                        ctx.exit(2)
                        return
                    }
                }
                collectInput(ctx, cmd: "cut", files: args) { data, status in
                    var out = ""
                    for line in splitLines(data) {
                        let parts = line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
                        if parts.count <= 1 {
                            out += line + "\n"          // no delimiter: pass through
                        } else if field <= parts.count {
                            out += parts[field - 1] + "\n"
                        } else {
                            out += "\n"
                        }
                    }
                    ctx.print(out)
                    ctx.exit(status)
                }
            },

            // tee [-a] file... — copy stdin to stdout and to each file.
            Command(name: "tee", summary: "copy stdin to stdout and to files", category: .text) { ctx, argv in
                var files = Array(argv.dropFirst())
                var append = false
                if files.first == "-a" { append = true; files.removeFirst() }
                pumpStdin(ctx) { data in
                    ctx.write(1, data)
                    var status: Int32 = 0
                    for file in files {
                        if let fd = ctx.open(file, create: true, truncate: !append) {
                            if append { _ = ctx.seek(fd, to: 0, whence: 2) }
                            ctx.write(fd, data)
                            ctx.close(fd)
                        } else {
                            ctx.error("tee: \(file): cannot open")
                            status = 1
                        }
                    }
                    ctx.exit(status)
                }
            },

            // printf FORMAT [args...] — minimal: %s, %d, %%, and \n \t \\ escapes.
            Command(name: "printf", summary: "format and print arguments", category: .text) { ctx, argv in
                guard argv.count > 1 else { ctx.exit(0); return }
                ctx.print(formatPrintf(argv[1], Array(argv.dropFirst(2))))
                ctx.exit(0)
            },

            // more [file...] — page through text a screen at a time. Content
            // comes from the file arguments, or from stdin (so `cmd | more`
            // works); the page-advance keypress is read from fd 2, which stays
            // wired to the terminal even in a pipeline (only fd 0 becomes the
            // pipe). Press Enter at the `--More--` prompt to show the next page.
            // Page height is `$LINES` (default 24). Content that fits on one page
            // prints without any prompt.
            Command(name: "more", summary: "page through text", category: .text, asyncRun: { ctx, argv in
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

            // seq [START [STEP]] STOP — print an arithmetic sequence, one per line.
            Command(name: "seq", summary: "print a sequence of numbers", category: .text) { ctx, argv in
                let nums = argv.dropFirst().compactMap { Int($0) }
                let start: Int, step: Int, stop: Int
                switch nums.count {
                case 1: start = 1; step = 1; stop = nums[0]
                case 2: start = nums[0]; step = 1; stop = nums[1]
                case 3: start = nums[0]; step = nums[1]; stop = nums[2]
                default:
                    ctx.error("seq: usage: seq [start [step]] stop")
                    ctx.exit(2)
                    return
                }
                guard step != 0 else { ctx.fail("seq: step cannot be 0"); return }
                var out = ""
                var value = start
                while (step > 0 && value <= stop) || (step < 0 && value >= stop) {
                    out += "\(value)\n"
                    value += step
                }
                ctx.print(out)
                ctx.exit(0)
            },
        ]
    }

}
