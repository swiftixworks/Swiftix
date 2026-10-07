/// The `awk` back end: a tree-walking interpreter over the `AwkProgram` the
/// parser produced, plus the record reader that feeds it.
///
/// The interpreter owns all of awk's run-time state — variables and arrays,
/// the current record and its lazily split fields, queued output, open
/// redirections, and the walk over the input operands.
///
/// It is two evaluators over one tree. Everything the parser marked `.pure` /
/// `.simple` (no user-function call, no `getline`, no loop) runs in plain
/// synchronous code: `value(_:)` and `run(_:)`. Only what can genuinely wait
/// is `async` — `evaluate(_:)` / `execute(_:)` for calls, `getline` and loops —
/// and those hand every pure operand straight back to the synchronous side.
/// The split matters on this kernel: entering an `async` function costs one
/// event-loop job, so an all-`async` walker would spend a job per syntax node.
/// As built, a rule such as `{ print $1 }` costs no jobs per record beyond the
/// reads and writes themselves.
///
/// All waiting is an `await` on a `ProcessContext` syscall. Input arrives
/// through `CommandInput.chunk()`; output is queued and written with
/// `writeAll` (pipe backpressure) at checkpoints — once per record, per loop
/// iteration and per function call — whenever 8 KiB is pending, when the
/// reader has to go back to its descriptor for more input (so an interactive
/// or piped session sees output as soon as awk would block), and at exit.
/// Text for stderr travels in the same queue, which keeps it ordered with
/// stdout. Every 65 536 checkpoints the interpreter also yields
/// (`ProcessContext.yield()`), so a runaway program stays interruptible and
/// does not hold logical time.
///
/// Concurrency: plain reference types used only from the owning `awk` command
/// body on the kernel's loop-bound serial executor. No locks, not `Sendable`.

// MARK: - Values and storage

enum AwkValue {
    /// Never assigned: the empty string and zero at once.
    case uninitialized
    case number(Double)
    case string(String)
    /// Text that came from input (a field, `getline`, `split`, `-v`, …): it
    /// compares numerically when it looks like a number.
    case numericString(String)
}

final class AwkArray {
    var items: [String: AwkValue] = [:]
}

/// One variable slot. `array` is set once the variable is used as an array;
/// `alias` links an untyped function argument back to the caller's variable so
/// that a callee can still turn it into an array by reference.
final class AwkVariable {
    var value: AwkValue = .uninitialized
    var array: AwkArray?
    var alias: AwkVariable?
}

enum AwkRuntimeError: Error {
    case failure(String)
    /// Output can no longer be delivered (or the process was interrupted):
    /// stop quietly.
    case stopped
}

enum AwkFlow {
    case normal, breakLoop, continueLoop, next, nextFile, exit, returned
}

/// `next` / `exit` raised inside a function call, carried out through the
/// expression evaluator to the rule loop.
struct AwkUnwind: Error {
    let flow: AwkFlow
}

// MARK: - Record reader

/// Splits a byte stream into records on `RS` (a single character, or
/// paragraph mode for the empty string) without ever blocking: `take` reports
/// `.needMore` and the caller awaits `refill()`.
final class AwkRecordReader {
    enum Source {
        case input(CommandInput)
        case descriptor(Int, owned: Bool)
    }

    enum Step {
        case record([UInt8])
        case needMore
        case end
    }

    let source: Source
    private let ctx: ProcessContext
    private var buffer: [UInt8] = []
    private var start = 0
    private var scan = 0
    private var atEnd = false
    private var lastSeparator: String? = nil

    init(_ ctx: ProcessContext, source: Source) {
        self.ctx = ctx
        self.source = source
    }

    func refill() async {
        let bytes: [UInt8]
        switch source {
        case let .input(input):
            bytes = await input.chunk() ?? []
        case let .descriptor(fd, _):
            bytes = (try? await ctx.read(fd, upTo: 65536)) ?? []
        }
        if bytes.isEmpty {
            atEnd = true
            return
        }
        if start > 0 {
            buffer.removeFirst(start)
            scan = Swift.max(0, scan - start)
            start = 0
        }
        buffer.append(contentsOf: bytes)
    }

    func close() {
        if case let .descriptor(fd, owned) = source, owned { ctx.close(fd) }
    }

    func take(separator: String) -> Step {
        if separator != lastSeparator {
            lastSeparator = separator
            scan = start
        }
        guard let first = separator.first else { return takeParagraph() }
        let pattern = Array(String(first).utf8)
        if scan < start { scan = start }
        var found: Int? = nil
        if pattern.count == 1 {
            found = buffer[scan...].firstIndex(of: pattern[0])
        } else {
            var index = scan
            while index + pattern.count <= buffer.count {
                if buffer[index] == pattern[0], buffer[index..<index + pattern.count].elementsEqual(pattern) {
                    found = index
                    break
                }
                index += 1
            }
        }
        if let found {
            let record = Array(buffer[start..<found])
            start = found + pattern.count
            scan = start
            return .record(record)
        }
        if !atEnd {
            scan = Swift.max(start, buffer.count - (pattern.count - 1))
            return .needMore
        }
        guard start < buffer.count else { return .end }
        let record = Array(buffer[start...])
        start = buffer.count
        scan = start
        return .record(record)
    }

    /// `RS = ""`: records are separated by one or more blank lines.
    private func takeParagraph() -> Step {
        while start < buffer.count, buffer[start] == 0x0A { start += 1 }
        if scan < start { scan = start }
        if start == buffer.count { return atEnd ? .end : .needMore }
        var index = scan
        while index + 1 < buffer.count {
            if buffer[index] == 0x0A, buffer[index + 1] == 0x0A {
                let record = Array(buffer[start..<index])
                start = index + 2
                scan = start
                return .record(record)
            }
            index += 1
        }
        if !atEnd {
            scan = Swift.max(start, buffer.count - 1)
            return .needMore
        }
        var end = buffer.count
        while end > start, buffer[end - 1] == 0x0A { end -= 1 }
        let record = Array(buffer[start..<end])
        start = buffer.count
        scan = start
        return .record(record)
    }
}

// MARK: - Interpreter

final class AwkInterpreter {
    private let ctx: ProcessContext
    private let program: AwkProgram
    private var globals: [AwkVariable]
    private var locals: [AwkVariable] = []
    private var callDepth = 0
    private var returnValue = AwkValue.uninitialized

    // The current record.
    private var record = ""
    private var recordCharacters: [Character]? = nil
    private var fields: [String] = []
    private var fieldsValid = true

    // Cached copies of the special variables the hot paths consult.
    private var fieldSeparator = " "
    private var fieldSplitter: Splitter? = .whitespace
    private var outputFieldSeparator = " "
    private var outputRecordSeparator = "\n"
    private var recordSeparator = "\n"
    private var subscriptSeparator = "\u{1C}"
    private var conversionFormat = "%.6g"
    private var outputFormat = "%.6g"
    private var recordNumber = 0.0
    private var fileRecordNumber = 0.0

    private var regexCache: [String: Regex] = [:]
    private var rangeActive: [Bool]

    // Output: stdout / stderr text queued in order, plus redirection files.
    private struct OutputChunk {
        let fd: Int
        var bytes: [UInt8]
    }
    private struct OutputStream {
        let fd: Int
        var buffer: [UInt8] = []
        /// The `sh -c` child reading this stream (`print | "command"`).
        var child: PID? = nil
    }
    private var chunks: [OutputChunk] = []
    private var pendingBytes = 0
    private var flushRequested = false
    private var streams: [String: OutputStream] = [:]
    private var closingStreams: [OutputStream] = []
    /// Children feeding the `"command" | getline` readers, keyed like `readers`.
    private var readerChildren: [String: PID] = [:]
    private static let flushThreshold = 8192

    // Input.
    private var mainReader: AwkRecordReader? = nil
    private var mainInput: CommandInput? = nil
    private var argumentIndex = 1
    private var sawFileOperand = false
    private var usedStandardInput = false
    private var readers: [String: AwkRecordReader] = [:]
    private var inputFailed = false

    private var exitCode: Int32 = 0
    private var steps = 0
    private var randomSeed = 0.0
    private var randomState: UInt64 = 0

    init(_ ctx: ProcessContext, program: AwkProgram, arguments: [String]) {
        self.ctx = ctx
        self.program = program
        globals = program.globalNames.map { _ in AwkVariable() }
        rangeActive = Array(repeating: false, count: program.rules.count)
        globals[AwkSpecial.fs].value = .string(" ")
        globals[AwkSpecial.ofs].value = .string(" ")
        globals[AwkSpecial.ors].value = .string("\n")
        globals[AwkSpecial.rs].value = .string("\n")
        globals[AwkSpecial.subsep].value = .string(subscriptSeparator)
        globals[AwkSpecial.convfmt].value = .string(conversionFormat)
        globals[AwkSpecial.ofmt].value = .string(outputFormat)
        globals[AwkSpecial.nr].value = .number(0)
        globals[AwkSpecial.fnr].value = .number(0)
        globals[AwkSpecial.rstart].value = .number(0)
        globals[AwkSpecial.rlength].value = .number(-1)
        globals[AwkSpecial.filename].value = .string("")
        let environment = AwkArray()
        for (name, value) in ctx.environment { environment.items[name] = .numericString(value) }
        globals[AwkSpecial.environ].array = environment
        let argv = AwkArray()
        for (index, argument) in arguments.enumerated() {
            argv.items[String(index)] = .numericString(argument)
        }
        globals[AwkSpecial.argv].array = argv
        globals[AwkSpecial.argc].value = .number(Double(arguments.count))
        seedRandom(0)
    }

    // MARK: Top level

    /// Assign a command-line `name=value` (`-v`, or an operand between files).
    /// Returns `false` when `text` is not of that form.
    @discardableResult
    func assignCommandLine(_ text: String) throws -> Bool {
        guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { return false }
        let name = text[..<equals]
        func isLetter(_ byte: UInt8) -> Bool {
            byte == 0x5F || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        }
        guard let first = name.utf8.first, isLetter(first),
              name.utf8.allSatisfy({ isLetter($0) || ($0 >= 0x30 && $0 <= 0x39) })
        else { return false }
        let value = AwkLexer.unescape(String(text[text.index(after: equals)...]))
        // A variable the program never mentions cannot be observed.
        if let slot = program.globalNames.firstIndex(of: String(name)) {
            try writeVariable(.global(slot), .numericString(value))
        }
        return true
    }

    /// Run the whole program; returns the exit status.
    func run() async -> Int32 {
        do {
            try await runRules()
            try await flushAll()
            await finishStreams()
        } catch AwkRuntimeError.stopped {
            await finishStreams()
            return exitCode
        } catch let AwkRuntimeError.failure(message) {
            append(2, "awk: \(message)\n")
            try? await flushAll()
            await finishStreams()
            return 2
        } catch {
            await finishStreams()
            return 2
        }
        if exitCode == 0, inputFailed { return 2 }
        return exitCode
    }

    private func runRules() async throws {
        var exiting = false
        var needsInput = false
        var hasEnd = false
        var isSimpleRule: [Bool] = []
        for rule in program.rules {
            switch rule.pattern {
            case .begin: break
            case .end: hasEnd = true
            default: needsInput = true
            }
            isSimpleRule.append(Self.isSimple(rule))
        }
        for rule in program.rules {
            guard case .begin = rule.pattern else { continue }
            if try await runBody(rule.body) == .exit {
                exiting = true
                break
            }
        }
        if !exiting, needsInput || hasEnd {
            records: while true {
                // A record that is already buffered is taken without awaiting.
                var next = takeBufferedMainRecord()
                if next == nil { next = try await nextMainRecord() }
                guard let next else { break }
                setRecord(next)
                for (index, rule) in program.rules.enumerated() {
                    let flow: AwkFlow
                    if isSimpleRule[index] {
                        flow = try runSimpleRule(rule, index)
                    } else {
                        flow = try await runRule(rule, index)
                    }
                    if flow == .next { break }
                    if flow == .nextFile {
                        closeMainReader()
                        break
                    }
                    if flow == .exit {
                        exiting = true
                        break records
                    }
                }
                if checkpointDue { try await checkpoint() }
            }
        }
        for rule in program.rules {
            guard case .end = rule.pattern else { continue }
            if try await runBody(rule.body) == .exit { break }
        }
    }

    /// Whether a main rule can run without suspending at all.
    private static func isSimple(_ rule: AwkRule) -> Bool {
        switch rule.pattern {
        case .begin, .end:
            return false
        case .always:
            break
        case let .expression(condition):
            guard case .pure = condition else { return false }
        case let .range(first, last):
            guard case .pure = first, case .pure = last else { return false }
        }
        guard let body = rule.body else { return true }
        return body.allSatisfy { statement in
            if case .simple = statement { return true }
            return false
        }
    }

    private func runSimpleRule(_ rule: AwkRule, _ index: Int) throws -> AwkFlow {
        switch rule.pattern {
        case .begin, .end:
            return .normal
        case .always:
            break
        case let .expression(condition):
            guard truth(try value(condition)) else { return .normal }
        case let .range(first, last):
            if !rangeActive[index] {
                guard truth(try value(first)) else { return .normal }
                rangeActive[index] = true
            }
            if truth(try value(last)) { rangeActive[index] = false }
        }
        guard let body = rule.body else {
            append(1, record + outputRecordSeparator)
            return .normal
        }
        for statement in body {
            let flow = try run(statement)
            if flow != .normal { return flow }
        }
        return .normal
    }

    private func runRule(_ rule: AwkRule, _ index: Int) async throws -> AwkFlow {
        do {
            switch rule.pattern {
            case .begin, .end:
                return .normal
            case .always:
                break
            case let .expression(condition):
                guard truth(try await evaluate(condition)) else { return .normal }
            case let .range(first, last):
                if !rangeActive[index] {
                    guard truth(try await evaluate(first)) else { return .normal }
                    rangeActive[index] = true
                }
                if truth(try await evaluate(last)) { rangeActive[index] = false }
            }
        } catch let unwind as AwkUnwind {
            return unwind.flow
        }
        return try await runBody(rule.body)
    }

    private func runBody(_ body: [AwkStmt]?) async throws -> AwkFlow {
        do {
            guard let body else {
                append(1, record + outputRecordSeparator)
                return .normal
            }
            return try await execute(body)
        } catch let unwind as AwkUnwind {
            return unwind.flow
        }
    }

    private func closeDescriptors() {
        for stream in streams.values { ctx.close(stream.fd) }
        streams.removeAll()
        for stream in closingStreams { ctx.close(stream.fd) }
        closingStreams.removeAll()
        for reader in readers.values { reader.close() }
        readers.removeAll()
    }

    /// End-of-program teardown: close every stream, then wait for the
    /// commands behind `print | "command"` / `"command" | getline`, so their
    /// output is complete before awk itself exits.
    private func finishStreams() async {
        let children = streams.values.compactMap(\.child) + closingStreams.compactMap(\.child)
            + Array(readerChildren.values)
        closeDescriptors()
        readerChildren.removeAll()
        for child in children { _ = try? await ctx.waitpid(child) }
    }

    // MARK: Commands

    /// Start `sh -c command` as a child with its stdin and/or stdout replaced
    /// by the given descriptors. Every descriptor awk itself holds open for
    /// redirections is closed in the child, so no pipe is kept alive by an
    /// unrelated command. Returns `nil` when there is no shell to run it.
    private func spawnShell(_ command: String, stdin: Int? = nil, stdout: Int? = nil,
                            closing extra: [Int] = []) -> PID? {
        guard let shell = ctx.resolveCommand("sh") else { return nil }
        var inherited = streams.values.map(\.fd) + closingStreams.map(\.fd) + extra
        for reader in readers.values {
            if case let .descriptor(fd, owned) = reader.source, owned { inherited.append(fd) }
        }
        let argv = ["sh", "-c", command]
        let wire: (ProcessContext) -> Void = { child in
            if let stdin { child.dup2(stdin, onto: 0) }
            if let stdout { child.dup2(stdout, onto: 1) }
            for fd in inherited { child.close(fd) }
        }
        let pid: PID
        switch shell.body {
        case let .sync(body):
            pid = ctx.spawn("sh", args: argv) { child in
                wire(child)
                body(child, argv)
            }
        case let .async(body):
            pid = ctx.spawn("sh", args: argv) { (child: ProcessContext) async in
                wire(child)
                await body(child, argv)
            }
        }
        return pid == 0 ? nil : pid
    }

    /// `system(command)`: flush pending output, run the command, return its
    /// exit status.
    private func system(_ command: String) async throws -> AwkValue {
        try await flushAll()
        guard let pid = spawnShell(command) else { throw failure("system: cannot run sh") }
        guard let event = try? await ctx.waitpid(pid) else { throw AwkRuntimeError.stopped }
        return .number(Double(event.status.code))
    }

    /// `close(name)` in a context that may wait: an output pipe is drained,
    /// closed, and its command awaited (the result is its exit status); a
    /// command read with `getline` is awaited too.
    private func close(_ name: String) async throws -> AwkValue {
        var result: Double = -1
        if let stream = streams[name], let child = stream.child {
            streams[name] = nil
            try await flushAll()
            await ctx.writeAll(stream.fd, stream.buffer)
            ctx.close(stream.fd)
            result = Double((try? await ctx.waitpid(child))?.status.code ?? 0)
        } else if closeStream(name) {
            result = 0
        }
        if let reader = readers.removeValue(forKey: name) {
            reader.close()
            result = 0
            if let child = readerChildren.removeValue(forKey: name) {
                result = Double((try? await ctx.waitpid(child))?.status.code ?? 0)
            }
        }
        return .number(result)
    }

    private func failure(_ message: String) -> AwkRuntimeError { .failure(message) }

    // MARK: Output

    /// Queue text for stdout (1) or stderr (2), preserving their order.
    private func append(_ fd: Int, _ text: String) {
        if let last = chunks.indices.last, chunks[last].fd == fd {
            chunks[last].bytes.append(contentsOf: text.utf8)
        } else {
            chunks.append(OutputChunk(fd: fd, bytes: Array(text.utf8)))
        }
        pendingBytes += text.utf8.count
        if fd == 2 { flushRequested = true }
    }

    /// Write everything queued: the stdout / stderr chunks in order, then the
    /// redirection files.
    private func flushAll() async throws {
        flushRequested = false
        if !chunks.isEmpty {
            let queued = chunks
            chunks.removeAll()
            pendingBytes = 0
            for chunk in queued {
                if chunk.fd == 1 {
                    guard await ctx.put(chunk.bytes) else { throw AwkRuntimeError.stopped }
                } else {
                    ctx.write(2, chunk.bytes)
                }
            }
        }
        for name in Array(streams.keys) {
            guard var stream = streams[name], !stream.buffer.isEmpty else { continue }
            let bytes = stream.buffer
            stream.buffer = []
            streams[name] = stream
            await ctx.writeAll(stream.fd, bytes)
        }
        if !closingStreams.isEmpty {
            let closing = closingStreams
            closingStreams.removeAll()
            for stream in closing {
                await ctx.writeAll(stream.fd, stream.buffer)
                ctx.close(stream.fd)
                if let child = stream.child { _ = try? await ctx.waitpid(child) }
            }
        }
    }

    /// Deliver one `print` / `printf` result to stdout or its redirection.
    private func send(_ text: String, _ destination: (name: String, append: Bool, pipe: Bool)?) throws {
        guard let destination else {
            append(1, text)
            return
        }
        let name = destination.name
        if destination.pipe {
            if streams[name] == nil {
                let pipe = ctx.pipe()
                guard let child = spawnShell(name, stdin: pipe.read, closing: [pipe.read, pipe.write]) else {
                    ctx.close(pipe.read)
                    ctx.close(pipe.write)
                    throw failure("can't open pipe to \(name)")
                }
                ctx.close(pipe.read)
                streams[name] = OutputStream(fd: pipe.write, child: child)
            }
            streams[name]?.buffer.append(contentsOf: text.utf8)
            if (streams[name]?.buffer.count ?? 0) >= Self.flushThreshold { flushRequested = true }
            return
        }
        if name == "/dev/stdout" || name == "-" {
            append(1, text)
            return
        }
        if name == "/dev/stderr" {
            append(2, text)
            return
        }
        if streams[name] == nil {
            do {
                let fd = try ctx.openForWriting(name, truncate: !destination.append, append: destination.append)
                streams[name] = OutputStream(fd: fd)
            } catch {
                throw failure("can't redirect to \(name): \(errnoText(error))")
            }
        }
        streams[name]?.buffer.append(contentsOf: text.utf8)
        if (streams[name]?.buffer.count ?? 0) >= Self.flushThreshold { flushRequested = true }
    }

    /// `close(name)` for an output redirection: write what the descriptor
    /// accepts right now (a regular file takes it all); anything left is
    /// written, and the descriptor closed, at the next checkpoint.
    private func closeStream(_ name: String) -> Bool {
        guard var stream = streams.removeValue(forKey: name) else { return false }
        var offset = 0
        while offset < stream.buffer.count {
            guard let accepted = try? ctx.writeFile(stream.fd, Array(stream.buffer[offset...])), accepted > 0 else {
                break
            }
            offset += accepted
        }
        if offset == stream.buffer.count {
            ctx.close(stream.fd)
        } else {
            stream.buffer.removeFirst(offset)
            closingStreams.append(stream)
            flushRequested = true
        }
        return true
    }

    // MARK: Input

    private func countRecord() {
        recordNumber += 1
        fileRecordNumber += 1
        globals[AwkSpecial.nr].value = .number(recordNumber)
        globals[AwkSpecial.fnr].value = .number(fileRecordNumber)
    }

    /// The next main-input record if one is already buffered.
    private func takeBufferedMainRecord() -> String? {
        guard let reader = mainReader, case let .record(bytes) = reader.take(separator: recordSeparator) else {
            return nil
        }
        countRecord()
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The next record of the main input (the file operands in `ARGV` order,
    /// or standard input), with `NR` / `FNR` / `FILENAME` updated.
    private func nextMainRecord() async throws -> String? {
        while true {
            if mainReader == nil {
                guard try openNextOperand() else { return nil }
            }
            guard let reader = mainReader else { return nil }
            switch reader.take(separator: recordSeparator) {
            case let .record(bytes):
                countRecord()
                return String(decoding: bytes, as: UTF8.self)
            case .needMore:
                // About to wait for input: let what has been printed out first.
                if pendingBytes > 0 || flushRequested { try await flushAll() }
                await reader.refill()
            case .end:
                closeMainReader()
            }
        }
    }

    private func closeMainReader() {
        if let input = mainInput, input.status != 0 { inputFailed = true }
        mainReader = nil
        mainInput = nil
    }

    private func openNextOperand() throws -> Bool {
        let argv = globals[AwkSpecial.argv].array
        while Double(argumentIndex) < number(globals[AwkSpecial.argc].value) {
            let operand = string(argv?.items[String(argumentIndex)] ?? .uninitialized)
            argumentIndex += 1
            if operand.isEmpty { continue }
            if try assignCommandLine(operand) { continue }
            sawFileOperand = true
            startMainReader(operand)
            return true
        }
        guard !sawFileOperand, !usedStandardInput else { return false }
        startMainReader("-")
        return true
    }

    private func startMainReader(_ operand: String) {
        if operand == "-" { usedStandardInput = true }
        let input = CommandInput(ctx, command: "awk", files: [operand])
        mainInput = input
        mainReader = AwkRecordReader(ctx, source: .input(input))
        fileRecordNumber = 0
        globals[AwkSpecial.fnr].value = .number(0)
        globals[AwkSpecial.filename].value = .string(operand == "-" ? "" : operand)
    }

    // MARK: Record and fields

    private func setRecord(_ text: String) {
        record = text
        recordCharacters = nil
        fieldsValid = false
    }

    private func ensureFields() {
        guard !fieldsValid else { return }
        fieldsValid = true
        let splitter: Splitter
        if let cached = fieldSplitter {
            splitter = cached
        } else {
            // An invalid FS regex falls back to whitespace; the assignment
            // already reported it.
            splitter = (try? self.splitter(for: fieldSeparator)) ?? .whitespace
            fieldSplitter = splitter
        }
        if recordSeparator.isEmpty, case .whitespace = splitter {
            fields = split(record, splitter)
        } else if recordSeparator.isEmpty {
            // Paragraph mode: a newline separates fields as well as FS.
            fields = record.split(separator: "\n", omittingEmptySubsequences: false)
                .flatMap { split(String($0), splitter) }
        } else {
            fields = split(record, splitter)
        }
    }

    private func rebuildRecord() {
        record = fields.joined(separator: outputFieldSeparator)
        recordCharacters = nil
    }

    private func field(_ index: Int) -> AwkValue {
        if index == 0 { return .numericString(record) }
        ensureFields()
        return index <= fields.count ? .numericString(fields[index - 1]) : .uninitialized
    }

    private func setField(_ index: Int, _ text: String) throws {
        if index == 0 {
            setRecord(text)
            return
        }
        guard index <= 1_000_000 else { throw failure("field index \(index) is too large") }
        ensureFields()
        while fields.count < index { fields.append("") }
        fields[index - 1] = text
        rebuildRecord()
    }

    private func setFieldCount(_ count: Int) throws {
        guard count >= 0, count <= 1_000_000 else { throw failure("NF set to an invalid value \(count)") }
        ensureFields()
        if count < fields.count {
            fields.removeLast(fields.count - count)
        } else {
            while fields.count < count { fields.append("") }
        }
        rebuildRecord()
    }

    private func fieldIndex(_ value: AwkValue) throws -> Int {
        let index = number(value)
        guard index >= 0, index < 1e9 else { throw failure("attempt to access field \(string(value))") }
        return Int(index)
    }

    private func characters() -> [Character] {
        if let cached = recordCharacters { return cached }
        let made = Array(record)
        recordCharacters = made
        return made
    }

    // MARK: Splitting

    private enum Splitter {
        case whitespace
        case character(Character)
        case characters
        case regex(Regex)
    }

    private func splitter(for separator: String) throws -> Splitter {
        if separator == " " { return .whitespace }
        if separator.isEmpty { return .characters }
        if separator.count == 1, let only = separator.first, only != "\\" { return .character(only) }
        return .regex(try regex(separator))
    }

    private func split(_ text: String, _ splitter: Splitter) -> [String] {
        if text.isEmpty { return [] }
        switch splitter {
        case .whitespace:
            return text.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A })
                .map { String(Substring($0)) }
        case let .character(separator):
            return text.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        case .characters:
            return text.map { String($0) }
        case let .regex(regex):
            let source = Array(text)
            var parts: [String] = []
            var start = 0
            var position = 0
            while position <= source.count, let match = regex.match(in: source, from: position) {
                if match.range.isEmpty {
                    position = match.range.lowerBound + 1
                    continue
                }
                parts.append(String(source[start..<match.range.lowerBound]))
                start = match.range.upperBound
                position = start
            }
            parts.append(String(source[start...]))
            return parts
        }
    }

    // MARK: Conversions

    /// The numeric value of a whole string that looks like a number (leading
    /// and trailing blanks allowed), or `nil`.
    private func looksNumeric(_ text: String) -> Double? {
        guard let parsed = NumberFormat.parseDouble(text[...]) else { return nil }
        if parsed.length == text.utf8.count { return parsed.value }
        let rest = text.utf8.dropFirst(parsed.length)
        return rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A }) ? parsed.value : nil
    }

    private func number(_ value: AwkValue) -> Double {
        switch value {
        case .uninitialized: return 0
        case let .number(number): return number
        case let .string(text), let .numericString(text):
            return NumberFormat.parseDouble(text[...])?.value ?? 0
        }
    }

    private func numberText(_ value: Double, _ format: String) -> String {
        // Integral values print as integers (anything that fits an Int64).
        if value == value.rounded(.towardZero), value.magnitude < 9.2e18 { return String(Int64(value)) }
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        if format == "%.6g" { return NumberFormat.format(value, conversion: "g", precision: 6) }
        return self.format(format, [.number(value)])
    }

    private func string(_ value: AwkValue) -> String {
        switch value {
        case .uninitialized: return ""
        case let .number(number): return numberText(number, conversionFormat)
        case let .string(text), let .numericString(text): return text
        }
    }

    /// The text `print` writes for a value (numbers go through `OFMT`).
    private func outputText(_ value: AwkValue) -> String {
        if case let .number(number) = value { return numberText(number, outputFormat) }
        return string(value)
    }

    private func truth(_ value: AwkValue) -> Bool {
        switch value {
        case .uninitialized: return false
        case let .number(number): return number != 0
        case let .string(text): return !text.isEmpty
        case let .numericString(text):
            if let number = looksNumeric(text) { return number != 0 }
            return !text.isEmpty
        }
    }

    private func comparableNumber(_ value: AwkValue) -> Double? {
        switch value {
        case .uninitialized: return 0
        case let .number(number): return number
        case .string: return nil
        case let .numericString(text): return looksNumeric(text)
        }
    }

    private func compare(_ operation: AwkComparison, _ left: AwkValue, _ right: AwkValue) -> Bool {
        if let a = comparableNumber(left), let b = comparableNumber(right) {
            switch operation {
            case .less: return a < b
            case .lessEqual: return a <= b
            case .equal: return a == b
            case .notEqual: return a != b
            case .greater: return a > b
            case .greaterEqual: return a >= b
            }
        }
        let a = string(left), b = string(right)
        switch operation {
        case .less: return a < b
        case .lessEqual: return a <= b
        case .equal: return a == b
        case .notEqual: return a != b
        case .greater: return a > b
        case .greaterEqual: return a >= b
        }
    }

    private func arithmetic(_ operation: AwkArithmetic, _ a: Double, _ b: Double) throws -> Double {
        switch operation {
        case .add: return a + b
        case .subtract: return a - b
        case .multiply: return a * b
        case .divide:
            guard b != 0 else { throw failure("division by zero") }
            return a / b
        case .modulo:
            guard b != 0 else { throw failure("division by zero in %") }
            return a.truncatingRemainder(dividingBy: b)
        case .power:
            return AwkMath.pow(a, b)
        }
    }

    private func regex(_ pattern: String) throws -> Regex {
        if let cached = regexCache[pattern] { return cached }
        guard let compiled = Regex(pattern: pattern) else {
            throw failure("invalid regular expression /\(pattern)/")
        }
        if regexCache.count > 500 { regexCache.removeAll() }
        regexCache[pattern] = compiled
        return compiled
    }

    // MARK: Variables

    private func slot(_ reference: AwkVarRef) -> AwkVariable {
        switch reference {
        case let .global(slot): return globals[slot]
        case let .local(slot): return locals[slot]
        }
    }

    private func name(_ reference: AwkVarRef) -> String {
        switch reference {
        case let .global(slot): return program.globalNames[slot]
        case .local: return "parameter"
        }
    }

    private func readVariable(_ reference: AwkVarRef) throws -> AwkValue {
        if case let .global(slot) = reference, slot == AwkSpecial.nf {
            ensureFields()
            return .number(Double(fields.count))
        }
        let variable = slot(reference)
        guard variable.array == nil else {
            throw failure("can't use array \(name(reference)) in a scalar context")
        }
        return variable.value
    }

    private func writeVariable(_ reference: AwkVarRef, _ value: AwkValue) throws {
        let variable = slot(reference)
        guard variable.array == nil else {
            throw failure("can't assign to \(name(reference)); it's an array name")
        }
        variable.value = value
        variable.alias = nil
        guard case let .global(slot) = reference, slot < AwkSpecial.count else { return }
        switch slot {
        case AwkSpecial.nf:
            try setFieldCount(Int(Swift.max(-1, Swift.min(number(value), 1e9))))
        case AwkSpecial.nr:
            recordNumber = number(value)
        case AwkSpecial.fnr:
            fileRecordNumber = number(value)
        case AwkSpecial.fs:
            fieldSeparator = string(value)
            fieldSplitter = nil
            _ = try splitter(for: fieldSeparator)
        case AwkSpecial.ofs:
            outputFieldSeparator = string(value)
        case AwkSpecial.ors:
            outputRecordSeparator = string(value)
        case AwkSpecial.rs:
            recordSeparator = string(value)
        case AwkSpecial.subsep:
            subscriptSeparator = string(value)
        case AwkSpecial.convfmt:
            conversionFormat = string(value)
        case AwkSpecial.ofmt:
            outputFormat = string(value)
        default:
            break
        }
    }

    private func arrayStorage(_ reference: AwkVarRef) throws -> AwkArray {
        do {
            return try arrayStorage(of: slot(reference))
        } catch {
            throw failure("can't use scalar \(name(reference)) as an array")
        }
    }

    private func arrayStorage(of variable: AwkVariable) throws -> AwkArray {
        if let existing = variable.array { return existing }
        guard case .uninitialized = variable.value else { throw AwkRuntimeError.failure("scalar") }
        let made = try variable.alias.map { try arrayStorage(of: $0) } ?? AwkArray()
        variable.array = made
        variable.alias = nil
        return made
    }

    private func key(_ parts: [AwkValue]) -> String {
        if parts.count == 1 { return string(parts[0]) }
        return parts.map(string).joined(separator: subscriptSeparator)
    }

    private func subscriptKey(_ subscripts: [AwkExpr]) throws -> String {
        if subscripts.count == 1 { return string(try value(subscripts[0])) }
        return key(try subscripts.map { try value($0) })
    }

    /// Array keys in a stable order: integers ascending, then other strings.
    private func sortedKeys(_ array: AwkArray) -> [String] {
        let keyed = array.items.keys.map { (key: $0, number: Int($0)) }
        return keyed.sorted { a, b in
            switch (a.number, b.number) {
            case let (x?, y?): return x != y ? x < y : a.key < b.key
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.key < b.key
            }
        }.map(\.key)
    }

    // MARK: Assignable locations

    private enum Location {
        case variable(AwkVarRef)
        case element(AwkArray, String)
        case field(Int)
    }

    private func location(_ expression: AwkExpr) throws -> Location {
        switch expression {
        case let .variable(reference):
            return .variable(reference)
        case let .element(reference, subscripts):
            let key = try subscriptKey(subscripts)
            return .element(try arrayStorage(reference), key)
        case let .field(index):
            return .field(try fieldIndex(try value(index)))
        default:
            throw failure("assignment to something that is not a variable")
        }
    }

    /// `location(_:)` for a target whose subscripts may have to be awaited.
    private func locate(_ expression: AwkExpr) async throws -> Location {
        switch expression {
        case let .element(reference, subscripts):
            var parts: [AwkValue] = []
            for part in subscripts { parts.append(try await evaluate(part)) }
            return .element(try arrayStorage(reference), key(parts))
        case let .field(index):
            return .field(try fieldIndex(try await evaluate(index)))
        default:
            return try location(expression)
        }
    }

    private func load(_ location: Location) throws -> AwkValue {
        switch location {
        case let .variable(reference): return try readVariable(reference)
        case let .element(array, key): return array.items[key] ?? .uninitialized
        case let .field(index): return field(index)
        }
    }

    private func store(_ location: Location, _ value: AwkValue) throws {
        switch location {
        case let .variable(reference): try writeVariable(reference, value)
        case let .element(array, key): array.items[key] = value
        case let .field(index): try setField(index, string(value))
        }
    }

    // MARK: Checkpoints

    /// Counts one unit of work and reports whether `checkpoint()` has
    /// something to do. Kept synchronous so the common "nothing due" case
    /// costs no suspension.
    private var checkpointDue: Bool {
        steps &+= 1
        return pendingBytes >= Self.flushThreshold || flushRequested || steps & 0xFFFF == 0
    }

    private func checkpoint() async throws {
        if pendingBytes >= Self.flushThreshold || flushRequested { try await flushAll() }
        guard steps & 0xFFFF == 0 else { return }
        // Let the event loop deliver signals and run other processes; an
        // interrupted wait means this process was told to stop.
        do {
            try await ctx.yield()
        } catch {
            throw AwkRuntimeError.stopped
        }
    }

    // MARK: Statements

    private func printText(_ values: [AwkValue]) -> String {
        guard !values.isEmpty else { return record + outputRecordSeparator }
        return values.map(outputText).joined(separator: outputFieldSeparator) + outputRecordSeparator
    }

    private func setExitCode(_ value: AwkValue) {
        exitCode = Int32(Int(Swift.max(-1e9, Swift.min(number(value), 1e9))) & 0xFF)
    }

    /// Execute a statement the parser marked simple: no loop, nothing that
    /// can suspend.
    private func run(_ statement: AwkStmt) throws -> AwkFlow {
        switch statement {
        case let .simple(inner):
            return try run(inner)
        case let .expression(expression):
            _ = try value(expression)
            return .normal
        case let .print(arguments, redirect):
            let text = printText(try arguments.map { try value($0) })
            try send(text, try redirect.map { (string(try value($0.target)), $0.append, $0.pipe) })
            return .normal
        case let .printf(arguments, redirect):
            let values = try arguments.map { try value($0) }
            try send(format(string(values[0]), Array(values.dropFirst())),
                     try redirect.map { (string(try value($0.target)), $0.append, $0.pipe) })
            return .normal
        case let .block(statements):
            for statement in statements {
                let flow = try run(statement)
                if flow != .normal { return flow }
            }
            return .normal
        case let .ifElse(condition, thenBranch, elseBranch):
            if truth(try value(condition)) { return try run(thenBranch) }
            if let elseBranch { return try run(elseBranch) }
            return .normal
        case .whileLoop, .doWhile, .forLoop, .forIn:
            throw failure("internal error: loop in a simple statement")
        case .next: return .next
        case .nextFile: return .nextFile
        case .breakLoop: return .breakLoop
        case .continueLoop: return .continueLoop
        case let .exit(code):
            if let code { setExitCode(try value(code)) }
            return .exit
        case let .returnValue(expression):
            returnValue = try expression.map { try value($0) } ?? .uninitialized
            return .returned
        case let .delete(reference, subscripts):
            let array = try arrayStorage(reference)
            if let subscripts {
                array.items[try subscriptKey(subscripts)] = nil
            } else {
                array.items.removeAll()
            }
            return .normal
        }
    }

    private func execute(_ statements: [AwkStmt]) async throws -> AwkFlow {
        for statement in statements {
            let flow: AwkFlow
            if case let .simple(inner) = statement {
                flow = try run(inner)
            } else {
                flow = try await execute(statement)
            }
            if flow != .normal { return flow }
        }
        return .normal
    }

    /// After one pass of a loop body: `nil` to keep looping, or the flow that
    /// ends the loop (`.normal` for `break`).
    private func endOfLoop(after flow: AwkFlow) -> AwkFlow? {
        if flow == .breakLoop { return .normal }
        if flow != .normal && flow != .continueLoop { return flow }
        return nil
    }

    private func destination(_ redirect: AwkRedirect?) async throws -> (name: String, append: Bool, pipe: Bool)? {
        guard let redirect else { return nil }
        return (string(try await evaluate(redirect.target)), redirect.append, redirect.pipe)
    }

    private func execute(_ statement: AwkStmt) async throws -> AwkFlow {
        switch statement {
        case let .simple(inner):
            return try run(inner)

        case let .expression(expression):
            _ = try await evaluate(expression)
            return .normal

        case let .print(arguments, redirect):
            var values: [AwkValue] = []
            for argument in arguments { values.append(try await evaluate(argument)) }
            try send(printText(values), try await destination(redirect))
            return .normal

        case let .printf(arguments, redirect):
            var values: [AwkValue] = []
            for argument in arguments { values.append(try await evaluate(argument)) }
            try send(format(string(values[0]), Array(values.dropFirst())), try await destination(redirect))
            return .normal

        case let .block(statements):
            return try await execute(statements)

        case let .ifElse(condition, thenBranch, elseBranch):
            if truth(try await evaluate(condition)) { return try await execute(thenBranch) }
            if let elseBranch { return try await execute(elseBranch) }
            return .normal

        case let .whileLoop(condition, body):
            while true {
                if checkpointDue { try await checkpoint() }
                let proceed: Bool
                if case let .pure(inner) = condition {
                    proceed = truth(try value(inner))
                } else {
                    proceed = truth(try await evaluate(condition))
                }
                guard proceed else { return .normal }
                let flow: AwkFlow
                if case let .simple(inner) = body {
                    flow = try run(inner)
                } else {
                    flow = try await execute(body)
                }
                if let end = endOfLoop(after: flow) { return end }
            }

        case let .doWhile(body, condition):
            while true {
                if checkpointDue { try await checkpoint() }
                let flow: AwkFlow
                if case let .simple(inner) = body {
                    flow = try run(inner)
                } else {
                    flow = try await execute(body)
                }
                if let end = endOfLoop(after: flow) { return end }
                let proceed: Bool
                if case let .pure(inner) = condition {
                    proceed = truth(try value(inner))
                } else {
                    proceed = truth(try await evaluate(condition))
                }
                guard proceed else { return .normal }
            }

        case let .forLoop(initial, condition, update, body):
            if let initial { _ = try await execute(initial) }
            while true {
                if checkpointDue { try await checkpoint() }
                if let condition {
                    let proceed: Bool
                    if case let .pure(inner) = condition {
                        proceed = truth(try value(inner))
                    } else {
                        proceed = truth(try await evaluate(condition))
                    }
                    guard proceed else { return .normal }
                }
                let flow: AwkFlow
                if case let .simple(inner) = body {
                    flow = try run(inner)
                } else {
                    flow = try await execute(body)
                }
                if let end = endOfLoop(after: flow) { return end }
                if let update {
                    if case let .simple(inner) = update {
                        _ = try run(inner)
                    } else {
                        _ = try await execute(update)
                    }
                }
            }

        case let .forIn(target, reference, body):
            let array = try arrayStorage(reference)
            for key in sortedKeys(array) where array.items[key] != nil {
                if checkpointDue { try await checkpoint() }
                try store(try location(target), .string(key))
                let flow: AwkFlow
                if case let .simple(inner) = body {
                    flow = try run(inner)
                } else {
                    flow = try await execute(body)
                }
                if let end = endOfLoop(after: flow) { return end }
            }
            return .normal

        case .next: return .next
        case .nextFile: return .nextFile
        case .breakLoop: return .breakLoop
        case .continueLoop: return .continueLoop

        case let .exit(code):
            if let code { setExitCode(try await evaluate(code)) }
            return .exit

        case let .returnValue(expression):
            if let expression {
                returnValue = try await evaluate(expression)
            } else {
                returnValue = .uninitialized
            }
            return .returned

        case let .delete(reference, subscripts):
            let array = try arrayStorage(reference)
            if let subscripts {
                var parts: [AwkValue] = []
                for part in subscripts { parts.append(try await evaluate(part)) }
                array.items[key(parts)] = nil
            } else {
                array.items.removeAll()
            }
            return .normal
        }
    }

    // MARK: Expressions

    /// Evaluate an expression that cannot suspend.
    private func value(_ expression: AwkExpr) throws -> AwkValue {
        switch expression {
        case let .pure(inner):
            return try value(inner)
        case let .value(value):
            return value
        case let .number(value):
            return .number(value)
        case let .string(text):
            return .string(text)
        case let .regex(pattern):
            return .number(try regex(pattern).match(in: characters(), from: 0) != nil ? 1 : 0)
        case let .variable(reference):
            return try readVariable(reference)
        case let .field(index):
            return field(try fieldIndex(try value(index)))
        case let .element(reference, subscripts):
            let key = try subscriptKey(subscripts)
            let array = try arrayStorage(reference)
            if let value = array.items[key] { return value }
            array.items[key] = .uninitialized
            return .uninitialized
        case let .assign(target, source):
            let assigned = try value(source)
            try store(try location(target), assigned)
            return assigned
        case let .compoundAssign(operation, target, source):
            let place = try location(target)
            let operand = number(try value(source))
            let result = try arithmetic(operation, number(try load(place)), operand)
            try store(place, .number(result))
            return .number(result)
        case let .conditional(condition, whenTrue, whenFalse):
            return try value(truth(try value(condition)) ? whenTrue : whenFalse)
        case let .and(left, right):
            guard truth(try value(left)) else { return .number(0) }
            return .number(truth(try value(right)) ? 1 : 0)
        case let .or(left, right):
            if truth(try value(left)) { return .number(1) }
            return .number(truth(try value(right)) ? 1 : 0)
        case let .not(operand):
            return .number(truth(try value(operand)) ? 0 : 1)
        case let .negate(operand):
            return .number(-number(try value(operand)))
        case let .numeric(operand):
            return .number(number(try value(operand)))
        case let .arithmetic(operation, left, right):
            let a = number(try value(left))
            let b = number(try value(right))
            return .number(try arithmetic(operation, a, b))
        case let .compare(operation, left, right):
            let a = try value(left)
            let b = try value(right)
            return .number(compare(operation, a, b) ? 1 : 0)
        case let .concat(parts):
            var text = ""
            for part in parts { text += string(try value(part)) }
            return .string(text)
        case let .match(negated, subject, pattern):
            let text = string(try value(subject))
            let compiled: Regex
            if case let .regex(literal) = pattern {
                compiled = try regex(literal)
            } else {
                compiled = try regex(string(try value(pattern)))
            }
            return .number(compiled.matches(text) != negated ? 1 : 0)
        case let .membership(subscripts, reference):
            let key = try subscriptKey(subscripts)
            return .number(try arrayStorage(reference).items[key] != nil ? 1 : 0)
        case let .increment(target, delta, prefix):
            let place = try location(target)
            let old = number(try load(place))
            try store(place, .number(old + delta))
            return .number(prefix ? old + delta : old)
        case let .builtin(builtin, arguments):
            var values: [AwkValue?] = []
            values.reserveCapacity(arguments.count)
            for (index, argument) in arguments.enumerated() {
                values.append(builtin.usesStructure(at: index, argument) ? nil : try value(argument))
            }
            var target: Location? = nil
            if arguments.count == 3, builtin.usesStructure(at: 2, arguments[2]), arguments[2].isLvalue {
                target = try location(arguments[2])
            }
            return try apply(builtin, arguments, values, target)
        case .group:
            throw failure("a parenthesized list is only valid in print or before 'in'")
        case .call, .getline:
            throw failure("internal error: suspending expression in a pure context")
        }
    }

    /// Evaluate an expression that may suspend (it contains a function call
    /// or a `getline`). Pure operands go straight back to `value(_:)`.
    private func evaluate(_ expression: AwkExpr) async throws -> AwkValue {
        switch expression {
        case let .pure(inner):
            return try value(inner)
        case let .call(index, arguments):
            return try await call(index, arguments)
        case let .getline(target, file, command):
            return try await getline(target, file, command)
        case let .builtin(.system, arguments):
            guard arguments.count == 1 else { throw failure("system: expected 1 argument") }
            return try await system(string(try await evaluate(arguments[0])))
        case let .builtin(.close, arguments):
            guard arguments.count == 1 else { throw failure("close: expected 1 argument") }
            return try await close(string(try await evaluate(arguments[0])))
        case let .assign(target, source):
            let assigned = try await evaluate(source)
            if case .variable = target {
                try store(try location(target), assigned)
            } else {
                try store(try await locate(target), assigned)
            }
            return assigned
        case let .compoundAssign(operation, target, source):
            let location: Location
            if case let .variable(reference) = target {
                location = .variable(reference)
            } else {
                location = try await locate(target)
            }
            let operand = number(try await evaluate(source))
            let result = try arithmetic(operation, number(try load(location)), operand)
            try store(location, .number(result))
            return .number(result)
        case let .increment(target, delta, prefix):
            let location = try await locate(target)
            let old = number(try load(location))
            try store(location, .number(old + delta))
            return .number(prefix ? old + delta : old)
        case let .conditional(condition, whenTrue, whenFalse):
            return try await evaluate(truth(try await evaluate(condition)) ? whenTrue : whenFalse)
        case let .and(left, right):
            guard truth(try await evaluate(left)) else { return .number(0) }
            return .number(truth(try await evaluate(right)) ? 1 : 0)
        case let .or(left, right):
            if truth(try await evaluate(left)) { return .number(1) }
            return .number(truth(try await evaluate(right)) ? 1 : 0)
        case let .match(negated, subject, pattern):
            let text = string(try await evaluate(subject))
            let compiled: Regex
            if case let .regex(literal) = pattern {
                compiled = try regex(literal)
            } else {
                compiled = try regex(string(try await evaluate(pattern)))
            }
            return .number(compiled.matches(text) != negated ? 1 : 0)
        case let .builtin(builtin, arguments):
            var values: [AwkValue?] = []
            for (index, argument) in arguments.enumerated() {
                if builtin.usesStructure(at: index, argument) {
                    values.append(nil)
                } else {
                    values.append(try await evaluate(argument))
                }
            }
            var target: Location? = nil
            if arguments.count == 3, builtin.usesStructure(at: 2, arguments[2]), arguments[2].isLvalue {
                target = try await locate(arguments[2])
            }
            return try apply(builtin, arguments, values, target)
        default:
            // A strict operator: compute the operands in order (awaiting the
            // ones that need it), then apply the operator synchronously.
            var operands: [AwkExpr] = []
            _ = expression.mapChildren { operand in
                operands.append(operand)
                return operand
            }
            var computed: [AwkExpr] = []
            computed.reserveCapacity(operands.count)
            for operand in operands {
                if case let .pure(inner) = operand {
                    computed.append(.value(try value(inner)))
                } else {
                    computed.append(.value(try await evaluate(operand)))
                }
            }
            var next = 0
            return try value(expression.mapChildren { _ in
                next += 1
                return computed[next - 1]
            })
        }
    }

    private func call(_ index: Int, _ arguments: [AwkExpr]) async throws -> AwkValue {
        let function = program.functions[index]
        guard arguments.count <= function.parameterCount else {
            throw failure("function \(function.name) called with \(arguments.count) arguments, accepts only \(function.parameterCount)")
        }
        guard callDepth < 2000 else { throw failure("function call nesting too deep in \(function.name)") }
        if checkpointDue { try await checkpoint() }
        var frame: [AwkVariable] = []
        frame.reserveCapacity(function.parameterCount)
        for position in 0..<function.parameterCount {
            let parameter = AwkVariable()
            if position < arguments.count {
                let argument = arguments[position]
                if case let .variable(reference) = argument {
                    let source = slot(reference)
                    var isSpecial = false
                    if case let .global(global) = reference { isSpecial = global < AwkSpecial.count }
                    if let array = source.array {
                        parameter.array = array
                    } else if case .uninitialized = source.value, !isSpecial {
                        // Untyped so far: the callee may still make it an array.
                        parameter.alias = source
                    } else {
                        parameter.value = try readVariable(reference)
                    }
                } else if case let .pure(inner) = argument {
                    parameter.value = try value(inner)
                } else {
                    parameter.value = try await evaluate(argument)
                }
            }
            frame.append(parameter)
        }
        let savedLocals = locals
        locals = frame
        callDepth += 1
        defer {
            locals = savedLocals
            callDepth -= 1
        }
        returnValue = .uninitialized
        let flow = try await execute(function.body)
        if flow == .next || flow == .nextFile || flow == .exit { throw AwkUnwind(flow: flow) }
        let result = returnValue
        returnValue = .uninitialized
        return result
    }

    private func getline(_ target: AwkExpr?, _ file: AwkExpr?, _ command: AwkExpr?) async throws -> AwkValue {
        var text: String? = nil
        if let source = file ?? command {
            let name = string(try await evaluate(source))
            var reader = readers[name]
            if reader == nil {
                if command != nil {
                    // Let what has been printed out before the command runs.
                    try await flushAll()
                    let pipe = ctx.pipe()
                    guard let child = spawnShell(name, stdout: pipe.write, closing: [pipe.read, pipe.write]) else {
                        ctx.close(pipe.read)
                        ctx.close(pipe.write)
                        return .number(-1)
                    }
                    ctx.close(pipe.write)
                    readerChildren[name] = child
                    reader = AwkRecordReader(ctx, source: .descriptor(pipe.read, owned: true))
                } else if name == "-" {
                    reader = AwkRecordReader(ctx, source: .descriptor(0, owned: false))
                } else if let fd = try? ctx.openFile(name) {
                    reader = AwkRecordReader(ctx, source: .descriptor(fd, owned: true))
                } else {
                    return .number(-1)
                }
                readers[name] = reader
            }
            guard let reader else { return .number(-1) }
            scan: while true {
                switch reader.take(separator: recordSeparator) {
                case let .record(bytes):
                    text = String(decoding: bytes, as: UTF8.self)
                    break scan
                case .needMore:
                    if pendingBytes > 0 || flushRequested { try await flushAll() }
                    await reader.refill()
                case .end:
                    break scan
                }
            }
        } else {
            text = takeBufferedMainRecord()
            if text == nil { text = try await nextMainRecord() }
        }
        guard let text else { return .number(0) }
        if let target {
            try store(try await locate(target), .numericString(text))
        } else {
            setRecord(text)
        }
        return .number(1)
    }

    // MARK: Builtin functions

    /// Apply a builtin to its operands. `values[i]` is the evaluated argument,
    /// or `nil` where the builtin uses the argument's structure instead (see
    /// `AwkBuiltin.usesStructure`); `target` is the located third argument of
    /// `sub` / `gsub` when that is assignable.
    private func apply(_ builtin: AwkBuiltin,
                       _ arguments: [AwkExpr],
                       _ values: [AwkValue?],
                       _ target: Location?) throws -> AwkValue {
        func require(_ range: ClosedRange<Int>) throws {
            guard range.contains(arguments.count) else {
                throw failure("wrong number of arguments to \(builtin.rawValue)")
            }
        }
        func numberArgument(_ index: Int) -> Double { number(values[index] ?? .uninitialized) }
        func stringArgument(_ index: Int) -> String { string(values[index] ?? .uninitialized) }
        func regexArgument(_ index: Int) throws -> Regex {
            if case let .regex(pattern) = arguments[index] { return try regex(pattern) }
            return try regex(stringArgument(index))
        }
        switch builtin {
        case .length:
            try require(0...1)
            guard let argument = arguments.first else { return .number(Double(characters().count)) }
            if case let .variable(reference) = argument {
                var candidate: AwkVariable? = slot(reference)
                while let current = candidate {
                    if let array = current.array { return .number(Double(array.items.count)) }
                    candidate = current.alias
                }
                return .number(Double(string(try readVariable(reference)).count))
            }
            return .number(Double(stringArgument(0).count))

        case .substr:
            try require(2...3)
            let source = Array(stringArgument(0))
            let start = numberArgument(1).rounded(.toNearestOrEven)
            var end = Double(source.count + 1)
            if arguments.count == 3 {
                end = Swift.min(end, start + numberArgument(2).rounded(.toNearestOrEven))
            }
            let begin = Swift.max(start, 1)
            guard begin < end else { return .string("") }      // also false for NaN
            return .string(String(source[(Int(begin) - 1)..<(Int(end) - 1)]))

        case .index:
            try require(2...2)
            let haystack = Array(stringArgument(0))
            let needle = Array(stringArgument(1))
            guard !needle.isEmpty, needle.count <= haystack.count else { return .number(0) }
            for offset in 0...(haystack.count - needle.count)
            where haystack[offset] == needle[0] && haystack[offset..<offset + needle.count].elementsEqual(needle) {
                return .number(Double(offset + 1))
            }
            return .number(0)

        case .split:
            try require(2...3)
            guard case let .variable(reference) = arguments[1] else {
                throw failure("split: second argument must be an array")
            }
            let splitter: Splitter
            if arguments.count == 3 {
                if case let .regex(pattern) = arguments[2] {
                    splitter = .regex(try regex(pattern))
                } else {
                    splitter = try self.splitter(for: stringArgument(2))
                }
            } else {
                splitter = try self.splitter(for: fieldSeparator)
            }
            let parts = split(stringArgument(0), splitter)
            let array = try arrayStorage(reference)
            array.items.removeAll()
            for (offset, part) in parts.enumerated() {
                array.items[String(offset + 1)] = .numericString(part)
            }
            return .number(Double(parts.count))

        case .sub, .gsub:
            try require(2...3)
            let location = arguments.count == 3 ? target : Location.field(0)
            let source: String
            if let location {
                source = string(try load(location))
            } else {
                source = stringArgument(2)
            }
            let (count, result) = substitute(try regexArgument(0), Array(stringArgument(1)), Array(source),
                                             global: builtin == .gsub)
            if count > 0, let location { try store(location, .string(result)) }
            return .number(Double(count))

        case .match:
            try require(2...2)
            let source = Array(stringArgument(0))
            var start = 0.0, length = -1.0
            if let match = try regexArgument(1).match(in: source, from: 0) {
                start = Double(match.range.lowerBound + 1)
                length = Double(match.range.count)
            }
            globals[AwkSpecial.rstart].value = .number(start)
            globals[AwkSpecial.rlength].value = .number(length)
            return .number(start)

        case .sprintf:
            guard !arguments.isEmpty else { throw failure("sprintf: no format") }
            return .string(format(stringArgument(0), values.dropFirst().map { $0 ?? .uninitialized }))

        case .tolower:
            try require(1...1)
            return .string(stringArgument(0).lowercased())
        case .toupper:
            try require(1...1)
            return .string(stringArgument(0).uppercased())
        case .int:
            try require(1...1)
            return .number(numberArgument(0).rounded(.towardZero))
        case .sqrt:
            try require(1...1)
            let operand = numberArgument(0)
            return .number(operand < 0 ? .nan : operand.squareRoot())
        case .exp:
            try require(1...1)
            return .number(AwkMath.exp(numberArgument(0)))
        case .log:
            try require(1...1)
            return .number(AwkMath.log(numberArgument(0)))
        case .sin:
            try require(1...1)
            return .number(AwkMath.sin(numberArgument(0)))
        case .cos:
            try require(1...1)
            return .number(AwkMath.cos(numberArgument(0)))
        case .atan2:
            try require(2...2)
            return .number(AwkMath.atan2(numberArgument(0), numberArgument(1)))
        case .rand:
            try require(0...0)
            return .number(nextRandom())
        case .srand:
            try require(0...1)
            let previous = randomSeed
            // With no argument POSIX seeds from the time of day; the only
            // clock here is the kernel's logical one.
            seedRandom(arguments.isEmpty ? ctx.kernel.loop.now : numberArgument(0))
            return .number(previous)

        case .system:
            throw failure("internal error: system() in a pure context")

        case .close:
            try require(1...1)
            let name = stringArgument(0)
            var found = closeStream(name)
            if let reader = readers.removeValue(forKey: name) {
                reader.close()
                found = true
            }
            return .number(found ? 0 : -1)

        case .fflush:
            try require(0...1)
            flushRequested = true
            return .number(0)
        }
    }

    /// The `sub` / `gsub` engine: returns the number of replacements and the
    /// rewritten text. In the replacement `&` is the matched text, `\&` a
    /// literal ampersand and `\\` a backslash.
    private func substitute(_ regex: Regex, _ replacement: [Character], _ source: [Character],
                            global: Bool) -> (count: Int, text: String) {
        var out: [Character] = []
        func appendReplacement(_ matched: ArraySlice<Character>) {
            var index = 0
            while index < replacement.count {
                let c = replacement[index]
                if c == "\\", index + 1 < replacement.count,
                   replacement[index + 1] == "&" || replacement[index + 1] == "\\" {
                    out.append(replacement[index + 1])
                    index += 2
                } else if c == "&" {
                    out.append(contentsOf: matched)
                    index += 1
                } else {
                    out.append(c)
                    index += 1
                }
            }
        }
        var count = 0
        var position = 0
        var previousEnd = -1
        while position <= source.count, let match = regex.match(in: source, from: position) {
            let range = match.range
            out.append(contentsOf: source[position..<range.lowerBound])
            if range.isEmpty {
                // An empty match right after a real one is not replaced again.
                if range.lowerBound != previousEnd {
                    appendReplacement(source[range])
                    count += 1
                }
                if range.lowerBound < source.count { out.append(source[range.lowerBound]) }
                position = range.lowerBound + 1
            } else {
                appendReplacement(source[range])
                count += 1
                position = range.upperBound
                previousEnd = position
            }
            if !global { break }
        }
        if position < source.count { out.append(contentsOf: source[position...]) }
        return (count, String(out))
    }

    // MARK: Random numbers

    private func seedRandom(_ seed: Double) {
        randomSeed = seed
        randomState = seed.bitPattern &* 0x2545_F491_4F6C_DD1D &+ 0x1234_5678_9ABC_DEF1
    }

    /// SplitMix64, mapped to [0, 1).
    private func nextRandom() -> Double {
        randomState &+= 0x9E37_79B9_7F4A_7C15
        var z = randomState
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    // MARK: printf

    /// Expand a printf format against `arguments` (missing ones read as
    /// uninitialized).
    private func format(_ format: String, _ arguments: [AwkValue]) -> String {
        guard format.contains("%") else { return format }
        let source = Array(format)
        var out = ""
        var index = 0
        var nextArgument = 0
        func argument() -> AwkValue {
            defer { nextArgument += 1 }
            return nextArgument < arguments.count ? arguments[nextArgument] : .uninitialized
        }
        func size(_ value: Double) -> Int {
            Int(Swift.max(-1_000_000, Swift.min(value.isNaN ? 0 : value, 1_000_000)))
        }
        while index < source.count {
            let c = source[index]
            index += 1
            guard c == "%" else {
                out.append(c)
                continue
            }
            let start = index - 1
            if index < source.count, source[index] == "%" {
                out.append("%")
                index += 1
                continue
            }
            var flags: NumberFormat.Flags = []
            flagLoop: while index < source.count {
                switch source[index] {
                case "-": flags.insert(.leftAlign)
                case "0": flags.insert(.zeroPad)
                case "+": flags.insert(.plus)
                case " ": flags.insert(.space)
                case "#": flags.insert(.alternate)
                default: break flagLoop
                }
                index += 1
            }
            var width = 0
            if index < source.count, source[index] == "*" {
                index += 1
                width = size(number(argument()))
                if width < 0 {
                    flags.insert(.leftAlign)
                    width = -width
                }
            } else {
                while index < source.count, source[index].isASCII, let digit = source[index].wholeNumberValue {
                    width = Swift.min(width * 10 + digit, 1_000_000)
                    index += 1
                }
            }
            var precision: Int? = nil
            if index < source.count, source[index] == "." {
                index += 1
                var digits = 0
                if index < source.count, source[index] == "*" {
                    index += 1
                    digits = size(number(argument()))
                } else {
                    while index < source.count, source[index].isASCII, let digit = source[index].wholeNumberValue {
                        digits = Swift.min(digits * 10 + digit, 1_000_000)
                        index += 1
                    }
                }
                precision = digits < 0 ? nil : digits
            }
            guard index < source.count else {
                out += String(source[start...])
                break
            }
            let conversion = source[index]
            index += 1
            switch conversion {
            case "d", "i", "o", "x", "X", "u":
                let operand = number(argument()).rounded(.towardZero)
                if operand.isNaN || operand.magnitude >= 9.2e18 {
                    out += NumberFormat.format(operand, conversion: "f", flags: flags, width: width, precision: 0)
                } else {
                    out += NumberFormat.formatInteger(Int64(operand), conversion: conversion, flags: flags,
                                                      width: width, precision: precision)
                }
            case "e", "E", "f", "F", "g", "G":
                out += NumberFormat.format(number(argument()), conversion: conversion, flags: flags,
                                           width: width, precision: precision)
            case "c":
                let operand = argument()
                var text = ""
                if case let .number(code) = operand {
                    if code >= 0, code < 0x11_0000, let scalar = Unicode.Scalar(UInt32(code)) {
                        text = String(Character(scalar))
                    }
                } else {
                    text = String(string(operand).prefix(1))
                }
                out += NumberFormat.pad(body: text, flags: flags.subtracting(.zeroPad), width: width)
            case "s":
                var text = string(argument())
                if let precision { text = String(text.prefix(precision)) }
                out += NumberFormat.pad(body: text, flags: flags.subtracting(.zeroPad), width: width)
            default:
                out += String(source[start..<index])
            }
        }
        return out
    }
}
