/// The part of the run-time library that is written in Go, and how to add
/// to it.
///
/// Most of the library is native: the checker knows each member where a
/// program can write it, and the VM executes it. A native cannot call a
/// function of the program, so whatever has to (`sort.Slice` with its
/// `less`, `once.Do` with its `f`, an HTTP server with its handlers) is Go,
/// compiled with the program that uses it. So is whatever is simply easier
/// to write in Go than in the VM. Its callbacks are called like any other
/// function value, it yields to the scheduler and panics like any other
/// code, and `%T` prints `*http.Request` because that is the name of the
/// type.
///
/// ## How the text reaches a program
///
/// A package-level name `X` of the package at the import path `p` is the
/// program symbol `p.X` (`sort.Slice`, `io.ReadAll`, `net/http.Server`), as
/// for a local package of a module. `link` runs on the files of a program
/// once the names of their imports are settled, before anything is checked:
///
/// - In a file that imports `p`, a selection `p.X` that the text of `p`
///   declares and exports becomes the symbol, and so does the type `p.X`.
///   Anything else of `p` stays what it was, a native member of the package:
///   a package may be native in part (`sort.Ints`, `io.EOF`, `sync.Mutex`).
/// - What the program names, and what that reaches in the text, is linked:
///   functions, types with all their methods, constants, and package-level
///   variables with their initializers. Nothing else is. Each package that
///   has something linked is a unit of the program after the program's own,
///   and initializes before them, a package after those it uses.
/// - A program that names nothing of the text is returned as it came, and
///   compiles to the image it compiled to before there was any text.
///
/// The checker and the compiler then see functions, types, and variables of
/// the program, in files whose package is `p`: its unexported names are its
/// own. A diagnostic names a symbol as Go does (`http.Request`).
///
/// ## Adding a package or a member
///
/// 1. **Write Go.** The text is in `Sources/SwiftixGoLibrary/<import path>/`,
///    one directory for each package, any number of `.go` files, formatted
///    by `gofmt`. They are the source of truth. The package clause says the
///    last element of the path. A new path is also added to
///    `GoStandardLibrary.supportedPackages`.
/// 2. **Write it as Go of this dialect.** The text is checked and compiled
///    like a program's, with the same errors (an unused variable is one).
///    It may import any package of the library, native or Go, under any
///    name. To name a native member of its own package it imports its own
///    path, which in the text means the native part: `import "io"` and then
///    `io.EOF` in `io/io.go`. What it declares itself it names without a
///    qualifier. A name must not be both native and declared in the text:
///    a program would get the text's.
/// 3. **Mind what is linked when.** A declaration is linked when a program
///    reaches it, a method when its type is reached. A package-level
///    variable is initialized only in a program that reaches it, so an
///    initializer must not be needed for its effect alone, and the text has
///    no `init` functions: nothing would say when one is reached. Function
///    literals are named by their place in the file.
/// 4. **Call a native as `native.name(arguments)`.** That is the reserved
///    call `$name` of the package, which no program can write. Three places
///    declare one: its parameters and results in `native(package:member:)`
///    below (by the package's name: `http` for `net/http`), its call name
///    `$<package name>.<name>` in `nativeCallNames` (or the table it
///    includes), and its code in the VM, beside `executeSliceNative` in
///    `Runtime.swift` with its operand count in `GoNative`. A native takes
///    and gives values of the dialect; it cannot call back.
/// 5. **Regenerate.** `Scripts/generate-go-library.py` writes
///    `SourceLibraryText.swift`, which the build reads, and
///    `sort/zsortfunc.go`, which is derived from `sort/sorting.go`. With
///    `--check` it writes nothing and fails when something is stale.
///    `GoSourceLibraryFilesTests` fails then too, and when a file is not
///    as `gofmt` prints it.
/// 6. **Test against real Go.** Twice:
///    - What a program prints. Run it with real Go and pin that output
///      (`GoSortTests`, `GoSyncOnceTests`, `GoHTTPServerTests`). Where
///      order or the number of calls can be seen, print them too. An
///      error a program meets is pinned as Go's first error.
///    - The text itself, in real Go, against Go's own package:
///      `Scripts/go-library-harness/run.sh sort`. The script copies the
///      package's files, unchanged, into a scratch module, and adds two
///      files kept beside it. `native.go` declares a variable named
///      `native` with a field for each native, so that
///      `native.swap(x, i, j)` is a call of a field and the text compiles
///      as it is:
///
///          var native = struct {
///              length func(x any, caller string) int
///              swap   func(x any, i, j int)
///          }{
///              length: func(x any, _ string) int { return reflect.ValueOf(x).Len() },
///              swap:   func(x any, i, j int) { reflect.Swapper(x)(i, j) },
///          }
///
///      `main.go` drives the text and Go's package with the same inputs and
///      compares what they return and every call they make of the functions
///      it gave them. That finds in a minute what a program would meet
///      once, and the script then lists the statements the inputs did not
///      reach. `sort` is held to Go's `Less` and `Swap` sequences this way
///      on lengths up to 100,000. For another package, add a directory with
///      those two files. The text's import of its own path means Go's real
///      package there, which has every native member.
/// 7. **Check what a program pays.** `GoSourceLibraryTests` pins which
///    functions a program is linked with; add a case for a new package, and
///    one that a program importing it for a native member alone gets none.
///
/// Pure value transformation; no executor state.
enum GoSourceLibrary {
    /// What the reserved native calls of a package are selected from in its
    /// text: `native.swap(x, i, j)` is the call `$swap` of the package.
    static let nativeQualifier = "native"

    // MARK: Natives of the text

    /// The reserved native call `member` (`$name`) that the text of the
    /// package named `package` makes as `native.name(...)`.
    static func native(package: String, member: String) -> GoNativeFunction? {
        let name = String(member.dropFirst())
        switch package {
        case "sort":
            switch name {
            case "length":
                // The slice an `any` holds, and the function of Go's
                // `reflect` that would have refused anything else.
                return GoNativeFunction(
                    symbol: "$sort.length", goName: "sort.Slice",
                    parameters: [.interface([]), .string], results: [.int])
            case "swap":
                return GoNativeFunction(
                    symbol: "$sort.swap", goName: "sort.Slice",
                    parameters: [.interface([]), .int, .int])
            default:
                return nil
            }
        case "http": return GoStandardLibrary.httpNativeFunction(name)
        case "url": return GoStandardLibrary.urlNativeFunction(name)
        case "bufio", "bytes":
            return GoStandardLibrary.bytesNativeFunction(package: package, member: name)
        case "strconv": return GoNumberLibrary.parsingFunction(name)
        case "time": return GoTimeLibrary.textNative(name)
        case "net": return GoNetLibrary.textNative(name)
        case "os": return GoStandardLibrary.fileSystemNative(name)
        default: return nil
        }
    }

    /// The call names of those, which the linker leaves for the VM.
    static let nativeCallNames =
        ["$sort.length", "$sort.swap"] + GoStandardLibrary.httpNativeCallNames
        + GoStandardLibrary.bytesNativeCallNames + GoNetLibrary.nativeCallNames

    // MARK: What the text declares

    /// Whether the text of the package at `path` declares the exported
    /// `member`: a function, a type, a constant, or a variable.
    static func declares(path: String, member: String) -> Bool {
        GoModuleLinker.isExported(member)
            && GoSourceLibraryText.declared[path]?.contains(member) == true
    }

    /// The symbol of the package-level `name` of the package at `path`. A
    /// package of the library is named by the last element of its path, so
    /// its symbols begin with the path alone.
    fileprivate static func symbol(_ path: String, _ name: String) -> String {
        GoModuleLinker.symbol(path, name)
    }

    // MARK: Linking

    /// `units` with every use of a declaration of the text named by its
    /// symbol, and after them a unit for each package of the text that
    /// declares what they reach. The units themselves, when they name none.
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
        return linked + (try libraryUnits(declaring: wanted, packageName: packageName))
    }

    /// The order in which `units` initialize: the packages of the library
    /// first, as `link` ordered them, then the program's. The functions of
    /// the library stand after the program's all the same, which keeps the
    /// image of a program what it was before a package had text.
    static func initializationOrder(of units: [GoLinkedUnit]) -> [Int] {
        units.indices.filter { units[$0].isLibrary } + units.indices.filter { !units[$0].isLibrary }
    }

    /// `diagnostic` with the symbols of the text spelled as Go spells them:
    /// by the name of the package, `http.Request`.
    static func inGoSpelling(_ diagnostic: GoDiagnostic) -> GoDiagnostic {
        var message = diagnostic.message
        for path in GoSourceLibraryText.paths.sorted(by: { ($0.utf8.count, $0) > ($1.utf8.count, $1) }) {
            let name = GoImportName.defaultName(ofPath: path)
            guard name != path, message.contains(path) else { continue }
            message = GoModuleLinker.replacing(path + ".", with: name + ".", in: message)
        }
        return GoDiagnostic(position: diagnostic.position, message: message)
    }

    /// The packages with text that `file` can select from, by the names it
    /// has for them: their own, which name resolution has given them all.
    private static func importedPackages(of file: GoFile) -> [String: String] {
        var packages: [String: String] = [:]
        for declaration in file.imports
        where GoSourceLibraryText.paths.contains(declaration.path) {
            let name = GoImportName.defaultName(ofPath: declaration.path)
            if declaration.name == nil || declaration.name == name {
                packages[name] = declaration.path
            }
        }
        return packages
    }

    /// A unit for each package that declares one of `wanted` or something
    /// those reach, holding those declarations and no other, a package
    /// after the packages it names.
    private static func libraryUnits(
        declaring wanted: [Member], packageName: String
    ) throws -> [GoLinkedUnit] {
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
        var names: [String: Set<String>] = [:]
        var uses: [String: Set<String>] = [:]
        for member in included {
            names[member.package, default: []].insert(member.name)
            for reference in packages[member.package]?.references[member.name] ?? []
            where reference.package != member.package && included.contains(reference) {
                uses[member.package, default: []].insert(reference.package)
            }
        }
        // Go initializes a package after those it imports; among packages
        // that do not name each other the order is that of their paths.
        var order: [String] = []
        var placed: Set<String> = []
        func place(_ path: String) {
            guard placed.insert(path).inserted else { return }
            for used in (uses[path] ?? []).sorted() { place(used) }
            order.append(path)
        }
        for path in names.keys.sorted() { place(path) }
        return order.compactMap { path in
            guard let package = packages[path], let declared = names[path] else { return nil }
            return GoLinkedUnit(
                importPath: path, initializerName: "$" + path + ".init",
                files: package.files(declaring: declared, packageName: packageName),
                isLibrary: true)
        }
    }

    /// A package-level declaration of a package with text: the import path
    /// of the package, and the name as its files have it.
    fileprivate struct Member: Hashable {
        let package: String
        let name: String

        var symbol: String { GoSourceLibrary.symbol(package, name) }
    }
}

/// The text of one package, parsed, with its names as symbols.
private struct Package {
    let path: String
    /// The package-level names the text declares, as it writes them.
    let declared: Set<String>
    /// The declarations each of those reaches: what its type, its
    /// initializer, its body, and for a type the methods on it, name.
    let references: [String: Set<GoSourceLibrary.Member>]
    private let files: [GoFile]

    init(path: String) throws {
        guard let sources = GoSourceLibraryText.files(ofPackage: path) else {
            throw GoDiagnostic(
                position: GoSourcePosition(path: path, offset: 0, line: 1, column: 1),
                message: "package \(path) is not available")
        }
        // The names only the package can settle, as for a package of a
        // program: array lengths, local types, and the names of imports.
        let parsed = try GoNames.resolve(try sources.map(GoParser.parse))
        var declared: Set<String> = []
        for file in parsed {
            declared.formUnion(file.typeDeclarations.map(\.name))
            declared.formUnion(file.globalDeclarations.map(\.name))
            declared.formUnion(file.functions.lazy.filter { $0.receiver == nil }.map(\.name))
        }
        var references: [String: Set<GoSourceLibrary.Member>] = [:]
        var files: [GoFile] = []
        for file in parsed {
            var rewriter = LibraryRewriter(package: path, declared: declared, file: file)
            var types: [GoTypeDeclaration] = []
            for declaration in file.typeDeclarations {
                rewriter.references = []
                types.append(
                    GoTypeDeclaration(
                        name: GoSourceLibrary.symbol(path, declaration.name),
                        type: try rewriter.rewrite(declaration.type),
                        isAlias: declaration.isAlias,
                        position: declaration.position))
                references[declaration.name, default: []].formUnion(rewriter.references)
            }
            var globals: [GoGlobalDeclaration] = []
            for declaration in file.globalDeclarations {
                rewriter.references = []
                rewriter.openScope()
                globals.append(
                    GoGlobalDeclaration(
                        name: GoSourceLibrary.symbol(path, declaration.name),
                        explicitType: try declaration.explicitType.map { try rewriter.rewrite($0) },
                        expression: try declaration.expression.map { try rewriter.rewrite($0) },
                        isConstant: declaration.isConstant,
                        position: declaration.position))
                rewriter.closeScope()
                references[declaration.name, default: []].formUnion(rewriter.references)
            }
            var functions: [GoFunctionDeclaration] = []
            for function in file.functions {
                rewriter.references = []
                let rewritten = try rewriter.rewrite(function)
                // A method goes where its type goes.
                let owner = Self.receiverTypeName(of: function) ?? function.name
                references[owner, default: []].formUnion(rewriter.references)
                functions.append(
                    function.receiver != nil
                        ? rewritten
                        : GoFunctionDeclaration(
                            name: GoSourceLibrary.symbol(path, function.name),
                            parameters: rewritten.parameters,
                            resultNames: rewritten.resultNames,
                            resultTypes: rewritten.resultTypes,
                            body: rewritten.body,
                            position: rewritten.position))
            }
            // A file selects its native calls from the package itself.
            var imports = file.imports
            if !imports.contains(where: { $0.path == path }) {
                imports.append(
                    GoImportDeclaration(
                        path: path,
                        position: GoSourcePosition(path: file.path, offset: 0, line: 1, column: 1)))
            }
            var linked = file.rebuilt(
                imports: imports, typeDeclarations: types, globalDeclarations: globals,
                functions: functions)
            linked.hasResolvedImports = true
            // The file is of its own package, whose unexported fields and
            // methods it may name: what its symbols begin with says which.
            linked.packagePath = path
            files.append(linked)
        }
        self.path = path
        self.declared = declared
        self.references = references
        self.files = files
    }

    /// The name of the type `function` is a method of, as the text has it.
    private static func receiverTypeName(of function: GoFunctionDeclaration) -> String? {
        switch function.receiver?.type {
        case .named(let name, _)?, .pointer(.named(let name, _), _)?: return name
        default: return nil
        }
    }

    /// The files of the package with the declarations `names` and the
    /// methods of the types among them, as files of the package
    /// `packageName`, which every file of a program is. A file that is
    /// left with nothing is left out.
    func files(declaring names: Set<String>, packageName: String) -> [GoFile] {
        let symbols = Set(names.map { GoSourceLibrary.symbol(path, $0) })
        func isMethodOfIncludedType(_ function: GoFunctionDeclaration) -> Bool {
            switch function.receiver?.type {
            case .named(let name, _)?, .pointer(.named(let name, _), _)?:
                return symbols.contains(name)
            default: return false
            }
        }
        return files.compactMap { file in
            let types = file.typeDeclarations.filter { symbols.contains($0.name) }
            let globals = file.globalDeclarations.filter { symbols.contains($0.name) }
            let functions = file.functions.filter {
                $0.receiver == nil ? symbols.contains($0.name) : isMethodOfIncludedType($0)
            }
            guard !(types.isEmpty && globals.isEmpty && functions.isEmpty) else { return nil }
            var linked = file.rebuilt(
                packageName: packageName, imports: file.imports, typeDeclarations: types,
                globalDeclarations: globals, functions: functions)
            linked.hasResolvedImports = true
            return linked
        }
    }
}

/// Names the uses a file of the program makes of the text by their
/// symbols, and notes them.
private struct ProgramRewriter: GoScopedRewriter {
    /// The packages with text the file imports, by the names it has for
    /// them.
    let imported: [String: String]
    private var scopes: [Set<String>] = []
    private(set) var uses: [GoSourceLibrary.Member] = []

    init(imported: [String: String]) {
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
        var rewritten = file.rebuilt(
            imports: file.imports, typeDeclarations: types, globalDeclarations: globals,
            functions: functions)
        // Where the file calls the package by a name of its own, a
        // diagnostic says that name in the place of the symbol.
        rewritten.importRenames = file.importRenames.map { rename in
            guard let path = imported[rename.ownName], path != rename.ownName,
                GoSourceLibrary.declares(path: path, member: rename.member)
            else { return rename }
            return GoImportRename(
                line: rename.line, ownName: path, name: rename.name, member: rename.member)
        }
        return rewritten
    }

    /// The symbol of `package.member` when it is a declaration of the text
    /// the file can name, which that makes a use of.
    private mutating func use(_ member: String, of package: String) -> String? {
        guard let path = imported[package], !scopes.contains(where: { $0.contains(package) }),
            GoSourceLibrary.declares(path: path, member: member)
        else { return nil }
        let used = GoSourceLibrary.Member(package: path, name: member)
        uses.append(used)
        return used.symbol
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
            let symbol = use(String(name[name.index(after: dot)...]), of: String(name[..<dot]))
        else { return .named(name, position: position) }
        return .named(symbol, position: position)
    }

    mutating func member(
        _ member: String, of qualifier: String,
        qualifierPosition: GoSourcePosition, position: GoSourcePosition
    ) -> GoExpression? {
        guard let symbol = use(member, of: qualifier) else { return nil }
        return .identifier(symbol, position: qualifierPosition)
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

/// Gives the package-level names of a file of the text their symbols, and
/// notes what each declaration names.
private struct LibraryRewriter: GoScopedRewriter {
    /// The import path of the file's package, and the name programs and
    /// the text call it by.
    let package: String
    let packageName: String
    let declared: Set<String>
    /// The packages with text the file imports, its own among them when it
    /// names the native part of that, by the names it has for them.
    let imported: [String: String]
    private var scopes: [Set<String>] = []
    /// What the declaration being rewritten names of the text.
    var references: Set<GoSourceLibrary.Member> = []

    init(package: String, declared: Set<String>, file: GoFile) {
        self.package = package
        self.packageName = GoImportName.defaultName(ofPath: package)
        self.declared = declared
        var imported: [String: String] = [:]
        for declaration in file.imports
        where declaration.name == nil && GoSourceLibraryText.paths.contains(declaration.path) {
            imported[GoImportName.defaultName(ofPath: declaration.path)] = declaration.path
        }
        self.imported = imported
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

    /// The symbol of `qualifier.name` when the qualifier is a package with
    /// text that declares the name: another package's exported one, or the
    /// file's own. Anything else of a package is native.
    private mutating func symbol(of name: String, in qualifier: String) -> String? {
        guard !isLocal(qualifier), let path = imported[qualifier],
            path == package
                ? declared.contains(name) : GoSourceLibrary.declares(path: path, member: name)
        else { return nil }
        let member = GoSourceLibrary.Member(package: path, name: name)
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
            let symbol = symbol(
                of: String(name[name.index(after: dot)...]), in: String(name[..<dot]))
            return .named(symbol ?? name, position: position)
        }
        return .named(symbol(of: name) ?? name, position: position)
    }

    mutating func member(
        _ member: String, of qualifier: String,
        qualifierPosition: GoSourcePosition, position: GoSourcePosition
    ) -> GoExpression? {
        if qualifier == GoSourceLibrary.nativeQualifier, !isLocal(qualifier) {
            return .selector(
                base: .identifier(packageName, position: qualifierPosition), name: "$" + member,
                position: position)
        }
        guard let symbol = symbol(of: member, in: qualifier) else { return nil }
        return .identifier(symbol, position: qualifierPosition)
    }

    mutating func localType(_ declaration: GoTypeDeclaration) -> [GoStatement] {
        [
            .localType(
                name: declaration.name, type: declaration.type, isAlias: declaration.isAlias,
                position: declaration.position)
        ]
    }
}
