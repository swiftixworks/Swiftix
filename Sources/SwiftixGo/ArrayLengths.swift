/// Array lengths that are constant expressions: `[n]T`, `[2 * n]T`,
/// `[len("abc")]T`.
///
/// `GoTypeExpression.array` is frozen and holds its length as a number, and
/// no type expression holds an expression. The parser therefore writes
/// `[expr]T` as an interface with one method that no source can declare,
/// `$array.<offset>`, whose result is `T`, so every pass rewrites the element
/// type like any other; the expression itself is kept beside the tree, by
/// that offset, with the initializer of every constant a function declares
/// (`GoArrayLengthNotes`).
///
/// The lengths are settled first of all the passes over a package, while
/// every name is still the one the source wrote: the tree is walked in the
/// order Go brings names into scope, a constant is folded where it is
/// declared, a variable or parameter of the same name hides it, and each
/// marker becomes the array it stands for. What comes after sees arrays with
/// numbers, as it always did.
///
/// A length may name the constants of its own package and of the functions
/// around it. One that names a constant of another package is refused: the
/// expression is not part of the tree the linker rewrites.

/// What the parser keeps beside the tree for the lengths of arrays.
struct GoArrayLengthNotes: Sendable, Equatable {
    /// The length expression of each `[expr]T`, by the offset of its `[`.
    var lengths: [Int: GoExpression] = [:]
    /// The initializer of each constant a function declares, by the offset
    /// of its declaration and its name.
    var constants: [Int: [String: GoExpression]] = [:]

    var isEmpty: Bool { lengths.isEmpty }
}

enum GoArrayLengths {
    static let methodPrefix = "$array."

    /// The type `[expr]element` as the parser writes it.
    static func marker(element: GoTypeExpression, position: GoSourcePosition) -> GoTypeExpression {
        .interface(
            methods: [
                GoInterfaceMethodDeclaration(
                    name: methodPrefix + String(position.offset), results: [element],
                    position: position)
            ],
            position: position)
    }

    /// The files of one package with every such array given its length.
    static func resolve(_ files: [GoFile]) throws -> [GoFile] {
        guard files.contains(where: { !$0.arrayLengths.isEmpty }) else { return files }
        // The constants of the package, by the name the source gives them:
        // a linked package spells its own as `path.name`.
        var globals: [String: GoExpression] = [:]
        for declaration in files.lazy.flatMap(\.globalDeclarations) where declaration.isConstant {
            guard let expression = declaration.expression else { continue }
            let name = declaration.name
            globals[name.lastIndex(of: ".").map { String(name[name.index(after: $0)...]) } ?? name] =
                expression
        }
        return try files.map { file in
            guard !file.arrayLengths.isEmpty else { return file }
            var resolver = Resolver(notes: file.arrayLengths, globals: globals)
            let types = try file.typeDeclarations.map { declaration in
                GoTypeDeclaration(
                    name: declaration.name, type: try resolver.rewrite(declaration.type),
                    isAlias: declaration.isAlias, position: declaration.position)
            }
            let variables = try file.globalDeclarations.map { declaration in
                GoGlobalDeclaration(
                    name: declaration.name,
                    explicitType: try declaration.explicitType.map { try resolver.rewrite($0) },
                    expression: try declaration.expression.map { try resolver.rewrite($0) },
                    isConstant: declaration.isConstant, position: declaration.position)
            }
            let functions = try file.functions.map { try resolver.rewrite($0) }
            var rebuilt = file.rebuilt(
                imports: file.imports, typeDeclarations: types, globalDeclarations: variables,
                functions: functions)
            rebuilt.arrayLengths = GoArrayLengthNotes()
            return rebuilt
        }
    }

    private struct Resolver: GoScopedRewriter {
        let notes: GoArrayLengthNotes
        let globals: [String: GoExpression]
        /// What each name of the open scopes is: a constant with its value,
        /// or nil for anything else, which hides a constant of that name.
        var scopes: [[String: GoBigInt?]] = []
        /// The package-level constants being folded, to stop at a cycle.
        var folding: Set<String> = []

        mutating func openScope() { scopes.append([:]) }
        mutating func closeScope() { scopes.removeLast() }

        mutating func declare(_ name: String, at position: GoSourcePosition) -> String {
            guard !scopes.isEmpty else { return name }
            let value = notes.constants[position.offset]?[name].flatMap { integer($0) }
            scopes[scopes.count - 1][name] = .some(value)
            return name
        }

        func value(named name: String, at position: GoSourcePosition) -> GoExpression {
            .identifier(name, position: position)
        }

        func type(named name: String, at position: GoSourcePosition) -> GoTypeExpression {
            .named(name, position: position)
        }

        func member(
            _ member: String, of qualifier: String,
            qualifierPosition: GoSourcePosition, position: GoSourcePosition
        ) -> GoExpression? { nil }

        mutating func localType(_ declaration: GoTypeDeclaration) throws -> [GoStatement] {
            [
                .localType(
                    name: declaration.name, type: try rewrite(declaration.type),
                    isAlias: declaration.isAlias, position: declaration.position)
            ]
        }

        mutating func interface(
            _ methods: [GoInterfaceMethodDeclaration], at position: GoSourcePosition
        ) throws -> GoTypeExpression {
            guard methods.count == 1, methods[0].name.hasPrefix(GoArrayLengths.methodPrefix),
                let element = methods[0].results.first,
                let expression = notes.lengths[position.offset]
            else { return .interface(methods: methods, position: position) }
            let spelling = expression.sourceSpelling
            guard let length = integer(expression) else {
                throw GoDiagnostic(
                    position: expression.startPosition, message: "invalid array length \(spelling)")
            }
            guard !length.isNegative, let count = length.int64, let exact = Int(exactly: count)
            else {
                // Go says what the length is: a literal is its own value.
                var isLiteral = false
                if case .unary(.minus, .integer, _) = expression { isLiteral = true }
                throw GoDiagnostic(
                    position: expression.startPosition,
                    message: "invalid array length \(spelling) (untyped int constant"
                        + (isLiteral ? ")" : " \(length))"))
            }
            return .array(length: exact, element: element, position: position)
        }

        /// The value of `name` where the walk stands: a constant of an open
        /// scope, or else of the package.
        mutating func constant(named name: String) -> GoBigInt? {
            for scope in scopes.reversed() {
                if let found = scope[name] { return found }
            }
            guard let expression = globals[name], folding.insert(name).inserted else { return nil }
            defer { folding.remove(name) }
            // A constant of the package is folded in the scope of the
            // package, where no function's names are.
            let open = scopes
            scopes = []
            defer { scopes = open }
            return integer(expression)
        }

        /// The text of a string constant: a literal, a named constant, and
        /// `+` of two.
        mutating func text(_ expression: GoExpression) -> String? {
            switch expression {
            case .string(let value, _): return value
            case .identifier(let name, _):
                for scope in scopes.reversed() where scope[name] != nil { return nil }
                guard let value = globals[name], folding.insert(name).inserted else { return nil }
                defer { folding.remove(name) }
                return text(value)
            case .binary(let left, .add, let right, _):
                guard let tail = text(right), let head = text(left) else { return nil }
                return head + tail
            default: return nil
            }
        }

        /// The value of an integer constant expression, or nil when
        /// `expression` is none that can be folded here.
        mutating func integer(_ expression: GoExpression) -> GoBigInt? {
            switch expression {
            case .integer(let value, _):
                return GoBigInt(value)
            case .identifier(let name, _):
                if let rune = GoLiteral.runeValue(name) { return GoBigInt(rune) }
                if GoLiteral.isSpelling(name) {
                    guard let literal = GoNumberLiteral.value(of: name), literal.value.isInteger
                    else { return nil }
                    return literal.value.truncated
                }
                return constant(named: name)
            case .selector(.identifier(let package, _), let member, _):
                guard let value = GoNumberLibrary.constant(package: package, member: member)?.value,
                    value.isInteger
                else { return nil }
                return value.truncated
            case .unary(.plus, let operand, _):
                return integer(operand)
            case .unary(.minus, let operand, _):
                return integer(operand).map { -$0 }
            case .binary(let left, let binaryOperator, let right, _):
                guard let rhs = integer(right), let lhs = integer(left) else { return nil }
                switch binaryOperator {
                case .add: return lhs + rhs
                case .subtract: return lhs - rhs
                case .multiply: return lhs * rhs
                case .divide: return lhs.quotientAndRemainder(dividingBy: rhs)?.quotient
                case .remainder: return lhs.quotientAndRemainder(dividingBy: rhs)?.remainder
                default: return nil
                }
            case .call(let callee, let arguments, _):
                return call(expression, callee, arguments)
            default:
                return nil
            }
        }

        private mutating func call(
            _ expression: GoExpression, _ callee: GoExpression, _ arguments: [GoExpression]
        ) -> GoBigInt? {
            if let operation = expression.bitwiseOperation {
                guard let lhs = integer(operation.operands[0]) else { return nil }
                if operation.operator == .complement { return ~lhs }
                guard let rhs = integer(operation.operands[1]) else { return nil }
                switch operation.operator {
                case .and: return lhs & rhs
                case .or: return lhs | rhs
                case .xor: return lhs ^ rhs
                case .andNot: return lhs.andNot(rhs)
                case .shiftLeft, .shiftRight:
                    guard let count = rhs.int64, (0...4096).contains(count) else { return nil }
                    return operation.operator == .shiftLeft
                        ? lhs.shiftedLeft(Int(count)) : lhs.shiftedRight(Int(count))
                case .complement: return nil
                }
            }
            guard arguments.count == 1, case .identifier(let name, _) = callee else { return nil }
            for scope in scopes.reversed() where scope[name] != nil { return nil }
            if name == "len" { return text(arguments[0]).map { GoBigInt(Int64($0.utf8.count)) } }
            // A conversion to an integer type keeps the value.
            guard GoNumericKind(typeName: name)?.isInteger == true else { return nil }
            return integer(arguments[0])
        }
    }
}
