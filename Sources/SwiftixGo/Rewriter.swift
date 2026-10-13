/// AST-aware source rewriting used by the supported `gofmt -r` and `gofmt -s` modes.

public enum GoSourceRewriter {
    public static func rewrite(_ source: GoSourceFile, rule: String) throws -> GoSourceFile {
        let parts = splitRule(rule)
        let pattern = try parseRuleExpression(parts.pattern, label: "pattern")
        let replacement = try parseRuleExpression(parts.replacement, label: "replacement")
        if case .identifier(let name, _) = pattern, !isWildcard(name),
            case .identifier(let newName, _) = replacement
        {
            return try renaming(name, to: newName, in: source)
        }
        return try applying(pattern: pattern, replacement: replacement, to: source)
    }

    /// A rule that turns one identifier into another renames it wherever
    /// the file has it: Go's rule meets every identifier of the syntax tree,
    /// the name of a declaration, a field, or a type as much as a use.
    private static func renaming(
        _ name: String, to newName: String, in source: GoSourceFile
    ) throws -> GoSourceFile {
        _ = try GoParser.parse(source)
        var bytes = Array(source.text.utf8)
        let offsets = try GoLexer.tokenize(source).compactMap { token -> Int? in
            guard case .identifier(name) = token.kind else { return nil }
            return token.position.offset
        }
        guard !offsets.isEmpty else { return source }
        for offset in offsets.reversed() {
            bytes.replaceSubrange(offset..<(offset + name.utf8.count), with: newName.utf8)
        }
        return GoSourceFile(path: source.path, text: String(decoding: bytes, as: UTF8.self))
    }

    public static func simplify(_ source: GoSourceFile) throws -> GoSourceFile {
        try rewrite(source, rule: "a[b:len(a)] -> a[b:]")
    }

    private static func splitRule(_ rule: String) -> (pattern: String, replacement: String) {
        let characters = Array(rule)
        if characters.count >= 2 {
            for index in 0..<(characters.count - 1)
            where characters[index] == "-" && characters[index + 1] == ">" {
                let pattern = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
                let replacement = String(characters[(index + 2)...]).trimmingCharacters(in: .whitespaces)
                return (pattern, replacement)
            }
        }
        return (rule, "")
    }

    private static func parseRuleExpression(_ text: String, label: String) throws -> GoExpression {
        guard !text.isEmpty else {
            throw GoDiagnostic(position: rulePosition(), message: "rewrite \(label) is empty")
        }
        let file = try GoParser.parse(GoSourceFile(path: "<rewrite>", text: ruleSource(text)))
        guard let function = file.functions.first,
            let statement = function.body.statements.first,
            case .assignment(_, let expression, _) = statement
        else {
            throw GoDiagnostic(position: rulePosition(), message: "invalid rewrite \(label)")
        }
        return expression
    }

    /// A file that holds the expression `text` and nothing else to match.
    private static func ruleSource(_ text: String) -> String {
        "package rewrite\nfunc rewrite() { result = \(text)\n}\n"
    }

    /// The bodies of the function literals in `expression`.
    private static func literalBodies(in expression: GoExpression) -> [GoBlock] {
        if case .functionLiteral(_, _, _, let body, _) = expression { return [body] }
        return children(of: expression).flatMap { literalBodies(in: $0) }
    }

    private static func applying(
        pattern: GoExpression,
        replacement: GoExpression,
        to source: GoSourceFile
    ) throws -> GoSourceFile {
        let file = try GoParser.parse(source)
        let bytes = Array(source.text.utf8)
        var edits: [Edit] = []

        /// The text of `expression` once the rule has been applied inside
        /// it and then to it, or nil when nothing in it matches. Go rewrites
        /// the operands of a node first and then matches the node that
        /// results, so `f(f(1))` under `f(1) -> 1` becomes `1`.
        func rewritten(_ expression: GoExpression) -> String? {
            guard let range = expressionRange(expression, bytes: bytes) else { return nil }
            var operands: [(range: Range<Int>, text: String)] = []
            for child in children(of: expression) {
                guard let childRange = expressionRange(child, bytes: bytes),
                    childRange.lowerBound >= range.lowerBound,
                    childRange.upperBound <= range.upperBound,
                    !operands.contains(where: { $0.range.overlaps(childRange) }),
                    let text = rewritten(child)
                else { continue }
                operands.append((childRange, text))
            }
            var captures: [String: String] = [:]
            guard !operands.isEmpty else {
                return matches(pattern, expression, source: bytes, captures: &captures)
                    ? render(replacement, captures: captures) : nil
            }
            var text = Array(bytes[range])
            for operand in operands.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                let lower = operand.range.lowerBound - range.lowerBound
                let upper = operand.range.upperBound - range.lowerBound
                text.replaceSubrange(lower..<upper, with: operand.text.utf8)
            }
            let current = String(decoding: text, as: UTF8.self)
            // What the node has become is read again to be matched.
            if let node = try? parseRuleExpression(current, label: "operand"),
                matches(
                    pattern, node, source: Array(ruleSource(current).utf8), captures: &captures)
            {
                return render(replacement, captures: captures)
            }
            return current
        }

        func consider(_ expression: GoExpression) {
            let before = edits.count
            if let range = expressionRange(expression, bytes: bytes),
                // A constant that repeats the specification before it has
                // that one's expression, which the source holds once.
                !edits.contains(where: { $0.range == range }),
                let text = rewritten(expression)
            {
                edits.append(Edit(range: range, replacement: text))
            }
            // The statements of a function literal are not operands; they
            // are reached where the expression around them stays as it is.
            if edits.count == before {
                for body in literalBodies(in: expression) { visit(body, consider: consider) }
            }
        }

        for declaration in file.globalDeclarations {
            if let expression = declaration.expression { consider(expression) }
        }
        for function in file.functions {
            visit(function.body, consider: consider)
        }
        guard !edits.isEmpty else { return source }

        var rewritten = bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            rewritten.replaceSubrange(edit.range, with: edit.replacement.utf8)
        }
        return GoSourceFile(path: source.path, text: String(decoding: rewritten, as: UTF8.self))
    }

    private static func visit(_ block: GoBlock, consider: (GoExpression) -> Void) {
        for statement in block.statements {
            switch statement {
            case .declaration(_, _, let expression, _, _):
                if let expression { consider(expression) }
            case .assignment(let target, let expression, _):
                consider(target)
                if let value = compoundAssignmentValue(target: target, expression: expression) {
                    // `x += y` is parsed as `x = x + y`; only `y` has source text.
                    consider(value)
                } else {
                    consider(expression)
                }
            case .multiDeclaration(_, let expression, _):
                values(of: expression).forEach(consider)
            case .multiAssignment(let targets, let expression, _):
                targets.forEach(consider)
                values(of: expression).forEach(consider)
            case .increment(let target, _, _):
                consider(target)
            case .expression(let expression):
                if let declaration = statement.localType {
                    // Of a type declared here the source holds the name;
                    // the call around it is the parser's.
                    consider(.identifier(declaration.name, position: declaration.position))
                } else {
                    consider(expression)
                }
            case .deferStatement(let expression, _), .goStatement(let expression, _):
                consider(expression)
            case .sendStatement(let channel, let value, _):
                consider(channel)
                consider(value)
            case .returnValues(let expressions, _):
                expressions.forEach(consider)
            case .ifStatement(let condition, let thenBlock, let elseBlock, _):
                consider(condition)
                visit(thenBlock, consider: consider)
                if let elseBlock { visit(elseBlock, consider: consider) }
            case .forStatement(let initializer, let condition, let post, let body, _):
                if let initializer { visit(initializer, consider: consider) }
                if let condition { consider(condition) }
                if let post { visit(post, consider: consider) }
                visit(body, consider: consider)
            case .forRangeStatement(_, _, let collection, let body, _):
                consider(collection)
                visit(body, consider: consider)
            case .switchStatement(let expression, let cases, _):
                if let expression { consider(expression) }
                for switchCase in cases {
                    switchCase.expressions.forEach(consider)
                    visit(switchCase.body, consider: consider)
                }
            case .selectStatement(let cases, _):
                for selectCase in cases {
                    if let communication = selectCase.communication {
                        visit(communication, consider: consider)
                    }
                    visit(selectCase.body, consider: consider)
                }
            case .breakStatement, .continueStatement:
                break
            }
        }
    }

    /// The right operand when `expression` is the synthesized operation of a
    /// compound assignment, which shares the target node as its left operand.
    private static func compoundAssignmentValue(
        target: GoExpression,
        expression: GoExpression
    ) -> GoExpression? {
        if case .binary(let left, _, let right, _) = expression,
            left.position == target.position
        {
            return right
        }
        if let operation = expression.bitwiseOperation, operation.operands.count == 2,
            operation.operands[0].position == target.position
        {
            return operation.operands[1]
        }
        return nil
    }

    /// The expressions the source holds on the right of a declaration or an
    /// assignment of several names: a list of values is a node of the parser,
    /// not text a rule could match.
    private static func values(of expression: GoExpression) -> [GoExpression] {
        expression.valueList ?? expression.variables?.values ?? [expression]
    }

    private static func visit(_ statement: GoStatement, consider: (GoExpression) -> Void) {
        visit(
            GoBlock(statements: [statement], position: statementPosition(statement)),
            consider: consider)
    }

    private static func statementPosition(_ statement: GoStatement) -> GoSourcePosition {
        switch statement {
        case .declaration(_, _, _, _, let position), .assignment(_, _, let position),
            .multiDeclaration(_, _, let position), .multiAssignment(_, _, let position),
            .increment(_, _, let position), .returnValues(_, let position),
            .breakStatement(let position), .continueStatement(let position),
            .deferStatement(_, let position), .goStatement(_, let position),
            .sendStatement(_, _, let position),
            .ifStatement(_, _, _, let position), .forStatement(_, _, _, _, let position),
            .forRangeStatement(_, _, _, _, let position),
            .switchStatement(_, _, let position), .selectStatement(_, let position):
            return position
        case .expression(let expression): return expression.position
        }
    }

    private static func children(of expression: GoExpression) -> [GoExpression] {
        if let operation = expression.bitwiseOperation { return operation.operands }
        if let operand = expression.spreadOperand { return [operand] }
        switch expression {
        case .selector(let base, _, _): return [base]
        case .typeAssertion(let base, _, _): return [base]
        case .functionLiteral: return []
        case .compositeLiteral(_, let elements, _):
            return elements.flatMap { element in
                [element.keyExpression, element.value].compactMap { $0 }
            }
        case .index(let base, let index, _): return [base, index]
        case .slicing(let base, let low, let high, _):
            return [base] + [low, high].compactMap { $0 }
        case .call(let callee, let arguments, _): return [callee] + arguments
        case .unary(_, let operand, _): return [operand]
        case .binary(let left, _, let right, _): return [left, right]
        case .integer, .string, .identifier, .typeExpression: return []
        }
    }

    /// Whether an identifier of a rule stands for any expression: as in
    /// Go's `gofmt`, one that is a single lower-case letter. Every other
    /// identifier matches itself.
    private static func isWildcard(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return false }
        return scalar.properties.isLowercase
    }

    private static func matches(
        _ pattern: GoExpression,
        _ target: GoExpression,
        source: [UInt8],
        captures: inout [String: String]
    ) -> Bool {
        // Bitwise operators are call-shaped nodes whose callee names the
        // operator, so the callee must match exactly instead of capturing.
        if let patternOperation = pattern.bitwiseOperation {
            guard let targetOperation = target.bitwiseOperation,
                patternOperation.operator == targetOperation.operator
            else { return false }
            return matchesList(
                patternOperation.operands,
                targetOperation.operands,
                source: source,
                captures: &captures)
        }
        // A spread is call-shaped too, and matches only another spread.
        if let patternOperand = pattern.spreadOperand {
            guard let targetOperand = target.spreadOperand else { return false }
            return matches(patternOperand, targetOperand, source: source, captures: &captures)
        }
        if case .identifier(let name, _) = pattern, isWildcard(name) {
            // An operand in parentheses is matched with them, as Go's
            // syntax tree has it.
            guard let range = operandRange(target, bytes: source) else { return false }
            let text = String(decoding: source[range], as: UTF8.self)
            if let existing = captures[name] { return existing == text }
            captures[name] = text
            return true
        }
        // An operator is never an ordinary call, whatever the pattern's callee.
        if target.bitwiseOperation != nil || target.spreadOperand != nil { return false }
        switch (pattern, target) {
        case (.integer(let lhs, _), .integer(let rhs, let position)):
            // A number of a rule is no `iota` of the source.
            return lhs == rhs && !spellsIota(at: position.offset, in: source)
        case (.string(let lhs, _), .string(let rhs, _)): return lhs == rhs
        case (.identifier(let lhs, _), .identifier(let rhs, _)): return lhs == rhs
        case (.selector(let lhsBase, let lhsName, _), .selector(let rhsBase, let rhsName, _)):
            return lhsName == rhsName
                && matches(lhsBase, rhsBase, source: source, captures: &captures)
        case (.index(let lhsBase, let lhsIndex, _), .index(let rhsBase, let rhsIndex, _)):
            return matches(lhsBase, rhsBase, source: source, captures: &captures)
                && matches(lhsIndex, rhsIndex, source: source, captures: &captures)
        case (
            .slicing(let lhsBase, let lhsLow, let lhsHigh, _),
            .slicing(let rhsBase, let rhsLow, let rhsHigh, _)
        ):
            return matches(lhsBase, rhsBase, source: source, captures: &captures)
                && matchesOptional(lhsLow, rhsLow, source: source, captures: &captures)
                && matchesOptional(lhsHigh, rhsHigh, source: source, captures: &captures)
        case (.call(let lhsCallee, let lhsArgs, _), .call(let rhsCallee, let rhsArgs, _)):
            return matches(lhsCallee, rhsCallee, source: source, captures: &captures)
                && matchesList(lhsArgs, rhsArgs, source: source, captures: &captures)
        case (.unary(let lhsOperator, let lhsOperand, _), .unary(let rhsOperator, let rhsOperand, _)):
            return lhsOperator == rhsOperator
                && matches(lhsOperand, rhsOperand, source: source, captures: &captures)
        case (
            .binary(let lhsLeft, let lhsOperator, let lhsRight, _),
            .binary(let rhsLeft, let rhsOperator, let rhsRight, _)
        ):
            return lhsOperator == rhsOperator
                && matches(lhsLeft, rhsLeft, source: source, captures: &captures)
                && matches(lhsRight, rhsRight, source: source, captures: &captures)
        case (
            .compositeLiteral(let lhsType, let lhsElements, _),
            .compositeLiteral(let rhsType, let rhsElements, _)
        ):
            return typeText(lhsType) == typeText(rhsType)
                && lhsElements.map(\.key) == rhsElements.map(\.key)
                && matchesList(
                    lhsElements.compactMap(\.keyExpression),
                    rhsElements.compactMap(\.keyExpression),
                    source: source,
                    captures: &captures)
                && matchesList(
                    lhsElements.map(\.value),
                    rhsElements.map(\.value),
                    source: source,
                    captures: &captures)
        case (.typeExpression(let lhs, _), .typeExpression(let rhs, _)):
            return typeText(lhs) == typeText(rhs)
        default:
            return false
        }
    }

    private static func matchesOptional(
        _ pattern: GoExpression?,
        _ target: GoExpression?,
        source: [UInt8],
        captures: inout [String: String]
    ) -> Bool {
        switch (pattern, target) {
        case (nil, nil): return true
        case (.some(let pattern), .some(let target)):
            return matches(pattern, target, source: source, captures: &captures)
        default: return false
        }
    }

    private static func matchesList(
        _ patterns: [GoExpression],
        _ targets: [GoExpression],
        source: [UInt8],
        captures: inout [String: String]
    ) -> Bool {
        guard patterns.count == targets.count else { return false }
        for (pattern, target) in zip(patterns, targets) {
            guard matches(pattern, target, source: source, captures: &captures) else { return false }
        }
        return true
    }

    /// The source of `expression` with the parentheses that group it.
    private static func operandRange(
        _ expression: GoExpression,
        bytes: [UInt8]
    ) -> Range<Int>? {
        expressionRange(expression, bytes: bytes).map { grouped($0, bytes: bytes) }
    }

    /// `range` widened over the parentheses around it that group an
    /// expression. Those of a call or a conversion follow a name or a
    /// closing bracket and are left alone.
    private static func grouped(_ range: Range<Int>, bytes: [UInt8]) -> Range<Int> {
        func isBlank(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        var range = range
        while true {
            var open = range.lowerBound - 1
            while open >= 0, isBlank(bytes[open]) { open -= 1 }
            var close = range.upperBound
            while close < bytes.count, isBlank(bytes[close]) { close += 1 }
            guard open >= 0, close < bytes.count, bytes[open] == 0x28, bytes[close] == 0x29 else {
                return range
            }
            var before = open - 1
            while before >= 0, isBlank(bytes[before]) { before -= 1 }
            if before >= 0 {
                let byte = bytes[before]
                let endsOperand =
                    byte == 0x29 || byte == 0x5D || byte == 0x7D || byte == 0x5F || byte >= 0x80
                    || (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                    || (byte >= 0x61 && byte <= 0x7A)
                if endsOperand { return range }
            }
            range = open..<(close + 1)
        }
    }

    /// The source of `expression`, without parentheses around the whole of
    /// it and with those around its first and last operand.
    private static func expressionRange(
        _ expression: GoExpression,
        bytes: [UInt8]
    ) -> Range<Int>? {
        let start: Int
        let end: Int
        if let operation = expression.bitwiseOperation {
            // The node's position is the operator; its text spans the operands.
            guard let first = operation.operands.first,
                let last = operation.operands.last,
                let lastRange = operandRange(last, bytes: bytes)
            else { return nil }
            if operation.operator.isUnary {
                return expression.position.offset..<lastRange.upperBound
            }
            guard let firstRange = operandRange(first, bytes: bytes) else { return nil }
            return firstRange.lowerBound..<lastRange.upperBound
        }
        if let operand = expression.spreadOperand {
            // The node's position is the `...` after its operand.
            guard let range = operandRange(operand, bytes: bytes) else { return nil }
            return range.lowerBound..<(expression.position.offset + GoSpread.spelling.utf8.count)
        }
        switch expression {
        case .integer(let value, let position):
            start = position.offset
            // The parser writes `iota` as the integer it stands for.
            end = start + (spellsIota(at: start, in: bytes) ? GoIota.name.utf8.count : String(value).utf8.count)
        case .string(_, let position):
            start = position.offset
            end = stringEnd(start, bytes: bytes)
        case .identifier(let name, let position):
            start = position.offset
            end = start + name.utf8.count
        case .selector(let base, let name, let position):
            start = operandRange(base, bytes: bytes)?.lowerBound ?? position.offset
            end = position.offset + 1 + name.utf8.count
        case .typeAssertion(let base, _, let position):
            start = operandRange(base, bytes: bytes)?.lowerBound ?? position.offset
            guard let open = nextByte(0x28, from: position.offset, bytes: bytes),
                let close = matchingDelimiter(open, open: 0x28, close: 0x29, bytes: bytes)
            else { return nil }
            end = close + 1
        case .functionLiteral(_, _, _, _, let position):
            start = position.offset
            guard let open = nextByte(0x7B, from: start, bytes: bytes),
                let close = matchingDelimiter(open, open: 0x7B, close: 0x7D, bytes: bytes)
            else { return nil }
            end = close + 1
        case .compositeLiteral(_, _, let position):
            start = position.offset
            guard let open = nextByte(0x7B, from: start, bytes: bytes),
                let close = matchingDelimiter(open, open: 0x7B, close: 0x7D, bytes: bytes)
            else { return nil }
            end = close + 1
        case .index(let base, _, let position), .slicing(let base, _, _, let position):
            start = operandRange(base, bytes: bytes)?.lowerBound ?? position.offset
            guard
                let close = matchingDelimiter(
                    position.offset,
                    open: 0x5B,
                    close: 0x5D,
                    bytes: bytes)
            else { return nil }
            end = close + 1
        case .call(let callee, _, let position):
            start = operandRange(callee, bytes: bytes)?.lowerBound ?? position.offset
            guard
                let close = matchingDelimiter(
                    position.offset,
                    open: 0x28,
                    close: 0x29,
                    bytes: bytes)
            else { return nil }
            end = close + 1
        case .unary(_, let operand, let position):
            start = position.offset
            guard let range = operandRange(operand, bytes: bytes) else { return nil }
            end = range.upperBound
        case .binary(let left, _, let right, _):
            guard let leftRange = operandRange(left, bytes: bytes),
                let rightRange = operandRange(right, bytes: bytes)
            else { return nil }
            start = leftRange.lowerBound
            end = rightRange.upperBound
        case .typeExpression(let type, _):
            start = type.position.offset
            end = typeEnd(type, bytes: bytes)
        }
        guard start >= 0, start <= end, end <= bytes.count else { return nil }
        return start..<end
    }

    /// Whether the source has `iota` at `offset`, where the tree has the
    /// integer it stands for.
    private static func spellsIota(at offset: Int, in bytes: [UInt8]) -> Bool {
        let name = Array(GoIota.name.utf8)
        return offset >= 0 && offset + name.count <= bytes.count
            && bytes[offset..<(offset + name.count)].elementsEqual(name)
    }

    private static func matchingDelimiter(
        _ start: Int,
        open: UInt8,
        close: UInt8,
        bytes: [UInt8]
    ) -> Int? {
        guard bytes.indices.contains(start), bytes[start] == open else { return nil }
        var depth = 0
        var index = start
        while index < bytes.count {
            if bytes[index] == 0x22 {
                index = stringEnd(index, bytes: bytes)
                continue
            }
            if bytes[index] == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                continue
            }
            if bytes[index] == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                index += 2
                while index + 1 < bytes.count,
                    !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F)
                { index += 1 }
                index = min(bytes.count, index + 2)
                continue
            }
            if bytes[index] == open { depth += 1 }
            if bytes[index] == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func stringEnd(_ start: Int, bytes: [UInt8]) -> Int {
        var index = min(start + 1, bytes.count)
        while index < bytes.count {
            if bytes[index] == 0x5C {
                index = min(bytes.count, index + 2)
            } else if bytes[index] == 0x22 {
                return index + 1
            } else {
                index += 1
            }
        }
        return bytes.count
    }

    private static func nextByte(_ byte: UInt8, from start: Int, bytes: [UInt8]) -> Int? {
        guard start < bytes.count else { return nil }
        return (start..<bytes.count).first { bytes[$0] == byte }
    }

    private static func typeEnd(_ type: GoTypeExpression, bytes: [UInt8]) -> Int {
        switch type {
        case .named(let name, let position): return position.offset + name.utf8.count
        case .pointer(let pointee, _): return typeEnd(pointee, bytes: bytes)
        case .array(_, let element, _), .slice(let element, _): return typeEnd(element, bytes: bytes)
        case .map(_, let value, _), .channel(_, let value, _):
            return typeEnd(value, bytes: bytes)
        case .interface(_, let position):
            guard let open = nextByte(0x7B, from: position.offset, bytes: bytes),
                let close = matchingDelimiter(open, open: 0x7B, close: 0x7D, bytes: bytes)
            else { return position.offset }
            return close + 1
        case .structure(_, let position):
            guard let open = nextByte(0x7B, from: position.offset, bytes: bytes),
                let close = matchingDelimiter(open, open: 0x7B, close: 0x7D, bytes: bytes)
            else { return position.offset }
            return close + 1
        }
    }

    private static func render(_ expression: GoExpression, captures: [String: String]) -> String {
        if let operation = expression.bitwiseOperation {
            // Print the operator syntax back, parenthesizing operands that
            // would otherwise regroup under Go's precedence.
            func operand(_ index: Int, minimumPrecedence: Int) -> String {
                let text = render(operation.operands[index], captures: captures)
                return precedence(of: operation.operands[index]) < minimumPrecedence
                    ? "(" + text + ")" : text
            }
            let level = operation.operator.precedence
            if operation.operator.isUnary {
                return operation.operator.spelling + operand(0, minimumPrecedence: level)
            }
            return operand(0, minimumPrecedence: level) + " " + operation.operator.spelling
                + " " + operand(1, minimumPrecedence: level + 1)
        }
        if let operand = expression.spreadOperand {
            return render(operand, captures: captures) + GoSpread.spelling
        }
        switch expression {
        case .integer(let value, _): return String(value)
        case .string(let value, _): return quote(value)
        case .identifier(let name, _): return captures[name] ?? name
        case .selector(let base, let name, _): return render(base, captures: captures) + "." + name
        case .typeAssertion(let base, let type, _):
            return render(base, captures: captures) + ".(" + typeText(type) + ")"
        case .functionLiteral(let parameters, _, _, _, _):
            return "func(" + parameters.map {
                $0.name + " " + typeText($0.type)
            }.joined(separator: ", ") + ") {}"
        case .compositeLiteral(let type, let elements, _):
            return typeText(type) + "{"
                + elements.map { element in
                    let key = element.keyExpression.map {
                        render($0, captures: captures) + ": "
                    } ?? element.key.map { $0 + ": " } ?? ""
                    return key + render(element.value, captures: captures)
                }.joined(separator: ", ") + "}"
        case .index(let base, let index, _):
            return render(base, captures: captures) + "[" + render(index, captures: captures) + "]"
        case .slicing(let base, let low, let high, _):
            return render(base, captures: captures) + "["
                + (low.map { render($0, captures: captures) } ?? "") + ":"
                + (high.map { render($0, captures: captures) } ?? "") + "]"
        case .call(let callee, let arguments, _):
            return render(callee, captures: captures) + "("
                + arguments.map { render($0, captures: captures) }.joined(separator: ", ") + ")"
        case .unary(let operation, let operand, _):
            return unaryText(operation) + render(operand, captures: captures)
        case .binary(let left, let operation, let right, _):
            return render(left, captures: captures) + " " + binaryText(operation) + " "
                + render(right, captures: captures)
        case .typeExpression(let type, _): return typeText(type)
        }
    }

    /// Binding strength of an expression's outermost operator on the parser's
    /// scale; operands and postfix forms bind tightest.
    private static func precedence(of expression: GoExpression) -> Int {
        if let operation = expression.bitwiseOperation { return operation.operator.precedence }
        switch expression {
        case .binary(_, let operation, _, _):
            switch operation {
            case .logicalOr: return 1
            case .logicalAnd: return 2
            case .equal, .notEqual: return 3
            case .less, .lessEqual, .greater, .greaterEqual: return 4
            case .add, .subtract: return 5
            case .multiply, .divide, .remainder: return 6
            }
        case .unary: return 7
        default: return 8
        }
    }

    private static func typeText(_ type: GoTypeExpression) -> String {
        switch type {
        case .named(let name, _): return name
        case .pointer(let pointee, _): return "*" + typeText(pointee)
        case .array(let length, let element, _): return "[\(length)]" + typeText(element)
        case .slice(let element, _): return "[]" + typeText(element)
        case .map(let key, let value, _): return "map[" + typeText(key) + "]" + typeText(value)
        case .channel(let direction, let element, _):
            switch direction {
            case .bidirectional: return "chan " + typeText(element)
            case .sendOnly: return "chan<- " + typeText(element)
            case .receiveOnly: return "<-chan " + typeText(element)
            }
        case .interface(let methods, _):
            if methods.isEmpty { return "interface{}" }
            return "interface{ "
                + methods.map { m in
                    m.name + "("
                        + m.parameters.map(typeText).joined(separator: ", ") + ")"
                        + (m.results.isEmpty ? "" : " " + m.results.map(typeText).joined(separator: ", "))
                }.joined(separator: "; ") + " }"
        case .structure(let fields, _):
            return "struct { "
                + fields.map { $0.name + " " + typeText($0.type) }
                .joined(separator: "; ") + " }"
        }
    }

    private static func unaryText(_ operation: GoUnaryOperator) -> String {
        switch operation {
        case .plus: return "+"
        case .minus: return "-"
        case .not: return "!"
        case .address: return "&"
        case .dereference: return "*"
        case .receive: return "<-"
        }
    }

    private static func binaryText(_ operation: GoBinaryOperator) -> String {
        switch operation {
        case .add: return "+"
        case .subtract: return "-"
        case .multiply: return "*"
        case .divide: return "/"
        case .remainder: return "%"
        case .equal: return "=="
        case .notEqual: return "!="
        case .less: return "<"
        case .lessEqual: return "<="
        case .greater: return ">"
        case .greaterEqual: return ">="
        case .logicalAnd: return "&&"
        case .logicalOr: return "||"
        }
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        // Scalars rather than Characters, so "\r\n" is not one grapheme.
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    let hex = String(scalar.value, radix: 16)
                    result += "\\x" + (hex.count == 1 ? "0" + hex : hex)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    private static func rulePosition() -> GoSourcePosition {
        GoSourcePosition(path: "<rewrite>", offset: 0, line: 1, column: 1)
    }
}

private struct Edit {
    let range: Range<Int>
    let replacement: String
}

private extension String {
    func trimmingCharacters(in set: Set<Character>) -> String {
        var characters = Array(self)
        while characters.first.map(set.contains) == true { characters.removeFirst() }
        while characters.last.map(set.contains) == true { characters.removeLast() }
        return String(characters)
    }
}

private extension Set where Element == Character {
    static let whitespaces: Set<Character> = [" ", "\t", "\n", "\r"]
}
