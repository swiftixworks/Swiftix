/// Which variables of one function can be reached through a pointer.
///
/// In Go a variable declared in the body of a loop is a new variable on every
/// iteration, and so is the variable of a `for` or `range` clause. A VM local
/// is one storage cell that the next iteration writes again, which no program
/// can tell from Go's rule until a pointer to the variable outlives the
/// iteration: then every iteration's pointer would name the same cell. The
/// compiler gives such a variable a cell of its own each time it is declared,
/// and this is how it finds them, by name, before lowering a function:
///
/// - `&x`, `&x.f`, and `&x[i]` take the address of `x`;
/// - `x.m()` does when `m` has a pointer receiver, which the lowerer checks
///   once it knows the type of `x`;
/// - `x[a:b]` does when `x` is an array, which lends its storage to the slice.
///
/// Names are not resolved to scopes, so two variables of one name are treated
/// alike; that only gives a variable a cell it did not need. Function
/// literals are functions of their own and are not entered. A pure value.

struct GoAddressedVariables: Equatable, Sendable {
    /// Named by `&`, directly or through fields and elements.
    private(set) var addressed: Set<String> = []
    /// Sliced.
    private(set) var sliced: Set<String> = []
    /// Methods called on the variable itself.
    private(set) var receivers: [String: Set<String>] = [:]
    /// Methods called on a field or an element of the variable.
    private(set) var nestedReceivers: [String: Set<String>] = [:]

    init() {}

    init(_ body: GoBlock) {
        visit(body)
    }

    /// A function literal of the body captures the variables `names`: it
    /// holds a pointer to each, as `&x` would give.
    mutating func capture(_ names: Set<String>) {
        addressed.formUnion(names)
    }

    /// The variable a field or element path starts at: `x` of `x.f[i].g`.
    static func root(of expression: GoExpression) -> String? {
        switch expression {
        case .identifier(let name, _): return name
        case .selector(let base, _, _): return root(of: base)
        case .index(let base, _, _): return root(of: base)
        default: return nil
        }
    }

    private mutating func visit(_ block: GoBlock) {
        for statement in block.statements { visit(statement) }
    }

    private mutating func visit(_ statement: GoStatement) {
        switch statement {
        case .declaration(_, _, let expression, _, _):
            if let expression { visit(expression) }
        case .multiDeclaration(_, let expression, _):
            visit(expression)
        case .assignment(let target, let expression, _):
            visit(target)
            visit(expression)
        case .multiAssignment(let targets, let expression, _):
            targets.forEach { visit($0) }
            visit(expression)
        case .increment(let target, _, _):
            visit(target)
        case .expression(let expression):
            visit(expression)
        case .returnValues(let values, _):
            values.forEach { visit($0) }
        case .breakStatement, .continueStatement:
            break
        case .deferStatement(let expression, _), .goStatement(let expression, _):
            visit(expression)
        case .sendStatement(let channel, let value, _):
            visit(channel)
            visit(value)
        case .ifStatement(let condition, let thenBlock, let elseBlock, _):
            visit(condition)
            visit(thenBlock)
            if let elseBlock { visit(elseBlock) }
        case .forStatement(let initializer, let condition, let post, let body, _):
            if let initializer { visit(initializer) }
            if let condition { visit(condition) }
            if let post { visit(post) }
            visit(body)
        case .forRangeStatement(_, _, let collection, let body, _):
            visit(collection)
            visit(body)
        case .switchStatement(let expression, let cases, _):
            if let expression { visit(expression) }
            for switchCase in cases {
                switchCase.expressions.forEach { visit($0) }
                visit(switchCase.body)
            }
        case .selectStatement(let cases, _):
            for selectCase in cases {
                if let communication = selectCase.communication { visit(communication) }
                visit(selectCase.body)
            }
        }
    }

    private mutating func visit(_ expression: GoExpression) {
        switch expression {
        case .integer, .string, .identifier, .typeExpression, .functionLiteral:
            break
        case .selector(let base, _, _):
            visit(base)
        case .compositeLiteral(_, let elements, _):
            for element in elements {
                if let key = element.keyExpression { visit(key) }
                visit(element.value)
            }
        case .index(let base, let index, _):
            visit(base)
            visit(index)
        case .slicing(let base, let low, let high, _):
            if let name = Self.root(of: base) { sliced.insert(name) }
            visit(base)
            if let low { visit(low) }
            if let high { visit(high) }
        case .typeAssertion(let base, _, _):
            visit(base)
        case .call(let callee, let arguments, _):
            if case .selector(let receiver, let method, _) = callee,
                let name = Self.root(of: receiver)
            {
                if case .identifier = receiver {
                    receivers[name, default: []].insert(method)
                } else {
                    nestedReceivers[name, default: []].insert(method)
                }
            }
            visit(callee)
            arguments.forEach { visit($0) }
        case .unary(let unaryOperator, let operand, _):
            if unaryOperator == .address, let name = Self.root(of: operand) {
                addressed.insert(name)
            }
            visit(operand)
        case .binary(let left, _, let right, _):
            visit(left)
            visit(right)
        }
    }
}
