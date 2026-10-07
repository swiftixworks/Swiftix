/// Archive built-ins: `tar` (POSIX ustar create / list / extract) and the
/// `gzip` / `gunzip` / `zcat` front ends over `Gzip.swift`.
///
/// `TarArchive` is the format layer — header encoding with correct checksums,
/// ustar prefix splitting, GNU `L`/`K` long-name records (written only when a
/// name fits neither field; always understood on read), pax `x` records (read
/// only), and end-of-archive blocking to 10240 bytes like GNU tar's default
/// blocking factor of 20. The `tar` command above it walks the VFS, maps
/// regular files, directories, symlinks and FIFOs to members, and restores
/// modes, ownership (when permitted) and modification times on extraction.
/// Hard links are stored as independent regular files; a hard-link member in a
/// foreign archive is extracted with `link`.
///
/// Timestamps are the node's file times on the kernel wall clock, stored as
/// the integer `mtime` field and listed as `YYYY-MM-DD HH:MM`.
///
/// Archives are assembled and parsed in memory: files in this system live in
/// memory already, so streaming would only move the copy around.
///
/// Concurrency: value types and async programs over `ProcessContext`, used on
/// the single loop-bound executor. No shared state, no locks.

// MARK: - Format

enum TarArchive {

    static let blockSize = 512
    /// GNU tar's default record size (blocking factor 20).
    static let recordSize = 20 * blockSize

    enum Failure: Error {
        case notAnArchive
        case unexpectedEnd
    }

    /// One archive member as stored.
    struct Member {
        var name: String
        var linkName = ""
        /// The ustar type flag (`0` file, `1` hard link, `2` symlink, `5`
        /// directory, `6` FIFO, …); the historical NUL is normalized to `0`.
        var type: UInt8 = 0x30
        var mode = 0o644
        var uid = 0
        var gid = 0
        var size = 0
        var mtime = 0
        var userName = ""
        var groupName = ""
        /// Offset of the member's data in the archive.
        var dataOffset = 0

        var isDirectory: Bool { type == 0x35 || (type == 0x30 && name.hasSuffix("/")) }
    }

    // MARK: Writing

    private static func put(_ block: inout [UInt8], _ offset: Int, _ length: Int, _ text: [UInt8]) {
        for (index, byte) in text.prefix(length).enumerated() { block[offset + index] = byte }
    }

    /// A numeric field: zero-padded octal with a terminating NUL, or GNU
    /// base-256 when the value does not fit.
    private static func putNumber(_ block: inout [UInt8], _ offset: Int, _ length: Int, _ value: Int) {
        let digits = Array(String(Swift.max(0, value), radix: 8).utf8)
        if digits.count <= length - 1 {
            let padding = length - 1 - digits.count
            for index in 0..<padding { block[offset + index] = 0x30 }
            put(&block, offset + padding, digits.count, digits)
            return
        }
        var rest = value
        var index = length - 1
        while index > 0 {
            block[offset + index] = UInt8(rest & 0xFF)
            rest >>= 8
            index -= 1
        }
        block[offset] = 0x80
    }

    /// Split a long name into ustar `prefix` (≤155) and `name` (≤100) at a
    /// slash, preferring the longest prefix.
    static func splitName(_ name: [UInt8]) -> (prefix: [UInt8], name: [UInt8])? {
        if name.count <= 100 { return ([], name) }
        var position = Swift.min(155, name.count - 2)
        while position > 0 {
            if name[position] == 0x2F, name.count - position - 1 <= 100 {
                return (Array(name[..<position]), Array(name[(position + 1)...]))
            }
            position -= 1
        }
        return nil
    }

    private static func rawHeader(name: [UInt8], prefix: [UInt8], member: Member, linkName: [UInt8]) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: blockSize)
        put(&block, 0, 100, name)
        putNumber(&block, 100, 8, member.mode & 0o7777)
        putNumber(&block, 108, 8, member.uid)
        putNumber(&block, 116, 8, member.gid)
        putNumber(&block, 124, 12, member.size)
        putNumber(&block, 136, 12, member.mtime)
        block[156] = member.type
        put(&block, 157, 100, linkName)
        put(&block, 257, 6, Array("ustar".utf8) + [0])
        put(&block, 263, 2, Array("00".utf8))
        put(&block, 265, 31, Array(member.userName.utf8))
        put(&block, 297, 31, Array(member.groupName.utf8))
        putNumber(&block, 329, 8, 0)
        putNumber(&block, 337, 8, 0)
        put(&block, 345, 155, prefix)
        // The checksum is computed with its own field read as eight spaces and
        // stored as six octal digits, NUL, space.
        for index in 148..<156 { block[index] = 0x20 }
        let sum = block.reduce(0) { $0 + Int($1) }
        let digits = Array(String(sum, radix: 8).utf8)
        for index in 0..<6 { block[148 + index] = 0x30 }
        put(&block, 148 + 6 - digits.count, digits.count, digits)
        block[154] = 0
        block[155] = 0x20
        return block
    }

    /// `data` followed by NUL padding to a whole number of blocks.
    static func padded(_ data: [UInt8]) -> [UInt8] {
        let remainder = data.count % blockSize
        return remainder == 0 ? data : data + [UInt8](repeating: 0, count: blockSize - remainder)
    }

    /// A GNU extension record carrying a name too long for the header.
    private static func longRecord(_ type: UInt8, _ text: [UInt8]) -> [UInt8] {
        var member = Member(name: "././@LongLink")
        member.type = type
        member.mode = 0o644
        member.size = text.count + 1
        return rawHeader(name: Array(member.name.utf8), prefix: [], member: member, linkName: [])
            + padded(text + [0])
    }

    /// The header block(s) for `member`: one ustar header, preceded by GNU
    /// long-name records when the name or link target fits no ustar field.
    static func header(for member: Member) -> [UInt8] {
        var out: [UInt8] = []
        let fullName = Array(member.name.utf8)
        let fullLink = Array(member.linkName.utf8)
        if fullLink.count > 100 { out.append(contentsOf: longRecord(0x4B, fullLink)) }
        if let (prefix, name) = splitName(fullName) {
            out.append(contentsOf: rawHeader(name: name, prefix: prefix, member: member, linkName: fullLink))
        } else {
            out.append(contentsOf: longRecord(0x4C, fullName))
            out.append(contentsOf: rawHeader(name: fullName, prefix: [], member: member, linkName: fullLink))
        }
        return out
    }

    /// The end-of-archive marker (two zero blocks) plus padding to a whole
    /// record for an archive that currently holds `count` bytes.
    static func trailer(after count: Int) -> [UInt8] {
        let end = count + 2 * blockSize
        let remainder = end % recordSize
        return [UInt8](repeating: 0, count: 2 * blockSize + (remainder == 0 ? 0 : recordSize - remainder))
    }

    // MARK: Reading

    private static func text(_ archive: [UInt8], _ offset: Int, _ length: Int) -> String {
        var end = offset
        while end < offset + length, archive[end] != 0 { end += 1 }
        return String(decoding: archive[offset..<end], as: UTF8.self)
    }

    private static func number(_ archive: [UInt8], _ offset: Int, _ length: Int) -> Int {
        if archive[offset] & 0x80 != 0 {
            var value = Int(archive[offset] & 0x7F)
            for index in 1..<length { value = (value & 0x00FF_FFFF_FFFF_FFFF) << 8 | Int(archive[offset + index]) }
            return value
        }
        var value = 0
        for index in offset..<(offset + length) {
            let byte = archive[index]
            if byte >= 0x30, byte <= 0x37 {
                value = value &* 8 &+ Int(byte - 0x30)
            } else if byte == 0x20, value == 0 {
                continue
            } else {
                break
            }
        }
        return value
    }

    /// The `key=value` records of a pax extended header.
    private static func paxRecords(_ data: ArraySlice<UInt8>) -> [String: String] {
        var records: [String: String] = [:]
        var position = data.startIndex
        while position < data.endIndex {
            var length = 0
            var cursor = position
            while cursor < data.endIndex, data[cursor] >= 0x30, data[cursor] <= 0x39 {
                length = length * 10 + Int(data[cursor] - 0x30)
                cursor += 1
            }
            guard length > 0, position + length <= data.endIndex, cursor < data.endIndex,
                  data[cursor] == 0x20 else { break }
            let record = data[(cursor + 1)..<(position + length)]
            if let equals = record.firstIndex(of: 0x3D) {
                var value = record[(equals + 1)...]
                if value.last == 0x0A { value = value.dropLast() }
                records[String(decoding: record[..<equals], as: UTF8.self)] = String(decoding: value, as: UTF8.self)
            }
            position += length
        }
        return records
    }

    /// Parse every member header up to the end-of-archive marker.
    static func members(of archive: [UInt8]) throws -> [Member] {
        var members: [Member] = []
        var offset = 0
        var longName: String? = nil
        var longLink: String? = nil
        var pax: [String: String] = [:]
        guard archive.count >= blockSize else { throw Failure.notAnArchive }
        while offset + blockSize <= archive.count {
            let block = archive[offset..<(offset + blockSize)]
            if block.allSatisfy({ $0 == 0 }) { break }
            var unsignedSum = 0
            var signedSum = 0
            for (index, byte) in block.enumerated() {
                let value = index >= 148 && index < 156 ? 0x20 : byte
                unsignedSum += Int(value)
                signedSum += Int(Int8(bitPattern: value))
            }
            let stored = number(archive, offset + 148, 8)
            guard stored == unsignedSum || stored == signedSum else {
                if members.isEmpty { throw Failure.notAnArchive }
                throw Failure.unexpectedEnd
            }
            var member = Member(name: text(archive, offset, 100))
            member.mode = number(archive, offset + 100, 8) & 0o7777
            member.uid = number(archive, offset + 108, 8)
            member.gid = number(archive, offset + 116, 8)
            member.size = number(archive, offset + 124, 12)
            member.mtime = number(archive, offset + 136, 12)
            member.type = archive[offset + 156] == 0 ? 0x30 : archive[offset + 156]
            member.linkName = text(archive, offset + 157, 100)
            let isUstar = text(archive, offset + 257, 6) == "ustar"
            if isUstar {
                member.userName = text(archive, offset + 265, 32)
                member.groupName = text(archive, offset + 297, 32)
                let prefix = text(archive, offset + 345, 155)
                if !prefix.isEmpty { member.name = prefix + "/" + member.name }
            }
            member.dataOffset = offset + blockSize
            // Only these types carry data blocks.
            let hasData = member.type == 0x30 || member.type == 0x37
                || member.type == 0x4C || member.type == 0x4B || member.type == 0x78 || member.type == 0x67
            let dataSize = hasData ? member.size : 0
            guard member.dataOffset + dataSize <= archive.count else { throw Failure.unexpectedEnd }
            offset = member.dataOffset + (dataSize + blockSize - 1) / blockSize * blockSize

            let data = archive[member.dataOffset..<(member.dataOffset + dataSize)]
            if member.type == 0x4C || member.type == 0x4B {
                var end = data.endIndex
                while end > data.startIndex, data[end - 1] == 0 { end -= 1 }
                let value = String(decoding: data[..<end], as: UTF8.self)
                if member.type == 0x4C { longName = value } else { longLink = value }
                continue
            }
            if member.type == 0x78 {
                pax = paxRecords(data)
                continue
            }
            if member.type == 0x67 { continue }
            if let longName { member.name = longName }
            if let longLink { member.linkName = longLink }
            if let path = pax["path"] { member.name = path }
            if let link = pax["linkpath"] { member.linkName = link }
            if let size = pax["size"].flatMap({ Int($0) }) {
                member.size = size
                guard member.dataOffset + size <= archive.count else { throw Failure.unexpectedEnd }
                offset = member.dataOffset + (size + blockSize - 1) / blockSize * blockSize
            }
            if let name = pax["uname"] { member.userName = name }
            if let name = pax["gname"] { member.groupName = name }
            if !hasData { member.size = 0 }
            longName = nil
            longLink = nil
            pax = [:]
            members.append(member)
        }
        return members
    }
}

// MARK: - Commands

extension BuiltinCommands {

    static func archiveCommands() -> [Command] {
        [
            tarCommand(),
            gzipCommand("gzip", summary: "compress or expand files", decompress: false, toStdout: false),
            gzipCommand("gunzip", summary: "expand gzip-compressed files", decompress: true, toStdout: false),
            gzipCommand("zcat", summary: "expand gzip-compressed files to standard output",
                        decompress: true, toStdout: true),
        ]
    }

    // MARK: tar

    private enum TarOperand {
        case path(String)
        case directory(String)
    }

    private struct TarOptions {
        var mode: Character? = nil
        var verbose = 0
        var archive: String? = nil
        var gzip = false
        var toStdout = false
        var keepOld = false
        var strip = 0
        var excludes: [String] = []
        var operands: [TarOperand] = []
    }

    /// Parse a tar command line: an optional old-style first bundle (`cvf`),
    /// dashed bundles (`-xvf a.tar`), `-C DIR` kept in order among the
    /// operands, and the long options. Reports problems itself and returns
    /// `nil`.
    private static func parseTarArguments(_ ctx: ProcessContext, _ args: [String]) -> TarOptions? {
        var options = TarOptions()
        var index = 0

        func usageError(_ message: String) -> TarOptions? {
            ctx.error("tar: \(message)")
            ctx.fail("Try 'tar --help' or 'tar --usage' for more information.")
            return nil
        }
        func nextValue(_ letter: Character) -> String? {
            guard index < args.count else {
                ctx.error("tar: option requires an argument -- '\(letter)'")
                ctx.fail("Try 'tar --help' or 'tar --usage' for more information.")
                return nil
            }
            index += 1
            return args[index - 1]
        }
        /// Apply one option letter; `attached` is the rest of a dashed bundle,
        /// usable as the value of `f` / `C` (`-fa.tar`). Returns whether the
        /// attached text was consumed, or `nil` after reporting an error.
        func apply(_ letter: Character, attached: String?) -> Bool? {
            if letter == "c" || letter == "x" || letter == "t" {
                if let mode = options.mode, mode != letter {
                    _ = usageError("You may not specify more than one '-Acdtrux', '--delete' or  '--test-label' option")
                    return nil
                }
                options.mode = letter
            } else if letter == "v" {
                options.verbose += 1
            } else if letter == "z" {
                options.gzip = true
            } else if letter == "O" {
                options.toStdout = true
            } else if letter == "k" {
                options.keepOld = true
            } else if letter == "p" || letter == "s" || letter == "m" || letter == "h" || letter == "o" {
                return false                      // accepted; these are the defaults here
            } else if letter == "f" || letter == "C" || letter == "b" {
                let value: String
                var consumed = false
                if let attached, !attached.isEmpty {
                    value = attached
                    consumed = true
                } else if let next = nextValue(letter) {
                    value = next
                } else {
                    return nil
                }
                if letter == "f" {
                    options.archive = value
                } else if letter == "C" {
                    options.operands.append(.directory(value))
                }
                return consumed
            } else if letter == "j" || letter == "J" || letter == "Z" {
                ctx.fail("tar: only gzip compression (-z) is supported")
                return nil
            } else if letter == "r" || letter == "u" || letter == "A" || letter == "d" {
                ctx.fail("tar: option -\(letter) is not supported")
                return nil
            } else {
                ctx.error("tar: invalid option -- '\(letter)'")
                ctx.fail("Try 'tar --help' or 'tar --usage' for more information.")
                return nil
            }
            return false
        }

        // Old-style: the first word is a bundle of option letters with no
        // dash, whose arguments follow as separate words in letter order.
        if let first = args.first, !first.hasPrefix("-") {
            index = 1
            for letter in first {
                guard apply(letter, attached: nil) != nil else { return nil }
            }
        }
        while index < args.count {
            let token = args[index]
            index += 1
            if token == "--" {
                options.operands.append(contentsOf: args[index...].map { TarOperand.path($0) })
                break
            }
            if token.hasPrefix("--") {
                let body = token.dropFirst(2)
                var name = String(body)
                var inline: String? = nil
                if let equals = body.firstIndex(of: "=") {
                    name = String(body[..<equals])
                    inline = String(body[body.index(after: equals)...])
                }
                func value() -> String? {
                    if let inline { return inline }
                    guard index < args.count else {
                        ctx.error("tar: option '--\(name)' requires an argument")
                        ctx.fail("Try 'tar --help' or 'tar --usage' for more information.")
                        return nil
                    }
                    index += 1
                    return args[index - 1]
                }
                let flags: [String: Character] = [
                    "create": "c", "extract": "x", "get": "x", "list": "t", "verbose": "v",
                    "gzip": "z", "gunzip": "z", "ungzip": "z", "to-stdout": "O",
                    "keep-old-files": "k", "preserve-permissions": "p", "same-permissions": "p",
                ]
                if let letter = flags[name] {
                    guard apply(letter, attached: nil) != nil else { return nil }
                } else if name == "file" {
                    guard let text = value() else { return nil }
                    options.archive = text
                } else if name == "directory" {
                    guard let text = value() else { return nil }
                    options.operands.append(.directory(text))
                } else if name == "exclude" {
                    guard let text = value() else { return nil }
                    options.excludes.append(text)
                } else if name == "strip-components" {
                    guard let text = value() else { return nil }
                    guard let count = Int(text), count >= 0 else {
                        ctx.fail("tar: Invalid number of elements: '\(text)'")
                        return nil
                    }
                    options.strip = count
                } else {
                    ctx.error("tar: unrecognized option '--\(name)'")
                    ctx.fail("Try 'tar --help' or 'tar --usage' for more information.")
                    return nil
                }
                continue
            }
            if CommandArguments.isOptionToken(token) {
                let letters = Array(token.dropFirst())
                var position = 0
                while position < letters.count {
                    let rest = String(letters[(position + 1)...])
                    guard let consumed = apply(letters[position], attached: rest) else { return nil }
                    if consumed { break }
                    position += 1
                }
                continue
            }
            options.operands.append(.path(token))
        }
        guard options.mode != nil else {
            return usageError("You must specify one of the '-Acdtrux', '--delete' or '--test-label' options")
        }
        return options
    }

    /// Whether `--exclude` pattern `pattern` rules out member `name`: it may
    /// match the whole name, any trailing run of components, or any leading
    /// directory of those (so excluding a directory excludes its contents).
    static func tarExcludes(_ patterns: [String], _ name: String) -> Bool {
        if patterns.isEmpty { return false }
        let components = name.split(separator: "/").map(String.init)
        for pattern in patterns {
            for start in 0..<components.count {
                for end in (start + 1)...components.count {
                    let candidate = components[start..<end].joined(separator: "/")
                    if wildcardMatch(pattern, candidate) { return true }
                    if start == 0, name.hasPrefix("/"), wildcardMatch(pattern, "/" + candidate) { return true }
                }
            }
        }
        return false
    }

    /// Whether a member is selected by an extract/list operand: the exact
    /// name, anything beneath a named directory, or a wildcard match.
    private static func tarSelects(_ pattern: String, _ name: String) -> Bool {
        var wanted = Substring(pattern)
        while wanted.count > 1, wanted.hasSuffix("/") { wanted = wanted.dropLast() }
        var actual = Substring(name)
        while actual.count > 1, actual.hasSuffix("/") { actual = actual.dropLast() }
        if actual == wanted || actual.hasPrefix(wanted + "/") { return true }
        return wildcardMatch(String(wanted), String(actual))
    }

    /// The `tar -tv` line for a member. `width` is GNU tar's running
    /// owner+size column width (starts at 19 and only grows).
    private static func tarLongListing(_ ctx: ProcessContext, _ member: TarArchive.Member, width: inout Int) -> String {
        let typeCharacter: Character
        if member.isDirectory {
            typeCharacter = "d"
        } else if member.type == 0x32 {
            typeCharacter = "l"
        } else if member.type == 0x31 {
            typeCharacter = "h"
        } else if member.type == 0x36 {
            typeCharacter = "p"
        } else if member.type == 0x33 {
            typeCharacter = "c"
        } else if member.type == 0x34 {
            typeCharacter = "b"
        } else {
            typeCharacter = "-"
        }
        let permissions = permissionString(FileMode(rawValue: UInt16(member.mode & 0o7777)))
        let owner = (member.userName.isEmpty ? "\(member.uid)" : member.userName)
            + "/" + (member.groupName.isEmpty ? "\(member.gid)" : member.groupName)
        let size = "\(member.size)"
        width = Swift.max(width, owner.count + 1 + size.count)
        let padding = String(repeating: " ", count: width - owner.count - size.count)
        var line = "\(typeCharacter)\(permissions) \(owner)\(padding)\(size) "
            + "\(ctx.calendarTime(Double(member.mtime)).formatted("%Y-%m-%d %H:%M")) \(member.name)"
        if member.type == 0x32 {
            line += " -> \(member.linkName)"
        } else if member.type == 0x31 {
            line += " link to \(member.linkName)"
        }
        return line
    }

    private static func tarCommand() -> Command {
        Command(name: "tar", summary: "create, list and extract tar archives", category: .fileSystem, usage: """
            tar {c|x|t}[vzf] [ARCHIVE] [-C DIR] [--exclude=PATTERN] [--strip-components=N] [FILE]...
              c, -c       create an archive from the FILEs (directories are archived recursively)
              x, -x       extract members (all of them, or those matching the FILE operands)
              t, -t       list members; with -v in long form
              -f ARCHIVE  archive file; '-' (the default) means standard input / output
              -v          verbose: name each member processed
              -z          gzip: decompress on read (also auto-detected); write stored gzip blocks
              -C DIR      change to DIR: for the following FILEs on create, for the output on extract
              -O          extract file contents to standard output
              -k          do not replace existing files when extracting
              --exclude=PATTERN       skip members matching the shell wildcard PATTERN
              --strip-components=N    strip N leading path components on extraction
              The option letters may be bundled as the first argument without a dash (tar cvf a.tar dir).
              The archive format is POSIX ustar; GNU long-name and pax path records are read.
            """, asyncRun: { ctx, argv in
            guard let options = parseTarArguments(ctx, Array(argv.dropFirst())) else { return }
            if options.mode == "c" {
                await tarCreate(ctx, options)
            } else {
                await tarRead(ctx, options)
            }
        })
    }

    /// `base` joined with `path` (absolute paths stand alone), normalized.
    private static func tarResolve(_ ctx: ProcessContext, _ base: String, _ path: String) -> String {
        ctx.absolute(path.hasPrefix("/") ? path : ctx.join(base, path))
    }

    private static func tarCreate(_ ctx: ProcessContext, _ options: TarOptions) async {
        let archiveName = options.archive ?? "-"
        let toStandardOutput = archiveName == "-"
        guard options.operands.contains(where: { if case .path = $0 { return true } else { return false } }) else {
            ctx.error("tar: Cowardly refusing to create an empty archive")
            ctx.fail("Try 'tar --help' or 'tar --usage' for more information.")
            return
        }
        var archiveFD = 1
        if !toStandardOutput {
            do {
                archiveFD = try ctx.openForWriting(archiveName)
            } catch {
                ctx.error("tar: \(archiveName): Cannot open: \(errnoText(error))")
                ctx.fail("tar: Error is not recoverable: exiting now")
                return
            }
        }
        defer { if !toStandardOutput { ctx.close(archiveFD) } }
        let archivePath = toStandardOutput ? nil : ctx.absolute(archiveName)
        let identities = ctx.userDatabase()

        var archive: [UInt8] = []
        var failed = false
        var warnedLeadingSlash = false
        var listingWidth = 19
        var verboseLines: [String] = []

        func note(_ member: TarArchive.Member) {
            if options.verbose == 1 {
                verboseLines.append(member.name)
            } else if options.verbose > 1 {
                verboseLines.append(tarLongListing(ctx, member, width: &listingWidth))
            }
        }

        /// Archive the node at `disk` under the member name `name`, recursing
        /// into directories.
        func add(_ name: String, _ disk: String) async {
            if tarExcludes(options.excludes, name) { return }
            let info: FileStat
            do {
                info = try ctx.lstatOrThrow(disk)
            } catch {
                ctx.error("tar: \(name): Cannot stat: \(errnoText(error))")
                failed = true
                return
            }
            var stored = name
            if stored.hasPrefix("/") {
                if !warnedLeadingSlash {
                    ctx.error("tar: Removing leading '/' from member names")
                    warnedLeadingSlash = true
                }
                while stored.hasPrefix("/") { stored.removeFirst() }
                if stored.isEmpty { stored = "." }
            }
            var member = TarArchive.Member(name: stored)
            member.mode = Int(info.mode.rawValue & 0o7777)
            member.uid = Int(info.uid)
            member.gid = Int(info.gid)
            member.mtime = Int(Swift.max(0, info.mtime))
            member.userName = identities.userName(uid: info.uid)
            member.groupName = identities.groupName(gid: info.gid)

            if info.type == .directory {
                if !member.name.hasSuffix("/") { member.name += "/" }
                member.type = 0x35
                archive.append(contentsOf: TarArchive.header(for: member))
                note(member)
                let entries: [FileSystemDirectoryEntry]
                do {
                    entries = try ctx.directoryEntries(disk)
                } catch {
                    ctx.error("tar: \(name): Cannot open: \(errnoText(error))")
                    failed = true
                    return
                }
                for entry in entries {
                    await add(ctx.join(name, entry.name), ctx.join(disk, entry.name))
                }
            } else if info.type == .symlink {
                member.type = 0x32
                member.linkName = ctx.readlink(disk) ?? ""
                archive.append(contentsOf: TarArchive.header(for: member))
                note(member)
            } else if info.type == .fifo {
                member.type = 0x36
                archive.append(contentsOf: TarArchive.header(for: member))
                note(member)
            } else if ctx.isDeviceNode(disk) {
                ctx.error("tar: \(name): device file ignored")
            } else if info.type == .regular {
                if let archivePath, ctx.absolute(disk) == archivePath {
                    ctx.error("tar: \(name): file is the archive; not dumped")
                    return
                }
                let data: [UInt8]
                do {
                    data = try await readOperand(ctx, disk)
                } catch {
                    ctx.error("tar: \(name): Cannot open: \(errnoText(error))")
                    failed = true
                    return
                }
                member.size = data.count
                archive.append(contentsOf: TarArchive.header(for: member))
                archive.append(contentsOf: TarArchive.padded(data))
                note(member)
            } else {
                ctx.error("tar: \(name): Unknown file type; file ignored")
                failed = true
            }
        }

        var base = ctx.currentDirectory
        for operand in options.operands {
            switch operand {
            case let .directory(directory):
                let target = tarResolve(ctx, base, directory)
                guard ctx.stat(target)?.isDirectory == true else {
                    let reason = ctx.stat(target) == nil ? "No such file or directory" : "Not a directory"
                    ctx.error("tar: \(directory): Cannot open: \(reason)")
                    ctx.fail("tar: Error is not recoverable: exiting now")
                    return
                }
                base = target
            case let .path(path):
                await add(path, path.hasPrefix("/") ? path : ctx.join(base, path))
            }
        }
        archive.append(contentsOf: TarArchive.trailer(after: archive.count))
        let output = options.gzip ? Gzip.compressStored(archive) : archive

        // Member names go to stdout, unless the archive itself is going there.
        if !verboseLines.isEmpty {
            let text = verboseLines.joined(separator: "\n") + "\n"
            if toStandardOutput {
                ctx.write(2, Array(text.utf8))
            } else {
                guard await ctx.put(text) else { return }
            }
        }
        guard await ctx.writeAll(archiveFD, output) else {
            if !toStandardOutput { ctx.fail("tar: \(archiveName): Cannot write: Input/output error") }
            return
        }
        if failed {
            ctx.fail("tar: Exiting with failure status due to previous errors")
        } else {
            ctx.exit(0)
        }
    }

    private static func tarRead(_ ctx: ProcessContext, _ options: TarOptions) async {
        let archiveName = options.archive ?? "-"
        var archive: [UInt8]
        do {
            archive = try await readOperand(ctx, archiveName)
        } catch {
            ctx.error("tar: \(archiveName): Cannot open: \(errnoText(error))")
            ctx.fail("tar: Error is not recoverable: exiting now")
            return
        }
        if options.gzip || Gzip.hasMagic(archive) {
            do {
                archive = try Gzip.decompress(archive)
            } catch {
                let reason = (error as? Gzip.Failure)?.message ?? "invalid compressed data"
                ctx.error("gzip: \(archiveName == "-" ? "stdin" : archiveName): \(reason)")
                ctx.error("tar: Child returned status 1")
                ctx.fail("tar: Error is not recoverable: exiting now")
                return
            }
        }
        let members: [TarArchive.Member]
        do {
            members = try TarArchive.members(of: archive)
        } catch TarArchive.Failure.unexpectedEnd {
            ctx.error("tar: Unexpected EOF in archive")
            ctx.fail("tar: Error is not recoverable: exiting now")
            return
        } catch {
            ctx.error("tar: This does not look like a tar archive")
            ctx.fail("tar: Exiting with failure status due to previous errors")
            return
        }

        // Operands: every -C applies to the extraction target; the paths select members.
        var base = ctx.currentDirectory
        var patterns: [String] = []
        for operand in options.operands {
            switch operand {
            case let .directory(directory):
                let target = tarResolve(ctx, base, directory)
                guard ctx.stat(target)?.isDirectory == true else {
                    let reason = ctx.stat(target) == nil ? "No such file or directory" : "Not a directory"
                    ctx.error("tar: \(directory): Cannot open: \(reason)")
                    ctx.fail("tar: Error is not recoverable: exiting now")
                    return
                }
                base = target
            case let .path(path):
                patterns.append(path)
            }
        }
        var matched = [Bool](repeating: false, count: patterns.count)
        var failed = false
        var warnedLeadingSlash = false
        var listingWidth = 19
        var out: [UInt8] = []
        /// Directory metadata is applied last, deepest first, so restoring a
        /// read-only mode or an old mtime is not undone by extracting children.
        var directories: [(path: String, member: TarArchive.Member)] = []

        func restoreMetadata(_ path: String, _ member: TarArchive.Member) {
            _ = ctx.chown(path, uid: UInt32(truncatingIfNeeded: member.uid), gid: UInt32(truncatingIfNeeded: member.gid))
            _ = ctx.chmod(path, mode: FileMode(rawValue: UInt16(member.mode & 0o7777)))
            ctx.utimes(path, atime: Double(member.mtime), mtime: Double(member.mtime))
        }

        /// The on-disk path for a member name, or `nil` when it must be skipped.
        func destination(_ stored: String, report: Bool) -> String? {
            var name = Substring(stored)
            if name.hasPrefix("/") {
                if report, !warnedLeadingSlash {
                    ctx.error("tar: Removing leading '/' from member names")
                    warnedLeadingSlash = true
                }
                while name.hasPrefix("/") { name = name.dropFirst() }
            }
            let components = name.split(separator: "/").filter { $0 != "." }
            if components.contains("..") {
                if report {
                    ctx.error("tar: \(stored): Member name contains '..'")
                    failed = true
                }
                return nil
            }
            guard components.count > options.strip else { return nil }
            let kept = components.dropFirst(options.strip).joined(separator: "/")
            return ctx.join(base, kept)
        }

        for member in members {
            if !patterns.isEmpty {
                var selected = false
                for (index, pattern) in patterns.enumerated() where tarSelects(pattern, member.name) {
                    matched[index] = true
                    selected = true
                }
                if !selected { continue }
            }
            if tarExcludes(options.excludes, member.name) { continue }

            if options.mode == "t" {
                let line = options.verbose > 0 ? tarLongListing(ctx, member, width: &listingWidth) : member.name
                out.append(contentsOf: Array((line + "\n").utf8))
                continue
            }

            // Extraction.
            let data = Array(archive[member.dataOffset..<(member.dataOffset + member.size)])
            if options.toStdout {
                if member.type == 0x30 || member.type == 0x37, !member.isDirectory {
                    if options.verbose > 0 { ctx.error(member.name) }
                    guard await ctx.put(data) else { return }
                }
                continue
            }
            guard let path = destination(member.name, report: true) else { continue }
            if options.verbose > 1 {
                out.append(contentsOf: Array((tarLongListing(ctx, member, width: &listingWidth) + "\n").utf8))
            } else if options.verbose == 1 {
                out.append(contentsOf: Array((member.name + "\n").utf8))
            }
            let parent = directoryName(path)
            if ctx.stat(parent) == nil { ctx.mkdir(parent) }
            let existing = ctx.lstat(path)

            if member.isDirectory {
                if existing?.type != .directory {
                    if existing != nil { try? ctx.unlinkOrThrow(path) }
                    guard ctx.mkdir(path) else {
                        ctx.error("tar: \(member.name): Cannot mkdir: Permission denied")
                        failed = true
                        continue
                    }
                }
                directories.append((path, member))
                continue
            }
            if let existing {
                if options.keepOld {
                    ctx.error("tar: \(member.name): Cannot open: File exists")
                    failed = true
                    continue
                }
                if existing.type == .directory {
                    ctx.error("tar: \(member.name): Cannot open: Is a directory")
                    failed = true
                    continue
                }
                try? ctx.unlinkOrThrow(path)
            }
            if member.type == 0x32 {
                guard ctx.symlink(member.linkName, at: path) else {
                    ctx.error("tar: \(member.name): Cannot create symlink to '\(member.linkName)': Permission denied")
                    failed = true
                    continue
                }
            } else if member.type == 0x31 {
                guard let target = destination(member.linkName, report: false), ctx.link(target, at: path) else {
                    ctx.error("tar: \(member.name): Cannot hard link to '\(member.linkName)': No such file or directory")
                    failed = true
                    continue
                }
            } else if member.type == 0x36 {
                guard ctx.mkfifo(path) else {
                    ctx.error("tar: \(member.name): Cannot mkfifo: Permission denied")
                    failed = true
                    continue
                }
                restoreMetadata(path, member)
            } else if member.type == 0x30 || member.type == 0x37 {
                do {
                    let fd = try ctx.openForWriting(path)
                    let written = await ctx.writeAll(fd, data)
                    ctx.close(fd)
                    guard written else {
                        ctx.error("tar: \(member.name): Cannot write: Input/output error")
                        failed = true
                        continue
                    }
                } catch {
                    ctx.error("tar: \(member.name): Cannot open: \(errnoText(error))")
                    failed = true
                    continue
                }
                restoreMetadata(path, member)
            } else {
                ctx.error("tar: \(member.name): Unknown file type '\(Character(UnicodeScalar(member.type)))'; skipped")
                failed = true
            }
        }
        for (path, member) in directories.reversed() { restoreMetadata(path, member) }

        guard await ctx.put(out) else { return }
        for (index, pattern) in patterns.enumerated() where !matched[index] {
            ctx.error("tar: \(pattern): Not found in archive")
            failed = true
        }
        if failed {
            ctx.fail("tar: Exiting with failure status due to previous errors")
        } else {
            ctx.exit(0)
        }
    }

    // MARK: gzip / gunzip / zcat

    private static func gzipCommand(_ name: String, summary: String, decompress: Bool, toStdout: Bool) -> Command {
        let synopsis = name == "gzip" ? "gzip [-cdfkt] [FILE]..." : "\(name) [-cfkt] [FILE]..."
        return Command(name: name, summary: summary, category: .fileSystem, usage: """
            \(synopsis)
              -c  write to standard output and keep the input files
              -d  decompress (the default for gunzip and zcat)
              -f  overwrite an existing output file
              -k  keep the input file instead of removing it
              -t  test the integrity of a compressed file
              With no FILE, or when FILE is -, filter standard input to standard output.
              FILE is replaced by FILE.gz (or FILE.gz by FILE). Compression levels -1..-9 are
              accepted, but output always uses stored (uncompressed) deflate blocks.
            """, asyncRun: { ctx, argv in
            guard let opts = ctx.options(name, Array(argv.dropFirst()), "cdfknNqvt123456789",
                                         long: ["stdout": "c", "to-stdout": "c", "decompress": "d",
                                                "uncompress": "d", "force": "f", "keep": "k", "test": "t",
                                                "quiet": "q", "verbose": "v", "fast": "1", "best": "9"]) else { return }
            let testing = opts.has("t")
            let expanding = decompress || opts.has("d") || testing
            let standardOutput = toStdout || opts.has("c")
            let files = opts.operands.isEmpty ? ["-"] : opts.operands
            var status: Int32 = 0

            for file in files {
                let label = file == "-" ? "stdin" : file
                if file != "-" {
                    guard let info = ctx.stat(file) else {
                        ctx.error("gzip: \(file): No such file or directory")
                        status = 1
                        continue
                    }
                    if info.type == .directory {
                        ctx.error("gzip: \(file) is a directory -- ignored")
                        if status == 0 { status = 2 }
                        continue
                    }
                }
                // Decide the output name before doing any work.
                var outputPath: String? = nil
                if file != "-", !standardOutput, !testing {
                    if expanding {
                        if file.hasSuffix(".gz"), file.count > 3 {
                            outputPath = String(file.dropLast(3))
                        } else if file.hasSuffix(".tgz"), file.count > 4 {
                            outputPath = String(file.dropLast(4)) + ".tar"
                        } else {
                            ctx.error("gzip: \(file): unknown suffix -- ignored")
                            if status == 0 { status = 2 }
                            continue
                        }
                    } else {
                        if file.hasSuffix(".gz") {
                            ctx.error("gzip: \(file) already has .gz suffix -- unchanged")
                            if status == 0 { status = 2 }
                            continue
                        }
                        outputPath = file + ".gz"
                    }
                    if let outputPath, ctx.lstat(outputPath) != nil, !opts.has("f") {
                        ctx.error("gzip: \(outputPath) already exists; not overwritten")
                        if status == 0 { status = 2 }
                        continue
                    }
                }
                let input: [UInt8]
                do {
                    input = try await readOperand(ctx, file)
                } catch {
                    ctx.error("gzip: \(file): \(errnoText(error))")
                    status = 1
                    continue
                }
                let output: [UInt8]
                if expanding {
                    do {
                        output = try Gzip.decompress(input)
                    } catch {
                        ctx.error("gzip: \(label): \((error as? Gzip.Failure)?.message ?? "invalid compressed data")")
                        status = 1
                        continue
                    }
                } else {
                    output = Gzip.compressStored(input)
                }
                if testing { continue }
                guard let outputPath else {
                    guard await ctx.put(output) else { return }
                    continue
                }
                do {
                    let fd = try ctx.openForWriting(outputPath)
                    let written = await ctx.writeAll(fd, output)
                    ctx.close(fd)
                    guard written else {
                        ctx.error("gzip: \(outputPath): write error")
                        status = 1
                        continue
                    }
                } catch {
                    ctx.error("gzip: \(outputPath): \(errnoText(error))")
                    status = 1
                    continue
                }
                // The replacement keeps the original's mode, owner and times.
                if let info = ctx.stat(file) {
                    _ = ctx.chown(outputPath, uid: info.uid, gid: info.gid)
                    _ = ctx.chmod(outputPath, mode: info.mode)
                    ctx.utimes(outputPath, atime: info.atime, mtime: info.mtime)
                }
                if !opts.has("k") {
                    try? ctx.unlinkOrThrow(file)
                }
            }
            ctx.exit(status)
        })
    }
}
