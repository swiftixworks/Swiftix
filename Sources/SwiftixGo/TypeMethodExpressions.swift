/// Method expressions of interface types and of types of the run-time
/// library: `I.m`, `error.Error`, `time.Duration.String`, `(*time.Time).Year`.
///
/// A method expression of a type of the program is the method itself (see
/// `GoMethodExpression`). These have no function of the program to name, so
/// the value names a function the compiler synthesizes, which takes the
/// receiver first: for an interface the one a method value of an interface
/// calls through (`interfaceMethodFunction`), which finds the method of
/// whatever the interface holds; for a library type the one a method value
/// of that type calls through (`libraryValueFunction`), whose body is the
/// call `receiver.m(arguments)` lowered as a call the program wrote. Nothing
/// that compiled before is compiled differently: each of these was refused.
extension GoMethodExpression {
    /// The type expression `base` is when it is written the way a method
    /// expression names its type: `T`, `pkg.T`, `*T`, or `*pkg.T`. The caller
    /// knows whether the names are types.
    static func receiverTypeExpression(of base: GoExpression) -> GoTypeExpression? {
        switch base {
        case .identifier(let name, let position):
            return .named(name, position: position)
        case .selector(.identifier(let package, _), let member, let position):
            return .named(package + "." + member, position: position)
        case .unary(.dereference, let operand, let position):
            return receiverTypeExpression(of: operand).map { .pointer(pointee: $0, position: position) }
        case .typeExpression(let type, _):
            // An alias of a type of the library, which has no name.
            return type
        default:
            return nil
        }
    }

    /// The name in `base` that must not be a value for it to name a type:
    /// the type's name, or the package's. Nil when `base` is a type as it
    /// is written, and "" when it names none.
    static func leadingName(of base: GoExpression, _ expression: GoTypeExpression) -> String? {
        if case .typeExpression = base.dereferenced { return nil }
        return leadingName(of: expression) ?? ""
    }

    /// Whether `base` is a type as it is written, `T` or `*T` where an
    /// alias stands for a type of the library: no receiver of a call.
    static func isWrittenType(_ base: GoExpression) -> Bool {
        if case .typeExpression = base.dereferenced { return true }
        return false
    }

    /// The names of `type expression` that must not be values for it to
    /// be a type: the type's name, or the package's.
    static func leadingName(of expression: GoTypeExpression) -> String? {
        switch expression {
        case .named(let name, _):
            return String(name.split(separator: ".", maxSplits: 1).first ?? Substring(name))
        case .pointer(let pointee, _):
            return leadingName(of: pointee)
        default:
            return nil
        }
    }

    /// Whether the methods of the library type `typeName` are all of its
    /// pointer, as those of a type that must not be copied are.
    static func takesPointer(_ typeName: String) -> Bool {
        switch typeName {
        case GoLibraryStructs.mutexName, "sync.WaitGroup", "time.Location": return true
        default: return GoLibraryStructs.isStruct(typeName)
        }
    }

    /// `typeName` as Go 1.24 writes a type in an invalid method expression:
    /// with the path of its package quoted when another package of the
    /// standard library has the same name (`internal/sync`,
    /// `internal/runtime/atomic`).
    static func qualified(_ typeName: String) -> String {
        if typeName.hasPrefix("sync.") { return "\"sync\"" + typeName.dropFirst(4) }
        if typeName.hasPrefix("atomic.") { return "\"sync/atomic\"" + typeName.dropFirst(6) }
        if typeName.hasPrefix("sync/atomic.") {
            return "\"sync/atomic\"" + typeName.dropFirst(11)
        }
        return typeName
    }

    /// The method `name` of an interface type, or of a type of the library,
    /// as a function that takes the receiver first. `underlying` is what
    /// the receiver is underneath; nil when it is neither kind of type.
    static func signature(
        of receiver: GoType, underlying: GoType, named name: String, isProgramType: Bool
    ) -> (parameters: [GoType], results: [GoType], isInterface: Bool)? {
        if case .interface(let methods) = underlying {
            guard let method = methods.first(where: { $0.name == name }),
                name != GoFunctionType.methodName
            else { return nil }
            return ([receiver] + method.parameters, method.results, true)
        }
        guard !isProgramType else { return nil }
        // A pointer's method set has the methods of what it points to.
        var found = GoLibraryValue.method(of: receiver, named: name)
        if found == nil, case .pointer(let pointee) = receiver {
            found = GoLibraryValue.method(of: pointee, named: name)
        }
        guard let method = found else { return nil }
        return ([receiver] + method.parameters, method.results, false)
    }
}

extension FunctionChecker {
    /// The type of `T.m` when `T` is an interface type or a type of the
    /// run-time library; nil when `base` names neither. A method a type of
    /// the library does not have, or has only for a pointer, is reported as
    /// Go reports it, at `position`.
    func typeMethodExpressionType(
        base: GoExpression, name: String, position: GoSourcePosition
    ) throws -> GoType? {
        guard let receiver = typeMethodExpressionReceiver(base) else { return nil }
        let pointee: GoType
        if case .pointer(let inner) = receiver { pointee = inner } else { pointee = receiver }
        guard case .named(let typeName) = pointee, typeDefinitions[typeName] == nil,
            !isInterface(pointee)
        else {
            // An interface, or a type of the program, which has its own rules.
            guard
                let method = GoMethodExpression.signature(
                    of: receiver, underlying: underlying(receiver), named: name,
                    isProgramType: true)
            else { return nil }
            return .function(parameters: method.parameters, results: method.results)
        }
        let isPointer = receiver != pointee
        let spelling = GoMethodExpression.spelling((typeName, isPointer), name)
        let quoted = GoMethodExpression.qualified(typeName)
        let needsPointer =
            "invalid method expression \(quoted).\(name) (needs pointer receiver (*\(quoted)).\(name))"
        guard
            let method = GoMethodExpression.signature(
                of: receiver, underlying: underlying(receiver), named: name,
                isProgramType: false)
        else {
            if !isPointer, GoLibraryValue.method(of: .pointer(receiver), named: name) != nil {
                throw GoDiagnostic(position: position, message: needsPointer)
            }
            throw GoDiagnostic(
                position: position,
                message: "\(spelling) undefined (type \(isPointer ? "*" : "")\(typeName) has no "
                    + "field or method \(name))")
        }
        if !isPointer, GoMethodExpression.takesPointer(typeName) {
            throw GoDiagnostic(position: position, message: needsPointer)
        }
        return .function(parameters: method.parameters, results: method.results)
    }

    /// The type `base` names when it is written as a method expression
    /// names one and nothing of the program makes it a value.
    func typeMethodExpressionReceiver(_ base: GoExpression) -> GoType? {
        guard let expression = GoMethodExpression.receiverTypeExpression(of: base) else {
            return nil
        }
        if let leading = GoMethodExpression.leadingName(of: base, expression) {
            guard !leading.isEmpty, lookup(leading) == nil, functionSignatures[leading] == nil
            else { return nil }
        }
        if case .selector(.identifier(let package, _), _, _) = base.dereferenced,
            importedPackage(named: .identifier(package, position: base.position)) == nil
        {
            return nil
        }
        return try? declaredType(expression)
    }
}

extension IRLowerer {
    /// The receiver type and the signature of `T.m` when `T` is an
    /// interface type or a type of the run-time library.
    func typeMethodExpression(
        base: GoExpression, name: String
    ) -> (parameters: [GoType], results: [GoType], isInterface: Bool)? {
        guard let expression = GoMethodExpression.receiverTypeExpression(of: base) else {
            return nil
        }
        if let leading = GoMethodExpression.leadingName(of: base, expression) {
            guard !leading.isEmpty, lookup(leading) == nil, globalInfos[leading] == nil,
                functionReturnCounts[leading] == nil, functionParameterTypes[leading] == nil
            else { return nil }
        }
        let receiver = resolve(expression)
        let pointee: GoType
        if case .pointer(let inner) = receiver { pointee = inner } else { pointee = receiver }
        let isProgramType: Bool
        switch pointee {
        case .named(let typeName):
            // A name that is no type is a variable of an enclosing block
            // the checker has seen; only a known type gets this far.
            isProgramType = typeDefinitions[typeName] != nil
            // A name of the library is one an alias stands for
            // (`time.Time`); any other name that is no type of the program
            // is none of a type that has methods.
            if !isProgramType, case .identifier(let only, _) = base.dereferenced,
                only != "error", !only.contains(".")
            {
                return nil
            }
        case .interface:
            isProgramType = true
        default:
            return nil
        }
        return GoMethodExpression.signature(
            of: receiver, underlying: underlying(receiver), named: name,
            isProgramType: isProgramType)
    }

    /// `T.m` as a value when `T` is an interface type or a type of the
    /// run-time library; nil when it is anything else.
    mutating func lowerTypeMethodExpression(base: GoExpression, name: String) throws -> Int? {
        guard let method = typeMethodExpression(base: base, name: name) else { return nil }
        if method.isInterface {
            return functionValue(
                symbol: interfaceMethodFunction(
                    name, parameterCount: method.parameters.count - 1,
                    resultCount: method.results.count))
        }
        let receiver = method.parameters[0]
        return functionValue(
            symbol: try libraryValueFunction(
                named: "\(receiver.legacyDescription).\(name)", of: nil, member: name,
                signature: GoLibrarySignature(
                    receiver: receiver, parameters: Array(method.parameters.dropFirst()),
                    results: method.results)))
    }
}

extension GoExpression {
    /// What `*x` dereferences, or the expression itself.
    fileprivate var dereferenced: GoExpression {
        if case .unary(.dereference, let operand, _) = self { return operand.dereferenced }
        return self
    }
}
