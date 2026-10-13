/// Deterministic source formatting for the Swiftix-supported Go subset.

public enum GoFormatter {
    /// Validate and format a source file using Go-style tabs, spacing, and braces.
    /// Comments are retained in source order and the result always ends in a newline.
    public static func format(_ source: GoSourceFile) throws -> String {
        let parsed = try GoParser.parseRecordingParentheses(source)
        let spacing = GoOperatorSpacing(file: parsed.file, parentheses: parsed.parentheses)
        var scanner = FormatScanner(source: source)
        var tokens: [FormatToken] = []
        // Line breaks before a parenthesis that is not printed belong to
        // the token after it.
        var carriedNewlines = 0
        for token in try scanner.scan() {
            if token.kind == .symbol, spacing.droppedParentheses.contains(token.offset) {
                carriedNewlines = max(carriedNewlines, token.leadingNewlines)
                continue
            }
            tokens.append(
                carriedNewlines > token.leadingNewlines
                    ? token.withLeadingNewlines(carriedNewlines) : token)
            carriedNewlines = 0
        }
        var printer = FormatPrinter(tokens: tokens, spacing: spacing)
        return printer.render()
    }
}

private enum FormatTokenKind: Equatable {
    case word
    case literal
    case symbol
    case lineComment
    case blockComment
}

private struct FormatToken: Equatable {
    let kind: FormatTokenKind
    let text: String
    let leadingNewlines: Int
    /// Byte offset of the token in the source, as syntax tree positions count.
    let offset: Int

    func withLeadingNewlines(_ count: Int) -> FormatToken {
        FormatToken(kind: kind, text: text, leadingNewlines: count, offset: offset)
    }
}

private struct FormatScanner {
    let source: GoSourceFile
    let bytes: [UInt8]
    var index = 0
    var leadingNewlines = 0

    init(source: GoSourceFile) {
        self.source = source
        self.bytes = Array(source.text.utf8)
    }

    mutating func scan() throws -> [FormatToken] {
        var tokens: [FormatToken] = []
        while index < bytes.count {
            skipWhitespace()
            guard index < bytes.count else { break }

            let newlines = leadingNewlines
            leadingNewlines = 0
            let byte = bytes[index]
            if byte == 0x2F, peek(1) == 0x2F {
                tokens.append(scanLineComment(leadingNewlines: newlines))
            } else if byte == 0x2F, peek(1) == 0x2A {
                tokens.append(try scanBlockComment(leadingNewlines: newlines))
            } else if isIdentifierStart(byte) {
                tokens.append(scanWord(leadingNewlines: newlines))
            } else if isDigit(byte) {
                tokens.append(scanInteger(leadingNewlines: newlines))
            } else if byte == 0x22 {
                tokens.append(try scanString(leadingNewlines: newlines))
            } else {
                tokens.append(scanSymbol(leadingNewlines: newlines))
            }
        }
        return tokens
    }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0D:
                index += 1
            case 0x0A:
                leadingNewlines += 1
                index += 1
            default:
                return
            }
        }
    }

    mutating func scanLineComment(leadingNewlines: Int) -> FormatToken {
        let start = index
        while index < bytes.count, bytes[index] != 0x0A { index += 1 }
        return token(.lineComment, from: start, leadingNewlines: leadingNewlines)
    }

    mutating func scanBlockComment(leadingNewlines: Int) throws -> FormatToken {
        let start = index
        index += 2
        while index < bytes.count {
            if bytes[index] == 0x2A, peek(1) == 0x2F {
                index += 2
                return token(.blockComment, from: start, leadingNewlines: leadingNewlines)
            }
            index += 1
        }
        throw GoDiagnostic(
            position: position(at: start),
            message: "comment not terminated")
    }

    mutating func scanWord(leadingNewlines: Int) -> FormatToken {
        let start = index
        while index < bytes.count, isIdentifierContinue(bytes[index]) { index += 1 }
        return token(.word, from: start, leadingNewlines: leadingNewlines)
    }

    mutating func scanInteger(leadingNewlines: Int) -> FormatToken {
        // Keeps a prefixed or separated literal (`0x1f`, `0o644`, `1_000`) whole.
        let start = index
        while index < bytes.count, isIdentifierContinue(bytes[index]), bytes[index] < 0x80 {
            index += 1
        }
        return token(.literal, from: start, leadingNewlines: leadingNewlines)
    }

    mutating func scanString(leadingNewlines: Int) throws -> FormatToken {
        let start = index
        index += 1
        while index < bytes.count {
            if bytes[index] == 0x22 {
                index += 1
                return token(.literal, from: start, leadingNewlines: leadingNewlines)
            }
            if bytes[index] == 0x5C {
                index += 1
                if index < bytes.count { index += 1 }
            } else {
                index += 1
            }
        }
        throw GoDiagnostic(
            position: position(at: start),
            message: "string not terminated")
    }

    mutating func scanSymbol(leadingNewlines: Int) -> FormatToken {
        let start = index
        let pairs = [
            ":=", "++", "--", "==", "!=", "<=", ">=", "&&", "||", "<-", "<<", ">>", "&^",
        ]
        for spelling in GoCompoundAssignment.spellings + [GoSpread.spelling] {
            let end = index + spelling.utf8.count
            if end <= bytes.count, bytes[index..<end].elementsEqual(spelling.utf8) {
                index = end
                return token(.symbol, from: start, leadingNewlines: leadingNewlines)
            }
        }
        if index + 1 < bytes.count {
            let pair = String(decoding: bytes[index...(index + 1)], as: UTF8.self)
            if pairs.contains(pair) { index += 2 }
        }
        if index == start { index += 1 }
        return token(.symbol, from: start, leadingNewlines: leadingNewlines)
    }

    func token(
        _ kind: FormatTokenKind,
        from start: Int,
        leadingNewlines: Int
    ) -> FormatToken {
        FormatToken(
            kind: kind,
            text: String(decoding: bytes[start..<index], as: UTF8.self),
            leadingNewlines: leadingNewlines,
            offset: start)
    }

    func peek(_ distance: Int) -> UInt8? {
        let target = index + distance
        return target < bytes.count ? bytes[target] : nil
    }

    func position(at offset: Int) -> GoSourcePosition {
        var line = 1
        var column = 1
        for byte in bytes[..<offset] {
            if byte == 0x0A {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return GoSourcePosition(
            path: source.path,
            offset: offset,
            line: line,
            column: column)
    }

    func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    func isIdentifierStart(_ byte: UInt8) -> Bool {
        byte == 0x5F || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte >= 0x80
    }

    func isIdentifierContinue(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || isDigit(byte)
    }
}

private struct FormatPrinter {
    let tokens: [FormatToken]
    /// Which operators and slice colons Go's printer spaces differently.
    let spacing: GoOperatorSpacing
    var lines: [String] = []
    var current = ""
    var indent = 0
    var braceDepth = 0
    var parenthesisDepth = 0
    var forHeader = false
    var pendingIf = false
    var pendingFunction = false
    var pendingVariableDeclaration = false
    /// From `type` to the end of its line or the `{` of a body: what
    /// follows the name is a type.
    var pendingTypeDeclaration = false
    var pendingSwitch = false
    var switchDepths: Set<Int> = []
    var compositeDepths: Set<Int> = []
    var activeCaseDepths: Set<Int> = []
    var previous: FormatToken?
    var previousWasUnaryOperator = false
    var previousTopLevelDeclaration: String?
    var pendingTopLevelComments = false
    /// Brace depths of `struct` and `interface` bodies, where every line
    /// declares a name and its type.
    var typeBodyDepths: Set<Int> = []
    /// Whether each open `[` belongs to a type (`[]T`, `[3]T`, `map[K]V`)
    /// rather than to an index expression.
    var typeBrackets: [Bool] = []
    /// For each open `[`: whether the `:` of its slice expression has blanks,
    /// and the parenthesis and brace depths the bracket was opened at, which
    /// are those of its own `:`.
    var sliceBrackets: [(spaced: Bool, parenthesisDepth: Int, braceDepth: Int)] = []
    /// Whether the previous token was the `]` of such a bracket, after which
    /// a `*` is a pointer type and a `[` is another type.
    var afterTypeBracket = false
    /// Brace depths of `interface{}` and `struct{}`, which stay on their
    /// line, and whether the previous token closed one: a `{` after it
    /// opens a composite literal of that type (`[]interface{}{x}`).
    var emptyTypeDepths: Set<Int> = []
    var closedEmptyType = false
    /// Whether the tokens so far spell a literal type (`[]T`, `[3]*T`,
    /// `map[K]V`), after which a `{` opens a composite literal even in the
    /// header of a statement.
    var spellsLiteralType = false

    mutating func render() -> String {
        for (index, token) in tokens.enumerated() {
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            handleLeadingNewlines(for: token)
            handle(token, next: next)
        }
        finishLine()
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    mutating func handleLeadingNewlines(for token: FormatToken) {
        guard token.leadingNewlines > 0 else { return }
        if compositeDepths.contains(braceDepth) { return }
        if token.text == "else", previous?.text == "}" { return }
        if !current.isEmpty, parenthesisDepth == 0, !forHeader, canEndLine(previous) {
            finishLine()
        }
        if token.leadingNewlines > 1, current.isEmpty, !lines.isEmpty {
            appendBlankLine()
        }
    }

    mutating func handle(_ token: FormatToken, next: FormatToken?) {
        if token.kind == .lineComment {
            let isStandaloneTopLevelComment = braceDepth == 0 && current.isEmpty
            beginTopLevelCommentIfNeeded(isStandaloneTopLevelComment)
            if !current.isEmpty { ensureSpace() }
            append(token.text)
            finishLine()
            previous = token
            previousWasUnaryOperator = false
            return
        }
        if token.kind == .blockComment {
            let isStandaloneTopLevelComment = braceDepth == 0 && current.isEmpty
            beginTopLevelCommentIfNeeded(isStandaloneTopLevelComment)
            if !current.isEmpty { ensureSpace() }
            appendBlockComment(token.text)
            previous = token
            previousWasUnaryOperator = false
            return
        }

        if braceDepth == 0, current.isEmpty,
            token.text == "package" || token.text == "import" || token.text == "type"
                || token.text == "var" || token.text == "const" || token.text == "func"
        {
            beginTopLevelDeclaration(token.text)
        }

        let followsTypeBracket = afterTypeBracket
        afterTypeBracket = false
        let followsLiteralType = spellsLiteralType && !pendingFunction
        let followsEmptyType = closedEmptyType && !pendingFunction
        closedEmptyType = false
        // A type goes on through names, pointers, and further brackets.
        spellsLiteralType =
            spellsLiteralType
            && (token.kind == .word || ["*", ".", "[", "]"].contains(token.text))
        // The syntax tree says this operator is binary and joined to its
        // operands, whatever the tokens around it suggest.
        let isTightOperator = token.kind == .symbol && spacing.tight.contains(token.offset)
        let tokenIsUnaryOperator =
            !isTightOperator
            && (token.text == "!"
            || ((token.text == "&" || token.text == "^") && isUnaryOperator)
            || (token.text == "<-" && previous?.text != "chan" && isUnaryOperator)
            || (token.text == "*"
                && (isUnaryOperator || isPointerTypeContext || followsTypeBracket))
            || ((token.text == "+" || token.text == "-") && isUnaryOperator))
        switch token.text {
        case _ where isTightOperator:
            trimTrailingWhitespace()
            append(token.text)
        case "func":
            appendWord(token.text, kind: token.kind)
            pendingFunction = true
        case "if":
            appendWord(token.text, kind: token.kind)
            pendingIf = true
        case "var":
            appendWord(token.text, kind: token.kind)
            pendingVariableDeclaration = true
        case "for":
            appendWord(token.text, kind: token.kind)
            forHeader = true
        case "switch", "select":
            appendWord(token.text, kind: token.kind)
            pendingSwitch = true
        case "case", "default":
            beginCase(token.text)
        case "else" where previous?.text == "}":
            ensureSpace()
            append("else")
        case "(":
            // After a keyword a parenthesis opens an operand, not a call.
            if let previous, previous.kind == .word,
                ["if", "for", "switch", "return", "case", "range"].contains(previous.text)
            {
                ensureSpace()
            } else if previous?.text == "func", braceDepth == 0, current == "func" {
                // The receiver of a method declaration; a function literal
                // and a function type have none: `func() {`.
                ensureSpace()
            }
            // The result list of a function signature: `func f() (int, error)`.
            if previous?.text == ")", pendingFunction || typeBodyDepths.contains(braceDepth),
                parenthesisDepth == 0
            {
                ensureSpace()
            }
            append("(")
            parenthesisDepth += 1
        case ")":
            trimTrailingWhitespace()
            append(")")
            parenthesisDepth -= 1
        case "[":
            // `[]` is always a slice type, and so is a bracket where an
            // operand begins or that follows `map` or another type bracket.
            let opensSliceType = next?.text == "]"
            typeBrackets.append(
                opensSliceType || followsTypeBracket || previous?.text == "map"
                    || isPointerTypeContext || !endsOperand(previous))
            if previous?.text == "map" {
                // `map[K]V`: the key follows the keyword directly.
            } else if isPointerTypeContext, previous?.kind == .word || previous?.text == ")" {
                ensureSpace()
            } else if opensSliceType, previous?.kind == .word {
                // A slice type after a name declares it: `lines []string`.
                ensureSpace()
            } else if let previous, previous.kind == .word, !endsOperand(previous) {
                // An array type after a keyword: `range [2]string{...}`.
                ensureSpace()
            }
            append("[")
            sliceBrackets.append(
                (spacing.spacedSlices.contains(token.offset), parenthesisDepth, braceDepth))
        case "]":
            trimTrailingWhitespace()
            append("]")
            afterTypeBracket = typeBrackets.popLast() ?? false
            _ = sliceBrackets.popLast()
            if afterTypeBracket { spellsLiteralType = true }
        case "{":
            // `interface{}` stays on its line; an interface with methods is
            // a block like a struct.
            // `interface{}` and `struct{}` are types written on one line,
            // in a signature as anywhere else.
            let opensEmptyType =
                (previous?.text == "interface" || previous?.text == "struct")
                && next?.text == "}" && next?.leadingNewlines == 0
            if opensEmptyType {
                append("{")
                braceDepth += 1
                compositeDepths.insert(braceDepth)
                emptyTypeDepths.insert(braceDepth)
                break
            }
            let isLiteral =
                followsLiteralType || followsEmptyType
                // Inside a literal every brace is an element's.
                || (compositeDepths.contains(braceDepth)
                    && (previous?.kind == .word || ["{", ",", ":", "]"].contains(previous?.text)))
                // Inside parentheses a type name before `{` cannot be the
                // operand before a block, in a statement header either.
                || (parenthesisDepth > 0 && !pendingFunction && previous?.kind == .word
                    && endsOperand(previous))
                || (isCompositeLiteralBrace
                    && !(previous?.text == "interface" && next?.text != "}"))
            if isLiteral {
                append("{")
                braceDepth += 1
                compositeDepths.insert(braceDepth)
            } else {
                ensureSpace()
                append("{")
                finishLine()
                braceDepth += 1
                indent += 1
                if previous?.text == "struct" || previous?.text == "interface" {
                    typeBodyDepths.insert(braceDepth)
                }
                if pendingSwitch { switchDepths.insert(braceDepth) }
                pendingSwitch = false
                pendingIf = false
                pendingFunction = false
                pendingTypeDeclaration = false
                forHeader = false
            }
        case "}":
            if compositeDepths.remove(braceDepth) != nil {
                trimTrailingWhitespace()
                append("}")
                closedEmptyType = emptyTypeDepths.remove(braceDepth) != nil
                braceDepth -= 1
            } else {
                closeBrace()
            }
        case ",":
            trimTrailingWhitespace()
            append(",")
            if next?.text != ")" && next?.text != "}" { append(" ") }
        case ".":
            trimTrailingWhitespace()
            append(".")
        case GoSpread.spelling:
            // Before a type it marks a variadic parameter, `values ...T`;
            // after an argument it spreads a slice, `values...`.
            if next?.kind == .word || next?.text == "[" || next?.text == "*" {
                ensureSpace()
            } else {
                trimTrailingWhitespace()
            }
            append(GoSpread.spelling)
        case ":" where sliceBrackets.last.map({
            $0.parenthesisDepth == parenthesisDepth && $0.braceDepth == braceDepth
        }) ?? false:
            // The colon of a slice expression: blanks on both sides when Go
            // prints them, and none otherwise, inside a literal too.
            trimTrailingWhitespace()
            if sliceBrackets.last?.spaced == true {
                if previous?.text != "[" { append(" ") }
                append(":")
                if next?.text != "]" { append(" ") }
            } else {
                append(":")
            }
        case ":":
            trimTrailingWhitespace()
            append(":")
            if compositeDepths.contains(braceDepth) {
                append(" ")
            } else if switchDepths.contains(braceDepth),
                current == "case:" || current.hasPrefix("case ") || current == "default:"
            {
                finishLine()
                indent += 1
                activeCaseDepths.insert(braceDepth)
            }
        case ";":
            // Inside a `for` clause, and after the initializer of an `if` or
            // a `switch`, the header goes on.
            if forHeader || pendingIf || pendingSwitch {
                trimTrailingWhitespace()
                append("; ")
            } else {
                finishLine()
            }
        case "++", "--":
            trimTrailingWhitespace()
            append(token.text)
        case "!":
            if needsSpaceBeforeUnary() { ensureSpace() }
            append("!")
        case "&" where isUnaryOperator,
            "^" where isUnaryOperator:
            // Address-of and bitwise complement; the binary forms fall through.
            if needsSpaceBeforeUnary() { ensureSpace() }
            append(token.text)
        case "<-" where previous?.text == "chan":
            trimTrailingWhitespace()
            append("<-")
            append(" ")
        case "<-" where isUnaryOperator:
            if needsSpaceBeforeUnary() { ensureSpace() }
            append("<-")
        case "<-":
            ensureSpace()
            append("<-")
            append(" ")
        case "*" where followsTypeBracket:
            // The element of `[]*T`, `[3]*T`, and `map[K]*V`.
            append("*")
        case "*" where isPointerTypeContext:
            if previous?.text != GoSpread.spelling, previous?.text != "(" { ensureSpace() }
            append("*")
        case "*" where isUnaryOperator:
            if needsSpaceBeforeUnary() { ensureSpace() }
            append("*")
        case "+" where isUnaryOperator,
            "-" where isUnaryOperator:
            if needsSpaceBeforeUnary() { ensureSpace() }
            append(token.text)
        case "=", ":=", "+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "&&", "||",
            "&", "|", "^", "<<", ">>", "&^",
            "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "&^=":
            ensureSpace()
            append(token.text)
            append(" ")
        default:
            appendWord(token.text, kind: token.kind)
        }
        // What follows the `=` of a `var` is a value, not its type.
        if token.text == "=" { pendingVariableDeclaration = false }
        if token.text == "type", token.kind == .word { pendingTypeDeclaration = true }
        previous = token
        previousWasUnaryOperator = tokenIsUnaryOperator
    }

    mutating func beginTopLevelDeclaration(_ declaration: String) {
        if pendingTopLevelComments {
            pendingTopLevelComments = false
            previousTopLevelDeclaration = declaration
            return
        }
        // Go's printer puts an empty line where the kind of declaration
        // changes, and otherwise keeps the lines the source has.
        let needsBlankLine =
            previousTopLevelDeclaration != nil && previousTopLevelDeclaration != declaration
        if needsBlankLine { appendBlankLine() }
        previousTopLevelDeclaration = declaration
    }

    mutating func beginTopLevelCommentIfNeeded(_ isStandalone: Bool) {
        guard isStandalone else { return }
        if previousTopLevelDeclaration != nil, !pendingTopLevelComments {
            appendBlankLine()
        }
        pendingTopLevelComments = true
    }

    mutating func beginCase(_ keyword: String) {
        if !current.isEmpty { finishLine() }
        if activeCaseDepths.remove(braceDepth) != nil || switchDepths.contains(braceDepth) {
            indent -= 1
        }
        append(keyword)
    }

    mutating func closeBrace() {
        if !current.isEmpty { finishLine() }
        activeCaseDepths.remove(braceDepth)
        switchDepths.remove(braceDepth)
        typeBodyDepths.remove(braceDepth)
        indent -= 1
        braceDepth -= 1
        append("}")
    }

    mutating func appendWord(_ text: String, kind: FormatTokenKind) {
        if shouldSeparateWord(kind: kind) { ensureSpace() }
        append(text)
    }

    func shouldSeparateWord(kind: FormatTokenKind) -> Bool {
        guard !current.isEmpty, let previous else { return false }
        if current.last == " " || previous.text == "(" || previous.text == "."
            || previous.text == GoSpread.spelling
        {
            return false
        }
        if previousWasUnaryOperator {
            return false
        }
        switch previous.kind {
        case .word, .literal, .blockComment:
            return true
        case .symbol:
            return previous.text == ")" || previous.text == "}" || previous.text == "++"
                || previous.text == "--"
        case .lineComment:
            return false
        }
    }

    /// Whether an expression can end at `token`, so that a `[` after it
    /// indexes what came before.
    func endsOperand(_ token: FormatToken?) -> Bool {
        guard let token else { return false }
        switch token.kind {
        case .literal:
            return true
        case .word:
            return ![
                "return", "case", "if", "for", "switch", "select", "range", "map", "chan",
                "func", "var", "const", "type", "else", "go", "defer", "struct", "interface",
                "package", "import", "break", "continue", "default",
            ].contains(token.text)
        case .symbol:
            return [")", "]", "}"].contains(token.text)
        case .lineComment, .blockComment:
            return false
        }
    }

    var isCompositeLiteralBrace: Bool {
        guard let previous, previous.kind == .word else { return false }
        guard !forHeader, !pendingSwitch, !pendingIf, !pendingFunction else { return false }
        return !["if", "else", "for", "switch", "select", "func", "struct", "type"].contains(
            previous.text)
    }

    var isPointerTypeContext: Bool {
        pendingFunction || pendingVariableDeclaration || pendingTypeDeclaration
            || typeBodyDepths.contains(braceDepth)
    }

    var isUnaryOperator: Bool {
        if current.isEmpty { return true }
        guard let previous else { return true }
        if previous.kind == .word {
            return ["return", "case", "if", "for", "switch", "select", "range", "chan"]
                .contains(previous.text)
        }
        return [
            "(", "[", ",", "{", ":", ";", "=", ":=", "+", "-", "*", "/", "%", "==",
            "!=", "<", "<=", ">", ">=", "&&", "||", "!", "<-",
            "&", "|", "^", "<<", ">>", "&^",
        ].contains(previous.text)
    }

    func needsSpaceBeforeUnary() -> Bool {
        guard let previous else { return false }
        return previous.kind == .word
            && ["return", "case", "if", "for", "switch", "select", "range", "chan"]
                .contains(previous.text)
    }

    func canEndLine(_ token: FormatToken?) -> Bool {
        guard let token else { return false }
        if token.kind == .word || token.kind == .literal || token.kind == .lineComment
            || token.kind == .blockComment
        {
            return true
        }
        return [")", "}", "]", "++", "--"].contains(token.text)
    }

    mutating func appendBlockComment(_ text: String) {
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            if index > 0 { finishLine() }
            append(String(part))
        }
    }

    mutating func append(_ text: String) {
        current += text
    }

    mutating func ensureSpace() {
        guard !current.isEmpty, current.last != " ", current.last != "\t" else { return }
        current.append(" ")
    }

    mutating func finishLine() {
        trimTrailingWhitespace()
        guard !current.isEmpty else { return }
        lines.append(String(repeating: "\t", count: max(0, indent)) + current)
        current = ""
        pendingVariableDeclaration = false
        pendingTypeDeclaration = false
    }

    mutating func appendBlankLine() {
        finishLine()
        guard !lines.isEmpty, lines.last != "" else { return }
        lines.append("")
    }

    mutating func trimTrailingWhitespace() {
        while current.last == " " || current.last == "\t" { current.removeLast() }
    }
}
