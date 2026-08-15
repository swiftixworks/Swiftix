/// Register-based intermediate representation shared by the compiler stages.

public enum GoIRConstant: Sendable, Equatable {
    case int(Int64)
    case string(String)
    case bool(Bool)
    case nilValue
}

public enum GoIRUnaryOperator: Sendable, Equatable {
    case negate
    case not
}

public enum GoIRBinaryOperator: Sendable, Equatable {
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

public enum GoIRSelectCase: Sendable, Equatable {
    case send(channel: Int, value: Int, target: Int)
    case receive(
        channel: Int,
        destination: Int?,
        okDestination: Int?,
        zero: Int,
        target: Int)
}

public enum GoIROperation: Sendable, Equatable {
    case constant(destination: Int, value: GoIRConstant)
    case copy(destination: Int, source: Int)
    case unary(destination: Int, operator: GoIRUnaryOperator, operand: Int)
    case binary(
        destination: Int,
        operator: GoIRBinaryOperator,
        left: Int,
        right: Int)
    case print(arguments: [Int], newline: Bool)
    case label(Int)
    case jump(target: Int)
    case jumpIfFalse(condition: Int, target: Int)
    case jumpIfTrue(condition: Int, target: Int)
    case call(function: String, arguments: [Int], destinations: [Int])
    case spawn(function: String, arguments: [Int])
    case makeStruct(
        destination: Int,
        typeName: String?,
        fieldNames: [String],
        values: [Int])
    case getField(destination: Int, base: Int, name: String)
    case setField(destination: Int, base: Int, name: String, value: Int)
    case address(destination: Int, local: Int, fieldPath: [String])
    case fieldAddress(destination: Int, pointer: Int, name: String)
    case dereference(destination: Int, pointer: Int)
    case setPointer(pointer: Int, value: Int)
    case makeArray(destination: Int, values: [Int])
    case makeSlice(destination: Int, zero: Int, values: [Int])
    case allocateSlice(destination: Int, zero: Int, length: Int, capacity: Int)
    case getIndex(destination: Int, base: Int, index: Int)
    case setIndex(destination: Int, base: Int, index: Int, value: Int)
    case sliceValue(destination: Int, base: Int, low: Int, high: Int)
    case sliceArray(destination: Int, pointer: Int, low: Int, high: Int, zero: Int)
    case length(destination: Int, base: Int)
    case capacity(destination: Int, base: Int)
    case append(destination: Int, slice: Int, value: Int, zero: Int)
    case indexAddress(destination: Int, base: Int, index: Int)
    case loadGlobal(destination: Int, index: Int)
    case storeGlobal(index: Int, source: Int)
    case addressGlobal(destination: Int, index: Int)
    case `return`
    case returnValues(sources: [Int])
    case deferCall(function: String, arguments: [Int])
    case `panic`(source: Int)
    case recover(destination: Int)
    case makeMap(destination: Int, keys: [Int], values: [Int])
    case makeChannel(destination: Int, zero: Int, capacity: Int)
    case sendChannel(channel: Int, value: Int)
    case receiveChannel(destination: Int, okDestination: Int?, channel: Int, zero: Int)
    case closeChannel(channel: Int)
    case select(cases: [GoIRSelectCase], defaultTarget: Int?)
    case timeAfter(destination: Int, duration: Int)
    case timeSleep(duration: Int)
    case timeTick(destination: Int, duration: Int)
    case contextBackground(destination: Int)
    case contextWithCancel(ctxDestination: Int, cancelDestination: Int, parent: Int)
    case contextWithTimeout(ctxDestination: Int, cancelDestination: Int, parent: Int, duration: Int)
    case contextDone(destination: Int, ctx: Int)
    case contextErr(destination: Int, ctx: Int)
    case cancelContext(ctx: Int)
    case netDial(connDestination: Int, errDestination: Int, network: Int, address: Int)
    case netListen(lnDestination: Int, errDestination: Int, network: Int, address: Int)
    case netAccept(connDestination: Int, errDestination: Int, listener: Int)
    case netRead(nDestination: Int, errDestination: Int, conn: Int, buf: Int)
    case netWrite(nDestination: Int, errDestination: Int, conn: Int, buf: Int)
    case netClose(errDestination: Int, conn: Int)
    case netLookupHost(destination: Int, errDestination: Int, host: Int)
    case httpHandleFunc(pattern: Int, handler: String)
    case httpListenAndServe(errDestination: Int, addr: Int)
    case httpGet(respDestination: Int, errDestination: Int, url: Int)
    case makeMutex(destination: Int)
    case mutexLock(mutex: Int)
    case mutexUnlock(mutex: Int)
    case makeWaitGroup(destination: Int)
    case waitGroupAdd(waitGroup: Int, delta: Int)
    case waitGroupWait(waitGroup: Int)
    case garbageCollect
    case getMapIndex(
        destination: Int,
        okDestination: Int?,
        base: Int,
        key: Int,
        zero: Int)
    case setMapIndex(destination: Int, base: Int, key: Int, value: Int)
    case deleteMap(destination: Int, base: Int, key: Int)
    case callInterface(method: String, receiver: Int, arguments: [Int], destinations: [Int])
    case makeInterface(destination: Int, source: Int, typeName: String)
    case typeAssert(
        destination: Int,
        okDestination: Int?,
        source: Int,
        targetName: String,
        zero: Int)
    case rangeKeys(destination: Int, base: Int)
    case rangeValue(destination: Int, base: Int, key: Int, zero: Int)
    case testFail(arguments: [Int], fatal: Bool)
    case testBegin(name: String)
    case testEnd(name: String, destination: Int)
    // Process/exec ABI: argv/exit plus userland stdin and VFS input collection.
    case osArgs(destination: Int)
    case osExit(source: Int)
    case parseInt(destination: Int, errDestination: Int, source: Int)
    case readInput(
        dataDestination: Int,
        statusDestination: Int,
        command: Int,
        paths: Int)
}

public struct GoIRFunction: Sendable, Equatable {
    public let name: String
    public let parameterCount: Int
    public let returnCount: Int
    public let registerCount: Int
    public let operations: [GoIROperation]

    public init(
        name: String,
        parameterCount: Int = 0,
        returnCount: Int = 0,
        registerCount: Int,
        operations: [GoIROperation]
    ) {
        self.name = name
        self.parameterCount = parameterCount
        self.returnCount = returnCount
        self.registerCount = registerCount
        self.operations = operations
    }
}

public struct GoIRProgram: Sendable, Equatable {
    public let entryPoint: String
    public let initializers: [String]
    public let globalCount: Int
    public let functions: [GoIRFunction]

    public init(
        entryPoint: String,
        initializers: [String] = [],
        globalCount: Int = 0,
        functions: [GoIRFunction]
    ) {
        self.entryPoint = entryPoint
        self.initializers = initializers
        self.globalCount = globalCount
        self.functions = functions
    }
}
