/// The builtins `print` and `println`, which write their operands to
/// standard error as Go's runtime writes them: numbers in decimal, a float
/// as `+1.500000e+000`, a value of a reference type as an address. The
/// operands are boxed with their types, as for `fmt`, and a native prints
/// them (`$print`, `$println`).
enum GoBuiltinPrint {
    static func native(newline: Bool) -> String { newline ? "$println" : "$print" }
    static let nativeCallNames: Set<String> = ["$print", "$println"]
}

extension FunctionChecker {
    /// Go's checks of the operands of `print` and `println`: each is a
    /// value of a type the runtime can print, which a struct or an array is
    /// not, and an untyped constant fits the type it takes.
    mutating func checkPrintOperands(
        _ name: String, arguments: [GoExpression], position: GoSourcePosition
    ) throws {
        for argument in arguments {
            let operandType: GoType
            do {
                operandType = try type(of: argument)
                try requireDefaultValue(argument)
            } catch let diagnostic as GoDiagnostic {
                // A constant that is too large for the type it takes, said
                // as Go says it of an argument.
                let prefix = "constant "
                let parts = diagnostic.message.dropFirst(prefix.count).split(
                    separator: " ", omittingEmptySubsequences: false)
                let kinds = ["int": "int", "float64": "float", "int32": "rune"]
                guard diagnostic.message.hasPrefix(prefix), parts.count == 3, parts[1] == "overflows",
                    let kind = kinds[String(parts[2])]
                else { throw diagnostic }
                throw GoDiagnostic(
                    position: diagnostic.position,
                    message: "cannot use \(argument.sourceSpelling) (untyped \(kind) constant \(parts[0])) "
                        + "as \(parts[2]) value in argument to built-in \(name) (overflows)")
            }
            if operandType == .nilType {
                throw GoDiagnostic(
                    position: argument.position, message: "use of untyped nil in argument to built-in \(name)")
            }
            switch underlying(operandType) {
            case .structure, .array:
                // Go names `print` for both, at the call's parenthesis.
                throw GoDiagnostic(
                    position: GoSourcePosition(
                        path: position.path, offset: position.offset + name.utf8.count,
                        line: position.line, column: position.column + name.utf8.count),
                    message: "illegal types for operand: print\n\t\(operandType)")
            default:
                break
            }
        }
    }
}
