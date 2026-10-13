/// Alias declarations, `type Name = T`.
///
/// An alias is another name for a type and declares no type of its own:
/// `Name` and `T` are one type wherever either is written, with one method
/// set, one identity in an assertion, and one name when printed. So nothing
/// after the syntax tree needs to know of them. `GoTypeAliases.resolve` puts
/// `T` wherever the name is used and drops the declarations.
///
/// It runs over every file of the program at once, after local types have
/// left their functions and the linker has given each package's names their
/// symbols: by then a type's name is one name in the whole program, and only
/// a variable of a function can hide it.
enum GoTypeAliases {
    static func resolve(_ files: [GoFile]) throws -> [GoFile] {
        guard files.contains(where: { $0.typeDeclarations.contains(where: \.isAlias) }) else {
            return files
        }
        // The checker never sees an alias, so a name declared twice is
        // found here. By now a name of a package is one in the program.
        var declared: [String: GoSourcePosition] = [:]
        for file in files {
            for declaration in file.typeDeclarations where !declaration.isAlias {
                declared[declaration.name] = declaration.position
            }
            for declaration in file.globalDeclarations {
                declared[declaration.name] = declaration.position
            }
            for function in file.functions where function.receiver == nil && function.name != "init" {
                declared[function.name] = function.position
            }
        }
        var declarations: [String: GoTypeDeclaration] = [:]
        for declaration in files.lazy.flatMap(\.typeDeclarations) where declaration.isAlias {
            if let other = declarations[declaration.name]?.position ?? declared[declaration.name] {
                // Go reports the one that comes second.
                let isLater =
                    other.path != declaration.position.path
                    || other.offset < declaration.position.offset
                throw GoDiagnostic(
                    position: isLater ? declaration.position : other,
                    message: "\(GoLocalTypes.sourceName(declaration.name)) redeclared in this block")
            }
            declarations[declaration.name] = declaration
        }

        var resolver = Resolver(declarations: declarations)
        // Every alias, used or not, must stand for a type.
        for name in declarations.keys.sorted() { _ = try resolver.target(of: name) }
        return try files.map { file in
            let types = try file.typeDeclarations.filter { !$0.isAlias }.map { declaration in
                GoTypeDeclaration(
                    name: declaration.name,
                    type: try resolver.rewrite(declaration.type),
                    position: declaration.position)
            }
            let globals = try file.globalDeclarations.map { declaration in
                resolver.openScope()
                defer { resolver.closeScope() }
                return GoGlobalDeclaration(
                    name: declaration.name,
                    explicitType: try declaration.explicitType.map { try resolver.rewrite($0) },
                    expression: try declaration.expression.map { try resolver.rewrite($0) },
                    isConstant: declaration.isConstant,
                    position: declaration.position)
            }
            var rebuilt = file.rebuilt(
                imports: file.imports,
                typeDeclarations: types,
                globalDeclarations: globals,
                functions: try file.functions.map { try resolver.rewrite($0) })
            rebuilt.aliasTargets += try file.typeDeclarations.filter(\.isAlias).compactMap {
                try resolver.target(of: $0.name)
            }
            return rebuilt
        }
    }
}

private struct Resolver: GoScopedRewriter {
    private let declarations: [String: GoTypeDeclaration]
    /// The type each alias stands for, once it has been worked out.
    private var targets: [String: GoTypeExpression] = [:]
    /// The aliases whose types are being worked out, to find one that
    /// stands for itself.
    private var expanding: [String] = []
    private var scopes: [Set<String>] = []

    init(declarations: [String: GoTypeDeclaration]) {
        self.declarations = declarations
    }

    /// The type the alias `name` stands for, with no alias left in it.
    mutating func target(of name: String) throws -> GoTypeExpression? {
        if let known = targets[name] { return known }
        guard let declaration = declarations[name] else { return nil }
        guard !expanding.contains(name) else {
            // Reported at the alias the cycle was entered by.
            let first = declarations[expanding[0]] ?? declaration
            let firstName = GoLocalTypes.sourceName(first.name)
            throw GoDiagnostic(
                position: first.position,
                message: expanding.count == 1
                    ? "invalid recursive type: \(firstName) refers to itself"
                    : "invalid recursive type \(firstName)")
        }
        expanding.append(name)
        defer { expanding.removeLast() }
        // A type's own scope is the package's: no variable hides a name here.
        let outer = scopes
        scopes = []
        defer { scopes = outer }
        let target = try rewrite(declaration.type)
        targets[name] = target
        return target
    }

    mutating func openScope() { scopes.append([]) }
    mutating func closeScope() { scopes.removeLast() }

    mutating func declare(_ name: String, at position: GoSourcePosition) -> String {
        scopes[scopes.count - 1].insert(name)
        return name
    }

    mutating func value(
        named name: String, at position: GoSourcePosition
    ) throws -> GoExpression {
        guard !scopes.contains(where: { $0.contains(name) }), let target = try target(of: name)
        else { return .identifier(name, position: position) }
        // In a conversion or as the argument of `make` a type is written
        // where a value is. A type of the library has no name a value
        // could be written with, and stays a type.
        if case .named(let targetName, _) = target,
            GoLibraryTypes.underlying(of: targetName) == nil
        {
            return .identifier(targetName, position: position)
        }
        return .typeExpression(target.moved(to: position), position: position)
    }

    mutating func type(
        named name: String, at position: GoSourcePosition
    ) throws -> GoTypeExpression {
        // What is wrong with a use of the alias is wrong where it is used.
        try target(of: name)?.moved(to: position) ?? .named(name, position: position)
    }

    mutating func member(
        _ member: String, of qualifier: String,
        qualifierPosition: GoSourcePosition, position: GoSourcePosition
    ) -> GoExpression? {
        nil
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

extension GoTypeExpression {
    /// The same type, written at `position`.
    fileprivate func moved(to position: GoSourcePosition) -> GoTypeExpression {
        switch self {
        case .named(let name, _):
            return .named(name, position: position)
        case .structure(let fields, _):
            return .structure(fields: fields, position: position)
        case .pointer(let pointee, _):
            return .pointer(pointee: pointee, position: position)
        case .array(let length, let element, _):
            return .array(length: length, element: element, position: position)
        case .slice(let element, _):
            return .slice(element: element, position: position)
        case .map(let key, let value, _):
            return .map(key: key, value: value, position: position)
        case .channel(let direction, let element, _):
            return .channel(direction: direction, element: element, position: position)
        case .interface(let methods, _):
            return .interface(methods: methods, position: position)
        }
    }
}
