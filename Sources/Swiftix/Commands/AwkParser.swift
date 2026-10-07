/// The `awk` front end: the syntax tree, the lexer, and the recursive-descent
/// parser that turns program text into an `AwkProgram`.
///
/// Names are resolved while parsing: every global variable gets a slot in one
/// flat table (the special variables — `NF`, `FS`, … — occupy fixed leading
/// slots, see `AwkSpecial`), and a function's parameters get slots in its call
/// frame, so the interpreter never looks a variable up by name. The grammar is
/// POSIX awk's: `/` is a regular expression wherever an operand is expected
/// (the parser asks the lexer to rescan), juxtaposition is concatenation, and
/// an unparenthesized `>` inside `print` is a redirection.
///
/// After parsing, `AwkMarker` annotates the tree with what can run without
/// ever suspending: an expression that contains no user-function call and no
/// `getline` is wrapped in `.pure`, and a statement with no loop and no such
/// expression in `.simple`. The interpreter runs those synchronously and
/// keeps `async` for the rest (see `AwkInterpreter`).
///
/// Concurrency: value types and pure functions only. Parsing happens once, in
/// the `awk` command body on the kernel's single serial executor.

// MARK: - Syntax tree

/// A variable reference resolved to a storage slot.
enum AwkVarRef {
    case global(Int)
    case local(Int)
}

enum AwkArithmetic {
    case add, subtract, multiply, divide, modulo, power
}

enum AwkComparison {
    case less, lessEqual, equal, notEqual, greater, greaterEqual
}

enum AwkBuiltin: String {
    case length, substr, index, split, sub, gsub, match, sprintf, tolower, toupper
    case int, sqrt, exp, log, sin, cos, atan2, rand, srand, system, close, fflush
}

indirect enum AwkExpr {
    case number(Double)
    case string(String)
    /// A regex literal. As a plain expression it means `$0 ~ /re/`; the match
    /// operators and the regex-taking builtins use the pattern itself.
    case regex(String)
    case variable(AwkVarRef)
    case field(AwkExpr)
    case element(AwkVarRef, [AwkExpr])
    case assign(AwkExpr, AwkExpr)
    case compoundAssign(AwkArithmetic, AwkExpr, AwkExpr)
    case conditional(AwkExpr, AwkExpr, AwkExpr)
    case and(AwkExpr, AwkExpr)
    case or(AwkExpr, AwkExpr)
    case not(AwkExpr)
    case negate(AwkExpr)
    case numeric(AwkExpr)
    case arithmetic(AwkArithmetic, AwkExpr, AwkExpr)
    case compare(AwkComparison, AwkExpr, AwkExpr)
    /// Juxtaposed operands, kept flat so a long chain is not a deep tree.
    case concat([AwkExpr])
    case match(negated: Bool, AwkExpr, AwkExpr)
    case membership([AwkExpr], AwkVarRef)
    case increment(AwkExpr, delta: Double, prefix: Bool)
    case call(Int, [AwkExpr])
    case builtin(AwkBuiltin, [AwkExpr])
    /// `getline [target] [< file]`, or `command | getline [target]`.
    case getline(target: AwkExpr?, file: AwkExpr?, command: AwkExpr?)
    /// A parenthesized expression list; only meaningful as `print (a, b)`.
    case group([AwkExpr])
    /// Marker: the wrapped expression never suspends (no call, no getline).
    case pure(AwkExpr)
    /// An already computed operand (the interpreter substitutes these while
    /// evaluating an expression whose operands had to be awaited).
    case value(AwkValue)

    var isLvalue: Bool {
        switch self {
        case .variable, .field, .element: return true
        default: return false
        }
    }
}

struct AwkRedirect {
    let append: Bool
    let target: AwkExpr
    /// `print | "command"`: the target is a command line run by `sh -c`.
    var pipe = false
}

indirect enum AwkStmt {
    case expression(AwkExpr)
    case print([AwkExpr], AwkRedirect?)
    case printf([AwkExpr], AwkRedirect?)
    case ifElse(AwkExpr, AwkStmt, AwkStmt?)
    case whileLoop(AwkExpr, AwkStmt)
    case doWhile(AwkStmt, AwkExpr)
    case forLoop(AwkStmt?, AwkExpr?, AwkStmt?, AwkStmt)
    case forIn(AwkExpr, AwkVarRef, AwkStmt)
    case block([AwkStmt])
    case next
    case nextFile
    case breakLoop
    case continueLoop
    case exit(AwkExpr?)
    case returnValue(AwkExpr?)
    case delete(AwkVarRef, [AwkExpr]?)
    /// Marker: the wrapped statement has no loop and never suspends.
    case simple(AwkStmt)
}

enum AwkPattern {
    case begin
    case end
    case always
    case expression(AwkExpr)
    case range(AwkExpr, AwkExpr)
}

struct AwkRule {
    let pattern: AwkPattern
    /// `nil` is the default action, `print $0`.
    let body: [AwkStmt]?
}

struct AwkFunction {
    var name: String
    /// Source line of the first reference (for "undefined function").
    var line = 0
    var parameterCount = 0
    var body: [AwkStmt] = []
    var isDefined = false
}

struct AwkProgram {
    var rules: [AwkRule] = []
    var functions: [AwkFunction] = []
    /// Global variable names; the index is the variable's slot.
    var globalNames: [String] = []
}

/// Fixed global slots of the special variables.
enum AwkSpecial {
    static let names = ["NF", "NR", "FNR", "FS", "OFS", "ORS", "RS", "FILENAME", "SUBSEP",
                        "RSTART", "RLENGTH", "CONVFMT", "OFMT", "ENVIRON", "ARGC", "ARGV"]
    static let nf = 0, nr = 1, fnr = 2, fs = 3, ofs = 4, ors = 5, rs = 6, filename = 7
    static let subsep = 8, rstart = 9, rlength = 10, convfmt = 11, ofmt = 12
    static let environ = 13, argc = 14, argv = 15
    static var count: Int { names.count }
}

struct AwkSyntaxError: Error {
    let message: String
    let line: Int
}

// MARK: - Lexer

enum AwkKeyword: String {
    case begin = "BEGIN", end = "END", function, `func`, `if`, `else`, `while`, `for`, `do`
    case `break`, `continue`, next, nextfile, exit, `return`, delete, `in`, getline, print, printf
}

enum AwkToken: Equatable {
    case number(Double)
    case string(String)
    case name(String)
    /// A name immediately followed by `(`: a user-function call.
    case functionName(String)
    case builtin(AwkBuiltin)
    case keyword(AwkKeyword)
    case symbol(String)
    case newline
    case eof

    var description: String {
        switch self {
        case let .number(value): return AwkLexer.plain(value)
        case let .string(text): return "\"\(text)\""
        case let .name(name), let .functionName(name): return name
        case let .builtin(builtin): return builtin.rawValue
        case let .keyword(keyword): return keyword.rawValue
        case let .symbol(symbol): return symbol
        case .newline: return "newline"
        case .eof: return "end of program"
        }
    }
}

struct AwkLexer {
    private let source: [Character]
    var position = 0
    var line = 1
    /// Where the most recently returned token began.
    private(set) var tokenStart = 0

    init(_ text: String) {
        source = Array(text)
    }

    static func plain(_ value: Double) -> String {
        value == value.rounded(.towardZero) && value.magnitude < 1e15 ? String(Int64(value)) : "\(value)"
    }

    private static func isNewline(_ c: Character) -> Bool { c == "\n" || c == "\r\n" }
    private static func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
    private static func isNameStart(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
    }

    private func peek(_ offset: Int = 0) -> Character? {
        position + offset < source.count ? source[position + offset] : nil
    }

    private static let symbols3 = ["**="]
    private static let symbols2 = ["&&", "||", "==", "!=", "<=", ">=", "!~", "++", "--", "+=", "-=",
                                   "*=", "/=", "%=", "^=", "**", ">>"]
    private static let symbols1: Set<Character> = ["{", "}", "(", ")", "[", "]", ";", ",", "+", "-", "*",
                                                   "/", "%", "^", "!", "<", ">", "~", "?", ":", "$", "=",
                                                   "|"]

    mutating func next() throws -> AwkToken {
        while let c = peek() {
            if c == " " || c == "\t" || c == "\r" {
                position += 1
            } else if c == "\\", let following = peek(1), Self.isNewline(following) {
                position += 2
                line += 1
            } else if c == "#" {
                while let comment = peek(), !Self.isNewline(comment) { position += 1 }
            } else {
                break
            }
        }
        tokenStart = position
        guard let c = peek() else { return .eof }
        if Self.isNewline(c) {
            position += 1
            line += 1
            return .newline
        }
        if Self.isDigit(c) || (c == "." && peek(1).map(Self.isDigit) == true) {
            return .number(readNumber())
        }
        if Self.isNameStart(c) {
            var name = ""
            while let part = peek(), Self.isNameStart(part) || Self.isDigit(part) {
                name.append(part)
                position += 1
            }
            if let keyword = AwkKeyword(rawValue: name) { return .keyword(keyword) }
            if let builtin = AwkBuiltin(rawValue: name) { return .builtin(builtin) }
            return peek() == "(" ? .functionName(name) : .name(name)
        }
        if c == "\"" {
            position += 1
            return .string(try readString())
        }
        if position + 3 <= source.count {
            let three = String(source[position..<position + 3])
            if Self.symbols3.contains(three) {
                position += 3
                return .symbol(three)
            }
        }
        if position + 2 <= source.count {
            let two = String(source[position..<position + 2])
            if Self.symbols2.contains(two) {
                position += 2
                return .symbol(two)
            }
        }
        if Self.symbols1.contains(c) {
            position += 1
            return .symbol(String(c))
        }
        throw AwkSyntaxError(message: "unexpected character '\(c)'", line: line)
    }

    private mutating func readNumber() -> Double {
        if peek() == "0", peek(1) == "x" || peek(1) == "X", peek(2)?.isHexDigit == true {
            position += 2
            var value = 0.0
            while let digit = peek()?.hexDigitValue {
                value = value * 16 + Double(digit)
                position += 1
            }
            return value
        }
        var text = ""
        while let digit = peek(), Self.isDigit(digit) {
            text.append(digit)
            position += 1
        }
        if peek() == "." {
            text.append(".")
            position += 1
            while let digit = peek(), Self.isDigit(digit) {
                text.append(digit)
                position += 1
            }
        }
        if peek() == "e" || peek() == "E" {
            var offset = 1
            if peek(offset) == "+" || peek(offset) == "-" { offset += 1 }
            if peek(offset).map(Self.isDigit) == true {
                for _ in 0..<offset {
                    text.append(source[position])
                    position += 1
                }
                while let digit = peek(), Self.isDigit(digit) {
                    text.append(digit)
                    position += 1
                }
            }
        }
        return Double(text) ?? 0
    }

    private mutating func readString() throws -> String {
        var out = ""
        while let c = peek() {
            if c == "\"" {
                position += 1
                return out
            }
            if Self.isNewline(c) { break }
            position += 1
            if c == "\\" {
                out += Self.decodeEscape(source, &position)
            } else {
                out.append(c)
            }
        }
        throw AwkSyntaxError(message: "non-terminated string", line: line)
    }

    /// Scan a regex literal whose opening `/` is at `tokenStart` (the parser
    /// calls this when a `/` or `/=` token turns up where an operand belongs).
    mutating func rescanRegex() throws -> String {
        position = tokenStart + 1
        var out = ""
        var inBracket = false
        while let c = peek() {
            if Self.isNewline(c) { break }
            position += 1
            if c == "\\", let escaped = peek() {
                position += 1
                if escaped == "/" {
                    out.append("/")
                } else {
                    out.append(c)
                    out.append(escaped)
                }
                continue
            }
            if c == "[" {
                inBracket = true
            } else if c == "]" {
                inBracket = false
            } else if c == "/" && !inBracket {
                return out
            }
            out.append(c)
        }
        throw AwkSyntaxError(message: "non-terminated regular expression", line: line)
    }

    /// Decode one backslash escape; `index` is just past the backslash and is
    /// advanced over the escape. Unknown escapes keep their backslash so that
    /// `"\."` still works as a dynamic regex and `"\\&"` in a replacement.
    static func decodeEscape(_ source: [Character], _ index: inout Int) -> String {
        guard index < source.count else { return "\\" }
        let c = source[index]
        index += 1
        switch c {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "a": return "\u{07}"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "v": return "\u{0B}"
        case "\\": return "\\"
        case "\"": return "\""
        case "/": return "/"
        case "\n", "\r\n": return ""
        case "0"..."7":
            var value = UInt32(c.wholeNumberValue ?? 0)
            var digits = 1
            while digits < 3, index < source.count, source[index] >= "0", source[index] <= "7" {
                value = value * 8 + UInt32(source[index].wholeNumberValue ?? 0)
                index += 1
                digits += 1
            }
            return String(Character(Unicode.Scalar(value & 0xFF) ?? " "))
        default:
            return "\\" + String(c)
        }
    }

    /// Process the escapes of a command-line value (`-v`, `-F`, `var=value`).
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        let source = Array(text)
        var out = ""
        var index = 0
        while index < source.count {
            let c = source[index]
            index += 1
            if c == "\\" {
                out += decodeEscape(source, &index)
            } else {
                out.append(c)
            }
        }
        return out
    }
}

// MARK: - Parser

struct AwkParser {
    private var lexer: AwkLexer
    private var token: AwkToken = .eof
    private var tokenLine = 1
    private var globals: [String: Int] = [:]
    private var globalNames: [String] = []
    private var functionIndex: [String: Int] = [:]
    private var functions: [AwkFunction] = []
    private var locals: [String: Int]? = nil
    /// Set while parsing unparenthesized `print` arguments, where `>` redirects.
    private var greaterIsRedirect = false
    private var loopDepth = 0
    /// How deep the parse currently is, in units of one nested statement,
    /// sub-expression, unary operator or chained binary operator. It bounds
    /// both this parser's recursion and the depth of the tree it builds — and
    /// with that the recursion of everything that later walks the tree — so
    /// that no input can exhaust the native stack. The limit is sized for
    /// unoptimized builds on a 512 KiB thread stack (a nesting unit costs up
    /// to about 6 KiB there); it allows 24 nested parentheses or 48 chained
    /// operators, far beyond hand-written awk.
    private var nesting = 0
    private static let maximumNesting = 48

    static func parse(_ text: String) throws -> AwkProgram {
        var parser = AwkParser(text)
        return try parser.program()
    }

    private init(_ text: String) {
        lexer = AwkLexer(text)
        for name in AwkSpecial.names {
            globals[name] = globalNames.count
            globalNames.append(name)
        }
    }

    // MARK: Token plumbing

    private mutating func advance() throws {
        token = try lexer.next()
        // A newline belongs to the line it ends, and the end of the program
        // is reported on the last line that had anything on it.
        if token == .newline {
            tokenLine = lexer.line - 1
        } else if token != .eof {
            tokenLine = lexer.line
        }
    }

    private func fail(_ message: String) -> AwkSyntaxError {
        AwkSyntaxError(message: message, line: tokenLine)
    }

    private func unexpected() -> AwkSyntaxError {
        return fail("unexpected \(token.description)")
    }

    private func at(_ symbol: String) -> Bool { token == .symbol(symbol) }
    private func at(_ keyword: AwkKeyword) -> Bool { token == .keyword(keyword) }

    private mutating func accept(_ symbol: String) throws -> Bool {
        guard at(symbol) else { return false }
        try advance()
        return true
    }

    private mutating func expect(_ symbol: String) throws {
        guard at(symbol) else {
            throw fail("expected '\(symbol)' but found \(token.description)")
        }
        try advance()
    }

    private mutating func skipNewlines() throws {
        while token == .newline { try advance() }
    }

    private mutating func skipTerminators() throws {
        while token == .newline || at(";") { try advance() }
    }

    // MARK: Names

    private mutating func reference(_ name: String) -> AwkVarRef {
        if let slot = locals?[name] { return .local(slot) }
        if let slot = globals[name] { return .global(slot) }
        let slot = globalNames.count
        globals[name] = slot
        globalNames.append(name)
        return .global(slot)
    }

    private mutating func function(_ name: String) -> Int {
        if let index = functionIndex[name] { return index }
        functionIndex[name] = functions.count
        functions.append(AwkFunction(name: name, line: tokenLine))
        return functions.count - 1
    }

    // MARK: Program structure

    private mutating func program() throws -> AwkProgram {
        try advance()
        var rules: [AwkRule] = []
        while true {
            try skipTerminators()
            if token == .eof { break }
            if at(.function) || at(.func) {
                try functionDefinition()
            } else {
                rules.append(try rule())
            }
        }
        if let missing = functions.first(where: { !$0.isDefined }) {
            throw AwkSyntaxError(message: "calling undefined function \(missing.name)", line: missing.line)
        }
        return AwkMarker.program(AwkProgram(rules: rules, functions: functions, globalNames: globalNames))
    }

    private mutating func rule() throws -> AwkRule {
        if at(.begin) || at(.end) {
            let isBegin = at(.begin)
            try advance()
            guard at("{") else { throw fail("\(isBegin ? "BEGIN" : "END") requires an action") }
            return AwkRule(pattern: isBegin ? .begin : .end, body: try block())
        }
        if at("{") {
            return AwkRule(pattern: .always, body: try block())
        }
        let first = try expression()
        var pattern = AwkPattern.expression(first)
        if try accept(",") {
            try skipNewlines()
            pattern = .range(first, try expression())
        }
        if at("{") {
            return AwkRule(pattern: pattern, body: try block())
        }
        guard token == .newline || token == .eof || at(";") else { throw unexpected() }
        return AwkRule(pattern: pattern, body: nil)
    }

    private mutating func functionDefinition() throws {
        try advance()
        let name: String
        switch token {
        case let .name(text), let .functionName(text): name = text
        default: throw fail("expected a function name")
        }
        let index = function(name)
        guard !functions[index].isDefined else { throw fail("function \(name) redefined") }
        try advance()
        try expect("(")
        var parameters: [String: Int] = [:]
        while !at(")") {
            guard case let .name(parameter) = token else { throw fail("expected a parameter name") }
            guard parameters[parameter] == nil else { throw fail("duplicate parameter \(parameter)") }
            parameters[parameter] = parameters.count
            try advance()
            if try accept(",") {
                try skipNewlines()
            } else if !at(")") {
                throw unexpected()
            }
        }
        try advance()
        try skipNewlines()
        locals = parameters
        let savedDepth = loopDepth
        loopDepth = 0
        let body = try block()
        loopDepth = savedDepth
        locals = nil
        functions[index].parameterCount = parameters.count
        functions[index].body = body
        functions[index].isDefined = true
    }

    private mutating func block() throws -> [AwkStmt] {
        try expect("{")
        var statements: [AwkStmt] = []
        while true {
            try skipTerminators()
            if at("}") { break }
            if token == .eof { throw fail("missing '}'") }
            statements.append(try statement())
        }
        try advance()
        return statements
    }

    // MARK: Statements

    /// The body of a loop or branch: a statement, or a bare `;`.
    private mutating func body() throws -> AwkStmt {
        if try accept(";") { return .block([]) }
        try skipNewlines()
        return try statement()
    }

    private mutating func loopBody() throws -> AwkStmt {
        loopDepth += 1
        defer { loopDepth -= 1 }
        return try body()
    }

    private mutating func enterNesting() throws {
        nesting += 1
        guard nesting <= Self.maximumNesting else {
            nesting -= 1
            throw fail("program nested too deeply")
        }
    }

    private mutating func statement() throws -> AwkStmt {
        try enterNesting()
        defer { nesting -= 1 }
        if at("{") { return .block(try block()) }
        if try accept(";") { return .block([]) }
        if case let .keyword(keyword) = token {
            switch keyword {
            case .if:
                try advance()
                try expect("(")
                let condition = try expression()
                try expect(")")
                let thenBranch = try body()
                let saved = self
                try skipTerminators()
                if at(.else) {
                    try advance()
                    return .ifElse(condition, thenBranch, try body())
                }
                self = saved
                return .ifElse(condition, thenBranch, nil)
            case .while:
                try advance()
                try expect("(")
                let condition = try expression()
                try expect(")")
                return .whileLoop(condition, try loopBody())
            case .do:
                try advance()
                let loop = try loopBody()
                try skipTerminators()
                guard at(.while) else { throw fail("expected 'while' after 'do' body") }
                try advance()
                try expect("(")
                let condition = try expression()
                try expect(")")
                try endSimpleStatement()
                return .doWhile(loop, condition)
            case .for:
                return try forStatement()
            default:
                break
            }
        }
        let simple = try simpleStatement()
        try endSimpleStatement()
        return simple
    }

    private mutating func endSimpleStatement() throws {
        if token == .newline || at(";") {
            try advance()
        } else if !(at("}") || token == .eof) {
            throw unexpected()
        }
    }

    private var atStatementEnd: Bool {
        token == .newline || token == .eof || at(";") || at("}")
    }

    private mutating func forStatement() throws -> AwkStmt {
        try advance()
        try expect("(")
        // `for (name in array)`.
        if case let .name(variable) = token {
            let saved = self
            try advance()
            if at(.in) {
                try advance()
                if case let .name(array) = token {
                    try advance()
                    if at(")") {
                        try advance()
                        let target = AwkExpr.variable(reference(variable))
                        let arrayRef = reference(array)
                        return .forIn(target, arrayRef, try loopBody())
                    }
                }
            }
            self = saved
        }
        var initial: AwkStmt? = nil
        if !at(";") { initial = try simpleStatement() }
        try expect(";")
        try skipNewlines()
        var condition: AwkExpr? = nil
        if !at(";") { condition = try expression() }
        try expect(";")
        try skipNewlines()
        var update: AwkStmt? = nil
        if !at(")") { update = try simpleStatement() }
        try expect(")")
        return .forLoop(initial, condition, update, try loopBody())
    }

    private mutating func simpleStatement() throws -> AwkStmt {
        guard case let .keyword(keyword) = token else {
            return .expression(try expression())
        }
        switch keyword {
        case .break, .continue:
            guard loopDepth > 0 else { throw fail("'\(keyword.rawValue)' outside a loop") }
            try advance()
            return keyword == .break ? .breakLoop : .continueLoop
        case .next:
            guard locals == nil else { throw fail("'next' used in a function") }
            try advance()
            return .next
        case .nextfile:
            guard locals == nil else { throw fail("'nextfile' used in a function") }
            try advance()
            return .nextFile
        case .exit:
            try advance()
            return .exit(atStatementEnd ? nil : try expression())
        case .return:
            guard locals != nil else { throw fail("'return' outside a function") }
            try advance()
            return .returnValue(atStatementEnd ? nil : try expression())
        case .delete:
            try advance()
            guard case let .name(name) = token else { throw fail("expected an array name after 'delete'") }
            let array = reference(name)
            try advance()
            guard at("[") else { return .delete(array, nil) }
            try advance()
            let subscripts = try nested { try $0.expressionList() }
            try expect("]")
            return .delete(array, subscripts)
        case .print, .printf:
            try advance()
            var arguments: [AwkExpr] = []
            if !(atStatementEnd || at(">") || at(">>") || at("|")) {
                let saved = greaterIsRedirect
                greaterIsRedirect = true
                arguments = try expressionList()
                greaterIsRedirect = saved
                if arguments.count == 1, case let .group(list) = arguments[0] { arguments = list }
            }
            var redirect: AwkRedirect? = nil
            if at(">") || at(">>") {
                let append = at(">>")
                try advance()
                let saved = greaterIsRedirect
                greaterIsRedirect = true
                redirect = AwkRedirect(append: append, target: try binary(5))
                greaterIsRedirect = saved
            } else if at("|") {
                try advance()
                let saved = greaterIsRedirect
                greaterIsRedirect = true
                redirect = AwkRedirect(append: false, target: try binary(5), pipe: true)
                greaterIsRedirect = saved
            }
            if keyword == .printf {
                guard !arguments.isEmpty else { throw fail("printf: no format") }
                return .printf(arguments, redirect)
            }
            return .print(arguments, redirect)
        default:
            return .expression(try expression())
        }
    }

    // MARK: Expressions

    /// Parse with `>` meaning comparison again (inside brackets and parens).
    private mutating func nested<T>(_ parse: (inout AwkParser) throws -> T) rethrows -> T {
        let saved = greaterIsRedirect
        greaterIsRedirect = false
        defer { greaterIsRedirect = saved }
        return try parse(&self)
    }

    private mutating func expressionList() throws -> [AwkExpr] {
        var list = [try expression()]
        while try accept(",") {
            try skipNewlines()
            list.append(try expression())
        }
        return list
    }

    private static let assignments: [String: AwkArithmetic?] = [
        "=": nil, "+=": .add, "-=": .subtract, "*=": .multiply, "/=": .divide,
        "%=": .modulo, "^=": .power, "**=": .power,
    ]

    private mutating func expression() throws -> AwkExpr {
        try enterNesting()
        defer { nesting -= 1 }
        let left = try conditional()
        guard case let .symbol(symbol) = token, let operation = Self.assignments[symbol] else {
            return left
        }
        guard left.isLvalue else { throw fail("assignment to something that is not a variable") }
        try advance()
        try skipNewlines()
        let right = try expression()
        if let operation { return .compoundAssign(operation, left, right) }
        return .assign(left, right)
    }

    private mutating func conditional() throws -> AwkExpr {
        let condition = try binary(0)
        guard at("?") else { return condition }
        try advance()
        try skipNewlines()
        let whenTrue = try expression()
        try skipNewlines()
        try expect(":")
        try skipNewlines()
        return .conditional(condition, whenTrue, try expression())
    }

    /// A binary operator at the current token, with its precedence level
    /// (higher binds tighter). Juxtaposition — a token that can only start an
    /// operand — is the concatenation operator.
    private enum BinaryOperator {
        case or, and, membership
        case match(negated: Bool)
        case compare(AwkComparison)
        case concat
        case arithmetic(AwkArithmetic)

        var level: Int {
            switch self {
            case .or: return 0
            case .and: return 1
            case .membership: return 2
            case .match: return 3
            case .compare: return 4
            case .concat: return 5
            case let .arithmetic(operation):
                return operation == .add || operation == .subtract ? 6 : 7
            }
        }
    }

    private var binaryOperator: BinaryOperator? {
        switch token {
        case .number, .string, .name, .functionName, .builtin:
            return .concat
        case .keyword(.in):
            return .membership
        case let .symbol(symbol):
            switch symbol {
            case "||": return .or
            case "&&": return .and
            case "~": return .match(negated: false)
            case "!~": return .match(negated: true)
            case "<": return .compare(.less)
            case "<=": return .compare(.lessEqual)
            case "==": return .compare(.equal)
            case "!=": return .compare(.notEqual)
            case ">": return greaterIsRedirect ? nil : .compare(.greater)
            case ">=": return .compare(.greaterEqual)
            case "+": return .arithmetic(.add)
            case "-": return .arithmetic(.subtract)
            case "*": return .arithmetic(.multiply)
            case "/": return .arithmetic(.divide)
            case "%": return .arithmetic(.modulo)
            case "$", "(", "++", "--": return .concat
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Precedence climbing over every binary operator at `minimum` or above.
    /// One function instead of a ladder of eight keeps the native stack use
    /// per nesting level small.
    private mutating func binary(_ minimum: Int) throws -> AwkExpr {
        var left = try unary()
        var chained = 0
        defer { nesting -= chained }
        while true {
            // `command | getline [var]`: the command is everything parsed so
            // far at concatenation level or looser. A `|` not followed by
            // `getline` is left for `print … | "command"`.
            if minimum < 6, at("|") {
                let saved = self
                try advance()
                guard case .keyword(.getline) = token else { self = saved; break }
                try advance()
                var target: AwkExpr? = nil
                if at("$") {
                    target = try primary()
                } else if case .name = token {
                    target = try primary()
                }
                left = .getline(target: target, file: nil, command: left)
                continue
            }
            guard let operation = binaryOperator, operation.level >= minimum else { break }
            switch operation {
            case .concat:
                var parts = [left]
                while case .concat? = binaryOperator { parts.append(try binary(6)) }
                left = .concat(parts)
            case .membership:
                try advance()
                guard case let .name(array) = token else { throw fail("expected an array name after 'in'") }
                chained += 1
                try enterNesting()
                left = .membership([left], reference(array))
                try advance()
            default:
                try advance()
                if operation.level <= 1 { try skipNewlines() }
                // Each operator deepens the tree by one, like a nesting level.
                chained += 1
                try enterNesting()
                let right = try binary(operation.level + 1)
                switch operation {
                case .or: left = .or(left, right)
                case .and: left = .and(left, right)
                case let .match(negated): left = .match(negated: negated, left, right)
                case let .compare(comparison): left = .compare(comparison, left, right)
                case let .arithmetic(arithmetic): left = .arithmetic(arithmetic, left, right)
                case .concat, .membership: break
                }
            }
        }
        return left
    }

    private mutating func unary() throws -> AwkExpr {
        try enterNesting()
        defer { nesting -= 1 }
        if try accept("!") { return .not(try unary()) }
        if try accept("-") { return .negate(try unary()) }
        if try accept("+") { return .numeric(try unary()) }
        return try power()
    }

    private mutating func power() throws -> AwkExpr {
        let base = try postfix()
        guard at("^") || at("**") else { return base }
        try advance()
        // Right-associative, and the exponent may carry its own sign.
        try enterNesting()
        defer { nesting -= 1 }
        let exponent = at("-") || at("+") || at("!") ? try unary() : try power()
        return .arithmetic(.power, base, exponent)
    }

    private mutating func postfix() throws -> AwkExpr {
        let operand = try primary()
        if operand.isLvalue, at("++") || at("--") {
            let delta: Double = at("++") ? 1 : -1
            try advance()
            return .increment(operand, delta: delta, prefix: false)
        }
        return operand
    }

    /// The operand of `$`: binds tighter than any binary operator.
    private mutating func fieldOperand() throws -> AwkExpr {
        try enterNesting()
        defer { nesting -= 1 }
        if at("++") || at("--") {
            let delta: Double = at("++") ? 1 : -1
            try advance()
            let target = try fieldOperand()
            guard target.isLvalue else { throw fail("'++'/'--' needs a variable") }
            return .increment(target, delta: delta, prefix: true)
        }
        if try accept("-") { return .negate(try fieldOperand()) }
        if try accept("+") { return .numeric(try fieldOperand()) }
        if try accept("!") { return .not(try fieldOperand()) }
        return try primary()
    }

    private mutating func arguments() throws -> [AwkExpr] {
        try expect("(")
        var list: [AwkExpr] = []
        try nested { parser in
            try parser.skipNewlines()
            if !parser.at(")") {
                list = try parser.expressionList()
                try parser.skipNewlines()
            }
        }
        try expect(")")
        return list
    }

    private mutating func primary() throws -> AwkExpr {
        switch token {
        case let .number(value):
            try advance()
            return .number(value)
        case let .string(text):
            try advance()
            return .string(text)
        case let .name(name):
            let variable = reference(name)
            try advance()
            guard at("[") else { return .variable(variable) }
            try advance()
            let subscripts = try nested { try $0.expressionList() }
            try expect("]")
            return .element(variable, subscripts)
        case let .functionName(name):
            guard locals?[name] == nil else { throw fail("\(name) is a parameter, not a function") }
            let index = function(name)
            try advance()
            return .call(index, try arguments())
        case let .builtin(builtin):
            try advance()
            if at("(") { return .builtin(builtin, try arguments()) }
            guard builtin == .length else { throw fail("\(builtin.rawValue) requires arguments") }
            return .builtin(.length, [])
        case .keyword(.getline):
            try advance()
            var target: AwkExpr? = nil
            if at("$") {
                target = try primary()
            } else if case .name = token {
                target = try primary()
            }
            var file: AwkExpr? = nil
            if at("<") {
                try advance()
                file = try primary()
            }
            return .getline(target: target, file: file, command: nil)
        case let .symbol(symbol):
            switch symbol {
            case "/", "/=":
                let pattern = try lexer.rescanRegex()
                try advance()
                return .regex(pattern)
            case "$":
                try advance()
                return .field(try fieldOperand())
            case "++", "--":
                try advance()
                try enterNesting()
                defer { nesting -= 1 }
                let target = try primary()
                guard target.isLvalue else { throw fail("'\(symbol)' needs a variable") }
                return .increment(target, delta: symbol == "++" ? 1 : -1, prefix: true)
            case "-":
                try advance()
                return .negate(try unary())
            case "+":
                try advance()
                return .numeric(try unary())
            case "!":
                try advance()
                return .not(try unary())
            case "(":
                try advance()
                let list = try nested { try $0.expressionList() }
                try expect(")")
                guard list.count > 1 else { return list[0] }
                if at(.in) {
                    try advance()
                    guard case let .name(array) = token else {
                        throw fail("expected an array name after 'in'")
                    }
                    let reference = reference(array)
                    try advance()
                    return .membership(list, reference)
                }
                return .group(list)
            default:
                throw unexpected()
            }
        default:
            throw unexpected()
        }
    }
}

// MARK: - Suspension marking

extension AwkBuiltin {
    /// Whether argument `index` is used structurally rather than for its
    /// value: a regex literal where a regex is expected, an array name, or the
    /// assignable target of `sub` / `gsub`.
    func usesStructure(at index: Int, _ argument: AwkExpr) -> Bool {
        let substitution = self == .sub || self == .gsub
        if case .regex = argument {
            return (self == .split && index == 2) || (substitution && index == 0) || (self == .match && index == 1)
        }
        if case .variable = argument, (self == .split && index == 1) || (self == .length && index == 0) {
            return true
        }
        return substitution && index == 2 && argument.isLvalue
    }
}

extension AwkExpr {
    /// Rebuild this node with `transform` applied, in evaluation order, to
    /// every operand that is evaluated for its value. Assignable targets, array
    /// names and regex literals keep their shape (only a target's subscripts
    /// are transformed), so the result is still a valid tree.
    func mapChildren(_ transform: (AwkExpr) -> AwkExpr) -> AwkExpr {
        switch self {
        case .number, .string, .regex, .variable, .value, .pure:
            return self
        case let .field(index):
            return .field(transform(index))
        case let .element(reference, subscripts):
            return .element(reference, subscripts.map(transform))
        case let .assign(target, source):
            return .assign(target.mapChildren(transform), transform(source))
        case let .compoundAssign(operation, target, source):
            return .compoundAssign(operation, target.mapChildren(transform), transform(source))
        case let .conditional(condition, whenTrue, whenFalse):
            return .conditional(transform(condition), transform(whenTrue), transform(whenFalse))
        case let .and(left, right):
            return .and(transform(left), transform(right))
        case let .or(left, right):
            return .or(transform(left), transform(right))
        case let .not(operand):
            return .not(transform(operand))
        case let .negate(operand):
            return .negate(transform(operand))
        case let .numeric(operand):
            return .numeric(transform(operand))
        case let .arithmetic(operation, left, right):
            return .arithmetic(operation, transform(left), transform(right))
        case let .compare(operation, left, right):
            return .compare(operation, transform(left), transform(right))
        case let .concat(parts):
            return .concat(parts.map(transform))
        case let .match(negated, subject, pattern):
            if case .regex = pattern { return .match(negated: negated, transform(subject), pattern) }
            return .match(negated: negated, transform(subject), transform(pattern))
        case let .membership(subscripts, reference):
            return .membership(subscripts.map(transform), reference)
        case let .increment(target, delta, prefix):
            return .increment(target.mapChildren(transform), delta: delta, prefix: prefix)
        case let .call(index, arguments):
            // A bare variable may be an array passed by reference.
            return .call(index, arguments.map { argument in
                if case .variable = argument { return argument }
                return transform(argument)
            })
        case let .builtin(builtin, arguments):
            return .builtin(builtin, arguments.enumerated().map { index, argument in
                guard builtin.usesStructure(at: index, argument) else { return transform(argument) }
                return argument.isLvalue ? argument.mapChildren(transform) : argument
            })
        case let .getline(target, file, command):
            return .getline(target: target?.mapChildren(transform), file: file.map(transform),
                            command: command.map(transform))
        case let .group(list):
            return .group(list.map(transform))
        }
    }

    /// Whether evaluating this expression can suspend: it contains a
    /// user-function call or a `getline`.
    var suspends: Bool {
        switch self {
        case .call, .getline, .builtin(.system, _), .builtin(.close, _):
            return true
        case .number, .string, .regex, .variable, .value, .pure:
            return false
        default:
            var found = false
            _ = mapChildren { child in
                if !found, child.suspends { found = true }
                return child
            }
            return found
        }
    }
}

/// Wraps the maximal never-suspending parts of a program in `.pure` /
/// `.simple` so the interpreter can run them without `await`.
enum AwkMarker {

    static func program(_ program: AwkProgram) -> AwkProgram {
        var marked = program
        marked.rules = program.rules.map { rule in
            let pattern: AwkPattern
            switch rule.pattern {
            case let .expression(condition): pattern = .expression(expression(condition))
            case let .range(first, last): pattern = .range(expression(first), expression(last))
            default: pattern = rule.pattern
            }
            return AwkRule(pattern: pattern, body: rule.body.map(statements))
        }
        for index in marked.functions.indices {
            marked.functions[index].body = statements(marked.functions[index].body)
        }
        return marked
    }

    static func expression(_ expression: AwkExpr) -> AwkExpr {
        expression.suspends ? expression.mapChildren(AwkMarker.expression) : .pure(expression)
    }

    private static func isSimple(_ statement: AwkStmt) -> Bool {
        switch statement {
        case let .expression(expression):
            return !expression.suspends
        case let .print(arguments, redirect), let .printf(arguments, redirect):
            return !arguments.contains { $0.suspends } && redirect?.target.suspends != true
        case let .ifElse(condition, thenBranch, elseBranch):
            return !condition.suspends && isSimple(thenBranch) && elseBranch.map(isSimple) != false
        case let .block(list):
            return list.allSatisfy(isSimple)
        case .whileLoop, .doWhile, .forLoop, .forIn:
            return false
        case .next, .nextFile, .breakLoop, .continueLoop, .simple:
            return true
        case let .exit(expression), let .returnValue(expression):
            return expression?.suspends != true
        case let .delete(_, subscripts):
            return subscripts?.contains { $0.suspends } != true
        }
    }

    static func statement(_ statement: AwkStmt) -> AwkStmt {
        if isSimple(statement) { return .simple(statement) }
        func redirected(_ redirect: AwkRedirect?) -> AwkRedirect? {
            redirect.map { AwkRedirect(append: $0.append, target: expression($0.target), pipe: $0.pipe) }
        }
        switch statement {
        case let .expression(inner):
            return .expression(expression(inner))
        case let .print(arguments, redirect):
            return .print(arguments.map(expression), redirected(redirect))
        case let .printf(arguments, redirect):
            return .printf(arguments.map(expression), redirected(redirect))
        case let .ifElse(condition, thenBranch, elseBranch):
            return .ifElse(expression(condition), AwkMarker.statement(thenBranch),
                           elseBranch.map(AwkMarker.statement))
        case let .whileLoop(condition, body):
            return .whileLoop(expression(condition), AwkMarker.statement(body))
        case let .doWhile(body, condition):
            return .doWhile(AwkMarker.statement(body), expression(condition))
        case let .forLoop(initial, condition, update, body):
            return .forLoop(initial.map(AwkMarker.statement), condition.map(expression),
                            update.map(AwkMarker.statement), AwkMarker.statement(body))
        case let .forIn(target, reference, body):
            return .forIn(target, reference, AwkMarker.statement(body))
        case let .block(list):
            return .block(statements(list))
        case let .exit(code):
            return .exit(code.map(expression))
        case let .returnValue(value):
            return .returnValue(value.map(expression))
        case let .delete(reference, subscripts):
            return .delete(reference, subscripts.map { $0.map(expression) })
        case .next, .nextFile, .breakLoop, .continueLoop, .simple:
            return statement
        }
    }

    /// Mark a statement list, folding each run of simple statements into one
    /// `.simple(.block(…))` so it executes as a single synchronous step.
    static func statements(_ list: [AwkStmt]) -> [AwkStmt] {
        var out: [AwkStmt] = []
        var run: [AwkStmt] = []
        func closeRun() {
            if run.count == 1 {
                out.append(.simple(run[0]))
            } else if run.count > 1 {
                out.append(.simple(.block(run)))
            }
            run.removeAll()
        }
        for statement in list {
            if isSimple(statement) {
                run.append(statement)
            } else {
                closeRun()
                out.append(AwkMarker.statement(statement))
            }
        }
        closeRun()
        return out
    }
}
