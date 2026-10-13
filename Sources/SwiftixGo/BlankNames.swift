/// Package-level declarations the blank identifier names.
///
/// `var _ I = (*T)(nil)`, `var _ = register()`, and `func _() { ... }`
/// declare nothing a program can use, and a package may have any number of
/// them. They are still checked, and the initializer of a variable still
/// runs, in its place among the others. Every later stage keeps what a
/// package declares by name, so `GoBlankNames.name` gives each of these a
/// name of its own that no source can spell, `_··1`, numbered through the
/// package: what follows then sees ordinary declarations nothing refers to.
/// The linker makes it `path._··1` like any name of a package, and a
/// diagnostic prints it as `_`, the way it prints the name of a local type.
///
/// A blank constant never gets here: the parser drops it once it has taken
/// its place in the count of `iota`. A blank parameter, receiver, or result
/// stays `_`, which the checker and the compiler bind to nothing.
enum GoBlankNames {
    /// What follows `_` in the name of a blank declaration, before its
    /// number. A local type `_` is hoisted as `_·1`, with one marker.
    private static let infix = String(repeating: String(GoLocalTypes.marker), count: 2)

    /// The files of one package with a name for each blank declaration.
    static func name(_ files: [GoFile]) -> [GoFile] {
        func isBlank(_ file: GoFile) -> Bool {
            file.globalDeclarations.contains { $0.name == GoValueList.blank }
                || file.functions.contains { $0.name == GoValueList.blank }
                || file.typeDeclarations.contains { $0.name == GoValueList.blank }
        }
        guard files.contains(where: isBlank) else { return files }
        var count = 0
        func unique(_ name: String) -> String {
            guard name == GoValueList.blank else { return name }
            count += 1
            return name + infix + String(count)
        }
        return files.map { file in
            guard isBlank(file) else { return file }
            // A function's places are kept by where it is, not by its name.
            var named = file.rebuilt(
                imports: file.imports,
                typeDeclarations: file.typeDeclarations.map {
                    GoTypeDeclaration(
                        name: unique($0.name), type: $0.type, isAlias: $0.isAlias,
                        position: $0.position)
                },
                globalDeclarations: file.globalDeclarations.map {
                    GoGlobalDeclaration(
                        name: unique($0.name), explicitType: $0.explicitType,
                        expression: $0.expression, isConstant: $0.isConstant,
                        position: $0.position)
                },
                functions: file.functions.map {
                    GoFunctionDeclaration(
                        name: unique($0.name), receiver: $0.receiver, parameters: $0.parameters,
                        resultNames: $0.resultNames, resultTypes: $0.resultTypes, body: $0.body,
                        position: $0.position)
                })
            // The types its functions declare are still theirs to move.
            named.declaresLocalTypes = file.declaresLocalTypes
            return named
        }
    }
}

/// `var a, b = f()` at package level.
///
/// A package-level variable is one declaration with one value, and the
/// later stages look each up by its name. Several variables that one
/// expression gives their values are therefore several declarations, each
/// with the same expression inside a call no program can write,
/// `$result(index, count, expression)`: its place among the values, and how
/// many names share them. The checker types each as that value; the
/// compiler evaluates the expression once, when the first of them is
/// initialized, and stores every value.
enum GoGroupedResult {
    static let calleeName = "$result"
}

extension GoExpression {
    /// The value at `index` of the `count` values `expression` yields.
    static func groupedResult(
        _ index: Int, of count: Int, _ expression: GoExpression
    ) -> GoExpression {
        let position = expression.position
        return .call(
            callee: .identifier(GoGroupedResult.calleeName, position: position),
            arguments: [
                .integer(Int64(index), position: position),
                .integer(Int64(count), position: position),
                expression,
            ],
            position: position)
    }

    /// The place, the number of names, and the expression, when this is the
    /// value of one of several package-level variables.
    var groupedResult: (index: Int, count: Int, value: GoExpression)? {
        guard case .call(.identifier(GoGroupedResult.calleeName, _), let arguments, _) = self,
            arguments.count == 3,
            case .integer(let index, _) = arguments[0],
            case .integer(let count, _) = arguments[1]
        else { return nil }
        return (Int(index), Int(count), arguments[2])
    }
}
