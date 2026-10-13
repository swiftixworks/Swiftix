/// Types declared inside functions.
///
/// `GoStatement` has no case for a type declaration, so the parser leaves one
/// where it stands as a call no program can write: `$type(Name, type)`. The
/// place matters, because the name reaches from there to the end of its
/// block and hides what the name meant outside.
///
/// Every later stage knows only the types of a package. `GoLocalTypes.hoist`
/// makes a local type one of them: it moves the declaration to the package
/// level under a name no source can spell, `Name·1`, and renames the uses the
/// scope gives it. Two types of the same name in two functions stay two
/// types, and both print as Go prints them, without what follows the dot.
enum GoLocalTypes {
    /// Separates a name from what makes it unique. Not a letter, so no Go
    /// identifier contains it.
    static let marker: Character = "\u{B7}"

    static let calleeName = "$type"

    /// The name as the program wrote it.
    static func sourceName<S: StringProtocol>(_ name: S) -> S.SubSequence {
        name.firstIndex(of: marker).map { name[..<$0] } ?? name[...]
    }

    /// `text` with every name in it as the program wrote it.
    static func sourceNames(in text: String) -> String {
        guard text.contains(marker) else { return text }
        var result = ""
        var isDropping = false
        for character in text {
            if character == marker {
                isDropping = true
            } else if isDropping, character.isASCII, character.isNumber {
                continue
            } else {
                isDropping = false
                result.append(character)
            }
        }
        return result
    }

    static func sourceNames(in diagnostic: GoDiagnostic) -> GoDiagnostic {
        GoDiagnostic(position: diagnostic.position, message: sourceNames(in: diagnostic.message))
    }

    /// The files of one package with the types its functions declare moved
    /// to the package level.
    static func hoist(_ files: [GoFile]) throws -> [GoFile] {
        guard files.contains(where: \.declaresLocalTypes) else { return files }
        var hoister = Hoister()
        return try files.map { file in
            guard file.declaresLocalTypes else { return file }
            hoister.hoisted = []
            let globals = try file.globalDeclarations.map { declaration in
                // A function literal is the only place a value has a block.
                hoister.openScope()
                defer { hoister.closeScope() }
                return GoGlobalDeclaration(
                    name: declaration.name,
                    explicitType: declaration.explicitType,
                    expression: try declaration.expression.map { try hoister.rewrite($0) },
                    isConstant: declaration.isConstant,
                    position: declaration.position)
            }
            let functions = try file.functions.map { try hoister.rewrite($0) }
            return GoFile(
                path: file.path,
                packageName: file.packageName,
                imports: file.imports,
                typeDeclarations: file.typeDeclarations + hoister.hoisted,
                globalDeclarations: globals,
                functions: functions)
        }
    }
}

extension GoStatement {
    static func localType(
        name: String, type: GoTypeExpression, position: GoSourcePosition
    ) -> GoStatement {
        .expression(
            .call(
                callee: .identifier(GoLocalTypes.calleeName, position: position),
                arguments: [
                    .identifier(name, position: position),
                    .typeExpression(type, position: type.position),
                ],
                position: position))
    }

    /// The type a function declares here, when this is such a declaration.
    var localType: (name: String, type: GoTypeExpression, position: GoSourcePosition)? {
        guard case .expression(.call(.identifier(GoLocalTypes.calleeName, _), let arguments, let position)) = self,
            arguments.count == 2,
            case .identifier(let name, _) = arguments[0],
            case .typeExpression(let type, _) = arguments[1]
        else { return nil }
        return (name, type, position)
    }
}

private struct Hoister: GoScopedRewriter {
    /// What each open scope declares, with the name its uses are written by.
    private var scopes: [[String: String]] = []
    /// Counts the local types of the package, which keeps their names apart.
    private var count = 0
    var hoisted: [GoTypeDeclaration] = []

    mutating func openScope() { scopes.append([:]) }
    mutating func closeScope() { scopes.removeLast() }

    private func resolved(_ name: String) -> String {
        for scope in scopes.reversed() {
            if let spelling = scope[name] { return spelling }
        }
        return name
    }

    mutating func declare(_ name: String, at position: GoSourcePosition) throws -> String {
        // A variable may be declared again by `:=`; a type's name may not be
        // given to anything else in its block.
        if let spelling = scopes[scopes.count - 1][name], spelling != name {
            throw GoDiagnostic(position: position, message: "\(name) redeclared in this block")
        }
        scopes[scopes.count - 1][name] = name
        return name
    }

    mutating func value(named name: String, at position: GoSourcePosition) -> GoExpression {
        .identifier(resolved(name), position: position)
    }

    mutating func type(named name: String, at position: GoSourcePosition) -> GoTypeExpression {
        .named(resolved(name), position: position)
    }

    mutating func member(
        _ member: String, of qualifier: String,
        qualifierPosition: GoSourcePosition, position: GoSourcePosition
    ) -> GoExpression? {
        nil
    }

    mutating func localType(
        name: String, type: GoTypeExpression, position: GoSourcePosition
    ) throws -> [GoStatement] {
        guard scopes[scopes.count - 1][name] == nil else {
            throw GoDiagnostic(position: position, message: "\(name) redeclared in this block")
        }
        count += 1
        let hoistedName = name + String(GoLocalTypes.marker) + String(count)
        // Declared before its own type is read: a type may refer to itself.
        if name != GoValueList.blank { scopes[scopes.count - 1][name] = hoistedName }
        hoisted.append(
            GoTypeDeclaration(name: hoistedName, type: try rewrite(type), position: position))
        return []
    }
}
