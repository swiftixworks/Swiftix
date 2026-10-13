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
            if byte == 0x27 {
                try scanRune()
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

    /// Scans a decimal, hexadecimal (`0x1f`), octal (`0o644` or `0644`), or
    /// binary (`0b101`) integer literal. `_` may separate digits.
    mutating func scanInteger() throws {
        let start = position()
        var radix: UInt64 = 10
        var name = "decimal"
        var requiresDigit = false
        if bytes[index] == 0x30, let prefix = peek(1) {
            switch prefix {
            case 0x78, 0x58: (radix, name) = (16, "hexadecimal")
            case 0x6F, 0x4F: (radix, name) = (8, "octal")
            case 0x62, 0x42: (radix, name) = (2, "binary")
            default: break
            }
            if radix != 10 {
                advance()
                advance()
                requiresDigit = true
            } else if isDigit(prefix) || prefix == 0x5F {
                // A leading zero selects octal: 0644.
                (radix, name) = (8, "octal")
                advance()
            }
        }
        var value: UInt64 = 0
        var digitCount = 0
        var overflowed = false
        var lastWasSeparator = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5F {
                guard !lastWasSeparator, digitCount > 0 || radix != 10 else {
                    throw GoDiagnostic(
                        position: start, message: "'_' must separate successive digits")
                }
                lastWasSeparator = true
                advance()
                continue
            }
            guard let digit = escapeDigitValue(byte).map(UInt64.init) else {
                if isIdentifierStart(byte) {
                    throw GoDiagnostic(
                        position: start,
                        message: "invalid digit '\(String(decoding: [byte], as: UTF8.self))' in \(name) literal")
                }
                break
            }
            guard digit < radix else {
                throw GoDiagnostic(
                    position: start,
                    message: "invalid digit '\(String(decoding: [byte], as: UTF8.self))' in \(name) literal")
            }
            let (scaled, scaleOverflow) = value.multipliedReportingOverflow(by: radix)
            let (sum, sumOverflow) = scaled.addingReportingOverflow(digit)
            overflowed = overflowed || scaleOverflow || sumOverflow
            value = sum
            digitCount += 1
            lastWasSeparator = false
            advance()
        }
        guard !lastWasSeparator else {
            throw GoDiagnostic(position: start, message: "'_' must separate successive digits")
        }
        guard !requiresDigit || digitCount > 0 else {
            throw GoDiagnostic(position: start, message: "\(name) literal has no digits")
        }
        guard !overflowed, let signed = Int64(exactly: value) else {
            throw GoDiagnostic(position: start, message: "integer literal overflows int64")
        }
        tokens.append(GoToken(kind: .integer(signed), position: start))
    }

    mutating func scanString() throws {
        let start = position()
        advance()
        var value: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                advance()
                // Guest strings are Unicode text, so byte escapes must still
                // form valid UTF-8 rather than decode to replacement characters.
                let text = String(decoding: value, as: UTF8.self)
                guard Array(text.utf8) == value else {
                    throw GoDiagnostic(
                        position: start,
                        message: "string literal is not valid UTF-8")
                }
                tokens.append(GoToken(kind: .string(text), position: start))
                return
            }
            if byte == 0x0A {
                throw GoDiagnostic(position: position(), message: "newline in string")
            }
            if byte == 0x5C {
                advance()
                let escape = try scanEscape(quote: 0x22, start: start, unterminated: "string not terminated")
                if escape.isByte {
                    value.append(UInt8(escape.value))
                } else if let scalar = Unicode.Scalar(escape.value) {
                    value.append(contentsOf: Array(String(Character(scalar)).utf8))
                }
                continue
            }
            value.append(byte)
            advance()
        }
        throw GoDiagnostic(position: start, message: "string not terminated")
    }

    /// A rune literal, `'a'` or `'\n'`: the code point it names, as the
    /// integer constant it is. The token is an integer, so everything after
    /// the lexer sees a number where the source has a character.
    ///
    /// The errors are those of Go's scanner, each where it reports it: one
    /// about what is between the quotes at the character it is about, one
    /// about the whole literal where the literal starts.
    mutating func scanRune() throws {
        let start = position()
        advance()
        var values: [UInt32] = []
        while true {
            guard index < bytes.count else {
                throw GoDiagnostic(position: start, message: "rune literal not terminated")
            }
            let byte = bytes[index]
            if byte == 0x27 { break }
            if byte == 0x0A {
                throw GoDiagnostic(position: position(), message: "newline in rune literal")
            }
            if byte == 0x5C {
                advance()
                values.append(
                    try scanEscape(quote: 0x27, start: start, unterminated: "rune literal not terminated")
                        .value)
                continue
            }
            // One code point of the source, which is UTF-8.
            guard let scalar = scalar(at: index) else {
                throw GoDiagnostic(position: position(), message: "invalid UTF-8 encoding")
            }
            values.append(scalar.value)
            for _ in 0..<UTF8.width(scalar) { advance() }
        }
        guard let value = values.first else {
            throw GoDiagnostic(position: position(), message: "empty rune literal or unescaped '")
        }
        guard values.count == 1 else {
            throw GoDiagnostic(position: start, message: "more than one character in rune literal")
        }
        advance()
        tokens.append(GoToken(kind: .integer(Int64(value)), position: start))
    }

    /// The code point the UTF-8 at `offset` encodes, or nil when it is none.
    func scalar(at offset: Int) -> Unicode.Scalar? {
        var length = 1
        while offset + length < bytes.count, bytes[offset + length] & 0xC0 == 0x80 { length += 1 }
        let encoded = bytes[offset..<(offset + length)]
        let text = String(decoding: encoded, as: UTF8.self)
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
            text.utf8.elementsEqual(encoded)
        else { return nil }
        return scalar
    }

    /// What follows a backslash in a literal that `quote` ends: the escape
    /// of one character, of a byte (`\x41`, `\101`), or of a code point
    /// (`é`, `\U0001F600`). The index starts after the backslash and
    /// ends after the escape; the messages are those of Go's scanner.
    mutating func scanEscape(
        quote: UInt8, start: GoSourcePosition, unterminated: String
    ) throws -> (value: UInt32, isByte: Bool) {
        guard index < bytes.count else { throw GoDiagnostic(position: start, message: unterminated) }
        let count: Int
        let radix: UInt32
        switch bytes[index] {
        case 0x61: advance(); return (0x07, false)
        case 0x62: advance(); return (0x08, false)
        case 0x66: advance(); return (0x0C, false)
        case 0x6E: advance(); return (0x0A, false)
        case 0x72: advance(); return (0x0D, false)
        case 0x74: advance(); return (0x09, false)
        case 0x76: advance(); return (0x0B, false)
        case 0x5C: advance(); return (0x5C, false)
        case quote: advance(); return (UInt32(quote), false)
        case 0x30...0x37: (count, radix) = (3, 8)
        case 0x78: advance(); (count, radix) = (2, 16)
        case 0x75: advance(); (count, radix) = (4, 16)
        case 0x55: advance(); (count, radix) = (8, 16)
        default: throw GoDiagnostic(position: position(), message: "unknown escape")
        }
        var value: UInt32 = 0
        for _ in 0..<count {
            guard index < bytes.count else { throw GoDiagnostic(position: start, message: unterminated) }
            guard let digit = escapeDigitValue(bytes[index]), digit < radix else {
                throw GoDiagnostic(
                    position: position(),
                    message: "invalid character \(quotedCharacter(at: index)) in "
                        + "\(radix == 8 ? "octal" : "hexadecimal") escape")
            }
            value = value * radix + digit
            advance()
        }
        if count <= 3 {
            guard value <= 0xFF else {
                throw GoDiagnostic(position: position(), message: "octal escape value \(value) > 255")
            }
            return (value, true)
        }
        guard Unicode.Scalar(value) != nil else {
            let digits = String(value, radix: 16, uppercase: true)
            throw GoDiagnostic(
                position: position(),
                message: "escape is invalid Unicode code point U+"
                    + String(repeating: "0", count: max(0, 4 - digits.count)) + digits)
        }
        return (value, false)
    }

    /// The character at `offset` the way Go's `%q` writes a rune.
    func quotedCharacter(at offset: Int) -> String {
        switch bytes[offset] {
        case 0x27: return #"'\''"#
        case 0x5C: return #"'\\'"#
        case 0x0A: return #"'\n'"#
        case 0x0D: return #"'\r'"#
        case 0x09: return #"'\t'"#
        default:
            guard let scalar = scalar(at: offset) else { return "'\u{FFFD}'" }
            return "'\(Character(scalar))'"
        }
    }

    func escapeDigitValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: return UInt32(byte - 0x30)
        case 0x41...0x46: return UInt32(byte - 0x41 + 10)
        case 0x61...0x66: return UInt32(byte - 0x61 + 10)
        default: return nil
        }
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
        case 0x2E where peek(1) == 0x2E && peek(2) == 0x2E:
            kind = .identifier(GoSpread.spelling)
            advance()
            advance()
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
        case 0x2B where peek(1) == 0x3D:
            kind = .identifier("+=")
            advance()
        case 0x2D where peek(1) == 0x3D:
            kind = .identifier("-=")
            advance()
        case 0x2A where peek(1) == 0x3D:
            kind = .identifier("*=")
            advance()
        case 0x2F where peek(1) == 0x3D:
            kind = .identifier("/=")
            advance()
        case 0x25 where peek(1) == 0x3D:
            kind = .identifier("%=")
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
        case 0x3C where peek(1) == 0x3C:
            advance()
            if peek(1) == 0x3D {
                kind = .identifier("<<=")
                advance()
            } else {
                kind = .identifier(GoBitwiseOperator.shiftLeft.spelling)
            }
        case 0x3E where peek(1) == 0x3E:
            advance()
            if peek(1) == 0x3D {
                kind = .identifier(">>=")
                advance()
            } else {
                kind = .identifier(GoBitwiseOperator.shiftRight.spelling)
            }
        case 0x26 where peek(1) == 0x26:
            kind = .logicalAnd
            advance()
        case 0x26 where peek(1) == 0x5E:
            advance()
            if peek(1) == 0x3D {
                kind = .identifier("&^=")
                advance()
            } else {
                kind = .identifier(GoBitwiseOperator.andNot.spelling)
            }
        case 0x26 where peek(1) == 0x3D:
            kind = .identifier("&=")
            advance()
        case 0x26: kind = .ampersand
        case 0x7C where peek(1) == 0x7C:
            kind = .logicalOr
            advance()
        case 0x7C where peek(1) == 0x3D:
            kind = .identifier("|=")
            advance()
        case 0x7C: kind = .identifier(GoBitwiseOperator.or.spelling)
        case 0x5E where peek(1) == 0x3D:
            kind = .identifier("^=")
            advance()
        case 0x5E: kind = .identifier(GoBitwiseOperator.xor.spelling)
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
