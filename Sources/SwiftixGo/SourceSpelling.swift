/// An expression or a type as a message names it.
///
/// Go quotes the operand an error is about: `index i must be integer
/// constant`, `invalid field name "X" in struct literal`, `defer discards
/// result of len(s)`. The syntax tree keeps no text, so the operand is
/// written back from its nodes the way Go's checker writes one: a composite
/// literal by its type and `{…}`, a function literal by its header and `{…}`,
/// and either with `{}` when there is nothing between the braces.
/// Where the parser notes the parentheses around an expression among the
/// name positions of its file: the `(` of each pair, innermost first, by
/// the place of the expression. The tree keeps no node for a pair.
enum GoParenthesized {
    static func key(of position: GoSourcePosition) -> Int {
        -2_000_000_000 - position.offset
    }
}

extension GoExpression {
    var sourceSpelling: String { spelled(in: [:]) }

    /// The expression as the source writes it. `parentheses` are the name
    /// positions of its file, which say where a pair of parentheses is;
    /// without them the pairs an operand must have had are written back,
    /// around one whose operator binds less tightly than the one it is an
    /// operand of.
    func spelled(in parentheses: [Int: [GoSourcePosition]]) -> String {
        let text = bare(in: parentheses)
        guard let pairs = parentheses[GoParenthesized.key(of: position)] else { return text }
        return String(repeating: "(", count: pairs.count) + text
            + String(repeating: ")", count: pairs.count)
    }

    private func bare(in parentheses: [Int: [GoSourcePosition]]) -> String {
        if let operation = bitwiseOperation {
            let precedence = operation.operator.spellingPrecedence
            if operation.operator.isUnary {
                return operation.operator.spelling
                    + operation.operands[0].operand(of: precedence, in: parentheses)
            }
            return operation.operands[0].operand(of: precedence, in: parentheses) + " "
                + operation.operator.spelling + " "
                + operation.operands[1].operand(of: precedence + 1, in: parentheses)
        }
        if let operand = spreadOperand { return operand.spelled(in: parentheses) + GoSpread.spelling }
        switch self {
        case .integer(let value, _):
            return String(value)
        case .string(let value, _):
            return GoSourceSpelling.quoted(value)
        case .identifier(let name, _):
            return name
        case .selector(let base, let name, _):
            return base.spelledAsOperand(in: parentheses) + "." + name
        case .compositeLiteral(let type, let elements, _):
            return (type.isElided ? "" : type.sourceSpelling) + (elements.isEmpty ? "{}" : "{…}")
        case .index(let base, let index, _):
            return base.spelledAsOperand(in: parentheses) + "[" + index.spelled(in: parentheses)
                + "]"
        case .slicing(let base, let low, let high, _):
            return base.spelledAsOperand(in: parentheses) + "["
                + (low?.spelled(in: parentheses) ?? "") + ":"
                + (high?.sliceIndexesAfterLow.map { $0.spelled(in: parentheses) }
                    .joined(separator: ":") ?? "") + "]"
        case .typeExpression(let type, _):
            return type.sourceSpelling
        case .call(let callee, let arguments, _):
            return callee.spelledAsOperand(in: parentheses) + "("
                + arguments.map { $0.spelled(in: parentheses) }.joined(separator: ", ") + ")"
        case .typeAssertion(let base, let type, _):
            return base.spelledAsOperand(in: parentheses) + ".("
                + (isTypeSwitchGuard ? "type" : type.sourceSpelling) + ")"
        case .functionLiteral(let parameters, let resultNames, let resultTypes, let body, _):
            return GoSourceSpelling.functionLiteral(
                parameters, resultNames: resultNames, resultTypes: resultTypes)
                + (body.statements.isEmpty ? " {}" : " {…}")
        case .unary(let unaryOperator, let operand, _):
            return GoSourceSpelling.text(of: unaryOperator)
                + operand.operand(of: GoSourceSpelling.unaryPrecedence, in: parentheses)
        case .binary(let left, let binaryOperator, let right, _):
            let precedence = GoSourceSpelling.precedence(of: binaryOperator)
            return left.operand(of: precedence, in: parentheses) + " "
                + GoSourceSpelling.text(of: binaryOperator) + " "
                + right.operand(of: precedence + 1, in: parentheses)
        }
    }

    /// How tightly the operator of the expression binds: Go's five levels
    /// for a binary operator, one above them for a unary one, and above
    /// that for anything else.
    private var spellingPrecedence: Int {
        if let operation = bitwiseOperation {
            return operation.operator.isUnary
                ? GoSourceSpelling.unaryPrecedence : operation.operator.spellingPrecedence
        }
        switch self {
        case .binary(_, let binaryOperator, _, _): return GoSourceSpelling.precedence(of: binaryOperator)
        case .unary: return GoSourceSpelling.unaryPrecedence
        default: return GoSourceSpelling.unaryPrecedence + 1
        }
    }

    /// The expression as an operand of an operator of `precedence`.
    private func operand(of precedence: Int, in parentheses: [Int: [GoSourcePosition]]) -> String {
        let text = spelled(in: parentheses)
        if parentheses[GoParenthesized.key(of: position)] != nil { return text }
        return spellingPrecedence < precedence ? "(" + text + ")" : text
    }

    /// The expression where a selection, an index, or a call follows it.
    func spelledAsOperand(in parentheses: [Int: [GoSourcePosition]]) -> String {
        operand(of: GoSourceSpelling.unaryPrecedence + 1, in: parentheses)
    }
}

extension GoBitwiseOperator {
    /// The level of the operator among Go's five: `|` and `^` add, the
    /// others multiply.
    var spellingPrecedence: Int {
        switch self {
        case .or, .xor: return 4
        case .and, .andNot, .shiftLeft, .shiftRight: return 5
        case .complement: return GoSourceSpelling.unaryPrecedence
        }
    }
}

extension GoTypeExpression {
    var sourceSpelling: String {
        switch self {
        case .named(let name, _):
            return name
        case .pointer(let pointee, _):
            return "*" + pointee.sourceSpelling
        case .array(let length, let element, _):
            switch length {
            case GoSpread.variadicLength: return GoSpread.spelling + element.sourceSpelling
            case GoCompositeLiterals.openLength: return "[...]" + element.sourceSpelling
            default: return "[\(length)]" + element.sourceSpelling
            }
        case .slice(let element, _):
            return "[]" + element.sourceSpelling
        case .map(let key, let value, _):
            return "map[" + key.sourceSpelling + "]" + value.sourceSpelling
        case .channel(let direction, let element, _):
            switch direction {
            case .bidirectional: return "chan " + element.sourceSpelling
            case .sendOnly: return "chan<- " + element.sourceSpelling
            case .receiveOnly: return "<-chan " + element.sourceSpelling
            }
        case .structure(let fields, _):
            return "struct{" + fields.map { $0.name + " " + $0.type.sourceSpelling }.joined(separator: "; ")
                + "}"
        case .interface(let methods, _):
            if let signature = functionSignature {
                return "func" + GoSourceSpelling.signature(signature.parameters, signature.results)
            }
            if methods.isEmpty { return "interface{}" }
            return "interface{"
                + methods.map {
                    $0.name + GoSourceSpelling.signature($0.parameters, $0.results)
                }.joined(separator: "; ") + "}"
        }
    }
}

enum GoSourceSpelling {
    /// A string as an interpreted string literal.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    static func signature(_ parameters: [GoTypeExpression], _ results: [GoTypeExpression]) -> String {
        let list = "(" + parameters.map(\.sourceSpelling).joined(separator: ", ") + ")"
        switch results.count {
        case 0: return list
        case 1: return list + " " + results[0].sourceSpelling
        default: return list + " (" + results.map(\.sourceSpelling).joined(separator: ", ") + ")"
        }
    }

    static let unaryPrecedence = 6

    static func precedence(of binaryOperator: GoBinaryOperator) -> Int {
        switch binaryOperator {
        case .logicalOr: return 1
        case .logicalAnd: return 2
        case .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual: return 3
        case .add, .subtract: return 4
        case .multiply, .divide, .remainder: return 5
        }
    }

    /// The header of a function literal as Go prints it: `func(a, b int) string`.
    /// Parameters that share one type in the source are written together;
    /// the parser gave them the same type node.
    static func functionLiteral(
        _ parameters: [GoParameter], resultNames: [String?], resultTypes: [GoTypeExpression]
    ) -> String {
        // A parameter without a name is kept as a blank one; a list of
        // nothing but those is taken for the one without names.
        let isNamed = !parameters.allSatisfy { $0.name == GoValueList.blank }
        var groups: [String] = []
        var index = 0
        while index < parameters.count {
            let type = parameters[index].type
            var names: [String] = []
            var next = index
            while next < parameters.count, parameters[next].type.position == type.position,
                parameters[next].type == type
            {
                if isNamed { names.append(parameters[next].name) }
                next += 1
            }
            groups.append(
                names.isEmpty
                    ? type.sourceSpelling : names.joined(separator: ", ") + " " + type.sourceSpelling)
            index = next
        }
        var text = "func(" + groups.joined(separator: ", ") + ")"
        let named = zip(resultNames, resultTypes).compactMap { name, type in
            name.map { $0 + " " + type.sourceSpelling }
        }
        if named.count == resultTypes.count, !named.isEmpty {
            text += " (" + named.joined(separator: ", ") + ")"
        } else if resultTypes.count == 1 {
            text += " " + resultTypes[0].sourceSpelling
        } else if !resultTypes.isEmpty {
            text += " (" + resultTypes.map(\.sourceSpelling).joined(separator: ", ") + ")"
        }
        return text
    }

    static func text(of unaryOperator: GoUnaryOperator) -> String {
        switch unaryOperator {
        case .plus: return "+"
        case .minus: return "-"
        case .not: return "!"
        case .address: return "&"
        case .dereference: return "*"
        case .receive: return "<-"
        }
    }

    static func text(of binaryOperator: GoBinaryOperator) -> String {
        switch binaryOperator {
        case .add: return "+"
        case .subtract: return "-"
        case .multiply: return "*"
        case .divide: return "/"
        case .remainder: return "%"
        case .equal: return "=="
        case .notEqual: return "!="
        case .less: return "<"
        case .lessEqual: return "<="
        case .greater: return ">"
        case .greaterEqual: return ">="
        case .logicalAnd: return "&&"
        case .logicalOr: return "||"
        }
    }
}
