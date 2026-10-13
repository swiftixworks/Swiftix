/// Recursive-descent parser for the first Go-compatible language checkpoint.

public enum GoParser {
    public static func parse(_ source: GoSourceFile) throws -> GoFile {
        var parser = Parser(tokens: try GoLexer.tokenize(source), path: source.path)
        return try parser.parseFile()
    }

    /// Parses `source` and also reports where it has parentheses around an
    /// expression. The tree keeps no node for a pair; `gofmt` needs to know
    /// where they are.
    static func parseRecordingParentheses(
        _ source: GoSourceFile
    ) throws -> (file: GoFile, parentheses: GoParentheses) {
        var parser = Parser(tokens: try GoLexer.tokenize(source), path: source.path)
        let file = try parser.parseFile()
        return (file, parser.parentheses)
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
        lhs.redundant == rhs.redundant && lhs.pairs.count == rhs.pairs.count
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
        var names = [try expectIdentifier(message: "expected name in declaration")]
        while check(.comma) {
            advance()
            names.append(try expectIdentifier(message: "expected name in declaration"))
        }
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
            specification = ValueSpecification(
                names: specification.names, type: specification.type,
                values: isConstant
                    ? specification.values.map { $0.replacingIota(with: 0) } : specification.values,
                position: keywordPosition)
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
                specification.values = specification.values.map { $0.replacingIota(with: index) }
            }
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
            guard specification.values.isEmpty
                || specification.values.count == specification.names.count
            else {
                // One call for several package-level variables has no single
                // declaration to stand for it.
                throw GoDiagnostic(
                    position: specification.position,
                    message:
                        "assignment mismatch: \(specification.names.count) variables but 1 value")
            }
            for (index, name) in specification.names.enumerated() {
                // A blank constant only takes its place in the count of `iota`.
                if specifications.isConstant, name == GoValueList.blank { continue }
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
            let name = try expectIdentifier(message: "expected type name")
            declarations.append(
                GoTypeDeclaration(name: name, type: try parseTypeExpression(), position: position))
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
        let position = current.position
        advance()
        let name = try expectIdentifier(message: "expected type name")
        return GoTypeDeclaration(
            name: name,
            type: try parseTypeExpression(),
            position: position)
    }

    mutating func parseTypeExpression() throws -> GoTypeExpression {
        let position = current.position
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
                var parameters: [GoTypeExpression] = []
                while !check(.rightParen) {
                    // Interface methods only declare types, not names
                    let parameter = try parseParameterType()
                    parameters.append(parameter)
                    if check(.comma) { advance() }
                    if case .array(GoSpread.variadicLength, _, let position) = parameter,
                        !check(.rightParen)
                    {
                        throw GoDiagnostic(
                            position: position,
                            message: "can only use ... with final parameter in list")
                    }
                }
                advance()  // consume ')'
                var results: [GoTypeExpression] = []
                if case .identifier = current.kind {
                    results.append(try parseTypeExpression())
                } else if check(.leftParen) {
                    advance()
                    while !check(.rightParen) {
                        results.append(try parseTypeExpression())
                        if check(.comma) { advance() }
                    }
                    advance()
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
                let fieldPosition = current.position
                let name = try expectIdentifier(message: "expected field name")
                fields.append(
                    GoStructFieldDeclaration(
                        name: name,
                        type: try parseTypeExpression(),
                        position: fieldPosition))
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
            let receiverPosition = current.position
            let receiverName = try expectIdentifier(message: "expected receiver name")
            receiver = GoParameter(
                name: receiverName,
                type: try parseTypeExpression(),
                position: receiverPosition)
            try expect(.rightParen, message: "expected ')' after receiver")
        }
        let name = try expectIdentifier(message: "expected function name")
        try expect(.leftParen, message: "expected '('")
        var parameters: [GoParameter] = []
        while !check(.rightParen) {
            var names: [(String, GoSourcePosition)] = []
            let firstPosition = current.position
            names.append(
                (
                    try expectIdentifier(message: "expected parameter name"),
                    firstPosition
                ))
            while check(.comma), case .identifier = lookahead(1).kind {
                advance()
                let namePosition = current.position
                names.append(
                    (
                        try expectIdentifier(message: "expected parameter name"),
                        namePosition
                    ))
            }
            let type = try parseParameterType()
            parameters.append(
                contentsOf: names.map {
                    GoParameter(name: $0.0, type: type, position: $0.1)
                })
            if check(.comma) {
                advance()
                if check(.rightParen) { break }
            } else if !check(.rightParen) {
                throw diagnostic("expected ',' or ')' in parameter list")
            }
        }
        advance()
        try requireFinalVariadic(parameters)
        var resultNames: [String?] = []
        var resultTypes: [GoTypeExpression] = []
        if case .identifier = current.kind {
            resultTypes.append(try parseTypeExpression())
            resultNames.append(nil)
        } else if check(.structKeyword) || check(.star) || check(.leftBracket)
            || check(.mapKeyword) || check(.interfaceKeyword) || check(.chanKeyword)
            || check(.arrow)
        {
            resultTypes.append(try parseTypeExpression())
            resultNames.append(nil)
        } else if check(.leftParen) {
            advance()
            while !check(.rightParen) {
                guard !check(.eof) else { throw diagnostic("expected ')'") }
                if let names = namedResultGroup() {
                    for _ in names {
                        resultTypes.append(try parseTypeExpression())
                    }
                    resultNames.append(contentsOf: names.map(Optional.some))
                } else {
                    resultTypes.append(try parseTypeExpression())
                    resultNames.append(nil)
                }
                if check(.comma) {
                    advance()
                } else if !check(.rightParen) {
                    throw diagnostic("expected ',' or ')' in result type list")
                }
            }
            advance()
        }
        return GoFunctionDeclaration(
            name: name,
            receiver: receiver,
            parameters: parameters,
            resultNames: resultNames,
            resultTypes: resultTypes,
            body: try parseBlock(),
            position: position)
    }

    /// Returns and consumes a named result group when the upcoming tokens have
    /// the `name[, name] type` shape. A plain `(int, string)` result list is
    /// deliberately left to `parseTypeExpression`.
    mutating func namedResultGroup() -> [String]? {
        guard case .identifier(let first) = current.kind else { return nil }
        var names = [first]
        var cursor = 1
        while lookahead(cursor).kind == .comma,
            case .identifier(let name) = lookahead(cursor + 1).kind
        {
            names.append(name)
            cursor += 2
        }
        guard isTypeStart(lookahead(cursor).kind) else { return nil }
        for _ in names.indices {
            advance()
            if names.count > 1, check(.comma) { advance() }
        }
        return names
    }

    func isTypeStart(_ kind: GoTokenKind) -> Bool {
        switch kind {
        case .identifier, .star, .leftBracket, .mapKeyword, .interfaceKeyword, .structKeyword,
            .chanKeyword, .arrow:
            return true
        default:
            return false
        }
    }

    mutating func parseBlock() throws -> GoBlock {
        let position = current.position
        try expect(.leftBrace, message: "expected '{'")
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
        return GoBlock(statements: statements, position: position)
    }

    /// The statement at the current token, or the several a `var` or
    /// `const` declaration stands for.
    mutating func parseStatements() throws -> [GoStatement] {
        if check(.variable) || check(.constant) { return try parseDeclarations() }
        if check(.typeKeyword) {
            declaresLocalTypes = true
            // Go reports a type by where its name is.
            let isGroup = lookahead(1).kind == .leftParen
            let namePosition = lookahead(1).position
            return try parseTypeDeclarations().map {
                .localType(
                    name: $0.name, type: $0.type, position: isGroup ? $0.position : namePosition)
            }
        }
        return [try parseStatement()]
    }

    mutating func parseStatement() throws -> GoStatement {
        if check(.return) { return try parseReturn() }
        if check(.if) { return try parseIf() }
        if check(.for) { return try parseFor() }
        if check(.switchKeyword) { return try parseSwitch() }
        if check(.selectKeyword) { return try parseSelect() }
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
            advance()
            if check(.declare) {
                // for x := range expr
                advance()
                if check(.rangeKeyword) {
                    advance()
                    let collection = try parseExpression(allowCompositeLiteral: false)
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
                    advance()
                    if check(.declare) {
                        advance()
                        if check(.rangeKeyword) {
                            // for x, y := range expr
                            advance()
                            let collection = try parseExpression(allowCompositeLiteral: false)
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
        if !check(.leftBrace) {
            header = try parseHeader(closesHeader: true)
            if header.expression == nil, header.initializer != nil, !check(.leftBrace) {
                throw diagnostic("expected '{' after switch expression")
            }
        }
        let expression = header.expression
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
                expressions.append(try parseExpression())
                while check(.comma) {
                    advance()
                    expressions.append(try parseExpression())
                }
            } else if check(.defaultKeyword) {
                isDefault = true
                advance()
            } else {
                throw diagnostic("expected 'case' or 'default'")
            }
            try expect(.colon, message: "expected ':' after switch case")

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
        }
        advance()
        let statement = GoStatement.switchStatement(
            expression: expression, cases: cases, position: position)
        guard let initializer = header.initializer else { return statement }
        return .initialized(statement, by: initializer, position: position)
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
                return .multiDeclaration(
                    names: names,
                    expression: try parseValues(allowCompositeLiteral: allowCompositeLiteral),
                    position: position)
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
            return .declaration(
                name: name,
                explicitType: nil,
                expression: try parseSingleValue(allowCompositeLiteral: allowCompositeLiteral),
                isConstant: false,
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
            return .unary(
                operator: unaryOperator,
                operand: try parseUnary(allowCompositeLiteral: allowCompositeLiteral),
                position: position)
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
                    let assertedType = try parseTypeExpression()
                    try expect(.rightParen, message: "expected ')' after asserted type")
                    expression = .typeAssertion(
                        base: expression, type: assertedType, position: position)
                    continue
                }
                let name = try expectIdentifier(message: "expected selector name")
                expression = .selector(base: expression, name: name, position: position)
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
        try expect(.leftBrace, message: "expected '{'")
        skipSemicolons()
        var elements: [GoCompositeElement] = []
        while !check(.rightBrace) {
            let elementPosition = current.position
            var key: String?
            var keyExpression: GoExpression?
            if case .map = type {
                keyExpression = try parseExpression()
                try expect(.colon, message: "expected ':' after map key")
            } else if case .identifier(let name) = current.kind, lookahead(1).kind == .colon {
                key = name
                advance()
                advance()
            } else if case .string(let name) = current.kind, lookahead(1).kind == .colon {
                key = name
                advance()
                advance()
            } else if case .integer = current.kind, lookahead(1).kind == .colon {
                // integer keys for maps — store as string representation
                if case .integer(let value) = current.kind {
                    key = String(value)
                }
                advance()
                advance()
            }
            elements.append(
                GoCompositeElement(
                    key: key,
                    keyExpression: keyExpression,
                    value: try parseExpression(),
                    position: elementPosition))
            if check(.comma) {
                advance()
                skipSemicolons()
            } else if check(.semicolon) {
                skipSemicolons()
            } else if !check(.rightBrace) {
                throw diagnostic("expected ',' or '}' in composite literal")
            }
        }
        advance()
        return .compositeLiteral(type: type, elements: elements, position: position)
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
        case .function:
            return try parseFunctionLiteral()
        default:
            throw diagnostic("expected expression")
        }
    }

    /// The type of a parameter, where `...T` is a variadic one: an array type
    /// of the marker length that stands for it.
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

    mutating func parseFunctionLiteral() throws -> GoExpression {
        let position = current.position
        advance()
        try expect(.leftParen, message: "expected '(' after func")
        var parameters: [GoParameter] = []
        while !check(.rightParen) {
            let parameterPosition = current.position
            let name = try expectIdentifier(message: "expected parameter name")
            let type = try parseTypeExpression()
            parameters.append(GoParameter(
                name: name, type: type, position: parameterPosition))
            if check(.comma) { advance() }
            else if !check(.rightParen) {
                throw diagnostic("expected ',' or ')' in parameter list")
            }
        }
        advance()
        return .functionLiteral(
            parameters: parameters,
            resultNames: [],
            resultTypes: [],
            body: try parseBlock(),
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
