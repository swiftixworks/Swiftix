/// Go-compatible tokenization with comments, string escapes, and semicolon insertion.

public enum GoLexer {
    public static func tokenize(_ source: GoSourceFile) throws -> [GoToken] {
        var scanner = Scanner(source: source)
        return try scanner.scan()
    }
}

private struct Scanner {
    let source: GoSourceFile
    let bytes: [UInt8]
    var index = 0
    var line = 1
    var column = 1
    var tokens: [GoToken] = []

    init(source: GoSourceFile) {
        self.source = source
        self.bytes = Array(source.text.utf8)
    }

    mutating func scan() throws -> [GoToken] {
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x09 || byte == 0x0D {
                advance()
                continue
            }
            if byte == 0x0A {
                let newline = position()
                advance()
                insertSemicolonIfNeeded(at: newline)
                continue
            }
            if byte == 0x2F, peek(1) == 0x2F {
                skipLineComment()
                continue
            }
            if byte == 0x2F, peek(1) == 0x2A {
                try skipBlockComment()
                continue
            }
            if isIdentifierStart(byte) {
                scanIdentifier()
                continue
            }
            if isDigit(byte) {
                try scanInteger()
                continue
            }
            if byte == 0x22 {
                try scanString()
                continue
            }
            try scanPunctuation()
        }

        let end = position()
        insertSemicolonIfNeeded(at: end)
        tokens.append(GoToken(kind: .eof, position: end))
        return tokens
    }

    mutating func scanIdentifier() {
        let start = position()
        let begin = index
        while index < bytes.count, isIdentifierContinue(bytes[index]) { advance() }
        let text = String(decoding: bytes[begin..<index], as: UTF8.self)
        let kind: GoTokenKind
        switch text {
        case "package": kind = .package
        case "import": kind = .import
        case "func": kind = .function
        case "type": kind = .typeKeyword
        case "struct": kind = .structKeyword
        case "var": kind = .variable
        case "const": kind = .constant
        case "return": kind = .return
        case "if": kind = .if
        case "else": kind = .else
        case "for": kind = .for
        case "switch": kind = .switchKeyword
        case "case": kind = .caseKeyword
        case "default": kind = .defaultKeyword
        case "break": kind = .breakKeyword
        case "continue": kind = .continueKeyword
        case "range": kind = .rangeKeyword
        case "defer": kind = .deferKeyword
        case "map": kind = .mapKeyword
        case "interface": kind = .interfaceKeyword
        case "go": kind = .goKeyword
        case "chan": kind = .chanKeyword
        case "select": kind = .selectKeyword
        default: kind = .identifier(text)
        }
        tokens.append(GoToken(kind: kind, position: start))
    }

    mutating func scanInteger() throws {
        let start = position()
        let begin = index
        while index < bytes.count, isDigit(bytes[index]) { advance() }
        let text = String(decoding: bytes[begin..<index], as: UTF8.self)
        guard let value = Int64(text) else {
            throw GoDiagnostic(position: start, message: "integer literal overflows int64")
        }
        tokens.append(GoToken(kind: .integer(value), position: start))
    }

    mutating func scanString() throws {
        let start = position()
        advance()
        var value: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                advance()
                tokens.append(
                    GoToken(kind: .string(String(decoding: value, as: UTF8.self)), position: start))
                return
            }
            if byte == 0x0A {
                throw GoDiagnostic(position: start, message: "newline in string")
            }
            if byte == 0x5C {
                advance()
                guard index < bytes.count else {
                    throw GoDiagnostic(position: start, message: "string not terminated")
                }
                let escaped = bytes[index]
                switch escaped {
                case 0x6E: value.append(0x0A)
                case 0x72: value.append(0x0D)
                case 0x74: value.append(0x09)
                case 0x22: value.append(0x22)
                case 0x5C: value.append(0x5C)
                default:
                    throw GoDiagnostic(
                        position: position(),
                        message: "unknown escape sequence")
                }
                advance()
                continue
            }
            value.append(byte)
            advance()
        }
        throw GoDiagnostic(position: start, message: "string not terminated")
    }

    mutating func scanPunctuation() throws {
        let start = position()
        let byte = bytes[index]
        let kind: GoTokenKind
        switch byte {
        case 0x28: kind = .leftParen
        case 0x29: kind = .rightParen
        case 0x7B: kind = .leftBrace
        case 0x7D: kind = .rightBrace
        case 0x5B: kind = .leftBracket
        case 0x5D: kind = .rightBracket
        case 0x2C: kind = .comma
        case 0x2E: kind = .period
        case 0x3A where peek(1) == 0x3D:
            kind = .declare
            advance()
        case 0x3A: kind = .colon
        case 0x3B: kind = .semicolon
        case 0x2B where peek(1) == 0x2B:
            kind = .increment
            advance()
        case 0x2D where peek(1) == 0x2D:
            kind = .decrement
            advance()
        case 0x2B: kind = .plus
        case 0x2D: kind = .minus
        case 0x2A: kind = .star
        case 0x2F: kind = .slash
        case 0x25: kind = .percent
        case 0x3D where peek(1) == 0x3D:
            kind = .equal
            advance()
        case 0x21 where peek(1) == 0x3D:
            kind = .notEqual
            advance()
        case 0x3C where peek(1) == 0x2D:
            kind = .arrow
            advance()
        case 0x3C where peek(1) == 0x3D:
            kind = .lessEqual
            advance()
        case 0x3E where peek(1) == 0x3D:
            kind = .greaterEqual
            advance()
        case 0x26 where peek(1) == 0x26:
            kind = .logicalAnd
            advance()
        case 0x26: kind = .ampersand
        case 0x7C where peek(1) == 0x7C:
            kind = .logicalOr
            advance()
        case 0x3D: kind = .assign
        case 0x21: kind = .bang
        case 0x3C: kind = .less
        case 0x3E: kind = .greater
        default:
            throw GoDiagnostic(
                position: start,
                message: "invalid character \(String(decoding: [byte], as: UTF8.self))")
        }
        advance()
        tokens.append(GoToken(kind: kind, position: start))
    }

    mutating func skipLineComment() {
        while index < bytes.count, bytes[index] != 0x0A { advance() }
    }

    mutating func skipBlockComment() throws {
        let start = position()
        advance()
        advance()
        var firstNewline: GoSourcePosition?
        while index < bytes.count {
            if bytes[index] == 0x2A, peek(1) == 0x2F {
                advance()
                advance()
                if let firstNewline { insertSemicolonIfNeeded(at: firstNewline) }
                return
            }
            if bytes[index] == 0x0A, firstNewline == nil { firstNewline = position() }
            advance()
        }
        throw GoDiagnostic(position: start, message: "comment not terminated")
    }

    mutating func insertSemicolonIfNeeded(at position: GoSourcePosition) {
        guard tokens.last?.kind.canEndStatement == true else { return }
        tokens.append(GoToken(kind: .semicolon, position: position))
    }

    func peek(_ distance: Int) -> UInt8? {
        let target = index + distance
        return target < bytes.count ? bytes[target] : nil
    }

    mutating func advance() {
        guard index < bytes.count else { return }
        if bytes[index] == 0x0A {
            line += 1
            column = 1
        } else {
            column += 1
        }
        index += 1
    }

    func position() -> GoSourcePosition {
        GoSourcePosition(path: source.path, offset: index, line: line, column: column)
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
