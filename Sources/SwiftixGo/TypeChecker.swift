/// Static type checking for the Swiftix Go language subset.

import SwiftixGoRuntime

public struct GoStructFieldType: Sendable, Equatable {
    public let name: String
    public let type: GoType
    /// Whether the field is embedded, and its tag: both are part of what
    /// makes two struct types one type.
    var isEmbedded = false
    var tag: String? = nil

    public init(name: String, type: GoType) {
        self.name = name
        self.type = type
    }

    /// The field as Go writes it in a message: `name T`, an embedded field
    /// by its type alone, and a tag after either, quoted.
    var spelling: String {
        let field = isEmbedded ? "\(type)" : "\(name) \(type)"
        guard let tag else { return field }
        var quoted = "\""
        for character in tag {
            if character == "\"" || character == "\\" { quoted.append("\\") }
            quoted.append(character)
        }
        return field + " " + quoted + "\""
    }

    /// The field `declaration` declares, once its type is `type`.
    init(_ declaration: GoStructFieldDeclaration, type: GoType) {
        self.init(name: declaration.name, type: type)
        isEmbedded = declaration.isEmbedded
        tag = declaration.tag
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
        case .named(let name): return GoTypeSpelling.named(name)
        case .structure(let fields):
            // As Go writes a struct type in a message: `struct{a int; b string}`.
            return "struct{" + fields.map(\.spelling).joined(separator: "; ") + "}"
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
            return GoTypeSpelling.interface(methods)
        case .function(let parameters, let results):
            let list = "func(" + parameters.map(\.description).joined(separator: ", ") + ")"
            switch results.count {
            case 0: return list
            case 1: return list + " " + results[0].description
            default:
                return list + " (" + results.map(\.description).joined(separator: ", ") + ")"
            }
        }
    }
}

public struct GoTypeDefinition: Sendable, Equatable {
    public let name: String
    public let underlying: GoType
    /// What the type has for a struct that embeds it, in a program that
    /// embeds anything: `GoEmbedding` finds promoted names by it.
    var embedding: GoEmbeddedShape? = nil

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
    /// The variables of the functions around it that each function literal
    /// reads or assigns, by the literal's name, in the order it meets them.
    var literalCaptures: [String: [String]] = [:]
    /// What the checker found out about the numbers of the package, for
    /// the lowerer: see `GoNumberFacts`.
    var numberFacts = GoNumberFacts()

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
            try GoNumberLedger.recording {
                try check(resolved: resolved, availablePackages: availablePackages)
            }
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
                    throw GoDiagnostic.redeclared(
                        importName, at: declaration.position,
                        other: file.imports.first {
                            $0.path == declaration.path && $0.name != GoImportName.blank
                        }?.position)
                }
            }
            importedPathsByFile.append(importedPaths)

            // What the file declares, each where its name is: Go reports
            // the one of two that comes second in the source.
            var declared: [DeclaredName] = []
            for declaration in file.typeDeclarations {
                guard GoPredeclared.namedType(declaration.name) == nil else {
                    throw GoDiagnostic(
                        position: declaration.position,
                        message: "cannot redeclare predeclared type \(declaration.name)")
                }
                declared.append((declaration.name, declaration.position, false))
                typeSyntax[declaration.name] = declaration
            }
            for declaration in file.globalDeclarations {
                declared.append((declaration.name, file.namePosition(of: declaration), false))
            }
            for function in file.functions where function.receiver == nil && function.name != "init" {
                declared.append((function.name, file.namePosition(of: function), true))
            }
            try reservePackageNames(
                declared, isMain: first.packageName == "main", names: &packageNames)
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
        if files.contains(where: \.usesEmbedding) {
            try GoEmbedding.validate(files)
            for (name, shape) in GoEmbedding.shapes(of: files) {
                typeDefinitions[name]?.embedding = shape
            }
        }
        // In the order of the source: Go reports a cycle at the first of
        // its types.
        for declaration in files.flatMap(\.typeDeclarations) {
            try rejectRecursiveValueType(
                declaration.name,
                definitions: typeDefinitions,
                position: declaration.position,
                places: typeSyntax.mapValues(\.position))
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
                results: resultTypes,
                names: GoSignatureNames(
                    parameters: function.parameters.map(\.name), results: function.resultNames))
            if let receiver = function.receiver {
                let identity = try receiverIdentity(
                    receiver.type,
                    availableTypes: availableTypes)
                try requireMethodReceiver(
                    identity.baseName, definitions: typeDefinitions, receiver: receiver.type)
                if case .structure(let fields)? = typeDefinitions[identity.baseName]?.underlying,
                    fields.contains(where: { $0.name == function.name })
                {
                    var message = "field and method with the same name \(function.name)"
                    if case .structure(let declared, _)? = typeSyntax[identity.baseName]?.type,
                        let field = declared.first(where: { $0.name == function.name })
                    {
                        message += "\n\t" + GoDiagnostic.place(field.position)
                            + ": other declaration of \(function.name)"
                    }
                    throw GoDiagnostic(position: file.namePosition(of: function), message: message)
                }
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
        // And its file knows where its names are, and of what package it is.
        var fileByGlobal: [String: GoFile] = [:]
        for (file, importedPaths) in zip(files, importedPathsByFile) {
            for declaration in file.globalDeclarations {
                importedPathsByGlobal[declaration.name] = importedPaths
                fileByGlobal[declaration.name] = file
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
            var undefined: [GoDiagnostic] = []
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
                        globalBindings: globalBindings,
                        namePositions: fileByGlobal[declaration.name]?.namePositions ?? [:])
                    let inferred = try checker.initializerType(of: expression)
                    guard inferred != .void, inferred != .nilType else {
                        throw GoDiagnostic(position: expression.position, message: "missing type in declaration")
                    }
                    globalBindings[declaration.name] = Binding(
                        type: inferred,
                        isConstant: declaration.isConstant,
                        constantValue: declaration.isConstant
                            ? checker.untypedConstantValue(expression) : nil)
                    if declaration.isConstant {
                        globalBindings[declaration.name]?.constant = try checker.constant(
                            of: expression)
                    }
                    madeProgress = true
                } catch let diagnostic as GoDiagnostic where undeclaredName(in: diagnostic) != nil {
                    next.append(declaration)
                    undefined.append(diagnostic)
                }
            }
            if !madeProgress, let diagnostic = firstUndeclared(undefined, among: next) {
                throw diagnostic
            }
            guard madeProgress else {
                throw GoDiagnostic(
                    position: next.first?.position ?? unresolved[0].position,
                    message: "initialization cycle for package variable")
            }
            unresolved = next
        }
        try resolveConstants(globals, bindings: &globalBindings) { declaration, bindings in
            FunctionChecker(
                importedPaths: importedPathsByGlobal[declaration.name] ?? [],
                functionSignatures: functionSignatures,
                methodSignatures: methodSignatures,
                typeDefinitions: typeDefinitions,
                availableTypes: availableTypes,
                globalBindings: bindings)
        }
        for declaration in globals {
            guard let expression = declaration.expression,
                let binding = globalBindings[declaration.name]
            else { continue }
            // An untyped constant is an exact value, checked where it was
            // given one; it need not be a value of its default type.
            if declaration.explicitType == nil, binding.constant != nil { continue }
            var checker = FunctionChecker(
                importedPaths: importedPathsByGlobal[declaration.name] ?? [],
                functionSignatures: functionSignatures,
                methodSignatures: methodSignatures,
                typeDefinitions: typeDefinitions,
                availableTypes: availableTypes,
                globalBindings: globalBindings,
                namePositions: fileByGlobal[declaration.name]?.namePositions ?? [:])
            try checker.requireInitializer(
                expression, assignableTo: binding.type, isConstant: declaration.isConstant)
        }
        forgetConstantNodes(globals, bindings: globalBindings)
        try checkBranches(ofInitializersIn: files)

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

        var literalCaptures: [String: [String]] = [:]
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
                try checker.check(function, branchErrors: file.branchErrors)
                literalCaptures.merge(checker.captures) { first, _ in first }
            }
        }

        var package = GoTypedPackage(
            name: first.packageName,
            files: files,
            typeDefinitions: typeDefinitions,
            globalTypes: globalBindings.mapValues(\.type))
        package.literalCaptures = literalCaptures
        return package
    }

    /// A name a file declares at package level, where it is, and whether a
    /// function has it.
    private typealias DeclaredName = (name: String, position: GoSourcePosition, isFunction: Bool)

    /// Reserves the names one file declares, in the order of the source.
    /// `init`, and `main` in the main package, are names of functions only.
    private static func reservePackageNames(
        _ declared: [DeclaredName], isMain: Bool, names: inout [String: GoSourcePosition]
    ) throws {
        for entry in declared.sorted(by: { $0.position.offset < $1.position.offset }) {
            // The symbol of a linked package ends in the name it was given.
            let name = entry.name.split(separator: ".").last.map(String.init) ?? entry.name
            if !entry.isFunction, name == "init" || (isMain && entry.name == "main") {
                throw GoDiagnostic(
                    position: entry.position, message: "cannot declare \(name) - must be func")
            }
            try reservePackageName(entry.name, at: entry.position, names: &names)
        }
    }

    /// A function literal among the initializers of package-level variables
    /// has labels and jumps of its own, which the parser checked.
    private static func checkBranches(ofInitializersIn files: [GoFile]) throws {
        for file in files where !file.branchErrors.isEmpty {
            for declaration in file.globalDeclarations {
                guard let expression = declaration.expression else { continue }
                var first: GoDiagnostic?
                GoFunctionLiterals.forEach(in: expression) { literal in
                    first = first ?? file.branchErrors[literal.position.offset]?.first
                }
                if let first { throw first }
            }
        }
    }

    private static func reservePackageName(
        _ name: String,
        at position: GoSourcePosition,
        names: inout [String: GoSourcePosition]
    ) throws {
        guard names[name] == nil else {
            throw GoDiagnostic.redeclared(name, at: position, other: names[name])
        }
        names[name] = position
    }

    /// Whether the run-time library package at `path` has `member`: a type,
    /// a value, or a function. Nothing lists what such a package declares.
    /// The checker knows each member where a program can write it, so it is
    /// asked the way a program asks: as a type, as a value, and as a call.
    static func libraryDeclares(path: String, member: String) -> Bool {
        if GoSourceLibrary.declares(path: path, member: member) { return true }
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
            checker.isProbing = true
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
                "net.Conn", "net.Listener",
                "http.Response", "http.ResponseWriter", "http.Request",
                "time.Time", "os.File":
                return .named(name)
            case GoLibraryTypes.durationName: return GoLibraryTypes.duration
            default:
                if let numeric = GoPredeclared.numericType(name) { return numeric }
                guard availableTypes.contains(name) else {
                    throw GoPredeclared.unsupportedNumericTypes.contains(name)
                        ? GoDiagnostic(
                            position: position, message: GoPredeclared.unsupportedTypeMessage(name))
                        : GoDiagnostic.undefinedType(name, at: position)
                }
                return .named(name)
            }
        case .structure(let fields, _):
            var names: Set<String> = []
            let resolvedFields = try fields.map { field -> GoStructFieldType in
                guard names.insert(field.name).inserted else {
                    throw GoDiagnostic.redeclared(
                        field.name, at: field.position,
                        other: fields.first { $0.name == field.name }?.position, inBlock: false)
                }
                return GoStructFieldType(
                    field, type: try resolve(field.type, availableTypes: availableTypes))
            }
            return .structure(resolvedFields)
        case .pointer(let pointee, _):
            return .pointer(try resolve(pointee, availableTypes: availableTypes))
        case .array(let length, let element, let position):
            try GoCompositeLiterals.requireLength(length, at: position)
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
            if let signature = expression.functionSignature {
                return .function(
                    parameters: try signature.parameters.map {
                        try resolve($0, availableTypes: availableTypes)
                    },
                    results: try signature.results.map {
                        try resolve($0, availableTypes: availableTypes)
                    })
            }
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
                throw GoDiagnostic.unknownReceiver(name, at: position)
            }
            return (name, false)
        case .pointer(let pointee, _):
            guard case .named(let name, let position) = pointee else {
                throw GoDiagnostic(
                    position: pointee.position,
                    message: "invalid receiver type \(expression.sourceSpelling)")
            }
            guard availableTypes.contains(name) else {
                throw GoDiagnostic.unknownReceiver(name, at: position)
            }
            return (name, true)
        default:
            throw GoDiagnostic(
                position: expression.position,
                message: "invalid receiver type \(expression.sourceSpelling)")
        }
    }

    private static func methodKey(baseName: String, pointer: Bool, method: String) -> String {
        "\(pointer ? "*" : "")\(baseName).\(method)"
    }

    /// The first of `diagnostics`, each an `undefined: name` that kept a
    /// package-level variable from being typed, whose name is none of the
    /// variables still waiting: a name nothing declares, and no cycle.
    private static func firstUndeclared(
        _ diagnostics: [GoDiagnostic], among waiting: [GoGlobalDeclaration]
    ) -> GoDiagnostic? {
        let names = Set(waiting.map(\.name))
        return diagnostics.first { diagnostic in
            undeclaredName(in: diagnostic).map { !names.contains($0) } ?? false
        }
    }

    /// The name a diagnostic says nothing declares, which a package-level
    /// variable that is yet to be typed may be: `undefined: name`, and what
    /// is said of `iota`, which a package may declare like any other name.
    private static func undeclaredName(in diagnostic: GoDiagnostic) -> String? {
        if diagnostic.message.hasPrefix("undefined: ") {
            return String(diagnostic.message.dropFirst("undefined: ".count))
        }
        return diagnostic.message == FunctionChecker.undeclaredMessage(GoIota.name)
            ? GoIota.name : nil
    }

    /// Go gives no methods to a type that is a pointer or an interface
    /// underneath: `type ptr *T` selects the fields of `T` and nothing else.
    private static func requireMethodReceiver(
        _ name: String, definitions: [String: GoTypeDefinition], receiver: GoTypeExpression
    ) throws {
        var underlying = definitions[name]?.underlying
        var seen: Set<String> = [name]
        while case .named(let next)? = underlying, seen.insert(next).inserted {
            underlying = definitions[next]?.underlying
        }
        switch underlying {
        case .pointer?, .interface?:
            // Reported where the name of the type is, after a `*`.
            var position = receiver.position
            if case .pointer(let pointee, _) = receiver { position = pointee.position }
            throw GoDiagnostic(
                position: position,
                message: "invalid receiver type \(name) (pointer or interface type)")
        default:
            return
        }
    }

    private static func rejectRecursiveValueType(
        _ root: String,
        definitions: [String: GoTypeDefinition],
        position: GoSourcePosition,
        places: [String: GoSourcePosition]
    ) throws {
        // The types between `type` and `root`, when a value of `type`
        // holds one of `root` without a pointer, a slice, or the like
        // between them.
        func cycle(_ type: GoType, visiting: inout Set<String>) -> [String]? {
            switch type {
            case .named(let name):
                if name == root { return [] }
                guard visiting.insert(name).inserted,
                    let definition = definitions[name]
                else { return nil }
                defer { visiting.remove(name) }
                return cycle(definition.underlying, visiting: &visiting).map { [name] + $0 }
            case .structure(let fields):
                for field in fields {
                    if let found = cycle(field.type, visiting: &visiting) { return found }
                }
                return nil
            case .array(_, let element):
                return cycle(element, visiting: &visiting)
            default:
                return nil
            }
        }

        guard let definition = definitions[root] else { return }
        var visiting: Set<String> = [root]
        guard let between = cycle(definition.underlying, visiting: &visiting) else { return }
        guard !between.isEmpty else {
            throw GoDiagnostic(
                position: position, message: "invalid recursive type: \(root) refers to itself")
        }
        // As Go lists a cycle of several types: each with what it refers to.
        let names = [root] + between
        var message = "invalid recursive type \(root)"
        for (index, name) in names.enumerated() {
            message += "\n\t" + GoDiagnostic.place(places[name] ?? position)
                + ": \(name) refers to \(names[(index + 1) % names.count])"
        }
        throw GoDiagnostic(position: position, message: message)
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

struct FunctionSignature {
    let parameters: [GoType]
    let results: [GoType]
    /// The names the declaration gives its parameters and results, which
    /// Go prints in the type of the function. Behind a reference: a
    /// signature is copied in many frames, and only a message reads these.
    var names: GoSignatureNames? = nil
}

private func builtinErrorType() -> GoType {
    .interface([
        GoInterfaceMethod(name: "Error", results: [.string])
    ])
}

struct Binding {
    let type: GoType
    let isConstant: Bool
    /// The value of a numeric constant, typed or untyped, with which the
    /// constant expressions that name it are folded. Behind a reference: a
    /// binding is copied in many frames, and the value is seldom there.
    var constantBox: GoConstantBox? = nil
    /// Value of a constant declared without a type from an untyped integer
    /// constant expression. Such a name stays usable with any integer type.
    var constantValue: Int64? = nil
    /// Where a statement of a function declared the variable. Go requires
    /// such a variable to be read; a parameter, a result, and a variable of
    /// the package have no position and need not be.
    var position: GoSourcePosition? = nil
    var isUsed = false
}

enum SwitchCaseConstant: Hashable {
    case int(Int64)
    case string(String)
}

struct FunctionChecker {
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
    /// Whether the checker is being asked what a library package declares,
    /// which a report must not ask in turn.
    var isProbing = false
    /// The function literals being checked, innermost last: the name of
    /// each and the first scope that is its own.
    var literals: [(name: String, base: Int)] = []
    /// The variables of the functions around it that each literal reads or
    /// assigns. The compiler passes the literal a pointer to each.
    var captures: [String: [String]] = [:]
    /// The types of the operands of the binary operator being typed, when
    /// the rule for numbers found them and left the operator to the rest.
    var operandTypesInHand: (left: GoType, right: GoType)?

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

    // MARK: Function values

    func isFunction(_ type: GoType) -> Bool {
        if case .function = underlying(type) { return true }
        return false
    }

    /// Whether `type` is written out and has no name: a pointer, a slice, a
    /// function, and the like.
    func isUnnamedComposite(_ type: GoType) -> Bool {
        switch type {
        case .pointer, .array, .slice, .map, .channel, .structure, .function: return true
        default: return false
        }
    }

    /// Whether `type` is a named type of the program whose structure is one
    /// of those.
    func isNamedComposite(_ type: GoType) -> Bool {
        guard case .named(let name) = type, typeDefinitions[name] != nil else { return false }
        return isUnnamedComposite(underlying(type))
    }

    /// What Go says of two values that `==` cannot compare. A function, a
    /// slice, and a map compare with nil alone.
    func incomparableMessage(_ type: GoType) -> String {
        let kind: String
        switch underlying(type) {
        case .function: kind = "func"
        case .slice: kind = "slice"
        case .map: kind = "map"
        default: return "values are not comparable"
        }
        return "invalid operation: \(kind) can only be compared to nil"
    }

    /// What Go says of a call of `name` when it names a value that is no
    /// function; nil when it names nothing.
    func uncallableMessage(_ name: String) -> String? {
        if name == "nil" { return "invalid operation: cannot call non-function nil" }
        if name == GoValueList.blank { return Self.undeclaredMessage(name) }
        guard let binding = lookup(name) else { return nil }
        var describer = self
        return "invalid operation: cannot call non-function "
            + describer.describe(
                .identifier(name, position: syntheticPosition()), ofType: binding.type)
    }

    /// The report for `package.name` where a value is expected and the
    /// package has a function of that name that cannot be one (see
    /// `GoLibraryValue.function`): it can only be called.
    func libraryFunctionValueMessage(_ packageName: String, _ name: String) -> String? {
        guard !isProbing,
            let path = importedPaths.first(where: {
                GoImportName.defaultName(ofPath: $0) == packageName
            }),
            GoTypeChecker.libraryDeclares(path: path, member: name)
        else { return nil }
        return "\(packageName).\(name) is a function of the run-time library, which can only be called: "
            + "wrap the call in a function literal to pass it"
    }

    /// The type of `package.name` where a value is expected and the package
    /// has a function of that name that can be one: the function's type.
    func libraryFunctionType(_ packageName: String, _ name: String) -> GoType? {
        GoLibraryValue.function(package: packageName, member: name)?.type
    }

    /// The type of `value.name` where `value` is of a type of the run-time
    /// library and `name` one of its methods: a function that has its
    /// receiver, like a method value of a type of the program.
    func libraryMethodType(of type: GoType, named name: String) -> GoType? {
        GoLibraryValue.method(of: type, named: name)?.type
    }

    /// The type of `T.m` or `(*T).m`, a method expression: the method as a
    /// function that takes its receiver first. Nil when `base` names no
    /// type of the program.
    func methodExpressionType(
        base: GoExpression, name: String, position: GoSourcePosition
    ) throws -> GoType? {
        guard let receiver = GoMethodExpression.receiver(of: base),
            lookup(receiver.typeName) == nil, typeDefinitions[receiver.typeName] != nil
        else { return nil }
        let typeName = receiver.typeName
        let value = methodSignatures[methodKey(baseName: typeName, pointer: false, method: name)]
        let pointer = methodSignatures[methodKey(baseName: typeName, pointer: true, method: name)]
        if value != nil || pointer != nil, isHidden(name, in: .named(typeName)) {
            throw GoDiagnostic(
                position: position,
                message: "\(GoMethodExpression.spelling(receiver, name)) undefined "
                    + "(cannot refer to unexported method \(name))")
        }
        guard let method = value ?? (receiver.pointer ? pointer : nil) else {
            let isField = structFields(of: .named(typeName))?.contains { $0.name == name } == true
            throw GoDiagnostic(
                position: position,
                message: pointer == nil
                    ? "\(GoMethodExpression.spelling(receiver, name)) undefined "
                        + "(type \(receiver.pointer ? "*" : "")\(typeName) has no "
                        + "\(isField ? "" : "field or ")method \(name))"
                    : "invalid method expression \(typeName).\(name) "
                        + "(needs pointer receiver (*\(typeName)).\(name))")
        }
        let receiverType: GoType = receiver.pointer ? .pointer(.named(typeName)) : .named(typeName)
        return .function(parameters: [receiverType] + method.parameters, results: method.results)
    }

    /// The results of calling `callee` when it is a method expression,
    /// `T.m(receiver, arguments)`; nil when it is anything else.
    mutating func methodExpressionResults(
        _ callee: GoExpression, arguments: [GoExpression], position: GoSourcePosition
    ) throws -> [GoType]? {
        guard case .selector(let base, let name, _) = callee,
            let receiver = GoMethodExpression.receiver(of: base),
            let method = try methodExpressionType(base: base, name: name, position: callee.position)
        else { return nil }
        _ = receiver
        return try resultsOfCall(
            through: method, callee: callee, arguments: arguments, position: position)
    }

    /// The results of calling a value of `type` with `arguments`, or nil
    /// when the type is no function.
    mutating func resultsOfCall(
        through calleeType: GoType, callee: GoExpression, arguments: [GoExpression],
        position: GoSourcePosition
    ) throws -> [GoType]? {
        guard case .function(let declared, let results) = underlying(calleeType) else {
            return nil
        }
        try checkArguments(arguments, of: callee, declared: declared, position: position)
        return results
    }

    /// `base.name` with the embedded fields between the two written out,
    /// when `name` is a field or a method that an embedded field lends the
    /// struct `base` is; nil when the struct has the name itself or nobody
    /// lends it. A method of the run-time library that is selected and not
    /// called is left to the method declared for it, which is a function
    /// where the library's is none.
    func promotedSelector(
        base: GoExpression, baseType: GoType, name: String, position: GoSourcePosition,
        isCalled: Bool = false
    ) throws -> GoExpression? {
        switch GoEmbedding.promotion(of: name, in: baseType, definitions: typeDefinitions) {
        case .none:
            return nil
        case .ambiguous:
            throw GoDiagnostic(
                position: position,
                message: "ambiguous selector \(base.spelledAsOperand(in: namePositions)).\(name)")
        case .found(let promotion):
            if promotion.isMethod, promotion.holderKind == .library, !isCalled,
                methodSignature(of: baseType, named: name) != nil
            {
                return nil
            }
            return promotion.selector(name, of: base, position: position)
        }
    }

    /// The type of `base.name` when an embedded field lends the name, as a
    /// value or, with `assignable`, as what a value is stored in. Each of
    /// these is a function of its own so that the ones that ask, which call
    /// themselves for every operand, keep nothing more in their frames.
    mutating func promotedType(
        base: GoExpression, baseType: GoType, name: String, at position: GoSourcePosition,
        assignable: Bool = false
    ) throws -> GoType? {
        guard
            let promoted = try promotedSelector(
                base: base, baseType: baseType, name: name, position: position)
        else { return nil }
        return try assignable ? assignableType(of: promoted) : type(of: promoted)
    }

    /// The results of the call of `callee`, a selection from a value of
    /// `baseType`, when an embedded field lends what is called: a method,
    /// or a field that holds a function. `single` asks for the one value a
    /// call has where a value is wanted.
    mutating func promotedCallResults(
        _ callee: GoExpression, baseType: GoType, arguments: [GoExpression],
        position: GoSourcePosition, single: Bool
    ) throws -> [GoType]? {
        guard case .selector(let base, let name, let namePosition) = callee,
            let promoted = try promotedSelector(
                base: base, baseType: baseType, name: name, position: namePosition,
                isCalled: true)
        else { return nil }
        if single {
            // Whether one value is wanted was settled for the call as the
            // source writes it: as a statement it may have several results.
            return [
                try callType(
                    of: .call(callee: promoted, arguments: arguments, position: position),
                    callee: promoted, arguments: arguments, position: position)
            ]
        }
        return try callResultTypes(callee: promoted, arguments: arguments, position: position)
    }

    /// The native method of the library that `callee` calls when an
    /// embedded field lends it, checked against `arguments`.
    mutating func promotedNativeCall(
        _ callee: GoExpression, arguments: [GoExpression], position: GoSourcePosition
    ) throws -> GoNativeFunction? {
        guard case .selector(let base, let name, let namePosition) = callee,
            let baseType = try? type(of: base),
            let promoted = try promotedSelector(
                base: base, baseType: baseType, name: name, position: namePosition,
                isCalled: true)
        else { return nil }
        return try nativeCall(callee: promoted, arguments: arguments, position: position)
    }

    /// What the method `name` of a value of `type` takes and gives, without
    /// its receiver.
    func methodSignature(of type: GoType, named name: String) -> FunctionSignature? {
        if let library = GoLibraryTypes.method(of: type, named: name) {
            return FunctionSignature(parameters: library.parameters, results: library.results)
        }
        let candidates: [String]
        switch type {
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
        return candidates.lazy.compactMap { methodSignatures[$0] }.first
    }

    /// The type of a function literal. Its body is checked as a function's
    /// is, inside the scopes of the function it is written in: a variable
    /// of those that it names is one it captures.
    mutating func functionLiteralType(
        parameters: [GoParameter], resultNames: [String?], resultTypes: [GoTypeExpression],
        body: GoBlock, position: GoSourcePosition
    ) throws -> GoType {
        let parameterTypes = try parameters.map { try declaredType($0.type) }
        let resolvedResults = try resultTypes.map(declaredType)
        let savedResults = expectedResults
        let savedNamedCount = namedResultCount
        let savedDepths = (breakableDepth, loopDepth)
        scopes.append([:])
        literals.append((GoFunctionType.literalName(at: position), scopes.count - 1))
        defer {
            literals.removeLast()
            scopes.removeLast()
            expectedResults = savedResults
            namedResultCount = savedNamedCount
            (breakableDepth, loopDepth) = savedDepths
        }
        expectedResults = resolvedResults
        namedResultCount = 0
        // A `break` in the literal does not leave a loop around it.
        (breakableDepth, loopDepth) = (0, 0)
        try bind(parameters, ofTypes: parameterTypes)
        bind(results: resultNames, ofTypes: resolvedResults)
        try checkBlock(body, createsScope: false)
        endScope()
        if !resolvedResults.isEmpty, !blockTerminates(body) {
            throw GoDiagnostic(
                position: namePositions[position.offset]?.last ?? position,
                message: "missing return")
        }
        return .function(parameters: parameterTypes, results: resolvedResults)
    }

    // MARK: Unused variables

    /// A statement reads the variable `name`.
    mutating func use(_ name: String) {
        for index in scopes.indices.dropFirst().reversed() where scopes[index][name] != nil {
            scopes[index][name]?.isUsed = true
            capture(name, declaredIn: index)
            return
        }
    }

    /// A function literal names `name`, a variable of the scope at `index`.
    /// It is captured by every literal being checked that the scope is
    /// outside of: an inner literal reaches it through the outer ones.
    mutating func capture(_ name: String, declaredIn index: Int) {
        for literal in literals where literal.base > index {
            if captures[literal.name]?.contains(name) != true {
                captures[literal.name, default: []].append(name)
            }
        }
    }

    /// The variable `name` of the innermost scope was declared at `position`.
    mutating func place(_ name: String, at position: GoSourcePosition) {
        // A stand-in the checker made up is nothing the source declares.
        guard name != GoValueList.blank, !name.hasPrefix("$"),
            let binding = scopes[scopes.count - 1][name], binding.position == nil
        else { return }
        scopes[scopes.count - 1][name]?.position = position
        // A constant need not be read; where it is declared is kept for a
        // second declaration of its name.
        if binding.isConstant { scopes[scopes.count - 1][name]?.isUsed = true }
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
                // The key of a map may be a variable. The name of a field
                // is none, whatever variable has the same name.
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
        // The name a type switch binds is kept as its guard has it, and
        // reported in the words Go has for it.
        let prefix = GoTypeSwitch.bindingPrefix
        return GoDiagnostic(
            position: first.position,
            message: first.name.hasPrefix(prefix)
                ? "\(first.name.dropFirst(prefix.count)) declared and not used"
                : "declared and not used: \(first.name)")
    }

    /// What to report for `function` when checking its body from `self`
    /// ended in `diagnostic`.
    ///
    /// Go checks on after an error and reports all it finds in the order of
    /// the source, so an unused variable declared before this error comes
    /// first, and so does a label or a jump that is out of place. Whether a
    /// variable is unused takes the rest of the function to say: it is
    /// checked again, past its errors. This is done here, off the stack the
    /// body was checked on, which a deeply nested function nearly fills.
    func firstError(
        of function: GoFunctionDeclaration, before diagnostic: GoDiagnostic,
        branchErrors: [Int: [GoDiagnostic]]
    ) -> GoDiagnostic {
        var recovery = self
        recovery.isRecovering = true
        try? recovery.checkBlock(function.body, createsScope: false)
        recovery.endScope()
        var branchError = branchError(in: function, of: branchErrors)
        if let found = branchError, found.position.offset >= diagnostic.position.offset {
            branchError = nil
        }
        return Self.first(of: [recovery.unusedVariable(before: diagnostic.position), branchError])
            ?? diagnostic
    }

    /// Reports the first variable of `function` that nothing reads, or the
    /// first label or jump of it that is out of place, whichever the source
    /// has first.
    func reportUnused(
        in function: GoFunctionDeclaration, branchErrors: [Int: [GoDiagnostic]]
    ) throws {
        let first = Self.first(of: [unusedVariable(), branchError(in: function, of: branchErrors)])
        if let first { throw first }
    }

    /// The first error among the labels and jumps of `function` and of the
    /// function literals in it, of those the parser found in the file.
    func branchError(
        in function: GoFunctionDeclaration, of branchErrors: [Int: [GoDiagnostic]]
    ) -> GoDiagnostic? {
        guard !branchErrors.isEmpty else { return nil }
        var errors = branchErrors[function.position.offset] ?? []
        GoFunctionLiterals.forEach(in: function.body) { literal in
            errors += branchErrors[literal.position.offset] ?? []
        }
        return Self.first(of: errors)
    }

    /// The diagnostic that comes first in the source, which is the one Go
    /// prints first.
    static func first(of diagnostics: [GoDiagnostic?]) -> GoDiagnostic? {
        diagnostics.compactMap { $0 }.min { $0.position.offset < $1.position.offset }
    }

    mutating func check(
        _ function: GoFunctionDeclaration, branchErrors: [Int: [GoDiagnostic]] = [:]
    ) throws {
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
            if receiver.name != GoValueList.blank {
                scopes[scopes.count - 1][receiver.name] = Binding(
                    type: receiverType,
                    isConstant: false, position: receiver.position, isUsed: true)
            }
        } else {
            signature = functionSignatures[function.name]
        }
        guard let signature else {
            throw GoDiagnostic(position: function.position, message: "undefined: \(function.name)")
        }
        expectedResults = signature.results
        for (parameter, parameterType) in zip(function.parameters, signature.parameters) {
            // A parameter without a name, or with the blank one, is none
            // the body can use, and any number may be so.
            if parameter.name == GoValueList.blank { continue }
            guard scopes[scopes.count - 1][parameter.name] == nil else {
                throw GoDiagnostic.redeclared(
                    parameter.name, at: parameter.position,
                    other: scopes[scopes.count - 1][parameter.name]?.position)
            }
            // A parameter need not be read; where it is declared is kept
            // for a second declaration of its name.
            scopes[scopes.count - 1][parameter.name] = Binding(
                type: parameterType.parameterType,
                isConstant: false, position: parameter.position, isUsed: true)
        }
        for (index, (name, resultType)) in zip(function.resultNames, signature.results).enumerated() {
            guard let name else { continue }
            if name == GoValueList.blank {
                // Named, so a bare `return` will do; nothing reads it.
                namedResultCount += 1
                continue
            }
            guard scopes[scopes.count - 1][name] == nil else {
                // The names of the results follow the two places above.
                let named = function.resultNames.prefix(index).compactMap { $0 }.count + 2
                throw GoDiagnostic.redeclared(
                    name,
                    at: positions.flatMap { named < $0.count ? $0[named] : $0.first }
                        ?? function.position,
                    other: scopes[scopes.count - 1][name]?.position)
            }
            let named = function.resultNames.prefix(index).compactMap { $0 }.count + 2
            scopes[scopes.count - 1][name] = Binding(
                type: resultType, isConstant: false,
                position: positions.flatMap { named < $0.count ? $0[named] : nil }, isUsed: true)
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
            throw entry.firstError(of: function, before: diagnostic, branchErrors: branchErrors)
        }
        endScope()
        try reportUnused(in: function, branchErrors: branchErrors)
        if !signature.results.isEmpty, !blockTerminates(function.body) {
            // Go reports the return a function lacks where its body ends.
            throw GoDiagnostic(
                position: positions.flatMap { $0.count > 1 ? $0[1] : nil } ?? function.position,
                message: "missing return")
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
            guard case .call = expression, !(try isOperatorOrConversion(expression)) else {
                _ = position
                throw try uncallableStatement(expression, after: keyword)
            }
            try checkCall(expression, droppedBy: keyword)
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
        try requireUndeclared(statement)
        if let expression {
            try requireOneValue(expression, assigned: isShortDeclaration(at: position))
        }
        let declared = try explicitType.map { try declaredType($0) }
        let expressionType = try expression.map { try type(of: $0) }
        if isConstant { try requireConstant(expression, ofType: expressionType) }
        if let declared, let expression, let expressionType {
            try requireUse(
                expression, ofType: expressionType, as: declared,
                in: isConstant ? "constant declaration" : "variable declaration")
        }
        guard let bindingType = declared ?? expressionType else {
            throw GoDiagnostic(position: position, message: "missing type in declaration")
        }
        guard bindingType != .void, bindingType != .nilType else {
            throw valueless(expression, ofType: bindingType, isConstant: isConstant, at: position)
        }
        // `var _ = v` checks and evaluates `v` and declares nothing.
        if name == GoValueList.blank { return }
        scopes[scopes.count - 1][name] = Binding(
            type: bindingType,
            isConstant: isConstant,
            constantValue: isConstant && declared == nil
                ? expression.flatMap { untypedConstantValue($0) } : nil)
        try noteChecked(
            name, declared: declared, expression: expression, isConstant: isConstant,
            position: position)
    }

    private mutating func checkAssignmentStatement(_ statement: GoStatement) throws {
        guard case .assignment(let target, let expression, _) = statement else {
            return
        }
        if target.isBlank {
            // `_ = x` evaluates `x` and keeps nothing.
            try requireOneValue(expression, assigned: true)
            try requireValue(expression, in: "assignment to _ identifier")
            return
        }
        let targetType = try targetType(of: target)
        try requireOneValue(expression, assigned: true)
        try requireUse(expression, as: targetType, in: "assignment")
    }

    private mutating func checkMultiDeclarationStatement(_ statement: GoStatement) throws {
        guard case .multiDeclaration(let names, let expression, let position) = statement else {
            return
        }
        if let variables = expression.variables {
            if variables.isConstant {
                // Constants are values of the compiler: one declaration each.
                guard variables.values.count == names.count else {
                    throw try arityMismatch(
                        names, values: variables.values, isConstant: true, position: position)
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
        try requireNewVariables(names, at: position)
        if let values = expression.valueList {
            try checkParallelDeclaration(names, values: values, position: position)
            return
        }
        if !isVariableDeclaration(names, at: position),
            names.allSatisfy({ $0 == GoValueList.blank || scopes[scopes.count - 1][$0] != nil })
        {
            throw GoDiagnostic(
                position: position, message: "no new variables on left side of :=")
        }
        if let statements = GoStatement.redeclaration(
            names: names, expression: expression, position: position,
            declared: Set(names.filter { scopes[scopes.count - 1][$0] != nil }))
        {
            try checkRedeclaration(statements, of: expression)
            return
        }
        if case .unary(.receive, let channel, _) = expression,
            case .channel(let direction, let elementType) = underlying(try type(of: channel))
        {
            guard direction != .sendOnly else {
                throw try invalidOperand(
                    "cannot receive from send-only channel", channel, ofType: type(of: channel))
            }
            guard names.count == 2 else {
                throw try countMismatch(variables: names.count, values: [expression])
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
                throw try countMismatch(variables: names.count, values: [expression])
            }
            try requireUse(key, as: keyType, in: "map index")
            scopes[scopes.count - 1][names[0]] = Binding(
                type: valueType, isConstant: false)
            scopes[scopes.count - 1][names[1]] = Binding(
                type: .bool, isConstant: false)
            return
        }
        if case .typeAssertion(_, let assertedType, _) = expression {
            guard names.count == 2 else {
                throw try countMismatch(variables: names.count, values: [expression])
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
            throw try countMismatch(variables: names.count, values: [expression])
        }
        let resultTypes = try callResultTypes(
            callee: callee, arguments: arguments, position: callPosition)
        guard resultTypes.count == names.count else {
            throw resultCountMismatch(
                variables: names.count, call: expression, results: resultTypes.count)
        }
        for (name, resultType) in zip(names, resultTypes) {
            // The blank identifier declares nothing and may repeat.
            if name == "_" { continue }
            guard scopes[scopes.count - 1][name] == nil else {
                throw GoDiagnostic.redeclared(
                    name, at: position, other: scopes[scopes.count - 1][name]?.position)
            }
            scopes[scopes.count - 1][name] = Binding(
                type: resultType, isConstant: false)
        }
    }

    private mutating func checkMultiAssignmentStatement(_ statement: GoStatement) throws {
        guard case .multiAssignment(let targets, let expression, _) = statement else {
            return
        }
        if let values = expression.valueList {
            guard targets.count == values.count else {
                throw try countMismatch(variables: targets.count, values: values)
            }
            for (target, value) in zip(targets, values) {
                if target.isBlank {
                    try requireValue(value, in: "assignment to _ identifier")
                    continue
                }
                let targetType = try targetType(of: target)
                try requireSingleValue(value, at: value.position)
                try requireUse(value, as: targetType, in: "assignment")
            }
            return
        }
        if case .unary(.receive, let channel, _) = expression,
            case .channel(let direction, let elementType) = underlying(try type(of: channel))
        {
            guard direction != .sendOnly else {
                throw try invalidOperand(
                    "cannot receive from send-only channel", channel, ofType: type(of: channel))
            }
            guard targets.count == 2 else {
                throw try countMismatch(variables: targets.count, values: [expression])
            }
            try requireCommaOk(expression, results: [elementType, .bool], targets: targets)
            return
        }
        if case .index(let base, let key, _) = expression,
            case .map(let keyType, let valueType) = underlying(try type(of: base))
        {
            guard targets.count == 2 else {
                throw try countMismatch(variables: targets.count, values: [expression])
            }
            try requireUse(key, as: keyType, in: "map index")
            try requireCommaOk(expression, results: [valueType, .bool], targets: targets)
            return
        }
        if case .typeAssertion(_, let assertedType, _) = expression {
            guard targets.count == 2 else {
                throw try countMismatch(variables: targets.count, values: [expression])
            }
            _ = try type(of: expression)
            try requireCommaOk(
                expression, results: [try declaredType(assertedType), .bool], targets: targets)
            return
        }
        guard case .call(let callee, let arguments, let callPosition) = expression else {
            throw try countMismatch(variables: targets.count, values: [expression])
        }
        let resultTypes = try callResultTypes(
            callee: callee, arguments: arguments, position: callPosition)
        guard resultTypes.count == targets.count else {
            throw resultCountMismatch(
                variables: targets.count, call: expression, results: resultTypes.count)
        }
        for (target, resultType) in zip(targets, resultTypes) {
            if target.isBlank { continue }
            let targetType = try targetType(of: target)
            guard isAssignable(resultType, to: targetType) else {
                throw cannotUseResult(
                    of: expression, type: resultType, as: targetType, in: "assignment")
            }
        }
    }

    private mutating func checkIncrementStatement(_ statement: GoStatement) throws {
        guard case .increment(let target, let incrementOperator, let position) = statement else {
            return
        }
        let targetType = try targetType(of: target, isRead: true)
        guard isInteger(targetType) || isFloat(targetType) else {
            let spelling = incrementOperator == .increment ? "++" : "--"
            throw GoDiagnostic(
                position: position,
                message: "invalid operation: \(target.sourceSpelling)\(spelling) "
                    + "(non-numeric type \(targetType))")
        }
    }

    private mutating func checkExpressionStatement(_ statement: GoStatement) throws {
        guard case .expression(let expression) = statement else {
            return
        }
        if try isLabelOrJump(expression) { return }
        guard case .call = expression else {
            if case .unary(.receive, _, _) = expression {
                _ = try type(of: expression)
                return
            }
            throw try unused(expression)
        }
        if try isOperatorOrConversion(expression) { throw try unused(expression) }
        try checkCall(expression, droppedBy: nil)
    }

    private mutating func checkReturnValuesStatement(_ statement: GoStatement) throws {
        guard case .returnValues(let values, let position) = statement else {
            return
        }
        guard !expectedResults.isEmpty else {
            guard values.isEmpty else {
                throw try returnCountMismatch(values, at: position)
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
            guard results.count == expectedResults.count else {
                throw returnCountMismatch(of: values[0], results: results)
            }
            for (actual, expected) in zip(results, expectedResults) {
                guard isAssignable(actual, to: expected) else {
                    throw cannotUseResult(
                        of: values[0], type: actual, as: expected, in: "return statement")
                }
            }
            return
        }
        guard values.count == expectedResults.count else {
            throw try returnCountMismatch(values, at: position)
        }
        if values.count == 1 { try rejectSeveralReturnValues(values[0]) }
        for (value, expected) in zip(values, expectedResults) {
            try requireUse(value, as: expected, in: "return statement")
        }
    }

    private mutating func checkSendStatement(_ statement: GoStatement) throws {
        guard case .sendStatement(let channel, let value, _) = statement else {
            return
        }
        let channelType = try type(of: channel)
        guard case .channel(let direction, let elementType) = underlying(channelType) else {
            throw invalidOperand("cannot send to non-channel", channel, ofType: channelType)
        }
        guard direction != .receiveOnly else {
            throw invalidOperand("cannot send to receive-only channel", channel, ofType: channelType)
        }
        try requireUse(value, as: elementType, in: "send")
    }

    private mutating func checkIfStatement(_ statement: GoStatement) throws {
        guard case .ifStatement(let condition, let thenBlock, let elseBlock, _) = statement else {
            return
        }
        try requireBool(condition, in: "if statement")
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
            try requireBool(condition, in: "for statement")
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
        switch rangedType(collectionType) {
        case .array(_, let element): elementType = element
        case .slice(let element): elementType = element
        case .string: elementType = GoPredeclared.rune
        case .map(_, let value): elementType = value
        case .channel(let direction, let element):
            guard direction != .sendOnly else {
                throw unrangeable(
                    collection, ofType: collectionType, why: ": receive from send-only channel")
            }
            guard valueName == nil else {
                throw tooManyRangeVariables(over: collection, ofType: collectionType, at: position)
            }
            elementType = element
        case .int:
            // `for i := range n`: the integers below `n`.
            guard valueName == nil else {
                throw tooManyRangeVariables(over: collection, ofType: collectionType, at: position)
            }
            elementType = .int
        default:
            throw unrangeable(collection, ofType: collectionType, why: "")
        }
        if let indexName {
            let indexType: GoType
            if case .map(let key, _) = underlying(collectionType) {
                indexType = key
            } else if case .channel(_, let element) = underlying(collectionType) {
                indexType = element
            } else {
                indexType = integerRangeType(collectionType)
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
        if statement.isTypeSwitch {
            try checkTypeSwitchStatement(statement)
            return
        }
        let switchType = try expression.map { try type(of: $0) } ?? .bool
        guard switchType != .void else {
            if let expression { throw noValue(expression) }
            throw GoDiagnostic(
                position: cases.first?.position ?? syntheticPosition(),
                message: "switch expression used as value")
        }
        try requireSwitchable(switchType, expression)
        var firstDefault: GoSourcePosition?
        var constants: [SwitchCaseConstant: GoSourcePosition] = [:]
        breakableDepth += 1
        defer { breakableDepth -= 1 }
        for switchCase in cases {
            if switchCase.isDefault {
                try requireOneDefault(at: switchCase.position, after: firstDefault)
                firstDefault = switchCase.position
            }
            for caseExpression in switchCase.expressions {
                try requireCase(caseExpression, of: switchType, switched: expression)
                guard let constant = switchCaseConstant(caseExpression) else { continue }
                let place = Self.start(of: caseExpression, in: namePositions)
                if let previous = constants.updateValue(place, forKey: constant) {
                    throw duplicateCase(caseExpression, of: switchType, at: place, after: previous)
                }
            }
            try checkBlock(switchCase.body)
        }
    }

    /// Whether a value of `type` compares with nil and with nothing else:
    /// a slice, a map, and a function. A switch on one has `nil` for its
    /// only case, as Go allows.
    func comparesWithNilAlone(_ type: GoType) -> Bool {
        !isComparable(type) && isAssignable(.nilType, to: type)
    }

    /// What a `switch` is on has a type, and one whose values compare.
    mutating func requireSwitchable(_ type: GoType, _ expression: GoExpression?) throws {
        let position = expression.map { Self.start(of: $0, in: namePositions) } ?? syntheticPosition()
        guard type != .nilType else {
            throw GoDiagnostic(
                position: position, message: "use of untyped nil in switch expression")
        }
        guard isComparable(type) || comparesWithNilAlone(type) else {
            guard let expression else {
                throw GoDiagnostic(position: position, message: "switch expression is not comparable")
            }
            throw GoDiagnostic(
                position: position,
                message: "cannot switch on \(describe(expression, ofType: type)) "
                    + "(\(type) is not comparable)")
        }
    }

    /// A case of a switch on a value of `switchType` compares with it: it
    /// has that type, is an untyped constant an integer type adopts, or is
    /// `nil` for a type that has it.
    mutating func requireCase(
        _ caseExpression: GoExpression, of switchType: GoType, switched: GoExpression?
    ) throws {
        let caseType = try type(of: caseExpression)
        let nilAlone = comparesWithNilAlone(switchType)
        let matches = try nilAlone
            ? caseType == .nilType
            : caseType == switchType
                || (adoptsConstants(switchType)
                    && isAssignable(caseExpression, ofType: caseType, to: switchType))
                || (caseType == .nilType && isAssignable(.nilType, to: switchType))
        guard matches else {
            // Go adds why to a case a slice, a map, or a function cannot
            // be compared with.
            let note = nilAlone
                ? " (" + incomparableMessage(switchType).dropFirst("invalid operation: ".count)
                    + ")" : ""
            throw invalidCase(
                caseExpression, caseType, switched: switched, switchType,
                fallback: "invalid case \(caseType) in switch on \(switchType)" + note)
        }
    }

    /// A `switch` or a `select` has one `default`: Go reports a second one
    /// with the place of the first.
    func requireOneDefault(
        at position: GoSourcePosition, after first: GoSourcePosition?
    ) throws {
        guard let first else { return }
        throw GoDiagnostic(
            position: position,
            message: "multiple defaults (first at \(GoBranchChecker.place(first)))")
    }

    /// Whether the statement `expression` is a label or a jump the tree has
    /// no case for. Whether it is in place was checked on the tree the
    /// parser made; see `GoBranchChecker`. `x.(type)` as a statement is
    /// refused here as Go refuses it anywhere outside a switch.
    func isLabelOrJump(_ expression: GoExpression) throws -> Bool {
        if expression.isTypeSwitchGuard {
            throw GoDiagnostic(
                position: expression.startPosition, message: GoTypeSwitch.misplacedGuardMessage)
        }
        return expression.branch != nil
    }

    /// The type of the first variable of a `range` over anything but a map
    /// or a channel: an `int`, or, over an integer, the type of the integer.
    func integerRangeType(_ collectionType: GoType) -> GoType {
        isInteger(collectionType) ? collectionType : .int
    }

    /// What Go says of a `range` with a second variable where it has one
    /// value to give: over a channel, and over an integer.
    mutating func tooManyRangeVariables(
        over collection: GoExpression, ofType type: GoType, at position: GoSourcePosition
    ) -> GoDiagnostic {
        GoDiagnostic(
            position: namePositions[position.offset]?.last ?? position,
            message: "range over \(describe(collection, ofType: type)) permits only one "
                + "iteration variable")
    }

    /// `switch v := x.(type) { case T: ... }`. The operand is a value of an
    /// interface type; each clause lists types, of which none comes twice
    /// and each is one a value of that interface can have. A clause is a
    /// scope: the name the switch binds has the type of the clause when it
    /// lists one, and the type of the operand when it lists several, `nil`,
    /// or is the `default`.
    private mutating func checkTypeSwitchStatement(_ statement: GoStatement) throws {
        guard let typeSwitch = statement.typeSwitch else { return }
        let operandType = try type(of: typeSwitch.operand)
        guard case .interface(let methods) = underlying(operandType) else {
            throw GoDiagnostic(
                position: Self.start(of: typeSwitch.operand, in: namePositions),
                message: "\(describe(typeSwitch.operand, ofType: operandType)) is not an interface")
        }
        var firstDefault: GoSourcePosition?
        var seen: [GoType?] = []
        var places: [GoSourcePosition] = []
        var isBindingUsed = false
        breakableDepth += 1
        defer { breakableDepth -= 1 }
        for clause in typeSwitch.cases {
            if clause.isDefault {
                try requireOneDefault(at: clause.position, after: firstDefault)
                firstDefault = clause.position
            }
            let types = try caseTypes(
                of: clause, inSwitchOn: typeSwitch.operand, ofType: operandType, methods: methods,
                seen: &seen, places: &places)
            scopes.append([:])
            defer { scopes.removeLast() }
            if let binding = typeSwitch.binding {
                let single = types.count == 1 ? types[0] : nil
                scopes[scopes.count - 1][binding.name] = Binding(
                    type: single ?? operandType, isConstant: false)
            }
            try checkBlock(clause.body, createsScope: false)
            if let binding = typeSwitch.binding,
                scopes[scopes.count - 1][binding.name]?.isUsed == true
            {
                isBindingUsed = true
            }
            endScope()
        }
        if let binding = typeSwitch.binding, !isBindingUsed {
            // The name is one variable to Go, however many clauses declare
            // it: unused when none of them reads it.
            unused.append((binding.position, GoTypeSwitch.bindingPrefix + binding.name))
        }
    }

    /// The types a clause of a type switch lists, nil for `nil`. `seen`
    /// holds those of the clauses before it: a type comes once, and is one
    /// a value of an interface with `methods` can have.
    mutating func caseTypes(
        of clause: GoSwitchCase, inSwitchOn operand: GoExpression, ofType operandType: GoType,
        methods: [GoInterfaceMethod], seen: inout [GoType?], places: inout [GoSourcePosition]
    ) throws -> [GoType?] {
        var types: [GoType?] = []
        for case .typeExpression(let syntax, let position) in clause.expressions {
            let caseType = syntax.isNilCase ? nil : canonical(try declaredType(syntax))
            if let caseType, isImpossibleDynamicType(caseType, ofInterface: methods) {
                throw impossibleCase(
                    syntax.spelling, caseType, of: operand, ofType: operandType, at: position)
            }
            if let earlier = seen.firstIndex(of: caseType) {
                throw GoDiagnostic(
                    position: position,
                    message: "duplicate case \(syntax.spelling) in type switch\n\t"
                        + GoDiagnostic.place(places[earlier]) + ": previous case")
            }
            seen.append(caseType)
            places.append(position)
            types.append(caseType)
        }
        return types
    }

    /// `type` with the methods of an interface in one order, so that two
    /// interface types with the same methods are equal.
    func canonical(_ type: GoType) -> GoType {
        guard case .interface(let methods) = type else { return type }
        return .interface(methods.sorted { $0.name < $1.name })
    }

    /// Whether no value of an interface with `methods` can hold a value of
    /// `type`: a type that is no interface and lacks one of the methods.
    /// Of a type of the run-time library the methods are not known here.
    func isImpossibleDynamicType(_ type: GoType, ofInterface methods: [GoInterfaceMethod]) -> Bool {
        if methods.isEmpty { return false }
        if case .interface = underlying(type) { return false }
        var base = type
        if case .pointer(let pointee) = type { base = pointee }
        if case .named(let name) = base, typeDefinitions[name] == nil,
            GoPredeclared.underlying(of: name) == nil
        {
            return false
        }
        return !satisfies(type, interface: methods)
    }

    private mutating func checkSelectStatement(_ statement: GoStatement) throws {
        guard case .selectStatement(let cases, let position) = statement else {
            return
        }
        guard !cases.isEmpty else {
            // `select {}` is valid and blocks forever.
            return
        }
        var firstDefault: GoSourcePosition?
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
                try requireOneDefault(at: selectCase.position, after: firstDefault)
                firstDefault = selectCase.position
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
        case .typeExpression:
            throw GoDiagnostic(
                position: Self.start(of: expression, in: namePositions),
                message: "\(spelling(of: expression)) (type) is not an expression")
        case .typeAssertion(let base, let assertedType, _):
            return try typeOfAssertion(base, to: assertedType)
        case .functionLiteral(
            let parameters, let resultNames, let resultTypes, let body, let position):
            return try functionLiteralType(
                parameters: parameters, resultNames: resultNames, resultTypes: resultTypes,
                body: body, position: position)
        case .call(let callee, let arguments, let position):
            // Typed in functions of their own. This one calls itself for
            // every operand, so its frame is what each level of a nested
            // expression costs, and the cases of a call are most of it.
            try requireSingleResult(of: expression)
            return try callType(
                of: expression, callee: callee, arguments: arguments, position: position)
        case .unary: return try typeOfUnary(expression)
        case .binary: return try numericBinaryType(expression) ?? typeOfBinary(expression)
        }
    }

    mutating func typeOfIdentifier(_ expression: GoExpression) throws -> GoType {
        guard case .identifier(let name, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        if name == "true" || name == "false" { return .bool }
        if name == "nil" { return .nilType }
        if let literal = try literalType(expression) { return literal }
        guard let binding = lookup(name) else {
            // A function of the program is a value of its type.
            if let signature = functionSignatures[name] {
                return .function(parameters: signature.parameters, results: signature.results)
            }
            let isPackage = importedPaths.contains {
                GoImportName.defaultName(ofPath: $0) == name
            }
            throw GoDiagnostic(
                position: position,
                message: isPackage
                    ? GoImportName.misuse(ofPackage: name) : Self.undeclaredMessage(name))
        }
        use(name)
        noteConstantUse(expression, binding)
        return binding.type
    }

    mutating func typeOfSelector(_ expression: GoExpression) throws -> GoType {
        guard case .selector(let base, let name, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        if let constant = try libraryConstantType(expression) { return constant }
        if case .identifier(let packageName, _) = base,
            importedPaths.contains(packageName),
            GoStandardLibrary.integerConstant(package: packageName, member: name) != nil
        {
            return GoLibraryTypes.constantType(package: packageName, member: name)
        }
        if let typeName = libraryTypeName(base: base, member: name) {
            // Go reports a type where a value is wanted at its first name.
            throw GoDiagnostic(
                position: base.position, message: "\(typeName) (type) is not an expression")
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
            // Called, they are typed where calls are; this is the name
            // alone, where a value is wanted.
            return libraryFunctionType(packageName, name) ?? .void
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
            // A function of the package is a value of its type.
            if let function = libraryFunctionType(packageName, name) { return function }
            // Nothing above knows the member of the package.
            throw GoDiagnostic(
                position: position,
                message: libraryFunctionValueMessage(packageName, name)
                    ?? "undefined: \(packageName).\(name)")
        }
        if let method = try methodExpressionType(base: base, name: name, position: position) {
            return method
        }
        let baseType = try type(of: base)
        try requireVisible(name, of: base, in: baseType, at: position)
        if let lent = try promotedType(base: base, baseType: baseType, name: name, at: position) {
            return lent
        }
        guard let field = structFields(of: baseType)?.first(where: { $0.name == name }) else {
            // A method selected and not called is a function that has
            // its receiver.
            if let method = methodSignature(of: baseType, named: name) {
                return .function(parameters: method.parameters, results: method.results)
            }
            // And so is a method of an interface value, whatever is in it.
            if case .interface(let methods) = underlying(baseType),
                let method = methods.first(where: { $0.name == name })
            {
                return .function(parameters: method.parameters, results: method.results)
            }
            // And a method of a type of the run-time library.
            if let method = libraryMethodType(of: baseType, named: name) { return method }
            throw undefinedSelection(name, of: base, ofType: baseType, at: position)
        }
        return field.type
    }

    mutating func typeOfCompositeLiteral(_ expression: GoExpression) throws -> GoType {
        guard case .compositeLiteral(let typeExpression, let elements, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        try requireLiteralType(typeExpression, at: position)
        let literalType = try declaredType(typeExpression)
        switch underlying(literalType) {
        case .structure(let fields):
            try checkStructLiteral(elements, fields: fields, type: literalType, position: position)
        case .array(let length, let elementType):
            try checkListLiteral(elements, element: elementType, length: length)
        case .slice(let elementType):
            try checkListLiteral(elements, element: elementType, length: nil)
        case .map(let keyType, let valueType):
            try checkMapLiteral(elements, key: keyType, value: valueType)
        default:
            // A literal that left its type out stands where its type does not.
            let isElement = typeExpression.position.offset != position.offset
            throw GoDiagnostic(
                position: position,
                message: "invalid composite literal \(isElement ? "element " : "")type \(literalType)")
        }
        return literalType
    }

    mutating func typeOfIndex(_ expression: GoExpression) throws -> GoType {
        guard case .index(let base, let index, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        let baseType = try indexedType(of: base)
        switch baseType {
        case .array(_, let element), .slice(let element):
            guard isInteger(try type(of: index)) else {
                throw nonIntegerIndex(index)
            }
            return element
        case .string:
            guard isInteger(try type(of: index)) else {
                throw nonIntegerIndex(index)
            }
            return GoPredeclared.byte
        case .map(let keyType, let valueType):
            try requireUse(index, as: keyType, in: "map index")
            return valueType
        default:
            throw unindexable(base, at: position)
        }
    }

    mutating func typeOfSlicing(_ expression: GoExpression) throws -> GoType {
        guard case .slicing(let base, let low, let high, _) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        for bound in [low, high].compactMap({ $0 }) where !isInteger(try type(of: bound)) {
            throw nonIntegerIndex(bound)
        }
        switch try indexedType(of: base) {
        case .array(_, let element), .slice(let element): return .slice(element)
        case .string: return .string
        default:
            throw try invalidOperand("cannot slice", base, ofType: type(of: base))
        }
    }

    mutating func typeOfUnary(_ expression: GoExpression) throws -> GoType {
        guard case .unary(let unaryOperator, let operand, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        switch unaryOperator {
        case .plus, .minus:
            let operandType = try type(of: operand)
            if let numeric = try checkedNumericUnaryType(expression, operandType: operandType) {
                return numeric
            }
            guard isInteger(operandType) else {
                throw undefinedOperator(
                    GoSourceSpelling.text(of: unaryOperator), on: operand, ofType: operandType)
            }
            return operandType
        case .not:
            let operandType = try type(of: operand)
            guard isBool(operandType) else {
                throw undefinedOperator("!", on: operand, ofType: operandType)
            }
            return operandType
        case .address:
            // A composite literal is the one operand that is not a
            // variable: `&T{...}` makes one.
            if case .compositeLiteral = operand { return .pointer(try type(of: operand)) }
            guard isAddressable(operand) else { throw unaddressable(operand) }
            return .pointer(try addressedType(of: operand))
        case .dereference:
            let operandType = try type(of: operand)
            guard let pointee = operandType.pointee(in: typeDefinitions) else {
                throw invalidOperand("cannot indirect", operand, ofType: operandType)
            }
            try rejectOpaqueFile(pointee, at: position)
            return pointee
        case .receive:
            let operandType = try type(of: operand)
            guard case .channel(let direction, let elementType) = underlying(operandType) else {
                throw invalidOperand("cannot receive from non-channel", operand, ofType: operandType)
            }
            guard direction != .sendOnly else {
                throw invalidOperand(
                    "cannot receive from send-only channel", operand, ofType: operandType)
            }
            return elementType
        }
    }

    mutating func typeOfBinary(_ expression: GoExpression) throws -> GoType {
        guard case .binary(let left, let binaryOperator, let right, _) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        var (leftType, rightType) = try operandTypes(left, right)
        if leftType != rightType,
            let common = try commonOperandType(
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
                        || isFunction(leftType) || isFunction(rightType)
                        || isInterface(leftType) || isInterface(rightType)))
        else {
            throw binaryFailure(expression, "mismatched types \(leftType) and \(rightType)")
        }
        switch binaryOperator {
        case .add:
            guard isInteger(leftType) || isString(leftType) else {
                throw binaryFailure(expression, "operator + not defined on \(leftType)")
            }
            return leftType
        case .subtract, .multiply:
            guard isInteger(leftType) else {
                throw binaryFailure(expression, "operator requires integer operands")
            }
            return leftType
        case .divide, .remainder:
            guard isInteger(leftType) else {
                throw binaryFailure(expression, "operator requires integer operands")
            }
            if case .integer(0, let zeroPosition) = right {
                throw GoDiagnostic(
                    position: zeroPosition, message: "invalid operation: division by zero")
            }
            return leftType
        case .equal, .notEqual:
            if (leftType == .nilType || rightType == .nilType)
                && (isPointer(leftType) || isPointer(rightType)
                    || isSlice(leftType) || isSlice(rightType)
                    || isMap(leftType) || isMap(rightType)
                    || isChannel(leftType) || isChannel(rightType)
                    || isFunction(leftType) || isFunction(rightType)
                    || isInterface(leftType) || isInterface(rightType))
            {
                return .bool
            }
            guard isComparable(leftType) else {
                throw binaryFailure(expression, incomparableMessage(leftType))
            }
            return .bool
        case .less, .lessEqual, .greater, .greaterEqual:
            guard isInteger(leftType) || isString(leftType) else {
                throw binaryFailure(expression, "operator is not defined on \(leftType)")
            }
            return .bool
        case .logicalAnd, .logicalOr:
            guard isBool(leftType) else {
                throw binaryFailure(expression, "operator requires boolean operands")
            }
            return leftType
        }
    }

    /// The type of the call `expression`.
    mutating func callType(
        of expression: GoExpression, callee: GoExpression, arguments: [GoExpression],
        position: GoSourcePosition
    ) throws -> GoType {
        if try forwardsResults(arguments, to: callee) {
            return try forwardedCallType(callee: callee, arguments: arguments)
        }
        if case .functionLiteral = callee,
            case .function(let parameters, let results) = try type(of: callee)
        {
            try checkArguments(arguments, of: callee, declared: parameters, position: position)
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
            guard arguments.count == 1 else {
                throw conversionCountMismatch(
                    to: target, callee: callee, arguments: arguments, position: position)
            }
            return try conversionResultType(target, arguments: arguments, position: position)
        }
        if let native = try nativeCall(
            callee: callee, arguments: arguments, position: position)
        {
            guard native.results.count <= 1 else {
                throw severalValues(expression, results: native.results)
            }
            guard let result = native.results.first else { return .void }
            return result
        }
        if let builtin = try predeclaredCallType(callee: callee, arguments: arguments) {
            return builtin
        }
        if case .identifier(let name, let namePosition) = callee {
            return try namedCallType(
                name: name, namePosition: namePosition, arguments: arguments, position: position)
        }
        if let results = try methodExpressionResults(callee, arguments: arguments, position: position) {
            return results.first ?? .void
        }
        guard case .selector(let base, let name, _) = callee else {
            // What an index, a call, or a literal gives may be a function.
            let calleeType = try type(of: callee)
            guard let results = try resultsOfCall(
                through: calleeType, callee: callee, arguments: arguments, position: position)
            else {
                throw invalidOperand("cannot call non-function", callee, ofType: calleeType)
            }
            return results.first ?? .void
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
            try requireArgumentCount(1, of: name, arguments: arguments, position: namePosition)
            let argumentType = try indexedType(of: arguments[0])
            if name == "len" {
                guard argumentType == .string || isArrayOrSlice(argumentType)
                    || isMap(argumentType) || isChannel(argumentType)
                else {
                    throw invalidArgument(arguments[0], "for built-in len")
                }
            } else {
                guard isArrayOrSlice(argumentType) || isChannel(argumentType) else {
                    throw invalidArgument(arguments[0], "for built-in cap")
                }
            }
            return .int
        }
        if name == "append" {
            try requireArgumentCount(
                1, of: name, arguments: arguments, position: namePosition, orMore: true)
            guard arguments.count >= 2 else {
                throw GoDiagnostic(position: position, message: "not enough arguments in call to append")
            }
            let sliceType = try type(of: arguments[0])
            guard case .slice(let elementType) = underlying(sliceType) else {
                throw GoDiagnostic(
                    position: Self.start(of: arguments[0], in: namePositions),
                    message: "first argument to append must be a slice; have "
                        + describe(arguments[0], ofType: sliceType))
            }
            if arguments.count == 2, let source = arguments[1].spreadOperand {
                let sourceType = try type(of: source)
                guard isElementSource(sourceType, of: elementType) else {
                    throw cannotUse(
                        source, ofType: sourceType, as: .slice(elementType),
                        in: "argument to append")
                }
                return sliceType
            }
            for argument in arguments.dropFirst() {
                try requireUse(argument, as: elementType, in: "argument to append")
            }
            return sliceType
        }
        if name == "make" {
            try requireArgumentCount(
                1, of: name, arguments: arguments, position: namePosition, orMore: true)
            guard case .typeExpression(let typeExpression, _) = arguments[0] else {
                throw GoDiagnostic(position: position, message: "invalid make call")
            }
            let madeType = try declaredType(typeExpression)
            switch underlying(madeType) {
            case .slice:
                try requireMakeArguments(2...3, arguments, at: namePosition)
            case .map, .channel:
                try requireMakeArguments(1...2, arguments, at: namePosition)
            default:
                throw GoDiagnostic(
                    position: arguments[0].position,
                    message: "invalid argument: cannot make \(typeExpression.sourceSpelling); "
                        + "type must be slice, map, or channel")
            }
            for argument in arguments.dropFirst() where !isInteger(try type(of: argument)) {
                throw nonIntegerIndex(argument)
            }
            return madeType
        }
        if name == "panic" {
            try requireArgumentCount(1, of: name, arguments: arguments, position: namePosition)
            _ = try type(of: arguments[0])
            return .void
        }
        if name == "recover" {
            try requireArgumentCount(0, of: name, arguments: arguments, position: namePosition)
            return .interface([])
        }
        if name == "delete" {
            try requireArgumentCount(2, of: name, arguments: arguments, position: namePosition)
            let mapType = try type(of: arguments[0])
            guard case .map(let keyType, _) = underlying(mapType) else {
                throw invalidArgument(arguments[0], "is not a map")
            }
            try requireUse(arguments[1], as: keyType, in: "argument to delete")
            return .void
        }
        if name == "copy" {
            try requireArgumentCount(2, of: name, arguments: arguments, position: namePosition)
            let destinationType = try type(of: arguments[0])
            let sourceType = try type(of: arguments[1])
            guard case .slice(let element) = underlying(destinationType),
                isElementSource(sourceType, of: element)
            else {
                throw uncopyable(arguments[0], destinationType, arguments[1], sourceType)
            }
            return .int
        }
        if name == "close" {
            try requireArgumentCount(1, of: name, arguments: arguments, position: namePosition)
            let closedType = try type(of: arguments[0])
            guard case .channel(let direction, _) = underlying(closedType) else {
                throw invalidOperand("cannot close non-channel", arguments[0], ofType: closedType)
            }
            guard direction != .receiveOnly else {
                throw invalidOperand(
                    "cannot close receive-only channel", arguments[0], ofType: closedType)
            }
            return .void
        }
        if let binding = lookup(name),
            let results = try resultsOfCall(
                through: binding.type, callee: .identifier(name, position: namePosition),
                arguments: arguments, position: position)
        {
            return results.first ?? .void
        }
        guard let signature = functionSignatures[name] else {
            throw GoDiagnostic(
                position: namePosition, message: uncallableMessage(name) ?? "undefined: \(name)")
        }
        try checkArguments(
            arguments, of: .identifier(name, position: namePosition),
            declared: signature.parameters, position: position)
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
            try checkAnyOperands(arguments[...], of: callee)
            return .void
        }
        if case .identifier("os", _) = base,
            importedPaths.contains("os"),
            name == "Exit"
        {
            try checkArguments(arguments, of: callee, declared: [.int], position: position)
            return .void
        }
        if case .identifier("strconv", _) = base,
            importedPaths.contains("strconv"),
            name == "Atoi"
        {
            try checkArguments(arguments, of: callee, declared: [.string], position: position)
            return .int
        }
        if case .identifier("userland", _) = base,
            importedPaths.contains("swiftix/userland"),
            name == "ReadInput"
        {
            try checkArguments(
                arguments, of: callee, declared: [.string, .slice(.string)],
                position: position)
            return .string
        }
        if case .identifier("userland", _) = base,
            importedPaths.contains("swiftix/userland"),
            let results = try userlandTerminalResults(
                name, callee: callee, arguments: arguments, position: position)
        {
            return results.first ?? .void
        }
        if case .identifier("strings", _) = base,
            importedPaths.contains("strings")
        {
            return try stringsCallResult(
                name, callee: callee, arguments: arguments, position: position)
        }
        if case .identifier(let packageName, _) = base,
            packageName == "time",
            importedPaths.contains("time"),
            name == "After"
        {
            try checkArguments(
                arguments, of: callee, declared: [GoLibraryTypes.duration],
                position: position)
            return .channel(direction: .receiveOnly, element: GoPredeclared.time)
        }
        if case .identifier(let packageName, _) = base,
            packageName == "time",
            importedPaths.contains("time"),
            name == "Sleep"
        {
            try checkArguments(
                arguments, of: callee, declared: [GoLibraryTypes.duration],
                position: position)
            return .void
        }
        if case .identifier(let packageName, _) = base,
            packageName == "time",
            importedPaths.contains("time"),
            name == "Tick"
        {
            try checkArguments(
                arguments, of: callee, declared: [GoLibraryTypes.duration],
                position: position)
            return .channel(direction: .receiveOnly, element: GoPredeclared.time)
        }
        if case .identifier(let packageName, _) = base,
            packageName == "net",
            importedPaths.contains("net")
        {
            switch name {
            case "Dial":
                try checkArguments(
                    arguments, of: callee, declared: [.string, .string],
                    position: position)
                return .named("net.Conn")
            case "Listen":
                try checkArguments(
                    arguments, of: callee, declared: [.string, .string],
                    position: position)
                return .named("net.Listener")
            case "LookupHost":
                try checkArguments(arguments, of: callee, declared: [.string], position: position)
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
                try checkArguments(
                    arguments, of: callee, declared: [.string, .function(parameters: [.named("http.ResponseWriter"), .pointer(.named("http.Request"))], results: [])],
                    position: position)
                return .void
            case "ListenAndServe":
                guard arguments.count == 2 else {
                    throw try argumentCountMismatch(
                        arguments, of: callee, declared: [.string, .named("http.Handler")],
                        position: position)
                }
                try requireArgument(arguments[0], as: .string, of: callee)
                return GoPredeclared.errorType
            case "Get":
                try checkArguments(arguments, of: callee, declared: [.string], position: position)
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
            try checkArguments(arguments, of: callee, declared: [], position: position)
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
                try checkArguments(arguments, of: callee, declared: [], position: position)
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
                    try checkArguments(arguments, of: callee, declared: [.int], position: position)
                    return .void
                case "Done", "Wait":
                    try checkArguments(arguments, of: callee, declared: [], position: position)
                    return .void
                default:
                    break
                }
            }
            if syncReceiverName == "net.Conn" {
                switch name {
                case "Read", "Write":
                    guard arguments.count == 1 else {
                        throw try argumentCountMismatch(
                            arguments, of: callee, declared: [.slice(GoPredeclared.byte)],
                            position: position)
                    }
                    // A `[]int` is taken as it always was here; what is
                    // neither is refused as Go refuses it.
                    let buffer = try type(of: arguments[0])
                    if buffer != .slice(GoPredeclared.byte), buffer != .slice(.int) {
                        try requireArgument(
                            arguments[0], as: .slice(GoPredeclared.byte), of: callee)
                    }
                    return .int
                case "Close":
                    try checkArguments(arguments, of: callee, declared: [], position: position)
                    return GoPredeclared.errorType
                default:
                    break
                }
            }
            if syncReceiverName == "net.Listener" {
                switch name {
                case "Accept":
                    try checkArguments(arguments, of: callee, declared: [], position: position)
                    return .named("net.Conn")
                case "Close":
                    try checkArguments(arguments, of: callee, declared: [], position: position)
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
            try checkArguments(
                arguments, of: callee, declared: funcExport.parameters, position: position)
            return funcExport.results.first ?? .void
        }
        if let packageName = importedPackage(named: base) {
            // Name the missing member instead of reporting the package
            // itself as undefined.
            throw GoDiagnostic(
                position: callee.position, message: "undefined: \(packageName).\(name)")
        }
        let baseType = try type(of: base)
        try requireVisible(name, of: base, in: baseType, at: callee.position)
        if let lent = try promotedCallResults(
            callee, baseType: baseType, arguments: arguments, position: position, single: true)
        {
            return lent.first ?? .void
        }
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
                try checkArguments(
                    arguments, of: callee, declared: method.parameters, position: position)
                return method.results.first ?? .void
            }
            // A field that holds a function is called like a method.
            if let field = structFields(of: baseType)?.first(where: { $0.name == name }),
                let results = try resultsOfCall(
                    through: field.type, callee: callee, arguments: arguments, position: position)
            {
                return results.first ?? .void
            }
            if let field = structFields(of: baseType)?.first(where: { $0.name == name }) {
                throw invalidOperand("cannot call non-function", callee, ofType: field.type)
            }
            throw undefinedSelection(name, of: base, ofType: baseType, at: callee.position)
        }
        if match.first == "*", case .named = baseType, !isAddressable(base) {
            throw GoDiagnostic(
                position: callee.position,
                message: "cannot call pointer method \(name) on \(baseType)")
        }
        try checkArguments(
            arguments, of: callee, declared: signature.parameters, position: position)
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
            guard let binding = lookup(name) else { throw unassignableName(name, at: position) }
            guard !binding.isConstant else { throw unassignable(expression) }
            if asTarget {
                // Assigned and not read, which a literal does to a variable
                // around it through the same pointer.
                if let index = scopes.indices.dropFirst().last(where: { scopes[$0][name] != nil }) {
                    capture(name, declaredIn: index)
                }
            } else {
                use(name)
            }
            return binding.type
        case .selector(let base, let name, let position):
            let baseType = try assignableType(of: base)
            try requireVisible(name, of: base, in: baseType, at: position)
            if let lent = try promotedType(
                base: base, baseType: baseType, name: name, at: position, assignable: true)
            {
                return lent
            }
            guard let field = structFields(of: baseType)?.first(where: { $0.name == name }) else {
                if methodSignature(of: baseType, named: name) != nil { throw unassignable(expression) }
                throw undefinedSelection(name, of: base, ofType: baseType, at: position)
            }
            return field.type
        case .unary(.dereference, let operand, let position):
            let operandType = try type(of: operand)
            guard let pointee = operandType.pointee(in: typeDefinitions) else {
                throw GoDiagnostic(position: position, message: "cannot indirect \(operandType)")
            }
            try rejectOpaqueFile(pointee, at: position)
            return pointee
        case .index(let base, let index, let position):
            let baseType = try type(of: base)
            switch underlying(baseType) {
            case .array(_, let element):
                guard isInteger(try type(of: index)) else {
                    throw nonIntegerIndex(index)
                }
                _ = try assignableType(of: base)
                return element
            case .slice(let element):
                guard isInteger(try type(of: index)) else {
                    throw nonIntegerIndex(index)
                }
                return element
            case .pointer where throughArrayPointer(baseType) != baseType:
                return try elementType(behind: baseType, index: index)
            case .map(let keyType, let valueType):
                try requireUse(index, as: keyType, in: "map index")
                return valueType
            default:
                _ = position
                throw unassignable(expression)
            }
        default:
            throw unassignable(expression)
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
            _ = position
            throw severalValues(expression, results: signature.results)
        } else if case .selector(let base, _, _) = callee,
            !(base == .identifier("fmt", position: base.position) && importedPaths.contains("fmt"))
        {
            let results = (try? callResultTypes(
                callee: callee, arguments: arguments, position: callPosition)) ?? []
            if results.count > 1 { throw severalValues(expression, results: results) }
        }
    }

    /// Requires `expression` to have a value: not a call without a result
    /// or with several, and not an untyped `nil`, which has no type to give
    /// a variable.
    mutating func requireValue(
        _ expression: GoExpression, in context: String = "assignment"
    ) throws {
        try requireSingleValue(expression, at: expression.position)
        let valueType = try type(of: expression)
        guard valueType != .void else { throw noValue(expression) }
        guard valueType != .nilType else {
            throw GoDiagnostic(
                position: expression.position, message: "use of untyped nil in \(context)")
        }
    }

    // MARK: Calls of several results

    /// Refuses the call `expression` where one value is wanted (an operand,
    /// an element, an index, a condition, one value of a list) when it has
    /// several results. Go does; to take the first would drop the others
    /// without a word.
    ///
    /// This returns before the call is typed, so a call inside a call costs
    /// the stack no frame for it.
    mutating func requireSingleResult(of expression: GoExpression) throws {
        guard case .call(let callee, let arguments, let position) = expression,
            let results = severalResults(of: expression)
        else { return }
        // What is wrong with the call itself comes first, and a call that
        // gives nothing is reported by what wanted its value.
        guard
            try callType(of: expression, callee: callee, arguments: arguments, position: position)
                != .void
        else { return }
        throw severalValues(expression, results: results)
    }

    /// `return f()` in a function of one result, where `f` has several: Go
    /// counts the values, as it does for a list of them.
    mutating func rejectSeveralReturnValues(_ value: GoExpression) throws {
        guard case .call(let callee, let arguments, let position) = value,
            severalResults(of: value) != nil
        else { return }
        // What is wrong with the call itself comes first.
        let results = try callResultTypes(callee: callee, arguments: arguments, position: position)
        throw returnCountMismatch(of: value, results: results)
    }

    /// The results of the call `expression` when it has several.
    mutating func severalResults(of expression: GoExpression) -> [GoType]? {
        guard case .call(let callee, _, _) = expression, let results = calleeResults(callee),
            results.count > 1
        else { return nil }
        return results
    }

    /// The results of a call of `callee`, told from the callee alone, or nil
    /// where it is nothing that says them: a builtin, a conversion, and most
    /// of the library, which give one value or none. The arguments are not
    /// looked at, so asking costs no second check of them.
    mutating func calleeResults(_ callee: GoExpression) -> [GoType]? {
        switch callee {
        case .identifier(let name, _):
            if let binding = lookup(name) { return functionResults(binding.type) }
            return functionSignatures[name]?.results
        case .selector(let base, let name, _):
            return selectedResults(base: base, name: name, callee: callee)
        case .functionLiteral(_, _, let resultTypes, _, _):
            return try? resultTypes.map { try declaredType($0) }
        default:
            // What an index, a call, or an assertion gives may be a function.
            return calledType(callee).flatMap { functionResults($0) }
        }
    }

    /// The results of `base.name(...)`, in the order `callType` looks: a
    /// function of a package, a method expression, then a method or a field
    /// of the value `base` is.
    mutating func selectedResults(
        base: GoExpression, name: String, callee: GoExpression
    ) -> [GoType]? {
        if case .identifier(let packageName, _) = base, lookup(packageName) == nil {
            if importedPaths.contains(packageName),
                let native = GoStandardLibrary.nativeFunction(package: packageName, member: name)
            {
                return native.results
            }
            if importedPackage(named: base) != nil,
                let function = GoStandardLibrary.resolve(package: packageName, member: name)
            {
                return function.severalResults
            }
            if let function = resolvePackageExport(packageName)?.functions[name] {
                return function.results
            }
        }
        if let method = try? methodExpressionType(base: base, name: name, position: callee.position) {
            return functionResults(method)
        }
        guard let baseType = calledType(base) else { return nil }
        if let native = GoStandardLibrary.method(of: baseType, named: name) {
            return native.results
        }
        switch (baseType, name) {
        case (.named("net.Conn"), "Read"), (.named("net.Conn"), "Write"):
            return [.int, GoPredeclared.errorType]
        case (.named("net.Listener"), "Accept"):
            return [.named("net.Conn"), GoPredeclared.errorType]
        default:
            break
        }
        if let signature = methodSignature(of: baseType, named: name) { return signature.results }
        if case .interface(let methods) = underlying(baseType),
            let method = methods.first(where: { $0.name == name })
        {
            return method.results
        }
        return structFields(of: baseType)?.first { $0.name == name }
            .flatMap { functionResults($0.type) }
    }

    func functionResults(_ type: GoType) -> [GoType]? {
        guard case .function(_, let results) = underlying(type) else { return nil }
        return results
    }

    /// The type of `expression` where a call selects from it or calls it.
    /// When it is a call itself, of something that says its results, the
    /// first of them is its type: the call was checked where it stands, and
    /// to check it once more for each link of `a.b(x).c(y).d(z)` would cost
    /// twice as much with every link.
    mutating func calledType(_ expression: GoExpression) -> GoType? {
        if case .call(let callee, _, _) = expression, let results = calleeResults(callee) {
            return results.first
        }
        return try? type(of: expression)
    }

    /// Whether a call of `callee` with `arguments` passes on the results of
    /// its only argument: a call of several results, which Go passes in
    /// order. `f(g()...)` is neither that nor a slice to spread.
    mutating func forwardsResults(
        _ arguments: [GoExpression], to callee: GoExpression
    ) throws -> Bool {
        guard arguments.count == 1 else { return false }
        if let operand = arguments[0].spreadOperand, case .call = operand,
            let results = severalResults(of: operand)
        {
            throw GoDiagnostic(
                position: callee.start,
                message: "cannot use ... with \(results.count)-valued \(spelling(of: operand))")
        }
        return try GoForwardedResults.call(in: arguments, of: callee) != nil
            && severalResults(of: arguments[0]) != nil && conversionTarget(callee) == nil
    }

    /// The arguments of a call that passes on the results of its only
    /// argument, `arguments[0]`. The inner call is checked here, once, and
    /// each result is a name in a scope this pushes, which the caller pops
    /// when it has checked the call.
    ///
    /// `position` is where Go reports results that do not fit in number: at
    /// the inner call, or at the builtin that was given them.
    mutating func forwardedArguments(
        _ arguments: [GoExpression], to callee: GoExpression
    ) throws -> (arguments: [GoExpression], position: GoSourcePosition) {
        guard let inner = GoForwardedResults.call(in: arguments, of: callee) else {
            // No such call: the arguments as they are, in a scope to pop.
            scopes.append([:])
            return (arguments, callee.position)
        }
        let operands = pushForwarded(
            try callResultTypes(
                callee: inner.callee, arguments: inner.arguments, position: inner.position),
            at: arguments[0].start)
        noteForwardedCall(arguments[0])
        if case .identifier(let name, let namePosition) = callee, lookup(name) == nil,
            functionSignatures[name] == nil
        {
            return (operands, namePosition)
        }
        return (operands, arguments[0].start)
    }

    /// Pushes a scope that names each of `results`, and returns the names
    /// as operands at `position`. They are variables, not constants: a
    /// result has the type its function gave it.
    mutating func pushForwarded(
        _ results: [GoType], at position: GoSourcePosition
    ) -> [GoExpression] {
        var scope: [String: Binding] = [:]
        var operands: [GoExpression] = []
        for (index, result) in results.enumerated() {
            let name = GoForwardedResults.name(index)
            scope[name] = Binding(type: result, isConstant: false)
            operands.append(.identifier(name, position: position))
        }
        scopes.append(scope)
        return operands
    }

    /// `callType` of a call that passes on the results of its only argument.
    mutating func forwardedCallType(
        callee: GoExpression, arguments: [GoExpression]
    ) throws -> GoType {
        let forwarded = try forwardedArguments(arguments, to: callee)
        defer { scopes.removeLast() }
        return try callType(
            of: .call(callee: callee, arguments: forwarded.arguments, position: forwarded.position),
            callee: callee, arguments: forwarded.arguments, position: forwarded.position)
    }

    /// `callResultTypes` of such a call.
    mutating func forwardedCallResults(
        callee: GoExpression, arguments: [GoExpression]
    ) throws -> [GoType] {
        let forwarded = try forwardedArguments(arguments, to: callee)
        defer { scopes.removeLast() }
        return try callResultTypes(
            callee: callee, arguments: forwarded.arguments, position: forwarded.position)
    }

    /// A call that is a statement, or what a `go` or a `defer` starts: its
    /// results are dropped, however many there are.
    mutating func checkCallStatement(_ expression: GoExpression) throws {
        guard case .call(let callee, let arguments, let position) = expression else { return }
        if try forwardsResults(arguments, to: callee) {
            try checkForwardedCallStatement(callee: callee, arguments: arguments)
            return
        }
        // A native call may discard all of its results as a statement.
        if try nativeCall(callee: callee, arguments: arguments, position: position) != nil {
            return
        }
        _ = try callType(of: expression, callee: callee, arguments: arguments, position: position)
    }

    /// `checkCallStatement` of a call that passes on the results of its only
    /// argument.
    mutating func checkForwardedCallStatement(
        callee: GoExpression, arguments: [GoExpression]
    ) throws {
        let forwarded = try forwardedArguments(arguments, to: callee)
        defer { scopes.removeLast() }
        try checkCallStatement(
            .call(callee: callee, arguments: forwarded.arguments, position: forwarded.position))
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
        for (index, name) in names.enumerated() where name != GoValueList.blank {
            guard scopes[scopes.count - 1][name] == nil, seen.insert(name).inserted else {
                // Go reports a name declared twice where the name is.
                let places = namePositions[position.offset] ?? []
                let first = names.firstIndex(of: name) ?? index
                throw GoDiagnostic.redeclared(
                    name, at: index < places.count ? places[index] : position,
                    other: scopes[scopes.count - 1][name]?.position
                        ?? (first < index && first < places.count ? places[first] : nil))
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
                throw try countMismatch(variables: names.count, values: values)
            }
            try check(.multiDeclaration(names: names, expression: values[0], position: position))
            if let declared {
                for name in names where name != GoValueList.blank {
                    guard let found = scopes[scopes.count - 1][name]?.type, found == declared else {
                        throw cannotUseResult(
                            of: values[0], type: scopes[scopes.count - 1][name]?.type ?? .void,
                            as: declared, in: "assignment")
                    }
                }
            }
            return
        }
        guard values.count == names.count else {
            throw try arityMismatch(names, values: values, isConstant: false, position: position)
        }
        var types: [GoType] = []
        for value in values {
            try requireValueOrNil(value, declared: declared)
            let valueType = try self.type(of: value)
            if let declared {
                try requireUse(value, ofType: valueType, as: declared, in: "variable declaration")
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
        try requireValue(expression, in: "variable declaration")
    }

    /// `a, b := x, y`. A name the block already declares is assigned, as
    /// long as one name is new; every value is read before any is stored.
    mutating func checkParallelDeclaration(
        _ names: [String],
        values: [GoExpression],
        position: GoSourcePosition
    ) throws {
        guard names.count == values.count else {
            throw try countMismatch(variables: names.count, values: values)
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
                    // A `:=` that names a constant: Go says no more.
                    throw GoDiagnostic(position: position, message: "cannot assign to \(name)")
                }
                try requireUse(value, ofType: valueType, as: existing.type, in: "assignment")
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


    mutating func requireBool(_ expression: GoExpression, in statement: String) throws {
        let expressionType = try type(of: expression)
        guard isBool(expressionType) else {
            if expressionType == .void { throw noValue(expression) }
            throw GoDiagnostic(
                position: Self.start(of: expression, in: namePositions),
                message: "non-boolean condition in \(statement)")
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
                "net.Conn", "net.Listener",
                "http.Response", "http.ResponseWriter", "http.Request",
                "time.Time", "os.File":
                return .named(name)
            case GoLibraryTypes.durationName: return GoLibraryTypes.duration
            default:
                if let numeric = GoPredeclared.numericType(name) { return numeric }
                guard availableTypes.contains(name) else {
                    if name.hasPrefix(GoTypeSwitch.guardName) {
                        throw GoDiagnostic(
                            position: position, message: GoTypeSwitch.misplacedGuardMessage)
                    }
                    throw GoPredeclared.unsupportedNumericTypes.contains(name)
                        ? GoDiagnostic(
                            position: position, message: GoPredeclared.unsupportedTypeMessage(name))
                        : GoDiagnostic.undefinedType(name, at: position)
                }
                return .named(name)
            }
        case .structure(let fields, _):
            var names: Set<String> = []
            return .structure(
                try fields.map { field in
                    guard names.insert(field.name).inserted else {
                        throw GoDiagnostic.redeclared(
                            field.name, at: field.position,
                            other: fields.first { $0.name == field.name }?.position,
                            inBlock: false)
                    }
                    return GoStructFieldType(field, type: try declaredType(field.type))
                })
        case .pointer(let pointee, _):
            return .pointer(try declaredType(pointee))
        case .array(let length, let element, let position):
            try GoCompositeLiterals.requireLength(length, at: position)
            return .array(length: length, element: try declaredType(element))
        case .slice(let element, _):
            return .slice(try declaredType(element))
        case .map(let key, let value, _):
            let keyType = try declaredType(key)
            guard isComparable(keyType) else {
                throw GoDiagnostic(position: key.position, message: "invalid map key type \(keyType)")
            }
            return .map(key: keyType, value: try declaredType(value))
        case .channel(let direction, let element, _):
            return .channel(direction: direction, element: try declaredType(element))
        case .interface(let methods, _):
            if let signature = expression.functionSignature {
                return .function(
                    parameters: try signature.parameters.map(declaredType),
                    results: try signature.results.map(declaredType))
            }
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
            // A rune literal is carried as it is spelled.
            if let rune = GoLiteral.runeValue(name) { return rune }
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
            if let extreme = orderedConstantValue(expression) { return extreme }
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
        if let numeric = try numericAssignable(expression, ofType: actual, to: expected) {
            return numeric
        }
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
        // Not integers alone: a value of a type without a name goes with one
        // of a named type of the same structure, as it is assigned to one.
        if differOnlyInName(leftType, rightType) { return leftType }
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
        if let numeric = try numericBitwiseType(
            bitwiseOperator, operands: operands,
            of: .bitwise(bitwiseOperator, operands: operands, position: position),
            position: position)
        {
            return numeric
        }
        let leftType = try type(of: operands[0])
        if bitwiseOperator == .complement {
            guard isInteger(leftType) else {
                throw undefinedOperator("^", on: operands[0], ofType: leftType)
            }
            return leftType
        }
        let rightType = try type(of: operands[1])
        guard isInteger(leftType), isInteger(rightType) else {
            throw bitwiseMistake(bitwiseOperator, operands, leftType, rightType, at: position)
        }
        if bitwiseOperator.isShift {
            if let count = untypedConstantValue(operands[1]), count < 0 {
                throw bitwiseMistake(bitwiseOperator, operands, leftType, rightType, at: position)
            }
            return leftType
        }
        guard
            let common = try commonIntegerType(
                left: operands[0], leftType: leftType, right: operands[1], rightType: rightType)
        else {
            throw bitwiseMistake(bitwiseOperator, operands, leftType, rightType, at: position)
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
            case "int", "string", "bool", "byte", "uint8", "any", "error":
                break
            default:
                guard availableTypes.contains(name)
                    || GoPredeclared.unsupportedNumericTypes.contains(name)
                    || GoPredeclared.numericType(name) != nil
                else { return nil }
            }
            return try declaredType(.named(name, position: position))
        case .unary(.dereference, let operand, _):
            // `(*T)(x)`: the parentheses are gone, and `*T` is a type
            // where `T` is one.
            return try conversionTarget(operand).map { .pointer($0) }
        case .selector:
            return libraryConversionTarget(callee)
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
        if let numeric = try numericConversionType(target, argument: argument, at: position) {
            return numeric
        }
        let source = try type(of: argument)
        let sourceShape = underlying(source)
        switch underlying(target) {
        case .int:
            if let value = untypedConstantValue(argument) {
                try requireConstant(value, representableAs: target, at: argument.position)
                return target
            }
            guard sourceShape == .int else { throw cannotConvert(argument, ofType: source, to: target) }
            return target
        case .string:
            if sourceShape == .string || sourceShape == .int { return target }
            if case .slice(let element) = sourceShape, isByte(element) { return target }
            throw cannotConvert(argument, ofType: source, to: target)
        case .slice(let element) where isByte(element) && sourceShape == .string:
            return target
        case .bool, .slice, .map, .pointer, .channel, .function:
            // Named types convert to and from their identical underlying type,
            // and a channel to one of its directions, as it is assigned.
            if source == .nilType {
                // `Handler(nil)`: nil is a value of every type that has one.
                guard underlying(target) != .bool else { throw cannotConvert(argument, ofType: source, to: target) }
                return target
            }
            guard sourceShape == underlying(target) || isAssignable(source, to: target) else {
                throw cannotConvert(argument, ofType: source, to: target)
            }
            return target
        case .interface, .structure, .array:
            // `Reader(rw)`, `error(e)`, `any(x)`: whatever may be assigned
            // to an interface converts to it; struct and array types
            // convert by their structure.
            guard source != .void, isConvertible(source, to: target) else { throw cannotConvert(argument, ofType: source, to: target) }
            return target
        default:
            throw cannotConvert(argument, ofType: source, to: target)
        }
    }

    func rejectOpaqueFile(_ pointee: GoType, at position: GoSourcePosition) throws {
        guard pointee == .named("os.File") else { return }
        throw GoDiagnostic(
            position: position,
            message: "os.File is opaque; a *os.File cannot be dereferenced")
    }

    // MARK: Library types

    /// The type `callee` names when it is a type of the library that a
    /// value converts to, as in `time.Duration(n)`; nil for anything else.
    func libraryConversionTarget(_ callee: GoExpression) -> GoType? {
        guard case .selector(let base, let name, _) = callee,
            let packageName = importedPackage(named: base)
        else { return nil }
        return GoLibraryTypes.convertible(package: packageName, member: name)
    }

    /// `package.member` when it names a type of the library, which is no
    /// value: `x := time.Duration`.
    func libraryTypeName(base: GoExpression, member: String) -> String? {
        guard let packageName = importedPackage(named: base) else { return nil }
        let name = packageName + "." + member
        let named = GoTypeExpression.named(name, position: base.position)
        return (try? declaredType(named)) == nil ? nil : name
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
            importedPaths.contains(packageName) || importedPackage(named: base) != nil,
            let native = GoStandardLibrary.nativeFunction(package: packageName, member: name)
        {
            function = native
            parameters = native.parameters[...]
        } else if let receiver = try? type(of: base),
            let native = GoStandardLibrary.method(
                of: GoLibraryTypes.methodOwner(receiver) ?? receiver, named: name)
        {
            function = native
            parameters = native.parameters.dropFirst()
        } else {
            return try promotedNativeCall(callee, arguments: arguments, position: position)
        }
        guard function.isVariadic
            ? arguments.count >= parameters.count
            : arguments.count == parameters.count
        else {
            throw try argumentCountMismatch(
                arguments, of: callee, declared: function.declared(parameters),
                position: position)
        }
        // The writer of `fmt.Fprint` is a file or anything with `Write`.
        let writes = try checkFormatWriter(function, arguments: arguments, position: position)
        for (argument, parameter) in zip(arguments, parameters).dropFirst(writes ? 1 : 0) {
            try requireArgument(argument, as: parameter, of: callee)
        }
        try checkAnyOperands(arguments.dropFirst(parameters.count), of: callee)
        return function
    }

    /// Whether the call of `function` is `fmt.Fprint`, `Fprintln`, or
    /// `Fprintf` to a writer that is no file: a value with the method
    /// `Write([]byte) (int, error)`, which the call is compiled to call. See
    /// `GoWriterFormat`. A first argument that is neither is reported as Go
    /// reports it, as no `io.Writer`.
    mutating func checkFormatWriter(
        _ function: GoNativeFunction, arguments: [GoExpression], position: GoSourcePosition
    ) throws -> Bool {
        guard function.formatsOperands, function.parameters.first == GoPredeclared.filePointer,
            let writer = arguments.first
        else { return false }
        let writerType = try type(of: writer)
        if writerType == GoPredeclared.filePointer || writerType == .nilType { return false }
        let write = GoWriterFormat.write(.string("", position: position), to: writer)
        let results = try? callResultTypes(
            callee: write.callee, arguments: write.arguments, position: position)
        guard results == [.int, GoPredeclared.errorType] else {
            throw noWriter(writer, ofType: writerType, in: "argument to \(function.goName)")
        }
        return true
    }

    /// Checks the operands of a `...any` parameter: any number of values, or
    /// one `[]any` followed by `...`.
    mutating func checkAnyOperands(
        _ operands: ArraySlice<GoExpression>, of callee: GoExpression
    ) throws {
        if operands.count == 1, let operand = operands.first?.spreadOperand {
            let operandType = try type(of: operand)
            guard case .slice(let element) = underlying(operandType),
                case .interface(let methods) = underlying(element), methods.isEmpty
            else {
                throw cannotUse(
                    operand, ofType: operandType, as: .slice(.interface([])),
                    in: "argument to " + calleeSpelling(callee))
            }
            return
        }
        for argument in operands where try type(of: argument) == .void {
            throw noValue(argument)
        }
        for argument in operands { try requireDefault(argument, of: callee) }
    }

    func structFields(of type: GoType) -> [GoStructFieldType]? {
        let candidate: GoType
        // A pointer, or a type that is one underneath (`type ptr *T`),
        // selects the fields of what it points to.
        if let pointee = type.pointee(in: typeDefinitions) {
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
        type.pointee(in: typeDefinitions) != nil
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
        // Only the library has values of a handle type.
        if GoLibraryTypes.isHandle(expected) { return actual == .nilType }
        if actual == .nilType
            && (isPointer(expected) || isSlice(expected) || isMap(expected) || isChannel(expected)
                || isFunction(expected))
        {
            return true
        }
        // A value of a type that has no name goes where a named type of the
        // same structure is asked for, and the reverse: a function literal
        // is a `HandlerFunc`, a `[]string` is a `names`.
        if isUnnamedComposite(actual) != isUnnamedComposite(expected),
            underlying(actual) == underlying(expected),
            isNamedComposite(actual) || isNamedComposite(expected)
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
        if case .interface(let own) = underlying(type) {
            // A value of one interface type is one of another that asks
            // for no method the first lacks: of `Reader`, a `ReadWriter`.
            return methods.allSatisfy(own.contains)
        }
        for method in methods {
            if let library = GoLibraryTypes.interfaceMethod(of: type, named: method.name) {
                // A method of a library type, which the VM provides.
                guard library.parameters == method.parameters, library.results == method.results
                else { return false }
                continue
            }
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
        if isFloat(type) { return true }
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
        callee: GoExpression,
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
        try checkArguments(arguments, of: callee, declared: parameters, position: position)
        return results
    }

    /// Check a call to a supported `strings` function and return its result.
    mutating func stringsCallResult(
        _ name: String,
        callee: GoExpression,
        arguments: [GoExpression],
        position: GoSourcePosition
    ) throws -> GoType {
        guard let function = GoStringsFunction(goName: name) else {
            throw GoDiagnostic(position: callee.position, message: "undefined: strings.\(name)")
        }
        let signature = function.signature
        try checkArguments(
            arguments, of: callee, declared: signature.parameters, position: position)
        return signature.result
    }

    mutating func callResultTypes(
        callee: GoExpression,
        arguments: [GoExpression],
        position: GoSourcePosition
    ) throws -> [GoType] {
        if try forwardsResults(arguments, to: callee) {
            return try forwardedCallResults(callee: callee, arguments: arguments)
        }
        if case .identifier(let name, let namePosition) = callee {
            if let binding = lookup(name),
                let results = try resultsOfCall(
                    through: binding.type, callee: callee, arguments: arguments, position: position)
            {
                return results
            }
            guard let signature = functionSignatures[name] else {
                throw GoDiagnostic(
                    position: namePosition,
                    message: uncallableMessage(name) ?? "undefined: \(name)")
            }
            try checkArguments(
                arguments, of: callee, declared: signature.parameters, position: position)
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
        if let results = try methodExpressionResults(callee, arguments: arguments, position: position) {
            return results
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
                try checkArguments(arguments, of: callee, declared: [.string], position: position)
                return [.int, GoPredeclared.errorType]
            }
            if case .identifier("userland", _) = base,
                importedPaths.contains("swiftix/userland"),
                name == "ReadInput"
            {
                try checkArguments(
                    arguments, of: callee, declared: [.string, .slice(.string)],
                    position: position)
                return [.string, .int]
            }
            if case .identifier("userland", _) = base,
                importedPaths.contains("swiftix/userland"),
                let results = try userlandTerminalResults(
                    name, callee: callee, arguments: arguments, position: position)
            {
                return results
            }
            if case .identifier("strings", _) = base,
                importedPaths.contains("strings")
            {
                return [
                    try stringsCallResult(
                        name, callee: callee, arguments: arguments, position: position)
                ]
            }
            if case .identifier(let packageName, _) = base,
                packageName == "net",
                importedPaths.contains("net")
            {
                switch name {
                case "Dial":
                    try checkArguments(
                        arguments, of: callee, declared: [.string, .string],
                        position: position)
                    return [.named("net.Conn"), GoPredeclared.errorType]
                case "Listen":
                    try checkArguments(
                        arguments, of: callee, declared: [.string, .string],
                        position: position)
                    return [.named("net.Listener"), GoPredeclared.errorType]
                case "LookupHost":
                    try checkArguments(
                        arguments, of: callee, declared: [.string],
                        position: position)
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
                    try checkArguments(
                        arguments, of: callee, declared: [.string],
                        position: position)
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
            try requireVisible(name, of: base, in: baseType, at: callee.position)
            if let lent = try promotedCallResults(
                callee, baseType: baseType, arguments: arguments, position: position, single: false)
            {
                return lent
            }
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
            if signature == nil,
                let field = structFields(of: baseType)?.first(where: { $0.name == name }),
                let results = try resultsOfCall(
                    through: field.type, callee: callee, arguments: arguments, position: position)
            {
                return results
            }
            guard let signature else {
                if let field = structFields(of: baseType)?.first(where: { $0.name == name }) {
                    throw invalidOperand("cannot call non-function", callee, ofType: field.type)
                }
                throw undefinedSelection(name, of: base, ofType: baseType, at: callee.position)
            }
            try checkArguments(
                arguments, of: callee, declared: signature.parameters, position: position)
            return signature.results
        }
        if let results = try resultsOfCall(
            through: try type(of: callee), callee: callee, arguments: arguments,
            position: position)
        {
            return results
        }
        throw GoDiagnostic(position: position, message: "unsupported function call in multi-value context")
    }

    /// The value of a case that is an integer or string constant, which
    /// Go allows a switch once. It does not compare the cases of a switch
    /// on a `bool`.
    func switchCaseConstant(_ expression: GoExpression) -> SwitchCaseConstant? {
        if case .string(let value, _) = expression { return .string(value) }
        return untypedConstantValue(expression).map { .int($0) }
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

    /// Whether `block` ends its function, so that no `return` is missing
    /// after it. See `GoTermination`.
    func blockTerminates(_ block: GoBlock) -> Bool {
        GoTermination(panicIsBuiltin: functionSignatures["panic"] == nil).terminates(block)
    }
}

// MARK: Declarations and names at the edges

/// The checks of this section that a statement or an expression asks for
/// are `mutating`, though they change nothing: a caller that is being
/// changed passes itself to such a function, and would hand any other a
/// copy of the whole checker, which an unoptimized build keeps in the
/// caller's frame for each place that asks. Those frames are what limits how
/// deep a program may nest.
extension FunctionChecker {
    /// What Go says of `name` where nothing declares it. The blank
    /// identifier names no value, and `iota` is one only in a `const`.
    static func undeclaredMessage(_ name: String) -> String {
        switch name {
        case GoValueList.blank: return "cannot use _ as value or type"
        case GoIota.name: return "cannot use iota outside constant declaration"
        default: return "undefined: \(name)"
        }
    }

    /// Where `expression` begins, which is where Go reports a value that
    /// does not fit its declaration. A node of the tree is where its own
    /// token is: a call at its `(`, an operation at its operator, a
    /// selection at the selected name. `positions` are the file's, where
    /// the parser notes a call that begins with a parenthesis.
    static func start(
        of expression: GoExpression, in positions: [Int: [GoSourcePosition]]
    ) -> GoSourcePosition {
        // In parentheses, it begins at the outermost of them.
        if let open = positions[GoParenthesized.key(of: expression.position)]?.last { return open }
        switch expression {
        case .call(let callee, let arguments, let position):
            if let grouped = expression.groupedResult { return start(of: grouped.value, in: positions) }
            if let operation = expression.bitwiseOperation {
                return operation.operator.isUnary
                    ? position : start(of: operation.operands[0], in: positions)
            }
            if case .identifier(let name, _) = callee, name.hasPrefix("$") {
                return arguments.first.map { start(of: $0, in: positions) } ?? position
            }
            return positions[position.offset]?.first ?? start(of: callee, in: positions)
        case .selector(let base, _, _), .typeAssertion(let base, _, _), .index(let base, _, _):
            return start(of: base, in: positions)
        case .binary(let left, _, _, _):
            return start(of: left, in: positions)
        default:
            return expression.position
        }
    }

    // MARK: Parameters of a function literal

    /// Declares the parameters of a literal in the scope that is its own.
    /// One without a name, or with the blank one, is none the body can
    /// use, and any number may be so.
    mutating func bind(_ parameters: [GoParameter], ofTypes types: [GoType]) throws {
        for (parameter, parameterType) in zip(parameters, types)
        where parameter.name != GoValueList.blank {
            guard scopes[scopes.count - 1][parameter.name] == nil else {
                throw GoDiagnostic.redeclared(
                    parameter.name, at: parameter.position,
                    other: scopes[scopes.count - 1][parameter.name]?.position)
            }
            scopes[scopes.count - 1][parameter.name] = Binding(
                type: parameterType.parameterType, isConstant: false,
                position: parameter.position, isUsed: true)
        }
    }

    /// Declares the results of a literal that have names. A blank one
    /// counts as named, so a bare `return` will do, and nothing reads it.
    mutating func bind(results names: [String?], ofTypes types: [GoType]) {
        for (name, resultType) in zip(names, types) {
            guard let name else { continue }
            if name != GoValueList.blank {
                scopes[scopes.count - 1][name] = Binding(type: resultType, isConstant: false)
            }
            namedResultCount += 1
        }
    }

    // MARK: Short declarations

    /// The name `statement` declares is new to its block. A `:=` that
    /// names a variable of the block is Go's `no new variables`; a `var` or
    /// `const` that does is a redeclaration, reported where the name is.
    mutating func requireUndeclared(_ statement: GoStatement) throws {
        guard case .declaration(let name, let explicitType, _, let isConstant, let position) = statement
        else { return }
        if explicitType == nil, !isConstant { try requireNewVariables([name], at: position) }
        guard scopes[scopes.count - 1][name] == nil else {
            throw GoDiagnostic.redeclared(
                name, at: namePositions[position.offset]?.first ?? position,
                other: scopes[scopes.count - 1][name]?.position)
        }
    }

    /// Whether the declaration of `names` at `position` is a `var`, whose
    /// names are all new or the blank one: the parser recorded their places
    /// and none for a `:=`.
    mutating func isVariableDeclaration(_ names: [String], at position: GoSourcePosition) -> Bool {
        namePositions[position.offset]?.count == names.count
    }

    /// A `:=` declares at least one variable: Go refuses one whose names
    /// the block all has already, at the `:=`, a name written twice, at
    /// its second place, and a name that is a constant of the block, which
    /// cannot be assigned. Nothing is asked of a `var`, whose names the
    /// parser recorded without a place for a `:=`.
    mutating func requireNewVariables(_ names: [String], at position: GoSourcePosition) throws {
        guard let positions = namePositions[position.offset], positions.count == names.count + 1
        else { return }
        var seen: Set<String> = []
        var declaresOne = false
        for (name, namePosition) in zip(names, positions) where name != GoValueList.blank {
            guard seen.insert(name).inserted else {
                throw GoDiagnostic(
                    position: namePosition, message: "\(name) repeated on left side of :=")
            }
            guard let existing = scopes[scopes.count - 1][name] else {
                declaresOne = true
                continue
            }
            if existing.isConstant {
                throw GoDiagnostic(position: namePosition, message: "cannot assign to \(name)")
            }
        }
        if !declaresOne {
            throw GoDiagnostic(
                position: positions[names.count], message: "no new variables on left side of :=")
        }
    }

    // MARK: Constants

    /// Whether `expression` is surely no constant: it names a variable or
    /// a function, calls one, or builds a value at run time. What this
    /// cannot tell — a member of a package, an operation the parser encodes
    /// in a way of its own — counts as constant, as every initializer did
    /// before there was this check.
    func isNotConstant(_ expression: GoExpression) -> Bool {
        switch expression {
        case .integer, .string, .typeExpression:
            return false
        case .identifier(let name, _):
            if let binding = lookup(name) { return !binding.isConstant }
            return functionSignatures[name] != nil
        case .unary(let unaryOperator, let operand, _):
            switch unaryOperator {
            case .plus, .minus, .not: return isNotConstant(operand)
            case .address, .dereference, .receive: return true
            }
        case .binary(let left, _, let right, _):
            return isNotConstant(left) || isNotConstant(right)
        case .selector(let base, _, _):
            return importedPackage(named: base) == nil
        case .call(let callee, let arguments, _):
            if case .identifier(let name, _) = callee {
                if name.hasPrefix("$") { return arguments.contains { isNotConstant($0) } }
                // `min` and `max` of constants are constants.
                if name == "min" || name == "max", isPredeclared(name) {
                    return arguments.contains { isNotConstant($0) }
                }
                if name == "len" || name == "cap", lookup(name) == nil,
                    functionSignatures[name] == nil
                {
                    return arguments.contains { hasNoConstantLength($0) }
                }
            }
            guard let target = try? conversionTarget(callee) else { return true }
            switch underlying(target) {
            case .int, .string, .bool: return arguments.contains { isNotConstant($0) }
            default: return true
            }
        case .compositeLiteral, .functionLiteral, .index, .slicing, .typeAssertion:
            return true
        }
    }

    /// Whether `len(operand)` is surely no constant. The length of a
    /// constant string is one, and so is that of an array, whatever holds
    /// it; what may be an array counts as one.
    func hasNoConstantLength(_ operand: GoExpression) -> Bool {
        switch operand {
        case .identifier(let name, _):
            guard let binding = lookup(name), !binding.isConstant else { return false }
            if case .array = underlying(binding.type) { return false }
            return true
        case .selector, .index, .unary(.dereference, _, _):
            return false
        default:
            return isNotConstant(operand)
        }
    }

    /// The value of a constant must be one: Go's report names a variable
    /// that is none, and says of any other expression what type its value
    /// has, where the expression begins.
    mutating func requireConstant(_ expression: GoExpression?, ofType type: GoType?) throws {
        guard let expression, let type, isNotConstant(expression) else { return }
        throw GoDiagnostic(
            position: Self.start(of: expression, in: namePositions),
            message: describe(expression, ofType: type) + " is not constant")
    }

    // MARK: Package-level variables

    /// The value of a package-level variable must fit its type, and the
    /// value of a constant be one. Reported where the value begins.
    mutating func requireInitializer(
        _ expression: GoExpression, assignableTo expected: GoType, isConstant: Bool
    ) throws {
        let actual = try initializerType(of: expression)
        if isConstant { try requireConstant(expression, ofType: actual) }
        if let grouped = expression.groupedResult {
            // One of the values of `var a, b T = f()`.
            guard try isAssignable(expression, ofType: actual, to: expected) else {
                throw cannotUseResult(
                    of: grouped.value, type: actual, as: expected, in: "assignment")
            }
            return
        }
        try requireUse(
            expression, ofType: actual, as: expected,
            in: isConstant ? "constant declaration" : "variable declaration")
    }

    /// The type of the value of a package-level variable: of the
    /// expression, or of its place among the values of one that several
    /// variables share, `var a, b = f()` and `var v, ok = m[k]`.
    /// Only a declaration of the package has such a value, so the question
    /// is asked here and not of every call.
    mutating func initializerType(of expression: GoExpression) throws -> GoType {
        guard let (index, count, value) = expression.groupedResult else {
            return try type(of: expression)
        }
        // Go reports a number of values that does not match where they begin.
        let names = Self.start(of: value, in: namePositions)
        var types: [GoType] = []
        switch value {
        case .call(let callee, let arguments, let position):
            types = try callResultTypes(callee: callee, arguments: arguments, position: position)
            guard types.count == count else {
                throw resultCountMismatch(variables: count, call: value, results: types.count)
            }
        case .index(let base, let key, _):
            guard case .map(let keyType, let valueType) = underlying(try type(of: base)) else {
                break
            }
            try requireUse(key, as: keyType, in: "map index")
            types = [valueType, .bool]
        case .typeAssertion(_, let assertedType, _):
            _ = try type(of: value)
            types = [try declaredType(assertedType), .bool]
        case .unary(.receive, _, _):
            types = [try type(of: value), .bool]
        default:
            break
        }
        guard types.count == count, index < count else {
            throw GoDiagnostic(position: names, message: Self.mismatch(variables: count, values: 1))
        }
        return types[index]
    }

    // MARK: Pointers with a name

    /// The type two operands of different types are compared or combined
    /// as: an integer type for an untyped constant beside it, and for two
    /// pointer types of which one has a name and the other is what it
    /// stands for, `ptr` and `*T` after `type ptr *T`, the first. Go
    /// compares those two as it assigns one to the other.
    func commonOperandType(
        left: GoExpression, leftType: GoType, right: GoExpression, rightType: GoType
    ) throws -> GoType? {
        if let common = try commonIntegerType(
            left: left, leftType: leftType, right: right, rightType: rightType)
        {
            return common
        }
        guard isPointer(leftType), isPointer(rightType),
            isAssignable(leftType, to: rightType) || isAssignable(rightType, to: leftType)
        else { return nil }
        return leftType
    }

    // MARK: Unexported fields and methods

    /// Whether the field or method `name` of a value of `type` is hidden
    /// from the package being checked: its name is not exported, and the
    /// type is one another package declares. A type's symbol begins with
    /// its package's path, and the root package's names have none.
    func isHidden(_ name: String, in type: GoType) -> Bool {
        guard !GoModuleLinker.isExported(name) else { return false }
        // The method the compiler declares for a promoted one selects what
        // its type was lent, whichever package that is from.
        guard lookup(GoEmbedding.receiverName) == nil else { return false }
        let owner = type.pointee(in: typeDefinitions) ?? type
        guard case .named(let typeName) = owner, typeDefinitions[typeName] != nil else {
            return false
        }
        // The file's package came with the places of its names.
        return typeName.lastIndex(of: ".").map { String(typeName[..<$0]) }
            != namePositions[GoFile.packagePathKey]?.first?.path
    }

    /// Refuses the selection of a hidden field or method, as Go does where
    /// the name is. A name the type does not have at all is left to the
    /// report that says so.
    mutating func requireVisible(
        _ name: String, of base: GoExpression, in type: GoType, at position: GoSourcePosition
    ) throws {
        guard isHidden(name, in: type) else { return }
        let kind: String
        if structFields(of: type)?.contains(where: { $0.name == name }) == true {
            kind = "field"
        } else if methodSignature(of: type, named: name) != nil {
            kind = "method"
        } else if case .interface(let methods) = underlying(type),
            methods.contains(where: { $0.name == name })
        {
            kind = "method"
        } else {
            return
        }
        throw GoDiagnostic(
            position: position,
            message: "\(base.spelledAsOperand(in: namePositions)).\(name) undefined "
                + "(cannot refer to unexported \(kind) \(name))")
    }

    /// A struct literal may not name a field that is hidden.
    mutating func requireVisibleKey(_ element: GoCompositeElement, in type: GoType) throws {
        guard let key = element.key, isHidden(key, in: type) else { return }
        throw GoDiagnostic(
            position: element.position,
            message: "cannot refer to unexported field \(key) in struct literal of type \(type)")
    }

    /// A struct literal without field names gives every field in turn, and
    /// may not give one that is hidden. Go checks each value as it comes,
    /// before it counts them.
    mutating func requireVisibleFields(
        _ fields: [GoStructFieldType], of type: GoType, for elements: [GoCompositeElement]
    ) throws {
        for (element, field) in zip(elements, fields) where isHidden(field.name, in: type) {
            throw GoDiagnostic(
                position: element.position,
                message:
                    "implicit assignment to unexported field \(field.name) in struct literal of type \(type)")
        }
    }
}
// MARK: - Composite literals

extension FunctionChecker {
    /// A literal without a type is an element or a key of a literal of an
    /// array, a slice, or a map, which gave it one before the checker saw
    /// it. Anywhere else it has none.
    func requireLiteralType(_ type: GoTypeExpression, at position: GoSourcePosition) throws {
        guard type.isElided else { return }
        throw GoDiagnostic(position: position, message: "missing type in composite literal")
    }

    /// Requires `expression` to be a value of `expected`, as an element, a
    /// field, or a key of a literal: `context` names the literal, as Go does.
    mutating func requireElement(
        _ expression: GoExpression, assignableTo expected: GoType, in context: String
    ) throws {
        try requireSingleResult(of: expression)
        let actual = try type(of: expression)
        guard actual != .void else { throw noValue(expression) }
        try requireUse(expression, ofType: actual, as: expected, in: context)
    }

    /// The elements of a struct literal: every one names its field, or none
    /// does and there is a value for each field in order. `T{}` is the zero
    /// value.
    mutating func checkStructLiteral(
        _ elements: [GoCompositeElement], fields: [GoStructFieldType], type literalType: GoType,
        position: GoSourcePosition
    ) throws {
        func hasKey(_ element: GoCompositeElement) -> Bool {
            element.key != nil || element.keyExpression != nil
        }
        guard let first = elements.first else { return }
        let mixture = "mixture of field:value and value elements in struct literal"
        guard hasKey(first) else {
            try requireVisibleFields(fields, of: literalType, for: elements)
            for (index, element) in elements.enumerated() {
                guard !hasKey(element) else {
                    throw GoDiagnostic(position: element.position, message: mixture)
                }
                guard index < fields.count else {
                    throw GoDiagnostic(
                        position: element.position,
                        message: "too many values in struct literal of type \(literalType)")
                }
                try requireElement(
                    element.value, assignableTo: fields[index].type, in: "struct literal")
            }
            guard elements.count == fields.count else {
                // Go reports the values a literal lacks where it ends.
                throw GoDiagnostic(
                    position: namePositions[GoCompositeLiterals.endKey(of: position)]?.first
                        ?? position,
                    message: "too few values in struct literal of type \(literalType)")
            }
            return
        }
        var seen: Set<String> = []
        for element in elements {
            guard hasKey(element) else {
                throw GoDiagnostic(position: element.position, message: mixture)
            }
            guard let key = element.key else {
                throw GoDiagnostic(
                    position: element.position,
                    message: "invalid field name "
                        + "\(element.keyExpression?.sourceSpelling ?? "") in struct literal")
            }
            guard let field = fields.first(where: { $0.name == key }) else {
                throw GoDiagnostic(
                    position: element.position,
                    message: "unknown field \(key) in struct literal of type \(literalType)")
            }
            try requireVisibleKey(element, in: literalType)
            guard seen.insert(key).inserted else {
                throw GoDiagnostic(
                    position: element.position,
                    message: "duplicate field name \(key) in struct literal")
            }
            try requireElement(element.value, assignableTo: field.type, in: "struct literal")
        }
    }

    /// The elements of an array or slice literal. Each stands at the index
    /// after that of the one before it, or at the constant index it is
    /// written with, which `GoCompositeLiterals` has replaced by its value;
    /// no index is given twice, and none is beyond an array's length.
    mutating func checkListLiteral(
        _ elements: [GoCompositeElement], element elementType: GoType, length: Int?
    ) throws {
        let hasIndexes = elements.contains { $0.keyExpression != nil }
        var seen: Set<Int> = []
        var next = 0
        for element in elements {
            var index = next
            if let written = element.keyExpression {
                index = try literalIndex(written)
                if let length, index >= length {
                    throw GoDiagnostic(
                        position: written.position,
                        message: "invalid argument: index \(index) out of bounds [0:\(length)]")
                }
            } else if let length, index >= length {
                throw GoDiagnostic(
                    position: element.position,
                    message: "index \(index) is out of bounds (>= \(length))")
            }
            guard index < GoCompositeLiterals.maximumLength else {
                throw GoDiagnostic(
                    position: element.position,
                    message: "index \(index) is beyond the \(GoCompositeLiterals.maximumLength) "
                        + "elements a composite literal may have")
            }
            if hasIndexes, !seen.insert(index).inserted {
                throw GoDiagnostic(
                    position: element.position,
                    message: "duplicate index \(index) in array or slice literal")
            }
            try requireElement(
                element.value, assignableTo: elementType, in: "array or slice literal")
            next = index + 1
        }
    }

    /// Whether one of two types has a name and the other is that type
    /// written out: `struct{ a int }` and a `type T struct{ a int }`. Each is
    /// assignable to the other, and their values compare.
    func differOnlyInName(_ first: GoType, _ second: GoType) -> Bool {
        first != second && isUnnamedComposite(first) != isUnnamedComposite(second)
            && underlying(first) == underlying(second)
            && (isNamedComposite(first) || isNamedComposite(second))
            && !isInterface(first)
    }

    /// Whether a value of `source` converts to `target`, an interface, a
    /// struct, or an array type: `any(x)` and `error(nil)` take what could
    /// be assigned to them, and two types of one structure convert to each
    /// other whatever either is called.
    func isConvertible(_ source: GoType, to target: GoType) -> Bool {
        if isInterface(target) { return isAssignable(source, to: target) }
        return underlying(source) == underlying(target)
    }

    /// The array a pointer to an array points to, and any other type as it
    /// is: `p[i]`, `p[a:b]`, `len(p)`, `cap(p)`, and `range p` follow such a
    /// pointer without a `*`.
    func throughArrayPointer(_ type: GoType) -> GoType {
        guard case .pointer(let pointee) = underlying(type), case .array = underlying(pointee)
        else { return type }
        return pointee
    }

    /// The type of the target `p[i]` for a pointer `p` to an array: the
    /// element of the array it points to, a variable whatever `p` is.
    mutating func elementType(behind pointer: GoType, index: GoExpression) throws -> GoType {
        guard case .array(_, let element) = underlying(throughArrayPointer(pointer)),
            isInteger(try type(of: index))
        else {
            throw nonIntegerIndex(index)
        }
        return element
    }

    /// The type an index, a slice expression, `len`, `cap`, or `range`
    /// works on in `operand`: its underlying type, past a pointer to an
    /// array.
    mutating func indexedType(of operand: GoExpression) throws -> GoType {
        underlying(throughArrayPointer(try type(of: operand)))
    }

    /// What a `range` over a value of `type` goes through: its underlying
    /// type, past a pointer to an array.
    func rangedType(_ type: GoType) -> GoType {
        underlying(throughArrayPointer(type))
    }

    /// The index an element is written with: a constant that is an integer
    /// and not negative.
    mutating func literalIndex(_ written: GoExpression) throws -> Int {
        guard case .integer(let value, let position) = written else {
            let writtenType = try type(of: written)
            guard isInteger(writtenType) else { throw nonIntegerIndex(written) }
            throw GoDiagnostic(
                position: written.position,
                message: "index \(written.sourceSpelling) must be integer constant")
        }
        guard value >= 0, let index = Int(exactly: value) else {
            throw GoDiagnostic(
                position: position,
                message: "invalid argument: index \(value) (constant of type int) must not be negative")
        }
        return index
    }

    /// The entries of a map literal: each a key and a value, and no
    /// constant key twice.
    mutating func checkMapLiteral(
        _ elements: [GoCompositeElement], key keyType: GoType, value valueType: GoType
    ) throws {
        var constants: Set<SwitchCaseConstant> = []
        for element in elements {
            if let key = element.keyExpression {
                try requireElement(key, assignableTo: keyType, in: "map literal")
                let constant = switchCaseConstant(key) ?? untypedConstantValue(key).map { .int($0) }
                if let constant, !constants.insert(constant).inserted {
                    throw GoDiagnostic(
                        position: key.position,
                        message: "duplicate key \(key.sourceSpelling) in map literal")
                }
            } else if element.key == nil {
                throw GoDiagnostic(position: element.position, message: "missing key in map literal")
            }
            try requireElement(element.value, assignableTo: valueType, in: "map literal")
        }
    }
}

// MARK: - `new`, `min`, `max`, and `clear`

extension FunctionChecker {
    /// Whether `name` means what Go predeclares: the program declares no
    /// variable, function, or type of that name where it is read.
    func isPredeclared(_ name: String) -> Bool {
        lookup(name) == nil && functionSignatures[name] == nil && !availableTypes.contains(name)
    }

    /// The types `<`, `min`, and `max` put in order.
    func isOrdered(_ type: GoType) -> Bool {
        isInteger(type) || isString(type) || isFloat(type)
    }

    /// The type of a call of `new`, `min`, `max`, or `clear`, or nil when
    /// `callee` is none of them or the program has given the name another
    /// meaning.
    mutating func predeclaredCallType(
        callee: GoExpression, arguments: [GoExpression]
    ) throws -> GoType? {
        guard case .identifier(let name, let position) = callee, isPredeclared(name) else {
            return nil
        }
        switch name {
        case "new":
            try requireArgumentCount(1, of: name, arguments: arguments, position: position)
            guard case .typeExpression(let type, _) = arguments[0] else {
                // What names nothing is reported as that.
                _ = try self.type(of: arguments[0])
                throw GoDiagnostic(
                    position: arguments[0].position,
                    message: "\(arguments[0].sourceSpelling) is not a type")
            }
            return .pointer(try declaredType(type))
        case "make":
            // The rest is checked with the builtins that were here before;
            // what is no type is reported for what it is.
            if let first = arguments.first, case .typeExpression = first { return nil }
            if let first = arguments.first {
                _ = try type(of: first)
                throw GoDiagnostic(
                    position: first.position, message: "\(first.sourceSpelling) is not a type")
            }
            return nil
        case "min", "max":
            return try orderedCallType(name, arguments: arguments, position: position)
        case "clear":
            try requireArgumentCount(1, of: name, arguments: arguments, position: position)
            let cleared = try type(of: arguments[0])
            guard isMap(cleared) || isSlice(cleared) else {
                throw GoDiagnostic(
                    position: arguments[0].position,
                    message: "invalid argument: cannot clear "
                        + describe(arguments[0], ofType: cleared)
                        + ": argument must be (or constrained by) map or slice")
            }
            return .void
        default:
            return nil
        }
    }

    /// Go's report of a builtin called with too few or too many operands.
    func requireArgumentCount(
        _ count: Int, of name: String, arguments: [GoExpression], position: GoSourcePosition,
        orMore: Bool = false
    ) throws {
        if arguments.count == count || (orMore && arguments.count > count) { return }
        let call = name + "(" + argumentList(arguments) + ")"
        throw GoDiagnostic(
            position: position,
            message: "invalid operation: "
                + (arguments.count < count ? "not enough" : "too many")
                + " arguments for \(call) (expected \(count), found \(arguments.count))")
    }

    /// Whether `expression` is a constant that takes the type of what it is
    /// used with: an untyped integer constant, or a string literal.
    func isUntypedConstant(_ expression: GoExpression) -> Bool {
        if case .string = expression { return true }
        return untypedConstantValue(expression) != nil
    }

    /// The type of `min(x, y...)` or `max(x, y...)`: the one type of the
    /// operands that have one, which the constants among them take, or the
    /// type of a constant when all are constants.
    mutating func orderedCallType(
        _ name: String, arguments: [GoExpression], position: GoSourcePosition
    ) throws -> GoType {
        try requireArgumentCount(1, of: name, arguments: arguments, position: position, orMore: true)
        guard !arguments.contains(where: { $0.spreadOperand != nil }) else {
            throw GoDiagnostic(
                position: position,
                message: "invalid operation: invalid use of ... with built-in \(name)")
        }
        if let floating = try floatingOrderedType(arguments) { return floating }
        // The type so far and how Go names it, and whether a constant gave it.
        var shared: (type: GoType, name: String, isConstant: Bool)?
        for argument in arguments {
            try requireSingleValue(argument, at: argument.position)
            let argumentType = try type(of: argument)
            guard argumentType != .void else {
                throw GoDiagnostic(position: argument.position, message: "no value used as value")
            }
            guard isOrdered(argumentType) else {
                throw GoDiagnostic(
                    position: argument.position,
                    message: "invalid argument: "
                        + describe(argument, ofType: argumentType)
                        + " cannot be ordered")
            }
            let isConstant = isUntypedConstant(argument)
            let typeName = isConstant ? "untyped \(argumentType)" : "\(argumentType)"
            guard let previous = shared else {
                shared = (argumentType, typeName, isConstant)
                continue
            }
            // A constant goes with any type of its kind; two types are one.
            let agrees =
                isConstant || previous.isConstant
                ? isInteger(argumentType) == isInteger(previous.type)
                : argumentType == previous.type
            guard agrees else {
                throw GoDiagnostic(
                    position: argument.position,
                    message: "invalid argument: mismatched types \(previous.name) "
                        + "(previous argument) and \(typeName) "
                        + "(type of \(argument.sourceSpelling))")
            }
            if previous.isConstant, !isConstant { shared = (argumentType, typeName, false) }
        }
        let result = shared?.type ?? .int
        for argument in arguments {
            if let value = untypedConstantValue(argument) {
                try requireConstant(value, representableAs: result, at: argument.position)
            }
        }
        return result
    }

    /// The value of `min` or `max` of constants, which is a constant.
    func orderedConstantValue(_ expression: GoExpression) -> Int64? {
        guard case .call(.identifier(let name, _), let arguments, _) = expression,
            name == "min" || name == "max", isPredeclared(name), !arguments.isEmpty
        else { return nil }
        var values: [Int64] = []
        for argument in arguments {
            guard let value = untypedConstantValue(argument) else { return nil }
            values.append(value)
        }
        return name == "min" ? values.min() : values.max()
    }

    /// Checks a call that is a statement of its own, or what `go` or
    /// `defer` starts. Go refuses one that calls a builtin for its value,
    /// which nothing takes: `len(s)` alone, or `defer new(int)`.
    mutating func checkCall(_ expression: GoExpression, droppedBy keyword: String?) throws {
        if case .call(.identifier(let name, let position), _, _) = expression,
            ["len", "cap", "append", "make", "new", "min", "max"].contains(name),
            isPredeclared(name)
        {
            let described = describe(expression, ofType: try type(of: expression))
            throw GoDiagnostic(
                position: position,
                message: keyword.map { "\($0) discards result of \(described)" }
                    ?? "\(described) is not used")
        }
        try checkCallStatement(expression)
    }
}
