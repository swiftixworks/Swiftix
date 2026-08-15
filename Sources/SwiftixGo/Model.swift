/// Source locations, diagnostics, tokens, and AST nodes for the Swiftix Go frontend.

public struct GoSourceFile: Sendable, Equatable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

public struct GoSourcePosition: Sendable, Equatable {
    public let path: String
    public let offset: Int
    public let line: Int
    public let column: Int

    public init(path: String, offset: Int, line: Int, column: Int) {
        self.path = path
        self.offset = offset
        self.line = line
        self.column = column
    }
}

public struct GoDiagnostic: Error, Sendable, Equatable, CustomStringConvertible {
    public let position: GoSourcePosition
    public let message: String

    public init(position: GoSourcePosition, message: String) {
        self.position = position
        self.message = message
    }

    public var description: String {
        "\(position.path):\(position.line):\(position.column): \(message)"
    }
}

public enum GoTokenKind: Sendable, Equatable {
    case identifier(String)
    case integer(Int64)
    case string(String)
    case package
    case `import`
    case function
    case typeKeyword
    case structKeyword
    case variable
    case constant
    case `return`
    case `if`
    case `else`
    case `for`
    case switchKeyword
    case caseKeyword
    case defaultKeyword
    case breakKeyword
    case continueKeyword
    case rangeKeyword
    case deferKeyword
    case mapKeyword
    case interfaceKeyword
    case goKeyword
    case chanKeyword
    case selectKeyword
    case leftParen
    case rightParen
    case leftBrace
    case rightBrace
    case leftBracket
    case rightBracket
    case comma
    case period
    case colon
    case semicolon
    case assign
    case declare
    case plus
    case minus
    case star
    case slash
    case percent
    case bang
    case equal
    case notEqual
    case less
    case arrow
    case lessEqual
    case greater
    case greaterEqual
    case logicalAnd
    case logicalOr
    case ampersand
    case increment
    case decrement
    case eof

    var canEndStatement: Bool {
        switch self {
        case .identifier, .integer, .string, .rightParen, .rightBrace, .rightBracket, .return,
            .breakKeyword, .continueKeyword, .increment, .decrement:
            return true
        default:
            return false
        }
    }
}

public struct GoToken: Sendable, Equatable {
    public let kind: GoTokenKind
    public let position: GoSourcePosition

    public init(kind: GoTokenKind, position: GoSourcePosition) {
        self.kind = kind
        self.position = position
    }
}

public struct GoFile: Sendable, Equatable {
    public let path: String
    public let packageName: String
    public let imports: [GoImportDeclaration]
    public let typeDeclarations: [GoTypeDeclaration]
    public let globalDeclarations: [GoGlobalDeclaration]
    public let functions: [GoFunctionDeclaration]

    public init(
        path: String,
        packageName: String,
        imports: [GoImportDeclaration],
        typeDeclarations: [GoTypeDeclaration] = [],
        globalDeclarations: [GoGlobalDeclaration] = [],
        functions: [GoFunctionDeclaration]
    ) {
        self.path = path
        self.packageName = packageName
        self.imports = imports
        self.typeDeclarations = typeDeclarations
        self.globalDeclarations = globalDeclarations
        self.functions = functions
    }
}

public struct GoGlobalDeclaration: Sendable, Equatable {
    public let name: String
    public let explicitType: GoTypeExpression?
    public let expression: GoExpression?
    public let isConstant: Bool
    public let position: GoSourcePosition

    public init(
        name: String,
        explicitType: GoTypeExpression? = nil,
        expression: GoExpression? = nil,
        isConstant: Bool = false,
        position: GoSourcePosition
    ) {
        self.name = name
        self.explicitType = explicitType
        self.expression = expression
        self.isConstant = isConstant
        self.position = position
    }
}

public struct GoTypeDeclaration: Sendable, Equatable {
    public let name: String
    public let type: GoTypeExpression
    public let position: GoSourcePosition

    public init(name: String, type: GoTypeExpression, position: GoSourcePosition) {
        self.name = name
        self.type = type
        self.position = position
    }
}

public struct GoStructFieldDeclaration: Sendable, Equatable {
    public let name: String
    public let type: GoTypeExpression
    public let position: GoSourcePosition

    public init(name: String, type: GoTypeExpression, position: GoSourcePosition) {
        self.name = name
        self.type = type
        self.position = position
    }
}

public struct GoInterfaceMethodDeclaration: Sendable, Equatable {
    public let name: String
    public let parameters: [GoTypeExpression]
    public let results: [GoTypeExpression]
    public let position: GoSourcePosition

    public init(
        name: String,
        parameters: [GoTypeExpression] = [],
        results: [GoTypeExpression] = [],
        position: GoSourcePosition
    ) {
        self.name = name
        self.parameters = parameters
        self.results = results
        self.position = position
    }
}

public indirect enum GoTypeExpression: Sendable, Equatable {
    case named(String, position: GoSourcePosition)
    case structure(fields: [GoStructFieldDeclaration], position: GoSourcePosition)
    case pointer(pointee: GoTypeExpression, position: GoSourcePosition)
    case array(length: Int, element: GoTypeExpression, position: GoSourcePosition)
    case slice(element: GoTypeExpression, position: GoSourcePosition)
    case map(key: GoTypeExpression, value: GoTypeExpression, position: GoSourcePosition)
    case channel(direction: GoChannelDirection, element: GoTypeExpression, position: GoSourcePosition)
    case interface(methods: [GoInterfaceMethodDeclaration], position: GoSourcePosition)

    public var position: GoSourcePosition {
        switch self {
        case .named(_, let position), .structure(_, let position), .pointer(_, let position),
            .array(_, _, let position), .slice(_, let position), .map(_, _, let position),
            .channel(_, _, let position),
            .interface(_, let position):
            return position
        }
    }
}

public enum GoChannelDirection: Sendable, Equatable {
    case bidirectional
    case sendOnly
    case receiveOnly
}

public struct GoImportDeclaration: Sendable, Equatable {
    public let path: String
    public let position: GoSourcePosition

    public init(path: String, position: GoSourcePosition) {
        self.path = path
        self.position = position
    }
}

public struct GoFunctionDeclaration: Sendable, Equatable {
    public let name: String
    public let receiver: GoParameter?
    public let parameters: [GoParameter]
    /// Result identifiers in declaration order. Unnamed results are `nil`.
    public let resultNames: [String?]
    public let resultTypes: [GoTypeExpression]
    public let body: GoBlock
    public let position: GoSourcePosition

    public init(
        name: String,
        receiver: GoParameter? = nil,
        parameters: [GoParameter] = [],
        resultNames: [String?] = [],
        resultTypes: [GoTypeExpression] = [],
        body: GoBlock,
        position: GoSourcePosition
    ) {
        self.name = name
        self.receiver = receiver
        self.parameters = parameters
        self.resultNames = resultNames.isEmpty
            ? Array(repeating: nil, count: resultTypes.count)
            : resultNames
        self.resultTypes = resultTypes
        self.body = body
        self.position = position
    }
}

public struct GoParameter: Sendable, Equatable {
    public let name: String
    public let type: GoTypeExpression
    public let position: GoSourcePosition

    public init(name: String, type: GoTypeExpression, position: GoSourcePosition) {
        self.name = name
        self.type = type
        self.position = position
    }
}

public struct GoBlock: Sendable, Equatable {
    public let statements: [GoStatement]
    public let position: GoSourcePosition

    public init(statements: [GoStatement], position: GoSourcePosition) {
        self.statements = statements
        self.position = position
    }
}

public struct GoSwitchCase: Sendable, Equatable {
    public let expressions: [GoExpression]
    public let body: GoBlock
    public let isDefault: Bool
    public let position: GoSourcePosition

    public init(
        expressions: [GoExpression],
        body: GoBlock,
        isDefault: Bool,
        position: GoSourcePosition
    ) {
        self.expressions = expressions
        self.body = body
        self.isDefault = isDefault
        self.position = position
    }
}

public struct GoSelectCase: Sendable, Equatable {
    /// A send or receive statement. `nil` represents `default`.
    public let communication: GoStatement?
    public let body: GoBlock
    public let position: GoSourcePosition

    public init(
        communication: GoStatement?,
        body: GoBlock,
        position: GoSourcePosition
    ) {
        self.communication = communication
        self.body = body
        self.position = position
    }
}

public enum GoIncrementOperator: Sendable, Equatable {
    case increment
    case decrement
}

public indirect enum GoStatement: Sendable, Equatable {
    case declaration(
        name: String,
        explicitType: GoTypeExpression?,
        expression: GoExpression?,
        isConstant: Bool,
        position: GoSourcePosition)
    case multiDeclaration(
        names: [String],
        expression: GoExpression,
        position: GoSourcePosition)
    case assignment(target: GoExpression, expression: GoExpression, position: GoSourcePosition)
    case multiAssignment(
        targets: [GoExpression],
        expression: GoExpression,
        position: GoSourcePosition)
    case increment(target: GoExpression, operator: GoIncrementOperator, position: GoSourcePosition)
    case expression(GoExpression)
    case returnValues([GoExpression], position: GoSourcePosition)
    case breakStatement(position: GoSourcePosition)
    case continueStatement(position: GoSourcePosition)
    case deferStatement(expression: GoExpression, position: GoSourcePosition)
    case goStatement(expression: GoExpression, position: GoSourcePosition)
    case sendStatement(
        channel: GoExpression,
        value: GoExpression,
        position: GoSourcePosition)
    case ifStatement(
        condition: GoExpression,
        thenBlock: GoBlock,
        elseBlock: GoBlock?,
        position: GoSourcePosition)
    case forStatement(
        initializer: GoStatement?,
        condition: GoExpression?,
        post: GoStatement?,
        body: GoBlock,
        position: GoSourcePosition)
    case forRangeStatement(
        indexName: String?,
        valueName: String?,
        collection: GoExpression,
        body: GoBlock,
        position: GoSourcePosition)
    case switchStatement(
        expression: GoExpression?,
        cases: [GoSwitchCase],
        position: GoSourcePosition)
    case selectStatement(cases: [GoSelectCase], position: GoSourcePosition)
}

public enum GoUnaryOperator: Sendable, Equatable {
    case plus
    case minus
    case not
    case address
    case dereference
    case receive
}

public enum GoBinaryOperator: Sendable, Equatable {
    case add
    case subtract
    case multiply
    case divide
    case remainder
    case equal
    case notEqual
    case less
    case lessEqual
    case greater
    case greaterEqual
    case logicalAnd
    case logicalOr
}

public struct GoCompositeElement: Sendable, Equatable {
    public let key: String?
    public let keyExpression: GoExpression?
    public let value: GoExpression
    public let position: GoSourcePosition

    public init(
        key: String? = nil,
        keyExpression: GoExpression? = nil,
        value: GoExpression,
        position: GoSourcePosition
    ) {
        self.key = key
        self.keyExpression = keyExpression
        self.value = value
        self.position = position
    }
}

public indirect enum GoExpression: Sendable, Equatable {
    case integer(Int64, position: GoSourcePosition)
    case string(String, position: GoSourcePosition)
    case identifier(String, position: GoSourcePosition)
    case selector(base: GoExpression, name: String, position: GoSourcePosition)
    case compositeLiteral(
        type: GoTypeExpression,
        elements: [GoCompositeElement],
        position: GoSourcePosition)
    case index(base: GoExpression, index: GoExpression, position: GoSourcePosition)
    case slicing(
        base: GoExpression,
        low: GoExpression?,
        high: GoExpression?,
        position: GoSourcePosition)
    case typeExpression(GoTypeExpression, position: GoSourcePosition)
    case call(callee: GoExpression, arguments: [GoExpression], position: GoSourcePosition)
    case typeAssertion(base: GoExpression, type: GoTypeExpression, position: GoSourcePosition)
    case functionLiteral(
        parameters: [GoParameter],
        resultNames: [String?],
        resultTypes: [GoTypeExpression],
        body: GoBlock,
        position: GoSourcePosition)
    case unary(operator: GoUnaryOperator, operand: GoExpression, position: GoSourcePosition)
    case binary(
        left: GoExpression,
        operator: GoBinaryOperator,
        right: GoExpression,
        position: GoSourcePosition)

    public var position: GoSourcePosition {
        switch self {
        case .integer(_, let position), .string(_, let position), .identifier(_, let position):
            return position
        case .selector(_, _, let position), .call(_, _, let position),
            .typeAssertion(_, _, let position), .unary(_, _, let position):
            return position
        case .functionLiteral(_, _, _, _, let position): return position
        case .compositeLiteral(_, _, let position):
            return position
        case .index(_, _, let position), .slicing(_, _, _, let position),
            .typeExpression(_, let position):
            return position
        case .binary(_, _, _, let position):
            return position
        }
    }
}
