/// An expression or a type as a message names it.
///
/// Go quotes the operand an error is about: `index i must be integer
/// constant`, `invalid field name "X" in struct literal`, `defer discards
/// result of len(s)`. The syntax tree keeps no text, so the operand is
/// written back from its nodes the way Go's checker writes one: a composite
/// literal by its type and `{…}`, a function literal as `func literal`.
extension GoExpression {
    var sourceSpelling: String {
        if let operation = bitwiseOperation {
            let operands = operation.operands.map(\.sourceSpelling)
            return operation.operator.isUnary
                ? operation.operator.spelling + operands[0]
                : operands[0] + " " + operation.operator.spelling + " " + operands[1]
        }
        if let operand = spreadOperand { return operand.sourceSpelling + GoSpread.spelling }
        switch self {
        case .integer(let value, _):
            return String(value)
        case .string(let value, _):
            return GoSourceSpelling.quoted(value)
        case .identifier(let name, _):
            return name
        case .selector(let base, let name, _):
            return base.sourceSpelling + "." + name
        case .compositeLiteral(let type, _, _):
            return (type.isElided ? "" : type.sourceSpelling) + "{…}"
        case .index(let base, let index, _):
            return base.sourceSpelling + "[" + index.sourceSpelling + "]"
        case .slicing(let base, let low, let high, _):
            return base.sourceSpelling + "[" + (low?.sourceSpelling ?? "") + ":" + (high?.sourceSpelling ?? "") + "]"
        case .typeExpression(let type, _):
            return type.sourceSpelling
        case .call(let callee, let arguments, _):
            return callee.sourceSpelling + "(" + arguments.map(\.sourceSpelling).joined(separator: ", ") + ")"
        case .typeAssertion(let base, let type, _):
            return base.sourceSpelling + ".(" + type.sourceSpelling + ")"
        case .functionLiteral:
            return "(func literal)"
        case .unary(let unaryOperator, let operand, _):
            return GoSourceSpelling.text(of: unaryOperator) + operand.sourceSpelling
        case .binary(let left, let binaryOperator, let right, _):
            return left.sourceSpelling + " " + GoSourceSpelling.text(of: binaryOperator) + " "
                + right.sourceSpelling
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
