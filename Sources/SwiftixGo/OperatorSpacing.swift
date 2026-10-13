/// Where `gofmt` leaves out the blanks around a binary operator.
///
/// Go's printer does not space every operator alike. It prints `x*2 + y`,
/// `f(a+1, b)`, `s[i+1]`, and `s[lo : hi+1]`: an operator is joined to its
/// operands when a looser one stands beside it, or when the expression is
/// nested deeply enough that blanks would no longer show its structure. This
/// file is that decision, taken from `go/printer` rule for rule so the two
/// formatters agree:
///
/// - every expression is printed at a *depth*, 1 for an expression of a
///   statement, one more inside the arguments of a call that has several,
///   inside an index, on either side of an assignment of several values, and
///   for the operands of a binary operator of another precedence; a pair of
///   parentheses takes one level back;
/// - a binary expression has a *cutoff*: at depth 1 it is 6, or 5 when the
///   expression mixes `+`-like and `*`-like operators; deeper it is 4. An
///   operator below the cutoff has blanks, so comparisons and `&&`, `||`
///   always do;
/// - an operator that would run into the unary operator after it (`a - -b`,
///   `a / *p`, `a & &b`) keeps its blanks whatever the depth;
/// - the `:` of a slice expression has blanks when the expression is at
///   depth 1 and has two bounds of which one is a binary expression.
///
/// The printer also drops parentheses that say nothing: the second pair of
/// `((x))`, and the pair around the whole condition of an `if`, `for`, or
/// `switch` and around the operand of `range`, unless a composite literal
/// that begins with a type name would then stand before the block.
///
/// The formatter prints token by token, so the result is sets of source
/// offsets it looks tokens up in. An operator that is not listed keeps its
/// blanks, which is also what happens to anything this analysis does not
/// reach. Pure values and functions; no executor state.

struct GoOperatorSpacing: Equatable, Sendable {
    /// Offsets of the binary operators printed without blanks.
    private(set) var tight: Set<Int> = []
    /// Offsets of the `[` of the slice expressions whose `:` has blanks.
    private(set) var spacedSlices: Set<Int> = []
    /// Offsets of the parentheses that are not printed.
    private(set) var droppedParentheses: Set<Int> = []
    /// Every binary operator by its offset, with Go's precedence: where the
    /// source breaks a line after one, the printer keeps the break, and it
    /// needs to know where the operand that follows ends.
    private(set) var binaryOperators: [Int: Int] = [:]
    /// Offsets of the `(` that wrap an expression rather than open the
    /// arguments of a call or the parameters of a function.
    var groupingParentheses: Set<Int> { parentheses.opens }
    /// Offsets of the expressions the source wraps in parentheses, which the
    /// parser drops: each is the position of the expression inside a pair.
    private let parenthesized: Set<Int>
    private let parentheses: GoParentheses

    init() {
        parenthesized = []
        parentheses = GoParentheses()
    }

    init(file: GoFile, parentheses: GoParentheses) {
        self.parentheses = parentheses
        parenthesized = Set(parentheses.pairs.keys)
        droppedParentheses = parentheses.redundant
        for declaration in file.globalDeclarations {
            if let expression = declaration.expression { visit(expression, depth: 1) }
        }
        for function in file.functions { visit(function.body) }
    }

    // MARK: Binary expressions

    /// A binary operator application, with Go's precedence: 1 for `||`, 2
    /// for `&&`, 3 for a comparison, 4 for `+ - | ^`, 5 for `* / % << >> & &^`.
    private struct Binary {
        let precedence: Int
        let spelling: String
        let offset: Int
        let left: GoExpression
        let right: GoExpression
    }

    /// The binary expression `expression` is, unless parentheses wrap it:
    /// Go's printer sees those as a node of their own.
    private func binary(_ expression: GoExpression) -> Binary? {
        guard !parenthesized.contains(expression.position.offset) else { return nil }
        return bareBinary(expression)
    }

    private func bareBinary(_ expression: GoExpression) -> Binary? {
        if let operation = expression.bitwiseOperation {
            guard operation.operands.count == 2 else { return nil }
            let precedence: Int
            switch operation.operator {
            case .or, .xor: precedence = 4
            case .and, .andNot, .shiftLeft, .shiftRight: precedence = 5
            case .complement: return nil
            }
            return Binary(
                precedence: precedence, spelling: operation.operator.spelling,
                offset: expression.position.offset,
                left: operation.operands[0], right: operation.operands[1])
        }
        guard case .binary(let left, let binaryOperator, let right, let position) = expression
        else { return nil }
        let precedence: Int
        let spelling: String
        switch binaryOperator {
        case .logicalOr: (precedence, spelling) = (1, "||")
        case .logicalAnd: (precedence, spelling) = (2, "&&")
        case .equal: (precedence, spelling) = (3, "==")
        case .notEqual: (precedence, spelling) = (3, "!=")
        case .less: (precedence, spelling) = (3, "<")
        case .lessEqual: (precedence, spelling) = (3, "<=")
        case .greater: (precedence, spelling) = (3, ">")
        case .greaterEqual: (precedence, spelling) = (3, ">=")
        case .add: (precedence, spelling) = (4, "+")
        case .subtract: (precedence, spelling) = (4, "-")
        case .multiply: (precedence, spelling) = (5, "*")
        case .divide: (precedence, spelling) = (5, "/")
        case .remainder: (precedence, spelling) = (5, "%")
        }
        return Binary(
            precedence: precedence, spelling: spelling, offset: position.offset,
            left: left, right: right)
    }

    /// The operator a unary expression begins with, unless parentheses wrap
    /// it. A dereference is Go's `StarExpr`, which the printer tells apart.
    private func unarySpelling(_ expression: GoExpression) -> String? {
        guard !parenthesized.contains(expression.position.offset) else { return nil }
        if let operation = expression.bitwiseOperation {
            return operation.operator.isUnary ? operation.operator.spelling : nil
        }
        guard case .unary(let unaryOperator, _, _) = expression else { return nil }
        switch unaryOperator {
        case .plus: return "+"
        case .minus: return "-"
        case .not: return "!"
        case .address: return "&"
        case .dereference: return "*"
        case .receive: return "<-"
        }
    }

    /// What one binary expression holds, as far as its own operators reach:
    /// whether it has `+`-like and `*`-like operators, and the precedence of
    /// an operator that must keep its blanks.
    private func walk(_ expression: Binary) -> (has4: Bool, has5: Bool, problem: Int) {
        var has4 = expression.precedence == 4
        var has5 = expression.precedence == 5
        var problem = 0
        if let left = binary(expression.left), left.precedence >= expression.precedence {
            let inner = walk(left)
            has4 = has4 || inner.has4
            has5 = has5 || inner.has5
            problem = max(problem, inner.problem)
        }
        if let right = binary(expression.right) {
            if right.precedence > expression.precedence {
                let inner = walk(right)
                has4 = has4 || inner.has4
                has5 = has5 || inner.has5
                problem = max(problem, inner.problem)
            }
        } else if let unary = unarySpelling(expression.right) {
            switch expression.spelling + unary {
            case "/*", "&&", "&^": problem = 5
            case "++", "--": problem = max(problem, 4)
            default: break
            }
        }
        return (has4, has5, problem)
    }

    private func cutoff(_ expression: Binary, depth: Int) -> Int {
        let found = walk(expression)
        if found.problem > 0 { return found.problem + 1 }
        if found.has4 && found.has5 { return depth == 1 ? 5 : 4 }
        return depth == 1 ? 6 : 4
    }

    // MARK: Expressions

    private mutating func visit(_ expression: GoExpression, depth: Int) {
        if parenthesized.contains(expression.position.offset) {
            // Parentheses undo one level of depth.
            visitBare(expression, depth: max(1, depth - 1))
        } else {
            visitBare(expression, depth: depth)
        }
    }

    private mutating func visitBare(_ expression: GoExpression, depth: Int) {
        if let operation = bareBinary(expression) {
            binaryOperators[operation.offset] = operation.precedence
            if operation.precedence >= cutoff(operation, depth: depth) {
                tight.insert(operation.offset)
            }
            // An operand of the same precedence continues the expression.
            let continues = binary(operation.left)?.precedence == operation.precedence
            visit(operation.left, depth: continues ? depth : depth + 1)
            visit(operation.right, depth: depth + 1)
            return
        }
        if let operation = expression.bitwiseOperation {
            // The unary `^x`.
            for operand in operation.operands { visit(operand, depth: depth) }
            return
        }
        if let operand = expression.spreadOperand {
            visit(operand, depth: depth)
            return
        }
        switch expression {
        case .integer, .string, .identifier, .typeExpression, .binary:
            break
        case .selector(let base, _, _), .typeAssertion(let base, _, _):
            visit(base, depth: depth)
        case .unary(let unaryOperator, let operand, _):
            // The operand of `*` is printed as an expression of its own.
            visit(operand, depth: unaryOperator == .dereference ? 1 : depth)
        case .index(let base, let index, _):
            visit(base, depth: 1)
            visit(index, depth: depth + 1)
        case .slicing(let base, let low, let high, let position):
            visit(base, depth: 1)
            if depth <= 1, let low, let high, binary(low) != nil || binary(high) != nil {
                spacedSlices.insert(position.offset)
            }
            if let low { visit(low, depth: depth + 1) }
            if let high { visit(high, depth: depth + 1) }
        case .call(let callee, let arguments, _):
            let inner = arguments.count > 1 ? depth + 1 : depth
            visit(callee, depth: inner)
            for argument in arguments { visit(argument, depth: inner) }
        case .compositeLiteral(_, let elements, _):
            for element in elements {
                if let key = element.keyExpression { visit(key, depth: 1) }
                visit(element.value, depth: 1)
            }
        case .functionLiteral(_, _, _, let body, _):
            visit(body)
        }
    }

    // MARK: Parentheses

    /// Drops the parentheses around the whole of a control clause's
    /// expression, as Go's printer does, and visits the expression.
    private mutating func visitClause(_ expression: GoExpression) {
        if let pair = parentheses.pairs[expression.position.offset],
            !startsBlockAmbiguously(expression, isClause: true)
        {
            droppedParentheses.insert(pair.open)
            droppedParentheses.insert(pair.close)
        }
        visit(expression, depth: 1)
    }

    /// Whether `expression` holds a composite literal that begins with a type
    /// name outside any parentheses of its own: before the `{` of a block
    /// that would read as the block's operand.
    private func startsBlockAmbiguously(_ expression: GoExpression, isClause: Bool = false) -> Bool {
        // Parentheses protect what they enclose.
        if !isClause, parenthesized.contains(expression.position.offset) { return false }
        if let operation = expression.bitwiseOperation {
            return operation.operands.contains { startsBlockAmbiguously($0) }
        }
        if let operand = expression.spreadOperand { return startsBlockAmbiguously(operand) }
        switch expression {
        case .integer, .string, .identifier, .typeExpression, .functionLiteral:
            return false
        case .compositeLiteral(let type, _, _):
            if case .named = type { return true }
            return false
        case .selector(let base, _, _), .typeAssertion(let base, _, _):
            return startsBlockAmbiguously(base)
        case .unary(_, let operand, _):
            return startsBlockAmbiguously(operand)
        case .index(let base, let index, _):
            return startsBlockAmbiguously(base) || startsBlockAmbiguously(index)
        case .slicing(let base, let low, let high, _):
            return ([base, low, high] as [GoExpression?]).contains {
                $0.map { startsBlockAmbiguously($0) } ?? false
            }
        case .call(let callee, let arguments, _):
            return startsBlockAmbiguously(callee)
                || arguments.contains { startsBlockAmbiguously($0) }
        case .binary(let left, _, let right, _):
            return startsBlockAmbiguously(left) || startsBlockAmbiguously(right)
        }
    }

    // MARK: Statements

    private mutating func visit(_ block: GoBlock) {
        for statement in block.statements { visit(statement) }
    }

    private mutating func visit(_ statement: GoStatement) {
        switch statement {
        case .declaration(_, _, let expression, _, _):
            if let expression { visit(expression, depth: 1) }
        case .multiDeclaration(_, let expression, _):
            if let variables = expression.variables {
                // The values of a `var` or `const` are a plain list.
                for value in variables.values { visit(value, depth: 1) }
            } else if let values = expression.valueList {
                for value in values { visit(value, depth: 2) }
            } else {
                visit(expression, depth: 1)
            }
        case .assignment(let target, let expression, _):
            visit(target, depth: 1)
            if let operation = bareBinary(expression),
                operation.left.position == target.position
            {
                // `x op= y` is parsed as `x = x op y`; the source holds `y`.
                visit(operation.right, depth: 1)
            } else {
                visit(expression, depth: 1)
            }
        case .multiAssignment(let targets, let expression, _):
            if let values = expression.valueList {
                // Several values for several targets: both sides one deeper.
                for target in targets { visit(target, depth: 2) }
                for value in values { visit(value, depth: 2) }
            } else {
                for target in targets { visit(target, depth: 1) }
                visit(expression, depth: 1)
            }
        case .increment(let target, _, _):
            visit(target, depth: 2)
        case .expression(let expression):
            visit(expression, depth: 1)
        case .returnValues(let values, _):
            for value in values { visit(value, depth: 1) }
        case .breakStatement, .continueStatement:
            break
        case .deferStatement(let expression, _), .goStatement(let expression, _):
            visit(expression, depth: 1)
        case .sendStatement(let channel, let value, _):
            visit(channel, depth: 1)
            visit(value, depth: 1)
        case .ifStatement(let condition, let thenBlock, let elseBlock, _):
            visitClause(condition)
            visit(thenBlock)
            if let elseBlock { visit(elseBlock) }
        case .forStatement(let initializer, let condition, let post, let body, _):
            // Also an `if` or `switch` with an initializer, which is one.
            if let initializer { visit(initializer) }
            if let condition { visitClause(condition) }
            if let post { visit(post) }
            visit(body)
        case .forRangeStatement(_, _, let collection, let body, _):
            visitClause(collection)
            visit(body)
        case .switchStatement(let expression, let cases, _):
            if let expression { visitClause(expression) }
            for switchCase in cases {
                for expression in switchCase.expressions { visit(expression, depth: 1) }
                visit(switchCase.body)
            }
        case .selectStatement(let cases, _):
            for selectCase in cases {
                if let communication = selectCase.communication { visit(communication) }
                visit(selectCase.body)
            }
        }
    }
}
