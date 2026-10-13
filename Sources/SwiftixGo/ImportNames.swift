/// What an import may put in the place of a name.
enum GoImportName {
    static let dot = "."
    static let blank = "_"

    /// The name a package has in a file that gives it none.
    static func defaultName(ofPath path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// What Go says of a package named where a value is expected.
    static func misuse(ofPackage name: String) -> String {
        "use of package \(name) not in selector"
    }

    /// Whether `name` is one the file can write before a `.`.
    static func isQualifier(_ name: String?) -> Bool {
        name != dot && name != blank
    }
}

/// The names a file gives the packages it imports.
///
/// `import f "fmt"` makes `f` the package in that file, `import . "fmt"`
/// puts the package's exported names in the file's scope, and `import _ "fmt"`
/// names nothing. The checker and the compiler know a package of the run-time
/// library by its own name — `fmt.Println`, `time.Time` — so
/// `GoImportNames.resolve` rewrites a file to say it that way: `f.Println`
/// becomes `fmt.Println` wherever no declaration hides `f`, and the import
/// loses its name. An import made for its initialization keeps `_`, which
/// tells the checker the file has no name for the package.
///
/// A file that calls `time` something else may use `time` for a variable of
/// its own. After the rewrite that would read as the package, so in a package
/// where some file renames an import, every other use of the package's own
/// name is respelled with `GoLocalTypes.marker`, which no source can write.
///
/// The names of local packages are the linker's to resolve, which knows what
/// each declares; it leaves this pass the imports it does not know.
enum GoImportNames {
    /// The files of one package with every package of the run-time library
    /// named by its own name.
    static func resolve(_ files: [GoFile]) throws -> [GoFile] {
        guard files.contains(where: { !$0.hasResolvedImports && !$0.imports.isEmpty }) else {
            return files
        }
        var renames = false
        // The packages some file calls by another name.
        var freed: Set<String> = []
        for declaration in files.lazy.flatMap(\.imports) {
            guard let name = declaration.name, name != GoImportName.blank else { continue }
            renames = true
            let ownName = GoImportName.defaultName(ofPath: declaration.path)
            if name != ownName { freed.insert(ownName) }
        }

        var packageLevel: Set<String> = []
        for file in files {
            packageLevel.formUnion(file.typeDeclarations.map(\.name))
            packageLevel.formUnion(file.globalDeclarations.map(\.name))
            packageLevel.formUnion(file.functions.lazy.filter { $0.receiver == nil }.map(\.name))
        }
        return try files.map { file in
            guard !file.hasResolvedImports, !file.imports.isEmpty else { return file }
            var resolver = try Resolver(file: file, freed: freed, packageLevel: packageLevel)
            var resolved = try resolver.resolve(file)
            try resolver.requireUses(of: file.imports)
            // A package where nothing is renamed says what it said: the
            // walk only found each import its use.
            if !renames { resolved = file }
            resolved.hasResolvedImports = true
            return resolved
        }
    }
}

private struct Resolver: GoScopedRewriter {
    /// The package each name of the file stands for, by the package's own name.
    private var packages: [String: String] = [:]
    /// The package whose exported names the file uses unqualified.
    private var dotImported: String?
    private let freed: Set<String>
    private let packageLevel: Set<String>
    private var scopes: [Set<String>] = []
    /// The names of the file's imports that something is selected from.
    private var used: Set<String> = []

    init(file: GoFile, freed: Set<String>, packageLevel: Set<String>) throws {
        self.freed = freed
        self.packageLevel = packageLevel
        for declaration in file.imports {
            let ownName = GoImportName.defaultName(ofPath: declaration.path)
            switch declaration.name {
            case GoImportName.blank?:
                continue
            case GoImportName.dot?:
                // Nothing lists what a package of the run-time library
                // declares, so a second one would leave a name's package
                // a guess.
                guard dotImported == nil || dotImported == ownName else {
                    throw GoDiagnostic(
                        position: declaration.position,
                        message: "a file can dot-import only one package of the run-time library")
                }
                dotImported = ownName
            default:
                let name = declaration.name ?? ownName
                guard packages.updateValue(ownName, forKey: name) == nil else {
                    throw GoDiagnostic(
                        position: declaration.position,
                        message: "\(name) redeclared in this block")
                }
            }
        }
    }

    mutating func resolve(_ file: GoFile) throws -> GoFile {
        // Two names for one package are one package.
        var imports: [GoImportDeclaration] = []
        var named: Set<String> = []
        for declaration in file.imports {
            if declaration.name == GoImportName.blank {
                imports.append(declaration)
            } else if named.insert(declaration.path).inserted {
                imports.append(
                    GoImportDeclaration(path: declaration.path, position: declaration.position))
            }
        }

        let types = try file.typeDeclarations.map { declaration in
            GoTypeDeclaration(
                name: spelled(declaration.name),
                type: try rewrite(declaration.type),
                isAlias: declaration.isAlias,
                position: declaration.position)
        }
        let globals = try file.globalDeclarations.map { declaration in
            openScope()
            defer { closeScope() }
            return GoGlobalDeclaration(
                name: spelled(declaration.name),
                explicitType: try declaration.explicitType.map { try rewrite($0) },
                expression: try declaration.expression.map { try rewrite($0) },
                isConstant: declaration.isConstant,
                position: declaration.position)
        }
        let functions = try file.functions.map { function in
            let rewritten = try rewrite(function)
            guard function.receiver == nil, spelled(function.name) != function.name else {
                return rewritten
            }
            return GoFunctionDeclaration(
                name: spelled(function.name),
                receiver: rewritten.receiver,
                parameters: rewritten.parameters,
                resultNames: rewritten.resultNames,
                resultTypes: rewritten.resultTypes,
                body: rewritten.body,
                position: rewritten.position)
        }
        return file.rebuilt(
            imports: imports,
            typeDeclarations: types,
            globalDeclarations: globals,
            functions: functions)
    }

    // MARK: Names

    /// A name of the program's own, kept apart from a package's.
    private func spelled(_ name: String) -> String {
        freed.contains(name) ? name + String(GoLocalTypes.marker) : name
    }

    private func isLocal(_ name: String) -> Bool {
        scopes.contains { $0.contains(name) }
    }

    /// The package `name` stands for where it is read.
    private func package(named name: String) -> String? {
        isLocal(name) ? nil : packages[name]
    }

    /// The package `qualifier.member` selects from, which that uses.
    private mutating func selectedPackage(_ qualifier: String) -> String? {
        guard let package = package(named: qualifier) else { return nil }
        used.insert(qualifier)
        return package
    }

    /// The package that brings the unqualified `name` into the file: an
    /// exported name nothing in the package declares. A linker symbol has a
    /// `.` and is another package's already.
    private mutating func dotImporter(of name: String) -> String? {
        guard let package = dotImported, GoModuleLinker.isExported(name),
            !name.contains("."), !isLocal(name), !packageLevel.contains(name)
        else { return nil }
        used.insert(GoImportName.dot)
        return package
    }

    /// Go refuses an import the file has no use for.
    func requireUses(of imports: [GoImportDeclaration]) throws {
        for declaration in imports where declaration.name != GoImportName.blank {
            let ownName = GoImportName.defaultName(ofPath: declaration.path)
            let name = declaration.name ?? ownName
            guard !used.contains(name) else { continue }
            let isRenamed = name != ownName && name != GoImportName.dot
            throw GoDiagnostic(
                position: declaration.position,
                message: "\"\(declaration.path)\" imported"
                    + (isRenamed ? " as \(name)" : "") + " and not used")
        }
    }

    mutating func openScope() { scopes.append([]) }
    mutating func closeScope() { scopes.removeLast() }

    mutating func declare(_ name: String, at position: GoSourcePosition) -> String {
        scopes[scopes.count - 1].insert(name)
        return spelled(name)
    }

    mutating func value(
        named name: String, at position: GoSourcePosition
    ) throws -> GoExpression {
        if name.hasPrefix("$") { return .identifier(name, position: position) }
        if let package = dotImporter(of: name) {
            return .selector(
                base: .identifier(package, position: position), name: name, position: position)
        }
        guard package(named: name) == nil else {
            throw GoDiagnostic(
                position: position, message: GoImportName.misuse(ofPackage: name))
        }
        return .identifier(spelled(name), position: position)
    }

    mutating func type(named name: String, at position: GoSourcePosition) -> GoTypeExpression {
        if let dot = name.firstIndex(of: ".") {
            guard let package = selectedPackage(String(name[..<dot])) else {
                return .named(name, position: position)
            }
            return .named(package + name[dot...], position: position)
        }
        if let package = dotImporter(of: name) {
            return .named(package + "." + name, position: position)
        }
        return .named(spelled(name), position: position)
    }

    mutating func member(
        _ member: String, of qualifier: String,
        qualifierPosition: GoSourcePosition, position: GoSourcePosition
    ) -> GoExpression? {
        guard let package = selectedPackage(qualifier) else { return nil }
        return .selector(
            base: .identifier(package, position: qualifierPosition),
            name: member,
            position: position)
    }

    mutating func localType(_ declaration: GoTypeDeclaration) -> [GoStatement] {
        // None is left: local types are hoisted first.
        [
            .localType(
                name: declaration.name, type: declaration.type, isAlias: declaration.isAlias,
                position: declaration.position)
        ]
    }
}
