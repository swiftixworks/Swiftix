/// Function types.
///
/// `GoTypeExpression` has no case for `func(int) string`. It is carried as
/// an interface type with one method, whose name no program can write and
/// whose parameters and results are the function's: every pass that walks a
/// type reads the types inside it without knowing, and the passes that give
/// a type its meaning ask `functionSignature` first.
enum GoFunctionType {
    static let methodName = "$func"

    /// The name of the function a literal is compiled to: where it is.
    static func literalName(at position: GoSourcePosition) -> String {
        "$literal.\(position.path).\(position.offset)"
    }
}

extension GoTypeExpression {
    static func function(
        parameters: [GoTypeExpression], results: [GoTypeExpression], position: GoSourcePosition
    ) -> GoTypeExpression {
        .interface(
            methods: [
                GoInterfaceMethodDeclaration(
                    name: GoFunctionType.methodName, parameters: parameters, results: results,
                    position: position)
            ],
            position: position)
    }

    /// What a function type takes and gives, when this is one.
    var functionSignature: (parameters: [GoTypeExpression], results: [GoTypeExpression])? {
        guard case .interface(let methods, _) = self, methods.count == 1,
            methods[0].name == GoFunctionType.methodName
        else { return nil }
        return (methods[0].parameters, methods[0].results)
    }
}

/// The function literals of a syntax tree.
enum GoFunctionLiterals {
    /// Whether `block` has a `defer` statement of its own function: one in
    /// a literal inside it belongs to the literal.
    static func hasDefer(in block: GoBlock) -> Bool {
        block.statements.contains { statement in
            switch statement {
            case .deferStatement:
                return true
            case .ifStatement(_, let thenBlock, let elseBlock, _):
                return hasDefer(in: thenBlock) || (elseBlock.map(hasDefer) ?? false)
            case .forStatement(let initializer, _, _, let body, _):
                if case .deferStatement? = initializer { return true }
                return hasDefer(in: body)
            case .forRangeStatement(_, _, _, let body, _):
                return hasDefer(in: body)
            case .switchStatement(_, let cases, _):
                return cases.contains { hasDefer(in: $0.body) }
            case .selectStatement(let cases, _):
                return cases.contains { hasDefer(in: $0.body) }
            default:
                return false
            }
        }
    }

    /// Calls `visit` with every function literal in `block`, one inside
    /// another after it.
    static func forEach(in block: GoBlock, _ visit: (GoExpression) -> Void) {
        for statement in block.statements { forEach(in: statement, visit) }
    }

    static func forEach(in statement: GoStatement, _ visit: (GoExpression) -> Void) {
        switch statement {
        case .declaration(_, _, let expression, _, _):
            if let expression { forEach(in: expression, visit) }
        case .multiDeclaration(_, let expression, _), .expression(let expression),
            .deferStatement(let expression, _), .goStatement(let expression, _):
            forEach(in: expression, visit)
        case .assignment(let target, let expression, _):
            forEach(in: target, visit)
            forEach(in: expression, visit)
        case .multiAssignment(let targets, let expression, _):
            targets.forEach { forEach(in: $0, visit) }
            forEach(in: expression, visit)
        case .increment(let target, _, _):
            forEach(in: target, visit)
        case .returnValues(let values, _):
            values.forEach { forEach(in: $0, visit) }
        case .breakStatement, .continueStatement:
            break
        case .sendStatement(let channel, let value, _):
            forEach(in: channel, visit)
            forEach(in: value, visit)
        case .ifStatement(let condition, let thenBlock, let elseBlock, _):
            forEach(in: condition, visit)
            forEach(in: thenBlock, visit)
            if let elseBlock { forEach(in: elseBlock, visit) }
        case .forStatement(let initializer, let condition, let post, let body, _):
            if let initializer { forEach(in: initializer, visit) }
            if let condition { forEach(in: condition, visit) }
            if let post { forEach(in: post, visit) }
            forEach(in: body, visit)
        case .forRangeStatement(_, _, let collection, let body, _):
            forEach(in: collection, visit)
            forEach(in: body, visit)
        case .switchStatement(let expression, let cases, _):
            if let expression { forEach(in: expression, visit) }
            for switchCase in cases {
                switchCase.expressions.forEach { forEach(in: $0, visit) }
                forEach(in: switchCase.body, visit)
            }
        case .selectStatement(let cases, _):
            for selectCase in cases {
                if let communication = selectCase.communication { forEach(in: communication, visit) }
                forEach(in: selectCase.body, visit)
            }
        }
    }

    static func forEach(in expression: GoExpression, _ visit: (GoExpression) -> Void) {
        switch expression {
        case .integer, .string, .identifier, .typeExpression:
            break
        case .functionLiteral(_, _, _, let body, _):
            visit(expression)
            forEach(in: body, visit)
        case .selector(let base, _, _), .typeAssertion(let base, _, _):
            forEach(in: base, visit)
        case .unary(_, let operand, _):
            forEach(in: operand, visit)
        case .binary(let left, _, let right, _):
            forEach(in: left, visit)
            forEach(in: right, visit)
        case .index(let base, let index, _):
            forEach(in: base, visit)
            forEach(in: index, visit)
        case .slicing(let base, let low, let high, _):
            forEach(in: base, visit)
            if let low { forEach(in: low, visit) }
            if let high { forEach(in: high, visit) }
        case .call(let callee, let arguments, _):
            forEach(in: callee, visit)
            arguments.forEach { forEach(in: $0, visit) }
        case .compositeLiteral(_, let elements, _):
            for element in elements {
                if let key = element.keyExpression { forEach(in: key, visit) }
                forEach(in: element.value, visit)
            }
        }
    }
}

/// A method expression, `T.m` or `(*T).m`: the method as a function that
/// takes its receiver first.
enum GoMethodExpression {
    /// The name `base` gives and whether it is `*` of it. The caller knows
    /// whether the name is one of a type.
    static func receiver(of base: GoExpression) -> (typeName: String, pointer: Bool)? {
        switch base {
        case .identifier(let name, _): return (name, false)
        case .unary(.dereference, .identifier(let name, _), _): return (name, true)
        default: return nil
        }
    }

    /// `T.m` or `(*T).m`, as Go writes it in a message.
    static func spelling(_ receiver: (typeName: String, pointer: Bool), _ name: String) -> String {
        (receiver.pointer ? "(*\(receiver.typeName))" : receiver.typeName) + "." + name
    }
}
