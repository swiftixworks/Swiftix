/// What a composite literal leaves for the type it is written in to say.
///
/// Three things in a literal are settled by a type that is not written
/// there:
///
/// - **An element without a type.** In `[]point{{1, 2}}` the inner literal
///   is a `point` because the outer one is a slice of them, and in
///   `[]*point{{1, 2}}` it is `&point{1, 2}`. `GoExpression.compositeLiteral`
///   has no room for a literal without a type, so the parser gives such a
///   literal a type no source can name, `$elided`.
/// - **A key.** `T{a: 1}` names a field when `T` is a struct, reads the
///   variable `a` when it is a map, and wants a constant index when it is an
///   array or a slice. The parser keeps both readings of a key that is an
///   identifier: its name and the expression.
/// - **The length of `[...]T`**, which is that of the literal. The parser
///   writes it as an array of the length `openLength`, which no array has.
///
/// `GoCompositeLiterals.resolve` settles all three on the syntax tree, for
/// the whole program at once, after every type has the one name the program
/// knows it by: it gives an elided literal the element or key type of the
/// literal around it, keeps of each key the one reading the type asks for,
/// replaces the index of an array or slice element by its value, and counts
/// the elements of `[...]T`. The checker and the compiler then meet only
/// literals that say what they are, as they did before.
///
/// The same walk settles the one other place where a name is a type or a
/// value by what declares it: the first operand of `new` and `make`. `T`,
/// `*T`, and `pkg.T` there become the type they name, as a type that is
/// written out (`[]int`, `struct{}`) already is.
enum GoCompositeLiterals {
    /// The type of a literal written without one.
    static let elidedTypeName = "$elided"

    /// The length of `[...]T` until its literal has been counted.
    static let openLength = -2

    /// The most elements an array or slice literal may have, counting those
    /// an index leaves out: each is an operand of one instruction.
    static let maximumLength = 1 << 20

    /// Whether `name` is a builtin whose first operand is a type.
    static func takesType(_ name: String) -> Bool {
        name == "new" || name == "make"
    }

    /// Whether `name` is a type every package has, or one of the numeric
    /// types this dialect names only to refuse.
    static func isPredeclaredType(_ name: String) -> Bool {
        switch name {
        case "int", "string", "bool", "byte", "uint8", "error", "any": return true
        default:
            return GoPredeclared.unsupportedNumericTypes.contains(name)
                || GoPredeclared.numericType(name) != nil
        }
    }

    /// `[...]T` is the type of a literal and of nothing else: an array type
    /// that still has no length when it is given its meaning stands elsewhere.
    static func requireLength(_ length: Int, at position: GoSourcePosition) throws {
        guard length == openLength else { return }
        throw GoDiagnostic(
            position: position,
            message: "invalid use of [...] array (outside a composite literal)")
    }

    /// Where the `}` of the literal at `position` is kept among the name
    /// positions of its file: below every offset of the source.
    static func endKey(of position: GoSourcePosition) -> Int {
        -1 - position.offset
    }

    /// The files of a whole program with every literal's type, keys, and
    /// length settled.
    static func resolve(_ files: [GoFile]) throws -> [GoFile] {
        guard files.contains(where: \.hasOpenLiterals) else { return files }
        var types: [String: GoTypeExpression] = [:]
        var constants: [String: GoExpression] = [:]
        var values: Set<String> = []
        for file in files {
            for declaration in file.typeDeclarations { types[declaration.name] = declaration.type }
            for declaration in file.globalDeclarations {
                values.insert(declaration.name)
                if declaration.isConstant { constants[declaration.name] = declaration.expression }
            }
            for function in file.functions where function.receiver == nil {
                values.insert(function.name)
            }
        }
        var resolver = LiteralResolver(types: types, constants: constants, values: values)
        return files.map { file in
            guard file.hasOpenLiterals else { return file }
            var rebuilt = file.rebuilt(
                imports: file.imports,
                typeDeclarations: file.typeDeclarations,
                globalDeclarations: file.globalDeclarations.map { declaration in
                    GoGlobalDeclaration(
                        name: declaration.name,
                        explicitType: declaration.explicitType,
                        expression: declaration.expression.map { resolver.rewrite($0) },
                        isConstant: declaration.isConstant,
                        position: declaration.position)
                },
                functions: file.functions.map { resolver.rewrite($0) })
            rebuilt.hasOpenLiterals = false
            return rebuilt
        }
    }
}

extension GoTypeExpression {
    /// Whether this stands for the type a literal left out.
    var isElided: Bool {
        if case .named(GoCompositeLiterals.elidedTypeName, _) = self { return true }
        return false
    }

    /// Whether this is `[...]T`, not yet counted.
    var isOpenArray: Bool {
        if case .array(GoCompositeLiterals.openLength, _, _) = self { return true }
        return false
    }
}

extension GoCompositeElement {
    /// The readings of the key `expression` that a literal of `type` may
    /// ask for. A literal type that is written out says which it is; a name
    /// may be that of a struct, a map, an array, or a slice.
    static func key(
        _ expression: GoExpression, in type: GoTypeExpression
    ) -> (name: String?, expression: GoExpression?) {
        var name: String?
        if case .identifier(let identifier, _) = expression { name = identifier }
        switch type {
        case .map, .array, .slice: return (nil, expression)
        case .structure: return name == nil ? (nil, expression) : (name, nil)
        default: return (name, expression)
        }
    }

    /// Whether the key may still be a field's name or an expression.
    var hasOpenKey: Bool { key != nil && keyExpression != nil }
}

extension GoExpression {
    /// The index an element of an array or slice literal is written with,
    /// once it is known.
    var literalIndex: Int? {
        if case .integer(let value, _) = self { return Int(exactly: value) }
        return nil
    }
}

/// Settles the literals of a program. See `GoCompositeLiterals`.
///
/// A name used as an index is a constant of the package or of an enclosing
/// block, so the walk keeps the names each block declares: a variable hides
/// a constant of the package, and a constant of a function has a value.
private struct LiteralResolver {
    /// What a type gives the elements of a literal of it.
    private enum Shape {
        /// An array or a slice.
        case list(element: GoTypeExpression)
        case map(key: GoTypeExpression, value: GoTypeExpression)
        /// A struct, or a type nothing here declares.
        case other
    }

    /// A name a function declares: a constant with its value, or anything
    /// else.
    private enum Local {
        case constant(GoExpression)
        case variable
    }

    let types: [String: GoTypeExpression]
    let constants: [String: GoExpression]
    /// The variables, constants, and functions of the program's packages.
    let values: Set<String>
    private var scopes: [[String: Local]] = []

    init(types: [String: GoTypeExpression], constants: [String: GoExpression], values: Set<String>) {
        self.types = types
        self.constants = constants
        self.values = values
    }

    // MARK: Types

    private func shape(of type: GoTypeExpression) -> Shape {
        var current = type
        var seen: Set<String> = []
        while true {
            switch current {
            case .array(let length, let element, _) where length != GoSpread.variadicLength:
                return .list(element: element)
            case .slice(let element, _):
                return .list(element: element)
            case .map(let key, let value, _):
                return .map(key: key, value: value)
            case .named(let name, _):
                guard seen.insert(name).inserted, let declared = types[name] else { return .other }
                current = declared
            default:
                return .other
            }
        }
    }

    /// What `type` points to, when it is a pointer type or names one.
    private func pointee(of type: GoTypeExpression) -> GoTypeExpression? {
        var current = type
        var seen: Set<String> = []
        while true {
            switch current {
            case .pointer(let pointee, _):
                return pointee
            case .named(let name, _):
                guard seen.insert(name).inserted, let declared = types[name] else { return nil }
                current = declared
            default:
                return nil
            }
        }
    }

    /// `value` as an element or a key of the type `type`: a literal that
    /// left its type out is one of that type, or the address of one of the
    /// type it points to.
    private func typed(_ value: GoExpression, as type: GoTypeExpression) -> GoExpression {
        guard case .compositeLiteral(let written, let elements, let position) = value,
            written.isElided
        else { return value }
        if let pointee = pointee(of: type) {
            return .unary(
                operator: .address,
                operand: .compositeLiteral(type: pointee, elements: elements, position: position),
                position: position)
        }
        return .compositeLiteral(type: type, elements: elements, position: position)
    }

    /// The type `expression` names, when it is written where a value could
    /// stand and names one: `T`, `*T`, and `pkg.T`, where no variable has
    /// the name. A type that is written out is a type already.
    private func writtenType(_ expression: GoExpression) -> GoTypeExpression? {
        func isValue(_ name: String) -> Bool { local(name) != nil || values.contains(name) }
        switch expression {
        case .identifier(let name, let position):
            guard !isValue(name), types[name] != nil || GoCompositeLiterals.isPredeclaredType(name)
            else { return nil }
            return .named(name, position: position)
        case .unary(.dereference, let operand, let position):
            return writtenType(operand).map { .pointer(pointee: $0, position: position) }
        case .selector(.identifier(let qualifier, let position), let name, _):
            // What is selected from no variable is a member of a package.
            guard !isValue(qualifier), types[qualifier] == nil else { return nil }
            return .named(qualifier + "." + name, position: position)
        default:
            return nil
        }
    }

    // MARK: Constants

    private func local(_ name: String) -> Local? {
        for scope in scopes.reversed() {
            if let local = scope[name] { return local }
        }
        return nil
    }

    /// The value of the integer constant expression `expression`, or nil
    /// when it is none that can be told here.
    private func constant(_ expression: GoExpression, depth: Int = 0) -> Int64? {
        // A constant that is declared by itself has no value.
        guard depth < 64 else { return nil }
        switch expression {
        case .integer(let value, _):
            return value
        case .identifier(let name, _):
            // A rune literal is carried as it is spelled.
            if let rune = GoLiteral.runeValue(name) { return rune }
            switch local(name) {
            case .constant(let value)?: return constant(value, depth: depth + 1)
            case .variable?: return nil
            case nil: return constants[name].flatMap { constant($0, depth: depth + 1) }
            }
        case .selector(.identifier(let package, _), let member, _):
            // A constant of the run-time library: `time.Second`, `os.O_RDWR`.
            guard local(package) == nil, !values.contains(package) else { return nil }
            return GoStandardLibrary.integerConstant(package: package, member: member)
        case .unary(.plus, let operand, _):
            return constant(operand, depth: depth + 1)
        case .unary(.minus, let operand, _):
            guard let value = constant(operand, depth: depth + 1), value != .min else { return nil }
            return -value
        case .binary(let left, let binaryOperator, let right, _):
            guard let lhs = constant(left, depth: depth + 1),
                let rhs = constant(right, depth: depth + 1)
            else { return nil }
            let folded: (partialValue: Int64, overflow: Bool)
            switch binaryOperator {
            case .add: folded = lhs.addingReportingOverflow(rhs)
            case .subtract: folded = lhs.subtractingReportingOverflow(rhs)
            case .multiply: folded = lhs.multipliedReportingOverflow(by: rhs)
            case .divide:
                guard rhs != 0 else { return nil }
                folded = lhs.dividedReportingOverflow(by: rhs)
            case .remainder:
                guard rhs != 0 else { return nil }
                folded = lhs.remainderReportingOverflow(dividingBy: rhs)
            default: return nil
            }
            return folded.overflow ? nil : folded.partialValue
        case .call(let callee, let arguments, _):
            if let operation = expression.bitwiseOperation {
                guard let first = constant(operation.operands[0], depth: depth + 1) else {
                    return nil
                }
                if operation.operator == .complement { return ~first }
                guard let second = constant(operation.operands[1], depth: depth + 1) else {
                    return nil
                }
                return operation.operator.fold(first, second)
            }
            // `int(k)` and `Color(2)`: a constant converted to an integer
            // type is the same number.
            guard arguments.count == 1, case .identifier(let name, _) = callee, local(name) == nil,
                name == "int" || name == "byte" || name == "uint8" || types[name] != nil
            else { return nil }
            return constant(arguments[0], depth: depth + 1)
        default:
            return nil
        }
    }

    // MARK: Literals

    private mutating func literal(
        type: GoTypeExpression, elements: [GoCompositeElement], position: GoSourcePosition
    ) -> GoExpression {
        var type = type
        var resolved: [GoCompositeElement] = []
        resolved.reserveCapacity(elements.count)
        switch type.isElided ? Shape.other : shape(of: type) {
        case .list(let elementType):
            // The index of an element is that of the one before it and one
            // more, or the one it is written with.
            var next = 0
            var length = 0
            for element in elements {
                var index = element.keyExpression
                if let written = index {
                    if let value = constant(written) {
                        index = .integer(value, position: written.position)
                        next = Int(exactly: value) ?? next
                    } else {
                        index = rewrite(written)
                    }
                }
                next += 1
                length = max(length, next)
                resolved.append(
                    GoCompositeElement(
                        keyExpression: index, value: rewrite(typed(element.value, as: elementType)),
                        position: element.position))
            }
            if case .array(GoCompositeLiterals.openLength, let element, let typePosition) = type {
                type = .array(length: length, element: element, position: typePosition)
            }
        case .map(let keyType, let valueType):
            for element in elements {
                resolved.append(
                    GoCompositeElement(
                        keyExpression: element.keyExpression.map { rewrite(typed($0, as: keyType)) },
                        value: rewrite(typed(element.value, as: valueType)),
                        position: element.position))
            }
        case .other:
            // A struct: a key that is a name is the name of a field.
            for element in elements {
                resolved.append(
                    GoCompositeElement(
                        key: element.key,
                        keyExpression: element.key == nil
                            ? element.keyExpression.map { rewrite($0) } : nil,
                        value: rewrite(element.value),
                        position: element.position))
            }
        }
        return .compositeLiteral(type: type, elements: resolved, position: position)
    }

    // MARK: Declarations

    private mutating func declare(_ name: String?, as local: Local = .variable) {
        guard let name, !scopes.isEmpty else { return }
        scopes[scopes.count - 1][name] = local
    }

    mutating func rewrite(_ function: GoFunctionDeclaration) -> GoFunctionDeclaration {
        scopes.append([:])
        defer { scopes.removeLast() }
        declare(function.receiver?.name)
        for parameter in function.parameters { declare(parameter.name) }
        for name in function.resultNames { declare(name) }
        return GoFunctionDeclaration(
            name: function.name,
            receiver: function.receiver,
            parameters: function.parameters,
            resultNames: function.resultNames,
            resultTypes: function.resultTypes,
            body: rewrite(function.body),
            position: function.position)
    }

    // MARK: Statements

    private mutating func rewrite(_ block: GoBlock) -> GoBlock {
        scopes.append([:])
        defer { scopes.removeLast() }
        return GoBlock(statements: block.statements.map { rewrite($0) }, position: block.position)
    }

    private mutating func rewrite(_ statement: GoStatement) -> GoStatement {
        switch statement {
        case .declaration(let name, let explicitType, let expression, let isConstant, let position):
            let value = expression.map { rewrite($0) }
            if isConstant, let expression {
                declare(name, as: .constant(expression))
            } else {
                declare(name)
            }
            return .declaration(
                name: name, explicitType: explicitType, expression: value, isConstant: isConstant,
                position: position)
        case .multiDeclaration(let names, let expression, let position):
            let value = rewrite(expression)
            if let variables = expression.variables, variables.isConstant,
                variables.values.count == names.count
            {
                for (name, constant) in zip(names, variables.values) {
                    declare(name, as: .constant(constant))
                }
            } else {
                for name in names { declare(name) }
            }
            return .multiDeclaration(names: names, expression: value, position: position)
        case .assignment(let target, let expression, let position):
            return .assignment(
                target: rewrite(target), expression: rewrite(expression), position: position)
        case .multiAssignment(let targets, let expression, let position):
            return .multiAssignment(
                targets: targets.map { rewrite($0) }, expression: rewrite(expression),
                position: position)
        case .increment(let target, let incrementOperator, let position):
            return .increment(target: rewrite(target), operator: incrementOperator, position: position)
        case .expression(let expression):
            return .expression(rewrite(expression))
        case .returnValues(let values, let position):
            return .returnValues(values.map { rewrite($0) }, position: position)
        case .breakStatement, .continueStatement:
            return statement
        case .deferStatement(let expression, let position):
            return .deferStatement(expression: rewrite(expression), position: position)
        case .goStatement(let expression, let position):
            return .goStatement(expression: rewrite(expression), position: position)
        case .sendStatement(let channel, let value, let position):
            return .sendStatement(channel: rewrite(channel), value: rewrite(value), position: position)
        case .ifStatement(let condition, let thenBlock, let elseBlock, let position):
            return .ifStatement(
                condition: rewrite(condition), thenBlock: rewrite(thenBlock),
                elseBlock: elseBlock.map { rewrite($0) }, position: position)
        case .forStatement(let initializer, let condition, let post, let body, let position):
            // Also a block, and an `if` or `switch` with an initializer.
            scopes.append([:])
            defer { scopes.removeLast() }
            return .forStatement(
                initializer: initializer.map { rewrite($0) },
                condition: condition.map { rewrite($0) },
                post: post.map { rewrite($0) },
                body: rewrite(body),
                position: position)
        case .forRangeStatement(let indexName, let valueName, let collection, let body, let position):
            let ranged = rewrite(collection)
            scopes.append([:])
            defer { scopes.removeLast() }
            declare(indexName)
            declare(valueName)
            return .forRangeStatement(
                indexName: indexName, valueName: valueName, collection: ranged, body: rewrite(body),
                position: position)
        case .switchStatement(let expression, let cases, let position):
            return .switchStatement(
                expression: expression.map { rewrite($0) },
                cases: cases.map { switchCase in
                    GoSwitchCase(
                        expressions: switchCase.expressions.map { rewrite($0) },
                        body: rewrite(switchCase.body),
                        isDefault: switchCase.isDefault,
                        position: switchCase.position)
                },
                position: position)
        case .selectStatement(let cases, let position):
            return .selectStatement(
                cases: cases.map { selectCase in
                    scopes.append([:])
                    defer { scopes.removeLast() }
                    return GoSelectCase(
                        communication: selectCase.communication.map { rewrite($0) },
                        body: rewrite(selectCase.body),
                        position: selectCase.position)
                },
                position: position)
        }
    }

    // MARK: Expressions

    mutating func rewrite(_ expression: GoExpression) -> GoExpression {
        switch expression {
        case .integer, .string, .identifier, .typeExpression:
            return expression
        case .compositeLiteral(let type, let elements, let position):
            return literal(type: type, elements: elements, position: position)
        case .selector(let base, let name, let position):
            return .selector(base: rewrite(base), name: name, position: position)
        case .index(let base, let index, let position):
            return .index(base: rewrite(base), index: rewrite(index), position: position)
        case .slicing(let base, let low, let high, let position):
            return .slicing(
                base: rewrite(base), low: low.map { rewrite($0) }, high: high.map { rewrite($0) },
                position: position)
        case .call(let callee, let arguments, let position):
            var operands = arguments.map { rewrite($0) }
            // `new(T)` and `make(T, n)` take a type, which a name is one way
            // to write.
            if case .identifier(let name, _) = callee, GoCompositeLiterals.takesType(name),
                local(name) == nil, !values.contains(name), types[name] == nil,
                let first = arguments.first, let type = writtenType(first)
            {
                operands[0] = .typeExpression(type, position: first.position)
            }
            return .call(callee: rewrite(callee), arguments: operands, position: position)
        case .typeAssertion(let base, let type, let position):
            return .typeAssertion(base: rewrite(base), type: type, position: position)
        case .functionLiteral(let parameters, let resultNames, let resultTypes, let body, let position):
            scopes.append([:])
            defer { scopes.removeLast() }
            for parameter in parameters { declare(parameter.name) }
            for name in resultNames { declare(name) }
            return .functionLiteral(
                parameters: parameters, resultNames: resultNames, resultTypes: resultTypes,
                body: rewrite(body), position: position)
        case .unary(let unaryOperator, let operand, let position):
            return .unary(operator: unaryOperator, operand: rewrite(operand), position: position)
        case .binary(let left, let binaryOperator, let right, let position):
            return .binary(
                left: rewrite(left), operator: binaryOperator, right: rewrite(right),
                position: position)
        }
    }
}
