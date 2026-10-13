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

    /// Compiles the package `root` together with every local package it
    /// imports, directly or transitively, into one executable.
    ///
    /// `packages` holds the sources of each local package by import path; any
    /// that `root` does not reach are ignored. Packages initialize dependencies
    /// first, each exactly once: package-level variables, then `init`
    /// functions. Cross-package references compile to the same code as
    /// in-package ones.
    public static func compile(
        packages: [GoPackageSource],
        root: String
    ) throws -> GoExecutable {
        let module = try GoModuleLinker.link(packages: packages, root: root)
        do {
            return try compile(
                units: module.units,
                fallbackPath: module.units.last?.files.first?.path ?? "<input>")
        } catch let diagnostic as GoDiagnostic {
            throw module.demangle(diagnostic)
        }
    }

    /// Compiles the package `root`, asking `sources` for the files of each
    /// local package the build reaches.
    ///
    /// `sources` is called once per imported path that is not a package the
    /// runtime provides, and returns nil when it has no such package, which
    /// is then reported as unavailable at the import that names it.
    public static func compile(
        root: String,
        sources: (_ importPath: String) throws -> [GoSourceFile]?
    ) throws -> GoExecutable {
        var packages: [GoPackageSource] = []
        var requested: Set<String> = [root]
        var pending = [root]
        while let importPath = pending.popLast() {
            guard let files = try sources(importPath) else { continue }
            packages.append(GoPackageSource(importPath: importPath, sources: files))
            guard packages.count <= GoModuleLinker.maximumPackages else { break }
            let imports = try files.flatMap { try GoParser.parse($0).imports.map(\.path) }
            for dependency in imports.sorted().reversed()
            where !GoStandardLibrary.supportedPackages.contains(dependency)
                && requested.insert(dependency).inserted
            {
                pending.append(dependency)
            }
        }
        return try compile(packages: packages, root: root)
    }

    /// Lowers linked units, in initialization order, into one executable. A
    /// single-package program is one unit.
    private static func compile(
        units: [GoLinkedUnit],
        fallbackPath: String
    ) throws -> GoExecutable {
        // What the program uses of the library that is Go source is linked
        // like a package of its own.
        let units = try GoSourceLibrary.link(units)
        let files = try GoNames.resolve(
            program: try units.flatMap { try GoNames.resolve($0.files) })
        let package = try GoTypeChecker.check(files)
        guard package.name == "main" else {
            let position =
                files.first?.functions.first?.position
                ?? GoSourcePosition(path: fallbackPath, offset: 0, line: 1, column: 1)
            throw GoDiagnostic(position: position, message: "go run requires package main")
        }
        var functions = files.flatMap(\.functions)
        functions.append(
            contentsOf: runtimeLiteralFunctions(in: functions, captures: package.literalCaptures))
        guard functions.contains(where: { $0.name == "main" }) else {
            let position = GoSourcePosition(path: fallbackPath, offset: 0, line: 1, column: 1)
            throw GoDiagnostic(position: position, message: "function main is undeclared in the main package")
        }

        let globals = files.flatMap(\.globalDeclarations)
        let globalInfos = Dictionary(
            uniqueKeysWithValues: globals.enumerated().map { index, declaration in
                (
                    declaration.name,
                    GlobalInfo(
                        index: index,
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
                        resultTypes: function.resultTypes.map(compilerResolve),
                        parameterTypes: function.parameters.map { compilerResolve($0.type) })
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
        var nativeWrappers: [String: GoIRFunction] = [:]
        var loweredFunctions = try zip(functions, compiledFunctionNames).map { function, name in
            var lowerer = IRLowerer(
                functionReturnCounts: functionReturnCounts,
                functionResultTypes: functionResultTypes,
                functionParameterTypes: functionParameterTypes,
                methodInfos: methodInfos,
                typeDefinitions: package.typeDefinitions,
                globalInfos: globalInfos,
                functionSymbolNames: [:],
                numbers: package.numberFacts,
                literalCaptures: package.literalCaptures)
            let lowered = try lowerer.lower(function, compiledName: name)
            nativeWrappers.merge(lowerer.nativeWrappers) { existing, _ in existing }
            return lowered
        }
        loweredFunctions.append(
            contentsOf: nativeWrappers.values.sorted { $0.name < $1.name })

        // Each unit initializes its package-level variables in dependency
        // order and then runs its `init` functions, after every unit it
        // imports has done both.
        var initializers: [String] = []
        var globalInitializers: [GoIRFunction] = []
        var functionCursor = 0
        var fileCursor = 0
        for unit in units {
            // The unit's files as name resolution left them, one for one:
            // an initializer names types and writes literals like any
            // other code.
            let unitFiles = files[fileCursor..<min(files.count, fileCursor + unit.files.count)]
            fileCursor += unit.files.count
            let unitGlobals = unitFiles.flatMap(\.globalDeclarations)
            if !unitGlobals.isEmpty {
                var lowerer = IRLowerer(
                    functionReturnCounts: functionReturnCounts,
                    functionResultTypes: functionResultTypes,
                    functionParameterTypes: functionParameterTypes,
                    methodInfos: methodInfos,
                    typeDefinitions: package.typeDefinitions,
                    globalInfos: globalInfos,
                    functionSymbolNames: [:],
                    numbers: package.numberFacts,
                literalCaptures: package.literalCaptures)
                globalInitializers.append(
                    try lowerer.lowerGlobals(
                        try orderedGlobals(
                            unitGlobals,
                            functions: functions,
                            globalTypes: package.globalTypes,
                            typeDefinitions: package.typeDefinitions),
                        name: unit.initializerName))
                // A function literal among the initializers is a function too.
                for wrapper in lowerer.nativeWrappers.values.sorted(by: { $0.name < $1.name })
                where nativeWrappers[wrapper.name] == nil {
                    nativeWrappers[wrapper.name] = wrapper
                    loweredFunctions.append(wrapper)
                }
                initializers.append(unit.initializerName)
            }
            let unitFunctionCount = unit.files.reduce(0) { $0 + $1.functions.count }
            for index in functionCursor..<(functionCursor + unitFunctionCount)
            where functions[index].name == "init" && functions[index].receiver == nil {
                initializers.append(compiledFunctionNames[index])
            }
            functionCursor += unitFunctionCount
        }
        loweredFunctions.insert(contentsOf: globalInitializers, at: 0)

        // Native error values have the dynamic type name `error`; give them
        // the method that interface dispatch looks up for `err.Error()`.
        let callsErrorMethod = loweredFunctions.contains { function in
            function.operations.contains { operation in
                if case .callInterface("Error", _, let arguments, _) = operation {
                    return arguments.isEmpty
                }
                return false
            }
        }
        if callsErrorMethod,
            !loweredFunctions.contains(where: { $0.name == GoPredeclared.nativeErrorMethod })
        {
            loweredFunctions.append(
                GoIRFunction(
                    name: GoPredeclared.nativeErrorMethod,
                    parameterCount: 1,
                    returnCount: 1,
                    registerCount: 1,
                    operations: [.returnValues(sources: [0])]))
        }

        let program = try GoSinglePackageLinker.link(
            entryPoint: "main",
            initializers: initializers,
            globalCount: globals.count,
            functions: loweredFunctions)
        return BytecodeEmitter.emit(program)
    }

    /// Links `sources` against separately compiled packages. This older path
    /// resolves only single-result functions of an imported package; module
    /// builds use ``compile(packages:root:)``.
    public static func compile(
        sources: [GoSourceFile],
        importedPackages: [String: GoCompiledPackage],
        packageOrder: [String] = []
    ) throws -> GoExecutable {
        let syntax = try sources.map(GoParser.parse)
        if importedPackages.isEmpty, try GoEmbeddedLibrary.isNeeded(by: syntax) {
            // A package of the library that is written in Go is linked with
            // the program, as a local package of a module is.
            return try compile(
                packages: [GoPackageSource(importPath: "main", sources: sources)], root: "main")
        }
        let parsed = try GoNames.resolve(syntax)
        if importedPackages.isEmpty {
            return try compile(
                units: [
                    GoLinkedUnit(
                        importPath: "main", initializerName: "$package.init", files: parsed)
                ],
                fallbackPath: sources.first?.path ?? "<input>")
        }
        let files = try GoNames.resolve(program: parsed)
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
        functions.append(
            contentsOf: runtimeLiteralFunctions(in: functions, captures: package.literalCaptures))
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
                        resultTypes: function.resultTypes.map(compilerResolve),
                        parameterTypes: function.parameters.map { compilerResolve($0.type) })
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
        var nativeWrappers: [String: GoIRFunction] = [:]
        var loweredFunctions = try zip(functions, compiledFunctionNames).map { function, name in
            var lowerer = IRLowerer(
                functionReturnCounts: functionReturnCountsMerged,
                functionResultTypes: functionResultTypesMerged,
                functionParameterTypes: functionParameterTypesMerged,
                methodInfos: methodInfos,
                typeDefinitions: package.typeDefinitions,
                globalInfos: globalInfos,
                functionSymbolNames: [:],
                numbers: package.numberFacts,
                literalCaptures: package.literalCaptures)
            let lowered = try lowerer.lower(function, compiledName: name)
            nativeWrappers.merge(lowerer.nativeWrappers) { existing, _ in existing }
            return lowered
        }
        loweredFunctions.append(
            contentsOf: nativeWrappers.values.sorted { $0.name < $1.name })
        var initializers: [String] = []
        if !globals.isEmpty {
            var lowerer = IRLowerer(
                functionReturnCounts: functionReturnCountsMerged,
                functionResultTypes: functionResultTypesMerged,
                functionParameterTypes: functionParameterTypesMerged,
                methodInfos: methodInfos,
                typeDefinitions: package.typeDefinitions,
                globalInfos: globalInfos,
                functionSymbolNames: [:],
                numbers: package.numberFacts,
                literalCaptures: package.literalCaptures)
            loweredFunctions.insert(
                try lowerer.lowerGlobals(
                    try orderedGlobals(
                        globals,
                        functions: functions,
                        globalTypes: package.globalTypes,
                        typeDefinitions: package.typeDefinitions),
                    name: "$package.init"),
                at: 0)
            // A function literal among the initializers is a function too.
            for wrapper in lowerer.nativeWrappers.values.sorted(by: { $0.name < $1.name })
            where nativeWrappers[wrapper.name] == nil {
                nativeWrappers[wrapper.name] = wrapper
                loweredFunctions.append(wrapper)
            }
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

        // Native error values have the dynamic type name `error`; give them
        // the method that interface dispatch looks up for `err.Error()`.
        let callsErrorMethod =
            loweredFunctions.contains { function in
                function.operations.contains { operation in
                    if case .callInterface("Error", _, let arguments, _) = operation {
                        return arguments.isEmpty
                    }
                    return false
                }
            }
            || orderedPackages.contains { package in
                package.functions.contains {
                    $0.instructions.contains(.callInterface("Error", argumentCount: 0))
                }
            }
        if callsErrorMethod,
            !externalSymbols.contains(GoPredeclared.nativeErrorMethod),
            !loweredFunctions.contains(where: { $0.name == GoPredeclared.nativeErrorMethod })
        {
            loweredFunctions.append(
                GoIRFunction(
                    name: GoPredeclared.nativeErrorMethod,
                    parameterCount: 1,
                    returnCount: 1,
                    registerCount: 1,
                    operations: [.returnValues(sources: [0])]))
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
        let files = try GoNames.resolve(
            program: try GoNames.resolve(try sources.map(GoParser.parse)))
        let availablePackageExports = Dictionary(
            uniqueKeysWithValues: importedPackages.map { ($0.key, $0.value.export) })
        let package = try GoTypeChecker.check(
            files, availablePackages: availablePackageExports)
        let pkgName = package.name
        var functions = files.flatMap(\.functions)
        functions.append(
            contentsOf: runtimeLiteralFunctions(in: functions, captures: package.literalCaptures))
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
                return (key, MethodInfo(functionName: key, receiverType: compilerResolve(receiver.type), resultTypes: function.resultTypes.map(compilerResolve), parameterTypes: function.parameters.map { compilerResolve($0.type) }))
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

        var nativeWrappers: [String: GoIRFunction] = [:]
        var loweredFunctions = try zip(functions, compiledFunctionNames).map { function, name in
            var lowerer = IRLowerer(
                functionReturnCounts: functionReturnCounts,
                functionResultTypes: functionResultTypes,
                functionParameterTypes: functionParameterTypes,
                methodInfos: methodInfos,
                typeDefinitions: package.typeDefinitions,
                globalInfos: globalInfos,
                functionSymbolNames: functionSymbolNames,
                numbers: package.numberFacts,
                literalCaptures: package.literalCaptures)
            lowerer.wrapperNamespace = pkgName
            let lowered = try lowerer.lower(function, compiledName: name)
            nativeWrappers.merge(lowerer.nativeWrappers) { existing, _ in existing }
            return lowered
        }
        loweredFunctions.append(
            contentsOf: nativeWrappers.values.sorted { $0.name < $1.name })

        var pkgInitializers: [String] = []
        if !globals.isEmpty {
            var lowerer = IRLowerer(
                functionReturnCounts: functionReturnCounts,
                functionResultTypes: functionResultTypes,
                functionParameterTypes: functionParameterTypes,
                methodInfos: methodInfos,
                typeDefinitions: package.typeDefinitions,
                globalInfos: globalInfos,
                functionSymbolNames: functionSymbolNames,
                numbers: package.numberFacts,
                literalCaptures: package.literalCaptures)
            let initName = "$\(pkgName).init"
            loweredFunctions.insert(
                try lowerer.lowerGlobals(
                    try orderedGlobals(globals, functions: functions, globalTypes: package.globalTypes, typeDefinitions: package.typeDefinitions),
                    name: initName),
                at: 0)
            // A function literal among the initializers is a function too.
            for wrapper in lowerer.nativeWrappers.values.sorted(by: { $0.name < $1.name })
            where nativeWrappers[wrapper.name] == nil {
                nativeWrappers[wrapper.name] = wrapper
                loweredFunctions.append(wrapper)
            }
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

struct MethodInfo {
    let functionName: String
    let receiverType: GoType
    let resultTypes: [GoType]
    /// Types of the parameters besides the receiver.
    let parameterTypes: [GoType]

    var parameterCount: Int { parameterTypes.count }

    var returnCount: Int { resultTypes.count }
}

/// A function literal whose body is yet to be lowered: the function it
/// becomes, and the variables it captures with their types.
struct PendingLiteral {
    let declaration: GoFunctionDeclaration
    let symbol: String
    let captures: [(name: String, type: GoType)]
}

struct LoweredBinding {
    let register: Int
    let type: GoType
}

struct GlobalInfo {
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
        default: return GoPredeclared.namedType(name) ?? .named(name)
        }
    case .structure(let fields, _):
        return .structure(
            fields.map {
                GoStructFieldType($0, type: compilerResolve($0.type))
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
        if let signature = expression.functionSignature {
            return .function(
                parameters: signature.parameters.map(compilerResolve),
                results: signature.results.map(compilerResolve))
        }
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
    GoFunctionType.literalName(at: position)
}

/// The function literals that `go` and `defer` statements call and that
/// capture nothing, as functions of the program. A literal that captures is
/// lowered where it stands, which is where its variables are.
private func runtimeLiteralFunctions(
    in functions: [GoFunctionDeclaration],
    captures: [String: [String]]
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
                if captures[name]?.isEmpty == false { continue }
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
    return initializationOrder(of: declarations, depthFirst: ordered, analyzer: analyzer)
}

/// The order Go initializes the variables of a package in: again and again
/// the first variable, as the source declares them, whose value reads no
/// variable that is still to be initialized, directly or through the
/// functions it calls.
///
/// `depthFirst` has every declaration after what it reads, which is that
/// order for a package whose variables read only what stands above them, and
/// for most others. It is kept wherever its variables come as Go has them.
/// Where they do not — a variable that waits for a later one while an
/// independent one stands between them — the variables are put in Go's order,
/// each after the constants it reads; constants have no order of their own.
private func initializationOrder(
    of declarations: [GoGlobalDeclaration],
    depthFirst: [GoGlobalDeclaration],
    analyzer: PackageDependencyAnalyzer
) -> [GoGlobalDeclaration] {
    let variables = Set(declarations.lazy.filter { !$0.isConstant }.map(\.name))
    guard variables.count > 1 else { return depthFirst }
    var dependencies: [String: Set<String>] = [:]
    for declaration in declarations {
        dependencies[declaration.name] =
            declaration.expression.map { analyzer.dependencies(of: $0) } ?? []
    }
    var waiting = declarations.filter { !$0.isConstant }
    var initialized: Set<String> = []
    var sequence: [GoGlobalDeclaration] = []
    while !waiting.isEmpty {
        let ready = waiting.firstIndex { declaration in
            (dependencies[declaration.name] ?? []).allSatisfy {
                !variables.contains($0) || initialized.contains($0)
            }
        }
        // None is ready only in a cycle, which the first order refuses.
        guard let ready else { return depthFirst }
        var group = [waiting.remove(at: ready)]
        if let shared = group[0].expression?.groupedResult?.value.position {
            // `var a, b = f()` is one initialization.
            group += waiting.filter { $0.expression?.groupedResult?.value.position == shared }
            waiting.removeAll { $0.expression?.groupedResult?.value.position == shared }
        }
        sequence += group
        initialized.formUnion(group.map(\.name))
    }
    guard sequence.map(\.name) != depthFirst.filter({ !$0.isConstant }).map(\.name) else {
        return depthFirst
    }
    let byName = Dictionary(declarations.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    var ordered: [GoGlobalDeclaration] = []
    var placed: Set<String> = []
    func place(_ declaration: GoGlobalDeclaration) {
        guard placed.insert(declaration.name).inserted else { return }
        for name in (dependencies[declaration.name] ?? []).sorted() {
            if let dependency = byName[name] { place(dependency) }
        }
        ordered.append(declaration)
    }
    for declaration in sequence { place(declaration) }
    for declaration in declarations { place(declaration) }
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

        // Parameters without names all have the blank one.
        var localTypes = Dictionary(
            function.parameters.map { ($0.name, compilerResolve($0.type)) },
            uniquingKeysWith: { first, _ in first })
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
                        localTypes: clauseTypes(of: switchCase, in: statement, localTypes),
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

    /// The types of the variables a clause of a switch sees: in a type
    /// switch, the name it binds is one more, of the type of the clause.
    private func clauseTypes(
        of switchCase: GoSwitchCase, in statement: GoStatement, _ localTypes: [String: GoType]
    ) -> [String: GoType] {
        guard let typeSwitch = statement.typeSwitch, let name = typeSwitch.binding?.name else {
            return localTypes
        }
        var types = localTypes
        if switchCase.expressions.count == 1,
            case .typeExpression(let syntax, _) = switchCase.expressions[0], !syntax.isNilCase
        {
            types[name] = compilerResolve(syntax)
        } else {
            types[name] = type(of: typeSwitch.operand, localTypes: localTypes) ?? .interface([])
        }
        return types
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
            case .string: return GoPredeclared.byte
            case .map(_, let value): return value
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
                case "len", "cap", "copy": return .int
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
            let definition = typeDefinitions[name]?.underlying
                ?? GoPredeclared.underlying(of: name)
        {
            current = definition
        }
        return current
    }
}

struct IRLowerer {
    let functionReturnCounts: [String: Int]
    let functionResultTypes: [String: [GoType]]
    let functionParameterTypes: [String: [GoType]]
    let methodInfos: [String: MethodInfo]
    let typeDefinitions: [String: GoTypeDefinition]
    let globalInfos: [String: GlobalInfo]
    let functionSymbolNames: [String: String]
    /// What the checker found out about the numbers of the program.
    var numbers = GoNumberFacts()
    var operations: [GoIROperation] = []
    var scopes: [[String: LoweredBinding]] = [[:]]
    var nextRegister = 0
    var nextLabel = 0
    var breakLabels: [Int] = []
    var continueLabels: [Int] = []
    var testAbortLabels: [Int] = []
    var resultRegisters: [Int] = []
    /// Declared result types of the function being lowered.
    var resultTypes: [GoType] = []
    /// Distinguishes the wrappers of separately compiled packages.
    var wrapperNamespace = "main"
    /// Functions synthesized for `go`/`defer` of a native library call.
    var nativeWrappers: [String: GoIRFunction] = [:]
    /// Variables of the function being lowered that a pointer can reach.
    var addressedVariables = GoAddressedVariables()
    /// The variables each function literal captures, by the literal's name:
    /// what the checker found it to read or assign of the functions around.
    var literalCaptures: [String: [String]] = [:]
    /// Whether a `return` of the function being lowered stores its values
    /// in the result variables, for a deferred call to change.
    var returnsThroughResults = false
    /// Function literals whose bodies are yet to be lowered, and the names
    /// of all that were ever put here. A body is lowered after the function
    /// it is written in, not inside it: literals nested in literals then
    /// nest no calls of the lowerer, whose frames are large.
    var pendingLiterals: [PendingLiteral] = []
    var scheduledLiterals: Set<String> = []
    /// Whether this lowerer is lowering the body of a literal, and leaves
    /// the literals it meets to the lowerer that started it.
    var isLiteralBody = false
    /// Whether the function has a `goto`, and whether one jumps back, so
    /// that a declaration outside any loop may be reached again.
    var hasGoto = false
    var jumpsBackward = false

    mutating func lower(
        _ function: GoFunctionDeclaration,
        compiledName: String,
        captures: [(name: String, type: GoType)] = []
    ) throws -> GoIRFunction {
        addressedVariables = GoAddressedVariables(function.body)
        // A variable a literal inside captures is reached through a pointer
        // like one whose address is taken, and is renewed in a loop alike.
        addressedVariables.capture(capturedNames(in: function.body))
        (hasGoto, jumpsBackward) = function.body.gotoStatements
        // A literal takes a pointer to each variable it captures before its
        // own parameters, and gives each a local that is that variable.
        let capturePointers = captures.map { _ in allocateRegister() }
        if let receiver = function.receiver {
            scopes[0][receiver.name] = LoweredBinding(
                register: allocateRegister(),
                type: resolve(receiver.type))
        }
        for parameter in function.parameters {
            scopes[0][parameter.name] = LoweredBinding(
                register: allocateRegister(),
                type: resolve(parameter.type).parameterType)
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
            resultTypes.append(type)
        }
        // A deferred call reaches a named result through a pointer or a
        // literal that captures it, and one that recovers leaves the
        // results as they are. Go returns what they hold after the deferred
        // calls; the VM is told which locals to read then. One result that
        // nothing reaches is the local after the parameters, where the VM
        // looks without being told.
        returnsThroughResults =
            !resultRegisters.isEmpty && GoFunctionLiterals.hasDefer(in: function.body)
            && (resultRegisters.count > 1
                || function.resultNames.contains { name in
                    name.map(addressedVariables.addressed.contains) ?? false
                })
        if returnsThroughResults {
            operations.append(
                .call(
                    function: GoPredeclared.liveResults
                        + resultRegisters.map(String.init).joined(separator: "."),
                    arguments: [], destinations: []))
        }
        for (capture, pointer) in zip(captures, capturePointers) {
            let local = allocateRegister()
            operations.append(
                .call(
                    function: GoPredeclared.bindVariable + String(local), arguments: [pointer],
                    destinations: []))
            scopes[0][capture.name] = LoweredBinding(register: local, type: capture.type)
        }
        try lower(function.body, createsScope: false)
        if function.resultTypes.isEmpty, operations.last != .return {
            operations.append(.return)
        }
        let lowered = GoIRFunction(
            name: compiledName,
            parameterCount: captures.count + function.parameters.count
                + (function.receiver == nil ? 0 : 1),
            returnCount: function.resultTypes.count,
            registerCount: nextRegister,
            operations: operations)
        if !isLiteralBody { try lowerPendingLiterals() }
        return lowered
    }

    /// Lowers the bodies of the literals met so far and of those met in
    /// them, each into `nativeWrappers` under its name.
    mutating func lowerPendingLiterals() throws {
        while let literal = pendingLiterals.popLast() {
            var lowerer = self
            lowerer.operations = []
            lowerer.scopes = [[:]]
            lowerer.nextRegister = 0
            lowerer.nextLabel = 0
            lowerer.breakLabels = []
            lowerer.continueLabels = []
            lowerer.testAbortLabels = []
            lowerer.resultRegisters = []
            lowerer.resultTypes = []
            lowerer.pendingLiterals = []
            lowerer.isLiteralBody = true
            let function = try lowerer.lower(
                literal.declaration, compiledName: literal.symbol, captures: literal.captures)
            // What it synthesized in turn, and the literals inside it.
            nativeWrappers.merge(lowerer.nativeWrappers) { existing, _ in existing }
            nativeWrappers[literal.symbol] = function
            scheduledLiterals.formUnion(lowerer.scheduledLiterals)
            pendingLiterals.append(contentsOf: lowerer.pendingLiterals)
        }
    }

    /// Returns the values in `sources`. Where a deferred call can change
    /// the results, they go into the result variables first.
    mutating func returnValues(_ sources: [Int]) {
        guard returnsThroughResults, sources.count == resultRegisters.count else {
            operations.append(.returnValues(sources: sources))
            return
        }
        for (result, source) in zip(resultRegisters, sources) where result != source {
            operations.append(.copy(destination: result, source: source))
        }
        operations.append(.returnValues(sources: resultRegisters))
    }

    // MARK: Function values

    /// The names the literals in `block` capture, those of literals inside
    /// them included.
    func capturedNames(in block: GoBlock) -> Set<String> {
        guard !literalCaptures.isEmpty else { return [] }
        var names: Set<String> = []
        GoFunctionLiterals.forEach(in: block) { literal in
            names.formUnion(literalCaptures[runtimeLiteralName(literal.position)] ?? [])
        }
        return names
    }

    /// A function as a value: the name of the function to call, and what is
    /// passed to it before the arguments of a call. `GoValue` has no case
    /// for a function, so it is a struct of a type no program can name.
    mutating func functionValue(symbol: String, bound: [Int] = []) -> Int {
        let destination = allocateRegister()
        operations.append(
            .makeStruct(
                destination: destination,
                typeName: GoPredeclared.functionValueTypeName,
                fieldNames: [GoPredeclared.functionValueSymbolField] + bound.indices.map(String.init),
                values: [constant(.string(symbol))] + bound))
        return destination
    }

    /// A function literal as a value. Its body becomes a function of the
    /// program, scheduled here, where the variables it captures are known:
    /// the value holds a pointer to each.
    mutating func lowerFunctionLiteral(
        parameters: [GoParameter], resultNames: [String?], resultTypes: [GoTypeExpression],
        body: GoBlock, position: GoSourcePosition
    ) throws -> Int {
        let name = runtimeLiteralName(position)
        let symbol = functionSymbolNames[name] ?? name
        let captures = (literalCaptures[name] ?? []).compactMap { captured in
            lookup(captured).map { (name: captured, binding: $0) }
        }
        if nativeWrappers[symbol] == nil, scheduledLiterals.insert(symbol).inserted {
            pendingLiterals.append(
                PendingLiteral(
                    declaration: GoFunctionDeclaration(
                        name: name, parameters: parameters, resultNames: resultNames,
                        resultTypes: resultTypes, body: body, position: position),
                    symbol: symbol,
                    captures: captures.map { ($0.name, $0.binding.type) }))
        }
        let pointers = captures.map { capture -> Int in
            let pointer = allocateRegister()
            operations.append(
                .address(destination: pointer, local: capture.binding.register, fieldPath: []))
            return pointer
        }
        return functionValue(symbol: symbol, bound: pointers)
    }

    /// `base.name` with the embedded fields between the two written out,
    /// when an embedded field lends the struct `base` is the field or the
    /// method `name`; nil when the struct has the name itself. The checker
    /// has refused a name two fields lend alike. A method of the run-time
    /// library that is selected and not called is left to the method
    /// declared for it, which is a function where the library's is none.
    func promotedSelector(
        base: GoExpression, baseType: GoType, name: String, position: GoSourcePosition,
        isCalled: Bool = false, isStarted: Bool = false
    ) -> GoExpression? {
        guard
            case .found(let promotion) = GoEmbedding.promotion(
                of: name, in: baseType, definitions: typeDefinitions)
        else { return nil }
        // The method declared for the promoted one does where the VM
        // needs a function to name: for a method of the library that is
        // not called, and for one of an interface that `go` or `defer`
        // starts.
        if promotion.isMethod,
            promotion.holderKind == .library && !isCalled
                || promotion.holderKind == .interface && isStarted,
            (try? methodInfo(base: base, name: name)) != nil
        {
            return nil
        }
        return promotion.selector(name, of: base, position: position)
    }

    /// The same for a selector whose base is yet to be typed. `isStarted`
    /// says that a `go` or `defer` statement calls it.
    func promotedSelector(
        _ expression: GoExpression, isCalled: Bool = false, isStarted: Bool = false
    ) -> GoExpression? {
        guard case .selector(let base, let name, let position) = expression,
            let baseType = try? type(of: base)
        else { return nil }
        return promotedSelector(
            base: base, baseType: baseType, name: name, position: position, isCalled: isCalled,
            isStarted: isStarted)
    }

    // What follows asks `promotedSelector` on behalf of a function that
    // lowers or types every kind of selector or call, and hands back what
    // that function returns: the frames of those, which nest as deeply as
    // expressions do, keep nothing for a name that nobody lends.

    /// The type of `expression`, a selection from a value of `baseType`
    /// or, without one, a call, when an embedded field lends what is
    /// selected or called.
    func promotedType(_ expression: GoExpression, baseType: GoType?) throws -> GoType? {
        if let baseType {
            guard case .selector(let base, let name, let position) = expression,
                let promoted = promotedSelector(
                    base: base, baseType: baseType, name: name, position: position)
            else { return nil }
            return try type(of: promoted)
        }
        guard case .call(let callee, let arguments, let position) = expression,
            let promoted = promotedSelector(callee, isCalled: true)
        else { return nil }
        return try type(of: .call(callee: promoted, arguments: arguments, position: position))
    }

    /// The value of the selection `expression`, or with `address` a
    /// pointer to what it selects, when an embedded field lends the name.
    mutating func lowerPromotedSelector(
        _ expression: GoExpression, address: Bool = false
    ) throws -> Int? {
        guard let promoted = promotedSelector(expression) else { return nil }
        return try address ? lowerAddress(of: promoted) : lower(promoted)
    }

    /// Stores `value` in `target`, a selection from a value of `baseType`,
    /// when an embedded field lends the field; false when none does.
    mutating func storePromoted(
        _ value: Int, to target: GoExpression, baseType: GoType
    ) throws -> Bool {
        guard case .selector(let base, let name, let position) = target,
            let promoted = promotedSelector(
                base: base, baseType: baseType, name: name, position: position)
        else { return false }
        try store(value, to: promoted)
        return true
    }

    /// `pinned` for a target that an embedded field lends.
    mutating func pinnedPromotedSelector(_ target: GoExpression) throws -> GoExpression? {
        guard let promoted = promotedSelector(target) else { return nil }
        return try pinned(promoted)
    }

    /// A register for each result of the call of `callee` when an embedded
    /// field lends what is called, a method or a field that holds a
    /// function; nil when the callee is anything else.
    mutating func lowerPromotedCall(
        callee: GoExpression, arguments: [GoExpression]
    ) throws -> [Int]? {
        guard let promoted = promotedSelector(callee, isCalled: true) else { return nil }
        if multiReturnTypes(callee: promoted).count > 1,
            let results = try lowerMultiReturnCall(callee: promoted, arguments: arguments)
        {
            return results
        }
        return try lowerCall(callee: promoted, arguments: arguments).map { [$0] } ?? []
    }

    /// Lowers the `go` or `defer` statement `statement` when it starts a
    /// method an embedded field lends; false when it starts anything else.
    mutating func lowerStartedPromotedCall(_ statement: GoStatement) throws -> Bool {
        let started: GoExpression
        switch statement {
        case .deferStatement(let expression, _), .goStatement(let expression, _):
            started = expression
        default:
            return false
        }
        guard case .call(let callee, let arguments, let callPosition) = started,
            let promoted = promotedSelector(callee, isCalled: true, isStarted: true)
        else { return false }
        let call = GoExpression.call(callee: promoted, arguments: arguments, position: callPosition)
        switch statement {
        case .deferStatement(_, let position):
            try lowerDeferStatement(.deferStatement(expression: call, position: position))
        case .goStatement(_, let position):
            try lowerGoStatement(.goStatement(expression: call, position: position))
        default:
            break
        }
        return true
    }

    /// The method `T.m` or `(*T).m` names and the receiver it is written
    /// to take, or nil when `base` names no type of the program.
    func methodExpression(
        base: GoExpression, name: String
    ) -> (info: MethodInfo, receiverType: GoType)? {
        guard let receiver = GoMethodExpression.receiver(of: base),
            lookup(receiver.typeName) == nil, globalInfos[receiver.typeName] == nil,
            typeDefinitions[receiver.typeName] != nil
        else { return nil }
        let value = methodInfos[methodKey(baseName: receiver.typeName, pointer: false, method: name)]
        let pointer = methodInfos[methodKey(baseName: receiver.typeName, pointer: true, method: name)]
        guard let info = value ?? (receiver.pointer ? pointer : nil) else { return nil }
        return (
            info,
            receiver.pointer ? .pointer(.named(receiver.typeName)) : .named(receiver.typeName)
        )
    }

    /// The function a method expression is: the method itself, or, for
    /// `(*T).m` with `m` declared on `T`, one that takes the pointer and
    /// calls the method with what it points to.
    mutating func methodExpressionSymbol(_ method: (info: MethodInfo, receiverType: GoType)) -> String {
        guard method.receiverType != method.info.receiverType else { return method.info.functionName }
        let name = "$native.\(wrapperNamespace).$deref.\(method.info.functionName)"
        if nativeWrappers[name] == nil {
            let parameterCount = method.info.parameterCount + 1
            let receiver = parameterCount
            let destinations = (0..<method.info.returnCount).map { receiver + 1 + $0 }
            nativeWrappers[name] = GoIRFunction(
                name: name,
                parameterCount: parameterCount,
                returnCount: destinations.count,
                registerCount: receiver + 1 + destinations.count,
                operations: [
                    .dereference(destination: receiver, pointer: 0),
                    .call(
                        function: method.info.functionName,
                        arguments: [receiver] + Array(1..<parameterCount),
                        destinations: destinations),
                    destinations.isEmpty ? .return : .returnValues(sources: destinations),
                ])
        }
        return name
    }

    /// The function a method value of an interface is: it takes the
    /// interface value and the arguments, and calls the method `method` of
    /// whatever the value holds.
    mutating func interfaceMethodFunction(
        _ method: String, parameterCount: Int, resultCount: Int
    ) -> String {
        let name = "$native.\(wrapperNamespace).$method.\(method).\(parameterCount).\(resultCount)"
        if nativeWrappers[name] == nil {
            let count = parameterCount + 1
            let destinations = (0..<resultCount).map { count + $0 }
            nativeWrappers[name] = GoIRFunction(
                name: name,
                parameterCount: count,
                returnCount: resultCount,
                registerCount: count + resultCount,
                operations: [
                    .callInterface(
                        method: method, receiver: 0, arguments: Array(1..<count),
                        destinations: destinations),
                    destinations.isEmpty ? .return : .returnValues(sources: destinations),
                ])
        }
        return name
    }

    /// Whether `callee` is a literal that is a function of the program
    /// already: one a `go` or `defer` statement calls that captures
    /// nothing. Such a literal is called by its name, as it always was.
    func isLiftedLiteral(_ callee: GoExpression) -> Bool {
        guard case .functionLiteral(_, _, _, _, let position) = callee else { return false }
        return functionParameterTypes[runtimeLiteralName(position)] != nil
    }

    /// What `callee` takes and gives when it is a value of function type:
    /// a variable, a field, or what another expression yields. Nil for the
    /// name of a function or a method, which is called directly.
    func valueCallSignature(_ callee: GoExpression) -> (parameters: [GoType], results: [GoType])? {
        let calleeType: GoType?
        switch callee {
        case .identifier(let name, _):
            calleeType = lookup(name)?.type ?? globalInfos[name]?.type
        case .selector(let base, let name, _):
            if methodExpression(base: base, name: name) != nil {
                calleeType = try? type(of: callee)
                break
            }
            guard let baseType = try? type(of: base) else { return nil }
            if let promoted = promotedSelector(
                base: base, baseType: baseType, name: name, position: callee.position,
                isCalled: true)
            {
                return valueCallSignature(promoted)
            }
            calleeType = structFields(of: baseType)?.first { $0.name == name }?.type
        default:
            calleeType = try? type(of: callee)
        }
        guard let calleeType, case .function(let parameters, let results) = underlying(calleeType)
        else { return nil }
        return (parameters, results)
    }

    /// What a method of an interface value takes and gives, when `callee`
    /// selects one. `defer i.m(x)` and `go i.m(x)` start it through its
    /// method value: the interface and the arguments are read at the
    /// statement, and which method it is, is found when the call runs.
    func interfaceMethodSignature(
        _ callee: GoExpression
    ) -> (parameters: [GoType], results: [GoType])? {
        guard case .selector(let base, let name, _) = callee,
            let baseType = try? type(of: base),
            case .interface(let methods) = underlying(baseType),
            let method = methods.first(where: { $0.name == name })
        else { return nil }
        return (method.parameters, method.results)
    }

    /// The function value and the arguments of a call through it.
    mutating func lowerValueCallOperands(
        callee: GoExpression, arguments: [GoExpression], parameters: [GoType]
    ) throws -> [Int] {
        let function = try lower(callee)
        return [function] + (try lowerArguments(arguments, parameters: parameters))
    }

    /// A call through a function value, or nil when `callee` is none.
    mutating func lowerValueCall(
        callee: GoExpression, arguments: [GoExpression]
    ) throws -> [Int]? {
        if let results = try lowerPromotedCall(callee: callee, arguments: arguments) {
            return results
        }
        guard let signature = valueCallSignature(callee) else { return nil }
        let operands = try lowerValueCallOperands(
            callee: callee, arguments: arguments, parameters: signature.parameters)
        let destinations = signature.results.map { _ in allocateRegister() }
        operations.append(
            .call(
                function: GoPredeclared.callFunctionValue, arguments: operands,
                destinations: destinations))
        return destinations
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
            if let grouped = declaration.expression?.groupedResult {
                try lowerGroupedGlobals(of: grouped.value, among: declarations)
                continue
            }
            let value: Int
            if let noted = notedConstant(declaration) {
                value = noted
            } else if let expression = declaration.expression {
                value = try lowerConverted(expression, to: global.type)
            } else {
                value = try zeroValue(for: global.type, position: declaration.position)
            }
            operations.append(.storeGlobal(index: global.index, source: value))
        }
        operations.append(.return)
        let lowered = GoIRFunction(
            name: name,
            registerCount: nextRegister,
            operations: operations)
        // A function literal among the initializers is a function too.
        try lowerPendingLiterals()
        return lowered
    }

    mutating func lower(_ block: GoBlock, createsScope: Bool = true) throws {
        if createsScope { scopes.append([:]) }
        defer { if createsScope { scopes.removeLast() } }
        if block.hasLabels {
            try lowerStatements(withLabels: block.statements)
            return
        }
        for statement in block.statements { try lower(statement) }
    }

    mutating func lower(_ statement: GoStatement) throws {
        // Each kind of statement is lowered by a function of its own. In
        // one function, an unoptimized build keeps the locals of every
        // case in every frame, and each nested statement cost the stack of
        // all of them: four levels of nesting filled a 512 KB thread.
        switch statement {
        case .declaration: try lowerDeclaration(statement)
        case .assignment: try lowerAssignment(statement)
        case .multiDeclaration: try lowerMultiDeclaration(statement)
        case .multiAssignment: try lowerMultiAssignment(statement)
        case .increment: try lowerIncrement(statement)
        case .expression(let expression):
            try lowerExpressionStatement(expression)
        case .returnValues: try lowerReturnValues(statement)
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
        case .deferStatement: try lowerDeferStatement(statement)
        case .goStatement: try lowerGoStatement(statement)
        case .sendStatement: try lowerSendStatement(statement)
        case .ifStatement: try lowerIfStatement(statement)
        case .forStatement: try lowerForStatement(statement)
        case .forRangeStatement: try lowerForRangeStatement(statement)
        case .switchStatement: try lowerSwitchStatement(statement)
        case .selectStatement: try lowerSelectStatement(statement)
        }
    }

    mutating func lowerDeclaration(_ statement: GoStatement) throws {
        guard case .declaration(let name, let explicitType, let expression, _, let position) = statement else { return }
        if lowerNotedConstant(statement) { return }
        let variable = allocateRegister()
        let value: Int
        if let expression {
            value = try lowerConverted(expression, to: explicitType.map(resolve))
        } else if let explicitType {
            value = try zeroValue(
                for: resolve(explicitType),
                position: position)
        } else {
            throw GoDiagnostic(position: position, message: "missing variable type or initialization")
        }
        let variableType = try explicitType.map(resolve) ?? expression.map { try type(of: $0) }
        guard let variableType else {
            throw GoDiagnostic(position: position, message: "missing variable type or initialization")
        }
        startVariable(variable, named: name, type: variableType)
        operations.append(.copy(destination: variable, source: value))
        scopes[scopes.count - 1][name] = LoweredBinding(
            register: variable,
            type: variableType)
    }

    mutating func lowerAssignment(_ statement: GoStatement) throws {
        guard case .assignment(let target, let expression, _) = statement else { return }
        if target.isBlank {
            _ = try lower(expression)
            return
        }
        let value = try lowerConverted(expression, to: try? type(of: target))
        try store(value, to: target)
    }

    mutating func lowerMultiDeclaration(_ statement: GoStatement) throws {
        guard case .multiDeclaration(let names, let expression, let position) = statement else { return }
        if let variables = expression.variables {
            if variables.isConstant {
                for (name, value) in zip(names, variables.values) {
                    try lower(
                        .declaration(
                            name: name, explicitType: variables.type, expression: value,
                            isConstant: true, position: position))
                }
                return
            }
            try lowerVariables(
                names, type: variables.type, values: variables.values, position: position)
            return
        }
        if let values = expression.valueList {
            // Every value is read before a name is bound or assigned, so
            // `a, b := b, a` sees the old values.
            var temporaries: [(register: Int, type: GoType)] = []
            for (name, value) in zip(names, values) {
                let existing = name == GoValueList.blank ? nil : scopes[scopes.count - 1][name]
                let temporary = allocateRegister()
                let source = try lowerConverted(value, to: existing?.type)
                let valueType = try existing?.type ?? type(of: value)
                // A new name's temporary becomes its variable.
                if existing == nil { startVariable(temporary, named: name, type: valueType) }
                operations.append(.copy(destination: temporary, source: source))
                temporaries.append((temporary, valueType))
            }
            for (name, temporary) in zip(names, temporaries) where name != GoValueList.blank {
                if let existing = scopes[scopes.count - 1][name] {
                    operations.append(
                        .copy(destination: existing.register, source: temporary.register))
                } else {
                    scopes[scopes.count - 1][name] = LoweredBinding(
                        register: temporary.register, type: temporary.type)
                }
            }
            return
        }
        if let statements = GoStatement.redeclaration(
            names: names, expression: expression, position: position,
            declared: Set(names.filter { scopes[scopes.count - 1][$0] != nil }))
        {
            for statement in statements { try lower(statement) }
            return
        }
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
                startVariable(variable, named: name, type: types[index])
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
                base: try lower(base), key: try lowerKey(key, ofMap: base), zero: zero))
            let registers = [value, ok]
            let types: [GoType] = [valueType, .bool]
            for index in names.indices {
                let variable = allocateRegister()
                startVariable(variable, named: names[index], type: types[index])
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
            guard let targetName = assertedTypeName(type) else {
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
                startVariable(variable, named: name, type: bindingTypes[index])
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
            let bindingType = index < resultTypes.count ? resultTypes[index] : .void
            startVariable(variable, named: name, type: bindingType)
            operations.append(.copy(destination: variable, source: register))
            scopes[scopes.count - 1][name] = LoweredBinding(
                register: variable,
                type: bindingType)
        }
    }

    mutating func lowerMultiAssignment(_ statement: GoStatement) throws {
        guard case .multiAssignment(let targets, let expression, let position) = statement else { return }
        if let values = expression.valueList {
            // Go reads the index and pointer operands on the left and
            // every value on the right first, then assigns in order.
            let pinnedTargets = try targets.map { try pinned($0) }
            var temporaries: [Int] = []
            for (target, value) in zip(targets, values) {
                let temporary = allocateRegister()
                operations.append(
                    .copy(
                        destination: temporary,
                        source: try lowerConverted(
                            value, to: target.isBlank ? nil : try? type(of: target))))
                temporaries.append(temporary)
            }
            for (target, temporary) in zip(pinnedTargets, temporaries) {
                try store(temporary, to: target)
            }
            return
        }
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
                base: try lower(base), key: try lowerKey(key, ofMap: base), zero: zero))
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
            guard let targetName = assertedTypeName(type) else {
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
        let types = multiReturnTypes(callee: callee)
        for (index, (target, register)) in zip(targets, results).enumerated() {
            try store(
                converted(
                    register, from: index < types.count ? types[index] : nil,
                    to: try? type(of: target)),
                to: target)
        }
    }

    mutating func lowerIncrement(_ statement: GoStatement) throws {
        guard case .increment(let target, let incrementOperator, _) = statement else { return }
        if try lowerNumericIncrement(statement) { return }
        let current = try lower(target)
        let one = constant(.int(1))
        let result = allocateRegister()
        operations.append(
            .binary(
                destination: result,
                operator: incrementOperator == .increment ? .add : .subtract,
                left: current,
                right: one))
        try store(wrapByte(result, type: try? type(of: target)), to: target)
    }

    mutating func lowerReturnValues(_ statement: GoStatement) throws {
        guard case .returnValues(let values, _) = statement else { return }
        if values.isEmpty {
            if resultRegisters.isEmpty {
                operations.append(.return)
            } else {
                operations.append(.returnValues(sources: resultRegisters))
            }
        } else if values.count == 1, resultRegisters.count > 1,
            case .call(let callee, let arguments, _) = values[0],
            let results = try lowerMultiReturnCall(callee: callee, arguments: arguments)
        {
            // `return f()` forwards every result of a multi-result call.
            returnValues(results)
        } else {
            let sources = try values.enumerated().map { index, value in
                try lowerConverted(
                    value, to: index < resultTypes.count ? resultTypes[index] : nil)
            }
            returnValues(sources)
        }
    }

    mutating func lowerDeferStatement(_ statement: GoStatement) throws {
        guard case .deferStatement(let expression, let position) = statement else { return }
        guard case .call(let callee, let arguments, let callPosition) = expression else {
            throw GoDiagnostic(position: position, message: "defer requires function call")
        }
        if let forwarded = try forwardedCall(callee: callee, arguments: arguments) {
            // The inner call is made now; its results wait with the call.
            try lowerDeferStatement(
                .deferStatement(
                    expression: .call(
                        callee: forwarded.callee, arguments: forwarded.arguments,
                        position: callPosition),
                    position: position))
            return
        }
        if try lowerStartedPromotedCall(statement) { return }
        if let write = writerFormatCall(callee: callee, arguments: arguments) {
            return try lowerDeferStatement(
                .deferStatement(
                    expression: .call(
                        callee: write.callee, arguments: write.arguments, position: callPosition),
                    position: position))
        }
        if let wrapper = try nativeWrapper(callee: callee, arguments: arguments) {
            operations.append(.deferCall(
                function: wrapper.name, arguments: wrapper.registers))
        } else if !isLiftedLiteral(callee),
            let signature = valueCallSignature(callee) ?? interfaceMethodSignature(callee)
        {
            // The value is read now, with the arguments; the call waits.
            operations.append(
                .deferCall(
                    function: GoPredeclared.callFunctionValue,
                    arguments: try lowerValueCallOperands(
                        callee: callee, arguments: arguments,
                        parameters: signature.parameters)))
        } else if case .identifier(let functionName, _) = callee {
            let registers = try lowerArguments(
                arguments, parameters: functionParameterTypes[functionName])
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
            if let newline = printCall(callee) {
                let registers = try lowerFormatOperands(arguments)
                operations.append(
                    .deferCall(
                        function: printWrapper(newline: newline, operandCount: registers.count),
                        arguments: registers))
            } else {
                let registers = try arguments.map { try lower($0) }
                operations.append(
                    .deferCall(function: "\(packageName).\(member)", arguments: registers))
            }
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
            let registers =
                [receiver] + (try lowerArguments(arguments, parameters: info.parameterTypes))
            operations.append(.deferCall(
                function: info.functionName,
                arguments: registers))
        } else {
            throw GoDiagnostic(position: position, message: "unsupported defer expression")
        }
    }

    mutating func lowerGoStatement(_ statement: GoStatement) throws {
        guard case .goStatement(let expression, let position) = statement else { return }
        guard case .call(let callee, let arguments, let callPosition) = expression else {
            throw GoDiagnostic(position: position, message: "go requires function call")
        }
        if let forwarded = try forwardedCall(callee: callee, arguments: arguments) {
            try lowerGoStatement(
                .goStatement(
                    expression: .call(
                        callee: forwarded.callee, arguments: forwarded.arguments,
                        position: callPosition),
                    position: position))
            return
        }
        if try lowerStartedPromotedCall(statement) { return }
        if let write = writerFormatCall(callee: callee, arguments: arguments) {
            return try lowerGoStatement(
                .goStatement(
                    expression: .call(
                        callee: write.callee, arguments: write.arguments, position: callPosition),
                    position: position))
        }
        if let wrapper = try nativeWrapper(callee: callee, arguments: arguments) {
            operations.append(.spawn(
                function: wrapper.name, arguments: wrapper.registers))
        } else if !isLiftedLiteral(callee),
            let signature = valueCallSignature(callee) ?? interfaceMethodSignature(callee)
        {
            operations.append(
                .spawn(
                    function: GoPredeclared.callFunctionValue,
                    arguments: try lowerValueCallOperands(
                        callee: callee, arguments: arguments,
                        parameters: signature.parameters)))
        } else if case .identifier(let functionName, _) = callee {
            operations.append(.spawn(
                function: functionSymbolNames[functionName] ?? functionName,
                arguments: try lowerArguments(
                    arguments, parameters: functionParameterTypes[functionName])))
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
            if let newline = printCall(callee) {
                let registers = try lowerFormatOperands(arguments)
                operations.append(
                    .spawn(
                        function: printWrapper(newline: newline, operandCount: registers.count),
                        arguments: registers))
            } else {
                operations.append(.spawn(
                    function: "\(packageName).\(member)",
                    arguments: try arguments.map { try lower($0) }))
            }
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
                arguments: [receiver]
                    + (try lowerArguments(arguments, parameters: info.parameterTypes))))
        } else {
            throw GoDiagnostic(position: position, message: "unsupported go expression")
        }
    }

    mutating func lowerSendStatement(_ statement: GoStatement) throws {
        guard case .sendStatement(let channel, let value, _) = statement else { return }
        var elementType: GoType?
        if case .channel(_, let element)? = (try? type(of: channel)).map({ underlying($0) }) {
            elementType = element
        }
        operations.append(.sendChannel(
            channel: try lower(channel),
            value: try lowerConverted(value, to: elementType)))
    }

    mutating func lowerIfStatement(_ statement: GoStatement) throws {
        guard case .ifStatement(let condition, let thenBlock, let elseBlock, _) = statement else { return }
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
    }

    mutating func lowerForStatement(_ statement: GoStatement) throws {
        guard case .forStatement(let initializer, let condition, let post, let body, _) = statement else { return }
        scopes.append([:])
        defer { scopes.removeLast() }
        if let scoped = statement.initialized {
            // An `if` or `switch` with an initializer runs once, and a
            // `break` or `continue` inside it belongs to what encloses it.
            try lower(scoped.initializer)
            try lower(scoped.statement)
            return
        }
        if let block = statement.block {
            try lower(block)
            return
        }
        if let initializer { try lower(initializer) }
        // The variables of the clause, which each iteration has anew.
        let iterationVariables = scopes[scopes.count - 1]
            .filter { mayBeAddressed($0.key, type: $0.value.type) }
            .sorted { $0.value.register < $1.value.register }
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
        for variable in iterationVariables {
            // Go copies each one before the post statement, so a pointer
            // taken in the body keeps the value the iteration ended with.
            let carried = allocateRegister()
            operations.append(.copy(destination: carried, source: variable.value.register))
            renewVariable(variable.value.register)
            operations.append(.copy(destination: variable.value.register, source: carried))
        }
        if let post { try lower(post) }
        operations.append(.jump(target: conditionLabel))
        operations.append(.label(endLabel))
    }

    mutating func lowerForRangeStatement(_ statement: GoStatement) throws {
        guard case .forRangeStatement(let indexName, let valueName, let collection, let body, _) = statement else { return }
        if let ranged = try rangeThroughArrayPointer(statement) {
            return try lowerForRangeStatement(ranged)
        }
        scopes.append([:])
        defer { scopes.removeLast() }

        // Evaluate the collection once. The VM snapshots its keys so map
        // iteration and UTF-8 string offsets use Go-compatible values.
        let collectionRegister = try lower(collection)
        let collectionType = underlying(try type(of: collection))
        if try lowerIntegerRange(
            collection, limit: collectionRegister, indexName: indexName, body: body)
        {
            return
        }
        if case .channel(_, let elementType) = collectionType {
            let receiveLabel = allocateLabel()
            let endLabel = allocateLabel()
            operations.append(.label(receiveLabel))
            let received = allocateRegister()
            let ok = allocateRegister()
            let zero = try zeroValue(for: elementType, position: collection.position)
            if let indexName, mayBeAddressed(indexName, type: elementType) {
                renewVariable(received)
            }
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
        let keyType: GoType
        if case .map(let mapKey, _) = collectionType { keyType = mapKey } else { keyType = .int }
        if let indexName, mayBeAddressed(indexName, type: keyType) {
            renewVariable(keyRegister)
        }
        operations.append(.getIndex(
            destination: keyRegister, base: keysRegister, index: indexRegister))
        if let indexName {
            scopes[scopes.count - 1][indexName] = LoweredBinding(
                register: keyRegister, type: keyType)
        }

        if let valueName {
            let valueRegister = allocateRegister()
            let elementType: GoType
            switch collectionType {
            case .array(_, let element), .slice(let element): elementType = element
            case .map(_, let value): elementType = value
            case .string: elementType = GoPredeclared.rune
            default: elementType = .void
            }
            let zero = try zeroValue(for: elementType, position: collection.position)
            if mayBeAddressed(valueName, type: elementType) { renewVariable(valueRegister) }
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
    }

    mutating func lowerSwitchStatement(_ statement: GoStatement) throws {
        guard case .switchStatement(let expression, let cases, _) = statement else { return }
        if statement.isTypeSwitch {
            try lowerTypeSwitchStatement(statement)
            return
        }
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
            // A clause that ends in `fallthrough` goes on with the next,
            // which is not asked whether it matches.
            let next = switchCase.fallsThrough && index + 1 < cases.count ? index + 1 : nil
            operations.append(.jump(target: next.map { caseLabels[$0] } ?? endLabel))
        }
        breakLabels.removeLast()
        operations.append(.label(endLabel))
    }

    // MARK: Labels and jumps

    /// The statements of a block that has a label. A label names the
    /// statement after it, and is where a `goto` arrives.
    ///
    /// A `goto` may jump over the declaration of a constant, which Go
    /// allows: a constant is no variable. Here it is a local that its
    /// declaration stores, so a label first stores the constants its block
    /// declared before it for whoever arrives by a `goto`; who comes the
    /// ordinary way is jumped around that.
    mutating func lowerStatements(withLabels statements: [GoStatement]) throws {
        var constants: [GoStatement] = []
        var index = 0
        while index < statements.count {
            let statement = statements[index]
            index += 1
            guard let label = statement.label else {
                if hasGoto, statement.declaresConstants { constants.append(statement) }
                try lower(statement)
                continue
            }
            if hasGoto {
                let resume = constants.isEmpty ? nil : allocateLabel()
                if let resume { operations.append(.jump(target: resume)) }
                operations.append(.label(gotoLabel(label)))
                for constant in constants { try storeConstants(of: constant) }
                if let resume { operations.append(.label(resume)) }
            }
            // A label before a label names no loop, `switch`, or `select`.
            if index < statements.count, !statements[index].isLabel {
                try lowerLabeled(statements[index], label: label)
                index += 1
            }
        }
    }

    /// Stores the constants `declaration` declared in their locals again.
    mutating func storeConstants(of declaration: GoStatement) throws {
        switch declaration {
        case .declaration(let name, let explicitType, let expression?, _, _):
            guard let binding = lookup(name) else { return }
            let value = try lowerConverted(expression, to: explicitType.map(resolve))
            operations.append(.copy(destination: binding.register, source: value))
        case .multiDeclaration(let names, let expression, _):
            guard let variables = expression.variables else { return }
            let declared = variables.type.map(resolve)
            for (name, value) in zip(names, variables.values) {
                guard let binding = lookup(name) else { continue }
                let source = try lowerConverted(value, to: declared)
                operations.append(.copy(destination: binding.register, source: source))
            }
        default:
            break
        }
    }

    /// Lowers the statement the label `label` names. While it is lowered,
    /// `break label` and `continue label` find the targets it opens: a
    /// loop, a `switch`, and a `select` each push theirs where the label
    /// found the two stacks. The lowerer keeps no table of labels; what one
    /// stands for is in the scope it is written in, under the name of the
    /// jump, which no variable has.
    mutating func lowerLabeled(_ statement: GoStatement, label: String) throws {
        let scope = scopes.count - 1
        let breakName = GoBranch.breakTo(label).calleeName
        let continueName = GoBranch.continueTo(label).calleeName
        scopes[scope][breakName] = LoweredBinding(register: breakLabels.count, type: .void)
        scopes[scope][continueName] = LoweredBinding(register: continueLabels.count, type: .void)
        defer {
            scopes[scope][breakName] = nil
            scopes[scope][continueName] = nil
        }
        try lower(statement)
    }

    /// The IR label a `goto` to the label `name` jumps to, kept in the
    /// scope of the function: a label is the function's.
    mutating func gotoLabel(_ name: String) -> Int {
        let key = GoBranch.label(name).calleeName
        if let known = scopes[0][key] { return known.register }
        let label = allocateLabel()
        scopes[0][key] = LoweredBinding(register: label, type: .void)
        return label
    }

    /// Lowers the statement `expression` when it is a label or a jump the
    /// tree has no case for, and says whether it was one. Whether it is in
    /// place was checked on the tree the parser made.
    mutating func lowerJump(_ expression: GoExpression) throws -> Bool {
        guard let branch = expression.branch else { return false }
        switch branch.kind {
        case .label, .fallthrough:
            // A label is lowered with its block, and a clause that ends in
            // `fallthrough` jumps to the next one.
            break
        case .goto(let name):
            operations.append(.jump(target: gotoLabel(name)))
        case .breakTo(let name):
            guard let depth = lookup(branch.kind.calleeName)?.register, depth < breakLabels.count
            else {
                throw GoDiagnostic(position: branch.position, message: "invalid break label \(name)")
            }
            operations.append(.jump(target: breakLabels[depth]))
        case .continueTo(let name):
            guard let depth = lookup(branch.kind.calleeName)?.register,
                depth < continueLabels.count
            else {
                throw GoDiagnostic(
                    position: branch.position, message: "invalid continue label \(name)")
            }
            operations.append(.jump(target: continueLabels[depth]))
        }
        return true
    }

    /// A type switch: the operand is read once, and each type of a clause
    /// is asked of it as a type assertion with `, ok` is, in the order of
    /// the source; `nil` matches the interface value that holds nothing.
    /// In a clause of one type the name the switch binds is the asserted
    /// value, and in any other the operand itself.
    mutating func lowerTypeSwitchStatement(_ statement: GoStatement) throws {
        guard let typeSwitch = statement.typeSwitch else { return }
        let operand = try lower(typeSwitch.operand)
        let operandType = try type(of: typeSwitch.operand)
        let endLabel = allocateLabel()
        let caseLabels = typeSwitch.cases.map { _ in allocateLabel() }
        // What a failed assertion leaves in its destination, which nothing
        // reads, and what `nil` is compared with.
        let nothing = constant(.nilValue)
        var bound: [(register: Int, type: GoType)?] = Array(
            repeating: nil, count: typeSwitch.cases.count)
        for (index, clause) in typeSwitch.cases.enumerated() {
            for case .typeExpression(let syntax, let position) in clause.expressions {
                let matches = allocateRegister()
                if syntax.isNilCase {
                    operations.append(
                        .binary(destination: matches, operator: .equal, left: operand, right: nothing))
                } else {
                    let type = resolve(syntax)
                    guard let targetName = assertedTypeName(type) else {
                        throw GoDiagnostic(position: position, message: "unsupported asserted type")
                    }
                    let value = allocateRegister()
                    operations.append(
                        .typeAssert(
                            destination: value, okDestination: matches, source: operand,
                            targetName: targetName, zero: nothing))
                    if clause.expressions.count == 1 { bound[index] = (value, type) }
                }
                operations.append(.jumpIfTrue(condition: matches, target: caseLabels[index]))
            }
        }
        let defaultIndex = typeSwitch.cases.firstIndex(where: \.isDefault)
        operations.append(.jump(target: defaultIndex.map { caseLabels[$0] } ?? endLabel))

        breakLabels.append(endLabel)
        for (index, clause) in typeSwitch.cases.enumerated() {
            operations.append(.label(caseLabels[index]))
            scopes.append([:])
            if let name = typeSwitch.binding?.name {
                let source = bound[index] ?? (operand, operandType)
                let variable = allocateRegister()
                startVariable(variable, named: name, type: source.type)
                operations.append(.copy(destination: variable, source: source.register))
                scopes[scopes.count - 1][name] = LoweredBinding(
                    register: variable, type: source.type)
            }
            try lower(clause.body, createsScope: false)
            scopes.removeLast()
            operations.append(.jump(target: endLabel))
        }
        breakLabels.removeLast()
        operations.append(.label(endLabel))
    }

    /// `for i := range n` over an integer, when `collection` is one: `i`
    /// is each integer below `n` in turn, of the type of `n`, which is read
    /// once and is in the register `collection` was lowered to. Go makes
    /// `i` a variable of the iteration, so what the body does to it does
    /// not reach the count. Returns false for any other collection.
    mutating func lowerIntegerRange(
        _ expression: GoExpression, limit collection: Int, indexName: String?, body: GoBlock
    ) throws -> Bool {
        let type = try type(of: expression)
        guard underlying(type) == .int else { return false }
        let limit = allocateRegister()
        operations.append(.copy(destination: limit, source: collection))
        let counter = allocateRegister()
        operations.append(.copy(destination: counter, source: constant(.int(0))))
        let conditionLabel = allocateLabel()
        let postLabel = allocateLabel()
        let endLabel = allocateLabel()
        operations.append(.label(conditionLabel))
        let condition = allocateRegister()
        operations.append(
            .binary(destination: condition, operator: .less, left: counter, right: limit))
        operations.append(.jumpIfFalse(condition: condition, target: endLabel))
        if let indexName, indexName != GoValueList.blank {
            let variable = allocateRegister()
            if mayBeAddressed(indexName, type: type) { renewVariable(variable) }
            operations.append(.copy(destination: variable, source: counter))
            scopes[scopes.count - 1][indexName] = LoweredBinding(register: variable, type: type)
        }
        breakLabels.append(endLabel)
        continueLabels.append(postLabel)
        try lower(body)
        breakLabels.removeLast()
        continueLabels.removeLast()
        operations.append(.label(postLabel))
        let incremented = allocateRegister()
        operations.append(
            .binary(
                destination: incremented, operator: .add, left: counter, right: constant(.int(1))))
        operations.append(.copy(destination: counter, source: incremented))
        operations.append(.jump(target: conditionLabel))
        operations.append(.label(endLabel))
        return true
    }

    mutating func lowerSelectStatement(_ statement: GoStatement) throws {
        guard case .selectStatement(let cases, _) = statement else { return }
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

    mutating func lowerExpressionStatement(_ expression: GoExpression) throws {
        if try lowerJump(expression) { return }
        if case .call(let callee, let arguments, let position) = expression {
            if let forwarded = try forwardedCall(callee: callee, arguments: arguments) {
                try lowerExpressionStatement(
                    .call(
                        callee: forwarded.callee, arguments: forwarded.arguments,
                        position: position))
                return
            }
            if let write = writerFormatCall(callee: callee, arguments: arguments) {
                _ = try lowerCall(callee: write.callee, arguments: write.arguments)
                return
            }
            if let native = nativeFunction(for: callee),
                let symbol = native.function.statementSymbol
            {
                // Nobody reads the results, so the VM is asked for none.
                operations.append(
                    .call(
                        function: symbol,
                        arguments: try lowerNativeOperands(
                            native.function, receiver: native.receiver, arguments: arguments),
                        destinations: []))
                return
            }
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
        if let forwarded = try lowerForwardingCall(callee: callee, arguments: arguments) {
            return forwarded
        }
        if let operation = GoExpression.call(
            callee: callee, arguments: arguments, position: callee.position
        ).bitwiseOperation {
            return try lowerBitwise(operation.operator, operands: operation.operands)
        }
        if let target = conversionTarget(callee), let argument = arguments.first {
            return try lowerConversion(to: target, argument: argument)
        }
        if let results = try lowerPredeclaredCall(callee: callee, arguments: arguments) {
            return results.first
        }
        if let results = try lowerNativeCall(callee: callee, arguments: arguments) {
            return results.first
        }
        if let results = try lowerValueCall(callee: callee, arguments: arguments) {
            return results.first
        }
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
                // The parameter of `panic` is an `interface{}`: the value
                // keeps its type, which `recover` and a crash report read.
                let source = try lowerConverted(argument, to: .interface([]))
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
                let key = try lowerKey(arguments[1], ofMap: arguments[0])
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
            if functionName == "copy" {
                guard arguments.count == 2 else { return nil }
                let target = try lower(arguments[0])
                let source = try lower(arguments[1])
                let destination = allocateRegister()
                operations.append(
                    .call(
                        function: GoPredeclared.copyElements,
                        arguments: [target, source],
                        destinations: [destination]))
                return destination
            }
            if functionName == "append" {
                guard let first = arguments.first,
                    case .slice(let elementType) = underlying(try type(of: first))
                else { return nil }
                var slice = try lower(first)
                let zero = try zeroValue(for: elementType, position: first.position)
                if arguments.count == 2, let source = arguments[1].spreadOperand {
                    let destination = allocateRegister()
                    operations.append(
                        .call(
                            function: GoPredeclared.appendElements,
                            arguments: [slice, try lower(source), zero],
                            destinations: [destination]))
                    return destination
                }
                for argument in arguments.dropFirst() {
                    let destination = allocateRegister()
                    operations.append(
                        .append(
                            destination: destination,
                            slice: slice,
                            value: try lowerConverted(argument, to: elementType),
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
            // An argument passed to an interface parameter is converted.
            let registers = try lowerArguments(
                arguments, parameters: functionParameterTypes[functionName])
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
            if builtin == .fmtPrint || builtin == .fmtPrintln {
                operations.append(
                    .print(
                        arguments: try lowerFormatOperands(arguments),
                        newline: builtin == .fmtPrintln))
                return nil
            }
            let registers = try arguments.map { try lower($0) }
            switch builtin {
            case .fmtPrint, .fmtPrintln:
                // Lowered above, with their operands boxed.
                break
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
                // The instruction names the handler: a function of the
                // program, or a literal, which is one once it is lowered.
                let handlerName: String
                switch arguments[1] {
                case .identifier(let name, _) where lookup(name) == nil && functionParameterTypes[name] != nil:
                    handlerName = functionSymbolNames[name] ?? name
                case .functionLiteral(_, _, _, _, let position):
                    let name = runtimeLiteralName(position)
                    handlerName = functionSymbolNames[name] ?? name
                default:
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
            case .userlandReadStdin:
                let data = allocateRegister()
                let status = allocateRegister()
                operations.append(.readStdin(
                    dataDestination: data, statusDestination: status))
                return data
            case .userlandWriteFile:
                let status = allocateRegister()
                operations.append(.writeFile(
                    destination: status, path: registers[0], data: registers[1]))
                return status
            case .userlandSetRawMode:
                let applied = allocateRegister()
                operations.append(.setRawMode(destination: applied, enabled: registers[0]))
                return applied
            case .userlandWindowSize:
                let rows = allocateRegister()
                let columns = allocateRegister()
                operations.append(.windowSize(
                    rowsDestination: rows, columnsDestination: columns))
                return rows
            case .strings(let function):
                let destination = allocateRegister()
                operations.append(.stringsCall(
                    destination: destination, function: function, arguments: registers))
                return destination
            }
            return nil
        }
        // Local package function call: pkg.Function(args...)
        if case .selector(let base, let member, _) = callee,
            case .identifier(let packageName, _) = base,
            GoStandardLibrary.resolve(package: packageName, member: member) == nil,
            lookup(packageName) == nil, globalInfos[packageName] == nil
        {
            // Check if this is a known imported package function (not fmt, not a method)
            let mangledName = packageName + "." + member
            if functionReturnCounts[mangledName] != nil || functionParameterTypes[mangledName] != nil {
                let registers = try lowerArguments(
                    arguments, parameters: functionParameterTypes[mangledName])
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
                let argRegisters = try lowerArguments(arguments, parameters: method.parameters)
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
            let receiver = try lowerReceiver(of: info, base: base, baseType: try type(of: base))
            let registers =
                [receiver] + (try lowerArguments(arguments, parameters: info.parameterTypes))
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

    /// What a method takes for its receiver from `base`: its address for a
    /// pointer receiver, its value for a value receiver.
    mutating func lowerReceiver(
        of info: MethodInfo, base: GoExpression, baseType: GoType
    ) throws -> Int {
        if case .pointer = info.receiverType {
            if case .pointer = baseType { return try lower(base) }
            return try lowerAddress(of: base)
        }
        if case .pointer = baseType {
            let pointer = try lower(base)
            let value = allocateRegister()
            operations.append(.dereference(destination: value, pointer: pointer))
            return value
        }
        return try lower(base)
    }

    /// Whether `callee` is `fmt.Println` (true) or `fmt.Print` (false), or
    /// nil for anything else.
    func printCall(_ callee: GoExpression) -> Bool? {
        guard case .selector(.identifier("fmt", _), let member, _) = callee,
            lookup("fmt") == nil, globalInfos["fmt"] == nil,
            member == "Print" || member == "Println"
        else { return nil }
        return member == "Println"
    }

    func multiReturnTypes(callee: GoExpression) -> [GoType] {
        if let promoted = promotedSelector(callee, isCalled: true) {
            return multiReturnTypes(callee: promoted)
        }
        if let native = nativeFunction(for: callee) {
            return native.function.results
        }
        if printCall(callee) != nil { return [.int, GoPredeclared.errorType] }
        if let signature = valueCallSignature(callee) { return signature.results }
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
                return [.named("net.Conn"), GoPredeclared.errorType]
            case .netListen:
                return [.named("net.Listener"), GoPredeclared.errorType]
            case .netLookupHost:
                return [.slice(.string), GoPredeclared.errorType]
            case .httpGet:
                return [.named("http.Response"), GoPredeclared.errorType]
            case .strconvAtoi:
                return [.int, GoPredeclared.errorType]
            case .userlandReadInput:
                return [.string, .int]
            case .userlandReadStdin:
                return [.string, .int]
            case .userlandWindowSize:
                return [.int, .int]
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
                return [.int, GoPredeclared.errorType]
            case ("net.Listener", "Accept"):
                return [.named("net.Conn"), GoPredeclared.errorType]
            default:
                break
            }
        }
        if case .selector(let base, let name, _) = callee,
            let info = try? methodInfo(base: base, name: name)
        {
            return info.resultTypes
        }
        if case .selector(let base, let name, _) = callee,
            let baseType = try? type(of: base),
            case .interface(let methods) = underlying(baseType),
            let method = methods.first(where: { $0.name == name })
        {
            return method.results
        }
        return []
    }

    mutating func lowerMultiReturnCall(
        callee: GoExpression,
        arguments: [GoExpression]
    ) throws -> [Int]? {
        if let forwarded = try lowerForwardingMultiReturnCall(
            callee: callee, arguments: arguments)
        {
            return forwarded
        }
        if let results = try lowerNativeCall(callee: callee, arguments: arguments) {
            return results
        }
        if let newline = printCall(callee) {
            let destinations = [allocateRegister(), allocateRegister()]
            operations.append(
                .call(
                    function: GoStandardLibrary.printCountSymbol(newline: newline),
                    arguments: try lowerFormatOperands(arguments),
                    destinations: destinations))
            return destinations
        }
        if let results = try lowerValueCall(callee: callee, arguments: arguments) {
            return results
        }
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
            case .userlandReadStdin:
                let data = allocateRegister()
                let status = allocateRegister()
                operations.append(.readStdin(
                    dataDestination: data, statusDestination: status))
                return [data, status]
            case .userlandWindowSize:
                let rows = allocateRegister()
                let columns = allocateRegister()
                operations.append(.windowSize(
                    rowsDestination: rows, columnsDestination: columns))
                return [rows, columns]
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
            let registers = try lowerArguments(
                arguments, parameters: functionParameterTypes[functionName])
            let destinations = (0..<returnCount).map { _ in allocateRegister() }
            operations.append(
                .call(
                    function: functionSymbolNames[functionName] ?? functionName,
                    arguments: registers,
                    destinations: destinations))
            return destinations
        }
        // A method of an interface value, found when the call runs.
        if case .selector(let base, let member, _) = callee,
            let baseType = try? type(of: base),
            case .interface(let methods) = underlying(baseType),
            let method = methods.first(where: { $0.name == member })
        {
            guard method.results.count > 1 else { return nil }
            let receiver = try lower(base)
            let registers = try lowerArguments(arguments, parameters: method.parameters)
            let destinations = method.results.map { _ in allocateRegister() }
            operations.append(
                .callInterface(
                    method: member,
                    receiver: receiver,
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
            let registers =
                [receiver] + (try lowerArguments(arguments, parameters: info.parameterTypes))
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
        // One function for each kind of expression, like the statements:
        // an expression inside an expression then costs the frame of its
        // own kind, not of all of them.
        if let number = try lowerNumeric(expression) { return number }
        switch expression {
        case .integer(let value, _):
            return constant(.int(value))
        case .string(let value, _):
            return constant(.string(value))
        case .identifier: return try lowerIdentifierExpression(expression)
        case .unary: return try lowerUnaryExpression(expression)
        case .binary: return try lowerBinaryExpression(expression)
        case .selector: return try lowerSelectorExpression(expression)
        case .typeAssertion: return try lowerTypeAssertionExpression(expression)
        case .functionLiteral(
            let parameters, let resultNames, let resultTypes, let body, let position):
            return try lowerFunctionLiteral(
                parameters: parameters, resultNames: resultNames, resultTypes: resultTypes,
                body: body, position: position)
        case .compositeLiteral: return try lowerCompositeLiteralExpression(expression)
        case .index: return try lowerIndexExpression(expression)
        case .slicing: return try lowerSlicingExpression(expression)
        case .typeExpression(_, let position):
            throw GoDiagnostic(position: position, message: "type is not a value")
        case .call(let callee, let arguments, let position):
            guard let destination = try lowerCall(callee: callee, arguments: arguments) else {
                throw GoDiagnostic(position: position, message: "no value used as value")
            }
            return destination
        }
    }

    mutating func lowerIdentifierExpression(_ expression: GoExpression) throws -> Int {
        guard case .identifier(let name, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
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
        if functionParameterTypes[name] != nil || functionReturnCounts[name] != nil {
            // A function of the program, as a value.
            return functionValue(symbol: functionSymbolNames[name] ?? name)
        }
        throw GoDiagnostic(position: position, message: "undefined: \(name)")
    }

    mutating func lowerUnaryExpression(_ expression: GoExpression) throws -> Int {
        guard case .unary(let unaryOperator, let operand, _) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
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
            return wrapByte(destination, type: try? type(of: operand))
        case .not:
            let source = try lower(operand)
            let destination = allocateRegister()
            operations.append(.unary(destination: destination, operator: .not, operand: source))
            return destination
        case .address:
            if case .compositeLiteral = operand {
                let destination = allocateRegister()
                operations.append(
                    .call(
                        function: GoPredeclared.newVariable,
                        arguments: [try lower(operand)],
                        destinations: [destination]))
                return destination
            }
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
    }

    mutating func lowerBinaryExpression(_ expression: GoExpression) throws -> Int {
        guard case .binary(let left, let binaryOperator, let right, _) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        if binaryOperator == .logicalAnd || binaryOperator == .logicalOr {
            return try lowerShortCircuit(
                left: left,
                operator: binaryOperator,
                right: right)
        }
        let leftRegister = try lower(left)
        let rightRegister = comparand(try lower(right), right, against: left, by: binaryOperator)
        let destination = allocateRegister()
        operations.append(
            .binary(
                destination: destination,
                operator: map(binaryOperator),
                left: leftRegister,
                right: rightRegister))
        switch binaryOperator {
        case .add, .subtract, .multiply:
            return wrapByte(destination, type: try? operandType(left, right))
        default:
            return destination
        }
    }

    mutating func lowerSelectorExpression(_ expression: GoExpression) throws -> Int {
        guard case .selector(let base, let name, _) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        if case .identifier(let packageName, _) = base,
            let value = GoStandardLibrary.integerConstant(
                package: packageName, member: name)
        {
            return constant(.int(value))
        }
        if let message = standardErrorValue(base: base, member: name) {
            let destination = allocateRegister()
            operations.append(
                .makeInterface(
                    destination: destination,
                    source: constant(.string(message)),
                    typeName: GoPredeclared.nativeErrorTypeName))
            return destination
        }
        if let descriptor = standardFileDescriptor(base: base, member: name) {
            return constant(.int(descriptor))
        }
        if case .identifier("os", _) = base, name == "Args" {
            let destination = allocateRegister()
            operations.append(.osArgs(destination: destination))
            return destination
        }
        if let method = methodExpression(base: base, name: name) {
            return functionValue(symbol: methodExpressionSymbol(method))
        }
        if let function = try lowerLibraryFunctionValue(base: base, member: name) {
            return function
        }
        if let lent = try lowerPromotedSelector(expression) { return lent }
        if let baseType = try? type(of: base),
            case .interface(let methods) = underlying(baseType),
            let method = methods.first(where: { $0.name == name })
        {
            // A method of an interface value that is not called: which
            // method it is depends on the value, so it is found when
            // the function is called.
            let receiver = try lower(base)
            operations.append(
                .call(function: GoPredeclared.requireValue, arguments: [receiver], destinations: []))
            return functionValue(
                symbol: interfaceMethodFunction(
                    name, parameterCount: method.parameters.count,
                    resultCount: method.results.count),
                bound: [receiver])
        }
        if let baseType = try? type(of: base),
            structFields(of: baseType)?.contains(where: { $0.name == name }) != true,
            let info = try methodInfo(base: base, name: name)
        {
            // A method that is not called: a function that already has
            // its receiver, read now as a call would read it.
            return functionValue(
                symbol: info.functionName,
                bound: [try lowerReceiver(of: info, base: base, baseType: baseType)])
        }
        if let method = try lowerLibraryMethodValue(base: base, member: name) {
            return method
        }
        var baseRegister = try lower(base)
        if try type(of: base).pointee(in: typeDefinitions) != nil {
            let dereferenced = allocateRegister()
            operations.append(.dereference(destination: dereferenced, pointer: baseRegister))
            baseRegister = dereferenced
        }
        let destination = allocateRegister()
        operations.append(
            .getField(destination: destination, base: baseRegister, name: name))
        return destination
    }

    mutating func lowerTypeAssertionExpression(_ expression: GoExpression) throws -> Int {
        guard case .typeAssertion(let base, let assertedType, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        let type = resolve(assertedType)
        guard let targetName = assertedTypeName(type) else {
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
    }

    mutating func lowerCompositeLiteralExpression(_ expression: GoExpression) throws -> Int {
        guard case .compositeLiteral(let typeExpression, let elements, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        let literalType = resolve(typeExpression)
        let destination = allocateRegister()
        switch underlying(literalType) {
        case .structure(let fields):
            var values: [Int] = []
            if elements.isEmpty || elements.contains(where: { $0.key != nil }) {
                // Fields a literal does not name, all of them in `T{}`,
                // have their zero values.
                let keyed = Dictionary(
                    uniqueKeysWithValues: elements.compactMap { element in
                        element.key.map { ($0, element.value) }
                    })
                for field in fields {
                    if let expression = keyed[field.name] {
                        values.append(try lowerConverted(expression, to: field.type))
                    } else {
                        values.append(try zeroValue(for: field.type, position: position))
                    }
                }
            } else {
                values = try elements.enumerated().map { index, element in
                    try lowerConverted(
                        element.value, to: index < fields.count ? fields[index].type : nil)
                }
            }
            operations.append(
                .makeStruct(
                    destination: destination,
                    typeName: typeName(of: literalType),
                    fieldNames: fields.map(\.name),
                    values: values))
        case .array(let length, let elementType):
            var values = try lowerListElements(elements, element: elementType, position: position)
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
                    values: try lowerListElements(
                        elements, element: elementType, position: position)))
        case .map(let keyType, let valueType):
            var keys: [Int] = []
            var values: [Int] = []
            for element in elements {
                if let keyExpression = element.keyExpression {
                    keys.append(try lowerConverted(keyExpression, to: keyType))
                } else if let key = element.key {
                    keys.append(constant(.string(key)))
                } else {
                    throw GoDiagnostic(position: element.position, message: "missing key in map literal")
                }
                values.append(try lowerConverted(element.value, to: valueType))
            }
            operations.append(.makeMap(destination: destination, keys: keys, values: values))
        default:
            throw GoDiagnostic(position: position, message: "invalid composite literal type")
        }
        return destination
    }

    mutating func lowerIndexExpression(_ expression: GoExpression) throws -> Int {
        guard case .index(let base, let index, _) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        if let followed = throughArrayPointer(indexOrSlice: expression) {
            return try lowerIndexExpression(followed)
        }
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
                    key: try lowerKey(index, ofMap: base),
                    zero: zero))
        } else {
            operations.append(
                .getIndex(
                    destination: destination,
                    base: try lower(base),
                    index: try lower(index)))
        }
        return destination
    }

    mutating func lowerSlicingExpression(_ expression: GoExpression) throws -> Int {
        guard case .slicing(let base, let low, let high, let position) = expression else {
            throw GoDiagnostic(position: expression.position, message: "unsupported expression")
        }
        if let followed = throughArrayPointer(indexOrSlice: expression) {
            return try lowerSlicingExpression(followed)
        }
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
    }

    /// Whether a pointer can reach a variable `name` of `type` somewhere in
    /// the function being lowered. See `GoAddressedVariables`.
    func mayBeAddressed(_ name: String, type: GoType) -> Bool {
        guard name != GoValueList.blank, !name.hasPrefix("$") else { return false }
        if addressedVariables.addressed.contains(name) { return true }
        if addressedVariables.sliced.contains(name), case .array = underlying(type) { return true }
        if case .named(let typeName) = type,
            let methods = addressedVariables.receivers[name],
            methods.contains(where: {
                methodInfos[methodKey(baseName: typeName, pointer: true, method: $0)] != nil
            })
        {
            return true
        }
        if let methods = addressedVariables.receivers[name], lendsPointerMethod(type, among: methods) {
            return true
        }
        if let methods = addressedVariables.nestedReceivers[name] {
            // A method of something inside the variable: one with a pointer
            // receiver, whatever its type, takes an address within it.
            return methodInfos.keys.contains { key in
                key.hasPrefix("*") && methods.contains { key.hasSuffix("." + $0) }
            }
        }
        return false
    }

    /// Whether an embedded field lends a struct of `type` one of `methods`
    /// that takes the address of the field, and so of the struct.
    func lendsPointerMethod(_ type: GoType, among methods: Set<String>) -> Bool {
        methods.contains { method in
            guard
                case .found(let promotion) = GoEmbedding.promotion(
                    of: method, in: type, definitions: typeDefinitions)
            else { return false }
            return promotion.isMethod && promotion.hasPointerReceiver && !promotion.isIndirect
        }
    }

    /// Makes `register` a new variable before a declaration stores in it,
    /// when a loop can reach the declaration again and a pointer can reach
    /// the variable: each iteration then has its own, as in Go.
    mutating func startVariable(_ register: Int, named name: String, type: GoType) {
        guard !continueLabels.isEmpty || jumpsBackward, mayBeAddressed(name, type: type) else {
            return
        }
        renewVariable(register)
    }

    /// Unbinds `register` from its storage cell; the next store allocates one.
    mutating func renewVariable(_ register: Int) {
        operations.append(
            .call(
                function: GoPredeclared.freshVariable + String(register),
                arguments: [], destinations: []))
    }

    /// `var a, b T`, `var a, b = x, y`, and `var n, err = f()`. The values
    /// are all read before a name is bound, so none sees another.
    mutating func lowerVariables(
        _ names: [String],
        type: GoTypeExpression?,
        values: [GoExpression],
        position: GoSourcePosition
    ) throws {
        let declared = type.map(resolve)
        if values.count == 1, names.count > 1 {
            try lower(.multiDeclaration(names: names, expression: values[0], position: position))
            return
        }
        var variables: [(register: Int, type: GoType)] = []
        for index in names.indices {
            let variable = allocateRegister()
            if index < values.count {
                let source = try lowerConverted(values[index], to: declared)
                let valueType = try declared ?? self.type(of: values[index])
                startVariable(variable, named: names[index], type: valueType)
                operations.append(.copy(destination: variable, source: source))
                variables.append((variable, valueType))
            } else if let declared {
                let source = try zeroValue(for: declared, position: position)
                startVariable(variable, named: names[index], type: declared)
                operations.append(.copy(destination: variable, source: source))
                variables.append((variable, declared))
            } else {
                throw GoDiagnostic(
                    position: position, message: "missing variable type or initialization")
            }
        }
        for (name, variable) in zip(names, variables) where name != GoValueList.blank {
            scopes[scopes.count - 1][name] = LoweredBinding(
                register: variable.register, type: variable.type)
        }
    }

    /// A target of a parallel assignment with its operands read: the index
    /// of `x[i]`, a slice or map that is indexed, and a pointer that is
    /// followed. What remains names a variable, so an assignment to another
    /// target of the same statement cannot change where this one stores.
    mutating func pinned(_ target: GoExpression) throws -> GoExpression {
        switch target {
        case .index(let base, let index, let position):
            let pinnedBase: GoExpression
            if case .array = underlying(try type(of: base)) {
                pinnedBase = try pinned(base)
            } else {
                pinnedBase = try pin(base)
            }
            return .index(base: pinnedBase, index: try pin(index), position: position)
        case .selector(let base, let name, let position):
            if let promoted = try pinnedPromotedSelector(target) { return promoted }
            if try type(of: base).pointee(in: typeDefinitions) != nil {
                return .selector(base: try pin(base), name: name, position: position)
            }
            return .selector(base: try pinned(base), name: name, position: position)
        case .unary(.dereference, let operand, let position):
            return .unary(operator: .dereference, operand: try pin(operand), position: position)
        default:
            return target
        }
    }

    /// Reads `expression` now and returns a name for its value.
    mutating func pin(_ expression: GoExpression) throws -> GoExpression {
        switch expression {
        case .integer, .string: return expression
        default: break
        }
        let valueType = try type(of: expression)
        let temporary = allocateRegister()
        operations.append(.copy(destination: temporary, source: try lower(expression)))
        // `$` cannot start a Go identifier, and the register is the name's own.
        let name = "$pinned.\(temporary)"
        scopes[scopes.count - 1][name] = LoweredBinding(register: temporary, type: valueType)
        return .identifier(name, position: expression.position)
    }

    // MARK: Call results as arguments

    /// The call to lower in place of `callee(arguments)` when its only
    /// argument is a call of several results, which Go passes in order: the
    /// inner call is made here, and its results are the arguments, by name.
    /// Nil for every other call. See `GoForwardedResults`.
    ///
    /// Go makes the calls of an expression in the order the source has
    /// them, so the calls `callee` is made of come first. What else it reads
    /// (the variable that holds the function, a receiver, an element) it
    /// reads when the call is made, after the inner call has run.
    mutating func forwardedCall(
        callee: GoExpression, arguments: [GoExpression]
    ) throws -> (callee: GoExpression, arguments: [GoExpression])? {
        guard let inner = GoForwardedResults.call(in: arguments, of: callee),
            conversionTarget(callee) == nil
        else { return nil }
        let types = multiReturnTypes(callee: inner.callee)
        guard types.count > 1 else { return nil }
        let function = try pinningCalls(in: callee)
        guard
            let results = try lowerMultiReturnCall(
                callee: inner.callee, arguments: inner.arguments),
            results.count == types.count
        else {
            throw GoDiagnostic(
                position: inner.position, message: "function does not return multiple values")
        }
        var operands: [GoExpression] = []
        for (register, type) in zip(results, types) {
            // As `pin` names a value: the register is the name's own.
            let name = "$pinned.\(register)"
            scopes[scopes.count - 1][name] = LoweredBinding(register: register, type: type)
            operands.append(.identifier(name, position: inner.position))
        }
        return (function, operands)
    }

    /// What `lowerCall` gives for such a call, or nil for any other.
    mutating func lowerForwardingCall(
        callee: GoExpression, arguments: [GoExpression]
    ) throws -> Int?? {
        guard let forwarded = try forwardedCall(callee: callee, arguments: arguments) else {
            return nil
        }
        return .some(try lowerCall(callee: forwarded.callee, arguments: forwarded.arguments))
    }

    /// What `lowerMultiReturnCall` gives for such a call, or nil for any
    /// other.
    mutating func lowerForwardingMultiReturnCall(
        callee: GoExpression, arguments: [GoExpression]
    ) throws -> [Int]?? {
        guard let forwarded = try forwardedCall(callee: callee, arguments: arguments) else {
            return nil
        }
        return .some(
            try lowerMultiReturnCall(callee: forwarded.callee, arguments: forwarded.arguments))
    }

    /// `callee` with the calls and channel receives it is made of made now,
    /// each a name for what it gave. A variable, a field, and an element
    /// stay as they are written, to be read when the call is made.
    mutating func pinningCalls(in callee: GoExpression) throws -> GoExpression {
        switch callee {
        case .selector(let base, let name, let position):
            return .selector(base: try pinningCalls(in: base), name: name, position: position)
        case .index(let base, let index, let position):
            return .index(
                base: try pinningCalls(in: base), index: try pinningCalls(in: index),
                position: position)
        case .typeAssertion(let base, let type, let position):
            return .typeAssertion(base: try pinningCalls(in: base), type: type, position: position)
        case .unary(.receive, _, _), .compositeLiteral, .unary(.address, .compositeLiteral, _):
            // `&T{...}` is a new variable each time, and stays one.
            return try pin(callee)
        case .unary(let unaryOperator, let operand, let position):
            return .unary(
                operator: unaryOperator, operand: try pinningCalls(in: operand), position: position)
        case .call(let function, let operands, let position):
            // An operator and a conversion are written as calls and call
            // nothing themselves.
            guard callee.bitwiseOperation != nil || conversionTarget(function) != nil else {
                return try pin(callee)
            }
            return .call(
                callee: function, arguments: try operands.map { try pinningCalls(in: $0) },
                position: position)
        case .binary, .slicing:
            // `&&` and `||` decide what is evaluated: one value for the lot.
            return callee.isRepeatable ? callee : try pin(callee)
        default:
            return callee
        }
    }

    mutating func store(_ value: Int, to target: GoExpression) throws {
        if let followed = throughArrayPointer(indexOrSlice: target) {
            return try store(value, to: followed)
        }
        switch target {
        case .identifier(let name, let position):
            // The blank identifier takes a value and keeps none.
            if name == GoValueList.blank { return }
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
            if try storePromoted(value, to: target, baseType: baseType) { return }
            let baseValue = try lower(base)
            if baseType.pointee(in: typeDefinitions) != nil {
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
                        key: try lowerKey(index, ofMap: base),
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
            default: return GoPredeclared.namedType(name) ?? .named(name)
            }
        case .structure(let fields, _):
            return .structure(
                fields.map {
                    GoStructFieldType($0, type: resolve($0.type))
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
            if let signature = expression.functionSignature {
                return .function(
                    parameters: signature.parameters.map(resolve),
                    results: signature.results.map(resolve))
            }
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
            let definition = typeDefinitions[name]?.underlying
                ?? GoPredeclared.underlying(of: name)
        else { return type }
        var next = visiting
        next.insert(name)
        return underlying(definition, visiting: next)
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
        // A pointer, or a type that is one underneath (`type ptr *T`).
        if let pointee = type.pointee(in: typeDefinitions) {
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

    /// The name a type assertion compares the dynamic type with. Types that
    /// earlier compilers could name keep that name, which the VM reads as the
    /// same identity; any other concrete type is named by its descriptor.
    /// What a type assertion, and `errors.As`, test a value's dynamic type
    /// against: a concrete type by its name or descriptor, an interface by
    /// the methods it asks for.
    func assertedTypeName(_ type: GoType) -> String? {
        if case .interface(let methods) = underlying(type) {
            var name = ""
            if case .named(let symbol) = type { name = symbol }
            let wanted = methods.sorted { $0.name < $1.name }
            return GoPredeclared.interfaceTarget
                + wanted.map { "\($0.name):\($0.parameters.count):\($0.results.count)" }
                .joined(separator: ",") + ";" + name
                + implementers(of: wanted).map { "\n" + $0 }.joined()
        }
        return concreteTypeName(type) ?? typeDescriptor(for: type)
    }

    /// The types of the program that implement an interface, `T` or `*T` as
    /// methods are registered: those whose method set has every method with
    /// the same parameter and result types. A value's method set holds the
    /// methods with a value receiver; a pointer's holds them all.
    func implementers(of methods: [GoInterfaceMethod]) -> [String] {
        guard !methods.isEmpty else { return [] }
        var bases: Set<String> = []
        for key in methodInfos.keys {
            guard let dot = key.lastIndex(of: ".") else { continue }
            let owner = key[..<dot]
            bases.insert(String(owner.hasPrefix("*") ? owner.dropFirst() : owner))
        }
        var owners: [String] = []
        for base in bases.sorted() {
            func has(_ method: GoInterfaceMethod, throughPointer: Bool) -> Bool {
                let found =
                    methodInfos[methodKey(baseName: base, pointer: false, method: method.name)]
                    ?? (throughPointer
                        ? methodInfos[
                            methodKey(baseName: base, pointer: true, method: method.name)] : nil)
                guard let found else { return false }
                return found.parameterTypes == method.parameters
                    && found.resultTypes == method.results
            }
            if methods.allSatisfy({ has($0, throughPointer: false) }) { owners.append(base) }
            if methods.allSatisfy({ has($0, throughPointer: true) }) { owners.append("*" + base) }
        }
        return owners + GoLibraryTypes.refusals(of: methods)
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
        if type == GoPredeclared.time {
            // An opaque timestamp; the zero time is 0.
            return constant(.int(0))
        }
        switch underlying(type) {
        case .int: return constant(.int(0))
        case .string: return constant(.string(""))
        case .bool: return constant(.bool(false))
        case .pointer, .slice, .map, .channel, .interface, .function: return constant(.nilValue)
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
        if let address = try lowerElementAddress(throughPointerOf: expression) { return address }
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
            if let lent = try lowerPromotedSelector(expression, address: true) { return lent }
            let pointer: Int
            if try type(of: base).pointee(in: typeDefinitions) != nil {
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
        if let noted = notedType(of: expression) { return noted }
        switch expression {
        case .integer: return .int
        case .string: return .string
        case .identifier(let name, let position):
            if name == "true" || name == "false" { return .bool }
            if name == "nil" { return .nilType }
            guard let binding = lookup(name) else {
                if let global = globalInfos[name] { return global.type }
                if let parameters = functionParameterTypes[name] {
                    return .function(
                        parameters: parameters, results: functionResultTypes[name] ?? [])
                }
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
                return GoLibraryTypes.constantType(package: packageName, member: name)
            }
            if standardErrorValue(base: base, member: name) != nil {
                return GoPredeclared.errorType
            }
            if standardFileDescriptor(base: base, member: name) != nil {
                return GoPredeclared.filePointer
            }
            if let method = methodExpression(base: base, name: name) {
                return .function(
                    parameters: [method.receiverType] + method.info.parameterTypes,
                    results: method.info.resultTypes)
            }
            if let function = libraryFunction(base: base, member: name) { return function.type }
            let baseType = try type(of: base)
            if let lent = try promotedType(expression, baseType: baseType) { return lent }
            guard let field = structFields(of: baseType)?.first(where: { $0.name == name }) else {
                if let info = try methodInfo(base: base, name: name) {
                    return .function(parameters: info.parameterTypes, results: info.resultTypes)
                }
                if case .interface(let methods) = underlying(baseType),
                    let method = methods.first(where: { $0.name == name })
                {
                    return .function(parameters: method.parameters, results: method.results)
                }
                if let method = GoLibraryValue.method(of: baseType, named: name) {
                    return method.type
                }
                throw GoDiagnostic(position: position, message: "undefined selector")
            }
            return field.type
        case .compositeLiteral(let typeExpression, _, _):
            return resolve(typeExpression)
        case .index(let base, _, _):
            switch underlying(throughArrayPointer(try type(of: base))) {
            case .array(_, let element), .slice(let element): return element
            case .string: return GoPredeclared.byte
            case .map(_, let value): return value
            default: return .void
            }
        case .slicing(let base, _, _, _):
            switch underlying(throughArrayPointer(try type(of: base))) {
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
                return operandType.pointee(in: typeDefinitions) ?? .void
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
                if case .binary(let left, _, let right, _) = expression {
                    return try operandType(left, right)
                }
                return .void
            }
        case .call(let callee, _, let position):
            if let operation = expression.bitwiseOperation {
                if operation.operator.isUnary || operation.operator.isShift {
                    return try type(of: operation.operands[0])
                }
                return try operandType(operation.operands[0], operation.operands[1])
            }
            if let lent = try promotedType(expression, baseType: nil) { return lent }
            if let target = conversionTarget(callee) {
                return target
            }
            if let builtin = try predeclaredCallType(of: expression) { return builtin }
            if let native = nativeFunction(for: callee) {
                return native.function.results.first ?? .void
            }
            if let signature = valueCallSignature(callee) {
                return signature.results.first ?? .void
            }
            if case .identifier(let name, _) = callee,
                name == "len" || name == "cap" || name == "copy"
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
            if case .selector(let base, let member, _) = callee,
                case .identifier("time", _) = base,
                member == "After" || member == "Tick"
            {
                return .channel(direction: .receiveOnly, element: GoPredeclared.time)
            }
            if case .selector(let base, let member, _) = callee,
                case .identifier("strings", _) = base,
                let function = GoStringsFunction(goName: member)
            {
                return function.signature.result
            }
            if case .selector(let base, let member, _) = callee,
                case .identifier("userland", _) = base
            {
                switch GoStandardLibrary.resolve(package: "userland", member: member) {
                case .userlandReadInput?, .userlandReadStdin?: return .string
                case .userlandWriteFile?, .userlandWindowSize?: return .int
                case .userlandSetRawMode?: return .bool
                default: break
                }
            }
            if case .selector(let base, let member, _) = callee,
                case .identifier(let packageName, _) = base,
                lookup(packageName) == nil,
                globalInfos[packageName] == nil,
                let result = functionResultTypes[packageName + "." + member]?.first
            {
                // An imported package function.
                return result
            }
            if case .selector(let base, let member, _) = callee,
                let baseType = try? type(of: base),
                case .interface(let methods) = underlying(baseType),
                let method = methods.first(where: { $0.name == member })
            {
                return method.results.first ?? .void
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

    // MARK: Bitwise operators, conversions, and native library calls

    /// Type of an arithmetic or bitwise operation. The type checker has
    /// already matched the operands, so an `int` side next to a named integer
    /// type is an untyped constant that adopted that type.
    func operandType(_ left: GoExpression, _ right: GoExpression) throws -> GoType {
        let leftType = try type(of: left)
        guard leftType == .int, let rightType = try? type(of: right) else { return leftType }
        return underlying(rightType) == .int ? rightType : leftType
    }

    /// Reduces `register` modulo 256 when `type` is a byte type, so byte
    /// arithmetic wraps the way Go's `uint8` does. A nil type is an operand
    /// this pass cannot type; no such expression produces a byte.
    mutating func wrapByte(_ register: Int, type: GoType?) -> Int {
        guard let type, GoPredeclared.isByte(type, definitions: typeDefinitions) else {
            return register
        }
        let mask = constant(.int(255))
        let destination = allocateRegister()
        operations.append(
            .call(
                function: GoBitwiseOperator.and.nativeName,
                arguments: [register, mask],
                destinations: [destination]))
        return destination
    }

    mutating func lowerBitwise(
        _ bitwiseOperator: GoBitwiseOperator,
        operands: [GoExpression]
    ) throws -> Int {
        let registers = try operands.map { try lower($0) }
        let destination = allocateRegister()
        operations.append(
            .call(
                function: bitwiseOperator.nativeName,
                arguments: registers,
                destinations: [destination]))
        switch bitwiseOperator {
        case .shiftLeft, .complement:
            return wrapByte(destination, type: try? type(of: operands[0]))
        default:
            return destination
        }
    }

    /// The target type when `callee` names a type, making the call a conversion.
    func conversionTarget(_ callee: GoExpression) -> GoType? {
        switch callee {
        case .typeExpression(let typeExpression, _):
            return resolve(typeExpression)
        case .identifier(let name, let position):
            guard lookup(name) == nil, globalInfos[name] == nil,
                functionReturnCounts[name] == nil, functionParameterTypes[name] == nil
            else { return nil }
            switch name {
            case "int", "string", "bool", "byte", "uint8", "any", "error":
                return resolve(.named(name, position: position))
            default:
                if let numeric = GoPredeclared.numericType(name) { return numeric }
                return typeDefinitions[name] == nil ? nil : .named(name)
            }
        case .unary(.dereference, let operand, _):
            // `(*T)(x)`.
            return conversionTarget(operand).map { .pointer($0) }
        case .selector(.identifier(let packageName, _), let member, _):
            // `time.Duration(x)`, where nothing hides the package.
            guard lookup(packageName) == nil, globalInfos[packageName] == nil else { return nil }
            return GoLibraryTypes.convertible(package: packageName, member: member)
        default:
            return nil
        }
    }

    mutating func lowerConversion(to target: GoType, argument: GoExpression) throws -> Int {
        // To an interface type: the value with its type, as when assigned.
        if isInterfaceType(target) { return try lowerConverted(argument, to: target) }
        if let number = try lowerNumericConversion(to: target, argument: argument) {
            return number
        }
        let value = try lower(argument)
        if underlying(target) == .int {
            // Narrowing to a byte truncates; a byte source is already in range.
            let isByteSource =
                (try? type(of: argument)).map {
                    GoPredeclared.isByte($0, definitions: typeDefinitions)
                } ?? false
            return isByteSource ? value : wrapByte(value, type: target)
        }
        let sourceShape = underlying(try type(of: argument))
        let native: String
        switch underlying(target) {
        case .string:
            if sourceShape == .int {
                native = GoPredeclared.runeToString
            } else if case .slice = sourceShape {
                native = GoPredeclared.bytesToString
            } else {
                return value
            }
        case .slice where sourceShape == .string:
            native = GoPredeclared.stringToBytes
        case .interface, .structure:
            // `any(x)` holds the value with its type, as an assignment
            // makes it, and `T(x)` is a struct under the name `T`.
            return converted(value, from: staticType(of: argument), to: target)
        default:
            return value
        }
        let destination = allocateRegister()
        operations.append(.call(function: native, arguments: [value], destinations: [destination]))
        return destination
    }

    func standardFileDescriptor(base: GoExpression, member: String) -> Int64? {
        guard case .identifier("os", _) = base, lookup("os") == nil, globalInfos["os"] == nil
        else { return nil }
        return GoStandardLibrary.standardFileDescriptor(member: member)
    }

    /// Message of the package-level `error` value `base.member`, such as
    /// `io.EOF`, or nil when the selector is not one.
    func standardErrorValue(base: GoExpression, member: String) -> String? {
        guard case .identifier(let packageName, _) = base, lookup(packageName) == nil,
            globalInfos[packageName] == nil
        else { return nil }
        return GoStandardLibrary.errorValue(package: packageName, member: member)
    }

    /// The native library function `callee` denotes, with the receiver
    /// expression for `*os.File` and `time.Time` methods.
    func nativeFunction(
        for callee: GoExpression
    ) -> (function: GoNativeFunction, receiver: GoExpression?)? {
        guard case .selector(let base, let member, _) = callee else { return nil }
        if case .identifier(let packageName, _) = base,
            lookup(packageName) == nil,
            globalInfos[packageName] == nil,
            let function = GoStandardLibrary.nativeFunction(package: packageName, member: member)
        {
            return (function, nil)
        }
        if let receiver = try? type(of: base),
            let function = GoStandardLibrary.method(
                of: GoLibraryTypes.methodOwner(receiver) ?? receiver, named: member)
        {
            return (function, GoLibraryTypes.receiver(base, of: receiver))
        }
        return nil
    }

    /// Lowers the receiver and arguments of a native call in evaluation order.
    mutating func lowerNativeOperands(
        _ function: GoNativeFunction,
        receiver: GoExpression?,
        arguments: [GoExpression]
    ) throws -> [Int] {
        var registers: [Int] = []
        if let receiver { registers.append(try lower(receiver)) }
        let fixedCount = function.parameters.count - registers.count
        let receiverCount = registers.count
        for (index, argument) in arguments.enumerated() {
            if function.isVariadic, index == fixedCount, arguments.count == fixedCount + 1,
                let operand = argument.spreadOperand
            {
                registers.append(spreadOperands(try lower(operand)))
                continue
            }
            let register = try lower(argument)
            if function.formatsOperands, index >= fixedCount {
                registers.append(formatOperand(register, for: argument))
            } else if function.symbol == GoPredeclared.errorsAs, index == 1 {
                // The target is the pointer itself, not an interface value.
                registers.append(register)
            } else {
                let parameter = index + receiverCount
                registers.append(
                    converted(
                        register, from: staticType(of: argument),
                        to: parameter < function.parameters.count
                            ? function.parameters[parameter] : nil))
            }
        }
        if function.symbol == GoPredeclared.errorsAs {
            registers.append(constant(.string(try errorsAsTarget(arguments))))
        }
        return registers
    }

    /// What `errors.As` looks for in an error chain, from the static type of
    /// its target: the name of a concrete type, or the methods of an
    /// interface.
    func errorsAsTarget(_ arguments: [GoExpression]) throws -> String {
        guard arguments.count == 2, case .pointer(let pointee)? = staticType(of: arguments[1])
        else {
            throw GoDiagnostic(
                position: arguments.last?.position ?? GoSourcePosition(path: "", offset: 0, line: 1, column: 1),
                message: "second argument to errors.As must be a non-nil pointer to either a type that implements error, or to any interface type")
        }
        guard let name = assertedTypeName(pointee) else {
            throw GoDiagnostic(
                position: arguments[1].position, message: "unsupported errors.As target type")
        }
        return name
    }

    /// The descriptor a value of `type` is boxed with when it becomes an
    /// interface value, or nil when it needs none: an `int`, a `string`, and
    /// a `bool` show their type themselves, and an interface already carries
    /// its value's.
    func typeDescriptor(for type: GoType) -> String? {
        switch type {
        case .int, .string, .bool, .void, .nilType: return nil
        default: break
        }
        if case .interface = underlying(type) { return nil }
        var encoder = GoTypeEncoder(definitions: typeDefinitions, packageName: "main")
        return GoPredeclared.typeDescriptorMarker + encoder.descriptor(of: type)
    }

    /// Go converts a value assigned to an interface, which then holds the
    /// value and its type. Returns `register`, a value of type `source`,
    /// boxed with its descriptor when `target` is an interface type.
    mutating func converted(_ register: Int, from source: GoType?, to target: GoType?) -> Int {
        if let renamed = renamedStruct(register, from: source, to: target) { return renamed }
        guard let target, isInterfaceType(target), let source,
            let descriptor = typeDescriptor(for: source)
        else { return register }
        let boxed = allocateRegister()
        operations.append(
            .makeInterface(destination: boxed, source: register, typeName: descriptor))
        return boxed
    }

    /// The static type of `expression`, when the lowerer can tell it.
    func staticType(of expression: GoExpression) -> GoType? {
        (try? type(of: expression)) ?? interfaceCallResult(expression)
    }

    /// Lowers `expression` as a value of type `target`, converting it when
    /// the target is an interface.
    mutating func lowerConverted(_ expression: GoExpression, to target: GoType?) throws -> Int {
        converted(try lower(expression), from: staticType(of: expression), to: target)
    }

    /// Lowers call arguments against the parameter types they are passed to.
    ///
    /// A variadic function receives its further arguments as one slice: the
    /// slice a `values...` argument names, a new one of the arguments given,
    /// or nil when there are none.
    mutating func lowerArguments(
        _ arguments: [GoExpression],
        parameters: [GoType]?
    ) throws -> [Int] {
        guard let parameters, let element = parameters.last?.variadicElement,
            arguments.count >= parameters.count - 1
        else {
            return try arguments.enumerated().map { index, argument in
                try lowerConverted(
                    argument, to: parameters.flatMap { index < $0.count ? $0[index] : nil })
            }
        }
        let fixedCount = parameters.count - 1
        var registers = try arguments.prefix(fixedCount).enumerated().map { index, argument in
            try lowerConverted(argument, to: parameters[index])
        }
        let rest = arguments.dropFirst(fixedCount)
        if rest.count == 1, let operand = rest.first?.spreadOperand {
            registers.append(try lower(operand))
        } else if rest.isEmpty {
            registers.append(constant(.nilValue))
        } else {
            let position = rest.first?.position ?? GoSourcePosition(path: "", offset: 0, line: 1, column: 1)
            let zero = try zeroValue(for: element, position: position)
            let values = try rest.map { try lowerConverted($0, to: element) }
            let slice = allocateRegister()
            operations.append(.makeSlice(destination: slice, zero: zero, values: values))
            registers.append(slice)
        }
        return registers
    }

    /// Converts `register`, the lowered `fmt` operand `argument`, to the
    /// `any` that the parameter of a `fmt` function is: boxed with its type
    /// unless the value shows it. The VM formats by that type, and finds an
    /// `Error` or `String` method through it.
    mutating func formatOperand(_ register: Int, for argument: GoExpression) -> Int {
        converted(register, from: staticType(of: argument), to: .interface([]))
    }

    func isInterfaceType(_ type: GoType) -> Bool {
        if case .interface = underlying(type) { return true }
        return false
    }

    /// The function a `go` or `defer` of the builtin `close` runs: the
    /// channel is read at the statement, and closed when the call runs.
    mutating func closeWrapper(
        callee: GoExpression, arguments: [GoExpression]
    ) throws -> (name: String, registers: [Int])? {
        guard case .identifier("close", _) = callee, arguments.count == 1,
            lookup("close") == nil, globalInfos["close"] == nil,
            functionParameterTypes["close"] == nil
        else { return nil }
        let name = "$native.\(wrapperNamespace).$close"
        if nativeWrappers[name] == nil {
            nativeWrappers[name] = GoIRFunction(
                name: name,
                parameterCount: 1,
                registerCount: 1,
                operations: [.closeChannel(channel: 0), .return])
        }
        return (name, [try lower(arguments[0])])
    }

    /// The function a `go` or `defer` of `fmt.Print` or `fmt.Println` runs:
    /// the `print` instruction over its parameters, so the operands are
    /// formatted in a frame of their own like any other call.
    mutating func printWrapper(newline: Bool, operandCount: Int) -> String {
        let name =
            "$native.\(wrapperNamespace).$fmt.\(newline ? "Println" : "Print").\(operandCount)"
        if nativeWrappers[name] == nil {
            nativeWrappers[name] = GoIRFunction(
                name: name,
                parameterCount: operandCount,
                registerCount: operandCount,
                operations: [
                    .print(arguments: Array(0..<operandCount), newline: newline),
                    .return,
                ])
        }
        return name
    }

    /// The result type of a method call through an interface value, which
    /// `type(of:)` does not resolve.
    func interfaceCallResult(_ expression: GoExpression) -> GoType? {
        guard case .call(.selector(let base, let name, _), _, _) = expression,
            let baseType = try? type(of: base),
            case .interface(let methods) = underlying(baseType)
        else { return nil }
        return methods.first { $0.name == name }?.results.first
    }

    /// Lowers the operands of `fmt.Print` or `fmt.Println`.
    mutating func lowerFormatOperands(_ arguments: [GoExpression]) throws -> [Int] {
        if arguments.count == 1, let operand = arguments[0].spreadOperand {
            return [spreadOperands(try lower(operand))]
        }
        return try arguments.map { formatOperand(try lower($0), for: $0) }
    }

    /// Marks `slice`, the `[]any` of a `values...` argument, as the operands
    /// of a `...any` parameter: the VM takes its elements in its place.
    mutating func spreadOperands(_ slice: Int) -> Int {
        let marked = allocateRegister()
        operations.append(
            .makeInterface(
                destination: marked, source: slice,
                typeName: GoPredeclared.spreadOperandsTypeName))
        return marked
    }

    /// The method call a `fmt.Fprint`, `Fprintln`, or `Fprintf` to a writer
    /// that is no file is compiled as, `w.Write([]byte(fmt.Sprint(...)))`;
    /// nil for a call to a file and for any other call. See
    /// `GoWriterFormat`.
    func writerFormatCall(
        callee: GoExpression, arguments: [GoExpression]
    ) -> (callee: GoExpression, arguments: [GoExpression])? {
        guard let native = nativeFunction(for: callee), native.receiver == nil,
            native.function.formatsOperands,
            native.function.parameters.first == GoPredeclared.filePointer,
            let writer = arguments.first, let writerType = staticType(of: writer),
            writerType != GoPredeclared.filePointer, writerType != .nilType
        else { return nil }
        return GoWriterFormat.call(callee: callee, arguments: arguments)
    }

    /// Lowers a native library call and returns one register per result, or
    /// nil when `callee` is not a native function.
    mutating func lowerNativeCall(
        callee: GoExpression,
        arguments: [GoExpression]
    ) throws -> [Int]? {
        if let write = writerFormatCall(callee: callee, arguments: arguments) {
            return try lowerMultiReturnCall(callee: write.callee, arguments: write.arguments)
        }
        guard let native = nativeFunction(for: callee) else { return nil }
        let registers = try lowerNativeOperands(
            native.function, receiver: native.receiver, arguments: arguments)
        let destinations = native.function.results.map { _ in allocateRegister() }
        operations.append(
            .call(
                function: native.function.symbol,
                arguments: registers,
                destinations: destinations))
        return destinations
    }

    /// Lowers the operands of a `go` or `defer` native call. The VM can only
    /// spawn or defer functions, so the call goes through a synthesized
    /// wrapper that performs the native call and drops its results.
    mutating func nativeWrapper(
        callee: GoExpression,
        arguments: [GoExpression]
    ) throws -> (name: String, registers: [Int])? {
        if let wrapper = try clearWrapper(callee: callee, arguments: arguments) { return wrapper }
        if let closing = try closeWrapper(callee: callee, arguments: arguments) { return closing }
        guard let native = nativeFunction(for: callee) else { return nil }
        let registers = try lowerNativeOperands(
            native.function, receiver: native.receiver, arguments: arguments)
        let count = registers.count
        // A `go` or `defer` drops the results like a statement does.
        let symbol = native.function.statementSymbol ?? native.function.symbol
        let resultCount =
            native.function.statementSymbol == nil ? native.function.results.count : 0
        let name = "$native.\(wrapperNamespace).\(symbol).\(count)"
        if nativeWrappers[name] == nil {
            nativeWrappers[name] = GoIRFunction(
                name: name,
                parameterCount: count,
                registerCount: count + resultCount,
                operations: [
                    .call(
                        function: symbol,
                        arguments: Array(0..<count),
                        destinations: Array(count..<(count + resultCount))),
                    .return,
                ])
        }
        return (name, registers)
    }

    // MARK: Functions of the run-time library as values

    /// What `base.member` takes and gives when it names a function of the
    /// run-time library that can be a value: `base` is the package, which
    /// nothing of the program hides.
    func libraryFunction(base: GoExpression, member: String) -> GoLibrarySignature? {
        guard case .identifier(let packageName, _) = base, lookup(packageName) == nil,
            globalInfos[packageName] == nil, typeDefinitions[packageName] == nil
        else { return nil }
        return GoLibraryValue.function(package: packageName, member: member)
    }

    /// `base.member` as a value when it is a function of the run-time
    /// library, or nil when it is anything else.
    mutating func lowerLibraryFunctionValue(base: GoExpression, member: String) throws -> Int? {
        guard case .identifier(let packageName, _) = base,
            let signature = libraryFunction(base: base, member: member)
        else { return nil }
        return functionValue(
            symbol: try libraryValueFunction(
                named: packageName + "." + member, of: base, member: member,
                signature: signature))
    }

    /// `base.member` as a value when it is a method of a type of the
    /// run-time library, or nil when it is anything else: a function that
    /// has its receiver, read now as a call would read it.
    mutating func lowerLibraryMethodValue(base: GoExpression, member: String) throws -> Int? {
        guard let baseType = try? type(of: base),
            let signature = GoLibraryValue.method(of: baseType, named: member),
            let receiverType = signature.receiver
        else { return nil }
        var receiver = try lower(base)
        if receiverType != baseType {
            // A pointer to a value the VM keeps behind a handle: the
            // function holds the handle, as a call passes it.
            let handle = allocateRegister()
            operations.append(.dereference(destination: handle, pointer: receiver))
            receiver = handle
        }
        return functionValue(
            symbol: try libraryValueFunction(
                named: "\(receiverType).\(member)", of: nil, member: member,
                signature: signature),
            bound: [receiver])
    }

    /// The function a function of the run-time library is as a value. Its
    /// parameters are the library function's, a bound receiver first, and
    /// its body is the call `package.member(parameters)`, or
    /// `receiver.member(parameters)` when `package` is nil, lowered as a
    /// call the program wrote is: whatever instruction or native call that
    /// is, a call through the value runs it in a frame of its own.
    mutating func libraryValueFunction(
        named goName: String, of package: GoExpression?, member: String,
        signature: GoLibrarySignature
    ) throws -> String {
        let name = "$native.\(wrapperNamespace).$value.\(goName)"
        guard nativeWrappers[name] == nil else { return name }
        let position = package?.position ?? GoSourcePosition(path: "", offset: 0, line: 1, column: 1)
        var lowerer = self
        lowerer.operations = []
        lowerer.scopes = [[:]]
        lowerer.nextRegister = 0
        lowerer.nextLabel = 0
        lowerer.breakLabels = []
        lowerer.continueLabels = []
        lowerer.testAbortLabels = []
        lowerer.resultRegisters = []
        lowerer.resultTypes = []
        lowerer.returnsThroughResults = false
        lowerer.pendingLiterals = []
        lowerer.isLiteralBody = true
        // The parameters have names no program can write.
        let types = (signature.receiver.map { [$0] } ?? []) + signature.parameters
        var operands: [GoExpression] = []
        for (index, type) in types.enumerated() {
            let operand = "$\(index)"
            lowerer.scopes[0][operand] = LoweredBinding(
                register: lowerer.allocateRegister(), type: type.parameterType)
            let value = GoExpression.identifier(operand, position: position)
            operands.append(type.variadicElement == nil ? value : .spread(value, position: position))
        }
        let callee = GoExpression.selector(
            base: package ?? operands.removeFirst(), name: member, position: position)
        let results: [Int]
        switch signature.results.count {
        case 0:
            try lowerer.lowerExpressionStatement(
                .call(callee: callee, arguments: operands, position: position))
            results = []
        case 1:
            guard let result = try lowerer.lowerCall(callee: callee, arguments: operands) else {
                throw GoDiagnostic(position: position, message: "no value used as value")
            }
            results = [result]
        default:
            guard
                let several = try lowerer.lowerMultiReturnCall(callee: callee, arguments: operands)
            else {
                throw GoDiagnostic(position: position, message: "no value used as value")
            }
            results = several
        }
        lowerer.operations.append(results.isEmpty ? .return : .returnValues(sources: results))
        nativeWrappers.merge(lowerer.nativeWrappers) { existing, _ in existing }
        nativeWrappers[name] = GoIRFunction(
            name: name,
            parameterCount: types.count,
            returnCount: results.count,
            registerCount: lowerer.nextRegister,
            operations: lowerer.operations)
        return name
    }

    func methodInfo(base: GoExpression, name: String) throws -> MethodInfo? {
        let baseType = try type(of: base)
        if let library = GoLibraryTypes.method(of: baseType, named: name) {
            // A method of a library type: a function the VM provides
            // under the name a method of the program would have. A call
            // the lowerer sees is the native call, made before this is
            // asked; what is left is the method as a value.
            return MethodInfo(
                functionName: library.symbol, receiverType: library.receiver,
                resultTypes: library.results, parameterTypes: library.parameters)
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

// MARK: - Composite literals

extension IRLowerer {
    /// The values of an array or slice literal, each where its index puts
    /// it. An element stands after the one before it or at the index it is
    /// written with, and an index the literal leaves out has the zero value.
    /// The elements are evaluated in the order the source has them.
    mutating func lowerListElements(
        _ elements: [GoCompositeElement], element elementType: GoType, position: GoSourcePosition
    ) throws -> [Int] {
        guard elements.contains(where: { $0.keyExpression != nil }) else {
            return try elements.map { try lowerConverted($0.value, to: elementType) }
        }
        var slots: [Int?] = []
        var next = 0
        for element in elements {
            let index = element.keyExpression?.literalIndex ?? next
            let value = try lowerConverted(element.value, to: elementType)
            guard index >= 0, index < GoCompositeLiterals.maximumLength else {
                throw GoDiagnostic(position: element.position, message: "invalid index in literal")
            }
            if slots.count <= index {
                slots.append(contentsOf: repeatElement(nil, count: index + 1 - slots.count))
            }
            slots[index] = value
            next = index + 1
        }
        var zero: Int?
        return try slots.map { slot in
            if let slot { return slot }
            if let zero { return zero }
            let register = try zeroValue(for: elementType, position: position)
            zero = register
            return register
        }
    }
}

// MARK: - `new`, `min`, `max`, and `clear`

extension IRLowerer {
    /// Whether `name` means what Go predeclares: the program declares
    /// nothing of that name where it is read.
    func isPredeclared(_ name: String) -> Bool {
        lookup(name) == nil && globalInfos[name] == nil && functionReturnCounts[name] == nil
            && functionParameterTypes[name] == nil && typeDefinitions[name] == nil
    }

    /// The length of the array `argument` points to when it is the operand
    /// of `len` or `cap`: a constant, for which the pointer is not followed.
    func lengthBehindPointer(callee: GoExpression, arguments: [GoExpression]) -> Int? {
        guard case .identifier(let name, _) = callee, name == "len" || name == "cap",
            isPredeclared(name), arguments.count == 1,
            let argumentType = try? type(of: arguments[0]),
            throughArrayPointer(argumentType) != argumentType,
            case .array(let length, _) = underlying(throughArrayPointer(argumentType))
        else { return nil }
        return length
    }

    /// The builtin `callee` names, when it is `new`, `min`, `max`, or
    /// `clear` and the program has given the name no other meaning.
    func predeclaredFunction(_ callee: GoExpression) -> String? {
        guard case .identifier(let name, _) = callee,
            name == "new" || name == "min" || name == "max" || name == "clear",
            isPredeclared(name)
        else { return nil }
        return name
    }

    /// The type of a call of one of those builtins, or nil for any other.
    func predeclaredCallType(of call: GoExpression) throws -> GoType? {
        guard case .call(let callee, let arguments, _) = call,
            let name = predeclaredFunction(callee)
        else { return nil }
        switch name {
        case "new":
            guard case .typeExpression(let type, _)? = arguments.first else { return nil }
            return .pointer(resolve(type))
        case "clear":
            return .void
        default:
            // The checker made the operands agree: one that is not an `int`
            // has the type the constants among them took.
            let types = try arguments.map { try type(of: $0) }
            let named = types.first { type in
                if case .named = type { return true }
                return false
            }
            return named ?? types.first { $0 != .int } ?? .int
        }
    }

    /// Lowers a call of one of those builtins and returns a register for
    /// each result, or nil when `callee` is none of them.
    mutating func lowerPredeclaredCall(
        callee: GoExpression, arguments: [GoExpression]
    ) throws -> [Int]? {
        if let length = lengthBehindPointer(callee: callee, arguments: arguments) {
            // Go reads the operand only for what it may do besides.
            if !arguments[0].isRepeatable { _ = try lower(arguments[0]) }
            return [constant(.int(Int64(length)))]
        }
        guard let name = predeclaredFunction(callee) else { return nil }
        switch name {
        case "new":
            // A pointer to a new variable that holds the zero value, made
            // as `&T{}` makes one.
            guard case .typeExpression(let type, let position)? = arguments.first else {
                throw GoDiagnostic(position: callee.position, message: "new requires a type")
            }
            let destination = allocateRegister()
            operations.append(
                .call(
                    function: GoPredeclared.newVariable,
                    arguments: [try zeroValue(for: resolve(type), position: position)],
                    destinations: [destination]))
            return [destination]
        case "clear":
            guard let cleared = arguments.first else { return [] }
            operations.append(
                .call(
                    function: GoPredeclared.clearElements,
                    arguments: try clearOperands(cleared), destinations: []))
            return []
        default:
            return [try lowerExtreme(isMinimum: name == "min", of: arguments)]
        }
    }

    /// `min` or `max`: every operand is read, in order, and the result is
    /// the first of them that none after it is before (`min`) or after
    /// (`max`), by the comparison `<` makes.
    mutating func lowerExtreme(isMinimum: Bool, of arguments: [GoExpression]) throws -> Int {
        let operands = try arguments.map { try lower($0) }
        let result = allocateRegister()
        guard let first = operands.first else { return constant(.int(0)) }
        operations.append(.copy(destination: result, source: first))
        for operand in operands.dropFirst() {
            let kept = allocateLabel()
            let isBetter = allocateRegister()
            operations.append(
                .binary(
                    destination: isBetter, operator: .less,
                    left: isMinimum ? operand : result, right: isMinimum ? result : operand))
            operations.append(.jumpIfFalse(condition: isBetter, target: kept))
            operations.append(.copy(destination: result, source: operand))
            operations.append(.label(kept))
        }
        return result
    }

    /// What the VM clears and what it leaves in each element of a slice:
    /// the zero value of the element type. A map loses its entries.
    mutating func clearOperands(_ cleared: GoExpression) throws -> [Int] {
        let collection = try lower(cleared)
        if case .slice(let element) = underlying(try type(of: cleared)) {
            return [collection, try zeroValue(for: element, position: cleared.position)]
        }
        return [collection, constant(.nilValue)]
    }

    /// The function a `go` or `defer` of `clear` runs: the VM starts and
    /// defers functions, and `clear` is one instruction.
    mutating func clearWrapper(
        callee: GoExpression, arguments: [GoExpression]
    ) throws -> (name: String, registers: [Int])? {
        guard predeclaredFunction(callee) == "clear", let cleared = arguments.first else {
            return nil
        }
        let name = "$native.\(wrapperNamespace).\(GoPredeclared.clearElements)"
        if nativeWrappers[name] == nil {
            nativeWrappers[name] = GoIRFunction(
                name: name,
                parameterCount: 2,
                registerCount: 2,
                operations: [
                    .call(function: GoPredeclared.clearElements, arguments: [0, 1], destinations: []),
                    .return,
                ])
        }
        return (name, try clearOperands(cleared))
    }
}

// MARK: - Struct types with and without a name

extension IRLowerer {
    /// A struct value carries the name of its type, which is part of what
    /// the VM compares. A value of `struct{ a int }` that becomes a `T` of
    /// that structure, or the reverse, by assignment or by conversion, is
    /// therefore written again under the name of its new type; its fields
    /// have the types they had. Nil when `source` and `target` are not two
    /// such types.
    mutating func renamedStruct(_ register: Int, from source: GoType?, to target: GoType?) -> Int? {
        guard let source, let target, source != target,
            typeName(of: source) != typeName(of: target),
            case .structure(let fields) = underlying(target),
            underlying(source) == underlying(target)
        else { return nil }
        let values = fields.map { field -> Int in
            let value = allocateRegister()
            operations.append(.getField(destination: value, base: register, name: field.name))
            return value
        }
        let destination = allocateRegister()
        operations.append(
            .makeStruct(
                destination: destination, typeName: typeName(of: target),
                fieldNames: fields.map(\.name), values: values))
        return destination
    }

    /// The key `key` of an index of the map `map`, under the name of the
    /// map's key type when it is a struct of another name: the VM finds an
    /// entry by a key that is equal.
    mutating func lowerKey(_ key: GoExpression, ofMap map: GoExpression) throws -> Int {
        let register = try lower(key)
        guard let mapType = try? type(of: map), case .map(let keyType, _) = underlying(mapType)
        else { return register }
        return renamedStruct(register, from: staticType(of: key), to: keyType) ?? register
    }

    /// The right operand of `==` or `!=` as a value of the left operand's
    /// type, when the two are a struct type and its structure written out.
    mutating func comparand(
        _ register: Int, _ operand: GoExpression, against other: GoExpression,
        by binaryOperator: GoBinaryOperator
    ) -> Int {
        guard binaryOperator == .equal || binaryOperator == .notEqual else { return register }
        return renamedStruct(register, from: staticType(of: operand), to: staticType(of: other))
            ?? register
    }
}

// MARK: - Pointers to arrays

extension IRLowerer {
    /// The array a pointer to an array points to, and any other type as it
    /// is.
    func throughArrayPointer(_ type: GoType) -> GoType {
        guard case .pointer(let pointee) = underlying(type), case .array = underlying(pointee)
        else { return type }
        return pointee
    }

    /// `*base` when `base` is a pointer to an array: `p[i]` and `p[a:b]` are
    /// `(*p)[i]` and `(*p)[a:b]`, and a nil `p` panics as `*p` does.
    func arrayBehindPointer(_ base: GoExpression) -> GoExpression? {
        guard let baseType = try? type(of: base), throughArrayPointer(baseType) != baseType
        else { return nil }
        return .unary(operator: .dereference, operand: base, position: base.position)
    }

    /// `p[i]` or `p[a:b]` as `(*p)[i]` or `(*p)[a:b]` when `p` is a pointer
    /// to an array, and nil for any other expression.
    func throughArrayPointer(indexOrSlice expression: GoExpression) -> GoExpression? {
        switch expression {
        case .index(let base, let index, let position):
            return arrayBehindPointer(base).map { .index(base: $0, index: index, position: position) }
        case .slicing(let base, let low, let high, let position):
            return arrayBehindPointer(base).map {
                .slicing(base: $0, low: low, high: high, position: position)
            }
        default:
            return nil
        }
    }

    /// `&p[i]` for a pointer `p` to an array: the address of the element
    /// inside the array it points to. Nil for any other expression.
    mutating func lowerElementAddress(throughPointerOf expression: GoExpression) throws -> Int? {
        guard case .index(let base, let index, _) = expression, arrayBehindPointer(base) != nil
        else { return nil }
        let pointer = try lower(base)
        let element = try lower(index)
        operations.append(
            .call(function: GoPredeclared.requireValue, arguments: [pointer], destinations: []))
        let destination = allocateRegister()
        operations.append(.indexAddress(destination: destination, base: pointer, index: element))
        return destination
    }

    /// A `range` over a pointer to an array as a `range` the VM knows, or
    /// nil for any other.
    ///
    /// With a value variable the loop reads the elements of the array the
    /// pointer points to as they are when it reaches them, which is a range
    /// over a slice of the whole array. With an index alone Go does not
    /// follow the pointer at all: the loop counts to the length of the
    /// array type, also when the pointer is nil.
    mutating func rangeThroughArrayPointer(_ statement: GoStatement) throws -> GoStatement? {
        guard case .forRangeStatement(let indexName, let valueName, let collection, let body, let position) = statement,
            let collectionType = try? type(of: collection),
            throughArrayPointer(collectionType) != collectionType,
            case .array(let length, let elementType) = underlying(
                throughArrayPointer(collectionType))
        else { return nil }
        let hasValue = valueName != nil && valueName != GoValueList.blank
        if hasValue, length > 0 {
            return .forRangeStatement(
                indexName: indexName, valueName: valueName,
                collection: .slicing(
                    base: collection, low: nil,
                    high: .integer(Int64(length), position: collection.position),
                    position: collection.position),
                body: body, position: position)
        }
        if !collection.isRepeatable { _ = try lower(collection) }
        // Something of that length to count: the VM ranges over values. A
        // value variable of an array without elements is never given one.
        let counted = allocateRegister()
        let size = constant(.int(Int64(length)))
        let zero =
            hasValue
            ? try zeroValue(for: elementType, position: collection.position)
            : constant(.bool(false))
        operations.append(
            .allocateSlice(destination: counted, zero: zero, length: size, capacity: size))
        let name = "$ranged.\(counted)"
        scopes[scopes.count - 1][name] = LoweredBinding(
            register: counted, type: .slice(hasValue ? elementType : .bool))
        return .forRangeStatement(
            indexName: indexName, valueName: hasValue ? valueName : nil,
            collection: .identifier(name, position: collection.position), body: body,
            position: position)
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
        case .readStdin: return 3
        case .writeFile: return 4
        case .setRawMode: return 3
        case .windowSize: return 3
        case .stringsCall(_, _, let arguments): return arguments.count + 2
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
        case .readStdin(let dataDestination, let statusDestination):
            instructions.append(.readStdin)
            instructions.append(.store(statusDestination))
            instructions.append(.store(dataDestination))
        case .writeFile(let destination, let path, let data):
            instructions.append(.load(path))
            instructions.append(.load(data))
            instructions.append(.writeFile)
            instructions.append(.store(destination))
        case .setRawMode(let destination, let enabled):
            instructions.append(.load(enabled))
            instructions.append(.setTerminalRawMode)
            instructions.append(.store(destination))
        case .windowSize(let rowsDestination, let columnsDestination):
            instructions.append(.terminalWindowSize)
            instructions.append(.store(columnsDestination))
            instructions.append(.store(rowsDestination))
        case .stringsCall(let destination, let function, let arguments):
            for argument in arguments {
                instructions.append(.load(argument))
            }
            instructions.append(.strings(function))
            instructions.append(.store(destination))
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

// MARK: Declarations and names at the edges

extension IRLowerer {
    /// `var a, b = f()` at package level: `value` is evaluated once, where
    /// the first of its variables is initialized, and each of them stored.
    /// The values are those of a declaration of locals no source can name,
    /// so a call, a map index, a type assertion, and a receive are lowered
    /// as they are in a function.
    mutating func lowerGroupedGlobals(
        of value: GoExpression, among declarations: [GoGlobalDeclaration]
    ) throws {
        let prefix = "$global.\(value.position.path).\(value.position.offset)."
        guard lookup(prefix + "0") == nil else { return }
        let members = declarations.compactMap { declaration -> (name: String, index: Int)? in
            guard let grouped = declaration.expression?.groupedResult,
                grouped.value.position == value.position
            else { return nil }
            return (declaration.name, grouped.index)
        }
        let count = (members.map(\.index).max() ?? 0) + 1
        try lower(
            .multiDeclaration(
                names: (0..<count).map { prefix + String($0) }, expression: value,
                position: value.position))
        for member in members {
            guard let global = globalInfos[member.name],
                let local = lookup(prefix + String(member.index))
            else { continue }
            operations.append(
                .storeGlobal(
                    index: global.index,
                    source: converted(local.register, from: local.type, to: global.type)))
        }
    }
}
