/// What a name means where only its scope can say: a type a function
/// declares, and the package an import's name stands for. Both are settled
/// on the syntax tree, a package at a time, before anything is checked.
enum GoNames {
    static func resolve(_ files: [GoFile]) throws -> [GoFile] {
        try GoImportNames.resolve(GoLocalTypes.hoist(files))
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
