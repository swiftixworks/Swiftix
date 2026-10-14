/// Type switches, `switch v := x.(type) { case T: ... }`.
///
/// `GoStatement` has one `switch`, and a type switch is that one. Its
/// expression is the guard `x.(type)`, a type assertion to a type no
/// program can name: `$type`, or `$type.v` when the switch binds `v`, with
/// the type written where `v` is. Each type of a clause is a
/// `.typeExpression`, and `nil` is the type name it reads as.
///
/// A pass that only walks the tree reads a switch on a type assertion, and
/// finds the operand, the types, and the statements where it looks for
/// them. The passes that give names a scope ask `typeSwitch` first: the
/// name a switch binds is declared in each clause, and is no type.
struct GoTypeSwitch {
    /// The name of the type a guard without a binding asserts.
    static let guardName = "$type"
    /// What the name of the type begins with when the guard binds a name,
    /// which follows.
    static let bindingPrefix = "$type."
    /// The case that matches an interface value that holds nothing.
    static let nilName = "nil"
    /// What Go says of a guard that is not the header of a switch.
    static let misplacedGuardMessage = "invalid syntax tree: use of .(type) outside type switch"

    var operand: GoExpression
    /// The name each clause declares, `v` of `v := x.(type)`, and where it
    /// is written.
    var binding: (name: String, position: GoSourcePosition)?
    var cases: [GoSwitchCase]
    /// Where the `.` of the guard is, where its operand begins, and where
    /// the `switch` is.
    let guardPosition: GoSourcePosition
    let operandPosition: GoSourcePosition
    let position: GoSourcePosition

    /// The guard, as the expression of a `switch`.
    var guardExpression: GoExpression {
        .typeAssertion(
            base: operand,
            type: .named(
                binding.map { Self.bindingPrefix + $0.name } ?? Self.guardName,
                position: binding?.position ?? operandPosition),
            position: guardPosition)
    }

    var statement: GoStatement {
        .switchStatement(expression: guardExpression, cases: cases, position: position)
    }
}

extension GoExpression {
    /// `operand.(type)`, the guard of a type switch that binds no name.
    /// The type it is carried by is written where the operand begins:
    /// outside a switch nothing knows that type, and Go reports the guard
    /// there.
    static func typeSwitchGuard(_ operand: GoExpression, position: GoSourcePosition) -> GoExpression {
        .typeAssertion(
            base: operand,
            type: .named(GoTypeSwitch.guardName, position: operand.startPosition),
            position: position)
    }

    /// The operand of the guard of a type switch and the name it binds,
    /// when this is one.
    var typeSwitchGuard: (operand: GoExpression, binding: (name: String, position: GoSourcePosition)?)? {
        guard case .typeAssertion(let operand, .named(let name, let position), _) = self,
            name.first == "$"
        else { return nil }
        if name == GoTypeSwitch.guardName { return (operand, nil) }
        guard name.hasPrefix(GoTypeSwitch.bindingPrefix) else { return nil }
        return (operand, (String(name.dropFirst(GoTypeSwitch.bindingPrefix.count)), position))
    }

    /// Whether this is the guard of a type switch.
    var isTypeSwitchGuard: Bool {
        guard case .typeAssertion(_, .named(let name, _), _) = self else { return false }
        return name == GoTypeSwitch.guardName || name.hasPrefix(GoTypeSwitch.bindingPrefix)
    }

    /// The guard with `name`, written at `position`, for the name it binds.
    func bindingTypeSwitch(_ name: String, at position: GoSourcePosition) -> GoExpression? {
        guard case .typeAssertion(let operand, .named(GoTypeSwitch.guardName, _), let guardPosition) = self
        else { return nil }
        return .typeAssertion(
            base: operand, type: .named(GoTypeSwitch.bindingPrefix + name, position: position),
            position: guardPosition)
    }

    /// Where the expression begins: Go reports an operand there.
    var startPosition: GoSourcePosition {
        switch self {
        case .selector(let base, _, _), .index(let base, _, _), .typeAssertion(let base, _, _):
            // A slice expression is where its `[` is: Go's checker corrects
            // the place of every other node that begins with an operand.
            return base.startPosition
        case .call(let callee, let arguments, let position):
            if let operation = bitwiseOperation {
                return operation.operator.isUnary ? position : operation.operands[0].startPosition
            }
            if let operand = spreadOperand { return operand.startPosition }
            if case .identifier(let name, _) = callee, name.hasPrefix("$") {
                return arguments.first?.startPosition ?? position
            }
            return callee.startPosition
        case .binary(let left, _, _, _):
            return left.startPosition
        default:
            return position
        }
    }
}

extension GoStatement {
    /// Whether this statement is a type switch.
    var isTypeSwitch: Bool {
        guard case .switchStatement(let expression?, _, _) = self else { return false }
        return expression.isTypeSwitchGuard
    }

    /// The type switch this statement is, when it is one.
    var typeSwitch: GoTypeSwitch? {
        guard case .switchStatement(let expression?, let cases, let position) = self,
            case .typeAssertion(_, _, let guardPosition) = expression,
            let typeGuard = expression.typeSwitchGuard
        else { return nil }
        return GoTypeSwitch(
            operand: typeGuard.operand, binding: typeGuard.binding, cases: cases,
            guardPosition: guardPosition, operandPosition: typeGuard.operand.startPosition,
            position: position)
    }
}

extension GoTypeExpression {
    /// Whether this is the `nil` of a type switch clause.
    var isNilCase: Bool {
        if case .named(GoTypeSwitch.nilName, _) = self { return true }
        return false
    }

    /// The type as a program writes it, for a message that names it.
    var spelling: String {
        switch self {
        case .named(let name, _):
            return name
        case .pointer(let pointee, _):
            return "*" + pointee.spelling
        case .array(let length, let element, _):
            return (length == GoSpread.variadicLength ? "..." : "[\(length)]") + element.spelling
        case .slice(let element, _):
            return "[]" + element.spelling
        case .map(let key, let value, _):
            return "map[" + key.spelling + "]" + value.spelling
        case .channel(let direction, let element, _):
            switch direction {
            case .bidirectional: return "chan " + element.spelling
            case .sendOnly: return "chan<- " + element.spelling
            case .receiveOnly: return "<-chan " + element.spelling
            }
        case .structure(let fields, _):
            if fields.isEmpty { return "struct{}" }
            return "struct{ " + fields.map { $0.name + " " + $0.type.spelling }
                .joined(separator: "; ") + " }"
        case .interface(let methods, _):
            func list(_ types: [GoTypeExpression]) -> String {
                types.map(\.spelling).joined(separator: ", ")
            }
            func results(_ types: [GoTypeExpression]) -> String {
                switch types.count {
                case 0: return ""
                case 1: return " " + types[0].spelling
                default: return " (" + list(types) + ")"
                }
            }
            if let signature = functionSignature {
                return "func(" + list(signature.parameters) + ")" + results(signature.results)
            }
            if methods.isEmpty { return "interface{}" }
            return "interface{ "
                + methods.map { $0.name + "(" + list($0.parameters) + ")" + results($0.results) }
                .joined(separator: "; ") + " }"
        }
    }
}
