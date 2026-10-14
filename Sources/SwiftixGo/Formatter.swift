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
        // Where a `func` begins a function literal: any other that is not a
        // declaration is a type, and no body follows it.
        var literals: Set<Int> = []
        func note(_ literal: GoExpression) { literals.insert(literal.position.offset) }
        for function in parsed.file.functions {
            GoFunctionLiterals.forEach(in: function.body, note)
        }
        for declaration in parsed.file.globalDeclarations {
            if let expression = declaration.expression {
                GoFunctionLiterals.forEach(in: expression, note)
            }
        }
        var printer = FormatPrinter(
            tokens: sortingImports(tokens), spacing: spacing, functionLiterals: literals,
            literalBraces: parsed.parentheses.literalBraces)
        return printer.render()
    }

    /// Sorts the imports of each `import ( ... )` group as Go's `gofmt`
    /// does: a run of imports on successive lines is put in the order of
    /// their paths, each with the comment at the end of its line, and an
    /// import that is there twice is kept once. An empty line or a comment
    /// on a line of its own ends a run.
    private static func sortingImports(_ tokens: [FormatToken]) -> [FormatToken] {
        var result = tokens
        var index = 0
        while index + 1 < result.count {
            defer { index += 1 }
            guard result[index].kind == .word, result[index].text == "import",
                result[index + 1].kind == .symbol, result[index + 1].text == "(",
                let close = result[(index + 2)...].firstIndex(where: {
                    $0.kind == .symbol && $0.text == ")"
                })
            else { continue }
            // Each import with what belongs to it: an alias before the path
            // and a comment after it on the same line.
            var runs: [[Range<Int>]] = []
            var cursor = index + 2
            var continuesRun = false
            while cursor < close {
                let token = result[cursor]
                if token.kind == .symbol, token.text == ";" {
                    // Two imports on one line are on successive lines too.
                    cursor += 1
                    continue
                }
                if token.kind == .lineComment || token.kind == .blockComment {
                    continuesRun = false
                    cursor += 1
                    continue
                }
                var end = cursor
                while end < close, result[end].kind != .literal { end += 1 }
                guard end < close else { break }
                end += 1
                while end < close, result[end].leadingNewlines == 0,
                    result[end].kind == .lineComment || result[end].kind == .blockComment
                {
                    end += 1
                }
                if continuesRun, token.leadingNewlines <= 1, !runs.isEmpty {
                    runs[runs.count - 1].append(cursor..<end)
                } else {
                    runs.append([cursor..<end])
                }
                continuesRun = true
                cursor = end
            }
            // Later runs first, so that the indexes of earlier ones hold.
            for run in runs.reversed() where run.count > 1 {
                func path(_ range: Range<Int>) -> String {
                    result[range].first { $0.kind == .literal }?.text ?? ""
                }
                func name(_ range: Range<Int>) -> String {
                    result[range].prefix { $0.kind != .literal }.map(\.text).joined()
                }
                func comment(_ range: Range<Int>) -> String {
                    result[range].filter { $0.kind == .lineComment || $0.kind == .blockComment }
                        .map(\.text).joined(separator: " ")
                }
                func precedes(_ left: String, _ right: String) -> Bool {
                    left.utf8.lexicographicallyPrecedes(right.utf8)
                }
                // By path, then alias, then comment: of two that are the
                // same, the one without a comment comes first.
                var sorted = run.enumerated().sorted { left, right in
                    let (a, b) = (left.element, right.element)
                    if path(a) != path(b) { return precedes(path(a), path(b)) }
                    if name(a) != name(b) { return precedes(name(a), name(b)) }
                    if comment(a) != comment(b) { return precedes(comment(a), comment(b)) }
                    return left.offset < right.offset
                }.map(\.element)
                // And goes, when the one after it is the same import.
                sorted = sorted.enumerated().filter { position, range in
                    guard position + 1 < sorted.count else { return true }
                    let following = sorted[position + 1]
                    return path(following) != path(range) || name(following) != name(range)
                        || !comment(range).isEmpty
                }.map(\.element)
                guard let first = run.first, let last = run.last else { continue }
                let leading = result[first.lowerBound].leadingNewlines
                var replacement: [FormatToken] = []
                for (position, range) in sorted.enumerated() {
                    // Without the `;` that may have stood between two.
                    var specification = Array(result[range])
                    specification[0] = specification[0].withLeadingNewlines(
                        position == 0 ? leading : 1)
                    replacement += specification
                }
                result.replaceSubrange(first.lowerBound..<last.upperBound, with: replacement)
            }
        }
        return result
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

    /// Whether this is a string literal, interpreted or raw.
    var isString: Bool { kind == .literal && (text.first == "\"" || text.first == "`") }

    /// Whether this is a raw string that goes on past the line it starts
    /// on: what follows it stands on another line than what precedes it.
    var spansLines: Bool { kind == .literal && text.first == "`" && text.contains("\n") }
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
            } else if isDigit(byte) || (byte == 0x2E && peek(1).map(isDigit) == true) {
                tokens.append(scanInteger(leadingNewlines: newlines))
            } else if byte == 0x22 || byte == 0x27 {
                tokens.append(try scanString(leadingNewlines: newlines))
            } else if byte == 0x60 {
                tokens.append(try scanRawString(leadingNewlines: newlines))
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
        // Keeps a prefixed or separated literal (`0x1f`, `0o644`, `1_000`) whole,
        // and a floating-point one with its point and its signed exponent
        // (`1.5`, `.5`, `1e-9`, `0x1p-2`).
        let start = index
        let isHexadecimal = bytes[index] == 0x30 && peek(1).map { $0 | 0x20 } == 0x78
        var hasPoint = false
        var hasExponent = false
        while index < bytes.count {
            let byte = bytes[index]
            if isIdentifierContinue(byte), byte < 0x80 {
                if (byte | 0x20) == (isHexadecimal ? 0x70 : 0x65), index > start {
                    // The marker of an exponent takes the sign after it.
                    hasExponent = hasExponent || isHexadecimal || !bytes[start..<index].contains(0x78)
                    index += 1
                    if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D,
                        peek(1).map(isDigit) == true
                    {
                        index += 1
                    }
                    continue
                }
                index += 1
            } else if byte == 0x2E, !hasPoint, !hasExponent {
                hasPoint = true
                index += 1
            } else {
                break
            }
        }
        let literal = token(.literal, from: start, leadingNewlines: leadingNewlines)
        return FormatToken(
            kind: .literal, text: Self.normalizedNumber(literal.text),
            leadingNewlines: leadingNewlines, offset: start)
    }

    /// A numeric literal as Go's `gofmt` writes it: the letter of a base
    /// prefix and of an exponent in lower case, the digits as they are.
    static func normalizedNumber(_ literal: String) -> String {
        var text = Array(literal.utf8)
        guard text.count >= 2 else { return literal }
        func lowerLast(_ letter: UInt8) {
            if let index = text.lastIndex(of: letter) { text[index] = letter | 0x20 }
        }
        if text[0] == 0x30, [0x58, 0x4F, 0x42, 0x78].contains(text[1]) {
            let isHexadecimal = (text[1] | 0x20) == 0x78
            text[1] |= 0x20
            if isHexadecimal { lowerLast(0x50) }
        } else if !(text[0] == 0x30 && [0x6F, 0x62].contains(text[1])) {
            lowerLast(0x45)
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// A string or a rune literal, kept as the source has it.
    mutating func scanString(leadingNewlines: Int) throws -> FormatToken {
        let start = index
        let quote = bytes[index]
        index += 1
        while index < bytes.count {
            if bytes[index] == quote {
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

    /// A raw string literal, kept as the source has it, the lines inside it
    /// too: only its carriage returns go, which are no part of its value.
    mutating func scanRawString(leadingNewlines: Int) throws -> FormatToken {
        let start = index
        index += 1
        while index < bytes.count {
            index += 1
            guard bytes[index - 1] == 0x60 else { continue }
            return FormatToken(
                kind: .literal,
                text: String(decoding: bytes[start..<index].filter { $0 != 0x0D }, as: UTF8.self),
                leadingNewlines: leadingNewlines,
                offset: start)
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

/// One printed line: its indentation, the cells whose columns are aligned
/// with those of the lines around it, and the text after the last cell.
///
/// Go's printer writes through a tabwriter: a cell ends where the printer
/// puts a tab, after the name of a struct field, before a trailing comment,
/// before the body of a one-line function, and after the key of a composite
/// literal element. Cells in the same column of consecutive lines get one
/// width; `FormatLine.aligned` is that step.
private struct FormatLine: Equatable {
    var indent: Int
    var cells: [String] = []
    var tail: String = ""
    /// Whether alignment starts over at this line, as after a formfeed of
    /// Go's printer: a case clause, a function that spans several lines.
    var startsSection = false

    var isBlank: Bool { cells.isEmpty && tail.isEmpty }

    /// The lines as text. A column is a run of consecutive lines of one
    /// indentation that all have a cell at that position; each cell is
    /// padded to the widest of the run plus one blank, and the columns to
    /// its right are aligned within the run.
    static func aligned(_ lines: [FormatLine]) -> [String] {
        var widths = lines.map { [Int](repeating: 0, count: $0.cells.count) }
        func width(_ text: String) -> Int { text.unicodeScalars.count }
        func align(_ range: Range<Int>, column: Int) {
            var index = range.lowerBound
            while index < range.upperBound {
                guard lines[index].cells.count > column else {
                    index += 1
                    continue
                }
                let start = index
                var widest = 0
                var isEmpty = true
                while index < range.upperBound, lines[index].cells.count > column,
                    lines[index].indent == lines[start].indent,
                    index == start || !lines[index].startsSection
                {
                    widest = max(widest, width(lines[index].cells[column]) + 1)
                    if !lines[index].cells[column].isEmpty { isEmpty = false }
                    index += 1
                }
                // A column no line has anything in takes no room, as with
                // the tabwriter Go's printer writes through.
                if isEmpty { widest = 0 }
                for line in start..<index { widths[line][column] = widest }
                align(start..<index, column: column + 1)
            }
        }
        align(lines.indices, column: 0)
        return lines.enumerated().map { index, line in
            guard !line.isBlank else { return "" }
            var text = String(repeating: "\t", count: max(0, line.indent))
            for (column, cell) in line.cells.enumerated() {
                text += cell
                text += String(
                    repeating: " ", count: max(0, widths[index][column] - width(cell)))
            }
            return text + line.tail
        }
    }
}

/// A construct of the statement being written in which the source broke a
/// line, or may: what follows the break is indented one level more until
/// the construct ends, as Go's printer does.
private struct FormatContinuation {
    enum Kind: Equatable {
        /// The right operand of a binary operator of this precedence.
        case binary(precedence: Int)
        /// The arguments of a call or the elements of a composite literal,
        /// between the delimiter at this offset and its partner.
        case list(opener: Int, isLiteral: Bool)
        /// The values of an assignment, a `return`, or a `case`, which no
        /// delimiters enclose: to the end of the statement.
        case statementList
        /// What follows a `.`, up to the token at this index.
        case selector(end: Int)
    }

    let kind: Kind
    /// The nesting the construct stands at: the depths inside a list's own
    /// delimiters, and those around an operator.
    let parenthesisDepth: Int
    let bracketDepth: Int
    let braceDepth: Int
    /// Whether a line was broken in it, so that it indents what follows.
    var indented = false
    /// For a list: whether the element being written began a line.
    var elementBeganLine = false
    /// For a list: how many source line breaks there were before it opened,
    /// which tells whether one fell inside it.
    var sourceBreaksAtOpen = 0
    /// For a list: the index of the element being written, and of the last
    /// one that began a line.
    var elementIndex = 0
    var lastElementThatBeganLine = -1
    /// For a list: whether the size of the element being written is known.
    var hasMeasuredElement = false
    /// For a list: whether the source breaks a line inside it, once that
    /// has been looked up. The sizes of its elements matter only then.
    var spansLines: Bool?
    /// For a list: the size of the element before the one being written,
    /// and the sum of the logarithms and the number of the sizes so far. Go's
    /// printer starts a new section of columns where a size leaves their
    /// geometric mean far behind.
    var previousSize = 0
    var logSizeSum = 0.0
    var sizeCount = 0

    var isList: Bool {
        if case .list = kind { return true }
        return false
    }
}

/// How a specification of a `var` or `const` group is written in columns,
/// as Go's printer decides for the group as a whole.
private struct FormatValueSpecification: Equatable {
    var hasType = false
    var hasValues = false
    /// Whether the column of types is kept although this one has none:
    /// some value in the same run of specifications has a type.
    var keepsTypeColumn = false
}

/// What the printer knows of a header it is in the middle of: the signature
/// of a function, or the clause of a `for`, `if`, or `switch`.
private struct FormatHeader {
    let pendingFunction: Bool
    let pendingFunctionIsType: Bool
    let pendingIf: Bool
    let pendingSwitch: Bool
    let forHeader: Bool

    var isOpen: Bool { pendingFunction || pendingIf || pendingSwitch || forHeader }
}

/// An open `import (`, `var (`, `const (`, or `type (` group.
private struct FormatGroup {
    let keyword: String
    let parenthesisDepth: Int
    let braceDepth: Int
    /// The shapes of the specifications of a `var` or `const` group that
    /// has several; empty for any other group.
    var specifications: [FormatValueSpecification] = []
    /// Whether the group has several specifications.
    var hasSeveral = false
    /// How many specifications have begun.
    var begun = 0
    /// Whether it is written `()`, having nothing in it.
    var isEmpty = false
    /// Whether its lines are indented: Go's printer indents the
    /// specifications, so a group that holds only a comment has none.
    var indents = true
}

private struct FormatPrinter {
    let tokens: [FormatToken]
    /// Which operators and slice colons Go's printer spaces differently.
    let spacing: GoOperatorSpacing
    /// The offsets of the `func` keywords that begin function literals.
    let functionLiterals: Set<Int>
    /// The offsets of the `{` that open composite literals, as the parser
    /// found them: every other brace opens a block or the body of a type.
    let literalBraces: Set<Int>
    var lines: [FormatLine] = []
    /// The cells of the line being written, and the text after the last one.
    var cells: [String] = []
    var current = ""
    /// The indentation of the line being written, fixed when it begins.
    var lineIndent: Int?
    /// Whether the line being written starts a section of its own.
    var lineStartsSection = false
    /// Whether the line being written declares a field of a struct, whose
    /// name is a cell.
    var lineIsStructField = false
    /// Whether the field being written is an embedded one, and whether the
    /// line has come to the field's tag.
    var lineIsEmbeddedField = false
    var lineHasTag = false
    /// Whether the line being written begins with the `}` that ends the
    /// type of a struct field.
    var lineClosesFieldType = false
    /// Whether the line written last ended in a `//` comment after code.
    var previousLineHadTrailingComment = false
    /// Whether the line written last holds a raw string of several lines:
    /// Go's printer starts the columns over after what spans lines.
    var previousLineSpannedLines = false
    /// Whether the line being written has such a string already.
    var lineEndsAlignment = false
    /// Brace depths of `struct` bodies.
    var structBodyDepths: Set<Int> = []
    /// Index in `tokens` of the token being handled.
    var position = 0
    /// Bodies written on one line, by brace depth: where the text of the
    /// body starts on the line, and how many statements it has so far.
    var oneLineBodies: [Int: (start: Int, statements: Int)] = [:]
    /// The size and statement count of the one-line body closed last.
    var closedOneLineBody: (size: Int, statements: Int)?
    /// Where on its line the `func` of the signature being written starts.
    var functionStart = 0
    /// Whether the line being written is a function declaration.
    var lineIsFunctionDeclaration = false
    /// The constructs of the statement being written that lines can break
    /// in, innermost last.
    var continuations: [FormatContinuation] = []
    /// The parenthesis depth each open block was opened at: a statement
    /// inside it ends where the depth is back at that.
    var blockBases: [Int] = []
    /// The last token that was not a comment.
    var previousCode: FormatToken?
    /// The brace depth of the `case` or `default` whose colon is to come.
    var pendingCaseDepth: Int?
    /// How many tokens so far began a line in the source.
    var sourceLineBreaks = 0
    /// False in a copy of the printer that writes something only to measure
    /// it: such a copy measures nothing itself.
    var measuresElements = true
    /// The declaration groups that are open, innermost last.
    var groups: [FormatGroup] = []
    /// Whether the next line written in the innermost group begins a
    /// specification of it.
    var groupAwaitsSpecification = false
    /// The shape of the `var` or `const` specification the line being
    /// written begins, when its group aligns columns, and how far the line
    /// has come: 0 while a name is expected, 1 after a name, 2 in the type,
    /// 3 in the values.
    var lineSpecification: FormatValueSpecification?
    var specificationPhase = 0
    var indent = 0
    var braceDepth = 0
    var parenthesisDepth = 0
    var forHeader = false
    var pendingIf = false
    var pendingFunction = false
    /// Whether the `func` being printed is a function type, `func(int) int`,
    /// which no body follows: a `{` after it opens a literal of a type
    /// that ends in it, `[]func(){a, b}`.
    var pendingFunctionIsType = false
    /// The parenthesis depth at which that type is written.
    var functionTypeDepth = 0
    /// For each open parenthesis, whether it holds the parameters of a
    /// `func` that has no name: a literal's or a type's.
    var parameterLists: [Bool] = []
    /// Whether the token just printed is the `)` of such a list.
    var closesParameterList = false
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
    /// The header a type body stands in, by the brace depth of the body: a
    /// struct type written out in the parameters of a function or in the
    /// clause of a `for`, `if`, or `switch`. Its lines are those of a type,
    /// and what it interrupted goes on where it ends.
    var suspendedHeaders: [Int: FormatHeader] = [:]
    /// Whether the token being handled follows the name of a label, whose
    /// colon it is; whether that colon is the token before the one being
    /// handled; and whether a comment stands between a label and the
    /// statement it names, which begins a line of its own.
    var pendingLabel = false
    var followsLabel = false
    var labelAwaitsStatement = false

    mutating func render() -> String {
        for (index, token) in tokens.enumerated() {
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            position = index
            if token.leadingNewlines > 0 { sourceLineBreaks += 1 }
            closeContinuations(before: token)
            handleLeadingNewlines(for: token)
            handle(token, next: next)
        }
        finishLine()
        while lines.last?.isBlank == true { lines.removeLast() }
        return FormatLine.aligned(lines).joined(separator: "\n") + "\n"
    }

    /// Whether nothing has been written on the current line.
    var lineIsEmpty: Bool { current.isEmpty && cells.isEmpty }

    /// Ends the cell being written: what follows starts the next column.
    mutating func endCell() {
        trimTrailingWhitespace()
        if lineEndsAlignment {
            // After a raw string of several lines Go's printer aligns
            // nothing more on the line: a blank stands where a column
            // would have ended.
            current += " "
            return
        }
        cells.append(current)
        current = ""
    }

    /// Makes the name of a struct field a cell of its own. A field without a
    /// name, an embedded type, has no blank and stays one piece.
    mutating func endStructFieldName() {
        // The names of a field list, `X, Y int`, are one cell: the blank
        // that ends them is the first that follows no comma.
        guard lineIsStructField, cells.isEmpty else { return }
        guard
            let blank = current.indices.first(where: { index in
                current[index] == " " && index > current.startIndex
                    && current[current.index(before: index)] != ","
            })
        else {
            lineIsEmbeddedField = structBodyDepths.contains(braceDepth)
            return
        }
        cells.append(String(current[..<blank]))
        current = String(current[current.index(after: blank)...])
    }

    /// Gives an embedded field, which has no name, the empty column Go's
    /// printer puts after its type before a comment: the type stands in
    /// the column of names, and the comment with those of the fields
    /// around it. Called when the type has just become a cell.
    mutating func endEmbeddedFieldType() {
        guard lineIsStructField, lineIsEmbeddedField, cells.count == 1, !lineEndsAlignment
        else { return }
        cells.append("")
    }

    /// Ends the columns before the tag of a struct field, the string
    /// literal `token`, as Go's printer has them: after the name and the
    /// type an empty column, where the comment of a field without a tag
    /// stands; after an embedded type nothing more.
    mutating func beginStructTag(_ token: FormatToken) {
        guard token.isString, lineIsStructField, structBodyDepths.contains(braceDepth),
            parenthesisDepth == statementBase, sliceBrackets.isEmpty, !lineIsEmpty,
            !lineHasTag
        else { return }
        lineHasTag = true
        endStructFieldName()
        let isEmbedded = cells.isEmpty
        endCell()
        if !isEmbedded { cells.append("") }
    }

    mutating func handleLeadingNewlines(for token: FormatToken) {
        guard token.leadingNewlines > 0 else { return }
        if token.text == "else", previous?.text == "}" { return }
        if let kept = breaksExpression(before: token) {
            // A line break the source has inside an expression. An empty
            // line there is kept as well, except before the delimiter that
            // closes a list.
            if kept, token.leadingNewlines > 1, lineIsEmpty, !lines.isEmpty { appendBlankLine() }
            return
        }
        if parenthesisDepth == statementBase, !forHeader,
            !compositeDepths.contains(braceDepth), canEndLine(previous)
        {
            // The statement ends here, also where a comment at the end of
            // its line has ended the line already.
            finishLine()
            endStatement()
        }
        // Go's printer starts the body of a struct or an interface with its
        // first field and ends it with its last: empty lines after `{` and
        // before `}` go. A block of statements keeps them.
        let isAtEdgeOfTypeBody =
            typeBodyDepths.contains(braceDepth)
            && (previous?.text == "{" || (token.text == "}" && token.kind == .symbol))
        // A group of declarations is laid out the same way.
        let isAtEdgeOfGroup =
            isAtGroupLevel
            && ((groups.last?.begun == 0 && previous?.text == "(")
                || (token.text == ")" && token.kind == .symbol))
        if token.leadingNewlines > 1, lineIsEmpty, !lines.isEmpty, !isAtEdgeOfTypeBody,
            !isAtEdgeOfGroup
        {
            appendBlankLine()
        }
    }

    // MARK: Line breaks inside a statement

    /// The parenthesis depth statements of the innermost block stand at.
    var statementBase: Int { blockBases.last ?? 0 }

    /// One level for each construct a line was broken in.
    var continuationIndent: Int { continuations.lazy.filter(\.indented).count }

    func continuation(
        _ kind: FormatContinuation.Kind,
        indented: Bool = false
    ) -> FormatContinuation {
        FormatContinuation(
            kind: kind, parenthesisDepth: parenthesisDepth, bracketDepth: sliceBrackets.count,
            braceDepth: braceDepth, indented: indented, sourceBreaksAtOpen: sourceLineBreaks)
    }

    /// The natural logarithm, which the standard library has only with a
    /// platform's C library: the mantissa's by the series of the inverse
    /// hyperbolic tangent, and the exponent's share added.
    static func naturalLogarithm(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        let mantissa = value.significand
        let ratio = (mantissa - 1) / (mantissa + 1)
        var term = ratio
        var sum = 0.0
        var divisor = 1.0
        for _ in 0..<24 {
            sum += term / divisor
            term *= ratio * ratio
            divisor += 2
        }
        return 2 * sum + Double(value.exponent) * 0.693_147_180_559_945_3
    }

    /// The size Go's printer gives the list element that starts at `start`:
    /// the width of its key when it is a `key: value` of a literal, else its
    /// own width, and 0 when the element does not stay on one line.
    func elementSize(startingAt start: Int, isLiteral: Bool) -> Int {
        var depth = 0
        var end = tokens.count
        var colon: Int?
        scan: for index in start..<tokens.count {
            let token = tokens[index]
            if index > start, token.leadingNewlines > 0 { return 0 }
            if token.kind == .lineComment || token.kind == .blockComment { return 0 }
            if token.spansLines { return 0 }
            guard token.kind == .symbol else { continue }
            switch token.text {
            case "(", "[", "{": depth += 1
            case ")", "]", "}":
                if depth == 0 {
                    end = index
                    break scan
                }
                depth -= 1
            case ",":
                if depth == 0 {
                    end = index
                    break scan
                }
            case ":":
                if depth == 0, isLiteral, colon == nil { colon = index }
            default: break
            }
        }
        let limit = colon ?? end
        guard limit > start else { return 0 }
        var probe = self
        probe.measuresElements = false
        probe.cells = []
        probe.current = ""
        for index in start..<limit {
            probe.position = index
            probe.closeContinuations(before: tokens[index])
            probe.handle(tokens[index], next: index + 1 < tokens.count ? tokens[index + 1] : nil)
            guard probe.lines.count == lines.count else { return 0 }
        }
        var written = probe.cells.joined(separator: " ") + probe.current
        while written.last == " " { written.removeLast() }
        while written.first == " " { written.removeFirst() }
        return Self.width(written)
    }

    /// Notes the size of the element of list `index` that starts at token
    /// `start`, and returns whether a line that begins with it starts a new
    /// section of columns: Go's printer keeps consecutive elements in one
    /// section while their sizes are small or of one magnitude.
    mutating func beginElement(
        ofList index: Int,
        at start: Int,
        beginsLine: Bool,
        afterEmptyLine: Bool
    ) -> Bool {
        guard measuresElements, case .list(_, let isLiteral) = continuations[index].kind,
            !continuations[index].hasMeasuredElement
        else { return false }
        continuations[index].hasMeasuredElement = true
        var list = continuations[index]
        let size = elementSize(startingAt: start, isLiteral: isLiteral)
        var separates = true
        if list.previousSize > 0, size > 0 {
            if list.sizeCount == 0 || (list.previousSize <= 40 && size <= 40) {
                separates = false
            } else {
                let threshold = Self.naturalLogarithm(2.5)
                let ratio =
                    Self.naturalLogarithm(Double(size)) - list.logSizeSum / Double(list.sizeCount)
                separates = threshold + ratio <= 0 || threshold <= ratio
            }
        }
        var startsSection = false
        if beginsLine {
            // The first break of a list always starts a section, and so does
            // a line after one that held several elements.
            startsSection =
                list.elementIndex == 0 || separates
                || list.lastElementThatBeganLine + 1 < list.elementIndex
            list.lastElementThatBeganLine = list.elementIndex
            if afterEmptyLine, list.elementIndex > 0 {
                list.logSizeSum = 0
                list.sizeCount = 0
            }
        }
        if size > 0 {
            list.logSizeSum += Self.naturalLogarithm(Double(size))
            list.sizeCount += 1
        }
        list.previousSize = size
        continuations[index] = list
        return startsSection
    }

    /// `hasSourceBreakAhead` for list `index`, looked up once.
    mutating func spansLines(list index: Int) -> Bool {
        if let known = continuations[index].spansLines { return known }
        let found = hasSourceBreakAhead(inList: index)
        continuations[index].spansLines = found
        return found
    }

    /// Whether the list `index`, whose element starts at `position`, spans
    /// lines in the source: only then do the sizes of its elements matter.
    func hasSourceBreakAhead(inList index: Int) -> Bool {
        if sourceLineBreaks > continuations[index].sourceBreaksAtOpen { return true }
        var depth = 0
        for ahead in position..<tokens.count {
            let token = tokens[ahead]
            if ahead > position, token.leadingNewlines > 0 { return true }
            if token.spansLines { return true }
            guard token.kind == .symbol else { continue }
            switch token.text {
            case "(", "[", "{": depth += 1
            case ")", "]", "}":
                if depth == 0 { return false }
                depth -= 1
            default: break
            }
        }
        return false
    }

    /// Whether a source line break fell inside list `index` before the
    /// token being handled.
    func hasSourceBreak(inList index: Int, before token: FormatToken) -> Bool {
        sourceLineBreaks - (token.leadingNewlines > 0 ? 1 : 0) > continuations[index].sourceBreaksAtOpen
    }

    func isAtDepth(of scope: FormatContinuation) -> Bool {
        scope.parenthesisDepth == parenthesisDepth && scope.bracketDepth == sliceBrackets.count
            && scope.braceDepth == braceDepth
    }

    /// The constructs of the statement end with it.
    mutating func endStatement() {
        continuations.removeAll { $0.braceDepth >= braceDepth }
        if isAtGroupLevel { groupAwaitsSpecification = true }
        // A function type has no body to end it.
        if pendingFunctionIsType {
            pendingFunction = false
            pendingFunctionIsType = false
        }
    }

    // MARK: Declaration groups

    /// Whether the tokens being handled stand directly in the innermost
    /// declaration group, not inside a bracket or a block within it.
    var isAtGroupLevel: Bool {
        guard let group = groups.last else { return false }
        return group.parenthesisDepth == parenthesisDepth && group.braceDepth == braceDepth
            && sliceBrackets.isEmpty && !group.isEmpty
    }

    /// The shapes of the specifications of the `var` or `const` group that
    /// opens at `position`, and how many there are. A specification begins
    /// where a line does after one is complete.
    func groupSpecifications() -> [FormatValueSpecification] {
        var specifications: [FormatValueSpecification] = []
        var depth = 0
        var index = position + 1
        var beginsSpecification = true
        var lastCode: FormatToken?
        // Where in its specification the scan is: 0 expects a name, 1 has
        // one, 2 is past the names.
        var phase = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token.kind == .lineComment || token.kind == .blockComment { continue }
            if depth == 0, token.kind == .symbol, token.text == ")" { break }
            if depth == 0, token.kind == .symbol, token.text == ";" {
                beginsSpecification = true
                continue
            }
            if depth == 0, token.leadingNewlines > 0, canEndLine(lastCode) {
                beginsSpecification = true
            }
            lastCode = token
            if depth == 0, beginsSpecification {
                specifications.append(FormatValueSpecification())
                beginsSpecification = false
                phase = 0
            }
            if token.kind == .symbol {
                switch token.text {
                case "(", "[", "{": depth += 1
                case ")", "]", "}": depth -= 1
                default: break
                }
            }
            guard depth == 0 || phase < 2, !specifications.isEmpty else { continue }
            let last = specifications.count - 1
            if phase == 0, token.kind == .word {
                phase = 1
            } else if phase == 1, token.kind == .symbol, token.text == "," {
                phase = 0
            } else if phase < 2 {
                // The first token after the names: `=`, or a type.
                phase = 2
                if token.text == "=" {
                    specifications[last].hasValues = true
                } else {
                    specifications[last].hasType = true
                }
            } else if depth == 0, token.kind == .symbol, token.text == "=" {
                specifications[last].hasValues = true
            }
        }
        // Go's printer keeps the column of types for a run of consecutive
        // specifications with values when one of them has a type.
        var runStart: Int?
        var keepsType = false
        func close(_ end: Int) {
            if let start = runStart, keepsType {
                for index in start..<end { specifications[index].keepsTypeColumn = true }
            }
        }
        for index in specifications.indices {
            if specifications[index].hasValues {
                if runStart == nil {
                    runStart = index
                    keepsType = false
                }
            } else if runStart != nil {
                close(index)
                runStart = nil
            }
            if specifications[index].hasType { keepsType = true }
        }
        close(specifications.count)
        return specifications
    }

    /// Opens the group whose `(` is the token at `position`.
    mutating func openGroup(_ keyword: String, next: FormatToken?) {
        ensureSpace()
        append("(")
        var group = FormatGroup(
            keyword: keyword, parenthesisDepth: parenthesisDepth, braceDepth: braceDepth)
        if next?.kind == .symbol, next?.text == ")" {
            group.isEmpty = true
            groups.append(group)
            return
        }
        let specifications = groupSpecifications()
        group.hasSeveral = specifications.count > 1
        if keyword == "var" || keyword == "const", group.hasSeveral {
            group.specifications = specifications
        }
        group.indents = !specifications.isEmpty
        finishLine(unlessCommentFollows: next)
        blockBases.append(parenthesisDepth)
        if group.indents { indent += 1 }
        groups.append(group)
        groupAwaitsSpecification = true
    }

    /// Closes the innermost group at its `)`.
    mutating func closeGroup() {
        guard let group = groups.popLast() else { return }
        if group.isEmpty {
            append(")")
            return
        }
        if !lineIsEmpty { finishLine() }
        endStatement()
        _ = blockBases.popLast()
        groupAwaitsSpecification = false
        if group.indents { indent -= 1 }
        append(")")
    }

    /// Begins a specification of the innermost group on the line that is
    /// about to be written.
    mutating func beginSpecification() {
        guard groupAwaitsSpecification, isAtGroupLevel, let index = groups.indices.last else {
            return
        }
        groupAwaitsSpecification = false
        let group = groups[index]
        groups[index].begun += 1
        switch group.keyword {
        case "var", "const":
            // What follows the names is a type, until the `=`.
            pendingVariableDeclaration = true
            if group.begun < group.specifications.count {
                lineSpecification = group.specifications[group.begun]
                specificationPhase = 0
            }
        case "type":
            pendingTypeDeclaration = true
            // The names of the types of a group are a column.
            lineIsStructField = group.hasSeveral
        default:
            break
        }
    }

    /// Ends the cells of a `var` or `const` specification where Go's
    /// printer does: after the names when a type follows or its column is
    /// kept, and before the `=`.
    mutating func advanceSpecification(at token: FormatToken) {
        guard let specification = lineSpecification, isAtGroupLevel else { return }
        if specificationPhase == 0, token.kind == .word {
            specificationPhase = 1
            return
        }
        if specificationPhase == 1, token.kind == .symbol, token.text == "," {
            specificationPhase = 0
            return
        }
        if specificationPhase < 2 {
            if specification.hasType || specification.keepsTypeColumn { endCell() }
            specificationPhase = 2
        }
        if specificationPhase == 2, token.kind == .symbol, token.text == "=" {
            endCell()
            specificationPhase = 3
        }
    }

    /// Ends the binary expressions whose right operand `token` is past: an
    /// operator that binds no tighter, or anything that closes or separates
    /// what the expression stands in.
    mutating func closeContinuations(before token: FormatToken) {
        guard token.kind == .symbol else { return }
        while let last = continuations.last, case .binary(let precedence) = last.kind,
            isAtDepth(of: last)
        {
            let ends =
                spacing.binaryOperators[token.offset].map { $0 <= precedence } ?? false
                || [",", ";", ":", ")", "]", "}", "=", ":="].contains(token.text)
            guard ends else { break }
            continuations.removeLast()
        }
    }

    /// Whether the element whose key ends at `position` is written on one
    /// line in the source: up to the comma or the delimiter that ends it,
    /// no token begins a line. Go's printer puts only such a value in the
    /// column of its neighbors.
    func elementStaysOnItsLine() -> Bool {
        var depth = 0
        for index in (position + 1)..<tokens.count {
            let token = tokens[index]
            if token.leadingNewlines > 0 || token.spansLines { return false }
            guard token.kind == .symbol else { continue }
            switch token.text {
            case "(", "[", "{": depth += 1
            case ")", "]", "}":
                if depth == 0 { return true }
                depth -= 1
            case ",":
                if depth == 0 { return true }
            default: break
            }
        }
        return true
    }

    /// Keeps a line break the source has where Go's printer keeps one: after
    /// a binary operator, between the elements of a list, before the
    /// delimiter that closes a list after a final comma, after `=`, and
    /// after `.`. Returns false for a break that ends a statement or that
    /// Go's printer does not keep.
    ///
    /// The result is nil for such a break, true for a break that is kept,
    /// and false for one inside an expression that is dropped or that takes
    /// no empty line before it.
    mutating func breaksExpression(before token: FormatToken) -> Bool? {
        guard let anchor = previousCode else { return nil }
        let isComment = token.kind == .lineComment || token.kind == .blockComment
        let innermostList = continuations.lastIndex { $0.isList && isAtDepth(of: $0) }
        if let index = innermostList, case .list(_, let isLiteral) = continuations[index].kind,
            token.kind == .symbol, token.text == (isLiteral ? "}" : ")"),
            index == continuations.count - 1
        {
            // The closing delimiter on a line of its own goes back to where
            // the list began, after the comma Go requires there. Where the
            // list was all on the line of its opening delimiter, Go's
            // printer closes it on that line too.
            guard anchor.text == ",", hasSourceBreak(inList: index, before: token) else {
                return false
            }
            continuations[index].indented = false
            finishLine()
            return false
        }
        if !isComment, anchor.kind == .symbol,
            let precedence = spacing.binaryOperators[anchor.offset]
        {
            finishLine()
            continuations.append(continuation(.binary(precedence: precedence), indented: true))
            return true
        }
        if let index = innermostList, case .list(let opener, _) = continuations[index].kind,
            anchor.text == "," || anchor.offset == opener
        {
            continuations[index].indented = true
            continuations[index].elementBeganLine = true
            finishLine()
            if !isComment,
                beginElement(
                    ofList: index, at: position, beginsLine: true,
                    afterEmptyLine: token.leadingNewlines > 1)
            {
                lineStartsSection = true
            }
            return true
        }
        if isComment { return nil }
        let isAtStatementLevel =
            parenthesisDepth == statementBase && !compositeDepths.contains(braceDepth)
            && sliceBrackets.isEmpty
        if isAtStatementLevel,
            anchor.text == "," || anchor.text == "=" || anchor.text == ":="
                || GoCompoundAssignment(spelling: anchor.text) != nil
        {
            // Values that no delimiters enclose: `a, b = x,` / `y`.
            if !continuations.contains(where: {
                $0.kind == .statementList && $0.braceDepth == braceDepth
            }) {
                continuations.append(continuation(.statementList, indented: true))
            }
            finishLine()
            return true
        }
        if anchor.text == ".", token.kind == .word {
            // A method call ends with its arguments, a field with its name.
            var end = position
            if position + 1 < tokens.count, tokens[position + 1].text == "(" {
                var depth = 0
                for index in (position + 1)..<tokens.count where tokens[index].kind == .symbol {
                    if tokens[index].text == "(" {
                        depth += 1
                    } else if tokens[index].text == ")" {
                        depth -= 1
                        if depth == 0 {
                            end = index
                            break
                        }
                    }
                }
            }
            finishLine()
            continuations.append(continuation(.selector(end: end), indented: true))
            return true
        }
        return nil
    }

    mutating func handle(_ token: FormatToken, next: FormatToken?) {
        if token.kind == .lineComment {
            let isStandaloneTopLevelComment = braceDepth == 0 && lineIsEmpty && groups.isEmpty
            beginTopLevelCommentIfNeeded(isStandaloneTopLevelComment)
            if !lineIsEmpty {
                // A comment after code is a column of its own, aligned with
                // the comments of the lines around it.
                endStructFieldName()
                endCell()
                endEmbeddedFieldType()
                if let specification = lineSpecification, isAtGroupLevel {
                    // Go's printer has four columns in a `var` or `const`
                    // group, names, types, values, and comments; the ones a
                    // specification lacks are empty cells before its comment.
                    let present =
                        (specification.hasType || specification.keepsTypeColumn ? 1 : 0)
                        + (specification.hasValues ? 1 : 0)
                    for _ in 0..<(2 - present) { endCell() }
                }
            }
            let standsAlone = lineIsEmpty
            // A comment on a line of its own begins no specification of a
            // group, and is no field of a struct.
            let awaitsSpecification = groupAwaitsSpecification
            if standsAlone { groupAwaitsSpecification = false }
            append(token.text)
            if standsAlone {
                lineIsStructField = false
                groupAwaitsSpecification = awaitsSpecification
            }
            finishLine()
            previous = token
            previousWasUnaryOperator = false
            return
        }
        if token.kind == .blockComment {
            let isStandaloneTopLevelComment = braceDepth == 0 && lineIsEmpty && groups.isEmpty
            beginTopLevelCommentIfNeeded(isStandaloneTopLevelComment)
            if !lineIsEmpty, next.map({ $0.leadingNewlines > 0 }) ?? true {
                // The last thing on its line, it is a column like a `//`
                // comment there.
                endStructFieldName()
                endCell()
                endEmbeddedFieldType()
            } else if !current.isEmpty {
                ensureSpace()
            }
            appendBlockComment(token.text)
            previous = token
            previousWasUnaryOperator = false
            return
        }

        if measuresElements,
            let index = continuations.lastIndex(where: { $0.isList && isAtDepth(of: $0) }),
            !continuations[index].hasMeasuredElement,
            spansLines(list: index)
        {
            // An element on the line of the one before it: its size still
            // counts for the lines that follow.
            _ = beginElement(ofList: index, at: position, beginsLine: false, afterEmptyLine: false)
        }

        if braceDepth == 0, lineIsEmpty,
            token.text == "package" || token.text == "import" || token.text == "type"
                || token.text == "var" || token.text == "const" || token.text == "func"
        {
            beginTopLevelDeclaration(token.text)
        }

        if labelAwaitsStatement {
            // The statement after a label and the comment beside it.
            labelAwaitsStatement = false
            if !lineIsEmpty { finishLine() }
        }
        let closedLabel = followsLabel
        followsLabel = false
        if isLabel(token, next: next) {
            beginLabel(token)
            return
        }

        // A function type ends where what it stands in goes on: at the
        // parenthesis that closes around it, or at a separator beside it.
        if pendingFunction, pendingFunctionIsType, parenthesisDepth <= functionTypeDepth,
            [")", ",", ";", "=", ":=", "}", ":"].contains(token.text)
        {
            pendingFunction = false
            pendingFunctionIsType = false
        }
        // Whether the `)` before this token closed the parameters of a
        // `func`: a `(` that follows opens its results.
        let closedParameterList = closesParameterList
        closesParameterList = false
        let followsFunctionType = pendingFunction && pendingFunctionIsType
        if followsFunctionType, token.text == "{", literalBraces.contains(token.offset) {
            // The type was the last part of a literal's type.
            pendingFunction = false
            pendingFunctionIsType = false
        }
        let followsTypeBracket = afterTypeBracket
        afterTypeBracket = false
        if lineIsEmpty { beginSpecification() }
        advanceSpecification(at: token)

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
            let isLiteral = functionLiterals.contains(token.offset)
            if !pendingFunction || (isLiteral && pendingFunctionIsType) {
                if shouldSeparateWord(kind: token.kind) { ensureSpace() }
                functionStart = Self.width(current)
                lineIsFunctionDeclaration = lineIsEmpty && braceDepth == 0
                pendingFunctionIsType = !isLiteral && !lineIsFunctionDeclaration
                functionTypeDepth = parenthesisDepth
            }
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
        case "(" where previous?.kind == .word
            && ["import", "var", "const", "type"].contains(previous?.text ?? ""):
            openGroup(previous?.text ?? "", next: next)
        case ")" where groups.last.map({
            $0.parenthesisDepth == parenthesisDepth && $0.braceDepth == braceDepth
        }) ?? false:
            closeGroup()
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
            // The result list of a function signature: `func f() (int, error)`,
            // also of a function type or literal written inside parentheses.
            if previous?.text == ")",
                closedParameterList
                    || ((pendingFunction || typeBodyDepths.contains(braceDepth))
                        && parenthesisDepth == 0)
            {
                ensureSpace()
            }
            append("(")
            parameterLists.append(previous?.text == "func")
            parenthesisDepth += 1
            if !spacing.groupingParentheses.contains(token.offset) {
                // The arguments of a call, or the parameters of a function.
                continuations.append(
                    continuation(.list(opener: token.offset, isLiteral: false)))
            }
        case ")":
            trimTrailingWhitespace()
            append(")")
            if let last = continuations.last, case .list(_, false) = last.kind, isAtDepth(of: last) {
                continuations.removeLast()
            }
            parenthesisDepth -= 1
            closesParameterList = parameterLists.popLast() ?? false
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
        case "{" where previous?.text == "select" && next?.text == "}" && next?.kind == .symbol:
            // Go's printer keeps a `select` without clauses on one line.
            ensureSpace()
            append("{")
            braceDepth += 1
            compositeDepths.insert(braceDepth)
            pendingSwitch = false
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
                break
            }
            // The syntax tree says which braces open a composite literal:
            // after a type that is a name, one that is written out, or none
            // at all, as an element of the literal around it.
            let isLiteral = literalBraces.contains(token.offset)
            // The body of a type, wherever the type is written: also in a
            // signature, where a `{` otherwise opens the function's body.
            let opensTypeBody = previous?.text == "struct" || previous?.text == "interface"
            if isLiteral {
                append("{")
                braceDepth += 1
                compositeDepths.insert(braceDepth)
                continuations.append(continuation(.list(opener: token.offset, isLiteral: true)))
            } else if opensTypeBody
                ? staysOnOneLineAsTypeBody() : pendingFunction && staysOnOneLineAsFunctionBody()
            {
                openOneLineBody(next: next)
            } else {
                if pendingFunction, lineIsFunctionDeclaration {
                    // Go's printer starts a section at a function that
                    // spans several lines.
                    lineStartsSection = true
                }
                ensureSpace()
                append("{")
                finishLine(unlessCommentFollows: next)
                // A block ends the expressions of its header; a list it
                // stands in goes on around it.
                continuations.removeAll { !$0.isList && $0.braceDepth >= braceDepth }
                blockBases.append(parenthesisDepth)
                braceDepth += 1
                indent += 1
                if opensTypeBody { suspendHeader() }
                if previous?.text == "struct" || previous?.text == "interface" {
                    typeBodyDepths.insert(braceDepth)
                }
                if previous?.text == "struct" { structBodyDepths.insert(braceDepth) }
                if pendingSwitch { switchDepths.insert(braceDepth) }
                pendingSwitch = false
                pendingIf = false
                pendingFunction = false
                pendingTypeDeclaration = false
                forHeader = false
            }
        case "}":
            if let body = oneLineBodies.removeValue(forKey: braceDepth) {
                trimTrailingWhitespace()
                closedOneLineBody = (Self.width(current) - body.start, body.statements)
                append(previous?.text == "{" ? "}" : " }")
                typeBodyDepths.remove(braceDepth)
                braceDepth -= 1
            } else if compositeDepths.remove(braceDepth) != nil {
                trimTrailingWhitespace()
                append("}")
                if let last = continuations.last, case .list(_, true) = last.kind,
                    last.braceDepth == braceDepth
                {
                    continuations.removeLast()
                }
                braceDepth -= 1
            } else {
                closeBrace()
            }
        case ",":
            trimTrailingWhitespace()
            let list = continuations.lastIndex(where: { $0.isList && isAtDepth(of: $0) })
            let closesList = next.map { $0.kind == .symbol && ($0.text == ")" || $0.text == "}") } ?? false
            if closesList, let list,
                next?.leadingNewlines == 0 || sourceLineBreaks == continuations[list].sourceBreaksAtOpen
            {
                // A final comma is for a closing delimiter on a line of its
                // own; before one on the same line Go's printer drops it.
            } else {
                append(",")
                if !closesList { append(" ") }
            }
            if let list {
                continuations[list].elementBeganLine = false
                continuations[list].elementIndex += 1
                continuations[list].hasMeasuredElement = false
            }
        case ".":
            if next?.kind == .literal {
                // A dot import: the `.` stands where a name would.
                if previous?.text == "import" { ensureSpace() }
                append(". ")
            } else {
                trimTrailingWhitespace()
                append(".")
            }
        case GoSpread.spelling:
            // Before a type it marks a variadic parameter, `values ...T`;
            // after an argument it spreads a slice, `values...`.
            if next?.kind == .word || next?.text == "[" || next?.text == "*" {
                // The first of a list that has no names, `func(...int)`,
                // stands against its parenthesis.
                if previous?.text != "(" { ensureSpace() }
            } else {
                trimTrailingWhitespace()
            }
            append(GoSpread.spelling)
        case ":" where pendingLabel:
            // The colon of a label, which has a line to itself: the
            // statement it names begins the next one. A comment on the
            // line stays beside the label.
            pendingLabel = false
            followsLabel = true
            append(":")
            if let next, next.leadingNewlines == 0,
                next.kind == .lineComment || next.kind == .blockComment
            {
                labelAwaitsStatement = true
            } else {
                finishLine()
            }
        case ";" where closedLabel:
            // The empty statement a label names, written out.
            append(";")
            finishLine()
            endStatement()
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
                // The values of the elements that each begin a line are a
                // column.
                if let list = continuations.last(where: { $0.isList && isAtDepth(of: $0) }),
                    list.elementBeganLine, elementStaysOnItsLine()
                {
                    endCell()
                } else {
                    append(" ")
                }
            } else if pendingCaseDepth == braceDepth, parenthesisDepth == statementBase {
                // The end of a `case` or `default`, on whichever line of
                // its list of values the colon stands.
                pendingCaseDepth = nil
                finishLine(unlessCommentFollows: next)
                endStatement()
                indent += 1
                activeCaseDepths.insert(braceDepth)
            }
        case ";":
            // Inside a `for` clause, and after the initializer of an `if` or
            // a `switch`, the header goes on.
            if forHeader || pendingIf || pendingSwitch {
                trimTrailingWhitespace()
                append("; ")
            } else if let body = oneLineBodies[braceDepth] {
                // The statements of a body that stays on its line.
                trimTrailingWhitespace()
                append("; ")
                oneLineBodies[braceDepth] = (body.start, body.statements + 1)
            } else {
                finishLine()
                endStatement()
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
        // Before `chan` the arrow is part of a type, `<-chan T`, wherever
        // the type is written: after a result list or a name as well.
        case "<-" where !isUnaryOperator && next?.text == "chan":
            if let before = previous?.text, !["(", "[", "]", "*"].contains(before) { ensureSpace() }
            append("<-")
        case "<-" where isUnaryOperator:
            if needsSpaceBeforeUnary() { ensureSpace() }
            append("<-")
        case "<-":
            ensureSpace()
            append("<-")
            append(" ")
        case "*" where spacing.binaryOperators[token.offset] != nil && isPointerTypeContext:
            // A product in the length of an array, `[2 * n]T`, which stands
            // where a type does.
            if spacing.tight.contains(token.offset) {
                append("*")
            } else {
                ensureSpace()
                append("*")
                append(" ")
            }
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
            beginStructTag(token)
            appendWord(token.text, kind: token.kind)
            if token.spansLines { lineEndsAlignment = true }
        }
        // What follows the `=` of a `var` is a value, not its type.
        if token.text == "=" { pendingVariableDeclaration = false }
        if token.text == "type", token.kind == .word { pendingTypeDeclaration = true }
        if case .selector(let end)? = continuations.last?.kind, position >= end {
            continuations.removeLast()
        }
        previous = token
        previousCode = token
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
        // After a line that ends in a comment it keeps to the source.
        let needsBlankLine =
            previousTopLevelDeclaration != nil && previousTopLevelDeclaration != declaration
            && !previousLineHadTrailingComment
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

    // MARK: One-line bodies

    static func width(_ text: String) -> Int { text.unicodeScalars.count }

    /// The index of the `}` that closes the body opening at `position`, when
    /// the source has the whole body on the line of its `{` and no comment
    /// in it: what Go's printer requires before it considers one line.
    func closingBraceOnSameLine() -> Int? {
        var depth = 0
        for index in position..<tokens.count {
            let token = tokens[index]
            if index > position, token.leadingNewlines > 0 { return nil }
            if token.kind == .lineComment || token.kind == .blockComment { return nil }
            if token.spansLines { return nil }
            guard token.kind == .symbol else { continue }
            if token.text == "{" {
                depth += 1
            } else if token.text == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    /// Writes the body opening at `position` on one line in a copy of the
    /// printer, and returns the copy when the body fits there: nothing in it
    /// needed a line of its own.
    func probingOneLineBody(until close: Int) -> FormatPrinter? {
        var probe = self
        probe.openOneLineBody(next: position + 1 < tokens.count ? tokens[position + 1] : nil)
        probe.previous = tokens[position]
        probe.previousWasUnaryOperator = false
        for index in (position + 1)...close {
            probe.position = index
            probe.closeContinuations(before: tokens[index])
            probe.handle(tokens[index], next: index + 1 < tokens.count ? tokens[index + 1] : nil)
            guard probe.lines.count == lines.count else { return nil }
        }
        return probe
    }

    /// Whether Go's printer keeps the function whose body opens here on one
    /// line: at most five statements, each of which fits a line, and no more
    /// than 100 columns for the signature and the statements together.
    func staysOnOneLineAsFunctionBody() -> Bool {
        guard let close = closingBraceOnSameLine(),
            let probe = probingOneLineBody(until: close), let body = probe.closedOneLineBody
        else { return false }
        var signature = current
        while signature.last == " " { signature.removeLast() }
        let header = Self.width(signature) - functionStart
        return body.statements <= 5 && header + body.size <= 100
    }

    /// Whether Go's printer keeps the `struct` or `interface` whose body
    /// opens here on one line: one field or method, written on one line,
    /// whose type takes no more than 30 columns with its name counted as 1.
    func staysOnOneLineAsTypeBody() -> Bool {
        guard previous?.text == "struct" || previous?.text == "interface",
            let close = closingBraceOnSameLine(),
            !tokens[position...close].contains(where: { $0.text == ";" || $0.isString }),
            let probe = probingOneLineBody(until: close), let body = probe.closedOneLineBody
        else { return false }
        // The field or method as the probe wrote it, between `{ ` and ` }`.
        let written = String(probe.current.unicodeScalars.dropLast(2).suffix(body.size))
        let size: Int
        if previous?.text == "struct" {
            // `name type`, or an embedded type alone.
            size = written.firstIndex(of: " ").map {
                1 + Self.width(String(written[written.index(after: $0)...]))
            } ?? Self.width(written)
        } else {
            // A method is measured as its function type, `func(...) ...`.
            size = written.firstIndex(of: "(").map {
                1 + 4 + Self.width(String(written[$0...]))
            } ?? Self.width(written)
        }
        return size <= 30
    }

    /// Opens a body that stays on its line: `{ a(); b() }`, or `{}`.
    mutating func openOneLineBody(next: FormatToken?) {
        let isType = previous?.text == "struct" || previous?.text == "interface"
        if isType {
            // `struct{ a int }`: the body follows the keyword directly.
        } else if pendingFunction, lineIsFunctionDeclaration {
            // The bodies of one-line functions that follow one another are
            // a column.
            endCell()
        } else {
            ensureSpace()
        }
        append("{")
        if next?.text != "}" { append(" ") }
        braceDepth += 1
        oneLineBodies[braceDepth] = (Self.width(current), next?.text == "}" ? 0 : 1)
        if isType { typeBodyDepths.insert(braceDepth) }
        // A type in a signature is not the end of it: the body of the
        // function is still to come.
        if !isType { pendingFunction = false }
        pendingTypeDeclaration = false
    }

    /// Sets aside the header the type body that has just opened stands in.
    mutating func suspendHeader() {
        let header = FormatHeader(
            pendingFunction: pendingFunction, pendingFunctionIsType: pendingFunctionIsType,
            pendingIf: pendingIf, pendingSwitch: pendingSwitch, forHeader: forHeader)
        guard header.isOpen else { return }
        suspendedHeaders[braceDepth] = header
        pendingFunction = false
        pendingFunctionIsType = false
        pendingIf = false
        pendingSwitch = false
        forHeader = false
    }

    /// Takes up the header again that the type body closing here stood in.
    mutating func resumeHeader() {
        guard let header = suspendedHeaders.removeValue(forKey: braceDepth) else { return }
        pendingFunction = header.pendingFunction
        pendingFunctionIsType = header.pendingFunctionIsType
        pendingIf = header.pendingIf
        pendingSwitch = header.pendingSwitch
        forHeader = header.forHeader
    }

    /// Whether `token` is the name of a label: a word before a colon where
    /// a statement begins, which is nowhere a key of a literal, a field, or
    /// the last value of a `case` can stand.
    func isLabel(_ token: FormatToken, next: FormatToken?) -> Bool {
        guard token.kind == .word, token.text != "default", let next, next.kind == .symbol,
            next.text == ":", braceDepth > 0, parenthesisDepth == statementBase,
            sliceBrackets.isEmpty, pendingCaseDepth == nil,
            !compositeDepths.contains(braceDepth), !typeBodyDepths.contains(braceDepth)
        else { return false }
        if lineIsEmpty { return true }
        // The statements of a body the source has on one line.
        return oneLineBodies[braceDepth] != nil && (previous?.text == "{" || previous?.text == ";")
    }

    /// Writes the name of a label, on a line of its own that Go's printer
    /// indents one level less than the statements around it.
    mutating func beginLabel(_ token: FormatToken) {
        if !lineIsEmpty { finishLine() }
        append(token.text)
        lineIndent = max(0, indent + continuationIndent - 1)
        pendingLabel = true
        previous = token
        previousCode = token
        previousWasUnaryOperator = false
    }

    mutating func beginCase(_ keyword: String) {
        if !lineIsEmpty { finishLine() }
        if activeCaseDepths.remove(braceDepth) != nil || switchDepths.contains(braceDepth) {
            indent -= 1
        }
        append(keyword)
        if switchDepths.contains(braceDepth) { pendingCaseDepth = braceDepth }
        // Each clause is a section of its own to Go's printer.
        lineStartsSection = true
    }

    mutating func closeBrace() {
        if !lineIsEmpty { finishLine() }
        endStatement()
        resumeHeader()
        _ = blockBases.popLast()
        activeCaseDepths.remove(braceDepth)
        switchDepths.remove(braceDepth)
        typeBodyDepths.remove(braceDepth)
        structBodyDepths.remove(braceDepth)
        indent -= 1
        braceDepth -= 1
        append("}")
        if structBodyDepths.contains(braceDepth) {
            // The last line of a field whose type is a struct or an
            // interface of several lines: Go's printer starts the columns
            // over before it and after it, so a tag or a comment that
            // follows the brace is aligned with nothing.
            lineStartsSection = true
            lineClosesFieldType = true
        }
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
        if lineIsEmpty {
            // A line is indented as its first token finds things, whatever
            // the tokens after it open or close.
            lineIndent = indent + continuationIndent
            lineIsStructField = lineIsStructField || structBodyDepths.contains(braceDepth)
        }
        current += text
    }

    mutating func ensureSpace() {
        guard !current.isEmpty, current.last != " ", current.last != "\t" else { return }
        current.append(" ")
    }

    mutating func finishLine() {
        trimTrailingWhitespace()
        guard !lineIsEmpty else { return }
        endStructFieldName()
        previousLineHadTrailingComment = !cells.isEmpty && current.hasPrefix("//")
        lines.append(
            FormatLine(
                indent: lineIndent ?? indent, cells: cells, tail: current,
                startsSection: lineStartsSection || previousLineSpannedLines))
        previousLineSpannedLines = lineClosesFieldType || lineEndsAlignment
        lineClosesFieldType = false
        lineEndsAlignment = false
        cells = []
        current = ""
        lineIndent = nil
        lineStartsSection = false
        lineIsStructField = false
        lineIsEmbeddedField = false
        lineHasTag = false
        lineIsFunctionDeclaration = false
        lineSpecification = nil
        pendingVariableDeclaration = false
        pendingTypeDeclaration = false
    }

    /// Ends the line, unless a comment follows on the same source line: the
    /// comment ends it then, and stays beside the code it belongs to.
    mutating func finishLine(unlessCommentFollows next: FormatToken?) {
        if let next, next.kind == .lineComment, next.leadingNewlines == 0 { return }
        finishLine()
    }

    mutating func appendBlankLine() {
        finishLine()
        guard let last = lines.last, !last.isBlank else { return }
        lines.append(FormatLine(indent: 0))
    }

    mutating func trimTrailingWhitespace() {
        while current.last == " " || current.last == "\t" { current.removeLast() }
    }
}
