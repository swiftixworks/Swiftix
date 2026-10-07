/// `sed` — the stream editor (category .text).
///
/// A script is parsed once into a flat program (blocks become conditional
/// jumps, labels become indices), then run once per input line over a pattern
/// space, with a hold space, an append queue, and one line of lookahead so `$`
/// can address the last line. Supported:
///
///   - options `-n`, `-e SCRIPT` (repeatable), `-f FILE`, `-E`/`-r`,
///     `-i[SUFFIX]` (edit files in place), `-s` (treat files separately)
///   - addresses `N`, `$`, `/re/` (and `\cREc`, `/re/I`), `first~step`, ranges
///     `A,B` with `B` a line, `$`, a regex, or `+N`, and negation with `!`
///   - commands `p d q Q s y a i c = n N D P h H g G x b t T :label { }`
///   - `s` flags `g`, `p`, `i`/`I`, and an occurrence number; any delimiter;
///     `&` and `\1`…`\9` in the replacement; an empty regex reuses the last one
///
/// Concurrency: a plain `async` program over `ProcessContext` on the single
/// loop-bound executor. Input is read line by line and output is written with
/// backpressure, so `sed` streams in a pipeline.
extension BuiltinCommands {

    static func sedCommands() -> [Command] {
        [
            Command(name: "sed", summary: "stream editor for filtering and transforming text", category: .text,
                    usage: """
                    sed [-nEs] [-i[SUFFIX]] [-e SCRIPT]... [-f FILE]... [SCRIPT] [FILE]...
                      -n          suppress automatic printing of the pattern space
                      -e SCRIPT   add SCRIPT to the commands to be executed
                      -f FILE     add the contents of FILE to the commands
                      -E, -r      use extended regular expressions
                      -i[SUFFIX]  edit files in place (keeping a backup if SUFFIX is given)
                      -s          treat files as separate rather than one stream
                    Addresses: N  $  /RE/  FIRST~STEP  ADDR1,ADDR2  ADDR1,+N  ADDR!
                    Commands:  s/RE/REPL/[gpiN]  y/SRC/DST/  p  d  q  a TEXT  i TEXT  c TEXT  =
                               n  N  D  P  h  H  g  G  x  b LABEL  t LABEL  :LABEL  { ... }
                    """, asyncRun: { ctx, argv in
                await sedCommand(ctx, Array(argv.dropFirst()))
            }),
        ]
    }

    // MARK: - Program model

    private enum SedAddress {
        case line(Int)
        case last
        case regex(Regex?)                 // nil: reuse the last regex
        case step(first: Int, step: Int)
        case offset(Int)                   // second address only: +N
    }

    private enum SedAction {
        case blockStart(end: Int)
        case blockEnd
        case print, printFirstLine, delete, deleteFirstLine, quit(code: Int32, print: Bool)
        case substitute(regex: Regex?, replacement: [SedReplacementPart], global: Bool,
                        occurrence: Int, print: Bool)
        case transliterate([Character: Character])
        case append(String), insert(String), change(String)
        case lineNumber
        case next, appendNext
        case hold, holdAppend, get, getAppend, exchange
        case label
        case branch(String), branchIfSubstituted(String), branchIfNotSubstituted(String)
    }

    private enum SedReplacementPart {
        case literal(String)
        case wholeMatch
        case group(Int)
    }

    private struct SedInstruction {
        var address1: SedAddress? = nil
        var address2: SedAddress? = nil
        var negate = false
        var action: SedAction
    }

    private struct SedError: Error { let message: String }

    // MARK: - Parser

    private struct SedParser {
        let chars: [Character]
        let syntax: Regex.Syntax
        var index = 0
        var program: [SedInstruction] = []
        var labels: [String: Int] = [:]
        private var openBlocks: [Int] = []

        init(_ script: String, syntax: Regex.Syntax) {
            self.chars = Array(script)
            self.syntax = syntax
        }

        private func peek() -> Character? { index < chars.count ? chars[index] : nil }

        private mutating func skipBlanks() {
            while let c = peek(), c == " " || c == "\t" { index += 1 }
        }

        private func fail(_ message: String) -> SedError {
            SedError(message: "-e expression #1, char \(min(index + 1, chars.count)): \(message)")
        }

        mutating func parse() throws {
            while true {
                while let c = peek(), c == " " || c == "\t" || c == "\n" || c == ";" { index += 1 }
                guard let c = peek() else { break }
                if c == "#" {
                    while let n = peek(), n != "\n" { _ = n; index += 1 }
                    continue
                }
                try parseInstruction()
            }
            guard openBlocks.isEmpty else { throw fail("unmatched `{'") }
            for instruction in program {
                switch instruction.action {
                case let .branch(name), let .branchIfSubstituted(name), let .branchIfNotSubstituted(name):
                    if !name.isEmpty, labels[name] == nil {
                        throw SedError(message: "-e expression #1, char \(chars.count): can't find label for jump to `\(name)'")
                    }
                default: break
                }
            }
        }

        private mutating func parseNumber() -> Int? {
            var digits = ""
            while let c = peek(), c.isASCII, c.isNumber { digits.append(c); index += 1 }
            return Int(digits)
        }

        /// Read text up to an unescaped `delimiter`, leaving the index after it.
        /// `\<delimiter>` yields the delimiter; `\n` yields a newline when
        /// `newlineEscape` is set; other escapes are kept for the consumer.
        private mutating func delimited(_ delimiter: Character, newlineEscape: Bool) throws -> String {
            var out = ""
            while let c = peek() {
                index += 1
                if c == delimiter { return out }
                if c == "\\", let next = peek() {
                    index += 1
                    if next == delimiter { out.append(delimiter) }
                    else if next == "n", newlineEscape { out.append("\n") }
                    else { out.append("\\"); out.append(next) }
                    continue
                }
                out.append(c)
            }
            throw fail("unterminated `\(delimiter)' expression")
        }

        private mutating func compile(_ pattern: String, ignoreCase: Bool) throws -> Regex? {
            if pattern.isEmpty { return nil }
            guard let regex = Regex(pattern: pattern, ignoreCase: ignoreCase, syntax: syntax) else {
                throw fail("invalid regular expression: \(pattern)")
            }
            return regex
        }

        private mutating func parseAddress(second: Bool) throws -> SedAddress? {
            guard let c = peek() else { return nil }
            if c == "$" { index += 1; return .last }
            if c.isASCII, c.isNumber {
                let first = parseNumber() ?? 0
                if peek() == "~" {
                    index += 1
                    return .step(first: first, step: parseNumber() ?? 0)
                }
                return .line(first)
            }
            if second, c == "+" {
                index += 1
                guard let count = parseNumber() else { throw fail("expected a number after `+'") }
                return .offset(count)
            }
            if c == "/" || c == "\\" {
                var delimiter: Character = "/"
                index += 1
                if c == "\\" {
                    guard let custom = peek() else { throw fail("unexpected end of address") }
                    delimiter = custom
                    index += 1
                }
                let pattern = try delimited(delimiter, newlineEscape: true)
                var ignoreCase = false
                while let flag = peek(), flag == "I" || flag == "M" {
                    if flag == "I" { ignoreCase = true }
                    index += 1
                }
                return .regex(try compile(pattern, ignoreCase: ignoreCase))
            }
            return nil
        }

        /// The text argument of `a`, `i`, `c`: the rest of the line (one-liner
        /// form), or the following lines when the command is written `a\`.
        private mutating func textArgument() -> String {
            skipBlanks()
            if peek() == "\\" {
                index += 1
                // `a\` + newline starts the text on the next line; `a\  text`
                // keeps the whitespace after the backslash.
                if peek() == "\n" { index += 1 }
            }
            var out = ""
            while let c = peek() {
                index += 1
                if c == "\n" { break }
                if c == "\\", let next = peek() {
                    index += 1
                    out.append(next == "n" ? "\n" : (next == "t" ? "\t" : next))
                    continue
                }
                out.append(c)
            }
            return out
        }

        private mutating func labelArgument() -> String {
            skipBlanks()
            var name = ""
            while let c = peek(), c != ";", c != "\n", c != "}" { name.append(c); index += 1 }
            while name.hasSuffix(" ") { name.removeLast() }
            return name
        }

        private mutating func parseInstruction() throws {
            var instruction = SedInstruction(action: .label)
            var consumedLine = false
            instruction.address1 = try parseAddress(second: false)
            if instruction.address1 != nil {
                skipBlanks()
                if peek() == "," {
                    index += 1
                    skipBlanks()
                    guard let second = try parseAddress(second: true) else {
                        throw fail("unexpected `,'")
                    }
                    instruction.address2 = second
                }
            }
            skipBlanks()
            while peek() == "!" { instruction.negate.toggle(); index += 1; skipBlanks() }
            guard let command = peek() else { throw fail("missing command") }
            index += 1
            switch command {
            case "{":
                openBlocks.append(program.count)
                instruction.action = .blockStart(end: 0)
            case "}":
                guard instruction.address1 == nil else { throw fail("} doesn't want any addresses") }
                guard let start = openBlocks.popLast() else { throw fail("unexpected `}'") }
                program[start].action = .blockStart(end: program.count)
                instruction.action = .blockEnd
            case "p": instruction.action = .print
            case "P": instruction.action = .printFirstLine
            case "d": instruction.action = .delete
            case "D": instruction.action = .deleteFirstLine
            case "q", "Q":
                skipBlanks()
                let code = parseNumber() ?? 0
                instruction.action = .quit(code: Int32(truncatingIfNeeded: code), print: command == "q")
            case "=": instruction.action = .lineNumber
            case "n": instruction.action = .next
            case "N": instruction.action = .appendNext
            case "h": instruction.action = .hold
            case "H": instruction.action = .holdAppend
            case "g": instruction.action = .get
            case "G": instruction.action = .getAppend
            case "x": instruction.action = .exchange
            case "a": instruction.action = .append(textArgument()); consumedLine = true
            case "i": instruction.action = .insert(textArgument()); consumedLine = true
            case "c": instruction.action = .change(textArgument()); consumedLine = true
            case ":":
                guard instruction.address1 == nil else { throw fail(": doesn't want any addresses") }
                let name = labelArgument()
                guard !name.isEmpty else { throw fail("\":\" lacks a label") }
                labels[name] = program.count
                instruction.action = .label
            case "b": instruction.action = .branch(labelArgument())
            case "t": instruction.action = .branchIfSubstituted(labelArgument())
            case "T": instruction.action = .branchIfNotSubstituted(labelArgument())
            case "s":
                guard let delimiter = peek(), delimiter != "\n", delimiter != "\\" else {
                    throw fail("unterminated `s' command")
                }
                index += 1
                let pattern: String, replacement: String
                do {
                    pattern = try delimited(delimiter, newlineEscape: true)
                    replacement = try delimitedReplacement(delimiter)
                } catch {
                    throw fail("unterminated `s' command")
                }
                var global = false, printFlag = false, ignoreCase = false
                var occurrence = 1
                flags: while let flag = peek() {
                    switch flag {
                    case "g": global = true
                    case "p": printFlag = true
                    case "i", "I": ignoreCase = true
                    case "0"..."9":
                        guard let number = parseNumber(), number > 0 else {
                            throw fail("number option to `s' command may not be zero")
                        }
                        occurrence = number
                        continue flags
                    case "m", "M": break
                    case ";", "\n", "}", " ", "\t", "#": break flags
                    default: throw fail("unknown option to `s'")
                    }
                    index += 1
                }
                instruction.action = .substitute(regex: try compile(pattern, ignoreCase: ignoreCase),
                                                 replacement: Self.parseReplacement(replacement),
                                                 global: global, occurrence: occurrence, print: printFlag)
            case "y":
                guard let delimiter = peek() else { throw fail("unterminated `y' command") }
                index += 1
                let source: [Character], destination: [Character]
                do {
                    source = Array(Self.unescape(try delimited(delimiter, newlineEscape: true)))
                    destination = Array(Self.unescape(try delimited(delimiter, newlineEscape: true)))
                } catch {
                    throw fail("unterminated `y' command")
                }
                guard source.count == destination.count else {
                    throw fail("strings for `y' command are different lengths")
                }
                instruction.action = .transliterate(Dictionary(zip(source, destination), uniquingKeysWith: { first, _ in first }))
            default:
                index -= 1
                throw fail("unknown command: `\(command)'")
            }
            program.append(instruction)
            if consumedLine { return }
            // Only separators (or a closing brace) may follow a command.
            skipBlanks()
            if let next = peek(), next != ";", next != "\n", next != "}", next != "#" {
                if case .blockStart = instruction.action { return }
                if case .blockEnd = instruction.action { return }
                throw fail("extra characters after command")
            }
        }

        /// Like `delimited`, but keeps every escape intact for `parseReplacement`
        /// (only `\<delimiter>` collapses), so `\1`, `\&`, and `\n` survive.
        private mutating func delimitedReplacement(_ delimiter: Character) throws -> String {
            var out = ""
            while let c = peek() {
                index += 1
                if c == delimiter { return out }
                if c == "\\", let next = peek() {
                    index += 1
                    if next == delimiter { out.append(delimiter) } else { out.append("\\"); out.append(next) }
                    continue
                }
                out.append(c)
            }
            throw fail("unterminated `s' command")
        }

        private static func unescape(_ text: String) -> String {
            var out = ""
            var chars = Array(text)[...]
            while let c = chars.popFirst() {
                if c == "\\", let next = chars.popFirst() {
                    out.append(next == "n" ? "\n" : (next == "t" ? "\t" : next))
                } else {
                    out.append(c)
                }
            }
            return out
        }

        private static func parseReplacement(_ text: String) -> [SedReplacementPart] {
            var parts: [SedReplacementPart] = []
            var literal = ""
            func flush() {
                if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
            }
            var chars = Array(text)[...]
            while let c = chars.popFirst() {
                if c == "&" {
                    flush()
                    parts.append(.wholeMatch)
                } else if c == "\\", let next = chars.popFirst() {
                    if let digit = next.wholeNumberValue, next.isASCII {
                        flush()
                        parts.append(digit == 0 ? .wholeMatch : .group(digit))
                    } else {
                        literal.append(next == "n" ? "\n" : (next == "t" ? "\t" : next))
                    }
                } else {
                    literal.append(c)
                }
            }
            flush()
            return parts
        }
    }

    // MARK: - Execution

    /// The editor state for one input stream.
    private final class SedMachine {
        let program: [SedInstruction]
        let labels: [String: Int]
        let suppress: Bool
        var active: [Bool]
        var rangeEnd: [Int]
        var hold = ""
        var lastRegex: Regex? = nil
        var lineNumber = 0
        var quitCode: Int32? = nil

        init(program: [SedInstruction], labels: [String: Int], suppress: Bool) {
            self.program = program
            self.labels = labels
            self.suppress = suppress
            self.active = Array(repeating: false, count: program.count)
            self.rangeEnd = Array(repeating: 0, count: program.count)
        }

        func resolve(_ regex: Regex?) -> Regex? {
            if let regex { lastRegex = regex }
            return regex ?? lastRegex
        }

        func matches(_ address: SedAddress, _ space: String, isLast: Bool) -> Bool {
            switch address {
            case let .line(number): return lineNumber == number
            case .last: return isLast
            case let .regex(regex): return resolve(regex)?.matches(space) ?? false
            case let .step(first, step):
                if step <= 0 { return lineNumber == first }
                return lineNumber >= first && (lineNumber - first) % step == 0
            case .offset: return false
            }
        }

        /// Whether instruction `index` applies to the current line, updating its
        /// range state. `endsRange` is set when this line closes the range (or
        /// the instruction is not a range at all) — what `c` needs to know.
        func selects(_ index: Int, _ space: String, isLast: Bool) -> (selected: Bool, endsRange: Bool) {
            let instruction = program[index]
            guard let first = instruction.address1 else { return (!instruction.negate, true) }
            var selected: Bool
            var ends = true
            if let second = instruction.address2 {
                if active[index] {
                    selected = true
                    switch second {
                    case let .line(number): if lineNumber >= number { active[index] = false }
                    case .offset: if lineNumber >= rangeEnd[index] { active[index] = false }
                    default: if matches(second, space, isLast: isLast) { active[index] = false }
                    }
                    if isLast { active[index] = false }
                    ends = !active[index]
                } else if matches(first, space, isLast: isLast) {
                    selected = true
                    switch second {
                    case let .line(number): active[index] = number > lineNumber
                    case let .offset(count):
                        rangeEnd[index] = lineNumber + count
                        active[index] = count > 0
                    default: active[index] = true
                    }
                    if isLast { active[index] = false }
                    ends = !active[index]
                } else {
                    selected = false
                }
            } else {
                selected = matches(first, space, isLast: isLast)
            }
            return (selected != instruction.negate, ends)
        }

        func substitute(_ space: String, regex: Regex, replacement: [SedReplacementPart],
                        global: Bool, occurrence: Int) -> String? {
            let chars = Array(space)
            var result = ""
            var position = 0
            var copied = 0
            var seen = 0
            var changed = false
            while position <= chars.count, let match = regex.match(in: chars, from: position) {
                seen += 1
                let range = match.range
                if seen >= occurrence {
                    result += String(chars[copied..<range.lowerBound])
                    for part in replacement {
                        switch part {
                        case let .literal(text): result += text
                        case .wholeMatch: result += String(chars[range])
                        case let .group(number):
                            if number < match.groups.count, let group = match.groups[number] {
                                result += String(chars[group])
                            }
                        }
                    }
                    copied = range.upperBound
                    changed = true
                    if !global { break }
                }
                if range.isEmpty {
                    // Zero-width match: step over one character to make progress.
                    if range.upperBound < chars.count, seen >= occurrence {
                        result.append(chars[range.upperBound])
                        copied = range.upperBound + 1
                    }
                    position = range.upperBound + 1
                } else {
                    position = range.upperBound
                }
            }
            guard changed else { return nil }
            if copied < chars.count { result += String(chars[copied...]) }
            return result
        }
    }

    /// Run `machine` over the lines `read` supplies, sending output to `write`.
    /// Returns `false` if a write failed (the reader went away).
    private static func runSed(_ machine: SedMachine,
                               read: () async -> [UInt8]?,
                               write: (String) async -> Bool) async -> Bool {
        var lookahead = await read()
        var out = ""
        func nextLine() async -> String? {
            guard let current = lookahead else { return nil }
            lookahead = await read()
            machine.lineNumber += 1
            return text(current)
        }
        cycles: while machine.quitCode == nil, var space = await nextLine() {
            var appendQueue: [String] = []
            var substituted = false
            var autoprint = !machine.suppress
            var pc = 0
            var restart = true                 // run the program at least once
            while restart {
                restart = false
                pc = 0
                script: while pc < machine.program.count {
                    let instruction = machine.program[pc]
                    let (selected, endsRange) = machine.selects(pc, space, isLast: lookahead == nil)
                    pc += 1
                    guard selected else {
                        if case let .blockStart(end) = instruction.action { pc = end }
                        continue
                    }
                    func jump(_ name: String) { pc = name.isEmpty ? machine.program.count : (machine.labels[name] ?? machine.program.count) }
                    switch instruction.action {
                    case .blockStart, .blockEnd, .label:
                        break
                    case .print:
                        out += space + "\n"
                    case .printFirstLine:
                        out += space.prefix { $0 != "\n" } + "\n"
                    case .delete:
                        autoprint = false
                        break script
                    case .deleteFirstLine:
                        guard let newline = space.firstIndex(of: "\n") else {
                            autoprint = false
                            break script
                        }
                        // Restart the cycle on what is left, without new input.
                        space = String(space[space.index(after: newline)...])
                        out += appendQueue.joined()
                        appendQueue = []
                        restart = true
                        break script
                    case let .quit(code, printSpace):
                        machine.quitCode = code
                        if !printSpace { autoprint = false }
                        break script
                    case let .substitute(regex, replacement, global, occurrence, printFlag):
                        guard let compiled = machine.resolve(regex) else { break }
                        if let replaced = machine.substitute(space, regex: compiled, replacement: replacement,
                                                             global: global, occurrence: occurrence) {
                            space = replaced
                            substituted = true
                            if printFlag { out += space + "\n" }
                        }
                    case let .transliterate(table):
                        space = String(space.map { table[$0] ?? $0 })
                    case let .append(text):
                        appendQueue.append(text + "\n")
                    case let .insert(text):
                        out += text + "\n"
                    case let .change(text):
                        if endsRange { out += text + "\n" }
                        autoprint = false
                        break script
                    case .lineNumber:
                        out += "\(machine.lineNumber)\n"
                    case .next:
                        guard lookahead != nil else { break script }     // no more input: end normally
                        if autoprint { out += space + "\n" }
                        out += appendQueue.joined()
                        appendQueue = []
                        space = await nextLine() ?? ""
                    case .appendNext:
                        guard lookahead != nil else { break script }     // GNU prints the pattern space
                        out += appendQueue.joined()
                        appendQueue = []
                        space += "\n" + (await nextLine() ?? "")
                    case .hold: machine.hold = space
                    case .holdAppend: machine.hold += "\n" + space
                    case .get: space = machine.hold
                    case .getAppend: space += "\n" + machine.hold
                    case .exchange: swap(&space, &machine.hold)
                    case let .branch(name):
                        jump(name)
                    case let .branchIfSubstituted(name):
                        if substituted { substituted = false; jump(name) }
                    case let .branchIfNotSubstituted(name):
                        if substituted { substituted = false } else { jump(name) }
                    }
                }
            }
            if autoprint { out += space + "\n" }
            out += appendQueue.joined()
            // Hand over each cycle's output before the next (possibly blocking)
            // read, so `sed` stays live in an interactive pipeline.
            if !out.isEmpty {
                guard await write(out) else { return false }
                out = ""
            }
        }
        return out.isEmpty ? true : await write(out)
    }

    private static func sedCommand(_ ctx: ProcessContext, _ arguments: [String]) async {
        var suppress = false, separate = false
        var syntax = Regex.Syntax.basic
        var inPlace: String? = nil                 // backup suffix ("" = none)
        var scripts: [String] = []
        var operands: [String] = []
        var args = arguments[...]
        func usageError(_ message: String) {
            ctx.error("sed: \(message)")
            ctx.fail("Try 'sed --help' for more information.", code: 1)
        }
        while let arg = args.popFirst() {
            if arg == "--" { operands += args; break }
            if arg == "--quiet" || arg == "--silent" { suppress = true; continue }
            if arg == "--regexp-extended" { syntax = .extended; continue }
            if arg == "--separate" { separate = true; continue }
            if arg == "--in-place" { inPlace = ""; continue }
            if arg.hasPrefix("--in-place=") { inPlace = String(arg.dropFirst(11)); continue }
            if arg.hasPrefix("--expression=") { scripts.append(String(arg.dropFirst(13))); continue }
            if arg.hasPrefix("--") { ctx.invalidOption("sed", arg); return }
            guard CommandArguments.isOptionToken(arg) else { operands.append(arg); continue }
            var letters = arg.dropFirst()
            while let letter = letters.popFirst() {
                switch letter {
                case "n": suppress = true
                case "E", "r": syntax = .extended
                case "s": separate = true
                case "u", "z": break
                case "i":
                    inPlace = String(letters)       // attached suffix, possibly empty
                    letters = ""
                case "e", "f":
                    var value = String(letters)
                    letters = ""
                    if value.isEmpty {
                        guard let next = args.popFirst() else {
                            usageError("option requires an argument -- '\(letter)'"); return
                        }
                        value = next
                    }
                    if letter == "e" {
                        scripts.append(value)
                    } else {
                        do {
                            scripts.append(text(try await readOperand(ctx, value)))
                        } catch {
                            ctx.fail("sed: couldn't open file \(value): \(errnoText(error))", code: 1); return
                        }
                    }
                default:
                    ctx.invalidOption("sed", String(letter)); return
                }
            }
        }
        if scripts.isEmpty {
            guard !operands.isEmpty else {
                ctx.error("Usage: sed [OPTION]... {script-only-if-no-other-script} [input-file]...")
                ctx.fail("Try 'sed --help' for more information.", code: 1); return
            }
            scripts.append(operands.removeFirst())
        }
        var parser = SedParser(scripts.joined(separator: "\n"), syntax: syntax)
        do {
            try parser.parse()
        } catch {
            ctx.fail("sed: \((error as? SedError)?.message ?? "invalid script")", code: 1); return
        }
        func machine() -> SedMachine {
            SedMachine(program: parser.program, labels: parser.labels, suppress: suppress)
        }

        if let suffix = inPlace {
            guard !operands.isEmpty else { ctx.fail("sed: no input files", code: 1); return }
            var status: Int32 = 0
            for file in operands {
                guard let info = ctx.stat(file), !info.isDirectory else {
                    let reason = ctx.stat(file) == nil ? SyscallError.noSuchFileOrDirectory.message
                                                       : "not a regular file"
                    ctx.error(ctx.stat(file) == nil ? "sed: can't read \(file): \(reason)"
                                                    : "sed: couldn't edit \(file): \(reason)")
                    status = 1
                    continue
                }
                let original: [UInt8]
                do { original = try await readOperand(ctx, file) } catch {
                    ctx.error("sed: can't read \(file): \(errnoText(error))")
                    status = 1
                    continue
                }
                var lines = splitRawLines(original)[...]
                var edited = ""
                _ = await runSed(machine(),
                                 read: { lines.popFirst().map { $0.last == 0x0A ? Array($0.dropLast()) : $0 } },
                                 write: { edited += $0; return true })
                do {
                    if !suffix.isEmpty {
                        let backupName = suffix.contains("*") ? suffix.replacing("*", with: baseName(file)) : file + suffix
                        let backup = try ctx.openForWriting(backupName)
                        _ = await ctx.writeAll(backup, original)
                        ctx.close(backup)
                    }
                    let fd = try ctx.openForWriting(file)
                    _ = await ctx.writeAll(fd, Array(edited.utf8))
                    ctx.close(fd)
                } catch {
                    ctx.error("sed: couldn't write \(file): \(errnoText(error))")
                    status = 1
                }
            }
            ctx.exit(status)
            return
        }

        var status: Int32 = 0
        var quitCode: Int32? = nil
        let groups = separate && !operands.isEmpty ? operands.map { [$0] } : [operands]
        for group in groups {
            let input = CommandInput(ctx, command: "sed", files: group)
            let editor = machine()
            guard await runSed(editor, read: { await input.line() }, write: { await ctx.put($0) }) else { return }
            if input.status != 0 { status = 2 }
            if let code = editor.quitCode { quitCode = code; break }
        }
        ctx.exit(quitCode.map { $0 != 0 ? $0 : status } ?? status)
    }
}
