/// Constants that are strings and truth values, and the named types they
/// take.
///
/// An untyped constant of Go has no type until it is used: `"GET"` is a
/// `Method` where a `Method` is wanted, and `true` a `Flag`. So is the
/// result of a comparison, which is an untyped boolean whether or not its
/// operands are constants. A string or a truth value is the same VM value
/// under any of its types, so nothing is lowered differently: the checker
/// allows the use, and tells the lowerer the type of an operator whose
/// operands do not show it (`"x" + s`).

/// A constant that is a string or a truth value.
struct GoWordConstant: Equatable, Sendable {
    /// The text of a string constant; nil for a truth value.
    var text: String?
    /// The constant's type; nil while it is untyped.
    var type: GoType?
}

extension FunctionChecker {
    /// The string constant `expression` is, typed or untyped, or nil when
    /// it is none: a literal, a constant, a conversion of one, and `+` of
    /// two. Two typed operands of different types make none; the rule for
    /// operand types reports them.
    func stringConstant(of expression: GoExpression) -> GoWordConstant? {
        switch expression {
        case .string(let value, _):
            return GoWordConstant(text: value, type: nil)
        case .identifier(let name, _):
            guard let word = lookup(name)?.word, word.text != nil else { return nil }
            return word
        case .binary(let left, .add, let right, _):
            // The right operand first, as the numbers are folded: it is the
            // leaf of a chain.
            guard let rhs = stringConstant(of: right), let lhs = stringConstant(of: left),
                let head = lhs.text, let tail = rhs.text
            else { return nil }
            if let leftType = lhs.type, let rightType = rhs.type, leftType != rightType {
                return nil
            }
            return GoWordConstant(text: head + tail, type: lhs.type ?? rhs.type)
        case .call(let callee, let arguments, _):
            guard arguments.count == 1, expression.bitwiseOperation == nil,
                let target = try? conversionTarget(callee), underlying(target) == .string,
                let operand = stringConstant(of: arguments[0])
            else { return nil }
            return GoWordConstant(text: operand.text, type: target)
        default:
            return nil
        }
    }

    /// Whether `expression` is an untyped boolean: `true` or `false`, a
    /// comparison, an untyped boolean constant, or `!`, `&&`, and `||` of
    /// those.
    func isUntypedBoolean(_ expression: GoExpression) -> Bool {
        switch expression {
        case .identifier(let name, _):
            guard let binding = lookup(name) else { return name == "true" || name == "false" }
            guard let word = binding.word else { return false }
            return word.text == nil && word.type == nil
        case .unary(.not, let operand, _):
            return isUntypedBoolean(operand)
        case .binary(let left, let binaryOperator, let right, _):
            switch binaryOperator {
            case .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual: return true
            case .logicalAnd, .logicalOr: return isUntypedBoolean(right) && isUntypedBoolean(left)
            default: return false
            }
        default:
            return false
        }
    }

    /// Whether a type takes an untyped constant that is a value of it: a
    /// number, a string, or a truth value, under any name.
    func adoptsConstants(_ type: GoType) -> Bool {
        isNumeric(type) || underlying(type) == .string || underlying(type) == .bool
    }

    /// Whether `expression`, of type `actual`, may be used where `expected`
    /// is wanted because it is an untyped string or boolean that takes the
    /// type; nil when that is not the question.
    func wordAssignable(
        _ expression: GoExpression, ofType actual: GoType, to expected: GoType
    ) -> Bool? {
        guard actual != expected else { return nil }
        if actual == .string, underlying(expected) == .string,
            let constant = stringConstant(of: expression), constant.type == nil
        {
            return true
        }
        if actual == .bool, underlying(expected) == .bool, isUntypedBoolean(expression) {
            return true
        }
        return nil
    }

    /// The types of the operands of a binary operator on strings or truth
    /// values once an untyped one has taken the type of the other. Where
    /// the result has a type its left operand does not show, the lowerer is
    /// told it.
    func wordOperandTypes(
        _ expression: GoExpression, _ left: GoExpression, _ right: GoExpression,
        _ leftType: GoType, _ rightType: GoType
    ) -> (left: GoType, right: GoType) {
        guard leftType != rightType else { return (leftType, rightType) }
        if wordAssignable(right, ofType: rightType, to: leftType) == true {
            return (leftType, leftType)
        }
        if wordAssignable(left, ofType: leftType, to: rightType) == true {
            if case .binary(_, let binaryOperator, _, _) = expression {
                switch binaryOperator {
                case .add, .logicalAnd, .logicalOr:
                    ledger?.facts.setDefault(
                        GoNumberFact(type: rightType, bits: nil), for: expression)
                default:
                    break
                }
            }
            return (rightType, rightType)
        }
        return (leftType, rightType)
    }

    /// The string or boolean constant a `const` of type `type` declares
    /// with `expression`, or nil when it declares neither. `isTyped` is
    /// whether the declaration writes the type.
    func wordConstant(
        declaredAs type: GoType, isTyped: Bool, _ expression: GoExpression
    ) -> GoWordConstant? {
        if underlying(type) == .string, let constant = stringConstant(of: expression) {
            return GoWordConstant(text: constant.text, type: isTyped ? type : constant.type)
        }
        if underlying(type) == .bool {
            let untyped = !isTyped && isUntypedBoolean(expression)
            return GoWordConstant(text: nil, type: untyped ? nil : type)
        }
        return nil
    }
}
