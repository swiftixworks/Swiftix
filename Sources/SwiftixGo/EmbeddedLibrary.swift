/// Packages of the run-time library that are written in Go.
///
/// Most of the library is native: the checker knows each member where a
/// program can write it, and the VM executes it. A package that has to run
/// the program's own functions cannot be made that way, because a native
/// cannot call guest code. `net/http` is such a package: a server is an
/// accept loop that starts a goroutine for each connection and calls a
/// handler of the program for each request. So its source is Go, kept here,
/// and a program that imports it is linked with it as with any local package
/// of a module: the linker turns `http.HandleFunc` into the symbol
/// `net/http.HandleFunc`, the checker and the compiler see ordinary
/// functions and types, goroutines, panics, and closures work as they do in
/// the program, and `%T` prints `*http.Request` because that is the name of
/// the type.
///
/// Three things make that fit the rest of the library:
///
/// - **Whole packages.** `net/http` and `net/url` are their Go source and
///   nothing else. The linker finds the source by the import path when the
///   build has no package of that path.
/// - **Supplements.** `io` and `strings` stay native, and gain members
///   written in Go: `io.Reader`, `io.ReadAll`, `strings.NewReader`. Those
///   live in a package of their own under a path no program imports, and
///   `redirected` rewrites `io.ReadAll` in a file to name it there. A file
///   that uses none of them is not touched, so a program that does not use
///   them compiles to what it compiled to before there were any.
/// - **Natives of a Go package.** What `net/http` leaves to the VM (sniffing
///   a content type, the canonical form of a header name) it reaches by
///   importing its own path, which inside the package means the native part.
///
/// Pure value transformation; no executor state.
enum GoEmbeddedLibrary {
    /// The members of a native package that Go source provides.
    struct Supplement {
        /// The path of the native package, as a program imports it.
        let libraryPath: String
        /// The path of the package of Go source, which no program imports.
        let path: String
        let sources: [GoSourceFile]
        /// The exported names the source declares at package level.
        let names: Set<String>

        /// The name a file that uses the supplement has for it: the
        /// package's own name and a mark no source can write.
        var qualifier: String {
            GoImportName.defaultName(ofPath: libraryPath) + String(GoLocalTypes.marker)
        }
    }

    /// The source of each package that is Go and nothing else.
    static let packages: [String: [GoSourceFile]] = [
        "net/http": GoEmbeddedSources.netHTTP,
        "net/url": GoEmbeddedSources.netURL,
    ]

    /// The supplements, by the path of the native package each adds to.
    static let supplements: [String: Supplement] = {
        var result: [String: Supplement] = [:]
        for (libraryPath, sources) in [
            ("io", GoEmbeddedSources.io), ("strings", GoEmbeddedSources.strings),
        ] {
            var names: Set<String> = []
            for file in sources.compactMap({ try? GoParser.parse($0) }) {
                names.formUnion(file.typeDeclarations.map(\.name))
                names.formUnion(file.globalDeclarations.map(\.name))
                names.formUnion(file.functions.lazy.filter { $0.receiver == nil }.map(\.name))
            }
            result[libraryPath] = Supplement(
                libraryPath: libraryPath, path: supplementRoot + libraryPath, sources: sources,
                names: names.filter(GoModuleLinker.isExported))
        }
        return result
    }()

    /// What the path of a supplement's package begins with. `swiftix/` is
    /// the run-time library's, as in `swiftix/userland`.
    static let supplementRoot = "swiftix/go/"

    /// Whether `path` is a package of Go source that reaches natives of its
    /// own by importing itself.
    static func isPackage(_ path: String) -> Bool { packages[path] != nil }

    /// The source of the package `declaration` imports, when it is one of
    /// these. A supplement is imported only under the name `redirected`
    /// gives it, so no program reaches one by writing its path.
    static func sources(importedBy declaration: GoImportDeclaration) -> [GoSourceFile]? {
        if let sources = packages[declaration.path] { return sources }
        guard declaration.path.hasPrefix(supplementRoot),
            let supplement = supplements[String(declaration.path.dropFirst(supplementRoot.utf8.count))],
            declaration.name == supplement.qualifier
        else { return nil }
        return supplement.sources
    }

    /// Whether a program of `files`, which imports no local package, needs
    /// one of these packages, and so has to be linked.
    static func isNeeded(by files: [GoFile]) throws -> Bool {
        if files.contains(where: { $0.imports.contains { packages[$0.path] != nil } }) {
            return true
        }
        guard files.contains(where: { $0.imports.contains { supplements[$0.path] != nil } })
        else { return false }
        for file in try GoLocalTypes.hoist(files) {
            if try redirected(file, inPackage: "") != nil { return true }
        }
        return false
    }

    /// The files of the package at `importPath` with every use of a
    /// supplement's member naming the supplement's package.
    static func redirected(_ files: [GoFile], inPackage importPath: String) throws -> [GoFile] {
        try files.map { try redirected($0, inPackage: importPath) ?? $0 }
    }

    /// `file` with its uses of supplements redirected, or nil when it has
    /// none.
    private static func redirected(_ file: GoFile, inPackage importPath: String) throws -> GoFile? {
        // A supplement's own source means the native package by its path.
        let imported = file.imports.filter {
            supplements[$0.path] != nil && GoImportName.isQualifier($0.name)
                && $0.name != GoImportName.blank
                && supplements[$0.path]?.path != importPath
        }
        guard !imported.isEmpty else { return nil }
        var redirector = Redirector(imports: imported)
        let rewritten = try redirector.redirect(file)
        guard !redirector.redirectedPaths.isEmpty else { return nil }
        var imports: [GoImportDeclaration] = []
        for declaration in file.imports {
            guard let supplement = supplements[declaration.path],
                redirector.redirectedPaths.contains(declaration.path),
                imported.contains(declaration)
            else {
                imports.append(declaration)
                continue
            }
            // The import stays for what the file still asks the native
            // package, and goes when the supplement had all of its uses.
            let name = declaration.name ?? GoImportName.defaultName(ofPath: declaration.path)
            if redirector.nativeUses.contains(name) { imports.append(declaration) }
            if !imports.contains(where: { $0.path == supplement.path }) {
                imports.append(
                    GoImportDeclaration(
                        name: supplement.qualifier, path: supplement.path,
                        position: declaration.position))
            }
        }
        return rewritten.rebuilt(
            imports: imports,
            typeDeclarations: rewritten.typeDeclarations,
            globalDeclarations: rewritten.globalDeclarations,
            functions: rewritten.functions)
    }
}

/// Rewrites `io.ReadAll` to `io·.ReadAll` where `io` is the package and the
/// supplement of `io` declares `ReadAll`.
private struct Redirector: GoScopedRewriter {
    /// The supplement each name of the file stands for.
    private var supplements: [String: GoEmbeddedLibrary.Supplement] = [:]
    private var scopes: [Set<String>] = []
    /// The native packages whose supplement the file uses, by path.
    private(set) var redirectedPaths: Set<String> = []
    /// The names of the file's imports it still selects a native member of.
    private(set) var nativeUses: Set<String> = []

    init(imports: [GoImportDeclaration]) {
        for declaration in imports {
            let name = declaration.name ?? GoImportName.defaultName(ofPath: declaration.path)
            supplements[name] = GoEmbeddedLibrary.supplements[declaration.path]
        }
    }

    mutating func redirect(_ file: GoFile) throws -> GoFile {
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
            imports: file.imports,
            typeDeclarations: types,
            globalDeclarations: globals,
            functions: functions)
    }

    /// The supplement's name for `qualifier.member`, when the qualifier is
    /// the package and the supplement has the member.
    private mutating func redirected(_ member: String, of qualifier: String) -> String? {
        guard let supplement = supplements[qualifier],
            !scopes.contains(where: { $0.contains(qualifier) })
        else { return nil }
        guard supplement.names.contains(member) else {
            nativeUses.insert(qualifier)
            return nil
        }
        redirectedPaths.insert(supplement.libraryPath)
        return supplement.qualifier
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
        guard let dot = name.firstIndex(of: "."),
            let qualifier = redirected(
                String(name[name.index(after: dot)...]), of: String(name[..<dot]))
        else { return .named(name, position: position) }
        return .named(qualifier + name[dot...], position: position)
    }

    mutating func member(
        _ member: String, of qualifier: String,
        qualifierPosition: GoSourcePosition, position: GoSourcePosition
    ) -> GoExpression? {
        guard let redirected = redirected(member, of: qualifier) else { return nil }
        return .selector(
            base: .identifier(redirected, position: qualifierPosition), name: member,
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

/// The Go source of the embedded packages, one file of this module each.
enum GoEmbeddedSources {}
