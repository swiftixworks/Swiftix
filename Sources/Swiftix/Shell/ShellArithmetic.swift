/// Integer arithmetic for `$(( … ))`: a tokenizer plus a precedence-climbing
/// evaluator. Pure apart from the caller-supplied variable lookup/assignment
/// closures, which run on the shell's executor.
extension Programs {

    /// Evaluate an integer arithmetic expression (the body of `$(( … ))`, with
    /// `$`-expansions already applied). Supports `+ - * / % **`, bitwise
    /// `& | ^ ~ << >>`, comparisons, `&& || !`, the ternary `?:`, the comma
    /// operator, assignments (`= += -= …`), `++`/`--`, parentheses, decimal /
    /// hex / octal literals, and variable references resolved through `lookup`
    /// (unset or non-numeric ⇒ 0). Arithmetic wraps on overflow; division or
    /// modulo by zero yields 0. Malformed input evaluates leniently.
    static func evaluateArithmetic(_ text: String,
                                   lookup: @escaping (String) -> String?,
                                   assign: @escaping (String, String) -> Void) -> Int {
        var evaluator = ArithmeticEvaluator(text: text, lookup: lookup, assign: assign)
        return evaluator.parse()
    }

    struct ArithmeticEvaluator {
        private enum Tok: Equatable {
            case number(Int)
            case name(String)
            case op(String)
        }

        private var toks: [Tok] = []
        private var pos = 0
        private let lookup: (String) -> String?
        private let assign: (String, String) -> Void
        /// Non-zero while evaluating a branch whose side effects are discarded
        /// (the untaken arm of `?:`, the short-circuited side of `&&`/`||`).
        private var suppressed = 0

        private static let operators: [String] = [
            "<<=", ">>=", "**", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||",
            "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=",
            "+", "-", "*", "/", "%", "<", ">", "=", "!", "~", "&", "|", "^", "?", ":", "(", ")", ",",
        ]
        private static let assignmentOperators: Set<String> =
            ["=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "|=", "^="]
        private static let precedence: [String: Int] = [
            "||": 1, "&&": 2, "|": 3, "^": 4, "&": 5, "==": 6, "!=": 6,
            "<": 7, "<=": 7, ">": 7, ">=": 7, "<<": 8, ">>": 8,
            "+": 9, "-": 9, "*": 10, "/": 10, "%": 10,
        ]

        init(text: String, lookup: @escaping (String) -> String?,
             assign: @escaping (String, String) -> Void) {
            self.lookup = lookup
            self.assign = assign
            toks = Self.tokenize(Array(text))
        }

        private static func tokenize(_ c: [Character]) -> [Tok] {
            var out: [Tok] = []
            var i = 0
            func isNameChar(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }
            while i < c.count {
                let ch = c[i]
                if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "$" { i += 1; continue }
                if ch.isASCII, ch.isNumber {
                    var text = ""
                    while i < c.count, c[i].isASCII, c[i].isLetter || c[i].isNumber { text.append(c[i]); i += 1 }
                    out.append(.number(parseInteger(text)))
                    continue
                }
                if ch.isLetter || ch == "_" {
                    var name = ""
                    while i < c.count, isNameChar(c[i]) { name.append(c[i]); i += 1 }
                    out.append(.name(name))
                    continue
                }
                var matched = false
                for op in operators {
                    let o = Array(op)
                    if i + o.count <= c.count, Array(c[i..<i + o.count]) == o {
                        out.append(.op(op)); i += o.count; matched = true
                        break
                    }
                }
                if !matched { i += 1 }             // skip an unexpected character
            }
            return out
        }

        static func parseInteger(_ raw: String) -> Int {
            var text = raw
            var negative = false
            if text.hasPrefix("-") { negative = true; text.removeFirst() }
            else if text.hasPrefix("+") { text.removeFirst() }
            let value: Int
            if text.hasPrefix("0x") || text.hasPrefix("0X") {
                value = Int(text.dropFirst(2), radix: 16) ?? 0
            } else if text.count > 1, text.hasPrefix("0") {
                value = Int(text.dropFirst(), radix: 8) ?? 0
            } else {
                value = Int(text) ?? 0
            }
            return negative ? 0 &- value : value
        }

        mutating func parse() -> Int { comma() }

        private var peek: Tok? { pos < toks.count ? toks[pos] : nil }

        private mutating func accept(_ op: String) -> Bool {
            if peek == .op(op) { pos += 1; return true }
            return false
        }

        private func value(of name: String) -> Int {
            guard let raw = lookup(name) else { return 0 }
            let trimmed = raw.filter { $0 != " " && $0 != "\t" && $0 != "\n" }
            return Self.parseInteger(trimmed)
        }

        private func store(_ name: String, _ value: Int) {
            if suppressed == 0 { assign(name, String(value)) }
        }

        private mutating func comma() -> Int {
            var result = assignment()
            while accept(",") { result = assignment() }
            return result
        }

        private mutating func assignment() -> Int {
            if case let .name(name)? = peek, pos + 1 < toks.count,
               case let .op(op) = toks[pos + 1], Self.assignmentOperators.contains(op) {
                pos += 2
                let rhs = assignment()
                let result = op == "=" ? rhs : Self.apply(String(op.dropLast()), value(of: name), rhs)
                store(name, result)
                return result
            }
            return ternary()
        }

        private mutating func ternary() -> Int {
            let condition = binary(1)
            guard accept("?") else { return condition }
            if condition == 0 { suppressed += 1 }
            let whenTrue = assignment()
            if condition == 0 { suppressed -= 1 }
            _ = accept(":")
            if condition != 0 { suppressed += 1 }
            let whenFalse = assignment()
            if condition != 0 { suppressed -= 1 }
            return condition != 0 ? whenTrue : whenFalse
        }

        private mutating func binary(_ minimum: Int) -> Int {
            var left = power()
            while case let .op(op)? = peek, let prec = Self.precedence[op], prec >= minimum {
                pos += 1
                if op == "&&" || op == "||" {
                    let shortCircuit = op == "&&" ? left == 0 : left != 0
                    if shortCircuit { suppressed += 1 }
                    let right = binary(prec + 1)
                    if shortCircuit { suppressed -= 1 }
                    left = op == "&&" ? ((left != 0 && right != 0) ? 1 : 0)
                                      : ((left != 0 || right != 0) ? 1 : 0)
                } else {
                    let right = binary(prec + 1)
                    left = Self.apply(op, left, right)
                }
            }
            return left
        }

        private mutating func unary() -> Int {
            if accept("!") { return unary() == 0 ? 1 : 0 }
            if accept("~") { return ~unary() }
            if accept("-") { return 0 &- unary() }
            if accept("+") { return unary() }
            if peek == .op("++") || peek == .op("--") {
                let delta = peek == .op("++") ? 1 : -1
                pos += 1
                if case let .name(name)? = peek {
                    pos += 1
                    let result = value(of: name) &+ delta
                    store(name, result)
                    return result
                }
                return unary()
            }
            return primary()
        }

        /// `**` binds looser than the unary operators (as in bash: `-2**2` is 4)
        /// and is right-associative.
        private mutating func power() -> Int {
            let base = unary()
            guard accept("**") else { return base }
            let exponent = power()
            guard exponent >= 0 else { return 0 }
            var result = 1
            var factor = base
            var remaining = exponent
            while remaining > 0 {
                if remaining & 1 == 1 { result = result &* factor }
                factor = factor &* factor
                remaining >>= 1
            }
            return result
        }

        private mutating func primary() -> Int {
            guard let token = peek else { return 0 }
            switch token {
            case let .number(n):
                pos += 1
                return n
            case let .name(name):
                pos += 1
                let current = value(of: name)
                if accept("++") { store(name, current &+ 1) }
                else if accept("--") { store(name, current &- 1) }
                return current
            case .op("("):
                pos += 1
                let inner = comma()
                _ = accept(")")
                return inner
            case .op:
                pos += 1                          // skip an unexpected operator
                return 0
            }
        }

        private static func apply(_ op: String, _ a: Int, _ b: Int) -> Int {
            switch op {
            case "+": return a &+ b
            case "-": return a &- b
            case "*": return a &* b
            case "/": return b == 0 || (a == .min && b == -1) ? 0 : a / b
            case "%": return b == 0 || (a == .min && b == -1) ? 0 : a % b
            case "<<": return a &<< b
            case ">>": return a &>> b
            case "&": return a & b
            case "|": return a | b
            case "^": return a ^ b
            case "==": return a == b ? 1 : 0
            case "!=": return a != b ? 1 : 0
            case "<": return a < b ? 1 : 0
            case "<=": return a <= b ? 1 : 0
            case ">": return a > b ? 1 : 0
            case ">=": return a >= b ? 1 : 0
            default: return 0
            }
        }
    }
}
