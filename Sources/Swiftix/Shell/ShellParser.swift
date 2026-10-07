/// The shell parser: turn a token stream into the AST (statements, pipelines,
/// if/while/until/for/case, groups, subshells, functions, redirections). Pure
/// value-type recursive descent; alias substitution is the only external input.
extension Programs {

    // MARK: - Parser

    /// Parse a complete token stream into a list of statements, or `nil` on a
    /// syntax error.
    static func parseScript(_ tokens: [Token],
                            alias: ((String) -> String?)? = nil) -> [ScriptStatement]? {
        var parser = ScriptParser(tokens: tokens, alias: alias)
        guard let list = parser.parseList(terminators: []) else { return nil }
        return parser.atEnd ? list : nil
    }

    /// Recursive-descent parser over the structural tokens.
    struct ScriptParser {
        var tokens: [Token]
        var pos = 0
        /// Alias lookup applied to the first word of each command.
        var alias: ((String) -> String?)?
        /// Alias names already substituted at a token index (stops recursion).
        private var expandedAliases: [Int: Set<String>] = [:]

        init(tokens: [Token], alias: ((String) -> String?)? = nil) {
            self.tokens = tokens
            self.alias = alias
        }

        var atEnd: Bool { pos >= tokens.count }

        /// One step of incremental (statement-at-a-time) parsing.
        enum Step {
            case statement(ScriptStatement)
            case end
            case syntaxError
        }

        /// Parse the next top-level statement. Lets a script run each command
        /// before the next is parsed, so aliases defined earlier apply and a
        /// late syntax error does not stop the commands before it.
        mutating func parseNext() -> Step {
            skipSeparators()
            if atEnd { return .end }
            guard let statement = parseStatement() else { return .syntaxError }
            if !statement.background, !atEnd, tokens[pos] != .semicolon { return .syntaxError }
            return .statement(statement)
        }

        private func peekWord() -> String? {
            guard pos < tokens.count, case let .word(w) = tokens[pos] else { return nil }
            return w
        }

        private mutating func skipSeparators() {
            while pos < tokens.count, tokens[pos] == .semicolon { pos += 1 }
        }

        @discardableResult
        private mutating func expectWord(_ word: String) -> Bool {
            guard peekWord() == word else { return false }
            pos += 1
            return true
        }

        /// Parse a statement list, stopping (without consuming) at end, at `)`,
        /// at `;;`, or at a reserved terminator word (e.g. `then`, `fi`).
        mutating func parseList(terminators: Set<String>) -> [ScriptStatement]? {
            var statements: [ScriptStatement] = []
            skipSeparators()
            while pos < tokens.count {
                if tokens[pos] == .doubleSemicolon || tokens[pos] == .rparen { break }
                if let w = peekWord(), terminators.contains(w) { break }
                guard let statement = parseStatement() else { return nil }
                statements.append(statement)
                if pos >= tokens.count { break }
                if tokens[pos] == .semicolon {
                    skipSeparators()
                } else if statement.background {
                    continue                    // `a & b`: `&` is itself a separator
                } else if tokens[pos] == .doubleSemicolon || tokens[pos] == .rparen {
                    break
                } else if let w = peekWord(), terminators.contains(w) {
                    break
                } else {
                    return nil   // two statements without a separator
                }
            }
            return statements
        }

        private mutating func parseStatement() -> ScriptStatement? {
            guard let first = parsePipeline() else { return nil }
            var rest: [(connector: Connector, command: ScriptCommand)] = []
            while pos < tokens.count, tokens[pos] == .and || tokens[pos] == .or {
                let connector: Connector = tokens[pos] == .and ? .and : .or
                pos += 1
                skipSeparators()                 // a newline may follow `&&` / `||`
                guard let command = parsePipeline() else { return nil }
                rest.append((connector, command))
            }
            var background = false
            if pos < tokens.count, tokens[pos] == .background { background = true; pos += 1 }
            return ScriptStatement(first: first, rest: rest, background: background)
        }

        private mutating func parsePipeline() -> ScriptCommand? {
            var negated = false
            while peekWord() == "!" { negated.toggle(); pos += 1 }
            guard let first = parseCommand() else { return nil }
            var commands = [first]
            while pos < tokens.count, tokens[pos] == .pipe {
                pos += 1
                skipSeparators()                 // a newline may follow `|`
                guard let next = parseCommand() else { return nil }
                commands.append(next)
            }
            if commands.count == 1, !negated { return first }
            return .pipeline(commands, negated: negated)
        }

        /// Replace an alias name at the cursor with its (lexed) value.
        private mutating func substituteAlias() {
            guard let alias else { return }
            while case let .word(w)? = tokens[safe: pos],
                  !(expandedAliases[pos]?.contains(w) ?? false),
                  let value = alias(w) {
                var seen = expandedAliases[pos] ?? []
                seen.insert(w)
                tokens.replaceSubrange(pos...pos, with: lex(value))
                expandedAliases[pos] = seen
            }
        }

        private mutating func parseCommand() -> ScriptCommand? {
            substituteAlias()
            let compound: ScriptCommand?
            if tokens[safe: pos] == .lparen {
                compound = parseSubshell()
            } else if isFunctionDefinitionAhead() {
                compound = parseFunctionDef()
            } else {
                switch peekWord() {
                case "if":    compound = parseIf()
                case "while": compound = parseWhile(until: false)
                case "until": compound = parseWhile(until: true)
                case "for":   compound = parseFor()
                case "case":  compound = parseCase()
                case "{":     compound = parseGroup()
                case "function":
                    if case .word? = tokens[safe: pos + 1] {
                        pos += 1
                        compound = parseFunctionDef()
                    } else {
                        return parseSimple()
                    }
                case "then", "else", "elif", "fi", "do", "done", "esac", "}":
                    return nil                   // reserved word out of place
                default:
                    return parseSimple()         // handles its own redirections
                }
            }
            guard let command = compound else { return nil }
            // A compound command may carry trailing redirections applied to the
            // whole block (`for … done > file`, `if … fi 2>&1`).
            var redirections: [Redirection] = []
            while true {
                switch parseRedirection() {
                case .none: return redirections.isEmpty ? command : .redirected(command, redirections)
                case .invalid: return nil
                case let .parsed(redirection): redirections.append(redirection)
                }
            }
        }

        private enum RedirectionStep {
            case none
            case invalid
            case parsed(Redirection)
        }

        /// Parse one redirection at the cursor, if there is one.
        private mutating func parseRedirection() -> RedirectionStep {
            guard pos < tokens.count else { return .none }
            switch tokens[pos] {
            case let .redirectInput(fd):
                guard case let .word(w)? = tokens[safe: pos + 1] else { return .invalid }
                pos += 2
                return .parsed(Redirection(fd: fd, kind: .input(w)))
            case let .redirectFile(fd, append):
                guard case let .word(w)? = tokens[safe: pos + 1] else { return .invalid }
                pos += 2
                return .parsed(Redirection(fd: fd, kind: .output(w, append: append)))
            case let .redirectDup(fromFd, toFd):
                pos += 1
                return .parsed(Redirection(fd: fromFd, kind: toFd < 0 ? .close : .duplicate(toFd)))
            case let .hereDocument(fd, body, expand):
                pos += 1
                return .parsed(Redirection(fd: fd, kind: .hereDocument(body: body, expand: expand)))
            case let .hereString(fd):
                guard case let .word(w)? = tokens[safe: pos + 1] else { return .invalid }
                pos += 2
                return .parsed(Redirection(fd: fd, kind: .hereString(w)))
            default:
                return .none
            }
        }

        private mutating func parseSimple() -> ScriptCommand? {
            var stage = RawStage()
            while pos < tokens.count {
                if case let .word(w) = tokens[pos] {
                    stage.argv.append(w); pos += 1
                    continue
                }
                switch parseRedirection() {
                case .none:
                    return stage.argv.isEmpty && stage.redirections.isEmpty ? nil : .simple(stage)
                case .invalid:
                    return nil
                case let .parsed(redirection):
                    stage.redirections.append(redirection)
                }
            }
            return stage.argv.isEmpty && stage.redirections.isEmpty ? nil : .simple(stage)
        }

        private mutating func parseSubshell() -> ScriptCommand? {
            guard tokens[safe: pos] == .lparen else { return nil }
            pos += 1
            guard let body = parseList(terminators: []), tokens[safe: pos] == .rparen else { return nil }
            pos += 1
            return .subshell(body)
        }

        private mutating func parseGroup() -> ScriptCommand? {
            guard expectWord("{"),
                  let body = parseList(terminators: ["}"]), expectWord("}") else { return nil }
            return .group(body)
        }

        private mutating func parseFor() -> ScriptCommand? {
            guard expectWord("for"), let name = peekWord(), Self.isValidFunctionName(name) else { return nil }
            pos += 1                                   // consume the loop variable
            var words: [String]?
            if tokens[safe: pos] == .semicolon, peekWordAfterSeparators() == "in" { skipSeparators() }
            if expectWord("in") {
                // Collect the raw word list up to a separator or `do`.
                var list: [String] = []
                collect: while pos < tokens.count {
                    switch tokens[pos] {
                    case let .word(w):
                        if w == "do" { break collect }     // `do` ends the list
                        list.append(w); pos += 1
                    default:
                        break collect                       // ';'/newline/operator ends it
                    }
                }
                words = list
            }
            skipSeparators()
            guard expectWord("do"),
                  let body = parseList(terminators: ["done"]), expectWord("done") else { return nil }
            return .forClause(variable: name, words: words, body: body)
        }

        private func peekWordAfterSeparators() -> String? {
            var index = pos
            while index < tokens.count, tokens[index] == .semicolon { index += 1 }
            guard case let .word(w)? = tokens[safe: index] else { return nil }
            return w
        }

        /// Whether the tokens at the cursor form a function definition header
        /// `NAME ( )`.
        private func isFunctionDefinitionAhead() -> Bool {
            guard case let .word(name)? = tokens[safe: pos], Self.isValidFunctionName(name),
                  tokens[safe: pos + 1] == .lparen, tokens[safe: pos + 2] == .rparen else { return false }
            return true
        }

        /// A valid function name: an identifier (letter/`_` then letters/digits/`_`).
        static func isValidFunctionName(_ name: String) -> Bool {
            guard let first = name.first, first.isLetter || first == "_" else { return false }
            return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }

        /// `NAME [( )] COMPOUND` — the cursor is on NAME.
        private mutating func parseFunctionDef() -> ScriptCommand? {
            guard case let .word(name)? = tokens[safe: pos], Self.isValidFunctionName(name) else { return nil }
            pos += 1
            if tokens[safe: pos] == .lparen {
                pos += 1
                guard tokens[safe: pos] == .rparen else { return nil }
                pos += 1
            }
            skipSeparators()                                   // allow newline(s) before `{`
            guard peekWord() == "{" || tokens[safe: pos] == .lparen,
                  let body = parseCommand() else { return nil }
            if case let .group(list) = body { return .functionDef(name: name, body: list) }
            return .functionDef(name: name,
                                body: [ScriptStatement(first: body, rest: [], background: false)])
        }

        private mutating func parseCase() -> ScriptCommand? {
            guard expectWord("case"), case let .word(subject)? = tokens[safe: pos] else { return nil }
            pos += 1                                           // the subject word
            skipSeparators()
            guard expectWord("in") else { return nil }
            skipSeparators()
            var clauses: [CaseClause] = []
            while pos < tokens.count, peekWord() != "esac" {
                if tokens[safe: pos] == .lparen { pos += 1 }   // optional leading `(`
                // Alternative patterns: `pat` (`|` `pat`)* `)`.
                var patterns: [String] = []
                guard case let .word(first)? = tokens[safe: pos] else { return nil }
                patterns.append(first); pos += 1
                while tokens[safe: pos] == .pipe {
                    pos += 1
                    guard case let .word(alt)? = tokens[safe: pos] else { return nil }
                    patterns.append(alt); pos += 1
                }
                guard tokens[safe: pos] == .rparen else { return nil }; pos += 1
                skipSeparators()
                guard let body = parseList(terminators: ["esac"]) else { return nil }
                clauses.append(CaseClause(patterns: patterns, body: body))
                if tokens[safe: pos] == .doubleSemicolon { pos += 1 }
                skipSeparators()
            }
            guard expectWord("esac") else { return nil }
            return .caseClause(subject: subject, clauses: clauses)
        }

        /// `if … then … [elif … then …]* [else …] fi`; the cursor is on `if` (or
        /// on `elif`, which parses as a nested `if` sharing the closing `fi`).
        private mutating func parseIf() -> ScriptCommand? {
            pos += 1                                           // `if` / `elif`
            guard let cond = parseList(terminators: ["then"]), !cond.isEmpty, expectWord("then"),
                  let then = parseList(terminators: ["else", "elif", "fi"]) else { return nil }
            var els: [ScriptStatement] = []
            if peekWord() == "elif" {
                guard let nested = parseIf() else { return nil }
                return .ifClause(cond: cond, then: then,
                                 els: [ScriptStatement(first: nested, rest: [], background: false)])
            }
            if peekWord() == "else" {
                pos += 1
                guard let e = parseList(terminators: ["fi"]) else { return nil }
                els = e
            }
            guard expectWord("fi") else { return nil }
            return .ifClause(cond: cond, then: then, els: els)
        }

        private mutating func parseWhile(until: Bool) -> ScriptCommand? {
            pos += 1                                           // `while` / `until`
            guard let cond = parseList(terminators: ["do"]), !cond.isEmpty, expectWord("do"),
                  let body = parseList(terminators: ["done"]), expectWord("done") else { return nil }
            return .whileClause(cond: cond, body: body, until: until)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
