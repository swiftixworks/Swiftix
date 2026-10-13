/// Labels and the statements that jump: `L:`, `break L`, `continue L`,
/// `goto L`, and `fallthrough`.
///
/// `GoStatement` is frozen. It has no case for a label, a `goto`, or a
/// `fallthrough`, and its `break` and `continue` have no room for a label.
/// Each is carried as a call no program can write, without arguments, whose
/// callee says what it is and names the label: `$label.L`, `$break.L`,
/// `$continue.L`, `$goto.L`, and `$fallthrough`. The callee is where the
/// label is written, which is where Go reports it, and the call is where the
/// statement begins.
///
/// A label is a statement of its own, before the one it names: `L: for { }`
/// is `$label.L` and then the loop, in one statement list. A pass that only
/// walks the tree reads an expression statement with nothing in it. The
/// passes that give a jump its meaning ask `branch` first, and take the
/// statement after a label for the labeled one; a label that ends its list
/// names the empty statement, as in Go.
///
/// A label is in a scope of its own, the function's, and no pass that
/// resolves names sees one: it is no identifier of the tree.
enum GoBranch: Equatable, Sendable {
    case label(String)
    case breakTo(String)
    case continueTo(String)
    case goto(String)
    case `fallthrough`

    static let labelPrefix = "$label."
    static let breakPrefix = "$break."
    static let continuePrefix = "$continue."
    static let gotoPrefix = "$goto."
    static let fallthroughName = "$fallthrough"

    /// The keywords the lexer has no token for: each is an identifier that
    /// no program can declare.
    static let gotoKeyword = "goto"
    static let fallthroughKeyword = "fallthrough"

    /// The name of the callee that carries the statement.
    var calleeName: String {
        switch self {
        case .label(let name): return Self.labelPrefix + name
        case .breakTo(let name): return Self.breakPrefix + name
        case .continueTo(let name): return Self.continuePrefix + name
        case .goto(let name): return Self.gotoPrefix + name
        case .fallthrough: return Self.fallthroughName
        }
    }

    init?(calleeName: String) {
        guard calleeName.first == "$" else { return nil }
        func label(after prefix: String) -> String? {
            calleeName.hasPrefix(prefix) ? String(calleeName.dropFirst(prefix.count)) : nil
        }
        if calleeName == Self.fallthroughName {
            self = .fallthrough
        } else if let name = label(after: Self.labelPrefix) {
            self = .label(name)
        } else if let name = label(after: Self.breakPrefix) {
            self = .breakTo(name)
        } else if let name = label(after: Self.continuePrefix) {
            self = .continueTo(name)
        } else if let name = label(after: Self.gotoPrefix) {
            self = .goto(name)
        } else {
            return nil
        }
    }
}

extension GoExpression {
    /// What the statement of this expression is, when it is a label or a
    /// jump. See `GoStatement.branch`.
    var branch: (kind: GoBranch, position: GoSourcePosition)? {
        guard case .call(.identifier(let name, let position), let arguments, _) = self,
            arguments.isEmpty, let kind = GoBranch(calleeName: name)
        else { return nil }
        return (kind, position)
    }
}

extension GoStatement {
    /// The statement for `branch`. `position` is where it begins and
    /// `labelPosition` where its label is written; a `fallthrough` has none.
    static func branch(
        _ branch: GoBranch, position: GoSourcePosition, labelPosition: GoSourcePosition? = nil
    ) -> GoStatement {
        .expression(
            .call(
                callee: .identifier(branch.calleeName, position: labelPosition ?? position),
                arguments: [], position: position))
    }

    /// What this statement is when it is a label or a jump the tree has no
    /// case for, with the place Go reports it by: its label's, or its own
    /// when it has none.
    var branch: (kind: GoBranch, position: GoSourcePosition)? {
        guard case .expression(let expression) = self else { return nil }
        return expression.branch
    }

    /// The label this statement is, when it is one.
    var label: String? {
        if case .label(let name)? = branch?.kind { return name }
        return nil
    }

    /// Whether this declares constants.
    var declaresConstants: Bool {
        switch self {
        case .declaration(_, _, _, let isConstant, _): return isConstant
        case .multiDeclaration(_, let expression, _): return expression.variables?.isConstant ?? false
        default: return false
        }
    }

    /// Whether this is a label.
    var isLabel: Bool {
        if case .label? = branch?.kind { return true }
        return false
    }

    /// Whether this is a `for` that loops: not the block, and not the
    /// statement with an initializer, that are carried as one.
    var isLoop: Bool {
        switch self {
        case .forStatement: return block == nil && initialized == nil
        case .forRangeStatement: return true
        default: return false
        }
    }
}

/// What Go's compiler checks of the labels and jumps of one function body,
/// as it checks it (`checkBranches` of `cmd/compile/internal/syntax`): a
/// `break`, `continue`, or `fallthrough` out of place, a label that is
/// unknown, defined twice, or not used, and a `goto` into a block or over
/// the declaration of a variable.
///
/// It reads the tree the parser made, before any pass rewrote it, and a
/// function literal is a body of its own. Go reports these with the errors
/// of the type checker, in the order of the source, so what is found here
/// is kept with the file for the checker to report in its turn.
struct GoBranchChecker {
    /// The tokens of the file. The tree does not say where the `:=` of a
    /// short declaration is, where Go reports a `goto` over one, nor
    /// whether a `var` is one of a group.
    let tokens: [GoToken]
    /// Where the names of a `var` are, by the offset of the declaration.
    let namePositions: [Int: [GoSourcePosition]]

    private(set) var errors: [GoDiagnostic] = []
    private var blocks: [Block] = []
    private var labels: [String: Label] = [:]

    /// A block: the one around it, where it starts, and the labeled
    /// statement it is the body of, if any.
    private struct Block {
        let parent: Int?
        let start: GoSourcePosition
        let labeled: Int?
    }

    /// What a label names.
    private enum Target {
        case loop
        case switchStatement
        case selectStatement
        case other
    }

    private struct Label {
        let block: Int
        /// The offset of the label, which tells one labeled statement from
        /// another.
        let identity: Int
        let position: GoSourcePosition
        let target: Target
        var isUsed = false
    }

    /// A `goto` whose label is not defined before it in a block around it.
    private struct Jump {
        let name: String
        let position: GoSourcePosition
    }

    /// The statement a `break` leaves and whether a `continue` has a loop:
    /// what encloses a statement.
    private struct Context {
        enum Breakable {
            case loop
            case expressionSwitch(clauses: Int)
            case typeSwitch
            case select
        }
        var breaks: Breakable?
        var continues = false
        /// The index of the clause of the switch directly around, or -1.
        var clause = -1
    }

    init(tokens: [GoToken], namePositions: [Int: [GoSourcePosition]]) {
        self.tokens = tokens
        self.namePositions = namePositions
    }

    /// What is wrong with the labels and jumps of each function and
    /// function literal of `file`, by the offset of its `func`.
    static func errors(in file: GoFile, tokens: [GoToken]) -> [Int: [GoDiagnostic]] {
        var checker = GoBranchChecker(tokens: tokens, namePositions: file.namePositions)
        var found: [Int: [GoDiagnostic]] = [:]
        func check(_ body: GoBlock, at position: GoSourcePosition) {
            let errors = checker.check(body)
            if !errors.isEmpty { found[position.offset] = errors }
        }
        func checkLiteral(_ literal: GoExpression) {
            if case .functionLiteral(_, _, _, let body, let position) = literal {
                check(body, at: position)
            }
        }
        for declaration in file.globalDeclarations {
            if let expression = declaration.expression {
                GoFunctionLiterals.forEach(in: expression, checkLiteral)
            }
        }
        for function in file.functions {
            check(function.body, at: function.position)
            GoFunctionLiterals.forEach(in: function.body, checkLiteral)
        }
        return found
    }

    /// The index of the token at `offset`.
    private func token(at offset: Int) -> Int? {
        var low = 0
        var high = tokens.count
        while low < high {
            let middle = (low + high) / 2
            if tokens[middle].position.offset < offset { low = middle + 1 } else { high = middle }
        }
        return low < tokens.count && tokens[low].position.offset == offset ? low : nil
    }

    /// Where the `:=` is of the short declaration that begins at `offset`,
    /// after its names; nil for a `var`.
    private func shortDeclaration(at offset: Int) -> GoSourcePosition? {
        guard var index = token(at: offset) else { return nil }
        while index < tokens.count {
            switch tokens[index].kind {
            case .identifier, .comma: index += 1
            case .declare: return tokens[index].position
            default: return nil
            }
        }
        return nil
    }

    /// Whether the `var` whose declaration is at `offset` is a
    /// specification of a group after its first: the group is one
    /// declaration to Go.
    private func continuesGroup(at offset: Int) -> Bool {
        guard var index = token(at: offset), case .identifier = tokens[index].kind else {
            return false
        }
        index -= 1
        while index >= 0, tokens[index].kind == .semicolon { index -= 1 }
        return index >= 0 && tokens[index].kind != .leftParen
    }

    /// The errors of `body`, in the order of the source.
    mutating func check(_ body: GoBlock) -> [GoDiagnostic] {
        errors = []
        blocks = []
        labels = [:]
        let unresolved = branches(
            in: body.statements, parent: nil, context: Context(), labeled: nil,
            start: body.position)
        // A `goto` nothing resolved: its label is inside a block the `goto`
        // is outside of, or there is none.
        for jump in unresolved {
            if let label = labels[jump.name] {
                labels[jump.name]?.isUsed = true
                report(
                    jump.position,
                    "goto \(jump.name) jumps into block starting at "
                        + Self.place(blocks[label.block].start))
            } else {
                report(jump.position, "label \(jump.name) not defined")
            }
        }
        for (name, label) in labels where !label.isUsed {
            report(label.position, "label \(name) defined and not used")
        }
        return errors.sorted { $0.position.offset < $1.position.offset }
    }

    /// A position as Go writes one inside a message.
    static func place(_ position: GoSourcePosition) -> String {
        "\(position.path):\(position.line):\(position.column)"
    }

    private mutating func report(_ position: GoSourcePosition, _ message: String) {
        errors.append(GoDiagnostic(position: position, message: message))
    }

    /// The labeled statement around `block` that `name` names: nil when no
    /// label has the name, and `.other` when the label names no statement
    /// around the block.
    private mutating func enclosingTarget(of block: Int, named name: String) -> Target? {
        guard let label = labels[name] else { return nil }
        labels[name]?.isUsed = true
        var current: Int? = block
        while let index = current {
            if blocks[index].labeled == label.identity { return label.target }
            current = blocks[index].parent
        }
        return .other
    }

    /// Whether `name` is a label of `block` or of a block around it, which
    /// a `goto` may jump to.
    private mutating func isGotoTarget(_ name: String, from block: Int) -> Bool {
        guard let label = labels[name] else { return false }
        labels[name]?.isUsed = true
        var current: Int? = block
        while let index = current {
            if label.block == index { return true }
            current = blocks[index].parent
        }
        return false
    }

    private func target(of statement: GoStatement?) -> Target {
        guard let statement else { return .other }
        let labeled = statement.initialized?.statement ?? statement
        if labeled.isLoop { return .loop }
        switch labeled {
        case .switchStatement: return .switchStatement
        case .selectStatement: return .selectStatement
        default: return .other
        }
    }

    /// Checks the statements of one block, and returns the `goto`s in it
    /// whose labels it does not define.
    private mutating func branches(
        in statements: [GoStatement], parent: Int?, context: Context, labeled: Int?,
        start: GoSourcePosition
    ) -> [Jump] {
        blocks.append(Block(parent: parent, start: start, labeled: labeled))
        let block = blocks.count - 1
        // The last variable declared in the block, and the `goto`s before
        // it that are still looking for their label.
        var variable: (position: GoSourcePosition, names: String)?
        var forward: [Jump] = []
        var overVariable: Set<Int> = []
        // The label before the statement being looked at.
        var upcoming: Int?

        func declare(_ names: String, at position: GoSourcePosition) {
            variable = (position, names)
            overVariable = Set(forward.map(\.position.offset))
        }

        for (index, statement) in statements.enumerated() {
            let labeled = upcoming
            upcoming = nil
            var inner = context
            inner.clause = -1

            if let branch = statement.branch {
                switch branch.kind {
                case .label(let name):
                    guard name != GoValueList.blank else { continue }
                    if let earlier = labels[name] {
                        report(
                            branch.position,
                            "label \(name) already defined at " + Self.place(earlier.position))
                    } else {
                        labels[name] = Label(
                            block: block, identity: branch.position.offset,
                            position: branch.position,
                            target: target(
                                of: index + 1 < statements.count ? statements[index + 1] : nil))
                    }
                    forward.removeAll { jump in
                        guard jump.name == name else { return false }
                        labels[name]?.isUsed = true
                        if let variable, overVariable.contains(jump.position.offset) {
                            report(
                                jump.position,
                                "goto \(name) jumps over declaration of \(variable.names) at "
                                    + Self.place(variable.position))
                        }
                        return true
                    }
                    upcoming = branch.position.offset
                case .fallthrough:
                    var message = "fallthrough statement out of place"
                    switch context.breaks {
                    case .typeSwitch:
                        message = "cannot fallthrough in type switch"
                    case .expressionSwitch(let clauses):
                        if context.clause < 0 || index + 1 < statements.count {
                            // Inside a block of the clause, or not its last
                            // statement.
                        } else if context.clause + 1 == clauses {
                            message = "cannot fallthrough final case in switch"
                        } else {
                            continue
                        }
                    default:
                        break
                    }
                    report(branch.position, message)
                case .breakTo(let name):
                    switch enclosingTarget(of: block, named: name) {
                    case .loop, .switchStatement, .selectStatement: break
                    case .other: report(branch.position, "invalid break label \(name)")
                    case nil: report(branch.position, "break label not defined: \(name)")
                    }
                case .continueTo(let name):
                    switch enclosingTarget(of: block, named: name) {
                    case .loop: break
                    case .switchStatement, .selectStatement, .other:
                        report(branch.position, "invalid continue label \(name)")
                    case nil: report(branch.position, "continue label not defined: \(name)")
                    }
                case .goto(let name):
                    if !isGotoTarget(name, from: block) {
                        forward.append(Jump(name: name, position: branch.position))
                    }
                }
                continue
            }

            func enter(_ body: GoBlock, _ context: Context) {
                forward += branches(
                    in: body.statements, parent: block, context: context, labeled: labeled,
                    start: body.position)
            }

            if let body = statement.block {
                enter(body, inner)
                continue
            }
            // The initializer of an `if` or a `switch` declares nothing a
            // `goto` could jump over: its scope is the statement.
            switch statement.initialized?.statement ?? statement {
            case .declaration(let name, _, _, let isConstant, let position):
                if let define = shortDeclaration(at: position.offset) {
                    declare(name, at: define)
                } else if !isConstant, !continuesGroup(at: position.offset) {
                    declare(name, at: namePositions[position.offset]?.first ?? position)
                }
            case .multiDeclaration(let names, let expression, let position):
                if let variables = expression.variables {
                    if !variables.isConstant, !continuesGroup(at: position.offset) {
                        declare(names[0], at: namePositions[position.offset]?.first ?? position)
                    }
                } else {
                    declare(
                        names.joined(separator: ", "),
                        at: shortDeclaration(at: position.offset) ?? position)
                }
            case .breakStatement(let position):
                if context.breaks == nil {
                    report(position, "break is not in a loop, switch, or select")
                }
            case .continueStatement(let position):
                if !context.continues { report(position, "continue is not in a loop") }
            case .ifStatement(_, let thenBlock, let elseBlock, _):
                enter(thenBlock, inner)
                if let elseBlock { enter(elseBlock, inner) }
            case .forStatement(_, _, _, let body, _), .forRangeStatement(_, _, _, let body, _):
                inner.breaks = .loop
                inner.continues = true
                enter(body, inner)
            case .switchStatement(let expression, let cases, _):
                inner.breaks =
                    expression?.isTypeSwitchGuard == true
                    ? .typeSwitch : .expressionSwitch(clauses: cases.count)
                for (clause, switchCase) in cases.enumerated() {
                    inner.clause = clause
                    enter(GoBlock(statements: switchCase.body.statements, position: switchCase.position), inner)
                }
            case .selectStatement(let cases, _):
                inner.breaks = .select
                for selectCase in cases {
                    enter(GoBlock(statements: selectCase.body.statements, position: selectCase.position), inner)
                }
            default:
                break
            }
        }
        return forward
    }
}

/// Whether a statement ends the function it is in, by Go's rules for a
/// terminating statement: a `return`, a `goto`, a call of the builtin
/// `panic`, a block whose last statement is one, an `if` whose two branches
/// are, a `for` without a condition that no `break` leaves, a `switch` with a
/// `default` whose clauses all end in one or in a `fallthrough`, and a
/// `select` whose clauses all do. A `break` counts against the statement it
/// leaves: the innermost one, or the one its label names.
///
/// Read off the tree, like the checks above. A label is the statement
/// before the one it names.
struct GoTermination {
    /// Whether `panic` is the builtin, which no function of the program
    /// replaces.
    let panicIsBuiltin: Bool

    func terminates(_ block: GoBlock) -> Bool {
        terminates(block.statements)
    }

    private func terminates(_ statements: [GoStatement]) -> Bool {
        guard let last = statements.last else { return false }
        // The last statement, with the label that names it.
        let label = statements.count > 1 ? statements[statements.count - 2].label : nil
        return terminates(last, label: label)
    }

    private func terminates(_ statement: GoStatement, label: String?) -> Bool {
        if let scoped = statement.initialized { return terminates(scoped.statement, label: label) }
        if let block = statement.block { return terminates(block.statements) }
        if let branch = statement.branch {
            switch branch.kind {
            case .goto, .fallthrough: return true
            case .label, .breakTo, .continueTo: return false
            }
        }
        switch statement {
        case .returnValues:
            return true
        case .expression(.call(callee: .identifier("panic", _), arguments: _, position: _)):
            return panicIsBuiltin
        case .ifStatement(_, let thenBlock, let elseBlock, _):
            guard let elseBlock else { return false }
            return terminates(thenBlock.statements) && terminates(elseBlock.statements)
        case .forStatement(_, let condition, _, let body, _):
            return condition == nil && !leaves(body.statements, label: label, implicit: true)
        case .switchStatement(_, let cases, _):
            guard cases.contains(where: \.isDefault) else { return false }
            return cases.allSatisfy {
                terminates($0.body.statements)
                    && !leaves($0.body.statements, label: label, implicit: true)
            }
        case .selectStatement(let cases, _):
            return cases.allSatisfy {
                terminates($0.body.statements)
                    && !leaves($0.body.statements, label: label, implicit: true)
            }
        default:
            return false
        }
    }

    /// Whether a `break` among `statements` leaves the statement they are
    /// the body of: one that names `label`, or, where `implicit` holds, one
    /// without a label that no loop, `switch`, or `select` between takes.
    private func leaves(_ statements: [GoStatement], label: String?, implicit: Bool) -> Bool {
        statements.contains { statement in
            if let block = statement.block {
                return leaves(block.statements, label: label, implicit: implicit)
            }
            if case .breakTo(let name)? = statement.branch?.kind { return name == label }
            switch statement.initialized?.statement ?? statement {
            case .breakStatement:
                return implicit
            case .ifStatement(_, let thenBlock, let elseBlock, _):
                return leaves(thenBlock.statements, label: label, implicit: implicit)
                    || leaves(elseBlock?.statements ?? [], label: label, implicit: implicit)
            case .forStatement(_, _, _, let body, _), .forRangeStatement(_, _, _, let body, _):
                return label != nil && leaves(body.statements, label: label, implicit: false)
            case .switchStatement(_, let cases, _):
                return label != nil
                    && cases.contains { leaves($0.body.statements, label: label, implicit: false) }
            case .selectStatement(let cases, _):
                return label != nil
                    && cases.contains { leaves($0.body.statements, label: label, implicit: false) }
            default:
                return false
            }
        }
    }
}

extension GoBlock {
    /// Whether this function body has a `goto`, and whether one jumps back
    /// to a label before it: the statements between then run again, as
    /// those of a loop do, and a variable declared there is a new one each
    /// time. A function literal is a body of its own.
    var gotoStatements: (any: Bool, backward: Bool) {
        var seen: Set<String> = []
        var found = (any: false, backward: false)
        func visit(_ statements: [GoStatement]) {
            for statement in statements {
                if let branch = statement.branch {
                    switch branch.kind {
                    case .label(let name):
                        seen.insert(name)
                    case .goto(let name):
                        found.any = true
                        if seen.contains(name) { found.backward = true }
                    default:
                        break
                    }
                    continue
                }
                switch statement {
                case .ifStatement(_, let thenBlock, let elseBlock, _):
                    visit(thenBlock.statements)
                    visit(elseBlock?.statements ?? [])
                case .forStatement(_, _, _, let body, _), .forRangeStatement(_, _, _, let body, _):
                    visit(body.statements)
                case .switchStatement(_, let cases, _):
                    for switchCase in cases { visit(switchCase.body.statements) }
                case .selectStatement(let cases, _):
                    for selectCase in cases { visit(selectCase.body.statements) }
                default:
                    break
                }
            }
        }
        visit(statements)
        return found
    }
}

extension GoBlock {
    /// Whether a statement of the block itself is a label.
    var hasLabels: Bool {
        statements.contains(where: \.isLabel)
    }
}

extension GoSwitchCase {
    /// Whether the clause ends in `fallthrough`, and so goes on with the
    /// clause after it.
    var fallsThrough: Bool {
        if case .fallthrough? = body.statements.last?.branch?.kind { return true }
        return false
    }
}
