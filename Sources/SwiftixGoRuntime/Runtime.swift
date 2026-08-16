/// Deterministic bytecode model and virtual machine for Swiftix Go programs.

import Swiftix

public struct GoStructFieldValue: Sendable, Equatable {
    public let name: String
    public var value: GoValue

    public init(name: String, value: GoValue) {
        self.name = name
        self.value = value
    }
}

public struct GoStructValue: Sendable, Equatable {
    public let typeName: String?
    public var fields: [GoStructFieldValue]

    public init(typeName: String? = nil, fields: [GoStructFieldValue]) {
        self.typeName = typeName
        self.fields = fields
    }
}

public enum GoPointerComponent: Sendable, Equatable {
    case field(String)
    case index(Int)
}

public struct GoSliceValue: Sendable, Equatable {
    public let backing: GoPointer
    public let start: Int
    public let length: Int
    public let capacity: Int
    public let zeroValue: GoValue

    public init(
        backing: GoPointer,
        start: Int,
        length: Int,
        capacity: Int,
        zeroValue: GoValue
    ) {
        self.backing = backing
        self.start = start
        self.length = length
        self.capacity = capacity
        self.zeroValue = zeroValue
    }
}

public struct GoPointer: Sendable, Equatable {
    public let cell: Int
    public let path: [GoPointerComponent]

    public init(cell: Int, path: [GoPointerComponent] = []) {
        self.cell = cell
        self.path = path
    }
}

public struct GoInterfaceValue: Sendable, Equatable {
    public let typeName: String
    public let value: GoValue

    public init(typeName: String, value: GoValue) {
        self.typeName = typeName
        self.value = value
    }
}

public struct GoMapStorage: Sendable, Equatable {
    public var entries: [(key: GoValue, value: GoValue)]

    public init(entries: [(key: GoValue, value: GoValue)] = []) {
        self.entries = entries
    }

    public func get(_ key: GoValue) -> GoValue? {
        entries.first(where: { $0.key == key })?.value
    }

    public mutating func set(_ key: GoValue, _ value: GoValue) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].value = value
        } else {
            entries.append((key: key, value: value))
        }
    }

    public mutating func delete(_ key: GoValue) {
        entries.removeAll(where: { $0.key == key })
    }

    public static func == (lhs: GoMapStorage, rhs: GoMapStorage) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for (l, r) in zip(lhs.entries, rhs.entries) {
            if l.key != r.key || l.value != r.value { return false }
        }
        return true
    }
}

/// A Go map value is a handle to VM-managed storage. Copying the handle keeps
/// Go's reference semantics without introducing shared host objects or locks.
public struct GoMapValue: Sendable, Equatable {
    public let storage: GoPointer

    public init(storage: GoPointer) {
        self.storage = storage
    }
}

public struct GoChannelSendWaiter: Sendable, Equatable {
    public let goroutineID: Int
    public let value: GoValue
    public let waitSequence: UInt64

    public init(goroutineID: Int, value: GoValue, waitSequence: UInt64 = 0) {
        self.goroutineID = goroutineID
        self.value = value
        self.waitSequence = waitSequence
    }
}

public struct GoChannelReceiveWaiter: Sendable, Equatable {
    public let goroutineID: Int
    public let commaOK: Bool
    public let zeroValue: GoValue
    public let waitSequence: UInt64

    public init(
        goroutineID: Int,
        commaOK: Bool,
        zeroValue: GoValue,
        waitSequence: UInt64 = 0
    ) {
        self.goroutineID = goroutineID
        self.commaOK = commaOK
        self.zeroValue = zeroValue
        self.waitSequence = waitSequence
    }
}

public struct GoChannelStorage: Sendable, Equatable {
    public let capacity: Int
    public var buffer: [GoValue]
    public var closed: Bool
    public var sendWaiters: [GoChannelSendWaiter]
    public var receiveWaiters: [GoChannelReceiveWaiter]

    public init(
        capacity: Int,
        buffer: [GoValue] = [],
        closed: Bool = false,
        sendWaiters: [GoChannelSendWaiter] = [],
        receiveWaiters: [GoChannelReceiveWaiter] = []
    ) {
        self.capacity = capacity
        self.buffer = buffer
        self.closed = closed
        self.sendWaiters = sendWaiters
        self.receiveWaiters = receiveWaiters
    }
}

public struct GoChannelValue: Sendable, Equatable {
    public let storage: GoPointer

    public init(storage: GoPointer) {
        self.storage = storage
    }
}

public struct GoRuntimeWaiter: Sendable, Equatable {
    public let goroutineID: Int
    public let waitSequence: UInt64

    public init(goroutineID: Int, waitSequence: UInt64) {
        self.goroutineID = goroutineID
        self.waitSequence = waitSequence
    }
}

public struct GoMutexStorage: Sendable, Equatable {
    public var locked: Bool
    public var waiters: [GoRuntimeWaiter]

    public init(locked: Bool = false, waiters: [GoRuntimeWaiter] = []) {
        self.locked = locked
        self.waiters = waiters
    }
}

public struct GoMutexValue: Sendable, Equatable {
    public let storage: GoPointer

    public init(storage: GoPointer) {
        self.storage = storage
    }
}

public struct GoWaitGroupStorage: Sendable, Equatable {
    public var count: Int64
    public var waiters: [GoRuntimeWaiter]

    public init(count: Int64 = 0, waiters: [GoRuntimeWaiter] = []) {
        self.count = count
        self.waiters = waiters
    }
}

public struct GoWaitGroupValue: Sendable, Equatable {
    public let storage: GoPointer

    public init(storage: GoPointer) {
        self.storage = storage
    }
}

public struct GoContextStorage: Sendable, Equatable {
    public var doneChannel: GoPointer
    public var cancelled: Bool
    public var errorMessage: String?
    public var children: [GoPointer]

    public init(
        doneChannel: GoPointer,
        cancelled: Bool = false,
        errorMessage: String? = nil,
        children: [GoPointer] = []
    ) {
        self.doneChannel = doneChannel
        self.cancelled = cancelled
        self.errorMessage = errorMessage
        self.children = children
    }
}

public struct GoContextValue: Sendable, Equatable {
    public let storage: GoPointer

    public init(storage: GoPointer) {
        self.storage = storage
    }
}

public struct GoNetConnValue: Sendable, Equatable {
    public let fd: Int
    public let network: String
    public let remoteAddr: String

    public init(fd: Int, network: String = "tcp", remoteAddr: String = "") {
        self.fd = fd
        self.network = network
        self.remoteAddr = remoteAddr
    }
}

public struct GoNetListenerValue: Sendable, Equatable {
    public let fd: Int
    public let network: String
    public let localAddr: String

    public init(fd: Int, network: String = "tcp", localAddr: String = "") {
        self.fd = fd
        self.network = network
        self.localAddr = localAddr
    }
}

public enum GoSelectCaseInstruction: Sendable, Equatable {
    case send(channelLocal: Int, valueLocal: Int, target: Int)
    case receive(
        channelLocal: Int,
        destinationLocal: Int?,
        okLocal: Int?,
        zeroLocal: Int,
        target: Int)
}

public indirect enum GoValue: Sendable, Equatable, CustomStringConvertible {
    case int(Int64)
    case string(String)
    case bool(Bool)
    case structure(GoStructValue)
    case pointer(GoPointer)
    case nilValue
    case array([GoValue])
    case slice(GoSliceValue)
    case map(GoMapValue)
    case mapStorage(GoMapStorage)
    case channel(GoChannelValue)
    case channelStorage(GoChannelStorage)
    case mutex(GoMutexValue)
    case mutexStorage(GoMutexStorage)
    case waitGroup(GoWaitGroupValue)
    case waitGroupStorage(GoWaitGroupStorage)
    case context(GoContextValue)
    case contextStorage(GoContextStorage)
    case netConn(GoNetConnValue)
    case netListener(GoNetListenerValue)
    case interface(GoInterfaceValue)

    public var description: String {
        switch self {
        case .int(let value): return String(value)
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .structure(let value):
            return "{" + value.fields.map { $0.value.description }.joined(separator: " ") + "}"
        case .pointer: return "&<pointer>"
        case .nilValue: return "<nil>"
        case .array(let values):
            return "[" + values.map(\.description).joined(separator: " ") + "]"
        case .slice: return "[<slice>]"
        case .map: return "map[<storage>]"
        case .mapStorage(let storage):
            return "map[" + storage.entries.map { "\($0.key):\($0.value)" }.joined(separator: " ") + "]"
        case .channel: return "<channel>"
        case .channelStorage: return "<channel storage>"
        case .mutex: return "{<mutex>}"
        case .mutexStorage: return "<mutex storage>"
        case .waitGroup: return "{<waitgroup>}"
        case .waitGroupStorage: return "<waitgroup storage>"
        case .context: return "context.Background"
        case .contextStorage: return "<context storage>"
        case .netConn(let conn): return "&net.TCPConn{\(conn.remoteAddr)}"
        case .netListener(let ln): return "&net.TCPListener{\(ln.localAddr)}"
        case .interface(let iface):
            return iface.value.description
        }
    }
}

public enum GoInstruction: Sendable, Equatable {
    case push(GoValue)
    case load(Int)
    case store(Int)
    case negate
    case not
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
    case print(argumentCount: Int, newline: Bool)
    case jump(Int)
    case jumpIfFalse(Int)
    case jumpIfTrue(Int)
    case call(String, argumentCount: Int)
    case spawn(String, argumentCount: Int)
    case makeStruct(typeName: String?, fieldNames: [String])
    case getField(String)
    case setField(String)
    case addressLocal(index: Int, fieldPath: [String])
    case fieldAddress(String)
    case dereference
    case setPointer
    case makeArray(elementCount: Int)
    case makeSlice(elementCount: Int)
    case allocateSlice
    case getIndex
    case setIndex
    case slice
    case sliceArray
    case length
    case capacity
    case append
    case indexAddress
    case loadGlobal(Int)
    case storeGlobal(Int)
    case addressGlobal(Int)
    case `return`
    case returnValues(count: Int)
    case deferCall(String, argumentCount: Int)
    case `panic`
    case recover
    case makeMap(entryCount: Int)
    case makeChannel
    case sendChannel
    case receiveChannel(commaOK: Bool)
    case closeChannel
    case select(cases: [GoSelectCaseInstruction], defaultTarget: Int?)
    case timeAfter
    case timeSleep
    case timeTick
    case contextBackground
    case contextWithCancel
    case contextWithTimeout
    case contextDone
    case contextErr
    case cancelContext
    case netDial
    case netListen
    case netAccept
    case netRead
    case netWrite
    case netClose
    case netLookupHost
    case httpHandleFunc(String)
    case httpListenAndServe
    case httpGet
    case makeMutex
    case mutexLock
    case mutexUnlock
    case makeWaitGroup
    case waitGroupAdd
    case waitGroupWait
    case garbageCollect
    case getMapIndex(commaOK: Bool)
    case setMapIndex
    case deleteMap
    case callInterface(String, argumentCount: Int)
    case makeInterface(typeName: String)
    case typeAssert(typeName: String, commaOK: Bool)
    case rangeKeys
    case rangeValue
    case testFail(argumentCount: Int, fatal: Bool)
    case testBegin(String)
    case testEnd(String)
    /// Push `os.Args` (the process argument vector) as a `[]string` slice.
    case osArgs
    /// Pop an int and terminate the whole program with it as the exit code
    /// (`os.Exit`). All goroutines stop; no deferred calls run, matching Go.
    case exit
    /// Pop a string, push `(int, error)` — `strconv.Atoi`. On failure the int is
    /// 0 and the error is a non-nil `error` interface value.
    case parseInt
    /// Pop a command name and `[]string` paths, then push `(string, int)`.
    /// With no paths, input is drained asynchronously from fd 0; otherwise the
    /// named VFS files are concatenated and missing files set status 1.
    case readInput
}

public struct GoBytecodeFunction: Sendable, Equatable {
    private static let maximumImplicitMetadataEntries = 1_048_576

    public let name: String
    public let parameterCount: Int
    public let returnCount: Int
    public let localCount: Int
    public let instructions: [GoInstruction]
    /// Exact boxed-local roots at every VM safepoint. Operand-stack values are
    /// tagged `GoValue`s and are therefore scanned precisely without treating
    /// integer payloads as possible pointers.
    public let rootLocalIndices: [Int]
    public let safepointProgramCounters: [Int]

    public init(
        name: String,
        parameterCount: Int = 0,
        returnCount: Int = 0,
        localCount: Int,
        instructions: [GoInstruction],
        rootLocalIndices: [Int]? = nil,
        safepointProgramCounters: [Int]? = nil
    ) {
        self.name = name
        self.parameterCount = parameterCount
        self.returnCount = returnCount
        self.localCount = localCount
        self.instructions = instructions
        if let rootLocalIndices {
            self.rootLocalIndices = rootLocalIndices
        } else if localCount >= 0,
            localCount <= Self.maximumImplicitMetadataEntries
        {
            self.rootLocalIndices = Array(0..<localCount)
        } else {
            // The execution preflight reports the malformed/oversized model.
            // Avoid constructing an invalid range or duplicating hostile input.
            self.rootLocalIndices = []
        }
        if let safepointProgramCounters {
            self.safepointProgramCounters = safepointProgramCounters
        } else if instructions.count < Self.maximumImplicitMetadataEntries {
            self.safepointProgramCounters = Array(0...instructions.count)
        } else {
            self.safepointProgramCounters = []
        }
    }
}

public struct GoRuntimeStatistics: Sendable, Equatable {
    public let heapAllocations: Int
    public let garbageCollections: Int
    public let reclaimedHeapCells: Int
    public let liveHeapCells: Int
    public let liveHeapBytes: Int
    public let maximumHeapBytes: Int

    public init(
        heapAllocations: Int,
        garbageCollections: Int,
        reclaimedHeapCells: Int,
        liveHeapCells: Int,
        liveHeapBytes: Int = 0,
        maximumHeapBytes: Int = 0
    ) {
        self.heapAllocations = heapAllocations
        self.garbageCollections = garbageCollections
        self.reclaimedHeapCells = reclaimedHeapCells
        self.liveHeapCells = liveHeapCells
        self.liveHeapBytes = liveHeapBytes
        self.maximumHeapBytes = maximumHeapBytes
    }
}

/// The outcome of running a program: its process exit code plus heap statistics.
public struct GoProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let statistics: GoRuntimeStatistics

    public init(exitCode: Int32, statistics: GoRuntimeStatistics) {
        self.exitCode = exitCode
        self.statistics = statistics
    }
}

public struct GoExecutable: Sendable, Equatable {
    public let entryPoint: String
    public let initializers: [String]
    public let globalCount: Int
    public let functions: [GoBytecodeFunction]

    public init(
        entryPoint: String,
        initializers: [String] = [],
        globalCount: Int = 0,
        functions: [GoBytecodeFunction]
    ) {
        self.entryPoint = entryPoint
        self.initializers = initializers
        self.globalCount = globalCount
        self.functions = functions
    }
}

public enum GoRuntimeError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingEntryPoint(String)
    case missingFunction(String)
    case invalidLocal(Int)
    case invalidJumpTarget(Int)
    case stackUnderflow
    case typeMismatch
    case divisionByZero
    case argumentCountMismatch(function: String, expected: Int, actual: Int)
    case missingReturn(String)
    case instructionLimitExceeded
    case callStackLimitExceeded
    case unknownField(String)
    case invalidPointer
    case indexOutOfRange
    case invalidSliceBounds
    case panicError(String)
    case testFailure
    case deadlock
    case invalidExecutable(String)
    case resourceLimitExceeded(String)

    public var description: String {
        switch self {
        case .missingEntryPoint(let name): return "missing entry point: \(name)"
        case .missingFunction(let name): return "missing function: \(name)"
        case .invalidLocal(let index): return "invalid local register: \(index)"
        case .invalidJumpTarget(let target): return "invalid jump target: \(target)"
        case .stackUnderflow: return "operand stack underflow"
        case .typeMismatch: return "bytecode operand type mismatch"
        case .divisionByZero: return "integer divide by zero"
        case .argumentCountMismatch(let function, let expected, let actual):
            return "call to \(function) has \(actual) arguments; expected \(expected)"
        case .missingReturn(let function): return "function \(function) returned without a value"
        case .instructionLimitExceeded: return "instruction limit exceeded"
        case .callStackLimitExceeded: return "call stack limit exceeded"
        case .unknownField(let name): return "unknown struct field: \(name)"
        case .invalidPointer: return "invalid pointer"
        case .indexOutOfRange: return "index out of range"
        case .invalidSliceBounds: return "slice bounds out of range"
        case .panicError(let message): return "panic: \(message)"
        case .testFailure: return "test failed"
        case .deadlock: return "fatal error: all goroutines are asleep - deadlock!"
        case .invalidExecutable(let reason): return "invalid Go executable: \(reason)"
        case .resourceLimitExceeded(let resource):
            return "Go runtime resource limit exceeded: \(resource)"
        }
    }
}

public struct GoVirtualMachine: Sendable {
    public let maximumInstructions: Int
    public let instructionQuantum: Int
    public let maximumCallDepth: Int
    public let selectSeed: UInt64
    public let garbageCollectionThreshold: Int
    public let resourceLimits: GoRuntimeResourceLimits

    public init(
        maximumInstructions: Int = 1_000_000,
        instructionQuantum: Int = 4_096,
        maximumCallDepth: Int = 1_024,
        selectSeed: UInt64 = 0x5357_4946_5449_5801,
        garbageCollectionThreshold: Int = 1_024,
        resourceLimits: GoRuntimeResourceLimits = GoRuntimeResourceLimits()
    ) {
        self.maximumInstructions = max(0, maximumInstructions)
        self.instructionQuantum = max(1, instructionQuantum)
        self.maximumCallDepth = max(1, maximumCallDepth)
        self.selectSeed = selectSeed
        self.garbageCollectionThreshold = max(1, garbageCollectionThreshold)
        self.resourceLimits = resourceLimits
    }

    /// Run `executable`, returning its process exit code (`os.Exit`, or 0 when
    /// `main` returns normally). `arguments` is the guest's `os.Args` — element 0
    /// is the program name. `write` receives stdout text.
    @discardableResult
    public func run(
        _ executable: GoExecutable,
        eventLoop: EventLoop = EventLoop(),
        processContext: ProcessContext? = nil,
        arguments: [String] = [],
        write: (String) throws -> Void
    ) throws -> Int32 {
        try runProgram(
            executable, eventLoop: eventLoop, processContext: processContext,
            arguments: arguments, write: write).exitCode
    }

    @discardableResult
    public func runWithStatistics(
        _ executable: GoExecutable,
        eventLoop: EventLoop = EventLoop(),
        processContext: ProcessContext? = nil,
        arguments: [String] = [],
        write: (String) throws -> Void
    ) throws -> GoRuntimeStatistics {
        try runProgram(
            executable, eventLoop: eventLoop, processContext: processContext,
            arguments: arguments, write: write).statistics
    }

    /// The full run: both the exit code and heap statistics.
    public func runProgram(
        _ executable: GoExecutable,
        eventLoop: EventLoop = EventLoop(),
        processContext: ProcessContext? = nil,
        arguments: [String] = [],
        write: (String) throws -> Void
    ) throws -> GoProcessResult {
        do {
            try GoExecutableValidator.validate(executable, limits: resourceLimits)
        } catch let error as GoExecutableValidationError {
            switch error {
            case .missingEntryPoint(let name):
                throw GoRuntimeError.missingEntryPoint(name)
            case .missingInitializer(let name):
                throw GoRuntimeError.missingFunction(name)
            case .resourceLimitExceeded(let resource):
                throw GoRuntimeError.resourceLimitExceeded(resource)
            case .duplicateFunction, .invalid:
                throw GoRuntimeError.invalidExecutable(error.description)
            }
        }
        guard resourceLimits.maximumGoroutines >= 1 else {
            throw GoRuntimeError.resourceLimitExceeded("goroutines")
        }
        guard arguments.count <= resourceLimits.maximumCollectionElements else {
            throw GoRuntimeError.resourceLimitExceeded("process arguments")
        }
        var argumentBytes = 0
        for argument in arguments {
            let count = argument.utf8.count
            guard argumentBytes <= resourceLimits.maximumInputBytes,
                count <= resourceLimits.maximumInputBytes - argumentBytes
            else {
                throw GoRuntimeError.resourceLimitExceeded("process argument bytes")
            }
            argumentBytes += count
        }

        var functions: [String: GoBytecodeFunction] = [:]
        functions.reserveCapacity(executable.functions.count)
        for function in executable.functions {
            functions[function.name] = function
        }
        guard functions[executable.entryPoint] != nil else {
            throw GoRuntimeError.missingEntryPoint(executable.entryPoint)
        }
        for initializer in executable.initializers where functions[initializer] == nil {
            throw GoRuntimeError.missingFunction(initializer)
        }
        var heap = try ManagedHeap(
            globalCount: executable.globalCount,
            maximumCells: resourceLimits.maximumHeapCells,
            maximumBytes: resourceLimits.maximumHeapBytes)
        var startupFunctions = executable.initializers + [executable.entryPoint]
        var frames: [Frame] = []
        var stack: [GoValue] = []
        var executed = 0
        var lastEventLoopYieldInstruction = 0
        var testFailureCount = 0
        var subtests: [(name: String, failuresAtStart: Int)] = []
        var currentGoroutineID = 0
        var nextGoroutineID = 1
        var goroutines: [Int: GoroutineContext] = [:]
        var runQueue: [Int] = []
        var blockedGoroutines: Set<Int> = []
        var blockedSelects: [Int: BlockedSelect] = [:]
        var currentBlocked = false
        var nextWaitSequence: UInt64 = 0
        var selectRandomState = selectSeed
        var asynchronousError: GoRuntimeError?
        var runtimeHandleRoots: [Int: GoValue] = [:]
        var nextRuntimeHandleID = 0
        var activeTimerCount = 0
        var activeDeferredCallCount = 0
        var liveFrameLocalCount = 0
        var outputBytesWritten = 0
        var executionIsActive = true
        var httpHandlers: [String: String] = [:]
        var programExitCode: Int32 = 0
        defer { executionIsActive = false }

        var lastRuntimeMemoryReport: (bytes: Int, cells: Int, collections: Int)?
        func reportRuntimeMemoryIfChanged() throws {
            guard let processContext else { return }
            let statistics = heap.statistics
            let current = (
                bytes: statistics.liveHeapBytes,
                cells: statistics.liveHeapCells,
                collections: statistics.garbageCollections)
            if let previous = lastRuntimeMemoryReport,
               previous.bytes == current.bytes,
               previous.cells == current.cells,
               previous.collections == current.collections { return }
            guard processContext.reportRuntimeMemory(
                bytes: current.bytes,
                limitBytes: statistics.maximumHeapBytes,
                heapCells: current.cells,
                garbageCollections: current.collections)
            else {
                throw GoRuntimeError.resourceLimitExceeded("kernel runtime memory")
            }
            lastRuntimeMemoryReport = current
        }
        defer {
            if let processContext {
                _ = processContext.reportRuntimeMemory(
                    bytes: 0,
                    limitBytes: 0,
                    heapCells: 0,
                    garbageCollections: 0)
            }
        }
        try reportRuntimeMemoryIfChanged()

        func requireCollectionCount(_ count: Int, resource: String) throws {
            guard count >= 0 else {
                throw GoRuntimeError.invalidExecutable("negative \(resource)")
            }
            guard count <= resourceLimits.maximumCollectionElements else {
                throw GoRuntimeError.resourceLimitExceeded(resource)
            }
        }

        func checkedAdd(_ lhs: Int, _ rhs: Int, resource: String) throws -> Int {
            let (result, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else { throw GoRuntimeError.resourceLimitExceeded(resource) }
            return result
        }

        func checkedMultiply(_ lhs: Int, _ rhs: Int, resource: String) throws -> Int {
            let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
            guard !overflow else { throw GoRuntimeError.resourceLimitExceeded(resource) }
            return result
        }

        func consumeOutputBytes(_ byteCount: Int) throws {
            guard byteCount >= 0,
                outputBytesWritten <= resourceLimits.maximumOutputBytes,
                byteCount <= resourceLimits.maximumOutputBytes - outputBytesWritten
            else {
                throw GoRuntimeError.resourceLimitExceeded("output bytes")
            }
            outputBytesWritten += byteCount
        }

        func emit(_ text: String) throws {
            try consumeOutputBytes(text.utf8.count)
            try write(text)
        }

        func formatOutput(
            _ values: [GoValue],
            prefix: String = "",
            separator: String,
            suffix: String
        ) throws -> String {
            guard outputBytesWritten <= resourceLimits.maximumOutputBytes else {
                throw GoRuntimeError.resourceLimitExceeded("output bytes")
            }
            let maximumBytes = resourceLimits.maximumOutputBytes - outputBytesWritten
            var parts: [String] = []
            parts.reserveCapacity(values.count * 2 + 1)
            var byteCount = 0

            func append(_ part: String) throws {
                let count = part.utf8.count
                guard byteCount <= maximumBytes, count <= maximumBytes - byteCount else {
                    throw GoRuntimeError.resourceLimitExceeded("output bytes")
                }
                byteCount += count
                parts.append(part)
            }

            try append(prefix)
            for (index, value) in values.enumerated() {
                if index > 0 { try append(separator) }
                let remaining = maximumBytes - byteCount
                try append(try describe(value, heap: heap, maximumBytes: remaining))
            }
            try append(suffix)
            return parts.joined()
        }

        func makeFrame(
            function: GoBytecodeFunction,
            stackBase: Int,
            arguments: [GoValue],
            heap: inout ManagedHeap,
            isDeferredCall: Bool = false
        ) throws -> Frame {
            guard liveFrameLocalCount <= resourceLimits.maximumLiveFrameLocals,
                function.localCount
                    <= resourceLimits.maximumLiveFrameLocals - liveFrameLocalCount
            else {
                throw GoRuntimeError.resourceLimitExceeded("live frame locals")
            }
            let frame = try Frame(
                function: function,
                stackBase: stackBase,
                arguments: arguments,
                heap: &heap,
                isDeferredCall: isDeferredCall)
            liveFrameLocalCount += function.localCount
            return frame
        }

        func releaseFrame(_ frame: Frame) {
            liveFrameLocalCount -= frame.function.localCount
        }

        func reserveTimer() throws {
            guard activeTimerCount < resourceLimits.maximumTimers else {
                throw GoRuntimeError.resourceLimitExceeded("timers")
            }
            activeTimerCount += 1
        }

        func finishTimer() {
            if activeTimerCount > 0 { activeTimerCount -= 1 }
        }

        func retainRuntimeHandle(_ value: GoValue) throws -> Int {
            guard runtimeHandleRoots.count < resourceLimits.maximumRuntimeHandles else {
                throw GoRuntimeError.resourceLimitExceeded("runtime handles")
            }
            guard nextRuntimeHandleID < Int.max else {
                throw GoRuntimeError.resourceLimitExceeded("runtime handle identifiers")
            }
            let identifier = nextRuntimeHandleID
            nextRuntimeHandleID += 1
            runtimeHandleRoots[identifier] = value
            return identifier
        }

        func runtimeTimestamp() -> Int64 {
            let scaled = eventLoop.now * 1_000_000_000
            if !scaled.isFinite { return scaled.sign == .minus ? Int64.min : Int64.max }
            if scaled <= Double(Int64.min) { return Int64.min }
            if scaled >= Double(Int64.max) { return Int64.max }
            return Int64(scaled)
        }

        func validatedSliceRange(_ slice: GoSliceValue) throws -> Range<Int> {
            guard slice.start >= 0,
                slice.length >= 0,
                slice.capacity >= slice.length,
                slice.backing.path.count < resourceLimits.maximumPointerDepth
            else {
                throw GoRuntimeError.invalidSliceBounds
            }
            let capacityEnd = try checkedAdd(
                slice.start, slice.capacity, resource: "slice bounds")
            let lengthEnd = try checkedAdd(
                slice.start, slice.length, resource: "slice bounds")
            guard case .array(let backing) = try read(pointer: slice.backing, heap: heap),
                capacityEnd <= backing.count,
                lengthEnd <= capacityEnd
            else {
                throw GoRuntimeError.invalidSliceBounds
            }
            return slice.start..<lengthEnd
        }

        /// Runtime timers belong to the hosting Swiftix process when one exists;
        /// standalone VM execution keeps using its explicitly supplied loop.
        func scheduleRuntimeWork(after delay: Double, _ work: @escaping () -> Void) {
            if let processContext {
                processContext.schedule(after: delay, work)
            } else {
                eventLoop.schedule(after: delay, work)
            }
        }

        func allocateWaitSequence() -> UInt64 {
            defer { nextWaitSequence &+= 1 }
            return nextWaitSequence
        }

        func selectRandomIndex(count: Int) -> Int {
            precondition(count > 0)
            selectRandomState = selectRandomState &* 6_364_136_223_846_793_005
                &+ 1_442_695_040_888_963_407
            return Int(selectRandomState % UInt64(count))
        }

        func localValue(_ index: Int, in frame: Frame) throws -> GoValue {
            guard frame.locals.indices.contains(index),
                let cell = frame.locals[index], heap.contains(cell)
            else { throw GoRuntimeError.invalidLocal(index) }
            return heap[cell]
        }

        func storeLocal(_ value: GoValue, at index: Int, in frame: inout Frame) throws {
            guard frame.locals.indices.contains(index) else {
                throw GoRuntimeError.invalidLocal(index)
            }
            if let cell = frame.locals[index] {
                guard heap.contains(cell) else { throw GoRuntimeError.invalidPointer }
                try heap.replace(cell, with: value)
            } else {
                frame.locals[index] = try heap.allocate(value)
            }
        }

        func resumeNextGoroutine() -> Bool {
            guard !runQueue.isEmpty else { return false }
            let next = runQueue.removeFirst()
            guard let context = goroutines.removeValue(forKey: next) else { return false }
            currentGoroutineID = next
            frames = context.frames
            stack = context.stack
            currentBlocked = false
            return true
        }

        func driveEventLoopUntilRunnable() throws {
            while !resumeNextGoroutine() {
                guard eventLoop.runNext() else { throw GoRuntimeError.deadlock }
                if let asynchronousError { throw asynchronousError }
            }
        }

        func scheduleNext(requeueCurrent: Bool) throws {
            // Give one already-ready EventLoop job/timer a turn at each quantum
            // without jumping logical time to a future deadline. Do this before
            // selecting another guest goroutine so a busy run queue cannot starve
            // host work.
            if executed > 0,
               executed != lastEventLoopYieldInstruction,
               executed.isMultiple(of: instructionQuantum) {
                lastEventLoopYieldInstruction = executed
                _ = eventLoop.runUntilIdle(stepBudget: 1)
                if let asynchronousError { throw asynchronousError }
            }
            if requeueCurrent, runQueue.isEmpty { return }
            goroutines[currentGoroutineID] = GoroutineContext(frames: frames, stack: stack)
            if requeueCurrent {
                runQueue.append(currentGoroutineID)
            } else {
                blockedGoroutines.insert(currentGoroutineID)
            }
            try driveEventLoopUntilRunnable()
        }

        func resumeAfterGoroutineCompletion() throws {
            try driveEventLoopUntilRunnable()
        }

        func wakeGoroutine(
            _ id: Int,
            values: [GoValue] = [],
            panicValue: GoValue? = nil
        ) throws {
            guard var context = goroutines[id], blockedGoroutines.remove(id) != nil else {
                throw GoRuntimeError.typeMismatch
            }
            guard context.stack.count <= resourceLimits.maximumValueStackEntries,
                values.count
                    <= resourceLimits.maximumValueStackEntries - context.stack.count
            else {
                throw GoRuntimeError.resourceLimitExceeded("operand stack")
            }
            context.stack.append(contentsOf: values)
            if let panicValue {
                guard !context.frames.isEmpty else { throw GoRuntimeError.typeMismatch }
                context.frames[context.frames.count - 1].pendingExit = .panicking(panicValue)
            }
            goroutines[id] = context
            runQueue.append(id)
        }

        func blockedReceiveCandidate(
            for channel: GoPointer,
            excluding excludedID: Int? = nil
        ) -> BlockedSelectCandidate? {
            blockedSelects.compactMap { id, blocked -> BlockedSelectCandidate? in
                guard id != excludedID else { return nil }
                let indices = blocked.cases.indices.filter { index in
                    guard case .receive(let base, _, _, _, _) = blocked.cases[index],
                        case .channel(let value) = base
                    else { return false }
                    return value.storage == channel
                }
                guard !indices.isEmpty else { return nil }
                return BlockedSelectCandidate(
                    goroutineID: id,
                    caseIndices: indices,
                    waitSequence: blocked.waitSequence)
            }.min { lhs, rhs in
                if lhs.waitSequence != rhs.waitSequence {
                    return lhs.waitSequence < rhs.waitSequence
                }
                return lhs.goroutineID < rhs.goroutineID
            }
        }

        func blockedSendCandidate(
            for channel: GoPointer,
            excluding excludedID: Int? = nil
        ) -> BlockedSelectCandidate? {
            blockedSelects.compactMap { id, blocked -> BlockedSelectCandidate? in
                guard id != excludedID else { return nil }
                let indices = blocked.cases.indices.filter { index in
                    guard case .send(let base, _, _) = blocked.cases[index],
                        case .channel(let value) = base
                    else { return false }
                    return value.storage == channel
                }
                guard !indices.isEmpty else { return nil }
                return BlockedSelectCandidate(
                    goroutineID: id,
                    caseIndices: indices,
                    waitSequence: blocked.waitSequence)
            }.min { lhs, rhs in
                if lhs.waitSequence != rhs.waitSequence {
                    return lhs.waitSequence < rhs.waitSequence
                }
                return lhs.goroutineID < rhs.goroutineID
            }
        }

        func makeSelectedGoroutineRunnable(
            _ candidate: BlockedSelectCandidate,
            receiveValue: GoValue? = nil,
            receiveOK: Bool = true
        ) throws -> GoValue? {
            guard let blocked = blockedSelects.removeValue(forKey: candidate.goroutineID),
                var context = goroutines[candidate.goroutineID],
                !context.frames.isEmpty,
                blockedGoroutines.remove(candidate.goroutineID) != nil
            else { throw GoRuntimeError.typeMismatch }
            let selectedIndex = candidate.caseIndices[
                selectRandomIndex(count: candidate.caseIndices.count)]
            guard blocked.cases.indices.contains(selectedIndex) else {
                throw GoRuntimeError.typeMismatch
            }
            let selected = blocked.cases[selectedIndex]
            var sentValue: GoValue?
            switch selected {
            case .send(_, let value, let target):
                sentValue = value
                try jump(to: target, frame: &context.frames[context.frames.count - 1])
            case .receive(_, let destination, let okDestination, _, let target):
                guard let receiveValue else { throw GoRuntimeError.typeMismatch }
                if let destination {
                    try storeLocal(
                        receiveValue,
                        at: destination,
                        in: &context.frames[context.frames.count - 1])
                }
                if let okDestination {
                    try storeLocal(
                        .bool(receiveOK),
                        at: okDestination,
                        in: &context.frames[context.frames.count - 1])
                }
                try jump(to: target, frame: &context.frames[context.frames.count - 1])
            }
            goroutines[candidate.goroutineID] = context
            runQueue.append(candidate.goroutineID)
            return sentValue
        }

        func selectCaseIsReady(
            _ selectCase: EvaluatedSelectCase,
            excluding excludedID: Int? = nil
        ) throws -> Bool {
            switch selectCase {
            case .send(let base, _, _):
                if base == .nilValue { return false }
                guard case .channel(let channel) = base,
                    case .channelStorage(let storage) = try read(
                        pointer: channel.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                return storage.closed
                    || !storage.receiveWaiters.isEmpty
                    || blockedReceiveCandidate(for: channel.storage, excluding: excludedID) != nil
                    || storage.buffer.count < storage.capacity
            case .receive(let base, _, _, _, _):
                if base == .nilValue { return false }
                guard case .channel(let channel) = base,
                    case .channelStorage(let storage) = try read(
                        pointer: channel.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                return !storage.buffer.isEmpty
                    || !storage.sendWaiters.isEmpty
                    || blockedSendCandidate(for: channel.storage, excluding: excludedID) != nil
                    || storage.closed
            }
        }

        func trySelectSend(
            _ value: GoValue,
            to base: GoValue,
            excluding excludedID: Int? = nil
        ) throws -> ChannelSendAttempt {
            if base == .nilValue { return .blocked }
            guard case .channel(let channel) = base,
                case .channelStorage(var storage) = try read(
                    pointer: channel.storage, heap: heap)
            else { throw GoRuntimeError.typeMismatch }
            if storage.closed { return .closed }

            let ordinary = storage.receiveWaiters.first
            let selected = blockedReceiveCandidate(
                for: channel.storage, excluding: excludedID)
            if let ordinary, selected == nil
                || (selected.map { ordinary.waitSequence <= $0.waitSequence } ?? false)
            {
                storage.receiveWaiters.removeFirst()
                try writePointer(
                    .channelStorage(storage), through: channel.storage, heap: &heap)
                var values = [value]
                if ordinary.commaOK { values.append(.bool(true)) }
                try wakeGoroutine(ordinary.goroutineID, values: values)
                return .sent
            }
            if let selected {
                _ = try makeSelectedGoroutineRunnable(
                    selected, receiveValue: value, receiveOK: true)
                return .sent
            }
            if storage.buffer.count < storage.capacity {
                storage.buffer.append(value)
                try writePointer(
                    .channelStorage(storage), through: channel.storage, heap: &heap)
                return .sent
            }
            return .blocked
        }

        func trySelectReceive(
            from base: GoValue,
            zero: GoValue,
            excluding excludedID: Int? = nil
        ) throws -> ChannelReceiveAttempt {
            if base == .nilValue { return .blocked }
            guard case .channel(let channel) = base,
                case .channelStorage(var storage) = try read(
                    pointer: channel.storage, heap: heap)
            else { throw GoRuntimeError.typeMismatch }
            if !storage.buffer.isEmpty {
                let value = storage.buffer.removeFirst()
                let ordinary = storage.sendWaiters.first
                let selected = blockedSendCandidate(for: channel.storage, excluding: excludedID)
                if let ordinary, selected == nil
                    || (selected.map { ordinary.waitSequence <= $0.waitSequence } ?? false)
                {
                    storage.sendWaiters.removeFirst()
                    storage.buffer.append(ordinary.value)
                    try wakeGoroutine(ordinary.goroutineID)
                } else if let selected,
                    let selectedValue = try makeSelectedGoroutineRunnable(selected)
                {
                    storage.buffer.append(selectedValue)
                }
                try writePointer(
                    .channelStorage(storage), through: channel.storage, heap: &heap)
                return .received(value, true)
            }

            let ordinary = storage.sendWaiters.first
            let selected = blockedSendCandidate(for: channel.storage, excluding: excludedID)
            if let ordinary, selected == nil
                || (selected.map { ordinary.waitSequence <= $0.waitSequence } ?? false)
            {
                storage.sendWaiters.removeFirst()
                try writePointer(
                    .channelStorage(storage), through: channel.storage, heap: &heap)
                try wakeGoroutine(ordinary.goroutineID)
                return .received(ordinary.value, true)
            }
            if let selected,
                let selectedValue = try makeSelectedGoroutineRunnable(selected)
            {
                return .received(selectedValue, true)
            }
            if storage.closed { return .received(zero, false) }
            return .blocked
        }

        func wakeReadyBlockedSelects() throws {
            while true {
                let ordered = blockedSelects.sorted { lhs, rhs in
                    if lhs.value.waitSequence != rhs.value.waitSequence {
                        return lhs.value.waitSequence < rhs.value.waitSequence
                    }
                    return lhs.key < rhs.key
                }
                var ready: (id: Int, blocked: BlockedSelect, indices: [Int])?
                for (id, blocked) in ordered {
                    var indices: [Int] = []
                    for index in blocked.cases.indices
                    where try selectCaseIsReady(blocked.cases[index], excluding: id) {
                        indices.append(index)
                    }
                    if !indices.isEmpty {
                        ready = (id, blocked, indices)
                        break
                    }
                }
                guard let ready else { return }
                let selectedIndex = ready.indices[selectRandomIndex(count: ready.indices.count)]
                let selected = ready.blocked.cases[selectedIndex]
                guard blockedSelects.removeValue(forKey: ready.id) != nil,
                    var context = goroutines[ready.id],
                    !context.frames.isEmpty,
                    blockedGoroutines.remove(ready.id) != nil
                else { throw GoRuntimeError.typeMismatch }
                let activeFrame = context.frames.count - 1
                switch selected {
                case .send(let channel, let value, let target):
                    switch try trySelectSend(value, to: channel, excluding: ready.id) {
                    case .sent:
                        try jump(to: target, frame: &context.frames[activeFrame])
                    case .closed:
                        context.frames[activeFrame].pendingExit = .panicking(
                            .string("send on closed channel"))
                    case .blocked:
                        throw GoRuntimeError.typeMismatch
                    }
                case .receive(
                    let channel, let destination, let okDestination, let zero, let target):
                    switch try trySelectReceive(
                        from: channel, zero: zero, excluding: ready.id)
                    {
                    case .received(let value, let ok):
                        if let destination {
                            try storeLocal(value, at: destination, in: &context.frames[activeFrame])
                        }
                        if let okDestination {
                            try storeLocal(.bool(ok), at: okDestination, in: &context.frames[activeFrame])
                        }
                        try jump(to: target, frame: &context.frames[activeFrame])
                    case .blocked:
                        throw GoRuntimeError.typeMismatch
                    }
                }
                goroutines[ready.id] = context
                runQueue.append(ready.id)
            }
        }

        func cancelContextTree(_ ctxPointer: GoPointer, message: String) throws {
            guard case .contextStorage(var ctxStorage) = try read(
                pointer: ctxPointer, heap: heap)
            else { return }
            guard !ctxStorage.cancelled else { return }
            ctxStorage.cancelled = true
            ctxStorage.errorMessage = message
            try writePointer(.contextStorage(ctxStorage), through: ctxPointer, heap: &heap)
            // Close the done channel to signal cancellation
            guard case .channelStorage(var doneStorage) = try read(
                pointer: ctxStorage.doneChannel, heap: heap)
            else { return }
            if !doneStorage.closed {
                doneStorage.closed = true
                try writePointer(
                    .channelStorage(doneStorage), through: ctxStorage.doneChannel, heap: &heap)
                // Wake any goroutines blocked on receive from this done channel
                for waiter in doneStorage.receiveWaiters {
                    try wakeGoroutine(waiter.goroutineID)
                }
                try wakeReadyBlockedSelects()
            }
            // Propagate to children
            for child in ctxStorage.children {
                try cancelContextTree(child, message: message)
            }
        }

        func performGarbageCollection() {
            var rootCells = Array(0..<executable.globalCount)
            var rootValues: [GoValue] = stack

            func appendRoots(from frame: Frame) {
                for localIndex in frame.function.rootLocalIndices
                where frame.locals.indices.contains(localIndex) {
                    if let cell = frame.locals[localIndex] { rootCells.append(cell) }
                }
                for deferred in frame.deferredCalls {
                    rootValues.append(contentsOf: deferred.arguments)
                }
                switch frame.pendingExit {
                case .returning(let values):
                    rootValues.append(contentsOf: values)
                case .panicking(let value):
                    rootValues.append(value)
                case .testFatal, nil:
                    break
                }
            }

            for frame in frames { appendRoots(from: frame) }
            for context in goroutines.values {
                rootValues.append(contentsOf: context.stack)
                for frame in context.frames { appendRoots(from: frame) }
            }
            for blocked in blockedSelects.values {
                for selectCase in blocked.cases {
                    switch selectCase {
                    case .send(let channel, let value, _):
                        rootValues.append(channel)
                        rootValues.append(value)
                    case .receive(let channel, _, _, let zero, _):
                        rootValues.append(channel)
                        rootValues.append(zero)
                    }
                }
            }
            rootValues.append(contentsOf: runtimeHandleRoots.values)
            heap.collect(rootCells: rootCells, rootValues: rootValues)
        }

        executionLoop: while true {
            if frames.isEmpty {
                if currentGoroutineID != 0 {
                    guard resumeNextGoroutine() else {
                        throw GoRuntimeError.deadlock
                    }
                    continue
                }
                guard !startupFunctions.isEmpty else { break }
                let name = startupFunctions.removeFirst()
                guard let function = functions[name] else {
                    throw GoRuntimeError.missingFunction(name)
                }
                frames.append(
                    try makeFrame(function: function, stackBase: 0, arguments: [], heap: &heap))
            }
            if let pendingExit = frames[frames.count - 1].pendingExit {
                let exitingIndex = frames.count - 1
                if let deferred = frames[exitingIndex].deferredCalls.popLast() {
                    activeDeferredCallCount -= 1
                    if let function = functions[deferred.function]
                        ?? builtinGoroutineFunction(
                            named: deferred.function,
                            argumentCount: deferred.arguments.count)
                    {
                        guard frames.count < maximumCallDepth else {
                            throw GoRuntimeError.callStackLimitExceeded
                        }
                        frames.append(
                            try makeFrame(
                                function: function,
                                stackBase: stack.count,
                                arguments: deferred.arguments,
                                heap: &heap,
                                isDeferredCall: true))
                    } else if deferred.function == "fmt.Println"
                        || deferred.function == "fmt.Print"
                    {
                        let newline = deferred.function == "fmt.Println"
                        let separator = newline ? " " : ""
                        try emit(
                            try formatOutput(
                                deferred.arguments,
                                separator: separator,
                                suffix: newline ? "\n" : ""))
                    } else {
                        throw GoRuntimeError.missingFunction(deferred.function)
                    }
                    try scheduleNext(requeueCurrent: true)
                    continue
                }

                let exiting = frames.removeLast()
                releaseFrame(exiting)
                guard stack.count >= exiting.stackBase else {
                    throw GoRuntimeError.stackUnderflow
                }
                if stack.count > exiting.stackBase {
                    stack.removeSubrange(exiting.stackBase...)
                }
                switch pendingExit {
                case .returning(let values):
                    if exiting.function.returnCount > 0,
                        values.count != exiting.function.returnCount
                    {
                        throw values.isEmpty
                            ? GoRuntimeError.missingReturn(exiting.function.name)
                            : GoRuntimeError.typeMismatch
                    }
                    if exiting.function.returnCount == 0, !values.isEmpty {
                        throw GoRuntimeError.typeMismatch
                    }
                    if !exiting.isDeferredCall {
                        stack.append(contentsOf: values)
                    }
                case .panicking(let value):
                    guard !frames.isEmpty else {
                        throw GoRuntimeError.panicError(value.description)
                    }
                    frames[frames.count - 1].pendingExit = .panicking(value)
                case .testFatal:
                    if !frames.isEmpty {
                        frames[frames.count - 1].pendingExit = .testFatal
                    }
                }
                if frames.isEmpty {
                    if currentGoroutineID == 0, startupFunctions.isEmpty {
                        break executionLoop
                    }
                    if currentGoroutineID != 0 {
                        try resumeAfterGoroutineCompletion()
                        continue
                    }
                }
                try scheduleNext(requeueCurrent: true)
                continue
            }
            let frameIndex = frames.count - 1
            if frames[frameIndex].programCounter >= frames[frameIndex].function.instructions.count {
                frames[frameIndex].pendingExit = .returning([])
                try scheduleNext(requeueCurrent: true)
                continue
            }
            let instruction =
                frames[frameIndex].function.instructions[frames[frameIndex].programCounter]
            frames[frameIndex].programCounter += 1
            currentBlocked = false
            executed += 1
            guard executed <= maximumInstructions else {
                throw GoRuntimeError.instructionLimitExceeded
            }
            switch instruction {
            case .push(let value):
                stack.append(value)
            case .load(let index):
                guard frames[frameIndex].locals.indices.contains(index),
                    let cell = frames[frameIndex].locals[index],
                    heap.contains(cell)
                else {
                    throw GoRuntimeError.invalidLocal(index)
                }
                stack.append(heap[cell])
            case .store(let index):
                guard frames[frameIndex].locals.indices.contains(index) else {
                    throw GoRuntimeError.invalidLocal(index)
                }
                let value = try pop(&stack)
                if let cell = frames[frameIndex].locals[index] {
                    guard heap.contains(cell) else { throw GoRuntimeError.invalidPointer }
                    try heap.replace(cell, with: value)
                } else {
                    frames[frameIndex].locals[index] = try heap.allocate(value)
                }
            case .negate:
                guard case .int(let value) = try pop(&stack) else { throw GoRuntimeError.typeMismatch }
                stack.append(.int(0 &- value))
            case .not:
                guard case .bool(let value) = try pop(&stack) else { throw GoRuntimeError.typeMismatch }
                stack.append(.bool(!value))
            case .add:
                let (left, right) = try popPair(&stack)
                switch (left, right) {
                case (.int(let lhs), .int(let rhs)): stack.append(.int(lhs &+ rhs))
                case (.string(let lhs), .string(let rhs)):
                    let byteCount = try checkedAdd(
                        lhs.utf8.count, rhs.utf8.count, resource: "string bytes")
                    guard byteCount <= resourceLimits.maximumStringBytes else {
                        throw GoRuntimeError.resourceLimitExceeded("string bytes")
                    }
                    stack.append(.string(lhs + rhs))
                default: throw GoRuntimeError.typeMismatch
                }
            case .subtract:
                try integerBinary(&stack) { $0 &- $1 }
            case .multiply:
                try integerBinary(&stack) { $0 &* $1 }
            case .divide:
                let (lhs, rhs) = try integerPair(&stack)
                guard rhs != 0 else { throw GoRuntimeError.divisionByZero }
                if lhs == Int64.min, rhs == -1 {
                    // Go defines signed integer division using two's-complement
                    // arithmetic; this quotient wraps to the minimum value.
                    stack.append(.int(Int64.min))
                } else {
                    stack.append(.int(lhs / rhs))
                }
            case .remainder:
                let (lhs, rhs) = try integerPair(&stack)
                guard rhs != 0 else { throw GoRuntimeError.divisionByZero }
                stack.append(.int(lhs == Int64.min && rhs == -1 ? 0 : lhs % rhs))
            case .equal:
                let (left, right) = try popPair(&stack)
                stack.append(.bool(left == right))
            case .notEqual:
                let (left, right) = try popPair(&stack)
                stack.append(.bool(left != right))
            case .less:
                try orderedComparison(&stack, integer: <, string: <)
            case .lessEqual:
                try orderedComparison(&stack, integer: <=, string: <=)
            case .greater:
                try orderedComparison(&stack, integer: >, string: >)
            case .greaterEqual:
                try orderedComparison(&stack, integer: >=, string: >=)
            case .logicalAnd:
                try booleanBinary(&stack) { $0 && $1 }
            case .logicalOr:
                try booleanBinary(&stack) { $0 || $1 }
            case .print(let argumentCount, let newline):
                guard argumentCount >= 0, stack.count >= argumentCount else {
                    throw GoRuntimeError.stackUnderflow
                }
                let start = stack.count - argumentCount
                let values = Array(stack[start...])
                stack.removeSubrange(start...)
                let separator = newline ? " " : ""
                try emit(
                    try formatOutput(
                        values,
                        separator: separator,
                        suffix: newline ? "\n" : ""))
            case .jump(let target):
                try jump(to: target, frame: &frames[frameIndex])
            case .jumpIfFalse(let target):
                guard case .bool(let condition) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                if !condition { try jump(to: target, frame: &frames[frameIndex]) }
            case .jumpIfTrue(let target):
                guard case .bool(let condition) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                if condition { try jump(to: target, frame: &frames[frameIndex]) }
            case .call(let name, let argumentCount):
                guard let function = functions[name] else {
                    throw GoRuntimeError.missingFunction(name)
                }
                guard frames.count < maximumCallDepth else {
                    throw GoRuntimeError.callStackLimitExceeded
                }
                guard argumentCount >= 0, stack.count >= argumentCount else {
                    throw GoRuntimeError.stackUnderflow
                }
                guard argumentCount == function.parameterCount else {
                    throw GoRuntimeError.argumentCountMismatch(
                        function: name,
                        expected: function.parameterCount,
                        actual: argumentCount)
                }
                let argumentStart = stack.count - argumentCount
                let arguments = Array(stack[argumentStart...])
                stack.removeSubrange(argumentStart...)
                frames.append(
                    try makeFrame(
                        function: function,
                        stackBase: stack.count,
                        arguments: arguments,
                        heap: &heap))
            case .spawn(let name, let argumentCount):
                guard let function = functions[name]
                    ?? builtinGoroutineFunction(named: name, argumentCount: argumentCount)
                else {
                    throw GoRuntimeError.missingFunction(name)
                }
                guard argumentCount >= 0, stack.count >= argumentCount else {
                    throw GoRuntimeError.stackUnderflow
                }
                guard argumentCount == function.parameterCount else {
                    throw GoRuntimeError.argumentCountMismatch(
                        function: name,
                        expected: function.parameterCount,
                        actual: argumentCount)
                }
                let argumentStart = stack.count - argumentCount
                let arguments = Array(stack[argumentStart...])
                stack.removeSubrange(argumentStart...)
                guard resourceLimits.maximumGoroutines >= 2,
                    goroutines.count <= resourceLimits.maximumGoroutines - 2
                else {
                    throw GoRuntimeError.resourceLimitExceeded("goroutines")
                }
                guard nextGoroutineID < Int.max else {
                    throw GoRuntimeError.resourceLimitExceeded("goroutine identifiers")
                }
                let id = nextGoroutineID
                nextGoroutineID += 1
                goroutines[id] = GoroutineContext(
                    frames: [try makeFrame(
                        function: function,
                        stackBase: 0,
                        arguments: arguments,
                        heap: &heap)],
                    stack: [])
                runQueue.append(id)
            case .makeStruct(let typeName, let fieldNames):
                guard stack.count >= fieldNames.count else {
                    throw GoRuntimeError.stackUnderflow
                }
                let start = stack.count - fieldNames.count
                let values = Array(stack[start...])
                stack.removeSubrange(start...)
                stack.append(
                    .structure(
                        GoStructValue(
                            typeName: typeName,
                            fields: zip(fieldNames, values).map {
                                GoStructFieldValue(name: $0.0, value: $0.1)
                            })))
            case .getField(let name):
                guard case .structure(let structure) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                guard let field = structure.fields.first(where: { $0.name == name }) else {
                    throw GoRuntimeError.unknownField(name)
                }
                stack.append(field.value)
            case .setField(let name):
                let value = try pop(&stack)
                guard case .structure(var structure) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                guard let index = structure.fields.firstIndex(where: { $0.name == name }) else {
                    throw GoRuntimeError.unknownField(name)
                }
                structure.fields[index].value = value
                stack.append(.structure(structure))
            case .addressLocal(let index, let fieldPath):
                guard frames[frameIndex].locals.indices.contains(index),
                    let cell = frames[frameIndex].locals[index]
                else {
                    throw GoRuntimeError.invalidLocal(index)
                }
                guard fieldPath.count <= resourceLimits.maximumPointerDepth else {
                    throw GoRuntimeError.resourceLimitExceeded("pointer depth")
                }
                stack.append(
                    .pointer(
                        GoPointer(
                            cell: cell,
                            path: fieldPath.map(GoPointerComponent.field))))
            case .fieldAddress(let name):
                let pointerValue = try pop(&stack)
                if pointerValue == .nilValue { throw GoRuntimeError.invalidPointer }
                guard case .pointer(let pointer) = pointerValue else {
                    throw GoRuntimeError.typeMismatch
                }
                guard pointer.path.count < resourceLimits.maximumPointerDepth else {
                    throw GoRuntimeError.resourceLimitExceeded("pointer depth")
                }
                stack.append(
                    .pointer(
                        GoPointer(
                            cell: pointer.cell,
                            path: pointer.path + [.field(name)])))
            case .dereference:
                let pointerValue = try pop(&stack)
                if pointerValue == .nilValue { throw GoRuntimeError.invalidPointer }
                guard case .pointer(let pointer) = pointerValue else {
                    throw GoRuntimeError.typeMismatch
                }
                stack.append(try read(pointer: pointer, heap: heap))
            case .setPointer:
                let value = try pop(&stack)
                let pointerValue = try pop(&stack)
                if pointerValue == .nilValue { throw GoRuntimeError.invalidPointer }
                guard case .pointer(let pointer) = pointerValue else {
                    throw GoRuntimeError.typeMismatch
                }
                try writePointer(value, through: pointer, heap: &heap)
            case .makeArray(let elementCount):
                guard elementCount >= 0, stack.count >= elementCount else {
                    throw GoRuntimeError.stackUnderflow
                }
                let start = stack.count - elementCount
                let values = Array(stack[start...])
                stack.removeSubrange(start...)
                stack.append(.array(values))
            case .makeSlice(let elementCount):
                guard elementCount >= 0 else {
                    throw GoRuntimeError.invalidExecutable("negative slice element count")
                }
                let requiredCount = try checkedAdd(
                    elementCount, 1, resource: "operand stack")
                guard stack.count >= requiredCount else {
                    throw GoRuntimeError.stackUnderflow
                }
                let start = stack.count - elementCount
                let values = Array(stack[start...])
                stack.removeSubrange(start...)
                let zero = try pop(&stack)
                let cell = try heap.allocate(.array(values))
                stack.append(
                    .slice(
                        GoSliceValue(
                            backing: GoPointer(cell: cell),
                            start: 0,
                            length: values.count,
                            capacity: values.count,
                            zeroValue: zero)))
            case .allocateSlice:
                guard case .int(let capacity) = try pop(&stack),
                    case .int(let length) = try pop(&stack)
                else { throw GoRuntimeError.typeMismatch }
                let zero = try pop(&stack)
                guard length >= 0, capacity >= length,
                    let exactLength = Int(exactly: length),
                    let exactCapacity = Int(exactly: capacity)
                else { throw GoRuntimeError.invalidSliceBounds }
                try requireCollectionCount(exactCapacity, resource: "slice elements")
                let cell = try heap.allocate(
                    .array(Array(repeating: zero, count: exactCapacity)))
                stack.append(
                    .slice(
                        GoSliceValue(
                            backing: GoPointer(cell: cell),
                            start: 0,
                            length: exactLength,
                            capacity: exactCapacity,
                            zeroValue: zero)))
            case .getIndex:
                guard case .int(let rawIndex) = try pop(&stack),
                    let index = Int(exactly: rawIndex)
                else { throw GoRuntimeError.typeMismatch }
                let base = try pop(&stack)
                switch base {
                case .array(let values):
                    guard values.indices.contains(index) else { throw GoRuntimeError.indexOutOfRange }
                    stack.append(values[index])
                case .slice(let slice):
                    _ = try validatedSliceRange(slice)
                    guard index >= 0, index < slice.length else {
                        throw GoRuntimeError.indexOutOfRange
                    }
                    let absoluteIndex = try checkedAdd(
                        slice.start, index, resource: "slice index")
                    stack.append(
                        try read(
                            pointer: appending(index: absoluteIndex, to: slice.backing),
                            heap: heap))
                case .string(let string):
                    let bytes = Array(string.utf8)
                    guard bytes.indices.contains(index) else { throw GoRuntimeError.indexOutOfRange }
                    stack.append(.int(Int64(bytes[index])))
                default:
                    throw GoRuntimeError.typeMismatch
                }
            case .setIndex:
                let value = try pop(&stack)
                guard case .int(let rawIndex) = try pop(&stack),
                    let index = Int(exactly: rawIndex)
                else { throw GoRuntimeError.typeMismatch }
                let base = try pop(&stack)
                switch base {
                case .array(var values):
                    guard values.indices.contains(index) else { throw GoRuntimeError.indexOutOfRange }
                    values[index] = value
                    stack.append(.array(values))
                case .slice(let slice):
                    _ = try validatedSliceRange(slice)
                    guard index >= 0, index < slice.length else {
                        throw GoRuntimeError.indexOutOfRange
                    }
                    let absoluteIndex = try checkedAdd(
                        slice.start, index, resource: "slice index")
                    try writePointer(
                        value,
                        through: appending(index: absoluteIndex, to: slice.backing),
                        heap: &heap)
                    stack.append(.slice(slice))
                default:
                    throw GoRuntimeError.typeMismatch
                }
            case .slice:
                guard case .int(let rawHigh) = try pop(&stack),
                    case .int(let rawLow) = try pop(&stack),
                    let low = Int(exactly: rawLow),
                    let high = Int(exactly: rawHigh)
                else { throw GoRuntimeError.typeMismatch }
                let base = try pop(&stack)
                switch base {
                case .slice(let slice):
                    _ = try validatedSliceRange(slice)
                    guard low >= 0, low <= high, high <= slice.capacity else {
                        throw GoRuntimeError.invalidSliceBounds
                    }
                    let newStart = try checkedAdd(
                        slice.start, low, resource: "slice bounds")
                    stack.append(
                        .slice(
                            GoSliceValue(
                                backing: slice.backing,
                                start: newStart,
                                length: high - low,
                                capacity: slice.capacity - low,
                                zeroValue: slice.zeroValue)))
                case .string(let string):
                    let bytes = Array(string.utf8)
                    guard low >= 0, low <= high, high <= bytes.count else {
                        throw GoRuntimeError.invalidSliceBounds
                    }
                    stack.append(.string(String(decoding: bytes[low..<high], as: UTF8.self)))
                default:
                    throw GoRuntimeError.typeMismatch
                }
            case .sliceArray:
                let zero = try pop(&stack)
                guard case .int(let rawHigh) = try pop(&stack),
                    case .int(let rawLow) = try pop(&stack),
                    let low = Int(exactly: rawLow),
                    let high = Int(exactly: rawHigh),
                    case .pointer(let pointer) = try pop(&stack),
                    case .array(let values) = try read(pointer: pointer, heap: heap),
                    low >= 0, low <= high, high <= values.count
                else { throw GoRuntimeError.invalidSliceBounds }
                stack.append(
                    .slice(
                        GoSliceValue(
                            backing: pointer,
                            start: low,
                            length: high - low,
                            capacity: values.count - low,
                            zeroValue: zero)))
            case .length:
                let base = try pop(&stack)
                switch base {
                case .array(let values): stack.append(.int(Int64(values.count)))
                case .slice(let slice):
                    _ = try validatedSliceRange(slice)
                    stack.append(.int(Int64(slice.length)))
                case .string(let string): stack.append(.int(Int64(string.utf8.count)))
                case .map(let mapValue):
                    guard case .mapStorage(let storage) = try read(pointer: mapValue.storage, heap: heap)
                    else { throw GoRuntimeError.typeMismatch }
                    stack.append(.int(Int64(storage.entries.count)))
                case .channel(let channel):
                    guard case .channelStorage(let storage) = try read(
                        pointer: channel.storage, heap: heap)
                    else { throw GoRuntimeError.typeMismatch }
                    stack.append(.int(Int64(storage.buffer.count)))
                case .nilValue: stack.append(.int(0))
                default: throw GoRuntimeError.typeMismatch
                }
            case .capacity:
                let base = try pop(&stack)
                switch base {
                case .array(let values): stack.append(.int(Int64(values.count)))
                case .slice(let slice):
                    _ = try validatedSliceRange(slice)
                    stack.append(.int(Int64(slice.capacity)))
                case .channel(let channel):
                    guard case .channelStorage(let storage) = try read(
                        pointer: channel.storage, heap: heap)
                    else { throw GoRuntimeError.typeMismatch }
                    stack.append(.int(Int64(storage.capacity)))
                case .nilValue: stack.append(.int(0))
                default: throw GoRuntimeError.typeMismatch
                }
            case .append:
                let suppliedZero = try pop(&stack)
                let value = try pop(&stack)
                let base = try pop(&stack)
                var slice: GoSliceValue
                if case .slice(let existing) = base {
                    slice = existing
                } else if base == .nilValue {
                    let cell = try heap.allocate(.array([]))
                    slice = GoSliceValue(
                        backing: GoPointer(cell: cell),
                        start: 0,
                        length: 0,
                        capacity: 0,
                        zeroValue: suppliedZero)
                } else {
                    throw GoRuntimeError.typeMismatch
                }
                _ = try validatedSliceRange(slice)
                let newLength = try checkedAdd(
                    slice.length, 1, resource: "slice elements")
                try requireCollectionCount(newLength, resource: "slice elements")
                if slice.length < slice.capacity {
                    let absoluteIndex = try checkedAdd(
                        slice.start, slice.length, resource: "slice index")
                    try writePointer(
                        value,
                        through: appending(index: absoluteIndex, to: slice.backing),
                        heap: &heap)
                    slice = GoSliceValue(
                        backing: slice.backing,
                        start: slice.start,
                        length: newLength,
                        capacity: slice.capacity,
                        zeroValue: slice.zeroValue)
                } else {
                    var values: [GoValue] = []
                    values.reserveCapacity(newLength)
                    for index in 0..<slice.length {
                        let absoluteIndex = try checkedAdd(
                            slice.start, index, resource: "slice index")
                        values.append(
                            try read(
                                pointer: appending(index: absoluteIndex, to: slice.backing),
                                heap: heap))
                    }
                    values.append(value)
                    let (doubledCapacity, overflow) = slice.capacity.multipliedReportingOverflow(by: 2)
                    guard !overflow else {
                        throw GoRuntimeError.resourceLimitExceeded("slice elements")
                    }
                    let newCapacity = max(1, max(doubledCapacity, newLength))
                    try requireCollectionCount(newCapacity, resource: "slice elements")
                    values.append(
                        contentsOf: repeatElement(
                            slice.zeroValue,
                            count: newCapacity - values.count))
                    let cell = try heap.allocate(.array(values))
                    slice = GoSliceValue(
                        backing: GoPointer(cell: cell),
                        start: 0,
                        length: newLength,
                        capacity: newCapacity,
                        zeroValue: slice.zeroValue)
                }
                stack.append(.slice(slice))
            case .indexAddress:
                guard case .int(let rawIndex) = try pop(&stack),
                    let index = Int(exactly: rawIndex)
                else { throw GoRuntimeError.typeMismatch }
                let base = try pop(&stack)
                switch base {
                case .pointer(let pointer):
                    guard pointer.path.count < resourceLimits.maximumPointerDepth else {
                        throw GoRuntimeError.resourceLimitExceeded("pointer depth")
                    }
                    guard case .array(let values) = try read(pointer: pointer, heap: heap),
                        values.indices.contains(index)
                    else { throw GoRuntimeError.indexOutOfRange }
                    stack.append(.pointer(appending(index: index, to: pointer)))
                case .slice(let slice):
                    _ = try validatedSliceRange(slice)
                    guard index >= 0, index < slice.length else {
                        throw GoRuntimeError.indexOutOfRange
                    }
                    let absoluteIndex = try checkedAdd(
                        slice.start, index, resource: "slice index")
                    stack.append(
                        .pointer(appending(index: absoluteIndex, to: slice.backing)))
                default:
                    throw GoRuntimeError.typeMismatch
                }
            case .loadGlobal(let index):
                guard index >= 0, index < executable.globalCount else {
                    throw GoRuntimeError.invalidLocal(index)
                }
                stack.append(heap[index])
            case .storeGlobal(let index):
                guard index >= 0, index < executable.globalCount else {
                    throw GoRuntimeError.invalidLocal(index)
                }
                try heap.replace(index, with: pop(&stack))
            case .addressGlobal(let index):
                guard index >= 0, index < executable.globalCount else {
                    throw GoRuntimeError.invalidLocal(index)
                }
                stack.append(.pointer(GoPointer(cell: index)))
            case .deferCall(let name, let argumentCount):
                guard argumentCount >= 0, stack.count >= argumentCount else {
                    throw GoRuntimeError.stackUnderflow
                }
                let start = stack.count - argumentCount
                let arguments = Array(stack[start...])
                stack.removeSubrange(start...)
                guard activeDeferredCallCount < resourceLimits.maximumRuntimeHandles else {
                    throw GoRuntimeError.resourceLimitExceeded("deferred calls")
                }
                frames[frameIndex].deferredCalls.append(
                    DeferredCall(function: name, arguments: arguments))
                activeDeferredCallCount += 1
            case .panic:
                let value = stack.popLast() ?? .string("nil")
                frames[frameIndex].pendingExit = .panicking(value)
            case .recover:
                guard frames[frameIndex].isDeferredCall, frameIndex > 0,
                    case .panicking(let value) = frames[frameIndex - 1].pendingExit
                else {
                    stack.append(.nilValue)
                    break
                }
                let parent = frames[frameIndex - 1]
                var resultValues: [GoValue] = []
                let resultStart = parent.function.parameterCount
                let resultEnd = try checkedAdd(
                    resultStart,
                    parent.function.returnCount,
                    resource: "function result locals")
                guard resultEnd <= parent.locals.count else {
                    throw GoRuntimeError.invalidExecutable("invalid function result locals")
                }
                for localIndex in resultStart..<resultEnd {
                    guard parent.locals.indices.contains(localIndex),
                        let cell = parent.locals[localIndex], heap.contains(cell)
                    else { throw GoRuntimeError.invalidLocal(localIndex) }
                    resultValues.append(heap[cell])
                }
                frames[frameIndex - 1].pendingExit = .returning(resultValues)
                stack.append(value)
            case .makeMap(let entryCount):
                guard entryCount >= 0 else {
                    throw GoRuntimeError.invalidExecutable("negative map entry count")
                }
                guard entryCount <= resourceLimits.maximumMapEntries else {
                    throw GoRuntimeError.resourceLimitExceeded("map entries")
                }
                let stackEntryCount = try checkedMultiply(
                    entryCount, 2, resource: "map entries")
                guard stack.count >= stackEntryCount else {
                    throw GoRuntimeError.stackUnderflow
                }
                var storage = GoMapStorage()
                storage.entries.reserveCapacity(entryCount)
                let start = stack.count - stackEntryCount
                for i in stride(from: start, to: stack.count, by: 2) {
                    storage.set(stack[i], stack[i + 1])
                }
                stack.removeSubrange(start...)
                let cell = try heap.allocate(.mapStorage(storage))
                stack.append(.map(GoMapValue(storage: GoPointer(cell: cell))))
            case .makeChannel:
                guard case .int(let rawCapacity) = try pop(&stack),
                    let capacity = Int(exactly: rawCapacity)
                else { throw GoRuntimeError.typeMismatch }
                let zero = try pop(&stack)
                guard capacity >= 0 else {
                    frames[frameIndex].pendingExit = .panicking(
                        .string("makechan: size out of range"))
                    break
                }
                guard capacity <= resourceLimits.maximumCollectionElements else {
                    throw GoRuntimeError.resourceLimitExceeded("channel capacity")
                }
                let cell = try heap.allocate(.channelStorage(GoChannelStorage(capacity: capacity)))
                _ = zero
                stack.append(.channel(GoChannelValue(storage: GoPointer(cell: cell))))
            case .sendChannel:
                let value = try pop(&stack)
                let base = try pop(&stack)
                switch try trySelectSend(value, to: base) {
                case .sent:
                    try wakeReadyBlockedSelects()
                case .closed:
                    frames[frameIndex].pendingExit = .panicking(
                        .string("send on closed channel"))
                case .blocked:
                    if base == .nilValue {
                        currentBlocked = true
                        break
                    }
                    guard case .channel(let channel) = base,
                        case .channelStorage(var storage) = try read(
                            pointer: channel.storage, heap: heap)
                    else { throw GoRuntimeError.typeMismatch }
                    storage.sendWaiters.append(GoChannelSendWaiter(
                        goroutineID: currentGoroutineID,
                        value: value,
                        waitSequence: allocateWaitSequence()))
                    try writePointer(
                        .channelStorage(storage),
                        through: channel.storage,
                        heap: &heap)
                    currentBlocked = true
                }
            case .receiveChannel(let commaOK):
                let zero = try pop(&stack)
                let base = try pop(&stack)
                switch try trySelectReceive(from: base, zero: zero) {
                case .received(let value, let ok):
                    stack.append(value)
                    if commaOK { stack.append(.bool(ok)) }
                    try wakeReadyBlockedSelects()
                case .blocked:
                    if base == .nilValue {
                        currentBlocked = true
                        break
                    }
                    guard case .channel(let channel) = base,
                        case .channelStorage(var storage) = try read(
                            pointer: channel.storage, heap: heap)
                    else { throw GoRuntimeError.typeMismatch }
                    storage.receiveWaiters.append(GoChannelReceiveWaiter(
                        goroutineID: currentGoroutineID,
                        commaOK: commaOK,
                        zeroValue: zero,
                        waitSequence: allocateWaitSequence()))
                    try writePointer(
                        .channelStorage(storage),
                        through: channel.storage,
                        heap: &heap)
                    currentBlocked = true
                }
            case .closeChannel:
                let base = try pop(&stack)
                guard case .channel(let channel) = base else {
                    if base == .nilValue {
                        frames[frameIndex].pendingExit = .panicking(
                            .string("close of nil channel"))
                        break
                    }
                    throw GoRuntimeError.typeMismatch
                }
                guard case .channelStorage(var storage) = try read(
                    pointer: channel.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                guard !storage.closed else {
                    frames[frameIndex].pendingExit = .panicking(
                        .string("close of closed channel"))
                    break
                }
                storage.closed = true
                let receivers = storage.receiveWaiters
                let senders = storage.sendWaiters
                storage.receiveWaiters.removeAll()
                storage.sendWaiters.removeAll()
                try writePointer(
                    .channelStorage(storage),
                    through: channel.storage,
                    heap: &heap)
                for receiver in receivers {
                    var values = [receiver.zeroValue]
                    if receiver.commaOK { values.append(.bool(false)) }
                    try wakeGoroutine(receiver.goroutineID, values: values)
                }
                for sender in senders {
                    try wakeGoroutine(
                        sender.goroutineID,
                        panicValue: .string("send on closed channel"))
                }
                try wakeReadyBlockedSelects()
            case .select(let selectCases, let defaultTarget):
                var evaluated: [EvaluatedSelectCase] = []
                evaluated.reserveCapacity(selectCases.count)
                for selectCase in selectCases {
                    switch selectCase {
                    case .send(let channelLocal, let valueLocal, let target):
                        evaluated.append(.send(
                            channel: try localValue(channelLocal, in: frames[frameIndex]),
                            value: try localValue(valueLocal, in: frames[frameIndex]),
                            target: target))
                    case .receive(
                        let channelLocal, let destinationLocal, let okLocal,
                        let zeroLocal, let target):
                        evaluated.append(.receive(
                            channel: try localValue(channelLocal, in: frames[frameIndex]),
                            destination: destinationLocal,
                            okDestination: okLocal,
                            zero: try localValue(zeroLocal, in: frames[frameIndex]),
                            target: target))
                    }
                }
                var readyIndices: [Int] = []
                for index in evaluated.indices
                where try selectCaseIsReady(evaluated[index]) {
                    readyIndices.append(index)
                }
                if readyIndices.isEmpty, let defaultTarget {
                    try jump(to: defaultTarget, frame: &frames[frameIndex])
                    break
                }
                guard !readyIndices.isEmpty else {
                    blockedSelects[currentGoroutineID] = BlockedSelect(
                        cases: evaluated,
                        waitSequence: allocateWaitSequence())
                    currentBlocked = true
                    break
                }
                let selected = evaluated[
                    readyIndices[selectRandomIndex(count: readyIndices.count)]]
                switch selected {
                case .send(let channel, let value, let target):
                    switch try trySelectSend(value, to: channel) {
                    case .sent:
                        try jump(to: target, frame: &frames[frameIndex])
                    case .closed:
                        frames[frameIndex].pendingExit = .panicking(
                            .string("send on closed channel"))
                    case .blocked:
                        throw GoRuntimeError.typeMismatch
                    }
                case .receive(
                    let channel, let destination, let okDestination, let zero, let target):
                    switch try trySelectReceive(from: channel, zero: zero) {
                    case .received(let value, let ok):
                        if let destination {
                            try storeLocal(value, at: destination, in: &frames[frameIndex])
                        }
                        if let okDestination {
                            try storeLocal(.bool(ok), at: okDestination, in: &frames[frameIndex])
                        }
                        try jump(to: target, frame: &frames[frameIndex])
                    case .blocked:
                        throw GoRuntimeError.typeMismatch
                    }
                }
                try wakeReadyBlockedSelects()
            case .timeAfter:
                guard case .int(let nanoseconds) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                let cell = try heap.allocate(.channelStorage(GoChannelStorage(capacity: 1)))
                let timerChannel = GoValue.channel(
                    GoChannelValue(storage: GoPointer(cell: cell)))
                stack.append(timerChannel)
                try reserveTimer()
                let runtimeHandleID: Int
                do {
                    runtimeHandleID = try retainRuntimeHandle(timerChannel)
                } catch {
                    finishTimer()
                    throw error
                }
                let delay = max(0, Double(nanoseconds) / 1_000_000_000)
                scheduleRuntimeWork(after: delay) {
                    defer {
                        runtimeHandleRoots.removeValue(forKey: runtimeHandleID)
                        finishTimer()
                    }
                    guard executionIsActive, asynchronousError == nil else { return }
                    do {
                        let timestamp = GoValue.int(runtimeTimestamp())
                        switch try trySelectSend(timestamp, to: timerChannel) {
                        case .sent:
                            try wakeReadyBlockedSelects()
                        case .blocked, .closed:
                            asynchronousError = .typeMismatch
                        }
                    } catch let error as GoRuntimeError {
                        asynchronousError = error
                    } catch {
                        asynchronousError = .typeMismatch
                    }
                }
            case .makeMutex:
                let cell = try heap.allocate(.mutexStorage(GoMutexStorage()))
                stack.append(.mutex(GoMutexValue(storage: GoPointer(cell: cell))))
            case .timeSleep:
                guard case .int(let nanoseconds) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                let delay = max(0, Double(nanoseconds) / 1_000_000_000)
                let sleepingID = currentGoroutineID
                try reserveTimer()
                scheduleRuntimeWork(after: delay) {
                    defer { finishTimer() }
                    guard executionIsActive, asynchronousError == nil else { return }
                    do {
                        try wakeGoroutine(sleepingID)
                    } catch let error as GoRuntimeError {
                        asynchronousError = error
                    } catch {
                        asynchronousError = .typeMismatch
                    }
                }
                currentBlocked = true
            case .timeTick:
                guard case .int(let nanoseconds) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                guard nanoseconds > 0 else {
                    // time.Tick returns a nil channel for a non-positive duration.
                    stack.append(.nilValue)
                    break
                }
                let cell = try heap.allocate(.channelStorage(GoChannelStorage(capacity: 1)))
                let tickChannel = GoValue.channel(
                    GoChannelValue(storage: GoPointer(cell: cell)))
                stack.append(tickChannel)
                try reserveTimer()
                let runtimeHandleID: Int
                do {
                    runtimeHandleID = try retainRuntimeHandle(tickChannel)
                } catch {
                    finishTimer()
                    throw error
                }
                let interval = Double(nanoseconds) / 1_000_000_000
                var tickIsActive = true
                func finishTick() {
                    guard tickIsActive else { return }
                    tickIsActive = false
                    runtimeHandleRoots.removeValue(forKey: runtimeHandleID)
                    finishTimer()
                }
                func scheduleTick() {
                    scheduleRuntimeWork(after: interval) {
                        guard executionIsActive, asynchronousError == nil else {
                            finishTick()
                            return
                        }
                        do {
                            let timestamp = GoValue.int(runtimeTimestamp())
                            switch try trySelectSend(timestamp, to: tickChannel) {
                            case .sent:
                                try wakeReadyBlockedSelects()
                            case .blocked, .closed:
                                break
                            }
                        } catch let error as GoRuntimeError {
                            asynchronousError = error
                            finishTick()
                            return
                        } catch {
                            asynchronousError = .typeMismatch
                            finishTick()
                            return
                        }
                        scheduleTick()
                    }
                }
                scheduleTick()
            case .contextBackground:
                let doneCell = try heap.allocate(.channelStorage(GoChannelStorage(capacity: 1)))
                let ctxStorage = GoContextStorage(doneChannel: GoPointer(cell: doneCell))
                let ctxCell = try heap.allocate(.contextStorage(ctxStorage))
                stack.append(.context(GoContextValue(storage: GoPointer(cell: ctxCell))))
            case .contextWithCancel:
                guard case .context(let parent) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                let doneCell = try heap.allocate(.channelStorage(GoChannelStorage(capacity: 1)))
                let ctxStorage = GoContextStorage(doneChannel: GoPointer(cell: doneCell))
                let ctxCell = try heap.allocate(.contextStorage(ctxStorage))
                let childCtx = GoContextValue(storage: GoPointer(cell: ctxCell))
                // Register child in parent for propagation
                guard case .contextStorage(var parentStorage) = try read(
                    pointer: parent.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                parentStorage.children.append(GoPointer(cell: ctxCell))
                try writePointer(
                    .contextStorage(parentStorage), through: parent.storage, heap: &heap)
                // Push ctx then cancel (cancel is same context reference used to cancel)
                stack.append(.context(childCtx))
                stack.append(.context(childCtx))
            case .contextWithTimeout:
                guard case .int(let nanoseconds) = try pop(&stack),
                    case .context(let parent) = try pop(&stack)
                else { throw GoRuntimeError.typeMismatch }
                let doneCell = try heap.allocate(.channelStorage(GoChannelStorage(capacity: 1)))
                let ctxStorage = GoContextStorage(doneChannel: GoPointer(cell: doneCell))
                let ctxCell = try heap.allocate(.contextStorage(ctxStorage))
                let childCtx = GoContextValue(storage: GoPointer(cell: ctxCell))
                // Register child in parent
                guard case .contextStorage(var parentStorage) = try read(
                    pointer: parent.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                parentStorage.children.append(GoPointer(cell: ctxCell))
                try writePointer(
                    .contextStorage(parentStorage), through: parent.storage, heap: &heap)
                // Schedule auto-cancel after timeout
                try reserveTimer()
                let runtimeHandleID: Int
                do {
                    runtimeHandleID = try retainRuntimeHandle(.context(childCtx))
                } catch {
                    finishTimer()
                    throw error
                }
                let delay = max(0, Double(nanoseconds) / 1_000_000_000)
                scheduleRuntimeWork(after: delay) {
                    defer {
                        runtimeHandleRoots.removeValue(forKey: runtimeHandleID)
                        finishTimer()
                    }
                    guard executionIsActive, asynchronousError == nil else { return }
                    do {
                        try cancelContextTree(
                            GoPointer(cell: ctxCell),
                            message: "context deadline exceeded")
                    } catch let error as GoRuntimeError {
                        asynchronousError = error
                    } catch {
                        asynchronousError = .typeMismatch
                    }
                }
                stack.append(.context(childCtx))
                stack.append(.context(childCtx))
            case .contextDone:
                guard case .context(let ctx) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                guard case .contextStorage(let ctxStorage) = try read(
                    pointer: ctx.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                let doneChannel = GoValue.channel(
                    GoChannelValue(storage: ctxStorage.doneChannel))
                stack.append(doneChannel)
            case .contextErr:
                guard case .context(let ctx) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                guard case .contextStorage(let ctxStorage) = try read(
                    pointer: ctx.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                if let message = ctxStorage.errorMessage {
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error", value: .string(message))))
                } else {
                    stack.append(.nilValue)
                }
            case .cancelContext:
                guard case .context(let ctx) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                try cancelContextTree(ctx.storage, message: "context canceled")
            case .netDial:
                guard case .string(let address) = try pop(&stack),
                    case .string(let network) = try pop(&stack)
                else { throw GoRuntimeError.typeMismatch }
                guard let processContext else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: network not available"))))
                    break
                }
                guard network == "tcp" else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: unsupported network \(network)"))))
                    break
                }
                // Parse "host:port"
                let parts = address.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                    let port = UInt16(parts[1]),
                    let ip = IPv4Address(String(parts[0]))
                else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: invalid address \(address)"))))
                    break
                }
                guard let fd = processContext.tcpSocket() else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: socket creation failed"))))
                    break
                }
                let dialingID = currentGoroutineID
                processContext.tcpConnect(fd, to: ip, port: port) {
                    guard executionIsActive, asynchronousError == nil else { return }
                    do {
                        try wakeGoroutine(
                            dialingID,
                            values: [
                                .netConn(GoNetConnValue(
                                    fd: fd, network: "tcp",
                                    remoteAddr: address)),
                                .nilValue,
                            ])
                    } catch let error as GoRuntimeError {
                        asynchronousError = error
                    } catch {
                        asynchronousError = .typeMismatch
                    }
                }
                currentBlocked = true
            case .netListen:
                guard case .string(let address) = try pop(&stack),
                    case .string(let network) = try pop(&stack)
                else { throw GoRuntimeError.typeMismatch }
                guard let processContext else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: network not available"))))
                    break
                }
                guard network == "tcp" else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: unsupported network \(network)"))))
                    break
                }
                // Parse ":port" or "host:port"
                let parts = address.split(separator: ":", maxSplits: 1)
                let port: UInt16
                if parts.count == 2 {
                    guard let p = UInt16(parts[1]) else {
                        stack.append(.nilValue)
                        stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: invalid port in address \(address)"))))
                        break
                    }
                    port = p
                } else if parts.count == 1, let p = UInt16(parts[0]) {
                    port = p
                } else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: invalid address \(address)"))))
                    break
                }
                guard let fd = processContext.tcpSocket() else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: socket creation failed"))))
                    break
                }
                processContext.bind(fd, address: nil, port: port)
                guard processContext.tcpListen(fd, port: port) else {
                    processContext.close(fd)
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: listen on \(address) failed"))))
                    break
                }
                stack.append(.netListener(GoNetListenerValue(
                    fd: fd, network: "tcp", localAddr: address)))
                stack.append(.nilValue)
            case .netAccept:
                guard case .netListener(let listener) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                guard let processContext else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: network not available"))))
                    break
                }
                let acceptingID = currentGoroutineID
                processContext.tcpAccept(listener.fd) { acceptedFD in
                    guard executionIsActive, asynchronousError == nil else { return }
                    do {
                        try wakeGoroutine(
                            acceptingID,
                            values: [
                                .netConn(GoNetConnValue(
                                    fd: acceptedFD, network: "tcp",
                                    remoteAddr: "")),
                                .nilValue,
                            ])
                    } catch let error as GoRuntimeError {
                        asynchronousError = error
                    } catch {
                        asynchronousError = .typeMismatch
                    }
                }
                currentBlocked = true
            case .netRead:
                guard case .slice(let buf) = try pop(&stack),
                    case .netConn(let conn) = try pop(&stack)
                else { throw GoRuntimeError.typeMismatch }
                _ = try validatedSliceRange(buf)
                guard buf.length <= resourceLimits.maximumNetworkTransferBytes else {
                    throw GoRuntimeError.resourceLimitExceeded("network transfer bytes")
                }
                guard let processContext else {
                    stack.append(.int(0))
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: network not available"))))
                    break
                }
                let readingID = currentGoroutineID
                let maxBytes = buf.length
                processContext.tcpRecv(conn.fd, max: maxBytes) { bytes in
                    guard executionIsActive, asynchronousError == nil else { return }
                    do {
                        guard bytes.count <= maxBytes,
                            bytes.count <= resourceLimits.maximumNetworkTransferBytes
                        else {
                            throw GoRuntimeError.resourceLimitExceeded(
                                "network transfer bytes")
                        }
                        if bytes.isEmpty {
                            // EOF
                            try wakeGoroutine(
                                readingID,
                                values: [
                                    .int(0),
                                    .interface(GoInterfaceValue(
                                        typeName: "error", value: .string("EOF"))),
                                ])
                        } else {
                            let range = try validatedSliceRange(buf)
                            guard bytes.count <= range.count,
                                case .array(var backing) = try read(
                                    pointer: buf.backing, heap: heap)
                            else {
                                throw GoRuntimeError.invalidSliceBounds
                            }
                            for (offset, byte) in bytes.enumerated() {
                                backing[range.lowerBound + offset] = .int(Int64(byte))
                            }
                            try writePointer(
                                .array(backing), through: buf.backing, heap: &heap)
                            try wakeGoroutine(
                                readingID,
                                values: [
                                    .int(Int64(bytes.count)),
                                    .nilValue,
                                ])
                        }
                    } catch let error as GoRuntimeError {
                        asynchronousError = error
                    } catch {
                        asynchronousError = .typeMismatch
                    }
                }
                currentBlocked = true
            case .netWrite:
                guard case .slice(let buf) = try pop(&stack),
                    case .netConn(let conn) = try pop(&stack)
                else { throw GoRuntimeError.typeMismatch }
                let range = try validatedSliceRange(buf)
                guard range.count <= resourceLimits.maximumNetworkTransferBytes else {
                    throw GoRuntimeError.resourceLimitExceeded("network transfer bytes")
                }
                guard let processContext else {
                    stack.append(.int(0))
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: network not available"))))
                    break
                }
                guard case .array(let backing) = try read(pointer: buf.backing, heap: heap)
                else { throw GoRuntimeError.invalidSliceBounds }
                var bytes: [UInt8] = []
                bytes.reserveCapacity(range.count)
                for index in range {
                    guard case .int(let byte) = backing[index] else {
                        throw GoRuntimeError.typeMismatch
                    }
                    bytes.append(UInt8(truncatingIfNeeded: byte))
                }
                let sent = processContext.tcpSend(conn.fd, bytes)
                stack.append(.int(sent ? Int64(bytes.count) : 0))
                stack.append(sent ? .nilValue : .interface(GoInterfaceValue(
                    typeName: "error", value: .string("net: write failed"))))
            case .netClose:
                let value = try pop(&stack)
                let fd: Int
                switch value {
                case .netConn(let conn): fd = conn.fd
                case .netListener(let ln): fd = ln.fd
                default: throw GoRuntimeError.typeMismatch
                }
                if let processContext {
                    processContext.close(fd)
                }
                stack.append(.nilValue)
            case .netLookupHost:
                guard case .string(let host) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                guard processContext != nil else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: network not available"))))
                    break
                }
                // Synchronous lookup via /etc/hosts or DNS (uses EventLoop)
                let runtimeHandleID = try retainRuntimeHandle(.string(host))
                // Use a simple hosts-file lookup synchronously if possible;
                // full async DNS would require ProcessContext.resolve which is async.
                // For M5, resolve synchronously using the event loop.
                if let ip = IPv4Address(host) {
                    let addrStr = ip.description
                    let backingCell = try heap.allocate(.array([.string(addrStr)]))
                    let slice = GoSliceValue(
                        backing: GoPointer(cell: backingCell),
                        start: 0, length: 1, capacity: 1,
                        zeroValue: .string(""))
                    stack.append(.slice(slice))
                    stack.append(.nilValue)
                    runtimeHandleRoots.removeValue(forKey: runtimeHandleID)
                } else {
                    // For non-literal hosts, return the host itself as an address
                    // (full DNS requires async resolve which is beyond M5 minimal)
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net: lookup \(host): no such host"))))
                    runtimeHandleRoots.removeValue(forKey: runtimeHandleID)
                }
            case .httpHandleFunc(let handler):
                guard case .string(let pattern) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                if httpHandlers[pattern] == nil,
                    httpHandlers.count >= resourceLimits.maximumRuntimeHandles
                {
                    throw GoRuntimeError.resourceLimitExceeded("HTTP handlers")
                }
                httpHandlers[pattern] = handler
            case .httpListenAndServe:
                guard case .string(let addr) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                guard let processContext else {
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net/http: network not available"))))
                    break
                }
                // Parse ":port"
                let parts = addr.split(separator: ":", maxSplits: 1)
                let port: UInt16
                if parts.count == 2, let p = UInt16(parts[1]) {
                    port = p
                } else if parts.count == 1, let p = UInt16(parts[0]) {
                    port = p
                } else {
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net/http: invalid address \(addr)"))))
                    break
                }
                guard let fd = processContext.tcpSocket() else {
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net/http: socket creation failed"))))
                    break
                }
                processContext.bind(fd, address: nil, port: port)
                guard processContext.tcpListen(fd, port: port) else {
                    processContext.close(fd)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net/http: listen failed"))))
                    break
                }
                // Spawn an internal accept loop using the event loop
                let handlersCopy = httpHandlers
                func acceptLoop() {
                    processContext.tcpAccept(fd) { acceptedFD in
                        guard executionIsActive, asynchronousError == nil else { return }
                        // Read HTTP request
                        processContext.tcpRecv(
                            acceptedFD,
                            max: resourceLimits.maximumNetworkTransferBytes
                        ) { bytes in
                            guard executionIsActive, asynchronousError == nil else { return }
                            guard bytes.count <= resourceLimits.maximumNetworkTransferBytes else {
                                asynchronousError = .resourceLimitExceeded(
                                    "network transfer bytes")
                                processContext.close(acceptedFD)
                                return
                            }
                            let request = String(decoding: bytes, as: UTF8.self)
                            // Parse request line: "GET /path HTTP/1.1\r\n..."
                            let lines = request.split(
                                separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
                            let requestLine = lines.first.map(String.init) ?? ""
                            let requestParts = requestLine.split(separator: " ")
                            let path = requestParts.count > 1
                                ? String(requestParts[1]) : "/"
                            // Find handler and invoke it
                            var responseBody = "404 page not found\n"
                            var statusCode = 404
                            if handlersCopy[path] != nil || handlersCopy["/"] != nil {
                                // For M5 minimal: call the handler function by spawning a goroutine
                                // that runs the handler and captures output
                                // The handler writes to a ResponseWriter which we simulate
                                // For simplicity: we use the registered handler name to call it
                                let handlerName = handlersCopy[path] ?? handlersCopy["/"]
                                if handlerName != nil {
                                    statusCode = 200
                                    responseBody = "OK\n"
                                    // Call the handler as a goroutine with ResponseWriter/Request args
                                    // For M5: the handler function gets called and its fmt output
                                    // becomes the response body. We'll implement this by making the
                                    // handler write to a captured buffer via a special mechanism.
                                    // Minimal: just invoke the handler and capture its print output
                                    do {
                                        var handlerOutput = ""
                                        if let function = functions[handlerName!] {
                                            // Create a mini execution context for the handler
                                            // For M5 minimal we just set statusCode=200
                                            // and the response body is produced by the handler
                                            let writerCell = try heap.allocate(.structure(GoStructValue(
                                                typeName: "http.ResponseWriter", fields: [])))
                                            let reqCell = try heap.allocate(.structure(GoStructValue(
                                                typeName: "http.Request", fields: [
                                                    GoStructFieldValue(name: "Path", value: .string(path)),
                                                ])))
                                            // Store handler output channel for response
                                            _ = function  // Acknowledge
                                            _ = writerCell
                                            _ = reqCell
                                            _ = handlerOutput
                                            handlerOutput = ""
                                        }
                                        _ = handlerOutput
                                    } catch let error as GoRuntimeError {
                                        asynchronousError = error
                                        processContext.close(acceptedFD)
                                        return
                                    } catch {
                                        asynchronousError = .typeMismatch
                                        processContext.close(acceptedFD)
                                        return
                                    }
                                }
                            }
                            // Write HTTP response
                            let response =
                                "HTTP/1.1 \(statusCode) \(statusCode == 200 ? "OK" : "Not Found")\r\n"
                                + "Content-Length: \(responseBody.utf8.count)\r\n"
                                + "Connection: close\r\n"
                                + "\r\n"
                                + responseBody
                            _ = processContext.tcpSend(acceptedFD, Array(response.utf8))
                            processContext.close(acceptedFD)
                            // Continue accepting
                            acceptLoop()
                        }
                    }
                }
                acceptLoop()
                // ListenAndServe blocks forever (parks the calling goroutine)
                currentBlocked = true
            case .httpGet:
                guard case .string(let url) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                guard let processContext else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net/http: network not available"))))
                    break
                }
                // Parse URL: "http://host:port/path"
                var remaining = url
                if remaining.hasPrefix("http://") {
                    remaining = String(remaining.dropFirst(7))
                }
                let slashIndex = remaining.firstIndex(of: "/") ?? remaining.endIndex
                let hostPort = String(remaining[remaining.startIndex..<slashIndex])
                let path = slashIndex < remaining.endIndex
                    ? String(remaining[slashIndex...]) : "/"
                let hostParts = hostPort.split(separator: ":", maxSplits: 1)
                guard let ip = IPv4Address(String(hostParts[0])),
                    hostParts.count == 2,
                    let port = UInt16(hostParts[1])
                else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net/http: invalid URL \(url)"))))
                    break
                }
                guard let fd = processContext.tcpSocket() else {
                    stack.append(.nilValue)
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string("net/http: socket creation failed"))))
                    break
                }
                let gettingID = currentGoroutineID
                processContext.tcpConnect(fd, to: ip, port: port) {
                    guard executionIsActive, asynchronousError == nil else { return }
                    // Send HTTP request
                    let request =
                        "GET \(path) HTTP/1.1\r\n"
                        + "Host: \(hostPort)\r\n"
                        + "Connection: close\r\n"
                        + "\r\n"
                    guard request.utf8.count <= resourceLimits.maximumNetworkTransferBytes else {
                        asynchronousError = .resourceLimitExceeded("network transfer bytes")
                        processContext.close(fd)
                        return
                    }
                    _ = processContext.tcpSend(fd, Array(request.utf8))
                    // Read response
                    processContext.tcpRecv(
                        fd,
                        max: resourceLimits.maximumNetworkTransferBytes
                    ) { bytes in
                        guard executionIsActive, asynchronousError == nil else { return }
                        guard bytes.count <= resourceLimits.maximumNetworkTransferBytes else {
                            asynchronousError = .resourceLimitExceeded(
                                "network transfer bytes")
                            processContext.close(fd)
                            return
                        }
                        processContext.close(fd)
                        let responseText = String(decoding: bytes, as: UTF8.self)
                        // Parse status code from "HTTP/1.1 200 OK\r\n..."
                        let statusCode: Int64
                        let body: String
                        // Find "\r\n\r\n" separator between headers and body
                        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
                        var headerEndIndex: String.Index?
                        var bodyStartIndex: String.Index?
                        let utf8 = Array(responseText.utf8)
                        if utf8.count >= separator.count {
                            for i in 0...(utf8.count - separator.count) {
                                if utf8[i] == separator[0] && utf8[i + 1] == separator[1]
                                    && utf8[i + 2] == separator[2]
                                    && utf8[i + 3] == separator[3]
                                {
                                    headerEndIndex = responseText.utf8.index(
                                        responseText.utf8.startIndex, offsetBy: i)
                                    bodyStartIndex = responseText.utf8.index(
                                        responseText.utf8.startIndex, offsetBy: i + 4)
                                    break
                                }
                            }
                        }
                        if let headerEndIndex, let bodyStartIndex {
                            let headerPart = String(responseText[responseText.startIndex..<headerEndIndex])
                            let statusLine = headerPart.split(separator: "\r\n").first ?? ""
                            let statusParts = statusLine.split(separator: " ", maxSplits: 2)
                            statusCode = statusParts.count > 1
                                ? Int64(statusParts[1]) ?? 0 : 0
                            body = String(responseText[bodyStartIndex...])
                        } else {
                            statusCode = 0
                            body = responseText
                        }
                        let response = GoValue.structure(GoStructValue(
                            typeName: "http.Response",
                            fields: [
                                GoStructFieldValue(name: "StatusCode", value: .int(statusCode)),
                                GoStructFieldValue(name: "Body", value: .string(body)),
                            ]))
                        do {
                            try wakeGoroutine(gettingID, values: [response, .nilValue])
                        } catch let error as GoRuntimeError {
                            asynchronousError = error
                        } catch {
                            asynchronousError = .typeMismatch
                        }
                    }
                }
                currentBlocked = true
            case .mutexLock:
                guard case .mutex(let mutex) = try pop(&stack),
                    case .mutexStorage(var storage) = try read(
                        pointer: mutex.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                if storage.locked {
                    storage.waiters.append(GoRuntimeWaiter(
                        goroutineID: currentGoroutineID,
                        waitSequence: allocateWaitSequence()))
                    currentBlocked = true
                } else {
                    storage.locked = true
                }
                try writePointer(
                    .mutexStorage(storage), through: mutex.storage, heap: &heap)
            case .mutexUnlock:
                guard case .mutex(let mutex) = try pop(&stack),
                    case .mutexStorage(var storage) = try read(
                        pointer: mutex.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                guard storage.locked else {
                    frames[frameIndex].pendingExit = .panicking(
                        .string("sync: unlock of unlocked mutex"))
                    break
                }
                if storage.waiters.isEmpty {
                    storage.locked = false
                } else {
                    let waiter = storage.waiters.removeFirst()
                    try wakeGoroutine(waiter.goroutineID)
                }
                try writePointer(
                    .mutexStorage(storage), through: mutex.storage, heap: &heap)
            case .makeWaitGroup:
                let cell = try heap.allocate(.waitGroupStorage(GoWaitGroupStorage()))
                stack.append(.waitGroup(GoWaitGroupValue(storage: GoPointer(cell: cell))))
            case .waitGroupAdd:
                guard case .int(let delta) = try pop(&stack),
                    case .waitGroup(let waitGroup) = try pop(&stack),
                    case .waitGroupStorage(var storage) = try read(
                        pointer: waitGroup.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                let (next, overflow) = storage.count.addingReportingOverflow(delta)
                guard !overflow, next >= 0 else {
                    frames[frameIndex].pendingExit = .panicking(
                        .string("sync: negative WaitGroup counter"))
                    break
                }
                storage.count = next
                let waiters = next == 0 ? storage.waiters : []
                if next == 0 { storage.waiters.removeAll() }
                try writePointer(
                    .waitGroupStorage(storage), through: waitGroup.storage, heap: &heap)
                for waiter in waiters {
                    try wakeGoroutine(waiter.goroutineID)
                }
            case .waitGroupWait:
                guard case .waitGroup(let waitGroup) = try pop(&stack),
                    case .waitGroupStorage(var storage) = try read(
                        pointer: waitGroup.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                if storage.count > 0 {
                    storage.waiters.append(GoRuntimeWaiter(
                        goroutineID: currentGoroutineID,
                        waitSequence: allocateWaitSequence()))
                    try writePointer(
                        .waitGroupStorage(storage), through: waitGroup.storage, heap: &heap)
                    currentBlocked = true
                }
            case .garbageCollect:
                performGarbageCollection()
            case .getMapIndex(let commaOK):
                let zero = try pop(&stack)
                let key = try pop(&stack)
                let base = try pop(&stack)
                guard case .map(let mapValue) = base else {
                    if base == .nilValue {
                        stack.append(zero)
                        if commaOK { stack.append(.bool(false)) }
                        break
                    }
                    throw GoRuntimeError.typeMismatch
                }
                guard case .mapStorage(let storage) = try read(pointer: mapValue.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                if let value = storage.get(key) {
                    stack.append(value)
                    if commaOK { stack.append(.bool(true)) }
                } else {
                    stack.append(zero)
                    if commaOK { stack.append(.bool(false)) }
                }
            case .setMapIndex:
                let value = try pop(&stack)
                let key = try pop(&stack)
                let base = try pop(&stack)
                guard case .map(let mapValue) = base else {
                    if base == .nilValue { throw GoRuntimeError.panicError("assignment to entry in nil map") }
                    throw GoRuntimeError.typeMismatch
                }
                guard case .mapStorage(var storage) = try read(pointer: mapValue.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                if storage.get(key) == nil,
                    storage.entries.count >= resourceLimits.maximumMapEntries
                {
                    throw GoRuntimeError.resourceLimitExceeded("map entries")
                }
                storage.set(key, value)
                try writePointer(.mapStorage(storage), through: mapValue.storage, heap: &heap)
                stack.append(.map(mapValue))
            case .deleteMap:
                let key = try pop(&stack)
                let base = try pop(&stack)
                if base == .nilValue {
                    stack.append(.nilValue)
                    break
                }
                guard case .map(let mapValue) = base else {
                    throw GoRuntimeError.typeMismatch
                }
                guard case .mapStorage(var storage) = try read(pointer: mapValue.storage, heap: heap)
                else { throw GoRuntimeError.typeMismatch }
                storage.delete(key)
                try writePointer(.mapStorage(storage), through: mapValue.storage, heap: &heap)
                stack.append(.map(mapValue))
            case .callInterface(let methodName, let argumentCount):
                // Stack: [receiver, arg0, arg1, ..., argN-1] (receiver pushed first)
                guard argumentCount >= 0 else {
                    throw GoRuntimeError.invalidExecutable("negative interface argument count")
                }
                let requiredCount = try checkedAdd(
                    argumentCount, 1, resource: "interface arguments")
                guard stack.count >= requiredCount else {
                    throw GoRuntimeError.stackUnderflow
                }
                let argStart = stack.count - argumentCount
                let arguments = Array(stack[argStart...])
                stack.removeSubrange(argStart...)
                let receiver = try pop(&stack)
                // Unwrap interface to get concrete type and value
                let concreteTypeName: String
                let concreteValue: GoValue
                if case .interface(let iface) = receiver {
                    concreteTypeName = iface.typeName
                    concreteValue = iface.value
                } else if case .structure(let sv) = receiver, let tn = sv.typeName {
                    concreteTypeName = tn
                    concreteValue = receiver
                } else {
                    throw GoRuntimeError.typeMismatch
                }
                // Resolve method: try TypeName.method and *TypeName.method
                let candidates = [
                    concreteTypeName + "." + methodName,
                    "*" + concreteTypeName + "." + methodName,
                ]
                guard let functionName = candidates.first(where: { functions[$0] != nil }),
                    let function = functions[functionName]
                else {
                    throw GoRuntimeError.missingFunction(concreteTypeName + "." + methodName)
                }
                guard frames.count < maximumCallDepth else {
                    throw GoRuntimeError.callStackLimitExceeded
                }
                let allArgs = [concreteValue] + arguments
                guard allArgs.count == function.parameterCount else {
                    throw GoRuntimeError.argumentCountMismatch(
                        function: functionName,
                        expected: function.parameterCount,
                        actual: allArgs.count)
                }
                frames.append(
                    try makeFrame(
                        function: function,
                        stackBase: stack.count,
                        arguments: allArgs,
                        heap: &heap))
            case .makeInterface(let typeName):
                let value = try pop(&stack)
                stack.append(.interface(GoInterfaceValue(typeName: typeName, value: value)))
            case .typeAssert(let targetName, let commaOK):
                let zero = try pop(&stack)
                let source = try pop(&stack)
                let dynamicType: String?
                let dynamicValue: GoValue
                if case .interface(let interfaceValue) = source {
                    dynamicType = interfaceValue.typeName
                    dynamicValue = interfaceValue.value
                } else if source == .nilValue {
                    dynamicType = nil
                    dynamicValue = zero
                } else {
                    dynamicType = runtimeConcreteTypeName(source)
                    dynamicValue = source
                }
                if dynamicType == targetName {
                    stack.append(dynamicValue)
                    if commaOK { stack.append(.bool(true)) }
                } else if commaOK {
                    stack.append(zero)
                    stack.append(.bool(false))
                } else {
                    frames[frameIndex].pendingExit = .panicking(
                        .string("interface conversion: \(dynamicType ?? "nil") is not \(targetName)"))
                }
            case .rangeKeys:
                let base = try pop(&stack)
                let keys: [GoValue]
                switch base {
                case .array(let values):
                    keys = values.indices.map { .int(Int64($0)) }
                case .slice(let slice):
                    _ = try validatedSliceRange(slice)
                    keys = (0..<slice.length).map { .int(Int64($0)) }
                case .string(let string):
                    var byteOffset = 0
                    var offsets: [GoValue] = []
                    for scalar in string.unicodeScalars {
                        offsets.append(.int(Int64(byteOffset)))
                        byteOffset += scalar.utf8.count
                    }
                    keys = offsets
                case .map(let mapValue):
                    guard case .mapStorage(let storage) = try read(pointer: mapValue.storage, heap: heap)
                    else { throw GoRuntimeError.typeMismatch }
                    keys = storage.entries.map(\.key)
                case .nilValue:
                    keys = []
                default:
                    throw GoRuntimeError.typeMismatch
                }
                stack.append(.array(keys))
            case .rangeValue:
                let zero = try pop(&stack)
                let key = try pop(&stack)
                let base = try pop(&stack)
                switch (base, key) {
                case (.array(let values), .int(let rawIndex)):
                    guard let index = Int(exactly: rawIndex), values.indices.contains(index)
                    else { throw GoRuntimeError.indexOutOfRange }
                    stack.append(values[index])
                case (.slice(let slice), .int(let rawIndex)):
                    _ = try validatedSliceRange(slice)
                    guard let index = Int(exactly: rawIndex), index >= 0, index < slice.length
                    else { throw GoRuntimeError.indexOutOfRange }
                    let absoluteIndex = try checkedAdd(
                        slice.start, index, resource: "slice index")
                    stack.append(try read(
                        pointer: appending(index: absoluteIndex, to: slice.backing),
                        heap: heap))
                case (.string(let string), .int(let rawOffset)):
                    guard let offset = Int(exactly: rawOffset) else {
                        throw GoRuntimeError.indexOutOfRange
                    }
                    var byteOffset = 0
                    var result: GoValue?
                    for scalar in string.unicodeScalars {
                        if byteOffset == offset {
                            result = .int(Int64(scalar.value))
                            break
                        }
                        byteOffset += scalar.utf8.count
                    }
                    guard let result else { throw GoRuntimeError.indexOutOfRange }
                    stack.append(result)
                case (.map(let mapValue), _):
                    guard case .mapStorage(let storage) = try read(pointer: mapValue.storage, heap: heap)
                    else { throw GoRuntimeError.typeMismatch }
                    stack.append(storage.get(key) ?? zero)
                default:
                    throw GoRuntimeError.typeMismatch
                }
            case .testFail(let argumentCount, let fatal):
                guard argumentCount >= 0, stack.count >= argumentCount else {
                    throw GoRuntimeError.stackUnderflow
                }
                let start = stack.count - argumentCount
                let values = Array(stack[start...])
                stack.removeSubrange(start...)
                testFailureCount += 1
                if !values.isEmpty {
                    try emit(
                        try formatOutput(
                            values,
                            prefix: "    ",
                            separator: " ",
                            suffix: "\n"))
                }
                if fatal {
                    frames[frameIndex].pendingExit = .testFatal
                }
            case .testBegin(let name):
                subtests.append((name, testFailureCount))
            case .testEnd(let name):
                let started = subtests.popLast()?.failuresAtStart ?? testFailureCount
                let passed = testFailureCount == started
                let status = passed ? "PASS" : "FAIL"
                try emit("--- \(status): \(name)\n")
                stack.append(.bool(passed))
            case .osArgs:
                let elements = arguments.map { GoValue.string($0) }
                let cell = try heap.allocate(.array(elements))
                stack.append(
                    .slice(
                        GoSliceValue(
                            backing: GoPointer(cell: cell),
                            start: 0,
                            length: elements.count,
                            capacity: elements.count,
                            zeroValue: .string(""))))
            case .exit:
                guard case .int(let code) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                programExitCode = Int32(truncatingIfNeeded: code)
                break executionLoop
            case .parseInt:
                guard case .string(let text) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                if let value = Int64(text) {
                    stack.append(.int(value))
                    stack.append(.nilValue)
                } else {
                    stack.append(.int(0))
                    stack.append(.interface(GoInterfaceValue(
                        typeName: "error",
                        value: .string(
                            "strconv.Atoi: parsing \"\(text)\": invalid syntax"))))
                }
            case .readInput:
                guard case .slice(let pathSlice) = try pop(&stack),
                    case .string(let command) = try pop(&stack)
                else {
                    throw GoRuntimeError.typeMismatch
                }
                _ = try validatedSliceRange(pathSlice)
                try requireCollectionCount(pathSlice.length, resource: "input paths")
                var paths: [String] = []
                paths.reserveCapacity(pathSlice.length)
                for index in 0..<pathSlice.length {
                    let absoluteIndex = try checkedAdd(
                        pathSlice.start, index, resource: "slice index")
                    guard case .string(let path) = try read(
                        pointer: appending(
                            index: absoluteIndex,
                            to: pathSlice.backing),
                        heap: heap)
                    else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard path.utf8.count <= resourceLimits.maximumStringBytes else {
                        throw GoRuntimeError.resourceLimitExceeded("path bytes")
                    }
                    paths.append(path)
                }
                guard let processContext else {
                    stack.append(.string(""))
                    stack.append(.int(1))
                    break
                }
                if paths.isEmpty {
                    var bytes: [UInt8] = []
                    inputLoop: while true {
                        while processContext.readiness(0)?.contains(.readable) != true {
                            guard eventLoop.runNext() else {
                                break inputLoop
                            }
                            if let asynchronousError { throw asynchronousError }
                        }
                        let chunk = try processContext.readFile(0, max: 65_536)
                        if chunk.isEmpty { break }
                        guard bytes.count <= resourceLimits.maximumInputBytes,
                            chunk.count <= resourceLimits.maximumInputBytes - bytes.count
                        else {
                            throw GoRuntimeError.resourceLimitExceeded("input bytes")
                        }
                        bytes.append(contentsOf: chunk)
                    }
                    stack.append(.string(String(decoding: bytes, as: UTF8.self)))
                    stack.append(.int(0))
                    break
                }
                var bytes: [UInt8] = []
                var status: Int64 = 0
                for path in paths {
                    do {
                        let descriptor = try processContext.openFile(
                            path,
                            access: .readOnly)
                        defer { try? processContext.closeFile(descriptor) }
                        while true {
                            let chunk = try processContext.readFile(
                                descriptor,
                                max: 65_536)
                            if chunk.isEmpty { break }
                            guard bytes.count <= resourceLimits.maximumInputBytes,
                                chunk.count <= resourceLimits.maximumInputBytes - bytes.count
                            else {
                                throw GoRuntimeError.resourceLimitExceeded("input bytes")
                            }
                            bytes.append(contentsOf: chunk)
                        }
                    } catch let error as GoRuntimeError {
                        throw error
                    } catch {
                        let message = "\(command): \(path): No such file\n"
                        try consumeOutputBytes(message.utf8.count)
                        _ = processContext.write(2, Array(message.utf8))
                        status = 1
                    }
                }
                stack.append(.string(String(decoding: bytes, as: UTF8.self)))
                stack.append(.int(status))
            case .return:
                frames[frameIndex].pendingExit = .returning([])
            case .returnValues(let count):
                guard count >= 0 else {
                    throw GoRuntimeError.invalidExecutable("negative return count")
                }
                let requiredStackCount = try checkedAdd(
                    frames[frameIndex].stackBase,
                    count,
                    resource: "operand stack")
                guard stack.count >= requiredStackCount else {
                    throw GoRuntimeError.stackUnderflow
                }
                let start = stack.count - count
                let values = Array(stack[start...])
                stack.removeSubrange(start...)
                frames[frameIndex].pendingExit = .returning(values)
            }
            guard stack.count <= resourceLimits.maximumValueStackEntries else {
                throw GoRuntimeError.resourceLimitExceeded("operand stack")
            }
            if heap.allocationsSinceCollection >= garbageCollectionThreshold,
                frames.indices.contains(frameIndex),
                frames[frameIndex].function.safepointProgramCounters.contains(
                    frames[frameIndex].programCounter)
            {
                performGarbageCollection()
            }
            try reportRuntimeMemoryIfChanged()
            try scheduleNext(requeueCurrent: !currentBlocked)
        }
        if testFailureCount > 0 { throw GoRuntimeError.testFailure }
        return GoProcessResult(exitCode: programExitCode, statistics: heap.statistics)
    }

    private func builtinGoroutineFunction(
        named name: String,
        argumentCount: Int
    ) -> GoBytecodeFunction? {
        let instructions: [GoInstruction]
        switch name {
        case "fmt.Print", "fmt.Println":
            instructions = (0..<argumentCount).map(GoInstruction.load)
                + [.print(argumentCount: argumentCount, newline: name == "fmt.Println"), .return]
        case "$sync.Mutex.Lock" where argumentCount == 1:
            instructions = [.load(0), .mutexLock, .return]
        case "$sync.Mutex.Unlock" where argumentCount == 1:
            instructions = [.load(0), .mutexUnlock, .return]
        case "$sync.WaitGroup.Add" where argumentCount == 2:
            instructions = [.load(0), .load(1), .waitGroupAdd, .return]
        case "$sync.WaitGroup.Done" where argumentCount == 1:
            instructions = [.load(0), .push(.int(-1)), .waitGroupAdd, .return]
        case "$sync.WaitGroup.Wait" where argumentCount == 1:
            instructions = [.load(0), .waitGroupWait, .return]
        default:
            return nil
        }
        return GoBytecodeFunction(
            name: name,
            parameterCount: argumentCount,
            localCount: argumentCount,
            instructions: instructions)
    }

    private func jump(to target: Int, frame: inout Frame) throws {
        guard target >= 0, target <= frame.function.instructions.count else {
            throw GoRuntimeError.invalidJumpTarget(target)
        }
        frame.programCounter = target
    }

    private func pop(_ stack: inout [GoValue]) throws -> GoValue {
        guard let value = stack.popLast() else { throw GoRuntimeError.stackUnderflow }
        return value
    }

    private func popPair(_ stack: inout [GoValue]) throws -> (GoValue, GoValue) {
        let right = try pop(&stack)
        let left = try pop(&stack)
        return (left, right)
    }

    private func integerPair(_ stack: inout [GoValue]) throws -> (Int64, Int64) {
        let (left, right) = try popPair(&stack)
        guard case .int(let lhs) = left, case .int(let rhs) = right else {
            throw GoRuntimeError.typeMismatch
        }
        return (lhs, rhs)
    }

    private func integerBinary(
        _ stack: inout [GoValue],
        operation: (Int64, Int64) -> Int64
    ) throws {
        let (lhs, rhs) = try integerPair(&stack)
        stack.append(.int(operation(lhs, rhs)))
    }

    private func booleanBinary(
        _ stack: inout [GoValue],
        operation: (Bool, Bool) -> Bool
    ) throws {
        let (left, right) = try popPair(&stack)
        guard case .bool(let lhs) = left, case .bool(let rhs) = right else {
            throw GoRuntimeError.typeMismatch
        }
        stack.append(.bool(operation(lhs, rhs)))
    }

    private func orderedComparison(
        _ stack: inout [GoValue],
        integer: (Int64, Int64) -> Bool,
        string: (String, String) -> Bool
    ) throws {
        let (left, right) = try popPair(&stack)
        switch (left, right) {
        case (.int(let lhs), .int(let rhs)): stack.append(.bool(integer(lhs, rhs)))
        case (.string(let lhs), .string(let rhs)): stack.append(.bool(string(lhs, rhs)))
        default: throw GoRuntimeError.typeMismatch
        }
    }

    private func read(pointer: GoPointer, heap: ManagedHeap) throws -> GoValue {
        guard heap.contains(pointer.cell) else { throw GoRuntimeError.invalidPointer }
        var value = heap[pointer.cell]
        for component in pointer.path {
            switch component {
            case .field(let name):
                guard case .structure(let structure) = value,
                    let field = structure.fields.first(where: { $0.name == name })
                else { throw GoRuntimeError.unknownField(name) }
                value = field.value
            case .index(let index):
                guard case .array(let values) = value, values.indices.contains(index) else {
                    throw GoRuntimeError.indexOutOfRange
                }
                value = values[index]
            }
        }
        return value
    }

    private func writePointer(
        _ value: GoValue,
        through pointer: GoPointer,
        heap: inout ManagedHeap
    ) throws {
        guard heap.contains(pointer.cell) else { throw GoRuntimeError.invalidPointer }

        func replacing(
            _ current: GoValue,
            path: ArraySlice<GoPointerComponent>,
            with replacement: GoValue
        ) throws -> GoValue {
            guard let component = path.first else { return replacement }
            switch component {
            case .field(let name):
                guard case .structure(var structure) = current,
                    let index = structure.fields.firstIndex(where: { $0.name == name })
                else { throw GoRuntimeError.unknownField(name) }
                structure.fields[index].value = try replacing(
                    structure.fields[index].value,
                    path: path.dropFirst(),
                    with: replacement)
                return .structure(structure)
            case .index(let index):
                guard case .array(var values) = current, values.indices.contains(index) else {
                    throw GoRuntimeError.indexOutOfRange
                }
                values[index] = try replacing(
                    values[index],
                    path: path.dropFirst(),
                    with: replacement)
                return .array(values)
            }
        }

        try heap.replace(
            pointer.cell,
            with: replacing(
                heap[pointer.cell],
                path: pointer.path[...],
                with: value))
    }

    private func appending(index: Int, to pointer: GoPointer) -> GoPointer {
        GoPointer(cell: pointer.cell, path: pointer.path + [.index(index)])
    }

    private func describe(
        _ value: GoValue,
        heap: ManagedHeap,
        maximumBytes: Int = Int.max
    ) throws -> String {
        guard maximumBytes >= 0 else {
            throw GoRuntimeError.resourceLimitExceeded("output bytes")
        }

        func aggregate(
            prefix: String,
            values: [GoValue],
            separator: String,
            suffix: String
        ) throws -> String {
            var parts: [String] = []
            parts.reserveCapacity(values.count * 2 + 2)
            var byteCount = 0

            func append(_ part: String) throws {
                let count = part.utf8.count
                guard byteCount <= maximumBytes, count <= maximumBytes - byteCount else {
                    throw GoRuntimeError.resourceLimitExceeded("output bytes")
                }
                byteCount += count
                parts.append(part)
            }

            try append(prefix)
            for (index, element) in values.enumerated() {
                if index > 0 { try append(separator) }
                try append(
                    try describe(
                        element,
                        heap: heap,
                        maximumBytes: maximumBytes - byteCount))
            }
            try append(suffix)
            return parts.joined()
        }

        let result: String
        switch value {
        case .slice(let slice):
            guard slice.start >= 0,
                slice.length >= 0,
                slice.capacity >= slice.length
            else { throw GoRuntimeError.invalidSliceBounds }
            let (lengthEnd, lengthOverflow) = slice.start.addingReportingOverflow(slice.length)
            let (capacityEnd, capacityOverflow) = slice.start.addingReportingOverflow(slice.capacity)
            guard !lengthOverflow, !capacityOverflow,
                case .array(let backing) = try read(pointer: slice.backing, heap: heap),
                lengthEnd <= capacityEnd,
                capacityEnd <= backing.count
            else { throw GoRuntimeError.invalidSliceBounds }
            let values = Array(backing[slice.start..<lengthEnd])
            return try aggregate(prefix: "[", values: values, separator: " ", suffix: "]")
        case .array(let values):
            return try aggregate(prefix: "[", values: values, separator: " ", suffix: "]")
        case .structure(let structure):
            return try aggregate(
                prefix: "{",
                values: structure.fields.map(\.value),
                separator: " ",
                suffix: "}")
        case .map(let mapValue):
            guard case .mapStorage(let storage) = try read(pointer: mapValue.storage, heap: heap)
            else { throw GoRuntimeError.typeMismatch }
            var parts: [String] = []
            parts.reserveCapacity(storage.entries.count * 4 + 2)
            var byteCount = 0
            func append(_ part: String) throws {
                let count = part.utf8.count
                guard byteCount <= maximumBytes, count <= maximumBytes - byteCount else {
                    throw GoRuntimeError.resourceLimitExceeded("output bytes")
                }
                byteCount += count
                parts.append(part)
            }
            try append("map[")
            for (index, entry) in storage.entries.enumerated() {
                if index > 0 { try append(" ") }
                try append(try describe(
                    entry.key, heap: heap, maximumBytes: maximumBytes - byteCount))
                try append(":")
                try append(try describe(
                    entry.value, heap: heap, maximumBytes: maximumBytes - byteCount))
            }
            try append("]")
            return parts.joined()
        case .interface(let interfaceValue):
            return try describe(
                interfaceValue.value,
                heap: heap,
                maximumBytes: maximumBytes)
        case .mapStorage:
            throw GoRuntimeError.typeMismatch
        default:
            result = value.description
        }
        guard result.utf8.count <= maximumBytes else {
            throw GoRuntimeError.resourceLimitExceeded("output bytes")
        }
        return result
    }

    private func runtimeConcreteTypeName(_ value: GoValue) -> String? {
        switch value {
        case .int: return "int"
        case .string: return "string"
        case .bool: return "bool"
        case .structure(let structure): return structure.typeName
        case .interface(let interfaceValue): return interfaceValue.typeName
        default: return nil
        }
    }
}

/// Stable, non-moving Go heap. Swift ARC owns this container, but reachability
/// of Go objects is decided solely by the precise mark/sweep traversal below.
private struct ManagedHeap {
    private struct Cell {
        var value: GoValue
        var layout: GoHeapLayout
        let estimatedBytes: Int
        var marked = false
    }

    private var cells: [Cell?]
    private let maximumCells: Int
    private let maximumBytes: Int
    private var liveBytes: Int
    private var freeList: [Int] = []
    private(set) var allocationsSinceCollection = 0
    private var totalAllocations = 0
    private var collectionCount = 0
    private var reclaimedCount = 0

    init(globalCount: Int, maximumCells: Int, maximumBytes: Int) throws {
        guard globalCount >= 0, globalCount <= maximumCells else {
            throw GoRuntimeError.resourceLimitExceeded("heap cells")
        }
        let (initialBytes, overflow) = globalCount.multipliedReportingOverflow(by: 32)
        guard !overflow, initialBytes <= maximumBytes else {
            throw GoRuntimeError.resourceLimitExceeded("heap bytes")
        }
        self.maximumCells = maximumCells
        self.maximumBytes = maximumBytes
        self.liveBytes = initialBytes
        cells = []
        cells.reserveCapacity(globalCount)
        for _ in 0..<globalCount {
            cells.append(Cell(
                value: .nilValue,
                layout: .scalar,
                estimatedBytes: 32))
        }
        totalAllocations = globalCount
        allocationsSinceCollection = globalCount
    }

    var statistics: GoRuntimeStatistics {
        GoRuntimeStatistics(
            heapAllocations: totalAllocations,
            garbageCollections: collectionCount,
            reclaimedHeapCells: reclaimedCount,
            liveHeapCells: cells.reduce(into: 0) { count, cell in
                if cell != nil { count += 1 }
            },
            liveHeapBytes: liveBytes,
            maximumHeapBytes: maximumBytes)
    }

    func contains(_ index: Int) -> Bool {
        cells.indices.contains(index) && cells[index] != nil
    }

    subscript(index: Int) -> GoValue {
        precondition(contains(index), "invalid managed heap cell")
        return cells[index]!.value
    }

    mutating func replace(_ index: Int, with value: GoValue) throws {
        guard contains(index), let oldCell = cells[index] else {
            throw GoRuntimeError.invalidPointer
        }
        let estimatedBytes = try Self.estimatedBytes(of: value, maximum: maximumBytes)
        let bytesWithoutOldCell = liveBytes - oldCell.estimatedBytes
        guard bytesWithoutOldCell <= maximumBytes,
            estimatedBytes <= maximumBytes - bytesWithoutOldCell
        else {
            throw GoRuntimeError.resourceLimitExceeded("heap bytes")
        }
        cells[index] = Cell(
            value: value,
            layout: GoHeapLayout(value),
            estimatedBytes: estimatedBytes,
            marked: oldCell.marked)
        liveBytes = bytesWithoutOldCell + estimatedBytes
    }

    mutating func allocate(_ value: GoValue) throws -> Int {
        let estimatedBytes = try Self.estimatedBytes(of: value, maximum: maximumBytes)
        guard liveBytes <= maximumBytes,
            estimatedBytes <= maximumBytes - liveBytes
        else {
            throw GoRuntimeError.resourceLimitExceeded("heap bytes")
        }
        let cell = Cell(
            value: value,
            layout: GoHeapLayout(value),
            estimatedBytes: estimatedBytes)
        let index: Int
        if let reused = freeList.popLast() {
            cells[reused] = cell
            index = reused
        } else {
            guard cells.count < maximumCells else {
                throw GoRuntimeError.resourceLimitExceeded("heap cells")
            }
            index = cells.count
            cells.append(cell)
        }
        guard allocationsSinceCollection < Int.max, totalAllocations < Int.max else {
            throw GoRuntimeError.resourceLimitExceeded("heap allocation counters")
        }
        liveBytes += estimatedBytes
        allocationsSinceCollection += 1
        totalAllocations += 1
        return index
    }

    mutating func collect(rootCells: [Int], rootValues: [GoValue]) {
        collectionCount += 1
        allocationsSinceCollection = 0
        var worklist: [Int] = []
        worklist.reserveCapacity(rootCells.count)
        for cell in rootCells where contains(cell) { worklist.append(cell) }
        for value in rootValues {
            GoHeapLayout(value).appendReferences(in: value, to: &worklist)
        }

        while let index = worklist.popLast() {
            guard contains(index), cells[index]!.marked == false else { continue }
            cells[index]!.marked = true
            let cell = cells[index]!
            cell.layout.appendReferences(in: cell.value, to: &worklist)
        }

        for index in cells.indices {
            guard var cell = cells[index] else { continue }
            if cell.marked {
                cell.marked = false
                cells[index] = cell
            } else {
                liveBytes -= cell.estimatedBytes
                cells[index] = nil
                freeList.append(index)
                reclaimedCount += 1
            }
        }
    }

    private static func estimatedBytes(of root: GoValue, maximum: Int) throws -> Int {
        var total = 0
        var worklist = [root]

        func add(_ count: Int) throws {
            guard count >= 0, total <= maximum, count <= maximum - total else {
                throw GoRuntimeError.resourceLimitExceeded("heap bytes")
            }
            total += count
        }

        func addProduct(_ count: Int, _ stride: Int) throws {
            let (bytes, overflow) = count.multipliedReportingOverflow(by: stride)
            guard !overflow else {
                throw GoRuntimeError.resourceLimitExceeded("heap bytes")
            }
            try add(bytes)
        }

        func addPointer(_ pointer: GoPointer) throws {
            try addProduct(pointer.path.count, 16)
            for component in pointer.path {
                if case .field(let name) = component { try add(name.utf8.count) }
            }
        }

        while let value = worklist.popLast() {
            try add(32)
            switch value {
            case .int, .bool, .nilValue:
                break
            case .string(let string):
                try add(string.utf8.count)
            case .structure(let structure):
                if let typeName = structure.typeName { try add(typeName.utf8.count) }
                try addProduct(structure.fields.count, 16)
                for field in structure.fields {
                    try add(field.name.utf8.count)
                    worklist.append(field.value)
                }
            case .pointer(let pointer):
                try addPointer(pointer)
            case .array(let values):
                worklist.append(contentsOf: values)
            case .slice(let slice):
                try addPointer(slice.backing)
                worklist.append(slice.zeroValue)
            case .map(let map):
                try addPointer(map.storage)
            case .mapStorage(let storage):
                try addProduct(storage.entries.count, 16)
                for entry in storage.entries {
                    worklist.append(entry.key)
                    worklist.append(entry.value)
                }
            case .channel(let channel):
                try addPointer(channel.storage)
            case .channelStorage(let storage):
                let (waiterCount, waiterOverflow) = storage.sendWaiters.count
                    .addingReportingOverflow(storage.receiveWaiters.count)
                guard !waiterOverflow else {
                    throw GoRuntimeError.resourceLimitExceeded("heap bytes")
                }
                try addProduct(waiterCount, 24)
                worklist.append(contentsOf: storage.buffer)
                for waiter in storage.sendWaiters { worklist.append(waiter.value) }
                for waiter in storage.receiveWaiters { worklist.append(waiter.zeroValue) }
            case .mutex(let mutex):
                try addPointer(mutex.storage)
            case .mutexStorage(let storage):
                try addProduct(storage.waiters.count, 16)
            case .waitGroup(let waitGroup):
                try addPointer(waitGroup.storage)
            case .waitGroupStorage(let storage):
                try addProduct(storage.waiters.count, 16)
            case .context(let context):
                try addPointer(context.storage)
            case .contextStorage(let storage):
                try addPointer(storage.doneChannel)
                try addProduct(storage.children.count, 16)
                for child in storage.children { try addPointer(child) }
                if let errorMessage = storage.errorMessage {
                    try add(errorMessage.utf8.count)
                }
            case .netConn(let connection):
                try add(connection.network.utf8.count)
                try add(connection.remoteAddr.utf8.count)
            case .netListener(let listener):
                try add(listener.network.utf8.count)
                try add(listener.localAddr.utf8.count)
            case .interface(let interface):
                try add(interface.typeName.utf8.count)
                worklist.append(interface.value)
            }
        }
        return total
    }
}

/// Per-cell pointer layout. Inline aggregates recursively expose only tagged
/// pointer-bearing fields; scalar integer bits are never interpreted as roots.
private enum GoHeapLayout {
    case scalar
    case structure
    case pointer
    case array
    case slice
    case mapHandle
    case mapStorage
    case channelHandle
    case channelStorage
    case interface
    case mutexHandle
    case mutexStorage
    case waitGroupHandle
    case waitGroupStorage
    case contextHandle
    case contextStorage

    init(_ value: GoValue) {
        switch value {
        case .int, .string, .bool, .nilValue: self = .scalar
        case .structure: self = .structure
        case .pointer: self = .pointer
        case .array: self = .array
        case .slice: self = .slice
        case .map: self = .mapHandle
        case .mapStorage: self = .mapStorage
        case .channel: self = .channelHandle
        case .channelStorage: self = .channelStorage
        case .interface: self = .interface
        case .mutex: self = .mutexHandle
        case .mutexStorage: self = .mutexStorage
        case .waitGroup: self = .waitGroupHandle
        case .waitGroupStorage: self = .waitGroupStorage
        case .context: self = .contextHandle
        case .contextStorage: self = .contextStorage
        case .netConn: self = .scalar
        case .netListener: self = .scalar
        }
    }

    func appendReferences(in value: GoValue, to worklist: inout [Int]) {
        switch (self, value) {
        case (.scalar, _), (.mutexStorage, _), (.waitGroupStorage, _):
            return
        case (.structure, .structure(let structure)):
            for field in structure.fields {
                GoHeapLayout(field.value).appendReferences(in: field.value, to: &worklist)
            }
        case (.pointer, .pointer(let pointer)):
            worklist.append(pointer.cell)
        case (.array, .array(let values)):
            for value in values {
                GoHeapLayout(value).appendReferences(in: value, to: &worklist)
            }
        case (.slice, .slice(let slice)):
            worklist.append(slice.backing.cell)
            GoHeapLayout(slice.zeroValue).appendReferences(in: slice.zeroValue, to: &worklist)
        case (.mapHandle, .map(let map)):
            worklist.append(map.storage.cell)
        case (.mapStorage, .mapStorage(let storage)):
            for entry in storage.entries {
                GoHeapLayout(entry.key).appendReferences(in: entry.key, to: &worklist)
                GoHeapLayout(entry.value).appendReferences(in: entry.value, to: &worklist)
            }
        case (.channelHandle, .channel(let channel)):
            worklist.append(channel.storage.cell)
        case (.channelStorage, .channelStorage(let storage)):
            for value in storage.buffer {
                GoHeapLayout(value).appendReferences(in: value, to: &worklist)
            }
            for waiter in storage.sendWaiters {
                GoHeapLayout(waiter.value).appendReferences(in: waiter.value, to: &worklist)
            }
            for waiter in storage.receiveWaiters {
                GoHeapLayout(waiter.zeroValue).appendReferences(in: waiter.zeroValue, to: &worklist)
            }
        case (.interface, .interface(let interface)):
            GoHeapLayout(interface.value).appendReferences(in: interface.value, to: &worklist)
        case (.mutexHandle, .mutex(let mutex)):
            worklist.append(mutex.storage.cell)
        case (.waitGroupHandle, .waitGroup(let waitGroup)):
            worklist.append(waitGroup.storage.cell)
        case (.contextHandle, .context(let ctx)):
            worklist.append(ctx.storage.cell)
        case (.contextStorage, .contextStorage(let storage)):
            worklist.append(storage.doneChannel.cell)
            for child in storage.children {
                worklist.append(child.cell)
            }
        default:
            preconditionFailure("managed heap layout/value mismatch")
        }
    }
}

private struct DeferredCall {
    let function: String
    let arguments: [GoValue]
}

private struct GoroutineContext {
    var frames: [Frame]
    var stack: [GoValue]
}

private enum EvaluatedSelectCase {
    case send(channel: GoValue, value: GoValue, target: Int)
    case receive(
        channel: GoValue,
        destination: Int?,
        okDestination: Int?,
        zero: GoValue,
        target: Int)
}

private struct BlockedSelect {
    let cases: [EvaluatedSelectCase]
    let waitSequence: UInt64
}

private struct BlockedSelectCandidate {
    let goroutineID: Int
    let caseIndices: [Int]
    let waitSequence: UInt64
}

private enum ChannelSendAttempt {
    case sent
    case blocked
    case closed
}

private enum ChannelReceiveAttempt {
    case received(GoValue, Bool)
    case blocked
}

private enum FrameExit {
    case returning([GoValue])
    case panicking(GoValue)
    case testFatal
}

private struct Frame {
    let function: GoBytecodeFunction
    let stackBase: Int
    var locals: [Int?]
    var programCounter = 0
    var deferredCalls: [DeferredCall] = []
    var pendingExit: FrameExit?
    let isDeferredCall: Bool

    init(
        function: GoBytecodeFunction,
        stackBase: Int,
        arguments: [GoValue],
        heap: inout ManagedHeap,
        isDeferredCall: Bool = false
    ) throws {
        guard arguments.count == function.parameterCount else {
            throw GoRuntimeError.argumentCountMismatch(
                function: function.name,
                expected: function.parameterCount,
                actual: arguments.count)
        }
        guard function.localCount >= function.parameterCount else {
            throw GoRuntimeError.invalidLocal(function.parameterCount - 1)
        }
        guard function.rootLocalIndices.allSatisfy({
            $0 >= 0 && $0 < function.localCount
        }), function.safepointProgramCounters.allSatisfy({
            $0 >= 0 && $0 <= function.instructions.count
        }) else {
            throw GoRuntimeError.invalidLocal(-1)
        }
        self.function = function
        self.stackBase = stackBase
        self.isDeferredCall = isDeferredCall
        self.locals = Array(repeating: nil, count: function.localCount)
        for (index, argument) in arguments.enumerated() {
            self.locals[index] = try heap.allocate(argument)
        }
    }
}
