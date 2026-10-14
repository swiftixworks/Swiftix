/// A call of several results as the arguments of another call.
///
/// Go has one special case in its calls: where `g()` is the only argument of
/// `f(g())` and `g` has several results, they are the arguments of `f`, in
/// order, as if a program had written each. Everywhere else one value is
/// wanted, and a call of several results is an error.
///
/// The syntax tree has no node for "the second result of this call", and the
/// public enums gain none. The type checker and the compiler each meet the
/// case where they meet any call: they check or make the inner call there,
/// once, and go on with a call whose arguments are names for its results.
/// The names begin with `$`, which no source can write, and belong to the
/// scope the call is in. Every kind of callee then takes the results the way
/// it takes arguments a program wrote: a function, a method, a function
/// value, a variadic parameter, a builtin, and the printers of the library
/// alike.
///
/// Pure value types; no executor state.
enum GoForwardedResults {
    /// The name the type checker gives result `index` of the inner call
    /// while it checks the call that takes it.
    static func name(_ index: Int) -> String { prefix + String(index) }

    /// What the name of every such result begins with.
    static let prefix = "$forwarded."

    /// The name under which the scope of those results keeps how the source
    /// writes the inner call: a message about a result names the call.
    static let spellingName = "$forwarded"

    /// The inner call when `arguments` is one call and `callee` is something
    /// that takes arguments. An operator and the `...` of `values...` are
    /// written as calls of reserved names: they take operands, each one
    /// value, and are no call whose results could be passed on.
    static func call(
        in arguments: [GoExpression], of callee: GoExpression
    ) -> (callee: GoExpression, arguments: [GoExpression], position: GoSourcePosition)? {
        guard arguments.count == 1, !isReserved(callee),
            case .call(let inner, let innerArguments, let position) = arguments[0],
            !isReserved(inner)
        else { return nil }
        return (inner, innerArguments, position)
    }

    private static func isReserved(_ callee: GoExpression) -> Bool {
        if case .identifier(let name, _) = callee { return name.hasPrefix("$") }
        return false
    }
}

extension GoExpression {
    /// Where the expression begins, which is where Go reports an operand.
    /// `position` is the place a node is recognized by: the `(` of a call,
    /// the name a selection selects, the operator between two operands.
    var start: GoSourcePosition {
        switch self {
        case .selector(let base, _, _), .index(let base, _, _), .typeAssertion(let base, _, _):
            return base.start
        case .binary(let left, _, _, _):
            return left.start
        case .call(let callee, let arguments, _):
            // An operator between its operands, and the `...` after one.
            if let operation = bitwiseOperation, !operation.operator.isUnary {
                return operation.operands[0].start
            }
            if spreadOperand != nil { return arguments[0].start }
            return callee.start
        default:
            return position
        }
    }
}

extension GoBuiltinFunction {
    /// The results of a function of the library that has several and is
    /// no `GoNativeFunction`, which lists its own.
    var severalResults: [GoType]? {
        let failure = GoPredeclared.errorType
        switch self {
        case .fmtPrint, .fmtPrintln, .strconvAtoi: return [.int, failure]
        case .userlandReadInput, .userlandReadStdin: return [.string, .int]
        case .userlandWindowSize: return [.int, .int]
        case .netDial: return [.named(GoLibraryTypes.connectionName), failure]
        case .netListen: return [.named(GoLibraryTypes.listenerName), failure]
        case .netLookupHost: return [.slice(.string), failure]
        case .httpGet: return [.named("http.Response"), failure]
        default: return nil
        }
    }
}
