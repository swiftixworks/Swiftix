/// What a name means where only its scope can say: a type a function
/// declares, and the package an import's name stands for. Both are settled
/// on the syntax tree, a package at a time, before anything is checked.
enum GoNames {
    /// The files of one package, with the names only it can settle.
    static func resolve(_ files: [GoFile]) throws -> [GoFile] {
        try GoImportNames.resolve(
            GoLocalTypes.hoist(GoBlankNames.name(GoArrayLengths.resolve(files))))
    }

    /// The files of a whole program, each package of it resolved, with
    /// every alias replaced by its type, every composite literal given
    /// what its type says of it, every interface holding the methods of
    /// those it embeds, and every struct type the methods its embedded
    /// fields lend it.
    static func resolve(program files: [GoFile]) throws -> [GoFile] {
        try GoEmbedding.resolve(GoCompositeLiterals.resolve(GoTypeAliases.resolve(files)))
    }

    /// Runs `body`, which works on the resolved `files`, and reports what
    /// it throws by the names the source has.
    static func reporting<Result>(
        on files: [GoFile] = [], _ body: () throws -> Result
    ) throws -> Result {
        do {
            return try body()
        } catch let diagnostic as GoDiagnostic {
            var message = GoLocalTypes.sourceNames(in: diagnostic.message)
            // A member of a package is named as the line names it.
            let position = diagnostic.position
            let renames =
                files.first { $0.path == position.path }?.importRenames
                .filter { $0.line == position.line } ?? []
            for rename in renames {
                message = replacing(
                    rename.ownName + "." + rename.member,
                    with: rename.name + "." + rename.member, in: message)
            }
            throw GoDiagnostic(position: position, message: message)
        }
    }

    /// `text` with `word` replaced where it is a word of its own.
    private static func replacing(_ word: String, with replacement: String, in text: String) -> String {
        let source = Array(text.unicodeScalars)
        let pattern = Array(word.unicodeScalars)
        guard !pattern.isEmpty, source.count >= pattern.count else { return text }
        func isPartOfName(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                || scalar == "_" || scalar == "."
        }
        var result = String.UnicodeScalarView()
        var index = 0
        while index < source.count {
            let end = index + pattern.count
            if end <= source.count, source[index..<end].elementsEqual(pattern),
                !isPartOfName(index > 0 ? source[index - 1] : nil),
                !isPartOfName(end < source.count ? source[end] : nil)
            {
                result.append(contentsOf: replacement.unicodeScalars)
                index = end
            } else {
                result.append(source[index])
                index += 1
            }
        }
        return String(result)
    }
}
