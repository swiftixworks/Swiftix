/// Bitwise integer operators and their encoding in the existing token and AST shapes.
///
/// The public token, AST, and IR enums are frozen, so these operators add no
/// cases. The lexer emits each operator as an `.identifier` token carrying its
/// spelling (no Go identifier can be spelled that way; `&` keeps its own
/// token), and the parser represents `a | b` as a `.call` whose callee is an
/// identifier with the reserved native name `$bits.or`. The type checker,
/// compiler, formatter, and rewriter decode that shape through
/// `GoExpression.bitwiseOperation`; the VM executes the same name natively.
///
/// The spread `values...` of an `append` argument is encoded the same way; see
/// `GoSpread`.
///
/// Compound assignment (`x += y`, `x <<= y`, ...) uses the same token trick:
/// the lexer emits the operator as an `.identifier` token carrying its
/// spelling and the parser rewrites the statement to `x = x op y`, reusing the
/// target node as the left operand so both share one source position.
/// Pure value types; no executor state.

enum GoBitwiseOperator: Sendable, Equatable, CaseIterable {
    case and
    case or
    case xor
    case andNot
    case shiftLeft
    case shiftRight
    /// Unary `^x`.
    case complement

    /// The Go source spelling. Unary complement shares `^` with binary xor.
    var spelling: String {
        switch self {
        case .and: return "&"
        case .or: return "|"
        case .xor, .complement: return "^"
        case .andNot: return "&^"
        case .shiftLeft: return "<<"
        case .shiftRight: return ">>"
        }
    }

    /// Reserved callee and VM call name.
    var nativeName: String {
        switch self {
        case .and: return "$bits.and"
        case .or: return "$bits.or"
        case .xor: return "$bits.xor"
        case .andNot: return "$bits.andNot"
        case .shiftLeft: return "$bits.shl"
        case .shiftRight: return "$bits.shr"
        case .complement: return "$bits.not"
        }
    }

    var isUnary: Bool { self == .complement }
    var isShift: Bool { self == .shiftLeft || self == .shiftRight }

    /// Binary precedence on the parser's scale, where `+` is 5 and `*` is 6.
    var precedence: Int {
        switch self {
        case .or, .xor: return 5
        case .and, .andNot, .shiftLeft, .shiftRight: return 6
        case .complement: return 7
        }
    }

    init?(nativeName: String) {
        guard let match = Self.allCases.first(where: { $0.nativeName == nativeName }) else {
            return nil
        }
        self = match
    }

    /// The binary operator a lexer identifier spelling denotes.
    static func binary(spelling: String) -> GoBitwiseOperator? {
        allCases.first { !$0.isUnary && $0.spelling == spelling }
    }

    /// Whether an `.identifier` token holds an operator instead of a name.
    static func isOperatorSpelling(_ text: String) -> Bool {
        text == "|" || text == "^" || text == "&^" || text == "<<" || text == ">>"
            || text == GoSpread.spelling
            || GoCompoundAssignment(spelling: text) != nil
    }

    /// Constant-folds two operands with the VM's semantics. Returns nil for a
    /// shift count that is negative or does not fit the folded 64-bit value.
    func fold(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        switch self {
        case .and: return lhs & rhs
        case .or: return lhs | rhs
        case .xor: return lhs ^ rhs
        case .andNot: return lhs & ~rhs
        case .shiftLeft:
            guard rhs >= 0, rhs < 64 else { return nil }
            let shifted = lhs << rhs
            return shifted >> rhs == lhs ? shifted : nil
        case .shiftRight:
            guard rhs >= 0 else { return nil }
            return rhs >= 64 ? (lhs < 0 ? -1 : 0) : lhs >> rhs
        case .complement:
            return nil
        }
    }
}

extension GoExpression {
    /// Builds the call-shaped node for a bitwise operator application.
    /// `position` is the operator's position, as for `.binary` and `.unary`.
    static func bitwise(
        _ bitwiseOperator: GoBitwiseOperator,
        operands: [GoExpression],
        position: GoSourcePosition
    ) -> GoExpression {
        .call(
            callee: .identifier(bitwiseOperator.nativeName, position: position),
            arguments: operands,
            position: position)
    }

    /// The operator and operands when this node encodes a bitwise operation.
    var bitwiseOperation: (operator: GoBitwiseOperator, operands: [GoExpression])? {
        guard case .call(.identifier(let name, _), let arguments, _) = self,
            name.first == "$",
            let bitwiseOperator = GoBitwiseOperator(nativeName: name),
            arguments.count == (bitwiseOperator.isUnary ? 1 : 2)
        else { return nil }
        return (bitwiseOperator, arguments)
    }
}

/// The `...` that spreads a slice over the final argument of `append`, in the
/// existing token and AST shapes like the operators above: the lexer emits it
/// as an `.identifier` token carrying its spelling, and the parser represents
/// `values...` as a `.call` whose callee is the reserved identifier `$spread`.
/// The node's position is the `...`, which follows its operand.
///
/// A variadic parameter `values ...T` uses the same token. Its type is kept
/// as an array type of length `variadicLength`, which no source array has:
/// a signature holds that marker, and inside its function the parameter is a
/// `[]T`.
enum GoSpread {
    static let spelling = "..."
    static let calleeName = "$spread"
    static let variadicLength = -1
}

extension GoType {
    /// The element type when this is the marker type of a variadic parameter.
    var variadicElement: GoType? {
        if case .array(let length, let element) = self, length == GoSpread.variadicLength {
            return element
        }
        return nil
    }

    /// The type a parameter of this declared type has inside its function.
    var parameterType: GoType {
        variadicElement.map { .slice($0) } ?? self
    }
}

extension GoExpression {
    /// Builds the call-shaped node for `operand...`.
    static func spread(_ operand: GoExpression, position: GoSourcePosition) -> GoExpression {
        .call(
            callee: .identifier(GoSpread.calleeName, position: position),
            arguments: [operand],
            position: position)
    }

    /// The operand when this node encodes `operand...`.
    var spreadOperand: GoExpression? {
        guard case .call(.identifier(GoSpread.calleeName, _), let arguments, _) = self,
            arguments.count == 1
        else { return nil }
        return arguments[0]
    }
}

/// A compound assignment operator: the binary operation applied before the
/// store in `target op= value`.
enum GoCompoundAssignment: Sendable, Equatable {
    case arithmetic(GoBinaryOperator)
    case bitwise(GoBitwiseOperator)

    /// Every spelling, longest first so a scanner can match greedily.
    static let spellings = [
        "<<=", ">>=", "&^=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=",
    ]

    init?(spelling: String) {
        switch spelling {
        case "+=": self = .arithmetic(.add)
        case "-=": self = .arithmetic(.subtract)
        case "*=": self = .arithmetic(.multiply)
        case "/=": self = .arithmetic(.divide)
        case "%=": self = .arithmetic(.remainder)
        case "&=": self = .bitwise(.and)
        case "|=": self = .bitwise(.or)
        case "^=": self = .bitwise(.xor)
        case "&^=": self = .bitwise(.andNot)
        case "<<=": self = .bitwise(.shiftLeft)
        case ">>=": self = .bitwise(.shiftRight)
        default: return nil
        }
    }

    /// The expression `target op value`, positioned at the operator.
    func apply(
        to target: GoExpression,
        _ value: GoExpression,
        position: GoSourcePosition
    ) -> GoExpression {
        switch self {
        case .arithmetic(let binaryOperator):
            return .binary(left: target, operator: binaryOperator, right: value, position: position)
        case .bitwise(let bitwiseOperator):
            return .bitwise(bitwiseOperator, operands: [target, value], position: position)
        }
    }
}

extension GoExpression {
    /// Whether evaluating the expression twice is indistinguishable from
    /// evaluating it once: it contains no call and no channel receive.
    var isRepeatable: Bool {
        switch self {
        case .integer, .string, .identifier, .typeExpression:
            return true
        case .selector(let base, _, _):
            return base.isRepeatable
        case .index(let base, let index, _):
            return base.isRepeatable && index.isRepeatable
        case .slicing(let base, let low, let high, _):
            return base.isRepeatable && (low?.isRepeatable ?? true) && (high?.isRepeatable ?? true)
        case .unary(let unaryOperator, let operand, _):
            return unaryOperator != .receive && operand.isRepeatable
        case .binary(let left, _, let right, _):
            return left.isRepeatable && right.isRepeatable
        case .call:
            guard let operation = bitwiseOperation else { return false }
            return operation.operands.allSatisfy(\.isRepeatable)
        case .compositeLiteral, .typeAssertion, .functionLiteral:
            return false
        }
    }
}

/// `if x := f(); x > 0 { }` and `switch x := f(); x { }`: a statement with an
/// initializer whose variables last for that statement only.
///
/// `GoStatement` is frozen and neither statement has room for an initializer,
/// so the pair is carried by the statement that already scopes one: a `for`
/// whose post statement is a `break`, which no source `for` can have, and
/// whose body is the statement alone. Read as a loop it runs the statement
/// once, so a pass that only walks the tree needs no case for it; the passes
/// that give `break` and `continue` a meaning ask `initialized` first,
/// because the statement is not a loop to them.
extension GoStatement {
    static func initialized(
        _ statement: GoStatement,
        by initializer: GoStatement,
        position: GoSourcePosition
    ) -> GoStatement {
        .forStatement(
            initializer: initializer,
            condition: nil,
            post: .breakStatement(position: position),
            body: GoBlock(statements: [statement], position: position),
            position: position)
    }

    /// The initializer and the statement it belongs to, when this is one.
    var initialized: (initializer: GoStatement, statement: GoStatement)? {
        guard case .forStatement(let initializer?, nil, .breakStatement?, let body, _) = self,
            body.statements.count == 1
        else { return nil }
        return (initializer, body.statements[0])
    }
}

/// Several values where a frozen statement holds one expression.
///
/// `a, b := x, y` and `a, b = y, x` carry their right side as a call to
/// `calleeName` with the values as arguments. `var a, b T = x, y` is a
/// declaration of several names whose expression is a call to
/// `variablesName`: the type first, when one is written, then the values,
/// of which there may be none. No Go identifier starts with `$`, so neither
/// meets a function of the program.
enum GoValueList {
    static let calleeName = "$list"
    static let variablesName = "$var"
    /// `const a, b = x, y`, written like `variablesName`.
    static let constantsName = "$const"
    /// The name of nothing: `_ = x` evaluates `x` and keeps no value.
    static let blank = "_"
}

extension GoExpression {
    static func valueList(_ values: [GoExpression], position: GoSourcePosition) -> GoExpression {
        .call(
            callee: .identifier(GoValueList.calleeName, position: position),
            arguments: values, position: position)
    }

    /// The values of a parallel `:=` or `=`, when this is their list.
    var valueList: [GoExpression]? {
        guard case .call(.identifier(GoValueList.calleeName, _), let values, _) = self else {
            return nil
        }
        return values
    }

    static func variables(
        type: GoTypeExpression?,
        values: [GoExpression],
        isConstant: Bool = false,
        position: GoSourcePosition
    ) -> GoExpression {
        .call(
            callee: .identifier(
                isConstant ? GoValueList.constantsName : GoValueList.variablesName,
                position: position),
            arguments: (type.map { [.typeExpression($0, position: $0.position)] } ?? []) + values,
            position: position)
    }

    /// The type and the values of a `var` or `const` with several names,
    /// when this is one. A value is never a type, so a leading type is the
    /// declared one.
    var variables: (type: GoTypeExpression?, values: [GoExpression], isConstant: Bool)? {
        guard case .call(.identifier(let name, _), let arguments, _) = self,
            name == GoValueList.variablesName || name == GoValueList.constantsName
        else { return nil }
        let isConstant = name == GoValueList.constantsName
        if case .typeExpression(let type, _)? = arguments.first {
            return (type, Array(arguments.dropFirst()), isConstant)
        }
        return (nil, arguments, isConstant)
    }

    /// Whether this is the blank identifier.
    var isBlank: Bool {
        if case .identifier(GoValueList.blank, _) = self { return true }
        return false
    }
}
