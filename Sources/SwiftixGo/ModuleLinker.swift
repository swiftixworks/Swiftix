/// Whole-program linking of the local packages of one Swiftix Go module.
///
/// Every package reachable from the root is parsed, ordered dependencies
/// first, and rewritten into one flat symbol space: a package-level name `X`
/// of the package with import path `p` becomes the symbol `p.X` (no Go
/// identifier contains `/` or `.`, so symbols of different packages and of the
/// unrenamed root package can never collide), and a qualified reference
/// `q.X` in an importing file becomes that symbol. The type checker and the
/// compiler then see ordinary in-package code, so a cross-package call,
/// constant, variable, type, or method costs exactly what the in-package form
/// costs. Export rules, import cycles, `internal/` visibility, and unused
/// local imports are diagnosed here, before the rewritten files are checked.
///
/// Pure value transformation; no executor state.

/// The sources of one package, addressed by its import path.
public struct GoPackageSource: Sendable, Equatable {
    public let importPath: String
    public let sources: [GoSourceFile]

    public init(importPath: String, sources: [GoSourceFile]) {
        self.importPath = importPath
        self.sources = sources
    }
}

/// The files of one package after linking, with the name of the function that
/// runs its package-level variable initializers.
struct GoLinkedUnit {
    let importPath: String
    let initializerName: String
    let files: [GoFile]
}

struct GoLinkedModule {
    /// Dependency-first initialization order; the root package is last.
    let units: [GoLinkedUnit]
    fileprivate let packageNames: [String: String]
    fileprivate let packageOfFile: [String: String]

    /// Restores Go spelling in a diagnostic raised on linked files: a symbol of
    /// the package the diagnostic is in loses its import path, and a symbol of
    /// another package is shown as `name.X`.
    func demangle(_ diagnostic: GoDiagnostic) -> GoDiagnostic {
        let home = packageOfFile[diagnostic.position.path]
        var message = diagnostic.message
        for path in packageNames.keys.sorted(by: { ($0.utf8.count, $0) > ($1.utf8.count, $1) }) {
            guard let name = packageNames[path] else { continue }
            message = GoModuleLinker.replacing(
                path + ".", with: path == home ? "" : name + ".", in: message)
        }
        return GoDiagnostic(position: diagnostic.position, message: message)
    }
}

enum GoModuleLinker {
    /// Symbol of the package-level `name` declared in the package `importPath`.
    static func symbol(_ importPath: String, _ name: String) -> String {
        importPath + "." + name
    }

    static func isExported(_ name: String) -> Bool {
        name.unicodeScalars.first?.properties.isUppercase ?? false
    }

    /// Whether `importer` may import `imported` under Go's `internal` rule: a
    /// package below a directory named `internal` is importable only from the
    /// tree rooted at that directory's parent.
    static func allowsInternalImport(of imported: String, from importer: String) -> Bool {
        let components = imported.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.lastIndex(of: "internal") else { return true }
        let parent = components[..<index].joined(separator: "/")
        if parent.isEmpty { return true }
        return importer == parent || importer.hasPrefix(parent + "/")
    }

    /// Upper bound on the packages of one build, which also bounds the depth
    /// of the import walk.
    static let maximumPackages = 1_024

    static func link(packages: [GoPackageSource], root: String) throws -> GoLinkedModule {
        guard packages.count <= maximumPackages else {
            throw GoDiagnostic(
                position: syntheticPosition("<link>"),
                message: "build has too many packages (limit \(maximumPackages))")
        }
        var sourcesByPath: [String: [GoSourceFile]] = [:]
        for package in packages {
            guard sourcesByPath.updateValue(package.sources, forKey: package.importPath) == nil
            else {
                throw GoDiagnostic(
                    position: position(of: package.sources),
                    message: "package \(package.importPath) is listed more than once")
            }
        }
        guard sourcesByPath[root] != nil else {
            throw GoDiagnostic(
                position: syntheticPosition("<link>"),
                message: "package \(root) is not available")
        }

        // Parse every reachable package. The walk uses explicit work lists so
        // a long import chain cannot exhaust the host stack.
        var parsed: [String: ParsedPackage] = [:]
        var pending = [root]
        while let path = pending.popLast() {
            if parsed[path] != nil { continue }
            let sources = sourcesByPath[path] ?? []
            guard !sources.isEmpty else {
                throw GoDiagnostic(
                    position: syntheticPosition("<link>"),
                    message: "no Go source files in package \(path)")
            }
            let files = try sources.map(GoParser.parse)
            let name = files[0].packageName
            for file in files where file.packageName != name {
                throw GoDiagnostic(
                    position: syntheticPosition(file.path),
                    message: "found packages \(name) and \(file.packageName)")
            }
            var imports: [GoImportDeclaration] = []
            var seen: Set<String> = []
            for declaration in files.flatMap(\.imports).sorted(by: { $0.path < $1.path })
            where seen.insert(declaration.path).inserted {
                guard sourcesByPath[declaration.path] != nil else {
                    guard GoStandardLibrary.supportedPackages.contains(declaration.path) else {
                        throw GoDiagnostic(
                            position: declaration.position,
                            message: "package \(declaration.path) is not available")
                    }
                    continue
                }
                guard allowsInternalImport(of: declaration.path, from: path) else {
                    throw GoDiagnostic(
                        position: declaration.position,
                        message: "use of internal package \(declaration.path) not allowed")
                }
                imports.append(declaration)
            }
            var declared: Set<String> = []
            for file in files {
                declared.formUnion(file.typeDeclarations.map(\.name))
                declared.formUnion(file.globalDeclarations.map(\.name))
                declared.formUnion(
                    file.functions.lazy
                        .filter { $0.receiver == nil && $0.name != "init" }
                        .map(\.name))
            }
            parsed[path] = ParsedPackage(
                importPath: path, name: name, files: files, declared: declared,
                imports: imports)
            pending.append(contentsOf: imports.reversed().map(\.path))
        }

        // Dependency-first order, rejecting cycles and imports of programs.
        var order: [String] = []
        var finished: Set<String> = []
        var active: [String] = []
        var cursors: [Int] = []
        active.append(root)
        cursors.append(0)
        while let path = active.last, let package = parsed[path] {
            let cursor = cursors[cursors.count - 1]
            guard cursor < package.imports.count else {
                active.removeLast()
                cursors.removeLast()
                finished.insert(path)
                order.append(path)
                continue
            }
            cursors[cursors.count - 1] = cursor + 1
            let declaration = package.imports[cursor]
            let dependency = declaration.path
            if let start = active.firstIndex(of: dependency) {
                let cycle = Array(active[start...]) + [dependency]
                throw GoDiagnostic(
                    position: declaration.position,
                    message: "import cycle not allowed: " + cycle.joined(separator: " imports "))
            }
            if parsed[dependency]?.name == "main" {
                throw GoDiagnostic(
                    position: declaration.position,
                    message: "import \"\(dependency)\" is a program, not an importable package")
            }
            if !finished.contains(dependency) {
                active.append(dependency)
                cursors.append(0)
            }
        }

        guard let rootPackage = parsed[root] else {
            throw GoDiagnostic(
                position: syntheticPosition("<link>"),
                message: "package \(root) is not available")
        }
        var units: [GoLinkedUnit] = []
        var packageOfFile: [String: String] = [:]
        for path in order {
            guard let package = parsed[path] else { continue }
            let isRoot = path == root
            var files: [GoFile] = []
            for file in package.files {
                packageOfFile[file.path] = path
                var rewriter = FileRewriter(
                    package: package,
                    isRoot: isRoot,
                    packages: parsed)
                files.append(
                    try rewriter.rewrite(file, packageName: rootPackage.name))
            }
            units.append(
                GoLinkedUnit(
                    importPath: path,
                    initializerName: isRoot ? "$package.init" : "$" + path + ".init",
                    files: files))
        }
        var names: [String: String] = [:]
        for path in order where path != root { names[path] = parsed[path]?.name }
        return GoLinkedModule(units: units, packageNames: names, packageOfFile: packageOfFile)
    }

    static func replacing(_ target: String, with replacement: String, in text: String) -> String {
        let source = Array(text.utf8)
        let pattern = Array(target.utf8)
        guard !pattern.isEmpty, source.count >= pattern.count else { return text }
        var result: [UInt8] = []
        result.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            if index + pattern.count <= source.count,
                source[index] == pattern[0],
                source[index..<(index + pattern.count)].elementsEqual(pattern)
            {
                result.append(contentsOf: replacement.utf8)
                index += pattern.count
            } else {
                result.append(source[index])
                index += 1
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func position(of sources: [GoSourceFile]) -> GoSourcePosition {
        syntheticPosition(sources.first?.path ?? "<link>")
    }

    private static func syntheticPosition(_ path: String) -> GoSourcePosition {
        GoSourcePosition(path: path, offset: 0, line: 1, column: 1)
    }
}

private struct ParsedPackage {
    let importPath: String
    let name: String
    let files: [GoFile]
    /// Package-level type, constant, variable, and function names.
    let declared: Set<String>
    /// Imports of local packages, one per imported path, sorted by path.
    let imports: [GoImportDeclaration]
}

/// Rewrites one file of a package into the flat symbol space.
///
/// Inside a non-root package every identifier spelled like one of the
/// package's own package-level names is renamed to its symbol, including a
/// local declaration that shadows it: renaming a name consistently everywhere
/// preserves every binding without modelling scopes. Scopes are tracked only to
/// tell a qualified reference `q.X` from a field access on a local `q`.
private struct FileRewriter {
    let package: ParsedPackage
    let isRoot: Bool
    let packages: [String: ParsedPackage]

    /// Local packages imported by the file, by qualifier.
    private var qualifiers: [String: ParsedPackage] = [:]
    private var usedQualifiers: Set<String> = []
    private var scopes: [Set<String>] = []

    init(package: ParsedPackage, isRoot: Bool, packages: [String: ParsedPackage]) {
        self.package = package
        self.isRoot = isRoot
        self.packages = packages
    }

    mutating func rewrite(_ file: GoFile, packageName: String) throws -> GoFile {
        var remainingImports: [GoImportDeclaration] = []
        var importPositions: [String: GoImportDeclaration] = [:]
        for declaration in file.imports {
            guard let imported = packages[declaration.path],
                declaration.path != package.importPath
            else {
                remainingImports.append(declaration)
                continue
            }
            guard qualifiers.updateValue(imported, forKey: imported.name) == nil else {
                throw GoDiagnostic(
                    position: declaration.position,
                    message: "\(imported.name) redeclared in this block")
            }
            importPositions[imported.name] = declaration
        }

        let types = try file.typeDeclarations.map { declaration in
            GoTypeDeclaration(
                name: renamed(declaration.name),
                type: try rewrite(declaration.type),
                position: declaration.position)
        }
        let globals = try file.globalDeclarations.map { declaration in
            GoGlobalDeclaration(
                name: renamed(declaration.name),
                explicitType: try declaration.explicitType.map { try rewrite($0) },
                expression: try declaration.expression.map { try rewrite($0) },
                isConstant: declaration.isConstant,
                position: declaration.position)
        }
        let functions = try file.functions.map { try rewrite($0) }

        for (qualifier, declaration) in importPositions.sorted(by: { $0.key < $1.key })
        where !usedQualifiers.contains(qualifier) {
            throw GoDiagnostic(
                position: declaration.position,
                message: "\"\(declaration.path)\" imported and not used")
        }
        return GoFile(
            path: file.path,
            packageName: packageName,
            imports: remainingImports,
            typeDeclarations: types,
            globalDeclarations: globals,
            functions: functions)
    }

    // MARK: Names

    private func renamed(_ name: String) -> String {
        guard !isRoot, package.declared.contains(name) else { return name }
        return GoModuleLinker.symbol(package.importPath, name)
    }

    private func isShadowed(_ name: String) -> Bool {
        scopes.contains { $0.contains(name) }
    }

    private mutating func declare(_ name: String?) {
        guard let name, !scopes.isEmpty else { return }
        scopes[scopes.count - 1].insert(name)
    }

    /// The symbol for `qualifier.member`, or nil when `qualifier` is not a
    /// local package imported by this file.
    private mutating func memberSymbol(
        qualifier: String,
        member: String,
        position: GoSourcePosition
    ) throws -> String? {
        guard let imported = qualifiers[qualifier], !isShadowed(qualifier) else { return nil }
        usedQualifiers.insert(qualifier)
        guard GoModuleLinker.isExported(member) else {
            throw GoDiagnostic(
                position: position,
                message: "cannot refer to unexported name \(qualifier).\(member)")
        }
        guard imported.declared.contains(member) else {
            throw GoDiagnostic(position: position, message: "undefined: \(qualifier).\(member)")
        }
        return GoModuleLinker.symbol(imported.importPath, member)
    }

    // MARK: Declarations

    private mutating func rewrite(_ function: GoFunctionDeclaration) throws -> GoFunctionDeclaration {
        scopes.append([])
        defer { scopes.removeLast() }
        let receiver = try function.receiver.map { try rewrite($0) }
        let parameters = try function.parameters.map { try rewrite($0) }
        let resultTypes = try function.resultTypes.map { try rewrite($0) }
        for name in function.resultNames { declare(name) }
        let isPackageLevel = function.receiver == nil && function.name != "init"
        return GoFunctionDeclaration(
            name: isPackageLevel ? renamed(function.name) : function.name,
            receiver: receiver,
            parameters: parameters,
            resultNames: function.resultNames.map { $0.map(renamed) },
            resultTypes: resultTypes,
            body: try rewrite(function.body),
            position: function.position)
    }

    private mutating func rewrite(_ parameter: GoParameter) throws -> GoParameter {
        declare(parameter.name)
        return GoParameter(
            name: renamed(parameter.name),
            type: try rewrite(parameter.type),
            position: parameter.position)
    }

    // MARK: Types

    private mutating func rewrite(_ type: GoTypeExpression) throws -> GoTypeExpression {
        switch type {
        case .named(let name, let position):
            if let dot = name.firstIndex(of: ".") {
                let qualifier = String(name[..<dot])
                let member = String(name[name.index(after: dot)...])
                if let symbol = try memberSymbol(
                    qualifier: qualifier, member: member, position: position)
                {
                    return .named(symbol, position: position)
                }
                return type
            }
            return .named(renamed(name), position: position)
        case .structure(let fields, let position):
            return .structure(
                fields: try fields.map {
                    GoStructFieldDeclaration(
                        name: $0.name, type: try rewrite($0.type), position: $0.position)
                },
                position: position)
        case .pointer(let pointee, let position):
            return .pointer(pointee: try rewrite(pointee), position: position)
        case .array(let length, let element, let position):
            return .array(length: length, element: try rewrite(element), position: position)
        case .slice(let element, let position):
            return .slice(element: try rewrite(element), position: position)
        case .map(let key, let value, let position):
            return .map(key: try rewrite(key), value: try rewrite(value), position: position)
        case .channel(let direction, let element, let position):
            return .channel(
                direction: direction, element: try rewrite(element), position: position)
        case .interface(let methods, let position):
            return .interface(
                methods: try methods.map { method in
                    GoInterfaceMethodDeclaration(
                        name: method.name,
                        parameters: try method.parameters.map { try rewrite($0) },
                        results: try method.results.map { try rewrite($0) },
                        position: method.position)
                },
                position: position)
        }
    }

    // MARK: Statements

    private mutating func rewrite(_ block: GoBlock) throws -> GoBlock {
        scopes.append([])
        defer { scopes.removeLast() }
        return GoBlock(
            statements: try block.statements.map { try rewrite($0) },
            position: block.position)
    }

    private mutating func rewrite(_ statement: GoStatement) throws -> GoStatement {
        switch statement {
        case .declaration(let name, let explicitType, let expression, let isConstant, let position):
            let type = try explicitType.map { try rewrite($0) }
            let value = try expression.map { try rewrite($0) }
            declare(name)
            return .declaration(
                name: renamed(name),
                explicitType: type,
                expression: value,
                isConstant: isConstant,
                position: position)
        case .multiDeclaration(let names, let expression, let position):
            let value = try rewrite(expression)
            for name in names { declare(name) }
            return .multiDeclaration(
                names: names.map(renamed), expression: value, position: position)
        case .assignment(let target, let expression, let position):
            return .assignment(
                target: try rewrite(target),
                expression: try rewrite(expression),
                position: position)
        case .multiAssignment(let targets, let expression, let position):
            return .multiAssignment(
                targets: try targets.map { try rewrite($0) },
                expression: try rewrite(expression),
                position: position)
        case .increment(let target, let incrementOperator, let position):
            return .increment(
                target: try rewrite(target), operator: incrementOperator, position: position)
        case .expression(let expression):
            return .expression(try rewrite(expression))
        case .returnValues(let values, let position):
            return .returnValues(try values.map { try rewrite($0) }, position: position)
        case .breakStatement, .continueStatement:
            return statement
        case .deferStatement(let expression, let position):
            return .deferStatement(expression: try rewrite(expression), position: position)
        case .goStatement(let expression, let position):
            return .goStatement(expression: try rewrite(expression), position: position)
        case .sendStatement(let channel, let value, let position):
            return .sendStatement(
                channel: try rewrite(channel), value: try rewrite(value), position: position)
        case .ifStatement(let condition, let thenBlock, let elseBlock, let position):
            return .ifStatement(
                condition: try rewrite(condition),
                thenBlock: try rewrite(thenBlock),
                elseBlock: try elseBlock.map { try rewrite($0) },
                position: position)
        case .forStatement(let initializer, let condition, let post, let body, let position):
            scopes.append([])
            defer { scopes.removeLast() }
            return .forStatement(
                initializer: try initializer.map { try rewrite($0) },
                condition: try condition.map { try rewrite($0) },
                post: try post.map { try rewrite($0) },
                body: try rewrite(body),
                position: position)
        case .forRangeStatement(let indexName, let valueName, let collection, let body, let position):
            let rewrittenCollection = try rewrite(collection)
            scopes.append([])
            defer { scopes.removeLast() }
            declare(indexName)
            declare(valueName)
            return .forRangeStatement(
                indexName: indexName.map(renamed),
                valueName: valueName.map(renamed),
                collection: rewrittenCollection,
                body: try rewrite(body),
                position: position)
        case .switchStatement(let expression, let cases, let position):
            return .switchStatement(
                expression: try expression.map { try rewrite($0) },
                cases: try cases.map { switchCase in
                    GoSwitchCase(
                        expressions: try switchCase.expressions.map { try rewrite($0) },
                        body: try rewrite(switchCase.body),
                        isDefault: switchCase.isDefault,
                        position: switchCase.position)
                },
                position: position)
        case .selectStatement(let cases, let position):
            return .selectStatement(
                cases: try cases.map { selectCase in
                    scopes.append([])
                    defer { scopes.removeLast() }
                    return GoSelectCase(
                        communication: try selectCase.communication.map { try rewrite($0) },
                        body: try rewrite(selectCase.body),
                        position: selectCase.position)
                },
                position: position)
        }
    }

    // MARK: Expressions

    private mutating func rewrite(_ expression: GoExpression) throws -> GoExpression {
        switch expression {
        case .integer, .string:
            return expression
        case .identifier(let name, let position):
            return .identifier(renamed(name), position: position)
        case .selector(let base, let name, let position):
            if case .identifier(let qualifier, let basePosition) = base,
                let symbol = try memberSymbol(
                    qualifier: qualifier, member: name, position: basePosition)
            {
                return .identifier(symbol, position: basePosition)
            }
            return .selector(base: try rewrite(base), name: name, position: position)
        case .compositeLiteral(let type, let elements, let position):
            return .compositeLiteral(
                type: try rewrite(type),
                elements: try elements.map { element in
                    GoCompositeElement(
                        key: element.key,
                        keyExpression: try element.keyExpression.map { try rewrite($0) },
                        value: try rewrite(element.value),
                        position: element.position)
                },
                position: position)
        case .index(let base, let index, let position):
            return .index(base: try rewrite(base), index: try rewrite(index), position: position)
        case .slicing(let base, let low, let high, let position):
            return .slicing(
                base: try rewrite(base),
                low: try low.map { try rewrite($0) },
                high: try high.map { try rewrite($0) },
                position: position)
        case .typeExpression(let type, let position):
            return .typeExpression(try rewrite(type), position: position)
        case .call(let callee, let arguments, let position):
            return .call(
                callee: try rewrite(callee),
                arguments: try arguments.map { try rewrite($0) },
                position: position)
        case .typeAssertion(let base, let type, let position):
            return .typeAssertion(
                base: try rewrite(base), type: try rewrite(type), position: position)
        case .functionLiteral(let parameters, let resultNames, let resultTypes, let body, let position):
            scopes.append([])
            defer { scopes.removeLast() }
            let rewrittenParameters = try parameters.map { try rewrite($0) }
            for name in resultNames { declare(name) }
            return .functionLiteral(
                parameters: rewrittenParameters,
                resultNames: resultNames.map { $0.map(renamed) },
                resultTypes: try resultTypes.map { try rewrite($0) },
                body: try rewrite(body),
                position: position)
        case .unary(let unaryOperator, let operand, let position):
            return .unary(
                operator: unaryOperator, operand: try rewrite(operand), position: position)
        case .binary(let left, let binaryOperator, let right, let position):
            return .binary(
                left: try rewrite(left),
                operator: binaryOperator,
                right: try rewrite(right),
                position: position)
        }
    }
}
