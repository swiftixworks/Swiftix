/// Frontend, IR lowering, and bytecode emission for Swiftix Go programs.

import SwiftixGoRuntime

public struct GoCompiledPackage: Sendable, Equatable {
    public let name: String
    public let export: GoPackageExport
    public let functions: [GoBytecodeFunction]
    public let globalCount: Int
    public let initializers: [String]

    public init(
        name: String,
        export: GoPackageExport,
        functions: [GoBytecodeFunction],
        globalCount: Int = 0,
        initializers: [String] = []
    ) {
        self.name = name
        self.export = export
        self.functions = functions
        self.globalCount = globalCount
        self.initializers = initializers
    }
}

public enum GoCompiler {
    public static func compile(sources: [GoSourceFile]) throws -> GoExecutable {
        try compile(sources: sources, importedPackages: [:])
    }

    public static func compile(
        sources: [GoSourceFile],
        importedPackages: [String: GoCompiledPackage],
        packageOrder: [String] = []
    ) throws -> GoExecutable {
        let files = try sources.map(GoParser.parse)
        let availablePackageExports = Dictionary(
            uniqueKeysWithValues: importedPackages.map { ($0.key, $0.value.export) })
        let package = try GoTypeChecker.check(files, availablePackages: availablePackageExports)
        guard package.name == "main" else {
            let position =
                files.first?.functions.first?.position
                ?? GoSourcePosition(path: sources.first?.path ?? "<input>", offset: 0, line: 1, column: 1)
            throw GoDiagnostic(position: position, message: "go run requires package main")
        }
        var functions = files.flatMap(\.functions)
        functions.append(contentsOf: runtimeLiteralFunctions(in: functions))
        guard functions.contains(where: { $0.name == "main" }) else {
            let position = GoSourcePosition(
                path: sources.first?.path ?? "<input>", offset: 0, line: 1, column: 1)
            throw GoDiagnostic(position: position, message: "function main is undeclared in the main package")
        }

        let orderedPackagePaths = packageOrder
            + importedPackages.keys.filter { !packageOrder.contains($0) }.sorted()
        let orderedPackages = orderedPackagePaths.compactMap { importedPackages[$0] }
        let importedGlobalCount = orderedPackages.reduce(0) { $0 + $1.globalCount }
        let globals = files.flatMap(\.globalDeclarations)
        let globalInfos = Dictionary(
            uniqueKeysWithValues: globals.enumerated().map { index, declaration in
                (
                    declaration.name,
                    GlobalInfo(
                        index: importedGlobalCount + index,
                        type: package.globalTypes[declaration.name] ?? .void)
                )
            })
        let functionReturnCounts = Dictionary(
            uniqueKeysWithValues: functions.compactMap {
                $0.receiver == nil && $0.name != "init"
                    ? ($0.name, $0.resultTypes.count)
                    : nil
            })
        let functionResultTypes = Dictionary(
            uniqueKeysWithValues: functions.compactMap { function -> (String, [GoType])? in
                guard function.receiver == nil, !function.resultTypes.isEmpty else {
                    return nil
                }
                return (function.name, function.resultTypes.map(compilerResolve))
            })
        let functionParameterTypes = Dictionary(
            uniqueKeysWithValues: functions.compactMap { function -> (String, [GoType])? in
                guard function.receiver == nil, function.name != "init" else {
                    return nil
                }
                return (function.name, function.parameters.map { compilerResolve($0.type) })
            })
        // Add imported package function metadata
        var functionReturnCountsMerged = functionReturnCounts
        var functionResultTypesMerged = functionResultTypes
        var functionParameterTypesMerged = functionParameterTypes
        for pkg in orderedPackages {
            let pkgName = pkg.name
            for (funcName, funcExport) in pkg.export.functions {
                let mangledName = pkgName + "." + funcName
                functionReturnCountsMerged[mangledName] = funcExport.results.count
                if !funcExport.results.isEmpty {
                    functionResultTypesMerged[mangledName] = funcExport.results
                }
                functionParameterTypesMerged[mangledName] = funcExport.parameters
            }
        }
        let methodInfos = Dictionary(
            uniqueKeysWithValues: functions.compactMap { function -> (String, MethodInfo)? in
                guard let receiver = function.receiver,
                    let identity = receiverIdentity(compilerResolve(receiver.type))
                else { return nil }
                let key = methodKey(
                    baseName: identity.baseName,
                    pointer: identity.isPointer,
                    method: function.name)
                return (
                    key,
                    MethodInfo(
                        functionName: key,
                        receiverType: compilerResolve(receiver.type),
                        resultTypes: function.resultTypes.map(compilerResolve))
                )
            })
        var initIndex = 0
        let compiledFunctionNames = functions.map { function -> String in
            if function.name == "init", function.receiver == nil {
                defer { initIndex += 1 }
                return "$init.\(initIndex)"
            }
            if let receiver = function.receiver,
                let identity = receiverIdentity(compilerResolve(receiver.type))
            {
                return methodKey(
                    baseName: identity.baseName,
                    pointer: identity.isPointer,
                    method: function.name)
            }
            return function.name
        }
        var loweredFunctions = try zip(functions, compiledFunctionNames).map { function, name in
            var lowerer = IRLowerer(
                functionReturnCounts: functionReturnCountsMerged,
                functionResultTypes: functionResultTypesMerged,
                functionParameterTypes: functionParameterTypesMerged,
                methodInfos: methodInfos,
                typeDefinitions: package.typeDefinitions,
                globalInfos: globalInfos,
                functionSymbolNames: [:])
            return try lowerer.lower(function, compiledName: name)
        }
        var initializers: [String] = []
        if !globals.isEmpty {
            var lowerer = IRLowerer(
                functionReturnCounts: functionReturnCountsMerged,
                functionResultTypes: functionResultTypesMerged,
                functionParameterTypes: functionParameterTypesMerged,
                methodInfos: methodInfos,
                typeDefinitions: package.typeDefinitions,
                globalInfos: globalInfos,
                functionSymbolNames: [:])
            loweredFunctions.insert(
                try lowerer.lowerGlobals(
                    try orderedGlobals(
                        globals,
                        functions: functions,
                        globalTypes: package.globalTypes,
                        typeDefinitions: package.typeDefinitions),
                    name: "$package.init"),
                at: 0)
            initializers.append("$package.init")
        }
        initializers.append(
            contentsOf: zip(functions, compiledFunctionNames).compactMap { function, name in
                function.name == "init" && function.receiver == nil ? name : nil
            })
        // Merge imported package functions and globals
        let totalGlobalCount = importedGlobalCount + globals.count
        let allInitializers = orderedPackages.flatMap(\.initializers) + initializers

        // Collect imported function names for linker symbol resolution
        var externalSymbols: Set<String> = []
        for pkg in orderedPackages {
            for function in pkg.functions {
                externalSymbols.insert(function.name)
            }
        }

        let program = try GoSinglePackageLinker.link(
            entryPoint: "main",
            initializers: allInitializers,
            globalCount: totalGlobalCount,
            functions: loweredFunctions,
            externalSymbols: externalSymbols)
        let executable = BytecodeEmitter.emit(program)

        // Append imported package bytecode functions to the executable
        var allBytecodeFunctions = executable.functions
        for pkg in orderedPackages {
            allBytecodeFunctions.append(contentsOf: pkg.functions)
        }
        return GoExecutable(
            entryPoint: executable.entryPoint,
            initializers: executable.initializers,
            globalCount: totalGlobalCount,
            functions: allBytecodeFunctions)
    }

    /// Compile a non-main package into a reusable compiled package. Exported
    /// functions (capitalized names) are prefixed with `packageName.` for the
    /// linker's flat namespace.
    public static func compilePackage(
        sources: [GoSourceFile],
        importedPackages: [String: GoCompiledPackage] = [:],
        globalOffset: Int = 0
    ) throws -> GoCompiledPackage {
        let files = try sources.map(GoParser.parse)
        let availablePackageExports = Dictionary(
            uniqueKeysWithValues: importedPackages.map { ($0.key, $0.value.export) })
        let package = try GoTypeChecker.check(
            files, availablePackages: availablePackageExports)
        let pkgName = package.name
        var functions = files.flatMap(\.functions)
        functions.append(contentsOf: runtimeLiteralFunctions(in: functions))
        let globals = files.flatMap(\.globalDeclarations)

        let globalInfos = Dictionary(
            uniqueKeysWithValues: globals.enumerated().map { index, declaration in
                (declaration.name, GlobalInfo(
                    index: globalOffset + index,
                    type: package.globalTypes[declaration.name] ?? .void))
            })
        var functionReturnCounts = Dictionary(
            uniqueKeysWithValues: functions.compactMap {
                $0.receiver == nil && $0.name != "init" ? ($0.name, $0.resultTypes.count) : nil
            })
        var functionResultTypes = Dictionary(
            uniqueKeysWithValues: functions.compactMap { f -> (String, [GoType])? in
                guard f.receiver == nil, !f.resultTypes.isEmpty else { return nil }
                return (f.name, f.resultTypes.map(compilerResolve))
            })
        var functionParameterTypes = Dictionary(
            uniqueKeysWithValues: functions.compactMap { f -> (String, [GoType])? in
                guard f.receiver == nil, f.name != "init" else { return nil }
                return (f.name, f.parameters.map { compilerResolve($0.type) })
            })
        for imported in importedPackages.values {
            for (name, export) in imported.export.functions {
                let symbol = imported.name + "." + name
                functionReturnCounts[symbol] = export.results.count
                functionResultTypes[symbol] = export.results
                functionParameterTypes[symbol] = export.parameters
            }
        }
        let methodInfos = Dictionary(
            uniqueKeysWithValues: functions.compactMap { function -> (String, MethodInfo)? in
                guard let receiver = function.receiver,
                    let identity = receiverIdentity(compilerResolve(receiver.type))
                else { return nil }
                let key = methodKey(baseName: identity.baseName, pointer: identity.isPointer, method: function.name)
                return (key, MethodInfo(functionName: key, receiverType: compilerResolve(receiver.type), resultTypes: function.resultTypes.map(compilerResolve)))
            })

        // Compile functions with mangled names: packageName.FunctionName
        var initIndex = 0
        let compiledFunctionNames = functions.map { function -> String in
            if function.name == "init", function.receiver == nil {
                defer { initIndex += 1 }
                return "$\(pkgName).init.\(initIndex)"
            }
            if let receiver = function.receiver,
                let identity = receiverIdentity(compilerResolve(receiver.type))
            {
                return methodKey(baseName: identity.baseName, pointer: identity.isPointer, method: function.name)
            }
            return pkgName + "." + function.name
        }
        let functionSymbolNames = Dictionary(
            uniqueKeysWithValues: functions.compactMap { function -> (String, String)? in
                guard function.receiver == nil, function.name != "init" else { return nil }
                return (function.name, pkgName + "." + function.name)
            })

        var loweredFunctions = try zip(functions, compiledFunctionNames).map { function, name in
            var lowerer = IRLowerer(
                functionReturnCounts: functionReturnCounts,
                functionResultTypes: functionResultTypes,
                functionParameterTypes: functionParameterTypes,
                methodInfos: methodInfos,
                typeDefinitions: package.typeDefinitions,
                globalInfos: globalInfos,
                functionSymbolNames: functionSymbolNames)
            return try lowerer.lower(function, compiledName: name)
        }

        var pkgInitializers: [String] = []
        if !globals.isEmpty {
            var lowerer = IRLowerer(
                functionReturnCounts: functionReturnCounts,
                functionResultTypes: functionResultTypes,
                functionParameterTypes: functionParameterTypes,
                methodInfos: methodInfos,
                typeDefinitions: package.typeDefinitions,
                globalInfos: globalInfos,
                functionSymbolNames: functionSymbolNames)
            let initName = "$\(pkgName).init"
            loweredFunctions.insert(
                try lowerer.lowerGlobals(
                    try orderedGlobals(globals, functions: functions, globalTypes: package.globalTypes, typeDefinitions: package.typeDefinitions),
                    name: initName),
                at: 0)
            pkgInitializers.append(initName)
        }
        pkgInitializers.append(
            contentsOf: zip(functions, compiledFunctionNames).compactMap { function, name in
                function.name == "init" && function.receiver == nil ? name : nil
            })

        // Build export table (only capitalized names)
        var exportedFunctions: [String: FunctionExport] = [:]
        for function in functions where function.receiver == nil && function.name != "init" {
            let firstName = function.name.first ?? Character("a")
            if firstName.isUppercase {
                exportedFunctions[function.name] = FunctionExport(
                    parameters: function.parameters.map { compilerResolve($0.type) },
                    results: function.resultTypes.map(compilerResolve))
            }
        }

        let bytecodeFunctions = loweredFunctions.map { function in
            BytecodeEmitter.emit(GoIRProgram(
                entryPoint: function.name,
                functions: [function])).functions[0]
        }

        return GoCompiledPackage(
            name: pkgName,
            export: GoPackageExport(
                name: pkgName,
                functions: exportedFunctions,
                types: package.typeDefinitions,
                globals: package.globalTypes),
            functions: bytecodeFunctions,
            globalCount: globals.count,
            initializers: pkgInitializers)
    }
}

private struct MethodInfo {
    let functionName: String
    let receiverType: GoType
    let resultTypes: [GoType]

    var returnCount: Int { resultTypes.count }
}

private struct LoweredBinding {
    let register: Int
    let type: GoType
}

private struct GlobalInfo {
    let index: Int
    let type: GoType
}

private func compilerResolve(_ expression: GoTypeExpression) -> GoType {
    switch expression {
    case .named(let name, _):
        switch name {
        case "int": return .int
        case "string": return .string
        case "bool": return .bool
        case "any": return .interface([])
        case "error": return compilerErrorType()
        case "testing.T": return .named("testing.T")
        default: return .named(name)
        }
    case .structure(let fields, _):
        return .structure(
            fields.map {
                GoStructFieldType(name: $0.name, type: compilerResolve($0.type))
            })
    case .pointer(let pointee, _):
        return .pointer(compilerResolve(pointee))
    case .array(let length, let element, _):
        return .array(length: length, element: compilerResolve(element))
    case .slice(let element, _):
        return .slice(compilerResolve(element))
    case .map(let key, let value, _):
        return .map(key: compilerResolve(key), value: compilerResolve(value))
    case .channel(let direction, let element, _):
        return .channel(direction: direction, element: compilerResolve(element))
    case .interface(let methods, _):
        return .interface(methods.map { method in
            GoInterfaceMethod(
                name: method.name,
                parameters: method.parameters.map(compilerResolve),
                results: method.results.map(compilerResolve))
        })
    }
}

private func compilerErrorType() -> GoType {
    .interface([GoInterfaceMethod(name: "Error", results: [.string])])
}

private func runtimeLiteralName(_ position: GoSourcePosition) -> String {
    "$literal.\(position.path).\(position.offset)"
}

private func runtimeLiteralFunctions(
    in functions: [GoFunctionDeclaration]
) -> [GoFunctionDeclaration] {
    var discovered: [GoFunctionDeclaration] = []
    var names: Set<String> = []

    func visit(_ block: GoBlock) {
        for statement in block.statements {
            switch statement {
            case .deferStatement(let expression, _), .goStatement(let expression, _):
                guard case .call(let callee, _, _) = expression,
                    case .functionLiteral(
                        let parameters, let resultNames, let resultTypes,
                        let body, let position) = callee
                else { continue }
                let name = runtimeLiteralName(position)
                if names.insert(name).inserted {
                    discovered.append(GoFunctionDeclaration(
                        name: name,
                        parameters: parameters,
                        resultNames: resultNames,
                        resultTypes: resultTypes,
                        body: body,
                        position: position))
                    visit(body)
                }
            case .ifStatement(_, let thenBlock, let elseBlock, _):
                visit(thenBlock)
                if let elseBlock { visit(elseBlock) }
            case .forStatement(_, _, _, let body, _),
                .forRangeStatement(_, _, _, let body, _):
                visit(body)
            case .switchStatement(_, let cases, _):
                for switchCase in cases { visit(switchCase.body) }
            case .selectStatement(let cases, _):
                for selectCase in cases { visit(selectCase.body) }
            default:
                continue
            }
        }
    }

    for function in functions { visit(function.body) }
    return discovered
}

private func receiverIdentity(_ type: GoType) -> (baseName: String, isPointer: Bool)? {
    switch type {
    case .named(let name): return (name, false)
    case .pointer(.named(let name)): return (name, true)
    default: return nil
    }
}

private func methodKey(baseName: String, pointer: Bool, method: String) -> String {
    "\(pointer ? "*" : "")\(baseName).\(method)"
}

private func orderedGlobals(
    _ declarations: [GoGlobalDeclaration],
    functions: [GoFunctionDeclaration],
    globalTypes: [String: GoType],
    typeDefinitions: [String: GoTypeDefinition]
) throws -> [GoGlobalDeclaration] {
    let byName = Dictionary(uniqueKeysWithValues: declarations.map { ($0.name, $0) })
    let analyzer = PackageDependencyAnalyzer(
        globalsByName: byName,
        globalTypes: globalTypes,
        typeDefinitions: typeDefinitions,
        functions: functions)
    var ordered: [GoGlobalDeclaration] = []
    var visiting: Set<String> = []
    var visited: Set<String> = []

    func visit(_ declaration: GoGlobalDeclaration) throws {
        if visited.contains(declaration.name) { return }
        guard visiting.insert(declaration.name).inserted else {
            throw GoDiagnostic(
                position: declaration.position,
                message: "initialization cycle for package variable \(declaration.name)")
        }
        if let expression = declaration.expression {
            for dependency in analyzer.dependencies(of: expression).sorted() {
                if let declaration = byName[dependency] { try visit(declaration) }
            }
        }
        visiting.remove(declaration.name)
        visited.insert(declaration.name)
        ordered.append(declaration)
    }

    for declaration in declarations { try visit(declaration) }
    return ordered
}

private struct PackageDependencyAnalyzer {
    let globalsByName: [String: GoGlobalDeclaration]
    let globalTypes: [String: GoType]
    let typeDefinitions: [String: GoTypeDefinition]
    let functionsByName: [String: GoFunctionDeclaration]
    let methodsByKey: [String: GoFunctionDeclaration]

    init(
        globalsByName: [String: GoGlobalDeclaration],
        globalTypes: [String: GoType],
        typeDefinitions: [String: GoTypeDefinition],
        functions: [GoFunctionDeclaration]
    ) {
        self.globalsByName = globalsByName
        self.globalTypes = globalTypes
        self.typeDefinitions = typeDefinitions
        functionsByName = Dictionary(
            uniqueKeysWithValues: functions.compactMap { function in
                function.receiver == nil && function.name != "init"
                    ? (function.name, function)
                    : nil
            })
        methodsByKey = Dictionary(
            uniqueKeysWithValues: functions.compactMap { function in
                guard let receiver = function.receiver,
                    let identity = receiverIdentity(compilerResolve(receiver.type))
                else { return nil }
                return (
                    methodKey(
                        baseName: identity.baseName,
                        pointer: identity.isPointer,
                        method: function.name),
                    function
                )
            })
    }

    func dependencies(of expression: GoExpression) -> Set<String> {
        var visitingFunctions: Set<String> = []
        return dependencies(
            of: expression,
            localTypes: [:],
            visitingFunctions: &visitingFunctions)
    }

    private func dependencies(
        of expression: GoExpression,
        localTypes: [String: GoType],
        visitingFunctions: inout Set<String>
    ) -> Set<String> {
        switch expression {
        case .identifier(let name, _):
            return localTypes[name] == nil && globalsByName[name] != nil ? [name] : []
        case .selector(let base, _, _):
            return dependencies(
                of: base,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions)
        case .typeAssertion(let base, _, _):
            return dependencies(
                of: base,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions)
        case .functionLiteral:
            return []
        case .compositeLiteral(_, let elements, _):
            return elements.reduce(into: []) { result, element in
                if let key = element.keyExpression {
                    result.formUnion(
                        dependencies(
                            of: key,
                            localTypes: localTypes,
                            visitingFunctions: &visitingFunctions))
                }
                result.formUnion(
                    dependencies(
                        of: element.value,
                        localTypes: localTypes,
                        visitingFunctions: &visitingFunctions))
            }
        case .index(let base, let index, _):
            return dependencies(
                of: base,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions
            ).union(
                dependencies(
                    of: index,
                    localTypes: localTypes,
                    visitingFunctions: &visitingFunctions))
        case .slicing(let base, let low, let high, _):
            var result = dependencies(
                of: base,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions)
            if let low {
                result.formUnion(
                    dependencies(
                        of: low,
                        localTypes: localTypes,
                        visitingFunctions: &visitingFunctions))
            }
            if let high {
                result.formUnion(
                    dependencies(
                        of: high,
                        localTypes: localTypes,
                        visitingFunctions: &visitingFunctions))
            }
            return result
        case .call(let callee, let arguments, _):
            var result = dependencies(
                of: callee,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions)
            for argument in arguments {
                result.formUnion(
                    dependencies(
                        of: argument,
                        localTypes: localTypes,
                        visitingFunctions: &visitingFunctions))
            }
            if case .identifier(let name, _) = callee,
                localTypes[name] == nil,
                let function = functionsByName[name]
            {
                result.formUnion(
                    dependencies(
                        of: function,
                        key: name,
                        visitingFunctions: &visitingFunctions))
            } else if case .selector(let base, let name, _) = callee,
                let key = resolvedMethodKey(for: base, name: name, localTypes: localTypes),
                let method = methodsByKey[key]
            {
                result.formUnion(
                    dependencies(
                        of: method,
                        key: key,
                        visitingFunctions: &visitingFunctions))
            }
            return result
        case .unary(_, let operand, _):
            return dependencies(
                of: operand,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions)
        case .binary(let left, _, let right, _):
            return dependencies(
                of: left,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions
            ).union(
                dependencies(
                    of: right,
                    localTypes: localTypes,
                    visitingFunctions: &visitingFunctions))
        case .integer, .string, .typeExpression:
            return []
        }
    }

    private func dependencies(
        of function: GoFunctionDeclaration,
        key: String,
        visitingFunctions: inout Set<String>
    ) -> Set<String> {
        guard visitingFunctions.insert(key).inserted else { return [] }
        defer { visitingFunctions.remove(key) }

        var localTypes = Dictionary(
            uniqueKeysWithValues: function.parameters.map {
                ($0.name, compilerResolve($0.type))
            })
        if let receiver = function.receiver {
            localTypes[receiver.name] = compilerResolve(receiver.type)
        }
        return dependencies(
            of: function.body,
            localTypes: localTypes,
            visitingFunctions: &visitingFunctions)
    }

    private func dependencies(
        of block: GoBlock,
        localTypes: [String: GoType],
        visitingFunctions: inout Set<String>
    ) -> Set<String> {
        var blockLocalTypes = localTypes
        var result: Set<String> = []
        for statement in block.statements {
            result.formUnion(
                dependencies(
                    of: statement,
                    localTypes: &blockLocalTypes,
                    visitingFunctions: &visitingFunctions))
        }
        return result
    }

    private func dependencies(
        of statement: GoStatement,
        localTypes: inout [String: GoType],
        visitingFunctions: inout Set<String>
    ) -> Set<String> {
        switch statement {
        case .declaration(let name, let explicitType, let expression, _, _):
            var result: Set<String> = []
            if let expression {
                result = dependencies(
                    of: expression,
                    localTypes: localTypes,
                    visitingFunctions: &visitingFunctions)
            }
            if let explicitType {
                localTypes[name] = compilerResolve(explicitType)
            } else if let expression,
                let inferredType = type(
                    of: expression,
                    localTypes: localTypes)
            {
                localTypes[name] = inferredType
            }
            return result
        case .assignment(let target, let expression, _):
            return dependencies(
                of: target,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions
            ).union(
                dependencies(
                    of: expression,
                    localTypes: localTypes,
                    visitingFunctions: &visitingFunctions))
        case .multiDeclaration(_, let expression, _):
            return dependencies(
                of: expression,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions)
        case .multiAssignment(let targets, let expression, _):
            var result = dependencies(
                of: expression,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions)
            for target in targets {
                result.formUnion(
                    dependencies(
                        of: target,
                        localTypes: localTypes,
                        visitingFunctions: &visitingFunctions))
            }
            return result
        case .increment(let target, _, _), .expression(let target):
            return dependencies(
                of: target,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions)
        case .returnValues(let expressions, _):
            return expressions.reduce(into: []) { result, expression in
                result.formUnion(
                    dependencies(
                        of: expression,
                        localTypes: localTypes,
                        visitingFunctions: &visitingFunctions))
            }
        case .breakStatement, .continueStatement:
            return []
        case .deferStatement(let expression, _), .goStatement(let expression, _):
            return dependencies(
                of: expression,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions)
        case .sendStatement(let channel, let value, _):
            return dependencies(
                of: channel,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions
            ).union(dependencies(
                of: value,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions))
        case .ifStatement(let condition, let thenBlock, let elseBlock, _):
            var result = dependencies(
                of: condition,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions)
            result.formUnion(
                dependencies(
                    of: thenBlock,
                    localTypes: localTypes,
                    visitingFunctions: &visitingFunctions))
            if let elseBlock {
                result.formUnion(
                    dependencies(
                        of: elseBlock,
                        localTypes: localTypes,
                        visitingFunctions: &visitingFunctions))
            }
            return result
        case .forStatement(let initializer, let condition, let post, let body, _):
            var loopLocalTypes = localTypes
            var result: Set<String> = []
            if let initializer {
                result.formUnion(
                    dependencies(
                        of: initializer,
                        localTypes: &loopLocalTypes,
                        visitingFunctions: &visitingFunctions))
            }
            if let condition {
                result.formUnion(
                    dependencies(
                        of: condition,
                        localTypes: loopLocalTypes,
                        visitingFunctions: &visitingFunctions))
            }
            result.formUnion(
                dependencies(
                    of: body,
                    localTypes: loopLocalTypes,
                    visitingFunctions: &visitingFunctions))
            if let post {
                result.formUnion(
                    dependencies(
                        of: post,
                        localTypes: &loopLocalTypes,
                        visitingFunctions: &visitingFunctions))
            }
            return result
        case .forRangeStatement(_, _, let collection, let body, _):
            var result = dependencies(
                of: collection,
                localTypes: localTypes,
                visitingFunctions: &visitingFunctions)
            result.formUnion(
                dependencies(
                    of: body,
                    localTypes: localTypes,
                    visitingFunctions: &visitingFunctions))
            return result
        case .switchStatement(let expression, let cases, _):
            var result: Set<String> = []
            if let expression {
                result.formUnion(
                    dependencies(
                        of: expression,
                        localTypes: localTypes,
                        visitingFunctions: &visitingFunctions))
            }
            for switchCase in cases {
                for expression in switchCase.expressions {
                    result.formUnion(
                        dependencies(
                            of: expression,
                            localTypes: localTypes,
                            visitingFunctions: &visitingFunctions))
                }
                result.formUnion(
                    dependencies(
                        of: switchCase.body,
                        localTypes: localTypes,
                        visitingFunctions: &visitingFunctions))
            }
            return result
        case .selectStatement(let cases, _):
            var result: Set<String> = []
            for selectCase in cases {
                if let communication = selectCase.communication {
                    var communicationTypes = localTypes
                    result.formUnion(dependencies(
                        of: communication,
                        localTypes: &communicationTypes,
                        visitingFunctions: &visitingFunctions))
                }
                result.formUnion(dependencies(
                    of: selectCase.body,
                    localTypes: localTypes,
                    visitingFunctions: &visitingFunctions))
            }
            return result
        }
    }

    private func resolvedMethodKey(
        for base: GoExpression,
        name: String,
        localTypes: [String: GoType]
    ) -> String? {
        guard let baseType = type(of: base, localTypes: localTypes) else { return nil }
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
        return candidates.first(where: { methodsByKey[$0] != nil })
    }

    private func type(
        of expression: GoExpression,
        localTypes: [String: GoType]
    ) -> GoType? {
        switch expression {
        case .integer:
            return .int
        case .string:
            return .string
        case .identifier(let name, _):
            if name == "true" || name == "false" { return .bool }
            if name == "nil" { return .nilType }
            return localTypes[name] ?? globalTypes[name]
        case .selector(let base, let name, _):
            if case .identifier("os", _) = base, name == "Args" {
                return .slice(.string)
            }
            guard let baseType = type(of: base, localTypes: localTypes) else { return nil }
            return fieldType(name: name, in: baseType)
        case .typeAssertion(_, let assertedType, _):
            return compilerResolve(assertedType)
        case .functionLiteral(let parameters, _, let resultTypes, _, _):
            return .function(
                parameters: parameters.map { compilerResolve($0.type) },
                results: resultTypes.map(compilerResolve))
        case .compositeLiteral(let expression, _, _), .typeExpression(let expression, _):
            return compilerResolve(expression)
        case .index(let base, _, _):
            guard let baseType = type(of: base, localTypes: localTypes) else { return nil }
            switch underlying(baseType) {
            case .array(_, let element), .slice(let element): return element
            case .string: return .int
            default: return nil
            }
        case .slicing(let base, _, _, _):
            guard let baseType = type(of: base, localTypes: localTypes) else { return nil }
            switch underlying(baseType) {
            case .array(_, let element): return .slice(element)
            case .slice, .string: return baseType
            default: return nil
            }
        case .call(let callee, let arguments, _):
            if case .identifier(let name, _) = callee {
                switch name {
                case "len", "cap": return .int
                case "append":
                    return arguments.first.flatMap { type(of: $0, localTypes: localTypes) }
                case "make":
                    guard let first = arguments.first,
                        case .typeExpression(let expression, _) = first
                    else { return nil }
                    return compilerResolve(expression)
                default:
                    return functionsByName[name]?.resultTypes.first.map(compilerResolve)
                }
            }
            if case .selector(let base, let name, _) = callee,
                let key = resolvedMethodKey(for: base, name: name, localTypes: localTypes)
            {
                return methodsByKey[key]?.resultTypes.first.map(compilerResolve)
            }
            return nil
        case .unary(let operation, let operand, _):
            guard let operandType = type(of: operand, localTypes: localTypes) else { return nil }
            switch operation {
            case .address: return .pointer(operandType)
            case .dereference:
                guard case .pointer(let pointee) = underlying(operandType) else { return nil }
                return pointee
            case .not: return .bool
            case .plus, .minus: return operandType
            case .receive:
                guard case .channel(_, let element) = underlying(operandType) else { return nil }
                return element
            }
        case .binary(let left, let operation, _, _):
            switch operation {
            case .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual, .logicalAnd,
                .logicalOr:
                return .bool
            default:
                return type(of: left, localTypes: localTypes)
            }
        }
    }

    private func fieldType(name: String, in type: GoType) -> GoType? {
        let resolved = underlying(type)
        if case .pointer(let pointee) = resolved {
            return fieldType(name: name, in: pointee)
        }
        guard case .structure(let fields) = resolved else { return nil }
        return fields.first(where: { $0.name == name })?.type
    }

    private func underlying(_ type: GoType) -> GoType {
        var current = type
        var visited: Set<String> = []
        while case .named(let name) = current,
            visited.insert(name).inserted,
            let definition = typeDefinitions[name]
        {
            current = definition.underlying
        }
        return current
    }
}

private struct IRLowerer {
    let functionReturnCounts: [String: Int]
    let functionResultTypes: [String: [GoType]]
    let functionParameterTypes: [String: [GoType]]
    let methodInfos: [String: MethodInfo]
    let typeDefinitions: [String: GoTypeDefinition]
    let globalInfos: [String: GlobalInfo]
    let functionSymbolNames: [String: String]
    var operations: [GoIROperation] = []
    var scopes: [[String: LoweredBinding]] = [[:]]
    var nextRegister = 0
    var nextLabel = 0
    var breakLabels: [Int] = []
    var continueLabels: [Int] = []
    var testAbortLabels: [Int] = []
    var resultRegisters: [Int] = []

    mutating func lower(
        _ function: GoFunctionDeclaration,
        compiledName: String
    ) throws -> GoIRFunction {
        if let receiver = function.receiver {
            scopes[0][receiver.name] = LoweredBinding(
                register: allocateRegister(),
                type: resolve(receiver.type))
        }
        for parameter in function.parameters {
            scopes[0][parameter.name] = LoweredBinding(
                register: allocateRegister(),
                type: resolve(parameter.type))
        }
        for (name, resultType) in zip(function.resultNames, function.resultTypes) {
            let register = allocateRegister()
            let type = resolve(resultType)
            let zero = try zeroValue(for: type, position: resultType.position)
            operations.append(.copy(destination: register, source: zero))
            if let name {
                scopes[0][name] = LoweredBinding(register: register, type: type)
            }
            resultRegisters.append(register)
        }
        try lower(function.body, createsScope: false)
        if function.resultTypes.isEmpty, operations.last != .return {
            operations.append(.return)
        }
        return GoIRFunction(
            name: compiledName,
            parameterCount: function.parameters.count + (function.receiver == nil ? 0 : 1),
            returnCount: function.resultTypes.count,
            registerCount: nextRegister,
            operations: operations)
    }

    mutating func lowerGlobals(
        _ declarations: [GoGlobalDeclaration],
        name: String
    ) throws -> GoIRFunction {
        for declaration in declarations {
            guard let global = globalInfos[declaration.name] else {
                throw GoDiagnostic(
                    position: declaration.position,
                    message: "undefined: \(declaration.name)")
            }
            let value: Int
            if let expression = declaration.expression {
                value = try lower(expression)
            } else {
                value = try zeroValue(for: global.type, position: declaration.position)
            }
            operations.append(.storeGlobal(index: global.index, source: value))
        }
        operations.append(.return)
        return GoIRFunction(
            name: name,
            registerCount: nextRegister,
            operations: operations)
    }

    mutating func lower(_ block: GoBlock, createsScope: Bool = true) throws {
        if createsScope { scopes.append([:]) }
        defer { if createsScope { scopes.removeLast() } }
        for statement in block.statements { try lower(statement) }
    }

    mutating func lower(_ statement: GoStatement) throws {
        switch statement {
        case .declaration(let name, let explicitType, let expression, _, let position):
            let variable = allocateRegister()
            if let expression {
                let value = try lower(expression)
                operations.append(.copy(destination: variable, source: value))
            } else if let explicitType {
                let value = try zeroValue(
                    for: resolve(explicitType),
                    position: position)
                operations.append(.copy(destination: variable, source: value))
            } else {
                throw GoDiagnostic(position: position, message: "missing variable type or initialization")
            }
            let variableType = try explicitType.map(resolve) ?? expression.map { try type(of: $0) }
            guard let variableType else {
                throw GoDiagnostic(position: position, message: "missing variable type or initialization")
            }
            scopes[scopes.count - 1][name] = LoweredBinding(
                register: variable,
                type: variableType)

        case .assignment(let target, let expression, _):
            let value = try lower(expression)
            try store(value, to: target)

        case .multiDeclaration(let names, let expression, let position):
            if case .unary(.receive, let channel, _) = expression,
                case .channel(_, let elementType) = underlying(try type(of: channel))
            {
                guard names.count == 2 else {
                    throw GoDiagnostic(position: position, message: "channel receive returns two values")
                }
                let value = allocateRegister()
                let ok = allocateRegister()
                let zero = try zeroValue(for: elementType, position: expression.position)
                operations.append(.receiveChannel(
                    destination: value,
                    okDestination: ok,
                    channel: try lower(channel),
                    zero: zero))
                let registers = [value, ok]
                let types = [elementType, GoType.bool]
                for index in names.indices {
                    let name = names[index]
                    let variable = allocateRegister()
                    operations.append(.copy(destination: variable, source: registers[index]))
                    scopes[scopes.count - 1][name] = LoweredBinding(
                        register: variable, type: types[index])
                }
                return
            }
            if case .index(let base, let key, _) = expression,
                case .map(_, let valueType) = underlying(try type(of: base))
            {
                guard names.count == 2 else {
                    throw GoDiagnostic(position: position, message: "map index returns two values")
                }
                let value = allocateRegister()
                let ok = allocateRegister()
                let zero = try zeroValue(for: valueType, position: expression.position)
                operations.append(.getMapIndex(
                    destination: value, okDestination: ok,
                    base: try lower(base), key: try lower(key), zero: zero))
                let registers = [value, ok]
                let types: [GoType] = [valueType, .bool]
                for index in names.indices {
                    let variable = allocateRegister()
                    operations.append(.copy(destination: variable, source: registers[index]))
                    scopes[scopes.count - 1][names[index]] = LoweredBinding(
                        register: variable, type: types[index])
                }
                return
            }
            if case .typeAssertion(let base, let assertedType, _) = expression {
                guard names.count == 2 else {
                    throw GoDiagnostic(position: position, message: "type assertion returns two values")
                }
                let type = resolve(assertedType)
                let value = allocateRegister()
                let ok = allocateRegister()
                let zero = try zeroValue(for: type, position: assertedType.position)
                guard let targetName = concreteTypeName(type) else {
                    throw GoDiagnostic(position: position, message: "unsupported asserted type")
                }
                operations.append(.typeAssert(
                    destination: value, okDestination: ok, source: try lower(base),
                    targetName: targetName, zero: zero))
                let registers = [value, ok]
                let bindingTypes: [GoType] = [type, .bool]
                for index in names.indices {
                    let name = names[index]
                    let variable = allocateRegister()
                    operations.append(.copy(destination: variable, source: registers[index]))
                    scopes[scopes.count - 1][name] = LoweredBinding(
                        register: variable, type: bindingTypes[index])
                }
                return
            }
            guard case .call(let callee, let arguments, _) = expression else {
                throw GoDiagnostic(position: position, message: "multi-value requires function call")
            }
            guard let results = try lowerMultiReturnCall(callee: callee, arguments: arguments) else {
                throw GoDiagnostic(position: position, message: "function does not return multiple values")
            }
            let resultTypes = multiReturnTypes(callee: callee)
            for (index, (name, register)) in zip(names, results).enumerated() {
                let variable = allocateRegister()
                operations.append(.copy(destination: variable, source: register))
                let bindingType = index < resultTypes.count ? resultTypes[index] : .void
                scopes[scopes.count - 1][name] = LoweredBinding(
                    register: variable,
                    type: bindingType)
            }

        case .multiAssignment(let targets, let expression, let position):
            if case .unary(.receive, let channel, _) = expression,
                case .channel(_, let elementType) = underlying(try type(of: channel))
            {
                guard targets.count == 2 else {
                    throw GoDiagnostic(position: position, message: "channel receive returns two values")
                }
                let value = allocateRegister()
                let ok = allocateRegister()
                let zero = try zeroValue(for: elementType, position: expression.position)
                operations.append(.receiveChannel(
                    destination: value,
                    okDestination: ok,
                    channel: try lower(channel),
                    zero: zero))
                for (target, register) in zip(targets, [value, ok]) {
                    try store(register, to: target)
                }
                return
            }
            if case .index(let base, let key, _) = expression,
                case .map(_, let valueType) = underlying(try type(of: base))
            {
                guard targets.count == 2 else {
                    throw GoDiagnostic(position: position, message: "map index returns two values")
                }
                let value = allocateRegister()
                let ok = allocateRegister()
                let zero = try zeroValue(for: valueType, position: expression.position)
                operations.append(.getMapIndex(
                    destination: value, okDestination: ok,
                    base: try lower(base), key: try lower(key), zero: zero))
                for (target, register) in zip(targets, [value, ok]) {
                    try store(register, to: target)
                }
                return
            }
            if case .typeAssertion(let base, let assertedType, _) = expression {
                guard targets.count == 2 else {
                    throw GoDiagnostic(position: position, message: "type assertion returns two values")
                }
                let type = resolve(assertedType)
                let value = allocateRegister()
                let ok = allocateRegister()
                let zero = try zeroValue(for: type, position: assertedType.position)
                guard let targetName = concreteTypeName(type) else {
                    throw GoDiagnostic(position: position, message: "unsupported asserted type")
                }
                operations.append(.typeAssert(
                    destination: value, okDestination: ok, source: try lower(base),
                    targetName: targetName, zero: zero))
                for (target, register) in zip(targets, [value, ok]) {
                    try store(register, to: target)
                }
                return
            }
            guard case .call(let callee, let arguments, _) = expression else {
                throw GoDiagnostic(position: position, message: "multi-value requires function call")
            }
            guard let results = try lowerMultiReturnCall(callee: callee, arguments: arguments) else {
                throw GoDiagnostic(position: position, message: "function does not return multiple values")
            }
            for (target, register) in zip(targets, results) {
                try store(register, to: target)
            }

        case .increment(let target, let incrementOperator, _):
            let current = try lower(target)
            let one = constant(.int(1))
            let result = allocateRegister()
            operations.append(
                .binary(
                    destination: result,
                    operator: incrementOperator == .increment ? .add : .subtract,
                    left: current,
                    right: one))
            try store(result, to: target)

        case .expression(let expression):
            try lowerExpressionStatement(expression)

        case .returnValues(let values, _):
            if values.isEmpty {
                if resultRegisters.isEmpty {
                    operations.append(.return)
                } else {
                    operations.append(.returnValues(sources: resultRegisters))
                }
            } else {
                let sources = try values.map { try lower($0) }
                operations.append(.returnValues(sources: sources))
            }

        case .breakStatement(let position):
            guard let target = breakLabels.last else {
                throw GoDiagnostic(position: position, message: "break is not in a loop or switch")
            }
            operations.append(.jump(target: target))

        case .continueStatement(let position):
            guard let target = continueLabels.last else {
                throw GoDiagnostic(position: position, message: "continue is not in a loop")
            }
            operations.append(.jump(target: target))

        case .deferStatement(let expression, let position):
            guard case .call(let callee, let arguments, _) = expression else {
                throw GoDiagnostic(position: position, message: "defer requires function call")
            }
            if case .identifier(let functionName, _) = callee {
                let registers = try arguments.map { try lower($0) }
                operations.append(.deferCall(
                    function: functionSymbolNames[functionName] ?? functionName,
                    arguments: registers))
            } else if case .functionLiteral(_, _, _, _, let literalPosition) = callee {
                let name = runtimeLiteralName(literalPosition)
                let registers = try arguments.map { try lower($0) }
                operations.append(.deferCall(
                    function: functionSymbolNames[name] ?? name,
                    arguments: registers))
            } else if case .selector(let base, let member, _) = callee,
                case .identifier(let packageName, _) = base,
                lookup(packageName) == nil,
                globalInfos[packageName] == nil
            {
                let registers = try arguments.map { try lower($0) }
                let resolvedName = "\(packageName).\(member)"
                operations.append(.deferCall(function: resolvedName, arguments: registers))
            } else if case .selector(let base, let member, _) = callee,
                let receiverType = try? type(of: base),
                let receiverName = syncReceiverName(receiverType)
            {
                var receiver = try lower(base)
                if case .pointer = receiverType {
                    let dereferenced = allocateRegister()
                    operations.append(.dereference(destination: dereferenced, pointer: receiver))
                    receiver = dereferenced
                }
                operations.append(.deferCall(
                    function: "$\(receiverName).\(member)",
                    arguments: [receiver] + (try arguments.map { try lower($0) })))
            } else if case .selector(let base, let member, _) = callee,
                let info = try methodInfo(base: base, name: member)
            {
                let baseType = try type(of: base)
                let receiver: Int
                if case .pointer = info.receiverType {
                    receiver = if case .pointer = baseType {
                        try lower(base)
                    } else {
                        try lowerAddress(of: base)
                    }
                } else if case .pointer = baseType {
                    let pointer = try lower(base)
                    let value = allocateRegister()
                    operations.append(.dereference(destination: value, pointer: pointer))
                    receiver = value
                } else {
                    receiver = try lower(base)
                }
                let registers = [receiver] + (try arguments.map { try lower($0) })
                operations.append(.deferCall(
                    function: info.functionName,
                    arguments: registers))
            } else {
                throw GoDiagnostic(position: position, message: "unsupported defer expression")
            }

        case .goStatement(let expression, let position):
            guard case .call(let callee, let arguments, _) = expression else {
                throw GoDiagnostic(position: position, message: "go requires function call")
            }
            if case .identifier(let functionName, _) = callee {
                operations.append(.spawn(
                    function: functionSymbolNames[functionName] ?? functionName,
                    arguments: try arguments.map { try lower($0) }))
            } else if case .functionLiteral(_, _, _, _, let literalPosition) = callee {
                let name = runtimeLiteralName(literalPosition)
                operations.append(.spawn(
                    function: functionSymbolNames[name] ?? name,
                    arguments: try arguments.map { try lower($0) }))
            } else if case .selector(let base, let member, _) = callee,
                case .identifier(let packageName, _) = base,
                lookup(packageName) == nil,
                globalInfos[packageName] == nil
            {
                operations.append(.spawn(
                    function: "\(packageName).\(member)",
                    arguments: try arguments.map { try lower($0) }))
            } else if case .selector(let base, let member, _) = callee,
                let receiverType = try? type(of: base),
                let receiverName = syncReceiverName(receiverType)
            {
                var receiver = try lower(base)
                if case .pointer = receiverType {
                    let dereferenced = allocateRegister()
                    operations.append(.dereference(destination: dereferenced, pointer: receiver))
                    receiver = dereferenced
                }
                operations.append(.spawn(
                    function: "$\(receiverName).\(member)",
                    arguments: [receiver] + (try arguments.map { try lower($0) })))
            } else if case .selector(let base, let member, _) = callee,
                let info = try methodInfo(base: base, name: member)
            {
                let baseType = try type(of: base)
                let receiver: Int
                if case .pointer = info.receiverType {
                    receiver = if case .pointer = baseType {
                        try lower(base)
                    } else {
                        try lowerAddress(of: base)
                    }
                } else if case .pointer = baseType {
                    let pointer = try lower(base)
                    let value = allocateRegister()
                    operations.append(.dereference(destination: value, pointer: pointer))
                    receiver = value
                } else {
                    receiver = try lower(base)
                }
                operations.append(.spawn(
                    function: info.functionName,
                    arguments: [receiver] + (try arguments.map { try lower($0) })))
            } else {
                throw GoDiagnostic(position: position, message: "unsupported go expression")
            }

        case .sendStatement(let channel, let value, _):
            operations.append(.sendChannel(
                channel: try lower(channel),
                value: try lower(value)))

        case .ifStatement(let condition, let thenBlock, let elseBlock, _):
            let falseLabel = allocateLabel()
            let conditionRegister = try lower(condition)
            operations.append(.jumpIfFalse(condition: conditionRegister, target: falseLabel))
            try lower(thenBlock)
            if let elseBlock {
                let endLabel = allocateLabel()
                operations.append(.jump(target: endLabel))
                operations.append(.label(falseLabel))
                try lower(elseBlock)
                operations.append(.label(endLabel))
            } else {
                operations.append(.label(falseLabel))
            }

        case .forStatement(let initializer, let condition, let post, let body, _):
            scopes.append([:])
            defer { scopes.removeLast() }
            if let initializer { try lower(initializer) }
            let conditionLabel = allocateLabel()
            let postLabel = allocateLabel()
            let endLabel = allocateLabel()
            operations.append(.label(conditionLabel))
            if let condition {
                let conditionRegister = try lower(condition)
                operations.append(.jumpIfFalse(condition: conditionRegister, target: endLabel))
            }
            breakLabels.append(endLabel)
            continueLabels.append(postLabel)
            try lower(body)
            breakLabels.removeLast()
            continueLabels.removeLast()
            operations.append(.label(postLabel))
            if let post { try lower(post) }
            operations.append(.jump(target: conditionLabel))
            operations.append(.label(endLabel))

        case .forRangeStatement(let indexName, let valueName, let collection, let body, _):
            scopes.append([:])
            defer { scopes.removeLast() }

            // Evaluate the collection once. The VM snapshots its keys so map
            // iteration and UTF-8 string offsets use Go-compatible values.
            let collectionRegister = try lower(collection)
            let collectionType = underlying(try type(of: collection))
            if case .channel(_, let elementType) = collectionType {
                let receiveLabel = allocateLabel()
                let endLabel = allocateLabel()
                operations.append(.label(receiveLabel))
                let received = allocateRegister()
                let ok = allocateRegister()
                let zero = try zeroValue(for: elementType, position: collection.position)
                operations.append(.receiveChannel(
                    destination: received,
                    okDestination: ok,
                    channel: collectionRegister,
                    zero: zero))
                operations.append(.jumpIfFalse(condition: ok, target: endLabel))
                if let indexName {
                    scopes[scopes.count - 1][indexName] = LoweredBinding(
                        register: received,
                        type: elementType)
                }
                breakLabels.append(endLabel)
                continueLabels.append(receiveLabel)
                try lower(body)
                breakLabels.removeLast()
                continueLabels.removeLast()
                operations.append(.jump(target: receiveLabel))
                operations.append(.label(endLabel))
                return
            }
            let keysRegister = allocateRegister()
            operations.append(.rangeKeys(destination: keysRegister, base: collectionRegister))
            let lengthRegister = allocateRegister()
            operations.append(.length(destination: lengthRegister, base: keysRegister))

            // Create the index variable (always int, always starts at 0)
            let indexRegister = allocateRegister()
            let zero = constant(.int(0))
            operations.append(.copy(destination: indexRegister, source: zero))

            // Loop structure: conditionLabel → body → postLabel → jump conditionLabel → endLabel
            let conditionLabel = allocateLabel()
            let postLabel = allocateLabel()
            let endLabel = allocateLabel()

            operations.append(.label(conditionLabel))
            // Condition: index < length
            let conditionRegister = allocateRegister()
            operations.append(
                .binary(
                    destination: conditionRegister,
                    operator: .less,
                    left: indexRegister,
                    right: lengthRegister))
            operations.append(.jumpIfFalse(condition: conditionRegister, target: endLabel))

            let keyRegister = allocateRegister()
            operations.append(.getIndex(
                destination: keyRegister, base: keysRegister, index: indexRegister))
            if let indexName {
                let keyType: GoType
                if case .map(let mapKey, _) = collectionType { keyType = mapKey }
                else { keyType = .int }
                scopes[scopes.count - 1][indexName] = LoweredBinding(
                    register: keyRegister, type: keyType)
            }

            if let valueName {
                let valueRegister = allocateRegister()
                let elementType: GoType
                switch collectionType {
                case .array(_, let element), .slice(let element): elementType = element
                case .map(_, let value): elementType = value
                case .string: elementType = .int
                default: elementType = .void
                }
                let zero = try zeroValue(for: elementType, position: collection.position)
                operations.append(.rangeValue(
                    destination: valueRegister,
                    base: collectionRegister,
                    key: keyRegister,
                    zero: zero))
                scopes[scopes.count - 1][valueName] = LoweredBinding(
                    register: valueRegister, type: elementType)
            }

            breakLabels.append(endLabel)
            continueLabels.append(postLabel)
            try lower(body)
            breakLabels.removeLast()
            continueLabels.removeLast()

            // Post: index++
            operations.append(.label(postLabel))
            let one = constant(.int(1))
            let incremented = allocateRegister()
            operations.append(
                .binary(
                    destination: incremented,
                    operator: .add,
                    left: indexRegister,
                    right: one))
            operations.append(.copy(destination: indexRegister, source: incremented))
            operations.append(.jump(target: conditionLabel))
            operations.append(.label(endLabel))

        case .switchStatement(let expression, let cases, _):
            let switchRegister = try expression.map { try lower($0) } ?? constant(.bool(true))
            let endLabel = allocateLabel()
            let caseLabels = cases.map { _ in allocateLabel() }
            let defaultIndex = cases.firstIndex(where: \.isDefault)

            for (index, switchCase) in cases.enumerated() where !switchCase.isDefault {
                for caseExpression in switchCase.expressions {
                    let caseRegister = try lower(caseExpression)
                    let comparison = allocateRegister()
                    operations.append(
                        .binary(
                            destination: comparison,
                            operator: .equal,
                            left: switchRegister,
                            right: caseRegister))
                    operations.append(.jumpIfTrue(condition: comparison, target: caseLabels[index]))
                }
            }
            operations.append(.jump(target: defaultIndex.map { caseLabels[$0] } ?? endLabel))

            breakLabels.append(endLabel)
            for (index, switchCase) in cases.enumerated() {
                operations.append(.label(caseLabels[index]))
                try lower(switchCase.body)
                operations.append(.jump(target: endLabel))
            }
            breakLabels.removeLast()
            operations.append(.label(endLabel))

        case .selectStatement(let cases, _):
            let endLabel = allocateLabel()
            let caseLabels = cases.map { _ in allocateLabel() }
            var loweredCases: [GoIRSelectCase] = []
            var receiveRegisters: [[Int]] = Array(repeating: [], count: cases.count)
            var receiveTypes: [[GoType]] = Array(repeating: [], count: cases.count)
            var defaultTarget: Int?

            // Go evaluates every channel operand and send RHS exactly once, in
            // source order, before it decides which communication can proceed.
            for (index, selectCase) in cases.enumerated() {
                guard let communication = selectCase.communication else {
                    defaultTarget = caseLabels[index]
                    continue
                }
                switch communication {
                case .sendStatement(let channel, let value, _):
                    loweredCases.append(.send(
                        channel: try lower(channel),
                        value: try lower(value),
                        target: caseLabels[index]))

                case .expression(.unary(.receive, let channel, let position)):
                    guard case .channel(_, let elementType) = underlying(try type(of: channel)) else {
                        throw GoDiagnostic(position: position, message: "receive from non-channel")
                    }
                    let zero = try zeroValue(for: elementType, position: position)
                    loweredCases.append(.receive(
                        channel: try lower(channel), destination: nil, okDestination: nil,
                        zero: zero, target: caseLabels[index]))

                case .declaration(let name, _, .some(.unary(.receive, let channel, let position)), _, _):
                    guard case .channel(_, let elementType) = underlying(try type(of: channel)) else {
                        throw GoDiagnostic(position: position, message: "receive from non-channel")
                    }
                    let destination = allocateRegister()
                    let zero = try zeroValue(for: elementType, position: position)
                    receiveRegisters[index] = [destination]
                    receiveTypes[index] = [elementType]
                    _ = name
                    loweredCases.append(.receive(
                        channel: try lower(channel), destination: destination, okDestination: nil,
                        zero: zero, target: caseLabels[index]))

                case .multiDeclaration(_, .unary(.receive, let channel, let position), _):
                    guard case .channel(_, let elementType) = underlying(try type(of: channel)) else {
                        throw GoDiagnostic(position: position, message: "receive from non-channel")
                    }
                    let destination = allocateRegister()
                    let ok = allocateRegister()
                    let zero = try zeroValue(for: elementType, position: position)
                    receiveRegisters[index] = [destination, ok]
                    receiveTypes[index] = [elementType, .bool]
                    loweredCases.append(.receive(
                        channel: try lower(channel), destination: destination, okDestination: ok,
                        zero: zero, target: caseLabels[index]))

                case .assignment(_, .unary(.receive, let channel, let position), _):
                    guard case .channel(_, let elementType) = underlying(try type(of: channel)) else {
                        throw GoDiagnostic(position: position, message: "receive from non-channel")
                    }
                    let destination = allocateRegister()
                    let zero = try zeroValue(for: elementType, position: position)
                    receiveRegisters[index] = [destination]
                    receiveTypes[index] = [elementType]
                    loweredCases.append(.receive(
                        channel: try lower(channel), destination: destination, okDestination: nil,
                        zero: zero, target: caseLabels[index]))

                case .multiAssignment(_, .unary(.receive, let channel, let position), _):
                    guard case .channel(_, let elementType) = underlying(try type(of: channel)) else {
                        throw GoDiagnostic(position: position, message: "receive from non-channel")
                    }
                    let destination = allocateRegister()
                    let ok = allocateRegister()
                    let zero = try zeroValue(for: elementType, position: position)
                    receiveRegisters[index] = [destination, ok]
                    receiveTypes[index] = [elementType, .bool]
                    loweredCases.append(.receive(
                        channel: try lower(channel), destination: destination, okDestination: ok,
                        zero: zero, target: caseLabels[index]))

                default:
                    throw GoDiagnostic(
                        position: selectCase.position,
                        message: "select case must be send or receive")
                }
            }

            operations.append(.select(cases: loweredCases, defaultTarget: defaultTarget))
            breakLabels.append(endLabel)
            for (index, selectCase) in cases.enumerated() {
                operations.append(.label(caseLabels[index]))
                scopes.append([:])
                switch selectCase.communication {
                case .declaration(let name, _, _, _, _):
                    if let register = receiveRegisters[index].first,
                        let type = receiveTypes[index].first
                    {
                        scopes[scopes.count - 1][name] = LoweredBinding(register: register, type: type)
                    }
                case .multiDeclaration(let names, _, _):
                    for (name, pair) in zip(names, zip(receiveRegisters[index], receiveTypes[index])) {
                        scopes[scopes.count - 1][name] = LoweredBinding(
                            register: pair.0, type: pair.1)
                    }
                case .assignment(let target, _, _):
                    if let register = receiveRegisters[index].first {
                        try store(register, to: target)
                    }
                case .multiAssignment(let targets, _, _):
                    for (target, register) in zip(targets, receiveRegisters[index]) {
                        try store(register, to: target)
                    }
                default:
                    break
                }
                try lower(selectCase.body, createsScope: false)
                scopes.removeLast()
                operations.append(.jump(target: endLabel))
            }
            breakLabels.removeLast()
            operations.append(.label(endLabel))
        }
    }

    mutating func lowerExpressionStatement(_ expression: GoExpression) throws {
        if case .call(let callee, let arguments, _) = expression {
            _ = try lowerCall(callee: callee, arguments: arguments)
            return
        }
        if case .unary(.receive, _, _) = expression {
            _ = try lower(expression)
            return
        }
        throw GoDiagnostic(position: expression.position, message: "unsupported expression statement")
    }

    mutating func lowerCall(
        callee: GoExpression,
        arguments: [GoExpression]
    ) throws -> Int? {
        if case .identifier(let functionName, _) = callee {
            if functionName == "len" || functionName == "cap" {
                guard let argument = arguments.first else { return nil }
                let destination = allocateRegister()
                let base = try lower(argument)
                if functionName == "len" {
                    operations.append(.length(destination: destination, base: base))
                } else {
                    operations.append(.capacity(destination: destination, base: base))
                }
                return destination
            }
            if functionName == "panic" {
                guard let argument = arguments.first else {
                    let nilValue = constant(.string("nil"))
                    operations.append(.panic(source: nilValue))
                    return nil
                }
                let source = try lower(argument)
                operations.append(.panic(source: source))
                return nil
            }
            if functionName == "recover" {
                guard arguments.isEmpty else { return nil }
                let destination = allocateRegister()
                operations.append(.recover(destination: destination))
                return destination
            }
            if functionName == "delete" {
                guard arguments.count == 2 else { return nil }
                let base = try lower(arguments[0])
                let key = try lower(arguments[1])
                let destination = allocateRegister()
                operations.append(.deleteMap(destination: destination, base: base, key: key))
                // Store updated map back to the source variable
                try store(destination, to: arguments[0])
                return nil
            }
            if functionName == "close" {
                guard arguments.count == 1 else { return nil }
                operations.append(.closeChannel(channel: try lower(arguments[0])))
                return nil
            }
            if functionName == "append" {
                guard let first = arguments.first,
                    case .slice(let elementType) = underlying(try type(of: first))
                else { return nil }
                var slice = try lower(first)
                let zero = try zeroValue(for: elementType, position: first.position)
                for argument in arguments.dropFirst() {
                    let destination = allocateRegister()
                    operations.append(
                        .append(
                            destination: destination,
                            slice: slice,
                            value: try lower(argument),
                            zero: zero))
                    slice = destination
                }
                return slice
            }
            if functionName == "make",
                arguments.count >= 1,
                case .typeExpression(let typeExpression, _) = arguments[0]
            {
                let madeType = resolve(typeExpression)
                switch underlying(madeType) {
                case .slice(let elementType):
                    guard arguments.count >= 2 else { break }
                    let length = try lower(arguments[1])
                    let capacity = arguments.count > 2 ? try lower(arguments[2]) : length
                    let zero = try zeroValue(for: elementType, position: arguments[0].position)
                    let destination = allocateRegister()
                    operations.append(
                        .allocateSlice(
                            destination: destination,
                            zero: zero,
                            length: length,
                            capacity: capacity))
                    return destination
                case .map:
                    let destination = allocateRegister()
                    operations.append(.makeMap(destination: destination, keys: [], values: []))
                    return destination
                case .channel(_, let elementType):
                    let capacity = arguments.count > 1
                        ? try lower(arguments[1])
                        : constant(.int(0))
                    let zero = try zeroValue(
                        for: elementType,
                        position: arguments[0].position)
                    let destination = allocateRegister()
                    operations.append(.makeChannel(
                        destination: destination,
                        zero: zero,
                        capacity: capacity))
                    return destination
                default:
                    break
                }
            }
            // Cancel function call: a local variable of type context.CancelFunc
            if let binding = lookup(functionName), binding.type == .named("context.CancelFunc") {
                let cancelFunc = binding.register
                operations.append(.cancelContext(ctx: cancelFunc))
                return nil
            }
            var registers = try arguments.map { try lower($0) }
            // Wrap arguments into interface values if parameter types are interfaces
            if let paramTypes = functionParameterTypes[functionName] {
                for (i, paramType) in paramTypes.enumerated() where i < registers.count {
                    if case .interface = underlying(paramType) {
                        let argType = try type(of: arguments[i])
                        if case .interface = underlying(argType) { continue }
                        if argType == .nilType { continue }
                        let typeName = concreteTypeName(argType) ?? "unknown"
                        let wrapped = allocateRegister()
                        operations.append(.makeInterface(
                            destination: wrapped, source: registers[i], typeName: typeName))
                        registers[i] = wrapped
                    }
                }
            }
            let returnCount = functionReturnCounts[functionName] ?? 0
            let destinations = (0..<returnCount).map { _ in allocateRegister() }
            operations.append(
                .call(
                    function: functionSymbolNames[functionName] ?? functionName,
                    arguments: registers,
                    destinations: destinations))
            return destinations.first
        }
        if case .selector(let base, let member, _) = callee,
            let receiverType = try? type(of: base),
            let receiverName = syncReceiverName(receiverType)
        {
            var receiver = try lower(base)
            if case .pointer = receiverType {
                let dereferenced = allocateRegister()
                operations.append(.dereference(destination: dereferenced, pointer: receiver))
                receiver = dereferenced
            }
            switch (receiverName, member) {
            case ("sync.Mutex", "Lock"):
                operations.append(.mutexLock(mutex: receiver))
                return nil
            case ("sync.Mutex", "Unlock"):
                operations.append(.mutexUnlock(mutex: receiver))
                return nil
            case ("sync.WaitGroup", "Add"):
                guard let delta = arguments.first else {
                    throw GoDiagnostic(position: callee.position, message: "WaitGroup.Add requires delta")
                }
                operations.append(.waitGroupAdd(waitGroup: receiver, delta: try lower(delta)))
                return nil
            case ("sync.WaitGroup", "Done"):
                operations.append(.waitGroupAdd(
                    waitGroup: receiver,
                    delta: constant(.int(-1))))
                return nil
            case ("sync.WaitGroup", "Wait"):
                operations.append(.waitGroupWait(waitGroup: receiver))
                return nil
            case ("context.Context", "Done"):
                let destination = allocateRegister()
                operations.append(.contextDone(destination: destination, ctx: receiver))
                return destination
            case ("context.Context", "Err"):
                let destination = allocateRegister()
                operations.append(.contextErr(destination: destination, ctx: receiver))
                return destination
            case ("net.Conn", "Write"):
                guard let data = arguments.first else { break }
                let buf = try lower(data)
                let nDest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.netWrite(
                    nDestination: nDest, errDestination: errDest,
                    conn: receiver, buf: buf))
                return nDest
            case ("net.Conn", "Read"):
                guard let data = arguments.first else { break }
                let buf = try lower(data)
                let nDest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.netRead(
                    nDestination: nDest, errDestination: errDest,
                    conn: receiver, buf: buf))
                return nDest
            case ("net.Conn", "Close"):
                let errDest = allocateRegister()
                operations.append(.netClose(errDestination: errDest, conn: receiver))
                return errDest
            case ("net.Listener", "Accept"):
                let connDest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.netAccept(
                    connDestination: connDest, errDestination: errDest,
                    listener: receiver))
                return connDest
            case ("net.Listener", "Close"):
                let errDest = allocateRegister()
                operations.append(.netClose(errDestination: errDest, conn: receiver))
                return errDest
            default:
                break
            }
        }
        if case .selector(let base, let member, _) = callee,
            case .identifier(let baseName, _) = base,
            lookup(baseName)?.type == .pointer(.named("testing.T"))
        {
            switch member {
            case "Error", "Fatal":
                let registers = try arguments.map { try lower($0) }
                operations.append(.testFail(
                    arguments: registers,
                    fatal: member == "Fatal" && testAbortLabels.isEmpty))
                if member == "Fatal", let target = testAbortLabels.last {
                    operations.append(.jump(target: target))
                }
                return nil
            case "Run":
                guard arguments.count == 2,
                    case .string(let name, _) = arguments[0],
                    case .functionLiteral(let parameters, _, _, let body, _) = arguments[1],
                    let parameter = parameters.first
                else {
                    throw GoDiagnostic(
                        position: callee.position,
                        message: "testing.T.Run requires a name and function literal")
                }
                let testContext = try lower(base)
                let endLabel = allocateLabel()
                operations.append(.testBegin(name: name))
                testAbortLabels.append(endLabel)
                scopes.append([
                    parameter.name: LoweredBinding(
                        register: testContext,
                        type: .pointer(.named("testing.T")))
                ])
                try lower(body, createsScope: false)
                scopes.removeLast()
                testAbortLabels.removeLast()
                operations.append(.label(endLabel))
                let result = allocateRegister()
                operations.append(.testEnd(name: name, destination: result))
                return result
            default:
                break
            }
        }
        if case .selector(let base, let member, _) = callee,
            case .identifier(let packageName, _) = base,
            let builtin = GoStandardLibrary.resolve(package: packageName, member: member)
        {
            let registers = try arguments.map { try lower($0) }
            switch builtin {
            case .fmtPrint:
                operations.append(.print(arguments: registers, newline: false))
            case .fmtPrintln:
                operations.append(.print(arguments: registers, newline: true))
            case .timeAfter:
                guard let duration = registers.first else {
                    throw GoDiagnostic(
                        position: callee.position,
                        message: "time.After requires a duration")
                }
                let destination = allocateRegister()
                operations.append(.timeAfter(destination: destination, duration: duration))
                return destination
            case .timeSleep:
                guard let duration = registers.first else {
                    throw GoDiagnostic(
                        position: callee.position,
                        message: "time.Sleep requires a duration")
                }
                operations.append(.timeSleep(duration: duration))
                return nil
            case .timeTick:
                guard let duration = registers.first else {
                    throw GoDiagnostic(
                        position: callee.position,
                        message: "time.Tick requires a duration")
                }
                let destination = allocateRegister()
                operations.append(.timeTick(destination: destination, duration: duration))
                return destination
            case .runtimeGC:
                operations.append(.garbageCollect)
                return nil
            case .contextBackground:
                let destination = allocateRegister()
                operations.append(.contextBackground(destination: destination))
                return destination
            case .contextWithCancel:
                let parent = registers.first!
                let ctxDest = allocateRegister()
                let cancelDest = allocateRegister()
                operations.append(.contextWithCancel(
                    ctxDestination: ctxDest,
                    cancelDestination: cancelDest,
                    parent: parent))
                return ctxDest
            case .contextWithTimeout:
                let parent = registers[0]
                let duration = registers[1]
                let ctxDest = allocateRegister()
                let cancelDest = allocateRegister()
                operations.append(.contextWithTimeout(
                    ctxDestination: ctxDest,
                    cancelDestination: cancelDest,
                    parent: parent,
                    duration: duration))
                return ctxDest
            case .netDial:
                let network = registers[0]
                let address = registers[1]
                let connDest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.netDial(
                    connDestination: connDest, errDestination: errDest,
                    network: network, address: address))
                return connDest
            case .netListen:
                let network = registers[0]
                let address = registers[1]
                let lnDest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.netListen(
                    lnDestination: lnDest, errDestination: errDest,
                    network: network, address: address))
                return lnDest
            case .netLookupHost:
                let host = registers[0]
                let dest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.netLookupHost(
                    destination: dest, errDestination: errDest, host: host))
                return dest
            case .httpHandleFunc:
                let pattern = registers[0]
                // The handler is a function reference - extract its name
                let handlerName: String
                if case .identifier(let name, _) = arguments[1] {
                    handlerName = name
                } else {
                    handlerName = "unknown"
                }
                operations.append(.httpHandleFunc(
                    pattern: pattern, handler: handlerName))
                return nil
            case .httpListenAndServe:
                let addr = registers[0]
                let errDest = allocateRegister()
                operations.append(.httpListenAndServe(
                    errDestination: errDest, addr: addr))
                return errDest
            case .httpGet:
                let url = registers[0]
                let respDest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.httpGet(
                    respDestination: respDest, errDestination: errDest, url: url))
                return respDest
            case .osExit:
                guard let code = registers.first else {
                    throw GoDiagnostic(
                        position: callee.position,
                        message: "os.Exit requires an exit code")
                }
                operations.append(.osExit(source: code))
                return nil
            case .strconvAtoi:
                guard let source = registers.first else {
                    throw GoDiagnostic(
                        position: callee.position,
                        message: "strconv.Atoi requires a string")
                }
                let value = allocateRegister()
                let err = allocateRegister()
                operations.append(.parseInt(
                    destination: value, errDestination: err, source: source))
                return value
            case .userlandReadInput:
                let data = allocateRegister()
                let status = allocateRegister()
                operations.append(.readInput(
                    dataDestination: data,
                    statusDestination: status,
                    command: registers[0],
                    paths: registers[1]))
                return data
            }
            return nil
        }
        // Local package function call: pkg.Function(args...)
        if case .selector(let base, let member, _) = callee,
            case .identifier(let packageName, _) = base,
            GoStandardLibrary.resolve(package: packageName, member: member) == nil
        {
            // Check if this is a known imported package function (not fmt, not a method)
            let mangledName = packageName + "." + member
            if functionReturnCounts[mangledName] != nil || functionParameterTypes[mangledName] != nil {
                let registers = try arguments.map { try lower($0) }
                let returnCount = functionReturnCounts[mangledName] ?? 0
                let destinations = (0..<returnCount).map { _ in allocateRegister() }
                operations.append(
                    .call(
                        function: mangledName,
                        arguments: registers,
                        destinations: destinations))
                return destinations.first
            }
        }
        // Interface method dispatch
        if case .selector(let base, let member, _) = callee {
            let baseType = try type(of: base)
            if case .interface(let methods) = underlying(baseType),
                let method = methods.first(where: { $0.name == member })
            {
                let receiver = try lower(base)
                let argRegisters = try arguments.map { try lower($0) }
                let returnCount = method.results.count
                let destinations = (0..<returnCount).map { _ in allocateRegister() }
                operations.append(
                    .callInterface(
                        method: member,
                        receiver: receiver,
                        arguments: argRegisters,
                        destinations: destinations))
                return destinations.first
            }
        }
        if case .selector(let base, let member, _) = callee,
            let info = try methodInfo(base: base, name: member)
        {
            let baseType = try type(of: base)
            let receiver: Int
            if case .pointer = info.receiverType {
                if case .pointer = baseType {
                    receiver = try lower(base)
                } else {
                    receiver = try lowerAddress(of: base)
                }
            } else if case .pointer = baseType {
                let pointer = try lower(base)
                let value = allocateRegister()
                operations.append(.dereference(destination: value, pointer: pointer))
                receiver = value
            } else {
                receiver = try lower(base)
            }
            let registers = [receiver] + (try arguments.map { try lower($0) })
            let destinations = (0..<info.returnCount).map { _ in allocateRegister() }
            operations.append(
                .call(
                    function: info.functionName,
                    arguments: registers,
                    destinations: destinations))
            return destinations.first
        }
        throw GoDiagnostic(position: callee.position, message: "unsupported function call")
    }

    func multiReturnTypes(callee: GoExpression) -> [GoType] {
        if case .identifier(let name, _) = callee {
            return functionResultTypes[name] ?? []
        }
        if case .selector(let base, let member, _) = callee,
            case .identifier(let packageName, _) = base,
            let builtin = GoStandardLibrary.resolve(package: packageName, member: member)
        {
            switch builtin {
            case .contextWithCancel:
                return [.named("context.Context"), .named("context.CancelFunc")]
            case .contextWithTimeout:
                return [.named("context.Context"), .named("context.CancelFunc")]
            case .netDial:
                return [.named("net.Conn"), .interface([])]
            case .netListen:
                return [.named("net.Listener"), .interface([])]
            case .netLookupHost:
                return [.slice(.string), .interface([])]
            case .httpGet:
                return [.named("http.Response"), .interface([])]
            case .strconvAtoi:
                return [.int, .interface([])]
            case .userlandReadInput:
                return [.string, .int]
            default:
                break
            }
        }
        if case .selector(let base, let member, _) = callee,
            let receiverType = try? type(of: base),
            let receiverName = syncReceiverName(receiverType)
        {
            switch (receiverName, member) {
            case ("net.Conn", "Read"), ("net.Conn", "Write"):
                return [.int, .interface([])]
            case ("net.Listener", "Accept"):
                return [.named("net.Conn"), .interface([])]
            default:
                break
            }
        }
        if case .selector(let base, let name, _) = callee,
            let info = try? methodInfo(base: base, name: name)
        {
            return info.resultTypes
        }
        return []
    }

    mutating func lowerMultiReturnCall(
        callee: GoExpression,
        arguments: [GoExpression]
    ) throws -> [Int]? {
        // Handle context.WithCancel / context.WithTimeout as multi-return builtins
        if case .selector(let base, let member, _) = callee,
            case .identifier(let packageName, _) = base,
            let builtin = GoStandardLibrary.resolve(package: packageName, member: member)
        {
            switch builtin {
            case .contextWithCancel:
                let parent = try lower(arguments[0])
                let ctxDest = allocateRegister()
                let cancelDest = allocateRegister()
                operations.append(.contextWithCancel(
                    ctxDestination: ctxDest,
                    cancelDestination: cancelDest,
                    parent: parent))
                return [ctxDest, cancelDest]
            case .contextWithTimeout:
                let parent = try lower(arguments[0])
                let duration = try lower(arguments[1])
                let ctxDest = allocateRegister()
                let cancelDest = allocateRegister()
                operations.append(.contextWithTimeout(
                    ctxDestination: ctxDest,
                    cancelDestination: cancelDest,
                    parent: parent,
                    duration: duration))
                return [ctxDest, cancelDest]
            case .netDial:
                let network = try lower(arguments[0])
                let address = try lower(arguments[1])
                let connDest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.netDial(
                    connDestination: connDest, errDestination: errDest,
                    network: network, address: address))
                return [connDest, errDest]
            case .netListen:
                let network = try lower(arguments[0])
                let address = try lower(arguments[1])
                let lnDest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.netListen(
                    lnDestination: lnDest, errDestination: errDest,
                    network: network, address: address))
                return [lnDest, errDest]
            case .netLookupHost:
                let host = try lower(arguments[0])
                let dest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.netLookupHost(
                    destination: dest, errDestination: errDest, host: host))
                return [dest, errDest]
            case .httpGet:
                let url = try lower(arguments[0])
                let respDest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.httpGet(
                    respDestination: respDest, errDestination: errDest, url: url))
                return [respDest, errDest]
            case .strconvAtoi:
                let source = try lower(arguments[0])
                let value = allocateRegister()
                let err = allocateRegister()
                operations.append(.parseInt(
                    destination: value, errDestination: err, source: source))
                return [value, err]
            case .userlandReadInput:
                let command = try lower(arguments[0])
                let paths = try lower(arguments[1])
                let data = allocateRegister()
                let status = allocateRegister()
                operations.append(.readInput(
                    dataDestination: data,
                    statusDestination: status,
                    command: command,
                    paths: paths))
                return [data, status]
            default:
                break
            }
        }
        // Handle net.Conn/net.Listener method multi-return calls
        if case .selector(let base, let member, _) = callee,
            let receiverType = try? type(of: base),
            let receiverName = syncReceiverName(receiverType)
        {
            var receiver = try lower(base)
            if case .pointer = receiverType {
                let dereferenced = allocateRegister()
                operations.append(.dereference(destination: dereferenced, pointer: receiver))
                receiver = dereferenced
            }
            switch (receiverName, member) {
            case ("net.Conn", "Read"):
                let buf = try lower(arguments[0])
                let nDest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.netRead(
                    nDestination: nDest, errDestination: errDest,
                    conn: receiver, buf: buf))
                return [nDest, errDest]
            case ("net.Conn", "Write"):
                let buf = try lower(arguments[0])
                let nDest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.netWrite(
                    nDestination: nDest, errDestination: errDest,
                    conn: receiver, buf: buf))
                return [nDest, errDest]
            case ("net.Listener", "Accept"):
                let connDest = allocateRegister()
                let errDest = allocateRegister()
                operations.append(.netAccept(
                    connDestination: connDest, errDestination: errDest,
                    listener: receiver))
                return [connDest, errDest]
            default:
                break
            }
        }
        if case .identifier(let functionName, _) = callee {
            let returnCount = functionReturnCounts[functionName] ?? 0
            guard returnCount > 1 else { return nil }
            let registers = try arguments.map { try lower($0) }
            let destinations = (0..<returnCount).map { _ in allocateRegister() }
            operations.append(
                .call(
                    function: functionSymbolNames[functionName] ?? functionName,
                    arguments: registers,
                    destinations: destinations))
            return destinations
        }
        if case .selector(let base, let member, _) = callee,
            let info = try methodInfo(base: base, name: member)
        {
            guard info.returnCount > 1 else { return nil }
            let baseType = try type(of: base)
            let receiver: Int
            if case .pointer = info.receiverType {
                if case .pointer = baseType {
                    receiver = try lower(base)
                } else {
                    receiver = try lowerAddress(of: base)
                }
            } else if case .pointer = baseType {
                let pointer = try lower(base)
                let value = allocateRegister()
                operations.append(.dereference(destination: value, pointer: pointer))
                receiver = value
            } else {
                receiver = try lower(base)
            }
            let registers = [receiver] + (try arguments.map { try lower($0) })
            let destinations = (0..<info.returnCount).map { _ in allocateRegister() }
            operations.append(
                .call(
                    function: info.functionName,
                    arguments: registers,
                    destinations: destinations))
            return destinations
        }
        return nil
    }

    mutating func lower(_ expression: GoExpression) throws -> Int {
        switch expression {
        case .integer(let value, _):
            return constant(.int(value))
        case .string(let value, _):
            return constant(.string(value))
        case .identifier(let name, let position):
            if name == "true" { return constant(.bool(true)) }
            if name == "false" { return constant(.bool(false)) }
            if name == "nil" { return constant(.nilValue) }
            if let binding = lookup(name) {
                return binding.register
            }
            if let global = globalInfos[name] {
                let destination = allocateRegister()
                operations.append(.loadGlobal(destination: destination, index: global.index))
                return destination
            }
            throw GoDiagnostic(position: position, message: "undefined: \(name)")
        case .unary(let unaryOperator, let operand, _):
            switch unaryOperator {
            case .plus:
                let source = try lower(operand)
                let destination = allocateRegister()
                operations.append(.copy(destination: destination, source: source))
                return destination
            case .minus:
                let source = try lower(operand)
                let destination = allocateRegister()
                operations.append(.unary(destination: destination, operator: .negate, operand: source))
                return destination
            case .not:
                let source = try lower(operand)
                let destination = allocateRegister()
                operations.append(.unary(destination: destination, operator: .not, operand: source))
                return destination
            case .address:
                return try lowerAddress(of: operand)
            case .dereference:
                let source = try lower(operand)
                let destination = allocateRegister()
                operations.append(.dereference(destination: destination, pointer: source))
                return destination
            case .receive:
                guard case .channel(_, let elementType) = underlying(try type(of: operand)) else {
                    throw GoDiagnostic(position: operand.position, message: "cannot receive from non-channel")
                }
                let destination = allocateRegister()
                let zero = try zeroValue(for: elementType, position: operand.position)
                operations.append(.receiveChannel(
                    destination: destination,
                    okDestination: nil,
                    channel: try lower(operand),
                    zero: zero))
                return destination
            }
        case .binary(let left, let binaryOperator, let right, _):
            if binaryOperator == .logicalAnd || binaryOperator == .logicalOr {
                return try lowerShortCircuit(
                    left: left,
                    operator: binaryOperator,
                    right: right)
            }
            let leftRegister = try lower(left)
            let rightRegister = try lower(right)
            let destination = allocateRegister()
            operations.append(
                .binary(
                    destination: destination,
                    operator: map(binaryOperator),
                    left: leftRegister,
                    right: rightRegister))
            return destination
        case .selector(let base, let name, _):
            if case .identifier(let packageName, _) = base,
                let value = GoStandardLibrary.integerConstant(
                    package: packageName, member: name)
            {
                return constant(.int(value))
            }
            if case .identifier("os", _) = base, name == "Args" {
                let destination = allocateRegister()
                operations.append(.osArgs(destination: destination))
                return destination
            }
            var baseRegister = try lower(base)
            if case .pointer = try type(of: base) {
                let dereferenced = allocateRegister()
                operations.append(.dereference(destination: dereferenced, pointer: baseRegister))
                baseRegister = dereferenced
            }
            let destination = allocateRegister()
            operations.append(
                .getField(destination: destination, base: baseRegister, name: name))
            return destination
        case .typeAssertion(let base, let assertedType, let position):
            let type = resolve(assertedType)
            guard let targetName = concreteTypeName(type) else {
                throw GoDiagnostic(position: position, message: "unsupported asserted type")
            }
            let destination = allocateRegister()
            let zero = try zeroValue(for: type, position: position)
            operations.append(.typeAssert(
                destination: destination,
                okDestination: nil,
                source: try lower(base),
                targetName: targetName,
                zero: zero))
            return destination
        case .functionLiteral(_, _, _, _, let position):
            throw GoDiagnostic(
                position: position,
                message: "function literal is only supported as a testing.T.Run callback")
        case .compositeLiteral(let typeExpression, let elements, let position):
            let literalType = resolve(typeExpression)
            let destination = allocateRegister()
            switch underlying(literalType) {
            case .structure(let fields):
                var values: [Int] = []
                if elements.contains(where: { $0.key != nil }) {
                    let keyed = Dictionary(
                        uniqueKeysWithValues: elements.compactMap { element in
                            element.key.map { ($0, element.value) }
                        })
                    for field in fields {
                        if let expression = keyed[field.name] {
                            values.append(try lower(expression))
                        } else {
                            values.append(try zeroValue(for: field.type, position: position))
                        }
                    }
                } else {
                    values = try elements.map { try lower($0.value) }
                }
                operations.append(
                    .makeStruct(
                        destination: destination,
                        typeName: typeName(of: literalType),
                        fieldNames: fields.map(\.name),
                        values: values))
            case .array(let length, let elementType):
                var values = try elements.map { try lower($0.value) }
                while values.count < length {
                    values.append(try zeroValue(for: elementType, position: position))
                }
                operations.append(.makeArray(destination: destination, values: values))
            case .slice(let elementType):
                let zero = try zeroValue(for: elementType, position: position)
                operations.append(
                    .makeSlice(
                        destination: destination,
                        zero: zero,
                        values: try elements.map { try lower($0.value) }))
            case .map:
                var keys: [Int] = []
                var values: [Int] = []
                for element in elements {
                    if let keyExpression = element.keyExpression {
                        keys.append(try lower(keyExpression))
                    } else if let key = element.key {
                        keys.append(constant(.string(key)))
                    } else {
                        throw GoDiagnostic(position: element.position, message: "missing key in map literal")
                    }
                    values.append(try lower(element.value))
                }
                operations.append(.makeMap(destination: destination, keys: keys, values: values))
            default:
                throw GoDiagnostic(position: position, message: "invalid composite literal type")
            }
            return destination
        case .index(let base, let index, _):
            let destination = allocateRegister()
            let baseType = try type(of: base)
            if case .map = underlying(baseType) {
                guard case .map(_, let valueType) = underlying(baseType) else {
                    throw GoDiagnostic(position: base.position, message: "invalid map type")
                }
                let zero = try zeroValue(for: valueType, position: base.position)
                operations.append(
                    .getMapIndex(
                        destination: destination,
                        okDestination: nil,
                        base: try lower(base),
                        key: try lower(index),
                        zero: zero))
            } else {
                operations.append(
                    .getIndex(
                        destination: destination,
                        base: try lower(base),
                        index: try lower(index)))
            }
            return destination
        case .slicing(let base, let low, let high, let position):
            let baseType = try type(of: base)
            let lowRegister = try low.map { try lower($0) } ?? constant(.int(0))
            let highRegister: Int
            if let high {
                highRegister = try lower(high)
            } else {
                let lengthBase = try lower(base)
                highRegister = allocateRegister()
                operations.append(.length(destination: highRegister, base: lengthBase))
            }
            let destination = allocateRegister()
            if case .array(_, let elementType) = underlying(baseType) {
                let pointer = try lowerAddress(of: base)
                let zero = try zeroValue(for: elementType, position: position)
                operations.append(
                    .sliceArray(
                        destination: destination,
                        pointer: pointer,
                        low: lowRegister,
                        high: highRegister,
                        zero: zero))
            } else {
                operations.append(
                    .sliceValue(
                        destination: destination,
                        base: try lower(base),
                        low: lowRegister,
                        high: highRegister))
            }
            return destination
        case .typeExpression(_, let position):
            throw GoDiagnostic(position: position, message: "type is not a value")
        case .call(let callee, let arguments, let position):
            guard let destination = try lowerCall(callee: callee, arguments: arguments) else {
                throw GoDiagnostic(position: position, message: "no value used as value")
            }
            return destination
        }
    }

    mutating func store(_ value: Int, to target: GoExpression) throws {
        switch target {
        case .identifier(let name, let position):
            if let variable = lookup(name)?.register {
                operations.append(.copy(destination: variable, source: value))
                return
            }
            if let global = globalInfos[name] {
                operations.append(.storeGlobal(index: global.index, source: value))
                return
            }
            throw GoDiagnostic(position: position, message: "undefined: \(name)")
        case .selector(let base, let name, _):
            let baseType = try type(of: base)
            let baseValue = try lower(base)
            if case .pointer = baseType {
                let dereferenced = allocateRegister()
                operations.append(.dereference(destination: dereferenced, pointer: baseValue))
                let updated = allocateRegister()
                operations.append(
                    .setField(
                        destination: updated,
                        base: dereferenced,
                        name: name,
                        value: value))
                operations.append(.setPointer(pointer: baseValue, value: updated))
                return
            }
            let updated = allocateRegister()
            operations.append(
                .setField(
                    destination: updated,
                    base: baseValue,
                    name: name,
                    value: value))
            try store(updated, to: base)
        case .unary(.dereference, let operand, _):
            operations.append(.setPointer(pointer: try lower(operand), value: value))
        case .index(let base, let index, _):
            let baseType = try type(of: base)
            if case .map = underlying(baseType) {
                let updated = allocateRegister()
                operations.append(
                    .setMapIndex(
                        destination: updated,
                        base: try lower(base),
                        key: try lower(index),
                        value: value))
                try store(updated, to: base)
            } else {
                let updated = allocateRegister()
                operations.append(
                    .setIndex(
                        destination: updated,
                        base: try lower(base),
                        index: try lower(index),
                        value: value))
                if case .array = underlying(baseType) {
                    try store(updated, to: base)
                }
            }
        default:
            throw GoDiagnostic(position: target.position, message: "cannot assign to expression")
        }
    }

    func resolve(_ expression: GoTypeExpression) -> GoType {
        switch expression {
        case .named(let name, _):
            switch name {
            case "int": return .int
            case "string": return .string
            case "bool": return .bool
            case "any": return .interface([])
            case "error": return compilerErrorType()
            case "testing.T": return .named("testing.T")
            default: return .named(name)
            }
        case .structure(let fields, _):
            return .structure(
                fields.map {
                    GoStructFieldType(name: $0.name, type: resolve($0.type))
                })
        case .pointer(let pointee, _):
            return .pointer(resolve(pointee))
        case .array(let length, let element, _):
            return .array(length: length, element: resolve(element))
        case .slice(let element, _):
            return .slice(resolve(element))
        case .map(let key, let value, _):
            return .map(key: resolve(key), value: resolve(value))
        case .channel(let direction, let element, _):
            return .channel(direction: direction, element: resolve(element))
        case .interface(let methods, _):
            return .interface(methods.map { method in
                GoInterfaceMethod(
                    name: method.name,
                    parameters: method.parameters.map(resolve),
                    results: method.results.map(resolve))
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

    func syncReceiverName(_ type: GoType) -> String? {
        switch type {
        case .named(let name)
            where name == "sync.Mutex" || name == "sync.WaitGroup"
                || name == "context.Context" || name == "context.CancelFunc"
                || name == "net.Conn" || name == "net.Listener":
            return name
        case .pointer(.named(let name))
            where name == "sync.Mutex" || name == "sync.WaitGroup"
                || name == "context.Context" || name == "context.CancelFunc"
                || name == "net.Conn" || name == "net.Listener":
            return name
        default:
            return nil
        }
    }

    func structFields(of type: GoType) -> [GoStructFieldType]? {
        let candidate: GoType
        if case .pointer(let pointee) = type {
            candidate = pointee
        } else {
            candidate = type
        }
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

    func typeName(of type: GoType) -> String? {
        guard case .named(let name) = type else { return nil }
        return name
    }

    func concreteTypeName(_ type: GoType) -> String? {
        switch type {
        case .named(let name): return name
        case .int: return "int"
        case .string: return "string"
        case .bool: return "bool"
        case .pointer(let pointee):
            return concreteTypeName(pointee).map { "*" + $0 }
        default: return nil
        }
    }

    mutating func zeroValue(for type: GoType, position: GoSourcePosition) throws -> Int {
        if type == .named("sync.Mutex") {
            let destination = allocateRegister()
            operations.append(.makeMutex(destination: destination))
            return destination
        }
        if type == .named("sync.WaitGroup") {
            let destination = allocateRegister()
            operations.append(.makeWaitGroup(destination: destination))
            return destination
        }
        switch underlying(type) {
        case .int: return constant(.int(0))
        case .string: return constant(.string(""))
        case .bool: return constant(.bool(false))
        case .pointer, .slice, .map, .channel, .interface: return constant(.nilValue)
        case .array(let length, let element):
            let values = try (0..<length).map { _ in
                try zeroValue(for: element, position: position)
            }
            let destination = allocateRegister()
            operations.append(.makeArray(destination: destination, values: values))
            return destination
        case .structure(let fields):
            let values = try fields.map { try zeroValue(for: $0.type, position: position) }
            let destination = allocateRegister()
            operations.append(
                .makeStruct(
                    destination: destination,
                    typeName: typeName(of: type),
                    fieldNames: fields.map(\.name),
                    values: values))
            return destination
        default:
            throw GoDiagnostic(position: position, message: "unsupported zero value type")
        }
    }

    mutating func lowerAddress(of expression: GoExpression) throws -> Int {
        switch expression {
        case .identifier(let name, let position):
            let destination = allocateRegister()
            if let binding = lookup(name) {
                operations.append(
                    .address(destination: destination, local: binding.register, fieldPath: []))
                return destination
            }
            if let global = globalInfos[name] {
                operations.append(.addressGlobal(destination: destination, index: global.index))
                return destination
            }
            throw GoDiagnostic(position: position, message: "undefined: \(name)")
        case .selector(let base, let name, _):
            let pointer: Int
            if case .pointer = try type(of: base) {
                pointer = try lower(base)
            } else {
                pointer = try lowerAddress(of: base)
            }
            let destination = allocateRegister()
            operations.append(
                .fieldAddress(destination: destination, pointer: pointer, name: name))
            return destination
        case .unary(.dereference, let operand, _):
            return try lower(operand)
        case .index(let base, let index, _):
            let baseType = try type(of: base)
            let addressBase: Int
            if case .array = underlying(baseType) {
                addressBase = try lowerAddress(of: base)
            } else {
                addressBase = try lower(base)
            }
            let destination = allocateRegister()
            operations.append(
                .indexAddress(
                    destination: destination,
                    base: addressBase,
                    index: try lower(index)))
            return destination
        default:
            throw GoDiagnostic(position: expression.position, message: "cannot take address")
        }
    }

    func type(of expression: GoExpression) throws -> GoType {
        switch expression {
        case .integer: return .int
        case .string: return .string
        case .identifier(let name, let position):
            if name == "true" || name == "false" { return .bool }
            if name == "nil" { return .nilType }
            guard let binding = lookup(name) else {
                if let global = globalInfos[name] { return global.type }
                throw GoDiagnostic(position: position, message: "undefined: \(name)")
            }
            return binding.type
        case .selector(let base, let name, let position):
            if case .identifier("os", _) = base, name == "Args" {
                return .slice(.string)
            }
            if case .identifier(let packageName, _) = base,
                GoStandardLibrary.integerConstant(package: packageName, member: name) != nil
            {
                return .int
            }
            let baseType = try type(of: base)
            guard let field = structFields(of: baseType)?.first(where: { $0.name == name }) else {
                throw GoDiagnostic(position: position, message: "undefined selector")
            }
            return field.type
        case .compositeLiteral(let typeExpression, _, _):
            return resolve(typeExpression)
        case .index(let base, _, _):
            switch underlying(try type(of: base)) {
            case .array(_, let element), .slice(let element): return element
            case .string: return .int
            default: return .void
            }
        case .slicing(let base, _, _, _):
            switch underlying(try type(of: base)) {
            case .array(_, let element), .slice(let element): return .slice(element)
            case .string: return .string
            default: return .void
            }
        case .typeExpression(let typeExpression, _):
            return resolve(typeExpression)
        case .typeAssertion(_, let assertedType, _):
            return resolve(assertedType)
        case .functionLiteral(let parameters, _, let resultTypes, _, _):
            return .function(
                parameters: parameters.map { resolve($0.type) },
                results: resultTypes.map(resolve))
        case .unary(let unaryOperator, let operand, _):
            let operandType = try type(of: operand)
            switch unaryOperator {
            case .address: return .pointer(operandType)
            case .dereference:
                guard case .pointer(let pointee) = operandType else { return .void }
                return pointee
            case .receive:
                guard case .channel(_, let element) = underlying(operandType) else { return .void }
                return element
            default: return operandType
            }
        case .binary(_, let binaryOperator, _, _):
            switch binaryOperator {
            case .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual:
                return .bool
            default:
                if case .binary(let left, _, _, _) = expression { return try type(of: left) }
                return .void
            }
        case .call(let callee, _, let position):
            if case .identifier(let name, _) = callee,
                name == "len" || name == "cap"
            {
                return .int
            }
            if case .identifier("recover", _) = callee {
                return .interface([])
            }
            if case .identifier("append", _) = callee,
                case .call(_, let arguments, _) = expression,
                let first = arguments.first
            {
                return try type(of: first)
            }
            if case .identifier("make", _) = callee,
                case .call(_, let arguments, _) = expression,
                case .typeExpression(let madeType, _) = arguments.first
            {
                return resolve(madeType)
            }
            if case .identifier(let name, _) = callee,
                let results = functionResultTypes[name],
                let result = results.first
            {
                return result
            }
            if case .selector(let base, let name, _) = callee,
                case .identifier(let baseName, _) = base,
                lookup(baseName)?.type == .pointer(.named("testing.T"))
            {
                return name == "Run" ? .bool : .void
            }
            if case .selector(let base, "After", _) = callee,
                case .identifier("time", _) = base
            {
                return .channel(direction: .receiveOnly, element: .int)
            }
            if case .selector(let base, let name, _) = callee,
                syncReceiverName(try type(of: base)) != nil
            {
                _ = name
                return .void
            }
            if case .selector(let base, let name, _) = callee,
                let info = try methodInfo(base: base, name: name)
            {
                return info.resultTypes.first ?? .void
            }
            throw GoDiagnostic(position: position, message: "no value used as value")
        }
    }

    func methodInfo(base: GoExpression, name: String) throws -> MethodInfo? {
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
            return nil
        }
        return candidates.lazy.compactMap { methodInfos[$0] }.first
    }

    func compiledName(of function: GoFunctionDeclaration) -> String {
        guard let receiver = function.receiver,
            let identity = receiverIdentity(resolve(receiver.type))
        else { return function.name }
        return methodKey(
            baseName: identity.baseName,
            pointer: identity.isPointer,
            method: function.name)
    }

    mutating func constant(_ value: GoIRConstant) -> Int {
        let register = allocateRegister()
        operations.append(.constant(destination: register, value: value))
        return register
    }

    mutating func allocateRegister() -> Int {
        defer { nextRegister += 1 }
        return nextRegister
    }

    mutating func allocateLabel() -> Int {
        defer { nextLabel += 1 }
        return nextLabel
    }

    func lookup(_ name: String) -> LoweredBinding? {
        for scope in scopes.reversed() {
            if let binding = scope[name] { return binding }
        }
        return nil
    }

    mutating func lowerShortCircuit(
        left: GoExpression,
        operator binaryOperator: GoBinaryOperator,
        right: GoExpression
    ) throws -> Int {
        let result = allocateRegister()
        let endLabel = allocateLabel()
        let leftRegister = try lower(left)
        if binaryOperator == .logicalAnd {
            operations.append(.constant(destination: result, value: .bool(false)))
            operations.append(.jumpIfFalse(condition: leftRegister, target: endLabel))
        } else {
            operations.append(.constant(destination: result, value: .bool(true)))
            operations.append(.jumpIfTrue(condition: leftRegister, target: endLabel))
        }
        let rightRegister = try lower(right)
        operations.append(.copy(destination: result, source: rightRegister))
        operations.append(.label(endLabel))
        return result
    }

    func map(_ binaryOperator: GoBinaryOperator) -> GoIRBinaryOperator {
        switch binaryOperator {
        case .add: return .add
        case .subtract: return .subtract
        case .multiply: return .multiply
        case .divide: return .divide
        case .remainder: return .remainder
        case .equal: return .equal
        case .notEqual: return .notEqual
        case .less: return .less
        case .lessEqual: return .lessEqual
        case .greater: return .greater
        case .greaterEqual: return .greaterEqual
        case .logicalAnd: return .logicalAnd
        case .logicalOr: return .logicalOr
        }
    }
}

private enum BytecodeEmitter {
    static func emit(_ program: GoIRProgram) -> GoExecutable {
        GoExecutable(
            entryPoint: program.entryPoint,
            initializers: program.initializers,
            globalCount: program.globalCount,
            functions: program.functions.map { function in
                let labelOffsets = labelOffsets(for: function.operations)
                var instructions: [GoInstruction] = []
                for operation in function.operations {
                    emit(operation, labels: labelOffsets, to: &instructions)
                }
                return GoBytecodeFunction(
                    name: function.name,
                    parameterCount: function.parameterCount,
                    returnCount: function.returnCount,
                    localCount: function.registerCount,
                    instructions: instructions,
                    rootLocalIndices: Array(0..<function.registerCount),
                    safepointProgramCounters: Array(0...instructions.count))
            })
    }

    static func labelOffsets(for operations: [GoIROperation]) -> [Int: Int] {
        var offsets: [Int: Int] = [:]
        var offset = 0
        for operation in operations {
            if case .label(let label) = operation { offsets[label] = offset }
            offset += instructionCount(for: operation)
        }
        return offsets
    }

    static func instructionCount(for operation: GoIROperation) -> Int {
        switch operation {
        case .constant, .copy: return 2
        case .unary: return 3
        case .binary: return 4
        case .print(let arguments, _): return arguments.count + 1
        case .label: return 0
        case .jump, .return: return 1
        case .jumpIfFalse, .jumpIfTrue: return 2
        case .call(_, let arguments, let destinations):
            return arguments.count + 1 + destinations.count
        case .spawn(_, let arguments): return arguments.count + 1
        case .makeStruct(_, _, _, let values): return values.count + 2
        case .getField: return 3
        case .setField: return 4
        case .address: return 2
        case .fieldAddress, .dereference: return 3
        case .setPointer: return 3
        case .makeArray(_, let values): return values.count + 2
        case .makeSlice(_, _, let values): return values.count + 3
        case .allocateSlice: return 5
        case .getIndex, .indexAddress: return 4
        case .setIndex: return 5
        case .sliceValue: return 5
        case .sliceArray: return 6
        case .length, .capacity: return 3
        case .append: return 5
        case .loadGlobal, .storeGlobal, .addressGlobal: return 2
        case .returnValues(let sources): return sources.count + 1
        case .deferCall(_, let arguments): return arguments.count + 1
        case .panic: return 2
        case .recover: return 2
        case .makeMap(_, let keys, _): return keys.count * 2 + 2
        case .makeChannel: return 4
        case .sendChannel: return 3
        case .receiveChannel(_, let okDestination, _, _):
            return okDestination == nil ? 4 : 5
        case .closeChannel: return 2
        case .select: return 1
        case .timeAfter: return 3
        case .timeSleep: return 2
        case .timeTick: return 3
        case .contextBackground: return 2
        case .contextWithCancel: return 4
        case .contextWithTimeout: return 5
        case .contextDone: return 3
        case .contextErr: return 3
        case .cancelContext: return 2
        case .netDial: return 5
        case .netListen: return 5
        case .netAccept: return 4
        case .netRead: return 5
        case .netWrite: return 5
        case .netClose: return 3
        case .netLookupHost: return 4
        case .httpHandleFunc: return 2
        case .httpListenAndServe: return 3
        case .httpGet: return 4
        case .makeMutex, .makeWaitGroup: return 2
        case .mutexLock, .mutexUnlock, .waitGroupWait: return 2
        case .waitGroupAdd: return 3
        case .garbageCollect: return 1
        case .getMapIndex(_, let okDestination, _, _, _):
            return okDestination == nil ? 5 : 6
        case .setMapIndex: return 5
        case .deleteMap: return 4
        case .callInterface(_, _, let arguments, let destinations):
            return arguments.count + 2 + destinations.count
        case .makeInterface: return 3
        case .typeAssert(_, let okDestination, _, _, _):
            return okDestination == nil ? 4 : 5
        case .rangeKeys: return 3
        case .rangeValue: return 5
        case .testFail(let arguments, _): return arguments.count + 1
        case .testBegin: return 1
        case .testEnd: return 2
        case .osArgs: return 2
        case .osExit: return 2
        case .parseInt: return 4
        case .readInput: return 5
        }
    }

    static func emit(
        _ operation: GoIROperation,
        labels: [Int: Int],
        to instructions: inout [GoInstruction]
    ) {
        switch operation {
        case .constant(let destination, let value):
            instructions.append(.push(map(value)))
            instructions.append(.store(destination))
        case .copy(let destination, let source):
            instructions.append(.load(source))
            instructions.append(.store(destination))
        case .unary(let destination, let unaryOperator, let operand):
            instructions.append(.load(operand))
            instructions.append(unaryOperator == .negate ? .negate : .not)
            instructions.append(.store(destination))
        case .binary(let destination, let binaryOperator, let left, let right):
            instructions.append(.load(left))
            instructions.append(.load(right))
            instructions.append(map(binaryOperator))
            instructions.append(.store(destination))
        case .print(let arguments, let newline):
            for argument in arguments { instructions.append(.load(argument)) }
            instructions.append(.print(argumentCount: arguments.count, newline: newline))
        case .label:
            break
        case .jump(let label):
            instructions.append(.jump(resolved(label, in: labels)))
        case .jumpIfFalse(let condition, let label):
            instructions.append(.load(condition))
            instructions.append(.jumpIfFalse(resolved(label, in: labels)))
        case .jumpIfTrue(let condition, let label):
            instructions.append(.load(condition))
            instructions.append(.jumpIfTrue(resolved(label, in: labels)))
        case .call(let function, let arguments, let destinations):
            for argument in arguments { instructions.append(.load(argument)) }
            instructions.append(.call(function, argumentCount: arguments.count))
            for destination in destinations.reversed() { instructions.append(.store(destination)) }
        case .spawn(let function, let arguments):
            for argument in arguments { instructions.append(.load(argument)) }
            instructions.append(.spawn(function, argumentCount: arguments.count))
        case .makeStruct(let destination, let typeName, let fieldNames, let values):
            for value in values { instructions.append(.load(value)) }
            instructions.append(.makeStruct(typeName: typeName, fieldNames: fieldNames))
            instructions.append(.store(destination))
        case .getField(let destination, let base, let name):
            instructions.append(.load(base))
            instructions.append(.getField(name))
            instructions.append(.store(destination))
        case .setField(let destination, let base, let name, let value):
            instructions.append(.load(base))
            instructions.append(.load(value))
            instructions.append(.setField(name))
            instructions.append(.store(destination))
        case .address(let destination, let local, let fieldPath):
            instructions.append(.addressLocal(index: local, fieldPath: fieldPath))
            instructions.append(.store(destination))
        case .fieldAddress(let destination, let pointer, let name):
            instructions.append(.load(pointer))
            instructions.append(.fieldAddress(name))
            instructions.append(.store(destination))
        case .dereference(let destination, let pointer):
            instructions.append(.load(pointer))
            instructions.append(.dereference)
            instructions.append(.store(destination))
        case .setPointer(let pointer, let value):
            instructions.append(.load(pointer))
            instructions.append(.load(value))
            instructions.append(.setPointer)
        case .makeArray(let destination, let values):
            for value in values { instructions.append(.load(value)) }
            instructions.append(.makeArray(elementCount: values.count))
            instructions.append(.store(destination))
        case .makeSlice(let destination, let zero, let values):
            instructions.append(.load(zero))
            for value in values { instructions.append(.load(value)) }
            instructions.append(.makeSlice(elementCount: values.count))
            instructions.append(.store(destination))
        case .allocateSlice(let destination, let zero, let length, let capacity):
            instructions.append(.load(zero))
            instructions.append(.load(length))
            instructions.append(.load(capacity))
            instructions.append(.allocateSlice)
            instructions.append(.store(destination))
        case .getIndex(let destination, let base, let index):
            instructions.append(.load(base))
            instructions.append(.load(index))
            instructions.append(.getIndex)
            instructions.append(.store(destination))
        case .setIndex(let destination, let base, let index, let value):
            instructions.append(.load(base))
            instructions.append(.load(index))
            instructions.append(.load(value))
            instructions.append(.setIndex)
            instructions.append(.store(destination))
        case .sliceValue(let destination, let base, let low, let high):
            instructions.append(.load(base))
            instructions.append(.load(low))
            instructions.append(.load(high))
            instructions.append(.slice)
            instructions.append(.store(destination))
        case .sliceArray(let destination, let pointer, let low, let high, let zero):
            instructions.append(.load(pointer))
            instructions.append(.load(low))
            instructions.append(.load(high))
            instructions.append(.load(zero))
            instructions.append(.sliceArray)
            instructions.append(.store(destination))
        case .length(let destination, let base):
            instructions.append(.load(base))
            instructions.append(.length)
            instructions.append(.store(destination))
        case .capacity(let destination, let base):
            instructions.append(.load(base))
            instructions.append(.capacity)
            instructions.append(.store(destination))
        case .append(let destination, let slice, let value, let zero):
            instructions.append(.load(slice))
            instructions.append(.load(value))
            instructions.append(.load(zero))
            instructions.append(.append)
            instructions.append(.store(destination))
        case .indexAddress(let destination, let base, let index):
            instructions.append(.load(base))
            instructions.append(.load(index))
            instructions.append(.indexAddress)
            instructions.append(.store(destination))
        case .loadGlobal(let destination, let index):
            instructions.append(.loadGlobal(index))
            instructions.append(.store(destination))
        case .storeGlobal(let index, let source):
            instructions.append(.load(source))
            instructions.append(.storeGlobal(index))
        case .addressGlobal(let destination, let index):
            instructions.append(.addressGlobal(index))
            instructions.append(.store(destination))
        case .return:
            instructions.append(.return)
        case .returnValues(let sources):
            for source in sources { instructions.append(.load(source)) }
            instructions.append(.returnValues(count: sources.count))
        case .deferCall(let function, let arguments):
            for argument in arguments { instructions.append(.load(argument)) }
            instructions.append(.deferCall(function, argumentCount: arguments.count))
        case .panic(let source):
            instructions.append(.load(source))
            instructions.append(.panic)
        case .recover(let destination):
            instructions.append(.recover)
            instructions.append(.store(destination))
        case .makeMap(let destination, let keys, let values):
            for (key, value) in zip(keys, values) {
                instructions.append(.load(key))
                instructions.append(.load(value))
            }
            instructions.append(.makeMap(entryCount: keys.count))
            instructions.append(.store(destination))
        case .makeChannel(let destination, let zero, let capacity):
            instructions.append(.load(zero))
            instructions.append(.load(capacity))
            instructions.append(.makeChannel)
            instructions.append(.store(destination))
        case .sendChannel(let channel, let value):
            instructions.append(.load(channel))
            instructions.append(.load(value))
            instructions.append(.sendChannel)
        case .receiveChannel(let destination, let okDestination, let channel, let zero):
            instructions.append(.load(channel))
            instructions.append(.load(zero))
            instructions.append(.receiveChannel(commaOK: okDestination != nil))
            if let okDestination { instructions.append(.store(okDestination)) }
            instructions.append(.store(destination))
        case .closeChannel(let channel):
            instructions.append(.load(channel))
            instructions.append(.closeChannel)
        case .select(let cases, let defaultTarget):
            instructions.append(.select(
                cases: cases.map { selectCase in
                    switch selectCase {
                    case .send(let channel, let value, let target):
                        return .send(
                            channelLocal: channel,
                            valueLocal: value,
                            target: resolved(target, in: labels))
                    case .receive(
                        let channel, let destination, let okDestination, let zero, let target):
                        return .receive(
                            channelLocal: channel,
                            destinationLocal: destination,
                            okLocal: okDestination,
                            zeroLocal: zero,
                            target: resolved(target, in: labels))
                    }
                },
                defaultTarget: defaultTarget.map { resolved($0, in: labels) }))
        case .timeAfter(let destination, let duration):
            instructions.append(.load(duration))
            instructions.append(.timeAfter)
            instructions.append(.store(destination))
        case .timeSleep(let duration):
            instructions.append(.load(duration))
            instructions.append(.timeSleep)
        case .timeTick(let destination, let duration):
            instructions.append(.load(duration))
            instructions.append(.timeTick)
            instructions.append(.store(destination))
        case .contextBackground(let destination):
            instructions.append(.contextBackground)
            instructions.append(.store(destination))
        case .contextWithCancel(let ctxDestination, let cancelDestination, let parent):
            instructions.append(.load(parent))
            instructions.append(.contextWithCancel)
            instructions.append(.store(cancelDestination))
            instructions.append(.store(ctxDestination))
        case .contextWithTimeout(let ctxDestination, let cancelDestination, let parent, let duration):
            instructions.append(.load(parent))
            instructions.append(.load(duration))
            instructions.append(.contextWithTimeout)
            instructions.append(.store(cancelDestination))
            instructions.append(.store(ctxDestination))
        case .contextDone(let destination, let ctx):
            instructions.append(.load(ctx))
            instructions.append(.contextDone)
            instructions.append(.store(destination))
        case .contextErr(let destination, let ctx):
            instructions.append(.load(ctx))
            instructions.append(.contextErr)
            instructions.append(.store(destination))
        case .cancelContext(let ctx):
            instructions.append(.load(ctx))
            instructions.append(.cancelContext)
        case .netDial(let connDestination, let errDestination, let network, let address):
            instructions.append(.load(network))
            instructions.append(.load(address))
            instructions.append(.netDial)
            instructions.append(.store(errDestination))
            instructions.append(.store(connDestination))
        case .netListen(let lnDestination, let errDestination, let network, let address):
            instructions.append(.load(network))
            instructions.append(.load(address))
            instructions.append(.netListen)
            instructions.append(.store(errDestination))
            instructions.append(.store(lnDestination))
        case .netAccept(let connDestination, let errDestination, let listener):
            instructions.append(.load(listener))
            instructions.append(.netAccept)
            instructions.append(.store(errDestination))
            instructions.append(.store(connDestination))
        case .netRead(let nDestination, let errDestination, let conn, let buf):
            instructions.append(.load(conn))
            instructions.append(.load(buf))
            instructions.append(.netRead)
            instructions.append(.store(errDestination))
            instructions.append(.store(nDestination))
        case .netWrite(let nDestination, let errDestination, let conn, let buf):
            instructions.append(.load(conn))
            instructions.append(.load(buf))
            instructions.append(.netWrite)
            instructions.append(.store(errDestination))
            instructions.append(.store(nDestination))
        case .netClose(let errDestination, let conn):
            instructions.append(.load(conn))
            instructions.append(.netClose)
            instructions.append(.store(errDestination))
        case .netLookupHost(let destination, let errDestination, let host):
            instructions.append(.load(host))
            instructions.append(.netLookupHost)
            instructions.append(.store(errDestination))
            instructions.append(.store(destination))
        case .httpHandleFunc(let pattern, let handler):
            instructions.append(.load(pattern))
            instructions.append(.httpHandleFunc(handler))
        case .httpListenAndServe(let errDestination, let addr):
            instructions.append(.load(addr))
            instructions.append(.httpListenAndServe)
            instructions.append(.store(errDestination))
        case .httpGet(let respDestination, let errDestination, let url):
            instructions.append(.load(url))
            instructions.append(.httpGet)
            instructions.append(.store(errDestination))
            instructions.append(.store(respDestination))
        case .makeMutex(let destination):
            instructions.append(.makeMutex)
            instructions.append(.store(destination))
        case .mutexLock(let mutex):
            instructions.append(.load(mutex))
            instructions.append(.mutexLock)
        case .mutexUnlock(let mutex):
            instructions.append(.load(mutex))
            instructions.append(.mutexUnlock)
        case .makeWaitGroup(let destination):
            instructions.append(.makeWaitGroup)
            instructions.append(.store(destination))
        case .waitGroupAdd(let waitGroup, let delta):
            instructions.append(.load(waitGroup))
            instructions.append(.load(delta))
            instructions.append(.waitGroupAdd)
        case .waitGroupWait(let waitGroup):
            instructions.append(.load(waitGroup))
            instructions.append(.waitGroupWait)
        case .garbageCollect:
            instructions.append(.garbageCollect)
        case .getMapIndex(let destination, let okDestination, let base, let key, let zero):
            instructions.append(.load(base))
            instructions.append(.load(key))
            instructions.append(.load(zero))
            instructions.append(.getMapIndex(commaOK: okDestination != nil))
            if let okDestination { instructions.append(.store(okDestination)) }
            instructions.append(.store(destination))
        case .setMapIndex(let destination, let base, let key, let value):
            instructions.append(.load(base))
            instructions.append(.load(key))
            instructions.append(.load(value))
            instructions.append(.setMapIndex)
            instructions.append(.store(destination))
        case .deleteMap(let destination, let base, let key):
            instructions.append(.load(base))
            instructions.append(.load(key))
            instructions.append(.deleteMap)
            instructions.append(.store(destination))
        case .callInterface(let method, let receiver, let arguments, let destinations):
            instructions.append(.load(receiver))
            for argument in arguments { instructions.append(.load(argument)) }
            instructions.append(.callInterface(method, argumentCount: arguments.count))
            for destination in destinations.reversed() { instructions.append(.store(destination)) }
        case .makeInterface(let destination, let source, let typeName):
            instructions.append(.load(source))
            instructions.append(.makeInterface(typeName: typeName))
            instructions.append(.store(destination))
        case .typeAssert(
            let destination, let okDestination, let source, let targetName, let zero):
            instructions.append(.load(source))
            instructions.append(.load(zero))
            instructions.append(.typeAssert(
                typeName: targetName, commaOK: okDestination != nil))
            if let okDestination {
                instructions.append(.store(okDestination))
            }
            instructions.append(.store(destination))
        case .rangeKeys(let destination, let base):
            instructions.append(.load(base))
            instructions.append(.rangeKeys)
            instructions.append(.store(destination))
        case .rangeValue(let destination, let base, let key, let zero):
            instructions.append(.load(base))
            instructions.append(.load(key))
            instructions.append(.load(zero))
            instructions.append(.rangeValue)
            instructions.append(.store(destination))
        case .testFail(let arguments, let fatal):
            for argument in arguments { instructions.append(.load(argument)) }
            instructions.append(.testFail(
                argumentCount: arguments.count, fatal: fatal))
        case .testBegin(let name):
            instructions.append(.testBegin(name))
        case .testEnd(let name, let destination):
            instructions.append(.testEnd(name))
            instructions.append(.store(destination))
        case .osArgs(let destination):
            instructions.append(.osArgs)
            instructions.append(.store(destination))
        case .osExit(let source):
            instructions.append(.load(source))
            instructions.append(.exit)
        case .parseInt(let destination, let errDestination, let source):
            instructions.append(.load(source))
            instructions.append(.parseInt)
            instructions.append(.store(errDestination))
            instructions.append(.store(destination))
        case .readInput(
            let dataDestination,
            let statusDestination,
            let command,
            let paths):
            instructions.append(.load(command))
            instructions.append(.load(paths))
            instructions.append(.readInput)
            instructions.append(.store(statusDestination))
            instructions.append(.store(dataDestination))
        }
    }

    static func resolved(_ label: Int, in labels: [Int: Int]) -> Int {
        guard let offset = labels[label] else {
            preconditionFailure("Swiftix Go compiler emitted an unresolved label")
        }
        return offset
    }

    static func map(_ value: GoIRConstant) -> GoValue {
        switch value {
        case .int(let value): return .int(value)
        case .string(let value): return .string(value)
        case .bool(let value): return .bool(value)
        case .nilValue: return .nilValue
        }
    }

    static func map(_ binaryOperator: GoIRBinaryOperator) -> GoInstruction {
        switch binaryOperator {
        case .add: return .add
        case .subtract: return .subtract
        case .multiply: return .multiply
        case .divide: return .divide
        case .remainder: return .remainder
        case .equal: return .equal
        case .notEqual: return .notEqual
        case .less: return .less
        case .lessEqual: return .lessEqual
        case .greater: return .greater
        case .greaterEqual: return .greaterEqual
        case .logicalAnd: return .logicalAnd
        case .logicalOr: return .logicalOr
        }
    }
}
