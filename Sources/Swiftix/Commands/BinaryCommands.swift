/// Binary-data built-ins: `cmp`, `dd`, `base64`, `od`, `xxd`, `hexdump`,
/// `strings`, `split`, and the checksum trio `md5sum` / `sha1sum` /
/// `sha256sum` (digests themselves live in `Digests.swift`).
///
/// Output formats follow the GNU / util-linux / vim tools byte for byte, since
/// scripts parse them. The dumpers (`od`, `xxd`, `hexdump`, `strings`) stream
/// their input row by row through `CommandInput`, so they work on pipes and on
/// endless device files when bounded with `-N` / `-n` / `-l` or a downstream
/// `head`; the whole-file tools (`cmp`, `base64`, `split`, checksums) read
/// their operands in full.
///
/// There is no wall clock, so `dd` reports records and byte totals but no
/// elapsed time or transfer rate.
///
/// Concurrency: plain async programs over `ProcessContext`, run on the single
/// loop-bound executor like every other built-in. Every read and write goes
/// through an `await`, so none of them blocks the event loop. No shared state.

extension BuiltinCommands {

    static func binaryCommands() -> [Command] {
        [
            cmpCommand(), ddCommand(), base64Command(), odCommand(), xxdCommand(),
            hexdumpCommand(), stringsCommand(), splitCommand(),
            checksumCommand("md5sum", .md5, title: "MD5"),
            checksumCommand("sha1sum", .sha1, title: "SHA1"),
            checksumCommand("sha256sum", .sha256, title: "SHA256"),
        ]
    }

    // MARK: - Shared helpers

    /// Append `value` in `radix`, left-padded with `pad` to `width` columns.
    static func appendNumber(_ out: inout [UInt8],
                             _ value: UInt64,
                             radix: UInt64,
                             width: Int = 0,
                             pad: UInt8 = 0x30,
                             uppercase: Bool = false) {
        var digits: [UInt8] = []
        var rest = value
        repeat {
            let digit = UInt8(rest % radix)
            digits.append(digit < 10 ? 0x30 + digit : (uppercase ? 0x41 : 0x61) + digit - 10)
            rest /= radix
        } while rest != 0
        if digits.count < width {
            out.append(contentsOf: repeatElement(pad, count: width - digits.count))
        }
        out.append(contentsOf: digits.reversed())
    }

    /// `value` in `radix`, left-padded with `pad` to `width` columns.
    static func numberString(_ value: Int, radix: Int, width: Int = 0, pad: Character = "0") -> String {
        var out: [UInt8] = []
        appendNumber(&out, UInt64(max(0, value)), radix: UInt64(radix), width: width,
                     pad: pad.asciiValue ?? 0x30)
        return String(decoding: out, as: UTF8.self)
    }

    /// Append `text` right-aligned in `width` columns.
    private static func appendRight(_ out: inout [UInt8], _ text: [UInt8], width: Int) {
        if text.count < width {
            out.append(contentsOf: repeatElement(0x20, count: width - text.count))
        }
        out.append(contentsOf: text)
    }

    /// A byte count the way `dd`, `split -b`, and `od -N` accept it: a decimal
    /// (or, with `allowHex`, `0x` hex / leading-`0` octal) number with an
    /// optional multiplier suffix — `c`=1, `w`=2, `b`=512, `K`/`k`=1024,
    /// `M`=1024², `G`=1024³ (also spelled `KiB`…), `kB`/`KB`=1000, `MB`, `GB`
    /// — and `x`-separated products (`2x512`).
    static func parseByteCount(_ text: String, allowHex: Bool = false) -> Int? {
        if !allowHex || !text.lowercased().hasPrefix("0x"), text.contains("x") {
            var product = 1
            for part in text.split(separator: "x", omittingEmptySubsequences: false) {
                guard let value = parseByteCount(String(part), allowHex: false) else { return nil }
                let (result, overflow) = product.multipliedReportingOverflow(by: value)
                if overflow { return nil }
                product = result
            }
            return product
        }
        var digits = Substring(text)
        var radix = 10
        if allowHex {
            if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
                digits = digits.dropFirst(2)
                radix = 16
            } else if digits.hasPrefix("0"), digits.count > 1, digits.dropFirst().first?.isNumber == true {
                radix = 8
            }
        }
        var end = digits.startIndex
        while end < digits.endIndex, digits[end].isHexDigit,
              radix == 16 || digits[end].isNumber {
            // In decimal `b` is the 512-byte suffix, not a digit.
            end = digits.index(after: end)
        }
        guard end > digits.startIndex, let value = Int(digits[..<end], radix: radix) else { return nil }
        let suffix = String(digits[end...])
        let multiplier: Int
        switch suffix {
        case "": multiplier = 1
        case "c": multiplier = 1
        case "w": multiplier = 2
        case "b": multiplier = 512
        case "k", "K", "KiB": multiplier = 1024
        case "kB", "KB": multiplier = 1000
        case "m", "M", "MiB": multiplier = 1024 * 1024
        case "MB": multiplier = 1000 * 1000
        case "g", "G", "GiB": multiplier = 1024 * 1024 * 1024
        case "GB": multiplier = 1000 * 1000 * 1000
        default: return nil
        }
        let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return overflow ? nil : result
    }

    /// Incremental row reader for the dumpers: skips `skip` bytes of the
    /// combined input, delivers at most `limit` bytes after that, and hands
    /// them out `width` at a time (the last row may be short).
    private struct RowReader {
        let input: CommandInput
        let width: Int
        var remainingSkip: Int
        var remainingLimit: Int?
        /// Offset (within the combined input) of the next row.
        private(set) var offset: Int
        private var buffer: [UInt8] = []
        private var start = 0
        private var ended = false

        init(_ input: CommandInput, width: Int, skip: Int, limit: Int?) {
            self.input = input
            self.width = width
            self.remainingSkip = skip
            self.remainingLimit = limit
            self.offset = skip
        }

        /// True when the input ended before `skip` bytes were consumed.
        var skippedPastEnd: Bool { ended && remainingSkip > 0 }

        mutating func next() async -> [UInt8]? {
            while buffer.count - start < width, !ended {
                if remainingLimit == 0 { ended = true; break }
                let want = remainingSkip > 0 ? 65536 : Swift.min(65536, remainingLimit ?? 65536)
                guard var chunk = await input.chunk(max: want) else { ended = true; break }
                if remainingSkip > 0 {
                    let dropped = Swift.min(remainingSkip, chunk.count)
                    remainingSkip -= dropped
                    chunk.removeFirst(dropped)
                    if chunk.isEmpty { continue }
                }
                if let limit = remainingLimit {
                    if chunk.count > limit { chunk.removeLast(chunk.count - limit) }
                    remainingLimit = limit - chunk.count
                }
                if start > 0 {
                    buffer.removeFirst(start)
                    start = 0
                }
                buffer.append(contentsOf: chunk)
            }
            let count = Swift.min(width, buffer.count - start)
            guard count > 0 else { return nil }
            let row = Array(buffer[start..<(start + count)])
            start += count
            offset += count
            return row
        }
    }

    private static func isPrintable(_ byte: UInt8) -> Bool { byte >= 0x20 && byte < 0x7F }

    // MARK: - cmp

    private static func cmpCommand() -> Command {
        Command(name: "cmp", summary: "compare two files byte by byte", category: .fileSystem, usage: """
            cmp [-l] [-s] FILE1 [FILE2]
              -l  print the byte number and both byte values (octal) of every difference
              -s  print nothing; only the exit status reports the result
              FILE2 defaults to standard input; '-' names standard input.
              Exit status: 0 identical, 1 different, 2 trouble.
            """, asyncRun: { ctx, argv in
            guard let opts = ctx.options("cmp", Array(argv.dropFirst()), "ls",
                                         long: ["verbose": "l", "silent": "s", "quiet": "s"]) else { return }
            guard let first = opts.operands.first else {
                ctx.error("cmp: missing operand after 'cmp'")
                ctx.fail("Try 'cmp --help' for more information.")
                return
            }
            guard opts.operands.count <= 2 else {
                ctx.error("cmp: extra operand '\(opts.operands[2])'")
                ctx.fail("Try 'cmp --help' for more information.")
                return
            }
            let second = opts.operands.count > 1 ? opts.operands[1] : "-"
            let silent = opts.has("s")
            var contents: [[UInt8]] = []
            for name in [first, second] {
                do {
                    contents.append(try await readOperand(ctx, name))
                } catch {
                    if !silent { ctx.error("cmp: \(name): \(errnoText(error))") }
                    ctx.exit(2)
                    return
                }
            }
            let a = contents[0], b = contents[1]
            let common = Swift.min(a.count, b.count)
            var status: Int32 = 0
            var out: [UInt8] = []
            if opts.has("l"), !silent {
                var width = 1
                var rest = common / 10
                while rest != 0 { width += 1; rest /= 10 }
                for index in 0..<common where a[index] != b[index] {
                    status = 1
                    appendNumber(&out, UInt64(index + 1), radix: 10, width: width, pad: 0x20)
                    out.append(0x20)
                    appendNumber(&out, UInt64(a[index]), radix: 8, width: 3, pad: 0x20)
                    out.append(0x20)
                    appendNumber(&out, UInt64(b[index]), radix: 8, width: 3, pad: 0x20)
                    out.append(0x0A)
                }
                guard await ctx.put(out) else { return }
            } else {
                var line = 1
                for index in 0..<common {
                    if a[index] != b[index] {
                        status = 1
                        if !silent {
                            guard await ctx.put("\(first) \(second) differ: byte \(index + 1), line \(line)\n") else { return }
                        }
                        break
                    }
                    if a[index] == 0x0A { line += 1 }
                }
            }
            if a.count != b.count, status == 0 || opts.has("l") {
                status = 1
                if !silent {
                    let shorter = a.count < b.count ? first : second
                    if common == 0 {
                        ctx.error("cmp: EOF on \(shorter) which is empty")
                    } else {
                        ctx.error("cmp: EOF on \(shorter) after byte \(common)")
                    }
                }
            }
            ctx.exit(status)
        })
    }

    // MARK: - dd

    private static func ddCommand() -> Command {
        Command(name: "dd", summary: "convert and copy a file", category: .fileSystem, usage: """
            dd [if=FILE] [of=FILE] [bs=N] [count=N] [skip=N] [seek=N] [conv=CONVS] [status=LEVEL]
              if=FILE       read from FILE instead of standard input
              of=FILE       write to FILE instead of standard output
              bs=N          read and write up to N bytes at a time (default 512)
              ibs=N, obs=N  set the input / output block size separately
              count=N       copy only N input blocks
              skip=N        skip N input blocks before copying
              seek=N        skip N output blocks before writing
              conv=CONVS    comma-separated: notrunc, sync, ucase, lcase, noerror, fsync, fdatasync
              iflag=fullblock  accumulate full input blocks from short reads
              status=LEVEL  none suppresses everything, noxfer the byte total
              N may carry a suffix: c=1, w=2, b=512, K=1024, M=1024^2, G=1024^3, kB=1000, MB, GB.
            """, asyncRun: { ctx, argv in
            var inputPath: String? = nil
            var outputPath: String? = nil
            var inputBlock = 512
            var outputBlock = 512
            var reblock = false           // ibs/obs given without bs: re-block the output
            var count: Int? = nil
            var skip = 0
            var seek = 0
            var keepExisting = false
            var padBlocks = false
            var upper = false
            var lower = false
            var fullBlock = false
            var showRecords = true
            var showTotal = true

            for argument in argv.dropFirst() {
                guard let equals = argument.firstIndex(of: "=") else {
                    ctx.error("dd: unrecognized operand '\(argument)'")
                    ctx.fail("Try 'dd --help' for more information.", code: 1)
                    return
                }
                let key = String(argument[..<equals])
                let value = String(argument[argument.index(after: equals)...])
                func number(positive: Bool) -> Int? {
                    guard let parsed = parseByteCount(value), parsed >= (positive ? 1 : 0) else {
                        ctx.fail("dd: invalid number: '\(value)'", code: 1)
                        return nil
                    }
                    return parsed
                }
                if key == "if" {
                    inputPath = value
                } else if key == "of" {
                    outputPath = value
                } else if key == "bs" {
                    guard let parsed = number(positive: true) else { return }
                    inputBlock = parsed
                    outputBlock = parsed
                    reblock = false
                } else if key == "ibs" {
                    guard let parsed = number(positive: true) else { return }
                    inputBlock = parsed
                    reblock = true
                } else if key == "obs" {
                    guard let parsed = number(positive: true) else { return }
                    outputBlock = parsed
                    reblock = true
                } else if key == "count" {
                    guard let parsed = number(positive: false) else { return }
                    count = parsed
                } else if key == "skip" || key == "iseek" {
                    guard let parsed = number(positive: false) else { return }
                    skip = parsed
                } else if key == "seek" || key == "oseek" {
                    guard let parsed = number(positive: false) else { return }
                    seek = parsed
                } else if key == "conv" {
                    for conversion in value.split(separator: ",") {
                        if conversion == "notrunc" {
                            keepExisting = true
                        } else if conversion == "sync" {
                            padBlocks = true
                        } else if conversion == "ucase" {
                            upper = true
                        } else if conversion == "lcase" {
                            lower = true
                        } else if conversion == "noerror" || conversion == "fsync" || conversion == "fdatasync" {
                            continue
                        } else {
                            ctx.fail("dd: invalid conversion: '\(conversion)'", code: 1)
                            return
                        }
                    }
                } else if key == "iflag" || key == "oflag" {
                    for flag in value.split(separator: ",") {
                        if flag == "fullblock", key == "iflag" {
                            fullBlock = true
                        } else {
                            ctx.fail("dd: invalid \(key == "iflag" ? "input" : "output") flag: '\(flag)'", code: 1)
                            return
                        }
                    }
                } else if key == "status" {
                    if value == "none" {
                        showRecords = false
                        showTotal = false
                    } else if value == "noxfer" {
                        showTotal = false
                    } else if value != "progress" {
                        ctx.fail("dd: invalid status level: '\(value)'", code: 1)
                        return
                    }
                } else {
                    ctx.error("dd: unrecognized operand '\(argument)'")
                    ctx.fail("Try 'dd --help' for more information.", code: 1)
                    return
                }
            }
            if upper, lower {
                ctx.fail("dd: cannot combine lcase and ucase", code: 1)
                return
            }

            // Input.
            var inputFD = 0
            if let inputPath {
                do {
                    inputFD = try ctx.openFile(inputPath)
                } catch {
                    ctx.fail("dd: failed to open '\(inputPath)': \(errnoText(error))", code: 1)
                    return
                }
            }
            defer { if inputPath != nil { ctx.close(inputFD) } }

            // Output. Without `conv=notrunc` the file is cut at the seek offset,
            // which (there being no ftruncate) means re-writing the kept prefix.
            let (seekBytes, seekOverflow) = seek.multipliedReportingOverflow(by: outputBlock)
            let (skipBytes, skipOverflow) = skip.multipliedReportingOverflow(by: inputBlock)
            guard !seekOverflow, !skipOverflow else {
                ctx.fail("dd: invalid number: offset too large", code: 1)
                return
            }
            var outputFD = 1
            var keptPrefix = 0
            if let outputPath {
                do {
                    var prefix: [UInt8] = []
                    if seekBytes > 0, !keepExisting,
                       let info = ctx.stat(outputPath), info.type == .regular {
                        let existing = try await readOperand(ctx, outputPath)
                        prefix = Array(existing.prefix(seekBytes))
                    }
                    outputFD = try ctx.openForWriting(outputPath, truncate: !keepExisting)
                    if !prefix.isEmpty {
                        guard await ctx.writeAll(outputFD, prefix) else {
                            ctx.fail("dd: error writing '\(outputPath)'", code: 1)
                            return
                        }
                        keptPrefix = prefix.count
                    }
                } catch {
                    ctx.fail("dd: failed to open '\(outputPath)': \(errnoText(error))", code: 1)
                    return
                }
            }
            defer { if outputPath != nil { ctx.close(outputFD) } }
            if seekBytes > 0 {
                guard ctx.seek(outputFD, to: seekBytes, whence: outputPath == nil ? 1 : 0) != nil else {
                    ctx.fail("dd: '\(outputPath ?? "standard output")': cannot seek: Illegal seek", code: 1)
                    return
                }
            }

            // Skip input blocks: by seeking when possible, by reading otherwise.
            if skipBytes > 0, ctx.seek(inputFD, to: skipBytes, whence: 1) == nil {
                var remaining = skipBytes
                while remaining > 0 {
                    let bytes: [UInt8]
                    do {
                        bytes = try await ctx.read(inputFD, upTo: Swift.min(remaining, 65536))
                    } catch {
                        return
                    }
                    if bytes.isEmpty { break }
                    remaining -= bytes.count
                }
            }

            var fullIn = 0, partialIn = 0, fullOut = 0, partialOut = 0, total = 0
            var pending: [UInt8] = []
            var records = 0
            func writeBlock(_ bytes: [UInt8]) async -> Bool {
                guard await ctx.writeAll(outputFD, bytes) else {
                    if let outputPath { ctx.fail("dd: error writing '\(outputPath)'", code: 1) }
                    return false
                }
                if bytes.count == outputBlock { fullOut += 1 } else { partialOut += 1 }
                total += bytes.count
                return true
            }
            while count.map({ records < $0 }) ?? true {
                var block: [UInt8]
                do {
                    block = try await ctx.read(inputFD, upTo: inputBlock)
                    while fullBlock, !block.isEmpty, block.count < inputBlock {
                        let more = try await ctx.read(inputFD, upTo: inputBlock - block.count)
                        if more.isEmpty { break }
                        block.append(contentsOf: more)
                    }
                } catch SyscallError.interrupted {
                    return
                } catch {
                    ctx.fail("dd: error reading '\(inputPath ?? "standard input")': \(errnoText(error))", code: 1)
                    return
                }
                if block.isEmpty { break }
                records += 1
                if block.count == inputBlock {
                    fullIn += 1
                } else {
                    partialIn += 1
                    if padBlocks {
                        block.append(contentsOf: repeatElement(0, count: inputBlock - block.count))
                    }
                }
                if upper || lower {
                    for index in block.indices {
                        let byte = block[index]
                        if upper, byte >= 0x61, byte <= 0x7A { block[index] = byte - 0x20 }
                        if lower, byte >= 0x41, byte <= 0x5A { block[index] = byte + 0x20 }
                    }
                }
                if !reblock {
                    guard await writeBlock(block) else { return }
                    continue
                }
                pending.append(contentsOf: block)
                var consumed = 0
                while pending.count - consumed >= outputBlock {
                    guard await writeBlock(Array(pending[consumed..<(consumed + outputBlock)])) else { return }
                    consumed += outputBlock
                }
                if consumed > 0 { pending.removeFirst(consumed) }
            }
            if !pending.isEmpty {
                guard await writeBlock(pending) else { return }
            }
            // A truncating seek with nothing written still extends the file to
            // the seek offset (what ftruncate would have done).
            if outputPath != nil, !keepExisting, total == 0, seekBytes > keptPrefix {
                _ = ctx.seek(outputFD, to: keptPrefix, whence: 0)
                _ = await ctx.writeAll(outputFD, [UInt8](repeating: 0, count: seekBytes - keptPrefix))
            }

            if showRecords {
                ctx.error("\(fullIn)+\(partialIn) records in")
                ctx.error("\(fullOut)+\(partialOut) records out")
            }
            if showTotal {
                ctx.error("\(total) \(total == 1 ? "byte" : "bytes") copied")
            }
            ctx.exit(0)
        })
    }

    // MARK: - base64

    private static let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    static func base64Encode(_ data: [UInt8], wrap: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count / 3 * 4 + data.count / 48 + 8)
        var column = 0
        func push(_ byte: UInt8) {
            out.append(byte)
            column += 1
            if wrap > 0, column == wrap {
                out.append(0x0A)
                column = 0
            }
        }
        var index = 0
        while index < data.count {
            let b0 = data[index]
            let b1: UInt8? = index + 1 < data.count ? data[index + 1] : nil
            let b2: UInt8? = index + 2 < data.count ? data[index + 2] : nil
            push(base64Alphabet[Int(b0 >> 2)])
            push(base64Alphabet[Int((b0 & 0x03) << 4 | (b1 ?? 0) >> 4)])
            if let b1 {
                push(base64Alphabet[Int((b1 & 0x0F) << 2 | (b2 ?? 0) >> 6)])
            } else {
                push(0x3D)
            }
            if let b2 {
                push(base64Alphabet[Int(b2 & 0x3F)])
            } else {
                push(0x3D)
            }
            index += 3
        }
        if wrap > 0, column > 0 { out.append(0x0A) }
        return out
    }

    /// Decode base64 text. Newlines (and other ASCII whitespace) are skipped;
    /// with `ignoreGarbage` so is every other non-alphabet byte. `valid` is
    /// false when the input is malformed — `bytes` then holds what decoded
    /// cleanly before the problem.
    static func base64Decode(_ text: [UInt8], ignoreGarbage: Bool) -> (bytes: [UInt8], valid: Bool) {
        var table = [Int8](repeating: -1, count: 256)
        for (value, character) in base64Alphabet.enumerated() { table[Int(character)] = Int8(value) }
        var out: [UInt8] = []
        out.reserveCapacity(text.count / 4 * 3)
        var group: [UInt8] = []
        var paddingNeeded = 0
        func flush() -> Bool {
            if group.count == 1 { return false }
            if group.count >= 2 { out.append(group[0] << 2 | group[1] >> 4) }
            if group.count >= 3 { out.append(group[1] << 4 | group[2] >> 2) }
            if group.count == 4 { out.append(group[2] << 6 | group[3]) }
            group.removeAll(keepingCapacity: true)
            return true
        }
        for byte in text {
            if byte == 0x0A || byte == 0x0D || byte == 0x20 || byte == 0x09 { continue }
            if byte == 0x3D {
                if paddingNeeded > 0 {
                    paddingNeeded -= 1
                    continue
                }
                guard group.count == 2 || group.count == 3 else {
                    if ignoreGarbage { continue }
                    return (out, false)
                }
                paddingNeeded = 3 - group.count
                _ = flush()
                continue
            }
            let value = table[Int(byte)]
            if value < 0 {
                if ignoreGarbage { continue }
                return (out, false)
            }
            if paddingNeeded > 0 { return (out, false) }
            group.append(UInt8(value))
            if group.count == 4 { _ = flush() }
        }
        if paddingNeeded > 0 { return (out, false) }
        if !group.isEmpty {
            // An unpadded final quantum still yields its bytes, then the error.
            _ = flush()
            return (out, false)
        }
        return (out, true)
    }

    private static func base64Command() -> Command {
        Command(name: "base64", summary: "base64 encode or decode data", category: .text, usage: """
            base64 [-d] [-i] [-w COLS] [FILE]
              -d       decode
              -i       when decoding, ignore non-alphabet characters
              -w COLS  wrap encoded lines after COLS characters (default 76; 0 disables wrapping)
              With no FILE, or when FILE is -, read standard input.
            """, asyncRun: { ctx, argv in
            guard let opts = ctx.options("base64", Array(argv.dropFirst()), "diw:",
                                         long: ["decode": "d", "ignore-garbage": "i", "wrap": "w"]) else { return }
            var wrap = 76
            if let text = opts.value("w") {
                guard let parsed = Int(text), parsed >= 0 else {
                    ctx.fail("base64: invalid wrap size: '\(text)'", code: 1)
                    return
                }
                wrap = parsed
            }
            guard opts.operands.count <= 1 else {
                ctx.error("base64: extra operand '\(opts.operands[1])'")
                ctx.fail("Try 'base64 --help' for more information.", code: 1)
                return
            }
            let name = opts.operands.first ?? "-"
            let data: [UInt8]
            do {
                data = try await readOperand(ctx, name)
            } catch {
                ctx.fail("base64: \(name): \(errnoText(error))", code: 1)
                return
            }
            if opts.has("d") {
                let (bytes, valid) = base64Decode(data, ignoreGarbage: opts.has("i"))
                guard await ctx.put(bytes) else { return }
                if valid {
                    ctx.exit(0)
                } else {
                    ctx.fail("base64: invalid input", code: 1)
                }
            } else {
                await ctx.emit(base64Encode(data, wrap: wrap))
            }
        })
    }

    // MARK: - od

    /// One `od` output type: a kind (`o`ctal, he`x`, signed `d`ecimal,
    /// `u`nsigned, `c`haracter, n`a`med character), a unit size in bytes, and
    /// the widest text one unit can produce.
    private struct DumpType {
        var kind: Character
        var size: Int

        var printWidth: Int {
            if kind == "c" || kind == "a" { return 3 }
            if kind == "x" { return size * 2 }
            if kind == "o" { return [1: 3, 2: 6, 4: 11, 8: 22][size] ?? 3 }
            if kind == "u" { return [1: 3, 2: 5, 4: 10, 8: 20][size] ?? 3 }
            return [1: 4, 2: 6, 4: 11, 8: 20][size] ?? 4
        }
    }

    /// Parse a `-t` type string such as `x1`, `o2`, `c`, or a run of them
    /// (`x1c`). Size letters `C`/`S`/`I`/`L` are accepted like digits.
    private static func parseDumpTypes(_ text: String) -> [DumpType]? {
        var types: [DumpType] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let kind = characters[index]
            index += 1
            if kind == "a" || kind == "c" {
                types.append(DumpType(kind: kind, size: 1))
                continue
            }
            guard kind == "d" || kind == "o" || kind == "u" || kind == "x" else { return nil }
            var size = 4
            if index < characters.count {
                let next = characters[index]
                if let named = ["C": 1, "S": 2, "I": 4, "L": 8][next] {
                    size = named
                    index += 1
                } else if next.isNumber {
                    var digits = ""
                    while index < characters.count, characters[index].isNumber {
                        digits.append(characters[index])
                        index += 1
                    }
                    guard let parsed = Int(digits), [1, 2, 4, 8].contains(parsed) else { return nil }
                    size = parsed
                }
            }
            types.append(DumpType(kind: kind, size: size))
        }
        return types.isEmpty ? nil : types
    }

    private static let namedCharacters: [String] = [
        "nul", "soh", "stx", "etx", "eot", "enq", "ack", "bel", "bs", "ht", "nl", "vt", "ff", "cr", "so", "si",
        "dle", "dc1", "dc2", "dc3", "dc4", "nak", "syn", "etb", "can", "em", "sub", "esc", "fs", "gs", "rs", "us",
        "sp",
    ]

    /// The text of one unit of `type` starting at `index` in `row` (missing
    /// trailing bytes of a multi-byte unit read as zero; little-endian).
    private static func dumpUnit(_ type: DumpType, _ row: [UInt8], _ index: Int) -> [UInt8] {
        if type.kind == "c" {
            let byte = row[index]
            if byte == 0 { return [0x5C, 0x30] }
            if byte == 7 { return [0x5C, 0x61] }
            if byte == 8 { return [0x5C, 0x62] }
            if byte == 9 { return [0x5C, 0x74] }
            if byte == 10 { return [0x5C, 0x6E] }
            if byte == 11 { return [0x5C, 0x76] }
            if byte == 12 { return [0x5C, 0x66] }
            if byte == 13 { return [0x5C, 0x72] }
            if isPrintable(byte) { return [byte] }
            var out: [UInt8] = []
            appendNumber(&out, UInt64(byte), radix: 8, width: 3)
            return out
        }
        if type.kind == "a" {
            let byte = row[index] & 0x7F
            if byte == 0x7F { return Array("del".utf8) }
            if byte <= 0x20 { return Array(namedCharacters[Int(byte)].utf8) }
            return [byte]
        }
        var value: UInt64 = 0
        for offset in 0..<type.size where index + offset < row.count {
            value |= UInt64(row[index + offset]) << UInt64(offset * 8)
        }
        var out: [UInt8] = []
        if type.kind == "x" {
            appendNumber(&out, value, radix: 16, width: type.size * 2)
        } else if type.kind == "o" {
            appendNumber(&out, value, radix: 8, width: type.printWidth)
        } else if type.kind == "u" {
            appendNumber(&out, value, radix: 10)
        } else {
            let bits = UInt64(type.size * 8)
            var signed = Int64(bitPattern: value)
            if bits < 64, value & (1 << (bits - 1)) != 0 {
                signed = Int64(bitPattern: value | ~((1 << bits) - 1))
            }
            out = Array(String(signed).utf8)
        }
        return out
    }

    private static func odCommand() -> Command {
        Command(name: "od", summary: "dump files in octal and other formats", category: .text, usage: """
            od [-A RADIX] [-t TYPE]... [-abcdiloxsv] [-j SKIP] [-N COUNT] [-w BYTES] [FILE]...
              -A RADIX  offset radix: o (octal, default), x (hex), d (decimal), n (none)
              -t TYPE   output type: a, c, d[SIZE], o[SIZE], u[SIZE], x[SIZE] with SIZE 1, 2, 4 or 8
              -a        same as -t a (named characters)
              -b        same as -t o1 (octal bytes)
              -c        same as -t c (characters with backslash escapes)
              -d        same as -t u2 (unsigned decimal 2-byte units)
              -i        same as -t d4;  -l same as -t d8;  -s same as -t d2
              -o        same as -t o2 (octal 2-byte units, the default)
              -x        same as -t x2 (hexadecimal 2-byte units)
              -j SKIP   skip SKIP input bytes first
              -N COUNT  dump at most COUNT bytes
              -v        do not replace repeated lines with *
              -w BYTES  bytes per output line (default 16)
            """, asyncRun: { ctx, argv in
            guard let opts = ctx.options("od", Array(argv.dropFirst()), "abcdilosxvA:t:N:j:w:",
                                         long: ["address-radix": "A", "format": "t", "read-bytes": "N",
                                                "skip-bytes": "j", "output-duplicates": "v", "width": "w"]) else { return }
            var types: [DumpType] = []
            let shorthand: [Character: DumpType] = [
                "a": DumpType(kind: "a", size: 1), "b": DumpType(kind: "o", size: 1),
                "c": DumpType(kind: "c", size: 1), "d": DumpType(kind: "u", size: 2),
                "i": DumpType(kind: "d", size: 4), "l": DumpType(kind: "d", size: 8),
                "o": DumpType(kind: "o", size: 2), "s": DumpType(kind: "d", size: 2),
                "x": DumpType(kind: "x", size: 2),
            ]
            for (option, value) in opts.sequence {
                if option == "t", let value {
                    guard let parsed = parseDumpTypes(value) else {
                        ctx.fail("od: invalid type string '\(value)'", code: 1)
                        return
                    }
                    types.append(contentsOf: parsed)
                } else if let type = shorthand[option] {
                    types.append(type)
                }
            }
            if types.isEmpty { types = [DumpType(kind: "o", size: 2)] }

            var offsetRadix: UInt64 = 8
            var offsetWidth = 7
            if let radix = opts.value("A") {
                if radix == "o" {
                    offsetRadix = 8
                } else if radix == "x" {
                    offsetRadix = 16
                    offsetWidth = 6
                } else if radix == "d" {
                    offsetRadix = 10
                } else if radix == "n" {
                    offsetWidth = 0
                } else {
                    ctx.error("od: invalid output address radix '\(radix.first ?? " ")'; it must be one character from [doxn]")
                    ctx.fail("Try 'od --help' for more information.", code: 1)
                    return
                }
            }
            var skip = 0
            var limit: Int? = nil
            if let text = opts.value("j") {
                guard let parsed = parseByteCount(text, allowHex: true) else {
                    ctx.fail("od: invalid -j argument '\(text)'", code: 1)
                    return
                }
                skip = parsed
            }
            if let text = opts.value("N") {
                guard let parsed = parseByteCount(text, allowHex: true) else {
                    ctx.fail("od: invalid -N argument '\(text)'", code: 1)
                    return
                }
                limit = parsed
            }

            // Column alignment across types: every block of `unit` bytes (the
            // least common multiple of the unit sizes — all powers of two, so
            // the largest) takes the same width in each type's line.
            let unit = types.map(\.size).max() ?? 1
            let blockWidth = types.map { ($0.printWidth + 1) * (unit / $0.size) }.max() ?? 4
            var lineBytes = 16
            if let text = opts.value("w") {
                guard let parsed = Int(text), parsed > 0 else {
                    ctx.fail("od: invalid -w argument '\(text)'", code: 1)
                    return
                }
                lineBytes = Swift.max(unit, parsed / unit * unit)
            }

            let input = CommandInput(ctx, command: "od", files: opts.operands)
            var reader = RowReader(input, width: lineBytes, skip: skip, limit: limit)
            var out: [UInt8] = []
            var previous: [UInt8]? = nil
            var squeezing = false
            let verbose = opts.has("v")
            while true {
                let rowOffset = reader.offset
                guard let row = await reader.next() else { break }
                if !verbose, row.count == lineBytes, row == previous {
                    if !squeezing {
                        out.append(contentsOf: [0x2A, 0x0A])
                        squeezing = true
                    }
                    continue
                }
                squeezing = false
                previous = row
                for (position, type) in types.enumerated() {
                    if offsetWidth > 0 {
                        if position == 0 {
                            appendNumber(&out, UInt64(rowOffset), radix: offsetRadix, width: offsetWidth)
                        } else {
                            out.append(contentsOf: repeatElement(0x20, count: offsetWidth))
                        }
                    }
                    let fieldWidth = blockWidth / (unit / type.size)
                    var index = 0
                    while index < row.count {
                        appendRight(&out, dumpUnit(type, row, index), width: fieldWidth)
                        index += type.size
                    }
                    out.append(0x0A)
                }
                if out.count >= 16384 {
                    guard await ctx.put(out) else { return }
                    out.removeAll(keepingCapacity: true)
                }
            }
            if reader.skippedPastEnd {
                _ = await ctx.put(out)
                ctx.fail("od: cannot skip past end of combined input", code: 1)
                return
            }
            if offsetWidth > 0 {
                appendNumber(&out, UInt64(reader.offset), radix: offsetRadix, width: offsetWidth)
                out.append(0x0A)
            }
            await ctx.emit(out, exit: input.status)
        })
    }

    // MARK: - xxd

    /// A number the way `xxd` reads one: decimal, `0x` hex, or leading-`0` octal.
    private static func parseCNumber(_ text: String) -> Int? {
        if text.hasPrefix("0x") || text.hasPrefix("0X") { return Int(text.dropFirst(2), radix: 16) }
        if text.hasPrefix("0"), text.count > 1 { return Int(text.dropFirst(), radix: 8) }
        return Int(text)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        if byte >= 0x30, byte <= 0x39 { return byte - 0x30 }
        if byte >= 0x61, byte <= 0x66 { return byte - 0x61 + 10 }
        if byte >= 0x41, byte <= 0x46 { return byte - 0x41 + 10 }
        return nil
    }

    /// Rebuild binary data from an `xxd` dump. Plain mode takes every hex pair;
    /// normal mode honors each line's address (later lines may overwrite or
    /// leave zero-filled gaps) and stops at the ASCII column.
    static func xxdRevert(_ text: [UInt8], plain: Bool) -> [UInt8] {
        var out: [UInt8] = []
        if plain {
            var high: UInt8? = nil
            for byte in text {
                guard let value = hexValue(byte) else { continue }
                if let first = high {
                    out.append(first << 4 | value)
                    high = nil
                } else {
                    high = value
                }
            }
            return out
        }
        for line in text.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let bytes = Array(line)
            var index = 0
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
            var address = 0
            var sawAddress = false
            while index < bytes.count, let value = hexValue(bytes[index]) {
                address = address &* 16 &+ Int(value)
                sawAddress = true
                index += 1
            }
            guard sawAddress, index < bytes.count, bytes[index] == 0x3A else { continue }
            index += 1
            if index < bytes.count, bytes[index] == 0x20 { index += 1 }
            var position = address
            while index + 1 < bytes.count {
                if bytes[index] == 0x20 {
                    // One space separates groups; two end the hex column.
                    if bytes[index + 1] == 0x20 { break }
                    index += 1
                    continue
                }
                guard let high = hexValue(bytes[index]), let low = hexValue(bytes[index + 1]) else { break }
                if position > out.count {
                    out.append(contentsOf: repeatElement(0, count: position - out.count))
                }
                if position < out.count {
                    out[position] = high << 4 | low
                } else {
                    out.append(high << 4 | low)
                }
                position += 1
                index += 2
            }
        }
        return out
    }

    private static func xxdCommand() -> Command {
        Command(name: "xxd", summary: "make a hex dump or do the reverse", category: .text, usage: """
            xxd [-r] [-p] [-u] [-c COLS] [-g BYTES] [-l LEN] [-s SEEK] [INFILE [OUTFILE]]
              -r        reverse: convert a hex dump (normal or, with -p, plain) back to binary
              -p        plain hex dump: no offsets, no ASCII column (30 bytes per line)
              -u        use upper-case hex letters
              -c COLS   bytes per line (default 16; 30 with -p)
              -g BYTES  bytes per group (default 2; 0 for no grouping)
              -l LEN    stop after LEN bytes
              -s SEEK   start at byte SEEK (+N from the start, -N from the end of INFILE)
            """, asyncRun: { ctx, argv in
            var revert = false
            var plain = false
            var upper = false
            var columns: Int? = nil
            var group = 2
            var length: Int? = nil
            var seekText: String? = nil
            var operands: [String] = []
            let args = Array(argv.dropFirst())
            var index = 0
            while index < args.count {
                let token = args[index]
                index += 1
                if token == "--" {
                    operands.append(contentsOf: args[index...])
                    break
                }
                if !CommandArguments.isOptionToken(token) {
                    operands.append(token)
                    continue
                }
                if token == "-r" || token == "-revert" {
                    revert = true
                } else if token == "-p" || token == "-ps" || token == "-plain" || token == "-postscript" {
                    plain = true
                } else if token == "-u" || token == "-uppercase" {
                    upper = true
                } else if token == "-a" || token == "-autoskip" {
                    continue
                } else {
                    // Valued options: `-c 8`, `-c8`, and the long spellings.
                    let names: [(String, Character)] = [
                        ("-cols", "c"), ("-len", "l"), ("-seek", "s"), ("-groupsize", "g"),
                        ("-c", "c"), ("-l", "l"), ("-s", "s"), ("-g", "g"),
                    ]
                    guard let (name, option) = names.first(where: { token.hasPrefix($0.0) }) else {
                        ctx.invalidOption("xxd", String(token.dropFirst()))
                        return
                    }
                    var value = String(token.dropFirst(name.count))
                    if value.isEmpty {
                        guard index < args.count else {
                            ctx.error("xxd: option requires an argument -- '\(option)'")
                            ctx.fail("Try 'xxd --help' for more information.")
                            return
                        }
                        value = args[index]
                        index += 1
                    }
                    if option == "s" {
                        seekText = value
                        continue
                    }
                    guard let parsed = parseCNumber(value), parsed >= 0 else {
                        ctx.fail("xxd: invalid number: '\(value)'", code: 1)
                        return
                    }
                    if option == "c" {
                        columns = parsed
                    } else if option == "l" {
                        length = parsed
                    } else {
                        group = parsed
                    }
                }
            }
            guard operands.count <= 2 else {
                ctx.fail("xxd: too many operands", code: 1)
                return
            }
            let inputName = operands.first ?? "-"
            var outputFD = 1
            func openOutput(truncate: Bool) -> Bool {
                guard operands.count == 2, operands[1] != "-" else { return true }
                do {
                    outputFD = try ctx.openForWriting(operands[1], truncate: truncate)
                    return true
                } catch {
                    ctx.fail("xxd: \(operands[1]): \(errnoText(error))", code: 2)
                    return false
                }
            }

            if revert {
                let text: [UInt8]
                do {
                    text = try await readOperand(ctx, inputName)
                } catch {
                    ctx.fail("xxd: \(inputName): \(errnoText(error))", code: 2)
                    return
                }
                guard openOutput(truncate: true) else { return }
                let bytes = xxdRevert(text, plain: plain)
                if await ctx.writeAll(outputFD, bytes) { ctx.exit(0) }
                if outputFD != 1 { ctx.close(outputFD) }
                return
            }

            var skip = 0
            if let seekText {
                let fromEnd = seekText.hasPrefix("-")
                let digits = seekText.hasPrefix("+") || fromEnd ? String(seekText.dropFirst()) : seekText
                guard let parsed = parseCNumber(digits), parsed >= 0 else {
                    ctx.fail("xxd: invalid number: '\(seekText)'", code: 1)
                    return
                }
                if fromEnd {
                    guard inputName != "-", let info = ctx.stat(inputName), info.type == .regular else {
                        ctx.fail("xxd: sorry, cannot seek.", code: 4)
                        return
                    }
                    skip = Swift.max(0, info.size - parsed)
                } else {
                    skip = parsed
                }
            }
            let width = Swift.min(256, Swift.max(1, columns.flatMap { $0 == 0 ? nil : $0 } ?? (plain ? 30 : 16)))
            let input = CommandInput(ctx, command: "xxd", files: [inputName])
            var reader = RowReader(input, width: width, skip: skip, limit: length)
            var first = await reader.next()
            if input.status != 0 {
                ctx.exit(2)
                return
            }
            guard openOutput(truncate: true) else { return }
            defer { if outputFD != 1 { ctx.close(outputFD) } }
            let groupCount = group > 0 ? (width + group - 1) / group : 1
            let hexWidth = width * 2 + groupCount
            var out: [UInt8] = []
            var rowOffset = skip
            while let row = first {
                if plain {
                    for byte in row { appendNumber(&out, UInt64(byte), radix: 16, width: 2, uppercase: upper) }
                } else {
                    appendNumber(&out, UInt64(rowOffset), radix: 16, width: 8)
                    out.append(0x3A)
                    var used = 0
                    for (position, byte) in row.enumerated() {
                        if group > 0 ? position % group == 0 : position == 0 {
                            out.append(0x20)
                            used += 1
                        }
                        appendNumber(&out, UInt64(byte), radix: 16, width: 2, uppercase: upper)
                        used += 2
                    }
                    out.append(contentsOf: repeatElement(0x20, count: hexWidth - used + 2))
                    for byte in row { out.append(isPrintable(byte) ? byte : 0x2E) }
                }
                out.append(0x0A)
                rowOffset += row.count
                if out.count >= 16384 {
                    guard await ctx.writeAll(outputFD, out) else { return }
                    out.removeAll(keepingCapacity: true)
                }
                first = await reader.next()
            }
            if await ctx.writeAll(outputFD, out) { ctx.exit(0) }
        })
    }

    // MARK: - hexdump

    private static func hexdumpCommand() -> Command {
        Command(name: "hexdump", summary: "display file contents in hexadecimal", category: .text, usage: """
            hexdump [-C] [-v] [-n LENGTH] [-s OFFSET] [FILE]...
              -C         canonical hex+ASCII display
              -n LENGTH  interpret only LENGTH bytes of input
              -s OFFSET  skip OFFSET bytes from the beginning
              -v         display all data (do not squeeze repeated lines into *)
              Without -C the input is shown as 16-bit little-endian hexadecimal words.
            """, asyncRun: { ctx, argv in
            guard let opts = ctx.options("hexdump", Array(argv.dropFirst()), "Cvn:s:",
                                         long: ["canonical": "C", "no-squeezing": "v",
                                                "length": "n", "skip": "s"]) else { return }
            var skip = 0
            var limit: Int? = nil
            if let text = opts.value("s") {
                guard let parsed = parseByteCount(text, allowHex: true) else {
                    ctx.fail("hexdump: \(text): bad skip value", code: 1)
                    return
                }
                skip = parsed
            }
            if let text = opts.value("n") {
                guard let parsed = parseByteCount(text, allowHex: true) else {
                    ctx.fail("hexdump: \(text): bad length value", code: 1)
                    return
                }
                limit = parsed
            }
            let canonical = opts.has("C")
            let verbose = opts.has("v")
            let input = CommandInput(ctx, command: "hexdump", files: opts.operands)
            var reader = RowReader(input, width: 16, skip: skip, limit: limit)
            var out: [UInt8] = []
            var previous: [UInt8]? = nil
            var squeezing = false
            var any = false
            while true {
                let rowOffset = reader.offset
                guard let row = await reader.next() else { break }
                any = true
                if !verbose, row.count == 16, row == previous {
                    if !squeezing {
                        out.append(contentsOf: [0x2A, 0x0A])
                        squeezing = true
                    }
                    continue
                }
                squeezing = false
                previous = row
                if canonical {
                    appendNumber(&out, UInt64(rowOffset), radix: 16, width: 8)
                    out.append(contentsOf: [0x20, 0x20])
                    for position in 0..<16 {
                        if position < row.count {
                            appendNumber(&out, UInt64(row[position]), radix: 16, width: 2)
                            out.append(0x20)
                        } else {
                            out.append(contentsOf: [0x20, 0x20, 0x20])
                        }
                        if position == 7 || position == 15 { out.append(0x20) }
                    }
                    out.append(0x7C)
                    for byte in row { out.append(isPrintable(byte) ? byte : 0x2E) }
                    out.append(contentsOf: [0x7C, 0x0A])
                } else {
                    // Like the real tool, a short last line is padded with
                    // blanks to the full eight-word width.
                    appendNumber(&out, UInt64(rowOffset), radix: 16, width: 7)
                    for word in 0..<8 {
                        let low = word * 2
                        if low < row.count {
                            let high = low + 1 < row.count ? row[low + 1] : 0
                            out.append(0x20)
                            appendNumber(&out, UInt64(high) << 8 | UInt64(row[low]), radix: 16, width: 4)
                        } else {
                            out.append(contentsOf: [0x20, 0x20, 0x20, 0x20, 0x20])
                        }
                    }
                    out.append(0x0A)
                }
                if out.count >= 16384 {
                    guard await ctx.put(out) else { return }
                    out.removeAll(keepingCapacity: true)
                }
            }
            if any {
                appendNumber(&out, UInt64(reader.offset), radix: 16, width: canonical ? 8 : 7)
                out.append(0x0A)
            }
            await ctx.emit(out, exit: input.status)
        })
    }

    // MARK: - strings

    private static func stringsCommand() -> Command {
        Command(name: "strings", summary: "print the printable strings in files", category: .text, usage: """
            strings [-a] [-n MIN] [-t RADIX] [FILE]...
              -a        scan the whole file (always the case; accepted for compatibility)
              -n MIN    print runs of at least MIN printable characters (default 4)
              -t RADIX  prefix each string with its offset: o (octal), d (decimal), x (hex)
            """, asyncRun: { ctx, argv in
            guard let opts = ctx.options("strings", Array(argv.dropFirst()), "an:t:",
                                         long: ["all": "a", "bytes": "n", "radix": "t"]) else { return }
            var minimum = 4
            if let text = opts.value("n") {
                guard let parsed = Int(text), parsed > 0 else {
                    ctx.fail("strings: invalid minimum string length \(text)", code: 1)
                    return
                }
                minimum = parsed
            }
            var radix: UInt64? = nil
            if let text = opts.value("t") {
                guard let parsed = ["o": UInt64(8), "d": 10, "x": 16][text] else {
                    ctx.fail("strings: invalid radix: \(text)", code: 1)
                    return
                }
                radix = parsed
            }
            let input = CommandInput(ctx, command: "strings", files: opts.operands)
            var out: [UInt8] = []
            var run: [UInt8] = []
            var runStart = 0
            var offset = 0
            var file = -1
            func finishRun() {
                if run.count >= minimum {
                    if let radix {
                        appendNumber(&out, UInt64(runStart), radix: radix, width: 7, pad: 0x20)
                        out.append(0x20)
                    }
                    out.append(contentsOf: run)
                    out.append(0x0A)
                }
                run.removeAll(keepingCapacity: true)
            }
            while let chunk = await input.chunk() {
                if input.fileIndex != file {
                    // Runs do not span operands, and offsets restart per file.
                    finishRun()
                    file = input.fileIndex
                    offset = 0
                }
                for byte in chunk {
                    if isPrintable(byte) || byte == 0x09 {
                        if run.isEmpty { runStart = offset }
                        run.append(byte)
                    } else if !run.isEmpty {
                        finishRun()
                    }
                    offset += 1
                }
                if out.count >= 16384 {
                    guard await ctx.put(out) else { return }
                    out.removeAll(keepingCapacity: true)
                }
            }
            finishRun()
            await ctx.emit(out, exit: input.status)
        })
    }

    // MARK: - split

    /// The `index`-th output suffix of `length` characters: `aa`, `ab`, … or,
    /// numerically, `00`, `01`, …; `nil` once the suffix space is exhausted.
    static func splitSuffix(_ index: Int, length: Int, numeric: Bool) -> String? {
        let base = numeric ? 10 : 26
        let first: UInt8 = numeric ? 0x30 : 0x61
        var characters = [UInt8](repeating: first, count: length)
        var rest = index
        var position = length - 1
        while position >= 0 {
            characters[position] = first + UInt8(rest % base)
            rest /= base
            position -= 1
        }
        return rest == 0 ? String(decoding: characters, as: UTF8.self) : nil
    }

    private static func splitCommand() -> Command {
        Command(name: "split", summary: "split a file into pieces", category: .fileSystem, usage: """
            split [-l LINES] [-b BYTES] [-d] [-a LENGTH] [FILE [PREFIX]]
              -l LINES   put LINES lines in each output file (default 1000)
              -b BYTES   put BYTES bytes in each output file (suffixes K, M, G)
              -d         use numeric suffixes (00, 01, ...) instead of alphabetic (aa, ab, ...)
              -a LENGTH  use suffixes of LENGTH characters (default 2)
              Output files are PREFIXaa, PREFIXab, ...; the default PREFIX is 'x'.
              With no FILE, or when FILE is -, read standard input.
            """, asyncRun: { ctx, argv in
            // The historical `-N` spelling of `-l N`.
            let args = argv.dropFirst().map { token -> String in
                let digits = token.dropFirst()
                return token.hasPrefix("-") && !digits.isEmpty && digits.allSatisfy(\.isNumber)
                    ? "-l" + digits : token
            }
            guard let opts = ctx.options("split", args, "l:b:da:",
                                         long: ["lines": "l", "bytes": "b", "numeric-suffixes": "d",
                                                "suffix-length": "a"]) else { return }
            var lines = 1000
            var bytes: Int? = nil
            var suffixLength = 2
            if let text = opts.value("l") {
                guard let parsed = Int(text), parsed > 0 else {
                    ctx.fail("split: invalid number of lines: '\(text)'", code: 1)
                    return
                }
                lines = parsed
            }
            if let text = opts.value("b") {
                guard let parsed = parseByteCount(text), parsed > 0 else {
                    ctx.fail("split: invalid number of bytes: '\(text)'", code: 1)
                    return
                }
                bytes = parsed
            }
            if opts.has("l"), opts.has("b") {
                ctx.error("split: cannot split in more than one way")
                ctx.fail("Try 'split --help' for more information.", code: 1)
                return
            }
            if let text = opts.value("a") {
                guard let parsed = Int(text), parsed > 0 else {
                    ctx.fail("split: invalid suffix length: '\(text)'", code: 1)
                    return
                }
                suffixLength = parsed
            }
            guard opts.operands.count <= 2 else {
                ctx.error("split: extra operand '\(opts.operands[2])'")
                ctx.fail("Try 'split --help' for more information.", code: 1)
                return
            }
            let name = opts.operands.first ?? "-"
            let prefix = opts.operands.count > 1 ? opts.operands[1] : "x"
            let data: [UInt8]
            do {
                data = try await readOperand(ctx, name)
            } catch {
                ctx.fail("split: cannot open '\(name)' for reading: \(errnoText(error))", code: 1)
                return
            }

            // Piece boundaries: fixed byte counts, or every `lines` newlines.
            var pieces: [Range<Int>] = []
            if let bytes {
                var start = 0
                while start < data.count {
                    let end = Swift.min(data.count, start + bytes)
                    pieces.append(start..<end)
                    start = end
                }
            } else {
                var start = 0
                var seen = 0
                for (index, byte) in data.enumerated() where byte == 0x0A {
                    seen += 1
                    if seen == lines {
                        pieces.append(start..<(index + 1))
                        start = index + 1
                        seen = 0
                    }
                }
                if start < data.count { pieces.append(start..<data.count) }
            }
            for (index, piece) in pieces.enumerated() {
                guard let suffix = splitSuffix(index, length: suffixLength, numeric: opts.has("d")) else {
                    ctx.fail("split: output file suffixes exhausted", code: 1)
                    return
                }
                let path = prefix + suffix
                do {
                    let fd = try ctx.openForWriting(path)
                    let written = await ctx.writeAll(fd, Array(data[piece]))
                    ctx.close(fd)
                    guard written else {
                        ctx.fail("split: \(path): write error", code: 1)
                        return
                    }
                } catch {
                    ctx.fail("split: \(path): \(errnoText(error))", code: 1)
                    return
                }
            }
            ctx.exit(0)
        })
    }

    // MARK: - md5sum / sha1sum / sha256sum

    private static func checksumCommand(_ name: String, _ algorithm: Digest.Algorithm, title: String) -> Command {
        Command(name: name, summary: "compute and check \(title) message digests", category: .fileSystem, usage: """
            \(name) [-c] [FILE]...
              -c        read digests from the FILEs and check them
              --quiet   with -c, do not print OK for each verified file
              --status  with -c, print nothing; the exit status reports the result
              With no FILE, or when FILE is -, read standard input.
              Output is '<hex digest>  <name>' (two spaces), one line per file.
            """, asyncRun: { ctx, argv in
            guard let opts = ctx.options(name, Array(argv.dropFirst()), "cbtQSw",
                                         long: ["check": "c", "binary": "b", "text": "t",
                                                "quiet": "Q", "status": "S", "warn": "w"]) else { return }
            let files = opts.operands.isEmpty ? ["-"] : opts.operands
            var status: Int32 = 0

            /// Digest of one operand, or `nil` after reporting why it is unreadable.
            func digest(of path: String) async -> String? {
                do {
                    if path != "-", let info = ctx.stat(path), info.type == .directory {
                        throw SyscallError.isADirectory
                    }
                    return Digest.hex(algorithm.hash(try await readOperand(ctx, path)))
                } catch {
                    ctx.error("\(name): \(path): \(errnoText(error))")
                    return nil
                }
            }

            guard opts.has("c") else {
                for path in files {
                    guard let hex = await digest(of: path) else {
                        status = 1
                        continue
                    }
                    guard await ctx.put("\(hex)  \(path)\n") else { return }
                }
                ctx.exit(status)
                return
            }

            let silent = opts.has("S")
            let quiet = opts.has("Q") || silent
            for list in files {
                let listing: [UInt8]
                do {
                    listing = try await readOperand(ctx, list)
                } catch {
                    ctx.error("\(name): \(list): \(errnoText(error))")
                    status = 1
                    continue
                }
                var malformed = 0, mismatched = 0, unreadable = 0, checked = 0
                for lineBytes in listing.split(separator: 0x0A, omittingEmptySubsequences: false) {
                    var line = Array(lineBytes)
                    if line.last == 0x0D { line.removeLast() }
                    if line.isEmpty || line.first == 0x23 { continue }
                    // `<hex>  name` (text) or `<hex> *name` (binary).
                    let hexLength = algorithm.hexLength
                    guard line.count > hexLength + 2,
                          line[..<hexLength].allSatisfy({ hexValue($0) != nil }),
                          line[hexLength] == 0x20,
                          line[hexLength + 1] == 0x20 || line[hexLength + 1] == 0x2A else {
                        malformed += 1
                        continue
                    }
                    let expected = String(decoding: line[..<hexLength], as: UTF8.self).lowercased()
                    let path = String(decoding: line[(hexLength + 2)...], as: UTF8.self)
                    checked += 1
                    guard let actual = await digest(of: path) else {
                        unreadable += 1
                        if !silent {
                            guard await ctx.put("\(path): FAILED open or read\n") else { return }
                        }
                        continue
                    }
                    if actual == expected {
                        if !quiet {
                            guard await ctx.put("\(path): OK\n") else { return }
                        }
                    } else {
                        mismatched += 1
                        if !silent {
                            guard await ctx.put("\(path): FAILED\n") else { return }
                        }
                    }
                }
                if checked == 0 {
                    ctx.error("\(name): \(list == "-" ? "standard input" : list): no properly formatted checksum lines found")
                    status = 1
                    continue
                }
                if !silent {
                    if malformed > 0 {
                        ctx.error("\(name): WARNING: \(malformed) \(malformed == 1 ? "line is" : "lines are") improperly formatted")
                    }
                    if unreadable > 0 {
                        ctx.error("\(name): WARNING: \(unreadable) listed \(unreadable == 1 ? "file" : "files") could not be read")
                    }
                    if mismatched > 0 {
                        ctx.error("\(name): WARNING: \(mismatched) computed \(mismatched == 1 ? "checksum" : "checksums") did NOT match")
                    }
                }
                if mismatched > 0 || unreadable > 0 { status = 1 }
            }
            ctx.exit(status)
        })
    }
}
