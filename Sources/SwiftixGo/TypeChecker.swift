/// Static type checking for the Swiftix Go language subset.

public struct GoStructFieldType: Sendable, Equatable {
    public let name: String
    public let type: GoType

    public init(name: String, type: GoType) {
        self.name = name
        self.type = type
    }
}

public struct GoInterfaceMethod: Sendable, Equatable {
    public let name: String
    public let parameters: [GoType]
    public let results: [GoType]

    public init(name: String, parameters: [GoType] = [], results: [GoType] = []) {
        self.name = name
        self.parameters = parameters
        self.results = results
    }
}

public indirect enum GoType: Sendable, Equatable, CustomStringConvertible {
    case int
    case string
    case bool
    case void
    case named(String)
    case structure([GoStructFieldType])
    case pointer(GoType)
    case nilType
    case array(length: Int, element: GoType)
    case slice(GoType)
    case map(key: GoType, value: GoType)
    case channel(direction: GoChannelDirection, element: GoType)
    case interface([GoInterfaceMethod])
    case function(parameters: [GoType], results: [GoType])

    public var description: String {
        switch self {
        case .int: return "int"
        case .string: return "string"
        case .bool: return "bool"
        case .void: return "void"
        case .named(let name): return name
        case .structure: return "struct"
        case .pointer(let pointee): return "*\(pointee)"
        case .nilType: return "nil"
        case .array(let length, let element): return "[\(length)]\(element)"
        case .slice(let element): return "[]\(element)"
        case .map(let key, let value): return "map[\(key)]\(value)"
        case .channel(let direction, let element):
            switch direction {
            case .bidirectional: return "chan \(element)"
            case .sendOnly: return "chan<- \(element)"
            case .receiveOnly: return "<-chan \(element)"
            }
        case .interface(let methods):
            if methods.isEmpty { return "interface{}" }
            return "interface{...}"
        case .function: return "func"
        }
    }
}

public struct GoTypeDefinition: Sendable, Equatable {
    public let name: String
    public let underlying: GoType

    public init(name: String, underlying: GoType) {
        self.name = name
        self.underlying = underlying
    }
}

public struct GoTypedPackage: Sendable, Equatable {
    public let name: String
    public let files: [GoFile]
    public let typeDefinitions: [String: GoTypeDefinition]
    public let globalTypes: [String: GoType]

    public init(
        name: String,
        files: [GoFile],
        typeDefinitions: [String: GoTypeDefinition] = [:],
        globalTypes: [String: GoType] = [:]
    ) {
        self.name = name
        self.files = files
        self.typeDefinitions = typeDefinitions
        self.globalTypes = globalTypes
    }
}

public struct GoPackageExport: Sendable, Equatable {
    public let name: String
    public let functions: [String: FunctionExport]
    public let types: [String: GoTypeDefinition]
    public let globals: [String: GoType]

    public init(
        name: String,
        functions: [String: FunctionExport] = [:],
        types: [String: GoTypeDefinition] = [:],
        globals: [String: GoType] = [:]
    ) {
        self.name = name
        self.functions = functions
        self.types = types
        self.globals = globals
    }
}

public struct FunctionExport: Sendable, Equatable {
    public let parameters: [GoType]
    public let results: [GoType]

    public init(parameters: [GoType] = [], results: [GoType] = []) {
        self.parameters = parameters
        self.results = results
    }
}

public enum GoTypeChecker {
    /// Standard-library import paths implemented by this toolchain checkpoint.
    /// Package loading and type checking share this list so adding a builtin
    /// package cannot accidentally work for in-memory compilation but fail via
    /// `go run` / `go build`.
    public static let supportedStandardPackages = Set(GoStandardLibrary.supportedPackages)

    public static func check(_ files: [GoFile]) throws -> GoTypedPackage {
        try check(files, availablePackages: [:])
    }

    public static func check(
        _ files: [GoFile],
        availablePackages: [String: GoPackageExport]
    ) throws -> GoTypedPackage {
        guard let first = files.first else {
            throw GoDiagnostic(position: syntheticPosition(), message: "no Go source files")
        }

        for file in files where file.packageName != first.packageName {
            throw GoDiagnostic(
                position: declarationPosition(in: file),
                message: "found packages \(first.packageName) and \(file.packageName)")
        }

        var importedPathsByFile: [Set<String>] = []
        var packageNames: [String: GoSourcePosition] = [:]
        var typeSyntax: [String: GoTypeDeclaration] = [:]
        let knownPackages = supportedStandardPackages
            .union(availablePackages.keys)
        for file in files {
            var importedPaths: Set<String> = []
            for declaration in file.imports {
                let importName = declaration.path.split(separator: "/").last.map(String.init)
                    ?? declaration.path
                guard knownPackages.contains(declaration.path)
                    || knownPackages.contains(importName)
                    || availablePackages.keys.contains(where: {
                        declaration.path.hasSuffix("/" + $0) || declaration.path == $0
                    })
                else {
                    throw GoDiagnostic(
                        position: declaration.position,
                        message: "package \(declaration.path) is not available")
                }
                guard importedPaths.insert(declaration.path).inserted else {
                    throw GoDiagnostic(
                        position: declaration.position,
                        message: "fmt redeclared in this block")
                }
            }
            importedPathsByFile.append(importedPaths)

            for declaration in file.typeDeclarations {
                try reservePackageName(
                    declaration.name,
                    at: declaration.position,
                    names: &packageNames)
                typeSyntax[declaration.name] = declaration
            }
            for declaration in file.globalDeclarations {
                try reservePackageName(
                    declaration.name,
                    at: declaration.position,
                    names: &packageNames)
            }
            for function in file.functions where function.receiver == nil && function.name != "init" {
                try reservePackageName(function.name, at: function.position, names: &packageNames)
            }
        }

        let availableTypes = Set(typeSyntax.keys)
        var typeDefinitions: [String: GoTypeDefinition] = [:]
        for declaration in files.flatMap(\.typeDeclarations) {
            let underlying = try resolve(
                declaration.type,
                availableTypes: availableTypes)
            typeDefinitions[declaration.name] = GoTypeDefinition(
                name: declaration.name,
                underlying: underlying)
        }
        for definition in typeDefinitions.values {
            try rejectRecursiveValueType(
                definition.name,
                definitions: typeDefinitions,
                position: typeSyntax[definition.name]?.position ?? syntheticPosition())
        }

        var functionSignatures: [String: FunctionSignature] = [:]
        var methodSignatures: [String: FunctionSignature] = [:]
        for function in files.flatMap(\.functions) {
            if function.name == "init" {
                guard function.receiver == nil,
                    function.parameters.isEmpty,
                    function.resultTypes.isEmpty
                else {
                    throw GoDiagnostic(
                        position: function.position,
                        message: "func init must have no arguments and no return values")
                }
                continue
            }
            let parameterTypes = try function.parameters.map {
                try resolve($0.type, availableTypes: availableTypes)
            }
            let resultTypes = try function.resultTypes.map {
                try resolve($0, availableTypes: availableTypes)
            }
            let signature = FunctionSignature(
                parameters: parameterTypes,
                results: resultTypes)
            if let receiver = function.receiver {
                let identity = try receiverIdentity(
                    receiver.type,
                    availableTypes: availableTypes)
                let key = methodKey(
                    baseName: identity.baseName,
                    pointer: identity.isPointer,
                    method: function.name)
                let receiverMethodKeys = [
                    methodKey(
                        baseName: identity.baseName,
                        pointer: false,
                        method: function.name),
                    methodKey(
                        baseName: identity.baseName,
                        pointer: true,
                        method: function.name),
                ]
                guard receiverMethodKeys.allSatisfy({ methodSignatures[$0] == nil }) else {
                    throw GoDiagnostic(
                        position: function.position,
                        message: "method \(function.name) already declared for type \(identity.baseName)")
                }
                methodSignatures[key] = signature
            } else {
                functionSignatures[function.name] = signature
            }
        }

        let globals = files.flatMap(\.globalDeclarations)
        var globalBindings: [String: Binding] = [:]
        for declaration in globals {
            if let explicitType = declaration.explicitType {
                globalBindings[declaration.name] = Binding(
                    type: try resolve(explicitType, availableTypes: availableTypes),
                    isConstant: declaration.isConstant)
            }
        }
        var unresolved = globals.filter { globalBindings[$0.name] == nil }
        while !unresolved.isEmpty {
            var next: [GoGlobalDeclaration] = []
            var madeProgress = false
            for declaration in unresolved {
                guard let expression = declaration.expression else {
                    throw GoDiagnostic(position: declaration.position, message: "missing type in declaration")
                }
                do {
                    var checker = FunctionChecker(
                        importedPaths: [],
                        functionSignatures: functionSignatures,
                        methodSignatures: methodSignatures,
                        typeDefinitions: typeDefinitions,
                        availableTypes: availableTypes,
                        globalBindings: globalBindings)
                    let inferred = try checker.type(of: expression)
                    guard inferred != .void, inferred != .nilType else {
                        throw GoDiagnostic(position: expression.position, message: "missing type in declaration")
                    }
                    globalBindings[declaration.name] = Binding(
                        type: inferred,
                        isConstant: declaration.isConstant)
                    madeProgress = true
                } catch let diagnostic as GoDiagnostic where diagnostic.message.hasPrefix("undefined:") {
                    next.append(declaration)
                }
            }
            guard madeProgress else {
                throw GoDiagnostic(
                    position: next.first?.position ?? unresolved[0].position,
                    message: "initialization cycle for package variable")
            }
            unresolved = next
        }
        for declaration in globals {
            guard let expression = declaration.expression,
                let binding = globalBindings[declaration.name]
            else { continue }
            var checker = FunctionChecker(
                importedPaths: [],
                functionSignatures: functionSignatures,
                methodSignatures: methodSignatures,
                typeDefinitions: typeDefinitions,
                availableTypes: availableTypes,
                globalBindings: globalBindings)
            try checker.require(expression, assignableTo: binding.type)
        }

        if first.packageName == "main", functionSignatures["main"] == nil {
            throw GoDiagnostic(
                position: syntheticPosition(path: first.path),
                message: "function main is undeclared in the main package")
        }
        if first.packageName == "main", let main = functionSignatures["main"],
            !main.parameters.isEmpty || !main.results.isEmpty
        {
            let position =
                files.flatMap(\.functions).first { $0.name == "main" }?.position
                ?? syntheticPosition(path: first.path)
            throw GoDiagnostic(
                position: position,
                message: "func main must have no arguments and no return values")
        }

        for (file, importedPaths) in zip(files, importedPathsByFile) {
            for function in file.functions {
                var checker = FunctionChecker(
                    importedPaths: importedPaths,
                    functionSignatures: functionSignatures,
                    methodSignatures: methodSignatures,
                    typeDefinitions: typeDefinitions,
                    availableTypes: availableTypes,
                    availablePackages: availablePackages,
                    globalBindings: globalBindings)
                try checker.check(function)
            }
        }

        return GoTypedPackage(
            name: first.packageName,
            files: files,
            typeDefinitions: typeDefinitions,
            globalTypes: globalBindings.mapValues(\.type))
    }

    private static func reservePackageName(
        _ name: String,
        at position: GoSourcePosition,
        names: inout [String: GoSourcePosition]
    ) throws {
        guard names[name] == nil else {
            throw GoDiagnostic(position: position, message: "\(name) redeclared in this block")
        }
        names[name] = position
    }

    private static func resolve(
        _ expression: GoTypeExpression,
        availableTypes: Set<String>
    ) throws -> GoType {
        switch expression {
        case .named(let name, let position):
            switch name {
            case "int": return .int
            case "string": return .string
            case "bool": return .bool
            case "any": return .interface([])
            case "error": return builtinErrorType()
            case "testing.T", "sync.Mutex", "sync.WaitGroup",
                "context.Context", "context.CancelFunc",
                "net.Conn", "net.Listener",
                "http.Response", "http.ResponseWriter", "http.Request":
                return .named(name)
            default:
                guard availableTypes.contains(name) else {
                    throw GoDiagnostic(position: position, message: "undefined: \(name)")
                }
                return .named(name)
            }
        case .structure(let fields, _):
            var names: Set<String> = []
            let resolvedFields = try fields.map { field -> GoStructFieldType in
                guard names.insert(field.name).inserted else {
                    throw GoDiagnostic(
                        position: field.position,
                        message: "\(field.name) redeclared in this block")
                }
                return GoStructFieldType(
                    name: field.name,
                    type: try resolve(field.type, availableTypes: availableTypes))
            }
            return .structure(resolvedFields)
        case .pointer(let pointee, _):
            return .pointer(try resolve(pointee, availableTypes: availableTypes))
        case .array(let length, let element, _):
            return .array(
                length: length,
                element: try resolve(element, availableTypes: availableTypes))
        case .slice(let element, _):
            return .slice(try resolve(element, availableTypes: availableTypes))
        case .map(let key, let value, _):
            return .map(
                key: try resolve(key, availableTypes: availableTypes),
                value: try resolve(value, availableTypes: availableTypes))
        case .channel(let direction, let element, _):
            return .channel(
                direction: direction,
                element: try resolve(element, availableTypes: availableTypes))
        case .interface(let methods, _):
            return .interface(try methods.map { method in
                GoInterfaceMethod(
                    name: method.name,
                    parameters: try method.parameters.map {
                        try resolve($0, availableTypes: availableTypes)
                    },
                    results: try method.results.map {
                        try resolve($0, availableTypes: availableTypes)
                    })
            })
        }
    }

    private static func receiverIdentity(
        _ expression: GoTypeExpression,
        availableTypes: Set<String>
    ) throws -> (baseName: String, isPointer: Bool) {
        switch expression {
        case .named(let name, let position):
            guard availableTypes.contains(name) else {
                throw GoDiagnostic(position: position, message: "invalid receiver type \(name)")
            }
            return (name, false)
        case .pointer(let pointee, let position):
            guard case .named(let name, _) = pointee, availableTypes.contains(name) else {
                throw GoDiagnostic(position: position, message: "invalid receiver type")
            }
            return (name, true)
        default:
            throw GoDiagnostic(position: expression.position, message: "invalid receiver type")
        }
    }

    private static func methodKey(baseName: String, pointer: Bool, method: String) -> String {
        "\(pointer ? "*" : "")\(baseName).\(method)"
    }

    private static func rejectRecursiveValueType(
        _ root: String,
        definitions: [String: GoTypeDefinition],
        position: GoSourcePosition
    ) throws {
        func contains(
            _ type: GoType,
            target: String,
            visiting: inout Set<String>
        ) -> Bool {
            switch type {
            case .named(let name):
                if name == target { return true }
                guard visiting.insert(name).inserted,
                    let definition = definitions[name]
                else { return false }
                defer { visiting.remove(name) }
                return contains(definition.underlying, target: target, visiting: &visiting)
            case .structure(let fields):
                return fields.contains {
                    contains($0.type, target: target, visiting: &visiting)
                }
            case .pointer:
                return false
            case .array(_, let element):
                return contains(element, target: target, visiting: &visiting)
            case .slice:
                return false
            default:
                return false
            }
        }

        guard let definition = definitions[root] else { return }
        var visiting: Set<String> = [root]
        if contains(definition.underlying, target: root, visiting: &visiting) {
            throw GoDiagnostic(position: position, message: "invalid recursive type \(root)")
        }
    }

    private static func declarationPosition(in file: GoFile) -> GoSourcePosition {
        file.typeDeclarations.first?.position
            ?? file.globalDeclarations.first?.position
            ?? file.functions.first?.position
            ?? syntheticPosition(path: file.path)
    }

    private static func syntheticPosition(path: String = "<input>") -> GoSourcePosition {
        GoSourcePosition(path: path, offset: 0, line: 1, column: 1)
    }
}

private struct FunctionSignature {
    let parameters: [GoType]
    let results: [GoType]
}

private func builtinErrorType() -> GoType {
    .interface([
        GoInterfaceMethod(name: "Error", results: [.string])
    ])
}

private struct Binding {
    let type: GoType
    let isConstant: Bool
}

private enum SwitchCaseConstant: Hashable {
    case int(Int64)
    case string(String)
    case bool(Bool)
}

private struct FunctionChecker {
    let importedPaths: Set<String>
    let functionSignatures: [String: FunctionSignature]
    let methodSignatures: [String: FunctionSignature]
    let typeDefinitions: [String: GoTypeDefinition]
    let availableTypes: Set<String>
    let availablePackages: [String: GoPackageExport]
    var scopes: [[String: Binding]]
    var breakableDepth = 0
    var loopDepth = 0
    var expectedResults: [GoType] = []
    var namedResultCount = 0

    init(
        importedPaths: Set<String>,
        functionSignatures: [String: FunctionSignature],
        methodSignatures: [String: FunctionSignature],
        typeDefinitions: [String: GoTypeDefinition],
        availableTypes: Set<String>,
        availablePackages: [String: GoPackageExport] = [:],
        globalBindings: [String: Binding] = [:]
    ) {
        self.importedPaths = importedPaths
        self.functionSignatures = functionSignatures
        self.methodSignatures = methodSignatures
        self.typeDefinitions = typeDefinitions
        self.availableTypes = availableTypes
        self.availablePackages = availablePackages
        self.scopes = [globalBindings, [:]]
    }

    mutating func check(_ function: GoFunctionDeclaration) throws {
        let signature: FunctionSignature?
        if function.name == "init", function.receiver == nil {
            signature = FunctionSignature(parameters: [], results: [])
        } else if let receiver = function.receiver {
            let receiverType = try declaredType(receiver.type)
            guard let identity = receiverIdentity(receiverType) else {
                throw GoDiagnostic(position: receiver.position, message: "invalid receiver type")
            }
            signature =
                methodSignatures[
                    methodKey(
                        baseName: identity.baseName,
                        pointer: identity.isPointer,
                        method: function.name)]
            scopes[scopes.count - 1][receiver.name] = Binding(
                type: receiverType,
                isConstant: false)
        } else {
            signature = functionSignatures[function.name]
        }
        guard let signature else {
            throw GoDiagnostic(position: function.position, message: "undefined: \(function.name)")
        }
        expectedResults = signature.results
        for (parameter, parameterType) in zip(function.parameters, signature.parameters) {
            guard scopes[scopes.count - 1][parameter.name] == nil else {
                throw GoDiagnostic(
                    position: parameter.position,
                    message: "\(parameter.name) redeclared in this block")
            }
            scopes[scopes.count - 1][parameter.name] = Binding(
                type: parameterType,
                isConstant: false)
        }
        for (name, resultType) in zip(function.resultNames, signature.results) {
            guard let name else { continue }
            guard scopes[scopes.count - 1][name] == nil else {
                throw GoDiagnostic(
                    position: function.position,
                    message: "\(name) redeclared in this block")
            }
            scopes[scopes.count - 1][name] = Binding(type: resultType, isConstant: false)
            namedResultCount += 1
        }
        if namedResultCount > 0, namedResultCount != signature.results.count {
            throw GoDiagnostic(
                position: function.position,
                message: "mixed named and unnamed parameters")
        }
        try checkBlock(function.body, createsScope: false)
        if !signature.results.isEmpty, !blockTerminates(function.body) {
            throw GoDiagnostic(position: function.position, message: "missing return")
        }
    }

    mutating func checkBlock(_ block: GoBlock, createsScope: Bool = true) throws {
        if createsScope { scopes.append([:]) }
        defer { if createsScope { scopes.removeLast() } }
        for statement in block.statements { try check(statement) }
    }

    mutating func check(_ statement: GoStatement) throws {
        switch statement {
        case .declaration(let name, let explicitType, let expression, let isConstant, let position):
            guard scopes[scopes.count - 1][name] == nil else {
                throw GoDiagnostic(position: position, message: "\(name) redeclared in this block")
            }
            if let expression, case .call(let callee, let arguments, let callPosition) = expression {
                if case .identifier(let name, _) = callee,
                    name != "len" && name != "cap" && name != "append" && name != "make" && name != "panic" && name != "recover" && name != "delete",
                    let signature = functionSignatures[name],
                    signature.results.count > 1
                {
                    throw GoDiagnostic(
                        position: position,
                        message: "multiple-value \(name)() (value of type (\(signature.results.map(\.description).joined(separator: ", ")))) in single-value context")
                } else if case .selector(let base, let name, _) = callee,
                    !(base == .identifier("fmt", position: base.position) && importedPaths.contains("fmt"))
                {
                    let results = (try? callResultTypes(
                        callee: callee, arguments: arguments, position: callPosition)) ?? []
                    if results.count > 1 {
                        throw GoDiagnostic(
                            position: position,
                            message: "multiple-value \(name)() in single-value context")
                    }
                }
            }
            let declared = try explicitType.map { try declaredType($0) }
            let expressionType = try expression.map { try type(of: $0) }
            if let declared, let expressionType, !isAssignable(expressionType, to: declared) {
                throw GoDiagnostic(
                    position: expression?.position ?? position,
                    message: "cannot use \(expressionType) as \(declared) value")
            }
            guard let bindingType = declared ?? expressionType else {
                throw GoDiagnostic(position: position, message: "missing type in declaration")
            }
            guard bindingType != .void, bindingType != .nilType else {
                throw GoDiagnostic(
                    position: expression?.position ?? position,
                    message: "no value used as value")
            }
            scopes[scopes.count - 1][name] = Binding(type: bindingType, isConstant: isConstant)

        case .assignment(let target, let expression, _):
            let targetType = try assignableType(of: target)
            let expressionType = try type(of: expression)
            guard isAssignable(expressionType, to: targetType) else {
                throw GoDiagnostic(
                    position: expression.position,
                    message: "cannot use \(expressionType) as \(targetType) value")
            }

        case .multiDeclaration(let names, let expression, let position):
            if case .unary(.receive, let channel, _) = expression,
                case .channel(let direction, let elementType) = underlying(try type(of: channel))
            {
                guard direction != .sendOnly else {
                    throw GoDiagnostic(position: expression.position, message: "cannot receive from send-only channel")
                }
                guard names.count == 2 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "assignment mismatch: channel receive returns 2 values")
                }
                scopes[scopes.count - 1][names[0]] = Binding(
                    type: elementType, isConstant: false)
                scopes[scopes.count - 1][names[1]] = Binding(
                    type: .bool, isConstant: false)
                return
            }
            if case .index(let base, let key, _) = expression,
                case .map(let keyType, let valueType) = underlying(try type(of: base))
            {
                guard names.count == 2 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "assignment mismatch: map index returns 2 values")
                }
                try require(key, assignableTo: keyType)
                scopes[scopes.count - 1][names[0]] = Binding(
                    type: valueType, isConstant: false)
                scopes[scopes.count - 1][names[1]] = Binding(
                    type: .bool, isConstant: false)
                return
            }
            if case .typeAssertion(_, let assertedType, _) = expression {
                guard names.count == 2 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "assignment mismatch: type assertion returns 2 values")
                }
                let valueType = try declaredType(assertedType)
                scopes[scopes.count - 1][names[0]] = Binding(
                    type: valueType, isConstant: false)
                scopes[scopes.count - 1][names[1]] = Binding(
                    type: .bool, isConstant: false)
                _ = try type(of: expression)
                return
            }
            guard case .call(let callee, let arguments, let callPosition) = expression else {
                throw GoDiagnostic(
                    position: position,
                    message: "multiple-value context requires function call")
            }
            let resultTypes = try callResultTypes(
                callee: callee, arguments: arguments, position: callPosition)
            guard resultTypes.count == names.count else {
                throw GoDiagnostic(
                    position: position,
                    message: "assignment mismatch: \(names.count) variables but function returns \(resultTypes.count) values")
            }
            for (name, resultType) in zip(names, resultTypes) {
                guard scopes[scopes.count - 1][name] == nil else {
                    throw GoDiagnostic(
                        position: position,
                        message: "\(name) redeclared in this block")
                }
                scopes[scopes.count - 1][name] = Binding(
                    type: resultType, isConstant: false)
            }

        case .multiAssignment(let targets, let expression, let position):
            if case .unary(.receive, let channel, _) = expression,
                case .channel(let direction, let elementType) = underlying(try type(of: channel))
            {
                guard direction != .sendOnly else {
                    throw GoDiagnostic(position: expression.position, message: "cannot receive from send-only channel")
                }
                guard targets.count == 2 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "assignment mismatch: channel receive returns 2 values")
                }
                for (target, resultType) in zip(targets, [elementType, GoType.bool]) {
                    let targetType = try assignableType(of: target)
                    guard isAssignable(resultType, to: targetType) else {
                        throw GoDiagnostic(
                            position: target.position,
                            message: "cannot assign \(resultType) to \(targetType)")
                    }
                }
                return
            }
            if case .index(let base, let key, _) = expression,
                case .map(let keyType, let valueType) = underlying(try type(of: base))
            {
                guard targets.count == 2 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "assignment mismatch: map index returns 2 values")
                }
                try require(key, assignableTo: keyType)
                for (target, resultType) in zip(targets, [valueType, .bool]) {
                    let targetType = try assignableType(of: target)
                    guard isAssignable(resultType, to: targetType) else {
                        throw GoDiagnostic(
                            position: target.position,
                            message: "cannot assign \(resultType) to \(targetType)")
                    }
                }
                return
            }
            if case .typeAssertion(_, let assertedType, _) = expression {
                guard targets.count == 2 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "assignment mismatch: type assertion returns 2 values")
                }
                _ = try type(of: expression)
                let resultTypes = [try declaredType(assertedType), GoType.bool]
                for (target, resultType) in zip(targets, resultTypes) {
                    let targetType = try assignableType(of: target)
                    guard isAssignable(resultType, to: targetType) else {
                        throw GoDiagnostic(
                            position: target.position,
                            message: "cannot assign \(resultType) to \(targetType)")
                    }
                }
                return
            }
            guard case .call(let callee, let arguments, let callPosition) = expression else {
                throw GoDiagnostic(
                    position: position,
                    message: "multiple-value context requires function call")
            }
            let resultTypes = try callResultTypes(
                callee: callee, arguments: arguments, position: callPosition)
            guard resultTypes.count == targets.count else {
                throw GoDiagnostic(
                    position: position,
                    message: "assignment mismatch: \(targets.count) variables but function returns \(resultTypes.count) values")
            }
            for (target, resultType) in zip(targets, resultTypes) {
                let targetType = try assignableType(of: target)
                guard isAssignable(resultType, to: targetType) else {
                    throw GoDiagnostic(
                        position: target.position,
                        message: "cannot use \(resultType) as \(targetType) value in assignment")
                }
            }

        case .increment(let target, let incrementOperator, let position):
            let targetType = try assignableType(of: target)
            guard isInteger(targetType) else {
                let spelling = incrementOperator == .increment ? "++" : "--"
                throw GoDiagnostic(
                    position: position,
                    message: "invalid operation: \(spelling) on non-numeric type \(targetType)")
            }

        case .expression(let expression):
            guard case .call = expression else {
                if case .unary(.receive, _, _) = expression {
                    _ = try type(of: expression)
                    return
                }
                throw GoDiagnostic(
                    position: expression.position,
                    message: "expression evaluated but not used")
            }
            _ = try type(of: expression)

        case .returnValues(let values, let position):
            guard !expectedResults.isEmpty else {
                guard values.isEmpty else {
                    throw GoDiagnostic(position: position, message: "too many return values")
                }
                return
            }
            if values.isEmpty, namedResultCount == expectedResults.count {
                return
            }
            guard values.count >= expectedResults.count else {
                throw GoDiagnostic(position: position, message: "not enough return values")
            }
            guard values.count <= expectedResults.count else {
                throw GoDiagnostic(position: position, message: "too many return values")
            }
            for (value, expected) in zip(values, expectedResults) {
                let actual = try type(of: value)
                guard isAssignable(actual, to: expected) else {
                    throw GoDiagnostic(
                        position: value.position,
                        message: "cannot use \(actual) as \(expected) value in return statement")
                }
            }

        case .breakStatement(let position):
            guard breakableDepth > 0 else {
                throw GoDiagnostic(
                    position: position,
                    message: "break is not in a loop, switch, or select")
            }

        case .continueStatement(let position):
            guard loopDepth > 0 else {
                throw GoDiagnostic(position: position, message: "continue is not in a loop")
            }

        case .deferStatement(let expression, let position):
            guard case .call = expression else {
                throw GoDiagnostic(
                    position: position,
                    message: "expression in defer must be function call")
            }
            _ = try type(of: expression)

        case .goStatement(let expression, let position):
            guard case .call = expression else {
                throw GoDiagnostic(
                    position: position,
                    message: "expression in go must be function call")
            }
            _ = try type(of: expression)

        case .sendStatement(let channel, let value, _):
            guard case .channel(let direction, let elementType) = underlying(try type(of: channel)) else {
                throw GoDiagnostic(position: channel.position, message: "cannot send to non-channel value")
            }
            guard direction != .receiveOnly else {
                throw GoDiagnostic(position: channel.position, message: "cannot send to receive-only channel")
            }
            let valueType = try type(of: value)
            guard isAssignable(valueType, to: elementType) else {
                throw GoDiagnostic(
                    position: value.position,
                    message: "cannot send \(valueType) value on \(elementType) channel")
            }

        case .ifStatement(let condition, let thenBlock, let elseBlock, _):
            try requireBool(condition)
            try checkBlock(thenBlock)
            if let elseBlock { try checkBlock(elseBlock) }

        case .forStatement(let initializer, let condition, let post, let body, _):
            scopes.append([:])
            defer { scopes.removeLast() }
            if let initializer { try check(initializer) }
            if let condition { try requireBool(condition) }
            if let post { try check(post) }
            breakableDepth += 1
            loopDepth += 1
            defer {
                breakableDepth -= 1
                loopDepth -= 1
            }
            try checkBlock(body)

        case .forRangeStatement(let indexName, let valueName, let collection, let body, let position):
            scopes.append([:])
            defer { scopes.removeLast() }
            let collectionType = try type(of: collection)
            let elementType: GoType
            switch underlying(collectionType) {
            case .array(_, let element): elementType = element
            case .slice(let element): elementType = element
            case .string: elementType = .int
            case .map(_, let value): elementType = value
            case .channel(let direction, let element):
                guard direction != .sendOnly else {
                    throw GoDiagnostic(
                        position: collection.position,
                        message: "cannot range over send-only channel")
                }
                guard valueName == nil else {
                    throw GoDiagnostic(
                        position: position,
                        message: "range over channel permits only one iteration variable")
                }
                elementType = element
            default:
                throw GoDiagnostic(
                    position: collection.position,
                    message: "cannot range over \(collectionType)")
            }
            if let indexName {
                let indexType: GoType
                if case .map(let key, _) = underlying(collectionType) {
                    indexType = key
                } else if case .channel(_, let element) = underlying(collectionType) {
                    indexType = element
                } else {
                    indexType = .int
                }
                scopes[scopes.count - 1][indexName] = Binding(type: indexType, isConstant: false)
            }
            if let valueName {
                scopes[scopes.count - 1][valueName] = Binding(type: elementType, isConstant: false)
            }
            _ = position
            breakableDepth += 1
            loopDepth += 1
            defer {
                breakableDepth -= 1
                loopDepth -= 1
            }
            try checkBlock(body)

        case .switchStatement(let expression, let cases, _):
            let switchType = try expression.map { try type(of: $0) } ?? .bool
            guard switchType != .void else {
                throw GoDiagnostic(
                    position: expression?.position ?? cases.first?.position ?? syntheticPosition(),
                    message: "switch expression used as value")
            }
            guard isComparable(switchType) else {
                throw GoDiagnostic(
                    position: expression?.position ?? cases.first?.position ?? syntheticPosition(),
                    message: "switch expression is not comparable")
            }
            var hasDefault = false
            var constants: Set<SwitchCaseConstant> = []
            breakableDepth += 1
            defer { breakableDepth -= 1 }
            for switchCase in cases {
                if switchCase.isDefault {
                    guard !hasDefault else {
                        throw GoDiagnostic(
                            position: switchCase.position,
                            message: "multiple defaults in switch")
                    }
                    hasDefault = true
                }
                for caseExpression in switchCase.expressions {
                    let caseType = try type(of: caseExpression)
                    guard caseType == switchType else {
                        throw GoDiagnostic(
                            position: caseExpression.position,
                            message: "invalid case \(caseType) in switch on \(switchType)")
                    }
                    if let constant = switchCaseConstant(caseExpression),
                        !constants.insert(constant).inserted
                    {
                        throw GoDiagnostic(
                            position: caseExpression.position,
                            message: "duplicate case in switch")
                    }
                }
                try checkBlock(switchCase.body)
            }

        case .selectStatement(let cases, let position):
            guard !cases.isEmpty else {
                // `select {}` is valid and blocks forever.
                return
            }
            var hasDefault = false
            breakableDepth += 1
            defer { breakableDepth -= 1 }
            for selectCase in cases {
                scopes.append([:])
                defer { scopes.removeLast() }
                if let communication = selectCase.communication {
                    guard isSelectCommunication(communication) else {
                        throw GoDiagnostic(
                            position: selectCase.position,
                            message: "select case must be send or receive")
                    }
                    try check(communication)
                } else {
                    guard !hasDefault else {
                        throw GoDiagnostic(
                            position: selectCase.position,
                            message: "multiple defaults in select")
                    }
                    hasDefault = true
                }
                try checkBlock(selectCase.body, createsScope: false)
            }
            _ = position
        }
    }

    mutating func type(of expression: GoExpression) throws -> GoType {
        switch expression {
        case .integer:
            return .int
        case .string:
            return .string
        case .identifier(let name, let position):
            if name == "true" || name == "false" { return .bool }
            if name == "nil" { return .nilType }
            guard let binding = lookup(name) else {
                throw GoDiagnostic(position: position, message: "undefined: \(name)")
            }
            return binding.type
        case .selector(let base, let name, let position):
            if case .identifier(let packageName, _) = base,
                importedPaths.contains(packageName),
                GoStandardLibrary.integerConstant(package: packageName, member: name) != nil
            {
                return .int
            }
            if case .identifier(let packageName, _) = base,
                packageName == "fmt",
                importedPaths.contains("fmt"),
                name == "Print" || name == "Println"
            {
                return .void
            }
            if case .identifier("os", _) = base,
                importedPaths.contains("os"),
                name == "Args"
            {
                return .slice(.string)
            }
            let baseType = try type(of: base)
            guard let field = structFields(of: baseType)?.first(where: { $0.name == name }) else {
                throw GoDiagnostic(
                    position: position,
                    message: "\(baseType) has no field or method \(name)")
            }
            return field.type
        case .compositeLiteral(let typeExpression, let elements, let position):
            let literalType = try declaredType(typeExpression)
            switch underlying(literalType) {
            case .structure(let fields):
                let keyed = elements.contains { $0.key != nil }
                if keyed, elements.contains(where: { $0.key == nil }) {
                    throw GoDiagnostic(position: position, message: "mixture of field:value and value elements")
                }
                if keyed {
                    var seen: Set<String> = []
                    for element in elements {
                        guard let key = element.key,
                            let field = fields.first(where: { $0.name == key })
                        else {
                            throw GoDiagnostic(
                                position: element.position,
                                message: "unknown field \(element.key ?? "") in struct literal")
                        }
                        guard seen.insert(key).inserted else {
                            throw GoDiagnostic(
                                position: element.position,
                                message: "duplicate field name \(key) in struct literal")
                        }
                        try require(element.value, assignableTo: field.type)
                    }
                } else {
                    guard elements.count == fields.count else {
                        throw GoDiagnostic(position: position, message: "too few values in struct literal")
                    }
                    for (element, field) in zip(elements, fields) {
                        try require(element.value, assignableTo: field.type)
                    }
                }
            case .array(let length, let elementType):
                guard !elements.contains(where: { $0.key != nil }) else {
                    throw GoDiagnostic(position: position, message: "keyed array literals are not supported yet")
                }
                guard elements.count <= length else {
                    throw GoDiagnostic(position: position, message: "index out of bounds in array literal")
                }
                for element in elements { try require(element.value, assignableTo: elementType) }
            case .slice(let elementType):
                guard !elements.contains(where: { $0.key != nil }) else {
                    throw GoDiagnostic(position: position, message: "keyed slice literals are not supported yet")
                }
                for element in elements { try require(element.value, assignableTo: elementType) }
            case .map(let keyType, let valueType):
                for element in elements {
                    if let keyExpression = element.keyExpression {
                        try require(keyExpression, assignableTo: keyType)
                    } else if element.key == nil {
                        throw GoDiagnostic(position: element.position, message: "missing key in map literal")
                    }
                    try require(element.value, assignableTo: valueType)
                }
            default:
                throw GoDiagnostic(position: position, message: "invalid composite literal type \(literalType)")
            }
            return literalType
        case .index(let base, let index, let position):
            let baseType = underlying(try type(of: base))
            switch baseType {
            case .array(_, let element), .slice(let element):
                guard isInteger(try type(of: index)) else {
                    throw GoDiagnostic(position: index.position, message: "index must be integer")
                }
                return element
            case .string:
                guard isInteger(try type(of: index)) else {
                    throw GoDiagnostic(position: index.position, message: "index must be integer")
                }
                return .int
            case .map(let keyType, let valueType):
                let indexType = try type(of: index)
                guard isAssignable(indexType, to: keyType) else {
                    throw GoDiagnostic(
                        position: index.position,
                        message: "cannot use \(indexType) as \(keyType) value in map index")
                }
                return valueType
            default:
                throw GoDiagnostic(position: position, message: "cannot index expression")
            }
        case .slicing(let base, let low, let high, let position):
            for bound in [low, high].compactMap({ $0 }) where !isInteger(try type(of: bound)) {
                throw GoDiagnostic(position: bound.position, message: "slice index must be integer")
            }
            switch underlying(try type(of: base)) {
            case .array(_, let element), .slice(let element): return .slice(element)
            case .string: return .string
            default:
                throw GoDiagnostic(position: position, message: "cannot slice expression")
            }
        case .typeExpression(_, let position):
            throw GoDiagnostic(position: position, message: "type is not an expression")
        case .typeAssertion(let base, let assertedType, let position):
            guard case .interface = underlying(try type(of: base)) else {
                throw GoDiagnostic(
                    position: position,
                    message: "invalid operation: value is not an interface")
            }
            return try declaredType(assertedType)
        case .functionLiteral(
            let parameters, let resultNames, let resultTypes, let body, _):
            let parameterTypes = try parameters.map { try declaredType($0.type) }
            let resolvedResults = try resultTypes.map(declaredType)
            let savedResults = expectedResults
            let savedNamedCount = namedResultCount
            scopes.append([:])
            defer {
                scopes.removeLast()
                expectedResults = savedResults
                namedResultCount = savedNamedCount
            }
            expectedResults = resolvedResults
            namedResultCount = 0
            for (parameter, parameterType) in zip(parameters, parameterTypes) {
                scopes[scopes.count - 1][parameter.name] = Binding(
                    type: parameterType, isConstant: false)
            }
            for (name, resultType) in zip(resultNames, resolvedResults) {
                if let name {
                    scopes[scopes.count - 1][name] = Binding(
                        type: resultType, isConstant: false)
                    namedResultCount += 1
                }
            }
            try checkBlock(body, createsScope: false)
            return .function(parameters: parameterTypes, results: resolvedResults)
        case .call(let callee, let arguments, let position):
            if case .functionLiteral = callee,
                case .function(let parameters, let results) = try type(of: callee)
            {
                guard arguments.count == parameters.count else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in function literal call")
                }
                for (argument, parameter) in zip(arguments, parameters) {
                    try require(argument, assignableTo: parameter)
                }
                return results.first ?? .void
            }
            if case .identifier(let name, let namePosition) = callee {
                if name == "len" || name == "cap" {
                    guard arguments.count == 1 else {
                        throw GoDiagnostic(position: position, message: "invalid argument count for \(name)")
                    }
                    let argumentType = underlying(try type(of: arguments[0]))
                    if name == "len" {
                        guard argumentType == .string || isArrayOrSlice(argumentType)
                            || isMap(argumentType) || isChannel(argumentType)
                        else {
                            throw GoDiagnostic(position: arguments[0].position, message: "invalid argument for len")
                        }
                    } else {
                        guard isArrayOrSlice(argumentType) || isChannel(argumentType) else {
                            throw GoDiagnostic(position: arguments[0].position, message: "invalid argument for cap")
                        }
                    }
                    return .int
                }
                if name == "append" {
                    guard arguments.count >= 2 else {
                        throw GoDiagnostic(position: position, message: "not enough arguments in call to append")
                    }
                    let sliceType = try type(of: arguments[0])
                    guard case .slice(let elementType) = underlying(sliceType) else {
                        throw GoDiagnostic(
                            position: arguments[0].position, message: "first argument to append must be slice")
                    }
                    for argument in arguments.dropFirst() {
                        try require(argument, assignableTo: elementType)
                    }
                    return sliceType
                }
                if name == "make" {
                    guard arguments.count >= 1 && arguments.count <= 3,
                        case .typeExpression(let typeExpression, _) = arguments[0]
                    else {
                        throw GoDiagnostic(position: position, message: "invalid make call")
                    }
                    let madeType = try declaredType(typeExpression)
                    switch underlying(madeType) {
                    case .slice:
                        guard arguments.count >= 2 else {
                            throw GoDiagnostic(position: position, message: "missing len argument")
                        }
                        for argument in arguments.dropFirst() where !isInteger(try type(of: argument)) {
                            throw GoDiagnostic(position: argument.position, message: "make size must be integer")
                        }
                    case .map:
                        if arguments.count > 2 {
                            throw GoDiagnostic(position: position, message: "too many arguments to make")
                        }
                        for argument in arguments.dropFirst() where !isInteger(try type(of: argument)) {
                            throw GoDiagnostic(position: argument.position, message: "make size must be integer")
                        }
                    case .channel:
                        if arguments.count > 2 {
                            throw GoDiagnostic(position: position, message: "too many arguments to make")
                        }
                        for argument in arguments.dropFirst() where !isInteger(try type(of: argument)) {
                            throw GoDiagnostic(position: argument.position, message: "make channel size must be integer")
                        }
                    default:
                        throw GoDiagnostic(position: arguments[0].position, message: "cannot make \(madeType)")
                    }
                    return madeType
                }
                if name == "panic" {
                    guard arguments.count == 1 else {
                        throw GoDiagnostic(position: position, message: "panic takes exactly one argument")
                    }
                    _ = try type(of: arguments[0])
                    return .void
                }
                if name == "recover" {
                    guard arguments.isEmpty else {
                        throw GoDiagnostic(
                            position: position,
                            message: "too many arguments in call to recover")
                    }
                    return .interface([])
                }
                if name == "delete" {
                    guard arguments.count == 2 else {
                        throw GoDiagnostic(position: position, message: "delete takes exactly two arguments")
                    }
                    let mapType = try type(of: arguments[0])
                    guard case .map(let keyType, _) = underlying(mapType) else {
                        throw GoDiagnostic(
                            position: arguments[0].position,
                            message: "first argument to delete must be map")
                    }
                    let actualKeyType = try type(of: arguments[1])
                    guard isAssignable(actualKeyType, to: keyType) else {
                        throw GoDiagnostic(
                            position: arguments[1].position,
                            message: "cannot use \(actualKeyType) as \(keyType) value in delete")
                    }
                    return .void
                }
                if name == "close" {
                    guard arguments.count == 1 else {
                        throw GoDiagnostic(position: position, message: "close takes exactly one argument")
                    }
                    guard case .channel(let direction, _) = underlying(try type(of: arguments[0])) else {
                        throw GoDiagnostic(
                            position: arguments[0].position,
                            message: "invalid operation: cannot close non-channel")
                    }
                    guard direction != .receiveOnly else {
                        throw GoDiagnostic(
                            position: arguments[0].position,
                            message: "invalid operation: cannot close receive-only channel")
                    }
                    return .void
                }
                guard let signature = functionSignatures[name] else {
                    // Allow calling variables of function type (e.g., context.CancelFunc)
                    if let binding = lookup(name),
                        binding.type == .named("context.CancelFunc")
                    {
                        guard arguments.isEmpty else {
                            throw GoDiagnostic(
                                position: position,
                                message: "too many arguments in call to cancel function")
                        }
                        return .void
                    }
                    throw GoDiagnostic(position: namePosition, message: "undefined: \(name)")
                }
                guard arguments.count <= signature.parameters.count else {
                    throw GoDiagnostic(position: position, message: "too many arguments in call to \(name)")
                }
                guard arguments.count == signature.parameters.count else {
                    throw GoDiagnostic(position: position, message: "not enough arguments in call to \(name)")
                }
                for (argument, parameterType) in zip(arguments, signature.parameters) {
                    let argumentType = try type(of: argument)
                    guard isAssignable(argumentType, to: parameterType) else {
                        throw GoDiagnostic(
                            position: argument.position,
                            message: "cannot use \(argumentType) as \(parameterType) value in argument to \(name)")
                    }
                }
                return signature.results.first ?? .void
            }
            guard case .selector(let base, let name, _) = callee else {
                throw GoDiagnostic(position: position, message: "unsupported function call")
            }
            if case .identifier(let packageName, _) = base,
                packageName == "fmt",
                importedPaths.contains("fmt"),
                name == "Print" || name == "Println"
            {
                for argument in arguments where try type(of: argument) == .void {
                    throw GoDiagnostic(position: argument.position, message: "no value used as value")
                }
                return .void
            }
            if case .identifier("os", _) = base,
                importedPaths.contains("os"),
                name == "Exit"
            {
                guard arguments.count == 1 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in call to os.Exit")
                }
                try require(arguments[0], assignableTo: .int)
                return .void
            }
            if case .identifier("strconv", _) = base,
                importedPaths.contains("strconv"),
                name == "Atoi"
            {
                guard arguments.count == 1 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in call to strconv.Atoi")
                }
                try require(arguments[0], assignableTo: .string)
                return .int
            }
            if case .identifier("userland", _) = base,
                importedPaths.contains("swiftix/userland"),
                name == "ReadInput"
            {
                guard arguments.count == 2 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in call to userland.ReadInput")
                }
                try require(arguments[0], assignableTo: .string)
                try require(arguments[1], assignableTo: .slice(.string))
                return .string
            }
            if case .identifier(let packageName, _) = base,
                packageName == "time",
                importedPaths.contains("time"),
                name == "After"
            {
                guard arguments.count == 1 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in call to time.After")
                }
                try require(arguments[0], assignableTo: .int)
                return .channel(direction: .receiveOnly, element: .int)
            }
            if case .identifier(let packageName, _) = base,
                packageName == "time",
                importedPaths.contains("time"),
                name == "Sleep"
            {
                guard arguments.count == 1 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in call to time.Sleep")
                }
                try require(arguments[0], assignableTo: .int)
                return .void
            }
            if case .identifier(let packageName, _) = base,
                packageName == "time",
                importedPaths.contains("time"),
                name == "Tick"
            {
                guard arguments.count == 1 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in call to time.Tick")
                }
                try require(arguments[0], assignableTo: .int)
                return .channel(direction: .receiveOnly, element: .int)
            }
            if case .identifier(let packageName, _) = base,
                packageName == "context",
                importedPaths.contains("context"),
                name == "Background"
            {
                guard arguments.isEmpty else {
                    throw GoDiagnostic(
                        position: position,
                        message: "too many arguments in call to context.Background")
                }
                return .named("context.Context")
            }
            if case .identifier(let packageName, _) = base,
                packageName == "context",
                importedPaths.contains("context"),
                name == "WithCancel"
            {
                guard arguments.count == 1 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in call to context.WithCancel")
                }
                try require(arguments[0], assignableTo: .named("context.Context"))
                return .named("context.Context")
            }
            if case .identifier(let packageName, _) = base,
                packageName == "context",
                importedPaths.contains("context"),
                name == "WithTimeout"
            {
                guard arguments.count == 2 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in call to context.WithTimeout")
                }
                try require(arguments[0], assignableTo: .named("context.Context"))
                try require(arguments[1], assignableTo: .int)
                return .named("context.Context")
            }
            if case .identifier(let packageName, _) = base,
                packageName == "net",
                importedPaths.contains("net")
            {
                switch name {
                case "Dial":
                    guard arguments.count == 2 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to net.Dial")
                    }
                    try require(arguments[0], assignableTo: .string)
                    try require(arguments[1], assignableTo: .string)
                    return .named("net.Conn")
                case "Listen":
                    guard arguments.count == 2 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to net.Listen")
                    }
                    try require(arguments[0], assignableTo: .string)
                    try require(arguments[1], assignableTo: .string)
                    return .named("net.Listener")
                case "LookupHost":
                    guard arguments.count == 1 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to net.LookupHost")
                    }
                    try require(arguments[0], assignableTo: .string)
                    return .slice(.string)
                default:
                    break
                }
            }
            if case .identifier(let packageName, _) = base,
                (packageName == "http" && importedPaths.contains("net/http"))
            {
                switch name {
                case "HandleFunc":
                    guard arguments.count == 2 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to http.HandleFunc")
                    }
                    try require(arguments[0], assignableTo: .string)
                    return .void
                case "ListenAndServe":
                    guard arguments.count == 2 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to http.ListenAndServe")
                    }
                    try require(arguments[0], assignableTo: .string)
                    return .interface([])
                case "Get":
                    guard arguments.count == 1 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to http.Get")
                    }
                    try require(arguments[0], assignableTo: .string)
                    return .named("http.Response")
                default:
                    break
                }
            }
            if case .identifier(let packageName, _) = base,
                packageName == "runtime",
                importedPaths.contains("runtime"),
                name == "GC"
            {
                guard arguments.isEmpty else {
                    throw GoDiagnostic(
                        position: position,
                        message: "too many arguments in call to runtime.GC")
                }
                return .void
            }
            if let syncReceiverType = try? type(of: base) {
                let syncReceiverName: String?
                let syncReceiverIsPointer: Bool
                switch syncReceiverType {
                case .named(let typeName):
                    syncReceiverName = typeName
                    syncReceiverIsPointer = false
                case .pointer(.named(let typeName)):
                    syncReceiverName = typeName
                    syncReceiverIsPointer = true
                default:
                    syncReceiverName = nil
                    syncReceiverIsPointer = false
                }
                if syncReceiverName == "sync.Mutex", name == "Lock" || name == "Unlock" {
                    guard arguments.isEmpty else {
                        throw GoDiagnostic(
                            position: position,
                            message: "too many arguments in call to \(name)")
                    }
                    guard syncReceiverIsPointer || isAddressable(base) else {
                        throw GoDiagnostic(
                            position: base.position,
                            message: "cannot call pointer method on non-addressable value")
                    }
                    return .void
                }
                if syncReceiverName == "sync.WaitGroup" {
                    guard syncReceiverIsPointer || isAddressable(base) else {
                        throw GoDiagnostic(
                            position: base.position,
                            message: "cannot call pointer method on non-addressable value")
                    }
                    switch name {
                    case "Add":
                        guard arguments.count == 1 else {
                            throw GoDiagnostic(
                                position: position,
                                message: "wrong number of arguments in call to Add")
                        }
                        try require(arguments[0], assignableTo: .int)
                        return .void
                    case "Done", "Wait":
                        guard arguments.isEmpty else {
                            throw GoDiagnostic(
                                position: position,
                                message: "too many arguments in call to \(name)")
                        }
                        return .void
                    default:
                        break
                    }
                }
                if syncReceiverName == "context.Context" {
                    switch name {
                    case "Done":
                        guard arguments.isEmpty else {
                            throw GoDiagnostic(
                                position: position,
                                message: "too many arguments in call to Done")
                        }
                        return .channel(direction: .receiveOnly, element: .int)
                    case "Err":
                        guard arguments.isEmpty else {
                            throw GoDiagnostic(
                                position: position,
                                message: "too many arguments in call to Err")
                        }
                        return .interface([])
                    default:
                        break
                    }
                }
                if syncReceiverName == "net.Conn" {
                    switch name {
                    case "Read", "Write":
                        guard arguments.count == 1 else {
                            throw GoDiagnostic(
                                position: position,
                                message: "wrong number of arguments in call to \(name)")
                        }
                        try require(arguments[0], assignableTo: .slice(.int))
                        return .int
                    case "Close":
                        guard arguments.isEmpty else {
                            throw GoDiagnostic(
                                position: position,
                                message: "too many arguments in call to Close")
                        }
                        return .interface([])
                    default:
                        break
                    }
                }
                if syncReceiverName == "net.Listener" {
                    switch name {
                    case "Accept":
                        guard arguments.isEmpty else {
                            throw GoDiagnostic(
                                position: position,
                                message: "too many arguments in call to Accept")
                        }
                        return .named("net.Conn")
                    case "Close":
                        guard arguments.isEmpty else {
                            throw GoDiagnostic(
                                position: position,
                                message: "too many arguments in call to Close")
                        }
                        return .interface([])
                    default:
                        break
                    }
                }
            }
            if case .identifier(let baseName, _) = base,
                lookup(baseName)?.type == .pointer(.named("testing.T"))
            {
                switch name {
                case "Error", "Fatal":
                    for argument in arguments where try type(of: argument) == .void {
                        throw GoDiagnostic(
                            position: argument.position, message: "no value used as value")
                    }
                    return .void
                case "Run":
                    guard arguments.count == 2,
                        try type(of: arguments[0]) == .string,
                        case .function(let parameters, let results) = try type(of: arguments[1]),
                        parameters == [.pointer(.named("testing.T"))], results.isEmpty
                    else {
                        throw GoDiagnostic(
                            position: position,
                            message: "invalid arguments in call to testing.T.Run")
                    }
                    return .bool
                default:
                    break
                }
            }
            // Local package function call: pkg.Function(args...)
            if case .identifier(let packageName, _) = base,
                let export = resolvePackageExport(packageName),
                let funcExport = export.functions[name]
            {
                guard arguments.count == funcExport.parameters.count else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in call to \(packageName).\(name)")
                }
                for (argument, paramType) in zip(arguments, funcExport.parameters) {
                    let argType = try type(of: argument)
                    guard isAssignable(argType, to: paramType) else {
                        throw GoDiagnostic(
                            position: argument.position,
                            message: "cannot use \(argType) as \(paramType) value in argument to \(packageName).\(name)")
                    }
                }
                return funcExport.results.first ?? .void
            }
            let baseType = try type(of: base)
            let candidates: [String]
            switch baseType {
            case .named(let baseName):
                candidates = [
                    methodKey(baseName: baseName, pointer: false, method: name),
                    methodKey(baseName: baseName, pointer: true, method: name),
                ]
            case .pointer(.named(let baseName)):
                candidates = [
                    methodKey(baseName: baseName, pointer: true, method: name),
                    methodKey(baseName: baseName, pointer: false, method: name),
                ]
            default:
                candidates = []
            }
            guard let match = candidates.first(where: { methodSignatures[$0] != nil }),
                let signature = methodSignatures[match]
            else {
                // Check if it's an interface method call
                if case .interface(let methods) = underlying(baseType),
                    let method = methods.first(where: { $0.name == name })
                {
                    guard arguments.count == method.parameters.count else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to \(name)")
                    }
                    for (argument, parameterType) in zip(arguments, method.parameters) {
                        try require(argument, assignableTo: parameterType)
                    }
                    return method.results.first ?? .void
                }
                throw GoDiagnostic(
                    position: callee.position,
                    message: "\(baseType) has no field or method \(name)")
            }
            if match.first == "*", case .named = baseType, !isAddressable(base) {
                throw GoDiagnostic(
                    position: base.position,
                    message: "cannot call pointer method on non-addressable value")
            }
            guard arguments.count <= signature.parameters.count else {
                throw GoDiagnostic(position: position, message: "too many arguments in call to \(name)")
            }
            guard arguments.count == signature.parameters.count else {
                throw GoDiagnostic(position: position, message: "not enough arguments in call to \(name)")
            }
            for (argument, parameterType) in zip(arguments, signature.parameters) {
                try require(argument, assignableTo: parameterType)
            }
            return signature.results.first ?? .void
        case .unary(let unaryOperator, let operand, let position):
            switch unaryOperator {
            case .plus, .minus:
                let operandType = try type(of: operand)
                guard isInteger(operandType) else {
                    throw GoDiagnostic(position: position, message: "operator requires integer operand")
                }
                return operandType
            case .not:
                let operandType = try type(of: operand)
                guard isBool(operandType) else {
                    throw GoDiagnostic(position: position, message: "operator ! not defined on \(operandType)")
                }
                return operandType
            case .address:
                return .pointer(try assignableType(of: operand))
            case .dereference:
                let operandType = try type(of: operand)
                guard case .pointer(let pointee) = operandType else {
                    throw GoDiagnostic(position: position, message: "cannot indirect \(operandType)")
                }
                return pointee
            case .receive:
                let operandType = underlying(try type(of: operand))
                guard case .channel(let direction, let elementType) = operandType else {
                    throw GoDiagnostic(position: position, message: "cannot receive from non-channel value")
                }
                guard direction != .sendOnly else {
                    throw GoDiagnostic(position: position, message: "cannot receive from send-only channel")
                }
                return elementType
            }
        case .binary(let left, let binaryOperator, let right, let position):
            let leftType = try type(of: left)
            let rightType = try type(of: right)
            guard
                leftType == rightType
                    || ((leftType == .nilType || rightType == .nilType)
                        && (isPointer(leftType) || isPointer(rightType)
                            || isSlice(leftType) || isSlice(rightType)
                            || isMap(leftType) || isMap(rightType)
                            || isChannel(leftType) || isChannel(rightType)
                            || isInterface(leftType) || isInterface(rightType)))
            else {
                throw GoDiagnostic(position: position, message: "mismatched types \(leftType) and \(rightType)")
            }
            switch binaryOperator {
            case .add:
                guard isInteger(leftType) || isString(leftType) else {
                    throw GoDiagnostic(position: position, message: "operator + not defined on \(leftType)")
                }
                return leftType
            case .subtract, .multiply:
                guard isInteger(leftType) else {
                    throw GoDiagnostic(position: position, message: "operator requires integer operands")
                }
                return leftType
            case .divide, .remainder:
                guard isInteger(leftType) else {
                    throw GoDiagnostic(position: position, message: "operator requires integer operands")
                }
                if case .integer(0, let zeroPosition) = right {
                    throw GoDiagnostic(position: zeroPosition, message: "division by zero")
                }
                return leftType
            case .equal, .notEqual:
                if (leftType == .nilType || rightType == .nilType)
                    && (isPointer(leftType) || isPointer(rightType)
                        || isSlice(leftType) || isSlice(rightType)
                        || isMap(leftType) || isMap(rightType)
                        || isChannel(leftType) || isChannel(rightType)
                        || isInterface(leftType) || isInterface(rightType))
                {
                    return .bool
                }
                guard isComparable(leftType) else {
                    throw GoDiagnostic(position: position, message: "values are not comparable")
                }
                return .bool
            case .less, .lessEqual, .greater, .greaterEqual:
                guard isInteger(leftType) || isString(leftType) else {
                    throw GoDiagnostic(position: position, message: "operator is not defined on \(leftType)")
                }
                return .bool
            case .logicalAnd, .logicalOr:
                guard isBool(leftType) else {
                    throw GoDiagnostic(position: position, message: "operator requires boolean operands")
                }
                return leftType
            }
        }
    }

    mutating func assignableType(of expression: GoExpression) throws -> GoType {
        switch expression {
        case .identifier(let name, let position):
            guard let binding = lookup(name) else {
                throw GoDiagnostic(position: position, message: "undefined: \(name)")
            }
            guard !binding.isConstant else {
                throw GoDiagnostic(position: position, message: "cannot assign to \(name)")
            }
            return binding.type
        case .selector(let base, let name, let position):
            let baseType = try assignableType(of: base)
            guard let field = structFields(of: baseType)?.first(where: { $0.name == name }) else {
                throw GoDiagnostic(
                    position: position,
                    message: "\(baseType) has no field or method \(name)")
            }
            return field.type
        case .unary(.dereference, let operand, let position):
            let operandType = try type(of: operand)
            guard case .pointer(let pointee) = operandType else {
                throw GoDiagnostic(position: position, message: "cannot indirect \(operandType)")
            }
            return pointee
        case .index(let base, let index, let position):
            let baseType = try type(of: base)
            switch underlying(baseType) {
            case .array(_, let element):
                guard isInteger(try type(of: index)) else {
                    throw GoDiagnostic(position: index.position, message: "index must be integer")
                }
                _ = try assignableType(of: base)
                return element
            case .slice(let element):
                guard isInteger(try type(of: index)) else {
                    throw GoDiagnostic(position: index.position, message: "index must be integer")
                }
                return element
            case .map(let keyType, let valueType):
                let indexType = try type(of: index)
                guard isAssignable(indexType, to: keyType) else {
                    throw GoDiagnostic(
                        position: index.position,
                        message: "cannot use \(indexType) as \(keyType) value in map index")
                }
                return valueType
            default:
                throw GoDiagnostic(position: position, message: "cannot assign to index expression")
            }
        default:
            throw GoDiagnostic(position: expression.position, message: "cannot assign to expression")
        }
    }

    mutating func require(_ expression: GoExpression, assignableTo expected: GoType) throws {
        let actual = try type(of: expression)
        guard isAssignable(actual, to: expected) else {
            throw GoDiagnostic(
                position: expression.position,
                message: "cannot use \(actual) as \(expected) value")
        }
    }

    mutating func requireBool(_ expression: GoExpression) throws {
        let expressionType = try type(of: expression)
        guard isBool(expressionType) else {
            throw GoDiagnostic(
                position: expression.position,
                message: "non-boolean condition in control statement")
        }
    }

    func declaredType(_ expression: GoTypeExpression) throws -> GoType {
        switch expression {
        case .named(let name, let position):
            switch name {
            case "int": return .int
            case "string": return .string
            case "bool": return .bool
            case "any": return .interface([])
            case "error": return builtinErrorType()
            case "testing.T", "sync.Mutex", "sync.WaitGroup",
                "context.Context", "context.CancelFunc",
                "net.Conn", "net.Listener",
                "http.Response", "http.ResponseWriter", "http.Request":
                return .named(name)
            default:
                guard availableTypes.contains(name) else {
                    throw GoDiagnostic(position: position, message: "undefined: \(name)")
                }
                return .named(name)
            }
        case .structure(let fields, _):
            var names: Set<String> = []
            return .structure(
                try fields.map { field in
                    guard names.insert(field.name).inserted else {
                        throw GoDiagnostic(
                            position: field.position,
                            message: "\(field.name) redeclared in this block")
                    }
                    return GoStructFieldType(name: field.name, type: try declaredType(field.type))
                })
        case .pointer(let pointee, _):
            return .pointer(try declaredType(pointee))
        case .array(let length, let element, _):
            return .array(length: length, element: try declaredType(element))
        case .slice(let element, _):
            return .slice(try declaredType(element))
        case .map(let key, let value, let position):
            let keyType = try declaredType(key)
            guard isComparable(keyType) else {
                throw GoDiagnostic(position: position, message: "invalid map key type \(keyType)")
            }
            return .map(key: keyType, value: try declaredType(value))
        case .channel(let direction, let element, _):
            return .channel(direction: direction, element: try declaredType(element))
        case .interface(let methods, _):
            return .interface(try methods.map { method in
                GoInterfaceMethod(
                    name: method.name,
                    parameters: try method.parameters.map(declaredType),
                    results: try method.results.map(declaredType))
            })
        }
    }

    func underlying(_ type: GoType, visiting: Set<String> = []) -> GoType {
        guard case .named(let name) = type,
            !visiting.contains(name),
            let definition = typeDefinitions[name]
        else { return type }
        var next = visiting
        next.insert(name)
        return underlying(definition.underlying, visiting: next)
    }

    func structFields(of type: GoType) -> [GoStructFieldType]? {
        let candidate: GoType
        if case .pointer(let pointee) = type {
            candidate = pointee
        } else {
            candidate = type
        }
        // Built-in stdlib struct types
        if case .named(let name) = candidate {
            switch name {
            case "http.Response":
                return [
                    GoStructFieldType(name: "StatusCode", type: .int),
                    GoStructFieldType(name: "Body", type: .string),
                ]
            default:
                break
            }
        }
        guard case .structure(let fields) = underlying(candidate) else { return nil }
        return fields
    }

    func isInteger(_ type: GoType) -> Bool { underlying(type) == .int }
    func isString(_ type: GoType) -> Bool { underlying(type) == .string }
    func isBool(_ type: GoType) -> Bool { underlying(type) == .bool }

    func isPointer(_ type: GoType) -> Bool {
        if case .pointer = type { return true }
        return false
    }

    func isSlice(_ type: GoType) -> Bool {
        if case .slice = underlying(type) { return true }
        return false
    }

    func isMap(_ type: GoType) -> Bool {
        if case .map = underlying(type) { return true }
        return false
    }

    func isChannel(_ type: GoType) -> Bool {
        if case .channel = underlying(type) { return true }
        return false
    }

    func isInterface(_ type: GoType) -> Bool {
        if case .interface = underlying(type) { return true }
        return false
    }

    func isArrayOrSlice(_ type: GoType) -> Bool {
        switch underlying(type) {
        case .array, .slice: return true
        default: return false
        }
    }

    func isAssignable(_ actual: GoType, to expected: GoType) -> Bool {
        if actual == expected { return true }
        if actual == .nilType
            && (isPointer(expected) || isSlice(expected) || isMap(expected) || isChannel(expected))
        {
            return true
        }
        if case .channel(let actualDirection, let actualElement) = underlying(actual),
            case .channel(let expectedDirection, let expectedElement) = underlying(expected),
            actualElement == expectedElement
        {
            return actualDirection == expectedDirection || actualDirection == .bidirectional
        }
        if actual == .nilType, case .interface = expected { return true }
        if case .interface(let methods) = underlying(expected) {
            // Empty interface accepts anything
            if methods.isEmpty { return true }
            // Check if actual type satisfies the interface (method set check)
            return satisfies(actual, interface: methods)
        }
        return false
    }

    func satisfies(_ type: GoType, interface methods: [GoInterfaceMethod]) -> Bool {
        for method in methods {
            let candidates: [String]
            switch type {
            case .named(let name):
                candidates = [
                    methodKey(baseName: name, pointer: false, method: method.name)
                ]
            case .pointer(.named(let name)):
                candidates = [
                    methodKey(baseName: name, pointer: true, method: method.name),
                    methodKey(baseName: name, pointer: false, method: method.name),
                ]
            default:
                return false
            }
            guard let match = candidates.first(where: { methodSignatures[$0] != nil }),
                let signature = methodSignatures[match]
            else { return false }
            guard signature.parameters.count == method.parameters.count,
                signature.results.count == method.results.count
            else { return false }
            for (p1, p2) in zip(signature.parameters, method.parameters) where p1 != p2 {
                return false
            }
            for (r1, r2) in zip(signature.results, method.results) where r1 != r2 {
                return false
            }
        }
        return true
    }

    func isComparable(_ type: GoType) -> Bool {
        switch underlying(type) {
        case .int, .string, .bool, .pointer, .nilType, .interface, .channel: return true
        case .structure(let fields): return fields.allSatisfy { isComparable($0.type) }
        case .array(_, let element): return isComparable(element)
        case .slice: return false
        default: return false
        }
    }

    func lookup(_ name: String) -> Binding? {
        for scope in scopes.reversed() {
            if let binding = scope[name] { return binding }
        }
        return nil
    }

    func receiverIdentity(_ type: GoType) -> (baseName: String, isPointer: Bool)? {
        switch type {
        case .named(let name): return (name, false)
        case .pointer(.named(let name)): return (name, true)
        default: return nil
        }
    }

    func isAddressable(_ expression: GoExpression) -> Bool {
        switch expression {
        case .identifier: return true
        case .selector(let base, _, _): return isAddressable(base)
        case .index: return true
        case .unary(.dereference, _, _): return true
        default: return false
        }
    }

    func methodKey(baseName: String, pointer: Bool, method: String) -> String {
        "\(pointer ? "*" : "")\(baseName).\(method)"
    }

    func syntheticPosition() -> GoSourcePosition {
        GoSourcePosition(path: "<input>", offset: 0, line: 1, column: 1)
    }

    func callName(_ callee: GoExpression) -> String {
        switch callee {
        case .identifier(let name, _): return name
        case .selector(_, let name, _): return name
        default: return "<call>"
        }
    }

    func resolvePackageExport(_ packageName: String) -> GoPackageExport? {
        // Check direct name match
        if let export = availablePackages[packageName] { return export }
        // Check import path suffix match (e.g., "math" matches "example/math")
        for (path, export) in availablePackages {
            let lastComponent = path.split(separator: "/").last.map(String.init) ?? path
            if lastComponent == packageName { return export }
        }
        return nil
    }

    mutating func callResultTypes(
        callee: GoExpression,
        arguments: [GoExpression],
        position: GoSourcePosition
    ) throws -> [GoType] {
        if case .identifier(let name, let namePosition) = callee {
            guard let signature = functionSignatures[name] else {
                throw GoDiagnostic(position: namePosition, message: "undefined: \(name)")
            }
            guard arguments.count == signature.parameters.count else {
                throw GoDiagnostic(
                    position: position,
                    message: "wrong number of arguments in call to \(name)")
            }
            for (argument, parameterType) in zip(arguments, signature.parameters) {
                let argumentType = try type(of: argument)
                guard isAssignable(argumentType, to: parameterType) else {
                    throw GoDiagnostic(
                        position: argument.position,
                        message: "cannot use \(argumentType) as \(parameterType) value in argument to \(name)")
                }
            }
            return signature.results
        }
        if case .selector(let base, let name, _) = callee {
            if case .identifier(let packageName, _) = base,
                packageName == "fmt",
                importedPaths.contains("fmt")
            {
                return []
            }
            if case .identifier("strconv", _) = base,
                importedPaths.contains("strconv"),
                name == "Atoi"
            {
                guard arguments.count == 1 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in call to strconv.Atoi")
                }
                try require(arguments[0], assignableTo: .string)
                return [.int, .interface([])]
            }
            if case .identifier("userland", _) = base,
                importedPaths.contains("swiftix/userland"),
                name == "ReadInput"
            {
                guard arguments.count == 2 else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in call to userland.ReadInput")
                }
                try require(arguments[0], assignableTo: .string)
                try require(arguments[1], assignableTo: .slice(.string))
                return [.string, .int]
            }
            if case .identifier(let packageName, _) = base,
                packageName == "context",
                importedPaths.contains("context")
            {
                switch name {
                case "WithCancel":
                    guard arguments.count == 1 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to context.WithCancel")
                    }
                    try require(arguments[0], assignableTo: .named("context.Context"))
                    return [.named("context.Context"), .named("context.CancelFunc")]
                case "WithTimeout":
                    guard arguments.count == 2 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to context.WithTimeout")
                    }
                    try require(arguments[0], assignableTo: .named("context.Context"))
                    try require(arguments[1], assignableTo: .int)
                    return [.named("context.Context"), .named("context.CancelFunc")]
                default:
                    break
                }
            }
            if case .identifier(let packageName, _) = base,
                packageName == "net",
                importedPaths.contains("net")
            {
                switch name {
                case "Dial":
                    guard arguments.count == 2 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to net.Dial")
                    }
                    try require(arguments[0], assignableTo: .string)
                    try require(arguments[1], assignableTo: .string)
                    return [.named("net.Conn"), .interface([])]
                case "Listen":
                    guard arguments.count == 2 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to net.Listen")
                    }
                    try require(arguments[0], assignableTo: .string)
                    try require(arguments[1], assignableTo: .string)
                    return [.named("net.Listener"), .interface([])]
                case "LookupHost":
                    guard arguments.count == 1 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to net.LookupHost")
                    }
                    try require(arguments[0], assignableTo: .string)
                    return [.slice(.string), .interface([])]
                default:
                    break
                }
            }
            // Handle net.Conn/net.Listener method calls
            if let receiverType = try? type(of: base) {
                switch (receiverType, name) {
                case (.named("net.Conn"), "Read"), (.named("net.Conn"), "Write"):
                    return [.int, .interface([])]
                case (.named("net.Listener"), "Accept"):
                    return [.named("net.Conn"), .interface([])]
                default:
                    break
                }
            }
            if case .identifier(let packageName, _) = base,
                (packageName == "http" && importedPaths.contains("net/http"))
            {
                switch name {
                case "Get":
                    guard arguments.count == 1 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to http.Get")
                    }
                    try require(arguments[0], assignableTo: .string)
                    return [.named("http.Response"), .interface([])]
                default:
                    break
                }
            }
            let baseType = try type(of: base)
            let candidates: [String]
            switch baseType {
            case .named(let baseName):
                candidates = [
                    methodKey(baseName: baseName, pointer: false, method: name),
                    methodKey(baseName: baseName, pointer: true, method: name),
                ]
            case .pointer(.named(let baseName)):
                candidates = [
                    methodKey(baseName: baseName, pointer: true, method: name),
                    methodKey(baseName: baseName, pointer: false, method: name),
                ]
            default:
                candidates = []
            }
            guard let match = candidates.first(where: { methodSignatures[$0] != nil }),
                let signature = methodSignatures[match]
            else {
                throw GoDiagnostic(
                    position: callee.position,
                    message: "\(baseType) has no field or method \(name)")
            }
            guard arguments.count == signature.parameters.count else {
                throw GoDiagnostic(
                    position: position,
                    message: "wrong number of arguments in call to \(name)")
            }
            for (argument, parameterType) in zip(arguments, signature.parameters) {
                try require(argument, assignableTo: parameterType)
            }
            return signature.results
        }
        throw GoDiagnostic(position: position, message: "unsupported function call in multi-value context")
    }

    func switchCaseConstant(_ expression: GoExpression) -> SwitchCaseConstant? {
        switch expression {
        case .integer(let value, _): return .int(value)
        case .string(let value, _): return .string(value)
        case .identifier("true", _): return .bool(true)
        case .identifier("false", _): return .bool(false)
        default: return nil
        }
    }

    func isSelectCommunication(_ statement: GoStatement) -> Bool {
        switch statement {
        case .sendStatement:
            return true
        case .expression(.unary(.receive, _, _)):
            return true
        case .declaration(_, _, .some(.unary(.receive, _, _)), _, _):
            return true
        case .assignment(_, .unary(.receive, _, _), _):
            return true
        case .multiDeclaration(_, .unary(.receive, _, _), _):
            return true
        case .multiAssignment(_, .unary(.receive, _, _), _):
            return true
        default:
            return false
        }
    }

    func blockTerminates(_ block: GoBlock) -> Bool {
        guard let last = block.statements.last else { return false }
        return statementTerminates(last)
    }

    func statementTerminates(_ statement: GoStatement) -> Bool {
        switch statement {
        case .returnValues:
            return true
        case .ifStatement(_, let thenBlock, let elseBlock, _):
            guard let elseBlock else { return false }
            return blockTerminates(thenBlock) && blockTerminates(elseBlock)
        case .forStatement(_, let condition, _, let body, _):
            return condition == nil && !containsBreakTargetingCurrentConstruct(body)
        case .switchStatement(_, let cases, _):
            guard cases.contains(where: \.isDefault), !cases.isEmpty else { return false }
            return cases.allSatisfy {
                blockTerminates($0.body) && !containsBreakTargetingCurrentConstruct($0.body)
            }
        default:
            return false
        }
    }

    func containsBreakTargetingCurrentConstruct(_ block: GoBlock) -> Bool {
        for statement in block.statements {
            switch statement {
            case .breakStatement:
                return true
            case .ifStatement(_, let thenBlock, let elseBlock, _):
                if containsBreakTargetingCurrentConstruct(thenBlock) { return true }
                if let elseBlock, containsBreakTargetingCurrentConstruct(elseBlock) { return true }
            case .forStatement, .forRangeStatement, .switchStatement:
                continue
            default:
                continue
            }
        }
        return false
    }
}
