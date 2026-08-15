/// The shell parser: turn a token stream into the AST (statements, pipelines,
/// if/while/for/case, functions, redirects).
extension Programs {

    // MARK: - Parser

    /// Parse a complete token stream into a list of statements, or `nil` on a
    /// syntax error.
    static func parseScript(_ tokens: [Token]) -> [ScriptStatement]? {
        var parser = ScriptParser(tokens: tokens)
        guard let list = parser.parseList(terminators: []) else { return nil }
        return parser.atEnd ? list : nil
    }

    /// Recursive-descent parser over the structural tokens.
    struct ScriptParser {
        let tokens: [Token]
        var pos = 0

        var atEnd: Bool { pos >= tokens.count }

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

        /// Parse a statement list, stopping (without consuming) at end or at a
        /// reserved terminator word (e.g. `then`, `fi`).
        mutating func parseList(terminators: Set<String>) -> [ScriptStatement]? {
            var statements: [ScriptStatement] = []
            skipSeparators()
            while pos < tokens.count {
                if tokens[pos] == .doubleSemicolon { break }   // `;;` ends a case clause
                if let w = peekWord(), terminators.contains(w) { break }
                guard let statement = parseStatement(terminators: terminators) else { return nil }
                statements.append(statement)
                if pos < tokens.count, tokens[pos] == .semicolon {
                    skipSeparators()
                } else if pos >= tokens.count {
                    break
                } else if tokens[pos] == .doubleSemicolon {
                    break   // leave `;;` for the case parser to consume
                } else if let w = peekWord(), terminators.contains(w) {
                    break
                } else {
                    return nil   // two statements without a separator
                }
            }
            return statements
        }

        private mutating func parseStatement(terminators: Set<String>) -> ScriptStatement? {
            guard let first = parseCommand(terminators: terminators) else { return nil }
            var rest: [(connector: Connector, command: ScriptCommand)] = []
            while pos < tokens.count, tokens[pos] == .and || tokens[pos] == .or {
                let connector: Connector = tokens[pos] == .and ? .and : .or
                pos += 1
                guard let command = parseCommand(terminators: terminators) else { return nil }
                rest.append((connector, command))
            }
            var background = false
            if pos < tokens.count, tokens[pos] == .background { background = true; pos += 1 }
            return ScriptStatement(first: first, rest: rest, background: background)
        }

        private mutating func parseCommand(terminators: Set<String>) -> ScriptCommand? {
            let compound: ScriptCommand?
            if isFunctionDefinitionAhead() {
                compound = parseFunctionDef()
            } else {
                switch peekWord() {
                case "if":    compound = parseIf()
                case "while": compound = parseWhile()
                case "for":   compound = parseFor()
                case "case":  compound = parseCase()
                default:      return parsePipeline(terminators: terminators)   // handles its own redirects
                }
            }
            guard let command = compound else { return nil }
            // A compound command may carry trailing redirections applied to the
            // whole block (`for … done > file`, `if … fi 2>&1`).
            let redirects = parseTrailingRedirects()
            return redirects.isEmpty ? command : .redirected(command, redirects)
        }

        private mutating func parseTrailingRedirects() -> Redirects {
            var redirects = Redirects()
            loop: while pos < tokens.count {
                switch tokens[pos] {
                case .redirectInput:
                    pos += 1
                    guard case let .word(w)? = tokens[safe: pos] else { break loop }
                    redirects.stdinFile = w; pos += 1
                case let .redirectFile(fd, append):
                    pos += 1
                    guard case let .word(w)? = tokens[safe: pos] else { break loop }
                    if fd == 2 { redirects.stderrFile = w; redirects.appendErr = append }
                    else { redirects.stdoutFile = w; redirects.appendOut = append }
                    pos += 1
                case let .redirectDup(fromFd, toFd):
                    pos += 1
                    if fromFd == 2, toFd == 1 { redirects.stderrToStdout = true }
                    else if fromFd == 1, toFd == 2 { redirects.stdoutToStderr = true }
                default:
                    break loop
                }
            }
            return redirects
        }

        private mutating func parseFor() -> ScriptCommand? {
            guard expectWord("for"), let name = peekWord() else { return nil }
            pos += 1                                   // consume the loop variable
            guard expectWord("in") else { return nil }
            // Collect the raw word list up to a separator or `do`.
            var words: [String] = []
            collect: while pos < tokens.count {
                switch tokens[pos] {
                case let .word(w):
                    if w == "do" { break collect }     // `do` ends the list
                    words.append(w); pos += 1
                default:
                    break collect                       // ';'/newline/operator ends it
                }
            }
            skipSeparators()
            guard expectWord("do"),
                  let body = parseList(terminators: ["done"]), expectWord("done") else { return nil }
            return .forClause(variable: name, words: words, body: body)
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

        private mutating func parseFunctionDef() -> ScriptCommand? {
            guard case let .word(name)? = tokens[safe: pos] else { return nil }
            pos += 1
            guard tokens[safe: pos] == .lparen else { return nil }; pos += 1
            guard tokens[safe: pos] == .rparen else { return nil }; pos += 1
            skipSeparators()                                   // allow newline(s) before `{`
            guard peekWord() == "{" else { return nil }; pos += 1
            guard let body = parseList(terminators: ["}"]) else { return nil }
            guard expectWord("}") else { return nil }
            return .functionDef(name: name, body: body)
        }

        private mutating func parseCase() -> ScriptCommand? {
            guard expectWord("case"), case let .word(subject)? = tokens[safe: pos] else { return nil }
            pos += 1                                           // the subject word
            guard expectWord("in") else { return nil }
            skipSeparators()
            var clauses: [CaseClause] = []
            while let word = peekWord(), word != "esac" {
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

        private mutating func parseIf() -> ScriptCommand? {
            guard expectWord("if"),
                  let cond = parseList(terminators: ["then"]), expectWord("then"),
                  let then = parseList(terminators: ["else", "fi"]) else { return nil }
            var els: [ScriptStatement] = []
            if peekWord() == "else" {
                pos += 1
                guard let e = parseList(terminators: ["fi"]) else { return nil }
                els = e
            }
            guard expectWord("fi") else { return nil }
            return .ifClause(cond: cond, then: then, els: els)
        }

        private mutating func parseWhile() -> ScriptCommand? {
            guard expectWord("while"),
                  let cond = parseList(terminators: ["do"]), expectWord("do"),
                  let body = parseList(terminators: ["done"]), expectWord("done") else { return nil }
            return .whileClause(cond: cond, body: body)
        }

        private mutating func parsePipeline(terminators: Set<String>) -> ScriptCommand? {
            guard let first = parseStage(terminators: terminators) else { return nil }
            var stages = [first]
            while pos < tokens.count, tokens[pos] == .pipe {
                pos += 1
                guard let next = parseStage(terminators: terminators) else { return nil }
                stages.append(next)
            }
            return .pipeline(stages)
        }

        private mutating func parseStage(terminators: Set<String>) -> RawStage? {
            var stage = RawStage()
            loop: while pos < tokens.count {
                switch tokens[pos] {
                case let .word(w):
                    // A reserved terminator at command position ends the stage.
                    if stage.argv.isEmpty, terminators.contains(w) { break loop }
                    stage.argv.append(w); pos += 1
                case .redirectInput:
                    pos += 1
                    guard case let .word(w)? = tokens[safe: pos] else { return nil }
                    stage.stdinFile = w; pos += 1
                case let .redirectFile(fd, append):
                    pos += 1
                    guard case let .word(w)? = tokens[safe: pos] else { return nil }
                    if fd == 2 {
                        stage.stderrFile = w; stage.appendErr = append
                        stage.stderrToStdout = false
                    } else {                       // fd 1 (or any other) → stdout
                        stage.stdoutFile = w; stage.appendOut = append
                        stage.stdoutToStderr = false
                    }
                    pos += 1
                case let .redirectDup(fromFd, toFd):
                    pos += 1
                    if fromFd == 2, toFd == 1 {
                        stage.stderrToStdout = true; stage.stderrFile = nil
                    } else if fromFd == 1, toFd == 2 {
                        stage.stdoutToStderr = true; stage.stdoutFile = nil
                    }
                    // Other fd duplications are accepted syntactically but ignored.
                default:
                    break loop   // pipe / separator / operator ends the stage
                }
            }
            let hasRedirect = stage.stdinFile != nil || stage.stdoutFile != nil
                || stage.stderrFile != nil || stage.stderrToStdout || stage.stdoutToStderr
            return stage.argv.isEmpty && !hasRedirect ? nil : stage
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
