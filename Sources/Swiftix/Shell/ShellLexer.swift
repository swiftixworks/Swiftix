/// The shell structural lexer: split a command line into tokens (words,
/// operators, redirects, reserved words), plus the multi-line completeness check
/// that decides whether more input is needed (open block / dangling connector).
extension Programs {

    // MARK: - Structural lexer

    /// Reserved words recognized at command position.
    static let reservedWords: Set<String> =
        ["if", "then", "else", "fi", "while", "for", "do", "done", "case", "in", "esac"]

    /// Split `line` into structural tokens, tracking quote state so quoted
    /// whitespace/metacharacters stay inside a word. Words keep their raw text.
    static func lex(_ line: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(line)
        var i = 0
        var current = ""
        var started = false

        func flush() {
            if started { tokens.append(.word(current)); current = ""; started = false }
        }

        /// If the pending word is a bare file-descriptor number immediately
        /// before a redirection operator (e.g. the `2` in `2>&1`), consume it as
        /// the fd and return it; otherwise flush the word and use `defaultFd`.
        func takeRedirectFd(default defaultFd: Int) -> Int {
            if started, !current.isEmpty, current.allSatisfy({ $0.isNumber }), let fd = Int(current) {
                current = ""; started = false
                return fd
            }
            flush()
            return defaultFd
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t", "\r":
                flush(); i += 1
            case "\n":
                flush(); tokens.append(.semicolon); i += 1
            case ";":
                flush()
                if i + 1 < chars.count, chars[i + 1] == ";" { tokens.append(.doubleSemicolon); i += 2 }
                else { tokens.append(.semicolon); i += 1 }
            case "(":
                flush(); tokens.append(.lparen); i += 1
            case ")":
                flush(); tokens.append(.rparen); i += 1
            case "|":
                flush()
                if i + 1 < chars.count, chars[i + 1] == "|" { tokens.append(.or); i += 2 }
                else { tokens.append(.pipe); i += 1 }
            case "&":
                flush()
                if i + 1 < chars.count, chars[i + 1] == "&" { tokens.append(.and); i += 2 }
                else { tokens.append(.background); i += 1 }
            case "<":
                let fd = takeRedirectFd(default: 0)
                tokens.append(.redirectInput(fd: fd)); i += 1
            case ">":
                let fd = takeRedirectFd(default: 1)
                if i + 1 < chars.count, chars[i + 1] == "&" {
                    // `N>&M` — duplicate descriptor. Read the target fd digits.
                    i += 2
                    var target = ""
                    while i < chars.count, chars[i].isNumber { target.append(chars[i]); i += 1 }
                    tokens.append(.redirectDup(fromFd: fd, toFd: Int(target) ?? 1))
                } else if i + 1 < chars.count, chars[i + 1] == ">" {
                    tokens.append(.redirectFile(fd: fd, append: true)); i += 2
                } else {
                    tokens.append(.redirectFile(fd: fd, append: false)); i += 1
                }
            case "'":
                started = true
                current.append(c); i += 1
                while i < chars.count, chars[i] != "'" { current.append(chars[i]); i += 1 }
                if i < chars.count { current.append(chars[i]); i += 1 }   // closing '
            case "\"":
                started = true
                current.append(c); i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        current.append(chars[i]); current.append(chars[i + 1]); i += 2
                    } else {
                        current.append(chars[i]); i += 1
                    }
                }
                if i < chars.count { current.append(chars[i]); i += 1 }   // closing "
            case "\\":
                started = true
                current.append(c)
                if i + 1 < chars.count { current.append(chars[i + 1]); i += 2 } else { i += 1 }
            case "$":
                // Keep `$( … )` / `$(( … ))` / `${ … }` as one word unit so their
                // internal spaces and metacharacters (`* | ; + …`) are not split
                // off as separate tokens — the expansion phase handles them.
                started = true
                current.append(c); i += 1
                if i < chars.count, chars[i] == "(" {
                    current.append(chars[i]); i += 1        // first '('
                    var depth = 1
                    while i < chars.count, depth > 0 {
                        if chars[i] == "(" { depth += 1 }
                        else if chars[i] == ")" { depth -= 1 }
                        current.append(chars[i]); i += 1
                    }
                } else if i < chars.count, chars[i] == "{" {
                    current.append(chars[i]); i += 1
                    while i < chars.count, chars[i] != "}" { current.append(chars[i]); i += 1 }
                    if i < chars.count { current.append(chars[i]); i += 1 }   // closing '}'
                }
            default:
                started = true
                current.append(c); i += 1
            }
        }
        flush()
        return tokens
    }


    // MARK: - Completeness (multi-line continuation)

    /// Whether `line` forms a complete command, or the shell should keep reading
    /// (secondary prompt). Incomplete when an `if`/`while` is unclosed, a
    /// here-document is still open, or the input ends on a binary operator
    /// awaiting its right-hand side.
    static func isComplete(_ line: String) -> Bool {
        if heredocPending(line) { return false }
        let tokens = lex(line)
        var depth = 0
        for token in tokens {
            if case let .word(w) = token {
                if w == "if" || w == "while" || w == "for" || w == "case" { depth += 1 }
                else if w == "fi" || w == "done" || w == "esac" { depth = max(0, depth - 1) }
                else if w == "{" { depth += 1 }        // function-body open
                else if w == "}" { depth = max(0, depth - 1) }
            }
        }
        if depth > 0 { return false }
        switch tokens.last {
        case .and, .or, .pipe: return false   // dangling operator: needs more
        default: return true
        }
    }

}
