/// Static type checking for the Swiftix Go language subset.

import SwiftixGoRuntime

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
        case .array(let length, let element):
            // The marker type of a variadic parameter.
            return length < 0 ? "...\(element)" : "[\(length)]\(element)"
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
        let resolved = try GoNames.reporting {
            try GoNames.resolve(program: GoNames.resolve(files))
        }
        return try GoNames.reporting(on: resolved) {
            try check(resolved: resolved, availablePackages: availablePackages)
        }
    }

    private static func check(
        resolved files: [GoFile],
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
                // An import made for its initialization names nothing.
                if declaration.name == GoImportName.blank { continue }
                guard importedPaths.insert(declaration.path).inserted else {
                    throw GoDiagnostic(
                        position: declaration.position,
                        message: "\(importName) redeclared in this block")
                }
            }
            importedPathsByFile.append(importedPaths)

            for declaration in file.typeDeclarations {
                guard GoPredeclared.namedType(declaration.name) == nil else {
                    throw GoDiagnostic(
                        position: declaration.position,
                        message: "cannot redeclare predeclared type \(declaration.name)")
                }
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
                try reservePackageName(
                    function.name, at: file.namePosition(of: function), names: &packageNames)
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
        for target in files.lazy.flatMap(\.aliasTargets) {
            _ = try resolve(target, availableTypes: availableTypes)
        }
        for definition in typeDefinitions.values {
            try rejectRecursiveValueType(
                definition.name,
                definitions: typeDefinitions,
                position: typeSyntax[definition.name]?.position ?? syntheticPosition())
        }

        var functionSignatures: [String: FunctionSignature] = [:]
        var methodSignatures: [String: FunctionSignature] = [:]
        var methodPositions: [String: GoSourcePosition] = [:]
        for (file, function) in files.flatMap({ file in file.functions.map { (file, $0) } }) {
            if function.name == "init" {
                guard function.receiver == nil,
                    function.parameters.isEmpty,
                    function.resultTypes.isEmpty
                else {
                    throw GoDiagnostic(
                        position: file.namePosition(of: function),
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
                if let earlier = receiverMethodKeys.lazy.compactMap({ methodPositions[$0] }).first {
                    throw GoDiagnostic(
                        position: file.namePosition(of: function),
                        message:
                            "method \(identity.baseName).\(function.name) already declared at "
                            + "\(earlier.path):\(earlier.line):\(earlier.column)")
                }
                methodSignatures[key] = signature
                methodPositions[key] = file.namePosition(of: function)
            } else {
                functionSignatures[function.name] = signature
            }
        }

        let globals = files.flatMap(\.globalDeclarations)
        // A package-level initializer sees the imports of its own file.
        var importedPathsByGlobal: [String: Set<String>] = [:]
        for (file, importedPaths) in zip(files, importedPathsByFile) {
            for declaration in file.globalDeclarations {
                importedPathsByGlobal[declaration.name] = importedPaths
            }
        }
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
                        importedPaths: importedPathsByGlobal[declaration.name] ?? [],
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
                        isConstant: declaration.isConstant,
                        constantValue: declaration.isConstant
                            ? checker.untypedConstantValue(expression) : nil)
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
                importedPaths: importedPathsByGlobal[declaration.name] ?? [],
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
                files.lazy.compactMap { file in
                    file.functions.first { $0.name == "main" }.map(file.namePosition(of:))
                }.first ?? syntheticPosition(path: first.path)
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
                    globalBindings: globalBindings,
                    namePositions: file.namePositions)
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

    /// Whether the run-time library package at `path` has `member`: a type,
    /// a value, or a function. Nothing lists what such a package declares.
    /// The checker knows each member where a program can write it, so it is
    /// asked the way a program asks: as a type, as a value, and as a call.
    static func libraryDeclares(path: String, member: String) -> Bool {
        let name = GoImportName.defaultName(ofPath: path)
        let position = syntheticPosition()
        if (try? resolve(.named(name + "." + member, position: position), availableTypes: [])) != nil {
            return true
        }
        let selection = GoExpression.selector(
            base: .identifier(name, position: position), name: member, position: position)
        for probe in [selection, .call(callee: selection, arguments: [], position: position)] {
            var checker = FunctionChecker(
                importedPaths: [path], functionSignatures: [:], methodSignatures: [:],
                typeDefinitions: [:], availableTypes: [])
            do {
                _ = try checker.type(of: probe)
                return true
            } catch let diagnostic as GoDiagnostic {
                // Anything but not knowing it is knowing it: too few
                // arguments, a result nothing takes.
                if !diagnostic.message.hasPrefix("undefined: ") { return true }
            } catch {
                return true
            }
        }
        return false
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
            case "byte", "uint8": return GoPredeclared.byte
            case "testing.T", "sync.Mutex", "sync.WaitGroup",
                "context.Context", "context.CancelFunc",
                "net.Conn", "net.Listener",
                "http.Response", "http.ResponseWriter", "http.Request",
                "time.Time", "os.File":
                return .named(name)
            default:
                guard availableTypes.contains(name) else {
                    throw GoDiagnostic(
                        position: position,
                        message: GoPredeclared.unsupportedNumericTypes.contains(name)
                            ? GoPredeclared.unsupportedTypeMessage(name)
                            : "undefined: \(name)")
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
    /// Value of a constant declared without a type from an untyped integer
    /// constant expression. Such a name stays usable with any integer type.
    var constantValue: Int64? = nil
    /// Where a statement of a function declared the variable. Go requires
    /// such a variable to be read; a parameter, a result, and a variable of
    /// the package have no position and need not be.
    var position: GoSourcePosition? = nil
    var isUsed = false
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
    /// Where the names of a declaration of several names are, by the
    /// offset of the declaration.
    let namePositions: [Int: [GoSourcePosition]]
    /// The variables whose scope ended without a statement reading them.
    var unused: [(position: GoSourcePosition, name: String)] = []
    /// Whether the function is being checked again after an error, only to
    /// learn which of its variables are read: a statement that fails is
    /// passed over.
    var isRecovering = false

    init(
        importedPaths: Set<String>,
        functionSignatures: [String: FunctionSignature],
        methodSignatures: [String: FunctionSignature],
        typeDefinitions: [String: GoTypeDefinition],
        availableTypes: Set<String>,
        availablePackages: [String: GoPackageExport] = [:],
        globalBindings: [String: Binding] = [:],
        namePositions: [Int: [GoSourcePosition]] = [:]
    ) {
        self.importedPaths = importedPaths
        self.functionSignatures = functionSignatures
        self.methodSignatures = methodSignatures
        self.typeDefinitions = typeDefinitions
        self.availableTypes = availableTypes
        self.availablePackages = availablePackages
        self.scopes = [globalBindings, [:]]
        self.namePositions = namePositions
    }

    /// The package `expression` names: the name of one the file imports,
    /// which no variable hides.
    func importedPackage(named expression: GoExpression) -> String? {
        guard case .identifier(let name, _) = expression, lookup(name) == nil,
            importedPaths.contains(where: { GoImportName.defaultName(ofPath: $0) == name })
        else { return nil }
        return name
    }

    // MARK: Unused variables

    /// A statement reads the variable `name`.
    mutating func use(_ name: String) {
        for index in scopes.indices.dropFirst().reversed() where scopes[index][name] != nil {
            scopes[index][name]?.isUsed = true
            return
        }
    }

    /// The variable `name` of the innermost scope was declared at `position`.
    mutating func place(_ name: String, at position: GoSourcePosition) {
        // A stand-in the checker made up is nothing the source declares.
        guard name != GoValueList.blank, !name.hasPrefix("$"),
            let binding = scopes[scopes.count - 1][name], !binding.isConstant,
            binding.position == nil
        else { return }
        scopes[scopes.count - 1][name]?.position = position
    }

    /// Marks every variable the expressions of `statement` read. Not every
    /// path of the checker types each operand, so what is read is settled
    /// here, on the tree: every name is a read except the bare target of an
    /// assignment. The statements of a nested block are read when they are
    /// checked, in their own scope.
    mutating func read(_ statement: GoStatement) {
        switch statement {
        case .declaration(_, _, let expression, _, _):
            if let expression { read(expression) }
        case .multiDeclaration(_, let expression, _):
            read(expression)
        case .assignment(let target, let expression, _):
            if case .identifier = target {} else { read(target) }
            read(expression)
        case .multiAssignment(let targets, let expression, _):
            for target in targets {
                if case .identifier = target {} else { read(target) }
            }
            read(expression)
        case .increment(let target, _, _):
            read(target)
        case .expression(let expression), .deferStatement(let expression, _),
            .goStatement(let expression, _):
            read(expression)
        case .returnValues(let values, _):
            values.forEach { read($0) }
        case .sendStatement(let channel, let value, _):
            read(channel)
            read(value)
        case .ifStatement(let condition, _, _, _):
            read(condition)
        case .forRangeStatement(_, _, let collection, _, _):
            read(collection)
        case .switchStatement(let expression, let cases, _):
            if let expression { read(expression) }
            for switchCase in cases { switchCase.expressions.forEach { read($0) } }
        case .forStatement, .selectStatement, .breakStatement, .continueStatement:
            // The clauses of a `for` and the cases of a `select` come after
            // what the statement itself declares.
            break
        }
    }

    /// A statement failed while the function is checked past its errors.
    /// Everything it and the blocks inside it name counts as read, and what
    /// it would have declared is declared, so that later statements can
    /// read it.
    mutating func recover(from statement: GoStatement) {
        readAll(statement)
        var names: [String] = []
        var isConstant = false
        switch statement {
        case .declaration(let name, _, _, let constant, _):
            names = [name]
            isConstant = constant
        case .multiDeclaration(let declared, let expression, _):
            names = declared
            isConstant = expression.variables?.isConstant ?? false
        default:
            return
        }
        for name in names where name != GoValueList.blank && scopes[scopes.count - 1][name] == nil {
            scopes[scopes.count - 1][name] = Binding(type: .int, isConstant: isConstant)
        }
        place(statement)
    }

    mutating func readAll(_ statement: GoStatement) {
        read(statement)
        switch statement {
        case .ifStatement(_, let thenBlock, let elseBlock, _):
            thenBlock.statements.forEach { readAll($0) }
            elseBlock?.statements.forEach { readAll($0) }
        case .forStatement(let initializer, let condition, let post, let body, _):
            if let initializer { readAll(initializer) }
            if let condition { read(condition) }
            if let post { readAll(post) }
            body.statements.forEach { readAll($0) }
        case .forRangeStatement(_, _, _, let body, _):
            body.statements.forEach { readAll($0) }
        case .switchStatement(_, let cases, _):
            for switchCase in cases { switchCase.body.statements.forEach { readAll($0) } }
        case .selectStatement(let cases, _):
            for selectCase in cases {
                if let communication = selectCase.communication { readAll(communication) }
                selectCase.body.statements.forEach { readAll($0) }
            }
        default:
            break
        }
    }

    mutating func read(_ expression: GoExpression) {
        switch expression {
        case .integer, .string, .typeExpression, .functionLiteral:
            // A literal's body is checked as the function it is.
            break
        case .identifier(let name, _):
            use(name)
        case .selector(let base, _, _), .typeAssertion(let base, _, _):
            read(base)
        case .unary(_, let operand, _):
            read(operand)
        case .binary(let left, _, let right, _):
            read(left)
            read(right)
        case .index(let base, let index, _):
            read(base)
            read(index)
        case .slicing(let base, let low, let high, _):
            read(base)
            if let low { read(low) }
            if let high { read(high) }
        case .call(let callee, let arguments, _):
            read(callee)
            arguments.forEach { read($0) }
        case .compositeLiteral(_, let elements, _):
            for element in elements {
                // The key of a map may be a variable; a field's name that
                // is also a variable's only spares that variable a report.
                if let key = element.key { use(key) }
                if let key = element.keyExpression { read(key) }
                read(element.value)
            }
        }
    }

    /// The innermost scope ends where its block does, without an error:
    /// what it declared and nothing read is unused.
    mutating func endScope() {
        for (name, binding) in scopes[scopes.count - 1] where !binding.isUsed {
            if let position = binding.position { unused.append((position, name)) }
        }
    }

    /// Go's report of the first unused variable.
    func unusedVariable(before limit: GoSourcePosition? = nil) -> GoDiagnostic? {
        let first = unused.min { $0.position.offset < $1.position.offset }
        guard let first else { return nil }
        if let limit, first.position.path != limit.path || first.position.offset >= limit.offset {
            return nil
        }
        return GoDiagnostic(
            position: first.position, message: "declared and not used: \(first.name)")
    }

    mutating func check(_ function: GoFunctionDeclaration) throws {
        // Where the parser saw the function's name, the end of its body, and
        // the names of its results.
        let positions = namePositions[function.position.offset]
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
                type: parameterType.parameterType,
                isConstant: false)
        }
        for (index, (name, resultType)) in zip(function.resultNames, signature.results).enumerated() {
            guard let name else { continue }
            guard scopes[scopes.count - 1][name] == nil else {
                // The names of the results follow the two places above.
                let named = function.resultNames.prefix(index).compactMap { $0 }.count + 2
                throw GoDiagnostic(
                    position: positions.flatMap { named < $0.count ? $0[named] : $0.first }
                        ?? function.position,
                    message: "\(name) redeclared in this block")
            }
            scopes[scopes.count - 1][name] = Binding(type: resultType, isConstant: false)
            namedResultCount += 1
        }
        if namedResultCount > 0, namedResultCount != signature.results.count {
            throw GoDiagnostic(
                position: positions?.first ?? function.position,
                message: "mixed named and unnamed parameters")
        }
        let entry = self
        do {
            try checkBlock(function.body, createsScope: false)
        } catch let diagnostic as GoDiagnostic {
            // Go checks on after an error and reports all it finds in the
            // order of the source, so an unused variable declared before
            // this error comes first. Whether one is unused takes the rest
            // of the function to say: check it again, past its errors.
            var recovery = entry
            recovery.isRecovering = true
            try? recovery.checkBlock(function.body, createsScope: false)
            recovery.endScope()
            throw recovery.unusedVariable(before: diagnostic.position) ?? diagnostic
        }
        endScope()
        if let diagnostic = unusedVariable() { throw diagnostic }
        if !signature.results.isEmpty, !blockTerminates(function.body) {
            // Go reports the return a function lacks where its body ends.
            throw GoDiagnostic(
                position: positions?.last ?? function.position, message: "missing return")
        }
    }

    mutating func checkBlock(_ block: GoBlock, createsScope: Bool = true) throws {
        if createsScope { scopes.append([:]) }
        defer { if createsScope { scopes.removeLast() } }
        for statement in block.statements {
            guard isRecovering else {
                try check(statement)
                continue
            }
            do { try check(statement) } catch { recover(from: statement) }
        }
        if createsScope { endScope() }
    }

    mutating func check(_ statement: GoStatement) throws {
        // Before the statement declares anything: `x := x + 1` reads the
        // `x` outside.
        read(statement)
        try checkStatement(statement)
        place(statement)
    }

    /// The variables `statement` declared are where it names them.
    mutating func place(_ statement: GoStatement) {
        switch statement {
        case .declaration(let name, _, _, _, let position):
            place(name, at: namePositions[position.offset]?.first ?? position)
        case .multiDeclaration(let names, _, let position):
            let positions = namePositions[position.offset] ?? []
            for (index, name) in names.enumerated() {
                place(name, at: index < positions.count ? positions[index] : position)
            }
        default:
            break
        }
    }

    private mutating func checkStatement(_ statement: GoStatement) throws {
        // Each kind of statement is checked by a function of its own. In
        // one function, an unoptimized build keeps the locals of every
        // case in every frame, and a statement inside a statement, or a
        // function literal inside a call, cost the stack of all of them.
        switch statement {
        case .declaration: try checkDeclarationStatement(statement)
        case .assignment: try checkAssignmentStatement(statement)
        case .multiDeclaration: try checkMultiDeclarationStatement(statement)
        case .multiAssignment: try checkMultiAssignmentStatement(statement)
        case .increment: try checkIncrementStatement(statement)
        case .expression: try checkExpressionStatement(statement)
        case .returnValues: try checkReturnValuesStatement(statement)
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
        case .deferStatement(let expression, let position),
            .goStatement(let expression, let position):
            let keyword: String
            if case .deferStatement = statement { keyword = "defer" } else { keyword = "go" }
            guard case .call(let callee, let arguments, let callPosition) = expression,
                !(try isOperatorOrConversion(expression))
            else {
                throw GoDiagnostic(
                    position: position,
                    message: "expression in \(keyword) must be function call")
            }
            if try nativeCall(callee: callee, arguments: arguments, position: callPosition) != nil {
                return
            }
            _ = try type(of: expression)
        case .sendStatement: try checkSendStatement(statement)
        case .ifStatement: try checkIfStatement(statement)
        case .forStatement: try checkForStatement(statement)
        case .forRangeStatement: try checkForRangeStatement(statement)
        case .switchStatement: try checkSwitchStatement(statement)
        case .selectStatement: try checkSelectStatement(statement)
        }
    }

    private mutating func checkDeclarationStatement(_ statement: GoStatement) throws {
        guard case .declaration(let name, let explicitType, let expression, let isConstant, let position) = statement else {
            return
        }
        guard scopes[scopes.count - 1][name] == nil else {
            throw GoDiagnostic(position: position, message: "\(name) redeclared in this block")
        }
        if let expression { try requireSingleValue(expression, at: position) }
        let declared = try explicitType.map { try declaredType($0) }
        let expressionType = try expression.map { try type(of: $0) }
        if let declared, let expression, let expressionType,
            !(try isAssignable(expression, ofType: expressionType, to: declared))
        {
            throw GoDiagnostic(
                position: expression.position,
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
        scopes[scopes.count - 1][name] = Binding(
            type: bindingType,
            isConstant: isConstant,
            constantValue: isConstant && declared == nil
                ? expression.flatMap { untypedConstantValue($0) } : nil)
    }

    private mutating func checkAssignmentStatement(_ statement: GoStatement) throws {
        guard case .assignment(let target, let expression, _) = statement else {
            return
        }
        if target.isBlank {
            // `_ = x` evaluates `x` and keeps nothing.
            try requireValue(expression)
            return
        }
        let targetType = try assignableType(of: target, asTarget: true)
        let expressionType = try type(of: expression)
        guard try isAssignable(expression, ofType: expressionType, to: targetType) else {
            throw GoDiagnostic(
                position: expression.position,
                message: "cannot use \(expressionType) as \(targetType) value")
        }
    }

    private mutating func checkMultiDeclarationStatement(_ statement: GoStatement) throws {
        guard case .multiDeclaration(let names, let expression, let position) = statement else {
            return
        }
        if let variables = expression.variables {
            if variables.isConstant {
                // Constants are values of the compiler: one declaration each.
                guard variables.values.count == names.count else {
                    throw GoDiagnostic(
                        position: position,
                        message: Self.mismatch(
                            variables: names.count, values: variables.values.count))
                }
                for (name, value) in zip(names, variables.values) {
                    try check(
                        .declaration(
                            name: name, explicitType: variables.type, expression: value,
                            isConstant: true, position: position))
                }
                return
            }
            try checkVariables(
                names, type: variables.type, values: variables.values, position: position)
            return
        }
        if let values = expression.valueList {
            try checkParallelDeclaration(names, values: values, position: position)
            return
        }
        if names.allSatisfy({ $0 == GoValueList.blank || scopes[scopes.count - 1][$0] != nil }) {
            throw GoDiagnostic(
                position: position, message: "no new variables on left side of :=")
        }
        if let statements = GoStatement.redeclaration(
            names: names, expression: expression, position: position,
            declared: Set(names.filter { scopes[scopes.count - 1][$0] != nil }))
        {
            for statement in statements { try check(statement) }
            return
        }
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
                message: Self.mismatch(variables: names.count, values: 1))
        }
        let resultTypes = try callResultTypes(
            callee: callee, arguments: arguments, position: callPosition)
        guard resultTypes.count == names.count else {
            throw GoDiagnostic(
                position: position,
                message: "assignment mismatch: \(names.count) variables but function returns \(resultTypes.count) values")
        }
        for (name, resultType) in zip(names, resultTypes) {
            // The blank identifier declares nothing and may repeat.
            if name == "_" { continue }
            guard scopes[scopes.count - 1][name] == nil else {
                throw GoDiagnostic(
                    position: position,
                    message: "\(name) redeclared in this block")
            }
            scopes[scopes.count - 1][name] = Binding(
                type: resultType, isConstant: false)
        }
    }

    private mutating func checkMultiAssignmentStatement(_ statement: GoStatement) throws {
        guard case .multiAssignment(let targets, let expression, let position) = statement else {
            return
        }
        if let values = expression.valueList {
            guard targets.count == values.count else {
                throw GoDiagnostic(
                    position: position,
                    message: Self.mismatch(variables: targets.count, values: values.count))
            }
            for (target, value) in zip(targets, values) {
                if target.isBlank {
                    try requireValue(value)
                    continue
                }
                let targetType = try assignableType(of: target, asTarget: true)
                try requireSingleValue(value, at: value.position)
                let valueType = try type(of: value)
                guard try isAssignable(value, ofType: valueType, to: targetType) else {
                    throw GoDiagnostic(
                        position: value.position,
                        message: "cannot use \(valueType) as \(targetType) value in assignment")
                }
            }
            return
        }
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
                if target.isBlank { continue }
                let targetType = try assignableType(of: target, asTarget: true)
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
                if target.isBlank { continue }
                let targetType = try assignableType(of: target, asTarget: true)
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
                if target.isBlank { continue }
                let targetType = try assignableType(of: target, asTarget: true)
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
                message: Self.mismatch(variables: targets.count, values: 1))
        }
        let resultTypes = try callResultTypes(
            callee: callee, arguments: arguments, position: callPosition)
        guard resultTypes.count == targets.count else {
            throw GoDiagnostic(
                position: position,
                message: "assignment mismatch: \(targets.count) variables but function returns \(resultTypes.count) values")
        }
        for (target, resultType) in zip(targets, resultTypes) {
            if target.isBlank { continue }
            let targetType = try assignableType(of: target, asTarget: true)
            guard isAssignable(resultType, to: targetType) else {
                throw GoDiagnostic(
                    position: target.position,
                    message: "cannot use \(resultType) as \(targetType) value in assignment")
            }
        }
    }

    private mutating func checkIncrementStatement(_ statement: GoStatement) throws {
        guard case .increment(let target, let incrementOperator, let position) = statement else {
            return
        }
        let targetType = try assignableType(of: target)
        guard isInteger(targetType) else {
            let spelling = incrementOperator == .increment ? "++" : "--"
            throw GoDiagnostic(
                position: position,
                message: "invalid operation: \(spelling) on non-numeric type \(targetType)")
        }
    }

    private mutating func checkExpressionStatement(_ statement: GoStatement) throws {
        guard case .expression(let expression) = statement else {
            return
        }
        guard case .call(let callee, let arguments, let callPosition) = expression else {
            if case .unary(.receive, _, _) = expression {
                _ = try type(of: expression)
                return
            }
            throw GoDiagnostic(
                position: expression.position,
                message: "expression evaluated but not used")
        }
        if try isOperatorOrConversion(expression) {
            _ = try type(of: expression)
            throw GoDiagnostic(
                position: expression.position,
                message: "expression evaluated but not used")
        }
        // A native call may discard all of its results as a statement.
        if try nativeCall(callee: callee, arguments: arguments, position: callPosition) != nil {
            return
        }
        _ = try type(of: expression)
    }

    private mutating func checkReturnValuesStatement(_ statement: GoStatement) throws {
        guard case .returnValues(let values, let position) = statement else {
            return
        }
        guard !expectedResults.isEmpty else {
            guard values.isEmpty else {
                throw GoDiagnostic(position: position, message: "too many return values")
            }
            return
        }
        if values.isEmpty, namedResultCount == expectedResults.count {
            return
        }
        // `return f()` forwards every result of a multi-result call.
        if values.count == 1, expectedResults.count > 1,
            case .call(let callee, let arguments, let callPosition) = values[0]
        {
            let results = try callResultTypes(
                callee: callee, arguments: arguments, position: callPosition)
            guard results.count >= expectedResults.count else {
                throw GoDiagnostic(position: position, message: "not enough return values")
            }
            guard results.count <= expectedResults.count else {
                throw GoDiagnostic(position: position, message: "too many return values")
            }
            for (actual, expected) in zip(results, expectedResults) {
                guard isAssignable(actual, to: expected) else {
                    throw GoDiagnostic(
                        position: values[0].position,
                        message: "cannot use \(actual) as \(expected) value in return statement")
                }
            }
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
            guard try isAssignable(value, ofType: actual, to: expected) else {
                throw GoDiagnostic(
                    position: value.position,
                    message: "cannot use \(actual) as \(expected) value in return statement")
            }
        }
    }

    private mutating func checkSendStatement(_ statement: GoStatement) throws {
        guard case .sendStatement(let channel, let value, _) = statement else {
            return
        }
        guard case .channel(let direction, let elementType) = underlying(try type(of: channel)) else {
            throw GoDiagnostic(position: channel.position, message: "cannot send to non-channel value")
        }
        guard direction != .receiveOnly else {
            throw GoDiagnostic(position: channel.position, message: "cannot send to receive-only channel")
        }
        let valueType = try type(of: value)
        guard try isAssignable(value, ofType: valueType, to: elementType) else {
            throw GoDiagnostic(
                position: value.position,
                message: "cannot send \(valueType) value on \(elementType) channel")
        }
    }

    private mutating func checkIfStatement(_ statement: GoStatement) throws {
        guard case .ifStatement(let condition, let thenBlock, let elseBlock, _) = statement else {
            return
        }
        try requireBool(condition)
        try checkBlock(thenBlock)
        if let elseBlock { try checkBlock(elseBlock) }
    }

    private mutating func checkForStatement(_ statement: GoStatement) throws {
        guard case .forStatement(let initializer, let condition, let post, let body, _) = statement else {
            return
        }
        scopes.append([:])
        defer { scopes.removeLast() }
        if let scoped = statement.initialized {
            // An `if` or `switch` with an initializer: its variables are
            // in scope for the statement, which is no loop.
            try check(scoped.initializer)
            try check(scoped.statement)
            endScope()
            return
        }
        if let block = statement.block {
            try checkBlock(block)
            return
        }
        if let initializer { try check(initializer) }
        if let condition {
            read(condition)
            try requireBool(condition)
        }
        if let post { try check(post) }
        breakableDepth += 1
        loopDepth += 1
        defer {
            breakableDepth -= 1
            loopDepth -= 1
        }
        try checkBlock(body)
        endScope()
    }

    private mutating func checkForRangeStatement(_ statement: GoStatement) throws {
        guard case .forRangeStatement(let indexName, let valueName, let collection, let body, let position) = statement else {
            return
        }
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
        let positions = namePositions[position.offset] ?? []
        for (index, name) in [indexName, valueName].enumerated() {
            if let name { place(name, at: index < positions.count ? positions[index] : position) }
        }
        breakableDepth += 1
        loopDepth += 1
        defer {
            breakableDepth -= 1
            loopDepth -= 1
        }
        try checkBlock(body)
        endScope()
    }

    private mutating func checkSwitchStatement(_ statement: GoStatement) throws {
        guard case .switchStatement(let expression, let cases, _) = statement else {
            return
        }
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
                // An untyped constant case adopts an integer switch type.
                let matchesSwitch = try caseType == switchType
                    || (isInteger(switchType)
                        && isAssignable(caseExpression, ofType: caseType, to: switchType))
                guard matchesSwitch else {
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
    }

    private mutating func checkSelectStatement(_ statement: GoStatement) throws {
        guard case .selectStatement(let cases, let position) = statement else {
            return
        }
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
            endScope()
        }
        _ = position
    }

    mutating func type(of expression: GoExpression) throws -> GoType {
        // One function for each kind of expression, like the statements.
        switch expression {
        case .integer:
            return .int
        case .string:
            return .string
        case .identifier: return try typeOfIdentifier(expression)
        case .selector: return try typeOfSelector(expression)
        case .compositeLiteral: return try typeOfCompositeLiteral(expression)
        case .index: return try typeOfIndex(expression)
        case .slicing: return try typeOfSlicing(expression)
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
            endScope()
            return .function(parameters: parameterTypes, results: resolvedResults)
        case .call(let callee, let arguments, let position):
            // Typed in functions of their own. This one calls itself for
            // every operand, so its frame is what each level of a nested
            // expression costs, and the cases of a call are most of it.
            return try callType(
                of: expression, callee: callee, arguments: arguments, position: position)
        case .unary: return try typeOfUnary(expression)
        case .binary: return try typeOfBinary(expression)
        }
    }

    mutating func typeOfIdentifier(_ expression: GoExpression) throws -> GoType {
        guard case .identifier(let name, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        if name == "true" || name == "false" { return .bool }
        if name == "nil" { return .nilType }
        guard let binding = lookup(name) else {
            let isPackage = importedPaths.contains {
                GoImportName.defaultName(ofPath: $0) == name
            }
            throw GoDiagnostic(
                position: position,
                message: isPackage
                    ? GoImportName.misuse(ofPackage: name) : "undefined: \(name)")
        }
        use(name)
        return binding.type
    }

    mutating func typeOfSelector(_ expression: GoExpression) throws -> GoType {
        guard case .selector(let base, let name, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        if case .identifier(let packageName, _) = base,
            importedPaths.contains(packageName),
            GoStandardLibrary.integerConstant(package: packageName, member: name) != nil
        {
            return .int
        }
        if case .identifier(let packageName, _) = base,
            importedPaths.contains(packageName),
            lookup(packageName) == nil,
            GoStandardLibrary.errorValue(package: packageName, member: name) != nil
        {
            return GoPredeclared.errorType
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
        if case .identifier("os", _) = base,
            importedPaths.contains("os"),
            lookup("os") == nil,
            GoStandardLibrary.standardFileDescriptor(member: name) != nil
        {
            return GoPredeclared.filePointer
        }
        if let packageName = importedPackage(named: base) {
            // Nothing above knows the member of the package.
            throw GoDiagnostic(position: position, message: "undefined: \(packageName).\(name)")
        }
        let baseType = try type(of: base)
        guard let field = structFields(of: baseType)?.first(where: { $0.name == name }) else {
            throw GoDiagnostic(
                position: position,
                message: "\(baseType) has no field or method \(name)")
        }
        return field.type
    }

    mutating func typeOfCompositeLiteral(_ expression: GoExpression) throws -> GoType {
        guard case .compositeLiteral(let typeExpression, let elements, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
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
                            message: "unknown field \(element.key ?? "") in struct literal of type \(literalType)")
                    }
                    guard seen.insert(key).inserted else {
                        throw GoDiagnostic(
                            position: element.position,
                            message: "duplicate field name \(key) in struct literal")
                    }
                    try require(element.value, assignableTo: field.type)
                }
            } else if !elements.isEmpty {
                // `T{}` is the zero value; a literal without field names
                // gives every field.
                guard elements.count == fields.count else {
                    throw GoDiagnostic(
                        position: position,
                        message:
                            "too \(elements.count < fields.count ? "few" : "many") values in struct literal of type \(literalType)"
                    )
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
    }

    mutating func typeOfIndex(_ expression: GoExpression) throws -> GoType {
        guard case .index(let base, let index, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
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
            return GoPredeclared.byte
        case .map(let keyType, let valueType):
            let indexType = try type(of: index)
            guard try isAssignable(index, ofType: indexType, to: keyType) else {
                throw GoDiagnostic(
                    position: index.position,
                    message: "cannot use \(indexType) as \(keyType) value in map index")
            }
            return valueType
        default:
            throw GoDiagnostic(position: position, message: "cannot index expression")
        }
    }

    mutating func typeOfSlicing(_ expression: GoExpression) throws -> GoType {
        guard case .slicing(let base, let low, let high, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        for bound in [low, high].compactMap({ $0 }) where !isInteger(try type(of: bound)) {
            throw GoDiagnostic(position: bound.position, message: "slice index must be integer")
        }
        switch underlying(try type(of: base)) {
        case .array(_, let element), .slice(let element): return .slice(element)
        case .string: return .string
        default:
            throw GoDiagnostic(position: position, message: "cannot slice expression")
        }
    }

    mutating func typeOfUnary(_ expression: GoExpression) throws -> GoType {
        guard case .unary(let unaryOperator, let operand, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
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
            // A composite literal is the one operand that is not a
            // variable: `&T{...}` makes one.
            if case .compositeLiteral = operand { return .pointer(try type(of: operand)) }
            guard isAddressable(operand) else {
                throw GoDiagnostic(
                    position: operand.position,
                    message: "invalid operation: cannot take address of a value that is not a variable")
            }
            return .pointer(try assignableType(of: operand))
        case .dereference:
            let operandType = try type(of: operand)
            guard case .pointer(let pointee) = operandType else {
                throw GoDiagnostic(position: position, message: "cannot indirect \(operandType)")
            }
            try rejectOpaqueFile(pointee, at: position)
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
    }

    mutating func typeOfBinary(_ expression: GoExpression) throws -> GoType {
        guard case .binary(let left, let binaryOperator, let right, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        var leftType = try type(of: left)
        var rightType = try type(of: right)
        if leftType != rightType,
            let common = try commonIntegerType(
                left: left, leftType: leftType, right: right, rightType: rightType)
        {
            leftType = common
            rightType = common
        }
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

    /// The type of the call `expression`.
    mutating func callType(
        of expression: GoExpression, callee: GoExpression, arguments: [GoExpression],
        position: GoSourcePosition
    ) throws -> GoType {
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
        if let operation = expression.bitwiseOperation {
            return try bitwiseResultType(
                operation.operator, operands: operation.operands, position: position)
        }
        if expression.spreadOperand != nil {
            throw GoDiagnostic(
                position: position,
                message: "can only use ... with final argument in list")
        }
        if let target = try conversionTarget(callee) {
            return try conversionResultType(target, arguments: arguments, position: position)
        }
        if let native = try nativeCall(
            callee: callee, arguments: arguments, position: position)
        {
            guard native.results.count <= 1 else {
                throw GoDiagnostic(
                    position: position,
                    message: "multiple-value \(native.goName)() in single-value context")
            }
            guard let result = native.results.first else { return .void }
            return result
        }
        if case .identifier(let name, let namePosition) = callee {
            return try namedCallType(
                name: name, namePosition: namePosition, arguments: arguments, position: position)
        }
        guard case .selector(let base, let name, _) = callee else {
            throw GoDiagnostic(position: position, message: "unsupported function call")
        }
        return try selectorCallType(
            base: base, name: name, callee: callee, arguments: arguments, position: position)
    }

    /// The type of a call of a builtin or of a function of the program by
    /// its name.
    mutating func namedCallType(
        name: String, namePosition: GoSourcePosition, arguments: [GoExpression],
        position: GoSourcePosition
    ) throws -> GoType {
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
            if arguments.count == 2, let source = arguments[1].spreadOperand {
                let sourceType = try type(of: source)
                guard isElementSource(sourceType, of: elementType) else {
                    throw GoDiagnostic(
                        position: source.position,
                        message: "cannot use \(sourceType) as \(sliceType) value in append")
                }
                return sliceType
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
            guard try isAssignable(arguments[1], ofType: actualKeyType, to: keyType) else {
                throw GoDiagnostic(
                    position: arguments[1].position,
                    message: "cannot use \(actualKeyType) as \(keyType) value in delete")
            }
            return .void
        }
        if name == "copy" {
            guard arguments.count == 2 else {
                throw GoDiagnostic(position: position, message: "copy takes exactly two arguments")
            }
            let destinationType = try type(of: arguments[0])
            guard case .slice(let element) = underlying(destinationType) else {
                throw GoDiagnostic(
                    position: arguments[0].position,
                    message: "first argument to copy must be slice")
            }
            let sourceType = try type(of: arguments[1])
            guard isElementSource(sourceType, of: element) else {
                throw GoDiagnostic(
                    position: arguments[1].position,
                    message: "cannot copy \(sourceType) into \(destinationType)")
            }
            return .int
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
                use(name)
                guard arguments.isEmpty else {
                    throw GoDiagnostic(
                        position: position,
                        message: "too many arguments in call to cancel function")
                }
                return .void
            }
            throw GoDiagnostic(position: namePosition, message: "undefined: \(name)")
        }
        let (arguments, parameters) = matched(arguments, to: signature.parameters)
        guard arguments.count <= parameters.count else {
            throw GoDiagnostic(position: position, message: "too many arguments in call to \(name)")
        }
        guard arguments.count == parameters.count else {
            throw GoDiagnostic(position: position, message: "not enough arguments in call to \(name)")
        }
        for (argument, parameterType) in zip(arguments, parameters) {
            let argumentType = try type(of: argument)
            guard try isAssignable(argument, ofType: argumentType, to: parameterType) else {
                throw GoDiagnostic(
                    position: argument.position,
                    message: "cannot use \(argumentType) as \(parameterType) value in argument to \(name)")
            }
        }
        return signature.results.first ?? .void
    }

    /// The type of a call `base.name(...)`: a function of a package or a
    /// method.
    mutating func selectorCallType(
        base: GoExpression, name: String, callee: GoExpression, arguments: [GoExpression],
        position: GoSourcePosition
    ) throws -> GoType {
        if case .identifier(let packageName, _) = base,
            packageName == "fmt",
            importedPaths.contains("fmt"),
            name == "Print" || name == "Println"
        {
            try checkAnyOperands(arguments[...])
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
        if case .identifier("userland", _) = base,
            importedPaths.contains("swiftix/userland"),
            let results = try userlandTerminalResults(
                name, arguments: arguments, position: position)
        {
            return results.first ?? .void
        }
        if case .identifier("strings", _) = base,
            importedPaths.contains("strings")
        {
            return try stringsCallResult(name, arguments: arguments, position: position)
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
            return .channel(direction: .receiveOnly, element: GoPredeclared.time)
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
            return .channel(direction: .receiveOnly, element: GoPredeclared.time)
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
                return GoPredeclared.errorType
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
                    return GoPredeclared.errorType
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
                    if try type(of: arguments[0]) != .slice(GoPredeclared.byte) {
                        try require(arguments[0], assignableTo: .slice(.int))
                    }
                    return .int
                case "Close":
                    guard arguments.isEmpty else {
                        throw GoDiagnostic(
                            position: position,
                            message: "too many arguments in call to Close")
                    }
                    return GoPredeclared.errorType
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
                    return GoPredeclared.errorType
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
                guard try isAssignable(argument, ofType: argType, to: paramType) else {
                    throw GoDiagnostic(
                        position: argument.position,
                        message: "cannot use \(argType) as \(paramType) value in argument to \(packageName).\(name)")
                }
            }
            return funcExport.results.first ?? .void
        }
        if let packageName = importedPackage(named: base) {
            // Name the missing member instead of reporting the package
            // itself as undefined.
            throw GoDiagnostic(
                position: callee.position, message: "undefined: \(packageName).\(name)")
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
                let (arguments, parameters) = matched(arguments, to: method.parameters)
                guard arguments.count == parameters.count else {
                    throw GoDiagnostic(
                        position: position,
                        message: "wrong number of arguments in call to \(name)")
                }
                for (argument, parameterType) in zip(arguments, parameters) {
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
        let (arguments, parameters) = matched(arguments, to: signature.parameters)
        guard arguments.count <= parameters.count else {
            throw GoDiagnostic(position: position, message: "too many arguments in call to \(name)")
        }
        guard arguments.count == parameters.count else {
            throw GoDiagnostic(position: position, message: "not enough arguments in call to \(name)")
        }
        for (argument, parameterType) in zip(arguments, parameters) {
            try require(argument, assignableTo: parameterType)
        }
        return signature.results.first ?? .void
    }

    /// The type of what `expression` names, which must be something a
    /// value can be stored in. To be the target of an assignment is not to
    /// be read: `x = 1` alone leaves `x` unused, where `x.f = 1`, `x[i] = 1`,
    /// `x++`, and `&x` read it.
    mutating func assignableType(
        of expression: GoExpression, asTarget: Bool = false
    ) throws -> GoType {
        switch expression {
        case .identifier(let name, let position):
            guard let binding = lookup(name) else {
                throw GoDiagnostic(position: position, message: "undefined: \(name)")
            }
            guard !binding.isConstant else {
                throw GoDiagnostic(position: position, message: "cannot assign to \(name)")
            }
            if !asTarget { use(name) }
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
            try rejectOpaqueFile(pointee, at: position)
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
                guard try isAssignable(index, ofType: indexType, to: keyType) else {
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

    /// Rejects a call with several results where one value is wanted.
    mutating func requireSingleValue(
        _ expression: GoExpression,
        at position: GoSourcePosition
    ) throws {
        guard case .call(let callee, let arguments, let callPosition) = expression else { return }
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

    /// Requires `expression` to have a value: not a call without a result
    /// or with several, and not an untyped `nil`, which has no type to give
    /// a variable.
    mutating func requireValue(_ expression: GoExpression) throws {
        try requireSingleValue(expression, at: expression.position)
        let valueType = try type(of: expression)
        guard valueType != .void else {
            throw GoDiagnostic(position: expression.position, message: "no value used as value")
        }
        guard valueType != .nilType else {
            throw GoDiagnostic(
                position: expression.position, message: "use of untyped nil in assignment")
        }
    }

    static func mismatch(variables: Int, values: Int) -> String {
        "assignment mismatch: \(variables) variable\(variables == 1 ? "" : "s") but \(values) value\(values == 1 ? "" : "s")"
    }

    /// `var a, b T`, `var a, b = x, y`, `var a, b T = x, y`, and
    /// `var n, err = f()`. Every name is new: a `var` reuses none.
    mutating func checkVariables(
        _ names: [String],
        type: GoTypeExpression?,
        values: [GoExpression],
        position: GoSourcePosition
    ) throws {
        let declared = try type.map { try declaredType($0) }
        var seen: Set<String> = []
        for name in names where name != GoValueList.blank {
            guard scopes[scopes.count - 1][name] == nil, seen.insert(name).inserted else {
                throw GoDiagnostic(position: position, message: "\(name) redeclared in this block")
            }
        }
        if values.isEmpty {
            guard let declared else {
                throw GoDiagnostic(
                    position: position, message: "missing variable type or initialization")
            }
            for name in names where name != GoValueList.blank {
                scopes[scopes.count - 1][name] = Binding(type: declared, isConstant: false)
            }
            return
        }
        if values.count == 1, names.count > 1 {
            // One call, map index, type assertion, or receive for them all.
            switch values[0] {
            case .call, .index, .typeAssertion, .unary(.receive, _, _): break
            default:
                throw GoDiagnostic(
                    position: position,
                    message: Self.mismatch(variables: names.count, values: 1))
            }
            try check(.multiDeclaration(names: names, expression: values[0], position: position))
            if let declared {
                for name in names where name != GoValueList.blank {
                    guard let found = scopes[scopes.count - 1][name]?.type, found == declared else {
                        throw GoDiagnostic(
                            position: values[0].position,
                            message: "cannot use a value of another type as \(declared) value in assignment")
                    }
                }
            }
            return
        }
        guard values.count == names.count else {
            throw GoDiagnostic(
                position: position,
                message: Self.mismatch(variables: names.count, values: values.count))
        }
        var types: [GoType] = []
        for value in values {
            try requireValueOrNil(value, declared: declared)
            let valueType = try self.type(of: value)
            if let declared {
                guard try isAssignable(value, ofType: valueType, to: declared) else {
                    throw GoDiagnostic(
                        position: value.position,
                        message: "cannot use \(valueType) as \(declared) value in variable declaration")
                }
                types.append(declared)
            } else {
                types.append(valueType)
            }
        }
        for (name, valueType) in zip(names, types) where name != GoValueList.blank {
            scopes[scopes.count - 1][name] = Binding(type: valueType, isConstant: false)
        }
    }

    /// A value of a declaration: any value when the type is written, since
    /// `nil` then has one, and a typed value otherwise.
    mutating func requireValueOrNil(_ expression: GoExpression, declared: GoType?) throws {
        if declared != nil, try type(of: expression) == .nilType { return }
        try requireValue(expression)
    }

    /// `a, b := x, y`. A name the block already declares is assigned, as
    /// long as one name is new; every value is read before any is stored.
    mutating func checkParallelDeclaration(
        _ names: [String],
        values: [GoExpression],
        position: GoSourcePosition
    ) throws {
        guard names.count == values.count else {
            throw GoDiagnostic(
                position: position,
                message: Self.mismatch(variables: names.count, values: values.count))
        }
        var seen: Set<String> = []
        var added: [(name: String, type: GoType)] = []
        for (name, value) in zip(names, values) {
            if name == GoValueList.blank {
                try requireValue(value)
                continue
            }
            guard seen.insert(name).inserted else {
                throw GoDiagnostic(
                    position: position, message: "\(name) repeated on left side of :=")
            }
            try requireSingleValue(value, at: value.position)
            let valueType = try type(of: value)
            if let existing = scopes[scopes.count - 1][name] {
                guard !existing.isConstant else {
                    throw GoDiagnostic(
                        position: position,
                        message: "cannot assign to \(name) (neither addressable nor a map index expression)")
                }
                guard try isAssignable(value, ofType: valueType, to: existing.type) else {
                    throw GoDiagnostic(
                        position: value.position,
                        message: "cannot use \(valueType) as \(existing.type) value in assignment")
                }
            } else {
                try requireValue(value)
                added.append((name, valueType))
            }
        }
        guard !added.isEmpty else {
            throw GoDiagnostic(position: position, message: "no new variables on left side of :=")
        }
        for binding in added {
            scopes[scopes.count - 1][binding.name] = Binding(type: binding.type, isConstant: false)
        }
    }

    mutating func require(_ expression: GoExpression, assignableTo expected: GoType) throws {
        let actual = try type(of: expression)
        guard try isAssignable(expression, ofType: actual, to: expected) else {
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
            case "byte", "uint8": return GoPredeclared.byte
            case "testing.T", "sync.Mutex", "sync.WaitGroup",
                "context.Context", "context.CancelFunc",
                "net.Conn", "net.Listener",
                "http.Response", "http.ResponseWriter", "http.Request",
                "time.Time", "os.File":
                return .named(name)
            default:
                guard availableTypes.contains(name) else {
                    throw GoDiagnostic(
                        position: position,
                        message: GoPredeclared.unsupportedNumericTypes.contains(name)
                            ? GoPredeclared.unsupportedTypeMessage(name)
                            : "undefined: \(name)")
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
            let definition = typeDefinitions[name]?.underlying
                ?? GoPredeclared.underlying(of: name)
        else { return type }
        var next = visiting
        next.insert(name)
        return underlying(definition, visiting: next)
    }

    // MARK: Untyped integer constants

    func isByte(_ type: GoType) -> Bool {
        GoPredeclared.isByte(type, definitions: typeDefinitions)
    }

    /// Value of an untyped integer constant expression: literals, constants
    /// declared without a type, and operators over them. Nil for a typed
    /// operand or when folding would overflow `int`.
    func untypedConstantValue(_ expression: GoExpression) -> Int64? {
        switch expression {
        case .integer(let value, _):
            return value
        case .identifier(let name, _):
            return lookup(name)?.constantValue
        case .unary(.plus, let operand, _):
            return untypedConstantValue(operand)
        case .unary(.minus, let operand, _):
            guard let value = untypedConstantValue(operand), value != .min else { return nil }
            return -value
        case .binary(let left, let binaryOperator, let right, _):
            guard let lhs = untypedConstantValue(left), let rhs = untypedConstantValue(right)
            else { return nil }
            let folded: (partialValue: Int64, overflow: Bool)
            switch binaryOperator {
            case .add: folded = lhs.addingReportingOverflow(rhs)
            case .subtract: folded = lhs.subtractingReportingOverflow(rhs)
            case .multiply: folded = lhs.multipliedReportingOverflow(by: rhs)
            case .divide:
                guard rhs != 0 else { return nil }
                folded = lhs.dividedReportingOverflow(by: rhs)
            case .remainder:
                guard rhs != 0 else { return nil }
                folded = lhs.remainderReportingOverflow(dividingBy: rhs)
            default: return nil
            }
            return folded.overflow ? nil : folded.partialValue
        case .call:
            guard let operation = expression.bitwiseOperation,
                let first = untypedConstantValue(operation.operands[0])
            else { return nil }
            if operation.operator == .complement { return ~first }
            guard let second = untypedConstantValue(operation.operands[1]) else { return nil }
            return operation.operator.fold(first, second)
        default:
            return nil
        }
    }

    func requireConstant(
        _ value: Int64,
        representableAs type: GoType,
        at position: GoSourcePosition
    ) throws {
        guard isByte(type), !(0...255).contains(value) else { return }
        throw GoDiagnostic(position: position, message: "constant \(value) overflows \(type)")
    }

    /// Whether `expression`, whose type is `actual`, may be used where
    /// `expected` is required. An untyped integer constant adopts any integer
    /// type that can represent it.
    func isAssignable(
        _ expression: GoExpression,
        ofType actual: GoType,
        to expected: GoType
    ) throws -> Bool {
        if isAssignable(actual, to: expected) { return true }
        guard isInteger(expected), let value = untypedConstantValue(expression) else {
            return false
        }
        try requireConstant(value, representableAs: expected, at: expression.position)
        return true
    }

    /// The operand type two integer operands share when one of them is an
    /// untyped constant, or nil when neither side can adopt the other's type.
    func commonIntegerType(
        left: GoExpression,
        leftType: GoType,
        right: GoExpression,
        rightType: GoType
    ) throws -> GoType? {
        if leftType == rightType { return leftType }
        if isInteger(rightType), let value = untypedConstantValue(left) {
            try requireConstant(value, representableAs: rightType, at: left.position)
            return rightType
        }
        if isInteger(leftType), let value = untypedConstantValue(right) {
            try requireConstant(value, representableAs: leftType, at: right.position)
            return leftType
        }
        return nil
    }

    // MARK: Bitwise operators, conversions, and native library calls

    mutating func bitwiseResultType(
        _ bitwiseOperator: GoBitwiseOperator,
        operands: [GoExpression],
        position: GoSourcePosition
    ) throws -> GoType {
        let leftType = try type(of: operands[0])
        if bitwiseOperator == .complement {
            guard isInteger(leftType) else {
                throw GoDiagnostic(
                    position: position, message: "operator ^ not defined on \(leftType)")
            }
            return leftType
        }
        let rightType = try type(of: operands[1])
        guard isInteger(leftType), isInteger(rightType) else {
            throw GoDiagnostic(
                position: position,
                message: "operator \(bitwiseOperator.spelling) requires integer operands")
        }
        if bitwiseOperator.isShift {
            if let count = untypedConstantValue(operands[1]), count < 0 {
                throw GoDiagnostic(
                    position: operands[1].position, message: "invalid negative shift count \(count)")
            }
            return leftType
        }
        guard
            let common = try commonIntegerType(
                left: operands[0], leftType: leftType, right: operands[1], rightType: rightType)
        else {
            throw GoDiagnostic(
                position: position, message: "mismatched types \(leftType) and \(rightType)")
        }
        return common
    }

    /// The target type when `callee` names a type, making the call a conversion.
    func conversionTarget(_ callee: GoExpression) throws -> GoType? {
        switch callee {
        case .typeExpression(let typeExpression, _):
            return try declaredType(typeExpression)
        case .identifier(let name, let position):
            guard lookup(name) == nil, functionSignatures[name] == nil else { return nil }
            switch name {
            case "int", "string", "bool", "byte", "uint8":
                break
            default:
                guard availableTypes.contains(name)
                    || GoPredeclared.unsupportedNumericTypes.contains(name)
                else { return nil }
            }
            return try declaredType(.named(name, position: position))
        default:
            return nil
        }
    }

    func isOperatorOrConversion(_ expression: GoExpression) throws -> Bool {
        guard case .call(let callee, _, _) = expression else { return false }
        return try expression.bitwiseOperation != nil || conversionTarget(callee) != nil
    }

    mutating func conversionResultType(
        _ target: GoType,
        arguments: [GoExpression],
        position: GoSourcePosition
    ) throws -> GoType {
        guard arguments.count == 1 else {
            throw GoDiagnostic(
                position: position,
                message: "conversion to \(target) requires exactly one argument")
        }
        let argument = arguments[0]
        let source = try type(of: argument)
        let failure = GoDiagnostic(
            position: argument.position, message: "cannot convert \(source) to type \(target)")
        let sourceShape = underlying(source)
        switch underlying(target) {
        case .int:
            if let value = untypedConstantValue(argument) {
                try requireConstant(value, representableAs: target, at: argument.position)
                return target
            }
            guard sourceShape == .int else { throw failure }
            return target
        case .string:
            if sourceShape == .string || sourceShape == .int { return target }
            if case .slice(let element) = sourceShape, isByte(element) { return target }
            throw failure
        case .slice(let element) where isByte(element) && sourceShape == .string:
            return target
        case .bool, .slice, .map, .pointer, .channel:
            // Named types convert to and from their identical underlying type.
            // Struct and array values carry their type name at run time, so
            // those conversions are not supported.
            guard source != .nilType, sourceShape == underlying(target) else { throw failure }
            return target
        default:
            throw failure
        }
    }

    func rejectOpaqueFile(_ pointee: GoType, at position: GoSourcePosition) throws {
        guard pointee == .named("os.File") else { return }
        throw GoDiagnostic(
            position: position,
            message: "os.File is opaque; a *os.File cannot be dereferenced")
    }

    /// Checks a call to a native library function or `*os.File` method and
    /// returns it, or nil when `callee` is not one.
    mutating func nativeCall(
        callee: GoExpression,
        arguments: [GoExpression],
        position: GoSourcePosition
    ) throws -> GoNativeFunction? {
        guard case .selector(let base, let name, _) = callee else { return nil }
        let function: GoNativeFunction
        var parameters: ArraySlice<GoType>
        if case .identifier(let packageName, _) = base,
            lookup(packageName) == nil,
            importedPaths.contains(packageName),
            let native = GoStandardLibrary.nativeFunction(package: packageName, member: name)
        {
            function = native
            parameters = native.parameters[...]
        } else if let receiver = try? type(of: base),
            let native = GoStandardLibrary.method(of: receiver, named: name)
        {
            function = native
            parameters = native.parameters.dropFirst()
        } else {
            return nil
        }
        guard function.isVariadic
            ? arguments.count >= parameters.count
            : arguments.count == parameters.count
        else {
            throw GoDiagnostic(
                position: position,
                message: "wrong number of arguments in call to \(function.goName)")
        }
        for (argument, parameter) in zip(arguments, parameters) {
            try require(argument, assignableTo: parameter)
        }
        try checkAnyOperands(arguments.dropFirst(parameters.count))
        return function
    }

    /// Checks the operands of a `...any` parameter: any number of values, or
    /// one `[]any` followed by `...`.
    mutating func checkAnyOperands(_ operands: ArraySlice<GoExpression>) throws {
        if operands.count == 1, let operand = operands.first?.spreadOperand {
            let operandType = try type(of: operand)
            guard case .slice(let element) = underlying(operandType),
                case .interface(let methods) = underlying(element), methods.isEmpty
            else {
                throw GoDiagnostic(
                    position: operand.position,
                    message: "cannot use \(operandType) as []interface{} value in argument")
            }
            return
        }
        for argument in operands where try type(of: argument) == .void {
            throw GoDiagnostic(position: argument.position, message: "no value used as value")
        }
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

    /// The arguments of a call paired with the parameter types they are
    /// checked against. A variadic function takes its fixed parameters and
    /// then any number of its element type, or one slice followed by `...`,
    /// which stands here by its operand.
    func matched(
        _ arguments: [GoExpression],
        to parameters: [GoType]
    ) -> (arguments: [GoExpression], parameters: [GoType]) {
        guard let element = parameters.last?.variadicElement else { return (arguments, parameters) }
        let fixed = Array(parameters.dropLast())
        if arguments.count == parameters.count, let operand = arguments.last?.spreadOperand {
            return (arguments.dropLast() + [operand], fixed + [.slice(element)])
        }
        return (
            arguments,
            fixed + Array(repeating: element, count: max(0, arguments.count - fixed.count))
        )
    }

    /// Whether a value of `source` supplies elements for a slice of `element`
    /// in `copy` and in `append(slice, source...)`: a slice of the same
    /// element type, or a string as a source of bytes.
    func isElementSource(_ source: GoType, of element: GoType) -> Bool {
        if isString(source) { return isByte(element) }
        if case .slice(let sourceElement) = underlying(source) { return sourceElement == element }
        return false
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
        if actual == .nilType, case .interface = underlying(expected) { return true }
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

    /// Signatures of the `swiftix/userland` terminal and file calls used by
    /// full-screen programs, or `nil` when `name` is not one of them.
    mutating func userlandTerminalResults(
        _ name: String,
        arguments: [GoExpression],
        position: GoSourcePosition
    ) throws -> [GoType]? {
        let parameters: [GoType]
        let results: [GoType]
        switch name {
        case "ReadStdin":
            parameters = []
            results = [.string, .int]
        case "WriteFile":
            parameters = [.string, .string]
            results = [.int]
        case "SetRawMode":
            parameters = [.bool]
            results = [.bool]
        case "WindowSize":
            parameters = []
            results = [.int, .int]
        default:
            return nil
        }
        guard arguments.count == parameters.count else {
            throw GoDiagnostic(
                position: position,
                message: "wrong number of arguments in call to userland.\(name)")
        }
        for (argument, parameter) in zip(arguments, parameters) {
            try require(argument, assignableTo: parameter)
        }
        return results
    }

    /// Check a call to a supported `strings` function and return its result.
    mutating func stringsCallResult(
        _ name: String,
        arguments: [GoExpression],
        position: GoSourcePosition
    ) throws -> GoType {
        guard let function = GoStringsFunction(goName: name) else {
            throw GoDiagnostic(position: position, message: "undefined: strings.\(name)")
        }
        let signature = function.signature
        guard arguments.count == signature.parameters.count else {
            throw GoDiagnostic(
                position: position,
                message: "wrong number of arguments in call to strings.\(name)")
        }
        for (argument, parameter) in zip(arguments, signature.parameters) {
            try require(argument, assignableTo: parameter)
        }
        return signature.result
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
            let (arguments, parameters) = matched(arguments, to: signature.parameters)
            guard arguments.count == parameters.count else {
                throw GoDiagnostic(
                    position: position,
                    message: "wrong number of arguments in call to \(name)")
            }
            for (argument, parameterType) in zip(arguments, parameters) {
                let argumentType = try type(of: argument)
                guard try isAssignable(argument, ofType: argumentType, to: parameterType) else {
                    throw GoDiagnostic(
                        position: argument.position,
                        message: "cannot use \(argumentType) as \(parameterType) value in argument to \(name)")
                }
            }
            return signature.results
        }
        if try isOperatorOrConversion(
            .call(callee: callee, arguments: arguments, position: position))
        {
            return [try type(of: .call(callee: callee, arguments: arguments, position: position))]
        }
        if let native = try nativeCall(callee: callee, arguments: arguments, position: position) {
            return native.results
        }
        if case .selector(let base, let name, _) = callee {
            if case .identifier(let packageName, _) = base,
                packageName == "fmt",
                importedPaths.contains("fmt")
            {
                // `fmt.Print` and `fmt.Println` return `(n int, err error)`.
                return name == "Print" || name == "Println"
                    ? [.int, GoPredeclared.errorType] : []
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
                return [.int, GoPredeclared.errorType]
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
            if case .identifier("userland", _) = base,
                importedPaths.contains("swiftix/userland"),
                let results = try userlandTerminalResults(
                    name, arguments: arguments, position: position)
            {
                return results
            }
            if case .identifier("strings", _) = base,
                importedPaths.contains("strings")
            {
                return [try stringsCallResult(name, arguments: arguments, position: position)]
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
                    return [.named("net.Conn"), GoPredeclared.errorType]
                case "Listen":
                    guard arguments.count == 2 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to net.Listen")
                    }
                    try require(arguments[0], assignableTo: .string)
                    try require(arguments[1], assignableTo: .string)
                    return [.named("net.Listener"), GoPredeclared.errorType]
                case "LookupHost":
                    guard arguments.count == 1 else {
                        throw GoDiagnostic(
                            position: position,
                            message: "wrong number of arguments in call to net.LookupHost")
                    }
                    try require(arguments[0], assignableTo: .string)
                    return [.slice(.string), GoPredeclared.errorType]
                default:
                    break
                }
            }
            // Handle net.Conn/net.Listener method calls
            if let receiverType = try? type(of: base) {
                switch (receiverType, name) {
                case (.named("net.Conn"), "Read"), (.named("net.Conn"), "Write"):
                    return [.int, GoPredeclared.errorType]
                case (.named("net.Listener"), "Accept"):
                    return [.named("net.Conn"), GoPredeclared.errorType]
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
                    return [.named("http.Response"), GoPredeclared.errorType]
                default:
                    break
                }
            }
            if let packageName = importedPackage(named: base) {
                throw GoDiagnostic(
                    position: callee.position, message: "undefined: \(packageName).\(name)")
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
            var signature: (parameters: [GoType], results: [GoType])?
            for candidate in candidates {
                if let found = methodSignatures[candidate] {
                    signature = (found.parameters, found.results)
                    break
                }
            }
            if signature == nil, case .interface(let methods) = underlying(baseType),
                let method = methods.first(where: { $0.name == name })
            {
                signature = (method.parameters, method.results)
            }
            guard let signature else {
                throw GoDiagnostic(
                    position: callee.position,
                    message: "\(baseType) has no field or method \(name)")
            }
            let (arguments, parameters) = matched(arguments, to: signature.parameters)
            guard arguments.count == parameters.count else {
                throw GoDiagnostic(
                    position: position,
                    message: "wrong number of arguments in call to \(name)")
            }
            for (argument, parameterType) in zip(arguments, parameters) {
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
        if let scoped = statement.initialized { return statementTerminates(scoped.statement) }
        if let block = statement.block { return blockTerminates(block) }
        switch statement {
        case .returnValues:
            return true
        case .expression(.call(callee: .identifier("panic", _), arguments: _, position: _)):
            // A call to the builtin ends a function as a return does.
            return functionSignatures["panic"] == nil
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
            // A `break` in a block of its own looks past the block.
            if let inner = statement.block {
                if containsBreakTargetingCurrentConstruct(inner) { return true }
                continue
            }
            // An `if` with an initializer is still that `if`.
            switch statement.initialized?.statement ?? statement {
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
