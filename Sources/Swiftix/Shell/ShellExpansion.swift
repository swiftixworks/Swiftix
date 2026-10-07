/// Shell word expansion: brace expansion, tilde expansion, parameter expansion
/// (`$VAR`, `${VAR:-x}`, `${VAR#pat}` …), arithmetic `$(( … ))`, splicing of
/// pre-computed command-substitution output, field splitting, and pathname
/// globbing. Pure value types: every effect (variable lookup/assignment,
/// directory listing) arrives through `ExpansionContext` closures that the
/// interpreter runs on the shell's executor.
extension Programs {

    // MARK: - Context

    /// Everything expansion needs from the running shell.
    struct ExpansionContext {
        /// Variables and special parameters (`?`, `#`, `$`, `!`, `0`, `1`…);
        /// `@` and `*` are served from `positional` instead.
        var parameter: (String) -> String?
        var positional: [String]
        /// `${VAR:=word}` and arithmetic assignments.
        var assign: (String, String) -> Void
        /// Output of a command substitution, keyed by its script text. The
        /// interpreter runs every substitution a word contains *before*
        /// expanding it (see `commandSubstitutions(in:)`).
        var commandOutput: (String) -> String
        /// Directory entries (names, directories suffixed with `/`).
        var list: (String) -> [String]?
        /// `set -u`: referencing an unset variable is an error.
        var nounset = false
    }

    /// One character of an expanded field. `literal` characters came from
    /// quotes/escapes and never act as glob metacharacters.
    struct Piece: Equatable {
        var ch: Character
        var literal: Bool
    }

    // MARK: - Expander

    struct WordExpander {
        let context: ExpansionContext
        /// The first expansion error (`${VAR:?msg}`, unbound variable, …).
        var error: String?

        private enum Mode { case unquoted, doubleQuoted, heredoc }
        private var noSplit = 0
        private var splitLiteralWhitespace = false
        private var sawEmptyAt = false

        init(context: ExpansionContext) {
            self.context = context
        }

        private struct FieldBuilder {
            var fields: [[Piece]] = []
            var current: [Piece] = []
            var hasCurrent = false

            mutating func append(_ ch: Character, literal: Bool) {
                current.append(Piece(ch: ch, literal: literal))
                hasCurrent = true
            }
            mutating func append(_ text: String, literal: Bool) {
                for ch in text { append(ch, literal: literal) }
            }
            /// The field exists even if empty (`""`).
            mutating func touch() { hasCurrent = true }
            mutating func softBreak() {
                if hasCurrent { forceBreak() }
            }
            mutating func forceBreak() {
                fields.append(current); current = []; hasCurrent = false
            }
            mutating func appendSplit(_ text: String, ifs: String) {
                for ch in text {
                    if ifs.contains(ch) {
                        if ch == " " || ch == "\t" || ch == "\n" { softBreak() } else { forceBreak() }
                    } else {
                        append(ch, literal: false)
                    }
                }
            }
            mutating func finish() -> [[Piece]] {
                softBreak()
                return fields
            }
        }

        // MARK: Entry points

        /// Fully expand one raw command word into its final fields: brace
        /// expansion, then parameter/command/arithmetic expansion with field
        /// splitting, then pathname globbing.
        mutating func fields(_ raw: String) -> [String] {
            var out: [String] = []
            for word in Programs.braceExpand(raw) {
                var builder = FieldBuilder()
                scan(Array(word), into: &builder, mode: .unquoted, tilde: true)
                for field in builder.finish() {
                    if let matches = glob(field) { out += matches }
                    else { out.append(String(field.map(\.ch))) }
                }
            }
            return out
        }

        /// Expand to exactly one string: no field splitting, no globbing. Used
        /// for assignment values, redirection targets, and `case` subjects.
        mutating func string(_ raw: String) -> String {
            String(pieces(Array(raw), mode: .unquoted, tilde: true).map(\.ch))
        }

        /// Expand to a glob pattern: quoted characters are literal.
        mutating func pattern(_ raw: String) -> [Piece] {
            pieces(Array(raw), mode: .unquoted, tilde: false)
        }

        /// Expand a here-document body: `$`-expansions apply, quotes are literal.
        mutating func heredoc(_ body: String) -> String {
            String(pieces(Array(body), mode: .heredoc, tilde: false).map(\.ch))
        }

        private mutating func pieces(_ chars: [Character], mode: Mode, tilde: Bool) -> [Piece] {
            var builder = FieldBuilder()
            noSplit += 1
            let savedSplit = splitLiteralWhitespace
            splitLiteralWhitespace = false
            scan(chars, into: &builder, mode: mode, tilde: tilde)
            splitLiteralWhitespace = savedSplit
            noSplit -= 1
            var all: [Piece] = []
            for (index, field) in (builder.fields + [builder.current]).enumerated() {
                if index > 0 { all.append(Piece(ch: " ", literal: true)) }
                all += field
            }
            return all
        }

        // MARK: Scanning

        private func slice(_ c: [Character], from start: Int, rawEnd: Int) -> (inner: [Character], next: Int) {
            if rawEnd > c.count { return (Array(c[Swift.min(start, c.count)...]), c.count) }
            return (Array(c[start..<(rawEnd - 1)]), rawEnd)
        }

        private var ifs: String { context.parameter("IFS") ?? " \t\n" }

        private mutating func scan(_ c: [Character], into b: inout FieldBuilder, mode: Mode, tilde: Bool = false) {
            var i = 0
            if mode == .unquoted, tilde, c.first == "~", c.count == 1 || c[1] == "/",
               let home = context.parameter("HOME") {
                b.append(home, literal: true)
                b.touch()
                i = 1
            }
            while i < c.count {
                let ch = c[i]
                if mode == .unquoted {
                    switch ch {
                    case "'":
                        let (inner, next) = slice(c, from: i + 1, rawEnd: ShellScanner.afterSingleQuote(c, i + 1))
                        b.append(String(inner), literal: true); b.touch()
                        i = next
                    case "\"":
                        let (inner, next) = slice(c, from: i + 1, rawEnd: ShellScanner.afterDoubleQuote(c, i + 1))
                        let fieldsBefore = b.fields.count, piecesBefore = b.current.count
                        sawEmptyAt = false
                        scan(inner, into: &b, mode: .doubleQuoted)
                        if !(sawEmptyAt && b.fields.count == fieldsBefore && b.current.count == piecesBefore) {
                            b.touch()
                        }
                        sawEmptyAt = false
                        i = next
                    case "\\":
                        if i + 1 < c.count {
                            if c[i + 1] != "\n" { b.append(c[i + 1], literal: true) }
                            i += 2
                        } else {
                            i += 1
                        }
                    case "`":
                        let (inner, next) = slice(c, from: i + 1, rawEnd: ShellScanner.afterBacktick(c, i + 1))
                        appendValue(context.commandOutput(Programs.unescapeBacktick(inner)), quoted: false, into: &b)
                        i = next
                    case "$":
                        if i + 1 < c.count, c[i + 1] == "'" {
                            let (inner, next) = slice(c, from: i + 2, rawEnd: ShellScanner.afterAnsiQuote(c, i + 2))
                            b.append(Programs.decodeAnsiQuoted(inner), literal: true); b.touch()
                            i = next
                        } else {
                            i = dollar(c, i, into: &b, quoted: false)
                        }
                    default:
                        if splitLiteralWhitespace, noSplit == 0, ch == " " || ch == "\t" || ch == "\n" {
                            b.softBreak()
                        } else {
                            b.append(ch, literal: false)
                        }
                        i += 1
                    }
                } else {
                    switch ch {
                    case "\\":
                        if i + 1 < c.count {
                            let next = c[i + 1]
                            if next == "$" || next == "`" || next == "\\" || (next == "\"" && mode == .doubleQuoted) {
                                b.append(next, literal: true); i += 2
                            } else if next == "\n" {
                                i += 2
                            } else {
                                b.append(ch, literal: true); i += 1
                            }
                        } else {
                            b.append(ch, literal: true); i += 1
                        }
                    case "`":
                        let (inner, next) = slice(c, from: i + 1, rawEnd: ShellScanner.afterBacktick(c, i + 1))
                        appendValue(context.commandOutput(Programs.unescapeBacktick(inner)), quoted: true, into: &b)
                        i = next
                    case "$":
                        i = dollar(c, i, into: &b, quoted: true)
                    default:
                        b.append(ch, literal: true); i += 1
                    }
                }
            }
        }

        private mutating func appendValue(_ value: String, quoted: Bool, into b: inout FieldBuilder) {
            if quoted || noSplit > 0 {
                b.append(value, literal: quoted)
            } else {
                b.appendSplit(value, ifs: ifs)
            }
        }

        /// `$@` / `$*` in every quoting context.
        private mutating func appendAll(star: Bool, quoted: Bool, into b: inout FieldBuilder) {
            let parameters = context.positional
            if noSplit > 0 || (quoted && star) {
                let separator = star ? String(ifs.first.map { String($0) } ?? "") : " "
                b.append(parameters.joined(separator: noSplit > 0 && !quoted ? " " : separator), literal: quoted)
                return
            }
            if quoted {
                if parameters.isEmpty { sawEmptyAt = true; return }
                for (index, parameter) in parameters.enumerated() {
                    if index > 0 { b.forceBreak() }
                    b.append(parameter, literal: true)
                    b.touch()
                }
                return
            }
            for (index, parameter) in parameters.enumerated() {
                if index > 0 { b.softBreak() }
                b.appendSplit(parameter, ifs: ifs)
            }
        }

        private mutating func lookup(_ name: String) -> String? {
            let value = context.parameter(name)
            if value == nil, context.nounset, error == nil,
               name.first.map({ $0.isLetter || $0 == "_" || $0.isNumber }) == true, name != "0" {
                error = "\(name): unbound variable"
            }
            return value
        }

        /// `c[start] == "$"`: expand the construct and return the index past it.
        private mutating func dollar(_ c: [Character], _ start: Int, into b: inout FieldBuilder, quoted: Bool) -> Int {
            guard start + 1 < c.count else { b.append("$", literal: true); return start + 1 }
            let next = c[start + 1]
            if next == "(" {
                let (inner, end) = slice(c, from: start + 2, rawEnd: ShellScanner.afterParen(c, start + 2))
                if let expression = Programs.arithmeticBody(inner) {
                    appendValue(String(arithmetic(expression)), quoted: quoted, into: &b)
                } else {
                    appendValue(context.commandOutput(String(inner)), quoted: quoted, into: &b)
                }
                return end
            }
            if next == "{" {
                let (inner, end) = slice(c, from: start + 2, rawEnd: ShellScanner.afterBrace(c, start + 2))
                braceParameter(inner, into: &b, quoted: quoted)
                return end
            }
            if next == "@" || next == "*" {
                appendAll(star: next == "*", quoted: quoted, into: &b)
                return start + 2
            }
            if next == "?" || next == "#" || next == "$" || next == "!" || next == "-"
                || (next.isASCII && next.isNumber) {
                appendValue(lookup(String(next)) ?? "", quoted: quoted, into: &b)
                return start + 2
            }
            if next.isLetter || next == "_" {
                var j = start + 1
                var name = ""
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { name.append(c[j]); j += 1 }
                appendValue(lookup(name) ?? "", quoted: quoted, into: &b)
                return j
            }
            b.append("$", literal: true)
            return start + 1
        }

        private mutating func arithmetic(_ expression: [Character]) -> Int {
            let text = String(pieces(expression, mode: .doubleQuoted, tilde: false).map(\.ch))
            return Programs.evaluateArithmetic(text, lookup: context.parameter, assign: context.assign)
        }

        /// The body of `${ … }`.
        private mutating func braceParameter(_ body: [Character], into b: inout FieldBuilder, quoted: Bool) {
            guard !body.isEmpty else { fail("bad substitution"); return }
            if body == ["#"] {
                appendValue(String(context.positional.count), quoted: quoted, into: &b)
                return
            }
            // `${#NAME}` — length.
            if body[0] == "#", body.count > 1, let (name, end) = parameterName(body, 1), end == body.count {
                let length = name == "@" || name == "*"
                    ? context.positional.count : (lookup(name) ?? "").count
                appendValue(String(length), quoted: quoted, into: &b)
                return
            }
            guard let (name, afterName) = parameterName(body, 0) else { fail("bad substitution"); return }
            let isAll = name == "@" || name == "*"

            func emit(_ expander: inout WordExpander, _ b: inout FieldBuilder) {
                if isAll { expander.appendAll(star: name == "*", quoted: quoted, into: &b) }
                else { expander.appendValue(expander.context.parameter(name) ?? "", quoted: quoted, into: &b) }
            }

            if afterName == body.count {
                if isAll { appendAll(star: name == "*", quoted: quoted, into: &b) }
                else { appendValue(lookup(name) ?? "", quoted: quoted, into: &b) }
                return
            }
            let value: String? = isAll
                ? (context.positional.isEmpty ? nil : context.positional.joined(separator: " "))
                : context.parameter(name)
            var k = afterName
            var colon = false
            if body[k] == ":" { colon = true; k += 1 }
            guard k < body.count else { fail("bad substitution"); return }
            let op = body[k]
            let word = Array(body[(k + 1)...])
            let unsetOrNull = value == nil || (colon && value!.isEmpty)
            switch op {
            case "-":
                if unsetOrNull { scanWord(word, into: &b, quoted: quoted) } else { emit(&self, &b) }
            case "+":
                if !unsetOrNull { scanWord(word, into: &b, quoted: quoted) }
            case "=":
                if unsetOrNull {
                    let assigned = String(pieces(word, mode: quoted ? .doubleQuoted : .unquoted, tilde: false).map(\.ch))
                    context.assign(name, assigned)
                    appendValue(assigned, quoted: quoted, into: &b)
                } else {
                    emit(&self, &b)
                }
            case "?":
                if unsetOrNull {
                    let message = word.isEmpty
                        ? "parameter null or not set"
                        : String(pieces(word, mode: quoted ? .doubleQuoted : .unquoted, tilde: false).map(\.ch))
                    if error == nil { error = "\(name): \(message)" }
                } else {
                    emit(&self, &b)
                }
            case "#" where !colon, "%" where !colon:
                var patternStart = k + 1
                var longest = false
                if patternStart < body.count, body[patternStart] == op { longest = true; patternStart += 1 }
                let patternPieces = pieces(Array(body[patternStart...]), mode: .unquoted, tilde: false)
                let subject = Array(lookupForOperator(name, value))
                let trimmed = op == "#"
                    ? Programs.removePrefix(subject, patternPieces, longest: longest)
                    : Programs.removeSuffix(subject, patternPieces, longest: longest)
                appendValue(String(trimmed), quoted: quoted, into: &b)
            case "/" where !colon:
                var rest = word
                var replaceAll = false
                if rest.first == "/" { replaceAll = true; rest.removeFirst() }
                var split = rest.count
                var index = 0
                while index < rest.count {
                    if rest[index] == "\\" { index += 2; continue }
                    if rest[index] == "/" { split = index; break }
                    index += 1
                }
                let patternPieces = pieces(Array(rest[..<split]), mode: .unquoted, tilde: false)
                let replacement = split < rest.count
                    ? String(pieces(Array(rest[(split + 1)...]), mode: .unquoted, tilde: false).map(\.ch)) : ""
                let subject = Array(lookupForOperator(name, value))
                appendValue(Programs.replacePattern(subject, patternPieces, with: replacement, all: replaceAll),
                            quoted: quoted, into: &b)
            default:
                guard colon else { fail("bad substitution"); return }
                // `${VAR:offset[:length]}` — substring.
                let spec = Array(body[k...])
                var parts: [[Character]] = [[]]
                for ch in spec {
                    if ch == ":", parts.count == 1 { parts.append([]) } else { parts[parts.count - 1].append(ch) }
                }
                let subject = Array(lookupForOperator(name, value))
                var offset = arithmetic(parts[0])
                if offset < 0 { offset = Swift.max(0, subject.count + offset) }
                offset = Swift.min(offset, subject.count)
                var end = subject.count
                if parts.count > 1 {
                    let length = arithmetic(parts[1])
                    end = length < 0 ? Swift.max(offset, subject.count + length)
                                     : Swift.min(subject.count, offset + length)
                }
                appendValue(String(subject[offset..<end]), quoted: quoted, into: &b)
            }
        }

        private mutating func lookupForOperator(_ name: String, _ value: String?) -> String {
            if value == nil, name != "@", name != "*" { _ = lookup(name) }
            return value ?? ""
        }

        /// Expand the word of `${VAR:-word}` in place; unquoted literal
        /// whitespace in it separates fields like any other unquoted text.
        private mutating func scanWord(_ word: [Character], into b: inout FieldBuilder, quoted: Bool) {
            let saved = splitLiteralWhitespace
            splitLiteralWhitespace = !quoted
            scan(word, into: &b, mode: quoted ? .doubleQuoted : .unquoted)
            splitLiteralWhitespace = saved
        }

        private mutating func fail(_ message: String) {
            if error == nil { error = message }
        }

        /// A parameter name starting at `body[start]`: a special character, a
        /// positional number, or an identifier.
        private func parameterName(_ body: [Character], _ start: Int) -> (String, Int)? {
            guard start < body.count else { return nil }
            let first = body[start]
            if "@*#?$!-".contains(first) { return (String(first), start + 1) }
            var j = start
            var name = ""
            if first.isASCII, first.isNumber {
                while j < body.count, body[j].isASCII, body[j].isNumber { name.append(body[j]); j += 1 }
                return (name, j)
            }
            guard first.isLetter || first == "_" else { return nil }
            while j < body.count, body[j].isLetter || body[j].isNumber || body[j] == "_" { name.append(body[j]); j += 1 }
            return (name, j)
        }

        // MARK: Pathname expansion

        /// Paths matching `field`, or `nil` when it has no active glob
        /// metacharacter or matches nothing (the word then stays literal).
        private func glob(_ field: [Piece]) -> [String]? {
            guard field.contains(where: { !$0.literal && ($0.ch == "*" || $0.ch == "?" || $0.ch == "[") }) else {
                return nil
            }
            var components: [[Piece]] = [[]]
            for piece in field {
                if piece.ch == "/" { components.append([]) } else { components[components.count - 1].append(piece) }
            }
            let absolute = field.first?.ch == "/"
            if absolute { components.removeFirst() }
            var prefixes = [absolute ? "/" : ""]
            for (index, component) in components.enumerated() {
                let isLast = index == components.count - 1
                if component.isEmpty {
                    // A doubled or trailing slash: nothing to match.
                    if isLast { break }
                    continue
                }
                let active = component.contains { !$0.literal && ($0.ch == "*" || $0.ch == "?" || $0.ch == "[") }
                var next: [String] = []
                for prefix in prefixes {
                    let directory = prefix.isEmpty ? "." : prefix
                    guard let entries = context.list(directory) else { continue }
                    if active {
                        let matchesDotFiles = component.first?.ch == "."
                        for entry in entries {
                            let isDirectory = entry.hasSuffix("/")
                            let name = isDirectory ? String(entry.dropLast()) : entry
                            if name.first == ".", !matchesDotFiles { continue }
                            if !isLast, !isDirectory { continue }
                            if Programs.patternMatch(component, Array(name)) {
                                next.append(prefix + name + (isLast ? "" : "/"))
                            }
                        }
                    } else {
                        let name = String(component.map(\.ch))
                        let isDirectory = name == "." || name == ".." || entries.contains(name + "/")
                        if isLast {
                            if isDirectory || entries.contains(name) { next.append(prefix + name) }
                        } else if isDirectory {
                            next.append(prefix + name + "/")
                        }
                    }
                }
                prefixes = next
                if prefixes.isEmpty { return nil }
            }
            if components.last?.isEmpty == true {
                // `*/` — keep the trailing slash; only directories reach here.
                prefixes = prefixes.filter { $0.hasSuffix("/") }
            }
            return prefixes.isEmpty ? nil : prefixes.sorted()
        }
    }

    // MARK: - Command substitution discovery (pure)

    /// `inner` is the text between `$(` and its matching `)`. When that text is
    /// itself one parenthesized group, the construct is arithmetic `$(( … ))`
    /// and the expression inside is returned.
    static func arithmeticBody(_ inner: [Character]) -> [Character]? {
        guard inner.count >= 2, inner.first == "(", inner.last == ")",
              ShellScanner.afterParen(inner, 1) == inner.count else { return nil }
        return Array(inner[1..<(inner.count - 1)])
    }

    /// A backtick substitution's script: `\`` `\\` `\$` lose their backslash.
    static func unescapeBacktick(_ inner: [Character]) -> String {
        var out = ""
        var i = 0
        while i < inner.count {
            if inner[i] == "\\", i + 1 < inner.count,
               inner[i + 1] == "`" || inner[i + 1] == "\\" || inner[i + 1] == "$" {
                out.append(inner[i + 1]); i += 2
            } else {
                out.append(inner[i]); i += 1
            }
        }
        return out
    }

    /// Decode the body of `$'…'` (ANSI-C quoting).
    static func decodeAnsiQuoted(_ inner: [Character]) -> String {
        var out = ""
        var i = 0
        while i < inner.count {
            guard inner[i] == "\\", i + 1 < inner.count else { out.append(inner[i]); i += 1; continue }
            let escape = inner[i + 1]
            i += 2
            switch escape {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "a": out.append("\u{07}")
            case "b": out.append("\u{08}")
            case "e", "E": out.append("\u{1B}")
            case "f": out.append("\u{0C}")
            case "v": out.append("\u{0B}")
            case "\\", "'", "\"": out.append(escape)
            case "x":
                var digits = ""
                while i < inner.count, digits.count < 2, inner[i].isHexDigit { digits.append(inner[i]); i += 1 }
                if let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) {
                    out.append(Character(scalar))
                }
            case "0", "1", "2", "3", "4", "5", "6", "7":
                var digits = String(escape)
                while i < inner.count, digits.count < 3, ("0"..."7").contains(inner[i]) { digits.append(inner[i]); i += 1 }
                if let value = UInt32(digits, radix: 8), let scalar = Unicode.Scalar(value) {
                    out.append(Character(scalar))
                }
            default:
                out.append("\\"); out.append(escape)
            }
        }
        return out
    }

    /// The scripts of every command substitution (`$( … )` and backticks) that
    /// expanding `raw` will ask for, in source order. Substitutions nested
    /// inside another substitution belong to the child shell and are not listed.
    static func commandSubstitutions(in raw: String, heredoc: Bool = false) -> [String] {
        var out: [String] = []
        func slice(_ c: [Character], _ start: Int, _ rawEnd: Int) -> ([Character], Int) {
            if rawEnd > c.count { return (Array(c[Swift.min(start, c.count)...]), c.count) }
            return (Array(c[start..<(rawEnd - 1)]), rawEnd)
        }
        func walk(_ c: [Character], quoted: Bool) {
            var i = 0
            while i < c.count {
                switch c[i] {
                case "\\":
                    i += 2
                case "'" where !quoted:
                    i = Swift.min(ShellScanner.afterSingleQuote(c, i + 1), c.count)
                case "\"" where !quoted:
                    let (inner, next) = slice(c, i + 1, ShellScanner.afterDoubleQuote(c, i + 1))
                    walk(inner, quoted: true)
                    i = next
                case "`":
                    let (inner, next) = slice(c, i + 1, ShellScanner.afterBacktick(c, i + 1))
                    out.append(unescapeBacktick(inner))
                    i = next
                case "$":
                    guard i + 1 < c.count else { i += 1; break }
                    if c[i + 1] == "(" {
                        let (inner, next) = slice(c, i + 2, ShellScanner.afterParen(c, i + 2))
                        if let expression = arithmeticBody(inner) { walk(expression, quoted: true) }
                        else { out.append(String(inner)) }
                        i = next
                    } else if c[i + 1] == "{" {
                        let (inner, next) = slice(c, i + 2, ShellScanner.afterBrace(c, i + 2))
                        walk(inner, quoted: quoted)
                        i = next
                    } else if c[i + 1] == "'", !quoted {
                        i = Swift.min(ShellScanner.afterAnsiQuote(c, i + 2), c.count)
                    } else {
                        i += 1
                    }
                default:
                    i += 1
                }
            }
        }
        walk(Array(raw), quoted: heredoc)
        return out
    }

    // MARK: - Brace expansion

    /// Expand `{a,b,c}` alternatives and `{1..5}` / `{a..e}` sequences in a raw
    /// word, leaving quoted text and `${ … }` / `$( … )` untouched.
    static func braceExpand(_ raw: String) -> [String] {
        guard raw.contains("{") else { return [raw] }
        let c = Array(raw)
        var i = 0
        while i < c.count {
            switch c[i] {
            case "\\": i += 2
            case "'": i = Swift.min(ShellScanner.afterSingleQuote(c, i + 1), c.count)
            case "\"": i = Swift.min(ShellScanner.afterDoubleQuote(c, i + 1), c.count)
            case "`": i = Swift.min(ShellScanner.afterBacktick(c, i + 1), c.count)
            case "$": i = Swift.min(ShellScanner.afterDollar(c, i), c.count)
            case "{":
                if let (alternatives, close) = braceAlternatives(c, i) {
                    let prefix = String(c[0..<i])
                    let suffixes = braceExpand(String(c[(close + 1)...]))
                    var out: [String] = []
                    for alternative in alternatives {
                        for expanded in braceExpand(alternative) {
                            for suffix in suffixes { out.append(prefix + expanded + suffix) }
                        }
                    }
                    return out
                }
                i += 1
            default: i += 1
            }
        }
        return [raw]
    }

    /// The alternatives of the brace group opening at `c[open]` and the index of
    /// its closing brace, or `nil` when it is not an expandable group.
    private static func braceAlternatives(_ c: [Character], _ open: Int) -> ([String], Int)? {
        var depth = 1
        var j = open + 1
        var parts: [String] = []
        var current = ""
        var sawComma = false
        while j < c.count {
            let ch = c[j]
            var end = j + 1
            switch ch {
            case "\\": end = Swift.min(j + 2, c.count)
            case "'": end = Swift.min(ShellScanner.afterSingleQuote(c, j + 1), c.count)
            case "\"": end = Swift.min(ShellScanner.afterDoubleQuote(c, j + 1), c.count)
            case "`": end = Swift.min(ShellScanner.afterBacktick(c, j + 1), c.count)
            case "$": end = Swift.min(ShellScanner.afterDollar(c, j), c.count)
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    parts.append(current)
                    if sawComma { return (parts, j) }
                    if let sequence = braceSequence(current) { return (sequence, j) }
                    return nil
                }
            case "," where depth == 1:
                sawComma = true
                parts.append(current); current = ""
                j += 1
                continue
            case " ", "\t", "\n":
                return nil
            default: break
            }
            current.append(contentsOf: c[j..<end])
            j = end
        }
        return nil
    }

    /// `1..5`, `5..1`, `1..10..2`, `a..e`.
    private static func braceSequence(_ body: String) -> [String]? {
        let c = Array(body)
        var parts: [String] = [""]
        var i = 0
        while i < c.count {
            if c[i] == ".", i + 1 < c.count, c[i + 1] == "." { parts.append(""); i += 2 }
            else { parts[parts.count - 1].append(c[i]); i += 1 }
        }
        guard parts.count == 2 || parts.count == 3, !parts.contains("") else { return nil }
        let step = parts.count == 3 ? Swift.max(1, abs(Int(parts[2]) ?? 0)) : 1
        if parts.count == 3, Int(parts[2]) == nil { return nil }
        if let from = Int(parts[0]), let to = Int(parts[1]) {
            guard abs(to - from) / step < 100_000 else { return nil }
            return stride(from: from, through: to, by: from <= to ? step : -step).map(String.init)
        }
        if parts[0].count == 1, parts[1].count == 1,
           let from = parts[0].unicodeScalars.first, let to = parts[1].unicodeScalars.first,
           from.isASCII, to.isASCII, parts[0].first!.isLetter, parts[1].first!.isLetter {
            return stride(from: Int(from.value), through: Int(to.value),
                          by: from.value <= to.value ? step : -step)
                .compactMap { Unicode.Scalar($0).map { String(Character($0)) } }
        }
        return nil
    }

    // MARK: - Pattern matching

    /// Glob matcher for a single name: `*` any run, `?` any one char, `[...]`
    /// a character class (with `^`/`!` negation and `a-z` ranges).
    static func globMatch(_ pattern: [Character], _ name: [Character]) -> Bool {
        patternMatch(pattern.map { Piece(ch: $0, literal: false) }, name)
    }

    /// `globMatch` over pattern pieces: `literal` pieces match only themselves.
    static func patternMatch(_ pattern: [Piece], _ name: [Character]) -> Bool {
        func match(_ p: Int, _ n: Int) -> Bool {
            var pi = p, ni = n
            while pi < pattern.count {
                let piece = pattern[pi]
                if piece.literal {
                    guard ni < name.count, name[ni] == piece.ch else { return false }
                    pi += 1; ni += 1
                    continue
                }
                switch piece.ch {
                case "*":
                    // Collapse consecutive '*'; try to match the rest at every split.
                    while pi < pattern.count, !pattern[pi].literal, pattern[pi].ch == "*" { pi += 1 }
                    if pi == pattern.count { return true }
                    var k = ni
                    while k <= name.count {
                        if match(pi, k) { return true }
                        k += 1
                    }
                    return false
                case "?":
                    guard ni < name.count else { return false }
                    pi += 1; ni += 1
                case "[":
                    guard ni < name.count else { return false }
                    guard let (matched, next) = matchClass(pi, name[ni]) else {
                        // Unterminated class: treat '[' literally.
                        if name[ni] != "[" { return false }
                        pi += 1; ni += 1
                        continue
                    }
                    guard matched else { return false }
                    pi = next; ni += 1
                default:
                    guard ni < name.count, name[ni] == piece.ch else { return false }
                    pi += 1; ni += 1
                }
            }
            return ni == name.count
        }

        /// Match a `[...]` class starting at `pattern[start]` against `character`.
        /// Returns whether it matched and the index just past the class, or `nil`
        /// if the class is unterminated.
        func matchClass(_ start: Int, _ character: Character) -> (Bool, Int)? {
            var i = start + 1
            var negated = false
            if i < pattern.count, pattern[i].ch == "^" || pattern[i].ch == "!" { negated = true; i += 1 }
            var matched = false
            var first = true
            while i < pattern.count, pattern[i].ch != "]" || first {
                first = false
                if i + 2 < pattern.count, pattern[i + 1].ch == "-", pattern[i + 2].ch != "]" {
                    if character >= pattern[i].ch, character <= pattern[i + 2].ch { matched = true }
                    i += 3
                } else {
                    if character == pattern[i].ch { matched = true }
                    i += 1
                }
            }
            guard i < pattern.count, pattern[i].ch == "]" else { return nil }   // unterminated
            return (matched != negated, i + 1)
        }

        return match(0, 0)
    }

    /// `${VAR#pat}` / `${VAR##pat}`.
    static func removePrefix(_ value: [Character], _ pattern: [Piece], longest: Bool) -> [Character] {
        let lengths = longest ? Array((0...value.count).reversed()) : Array(0...value.count)
        for length in lengths where patternMatch(pattern, Array(value[0..<length])) {
            return Array(value[length...])
        }
        return value
    }

    /// `${VAR%pat}` / `${VAR%%pat}`.
    static func removeSuffix(_ value: [Character], _ pattern: [Piece], longest: Bool) -> [Character] {
        let starts = longest ? Array(0...value.count) : Array((0...value.count).reversed())
        for start in starts where patternMatch(pattern, Array(value[start...])) {
            return Array(value[0..<start])
        }
        return value
    }

    /// `${VAR/pat/rep}` / `${VAR//pat/rep}` — longest match at each position.
    static func replacePattern(_ value: [Character], _ pattern: [Piece], with replacement: String, all: Bool) -> String {
        guard !pattern.isEmpty else { return String(value) }
        var out = ""
        var i = 0
        var replaced = false
        while i < value.count {
            var matchedEnd: Int?
            if all || !replaced {
                var end = value.count
                while end > i {
                    if patternMatch(pattern, Array(value[i..<end])) { matchedEnd = end; break }
                    end -= 1
                }
            }
            if let matchedEnd {
                out += replacement
                i = matchedEnd
                replaced = true
            } else {
                out.append(value[i]); i += 1
            }
        }
        return out
    }

    /// Whether a raw word is a `NAME=…` assignment (NAME an unquoted
    /// identifier); returns the name and the raw value text.
    static func assignment(_ token: String) -> (name: String, value: String)? {
        guard let eq = token.firstIndex(of: "=") else { return nil }
        let name = String(token[token.startIndex..<eq])
        guard let first = name.first, first.isLetter || first == "_",
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }
        return (name, String(token[token.index(after: eq)...]))
    }
}
