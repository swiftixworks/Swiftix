/// The shell structural lexer: split script text into tokens (words, operators,
/// redirections, here-documents), plus the multi-line completeness check that
/// decides whether an interactive shell needs more input. Pure functions.
extension Programs {

    // MARK: - Nested-construct scanning

    /// Skip helpers for quoted and `$`-introduced constructs. Each takes the
    /// index just past the opening delimiter and returns the index just past the
    /// closing one, or `chars.count + 1` when the construct is unterminated.
    enum ShellScanner {
        static func afterSingleQuote(_ c: [Character], _ start: Int) -> Int {
            var j = start
            while j < c.count {
                if c[j] == "'" { return j + 1 }
                j += 1
            }
            return c.count + 1
        }

        /// `$'…'`: like single quotes, but a backslash escapes the next char.
        static func afterAnsiQuote(_ c: [Character], _ start: Int) -> Int {
            var j = start
            while j < c.count {
                if c[j] == "\\" { j += 2; continue }
                if c[j] == "'" { return j + 1 }
                j += 1
            }
            return c.count + 1
        }

        static func afterDoubleQuote(_ c: [Character], _ start: Int) -> Int {
            var j = start
            while j < c.count {
                switch c[j] {
                case "\\": j += 2
                case "\"": return j + 1
                case "$": j = afterDollar(c, j)
                case "`": j = afterBacktick(c, j + 1)
                default: j += 1
                }
            }
            return c.count + 1
        }

        static func afterBacktick(_ c: [Character], _ start: Int) -> Int {
            var j = start
            while j < c.count {
                if c[j] == "\\" { j += 2; continue }
                if c[j] == "`" { return j + 1 }
                j += 1
            }
            return c.count + 1
        }

        /// Balanced `( … )`, honoring quotes and nested substitutions.
        static func afterParen(_ c: [Character], _ start: Int) -> Int {
            var j = start
            var depth = 1
            while j < c.count {
                switch c[j] {
                case "\\": j += 2
                case "'": j = afterSingleQuote(c, j + 1)
                case "\"": j = afterDoubleQuote(c, j + 1)
                case "`": j = afterBacktick(c, j + 1)
                case "(": depth += 1; j += 1
                case ")":
                    depth -= 1
                    if depth == 0 { return j + 1 }
                    j += 1
                case "$":
                    if j + 1 < c.count, c[j + 1] == "{" { j = afterBrace(c, j + 2) } else { j += 1 }
                default: j += 1
                }
            }
            return c.count + 1
        }

        /// `${ … }`, honoring double quotes and nested substitutions.
        static func afterBrace(_ c: [Character], _ start: Int) -> Int {
            var j = start
            while j < c.count {
                switch c[j] {
                case "\\": j += 2
                case "\"": j = afterDoubleQuote(c, j + 1)
                case "`": j = afterBacktick(c, j + 1)
                case "$": j = afterDollar(c, j)
                case "}": return j + 1
                default: j += 1
                }
            }
            return c.count + 1
        }

        /// `c[start] == "$"`: the index past a `$( … )` / `${ … }` construct, or
        /// `start + 1` for any other `$`.
        static func afterDollar(_ c: [Character], _ start: Int) -> Int {
            guard start + 1 < c.count else { return start + 1 }
            if c[start + 1] == "(" { return afterParen(c, start + 2) }
            if c[start + 1] == "{" { return afterBrace(c, start + 2) }
            return start + 1
        }
    }

    // MARK: - Structural lexer

    /// Reserved words recognized at command position.
    static let reservedWords: Set<String> =
        ["if", "then", "else", "elif", "fi", "while", "until", "for", "do", "done",
         "case", "in", "esac", "{", "}", "!", "function"]

    /// The token stream plus what the lexer saw left open at the end of input.
    struct LexResult {
        var tokens: [Token] = []
        /// A `<<DELIM` body whose terminator line never appeared.
        var unterminatedHeredoc = false
        /// An unclosed quote / `$( … )` / `${ … }` / backtick.
        var unterminatedQuote = false
        /// The input ends in a backslash-newline (or lone trailing backslash).
        var danglingContinuation = false
    }

    /// Split `line` into structural tokens.
    static func lex(_ line: String) -> [Token] {
        lexDetailed(line).tokens
    }

    /// Split `text` into structural tokens, tracking quote state so quoted
    /// whitespace/metacharacters stay inside a word. Words keep their raw text.
    /// Comments are dropped, backslash-newline joins lines, and here-document
    /// bodies are collected into their operator token.
    static func lexDetailed(_ text: String) -> LexResult {
        var result = LexResult()
        let chars = Array(text)
        var i = 0
        var current = ""
        var started = false
        struct PendingHeredoc {
            let tokenIndex: Int
            let fd: Int
            let delimiter: String
            let stripTabs: Bool
            let expand: Bool
        }
        var pending: [PendingHeredoc] = []

        func flush() {
            if started { result.tokens.append(.word(current)); current = ""; started = false }
        }

        /// If the pending word is a bare file-descriptor number immediately
        /// before a redirection operator (e.g. the `2` in `2>&1`), consume it as
        /// the fd and return it; otherwise flush the word and use `defaultFd`.
        func takeRedirectFd(default defaultFd: Int) -> Int {
            if started, !current.isEmpty, current.allSatisfy({ $0.isASCII && $0.isNumber }),
               let fd = Int(current) {
                current = ""; started = false
                return fd
            }
            flush()
            return defaultFd
        }

        /// Append `chars[i..<end]` to the current word, clamping an unterminated
        /// construct to the end of input.
        func take(upTo rawEnd: Int) {
            if rawEnd > chars.count { result.unterminatedQuote = true }
            let end = Swift.min(rawEnd, chars.count)
            started = true
            current.append(contentsOf: chars[i..<end])
            i = end
        }

        /// Read the bodies of every here-document announced on the line just
        /// ended; `i` is positioned at the start of the next line.
        func collectHeredocs() {
            for doc in pending {
                var body = ""
                var closed = false
                while i < chars.count {
                    var lineEnd = i
                    while lineEnd < chars.count, chars[lineEnd] != "\n" { lineEnd += 1 }
                    let rawLine = String(chars[i..<lineEnd])
                    i = lineEnd < chars.count ? lineEnd + 1 : lineEnd
                    let candidate = doc.stripTabs ? String(rawLine.drop(while: { $0 == "\t" })) : rawLine
                    if candidate == doc.delimiter { closed = true; break }
                    body += candidate + "\n"
                }
                if !closed { result.unterminatedHeredoc = true }
                result.tokens[doc.tokenIndex] = .hereDocument(fd: doc.fd, body: body, expand: doc.expand)
            }
            pending.removeAll()
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t", "\r":
                flush(); i += 1
            case "\n":
                flush(); result.tokens.append(.semicolon); i += 1
                if !pending.isEmpty { collectHeredocs() }
            case "#":
                if started {
                    current.append(c); i += 1
                } else {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                }
            case ";":
                flush()
                if i + 1 < chars.count, chars[i + 1] == ";" { result.tokens.append(.doubleSemicolon); i += 2 }
                else { result.tokens.append(.semicolon); i += 1 }
            case "(":
                flush(); result.tokens.append(.lparen); i += 1
            case ")":
                flush(); result.tokens.append(.rparen); i += 1
            case "|":
                flush()
                if i + 1 < chars.count, chars[i + 1] == "|" { result.tokens.append(.or); i += 2 }
                else { result.tokens.append(.pipe); i += 1 }
            case "&":
                flush()
                if i + 1 < chars.count, chars[i + 1] == "&" { result.tokens.append(.and); i += 2 }
                else { result.tokens.append(.background); i += 1 }
            case "<":
                let fd = takeRedirectFd(default: 0)
                if i + 2 < chars.count, chars[i + 1] == "<", chars[i + 2] == "<" {
                    result.tokens.append(.hereString(fd: fd)); i += 3
                } else if i + 1 < chars.count, chars[i + 1] == "<" {
                    i += 2
                    var stripTabs = false
                    if i < chars.count, chars[i] == "-" { stripTabs = true; i += 1 }
                    while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
                    var delimiter = ""
                    var quoted = false
                    scan: while i < chars.count {
                        switch chars[i] {
                        case " ", "\t", "\n", ";", "|", "&", "<", ">", "(", ")":
                            break scan
                        case "'", "\"":
                            quoted = true
                            let q = chars[i]; i += 1
                            while i < chars.count, chars[i] != q { delimiter.append(chars[i]); i += 1 }
                            if i < chars.count { i += 1 }
                        case "\\":
                            quoted = true
                            if i + 1 < chars.count { delimiter.append(chars[i + 1]) }
                            i += 2
                        default:
                            delimiter.append(chars[i]); i += 1
                        }
                    }
                    i = Swift.min(i, chars.count)
                    pending.append(PendingHeredoc(tokenIndex: result.tokens.count, fd: fd,
                                                  delimiter: delimiter, stripTabs: stripTabs,
                                                  expand: !quoted))
                    result.tokens.append(.hereDocument(fd: fd, body: "", expand: !quoted))
                } else if i + 1 < chars.count, chars[i + 1] == "&" {
                    i += 2
                    var target = ""
                    while i < chars.count, chars[i].isASCII, chars[i].isNumber { target.append(chars[i]); i += 1 }
                    if target.isEmpty, i < chars.count, chars[i] == "-" {
                        i += 1
                        result.tokens.append(.redirectDup(fromFd: fd, toFd: -1))
                    } else {
                        result.tokens.append(.redirectDup(fromFd: fd, toFd: Int(target) ?? 0))
                    }
                } else {
                    result.tokens.append(.redirectInput(fd: fd)); i += 1
                }
            case ">":
                let fd = takeRedirectFd(default: 1)
                if i + 1 < chars.count, chars[i + 1] == "&" {
                    // `N>&M` — duplicate descriptor. Read the target fd digits.
                    i += 2
                    var target = ""
                    while i < chars.count, chars[i].isASCII, chars[i].isNumber { target.append(chars[i]); i += 1 }
                    if target.isEmpty, i < chars.count, chars[i] == "-" {
                        i += 1
                        result.tokens.append(.redirectDup(fromFd: fd, toFd: -1))
                    } else {
                        result.tokens.append(.redirectDup(fromFd: fd, toFd: Int(target) ?? 1))
                    }
                } else if i + 1 < chars.count, chars[i + 1] == ">" {
                    result.tokens.append(.redirectFile(fd: fd, append: true)); i += 2
                } else if i + 1 < chars.count, chars[i + 1] == "|" {
                    result.tokens.append(.redirectFile(fd: fd, append: false)); i += 2
                } else {
                    result.tokens.append(.redirectFile(fd: fd, append: false)); i += 1
                }
            case "'":
                take(upTo: ShellScanner.afterSingleQuote(chars, i + 1))
            case "\"":
                take(upTo: ShellScanner.afterDoubleQuote(chars, i + 1))
            case "`":
                take(upTo: ShellScanner.afterBacktick(chars, i + 1))
            case "\\":
                if i + 1 < chars.count, chars[i + 1] == "\n" {
                    i += 2                                  // line continuation
                    if i >= chars.count { result.danglingContinuation = true }
                } else if i + 1 < chars.count {
                    started = true
                    current.append(c); current.append(chars[i + 1]); i += 2
                } else {
                    result.danglingContinuation = true
                    i += 1
                }
            case "$":
                // Keep `$( … )` / `$(( … ))` / `${ … }` / `$'…'` as one word unit
                // so their internal spaces and metacharacters are not split off
                // as separate tokens — the expansion phase handles them.
                if i + 1 < chars.count, chars[i + 1] == "'" {
                    take(upTo: ShellScanner.afterAnsiQuote(chars, i + 2))
                } else {
                    take(upTo: ShellScanner.afterDollar(chars, i))
                }
            default:
                started = true
                current.append(c); i += 1
            }
        }
        flush()
        if !pending.isEmpty {
            // The header line was never ended: the body is still to come.
            result.unterminatedHeredoc = true
        }
        return result
    }


    // MARK: - Completeness (multi-line continuation)

    /// Whether `line` forms a complete command, or the shell should keep reading
    /// (secondary prompt). Incomplete when a compound command, group, subshell,
    /// quote, or here-document is still open, or the input ends on a binary
    /// operator / line continuation awaiting its right-hand side.
    static func isComplete(_ line: String) -> Bool {
        let lexed = lexDetailed(line)
        if lexed.unterminatedHeredoc || lexed.unterminatedQuote || lexed.danglingContinuation {
            return false
        }
        let tokens = lexed.tokens
        var depth = 0
        var parens = 0
        var commandPosition = true
        var forHeaderWords = -1        // >= 0 while inside a `for NAME in …` header
        var caseHeaderWords = 0        // words still to skip after `case`
        for token in tokens {
            switch token {
            case let .word(w):
                if forHeaderWords >= 0 {
                    if w == "do", forHeaderWords == 1 {
                        forHeaderWords = -1; commandPosition = true
                    } else {
                        forHeaderWords += 1
                    }
                    continue
                }
                if caseHeaderWords > 0 {
                    caseHeaderWords -= 1
                    if caseHeaderWords == 0 { commandPosition = true }
                    continue
                }
                guard commandPosition else { continue }
                switch w {
                case "if", "while", "until":
                    depth += 1
                case "for":
                    depth += 1; forHeaderWords = 0; commandPosition = false
                case "case":
                    depth += 1; caseHeaderWords = 2; commandPosition = false
                case "{":
                    depth += 1
                case "fi", "done", "esac", "}":
                    depth = max(0, depth - 1); commandPosition = false
                case "then", "else", "elif", "do", "!":
                    break
                default:
                    commandPosition = false
                }
            case .semicolon:
                if forHeaderWords >= 0 { forHeaderWords = -1 }
                commandPosition = true
            case .doubleSemicolon, .and, .or, .pipe, .background:
                commandPosition = true
            case .lparen:
                parens += 1
                commandPosition = true
            case .rparen:
                parens = max(0, parens - 1)
                commandPosition = true
            default:
                break
            }
        }
        if depth > 0 || parens > 0 { return false }
        // A dangling operator (ignoring the newline that ended the line) needs
        // its right-hand side.
        switch tokens.last(where: { $0 != .semicolon }) {
        case .and, .or, .pipe: return false
        default: return true
        }
    }

}
