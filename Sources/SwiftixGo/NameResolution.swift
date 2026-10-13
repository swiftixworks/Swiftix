/// What a name means where only its scope can say: a type a function
/// declares, and the package an import's name stands for. Both are settled
/// on the syntax tree, a package at a time, before anything is checked.
enum GoNames {
    /// The files of one package, with the names only it can settle.
    static func resolve(_ files: [GoFile]) throws -> [GoFile] {
        try GoImportNames.resolve(GoLocalTypes.hoist(files))
    }

    /// The files of a whole program, each package of it resolved, with
    /// every alias replaced by its type.
    static func resolve(program files: [GoFile]) throws -> [GoFile] {
        try GoTypeAliases.resolve(files)
    }

    /// Runs `body`, which works on resolved files, and reports what it
    /// throws by the names the source has.
    static func reporting<Result>(_ body: () throws -> Result) throws -> Result {
        do {
            return try body()
        } catch let diagnostic as GoDiagnostic {
            throw GoLocalTypes.sourceNames(in: diagnostic)
        }
    }
}
