/// Recursive-descent parser for the first Go-compatible language checkpoint.

public enum GoParser {
    public static func parse(_ source: GoSourceFile) throws -> GoFile {
        try Parser.parsed(source).file
    }

    /// Parses `source` and also reports where it has parentheses around an
    /// expression. The tree keeps no node for a pair; `gofmt` needs to know
    /// where they are.
    static func parseRecordingParentheses(
        _ source: GoSourceFile
    ) throws -> (file: GoFile, parentheses: GoParentheses) {
        try Parser.parsed(source)
    }
}

/// The parentheses of a source file that wrap an expression, as distinct
/// from those of a call, a conversion, or a type assertion.
struct GoParentheses: Equatable, Sendable {
    /// The innermost pair around an expression, by the offset of the
    /// expression's position: the offsets of its `(` and `)`.
    private(set) var pairs: [Int: (open: Int, close: Int)] = [:]
    /// The `(` and `)` of every further pair around an expression that
    /// already has one, as in `((x))`.
    private(set) var redundant: Set<Int> = []
    /// The `(` of every pair.
    private(set) var opens: Set<Int> = []
    /// The `{` of every composite literal: the tree has a literal where
    /// its type begins, and `gofmt` tells its brace from that of a block
    /// or of the body of a type.
    private(set) var literalBraces: Set<Int> = []

    mutating func recordLiteral(openingAt offset: Int) {
        literalBraces.insert(offset)
    }

    mutating func record(around expression: GoExpression, open: Int, close: Int) {
        opens.insert(open)
        let offset = expression.position.offset
        if pairs[offset] == nil {
            pairs[offset] = (open, close)
        } else {
            redundant.insert(open)
            redundant.insert(close)
        }
    }

    static func == (lhs: GoParentheses, rhs: GoParentheses) -> Bool {
        lhs.redundant == rhs.redundant && lhs.literalBraces == rhs.literalBraces
            && lhs.pairs.count == rhs.pairs.count
            && lhs.pairs.allSatisfy { key, value in
                rhs.pairs[key].map { $0.open == value.open && $0.close == value.close } ?? false
            }
    }
}

private struct Parser {
    let tokens: [GoToken]
    let path: String
    var index = 0
    /// The parentheses around expressions, which the tree does not keep.
    var parentheses = GoParentheses()
    /// Whether a function body declared a type.
    var declaresLocalTypes = false
    /// How many blocks are open, the package being the first, and the
    /// outermost of them that declares something named `iota`, or 0. Such a
    /// declaration hides the constant generator from the `const`
    /// declarations in its scope. Two small numbers beside a flag: every
    /// frame of the parser holds the parser.
    var scopeDepth: UInt16 = 1
    var iotaDepth: UInt16 = 0
    /// Whether a composite literal leaves something for its type to settle.
    var hasOpenLiterals = false
    /// The names of each declaration of several names, which the tree keeps
    /// as text. For a function: its name, the end of its body, and the names
    /// of its results.
    var namePositions: [Int: [GoSourcePosition]] = [:]

    /// The file `source` holds, and where it has parentheses.
    ///
    /// A declaration of the package reaches the whole file, the lines above
    /// it too, so a file that declares `iota` at package level is parsed
    /// again knowing that: only then is no `iota` of it a generator.
    static func parsed(_ source: GoSourceFile) throws -> (file: GoFile, parentheses: GoParentheses) {
        let tokens = try GoLexer.tokenize(source)
        var parser = Parser(tokens: tokens, path: source.path)
        var file = try parser.parseFile()
        if parser.iotaDepth == 1 {
            parser = Parser(tokens: tokens, path: source.path)
            parser.iotaDepth = 1
            file = try parser.parseFile()
        }
        // What is wrong with the labels and jumps of a function is no
        // syntax error to Go, and is reported by the checker in its turn.
        file.branchErrors = GoBranchChecker.errors(in: file, tokens: tokens)
        return (file, parser.parentheses)
    }

    /// Whether `iota` is a name of the program where the parser stands.
    var isIotaHidden: Bool { iotaDepth != 0 }

    /// The block that is open declares `name`.
    mutating func declare(_ name: String) {
        if name == GoIota.name, iotaDepth == 0 { iotaDepth = scopeDepth }
    }

    mutating func declare(_ names: [String]) {
        for name in names { declare(name) }
    }

    /// A block opens, and closes. A parse that fails is given up, so
    /// nothing closes the blocks an error leaves open.
    mutating func openScope() { scopeDepth += 1 }
    mutating func closeScope() {
        if iotaDepth == scopeDepth { iotaDepth = 0 }
        scopeDepth -= 1
    }

    /// A call of what is in parentheses, `(*T)(nil)`, begins at the
    /// parenthesis, which the tree does not keep: noted by where the call
    /// is, at the `(` of its arguments, when one follows the `)`.
    mutating func noteCallStart(_ position: GoSourcePosition) {
        if check(.leftParen) { namePositions[current.position.offset] = [position] }
    }

    /// The names of a `:=` and then the `:=` itself, which the parser has
    /// just passed: Go reports a list that declares nothing there.
    mutating func noteShortDeclaration(
        at position: GoSourcePosition, names: [GoSourcePosition]
    ) {
        namePositions[position.offset] = names + [tokens[index - 1].position]
    }

    mutating func parseFile() throws -> GoFile {
        try expect(.package, message: "expected 'package'")
        let packageName = try expectIdentifier(message: "expected package name")
        try expectTerminator()

        var imports: [GoImportDeclaration] = []
        while check(.import) {
            advance()
            if check(.leftParen) {
                // `import ( "a"; "b" )`: an import for each path.
                advance()
                skipSemicolons()
                while !check(.rightParen) {
                    imports.append(try parseImport())
                    if check(.semicolon) {
                        skipSemicolons()
                    } else if !check(.rightParen) {
                        throw diagnostic("expected semicolon or newline")
                    }
                }
                advance()
            } else {
                imports.append(try parseImport())
            }
            try expectTerminator()
        }

        var typeDeclarations: [GoTypeDeclaration] = []
        var globalDeclarations: [GoGlobalDeclaration] = []
        var functions: [GoFunctionDeclaration] = []
        while !check(.eof) {
            skipSemicolons()
            if check(.eof) { break }
            if check(.typeKeyword) {
                typeDeclarations.append(contentsOf: try parseTypeDeclarations())
            } else if check(.variable) || check(.constant) {
                globalDeclarations.append(contentsOf: try parseGlobalDeclarations())
            } else {
                functions.append(try parseFunction())
            }
            skipSemicolons()
        }
        var file = GoFile(
            path: path,
            packageName: packageName,
            imports: imports,
            typeDeclarations: typeDeclarations,
            globalDeclarations: globalDeclarations,
            functions: functions)
        file.declaresLocalTypes = declaresLocalTypes
        file.hasOpenLiterals = hasOpenLiterals
        file.namePositions = namePositions
        return file
    }

    /// One import: the name the file gives the package, if any, and its path.
    mutating func parseImport() throws -> GoImportDeclaration {
        let position = current.position
        var name: String?
        if check(.period) {
            name = GoImportName.dot
            advance()
        } else if case .identifier(let identifier) = current.kind,
            !GoBitwiseOperator.isOperatorSpelling(identifier)
        {
            name = identifier
            advance()
        }
        guard case .string(let importPath) = current.kind else {
            throw diagnostic("expected import path")
        }
        advance()
        return GoImportDeclaration(name: name, path: importPath, position: position)
    }

    /// One specification of a `var` or `const`: `names [type] [= values]`.
    struct ValueSpecification {
        var names: [String]
        var type: GoTypeExpression?
        var values: [GoExpression]
        let position: GoSourcePosition
    }

    mutating func parseValueSpecification() throws -> ValueSpecification {
        let position = current.position
        var positions = [position]
        var names = [try expectIdentifier(message: "expected name in declaration")]
        while check(.comma) {
            advance()
            positions.append(current.position)
            names.append(try expectIdentifier(message: "expected name in declaration"))
        }
        namePositions[position.offset] = positions
        var type: GoTypeExpression?
        if !check(.assign), !check(.semicolon), !check(.rightParen), !check(.eof) {
            type = try parseTypeExpression()
        }
        var values: [GoExpression] = []
        if check(.assign) {
            advance()
            values.append(try parseExpression())
            while check(.comma) {
                advance()
                values.append(try parseExpression())
            }
        }
        return ValueSpecification(names: names, type: type, values: values, position: position)
    }

    /// The specifications of the `var` or `const` declaration at the
    /// keyword: one, or those of a parenthesized group, each with the
    /// position its declarations report. In a `const` group a specification
    /// without values repeats the type and the values of the one before it,
    /// and `iota` is the index of the specification.
    mutating func parseValueSpecifications() throws -> (isConstant: Bool, list: [ValueSpecification]) {
        let keywordPosition = current.position
        let isConstant = check(.constant)
        advance()
        func checked(_ specification: ValueSpecification) throws -> ValueSpecification {
            let names = specification.names.count
            let values = specification.values.count
            if isConstant, values == 0 {
                throw GoDiagnostic(
                    position: specification.position,
                    message: "missing init expr for \(specification.names[0])")
            }
            if specification.type == nil, values == 0 {
                throw GoDiagnostic(
                    position: specification.position,
                    message: "missing variable type or initialization")
            }
            // One call can give several variables their values, in a
            // function; otherwise there is a value for each name.
            guard values == 0 || values == names || (values == 1 && names > 1 && !isConstant)
            else {
                throw GoDiagnostic(
                    position: specification.position,
                    message:
                        "assignment mismatch: \(names) variable\(names == 1 ? "" : "s") but \(values) value\(values == 1 ? "" : "s")"
                )
            }
            return specification
        }
        guard check(.leftParen) else {
            var specification = try parseValueSpecification()
            // The declaration is where its keyword is; its names are not.
            namePositions[keywordPosition.offset] = namePositions.removeValue(
                forKey: specification.position.offset)
            specification = ValueSpecification(
                names: specification.names, type: specification.type,
                values: isConstant && !isIotaHidden
                    ? specification.values.map { $0.replacingIota(with: 0) } : specification.values,
                position: keywordPosition)
            // A name is declared after its specification: `const iota = iota`
            // still reads the generator.
            declare(specification.names)
            return (isConstant, [try checked(specification)])
        }
        advance()
        skipSemicolons()
        var list: [ValueSpecification] = []
        var repeated: ValueSpecification?
        while !check(.rightParen) {
            guard !check(.eof) else { throw diagnostic("expected ')'") }
            var specification = try parseValueSpecification()
            if isConstant {
                if specification.values.isEmpty, specification.type == nil, let repeated {
                    specification.type = repeated.type
                    specification.values = repeated.values
                } else {
                    repeated = specification
                }
                let index = list.count
                if !isIotaHidden {
                    specification.values = specification.values.map {
                        $0.replacingIota(with: index)
                    }
                }
            }
            declare(specification.names)
            list.append(try checked(specification))
            if check(.semicolon) {
                skipSemicolons()
            } else if !check(.rightParen) {
                throw diagnostic("expected semicolon or newline")
            }
        }
        advance()
        return (isConstant, list)
    }

    /// A package-level `var` or `const`, alone or in a group: a declaration
    /// for each name, as `var a, b int` and `var a, b = 1, 2` are.
    mutating func parseGlobalDeclarations() throws -> [GoGlobalDeclaration] {
        let specifications = try parseValueSpecifications()
        var declarations: [GoGlobalDeclaration] = []
        for specification in specifications.list {
            if specification.values.count == 1, specification.names.count > 1 {
                declarations.append(contentsOf: try groupedGlobalDeclarations(specification))
                continue
            }
            for (index, name) in specification.names.enumerated() {
                // A blank constant only takes its place in the count of `iota`.
                if specifications.isConstant, name == GoValueList.blank {
                    forgetBlankConstant(of: specification)
                    continue
                }
                declarations.append(
                    GoGlobalDeclaration(
                        name: name,
                        explicitType: specification.type,
                        expression: specification.values.isEmpty
                            ? nil : specification.values[index],
                        isConstant: specifications.isConstant,
                        position: specification.position))
            }
        }
        return declarations
    }

    /// The places of the names of a specification are those of the
    /// declarations it leaves, in their order: a blank constant leaves none.
    mutating func forgetBlankConstant(of specification: ValueSpecification) {
        let offset = specification.position.offset
        guard let positions = namePositions[offset], positions.count == specification.names.count
        else { return }
        namePositions[offset] = zip(specification.names, positions)
            .filter { $0.0 != GoValueList.blank }.map(\.1)
    }

    /// `var a, b = f()` at package level: a declaration for each name, whose
    /// value is its place among the values the one expression yields.
    func groupedGlobalDeclarations(
        _ specification: ValueSpecification
    ) throws -> [GoGlobalDeclaration] {
        let names = specification.names
        switch specification.values[0] {
        case .call, .index, .typeAssertion, .unary(.receive, _, _): break
        default:
            throw GoDiagnostic(
                position: specification.position,
                message: "assignment mismatch: \(names.count) variables but 1 value")
        }
        return names.indices.map { index in
            GoGlobalDeclaration(
                name: names[index],
                explicitType: specification.type,
                expression: .groupedResult(index, of: names.count, specification.values[0]),
                position: specification.position)
        }
    }

    /// `type name T`, or a group `type ( a T; b U )`.
    mutating func parseTypeDeclarations() throws -> [GoTypeDeclaration] {
        guard lookahead(1).kind == .leftParen else { return [try parseTypeDeclaration()] }
        advance()
        advance()
        skipSemicolons()
        var declarations: [GoTypeDeclaration] = []
        while !check(.rightParen) {
            guard !check(.eof) else { throw diagnostic("expected ')'") }
            let position = current.position
            declarations.append(try parseTypeSpecification(position: position))
            if check(.semicolon) {
                skipSemicolons()
            } else if !check(.rightParen) {
                throw diagnostic("expected semicolon or newline")
            }
        }
        advance()
        return declarations
    }

    mutating func parseTypeDeclaration() throws -> GoTypeDeclaration {
        advance()
        // A type is where its name is: the place Go reports it by.
        return try parseTypeSpecification(position: current.position)
    }

    /// `Name T`, a new type, or `Name = T`, another name for `T`.
    mutating func parseTypeSpecification(position: GoSourcePosition) throws -> GoTypeDeclaration {
        let name = try expectIdentifier(message: "expected type name")
        declare(name)
        let isAlias = check(.assign)
        if isAlias { advance() }
        return GoTypeDeclaration(
            name: name, type: try parseTypeExpression(), isAlias: isAlias, position: position)
    }

    mutating func parseTypeExpression() throws -> GoTypeExpression {
        let position = current.position
        if check(.function) {
            // `func(int, string) error`: what is taken and what is given,
            // by type; a name written beside one is not part of the type.
            // Go has the type start at its parameters, and reports there.
            advance()
            let position = current.position
            try expect(.leftParen, message: "expected '(' after func")
            let parameters = try parseSignatureTypes()
            for parameter in parameters.dropLast() {
                if case .array(GoSpread.variadicLength, _, let position) = parameter {
                    throw GoDiagnostic(
                        position: position,
                        message: "can only use ... with final parameter in list")
                }
            }
            return .function(
                parameters: parameters, results: try parseResults().types, position: position)
        }
        if check(.arrow) {
            advance()
            try expect(.chanKeyword, message: "expected 'chan' after '<-'")
            return .channel(
                direction: .receiveOnly,
                element: try parseTypeExpression(),
                position: position)
        }
        if check(.chanKeyword) {
            advance()
            let direction: GoChannelDirection
            if check(.arrow) {
                advance()
                direction = .sendOnly
            } else {
                direction = .bidirectional
            }
            return .channel(
                direction: direction,
                element: try parseTypeExpression(),
                position: position)
        }
        if check(.star) {
            advance()
            return .pointer(pointee: try parseTypeExpression(), position: position)
        }
        if check(.leftBracket) {
            advance()
            if check(.rightBracket) {
                advance()
                return .slice(element: try parseTypeExpression(), position: position)
            }
            if case .identifier(GoSpread.spelling) = current.kind, lookahead(1).kind == .rightBracket {
                // `[...]T`: an array as long as the literal it is the type of.
                advance()
                advance()
                hasOpenLiterals = true
                return .array(
                    length: GoCompositeLiterals.openLength, element: try parseTypeExpression(),
                    position: position)
            }
            guard case .integer(let length) = current.kind,
                length >= 0,
                let exactLength = Int(exactly: length)
            else {
                throw diagnostic("expected array length")
            }
            advance()
            try expect(.rightBracket, message: "expected ']' after array length")
            return .array(
                length: exactLength,
                element: try parseTypeExpression(),
                position: position)
        }
        if case .identifier(let name) = current.kind,
            !GoBitwiseOperator.isOperatorSpelling(name)
        {
            advance()
            if check(.period), case .identifier(let member) = lookahead(1).kind {
                advance()
                advance()
                return .named(name + "." + member, position: position)
            }
            return .named(name, position: position)
        }
        if check(.mapKeyword) {
            advance()
            try expect(.leftBracket, message: "expected '[' after map")
            let keyType = try parseTypeExpression()
            try expect(.rightBracket, message: "expected ']' after map key type")
            let valueType = try parseTypeExpression()
            return .map(key: keyType, value: valueType, position: position)
        }
        if check(.interfaceKeyword) {
            advance()
            try expect(.leftBrace, message: "expected '{' after interface")
            skipSemicolons()
            var methods: [GoInterfaceMethodDeclaration] = []
            while !check(.rightBrace) {
                guard !check(.eof) else { throw diagnostic("expected '}'") }
                let methodPosition = current.position
                let methodName = try expectIdentifier(message: "expected method name")
                try expect(.leftParen, message: "expected '('")
                let parameters = try parseSignatureTypes()
                for parameter in parameters.dropLast() {
                    if case .array(GoSpread.variadicLength, _, let position) = parameter {
                        throw GoDiagnostic(
                            position: position,
                            message: "can only use ... with final parameter in list")
                    }
                }
                var results: [GoTypeExpression] = []
                if case .identifier = current.kind {
                    results.append(try parseTypeExpression())
                } else if check(.leftParen) {
                    advance()
                    results = try parseSignatureTypes()
                } else if check(.structKeyword) || check(.star) || check(.leftBracket)
                    || check(.mapKeyword) || check(.interfaceKeyword) || check(.chanKeyword)
                    || check(.arrow)
                {
                    results.append(try parseTypeExpression())
                }
                methods.append(GoInterfaceMethodDeclaration(
                    name: methodName,
                    parameters: parameters,
                    results: results,
                    position: methodPosition))
                if check(.semicolon) { skipSemicolons() }
                else if !check(.rightBrace) {
                    throw diagnostic("expected semicolon or newline in interface type")
                }
            }
            advance()
            return .interface(methods: methods, position: position)
        }
        if check(.structKeyword) {
            advance()
            try expect(.leftBrace, message: "expected '{' after struct")
            skipSemicolons()
            var fields: [GoStructFieldDeclaration] = []
            while !check(.rightBrace) {
                guard !check(.eof) else { throw diagnostic("expected '}'") }
                // `X, Y int`: a field of that type for each name.
                var names = [(current.position, try expectIdentifier(message: "expected field name"))]
                while check(.comma) {
                    advance()
                    names.append(
                        (current.position, try expectIdentifier(message: "expected field name")))
                }
                let type = try parseTypeExpression()
                for (fieldPosition, name) in names {
                    fields.append(
                        GoStructFieldDeclaration(name: name, type: type, position: fieldPosition))
                }
                if check(.semicolon) {
                    skipSemicolons()
                } else if !check(.rightBrace) {
                    throw diagnostic("expected semicolon or newline in struct type")
                }
            }
            advance()
            return .structure(fields: fields, position: position)
        }
        throw diagnostic("expected type")
    }

    mutating func parseFunction() throws -> GoFunctionDeclaration {
        let position = current.position
        try expect(.function, message: "expected declaration")
        var receiver: GoParameter?
        if check(.leftParen) {
            advance()
            // A receiver is written like a parameter list of one: `(t T)`,
            // `(T)`, `(*T)`, `(_ T)`. Go reports another number where the
            // name of the method is.
            let receivers = try parseParameters()
            guard let first = receivers.first else { throw diagnostic("method has no receiver") }
            guard receivers.count == 1 else { throw diagnostic("method has multiple receivers") }
            receiver = first
        }
        let namePosition = current.position
        let name = try expectIdentifier(message: "expected function name")
        // The name of a function is the package's; what follows is its own.
        if receiver == nil { declare(name) }
        openScope()
        try expect(.leftParen, message: "expected '('")
        let parameters = try parseParameters()
        let results = try parseResults()
        if check(.semicolon) || check(.eof) {
            throw GoDiagnostic(position: namePosition, message: "missing function body")
        }
        declare((receiver.map { [$0] } ?? []).map(\.name) + parameters.map(\.name))
        declare(results.names.compactMap { $0 })
        let body = try parseBlock()
        closeScope()
        // Go reports a function by its name, and a return it lacks where
        // its body ends.
        namePositions[position.offset] =
            [namePosition, tokens[index - 1].position] + results.positions
        return GoFunctionDeclaration(
            name: name,
            receiver: receiver,
            parameters: parameters,
            resultNames: results.names,
            resultTypes: results.types,
            body: body,
            position: position)
    }

    /// The parameters of a function, after their `(` and with their `)`:
    /// each a name and a type, several names that share one, or types
    /// alone. A parameter without a name is one the blank identifier names.
    mutating func parseParameters() throws -> [GoParameter] {
        let parameters = try parseSignatureList(listName: " in parameter list").map {
            GoParameter(name: $0.name ?? GoValueList.blank, type: $0.type, position: $0.position)
        }
        try requireFinalVariadic(parameters)
        return parameters
    }

    /// One entry of a parameter or result list: its type, the name written
    /// before it if any, and where the entry is.
    typealias SignatureEntry = (name: String?, type: GoTypeExpression, position: GoSourcePosition)

    /// The entries of a parameter or result list, after its `(` and with
    /// its `)`.
    ///
    /// Go reads such a list as it stands and decides afterwards what it
    /// was: when no entry has a name and a type, every entry is a type, and
    /// an identifier alone names one; otherwise every entry must have a
    /// name, and an identifier alone is a name of the type that follows it
    /// (`a, b int`). This is Go's own procedure, with its two reports: an
    /// identifier that no type follows is `missing parameter type`, at the
    /// `)`, and a type where a name must be is `missing parameter name`.
    mutating func parseSignatureList(listName: String) throws -> [SignatureEntry] {
        var names: [String?] = []
        var types: [GoTypeExpression?] = []
        var positions: [GoSourcePosition] = []
        // Where the type of each entry begins, for an entry that has one.
        var typePositions: [GoSourcePosition] = []
        while !check(.rightParen) {
            guard !check(.eof) else { throw diagnostic("expected ')'") }
            let position = current.position
            var name: String?
            var type: GoTypeExpression?
            if case .identifier(let word) = current.kind,
                !GoBitwiseOperator.isOperatorSpelling(word)
            {
                advance()
                if check(.period), case .identifier(let member) = lookahead(1).kind {
                    // A qualified name is a type: `fmt.Stringer`.
                    advance()
                    advance()
                    type = .named(word + "." + member, position: position)
                } else {
                    name = word
                }
            }
            let typePosition = type == nil ? current.position : position
            if type == nil, startsParameterType(current.kind) { type = try parseParameterType() }
            guard name != nil || type != nil else { throw diagnostic("expected type") }
            names.append(name)
            types.append(type)
            positions.append(position)
            typePositions.append(typePosition)
            if check(.comma) {
                advance()
            } else if !check(.rightParen) {
                throw diagnostic("expected ',' or ')'" + listName)
            }
        }
        let end = current.position
        advance()

        let named = zip(names, types).filter { $0 != nil && $1 != nil }.count
        guard named > 0 else {
            // Types alone: an identifier by itself is the name of one.
            return names.indices.map { index in
                (nil, types[index] ?? .named(names[index] ?? "", position: positions[index]),
                    positions[index])
            }
        }
        // Names throughout: from the right, each name takes the type that
        // follows it.
        var entries: [SignatureEntry] = []
        var shared: GoTypeExpression?
        var misplaced: GoSourcePosition?
        for index in names.indices.reversed() {
            if let type = types[index] {
                shared = type
                if names[index] == nil { misplaced = typePositions[index] }
            } else if shared == nil {
                misplaced = positions[index]
            }
            guard let type = shared else { continue }
            entries.append((names[index] ?? GoValueList.blank, type, positions[index]))
        }
        if let misplaced {
            // Every entry with a type has a name, so what is missing is a
            // type, at the end; otherwise a name, where its type stands.
            let typed = types.filter { $0 != nil }.count
            throw named == typed
                ? GoDiagnostic(position: end, message: "syntax error: missing parameter type")
                : GoDiagnostic(position: misplaced, message: "syntax error: missing parameter name")
        }
        return entries.reversed()
    }

    /// Whether the type of a parameter can begin with a token of this kind,
    /// `...` included.
    func startsParameterType(_ kind: GoTokenKind) -> Bool {
        if case .identifier(let word) = kind {
            return word == GoSpread.spelling || !GoBitwiseOperator.isOperatorSpelling(word)
        }
        return isTypeStart(kind)
    }

    /// The results of a function, when it has any: one type, or a list in
    /// parentheses that may name them. With each name comes where it is.
    mutating func parseResults() throws -> (
        names: [String?], types: [GoTypeExpression], positions: [GoSourcePosition]
    ) {
        var resultNames: [String?] = []
        var resultTypes: [GoTypeExpression] = []
        var positions: [GoSourcePosition] = []
        if check(.leftParen) {
            advance()
            // Written like parameters: `(int, error)`, or `(n int, err error)`.
            for result in try parseSignatureList(listName: " in result type list") {
                resultTypes.append(result.type)
                resultNames.append(result.name)
                if result.name != nil { positions.append(result.position) }
            }
        } else if startsResultType(current.kind) {
            resultTypes.append(try parseTypeExpression())
            resultNames.append(nil)
        }
        return (resultNames, resultTypes, positions)
    }

    /// Whether a result type written without parentheses can begin with a
    /// token of this kind.
    func startsResultType(_ kind: GoTokenKind) -> Bool {
        if case .identifier(let word) = kind {
            return word != GoSpread.spelling && !GoBitwiseOperator.isOperatorSpelling(word)
        }
        return isTypeStart(kind)
    }

    func isTypeStart(_ kind: GoTokenKind) -> Bool {
        switch kind {
        case .identifier, .star, .leftBracket, .mapKeyword, .interfaceKeyword, .structKeyword,
            .chanKeyword, .arrow, .function:
            return true
        default:
            return false
        }
    }

    mutating func parseBlock() throws -> GoBlock {
        let position = current.position
        try expect(.leftBrace, message: "expected '{'")
        openScope()
        var statements: [GoStatement] = []
        skipSemicolons()
        while !check(.rightBrace) {
            guard !check(.eof) else { throw diagnostic("expected '}'") }
            statements.append(contentsOf: try parseStatements())
            if check(.semicolon) {
                skipSemicolons()
            } else if !check(.rightBrace) {
                throw diagnostic("expected semicolon or newline")
            }
        }
        advance()
        closeScope()
        return GoBlock(statements: statements, position: position)
    }

    /// The statement at the current token, or the several a `var` or
    /// `const` declaration stands for.
    mutating func parseStatements() throws -> [GoStatement] {
        if isAtLabel { return try parseLabeledStatements() }
        if check(.variable) || check(.constant) { return try parseDeclarations() }
        if check(.typeKeyword) {
            declaresLocalTypes = true
            return try parseTypeDeclarations().map {
                .localType(
                    name: $0.name, type: $0.type, isAlias: $0.isAlias, position: $0.position)
            }
        }
        return [try parseStatement()]
    }

    mutating func parseStatement() throws -> GoStatement {
        if let jump = try parseJump() { return jump }
        if check(.return) { return try parseReturn() }
        if check(.if) || check(.for) || check(.switchKeyword) || check(.selectKeyword) {
            return try parseHeaderStatement()
        }
        if check(.breakKeyword) {
            let position = current.position
            advance()
            return .breakStatement(position: position)
        }
        if check(.continueKeyword) {
            let position = current.position
            advance()
            return .continueStatement(position: position)
        }
        if check(.leftBrace) {
            let position = current.position
            return .block(try parseBlock(), position: position)
        }
        if check(.deferKeyword) {
            let position = current.position
            advance()
            let expression = try parseExpression()
            return .deferStatement(expression: expression, position: position)
        }
        if check(.goKeyword) {
            let position = current.position
            advance()
            return .goStatement(
                expression: try parseExpression(),
                position: position)
        }
        return try parseSimpleStatement()
    }

    /// An `if`, `for`, `switch`, or `select`. What its header declares
    /// lasts for the statement, which is a block around its own.
    mutating func parseHeaderStatement() throws -> GoStatement {
        openScope()
        let statement: GoStatement
        if check(.if) {
            statement = try parseIf()
        } else if check(.for) {
            statement = try parseFor()
        } else if check(.switchKeyword) {
            statement = try parseSwitch()
        } else {
            statement = try parseSelect()
        }
        closeScope()
        return statement
    }

    /// A `var` or `const` in a function, alone or in a group: a statement
    /// for each specification.
    mutating func parseDeclarations() throws -> [GoStatement] {
        let specifications = try parseValueSpecifications()
        return specifications.list.compactMap { specification in
            if specification.names.count > 1 {
                // `var a, b T`, `var a, b = x, y`, `var n, err = f()`.
                return .multiDeclaration(
                    names: specification.names,
                    expression: .variables(
                        type: specification.type, values: specification.values,
                        isConstant: specifications.isConstant, position: specification.position),
                    position: specification.position)
            }
            // A blank constant only takes its place in the count of `iota`.
            if specifications.isConstant, specification.names[0] == GoValueList.blank { return nil }
            return .declaration(
                name: specification.names[0],
                explicitType: specification.type,
                expression: specification.values.first,
                isConstant: specifications.isConstant,
                position: specification.position)
        }
    }

    mutating func parseReturn() throws -> GoStatement {
        let position = current.position
        advance()
        if check(.semicolon) || check(.rightBrace) {
            return .returnValues([], position: position)
        }
        var values = [try parseExpression()]
        while check(.comma) {
            advance()
            values.append(try parseExpression())
        }
        return .returnValues(values, position: position)
    }

    /// The optional initializer of an `if` or `switch` header, and the
    /// expression after it. Go writes both as `SimpleStmt; Expression`, and a
    /// header without `;` is the expression alone. `closesHeader` says
    /// whether a `{` may follow the `;`, as it may in a `switch` without a tag.
    mutating func parseHeader(
        closesHeader: Bool
    ) throws -> (initializer: GoStatement?, expression: GoExpression?) {
        if check(.semicolon) {
            // An empty initializer.
            advance()
            if closesHeader, check(.leftBrace) { return (nil, nil) }
            return (nil, try parseExpression(allowCompositeLiteral: false))
        }
        let first = try parseSimpleStatement(allowCompositeLiteral: false)
        if check(.semicolon) {
            advance()
            if closesHeader, check(.leftBrace) { return (first, nil) }
            return (first, try parseExpression(allowCompositeLiteral: false))
        }
        guard case .expression(let expression) = first else { return (first, nil) }
        return (nil, expression)
    }

    mutating func parseIf() throws -> GoStatement {
        let position = current.position
        advance()
        let header = try parseHeader(closesHeader: false)
        guard let condition = header.expression else {
            throw GoDiagnostic(position: position, message: "missing condition in if statement")
        }
        let thenBlock = try parseBlock()
        var elseBlock: GoBlock?
        if check(.else) {
            advance()
            if check(.if) {
                let elsePosition = current.position
                elseBlock = GoBlock(
                    statements: [try parseIf()],
                    position: elsePosition)
            } else {
                elseBlock = try parseBlock()
            }
        }
        let statement = GoStatement.ifStatement(
            condition: condition,
            thenBlock: thenBlock,
            elseBlock: elseBlock,
            position: position)
        guard let initializer = header.initializer else { return statement }
        return .initialized(statement, by: initializer, position: position)
    }

    mutating func parseFor() throws -> GoStatement {
        let position = current.position
        advance()
        if check(.leftBrace) {
            return .forStatement(
                initializer: nil,
                condition: nil,
                post: nil,
                body: try parseBlock(),
                position: position)
        }

        // for range expr { }   (Go 1.22+)
        if check(.rangeKeyword) {
            advance()
            let collection = try parseExpression(allowCompositeLiteral: false)
            return .forRangeStatement(
                indexName: nil,
                valueName: nil,
                collection: collection,
                body: try parseBlock(),
                position: position)
        }

        // Try to detect for-range with variables: for x := range ..., for x, y := range ...
        if case .identifier(let firstName) = current.kind {
            let saved = self
            let firstPosition = current.position
            advance()
            if check(.declare) {
                // for x := range expr
                advance()
                if check(.rangeKeyword) {
                    advance()
                    let collection = try parseExpression(allowCompositeLiteral: false)
                    namePositions[position.offset] = [firstPosition]
                    declare(firstName)
                    return .forRangeStatement(
                        indexName: firstName,
                        valueName: nil,
                        collection: collection,
                        body: try parseBlock(),
                        position: position)
                }
                // Not range — restore and fall through to normal parsing
                self = saved
            } else if check(.comma) {
                advance()
                if case .identifier(let secondName) = current.kind {
                    let secondPosition = current.position
                    advance()
                    if check(.declare) {
                        advance()
                        if check(.rangeKeyword) {
                            // for x, y := range expr
                            advance()
                            let collection = try parseExpression(allowCompositeLiteral: false)
                            namePositions[position.offset] = [firstPosition, secondPosition]
                            declare(firstName)
                            declare(secondName)
                            return .forRangeStatement(
                                indexName: firstName,
                                valueName: secondName,
                                collection: collection,
                                body: try parseBlock(),
                                position: position)
                        }
                    }
                }
                // Not range — restore and fall through
                self = saved
            } else {
                // Not a range form — restore
                self = saved
            }
        }

        var initializer: GoStatement?
        if check(.semicolon) {
            advance()
        } else {
            let first = try parseSimpleStatement(allowCompositeLiteral: false)
            if check(.semicolon) {
                initializer = first
                advance()
            } else {
                guard case .expression(let condition) = first else {
                    throw GoDiagnostic(position: position, message: "expected boolean or range expression")
                }
                return .forStatement(
                    initializer: nil,
                    condition: condition,
                    post: nil,
                    body: try parseBlock(),
                    position: position)
            }
        }

        let condition = check(.semicolon) ? nil : try parseExpression(allowCompositeLiteral: false)
        try expect(.semicolon, message: "expected ';' in for clause")
        let post = check(.leftBrace)
            ? nil
            : try parseSimpleStatement(allowShortDeclaration: false, allowCompositeLiteral: false)
        return .forStatement(
            initializer: initializer,
            condition: condition,
            post: post,
            body: try parseBlock(),
            position: position)
    }

    mutating func parseSwitch() throws -> GoStatement {
        let position = current.position
        advance()
        var header: (initializer: GoStatement?, expression: GoExpression?) = (nil, nil)
        if !check(.leftBrace) { header = try parseSwitchHeader() }
        let expression = header.expression
        // The clauses of a type switch list types.
        let listsTypes = expression?.isTypeSwitchGuard ?? false
        try expect(.leftBrace, message: "expected '{' after switch expression")
        skipSemicolons()

        var cases: [GoSwitchCase] = []
        while !check(.rightBrace) {
            guard !check(.eof) else { throw diagnostic("expected '}'") }
            let casePosition = current.position
            let isDefault: Bool
            var expressions: [GoExpression] = []
            if check(.caseKeyword) {
                isDefault = false
                advance()
                expressions.append(try parseCase(listsTypes: listsTypes))
                while check(.comma) {
                    advance()
                    expressions.append(try parseCase(listsTypes: listsTypes))
                }
            } else if check(.defaultKeyword) {
                isDefault = true
                advance()
            } else {
                throw diagnostic("expected 'case' or 'default'")
            }
            try expect(.colon, message: "expected ':' after switch case")

            openScope()
            var statements: [GoStatement] = []
            skipSemicolons()
            while !check(.caseKeyword) && !check(.defaultKeyword) && !check(.rightBrace) {
                guard !check(.eof) else { throw diagnostic("expected '}'") }
                statements.append(contentsOf: try parseStatements())
                if check(.semicolon) {
                    skipSemicolons()
                } else if !check(.caseKeyword) && !check(.defaultKeyword) && !check(.rightBrace) {
                    throw diagnostic("expected semicolon or newline")
                }
            }
            cases.append(
                GoSwitchCase(
                    expressions: expressions,
                    body: GoBlock(statements: statements, position: casePosition),
                    isDefault: isDefault,
                    position: casePosition))
            closeScope()
        }
        advance()
        let statement = GoStatement.switchStatement(
            expression: expression, cases: cases, position: position)
        guard let initializer = header.initializer else { return statement }
        return .initialized(statement, by: initializer, position: position)
    }

    /// The header of a `switch`, after the keyword and up to its `{`: an
    /// optional initializer, then nothing, the expression switched on, or
    /// the guard of a type switch, `x.(type)` or `v := x.(type)`. The guard
    /// that binds a name is written like a short declaration, and comes back
    /// as the guard with the name in it.
    mutating func parseSwitchHeader() throws -> (initializer: GoStatement?, expression: GoExpression?) {
        var initializer: GoStatement?
        var tag: GoStatement?
        var start = index
        if check(.semicolon) {
            advance()
        } else {
            let first = try parseSimpleStatement(allowCompositeLiteral: false)
            if check(.semicolon) {
                initializer = first
                advance()
            } else {
                tag = first
            }
        }
        if tag == nil, !check(.leftBrace) {
            start = index
            tag = try parseSimpleStatement(allowCompositeLiteral: false)
        }
        switch tag {
        case nil:
            return (initializer, nil)
        case .expression(let expression)?:
            return (initializer, expression)
        case .declaration(let name, nil, let value?, false, let position)?:
            if let typeGuard = value.bindingTypeSwitch(name, at: position) {
                return (initializer, typeGuard)
            }
            throw GoDiagnostic(
                position: operatorPosition(.declare, from: start), message: "cannot use := as value")
        case .multiDeclaration?:
            throw GoDiagnostic(
                position: operatorPosition(.declare, from: start), message: "cannot use := as value")
        case .assignment?, .multiAssignment?:
            throw GoDiagnostic(
                position: operatorPosition(.assign, from: start),
                message: "cannot use assignment as value")
        default:
            throw diagnostic("expected '{' after switch expression")
        }
    }

    /// Where the first token of `kind` is among those of the statement that
    /// began at the token `start` and ends before the current one.
    func operatorPosition(_ kind: GoTokenKind, from start: Int) -> GoSourcePosition {
        tokens[start..<index].first { $0.kind == kind }?.position ?? tokens[start].position
    }

    /// One entry of a `case`: an expression, or a type in a type switch.
    mutating func parseCase(listsTypes: Bool) throws -> GoExpression {
        try listsTypes ? parseCaseType() : parseExpression()
    }

    /// One type of a clause of a type switch, where `nil` is one.
    mutating func parseCaseType() throws -> GoExpression {
        if check(.leftParen) {
            // `case (T):`, as Go allows.
            advance()
            let type = try parseCaseType()
            try expect(.rightParen, message: "expected ')'")
            return type
        }
        let type = try parseTypeExpression()
        return .typeExpression(type, position: type.position)
    }

    /// `x.(type)`, at the `type` after `.(`. Only the header of a switch
    /// may hold one; the checker refuses it elsewhere.
    mutating func parseTypeSwitchGuard(
        of operand: GoExpression, at position: GoSourcePosition
    ) throws -> GoExpression {
        advance()
        try expect(.rightParen, message: "expected ')' after asserted type")
        return .typeSwitchGuard(operand, position: position)
    }

    // MARK: Labels and jumps

    /// Whether a label begins here: a name before a colon, where a
    /// statement begins.
    var isAtLabel: Bool {
        guard case .identifier(let name) = current.kind, lookahead(1).kind == .colon else {
            return false
        }
        return !GoBitwiseOperator.isOperatorSpelling(name)
    }

    /// The label at the current token and the statement it names, which is
    /// the next of its list. Before a `}` the statement may be left out, and
    /// nowhere else.
    mutating func parseLabeledStatements() throws -> [GoStatement] {
        guard case .identifier(let name) = current.kind else { return [] }
        let position = current.position
        advance()
        let colon = current.position
        advance()
        if check(.caseKeyword) || check(.defaultKeyword) || check(.eof) {
            throw GoDiagnostic(position: colon, message: "missing statement after label")
        }
        let label = GoStatement.branch(.label(name), position: position)
        if check(.rightBrace) || check(.semicolon) { return [label] }
        return [label] + (try parseStatements())
    }

    /// `break L`, `continue L`, `goto L`, or `fallthrough`, when the
    /// statement at the current token is one. The lexer has no token for
    /// the last two keywords: each is an identifier that begins a statement.
    mutating func parseJump() throws -> GoStatement? {
        let position = current.position
        let jump: (String) -> GoBranch
        switch current.kind {
        case .breakKeyword:
            jump = GoBranch.breakTo
        case .continueKeyword:
            jump = GoBranch.continueTo
        case .identifier(GoBranch.gotoKeyword):
            jump = GoBranch.goto
        case .identifier(GoBranch.fallthroughKeyword):
            advance()
            return .branch(.fallthrough, position: position)
        default:
            return nil
        }
        guard case .identifier(let label) = lookahead(1).kind,
            !GoBitwiseOperator.isOperatorSpelling(label)
        else {
            // A `break` or `continue` without a label is a statement the
            // tree has a case for.
            if case .identifier = current.kind {
                throw GoDiagnostic(
                    position: lookahead(1).position, message: "expected label after goto")
            }
            return nil
        }
        advance()
        let labelPosition = current.position
        advance()
        return .branch(jump(label), position: position, labelPosition: labelPosition)
    }

    mutating func parseSelect() throws -> GoStatement {
        let position = current.position
        advance()
        try expect(.leftBrace, message: "expected '{' after select")
        skipSemicolons()

        var cases: [GoSelectCase] = []
        while !check(.rightBrace) {
            guard !check(.eof) else { throw diagnostic("expected '}'") }
            let casePosition = current.position
            openScope()
            let communication: GoStatement?
            if check(.caseKeyword) {
                advance()
                communication = try parseSimpleStatement()
            } else if check(.defaultKeyword) {
                advance()
                communication = nil
            } else {
                throw diagnostic("expected 'case' or 'default'")
            }
            try expect(.colon, message: "expected ':' after select case")

            var statements: [GoStatement] = []
            skipSemicolons()
            while !check(.caseKeyword) && !check(.defaultKeyword) && !check(.rightBrace) {
                guard !check(.eof) else { throw diagnostic("expected '}'") }
                statements.append(contentsOf: try parseStatements())
                if check(.semicolon) {
                    skipSemicolons()
                } else if !check(.caseKeyword) && !check(.defaultKeyword) && !check(.rightBrace) {
                    throw diagnostic("expected semicolon or newline")
                }
            }
            cases.append(GoSelectCase(
                communication: communication,
                body: GoBlock(statements: statements, position: casePosition),
                position: casePosition))
            closeScope()
        }
        advance()
        return .selectStatement(cases: cases, position: position)
    }

    /// The right side of a `:=` or `=` with several names on its left: one
    /// expression that yields them all, or a value for each.
    mutating func parseValues(allowCompositeLiteral: Bool) throws -> GoExpression {
        let position = current.position
        var values = [try parseExpression(allowCompositeLiteral: allowCompositeLiteral)]
        while check(.comma) {
            advance()
            values.append(try parseExpression(allowCompositeLiteral: allowCompositeLiteral))
        }
        return values.count == 1 ? values[0] : .valueList(values, position: position)
    }

    /// The right side of a `:=` or `=` with one name on its left.
    mutating func parseSingleValue(allowCompositeLiteral: Bool) throws -> GoExpression {
        let position = current.position
        let value = try parseValues(allowCompositeLiteral: allowCompositeLiteral)
        if let values = value.valueList {
            throw GoDiagnostic(
                position: position,
                message: "assignment mismatch: 1 variable but \(values.count) values")
        }
        return value
    }

    /// `allowCompositeLiteral` is false in a `for` header, where `x {` opens
    /// the loop body rather than a composite literal.
    mutating func parseSimpleStatement(
        allowShortDeclaration: Bool = true,
        allowCompositeLiteral: Bool = true
    ) throws -> GoStatement {
        let position = current.position
        let target = try parseExpression(allowCompositeLiteral: allowCompositeLiteral)
        if check(.comma) {
            // Could be multi-value declaration (a, b := f()) or assignment (a, b = f())
            var targets: [GoExpression] = [target]
            while check(.comma) {
                advance()
                targets.append(try parseExpression(allowCompositeLiteral: allowCompositeLiteral))
            }
            if check(.declare) {
                guard allowShortDeclaration else {
                    throw GoDiagnostic(
                        position: position,
                        message: "cannot declare in post statement of for loop")
                }
                advance()
                let names = try targets.map { expr -> String in
                    guard case .identifier(let name, _) = expr else {
                        throw GoDiagnostic(
                            position: expr.position,
                            message: "non-name on left side of :=")
                    }
                    return name
                }
                noteShortDeclaration(at: position, names: targets.map(\.position))
                let values = try parseValues(allowCompositeLiteral: allowCompositeLiteral)
                declare(names)
                return .multiDeclaration(names: names, expression: values, position: position)
            }
            if check(.assign) {
                advance()
                return .multiAssignment(
                    targets: targets,
                    expression: try parseValues(allowCompositeLiteral: allowCompositeLiteral),
                    position: position)
            }
            throw GoDiagnostic(
                position: current.position,
                message: "expected ':=' or '=' after expression list")
        }
        if check(.declare) {
            guard allowShortDeclaration else {
                throw GoDiagnostic(
                    position: position,
                    message: "cannot declare in post statement of for loop")
            }
            guard case .identifier(let name, _) = target else {
                throw GoDiagnostic(position: position, message: "non-name on left side of :=")
            }
            advance()
            noteShortDeclaration(at: position, names: [position])
            let value = try parseSingleValue(allowCompositeLiteral: allowCompositeLiteral)
            declare(name)
            return .declaration(
                name: name, explicitType: nil, expression: value, isConstant: false,
                position: position)
        }
        if check(.assign) {
            advance()
            return .assignment(
                target: target,
                expression: try parseSingleValue(allowCompositeLiteral: allowCompositeLiteral),
                position: position)
        }
        if case .identifier(let spelling) = current.kind,
            let compound = GoCompoundAssignment(spelling: spelling)
        {
            let operatorPosition = current.position
            guard target.isRepeatable else {
                throw GoDiagnostic(
                    position: operatorPosition,
                    message: "\(spelling) target must not contain a call or a channel receive")
            }
            advance()
            let value = try parseExpression(allowCompositeLiteral: allowCompositeLiteral)
            return .assignment(
                target: target,
                expression: compound.apply(to: target, value, position: operatorPosition),
                position: position)
        }
        if check(.arrow) {
            advance()
            return .sendStatement(
                channel: target,
                value: try parseExpression(allowCompositeLiteral: allowCompositeLiteral),
                position: position)
        }
        if check(.increment) || check(.decrement) {
            let incrementOperator: GoIncrementOperator =
                check(.increment) ? .increment : .decrement
            advance()
            return .increment(target: target, operator: incrementOperator, position: position)
        }
        return .expression(target)
    }

    mutating func parseExpression(
        minimumPrecedence: Int = 1,
        allowCompositeLiteral: Bool = true
    ) throws -> GoExpression {
        var left = try parseUnary(allowCompositeLiteral: allowCompositeLiteral)
        while true {
            let position = current.position
            if let (precedence, binaryOperator) = binaryOperator(for: current.kind),
                precedence >= minimumPrecedence
            {
                advance()
                let right = try parseExpression(
                    minimumPrecedence: precedence + 1,
                    allowCompositeLiteral: allowCompositeLiteral)
                left = .binary(
                    left: left,
                    operator: binaryOperator,
                    right: right,
                    position: position)
            } else if let bitwiseOperator = bitwiseOperator(for: current.kind),
                bitwiseOperator.precedence >= minimumPrecedence
            {
                advance()
                let right = try parseExpression(
                    minimumPrecedence: bitwiseOperator.precedence + 1,
                    allowCompositeLiteral: allowCompositeLiteral)
                left = .bitwise(bitwiseOperator, operands: [left, right], position: position)
            } else {
                return left
            }
        }
    }

    mutating func parseUnary(allowCompositeLiteral: Bool = true) throws -> GoExpression {
        let position = current.position
        if current.kind == .identifier(GoBitwiseOperator.complement.spelling) {
            advance()
            return .bitwise(
                .complement,
                operands: [try parseUnary(allowCompositeLiteral: allowCompositeLiteral)],
                position: position)
        }
        let unaryOperator: GoUnaryOperator?
        switch current.kind {
        case .plus: unaryOperator = .plus
        case .minus: unaryOperator = .minus
        case .bang: unaryOperator = .not
        case .ampersand: unaryOperator = .address
        case .star: unaryOperator = .dereference
        case .arrow: unaryOperator = .receive
        default: unaryOperator = nil
        }
        if let unaryOperator {
            advance()
            let operand = try parseUnary(allowCompositeLiteral: allowCompositeLiteral)
            if unaryOperator == .receive,
                case .typeExpression(.channel(.bidirectional, let element, _), _) = operand
            {
                // `(<-chan int)(c)`: the arrow before a channel type is
                // part of the type, not a receive from it.
                return .typeExpression(
                    .channel(direction: .receiveOnly, element: element, position: position),
                    position: position)
            }
            return .unary(operator: unaryOperator, operand: operand, position: position)
        }
        return try parsePostfix(allowCompositeLiteral: allowCompositeLiteral)
    }

    mutating func parsePostfix(allowCompositeLiteral: Bool = true) throws -> GoExpression {
        var expression = try parsePrimary()
        while true {
            if allowCompositeLiteral, check(.leftBrace),
                case .identifier(let typeName, let typePosition) = expression
            {
                expression = try parseCompositeLiteral(
                    type: .named(typeName, position: typePosition))
                continue
            }
            if allowCompositeLiteral, check(.leftBrace),
                case .selector(.identifier(let qualifier, let typePosition), let typeName, _) =
                    expression
            {
                // A qualified type name: `pkg.Type{...}`.
                expression = try parseCompositeLiteral(
                    type: .named(qualifier + "." + typeName, position: typePosition))
                continue
            }
            // A literal type before `{` is a composite literal wherever it
            // stands, in a `for`, `if`, or `switch` header too: only a type
            // *name* could be mistaken for the operand before a block.
            if check(.leftBrace), case .typeExpression(let type, _) = expression {
                expression = try parseCompositeLiteral(type: type)
                continue
            }
            if check(.period) {
                let position = current.position
                advance()
                if check(.leftParen) {
                    advance()
                    if check(.typeKeyword) {
                        expression = try parseTypeSwitchGuard(of: expression, at: position)
                        continue
                    }
                    let assertedType = try parseTypeExpression()
                    try expect(.rightParen, message: "expected ')' after asserted type")
                    expression = .typeAssertion(
                        base: expression, type: assertedType, position: position)
                    continue
                }
                // A selection is where the selected name is: the place Go
                // reports it by.
                let namePosition = current.position
                let name = try expectIdentifier(message: "expected selector name")
                expression = .selector(base: expression, name: name, position: namePosition)
                continue
            }
            if check(.leftParen) {
                let position = current.position
                advance()
                var arguments: [GoExpression] = []
                if !check(.rightParen) {
                    arguments.append(try parseArgument())
                    while check(.comma) {
                        advance()
                        if check(.rightParen) { break }
                        arguments.append(try parseArgument())
                    }
                }
                try expect(.rightParen, message: "expected ')'")
                if case .identifier(let name, _) = expression, GoCompositeLiterals.takesType(name),
                    let first = arguments.first
                {
                    // `new(T)`, `make(T, n)`: whether the name is a type is
                    // for what declares it to say.
                    if case .typeExpression = first {} else { hasOpenLiterals = true }
                }
                expression = .call(callee: expression, arguments: arguments, position: position)
                continue
            }
            if check(.leftBracket) {
                let position = current.position
                advance()
                var low: GoExpression?
                if !check(.colon) && !check(.rightBracket) {
                    low = try parseExpression()
                }
                if check(.colon) {
                    advance()
                    let high = check(.rightBracket) ? nil : try parseExpression()
                    try expect(.rightBracket, message: "expected ']'")
                    expression = .slicing(
                        base: expression,
                        low: low,
                        high: high,
                        position: position)
                } else {
                    guard let index = low else { throw diagnostic("expected index") }
                    try expect(.rightBracket, message: "expected ']'")
                    expression = .index(base: expression, index: index, position: position)
                }
                continue
            }
            return expression
        }
    }

    mutating func parseCompositeLiteral(type: GoTypeExpression) throws -> GoExpression {
        let position = type.position
        parentheses.recordLiteral(openingAt: current.position.offset)
        try expect(.leftBrace, message: "expected '{'")
        skipSemicolons()
        var elements: [GoCompositeElement] = []
        while !check(.rightBrace) {
            let elementPosition = current.position
            var key: String?
            var keyExpression: GoExpression?
            var value = try parseLiteralValue()
            if check(.colon) {
                // What stands before a colon is a key. Whether it names a
                // field, or is the key of a map or an index, is for the
                // type of the literal to say.
                advance()
                (key, keyExpression) = GoCompositeElement.key(value, in: type)
                value = try parseLiteralValue()
                switch type {
                case .map, .structure: break
                default: hasOpenLiterals = true
                }
            }
            elements.append(
                GoCompositeElement(
                    key: key,
                    keyExpression: keyExpression,
                    value: value,
                    position: elementPosition))
            if check(.comma) {
                advance()
                skipSemicolons()
            } else if !check(.rightBrace) {
                // Also the end of a line: an element that ends one is
                // followed by a comma.
                throw diagnostic("expected ',' or '}' in composite literal")
            }
        }
        // A struct literal that gives too few values is reported where it
        // ends, which the tree does not keep.
        if !elements.isEmpty, elements.allSatisfy({ $0.key == nil && $0.keyExpression == nil }) {
            switch type {
            case .named, .structure:
                namePositions[GoCompositeLiterals.endKey(of: position)] = [current.position]
            default: break
            }
        }
        advance()
        return .compositeLiteral(type: type, elements: elements, position: position)
    }

    /// An element of a composite literal, or its key: an expression, or a
    /// literal in braces that leaves its type to the literal around it.
    mutating func parseLiteralValue() throws -> GoExpression {
        guard check(.leftBrace) else { return try parseExpression() }
        hasOpenLiterals = true
        return try parseCompositeLiteral(
            type: .named(GoCompositeLiterals.elidedTypeName, position: current.position))
    }

    mutating func parsePrimary() throws -> GoExpression {
        let token = current
        switch token.kind {
        case .integer(let value):
            advance()
            return .integer(value, position: token.position)
        case .string(let value):
            advance()
            return .string(value, position: token.position)
        case .identifier(let name) where !GoBitwiseOperator.isOperatorSpelling(name):
            advance()
            return .identifier(name, position: token.position)
        case .leftParen:
            advance()
            let expression = try parseExpression()
            let close = current.position.offset
            try expect(.rightParen, message: "expected ')'")
            parentheses.record(around: expression, open: token.position.offset, close: close)
            noteCallStart(token.position)
            return expression
        case .leftBracket:
            let type = try parseTypeExpression()
            return .typeExpression(type, position: token.position)
        case .mapKeyword:
            let type = try parseTypeExpression()
            return .typeExpression(type, position: token.position)
        case .interfaceKeyword:
            let type = try parseTypeExpression()
            return .typeExpression(type, position: token.position)
        case .chanKeyword:
            let type = try parseTypeExpression()
            return .typeExpression(type, position: token.position)
        case .structKeyword:
            // `struct{ a int }{1}`, and the type alone in a conversion or
            // as the argument of `new`.
            let type = try parseTypeExpression()
            return .typeExpression(type, position: token.position)
        case .function:
            return try parseFunctionLiteralOrType()
        default:
            throw diagnostic("expected expression")
        }
    }

    /// The type of a parameter, where `...T` is a variadic one: an array type
    /// of the marker length that stands for it.
    /// The types of the parameters or results of an interface method, up to
    /// and with the `)`. The list may name what it lists, `(key string)` or
    /// `(a, b int)`; a method of an interface keeps the types.
    mutating func parseSignatureTypes() throws -> [GoTypeExpression] {
        try parseSignatureList(listName: "").map(\.type)
    }

    mutating func parseParameterType() throws -> GoTypeExpression {
        guard case .identifier(GoSpread.spelling) = current.kind else {
            return try parseTypeExpression()
        }
        let position = current.position
        advance()
        return .array(
            length: GoSpread.variadicLength, element: try parseTypeExpression(),
            position: position)
    }

    /// Go allows `...` on the last parameter only, and on one name.
    func requireFinalVariadic(_ parameters: [GoParameter]) throws {
        func isVariadic(_ parameter: GoParameter) -> Bool {
            if case .array(let length, _, _) = parameter.type {
                return length == GoSpread.variadicLength
            }
            return false
        }
        for (index, parameter) in parameters.enumerated() where isVariadic(parameter) {
            let sharesType =
                index > 0 && parameters[index - 1].type == parameter.type
                && parameters[index - 1].type.position == parameter.type.position
            guard index == parameters.count - 1, !sharesType else {
                throw GoDiagnostic(
                    position: parameter.type.position,
                    message: "can only use ... with final parameter in list")
            }
        }
    }

    /// One call argument. A trailing `...` makes it a spread node; the type
    /// checker decides where one is allowed.
    mutating func parseArgument() throws -> GoExpression {
        let argument = try parseExpression()
        guard case .identifier(GoSpread.spelling) = current.kind else { return argument }
        let position = current.position
        advance()
        return .spread(argument, position: position)
    }

    /// A function literal, or a function type where an expression may be
    /// one: `(func())(nil)`, `new(func(int) string)`. What does not read as
    /// a literal is a type when no body follows it.
    mutating func parseFunctionLiteralOrType() throws -> GoExpression {
        // A signature that is no literal's has recorded nothing by the time
        // it fails, so going back is going back in the tokens.
        let start = index
        do {
            return try parseFunctionLiteral()
        } catch let failure as GoDiagnostic {
            index = start
            let position = current.position
            guard let type = try? parseTypeExpression(), !check(.leftBrace) else { throw failure }
            return .typeExpression(type, position: position)
        }
    }

    mutating func parseFunctionLiteral() throws -> GoExpression {
        let position = current.position
        advance()
        openScope()
        try expect(.leftParen, message: "expected '(' after func")
        let parameters = try parseParameters()
        let results = try parseResults()
        declare(parameters.map(\.name) + results.names.compactMap { $0 })
        let body = try parseBlock()
        closeScope()
        // As for a declared function: where it is, and where its body ends.
        namePositions[position.offset] = [position, tokens[index - 1].position]
        return .functionLiteral(
            parameters: parameters,
            resultNames: results.names,
            resultTypes: results.types,
            body: body,
            position: position)
    }

    func binaryOperator(for kind: GoTokenKind) -> (Int, GoBinaryOperator)? {
        switch kind {
        case .logicalOr: return (1, .logicalOr)
        case .logicalAnd: return (2, .logicalAnd)
        case .equal: return (3, .equal)
        case .notEqual: return (3, .notEqual)
        case .less: return (4, .less)
        case .lessEqual: return (4, .lessEqual)
        case .greater: return (4, .greater)
        case .greaterEqual: return (4, .greaterEqual)
        case .plus: return (5, .add)
        case .minus: return (5, .subtract)
        case .star: return (6, .multiply)
        case .slash: return (6, .divide)
        case .percent: return (6, .remainder)
        default: return nil
        }
    }

    /// Bitwise operators arrive as identifier tokens spelled like the operator,
    /// except `&`, which shares its token with address-of.
    func bitwiseOperator(for kind: GoTokenKind) -> GoBitwiseOperator? {
        switch kind {
        case .ampersand: return .and
        case .identifier(let spelling): return GoBitwiseOperator.binary(spelling: spelling)
        default: return nil
        }
    }

    mutating func expectIdentifier(message: String) throws -> String {
        guard case .identifier(let name) = current.kind,
            !GoBitwiseOperator.isOperatorSpelling(name)
        else { throw diagnostic(message) }
        advance()
        return name
    }

    mutating func expectTerminator() throws {
        try expect(.semicolon, message: "expected semicolon or newline")
        skipSemicolons()
    }

    mutating func expect(_ kind: GoTokenKind, message: String) throws {
        guard check(kind) else { throw diagnostic(message) }
        advance()
    }

    mutating func skipSemicolons() {
        while check(.semicolon) { advance() }
    }

    func check(_ kind: GoTokenKind) -> Bool { current.kind == kind }

    var current: GoToken { tokens[min(index, tokens.count - 1)] }

    func lookahead(_ distance: Int) -> GoToken {
        tokens[min(index + distance, tokens.count - 1)]
    }

    mutating func advance() {
        if index < tokens.count - 1 { index += 1 }
    }

    func diagnostic(_ message: String) -> GoDiagnostic {
        GoDiagnostic(position: current.position, message: message)
    }
}
