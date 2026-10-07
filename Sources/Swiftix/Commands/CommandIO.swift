/// Diagnostics and option-token helpers shared by the built-in commands.
///
/// The built-ins are plain programs over `ProcessContext`, so reporting a problem
/// means writing bytes to fd 2 and setting an exit status. Spelled out at every
/// call site that was `ctx.write(2, Array("cmd: …\n".utf8)); ctx.exit(2); return`
/// — 136 times across `Commands/`, with the trailing newline, the `2`, and the
/// `cmd: ` prefix all re-typed each time. These helpers name the three recurring
/// shapes so a command says what it means and the convention is enforced in one
/// place rather than by copy-paste.
///
/// Deliberately `internal`: this is the shape of the library's own built-ins, not
/// part of the consumer boundary. A consumer writing its own `Command` uses the
/// public syscall surface (`write` / `exit`) directly.
///
/// Concurrency: pure extensions over `ProcessContext`, which is part of the
/// non-Sendable reference-type core and is only touched on the single serial
/// executor driving the kernel. Nothing here adds state or locks.

extension ProcessContext {

    /// Writes one diagnostic line to stderr, supplying the trailing newline.
    func error(_ message: String) {
        write(2, Array((message + "\n").utf8))
    }

    /// Writes one diagnostic line to stderr and sets the exit status.
    ///
    /// The caller must still `return`, because a `Command` body owns its own
    /// control flow — `exit(_:)` records the status, it does not unwind.
    func fail(_ message: String, code: Int32 = 2) {
        error(message)
        exit(code)
    }

    /// Reports a usage error in the built-ins' standard form
    /// (`"<command>: usage: <synopsis>"`) and sets the exit status.
    ///
    /// Exit code 2 is the convention across the built-in set for "you invoked me
    /// wrongly", as distinct from 1 for "I ran and the operation failed".
    func usage(_ command: String, _ synopsis: String, code: Int32 = 2) {
        fail("\(command): usage: \(synopsis)", code: code)
    }
}

/// Shared argument-vector predicates for the built-ins' option parsers.
enum CommandArguments {

    /// Whether `token` introduces options rather than naming an operand.
    ///
    /// True for `-l`, a combined `-la`, and a long `--uts`; false for an operand,
    /// for the empty string, and for a bare `-` (which by convention names standard
    /// input, not an option).
    ///
    /// This single predicate replaces three spellings that were scattered across
    /// the option loops and looked like they disagreed:
    ///
    ///     first.hasPrefix("-") && first.count > 1     // ls, du, grep, kill
    ///     first.hasPrefix("-") && first.count >= 2    // touch
    ///     first.hasPrefix("-") && first != "-"        // unshare, nsenter
    ///
    /// All three are the same test: a string that starts with `-` has `count > 1`
    /// exactly when it is not the one-character string `-`. Naming it once removes
    /// the appearance of a disagreement and gives the `-`-means-stdin convention a
    /// place to be documented.
    static func isOptionToken(_ token: String) -> Bool {
        token.hasPrefix("-") && token != "-"
    }
}

// MARK: - errno text

extension SyscallError {

    /// The `strerror`-style text the built-ins print after `cmd: path: `. One
    /// table, so every command reports the same words for the same failure.
    var message: String {
        if self == .noSuchFileOrDirectory { return "No such file or directory" }
        if self == .permissionDenied || self == .capabilityViolation { return "Permission denied" }
        if self == .isADirectory { return "Is a directory" }
        if self == .notADirectory { return "Not a directory" }
        if self == .directoryNotEmpty { return "Directory not empty" }
        if self == .fileExists { return "File exists" }
        if self == .brokenPipe { return "Broken pipe" }
        if self == .badFileDescriptor { return "Bad file descriptor" }
        if self == .interrupted { return "Interrupted system call" }
        if self == .inputOutput { return "Input/output error" }
        if self == .wouldBlock { return "Resource temporarily unavailable" }
        if self == .noChildProcess { return "No child processes" }
        if self == .noSuchDevice { return "No such device" }
        if self == .invalidArgument { return "Invalid argument" }
        if self == .noSpace { return "No space left on device" }
        if self == .readOnlyFileSystem { return "Read-only file system" }
        if self == .connectionReset { return "Connection reset by peer" }
        if self == .notConnected { return "Transport endpoint is not connected" }
        return "Unknown error \(code)"
    }
}

/// The errno text for any thrown error (non-`SyscallError` values are not
/// expected from the syscall surface; they degrade to a generic message).
func errnoText(_ error: Error) -> String {
    (error as? SyscallError)?.message ?? "Input/output error"
}

// MARK: - Option parsing

/// The result of a getopt-style parse: which single-letter options were seen,
/// the arguments of the valued ones (in order), and the remaining operands.
struct CommandOptions {
    var flags: [Character: Int] = [:]
    var values: [Character: [String]] = [:]
    var operands: [String] = []
    /// Every option in command-line order (for "last one wins" decisions).
    var sequence: [(option: Character, value: String?)] = []

    func has(_ option: Character) -> Bool { flags[option] != nil || values[option] != nil }
    func count(_ option: Character) -> Int { flags[option] ?? values[option]?.count ?? 0 }
    /// The last argument given to a valued option.
    func value(_ option: Character) -> String? { values[option]?.last }
    func all(_ option: Character) -> [String] { values[option] ?? [] }
}

extension ProcessContext {

    /// Reports an unknown option in the built-ins' standard form and exits 2:
    ///
    ///     cmd: invalid option -- 'x'
    ///     Try 'cmd --help' for more information.
    func invalidOption(_ command: String, _ option: String) {
        if option.hasPrefix("--") {
            error("\(command): unrecognized option '\(option)'")
        } else {
            error("\(command): invalid option -- '\(option)'")
        }
        fail("Try '\(command) --help' for more information.")
    }

    /// Parse `args` (argv without the command name) against a getopt-style
    /// `spec`: each letter is a flag, a letter followed by `:` takes an argument
    /// (`-n 5`, `-n5`). Flags combine (`-lah`); `--` ends option parsing; a bare
    /// `-` is an operand. Options may follow operands (GNU permutation) unless
    /// `stopAtOperand` is set (for commands whose operands are another command
    /// line). `long` maps `--name` / `--name=value` onto a short option.
    ///
    /// On an unknown option or a missing argument this prints the standard
    /// diagnostic, sets exit status 2, and returns `nil` — the caller just
    /// `return`s.
    func options(_ command: String,
                 _ args: [String],
                 _ spec: String,
                 long: [String: Character] = [:],
                 stopAtOperand: Bool = false) -> CommandOptions? {
        var takesValue: [Character: Bool] = [:]
        let specChars = Array(spec)
        var position = 0
        while position < specChars.count {
            let letter = specChars[position]
            let valued = position + 1 < specChars.count && specChars[position + 1] == ":"
            takesValue[letter] = valued
            position += valued ? 2 : 1
        }

        var result = CommandOptions()
        var index = 0
        func record(_ option: Character, _ value: String?) {
            if let value {
                result.values[option, default: []].append(value)
            } else {
                result.flags[option, default: 0] += 1
            }
            result.sequence.append((option, value))
        }
        while index < args.count {
            let token = args[index]
            if token == "--" {
                result.operands.append(contentsOf: args[(index + 1)...])
                break
            }
            if token.hasPrefix("--") {
                let body = token.dropFirst(2)
                let name: String
                var inlineValue: String? = nil
                if let equals = body.firstIndex(of: "=") {
                    name = String(body[..<equals])
                    inlineValue = String(body[body.index(after: equals)...])
                } else {
                    name = String(body)
                }
                guard let option = long[name], let valued = takesValue[option] else {
                    invalidOption(command, "--" + name)
                    return nil
                }
                if valued {
                    if let inlineValue {
                        record(option, inlineValue)
                    } else if index + 1 < args.count {
                        index += 1
                        record(option, args[index])
                    } else {
                        error("\(command): option '--\(name)' requires an argument")
                        fail("Try '\(command) --help' for more information.")
                        return nil
                    }
                } else {
                    record(option, nil)
                }
                index += 1
                continue
            }
            if !CommandArguments.isOptionToken(token) {
                if stopAtOperand {
                    result.operands.append(contentsOf: args[index...])
                    break
                }
                result.operands.append(token)
                index += 1
                continue
            }
            let letters = Array(token.dropFirst())
            var offset = 0
            while offset < letters.count {
                let letter = letters[offset]
                guard let valued = takesValue[letter] else {
                    invalidOption(command, String(letter))
                    return nil
                }
                if !valued {
                    record(letter, nil)
                    offset += 1
                    continue
                }
                let attached = String(letters[(offset + 1)...])
                if !attached.isEmpty {
                    record(letter, attached)
                } else if index + 1 < args.count {
                    index += 1
                    record(letter, args[index])
                } else {
                    error("\(command): option requires an argument -- '\(letter)'")
                    fail("Try '\(command) --help' for more information.")
                    return nil
                }
                break
            }
            index += 1
        }
        return result
    }
}

// MARK: - Output with backpressure

extension ProcessContext {

    /// Write every byte of `bytes` to `fd`, parking on the event loop while a
    /// pipe is full instead of dropping the tail (a bare `write` to a full pipe
    /// accepts only what fits). Returns `false` when the write cannot complete —
    /// the reader went away (the kernel has already delivered SIGPIPE), the
    /// wait was interrupted by a signal, or the write failed outright (reported
    /// on stderr as `cmd: write error: …`, exit status 1) — in which case the
    /// caller should simply return.
    @discardableResult
    func writeAll(_ fd: Int, _ bytes: [UInt8]) async -> Bool {
        var offset = 0
        var idleRounds = 0
        while offset < bytes.count {
            let end = Swift.min(bytes.count, offset + 32 * 1024)
            let accepted: Int
            do {
                accepted = try writeFile(fd, Array(bytes[offset..<end]))
            } catch SyscallError.wouldBlock {
                accepted = 0
            } catch SyscallError.brokenPipe {
                return false
            } catch {
                // A real write failure (`> /dev/full` is ENOSPC): say so and
                // fail, instead of ending silently with status 0.
                if fd != 2 {
                    let name = arguments.first ?? "write"
                    self.error("\(name): write error: \(errnoText(error))")
                }
                exit(1)
                return false
            }
            offset += accepted
            if accepted > 0 { idleRounds = 0; continue }
            // Nothing fit: wait until the descriptor is writable (or hung up, in
            // which case the next write reports the broken pipe).
            idleRounds += 1
            if idleRounds > 8 { return false }
            guard (try? await poll([PollRequest(fd: fd, interests: .writable)])) != nil else {
                return false
            }
        }
        return true
    }

    /// Write text to stdout with backpressure (see `writeAll`).
    @discardableResult
    func put(_ text: String) async -> Bool {
        await writeAll(1, Array(text.utf8))
    }

    /// Write bytes to stdout with backpressure (see `writeAll`).
    @discardableResult
    func put(_ bytes: [UInt8]) async -> Bool {
        await writeAll(1, bytes)
    }

    /// Write `text` to stdout in full, then exit with `status`. The common tail
    /// of a filter that has computed its whole output.
    func emit(_ text: String, exit status: Int32 = 0) async {
        if await put(text) { exit(status) }
    }

    /// Byte-buffer form of `emit(_:exit:)`.
    func emit(_ bytes: [UInt8], exit status: Int32 = 0) async {
        if await put(bytes) { exit(status) }
    }
}

// MARK: - Input

/// Sequential reader over a command's input operands — the named files in
/// order, a `-` meaning standard input, or standard input alone when there are
/// no operands. It reads incrementally through the async `read`, so a filter
/// built on it works on pipes, FIFOs, terminals, and device files without
/// slurping, and can stop early (`head`) or run forever (`tail -f` upstream).
///
/// An operand that cannot be opened is reported as `cmd: path: <errno text>`
/// and recorded in `status`; reading continues with the next operand.
///
/// Concurrency: a plain reference type used only from the owning command body
/// on the loop-bound executor.
final class CommandInput {
    private let ctx: ProcessContext
    private let command: String
    private var pending: ArraySlice<String>
    private var fd: Int? = nil
    private var ownsDescriptor = false
    private var buffer: [UInt8] = []
    private var bufferStart = 0
    private var scanStart = 0
    private var atEnd = false

    /// Non-zero once any operand failed to open.
    private(set) var status: Int32 = 0
    /// The operand currently being read (`-` for standard input).
    private(set) var currentName = "-"
    /// Incremented each time reading moves on to another operand.
    private(set) var fileIndex = -1

    /// The descriptor a `-` operand reads (standard input unless the caller
    /// has already opened something else to read through this interface).
    private let standardInput: Int

    init(_ ctx: ProcessContext, command: String, files: [String], descriptor: Int = 0) {
        self.ctx = ctx
        self.command = command
        self.pending = files.isEmpty ? ["-"][...] : files[...]
        self.standardInput = descriptor
    }

    private func openNext() -> Bool {
        while let name = pending.first {
            pending = pending.dropFirst()
            if name == "-" {
                fd = standardInput
                ownsDescriptor = false
                currentName = name
                fileIndex += 1
                return true
            }
            do {
                fd = try ctx.openFile(name)
                ownsDescriptor = true
                currentName = name
                fileIndex += 1
                return true
            } catch {
                ctx.error("\(command): \(name): \(errnoText(error))")
                status = 1
            }
        }
        return false
    }

    /// The next chunk of raw bytes, or `nil` at the end of all input.
    func chunk(max: Int = 65536) async -> [UInt8]? {
        if bufferStart < buffer.count {
            let rest = Array(buffer[bufferStart...])
            buffer = []
            bufferStart = 0
            scanStart = 0
            return rest
        }
        while !atEnd {
            if fd == nil, !openNext() { atEnd = true; break }
            guard let descriptor = fd else { break }
            let bytes = (try? await ctx.read(descriptor, upTo: max)) ?? []
            if !bytes.isEmpty { return bytes }
            if ownsDescriptor { ctx.close(descriptor) }
            fd = nil
        }
        return nil
    }

    /// The next line without its terminating newline, or `nil` at end of input.
    /// A final line with no newline is still delivered. Lines never span two
    /// operands.
    func line() async -> [UInt8]? {
        while true {
            if let newline = buffer[scanStart...].firstIndex(of: 0x0A) {
                let line = Array(buffer[bufferStart..<newline])
                bufferStart = newline + 1
                if bufferStart > 1 << 16 {
                    buffer.removeFirst(bufferStart)
                    bufferStart = 0
                }
                scanStart = bufferStart
                return line
            }
            scanStart = buffer.count
            if atEnd { return takeRemainder() }
            if fd == nil, !openNext() {
                atEnd = true
                return takeRemainder()
            }
            guard let descriptor = fd else { continue }
            let bytes = (try? await ctx.read(descriptor, upTo: 65536)) ?? []
            if bytes.isEmpty {
                if ownsDescriptor { ctx.close(descriptor) }
                fd = nil
                // An unterminated last line of this operand is its own line.
                if let rest = takeRemainder() { return rest }
                continue
            }
            buffer.append(contentsOf: bytes)
        }
    }

    private func takeRemainder() -> [UInt8]? {
        defer {
            buffer = []
            bufferStart = 0
            scanStart = 0
        }
        guard bufferStart < buffer.count else { return nil }
        return Array(buffer[bufferStart...])
    }

    /// Everything that remains, concatenated.
    func all() async -> [UInt8] {
        var data: [UInt8] = []
        while let bytes = await chunk() { data.append(contentsOf: bytes) }
        return data
    }
}

extension BuiltinCommands {

    /// Read every input operand to the end (files in order, `-` or no operands
    /// meaning standard input) and return the concatenated bytes plus the exit
    /// status contribution (1 when an operand could not be opened).
    static func readInput(_ ctx: ProcessContext,
                          cmd: String,
                          files: [String]) async -> (data: [UInt8], status: Int32) {
        let input = CommandInput(ctx, command: cmd, files: files)
        let data = await input.all()
        return (data, input.status)
    }

    /// Read one operand in full: a path, or `-` for standard input. Throws the
    /// `SyscallError` from `open` so the caller can word its own diagnostic.
    static func readOperand(_ ctx: ProcessContext, _ path: String) async throws -> [UInt8] {
        let fd = path == "-" ? 0 : try ctx.openFile(path)
        var data: [UInt8] = []
        while let bytes = try? await ctx.read(fd, upTo: 65536), !bytes.isEmpty {
            data.append(contentsOf: bytes)
        }
        if path != "-" { ctx.close(fd) }
        return data
    }

    /// Text of a line's bytes (invalid UTF-8 is repaired, as everywhere else in
    /// the text tools).
    static func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
