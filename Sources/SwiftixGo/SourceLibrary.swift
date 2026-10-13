/// The part of the run-time library that is Go source.
///
/// A native function of the VM cannot call a function of the program, so a
/// library function that takes one — `sort.Slice` with its `less`,
/// `once.Do` with its `f` — is not native: it is Go, compiled with the
/// program that uses it. Its callback is then called like any other
/// function value, yields to the scheduler like any other code, and panics
/// into the frames that called it.
///
/// Such a package is linked the way a package of the module is. A
/// package-level name `X` of the package `p` becomes the program symbol
/// `p.X`, which is how Go spells it (`sort.Slice`, the type `sync.Once`), and
/// a selection `p.X` in a file that imports `p` becomes that symbol before
/// anything is checked. The checker and the compiler then see a function and
/// a type of the program: the function is a value, the type has methods, and
/// `%T` prints `sort.IntSlice`. A package may be native in part: `sort.Ints`
/// stays the native call it was.
///
/// Only what a program uses is linked: the declarations its files name, and
/// those that these reach. A program that names none compiles from the
/// very files it compiled from before, to the same image.
///
/// Pure value transformation; no executor state.
enum GoSourceLibrary {
    /// The unit that holds the linked declarations. It has no variables, so
    /// nothing initializes it.
    static let unitPath = "$library"

    /// What the reserved native calls of a package are selected from in its
    /// text: `native.swap(x, i, j)` is the call `$swap` of the package.
    static let nativeQualifier = "native"

    /// Where the text of the package at `path` is said to be.
    static func filePath(ofPackage path: String) -> String {
        "$GOROOT/src/\(path)/\(path).go"
    }

    /// The reserved native calls the text of `package` makes, by the name
    /// after the `$`.
    static func native(package: String, member: String) -> GoNativeFunction? {
        switch (package, member) {
        case ("sort", "$length"):
            // The slice an `any` holds, and the function of Go's `reflect`
            // that would have refused anything else.
            return GoNativeFunction(
                symbol: "$sort.length", goName: "sort.Slice",
                parameters: [.interface([]), .string], results: [.int])
        case ("sort", "$swap"):
            return GoNativeFunction(
                symbol: "$sort.swap", goName: "sort.Slice",
                parameters: [.interface([]), .int, .int])
        default:
            return nil
        }
    }

    /// The call names of those, which the linker leaves for the VM.
    static let nativeCallNames = ["$sort.length", "$sort.swap"]

    /// The exported names each package declares in its text.
    private static let exported: [String: Set<String>] = {
        var names: [String: Set<String>] = [:]
        for path in GoSourceLibraryText.paths {
            guard let parsed = try? parse(path) else { continue }
            names[path] = declaredNames(in: parsed).filter(GoModuleLinker.isExported)
        }
        return names
    }()

    /// The text of the package at `path` as a file.
    fileprivate static func parse(_ path: String) throws -> GoFile {
        guard let text = GoSourceLibraryText.text(ofPackage: path) else {
            throw GoDiagnostic(
                position: GoSourcePosition(path: path, offset: 0, line: 1, column: 1),
                message: "package \(path) is not available")
        }
        return try GoParser.parse(GoSourceFile(path: filePath(ofPackage: path), text: text))
    }

    /// The package-level names `file` declares.
    fileprivate static func declaredNames(in file: GoFile) -> Set<String> {
        var declared = Set(file.typeDeclarations.map(\.name))
        declared.formUnion(file.globalDeclarations.map(\.name))
        declared.formUnion(file.functions.lazy.filter { $0.receiver == nil }.map(\.name))
        return declared
    }

    /// Whether the text of the package at `path` declares the exported
    /// `member`: a function, a type, or a method set of one.
    static func declares(path: String, member: String) -> Bool {
        exported[path]?.contains(member) ?? false
    }

    /// `units` with every use of a declaration of the source library named
    /// by its symbol, and a unit after them that declares what they use.
    /// The units themselves, when they use none.
    static func link(_ units: [GoLinkedUnit]) throws -> [GoLinkedUnit] {
        // A program that imports no such package is not read at all.
        guard
            units.contains(where: { unit in
                unit.files.contains { !importedPackages(of: $0).isEmpty }
            })
        else { return units }
        var wanted: [Member] = []
        var linked: [GoLinkedUnit] = []
        for unit in units {
            var files: [GoFile] = []
            for file in unit.files {
                var rewriter = ProgramRewriter(imported: importedPackages(of: file))
                let rewritten = try rewriter.rewrite(file)
                files.append(rewriter.uses.isEmpty ? file : rewritten)
                wanted.append(contentsOf: rewriter.uses)
            }
            linked.append(
                GoLinkedUnit(
                    importPath: unit.importPath, initializerName: unit.initializerName,
                    files: files))
        }
        guard !wanted.isEmpty else { return units }
        let packageName = units.last?.files.first?.packageName ?? "main"
        return linked + [
            GoLinkedUnit(
                importPath: unitPath, initializerName: unitPath + ".init",
                files: try files(declaring: wanted, packageName: packageName))
        ]
    }

    /// The packages with text that `file` can select from: those it imports
    /// under their own names, which name resolution has given them all.
    private static func importedPackages(of file: GoFile) -> Set<String> {
        Set(
            file.imports.lazy
                .filter {
                    GoSourceLibraryText.paths.contains($0.path)
                        && ($0.name == nil || $0.name == GoImportName.defaultName(ofPath: $0.path))
                }
                .map(\.path))
    }

    /// A file for each package that declares one of `wanted` or something
    /// those reach, holding those declarations and no other.
    private static func files(declaring wanted: [Member], packageName: String) throws -> [GoFile] {
        var packages: [String: Package] = [:]
        var included: Set<Member> = []
        var pending = wanted
        while let member = pending.popLast() {
            if packages[member.package] == nil {
                packages[member.package] = try Package(path: member.package)
            }
            guard let package = packages[member.package],
                package.declared.contains(member.name), included.insert(member).inserted
            else { continue }
            pending.append(contentsOf: package.references[member.name] ?? [])
        }
        return packages.keys.sorted().compactMap { path in
            var file = packages[path]?.file(
                declaring: Set(included.lazy.filter { $0.package == path }.map(\.name)),
                packageName: packageName)
            // The file is of its own package, whose unexported fields and
            // methods it may name: what its symbols begin with says which.
            file?.packagePath = String(GoModuleLinker.symbol(path, "_").dropLast(2))
            return file
        }
    }

    /// A package-level declaration of a package with text.
    fileprivate struct Member: Hashable {
        let package: String
        let name: String

        var symbol: String { GoModuleLinker.symbol(package, name) }
    }
}

/// The text of one package, parsed, with its names as symbols.
private struct Package {
    let path: String
    /// The package-level names the text declares, as it writes them.
    let declared: Set<String>
    /// The declarations each of those reaches: what its type, its body,
    /// and for a type the methods on it, name.
    let references: [String: Set<GoSourceLibrary.Member>]
    private var file: GoFile

    init(path: String) throws {
        let parsed = try GoSourceLibrary.parse(path)
        let declared = GoSourceLibrary.declaredNames(in: parsed)
        var references: [String: Set<GoSourceLibrary.Member>] = [:]
        var rewriter = LibraryRewriter(package: path, declared: declared)
        var types: [GoTypeDeclaration] = []
        for declaration in parsed.typeDeclarations {
            rewriter.references = []
            types.append(
                GoTypeDeclaration(
                    name: GoModuleLinker.symbol(path, declaration.name),
                    type: try rewriter.rewrite(declaration.type),
                    isAlias: declaration.isAlias,
                    position: declaration.position))
            references[declaration.name, default: []].formUnion(rewriter.references)
        }
        var globals: [GoGlobalDeclaration] = []
        for declaration in parsed.globalDeclarations {
            rewriter.references = []
            rewriter.openScope()
            globals.append(
                GoGlobalDeclaration(
                    name: GoModuleLinker.symbol(path, declaration.name),
                    explicitType: try declaration.explicitType.map { try rewriter.rewrite($0) },
                    expression: try declaration.expression.map { try rewriter.rewrite($0) },
                    isConstant: declaration.isConstant,
                    position: declaration.position))
            rewriter.closeScope()
            references[declaration.name, default: []].formUnion(rewriter.references)
        }
        var functions: [GoFunctionDeclaration] = []
        for function in parsed.functions {
            rewriter.references = []
            let rewritten = try rewriter.rewrite(function)
            // A method goes where its type goes.
            let owner = Self.receiverTypeName(of: function) ?? function.name
            references[owner, default: []].formUnion(rewriter.references)
            functions.append(
                function.receiver != nil
                    ? rewritten
                    : GoFunctionDeclaration(
                        name: GoModuleLinker.symbol(path, function.name),
                        parameters: rewritten.parameters,
                        resultNames: rewritten.resultNames,
                        resultTypes: rewritten.resultTypes,
                        body: rewritten.body,
                        position: rewritten.position))
        }
        self.path = path
        self.declared = declared
        self.references = references
        // The file selects its native calls from the package itself, and
        // may name the package's native types.
        var imports = [
            GoImportDeclaration(
                path: path, position: GoSourcePosition(path: parsed.path, offset: 0, line: 1, column: 1))
        ]
        imports.append(contentsOf: parsed.imports.filter { $0.path != path })
        file = parsed.rebuilt(
            imports: imports, typeDeclarations: types, globalDeclarations: globals,
            functions: functions)
        file.hasResolvedImports = true
    }

    /// The name of the type `function` is a method of, as the text has it.
    private static func receiverTypeName(of function: GoFunctionDeclaration) -> String? {
        switch function.receiver?.type {
        case .named(let name, _)?, .pointer(.named(let name, _), _)?: return name
        default: return nil
        }
    }

    /// The file of the package with the declarations `names` and the
    /// methods of the types among them, as a file of the package
    /// `packageName`, which every file of a program is.
    func file(declaring names: Set<String>, packageName: String) -> GoFile {
        let symbols = Set(names.map { GoModuleLinker.symbol(path, $0) })
        func isMethodOfIncludedType(_ function: GoFunctionDeclaration) -> Bool {
            switch function.receiver?.type {
            case .named(let name, _)?, .pointer(.named(let name, _), _)?:
                return symbols.contains(name)
            default: return false
            }
        }
        var linked = file.rebuilt(
            packageName: packageName,
            imports: file.imports,
            typeDeclarations: file.typeDeclarations.filter { symbols.contains($0.name) },
            globalDeclarations: file.globalDeclarations.filter { symbols.contains($0.name) },
            functions: file.functions.filter {
                $0.receiver == nil ? symbols.contains($0.name) : isMethodOfIncludedType($0)
            })
        linked.hasResolvedImports = true
        return linked
    }
}

/// Names the uses a file of the program makes of the source library by
/// their symbols, and notes them.
private struct ProgramRewriter: GoScopedRewriter {
    /// The packages with text the file imports.
    let imported: Set<String>
    private var scopes: [Set<String>] = []
    private(set) var uses: [GoSourceLibrary.Member] = []

    init(imported: Set<String>) {
        self.imported = imported
    }

    mutating func rewrite(_ file: GoFile) throws -> GoFile {
        guard !imported.isEmpty else { return file }
        let types = try file.typeDeclarations.map { declaration in
            GoTypeDeclaration(
                name: declaration.name,
                type: try rewrite(declaration.type),
                isAlias: declaration.isAlias,
                position: declaration.position)
        }
        let globals = try file.globalDeclarations.map { declaration in
            openScope()
            defer { closeScope() }
            return GoGlobalDeclaration(
                name: declaration.name,
                explicitType: try declaration.explicitType.map { try rewrite($0) },
                expression: try declaration.expression.map { try rewrite($0) },
                isConstant: declaration.isConstant,
                position: declaration.position)
        }
        let functions = try file.functions.map { try rewrite($0) }
        return file.rebuilt(
            imports: file.imports, typeDeclarations: types, globalDeclarations: globals,
            functions: functions)
    }

    /// Whether `package.member` is a declaration of the source library the
    /// file can name, which that makes a use of.
    private mutating func uses(_ member: String, of package: String) -> Bool {
        guard imported.contains(package), !scopes.contains(where: { $0.contains(package) }),
            GoSourceLibrary.declares(path: package, member: member)
        else { return false }
        uses.append(GoSourceLibrary.Member(package: package, name: member))
        return true
    }

    mutating func openScope() { scopes.append([]) }
    mutating func closeScope() { scopes.removeLast() }

    mutating func declare(_ name: String, at position: GoSourcePosition) -> String {
        scopes[scopes.count - 1].insert(name)
        return name
    }

    mutating func value(named name: String, at position: GoSourcePosition) -> GoExpression {
        .identifier(name, position: position)
    }

    mutating func type(named name: String, at position: GoSourcePosition) -> GoTypeExpression {
        // The symbol of a type is what the file wrote: `sync.Once`.
        if let dot = name.firstIndex(of: ".") {
            _ = uses(String(name[name.index(after: dot)...]), of: String(name[..<dot]))
        }
        return .named(name, position: position)
    }

    mutating func member(
        _ member: String, of qualifier: String,
        qualifierPosition: GoSourcePosition, position: GoSourcePosition
    ) -> GoExpression? {
        guard uses(member, of: qualifier) else { return nil }
        return .identifier(GoModuleLinker.symbol(qualifier, member), position: qualifierPosition)
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

/// Gives the package-level names of a package's text their symbols, and
/// notes what each declaration names.
private struct LibraryRewriter: GoScopedRewriter {
    let package: String
    let declared: Set<String>
    private var scopes: [Set<String>] = []
    /// What the declaration being rewritten names of the source library.
    var references: Set<GoSourceLibrary.Member> = []

    init(package: String, declared: Set<String>) {
        self.package = package
        self.declared = declared
    }

    private func isLocal(_ name: String) -> Bool {
        scopes.contains { $0.contains(name) }
    }

    /// The symbol of `name` when the package declares it and nothing nearer
    /// does, which that makes a reference.
    private mutating func symbol(of name: String) -> String? {
        guard declared.contains(name), !isLocal(name) else { return nil }
        let member = GoSourceLibrary.Member(package: package, name: name)
        references.insert(member)
        return member.symbol
    }

    mutating func openScope() { scopes.append([]) }
    mutating func closeScope() { scopes.removeLast() }

    mutating func declare(_ name: String, at position: GoSourcePosition) -> String {
        scopes[scopes.count - 1].insert(name)
        return name
    }

    mutating func value(named name: String, at position: GoSourcePosition) -> GoExpression {
        .identifier(symbol(of: name) ?? name, position: position)
    }

    mutating func type(named name: String, at position: GoSourcePosition) -> GoTypeExpression {
        if let dot = name.firstIndex(of: ".") {
            // A type of another package with text, or a native one.
            let member = GoSourceLibrary.Member(
                package: String(name[..<dot]), name: String(name[name.index(after: dot)...]))
            if GoSourceLibrary.declares(path: member.package, member: member.name) {
                references.insert(member)
            }
            return .named(name, position: position)
        }
        return .named(symbol(of: name) ?? name, position: position)
    }

    mutating func member(
        _ member: String, of qualifier: String,
        qualifierPosition: GoSourcePosition, position: GoSourcePosition
    ) -> GoExpression? {
        guard !isLocal(qualifier) else { return nil }
        if qualifier == GoSourceLibrary.nativeQualifier {
            return .selector(
                base: .identifier(package, position: qualifierPosition), name: "$" + member,
                position: position)
        }
        let selected = GoSourceLibrary.Member(package: qualifier, name: member)
        guard GoSourceLibrary.declares(path: qualifier, member: member) else { return nil }
        references.insert(selected)
        return .identifier(selected.symbol, position: qualifierPosition)
    }

    mutating func localType(_ declaration: GoTypeDeclaration) -> [GoStatement] {
        [
            .localType(
                name: declaration.name, type: declaration.type, isAlias: declaration.isAlias,
                position: declaration.position)
        ]
    }
}
