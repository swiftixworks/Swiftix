/// Deterministic source formatting for the Swiftix-supported Go subset.

public enum GoFormatter {
    /// Validate and format a source file using Go-style tabs, spacing, and braces.
    /// Comments are retained in source order and the result always ends in a newline.
    public static func format(_ source: GoSourceFile) throws -> String {
        _ = try GoParser.parse(source)
        var scanner = FormatScanner(source: source)
        let tokens = try scanner.scan()
        var printer = FormatPrinter(tokens: tokens)
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
            leadingNewlines: leadingNewlines)
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
    var lines: [String] = []
    var current = ""
    var indent = 0
    var braceDepth = 0
    var parenthesisDepth = 0
    var forHeader = false
    var pendingIf = false
    var pendingFunction = false
    var pendingVariableDeclaration = false
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
    /// Whether the previous token was the `]` of such a bracket, after which
    /// a `*` is a pointer type and a `[` is another type.
    var afterTypeBracket = false
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
        // A type goes on through names, pointers, and further brackets.
        spellsLiteralType =
            spellsLiteralType
            && (token.kind == .word || ["*", ".", "[", "]"].contains(token.text))
        let tokenIsUnaryOperator =
            token.text == "!"
            || ((token.text == "&" || token.text == "^") && isUnaryOperator)
            || (token.text == "<-" && previous?.text != "chan" && isUnaryOperator)
            || (token.text == "*"
                && (isUnaryOperator || isPointerTypeContext || followsTypeBracket))
            || ((token.text == "+" || token.text == "-") && isUnaryOperator)
        switch token.text {
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
                ["func", "if", "for", "switch", "return", "case", "range"].contains(previous.text)
            {
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
        case "]":
            trimTrailingWhitespace()
            append("]")
            afterTypeBracket = typeBrackets.popLast() ?? false
            if afterTypeBracket { spellsLiteralType = true }
        case "{":
            // `interface{}` stays on its line; an interface with methods is
            // a block like a struct.
            let isLiteral =
                followsLiteralType
                // Inside a literal every brace is an element's.
                || (compositeDepths.contains(braceDepth)
                    && (previous?.kind == .word || ["{", ",", ":", "]"].contains(previous?.text)))
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
                forHeader = false
            }
        case "}":
            if compositeDepths.remove(braceDepth) != nil {
                trimTrailingWhitespace()
                append("}")
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
        previous = token
        previousWasUnaryOperator = tokenIsUnaryOperator
    }

    mutating func beginTopLevelDeclaration(_ declaration: String) {
        if pendingTopLevelComments {
            pendingTopLevelComments = false
            previousTopLevelDeclaration = declaration
            return
        }
        let needsBlankLine: Bool
        switch (previousTopLevelDeclaration, declaration) {
        case ("package", "import"), ("package", "type"), ("package", "func"),
            ("package", "var"), ("package", "const"),
            ("import", "type"), ("import", "var"), ("import", "const"), ("import", "func"),
            ("type", "type"), ("type", "var"), ("type", "const"), ("type", "func"),
            ("var", "func"), ("const", "func"), ("func", "func"), ("func", "type"),
            ("func", "var"), ("func", "const"):
            needsBlankLine = true
        default:
            needsBlankLine = false
        }
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
        pendingFunction || pendingVariableDeclaration || typeBodyDepths.contains(braceDepth)
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
