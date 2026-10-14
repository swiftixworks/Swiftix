/// Diagnostics worded as Go words them.
///
/// Go reports an operand by what the source wrote and what the checker
/// knows of it: `1 (untyped int constant)`, `x (variable of type int)`,
/// `f() (value of type T)`, `c (constant 5 of int type T)`. It says where
/// the operand was to be used (`in assignment`, `in argument to f`), and
/// why a value is none of an interface type (`T does not implement I
/// (missing method M)`). A message of this compiler is the one `go build`
/// prints for the same program, so each is built here, by the rules of Go's
/// checker, and only where a check has already failed: nothing in this file
/// runs for a program that compiles.

// MARK: - Types

enum GoTypeSpelling {
    /// An interface type as Go prints it. `any` and `error` have names; the
    /// tree keeps neither apart from the same methods written out.
    static func interface(_ methods: [GoInterfaceMethod]) -> String {
        if methods.isEmpty { return "any" }
        if methods == [GoInterfaceMethod(name: "Error", results: [.string])] { return "error" }
        return "interface{"
            + methods.map { $0.name + signature($0.parameters, $0.results) }
            .joined(separator: "; ") + "}"
    }

    /// A named type as Go prints it. Go 1.24 has two packages named `sync`
    /// among those every program that imports one reaches, and tells them
    /// apart by printing the path in quotes: `"sync".Mutex`.
    static func named(_ name: String) -> String {
        name.hasPrefix("sync.") ? "\"sync\"." + name.dropFirst("sync.".count) : name
    }

    /// `(int, string) error`: the parameters and results of a function.
    static func signature(_ parameters: [GoType], _ results: [GoType]) -> String {
        let list = "(" + parameters.map(\.description).joined(separator: ", ") + ")"
        switch results.count {
        case 0: return list
        case 1: return list + " " + results[0].description
        default: return list + " (" + results.map(\.description).joined(separator: ", ") + ")"
        }
    }

    /// What Go calls the structure of a type: the word it puts before a
    /// named type (`struct type T`) and after `not defined on`.
    static func kind(of underlying: GoType) -> String? {
        switch underlying {
        case .structure: return "struct"
        case .pointer: return "pointer"
        case .array: return "array"
        case .slice: return "slice"
        case .map: return "map"
        case .channel: return "chan"
        case .interface: return "interface"
        case .function: return "func"
        default: return nil
        }
    }

    /// The structure of a type of the run-time library, which no
    /// declaration of the program tells.
    static func libraryKind(of name: String) -> String {
        switch name {
        case GoLibraryTypes.durationName: return "int64"
        case GoTimeLibrary.monthName, GoTimeLibrary.weekdayName: return "int"
        case "context.Context", "net.Conn", "net.Listener", "http.ResponseWriter", "http.Handler",
            "io.Reader", "io.Writer", "io.Closer", "io.ReadWriter", "io.ReadCloser",
            "io.WriteCloser", "io.ReadWriteCloser", "io.Seeker", "io.ReaderAt", "io.WriterAt",
            "io.ByteReader", "io.ByteWriter", "io.StringWriter", "fmt.Stringer", "sort.Interface":
            return "interface"
        case "context.CancelFunc", "http.HandlerFunc": return "func"
        default: return "struct"
        }
    }
}

extension GoType {
    /// The type as `description` printed it before it spelled interface
    /// types out. The names of symbols and the descriptors of run-time
    /// types were made with that text, and are what they were.
    var legacyDescription: String {
        switch self {
        case .int: return "int"
        case .string: return "string"
        case .bool: return "bool"
        case .void: return "void"
        case .named(let name): return name
        case .structure(let fields):
            return "struct{"
                + fields.map { field -> String in
                    var text =
                        field.isEmbedded
                        ? field.type.legacyDescription
                        : "\(field.name) \(field.type.legacyDescription)"
                    if let tag = field.tag {
                        text += " \""
                        for character in tag {
                            if character == "\"" || character == "\\" { text.append("\\") }
                            text.append(character)
                        }
                        text += "\""
                    }
                    return text
                }.joined(separator: "; ") + "}"
        case .pointer(let pointee): return "*" + pointee.legacyDescription
        case .nilType: return "nil"
        case .array(let length, let element):
            return (length < 0 ? "..." : "[\(length)]") + element.legacyDescription
        case .slice(let element): return "[]" + element.legacyDescription
        case .map(let key, let value):
            return "map[" + key.legacyDescription + "]" + value.legacyDescription
        case .channel(let direction, let element):
            switch direction {
            case .bidirectional: return "chan " + element.legacyDescription
            case .sendOnly: return "chan<- " + element.legacyDescription
            case .receiveOnly: return "<-chan " + element.legacyDescription
            }
        case .interface(let methods):
            return methods.isEmpty ? "interface{}" : "interface{...}"
        case .function(let parameters, let results):
            let list =
                "func(" + parameters.map(\.legacyDescription).joined(separator: ", ") + ")"
            switch results.count {
            case 0: return list
            case 1: return list + " " + results[0].legacyDescription
            default:
                return list + " (" + results.map(\.legacyDescription).joined(separator: ", ")
                    + ")"
            }
        }
    }
}

// MARK: - Operands

extension FunctionChecker {
    /// `type T`, with the structure of a type that has a name before it, as
    /// Go describes the type of an operand: `struct type T`, `int type
    /// Celsius`, `interface type error`.
    func typePhrase(_ type: GoType) -> String {
        guard let kind = namedKind(type) else { return "type \(type)" }
        return "\(kind) type \(type)"
    }

    /// What a type that has a name is underneath, as Go words it; nil for a
    /// type without a name and for the predeclared ones but `any` and
    /// `error`, which are declared like any other.
    func namedKind(_ type: GoType) -> String? {
        switch type {
        case .interface(let methods):
            return methods.isEmpty || type == GoPredeclared.errorType ? "interface" : nil
        case .named(let name):
            guard typeDefinitions[name] != nil else {
                if GoNumericKind(typeName: name) != nil { return nil }
                return GoTypeSpelling.libraryKind(of: name)
            }
            let shape = underlying(type)
            if let kind = GoTypeSpelling.kind(of: shape) { return kind }
            // A type defined over one of the library is what that one is.
            var next = typeDefinitions[name]?.underlying
            while case .named(let inner)? = next {
                guard let definition = typeDefinitions[inner] else {
                    return GoNumericKind(typeName: inner) != nil
                        ? inner : GoTypeSpelling.libraryKind(of: inner)
                }
                next = definition.underlying
            }
            return "\(shape)"
        default:
            return nil
        }
    }

    /// What Go calls the type of a value in `operator < not defined on
    /// struct`: its structure, or the type itself when it has none.
    func kindOrType(_ type: GoType) -> String {
        let shape = underlying(type)
        if let kind = GoTypeSpelling.kind(of: shape) { return kind }
        if case .named(let name) = shape, typeDefinitions[name] == nil,
            GoNumericKind(typeName: name) == nil, GoLibraryTypes.underlying(of: name) == nil
        {
            return GoTypeSpelling.libraryKind(of: name)
        }
        return "\(type)"
    }

    /// An expression as a message writes it. A result of `g()` that `f(g())`
    /// passes on is written as the call it came from.
    func spelling(of expression: GoExpression) -> String {
        if case .identifier(let name, _) = expression, name.hasPrefix(GoForwardedResults.prefix),
            let call = lookup(GoForwardedResults.spellingName)?.position?.path
        {
            return call
        }
        if let grouped = expression.groupedResult { return spelling(of: grouped.value) }
        return expression.spelled(in: namePositions)
    }

    /// The arguments of a call as a message lists them. The results of
    /// `g()` that `f(g())` passes on are the one call the source wrote.
    func argumentList(_ arguments: [GoExpression]) -> String {
        if let first = arguments.first, case .identifier(let name, _) = first,
            name.hasPrefix(GoForwardedResults.prefix)
        {
            return spelling(of: first)
        }
        return arguments.map { spelling(of: $0) }.joined(separator: ", ")
    }

    /// Go's report of the call `expression`, which has `results`, where one
    /// value is wanted.
    func severalValues(_ expression: GoExpression, results: [GoType]) -> GoDiagnostic {
        // The results as Go prints them: with the names a declaration
        // of the program gives them, when it gives them all one.
        var tuple = Self.summary(of: results)
        var names: [String?]?
        if case .call(let callee, _, _) = expression {
            switch callee {
            case .identifier(let name, _):
                if lookup(name) == nil { names = functionSignatures[name]?.names?.results }
            case .selector(let base, let name, _):
                if importedPackage(named: base) == nil, let baseType = probedType(of: base) {
                    names = methodSignature(of: baseType, named: name)?.names?.results
                }
            default:
                break
            }
        }
        if let names, names.count == results.count, !names.contains(where: { $0 == nil }) {
            tuple = "(" + zip(names, results).map { "\($0 ?? "") \($1)" }.joined(separator: ", ") + ")"
        }
        return GoDiagnostic(
            position: Self.start(of: expression, in: namePositions),
            message: "multiple-value \(spelling(of: expression)) (value of type \(tuple)) in "
                + "single-value context")
    }

    /// Go's report of a value that does not convert to `target`:
    /// `cannot convert x (variable of type int) to type T`, and why a value
    /// is none of an interface type.
    mutating func cannotConvert(
        _ argument: GoExpression, ofType source: GoType, to target: GoType
    ) -> GoDiagnostic {
        if source == .void { return noValue(argument) }
        var message = "cannot convert \(describe(argument, ofType: source)) to type \(target)"
        if case .interface(let wanted) = underlying(target), !wanted.isEmpty, source != .nilType,
            let cause = implementationCause(of: source, for: target, methods: wanted)
        {
            message += ": " + cause
        }
        return GoDiagnostic(position: Self.start(of: argument, in: namePositions), message: message)
    }

    /// Whether `expression` is the predeclared `nil`.
    func isNil(_ expression: GoExpression) -> Bool {
        if case .identifier("nil", _) = expression { return lookup("nil") == nil }
        return false
    }

    /// The kind of an untyped constant and its value as Go prints it, when
    /// `expression` is a constant. The kind is nil for a constant that has
    /// a type, and the value where this cannot tell it.
    ///
    /// Numbers are folded by `constant(of:)`. A string or boolean constant
    /// is told here from literals and the operators on them, and a named
    /// string constant from what its binding keeps of it.
    func constantOperand(
        _ expression: GoExpression, ofType type: GoType
    ) -> (kind: String?, value: String?)? {
        if let number = (try? constant(of: expression)) ?? nil {
            guard number.isUntyped else { return (nil, number.text) }
            let kind: String
            switch number.kind {
            case .integer: kind = "int"
            case .rune: kind = "rune"
            case .float: kind = "float"
            }
            return (kind, number.text)
        }
        switch expression {
        case .string(let value, _):
            return ("string", Self.constantText(ofString: value))
        case .selector(let base, let member, _):
            // A constant of the library that is an integer of a type.
            guard let package = importedPackage(named: base),
                let value = GoStandardLibrary.integerConstant(package: package, member: member)
            else { return nil }
            return (package == "io" ? "int" : nil, String(value))
        case .identifier(let name, _):
            if name == "true" || name == "false", lookup(name) == nil { return ("bool", name) }
            guard let binding = lookup(name), binding.isConstant else { return nil }
            // A named string constant keeps its text and whether it has a
            // type; a named boolean one keeps only that it is a constant.
            if let word = binding.word, let text = word.text {
                return (word.type == nil ? "string" : nil, Self.constantText(ofString: text))
            }
            return (nil, nil)
        case .unary(.not, let operand, _):
            guard let folded = constantOperand(operand, ofType: type), folded.value != nil else {
                return nil
            }
            return (folded.kind, folded.value == "true" ? "false" : "true")
        case .binary(let left, let binaryOperator, let right, _):
            return constantOperand(left, binaryOperator, right)
        case .call(let callee, let arguments, _):
            // `min` and `max` of untyped constants.
            if let extreme = orderedConstantValue(expression) { return ("int", String(extreme)) }
            guard arguments.count == 1, expression.bitwiseOperation == nil else { return nil }
            if case .identifier("len", _) = callee, isPredeclared("len"),
                case .string(let value, _) = arguments[0]
            {
                return (nil, String(value.utf8.count))
            }
            // `string("abc")`: a constant of the type converted to.
            guard let target = try? conversionTarget(callee), isString(target) || isBool(target),
                let operand = constantOperand(arguments[0], ofType: target), operand.kind != nil
            else { return nil }
            return (nil, operand.value)
        default:
            return nil
        }
    }

    /// The constant a binary operator on two string or boolean constants
    /// gives: a concatenation, a comparison, `&&`, and `||`.
    func constantOperand(
        _ left: GoExpression, _ binaryOperator: GoBinaryOperator, _ right: GoExpression
    ) -> (kind: String?, value: String?)? {
        let numbers = ((try? constant(of: left)) ?? nil, (try? constant(of: right)) ?? nil)
        if let lhs = numbers.0, let rhs = numbers.1 {
            // Arithmetic was folded by the caller; this is a comparison.
            let order = lhs.value == rhs.value ? 0 : (lhs.value < rhs.value ? -1 : 1)
            guard let holds = Self.comparison(binaryOperator, order) else { return nil }
            return ("bool", holds ? "true" : "false")
        }
        guard let lhs = constantOperand(left, ofType: .string),
            let rhs = constantOperand(right, ofType: .string)
        else { return nil }
        let kind = lhs.kind == nil || rhs.kind == nil ? nil : lhs.kind
        guard case .string(let first, _) = left, case .string(let second, _) = right else {
            switch binaryOperator {
            case .add: return (kind, nil)
            default: return ("bool", nil)
            }
        }
        if binaryOperator == .add { return (kind, Self.constantText(ofString: first + second)) }
        let order = first == second ? 0 : (first < second ? -1 : 1)
        guard let holds = Self.comparison(binaryOperator, order) else { return nil }
        return ("bool", holds ? "true" : "false")
    }

    static func comparison(_ binaryOperator: GoBinaryOperator, _ order: Int) -> Bool? {
        switch binaryOperator {
        case .equal: return order == 0
        case .notEqual: return order != 0
        case .less: return order < 0
        case .lessEqual: return order <= 0
        case .greater: return order > 0
        case .greaterEqual: return order >= 0
        default: return nil
        }
    }

    /// A string constant as Go prints its value: quoted, and cut short
    /// after 72 characters.
    static func constantText(ofString value: String) -> String {
        let quoted = GoSourceSpelling.quoted(value)
        guard quoted.count > 72 else { return quoted }
        return String(quoted.prefix(69)) + "..."
    }

    /// The name of the type of an untyped operand, `untyped int`, or nil
    /// for an operand that has a type.
    func untypedName(of expression: GoExpression, ofType type: GoType) -> String? {
        if type == .nilType { return "untyped nil" }
        if let constant = constantOperand(expression, ofType: type) {
            return constant.kind.map { "untyped " + $0 }
        }
        return isUntypedBooleanValue(expression) ? "untyped bool" : nil
    }

    /// The type of an operand as `mismatched types` names it.
    func operandTypeName(_ expression: GoExpression, ofType type: GoType) -> String {
        untypedName(of: expression, ofType: type) ?? "\(type)"
    }

    /// Whether `expression` is a comparison, or made of comparisons by the
    /// operators on booleans: a value that is a `bool` only where it is
    /// used as one. `true`, `false`, and a constant are no values in this
    /// sense: Go describes them as constants. `isUntypedBoolean` asks the
    /// wider question, for what may take a named boolean type.
    func isUntypedBooleanValue(_ expression: GoExpression) -> Bool {
        switch expression {
        case .binary(let left, let binaryOperator, let right, _):
            switch binaryOperator {
            case .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual: return true
            case .logicalAnd, .logicalOr:
                return isUntypedBooleanOperand(left) && isUntypedBooleanOperand(right)
            default: return false
            }
        case .unary(.not, let operand, _):
            return isUntypedBooleanValue(operand)
        default:
            return false
        }
    }

    private func isUntypedBooleanOperand(_ expression: GoExpression) -> Bool {
        if isUntypedBooleanValue(expression) { return true }
        if case .identifier(let name, _) = expression, name == "true" || name == "false" {
            return lookup(name) == nil
        }
        return false
    }

    /// What Go's checker takes an operand that is no constant for: a
    /// variable, which has an address; a map index expression; a
    /// `comma, ok expression`, which may give a second value; or a value.
    mutating func operandMode(_ expression: GoExpression) -> String {
        switch expression {
        case .identifier(let name, _):
            if name.hasPrefix(GoForwardedResults.prefix) { return "value" }
            return lookup(name) == nil ? "value" : "variable"
        case .selector(let base, let name, _):
            if let packageName = importedPackage(named: base) {
                return libraryFunctionType(packageName, name) == nil
                    && GoStandardLibrary.resolve(package: packageName, member: name) == nil
                    && GoStandardLibrary.nativeFunction(package: packageName, member: name) == nil
                    ? "variable" : "value"
            }
            guard let baseType = probedType(of: base),
                structFields(of: baseType)?.contains(where: { $0.name == name }) == true
                    || isPromotedField(name, in: baseType)
            else { return "value" }
            return isPointer(baseType) || operandMode(base) == "variable" ? "variable" : "value"
        case .index(let base, _, _):
            guard let baseType = probedType(of: base) else { return "value" }
            switch underlying(baseType) {
            case .slice: return "variable"
            case .map: return "map index expression"
            case .array: return operandMode(base) == "variable" ? "variable" : "value"
            case .pointer: return "variable"
            default: return "value"
            }
        case .unary(.dereference, _, _):
            return "variable"
        case .unary(.receive, _, _), .typeAssertion:
            return "comma, ok expression"
        default:
            return "value"
        }
    }

    /// Whether an embedded field lends a value of `type` the field `name`.
    func isPromotedField(_ name: String, in type: GoType) -> Bool {
        if case .found(let promotion) = GoEmbedding.promotion(
            of: name, in: type, definitions: typeDefinitions)
        {
            return !promotion.isMethod
        }
        return false
    }

    /// The type of `expression`, asked of a copy of the checker: what the
    /// copy notes of the expression is not kept.
    func probedType(of expression: GoExpression) -> GoType? {
        var probe = self
        probe.isProbing = true
        return try? probe.type(of: expression)
    }

    /// An operand as Go describes it: `x (variable of type int)`.
    mutating func describe(_ expression: GoExpression, ofType type: GoType) -> String {
        if isNil(expression) { return "nil" }
        let text = spelling(of: expression)
        if type == .void { return text + " (no value)" }
        if let constant = constantOperand(expression, ofType: type) {
            let shown = constant.value.flatMap { $0 == text ? nil : " " + $0 } ?? ""
            if let kind = constant.kind { return "\(text) (untyped \(kind) constant\(shown))" }
            return "\(text) (constant\(shown) of \(typePhrase(type)))"
        }
        if isUntypedBooleanValue(expression) { return "\(text) (untyped bool value)" }
        let phrase = functionTypePhrase(of: expression, ofType: type) ?? typePhrase(type)
        return "\(text) (\(operandMode(expression)) of \(phrase))"
    }

    /// `type func(a int, b string) error`, for an operand that is a
    /// function literal, a function of the program, or a method of a value:
    /// Go prints the type of such a function with the names its declaration
    /// gives its parameters and results. Nil for any other operand.
    func functionTypePhrase(of expression: GoExpression, ofType type: GoType) -> String? {
        guard case .function(let parameters, let results) = type else { return nil }
        var names: GoSignatureNames?
        switch expression {
        case .functionLiteral(let declared, let resultNames, _, _, _):
            names = GoSignatureNames(parameters: declared.map(\.name), results: resultNames)
        case .identifier(let name, _):
            if lookup(name) == nil { names = functionSignatures[name]?.names }
        case .selector(let base, let name, _):
            guard importedPackage(named: base) == nil, let baseType = probedType(of: base),
                structFields(of: baseType)?.contains(where: { $0.name == name }) != true
            else { return nil }
            names = methodSignature(of: baseType, named: name)?.names
        default:
            break
        }
        guard let names, names.parameters.count == parameters.count else { return nil }
        return "type " + names.spelling(parameters: parameters, results: results)
    }

    /// The same for an operand whose type is yet to be asked. Nil when the
    /// operand has none: an error of its own comes before one about it.
    mutating func describe(_ expression: GoExpression) -> String? {
        guard let type = probedType(of: expression) else { return nil }
        return describe(expression, ofType: type)
    }

    // MARK: - Values that do not fit

    /// Go's report of `expression`, of type `actual`, where a value of
    /// `expected` is wanted. `context` says where that is: `assignment`,
    /// `argument to f`, `return statement`.
    mutating func cannotUse(
        _ expression: GoExpression, ofType actual: GoType, as expected: GoType,
        in context: String
    ) -> GoDiagnostic {
        let position = Self.start(of: expression, in: namePositions)
        if actual == .void {
            return GoDiagnostic(
                position: position, message: "\(spelling(of: expression)) (no value) used as value")
        }
        if actual == .nilType {
            return GoDiagnostic(
                position: position, message: "cannot use nil as \(expected) value in \(context)")
        }
        var operand = describe(expression, ofType: actual)
        if isInterface(expected), let constant = constantOperand(expression, ofType: actual),
            constant.kind != nil
        {
            // An untyped constant given to an interface has its default
            // type first, and is described as a constant of it.
            let text = spelling(of: expression)
            let shown = constant.value.flatMap { $0 == text ? nil : " " + $0 } ?? ""
            operand = "\(text) (constant\(shown) of \(typePhrase(actual)))"
        }
        var message = "cannot use \(operand) as \(expected) value in \(context)"
        if let cause = assignmentCause(of: actual, to: expected) { message += ": " + cause }
        return GoDiagnostic(position: position, message: message)
    }

    /// Requires `expression`, of type `actual`, to be a value of `expected`
    /// in `context`.
    mutating func requireUse(
        _ expression: GoExpression, ofType actual: GoType, as expected: GoType,
        in context: String
    ) throws {
        do {
            if try isAssignable(expression, ofType: actual, to: expected) { return }
        } catch let diagnostic as GoDiagnostic {
            throw unrepresentable(diagnostic, expression, ofType: actual, in: context) ?? diagnostic
        }
        throw cannotUse(expression, ofType: actual, as: expected, in: context)
    }

    /// The same for an expression whose type is yet to be asked.
    mutating func requireUse(
        _ expression: GoExpression, as expected: GoType, in context: String
    ) throws {
        try requireUse(expression, ofType: try type(of: expression), as: expected, in: context)
    }

    /// Go's report of a constant that its new type cannot hold, where it is
    /// assigned: `cannot use 300 (untyped int constant) as int8 value in
    /// assignment (overflows)`. `diagnostic` is what the rule for numbers
    /// said of the constant `expression`; nil when it is about anything else.
    mutating func unrepresentable(
        _ diagnostic: GoDiagnostic, _ expression: GoExpression, ofType actual: GoType,
        in context: String
    ) -> GoDiagnostic? {
        guard let failure = Self.unrepresentableConstant(in: diagnostic),
            diagnostic.position.offset == expression.startPosition.offset,
            let constant = constantOperand(expression, ofType: actual), constant.kind != nil
        else { return nil }
        return GoDiagnostic(
            position: Self.start(of: expression, in: namePositions),
            message: "cannot use \(describe(expression, ofType: actual)) as \(failure.type) "
                + "value in \(context) (\(failure.isTruncation ? "truncated" : "overflows"))")
    }

    /// The type a constant was found to be no value of, and whether for its
    /// fraction, when `diagnostic` is the report of that by the rules for
    /// numbers: `constant 300 overflows int8`, `constant 2.5 truncated to int`.
    static func unrepresentableConstant(
        in diagnostic: GoDiagnostic
    ) -> (type: String, isTruncation: Bool)? {
        let message = diagnostic.message
        guard message.hasPrefix("constant ") else { return nil }
        if let type = Self.text(after: " overflows ", in: message) { return (type, false) }
        if let type = Self.text(after: " truncated to ", in: message) { return (type, true) }
        return nil
    }

    /// What follows the first `marker` in `text`.
    static func text(after marker: String, in text: String) -> String? {
        let source = Array(text.utf8)
        let pattern = Array(marker.utf8)
        guard !pattern.isEmpty, source.count >= pattern.count else { return nil }
        for index in 0...(source.count - pattern.count)
        where source[index..<(index + pattern.count)].elementsEqual(pattern) {
            return String(decoding: source[(index + pattern.count)...], as: UTF8.self)
        }
        return nil
    }

    /// Why a value of `actual` is none of `expected`, where Go says: what
    /// keeps a type from implementing an interface, and that an interface
    /// value wants a type assertion to be a value of a type that implements
    /// it.
    func assignmentCause(of actual: GoType, to expected: GoType) -> String? {
        if case .interface(var wanted) = underlying(expected), !wanted.isEmpty {
            // A handle of the library is Go's interface of the name, which
            // has methods the dialect lacks: a type of the program is
            // said to lack the first of them.
            if case .named(let name) = expected, GoLibraryTypes.isHandle(expected),
                !isInterface(actual)
            {
                wanted = GoLibraryTypes.goMethods(ofHandle: name)
            }
            return implementationCause(of: actual, for: expected, methods: wanted)
        }
        if isInterface(actual), !isInterface(expected), isAssignable(expected, to: actual) {
            return "need type assertion"
        }
        return nil
    }

    /// How a value of `type` has the method `name`: with the signature it
    /// has, only through a pointer, or not at all.
    enum MethodFinding {
        case found(FunctionSignature)
        case pointerReceiver
        case missing
    }

    func findMethod(_ name: String, of type: GoType) -> MethodFinding {
        if case .interface(let methods) = underlying(type) {
            guard let method = methods.first(where: { $0.name == name }) else { return .missing }
            return .found(FunctionSignature(parameters: method.parameters, results: method.results))
        }
        if let lent = GoLibraryStructs.lends(type, GoInterfaceMethod(name: name)) {
            // A struct of the library, or `sync.Mutex`: its methods take a
            // pointer, and the value alone has none of them.
            var owner = type
            if case .pointer(let pointee) = type { owner = pointee }
            guard case .named(let typeName) = owner,
                let method = GoLibraryStructs.interfaceMethod(name, of: typeName)
            else { return .missing }
            _ = lent
            if case .pointer = type {
                return .found(
                    FunctionSignature(parameters: method.parameters, results: method.results))
            }
            return .pointerReceiver
        }
        if let library = GoLibraryTypes.method(of: type, named: name) {
            return .found(FunctionSignature(parameters: library.parameters, results: library.results))
        }
        if let native = GoStandardLibrary.method(of: type, named: name) {
            return .found(
                FunctionSignature(
                    parameters: Array(native.parameters.dropFirst()), results: native.results))
        }
        switch type {
        case .named(let base):
            if let method = methodSignatures[methodKey(baseName: base, pointer: false, method: name)] {
                return .found(method)
            }
            return methodSignatures[methodKey(baseName: base, pointer: true, method: name)] == nil
                ? .missing : .pointerReceiver
        case .pointer(.named(let base)):
            if let method = methodSignatures[methodKey(baseName: base, pointer: true, method: name)]
                ?? methodSignatures[methodKey(baseName: base, pointer: false, method: name)]
            {
                return .found(method)
            }
            return .missing
        default:
            return .missing
        }
    }

    /// `T does not implement I (missing method M)`, for the first method
    /// of the interface `target`, in the order of their names, that a value
    /// of `type` lacks or has otherwise.
    func implementationCause(
        of type: GoType, for target: GoType, methods wanted: [GoInterfaceMethod]
    ) -> String? {
        let prefix = "\(type) does not implement \(target)"
        if case .interface(let own) = underlying(type), own.isEmpty { return prefix }
        return missingMethodCause(of: type, methods: wanted).map { prefix + " " + $0 }
    }

    /// `(missing method M)`: what a value of `type` lacks of `wanted`, the
    /// methods of an interface, or has otherwise; nil when it has them all.
    func missingMethodCause(of type: GoType, methods wanted: [GoInterfaceMethod]) -> String? {
        for method in wanted.sorted(by: { $0.name < $1.name }) {
            let want = method.name + GoTypeSpelling.signature(method.parameters, method.results)
            switch findMethod(method.name, of: type) {
            case .found(let signature):
                if signature.parameters == method.parameters, signature.results == method.results {
                    continue
                }
                let have =
                    method.name + GoTypeSpelling.signature(signature.parameters, signature.results)
                return "(wrong type for method \(method.name))\n\t\thave \(have)"
                    + "\n\t\twant \(want)"
            case .pointerReceiver:
                return "(method \(method.name) has pointer receiver)"
            case .missing:
                if case .ambiguous = GoEmbedding.promotion(
                    of: method.name, in: type, definitions: typeDefinitions)
                {
                    return "(ambiguous selector \(type).\(method.name))"
                }
                if structFields(of: type)?.contains(where: { $0.name == method.name }) == true {
                    return "(\(type).\(method.name) is a field, not a method)"
                }
                if let other = otherSpelling(ofMethod: method.name, in: type),
                    case .found(let signature) = findMethod(other, of: type)
                {
                    let have = other + GoTypeSpelling.signature(signature.parameters, signature.results)
                    return "(missing method \(method.name))\n\t\thave \(have)"
                        + "\n\t\twant \(want)"
                }
                return "(missing method \(method.name))"
            }
        }
        return nil
    }

    /// The method of a value of `type` whose name is `name` in other
    /// capitals, which Go mentions beside a name it did not find.
    func otherSpelling(ofMethod name: String, in type: GoType) -> String? {
        guard case .named(let base) = type.pointee(in: typeDefinitions) ?? type else { return nil }
        let folded = name.lowercased()
        var found: String?
        for key in methodSignatures.keys {
            guard let dot = key.lastIndex(of: ".") else { continue }
            let owner = key[..<dot]
            let method = String(key[key.index(after: dot)...])
            guard owner == base || owner == "*" + base, method != name,
                method.lowercased() == folded
            else { continue }
            if found == nil || method < found! { found = method }
        }
        return found
    }
}

// MARK: - Calls

extension FunctionChecker {
    /// How a message names a call of `callee`: as the source writes what is
    /// called, `f`, `t.M`, `os.Exit`, `func(a int) {}`.
    func calleeSpelling(_ callee: GoExpression) -> String {
        spelling(of: callee)
    }

    /// Checks `arguments` against `declared`, the parameters of what
    /// `callee` names: as many as it takes, each a value of its parameter's
    /// type. `position` is the call's.
    mutating func checkArguments(
        _ arguments: [GoExpression], of callee: GoExpression, declared: [GoType],
        position: GoSourcePosition
    ) throws {
        let (operands, parameters) = matched(arguments, to: declared)
        guard operands.count == parameters.count, operands.last?.spreadOperand == nil else {
            throw try argumentCountMismatch(
                arguments, of: callee, declared: declared, position: position)
        }
        for (operand, parameter) in zip(operands, parameters) {
            try requireArgument(operand, as: parameter, of: callee)
        }
    }

    /// Requires `argument` to be a value of `expected`, the type of a
    /// parameter of what `callee` names.
    mutating func requireArgument(
        _ argument: GoExpression, as expected: GoType, of callee: GoExpression
    ) throws {
        let actual = try type(of: argument)
        do {
            if try isAssignable(argument, ofType: actual, to: expected) { return }
        } catch let diagnostic as GoDiagnostic {
            throw unrepresentable(
                diagnostic, argument, ofType: actual, in: "argument to " + calleeSpelling(callee))
                ?? diagnostic
        }
        throw cannotUse(
            argument, ofType: actual, as: expected, in: "argument to " + calleeSpelling(callee))
    }

    /// Go's report of a call with too few or too many arguments, with what
    /// it has and what it wants:
    ///
    ///     not enough arguments in call to f
    ///         have (number)
    ///         want (int, string)
    ///
    /// It is reported at the first argument too many, at the last of too
    /// few, and at the call when there is none. What is wrong with an
    /// argument itself comes first, as in Go, which types them all before
    /// it counts.
    mutating func argumentCountMismatch(
        _ arguments: [GoExpression], of callee: GoExpression, declared: [GoType],
        position: GoSourcePosition
    ) throws -> GoDiagnostic {
        var have: [String] = []
        for argument in arguments {
            let operand = argument.spreadOperand ?? argument
            let operandType = try type(of: operand)
            if operandType == .void { throw noValue(operand) }
            have.append(
                summaryName(operand, ofType: operandType)
                    + (argument.spreadOperand == nil ? "" : GoSpread.spelling))
        }
        let isVariadic = declared.last?.variadicElement != nil
        if !isVariadic, arguments.last?.spreadOperand != nil {
            return GoDiagnostic(
                position: namePositions[position.offset]?.first
                    ?? Self.start(of: callee, in: namePositions),
                message: "cannot use ... in call to non-variadic \(calleeSpelling(callee))")
        }
        var wanted = declared.count
        if isVariadic, arguments.last?.spreadOperand == nil { wanted -= 1 }
        let isTooMany = arguments.count > wanted
        var place = namePositions[position.offset]?.first
            ?? Self.start(of: callee, in: namePositions)
        if isTooMany, wanted < arguments.count {
            place = Self.start(of: arguments[max(wanted, 0)], in: namePositions)
        } else if let last = arguments.last {
            place = Self.start(of: last, in: namePositions)
        }
        return GoDiagnostic(
            position: place,
            message: "\(isTooMany ? "too many" : "not enough") arguments in call to "
                + "\(calleeSpelling(callee))\n\thave (\(have.joined(separator: ", ")))"
                + "\n\twant \(Self.summary(of: declared))")
    }

    /// Go's report of a call without a result where a value is wanted.
    func noValue(_ expression: GoExpression) -> GoDiagnostic {
        GoDiagnostic(
            position: Self.start(of: expression, in: namePositions),
            message: "\(spelling(of: expression)) (no value) used as value")
    }

    /// The type of an operand in the `have` line of a count that does not
    /// match. Go names no type for an untyped constant: a number is a
    /// `number`.
    func summaryName(_ expression: GoExpression, ofType type: GoType) -> String {
        if type == .nilType { return "nil" }
        guard let constant = constantOperand(expression, ofType: type), let kind = constant.kind
        else { return isUntypedBooleanValue(expression) ? "bool" : "\(type)" }
        return kind == "string" || kind == "bool" ? kind : "number"
    }

    /// `(int, ...string)`: the types of a list of parameters or results.
    static func summary(of types: [GoType]) -> String {
        "(" + types.map(\.description).joined(separator: ", ") + ")"
    }
}

// MARK: - Results and library arguments

extension FunctionChecker {
    /// Go's report of one result of the call `expression`, or one value of
    /// a `v, ok` form, that is of `type` where `expected` is wanted. The
    /// operand is the whole expression, which has the type of the result
    /// that does not fit.
    func cannotUseResult(
        of expression: GoExpression, type: GoType, as expected: GoType, in context: String
    ) -> GoDiagnostic {
        var mode = "value"
        switch expression {
        case .index: mode = "map index expression"
        case .typeAssertion, .unary(.receive, _, _): mode = "comma, ok expression"
        default: break
        }
        var message =
            "cannot use \(spelling(of: expression)) (\(mode) of \(typePhrase(type))) "
            + "as \(expected) value in \(context)"
        if let cause = assignmentCause(of: type, to: expected) { message += ": " + cause }
        return GoDiagnostic(
            position: Self.start(of: expression, in: namePositions), message: message)
    }

    /// The targets of `v, ok = expression`, a map index, a type assertion,
    /// or a receive, take its value and whether there was one.
    mutating func requireCommaOk(
        _ expression: GoExpression, results: [GoType], targets: [GoExpression]
    ) throws {
        for (index, (target, resultType)) in zip(targets, results).enumerated() {
            if target.isBlank { continue }
            let targetType = try targetType(of: target)
            if isAssignable(resultType, to: targetType) { continue }
            guard index == 1 else {
                throw cannotUseResult(
                    of: expression, type: resultType, as: targetType, in: "assignment")
            }
            // Whether there was a value is a boolean of no type of its own.
            throw GoDiagnostic(
                position: Self.start(of: expression, in: namePositions),
                message: "cannot use \(spelling(of: expression)) (untyped bool value) as "
                    + "\(targetType) value in assignment")
        }
    }

    /// Go's report of a first argument of `fmt.Fprint` and its like that
    /// has no `Write([]byte) (int, error)`: it is no `io.Writer`.
    mutating func noWriter(
        _ writer: GoExpression, ofType writerType: GoType, in context: String
    ) -> GoDiagnostic {
        let shape = GoType.interface([
            GoInterfaceMethod(
                name: "Write", parameters: [.slice(GoPredeclared.byte)],
                results: [.int, GoPredeclared.errorType])
        ])
        let diagnostic = cannotUse(writer, ofType: writerType, as: shape, in: context)
        return GoDiagnostic(
            position: diagnostic.position,
            message: GoModuleLinker.replacing(
                shape.description, with: "io.Writer", in: diagnostic.message))
    }

    /// Requires `argument`, when it is an untyped constant, to be a value
    /// of its default type: it is given to a parameter of type `any` of
    /// what `callee` names.
    mutating func requireDefault(_ argument: GoExpression, of callee: GoExpression) throws {
        do {
            try requireDefaultValue(argument)
        } catch let diagnostic as GoDiagnostic {
            guard let actual = probedType(of: argument) else { throw diagnostic }
            throw unrepresentable(
                diagnostic, argument, ofType: actual, in: "argument to " + calleeSpelling(callee))
                ?? diagnostic
        }
    }

    /// Keeps how the source writes `call`, whose results the innermost
    /// scope names, for a message about one of them.
    mutating func noteForwardedCall(_ call: GoExpression) {
        var binding = Binding(type: .void, isConstant: false)
        binding.position = GoSourcePosition(
            path: call.spelled(in: namePositions), offset: 0, line: 0, column: 0)
        binding.isUsed = true
        scopes[scopes.count - 1][GoForwardedResults.spellingName] = binding
    }
}

extension GoNativeFunction {
    /// The parameters a message lists for a call of the function, of which
    /// `parameters` are the ones a program gives: the writer of `fmt.Fprint`
    /// is an `io.Writer` to Go, and what follows the fixed ones is `...any`.
    func declared(_ parameters: ArraySlice<GoType>) -> [GoType] {
        var declared = Array(parameters)
        if formatsOperands, declared.first == GoPredeclared.filePointer {
            declared[0] = .named("io.Writer")
        }
        if isVariadic {
            declared.append(
                .array(length: GoSpread.variadicLength, element: variadicElement ?? .interface([])))
        }
        return declared
    }
}

// MARK: - Operators

extension FunctionChecker {
    /// How the source writes the operator at `position` between two
    /// operands: `+`, or `+=` where the parser noted that the operation is
    /// the one a compound assignment stands for.
    func operatorSpelling(_ text: String, at position: GoSourcePosition) -> String {
        namePositions[GoCompoundAssignment.key(of: position)] == nil ? text : text + "="
    }

    /// Whether an untyped operand of type `untyped` may take the type of the
    /// other operand, of type `other`, before an operator is applied: Go
    /// tries where the two could come to match, and reports the types as
    /// they are where they could not.
    private func mayConvert(
        _ leftType: GoType, _ leftName: String?, _ rightType: GoType, _ rightName: String?
    ) -> Bool {
        if leftName == nil, rightName == nil { return false }
        if leftName == nil && isInterface(leftType) || rightName == nil && isInterface(rightType) {
            return true
        }
        if isBool(leftType) != isBool(rightType) { return false }
        if isString(leftType) != isString(rightType) { return false }
        if leftType == .nilType { return rightName == nil && isAssignable(.nilType, to: rightType) }
        if rightType == .nilType { return leftName == nil && isAssignable(.nilType, to: leftType) }
        if isPointer(leftType) || isPointer(rightType) { return false }
        return true
    }

    /// Go's report of an untyped operand that cannot take the type `target`
    /// of the other operand: `cannot convert 1 (untyped int constant) to
    /// type []int`. Nil when it can.
    private mutating func conversionFailure(
        _ operand: GoExpression, ofType type: GoType, to target: GoType
    ) -> GoDiagnostic? {
        let shape = underlying(target)
        let fits: Bool
        switch shape {
        case _ where type == .nilType: fits = isAssignable(.nilType, to: target)
        case .interface(let methods): fits = methods.isEmpty
        case .int, .string, .bool: fits = shape == underlying(type)
        case .named: fits = isNumeric(target) && isNumeric(type)
        default: fits = false
        }
        if fits { return nil }
        // Go names the type by what it is underneath, and `error` by its
        // method.
        let name =
            shape == GoPredeclared.errorType ? "interface{Error() string}" : "\(shape)"
        return GoDiagnostic(
            position: Self.start(of: operand, in: namePositions),
            message: "cannot convert \(describe(operand, ofType: type)) to type \(name)")
    }

    /// Why Go cannot compare two values of `type` with `==`.
    func incomparableCause(_ type: GoType) -> String {
        switch underlying(type) {
        case .slice: return "slice can only be compared to nil"
        case .map: return "map can only be compared to nil"
        case .function: return "func can only be compared to nil"
        case .structure(let fields):
            if let field = fields.first(where: { !isComparable($0.type) }) {
                return "struct containing \(field.type) cannot be compared"
            }
        case .array:
            return "\(underlying(type)) cannot be compared"
        default:
            break
        }
        return "operator == not defined on \(kindOrType(type))"
    }

    /// Go's report of `left operator right`, by the rules of its checker in
    /// their order: an untyped operand takes the type of the other; the
    /// operands of a comparison are assignable one to the other and are
    /// comparable or ordered; those of any other operator have one type,
    /// and one the operator is defined on. Nil when those rules find
    /// nothing wrong.
    ///
    /// A comparison is reported at the operand that is at fault, the second
    /// when the two do not go together; anything else where the operation
    /// begins.
    ///
    /// With `isCase`, `left` is a case of a switch on `right`: an untyped
    /// case takes the type of what is switched on, whatever that is, and
    /// what is wrong is reported as an invalid case, at the case.
    mutating func invalidBinary(
        _ left: GoExpression, _ operatorText: String, _ right: GoExpression,
        _ leftType: GoType, _ rightType: GoType, at position: GoSourcePosition,
        isCase: Bool = false
    ) -> GoDiagnostic? {
        if leftType == .void { return noValue(left) }
        if rightType == .void { return noValue(right) }
        var (leftType, rightType) = (leftType, rightType)
        var leftName = untypedName(of: left, ofType: leftType)
        var rightName = isCase ? nil : untypedName(of: right, ofType: rightType)
        if isCase {
            if leftName != nil {
                if let failure = conversionFailure(left, ofType: leftType, to: rightType) {
                    return failure
                }
                if !isInterface(rightType), leftType != .nilType {
                    (leftType, leftName) = (rightType, nil)
                }
            }
        } else if mayConvert(leftType, leftName, rightType, rightName) {
            if leftName != nil, rightName == nil, leftType != .nilType {
                if let failure = conversionFailure(left, ofType: leftType, to: rightType) {
                    return failure
                }
                // Given to an interface, a constant has its default type.
                if !isInterface(rightType) {
                    (leftType, leftName) = (rightType, nil)
                } else {
                    leftName = nil
                }
            } else if rightName != nil, leftName == nil, rightType != .nilType {
                if let failure = conversionFailure(right, ofType: rightType, to: leftType) {
                    return failure
                }
                // Given to an interface, a constant has its default type.
                if !isInterface(leftType) {
                    (rightType, rightName) = (leftType, nil)
                } else {
                    rightName = nil
                }
            }
        }
        let spelled = operatorSpelling(operatorText, at: position)
        let text = "\(spelling(of: left)) \(spelled) \(spelling(of: right))"
        let leftStart = Self.start(of: left, in: namePositions)
        let rightStart = Self.start(of: right, in: namePositions)
        let mismatch =
            "invalid operation: \(text) (mismatched types \(leftName ?? "\(leftType)") and "
            + "\(rightName ?? "\(rightType)"))"
        let isEquality = operatorText == "==" || operatorText == "!="
        if isEquality || ["<", "<=", ">", ">="].contains(operatorText) {
            let together =
                leftType == rightType && (leftName == nil) == (rightName == nil)
                || (leftName == nil || leftType == .nilType) && (rightName == nil || rightType == .nilType)
                    && (isAssignable(leftType, to: rightType) || isAssignable(rightType, to: leftType))
                || leftName != nil && rightName != nil && isNumeric(leftType) && isNumeric(rightType)
            var fault: (position: GoSourcePosition, cause: String)?
            guard together else {
                guard isCase else { return GoDiagnostic(position: rightStart, message: mismatch) }
                return GoDiagnostic(
                    position: leftStart,
                    message: "invalid case \(spelling(of: left)) in switch on \(spelling(of: right)) "
                        + "(mismatched types \(leftName ?? "\(leftType)") and \(rightType))")
            }
            if isEquality {
                if leftType == .nilType || rightType == .nilType {
                    if leftType == rightType {
                        fault = (rightStart, "operator \(operatorText) not defined on untyped nil")
                    }
                } else if !isComparable(leftType) {
                    fault = (leftStart, incomparableCause(leftType))
                } else if !isComparable(rightType) {
                    fault = (rightStart, incomparableCause(rightType))
                }
            } else if !isOrdered(leftType) {
                fault = (leftStart, "operator \(operatorText) not defined on \(kindOrType(leftType))")
            } else if !isOrdered(rightType) {
                fault = (rightStart, "operator \(operatorText) not defined on \(kindOrType(rightType))")
            }
            return fault.map {
                isCase
                    ? GoDiagnostic(
                        position: leftStart,
                        message: "invalid case \(spelling(of: left)) in switch on "
                            + "\(spelling(of: right)) (\($0.cause))")
                    : GoDiagnostic(
                        position: $0.position, message: "invalid operation: \(text) (\($0.cause))")
            }
        }
        guard leftType == rightType, (leftName == nil) == (rightName == nil) || isNumeric(leftType)
        else { return GoDiagnostic(position: leftStart, message: mismatch) }
        let isDefined: Bool
        switch operatorText {
        case "+": isDefined = isNumeric(leftType) || isString(leftType)
        case "-", "*", "/": isDefined = isNumeric(leftType)
        case "&&", "||": isDefined = isBool(leftType)
        default: isDefined = isNumeric(leftType) && !isFloat(leftType)
        }
        if isDefined { return nil }
        return GoDiagnostic(
            position: leftStart,
            message: "invalid operation: operator \(operatorText) not defined on "
                + describe(left, ofType: leftType))
    }

    /// The same, or `fallback` at `position` where Go's rules find nothing
    /// that this checker refused.
    mutating func invalidBinary(
        _ left: GoExpression, _ operatorText: String, _ right: GoExpression,
        _ leftType: GoType, _ rightType: GoType, at position: GoSourcePosition,
        fallback: String
    ) -> GoDiagnostic {
        invalidBinary(left, operatorText, right, leftType, rightType, at: position)
            ?? GoDiagnostic(position: position, message: fallback)
    }

    /// Go's report of a unary operator applied to an operand it is not
    /// defined on, where the operand begins.
    mutating func undefinedOperator(
        _ operatorText: String, on operand: GoExpression, ofType type: GoType
    ) -> GoDiagnostic {
        if type == .void { return noValue(operand) }
        return GoDiagnostic(
            position: Self.start(of: operand, in: namePositions),
            message: "invalid operation: operator \(operatorText) not defined on "
                + describe(operand, ofType: type))
    }

    /// `invalid operation: <what> x (variable of type int)`, at the operand:
    /// Go's report of an operand that an operation cannot take.
    mutating func invalidOperand(
        _ what: String, _ operand: GoExpression, ofType type: GoType, suffix: String = ""
    ) -> GoDiagnostic {
        if type == .void { return noValue(operand) }
        return GoDiagnostic(
            position: Self.start(of: operand, in: namePositions),
            message: "invalid operation: \(what) \(describe(operand, ofType: type))\(suffix)")
    }

    /// Go's report of the shift `left operator right`: what is shifted is
    /// an integer, and the count is one that is not negative. Nil when
    /// those rules find nothing wrong.
    mutating func invalidShift(
        _ left: GoExpression, _ right: GoExpression, _ leftType: GoType, _ rightType: GoType
    ) -> GoDiagnostic? {
        if leftType == .void { return noValue(left) }
        if rightType == .void { return noValue(right) }
        let shifted = (try? constant(of: left)) ?? nil
        let isInteger =
            numericKind(leftType)?.isInteger == true && shifted?.type.map(isFloat) != true
            && (shifted == nil || shifted?.isUntyped == false || shifted?.value.isInteger == true)
        guard isInteger else {
            return invalidOperand("shifted operand", left, ofType: leftType, suffix: " must be integer")
        }
        if let count = (try? constant(of: right)) ?? nil {
            if count.value.isInteger, count.value.signum < 0 {
                return invalidOperand("negative shift count", right, ofType: rightType)
            }
            guard count.isUntyped, !count.value.isInteger else { return nil }
            return GoDiagnostic(
                position: Self.start(of: right, in: namePositions),
                message: "\(describe(right, ofType: rightType)) truncated to uint")
        }
        if numericKind(rightType)?.isInteger == true { return nil }
        if untypedName(of: right, ofType: rightType) != nil {
            return GoDiagnostic(
                position: Self.start(of: right, in: namePositions),
                message: "cannot convert \(describe(right, ofType: rightType)) to type uint")
        }
        return invalidOperand("shift count", right, ofType: rightType, suffix: " must be integer")
    }

    /// The type of a binary operator on two numbers, as the rules for
    /// numbers find it, with what they refuse reported as Go reports it.
    /// The operands were typed before this is called, so what is caught
    /// here is about this operator and its two operands alone.
    func checkedNumericBinaryType(
        _ expression: GoExpression, _ left: GoExpression, _ binaryOperator: GoBinaryOperator,
        _ right: GoExpression, _ leftType: GoType, _ rightType: GoType,
        _ position: GoSourcePosition
    ) throws -> GoType {
        do {
            return try numericBinaryType(
                expression, left, binaryOperator, right, leftType, rightType, position)
        } catch let diagnostic as GoDiagnostic {
            var reporter = self
            throw reporter.numericBinaryFailure(
                diagnostic, expression, left, GoSourceSpelling.text(of: binaryOperator), right,
                leftType, rightType, position)
        }
    }

    /// What Go says where the rules for numbers said `diagnostic` of
    /// `left operator right`.
    mutating func numericBinaryFailure(
        _ diagnostic: GoDiagnostic, _ expression: GoExpression, _ left: GoExpression,
        _ operatorText: String, _ right: GoExpression, _ leftType: GoType, _ rightType: GoType,
        _ position: GoSourcePosition
    ) -> GoDiagnostic {
        let message = diagnostic.message
        if message == "division by zero" {
            return GoDiagnostic(
                position: diagnostic.position, message: "invalid operation: division by zero")
        }
        if let failure = Self.unrepresentableConstant(in: diagnostic) {
            return unrepresentableOperand(
                diagnostic, failure, in: expression, left, leftType, right, rightType)
        }
        guard message.hasPrefix("mismatched types ") || message.hasPrefix("operator ") else {
            return diagnostic
        }
        return invalidBinary(left, operatorText, right, leftType, rightType, at: position)
            ?? diagnostic
    }

    /// Go's report of a constant operand that the type of the other
    /// operand cannot hold, `300 (untyped int constant) overflows int8`,
    /// and of a constant operation whose value its type cannot hold,
    /// `c * 2 (constant 200 of type int8) overflows int8`.
    mutating func unrepresentableOperand(
        _ diagnostic: GoDiagnostic, _ failure: (type: String, isTruncation: Bool),
        in expression: GoExpression, _ left: GoExpression, _ leftType: GoType,
        _ right: GoExpression, _ rightType: GoType
    ) -> GoDiagnostic {
        let verb = failure.isTruncation ? "truncated to" : "overflows"
        for (operand, type) in [(right, rightType), (left, leftType)]
        where diagnostic.position.offset == operand.startPosition.offset {
            // At the start of the operation, the operand that fits the
            // other's type is not the one that overflowed: the result did.
            if operand.startPosition.offset == expression.startPosition.offset,
                fits(operand, as: operand == left ? rightType : leftType)
            {
                continue
            }
            guard let constant = constantOperand(operand, ofType: type), constant.kind != nil,
                operand.startPosition.offset != expression.startPosition.offset
                    || untypedName(of: operand == left ? right : left, ofType: .int) == nil
            else { continue }
            return GoDiagnostic(
                position: Self.start(of: operand, in: namePositions),
                message: "\(describe(operand, ofType: type)) \(verb) \(basicName(failure.type))")
        }
        guard diagnostic.position.offset == expression.startPosition.offset,
            let value = Self.text(after: "constant ", in: diagnostic.message)?
                .split(separator: " ").first
        else { return diagnostic }
        return GoDiagnostic(
            position: diagnostic.position,
            message: "\(spelling(of: expression)) (constant \(value) of "
                + "\(basicPhrase(failure.type))) \(verb) \(basicName(failure.type))")
    }

    /// The type Go names where a constant does not fit a type: the basic
    /// type underneath a defined one, `int64` for `time.Duration`.
    func basicName(_ name: String) -> String {
        guard let kind = namedKind(.named(name)), GoNumericKind(typeName: kind) != nil else {
            return name
        }
        switch kind {
        case "byte": return "uint8"
        case "rune": return "int32"
        default: return kind
        }
    }

    /// `type int8`, or `int64 type time.Duration` for a defined type.
    func basicPhrase(_ name: String) -> String {
        let basic = basicName(name)
        return basic == name ? "type \(name)" : "\(basic) type \(name)"
    }

    /// Whether `operand` is an untyped constant that is a value of `type`.
    func fits(_ operand: GoExpression, as type: GoType) -> Bool {
        guard let value = (try? constant(of: operand)) ?? nil, value.isUntyped else { return false }
        return (try? converted(value, to: type, at: operand.startPosition)) != nil
    }
}

extension GoCompoundAssignment {
    /// Where the parser notes, among the name positions of a file, that the
    /// operator at `position` is that of a compound assignment: at an
    /// offset no token and no literal's end has.
    static func key(of position: GoSourcePosition) -> Int {
        -1_000_000_000 - position.offset
    }
}

extension FunctionChecker {
    /// Go's report of a bitwise operator or a shift that the checker
    /// refused for its operands.
    mutating func bitwiseMistake(
        _ bitwiseOperator: GoBitwiseOperator, _ operands: [GoExpression], _ leftType: GoType,
        _ rightType: GoType, at position: GoSourcePosition
    ) -> GoDiagnostic {
        let fallback = GoDiagnostic(
            position: position,
            message: "invalid operation: operator \(bitwiseOperator.spelling) requires integer operands")
        if bitwiseOperator.isShift {
            return invalidShift(operands[0], operands[1], leftType, rightType) ?? fallback
        }
        return invalidBinary(
            operands[0], bitwiseOperator.spelling, operands[1], leftType, rightType, at: position)
            ?? fallback
    }

    /// Go's report of the binary operation `expression`, which the checker
    /// refused with `fallback`.
    mutating func binaryFailure(_ expression: GoExpression, _ fallback: String) -> GoDiagnostic {
        guard case .binary(let left, let binaryOperator, let right, let position) = expression,
            let leftType = probedType(of: left), let rightType = probedType(of: right)
        else { return GoDiagnostic(position: expression.position, message: fallback) }
        return invalidBinary(
            left, GoSourceSpelling.text(of: binaryOperator), right, leftType, rightType,
            at: position, fallback: fallback)
    }

    /// Go's report of `&operand` where the operand has no address.
    mutating func unaddressable(_ operand: GoExpression) -> GoDiagnostic {
        guard let operandType = probedType(of: operand) else {
            return GoDiagnostic(
                position: Self.start(of: operand, in: namePositions),
                message: "invalid operation: cannot take address of \(spelling(of: operand))")
        }
        return invalidOperand("cannot take address of", operand, ofType: operandType)
    }

    /// Go's report of `base[index]` where `base` is nothing an index
    /// selects from. It is reported at the `[`.
    mutating func unindexable(_ base: GoExpression, at position: GoSourcePosition) -> GoDiagnostic {
        guard let baseType = probedType(of: base) else {
            return GoDiagnostic(position: position, message: "invalid operation: cannot index expression")
        }
        if baseType == .void { return noValue(base) }
        return GoDiagnostic(
            position: position,
            message: "invalid operation: cannot index \(describe(base, ofType: baseType))")
    }

    /// The type of `base.(assertedType)`: `base` is a value of an interface
    /// type.
    mutating func typeOfAssertion(
        _ base: GoExpression, to assertedType: GoTypeExpression
    ) throws -> GoType {
        let baseType = try type(of: base)
        guard case .interface = underlying(baseType) else {
            if baseType == .void { throw noValue(base) }
            throw GoDiagnostic(
                position: Self.start(of: base, in: namePositions),
                message: "invalid operation: \(describe(base, ofType: baseType)) is not an interface")
        }
        return try declaredType(assertedType)
    }
}

// MARK: - Builtins, indexes, and selections

extension FunctionChecker {
    /// `invalid argument: x (variable of type int) <what>`, at the argument.
    mutating func invalidArgument(_ argument: GoExpression, _ what: String) -> GoDiagnostic {
        let position = Self.start(of: argument, in: namePositions)
        guard let described = describe(argument) else {
            return GoDiagnostic(position: position, message: "invalid argument: \(what)")
        }
        return GoDiagnostic(position: position, message: "invalid argument: \(described) \(what)")
    }

    /// Go's report of an index, a bound of a slice expression, or a size
    /// given to `make` that is no integer: a constant that cannot become
    /// an `int`, or a value of another type.
    mutating func nonIntegerIndex(_ index: GoExpression) -> GoDiagnostic {
        let position = Self.start(of: index, in: namePositions)
        guard let type = probedType(of: index) else {
            return GoDiagnostic(position: position, message: "invalid argument: index must be integer")
        }
        if type == .void { return noValue(index) }
        let described = describe(index, ofType: type)
        if untypedName(of: index, ofType: type) != nil {
            return GoDiagnostic(position: position, message: "cannot convert \(described) to type int")
        }
        return GoDiagnostic(
            position: position, message: "invalid argument: index \(described) must be integer")
    }

    /// `make` takes its type and, for a slice, a length and maybe a
    /// capacity; for a map or a channel, maybe a size.
    func requireMakeArguments(
        _ allowed: ClosedRange<Int>, _ arguments: [GoExpression], at position: GoSourcePosition
    ) throws {
        guard !allowed.contains(arguments.count) else { return }
        let call = "make(" + argumentList(arguments) + ")"
        throw GoDiagnostic(
            position: position,
            message: "invalid operation: \(call) expects \(allowed.lowerBound) or "
                + "\(allowed.upperBound) arguments; found \(arguments.count)")
    }

    /// Go's report of a `copy` whose arguments are not two slices of one
    /// element type, or a slice of bytes and a string.
    mutating func uncopyable(
        _ destination: GoExpression, _ destinationType: GoType, _ source: GoExpression,
        _ sourceType: GoType
    ) -> GoDiagnostic {
        let position = Self.start(of: destination, in: namePositions)
        let operands =
            "\(describe(destination, ofType: destinationType)) and "
            + describe(source, ofType: sourceType)
        // A string is a source of bytes.
        let bytes: GoType = isString(sourceType) ? .slice(GoPredeclared.byte) : sourceType
        guard case .slice(let element) = underlying(destinationType),
            case .slice(let other) = underlying(bytes)
        else {
            return GoDiagnostic(
                position: position,
                message: "invalid argument: copy expects slice arguments; found \(operands)")
        }
        return GoDiagnostic(
            position: position,
            message: "invalid argument: arguments to copy \(operands) have different element "
                + "types \(element) and \(other)")
    }

    /// Go's report of `base.name` where a value of `baseType` has no such
    /// field or method: `x.f undefined (type T has no field or method f)`,
    /// with a field or a method of the same name in other capitals when
    /// there is one. It is reported where the name is.
    mutating func undefinedSelection(
        _ name: String, of base: GoExpression, ofType baseType: GoType,
        at position: GoSourcePosition
    ) -> GoDiagnostic {
        if baseType == .void { return noValue(base) }
        let selection = "\(base.spelledAsOperand(in: namePositions)).\(name)"
        if case .pointer(let pointee) = baseType, isInterface(pointee) {
            return GoDiagnostic(
                position: position,
                message: "\(selection) undefined (type \(baseType) is pointer to interface, "
                    + "not interface)")
        }
        var why =
            "type \(operandTypeName(base, ofType: baseType)) has no field or method \(name)"
        if let other = otherSpelling(of: name, in: baseType) {
            // What another package keeps to itself is said to be so.
            let hidden = isHidden(other.name, in: baseType) ? "unexported " : ""
            why += ", but does have \(hidden)\(other.kind) \(other.name)"
        }
        return GoDiagnostic(position: position, message: "\(selection) undefined (\(why))")
    }

    /// The field or method of a value of `type` whose name is `name` in
    /// other capitals.
    func otherSpelling(of name: String, in type: GoType) -> (kind: String, name: String)? {
        let folded = name.lowercased()
        if let field = structFields(of: type)?.first(where: {
            $0.name != name && $0.name.lowercased() == folded
        }) {
            return ("field", field.name)
        }
        if case .interface(let methods) = underlying(type),
            let method = methods.first(where: { $0.name != name && $0.name.lowercased() == folded })
        {
            return ("method", method.name)
        }
        if let method = otherSpelling(ofMethod: name, in: type) { return ("method", method) }
        // A type of the library says what methods it has only when asked
        // for one by its name.
        guard let first = name.first else { return nil }
        for candidate in [first.uppercased() + name.dropFirst(), first.lowercased() + name.dropFirst()]
        where candidate != name {
            if GoLibraryTypes.method(of: type, named: candidate) != nil
                || GoStandardLibrary.method(of: type, named: candidate) != nil
                || GoLibraryValue.method(of: type, named: candidate) != nil
            {
                return ("method", candidate)
            }
        }
        return nil
    }
}

extension FunctionChecker {
    /// Go's report of a conversion `T()` or `T(x, y)`: it takes one value.
    /// The first is reported where the conversion begins, the second at the
    /// first value too many.
    func conversionCountMismatch(
        to target: GoType, callee: GoExpression, arguments: [GoExpression],
        position: GoSourcePosition
    ) -> GoDiagnostic {
        guard arguments.count > 1 else {
            return GoDiagnostic(
                position: namePositions[position.offset]?.first
                    ?? Self.start(of: callee, in: namePositions),
                message: "missing argument in conversion to \(target)")
        }
        return GoDiagnostic(
            position: Self.start(of: arguments[1], in: namePositions),
            message: "too many arguments in conversion to \(target)")
    }
}

// MARK: - Assignments, declarations, and returns

extension FunctionChecker {
    /// Whether the declaration of one name at `position` is a `:=`: the
    /// parser noted where its operator is beside where its name is.
    func isShortDeclaration(at position: GoSourcePosition) -> Bool {
        namePositions[position.offset]?.count == 2
    }

    /// One variable takes one value. Of a call of several results Go says
    /// that the numbers do not match where the variable is assigned, `x :=
    /// f()` and `x = f()`, and that the call is no single value where it is
    /// declared with `var`.
    mutating func requireOneValue(_ expression: GoExpression, assigned: Bool) throws {
        guard case .call(let callee, let arguments, let position) = expression,
            severalResults(of: expression) != nil
        else { return }
        // What is wrong with the call itself comes first when it is where
        // the call begins, and after the count that does not match when it
        // is further on: Go reports both, in the order of the source.
        let results: [GoType]
        do {
            results = try callResultTypes(callee: callee, arguments: arguments, position: position)
        } catch let diagnostic as GoDiagnostic {
            guard assigned, let known = severalResults(of: expression),
                diagnostic.position.path == position.path,
                diagnostic.position.offset > Self.start(of: expression, in: namePositions).offset
            else { throw diagnostic }
            throw resultCountMismatch(variables: 1, call: expression, results: known.count)
        }
        guard results.count > 1 else { return }
        throw assigned
            ? resultCountMismatch(variables: 1, call: expression, results: results.count)
            : severalValues(expression, results: results)
    }

    /// Go's report of a call that gives another number of values than
    /// there are variables for: `assignment mismatch: 2 variables but f
    /// returns 1 value`, where the call begins.
    func resultCountMismatch(
        variables: Int, call: GoExpression, results: Int
    ) -> GoDiagnostic {
        guard results > 0, case .call(let callee, _, _) = call else { return noValue(call) }
        return GoDiagnostic(
            position: Self.start(of: call, in: namePositions),
            message: "assignment mismatch: \(variables) variable\(variables == 1 ? "" : "s") but "
                + "\(calleeSpelling(callee)) returns \(results) value\(results == 1 ? "" : "s")")
    }

    /// Go's report of a list of values that is not as long as the list of
    /// variables it is assigned to, where the values begin. What is wrong
    /// with a value comes first.
    mutating func countMismatch(variables: Int, values: [GoExpression]) throws -> GoDiagnostic {
        if values.count == 1, case .call(let callee, let arguments, let position) = values[0],
            !(try isOperatorOrConversion(values[0]))
        {
            let results = try callResultTypes(
                callee: callee, arguments: arguments, position: position)
            return resultCountMismatch(variables: variables, call: values[0], results: results.count)
        }
        for value in values {
            if try type(of: value) == .void { return noValue(value) }
        }
        return GoDiagnostic(
            position: values.first.map { Self.start(of: $0, in: namePositions) }
                ?? syntheticPosition(),
            message: Self.mismatch(variables: variables, values: values.count))
    }

    /// Go's report of a `var` or a `const` with more values than names, at
    /// the first value too many, or with fewer, at the first name without
    /// one. One value for several variables may be a call, and is counted
    /// as such.
    mutating func arityMismatch(
        _ names: [String], values: [GoExpression], isConstant: Bool, position: GoSourcePosition
    ) throws -> GoDiagnostic {
        if names.count < values.count {
            let extra = values[names.count]
            return GoDiagnostic(
                position: Self.start(of: extra, in: namePositions),
                message: "extra init expr \(spelling(of: extra))")
        }
        guard isConstant || values.count != 1 else {
            return try countMismatch(variables: names.count, values: values)
        }
        let places = namePositions[position.offset] ?? []
        return GoDiagnostic(
            position: values.count < places.count ? places[values.count] : position,
            message: "missing init expr for \(names[values.count])")
    }

    /// Go's report of a `return` with too few or too many values, with
    /// what it has and what the function wants: at the first value too
    /// many, at the last of too few, and at the `return` without any.
    mutating func returnCountMismatch(
        _ values: [GoExpression], at position: GoSourcePosition
    ) throws -> GoDiagnostic {
        var have: [String] = []
        for value in values {
            let valueType = try type(of: value)
            if valueType == .void { return noValue(value) }
            have.append(summaryName(value, ofType: valueType))
        }
        let isTooMany = values.count > expectedResults.count
        var place = position
        if isTooMany {
            place = Self.start(of: values[expectedResults.count], in: namePositions)
        } else if let last = values.last {
            place = Self.start(of: last, in: namePositions)
        }
        return GoDiagnostic(
            position: place,
            message: "\(isTooMany ? "too many" : "not enough") return values\n\thave "
                + "(\(have.joined(separator: ", ")))\n\twant \(Self.summary(of: expectedResults))")
    }

    /// The same for `return f()`, which returns the `results` of the call.
    func returnCountMismatch(of call: GoExpression, results: [GoType]) -> GoDiagnostic {
        if results.isEmpty { return noValue(call) }
        let isTooMany = results.count > expectedResults.count
        return GoDiagnostic(
            position: Self.start(of: call, in: namePositions),
            message: "\(isTooMany ? "too many" : "not enough") return values\n\thave "
                + "\(Self.summary(of: results))\n\twant \(Self.summary(of: expectedResults))")
    }

    /// Go's report of a declaration whose value has no type to give its
    /// name: a call without a result, or `nil`.
    func valueless(
        _ expression: GoExpression?, ofType type: GoType, isConstant: Bool,
        at position: GoSourcePosition
    ) -> GoDiagnostic {
        guard let expression else {
            return GoDiagnostic(position: position, message: "missing type in declaration")
        }
        if type == .void { return noValue(expression) }
        let place = Self.start(of: expression, in: namePositions)
        if isConstant { return GoDiagnostic(position: place, message: "nil is not constant") }
        return GoDiagnostic(
            position: place,
            message: "use of untyped nil in "
                + (isShortDeclaration(at: position) ? "assignment" : "variable declaration"))
    }

    /// Checks the statements a `:=` that reuses a variable stands for: the
    /// declaration of a stand-in for each reused name, then the assignment
    /// of each to its variable. A value that is none of the variable's type
    /// is reported as a result of `expression`, which is what the source
    /// assigns.
    mutating func checkRedeclaration(
        _ statements: [GoStatement], of expression: GoExpression
    ) throws {
        for statement in statements {
            do {
                try check(statement)
            } catch let diagnostic as GoDiagnostic {
                guard case .assignment(let target, .identifier(let standIn, _), _) = statement,
                    diagnostic.message.hasPrefix("cannot use " + standIn),
                    let found = lookup(standIn)?.type,
                    let wanted = try? assignableType(of: target, asTarget: true)
                else { throw diagnostic }
                throw cannotUseResult(of: expression, type: found, as: wanted, in: "assignment")
            }
        }
    }
}

// MARK: - Declarations

extension GoDiagnostic {
    /// Go's report of a name declared twice in one block, at the second
    /// declaration, with a line that says where the first is:
    ///
    ///     x redeclared in this block
    ///         main.go:5:5: other declaration of x
    ///
    /// A field of a struct is not in a block, and is said to be only
    /// `redeclared`.
    static func redeclared(
        _ name: String, at position: GoSourcePosition, other: GoSourcePosition?,
        inBlock: Bool = true
    ) -> GoDiagnostic {
        var message = name + " redeclared" + (inBlock ? " in this block" : "")
        if let other { message += "\n\t" + place(other) + ": other declaration of \(name)" }
        return GoDiagnostic(position: position, message: message)
    }

    /// A position as a line that continues a message names it.
    static func place(_ position: GoSourcePosition) -> String {
        "\(position.path):\(position.line):\(position.column)"
    }
}

// MARK: - Statements

extension FunctionChecker {
    /// Notes the constant a declaration declares, as the rules for numbers
    /// do, and reports a constant that the type it takes cannot hold as Go
    /// reports it where a value is given to a variable.
    mutating func noteChecked(
        _ name: String, declared: GoType?, expression: GoExpression?, isConstant: Bool,
        position: GoSourcePosition
    ) throws {
        do {
            try noteDeclaration(
                name, declared: declared, expression: expression, isConstant: isConstant,
                position: position)
        } catch let diagnostic as GoDiagnostic {
            guard let expression, !isConstant, declared == nil,
                let actual = probedType(of: expression),
                let report = unrepresentable(
                    diagnostic, expression, ofType: actual,
                    in: isShortDeclaration(at: position) ? "assignment" : "variable declaration")
            else { throw diagnostic }
            throw report
        }
    }

    /// Go's report of what `defer` or `go` is given when it is no call of a
    /// function: a conversion, something in parentheses, or any other
    /// expression. It is reported where the expression begins.
    mutating func uncallableStatement(
        _ expression: GoExpression, after keyword: String
    ) throws -> GoDiagnostic {
        let position = Self.start(of: expression, in: namePositions)
        if namePositions[GoParenthesized.key(of: expression.position)] != nil {
            return GoDiagnostic(
                position: position, message: "expression in \(keyword) must not be parenthesized")
        }
        if case .call(let callee, _, _) = expression, try conversionTarget(callee) != nil {
            let described = describe(expression, ofType: try type(of: expression))
            return GoDiagnostic(
                position: position,
                message: "\(keyword) requires function call, not conversion \(described)")
        }
        return GoDiagnostic(
            position: position, message: "expression in \(keyword) must be function call")
    }

    /// Go's report of an expression that is a statement and does nothing:
    /// `x (variable of type int) is not used`, where it begins.
    mutating func unused(_ expression: GoExpression) throws -> GoDiagnostic {
        let type = try type(of: expression)
        return GoDiagnostic(
            position: Self.start(of: expression, in: namePositions),
            message: "\(describe(expression, ofType: type)) is not used")
    }

    /// Go's report of a `range` over what has no elements to give.
    mutating func unrangeable(
        _ collection: GoExpression, ofType type: GoType, why: String
    ) -> GoDiagnostic {
        if type == .void { return noValue(collection) }
        return GoDiagnostic(
            position: Self.start(of: collection, in: namePositions),
            message: "cannot range over \(describe(collection, ofType: type))\(why)")
    }

    /// Go's report of a case that does not compare with what its switch is
    /// on. A switch without an expression is one on `true`.
    mutating func invalidCase(
        _ expression: GoExpression, _ type: GoType, switched: GoExpression?, _ switchType: GoType,
        fallback: String
    ) -> GoDiagnostic {
        let tag = switched ?? .identifier("true", position: expression.position)
        return invalidBinary(expression, "==", tag, type, switchType, at: expression.position, isCase: true)
            ?? GoDiagnostic(
                position: Self.start(of: expression, in: namePositions), message: fallback)
    }

    /// Go's report of a constant that is a case of a switch twice, with
    /// where it was a case before. The constant has the type of what is
    /// switched on.
    func duplicateCase(
        _ expression: GoExpression, of switchType: GoType, at position: GoSourcePosition,
        after previous: GoSourcePosition
    ) -> GoDiagnostic {
        let text = spelling(of: expression)
        let value = constantOperand(expression, ofType: switchType)?.value
        let shown = value.flatMap { $0 == text ? nil : " " + $0 } ?? ""
        return GoDiagnostic(
            position: position,
            message: "duplicate case \(text) (constant\(shown) of \(typePhrase(switchType))) in "
                + "expression switch\n\t\(GoDiagnostic.place(previous)): previous case")
    }

    /// Go's report of a type in a type switch that no value of the
    /// interface switched on can have, and what it lacks.
    mutating func impossibleCase(
        _ spelled: String, _ type: GoType, of operand: GoExpression, ofType operandType: GoType,
        at position: GoSourcePosition
    ) -> GoDiagnostic {
        var message = "impossible type switch case: \(spelled)"
        if case .interface(let methods) = underlying(operandType),
            let cause = missingMethodCause(of: type, methods: methods)
        {
            message += "\n\t\(describe(operand, ofType: operandType)) cannot have dynamic type "
                + "\(type) \(cause)"
        }
        return GoDiagnostic(position: position, message: message)
    }

    /// Go's report of what an assignment cannot store a value in.
    func unassignable(_ expression: GoExpression) -> GoDiagnostic {
        GoDiagnostic(
            position: Self.start(of: expression, in: namePositions),
            message: "cannot assign to \(spelling(of: expression)) "
                + "(neither addressable nor a map index expression)")
    }

    /// Go's report of a name on the left of an assignment that is no
    /// variable: a function, `nil`, `true`, a builtin, or nothing at all.
    func unassignableName(_ name: String, at position: GoSourcePosition) -> GoDiagnostic {
        if name == "nil" || name == "true" || name == "false" || functionSignatures[name] != nil {
            return unassignable(.identifier(name, position: position))
        }
        let builtins = [
            "len", "cap", "append", "make", "new", "panic", "recover", "delete", "copy", "close",
            "min", "max", "clear", "print", "println",
        ]
        if builtins.contains(name) {
            return GoDiagnostic(position: position, message: "\(name) (built-in) must be called")
        }
        return GoDiagnostic(position: position, message: Self.undeclaredMessage(name))
    }
}

extension GoDiagnostic {
    /// Go's report of a method declared on a type the package does not
    /// declare: a predeclared one, or none at all.
    static func unknownReceiver(_ name: String, at position: GoSourcePosition) -> GoDiagnostic {
        let isPredeclared =
            ["int", "string", "bool", "error", "any", "byte", "rune"].contains(name)
            || GoPredeclared.numericType(name) != nil
        return GoDiagnostic(
            position: position,
            message: isPredeclared
                ? "cannot define new methods on non-local type \(name)" : "undefined: \(name)")
    }

    /// Go's report of a type no declaration has. A name of a package that
    /// is unknown there, `fmt.Bar`, is reported where the name is; a
    /// selection from what is no package, by what it selects from.
    static func undefinedType(_ name: String, at position: GoSourcePosition) -> GoDiagnostic {
        guard let dot = name.firstIndex(of: "."), !name.contains("/"),
            !name.contains(GoLocalTypes.marker)
        else { return GoDiagnostic(position: position, message: "undefined: \(name)") }
        let qualifier = String(name[..<dot])
        guard GoStandardLibrary.supportedPackages.contains(where: {
            GoImportName.defaultName(ofPath: $0) == qualifier
        }) else {
            return GoDiagnostic(position: position, message: "undefined: \(qualifier)")
        }
        let shift = qualifier.utf8.count + 1
        return GoDiagnostic(
            position: GoSourcePosition(
                path: position.path, offset: position.offset + shift, line: position.line,
                column: position.column + shift),
            message: "undefined: \(name)")
    }
}

extension FunctionChecker {
    /// The type of what `target` names, where an assignment stores a value
    /// in it. What cannot be stored in is reported as Go reports it, by
    /// the whole target: `cannot assign to f().a`, though it is `f()` that
    /// has no address. `isRead` is for `x++`, which reads its target too.
    mutating func targetType(of target: GoExpression, isRead: Bool = false) throws -> GoType {
        try refuseFieldOfMapElement(target)
        do {
            return try assignableType(of: target, asTarget: !isRead)
        } catch let diagnostic as GoDiagnostic {
            guard diagnostic.message.hasPrefix("cannot assign to "),
                diagnostic.message.hasSuffix("(neither addressable nor a map index expression)")
            else { throw diagnostic }
            throw unassignable(target)
        }
    }

    /// The type of the variable `operand` names, where `&operand` takes
    /// its address. A constant, a function, and anything else that is no
    /// variable has none.
    mutating func addressedType(of operand: GoExpression) throws -> GoType {
        do {
            return try assignableType(of: operand)
        } catch let diagnostic as GoDiagnostic {
            guard diagnostic.message.hasPrefix("cannot assign to ") else { throw diagnostic }
            throw unaddressable(operand)
        }
    }
}

extension FunctionChecker {
    /// The type the operands of a bitwise operator share, as the rules for
    /// numbers find it, with what they refuse reported as Go reports it.
    func checkedBitwiseOperandType(
        _ bitwiseOperator: GoBitwiseOperator, _ operands: [GoExpression], _ leftType: GoType,
        _ rightType: GoType, at position: GoSourcePosition
    ) throws -> GoType {
        do {
            return try commonNumericType(
                operands[0], leftType, operands[1], rightType, at: position)
        } catch let diagnostic as GoDiagnostic {
            var reporter = self
            throw reporter.numericBinaryFailure(
                diagnostic, .bitwise(bitwiseOperator, operands: operands, position: position),
                operands[0], bitwiseOperator.spelling, operands[1], leftType, rightType, position)
        }
    }

    /// The type of `+x` or `-x` for a number, with a constant its type
    /// cannot hold reported as Go reports it: `-k (constant -3 of type
    /// uint) overflows uint`.
    func checkedNumericUnaryType(
        _ expression: GoExpression, operandType: GoType
    ) throws -> GoType? {
        do {
            return try numericUnaryType(expression, operandType: operandType)
        } catch let diagnostic as GoDiagnostic {
            guard let failure = Self.unrepresentableConstant(in: diagnostic),
                diagnostic.position.offset == expression.startPosition.offset,
                let value = Self.text(after: "constant ", in: diagnostic.message)?
                    .split(separator: " ").first
            else { throw diagnostic }
            throw GoDiagnostic(
                position: diagnostic.position,
                message: "\(spelling(of: expression)) (constant \(value) of "
                    + "\(basicPhrase(failure.type))) "
                    + "\(failure.isTruncation ? "truncated to" : "overflows") \(basicName(failure.type))")
        }
    }
}

/// The names a declaration gives the parameters and results of a function.
final class GoSignatureNames: Sendable {
    let parameters: [String]
    let results: [String?]

    init(parameters: [String], results: [String?]) {
        self.parameters = parameters
        self.results = results
    }

    /// The type of the function as Go prints it: each parameter with its
    /// name, and the results in parentheses when they have names. A
    /// parameter without a name is kept as a blank one; a list of nothing
    /// but those is taken for the one without names.
    func spelling(parameters types: [GoType], results resultTypes: [GoType]) -> String {
        let isNamed = !parameters.allSatisfy { $0 == GoValueList.blank }
        var text = "func("
            + zip(parameters, types).map { isNamed ? "\($0) \($1)" : "\($1)" }
            .joined(separator: ", ") + ")"
        let named = zip(results, resultTypes).compactMap { name, type in name.map { "\($0) \(type)" } }
        if !named.isEmpty, named.count == resultTypes.count {
            text += " (" + named.joined(separator: ", ") + ")"
        } else if resultTypes.count == 1 {
            text += " \(resultTypes[0])"
        } else if !resultTypes.isEmpty {
            text += " (" + resultTypes.map(\.description).joined(separator: ", ") + ")"
        }
        return text
    }
}
