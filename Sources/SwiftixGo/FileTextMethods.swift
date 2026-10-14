/// The methods of `*os.File` that are Go text of `os` rather than natives:
/// `Stat`, `ReadDir`, `Readdir`, and `Readdirnames` give values of `io/fs`
/// types, which only the text has. A call `f.Stat()` is a call of the
/// text's `os.fileMethodStat(f)`, through an interface as directly.
///
/// The linker settles what a program uses before the checker knows any
/// type, so it links these functions for a program that imports `os` and
/// selects a member of one of these names anywhere: an image may then hold
/// one it never calls, never lack one it does. A struct that embeds a
/// `*os.File` is not lent these methods: a program that names none of them
/// has not their types.
enum GoFileTextMethods {
    /// The method of `*os.File`, the function of `os` it is, and its
    /// parameters after the receiver and results.
    static let methods: [String: (function: String, parameters: [GoType], results: [GoType])] = {
        let fileInfo = GoType.named("io/fs.FileInfo")
        let dirEntry = GoType.named("io/fs.DirEntry")
        let failure = GoPredeclared.errorType
        return [
            "Stat": ("fileMethodStat", [], [fileInfo, failure]),
            "ReadDir": ("fileMethodReadDir", [.int], [.slice(dirEntry), failure]),
            "Readdir": ("fileMethodReaddir", [.int], [.slice(fileInfo), failure]),
            "Readdirnames": ("fileMethodReaddirnames", [.int], [.slice(.string), failure]),
        ]
    }()

    /// The method as the function the checker calls.
    static func method(_ name: String) -> GoNativeFunction? {
        guard let method = methods[name] else { return nil }
        return GoNativeFunction(
            symbol: "os." + method.function, goName: "os.File." + name,
            parameters: [GoPredeclared.filePointer] + method.parameters, results: method.results)
    }

    /// The functions of `os` to link for `file`, which imports `os`.
    static func functions(neededBy file: GoFile) -> [String] {
        var selected: Set<String> = []
        func note(_ expression: GoExpression) {
            GoSelectorNames.forEach(in: expression) { name in
                if methods[name] != nil { selected.insert(name) }
            }
        }
        for declaration in file.globalDeclarations {
            if let expression = declaration.expression { note(expression) }
        }
        for function in file.functions {
            GoSelectorNames.forEach(in: function.body) { name in
                if methods[name] != nil { selected.insert(name) }
            }
        }
        return selected.sorted().compactMap { methods[$0]?.function }
    }

    /// The functions of `os` to link for a function of the library's text
    /// with `body`, whose file imports `os`.
    static func functions(neededBy body: GoBlock) -> [String] {
        var selected: Set<String> = []
        GoSelectorNames.forEach(in: body) { name in
            if methods[name] != nil { selected.insert(name) }
        }
        return selected.sorted().compactMap { methods[$0]?.function }
    }
}

/// The member names of every selection in a body or an expression.
enum GoSelectorNames {
    static func forEach(in block: GoBlock, _ visit: (String) -> Void) {
        for statement in block.statements { forEach(in: statement, visit) }
    }

    static func forEach(in statement: GoStatement, _ visit: (String) -> Void) {
        switch statement {
        case .declaration(_, _, let expression, _, _):
            if let expression { forEach(in: expression, visit) }
        case .multiDeclaration(_, let expression, _), .expression(let expression),
            .deferStatement(let expression, _), .goStatement(let expression, _):
            forEach(in: expression, visit)
        case .assignment(let target, let expression, _):
            forEach(in: target, visit)
            forEach(in: expression, visit)
        case .multiAssignment(let targets, let expression, _):
            targets.forEach { forEach(in: $0, visit) }
            forEach(in: expression, visit)
        case .increment(let target, _, _):
            forEach(in: target, visit)
        case .returnValues(let values, _):
            values.forEach { forEach(in: $0, visit) }
        case .breakStatement, .continueStatement:
            break
        case .sendStatement(let channel, let value, _):
            forEach(in: channel, visit)
            forEach(in: value, visit)
        case .ifStatement(let condition, let thenBlock, let elseBlock, _):
            forEach(in: condition, visit)
            forEach(in: thenBlock, visit)
            if let elseBlock { forEach(in: elseBlock, visit) }
        case .forStatement(let initializer, let condition, let post, let body, _):
            if let initializer { forEach(in: initializer, visit) }
            if let condition { forEach(in: condition, visit) }
            if let post { forEach(in: post, visit) }
            forEach(in: body, visit)
        case .forRangeStatement(_, _, let collection, let body, _):
            forEach(in: collection, visit)
            forEach(in: body, visit)
        case .switchStatement(let expression, let cases, _):
            if let expression { forEach(in: expression, visit) }
            for switchCase in cases {
                switchCase.expressions.forEach { forEach(in: $0, visit) }
                forEach(in: switchCase.body, visit)
            }
        case .selectStatement(let cases, _):
            for selectCase in cases {
                if let communication = selectCase.communication { forEach(in: communication, visit) }
                forEach(in: selectCase.body, visit)
            }
        }
    }

    static func forEach(in expression: GoExpression, _ visit: (String) -> Void) {
        switch expression {
        case .integer, .string, .identifier, .typeExpression:
            break
        case .functionLiteral(_, _, _, let body, _):
            forEach(in: body, visit)
        case .selector(let base, let name, _):
            visit(name)
            forEach(in: base, visit)
        case .typeAssertion(let base, _, _):
            forEach(in: base, visit)
        case .unary(_, let operand, _):
            forEach(in: operand, visit)
        case .binary(let left, _, let right, _):
            forEach(in: left, visit)
            forEach(in: right, visit)
        case .index(let base, let index, _):
            forEach(in: base, visit)
            forEach(in: index, visit)
        case .slicing(let base, let low, let high, _):
            forEach(in: base, visit)
            if let low { forEach(in: low, visit) }
            if let high { forEach(in: high, visit) }
        case .call(let callee, let arguments, _):
            forEach(in: callee, visit)
            arguments.forEach { forEach(in: $0, visit) }
        case .compositeLiteral(_, let elements, _):
            for element in elements {
                if let key = element.keyExpression { forEach(in: key, visit) }
                forEach(in: element.value, visit)
            }
        }
    }
}
