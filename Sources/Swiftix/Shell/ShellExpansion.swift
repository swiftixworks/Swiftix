/// Shell word expansion: parameter/`$?`/arithmetic `$((…))` expansion, command
/// substitution `$(…)` helpers, pathname globbing, and here-document handling.
extension Programs {

    // MARK: - Word expansion

    /// Expand a RAW word: strip quotes, apply escapes, and substitute `$VAR` /
    /// `${VAR}` / `$?` using the current `env` and `status`. Single quotes are
    /// literal; double quotes allow `$` expansion and the escapes `\"`, `\\`,
    /// `\$`; an unquoted backslash escapes the next character.
    static func expandWord(_ raw: String, env: @escaping (String) -> String?, status: Int32) -> String {
        let chars = Array(raw)
        var out = ""
        var i = 0
        func isNameChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func expandDollar(_ from: Int) -> Int {
            var j = from
            // `$(( … ))` — arithmetic expansion. Checked before `$(` command
            // substitution (handled in an earlier phase) and `${…}`.
            if j + 1 < chars.count, chars[j] == "(", chars[j + 1] == "(" {
                j += 2
                var depth = 1
                var expr = ""
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1; expr.append(chars[j]); j += 1 }
                    else if chars[j] == ")" {
                        depth -= 1
                        if depth == 0 {
                            // Expect the second closing ')'.
                            if j + 1 < chars.count, chars[j + 1] == ")" { j += 2 } else { j += 1 }
                            break
                        }
                        expr.append(chars[j]); j += 1
                    } else { expr.append(chars[j]); j += 1 }
                }
                out += String(evaluateArithmetic(expr, env: env, status: status))
                return j
            }
            if j < chars.count, chars[j] == "?" {
                out += String(status); return j + 1
            } else if j < chars.count, chars[j] == "#" || chars[j] == "@" || chars[j] == "*" {
                // Positional-parameter specials: `$#` (count), `$@`/`$*` (all
                // arguments). Stored in the environment under those single-char
                // keys by the function-call machinery.
                out += env(String(chars[j])) ?? ""
                return j + 1
            } else if j < chars.count, chars[j] == "{" {
                j += 1
                var name = ""
                while j < chars.count, chars[j] != "}" { name.append(chars[j]); j += 1 }
                if j < chars.count { j += 1 }
                out += env(name) ?? ""
                return j
            } else {
                var name = ""
                while j < chars.count, isNameChar(chars[j]) { name.append(chars[j]); j += 1 }
                out += name.isEmpty ? "$" : (env(name) ?? "")
                return j
            }
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "'":
                i += 1
                while i < chars.count, chars[i] != "'" { out.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }
            case "\"":
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count,
                       chars[i + 1] == "\"" || chars[i + 1] == "\\" || chars[i + 1] == "$" {
                        out.append(chars[i + 1]); i += 2
                    } else if chars[i] == "$" {
                        i = expandDollar(i + 1)
                    } else {
                        out.append(chars[i]); i += 1
                    }
                }
                if i < chars.count { i += 1 }
            case "\\":
                if i + 1 < chars.count { out.append(chars[i + 1]); i += 2 } else { i += 1 }
            case "$":
                i = expandDollar(i + 1)
            default:
                out.append(c); i += 1
            }
        }
        return out
    }

    /// Evaluate an integer arithmetic expression (the body of `$(( … ))`).
    /// Supports `+ - * / %`, comparisons (`< <= > >= == !=`), `&& || !`, unary
    /// `-`/`+`, parentheses, integer literals, and variable references (bare
    /// `name`, `$name`, or `$?`), resolved through `env` as integers (unset or
    /// non-numeric ⇒ 0). Division/modulo by zero yields 0. Malformed input
    /// evaluates to 0, matching the shell's lenient arithmetic.
    static func evaluateArithmetic(_ text: String, env: @escaping (String) -> String?, status: Int32) -> Int {
        var parser = ArithmeticParser(chars: Array(text), env: env, status: status)
        return parser.parse()
    }

    /// A tiny recursive-descent integer evaluator for `$(( … ))`.
    struct ArithmeticParser {
        let chars: [Character]
        let env: (String) -> String?
        let status: Int32
        var pos = 0

        mutating func parse() -> Int { let v = parseOr(); return v }

        private mutating func skipSpaces() { while pos < chars.count, chars[pos] == " " || chars[pos] == "\t" { pos += 1 } }

        private mutating func parseOr() -> Int {
            var left = parseAnd()
            while match("||") { let r = parseAnd(); left = (left != 0 || r != 0) ? 1 : 0 }
            return left
        }
        private mutating func parseAnd() -> Int {
            var left = parseCompare()
            while match("&&") { let r = parseCompare(); left = (left != 0 && r != 0) ? 1 : 0 }
            return left
        }
        private mutating func parseCompare() -> Int {
            var left = parseAdditive()
            while true {
                if match("<=") { left = left <= parseAdditive() ? 1 : 0 }
                else if match(">=") { left = left >= parseAdditive() ? 1 : 0 }
                else if match("==") { left = left == parseAdditive() ? 1 : 0 }
                else if match("!=") { left = left != parseAdditive() ? 1 : 0 }
                else if match("<") { left = left < parseAdditive() ? 1 : 0 }
                else if match(">") { left = left > parseAdditive() ? 1 : 0 }
                else { break }
            }
            return left
        }
        private mutating func parseAdditive() -> Int {
            var left = parseMultiplicative()
            while true {
                skipSpaces()
                if match("+") { left += parseMultiplicative() }
                else if match("-") { left -= parseMultiplicative() }
                else { break }
            }
            return left
        }
        private mutating func parseMultiplicative() -> Int {
            var left = parseUnary()
            while true {
                skipSpaces()
                if match("*") { left *= parseUnary() }
                else if match("/") { let r = parseUnary(); left = r == 0 ? 0 : left / r }
                else if match("%") { let r = parseUnary(); left = r == 0 ? 0 : left % r }
                else { break }
            }
            return left
        }
        private mutating func parseUnary() -> Int {
            skipSpaces()
            if match("!") { return parseUnary() == 0 ? 1 : 0 }
            if match("-") { return -parseUnary() }
            if match("+") { return parseUnary() }
            return parsePrimary()
        }
        private mutating func parsePrimary() -> Int {
            skipSpaces()
            guard pos < chars.count else { return 0 }
            if chars[pos] == "(" {
                pos += 1
                let value = parseOr()
                skipSpaces()
                if pos < chars.count, chars[pos] == ")" { pos += 1 }
                return value
            }
            if chars[pos] == "$" {
                pos += 1
                if pos < chars.count, chars[pos] == "?" { pos += 1; return Int(status) }
                return variableValue(readName())
            }
            if chars[pos].isNumber {
                var text = ""
                while pos < chars.count, chars[pos].isNumber { text.append(chars[pos]); pos += 1 }
                return Int(text) ?? 0
            }
            if chars[pos].isLetter || chars[pos] == "_" {
                return variableValue(readName())
            }
            pos += 1   // skip an unexpected character
            return 0
        }
        private mutating func readName() -> String {
            var name = ""
            while pos < chars.count, chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_" {
                name.append(chars[pos]); pos += 1
            }
            return name
        }
        private func variableValue(_ name: String) -> Int {
            guard let raw = env(name) else { return 0 }
            var trimmed = Array(raw)
            while let f = trimmed.first, f == " " || f == "\t" { trimmed.removeFirst() }
            while let l = trimmed.last, l == " " || l == "\t" { trimmed.removeLast() }
            return Int(String(trimmed)) ?? 0
        }
        /// Consume `token` at the current position (after spaces) if it matches.
        private mutating func match(_ token: String) -> Bool {
            skipSpaces()
            let t = Array(token)
            guard pos + t.count <= chars.count else { return false }
            for (offset, character) in t.enumerated() where chars[pos + offset] != character { return false }
            // For single-char operators that are prefixes of others, ensure we
            // don't mis-match (e.g. `<` vs `<=`): callers try the longer first.
            pos += t.count
            return true
        }
    }

    /// Expand a `RawStage` into a runnable `Stage` (argv + redirection targets),
    /// against the current environment/status. Assignment peeling happens later.
    static func expandStage(_ raw: RawStage, env: @escaping (String) -> String?, status: Int32) -> Stage {
        Stage(argv: raw.argv.map { expandWord($0, env: env, status: status) },
              stdinFile: raw.stdinFile.map { expandWord($0, env: env, status: status) },
              stdoutFile: raw.stdoutFile.map { expandWord($0, env: env, status: status) },
              appendOut: raw.appendOut,
              stderrFile: raw.stderrFile.map { expandWord($0, env: env, status: status) },
              appendErr: raw.appendErr,
              stderrToStdout: raw.stderrToStdout,
              stdoutToStderr: raw.stdoutToStderr)
    }

    // MARK: - Command substitution helpers (pure)

    /// The quoting context a `$(…)` occurrence sits in.
    enum SubstitutionContext { case unquoted, doubleQuoted }

    /// The first `$(…)` command substitution in `raw`, split into the text before
    /// it, the inner script, the text after it, and its quoting context — or `nil`
    /// if there is none. `$(( … ))` arithmetic and single-quoted text are skipped;
    /// nested parentheses inside the substitution are balanced.
    static func firstCommandSubstitution(_ raw: String)
        -> (prefix: String, inner: String, suffix: String, context: SubstitutionContext)? {
        let chars = Array(raw)
        var i = 0
        var quote: Character?          // nil, '\'' or '"'
        while i < chars.count {
            let c = chars[i]
            if quote == "'" {
                if c == "'" { quote = nil }
                i += 1; continue
            }
            if c == "\\", quote != "'" { i += 2; continue }        // escaped char
            if c == "'", quote == nil { quote = "'"; i += 1; continue }
            if c == "\"" { quote = (quote == "\"") ? nil : "\""; i += 1; continue }
            if c == "$", i + 1 < chars.count, chars[i + 1] == "(",
               !(i + 2 < chars.count && chars[i + 2] == "(") {      // not $(( arithmetic
                var depth = 1
                var j = i + 2
                var inner = ""
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1 }
                    else if chars[j] == ")" { depth -= 1; if depth == 0 { break } }
                    inner.append(chars[j]); j += 1
                }
                let prefix = String(chars[0..<i])
                let suffix = j < chars.count ? String(chars[(j + 1)...]) : ""
                return (prefix, inner, suffix, quote == "\"" ? .doubleQuoted : .unquoted)
            }
            i += 1
        }
        return nil
    }

    /// Split on whitespace runs (the default field-splitting for unquoted
    /// command-substitution output).
    static func splitFields(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init)
    }

    /// Escape a command-substitution field so later parameter expansion leaves it
    /// literal, while still allowing pathname globbing (glob chars are *not*
    /// escaped, matching bash: unquoted command output is globbed).
    static func escapeSubstitutedField(_ text: String) -> String {
        var out = ""
        for character in text {
            if character == "\\" || character == "$" || character == "`"
                || character == "\"" || character == "'" {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    /// Escape command-substitution output spliced *inside double quotes*: only the
    /// characters double-quote expansion would act on need escaping.
    static func escapeInDoubleQuotes(_ text: String) -> String {
        var out = ""
        for character in text {
            if character == "\\" || character == "$" || character == "\"" || character == "`" {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    /// Escape command-substitution output spliced into an unquoted word with
    /// surrounding text (no field splitting): protect it fully so it stays one
    /// literal field.
    static func escapeInlineUnquoted(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\", "$", "`", "\"", "'", "*", "?", "[", " ", "\t", "\n", "\r":
                out.append("\\"); out.append(character)
            default:
                out.append(character)
            }
        }
        return out
    }

    // MARK: - Glob (pathname expansion)

    /// Expand one raw argv word to its final field(s): parameter/arithmetic
    /// expansion via `expandWord`, then pathname globbing when the *raw* word
    /// carried an unquoted glob metacharacter (`*`, `?`, `[`). A pattern that
    /// matches nothing is left literal (bash's default, nullglob off). `list`
    /// enumerates a directory's entries (names, dirs suffixed with `/`).
    static func expandAndGlob(_ raw: String,
                              env: @escaping (String) -> String?,
                              status: Int32,
                              list: (String) -> [String]?) -> [String] {
        let expanded = expandWord(raw, env: env, status: status)
        guard hasUnquotedGlobCharacter(raw) else { return [expanded] }
        let matches = glob(pattern: expanded, list: list)
        return matches.isEmpty ? [expanded] : matches
    }

    /// Whether `raw` contains a glob metacharacter outside quotes / escapes.
    static func hasUnquotedGlobCharacter(_ raw: String) -> Bool {
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "'":
                i += 1
                while i < chars.count, chars[i] != "'" { i += 1 }
                if i < chars.count { i += 1 }
            case "\"":
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                if i < chars.count { i += 1 }
            case "\\":
                i += 2
            case "*", "?", "[":
                return true
            default:
                i += 1
            }
        }
        return false
    }

    /// Match `pattern` against the filesystem, returning sorted paths. Only the
    /// final path component is a pattern (directory components are literal), so
    /// `*.txt`, `dir/*.c`, and `/etc/*` work; a glob in a middle component does
    /// not. Files beginning with `.` are matched only when the pattern's
    /// component starts with `.`.
    static func glob(pattern: String, list: (String) -> [String]?) -> [String] {
        let hasSlash = pattern.contains("/")
        let directory: String
        let component: String
        if let slash = pattern.lastIndex(of: "/") {
            directory = String(pattern[pattern.startIndex...slash])   // keep trailing '/'
            component = String(pattern[pattern.index(after: slash)...])
        } else {
            directory = ""
            component = pattern
        }
        let listPath = directory.isEmpty ? "." : String(directory.dropLast())   // strip trailing '/'
        guard let entries = list(listPath.isEmpty ? "/" : listPath) else { return [] }

        let patternChars = Array(component)
        let matchesDotFiles = component.first == "."
        var results: [String] = []
        for entry in entries {
            let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            if name.first == ".", !matchesDotFiles { continue }
            if globMatch(patternChars, Array(name)) {
                results.append(hasSlash ? directory + name : name)
            }
        }
        return results.sorted()
    }

    /// Glob matcher for a single name: `*` any run, `?` any one char, `[...]`
    /// a character class (with `^`/`!` negation and `a-z` ranges).
    static func globMatch(_ pattern: [Character], _ name: [Character]) -> Bool {
        func match(_ p: Int, _ n: Int) -> Bool {
            var pi = p, ni = n
            while pi < pattern.count {
                let pc = pattern[pi]
                switch pc {
                case "*":
                    // Collapse consecutive '*'; try to match the rest at every split.
                    while pi < pattern.count, pattern[pi] == "*" { pi += 1 }
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
                    guard ni < name.count, name[ni] == pc else { return false }
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
            if i < pattern.count, pattern[i] == "^" || pattern[i] == "!" { negated = true; i += 1 }
            var matched = false
            var first = true
            while i < pattern.count, pattern[i] != "]" || first {
                first = false
                if i + 2 < pattern.count, pattern[i + 1] == "-", pattern[i + 2] != "]" {
                    if character >= pattern[i], character <= pattern[i + 2] { matched = true }
                    i += 3
                } else {
                    if character == pattern[i] { matched = true }
                    i += 1
                }
            }
            guard i < pattern.count, pattern[i] == "]" else { return nil }   // unterminated
            return (matched != negated, i + 1)
        }

        return match(0, 0)
    }

    // MARK: - Here-documents

    /// A `<<[-]DELIM` here-document header parsed from a command line.
    struct HeredocSpec {
        /// The delimiter word that ends the body (quotes already stripped).
        let delimiter: String
        /// `<<-` strips leading tabs from body lines and the delimiter line.
        let stripTabs: Bool
        /// Whether the body is parameter-expanded (`<<EOF`) or literal
        /// (`<<'EOF'` / `<<"EOF"`).
        let expand: Bool
        /// The exact `<<[-]DELIM` substring, so it can be rewritten in place.
        let operatorText: String
    }

    /// Find the first `<<[-]DELIM` here-doc header on `line` (respecting quotes),
    /// or `nil` if there is none. `<<<` (here-strings) and a bare `<<` with no
    /// delimiter are ignored.
    static func firstHeredocSpec(in line: String) -> HeredocSpec? {
        let chars = Array(line)
        var i = 0
        var quote: Character?
        while i < chars.count {
            let c = chars[i]
            if let q = quote { if c == q { quote = nil }; i += 1; continue }
            if c == "'" || c == "\"" { quote = c; i += 1; continue }
            if c == "\\" { i += 2; continue }
            if c == "<", i + 1 < chars.count, chars[i + 1] == "<",
               !(i + 2 < chars.count && chars[i + 2] == "<") {   // not `<<<`
                var j = i + 2
                var stripTabs = false
                if j < chars.count, chars[j] == "-" { stripTabs = true; j += 1 }
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                var expand = true
                var delimiter = ""
                if j < chars.count, chars[j] == "'" || chars[j] == "\"" {
                    expand = false
                    let q = chars[j]; j += 1
                    while j < chars.count, chars[j] != q { delimiter.append(chars[j]); j += 1 }
                    if j < chars.count { j += 1 }
                } else {
                    while j < chars.count, !" \t\n;|&<>()".contains(chars[j]) {
                        delimiter.append(chars[j]); j += 1
                    }
                }
                guard !delimiter.isEmpty else { i += 2; continue }
                return HeredocSpec(delimiter: delimiter, stripTabs: stripTabs,
                                   expand: expand, operatorText: String(chars[i..<j]))
            }
            i += 1
        }
        return nil
    }

    /// Whether `text` has an *unclosed* here-document (a `<<DELIM` on the first
    /// line whose `DELIM` terminator has not yet appeared on its own line). The
    /// shell keeps reading (secondary prompt) while this is true.
    static func heredocPending(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, let spec = firstHeredocSpec(in: first) else { return false }
        for index in 1..<max(1, lines.count) {
            let raw = lines[index]
            let candidate = spec.stripTabs ? String(raw.drop(while: { $0 == "\t" })) : raw
            if candidate == spec.delimiter { return false }
        }
        return true
    }

    /// Parameter-expand a here-document body: substitute `$VAR` / `${VAR}` / `$?`
    /// / `$#`/`$@`/`$*` and `$(( … ))`, but treat quotes and other characters as
    /// literal (a here-doc body is not a quoted word). `\$` yields a literal `$`.
    static func expandHeredocBody(_ text: String, env: @escaping (String) -> String?, status: Int32) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        func isNameChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                out.append("$"); i += 2; continue
            }
            guard c == "$", i + 1 < chars.count else { out.append(c); i += 1; continue }
            var j = i + 1
            if chars[j] == "(", j + 1 < chars.count, chars[j + 1] == "(" {   // $(( … ))
                j += 2; var depth = 1; var expr = ""
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1; expr.append(chars[j]); j += 1 }
                    else if chars[j] == ")" {
                        depth -= 1
                        if depth == 0 { if j + 1 < chars.count, chars[j + 1] == ")" { j += 2 } else { j += 1 }; break }
                        expr.append(chars[j]); j += 1
                    } else { expr.append(chars[j]); j += 1 }
                }
                out += String(evaluateArithmetic(expr, env: env, status: status)); i = j
            } else if chars[j] == "?" {
                out += String(status); i = j + 1
            } else if chars[j] == "#" || chars[j] == "@" || chars[j] == "*" {
                out += env(String(chars[j])) ?? ""; i = j + 1
            } else if chars[j] == "{" {
                j += 1; var name = ""
                while j < chars.count, chars[j] != "}" { name.append(chars[j]); j += 1 }
                if j < chars.count { j += 1 }
                out += env(name) ?? ""; i = j
            } else if isNameChar(chars[j]) {
                var name = ""
                while j < chars.count, isNameChar(chars[j]) { name.append(chars[j]); j += 1 }
                out += env(name) ?? ""; i = j
            } else {
                out.append(c); i += 1                       // lone `$`
            }
        }
        return out
    }

    /// Replace the first occurrence of `needle` in `haystack` with `replacement`
    /// (standard library only; used to rewrite a here-doc operator in place).
    static func replaceFirstOccurrence(in haystack: String, of needle: String, with replacement: String) -> String {
        let h = Array(haystack), n = Array(needle)
        guard !n.isEmpty, h.count >= n.count else { return haystack }
        var i = 0
        while i + n.count <= h.count {
            if Array(h[i..<i + n.count]) == n {
                return String(h[0..<i]) + replacement + String(h[(i + n.count)...])
            }
            i += 1
        }
        return haystack
    }

}
