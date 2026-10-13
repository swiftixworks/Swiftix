/// Rewrites the names of a syntax tree in the order Go brings them into scope.
///
/// A name in Go means what the innermost block that declares it says, and a
/// declaration reaches from its own end to the end of its block: `x := x + 1`
/// reads the outer `x`. The traversal here visits every declaration and every
/// use in that order, and opens and closes a scope wherever Go has a block —
/// a function, a braced block, the clauses of `if`, `for`, `switch`, and
/// `select` — so a conformer can keep a stack of scopes and answer for each
/// name where it stands. Names that are not looked up in a scope are left
/// alone: fields, methods, and the keys of a struct literal.
protocol GoScopedRewriter {
    mutating func openScope()
    mutating func closeScope()

    /// A variable, constant, parameter, or result is declared in the scope
    /// that is open; returns the name to declare it by.
    mutating func declare(_ name: String, at position: GoSourcePosition) throws -> String

    /// A name used as a value.
    mutating func value(named name: String, at position: GoSourcePosition) throws -> GoExpression

    /// A name used as a type; a qualified one arrives as `package.Name`.
    mutating func type(named name: String, at position: GoSourcePosition) throws -> GoTypeExpression

    /// `qualifier.member`, where the qualifier is an identifier. Returns nil
    /// to have it rewritten as a selection from a value.
    mutating func member(
        _ member: String, of qualifier: String,
        qualifierPosition: GoSourcePosition, position: GoSourcePosition
    ) throws -> GoExpression?

    /// A type declared in a function; returns what stands in its place.
    mutating func localType(
        name: String, type: GoTypeExpression, position: GoSourcePosition
    ) throws -> [GoStatement]
}

extension GoScopedRewriter {
    private mutating func declared(
        _ name: String, at position: GoSourcePosition
    ) throws -> String {
        name == GoValueList.blank ? name : try declare(name, at: position)
    }

    // MARK: Declarations

    mutating func rewrite(_ function: GoFunctionDeclaration) throws -> GoFunctionDeclaration {
        openScope()
        defer { closeScope() }
        let receiver = try function.receiver.map { try rewrite($0) }
        let parameters = try function.parameters.map { try rewrite($0) }
        let resultTypes = try function.resultTypes.map { try rewrite($0) }
        let resultNames = try function.resultNames.map { name in
            try name.map { try declared($0, at: function.position) }
        }
        return GoFunctionDeclaration(
            name: function.name,
            receiver: receiver,
            parameters: parameters,
            resultNames: resultNames,
            resultTypes: resultTypes,
            body: try rewrite(function.body),
            position: function.position)
    }

    mutating func rewrite(_ parameter: GoParameter) throws -> GoParameter {
        let type = try rewrite(parameter.type)
        return GoParameter(
            name: try declared(parameter.name, at: parameter.position),
            type: type,
            position: parameter.position)
    }

    // MARK: Types

    mutating func rewrite(_ type: GoTypeExpression) throws -> GoTypeExpression {
        switch type {
        case .named(let name, let position):
            return try self.type(named: name, at: position)
        case .structure(let fields, let position):
            return .structure(
                fields: try fields.map {
                    GoStructFieldDeclaration(
                        name: $0.name, type: try rewrite($0.type), position: $0.position)
                },
                position: position)
        case .pointer(let pointee, let position):
            return .pointer(pointee: try rewrite(pointee), position: position)
        case .array(let length, let element, let position):
            return .array(length: length, element: try rewrite(element), position: position)
        case .slice(let element, let position):
            return .slice(element: try rewrite(element), position: position)
        case .map(let key, let value, let position):
            return .map(key: try rewrite(key), value: try rewrite(value), position: position)
        case .channel(let direction, let element, let position):
            return .channel(
                direction: direction, element: try rewrite(element), position: position)
        case .interface(let methods, let position):
            return .interface(
                methods: try methods.map { method in
                    GoInterfaceMethodDeclaration(
                        name: method.name,
                        parameters: try method.parameters.map { try rewrite($0) },
                        results: try method.results.map { try rewrite($0) },
                        position: method.position)
                },
                position: position)
        }
    }

    // MARK: Statements

    mutating func rewrite(_ block: GoBlock) throws -> GoBlock {
        openScope()
        defer { closeScope() }
        var statements: [GoStatement] = []
        statements.reserveCapacity(block.statements.count)
        for statement in block.statements {
            statements.append(contentsOf: try rewrite(statement))
        }
        return GoBlock(statements: statements, position: block.position)
    }

    /// A statement that stands alone in its clause: the initializer or post
    /// statement of a `for`, the communication of a `select` case.
    /// The grammar has no type declaration there, which alone is rewritten
    /// to another number of statements.
    private mutating func rewriteSingle(_ statement: GoStatement) throws -> GoStatement {
        try rewrite(statement).first ?? statement
    }

    mutating func rewrite(_ statement: GoStatement) throws -> [GoStatement] {
        if let declaration = statement.localType {
            return try localType(
                name: declaration.name, type: declaration.type, position: declaration.position)
        }
        switch statement {
        case .declaration(let name, let explicitType, let expression, let isConstant, let position):
            let type = try explicitType.map { try rewrite($0) }
            let value = try expression.map { try rewrite($0) }
            return [
                .declaration(
                    name: try declared(name, at: position),
                    explicitType: type,
                    expression: value,
                    isConstant: isConstant,
                    position: position)
            ]
        case .multiDeclaration(let names, let expression, let position):
            let value = try rewrite(expression)
            return [
                .multiDeclaration(
                    names: try names.map { try declared($0, at: position) },
                    expression: value,
                    position: position)
            ]
        case .assignment(let target, let expression, let position):
            return [
                .assignment(
                    target: try rewrite(target),
                    expression: try rewrite(expression),
                    position: position)
            ]
        case .multiAssignment(let targets, let expression, let position):
            return [
                .multiAssignment(
                    targets: try targets.map { try rewrite($0) },
                    expression: try rewrite(expression),
                    position: position)
            ]
        case .increment(let target, let incrementOperator, let position):
            return [
                .increment(
                    target: try rewrite(target), operator: incrementOperator, position: position)
            ]
        case .expression(let expression):
            return [.expression(try rewrite(expression))]
        case .returnValues(let values, let position):
            return [.returnValues(try values.map { try rewrite($0) }, position: position)]
        case .breakStatement, .continueStatement:
            return [statement]
        case .deferStatement(let expression, let position):
            return [.deferStatement(expression: try rewrite(expression), position: position)]
        case .goStatement(let expression, let position):
            return [.goStatement(expression: try rewrite(expression), position: position)]
        case .sendStatement(let channel, let value, let position):
            return [
                .sendStatement(
                    channel: try rewrite(channel), value: try rewrite(value), position: position)
            ]
        case .ifStatement(let condition, let thenBlock, let elseBlock, let position):
            return [
                .ifStatement(
                    condition: try rewrite(condition),
                    thenBlock: try rewrite(thenBlock),
                    elseBlock: try elseBlock.map { try rewrite($0) },
                    position: position)
            ]
        case .forStatement(let initializer, let condition, let post, let body, let position):
            // Also an `if` or `switch` with an initializer, whose scope is
            // the same: the initializer's names reach the whole statement.
            openScope()
            defer { closeScope() }
            return [
                .forStatement(
                    initializer: try initializer.map { try rewriteSingle($0) },
                    condition: try condition.map { try rewrite($0) },
                    post: try post.map { try rewriteSingle($0) },
                    body: try rewrite(body),
                    position: position)
            ]
        case .forRangeStatement(let indexName, let valueName, let collection, let body, let position):
            let rewrittenCollection = try rewrite(collection)
            openScope()
            defer { closeScope() }
            return [
                .forRangeStatement(
                    indexName: try indexName.map { try declared($0, at: position) },
                    valueName: try valueName.map { try declared($0, at: position) },
                    collection: rewrittenCollection,
                    body: try rewrite(body),
                    position: position)
            ]
        case .switchStatement(let expression, let cases, let position):
            return [
                .switchStatement(
                    expression: try expression.map { try rewrite($0) },
                    cases: try cases.map { switchCase in
                        GoSwitchCase(
                            expressions: try switchCase.expressions.map { try rewrite($0) },
                            body: try rewrite(switchCase.body),
                            isDefault: switchCase.isDefault,
                            position: switchCase.position)
                    },
                    position: position)
            ]
        case .selectStatement(let cases, let position):
            return [
                .selectStatement(
                    cases: try cases.map { selectCase in
                        openScope()
                        defer { closeScope() }
                        return GoSelectCase(
                            communication: try selectCase.communication.map {
                                try rewriteSingle($0)
                            },
                            body: try rewrite(selectCase.body),
                            position: selectCase.position)
                    },
                    position: position)
            ]
        }
    }

    // MARK: Expressions

    mutating func rewrite(_ expression: GoExpression) throws -> GoExpression {
        switch expression {
        case .integer, .string:
            return expression
        case .identifier(let name, let position):
            return try value(named: name, at: position)
        case .selector(let base, let name, let position):
            if case .identifier(let qualifier, let qualifierPosition) = base,
                let resolved = try member(
                    name, of: qualifier, qualifierPosition: qualifierPosition, position: position)
            {
                return resolved
            }
            return .selector(base: try rewrite(base), name: name, position: position)
        case .compositeLiteral(let type, let elements, let position):
            return .compositeLiteral(
                type: try rewrite(type),
                elements: try elements.map { element in
                    GoCompositeElement(
                        key: element.key,
                        keyExpression: try element.keyExpression.map { try rewrite($0) },
                        value: try rewrite(element.value),
                        position: element.position)
                },
                position: position)
        case .index(let base, let index, let position):
            return .index(base: try rewrite(base), index: try rewrite(index), position: position)
        case .slicing(let base, let low, let high, let position):
            return .slicing(
                base: try rewrite(base),
                low: try low.map { try rewrite($0) },
                high: try high.map { try rewrite($0) },
                position: position)
        case .typeExpression(let type, let position):
            return .typeExpression(try rewrite(type), position: position)
        case .call(let callee, let arguments, let position):
            // A call the parser made up to carry a list or an operator has a
            // name no scope declares.
            if case .identifier(let name, _) = callee, name.hasPrefix("$") {
                return .call(
                    callee: callee,
                    arguments: try arguments.map { try rewrite($0) },
                    position: position)
            }
            return .call(
                callee: try rewrite(callee),
                arguments: try arguments.map { try rewrite($0) },
                position: position)
        case .typeAssertion(let base, let type, let position):
            return .typeAssertion(
                base: try rewrite(base), type: try rewrite(type), position: position)
        case .functionLiteral(let parameters, let resultNames, let resultTypes, let body, let position):
            openScope()
            defer { closeScope() }
            let rewrittenParameters = try parameters.map { try rewrite($0) }
            let rewrittenResults = try resultTypes.map { try rewrite($0) }
            return .functionLiteral(
                parameters: rewrittenParameters,
                resultNames: try resultNames.map { name in
                    try name.map { try declared($0, at: position) }
                },
                resultTypes: rewrittenResults,
                body: try rewrite(body),
                position: position)
        case .unary(let unaryOperator, let operand, let position):
            return .unary(
                operator: unaryOperator, operand: try rewrite(operand), position: position)
        case .binary(let left, let binaryOperator, let right, let position):
            return .binary(
                left: try rewrite(left),
                operator: binaryOperator,
                right: try rewrite(right),
                position: position)
        }
    }
}
