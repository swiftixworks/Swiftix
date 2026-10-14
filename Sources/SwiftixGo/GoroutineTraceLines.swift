import SwiftixGoRuntime

/// What the trace of a panic needs to know of a function: the file it was
/// written in, the name Go gives it, and the names of the literals in it.
///
/// The lines themselves travel in the operations: before each statement the
/// lowerer puts a label no jump names (`GoLineMarker`), which the emitter
/// turns into the table of `GoSourceLines` and otherwise ignores. A label
/// emits no instruction, so the image is what it was without them.
struct GoFunctionTrace: Sendable, Equatable {
    struct Name: Sendable, Equatable {
        let goName: String
        let hasArguments: Bool
    }

    let path: String
    /// By compiled symbol: the function's own name and, for one that is not
    /// a literal, those of the literals written in it.
    let names: [String: Name]

    init(_ function: GoFunctionDeclaration, compiledName: String, isLiteral: Bool) {
        path = function.position.path
        guard !isLiteral else {
            names = [:]
            return
        }
        let goName = Self.goName(of: function, compiledName: compiledName)
        var names = [
            compiledName: Name(
                goName: goName,
                hasArguments: function.receiver != nil || !function.parameters.isEmpty)
        ]
        Self.nameLiterals(in: function.body, prefix: goName + ".func", into: &names)
        self.names = names
    }

    /// Go's name of a function that is not a literal: `main.f`,
    /// `main.(*T).m`, `main.T.m`, `io/fs.(*PathError).Error`.
    static func goName(of function: GoFunctionDeclaration, compiledName: String) -> String {
        guard function.receiver != nil else {
            return compiledName.contains(".") ? compiledName : "main." + compiledName
        }
        let isPointer = compiledName.hasPrefix("*")
        let receiver = String(
            compiledName.dropFirst(isPointer ? 1 : 0).dropLast(function.name.count + 1))
        var package = "main"
        var type = receiver
        if let dot = receiver.lastIndex(of: ".") {
            package = String(receiver[..<dot])
            type = String(receiver[receiver.index(after: dot)...])
        }
        return package + "." + (isPointer ? "(*\(type))" : type) + "." + function.name
    }

    /// Names the literals of `block` as Go does: `prefix1`, `prefix2`, ...
    /// in the order of the source, and those inside one after its name and
    /// a dot (`main.main.func1.1`).
    private static func nameLiterals(
        in block: GoBlock, prefix: String, into names: inout [String: Name]
    ) {
        var all: [GoExpression] = []
        GoFunctionLiterals.forEach(in: block) { all.append($0) }
        var inner: Set<String> = []
        var index = 0
        for literal in all {
            guard case .functionLiteral(let parameters, _, _, let body, let position) = literal
            else { continue }
            let symbol = GoFunctionType.literalName(at: position)
            guard !inner.contains(symbol) else { continue }
            index += 1
            let name = prefix + String(index)
            names[symbol] = Name(goName: name, hasArguments: !parameters.isEmpty)
            GoFunctionLiterals.forEach(in: body) { nested in
                inner.insert(GoFunctionType.literalName(at: nested.position))
            }
            nameLiterals(in: body, prefix: name + ".", into: &names)
        }
    }

    /// The table of every function of `program` the lowerer marked, given
    /// how many instructions the emitter makes of each operation.
    static func sourceLines(
        of program: GoIRProgram, instructionCount: (GoIROperation) -> Int
    ) -> GoSourceLines {
        var names: [String: Name] = [:]
        for function in program.functions {
            if let more = function.trace?.names { names.merge(more) { first, _ in first } }
        }
        var table = GoSourceLines()
        for function in program.functions {
            guard let trace = function.trace else { continue }
            var offsets: [Int] = []
            var lines: [Int] = []
            var offset = 0
            for operation in function.operations {
                if let line = GoLineMarker.line(operation) {
                    if offsets.last == offset {
                        lines[lines.count - 1] = line
                    } else {
                        offsets.append(offset)
                        lines.append(line)
                    }
                }
                offset += instructionCount(operation)
            }
            let name = names[function.name]
            table.functions[function.name] = GoSourceLines.Function(
                goName: name?.goName ?? GoTraceNames.fallback(function.name),
                path: trace.path,
                hasArguments: name?.hasArguments ?? (function.parameterCount > 0),
                offsets: offsets, lines: lines)
        }
        return table
    }
}

enum GoTraceNames {
    /// A function no declaration named: a literal of a package-level
    /// initializer, which Go names after the package.
    static func fallback(_ symbol: String) -> String {
        symbol.hasPrefix("$literal.") ? "main.init.func" : symbol
    }
}

/// The label before the operations of a statement, which says its line.
/// Labels of jumps count up from zero; these are negative.
enum GoLineMarker {
    static func operation(line: Int) -> GoIROperation { .label(-1 - line) }

    static func line(_ operation: GoIROperation) -> Int? {
        guard case .label(let label) = operation, label < 0 else { return nil }
        return -1 - label
    }
}

extension IRLowerer {
    /// Notes that the operations of `statement` begin here.
    mutating func markLine(of statement: GoStatement) {
        let line = GoLineMarker.line(of: statement)
        guard line > 0 else { return }
        operations.append(GoLineMarker.operation(line: line))
    }

    /// The last operation that emits something: a line marker does not.
    var lastOperation: GoIROperation? {
        operations.last { GoLineMarker.line($0) == nil }
    }
}

extension GoLineMarker {
    static func line(of statement: GoStatement) -> Int {
        switch statement {
        case .expression(let expression): return expression.position.line
        case .declaration(_, _, _, _, let position), .multiDeclaration(_, _, let position),
            .assignment(_, _, let position), .multiAssignment(_, _, let position),
            .increment(_, _, let position), .returnValues(_, let position),
            .breakStatement(let position), .continueStatement(let position),
            .deferStatement(_, let position), .goStatement(_, let position),
            .sendStatement(_, _, let position), .ifStatement(_, _, _, let position),
            .forStatement(_, _, _, _, let position), .forRangeStatement(_, _, _, _, let position),
            .switchStatement(_, _, let position), .selectStatement(_, let position):
            return position.line
        }
    }
}
