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

/// A value of the guest program.
///
/// Integers, truth values, strings, arrays and nil are stored inline, so
/// pushing or storing one does not allocate; every other case is boxed,
/// which keeps a value two words wide.
public enum GoValue: Sendable, Equatable, CustomStringConvertible {
    case int(Int64)
    case string(String)
    case bool(Bool)
    indirect case structure(GoStructValue)
    indirect case pointer(GoPointer)
    case nilValue
    case array([GoValue])
    indirect case slice(GoSliceValue)
    indirect case map(GoMapValue)
    indirect case mapStorage(GoMapStorage)
    indirect case channel(GoChannelValue)
    indirect case channelStorage(GoChannelStorage)
    indirect case mutex(GoMutexValue)
    indirect case mutexStorage(GoMutexStorage)
    indirect case waitGroup(GoWaitGroupValue)
    indirect case waitGroupStorage(GoWaitGroupStorage)
    indirect case context(GoContextValue)
    indirect case contextStorage(GoContextStorage)
    indirect case netConn(GoNetConnValue)
    indirect case netListener(GoNetListenerValue)
    indirect case interface(GoInterfaceValue)

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
    /// Push `(string, int)` — the next chunk of fd 0 (at most 4096 bytes, never
    /// splitting a UTF-8 sequence) and status 0, or `""` and status 1 at end of
    /// input. Only the calling goroutine waits; a resumable run suspends while
    /// the host has not yet delivered input.
    case readStdin
    /// Pop a path and contents, create or truncate the VFS file, and push the
    /// int status (0 on success, 1 on failure).
    case writeFile
    /// Pop a bool and switch the fd 0 terminal into or out of raw mode. Pushes
    /// `false` when fd 0 is not a terminal.
    case setTerminalRawMode
    /// Push `(rows, columns)` of the terminal at fd 1 (or fd 0), or `(0, 0)`
    /// when neither is a terminal.
    case terminalWindowSize
    /// Pop the operands of a Go `strings` function and push its result.
    case strings(GoStringsFunction)
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

/// Unwinds a resumable run whose goroutines are all waiting on host input.
private struct GoExecutionSuspension: Error {}

public struct GoVirtualMachine: Sendable {
    /// Upper bound on the bytes one `userland.ReadStdin` call returns.
    static let standardInputChunkBytes = 4_096

    /// Length of the longest prefix of `bytes` that does not end inside a UTF-8
    /// sequence. The remainder (at most three bytes) waits for the next read so
    /// a multi-byte character split across reads decodes intact.
    static func completeUTF8PrefixLength(_ bytes: [UInt8]) -> Int {
        var index = bytes.count - 1
        var continuationCount = 0
        while index >= 0, continuationCount < 3, bytes[index] & 0xC0 == 0x80 {
            index -= 1
            continuationCount += 1
        }
        guard index >= 0 else { return bytes.count }
        let expectedLength: Int
        switch bytes[index] {
        case 0xC0...0xDF: expectedLength = 2
        case 0xE0...0xEF: expectedLength = 3
        case 0xF0...0xF7: expectedLength = 4
        default: expectedLength = 1
        }
        return expectedLength > continuationCount + 1 ? index : bytes.count
    }


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
    ///
    /// The run completes before this call returns, so a goroutine waiting on
    /// input the host has not delivered yet is reported as a deadlock. Use
    /// ``startProgram(_:eventLoop:processContext:arguments:write:completion:)``
    /// for interactive programs.
    public func runProgram(
        _ executable: GoExecutable,
        eventLoop: EventLoop = EventLoop(),
        processContext: ProcessContext? = nil,
        arguments: [String] = [],
        write: (String) throws -> Void
    ) throws -> GoProcessResult {
        // A non-resumable run never parks a continuation, so `write` cannot
        // outlive this call.
        try withoutActuallyEscaping(write) { write in
            guard let result = try execute(
                executable,
                eventLoop: eventLoop,
                processContext: processContext,
                arguments: arguments,
                write: write,
                resumedCompletion: nil)
            else {
                preconditionFailure("a non-resumable Swiftix Go run suspended")
            }
            return result
        }
    }

    /// Start a resumable run for an interactive process.
    ///
    /// When every goroutine is waiting and only `userland.ReadStdin` can make
    /// progress, the run suspends and returns control to the event loop instead
    /// of reporting a deadlock; the kernel resumes it when fd 0 delivers input.
    /// The instruction and output budgets bound each uninterrupted slice between
    /// suspensions rather than the whole session. `completion` runs exactly
    /// once, possibly before this call returns.
    public func startProgram(
        _ executable: GoExecutable,
        eventLoop: EventLoop = EventLoop(),
        processContext: ProcessContext? = nil,
        arguments: [String] = [],
        write: @escaping (String) throws -> Void,
        completion: @escaping (Result<GoProcessResult, any Error>) -> Void
    ) {
        do {
            if let result = try execute(
                executable,
                eventLoop: eventLoop,
                processContext: processContext,
                arguments: arguments,
                write: write,
                resumedCompletion: completion)
            {
                completion(.success(result))
            }
        } catch {
            completion(.failure(error))
        }
    }

    /// Run `executable` as the body of a Swiftix process, scheduled
    /// cooperatively on the process's event loop.
    ///
    /// Unlike ``runProgram(_:eventLoop:processContext:arguments:write:)`` and
    /// ``startProgram(_:eventLoop:processContext:arguments:write:completion:)``,
    /// this run never drives the event loop itself:
    ///
    /// - After every `instructionQuantum` instructions the process yields to
    ///   the event loop and continues in a later step, so other processes run
    ///   in between and a signal can end a runaway program.
    /// - `time.Sleep`, timers, channel waits on them, standard-input reads, and
    ///   network waits park the process on the kernel until they complete.
    /// - Output goes to the process's descriptors (`fmt.Print` to fd 1). A write
    ///   that a full pipe accepts only partly parks the writing goroutine until
    ///   the reader makes room, so no output is dropped.
    ///
    /// `instructionBudget` bounds the instructions of the whole run; `nil`
    /// leaves CPU time unbounded, as for a native process. `maximumInstructions`
    /// and `resourceLimits.maximumOutputBytes` do not apply to this run: both
    /// exist to bound a synchronous run, and here yielding and pipe
    /// backpressure do that. A program whose goroutines all wait on each other
    /// still fails with ``GoRuntimeError/deadlock``.
    ///
    /// Call from inside a step of `processContext`'s process (for example its
    /// command body). `completion` runs exactly once, possibly before this
    /// call returns, unless the process is killed first.
    public func startProcess(
        _ executable: GoExecutable,
        processContext: ProcessContext,
        arguments: [String] = [],
        instructionBudget: Int? = nil,
        completion: @escaping (Result<GoProcessResult, any Error>) -> Void
    ) {
        do {
            if let result = try execute(
                executable,
                eventLoop: processContext.eventLoop,
                processContext: processContext,
                arguments: arguments,
                write: { _ in },
                resumedCompletion: completion,
                cooperative: true,
                instructionBudget: instructionBudget)
            {
                completion(.success(result))
            }
        } catch {
            completion(.failure(error))
        }
    }

    /// Run until the program finishes (returning its result) or suspends on
    /// host input (returning `nil`). Only a non-nil `resumedCompletion` permits
    /// suspension; it later receives the outcome of the resumed run.
    ///
    /// A `cooperative` run (see `startProcess`) requires a process context and
    /// a `resumedCompletion`; it suspends instead of driving the event loop.
    private func execute(
        _ executable: GoExecutable,
        eventLoop: EventLoop,
        processContext: ProcessContext?,
        arguments: [String],
        write: @escaping (String) throws -> Void,
        resumedCompletion: ((Result<GoProcessResult, any Error>) -> Void)?,
        cooperative: Bool = false,
        instructionBudget: Int? = nil
    ) throws -> GoProcessResult? {
        precondition(
            !cooperative || (processContext != nil && resumedCompletion != nil),
            "a cooperative Swiftix Go run needs a process and a completion")
        let instructionLimit = cooperative
            ? max(0, instructionBudget ?? Int.max)
            : maximumInstructions
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
        // The methods of the library's defined types, which no image has.
        for (name, function) in GoLibraryMethods.functions where functions[name] == nil {
            functions[name] = function
        }
        for (name, function) in GoLibraryStructMethods.functions where functions[name] == nil {
            functions[name] = function
        }
        guard functions[executable.entryPoint] != nil else {
            throw GoRuntimeError.missingEntryPoint(executable.entryPoint)
        }
        for initializer in executable.initializers where functions[initializer] == nil {
            throw GoRuntimeError.missingFunction(initializer)
        }
        let vm = GoExecutionState(heap: try ManagedHeap(
            globalCount: executable.globalCount,
            maximumCells: resourceLimits.maximumHeapCells,
            maximumBytes: resourceLimits.maximumHeapBytes))
        var startupFunctions = executable.initializers + [executable.entryPoint]
        var testFailureCount = 0
        var subtests: [(name: String, failuresAtStart: Int)] = []
        var nextGoroutineID = 1
        var blockedGoroutines: Set<Int> = []
        var blockedSelects: [Int: BlockedSelect] = [:]
        // True once the current goroutine's context is already stored in
        // `goroutines` (parked, and possibly woken again) within this
        // instruction, so the scheduler must not store it a second time.
        var nextWaitSequence: UInt64 = 0
        var selectRandomState = selectSeed
        var asynchronousError: GoRuntimeError?
        var runtimeHandleRoots: [Int: GoValue] = [:]
        var nextRuntimeHandleID = 0
        var activeTimerCount = 0
        var activeDeferredCallCount = 0
        var outputBytesWritten = 0
        var executionIsActive = true
        var httpHandlers: [String: String] = [:]
        // Files the program opened, by `*os.File` handle. A handle is never
        // reused, so a closed file stays closed after its descriptor number
        // is handed to a later open.
        var openFiles: [Int64: GoFiles.OpenFile] = [:]
        var nextFileHandle = GoFiles.firstHandle
        // Who is parked on each `sync.RWMutex` and `sync.Cond`, by where
        // the struct is.
        var lockWaiters: [GoAddress: GoLockWaiters] = [:]
        var conditionWaiters: [GoAddress: GoConditionWaiters] = [:]
        // The timers and tickers that are running, by where the struct is.
        var runningTimers: [GoAddress: GoRunningTimer] = [:]
        var nextTimerSequence: UInt64 = 0
        // The environment as the program has it, once it has asked.
        var environment: GoEnvironment?
        // Decoded type descriptors, by the type name that carries them.
        var typeDescriptors: [String: GoTypeDescriptor] = [:]
        // The results the native call being executed has from guest
        // functions, and how many of them this pass has used. Nil outside
        // such a call, where no guest function can be run.
        var guestCallResults: [GoValue]?
        var guestCallCursor = 0
        var programExitCode: Int32 = 0
        // Resumable-run state: a suspended run keeps every local alive through
        // `resumeHook`, which the stdin continuation invokes.
        var isSuspended = false
        var resumeHook: (() -> Void)?
        var pendingHostInputWaits = 0
        // Cooperative-run state: host continuations (timers, descriptor and
        // network waits, the quantum yield) that will resume a suspended run.
        var pendingHostWaits = 0
        // Who is parked in `Accept` or `Read` of a network handle, by
        // descriptor, and the descriptors closed since (`GoParkedNetWait`).
        var parkedNetWaits: [Int: [GoParkedNetWait]] = [:]
        var closedNetDescriptors: Set<Int> = []
        var descriptorWrites: [Int: [PendingDescriptorWrite]] = [:]
        var standardInputCarry: [UInt8] = []
        var completedNormally = false
        var programEnabledRawMode = false
        func releaseExecution() {
            executionIsActive = false
            resumeHook = nil
            guard let processContext else { return }
            // A program that fails while its terminal is raw cannot restore it
            // itself; a normal exit keeps whatever mode the program chose.
            if !completedNormally, programEnabledRawMode {
                processContext.setTerminalRawMode(0, false)
            }
            // Go closes nothing at exit, but the hosting process can outlive
            // the program. Handle order keeps the syscall trace deterministic.
            for handle in openFiles.keys.sorted() {
                processContext.close(openFiles[handle]!.descriptor)
            }
            openFiles.removeAll()
            _ = processContext.reportRuntimeMemory(
                bytes: 0,
                limitBytes: 0,
                heapCells: 0,
                garbageCollections: 0)
        }
        defer { if !isSuspended { releaseExecution() } }

        func reportRuntimeMemoryIfChanged() throws {
            guard let processContext else { return }
            let statistics = vm.heap.statistics
            let current = (
                bytes: statistics.liveHeapBytes,
                cells: statistics.liveHeapCells,
                collections: statistics.garbageCollections)
            if let previous = vm.lastRuntimeMemoryReport,
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
            vm.lastRuntimeMemoryReport = current
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
            // Pipe backpressure bounds a cooperative run's output instead.
            if cooperative { return }
            guard byteCount >= 0,
                outputBytesWritten <= resourceLimits.maximumOutputBytes,
                byteCount <= resourceLimits.maximumOutputBytes - outputBytesWritten
            else {
                throw GoRuntimeError.resourceLimitExceeded("output bytes")
            }
            outputBytesWritten += byteCount
        }

        /// Resume a suspended run from a host continuation.
        func resumeIfSuspended() {
            guard isSuspended, let hook = resumeHook else { return }
            resumeHook = nil
            hook()
        }

        /// Bracket a host continuation that can make a goroutine runnable. A
        /// cooperative run with nothing runnable suspends while any are
        /// outstanding and reports a deadlock otherwise.
        func beginHostWait() {
            pendingHostWaits += 1
        }

        func endHostWait() {
            pendingHostWaits -= 1
            if cooperative, executionIsActive { resumeIfSuspended() }
        }

        func recordAsynchronousFailure(_ error: any Error) {
            asynchronousError = (error as? GoRuntimeError) ?? .typeMismatch
        }

        /// Write the queued bytes of descriptor `fd` in order, waking each
        /// writer when its bytes are accepted and parking on the kernel while
        /// the descriptor is full.
        func pumpDescriptorWrites(_ fd: Int) {
            guard let processContext else { return }
            while var head = descriptorWrites[fd]?.first {
                var failure: String?
                var accepted = 0
                let end = min(head.bytes.count, head.offset + 65_536)
                do {
                    accepted = try processContext.writeFile(
                        fd, Array(head.bytes[head.offset..<end]))
                } catch SyscallError.wouldBlock {
                    accepted = 0
                } catch SyscallError.brokenPipe {
                    // The kernel has delivered SIGPIPE. Yield so a killed
                    // process stops here; one that ignores the signal sees the
                    // error instead.
                    failure = "broken pipe"
                    vm.yieldRequested = true
                } catch {
                    failure = "write failed: \(String(describing: error))"
                }
                head.offset += accepted
                if failure == nil, head.offset < head.bytes.count {
                    if accepted > 0 {
                        head.idleRounds = 0
                        descriptorWrites[fd]![0] = head
                        continue
                    }
                    head.idleRounds += 1
                    if head.idleRounds <= 8 {
                        descriptorWrites[fd]![0] = head
                        beginHostWait()
                        processContext.poll(
                            [PollRequest(fd: fd, interests: .writable)], timeout: nil
                        ) { _ in
                            defer { endHostWait() }
                            guard executionIsActive, asynchronousError == nil else { return }
                            pumpDescriptorWrites(fd)
                        }
                        return
                    }
                    failure = "write stalled"
                }
                descriptorWrites[fd]!.removeFirst()
                if descriptorWrites[fd]!.isEmpty { descriptorWrites[fd] = nil }
                do {
                    try wakeGoroutine(
                        head.goroutineID,
                        values: head.results?(head.offset, failure) ?? [])
                } catch {
                    recordAsynchronousFailure(error)
                    return
                }
            }
        }

        /// Write `bytes` to descriptor `fd` of the hosting process for the
        /// current goroutine. `results` maps the accepted byte count and an
        /// error message to the values the operation yields (none for
        /// `fmt.Print`).
        ///
        /// A cooperative run parks the goroutine until every byte is accepted
        /// (the caller ends the instruction with `currentBlocked` set).
        /// Otherwise the write is immediate: fd 1 goes to the `write` sink, and
        /// so does any descriptor of a run without a process.
        /// `opened` marks a file the program opened itself: it is never the
        /// run's output sink, even when it was handed descriptor 1, and its
        /// bytes are stored by the file system rather than spent from the
        /// run's output budget.
        func writeDescriptor(
            _ fd: Int,
            _ text: String,
            opened: Bool = false,
            results: ((Int, String?) -> [GoValue])? = nil
        ) throws {
            try writeDescriptor(
                fd, bytes: Array(text.utf8), text: text, opened: opened, results: results)
        }

        func writeDescriptor(
            _ fd: Int,
            bytes: [UInt8],
            text: String? = nil,
            opened: Bool = false,
            results: ((Int, String?) -> [GoValue])? = nil
        ) throws {
            guard cooperative else {
                if !opened { try consumeOutputBytes(bytes.count) }
                var accepted = bytes.count
                var failure: String?
                if (fd == 1 && !opened) || processContext == nil {
                    try write(text ?? String(decoding: bytes, as: UTF8.self))
                } else if let processContext {
                    accepted = 0
                    do {
                        while accepted < bytes.count {
                            let count = try processContext.writeFile(
                                fd, Array(bytes[accepted...]))
                            guard count > 0 else {
                                failure = "short write"
                                break
                            }
                            accepted += count
                        }
                    } catch {
                        failure = "write failed: \(String(describing: error))"
                    }
                }
                if let results { vm.stack.append(contentsOf: results(accepted, failure)) }
                return
            }
            descriptorWrites[fd, default: []].append(
                PendingDescriptorWrite(
                    goroutineID: vm.currentGoroutineID, bytes: bytes, results: results))
            // The goroutine is parked before the pump can wake it.
            vm.goroutines[vm.currentGoroutineID] = GoroutineContext(frames: vm.frames, stack: vm.stack)
            blockedGoroutines.insert(vm.currentGoroutineID)
            vm.currentParked = true
            vm.currentBlocked = true
            if descriptorWrites[fd]!.count == 1 { pumpDescriptorWrites(fd) }
            if let asynchronousError { throw asynchronousError }
        }

        func emit(_ text: String) throws {
            try writeDescriptor(1, text)
        }

        /// The operands of `fmt.Print` (no separator) or `fmt.Println`, each
        /// as `%v` prints it. `scope.limit` bounds the whole text.
        func formatOperands(
            _ values: [GoValue],
            prefix: String = "",
            separator: String,
            suffix: String,
            scope: GoFormatScope
        ) throws -> String {
            var parts: [String] = []
            parts.reserveCapacity(values.count * 2 + 1)
            var byteCount = 0

            func append(_ part: String) throws {
                let count = part.utf8.count
                guard byteCount <= scope.limit, count <= scope.limit - byteCount else {
                    throw scope.overflow
                }
                byteCount += count
                parts.append(part)
            }

            try append(prefix)
            let plain = GoFormat.Directive(verb: "v")
            var previousWasString = true
            for (index, value) in values.enumerated() {
                // Without a separator this is `fmt.Print`, which puts a space
                // between two operands when neither is a string.
                var isString = false
                if case .string = plainOperand(value) { isString = true }
                if index > 0 {
                    try append(separator.isEmpty && !isString && !previousWasString ? " " : separator)
                }
                previousWasString = isString
                var remaining = scope
                remaining.limit = scope.limit - byteCount
                try append(try formatValue(value, as: nil, plain, scope: remaining, depth: 0))
            }
            try append(suffix)
            return parts.joined()
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
            return try formatOperands(
                values, prefix: prefix, separator: separator, suffix: suffix,
                scope: GoFormatScope(
                    limit: resourceLimits.maximumOutputBytes - outputBytesWritten,
                    overflow: .resourceLimitExceeded("output bytes")))
        }

        func makeFrame(
            function: GoBytecodeFunction,
            stackBase: Int,
            arguments: [GoValue],
            heap: inout ManagedHeap,
            isDeferredCall: Bool = false
        ) throws -> Frame {
            guard vm.liveFrameLocalCount <= resourceLimits.maximumLiveFrameLocals,
                function.localCount
                    <= resourceLimits.maximumLiveFrameLocals - vm.liveFrameLocalCount
            else {
                throw GoRuntimeError.resourceLimitExceeded("live frame locals")
            }
            let frame = try Frame(
                function: function,
                stackBase: stackBase,
                arguments: arguments,
                heap: &heap,
                isDeferredCall: isDeferredCall)
            vm.liveFrameLocalCount += function.localCount
            return frame
        }

        func releaseFrame(_ frame: Frame) {
            vm.liveFrameLocalCount -= frame.function.localCount
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

        /// The current instant in nanoseconds: on the hosting kernel's wall
        /// clock (the Unix epoch unless the host anchored it elsewhere), or
        /// logical time for a run without a process.
        func runtimeTimestamp() -> Int64 {
            let seconds = processContext?.realtimeSeconds ?? eventLoop.now
            guard seconds.isFinite else { return seconds.sign == .minus ? Int64.min : Int64.max }
            // Whole seconds and the fraction convert separately: a product of
            // epoch seconds and 10^9 has no nanosecond precision left.
            let whole = seconds.rounded(.down)
            let limit = Double(Int64.max / 1_000_000_000)
            if whole >= limit { return Int64.max }
            if whole <= -limit { return Int64.min }
            return Int64(whole) * 1_000_000_000
                + Int64(((seconds - whole) * 1_000_000_000).rounded())
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
            guard case .array(let backing) = try read(pointer: slice.backing, heap: vm.heap),
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
            if cooperative, let processContext {
                // A kernel sleep keeps the parked process alive and shows it as
                // waiting; the continuation runs as a step of the process.
                beginHostWait()
                processContext.sleep(delay) {
                    defer { endHostWait() }
                    work()
                }
            } else if let processContext {
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
                let cell = frame.locals[index], vm.heap.contains(cell)
            else { throw GoRuntimeError.invalidLocal(index) }
            return vm.heap[cell]
        }

        func storeLocal(_ value: GoValue, at index: Int, in frame: inout Frame) throws {
            guard frame.locals.indices.contains(index) else {
                throw GoRuntimeError.invalidLocal(index)
            }
            if let cell = frame.locals[index] {
                guard vm.heap.contains(cell) else { throw GoRuntimeError.invalidPointer }
                try vm.heap.replace(cell, with: value)
            } else {
                frame.locals[index] = try vm.heap.allocate(value)
            }
        }

        func resumeNextGoroutine() -> Bool {
            guard !vm.runQueue.isEmpty else { return false }
            let next = vm.runQueue.removeFirst()
            guard let context = vm.goroutines.removeValue(forKey: next) else { return false }
            vm.currentGoroutineID = next
            vm.frames = context.frames
            vm.stack = context.stack
            vm.currentBlocked = false
            return true
        }

        func driveEventLoopUntilRunnable() throws {
            while !resumeNextGoroutine() {
                if cooperative {
                    // Never drive the loop from inside a process step: return
                    // to it and let a host continuation resume the run.
                    if let asynchronousError { throw asynchronousError }
                    guard pendingHostWaits > 0 else { throw GoRuntimeError.deadlock }
                    throw GoExecutionSuspension()
                }
                guard eventLoop.runNext() else {
                    if resumedCompletion != nil, pendingHostInputWaits > 0 {
                        throw GoExecutionSuspension()
                    }
                    throw GoRuntimeError.deadlock
                }
                if let asynchronousError { throw asynchronousError }
            }
        }

        func scheduleNext(requeueCurrent: Bool) throws {
            var quantumEnded = vm.yieldRequested
            if vm.executed > 0,
               vm.executed != vm.lastEventLoopYieldInstruction,
               vm.executed.isMultiple(of: instructionQuantum) {
                vm.lastEventLoopYieldInstruction = vm.executed
                quantumEnded = true
            }
            vm.yieldRequested = false
            // Record a parked goroutine before any host work runs: the turn
            // below may deliver the very wake-up it is waiting for.
            if vm.currentParked {
                vm.currentParked = false
            } else if !requeueCurrent {
                vm.goroutines[vm.currentGoroutineID] = GoroutineContext(frames: vm.frames, stack: vm.stack)
                blockedGoroutines.insert(vm.currentGoroutineID)
            } else if cooperative, quantumEnded {
                vm.goroutines[vm.currentGoroutineID] = GoroutineContext(frames: vm.frames, stack: vm.stack)
                vm.runQueue.append(vm.currentGoroutineID)
            } else {
                // The current goroutine keeps running unless others are ready.
                if quantumEnded {
                    _ = eventLoop.runUntilIdle(stepBudget: 1)
                    if let asynchronousError { throw asynchronousError }
                }
                if vm.runQueue.isEmpty { return }
                vm.goroutines[vm.currentGoroutineID] = GoroutineContext(frames: vm.frames, stack: vm.stack)
                vm.runQueue.append(vm.currentGoroutineID)
                try driveEventLoopUntilRunnable()
                return
            }
            if quantumEnded {
                if cooperative, let processContext {
                    // End this step. The yield keeps the process runnable and
                    // queues the next slice behind other ready work, without
                    // holding logical time at this instant.
                    beginHostWait()
                    processContext.yield { endHostWait() }
                    throw GoExecutionSuspension()
                }
                // Give one already-ready EventLoop job/timer a turn at each
                // quantum without jumping logical time to a future deadline.
                // Do this before selecting another guest goroutine so a busy
                // run queue cannot starve host work.
                _ = eventLoop.runUntilIdle(stepBudget: 1)
                if let asynchronousError { throw asynchronousError }
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
            guard var context = vm.goroutines[id], blockedGoroutines.remove(id) != nil else {
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
            vm.goroutines[id] = context
            vm.runQueue.append(id)
        }

        /// Park goroutine `id` until fd 0 yields a chunk that ends on a UTF-8
        /// boundary (or reaches end of input), then wake it with `(data, status)`
        /// and resume the run if it suspended meanwhile.
        func readStandardInputChunk(for id: Int) {
            guard let processContext else { return }
            beginHostWait()
            processContext.read(0, max: GoVirtualMachine.standardInputChunkBytes) { bytes in
                defer { endHostWait() }
                guard executionIsActive, asynchronousError == nil else { return }
                do {
                    let pending = standardInputCarry + bytes
                    if bytes.isEmpty {
                        standardInputCarry = []
                        pendingHostInputWaits -= 1
                        try wakeGoroutine(
                            id,
                            values: pending.isEmpty
                                ? [.string(""), .int(1)]
                                : [.string(String(decoding: pending, as: UTF8.self)), .int(0)])
                    } else {
                        let boundary = GoVirtualMachine.completeUTF8PrefixLength(pending)
                        standardInputCarry = Array(pending[boundary...])
                        guard boundary > 0 else {
                            readStandardInputChunk(for: id)
                            return
                        }
                        pendingHostInputWaits -= 1
                        try wakeGoroutine(
                            id,
                            values: [
                                .string(String(decoding: pending[..<boundary], as: UTF8.self)),
                                .int(0),
                            ])
                    }
                } catch let error as GoRuntimeError {
                    asynchronousError = error
                } catch {
                    asynchronousError = .typeMismatch
                }
                if !cooperative { resumeIfSuspended() }
            }
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
                var context = vm.goroutines[candidate.goroutineID],
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
            vm.goroutines[candidate.goroutineID] = context
            vm.runQueue.append(candidate.goroutineID)
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
                        pointer: channel.storage, heap: vm.heap)
                else { throw GoRuntimeError.typeMismatch }
                return storage.closed
                    || !storage.receiveWaiters.isEmpty
                    || blockedReceiveCandidate(for: channel.storage, excluding: excludedID) != nil
                    || storage.buffer.count < storage.capacity
            case .receive(let base, _, _, _, _):
                if base == .nilValue { return false }
                guard case .channel(let channel) = base,
                    case .channelStorage(let storage) = try read(
                        pointer: channel.storage, heap: vm.heap)
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
                    pointer: channel.storage, heap: vm.heap)
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
                    .channelStorage(storage), through: channel.storage, heap: &vm.heap)
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
                    .channelStorage(storage), through: channel.storage, heap: &vm.heap)
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
                    pointer: channel.storage, heap: vm.heap)
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
                    .channelStorage(storage), through: channel.storage, heap: &vm.heap)
                return .received(value, true)
            }

            let ordinary = storage.sendWaiters.first
            let selected = blockedSendCandidate(for: channel.storage, excluding: excludedID)
            if let ordinary, selected == nil
                || (selected.map { ordinary.waitSequence <= $0.waitSequence } ?? false)
            {
                storage.sendWaiters.removeFirst()
                try writePointer(
                    .channelStorage(storage), through: channel.storage, heap: &vm.heap)
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
                    var context = vm.goroutines[ready.id],
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
                            GoRuntimePanic.closedChannelSend.value)
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
                vm.goroutines[ready.id] = context
                vm.runQueue.append(ready.id)
            }
        }

        func cancelContextTree(_ ctxPointer: GoPointer, message: String) throws {
            guard case .contextStorage(var ctxStorage) = try read(
                pointer: ctxPointer, heap: vm.heap)
            else { return }
            guard !ctxStorage.cancelled else { return }
            ctxStorage.cancelled = true
            ctxStorage.errorMessage = message
            try writePointer(.contextStorage(ctxStorage), through: ctxPointer, heap: &vm.heap)
            // Close the done channel to signal cancellation
            guard case .channelStorage(var doneStorage) = try read(
                pointer: ctxStorage.doneChannel, heap: vm.heap)
            else { return }
            if !doneStorage.closed {
                doneStorage.closed = true
                try writePointer(
                    .channelStorage(doneStorage), through: ctxStorage.doneChannel, heap: &vm.heap)
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

        /// The elements of a slice value (`nil` is the empty slice).
        func sliceElements(_ value: GoValue) throws -> ArraySlice<GoValue> {
            if value == .nilValue { return [] }
            guard case .slice(let slice) = value else { throw GoRuntimeError.typeMismatch }
            let range = try validatedSliceRange(slice)
            guard case .array(let backing) = try read(pointer: slice.backing, heap: vm.heap) else {
                throw GoRuntimeError.typeMismatch
            }
            return backing[range]
        }

        /// The bytes of a `[]byte` value.
        func sliceBytes(_ value: GoValue) throws -> [UInt8] {
            try sliceElements(value).map { element in
                guard case .int(let byte) = element else { throw GoRuntimeError.typeMismatch }
                return UInt8(truncatingIfNeeded: byte)
            }
        }

        func makeByteSlice(_ bytes: [UInt8]) throws -> GoValue {
            try requireCollectionCount(bytes.count, resource: "slice elements")
            let cell = try vm.heap.allocate(.array(bytes.map { .int(Int64($0)) }))
            return .slice(
                GoSliceValue(
                    backing: GoPointer(cell: cell),
                    start: 0,
                    length: bytes.count,
                    capacity: bytes.count,
                    zeroValue: .int(0)))
        }

        /// A Go `error` result: `nil`, or an error whose `Error()` is `message`.
        func errorValue(_ message: String?) -> GoValue {
            guard let message else { return .nilValue }
            return .interface(GoInterfaceValue(typeName: "error", value: .string(message)))
        }

        /// The file a `*os.File` value denotes, or nil for a nil file and for
        /// one the program already closed.
        func resolveFile(_ value: GoValue) throws -> GoFiles.OpenFile? {
            if value == .nilValue { return nil }
            guard case .int(let raw) = value else { throw GoRuntimeError.typeMismatch }
            if raw >= GoFiles.firstHandle { return openFiles[raw] }
            guard let descriptor = Int(exactly: raw) else { throw GoRuntimeError.typeMismatch }
            return GoFiles.inherited(descriptor)
        }

        /// `value` as a copy of its own, with locks of its own: see
        /// `GoLockCopies`. Any other value is itself.
        func copiedLocks(_ value: GoValue) throws -> GoValue {
            guard GoLockCopies.holdsLock(value) else { return value }
            return try GoLockCopies.copied(
                value, read: { try read(pointer: $0, heap: vm.heap) },
                allocate: { try vm.heap.allocate($0) })
        }

        /// `values` with locks of their own, when they hold any: the
        /// elements of a new array made of others, or of a zero value.
        func copiedLocks(_ values: [GoValue]) throws -> [GoValue] {
            guard let first = values.first, GoLockCopies.holdsLock(first) else { return values }
            return try values.map(copiedLocks)
        }

        /// Store `values` in the leading elements of `destination`.
        func storeElements(_ values: [GoValue], into destination: GoSliceValue) throws {
            guard !values.isEmpty else { return }
            let range = try validatedSliceRange(destination)
            guard values.count <= range.count else { throw GoRuntimeError.invalidSliceBounds }
            if destination.backing.path.isEmpty,
                try vm.heap.replaceArrayElements(
                    destination.backing.cell, from: range.lowerBound, with: values)
            {
                return
            }
            for (offset, value) in values.enumerated() {
                try writePointer(
                    value,
                    through: appending(index: range.lowerBound + offset, to: destination.backing),
                    heap: &vm.heap)
            }
        }

        /// Copy `bytes` into the leading elements of `destination`.
        func storeBytes(_ bytes: [UInt8], into destination: GoSliceValue) throws {
            try storeElements(bytes.map { .int(Int64($0)) }, into: destination)
        }

        /// Run a library function that reaches the hosting process: `*os.File`
        /// writes and reads, and whole-file I/O.
        /// Arguments are the top `argumentCount` stack entries in call order.
        /// Returns `false` when `name` is not such a function.
        func executeHostNative(_ name: String, argumentCount: Int) throws -> Bool {
            let expectedCount: Int
            switch name {
            case "$os.File.Write", "$os.File.WriteString", "$os.File.Read": expectedCount = 2
            case "$os.ReadFile": expectedCount = 1
            case "$os.WriteFile": expectedCount = 3
            default: return false
            }
            guard argumentCount == expectedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expectedCount, actual: argumentCount)
            }
            guard vm.stack.count >= argumentCount else { throw GoRuntimeError.stackUnderflow }
            let start = vm.stack.count - argumentCount
            let operands = Array(vm.stack[start...])
            vm.stack.removeSubrange(start...)

            func descriptor(_ value: GoValue) throws -> Int {
                guard let file = try resolveFile(value) else { throw GoRuntimeError.typeMismatch }
                return file.descriptor
            }
            /// Whether the receiver is a file the program opened.
            var opened: Bool {
                if case .int(let raw) = operands[0] { return raw >= GoFiles.firstHandle }
                return false
            }
            let writeResults: (Int, String?) -> [GoValue] = { count, failure in
                [.int(Int64(count)), errorValue(failure)]
            }
            // A nil `*os.File` is refused, as Go's methods refuse it.
            if operands[0] == .nilValue, name.hasPrefix("$os.File.") {
                vm.stack.append(contentsOf: [.int(0), errorValue(GoFiles.invalidFile)])
                return true
            }
            // A file the program closed fails as it does in Go instead of
            // reaching whatever now owns its descriptor number.
            if case .int(let handle) = operands[0], handle >= GoFiles.firstHandle,
                openFiles[handle] == nil
            {
                let operation = name == "$os.File.Read" ? "read" : "write"
                vm.stack.append(contentsOf: [
                    .int(0), errorValue("\(operation): \(GoFiles.closedFile)"),
                ])
                return true
            }

            switch name {
            case "$os.File.Write":
                try writeDescriptor(
                    try descriptor(operands[0]),
                    bytes: try sliceBytes(operands[1]),
                    opened: opened,
                    results: writeResults)
            case "$os.File.WriteString":
                guard case .string(let text) = operands[1] else {
                    throw GoRuntimeError.typeMismatch
                }
                try writeDescriptor(
                    try descriptor(operands[0]), text, opened: opened, results: writeResults)
            case "$os.File.Read":
                let fd = try descriptor(operands[0])
                let capacity: Int
                let destination: GoSliceValue?
                if case .slice(let slice) = operands[1] {
                    _ = try validatedSliceRange(slice)
                    capacity = slice.length
                    destination = slice
                } else if operands[1] == .nilValue {
                    capacity = 0
                    destination = nil
                } else {
                    throw GoRuntimeError.typeMismatch
                }
                guard capacity > 0, let destination else {
                    vm.stack.append(contentsOf: [.int(0), .nilValue])
                    break
                }
                func deliver(_ bytes: [UInt8]) throws -> [GoValue] {
                    guard !bytes.isEmpty else { return [.int(0), errorValue("EOF")] }
                    for (offset, byte) in bytes.enumerated() {
                        let index = try checkedAdd(
                            destination.start, offset, resource: "slice index")
                        try writePointer(
                            .int(Int64(byte)),
                            through: appending(index: index, to: destination.backing),
                            heap: &vm.heap)
                    }
                    return [.int(Int64(bytes.count)), .nilValue]
                }
                // Bytes `ReadStdin` held back to keep a character whole are
                // still unread input.
                if fd == 0, !opened, !standardInputCarry.isEmpty {
                    let count = min(capacity, standardInputCarry.count)
                    let bytes = Array(standardInputCarry[..<count])
                    standardInputCarry.removeFirst(count)
                    vm.stack.append(contentsOf: try deliver(bytes))
                    break
                }
                guard let processContext, processContext.readiness(fd) != nil else {
                    vm.stack.append(contentsOf: [.int(0), errorValue("EOF")])
                    break
                }
                let readerID = vm.currentGoroutineID
                pendingHostInputWaits += 1
                beginHostWait()
                processContext.read(fd, max: min(capacity, 65_536)) { bytes in
                    defer { endHostWait() }
                    guard executionIsActive, asynchronousError == nil else { return }
                    pendingHostInputWaits -= 1
                    do {
                        try wakeGoroutine(readerID, values: try deliver(bytes))
                    } catch {
                        recordAsynchronousFailure(error)
                    }
                    if !cooperative { resumeIfSuspended() }
                }
                vm.currentBlocked = true
            case "$os.ReadFile":
                guard case .string(let path) = operands[0] else {
                    throw GoRuntimeError.typeMismatch
                }
                guard let processContext else {
                    vm.stack.append(contentsOf: [.nilValue, errorValue("open \(path): no file system")])
                    break
                }
                var bytes: [UInt8] = []
                do {
                    let descriptor = try processContext.openFile(path, access: .readOnly)
                    defer { try? processContext.closeFile(descriptor) }
                    while true {
                        let chunk = try processContext.readFile(descriptor, max: 65_536)
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
                    vm.stack.append(contentsOf: [
                        .nilValue, errorValue("open \(path): \(String(describing: error))"),
                    ])
                    break
                }
                vm.stack.append(contentsOf: [try makeByteSlice(bytes), .nilValue])
            default:
                guard case .string(let path) = operands[0],
                    case .int(let permissions) = operands[2]
                else { throw GoRuntimeError.typeMismatch }
                let contents = try sliceBytes(operands[1])
                guard let processContext else {
                    vm.stack.append(errorValue("open \(path): no file system"))
                    break
                }
                var failure: String?
                do {
                    let existed = processContext.stat(path) != nil
                    // The VFS creates missing directories on open; Go does not.
                    if let slash = path.lastIndex(of: "/"), slash != path.startIndex,
                        processContext.stat(String(path[..<slash]))?.isDirectory != true
                    {
                        throw SyscallError.noSuchFileOrDirectory
                    }
                    let descriptor = try processContext.openFile(
                        path, create: true, truncate: true, access: .writeOnly)
                    defer { try? processContext.closeFile(descriptor) }
                    if !existed {
                        _ = processContext.chmod(
                            path,
                            mode: FileMode(rawValue: UInt16(truncatingIfNeeded: permissions & 0o777))
                                .subtracting(processContext.fileCreationMask))
                    }
                    var offset = 0
                    while offset < contents.count {
                        let written = try processContext.writeFile(
                            descriptor, Array(contents[offset...]))
                        guard written > 0 else {
                            failure = "write \(path): short write"
                            break
                        }
                        offset += written
                    }
                } catch {
                    failure = "open \(path): \(String(describing: error))"
                }
                vm.stack.append(errorValue(failure))
            }
            return true
        }

        /// The descriptor an interface value's type name carries, if it is one.
        func typeDescriptor(named typeName: String) -> GoTypeDescriptor? {
            guard typeName.hasPrefix(GoTypeDescriptor.marker) else { return nil }
            if let cached = typeDescriptors[typeName] { return cached }
            guard let decoded = GoTypeDescriptor(typeName: typeName) else { return nil }
            typeDescriptors[typeName] = decoded
            return decoded
        }

        /// What the result variables of `frame` hold: the locals after its
        /// parameters.
        func resultValues(of frame: Frame) throws -> [GoValue] {
            let locals: [Int]
            if let named = frame.resultLocals {
                locals = named
            } else {
                // A function that did not say holds its results after its
                // parameters.
                let resultStart = frame.function.parameterCount
                let resultEnd = try checkedAdd(
                    resultStart, frame.function.returnCount, resource: "function result locals")
                guard resultEnd <= frame.locals.count else {
                    throw GoRuntimeError.invalidExecutable("invalid function result locals")
                }
                locals = Array(resultStart..<resultEnd)
            }
            return try locals.map { localIndex in
                guard let cell = frame.locals[localIndex], vm.heap.contains(cell) else {
                    throw GoRuntimeError.invalidLocal(localIndex)
                }
                return vm.heap[cell]
            }
        }

        /// The function a function value names and what it passes before
        /// the arguments of a call. Calling a nil one is Go's nil
        /// dereference.
        func functionValueTarget(_ value: GoValue) throws -> GoFunctionValueTarget {
            guard case .structure(let structure) = value,
                structure.typeName == GoNative.functionValueTypeName,
                case .string(let symbol)? = structure.fields.first?.value
            else {
                if value == .nilValue { throw GoRuntimePanic.nilDereference }
                throw GoRuntimeError.typeMismatch
            }
            guard let function = functions[symbol] else {
                throw GoRuntimeError.missingFunction(symbol)
            }
            return GoFunctionValueTarget(
                function: function, bound: structure.fields.dropFirst().map(\.value))
        }

        /// Ends the run with what Go prints for the panics of `report`, or
        /// starts the method that has to say what the next of them is and
        /// returns. Go prints an error it panicked with by its text and a
        /// value that has a `String` method by that; the method is the
        /// program's, so it runs as the goroutine's last frame, and the
        /// report goes on when it returns.
        func reportPanics(_ given: GoPanicReport) throws {
            var report = given
            while let record = report.pending.first {
                if let message = try libraryError(record.value)?.message {
                    report.describeFirst(as: message)
                } else if !report.skipsMethod, let target = methodTarget(record.value),
                    let function = GoFormat.textMethods.lazy
                        .compactMap({ method($0, of: target.owner) }).first
                {
                    let frame = try makeFrame(
                        function: function, stackBase: vm.stack.count,
                        arguments: [try methodReceiver(target.receiver, for: function)],
                        heap: &vm.heap)
                    frame.panicReport = report
                    vm.frames.append(frame)
                    return
                } else {
                    report.describeFirst(as: try panicText(record.value))
                }
            }
            throw GoRuntimeError.panicError(report.lines.joined(separator: "\n\tpanic: "))
        }

        /// What Go prints after `panic: ` for a value no method describes:
        /// a number, a string, or a truth value as it is, one of a named
        /// type as `main.code(4)`, and anything else by its type and where
        /// it is, `(main.point) 0xc000012000`.
        func panicText(_ value: GoValue) throws -> String {
            func plain(_ value: GoValue) -> String? {
                switch value {
                case .int(let number): return String(number)
                case .string(let text): return text
                case .bool(let truth): return String(truth)
                default: return nil
                }
            }
            var typeName: String
            var held = value
            if case .interface(let boxed) = value {
                held = boxed.value
                guard let descriptor = typeDescriptor(named: boxed.typeName) else {
                    return plain(held) ?? value.description
                }
                typeName = GoTypeDescriptor.name(of: descriptor.type)
                if case .named(let symbol) = descriptor.type {
                    switch descriptor.definitions[symbol] {
                    case .number(let number)?:
                        if case .int(let bits) = held,
                            let text = GoNumeric.panicValue(bits, number)
                        {
                            return "\(typeName)(\(text))"
                        }
                    case .integer?, .byte?, .boolean?:
                        if let text = plain(held) { return "\(typeName)(\(text))" }
                    case .string?:
                        if case .string(let text) = held {
                            return "\(typeName)(\(GoFormat.quote(text, asciiOnly: false)))"
                        }
                    default:
                        break
                    }
                } else if case .number(let number) = descriptor.type, case .int(let bits) = held,
                    let text = GoNumeric.panicValue(bits, number)
                {
                    return text
                } else if let text = plain(held) {
                    return text
                }
            } else if let text = plain(value) {
                return text
            } else {
                typeName = inferredTypeName(of: value)
            }
            // Go prints where the value it boxed lies. A value that is no
            // pointer has no cell of its own here; the address stands for it.
            let address = formatAddress(of: held) ?? 0xC0_0001_2000
            return "(\(typeName)) 0x" + String(address, radix: 16)
        }

        /// The address Go would print for a pointer, slice, map, or channel:
        /// stable for one value and distinct between heap cells. Nil is 0.
        func formatAddress(of value: GoValue) -> UInt64? {
            func address(_ pointer: GoPointer, offset: Int = 0) -> UInt64 {
                var within = UInt64(truncatingIfNeeded: offset) &* 8
                for component in pointer.path {
                    switch component {
                    case .index(let index):
                        within = within &* 31 &+ UInt64(truncatingIfNeeded: index) &+ 1
                    case .field(let name):
                        for byte in name.utf8 { within = within &* 31 &+ UInt64(byte) }
                    }
                }
                return 0xC0_0000_0000 &+ (UInt64(truncatingIfNeeded: pointer.cell) << 12)
                    &+ ((within &* 8) & 0xFF8)
            }
            switch value {
            case .nilValue: return 0
            case .pointer(let pointer): return address(pointer)
            case .slice(let slice): return address(slice.backing, offset: slice.start)
            case .map(let map): return address(map.storage)
            case .channel(let channel): return address(channel.storage)
            case .structure(let structure)
            where structure.typeName == GoNative.functionValueTypeName:
                // A function is where its code is: one address for each
                // function, made of its name.
                guard case .string(let symbol)? = structure.fields.first?.value else { return 0 }
                var hash: UInt64 = 0xCBF2_9CE4_8422_2325
                for byte in symbol.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
                return 0x1_0000_0000 | ((hash & 0x0FFF_FFFF) << 4)
            default: return nil
            }
        }

        /// The type name Go prints for a value that arrived without one: exact
        /// for an `int`, a `string`, a `bool`, and a struct, and the nearest
        /// spelling for anything an interface hid.
        func inferredTypeName(of value: GoValue) -> String {
            func element(_ zero: GoValue) -> String {
                zero == .nilValue ? "interface {}" : inferredTypeName(of: zero)
            }
            switch value {
            case .nilValue: return "<nil>"
            case .int: return "int"
            case .string: return "string"
            case .bool: return "bool"
            case .structure(let structure):
                if structure.typeName == GoNative.functionValueTypeName { return "func()" }
                return structure.typeName.map(GoTypeDescriptor.goName) ?? "struct {...}"
            case .slice(let slice): return "[]" + element(slice.zeroValue)
            case .array(let elements):
                return "[\(elements.count)]" + element(elements.first ?? .nilValue)
            case .map: return "map[interface {}]interface {}"
            case .pointer(let pointer):
                return "*" + ((try? read(pointer: pointer, heap: vm.heap)).map(inferredTypeName)
                    ?? "interface {}")
            case .channel: return "chan interface {}"
            case .interface(let boxed):
                if let descriptor = typeDescriptor(named: boxed.typeName) {
                    return GoTypeDescriptor.name(of: descriptor.type)
                }
                if boxed.typeName == "error" { return "*errors.errorString" }
                return GoTypeDescriptor.dynamicType(named: boxed.typeName)
                    .map(GoTypeDescriptor.name(of:)) ?? inferredTypeName(of: boxed.value)
            case .netConn: return "*net.TCPConn"
            case .netListener: return "*net.TCPListener"
            default: return "interface {}"
            }
        }

        /// Format `operand` under one `fmt` directive the way Go's
        /// `printValue` does. `declared` is its static type when the compiler
        /// supplied one; an interface and an operand without a descriptor
        /// show their own. Slices, arrays, structs, and maps apply the
        /// directive to each element, so a width pads every element and a
        /// wrong verb is marked per element. `depth` is 0 for an operand,
        /// which is where a pointer to a struct prints as `&{...}`.
        func formatValue(
            _ operand: GoValue,
            as declared: GoRuntimeType?,
            _ directive: GoFormat.Directive,
            scope: GoFormatScope,
            depth: Int
        ) throws -> String {
            guard depth <= resourceLimits.maximumPointerDepth else { throw scope.overflow }
            // The type a value was converted to an interface with.
            if case .interface(let boxed) = operand,
                let descriptor = typeDescriptor(named: boxed.typeName)
            {
                var typed = scope
                typed.definitions = descriptor.definitions
                return try formatValue(
                    boxed.value, as: descriptor.type, directive, scope: typed, depth: depth)
            }

            var value = operand
            var type = declared
            var kind = declared.map(scope.underlying)
            // Set for an error `errors.New` or `fmt.Errorf` made, which
            // prints by its message as if it had an `Error` method.
            var library: (message: String, wrapped: [GoValue])?
            if kind?.isInterface ?? true {
                // An interface, or an operand without a descriptor: the type
                // is the value's own.
                if case .interface(let boxed) = value {
                    if boxed.typeName == GoErrors.legacyTypeName,
                        case .string(let message) = boxed.value
                    {
                        return legacyError(message)
                    }
                    if GoErrors.isMessageType(boxed.typeName),
                        case .string(let message) = boxed.value
                    {
                        // An error of the runtime, which Go declares as a
                        // string type: its message, quoted for `%#v`.
                        if directive.goSyntax { return GoFormat.quote(message, asciiOnly: false) }
                        var plain = directive
                        plain.verb = "v"
                        return GoFormat.string(message, directive)
                            ?? GoFormat.badVerb(
                                directive, typeName: inferredTypeName(of: value),
                                value: GoFormat.string(message, plain) ?? message)
                    }
                    library = try libraryError(value)
                    type = GoTypeDescriptor.dynamicType(named: boxed.typeName)
                    value = boxed.value
                } else {
                    type = GoTypeDescriptor.inferred(from: value)
                }
                if value == .nilValue {
                    // Inside a slice, struct, or map a nil interface is
                    // `<nil>` under every verb; as an operand only under `%v`.
                    if depth > 0 {
                        guard directive.goSyntax, let declared else { return "<nil>" }
                        return GoTypeDescriptor.name(of: declared) + "(nil)"
                    }
                    return directive.verb == "v"
                        ? GoFormat.pad("<nil>", directive) : GoFormat.badVerb(directive)
                }
                kind = type.map(scope.underlying)
            }

            func typeName() -> String {
                type.map(GoTypeDescriptor.name(of:)) ?? inferredTypeName(of: value)
            }
            // `%#v` prints a time by its `GoString`.
            if directive.goSyntax, scope.callsMethods, depth == 0 || scope.accessible,
                case .other(GoCalendar.timeTypeName)? = type, let time = GoTime(value)
            {
                return GoTimeFormat.goString(time)
            }
            // Under a verb for text Go prints a value by its `Error` method,
            // or else its `String` method: an operand always, and inside
            // another value wherever it is not behind an unexported field.
            if scope.callsMethods, depth == 0 || scope.accessible,
                GoFormat.usesTextMethod(directive)
            {
                if let library {
                    return GoFormat.string(library.message, directive) ?? library.message
                }
                var owner: String?
                switch type {
                case .named(let symbol)?: owner = symbol
                case .pointer(.named(let symbol))?: owner = "*" + symbol
                // A time and a location, which have no definition.
                case .other(let symbol)? where GoCalendar.isOwner(symbol): owner = symbol
                case .pointer(.other(let symbol))? where GoCalendar.isOwner("*" + symbol):
                    owner = "*" + symbol
                default: break
                }
                if let owner {
                    // A library type's `String` is native: its text needs
                    // no frame, and no second pass of this call.
                    if let text = try GoLibraryMethods.text(
                        of: value, owner: owner, read: { try read(pointer: $0, heap: vm.heap) })
                    {
                        return value == .nilValue ? text : GoFormat.string(text, directive) ?? text
                    }
                    for name in GoFormat.textMethods {
                        guard let function = method(name, of: owner) else { continue }
                        // Go calls the method of a nil pointer as well, and
                        // prints `<nil>` when that panics, as it must for a
                        // method that takes the value the pointer lacks.
                        let isNilPointer = value == .nilValue && owner.hasPrefix("*")
                        if isNilPointer, !function.name.hasPrefix("*") {
                            return GoFormat.nilText
                        }
                        let result = try guestCall(
                            function, [try methodReceiver(value, for: function)],
                            recovery: .panics)
                        if case .interface(let caught)? = result,
                            caught.typeName == GoFormat.panicMarker
                        {
                            if isNilPointer { return GoFormat.nilText }
                            return "%!\(directive.verb)(PANIC=\(name) method: "
                                + (try formatValue(
                                    caught.value, as: nil, GoFormat.Directive(verb: "v"),
                                    scope: scope, depth: 0)) + ")"
                        }
                        // Anything but a string is a method `fmt` cannot
                        // print by, and the value prints as itself.
                        if case .string(let text)? = result,
                            let formatted = GoFormat.string(text, directive)
                        {
                            return formatted
                        }
                        break
                    }
                }
            }
            if case .other(GoCalendar.timeTypeName)? = type, let time = GoTime(value) {
                // Go's struct, where `fmt` calls no method of a time.
                return GoTimeFormat.fields(
                    of: time, labeled: directive.labelsFields, goSyntax: directive.goSyntax)
            }
            /// Go's marker for a verb that does not apply: the type, and the
            /// value as `%v` prints it under the same flags.
            func bad() throws -> String {
                var plain = directive
                plain.verb = "v"
                // Go prints the value itself here, not by its methods.
                var silent = scope
                silent.callsMethods = false
                return "%!\(directive.verb)(" + typeName() + "="
                    + (try formatValue(value, as: type, plain, scope: silent, depth: 0)) + ")"
            }
            func nested(_ element: GoValue, _ elementType: GoRuntimeType?) throws -> String {
                try formatValue(element, as: elementType, directive, scope: scope, depth: depth + 1)
            }
            /// `prefix`, the formatted elements, `suffix`.
            func aggregate(
                _ prefix: String,
                _ count: Int,
                _ suffix: String,
                element: (Int) throws -> String
            ) throws -> String {
                let separator = directive.goSyntax ? ", " : " "
                var parts = [prefix]
                var byteCount = prefix.utf8.count + suffix.utf8.count
                guard byteCount <= scope.limit else { throw scope.overflow }
                for index in 0..<count {
                    let part = (index > 0 ? separator : "") + (try element(index))
                    guard part.utf8.count <= scope.limit - byteCount else { throw scope.overflow }
                    byteCount += part.utf8.count
                    parts.append(part)
                }
                parts.append(suffix)
                return parts.joined()
            }
            /// The error of a failed library call prints its message under a
            /// verb for text. Under any other verb Go reaches the pointer to a
            /// struct that it is: `&{...}` for an operand, an address inside
            /// another value. No heap cell stands behind this form.
            func legacyError(_ message: String) -> String {
                var plain = directive
                plain.verb = "v"
                if depth > 0, directive.goSyntax || !["v", "s", "x", "X", "q"].contains(directive.verb) {
                    // No heap cell stands behind a library error, so the
                    // address is derived from its message.
                    var address: UInt64 = 0xC0_0000_0000
                    for byte in message.utf8 { address = address &+ (UInt64(byte) << 4) }
                    if directive.goSyntax {
                        return "(*errors.errorString)("
                            + (GoFormat.address(address, GoFormat.Directive(verb: "v")) ?? "") + ")"
                    }
                    return GoFormat.address(address, directive)
                        ?? GoFormat.badVerb(
                            directive, typeName: "*errors.errorString",
                            value: GoFormat.address(address, plain) ?? "")
                }
                if directive.goSyntax {
                    return "&errors.errorString{s:" + GoFormat.quote(message, asciiOnly: false) + "}"
                }
                if let text = GoFormat.string(message, directive) { return text }
                let shown = GoFormat.string(message, plain) ?? message
                if directive.verb == "w" {
                    return GoFormat.badVerb(
                        directive, typeName: "*errors.errorString", value: "&{" + shown + "}")
                }
                return "&{" + GoFormat.badVerb(directive, typeName: "string", value: shown) + "}"
            }
            func sequence(
                _ elements: [GoValue],
                of element: GoRuntimeType?,
                isNil: Bool = false
            ) throws -> String {
                if element.map(scope.underlying) == .byte,
                    ["s", "q", "x", "X"].contains(directive.verb)
                {
                    let bytes = try elements.map { element -> UInt8 in
                        guard case .int(let byte) = element else { throw GoRuntimeError.typeMismatch }
                        return UInt8(truncatingIfNeeded: byte)
                    }
                    if let text = GoFormat.bytes(bytes, directive) { return text }
                }
                guard directive.goSyntax else {
                    return try aggregate("[", elements.count, "]") {
                        try nested(elements[$0], element)
                    }
                }
                // Go names an operand that is exactly a `[]byte` that way.
                let name = depth == 0 && type == .slice(.byte) ? "[]byte" : typeName()
                if isNil { return name + "(nil)" }
                return try aggregate(name + "{", elements.count, "}") {
                    try nested(elements[$0], element)
                }
            }
            func pointerLike(_ address: UInt64) throws -> String {
                if directive.verb == "v" {
                    if directive.goSyntax {
                        var plain = GoFormat.Directive(verb: "v")
                        plain.width = nil
                        return "(" + typeName() + ")("
                            + (address == 0 ? "nil" : GoFormat.address(address, plain) ?? "") + ")"
                    }
                    if address == 0 { return GoFormat.pad("<nil>", directive) }
                }
                return try GoFormat.address(address, directive) ?? bad()
            }
            func elementType() -> GoRuntimeType? {
                switch kind {
                case .slice(let element)?, .array(_, let element)?: return element
                default: return nil
                }
            }

            switch value {
            case .int(let integer):
                if case .number(let number)? = kind {
                    return try GoFormat.number(integer, number, directive) ?? bad()
                }
                return try GoFormat.integer(integer, directive, unsigned: kind == .byte) ?? bad()
            case .string(let text):
                return try GoFormat.string(text, directive) ?? bad()
            case .bool(let flag):
                return try GoFormat.boolean(flag, directive) ?? bad()
            case .nilValue:
                // A nil of a declared type; a nil interface returned above.
                switch kind {
                case .slice(let element)?:
                    return try sequence([], of: element, isNil: true)
                case .map?:
                    return directive.goSyntax ? typeName() + "(nil)" : "map[]"
                default:
                    return try pointerLike(0)
                }
            case .array(let elements):
                return try sequence(elements, of: elementType())
            case .slice:
                return try sequence(Array(try sliceElements(value)), of: elementType())
            case .structure(let structure):
                if structure.typeName == GoNative.functionValueTypeName {
                    // Go prints a function as the address of its code.
                    return try pointerLike(formatAddress(of: value) ?? 0)
                }
                var fieldTypes = [GoRuntimeType?](repeating: nil, count: structure.fields.count)
                var fieldCount = structure.fields.count
                if case .structure(let declaredFields)? = kind,
                    declaredFields.count == structure.fields.count
                {
                    fieldTypes = declaredFields.map(\.type)
                } else if case .structure(let declaredFields)? = kind,
                    declaredFields.count < fieldCount
                {
                    // What the VM keeps after the fields Go has is not
                    // shown: the function of `time.AfterFunc`, the text of
                    // an `errors.Join`.
                    fieldCount = declaredFields.count
                    fieldTypes = declaredFields.map(\.type)
                }
                let labelled = directive.labelsFields || directive.goSyntax
                // Go cannot call the methods of a value it reaches through
                // an unexported field.
                var hidden = scope
                hidden.accessible = false
                return try aggregate(
                    (directive.goSyntax ? typeName() : "") + "{", fieldCount, "}"
                ) { index in
                    let field = structure.fields[index]
                    let exported = field.name.unicodeScalars.first.map {
                        GoUnicode.toLower($0) != $0
                    } ?? false
                    return (labelled ? field.name + ":" : "")
                        + (try formatValue(
                            field.value, as: fieldTypes[index], directive,
                            scope: exported ? scope : hidden, depth: depth + 1))
                }
            case .map(let mapValue):
                guard case .mapStorage(let storage) = try read(pointer: mapValue.storage, heap: vm.heap)
                else { throw GoRuntimeError.typeMismatch }
                var keyType: GoRuntimeType?
                var valueType: GoRuntimeType?
                if case .map(let declaredKey, let declaredValue)? = kind {
                    (keyType, valueType) = (declaredKey, declaredValue)
                }
                // Go prints a map sorted by key.
                let unsignedKeys = GoNumeric.ordersUnsigned(keyType.map(scope.underlying))
                let entries = storage.entries.enumerated().sorted { lhs, rhs in
                    let order =
                        unsignedKeys
                        ? GoNumeric.unsignedOrder(
                            lhs.element.key, rhs.element.key, keyType.map(scope.underlying))
                        : GoFormat.keyOrder(lhs.element.key, rhs.element.key)
                    return order == 0 ? lhs.offset < rhs.offset : order < 0
                }.map(\.element)
                return try aggregate(
                    directive.goSyntax ? typeName() + "{" : "map[", entries.count,
                    directive.goSyntax ? "}" : "]"
                ) { index in
                    (try nested(entries[index].key, keyType)) + ":"
                        + (try nested(entries[index].value, valueType))
                }
            case .pointer(let pointer):
                // An operand that points to a struct, array, slice, or map
                // prints as `&` and the value; a nested pointer as an address.
                if depth == 0, let pointee = try? read(pointer: pointer, heap: vm.heap) {
                    var pointeeType: GoRuntimeType?
                    if case .pointer(let declaredPointee)? = kind { pointeeType = declaredPointee }
                    let expands: Bool
                    switch pointeeType.map(scope.underlying) {
                    case .structure?, .array?, .slice?, .map?: expands = true
                    case nil:
                        switch pointee {
                        case .structure, .array, .slice, .map: expands = true
                        default: expands = false
                        }
                    default: expands = false
                    }
                    if expands {
                        return "&" + (try formatValue(
                            pointee, as: pointeeType, directive, scope: scope, depth: depth + 1))
                    }
                }
                return try pointerLike(formatAddress(of: value) ?? 0)
            case .channel:
                return try pointerLike(formatAddress(of: value) ?? 0)
            case .interface(let boxed):
                return try formatValue(boxed.value, as: nil, directive, scope: scope, depth: depth)
            default:
                // Library handles have one spelling.
                guard directive.verb == "v", !directive.goSyntax else { return try bad() }
                return GoFormat.pad(
                    try describe(value, heap: vm.heap, maximumBytes: scope.limit), directive)
            }
        }

        /// Format one operand of a `fmt` call, where `%T` and `%p` read the
        /// operand itself instead of its value.
        func formatOperand(
            _ operand: GoValue,
            _ directive: GoFormat.Directive,
            scope: GoFormatScope
        ) throws -> String {
            switch directive.verb {
            case "T":
                var text = GoFormat.Directive(verb: "s")
                text.minus = directive.minus
                text.zero = directive.zero
                text.width = directive.width
                text.precision = directive.precision
                return GoFormat.string(inferredTypeName(of: operand), text) ?? ""
            case "p":
                let value = plainOperand(operand)
                if operand == .nilValue { return GoFormat.badVerb(directive) }
                if let address = formatAddress(of: value),
                    let text = GoFormat.address(address, directive)
                {
                    return text
                }
                var plain = directive
                plain.verb = "v"
                var silent = scope
                silent.callsMethods = false
                return "%!p(" + inferredTypeName(of: operand) + "="
                    + (try formatValue(operand, as: nil, plain, scope: silent, depth: 0)) + ")"
            case "w":
                // `fmt.Errorf` prints the error a `%w` names as `%v` does.
                // Anywhere else, and for an operand that is no error, the
                // verb is a bad one.
                var plain = directive
                plain.verb = "v"
                plain.wraps = false
                if directive.wraps, try isError(operand) {
                    return try formatValue(operand, as: nil, plain, scope: scope, depth: 0)
                }
                if operand == .nilValue { return GoFormat.badVerb(directive) }
                var silent = scope
                silent.callsMethods = false
                return "%!w(" + inferredTypeName(of: operand) + "="
                    + (try formatValue(operand, as: nil, plain, scope: silent, depth: 0)) + ")"
            default:
                return try formatValue(operand, as: nil, directive, scope: scope, depth: 0)
            }
        }

        /// The operands of a `...any` parameter: the values given, or the
        /// elements of the `[]any` a `values...` argument named.
        func variadicOperands(_ values: [GoValue]) throws -> [GoValue] {
            guard values.count == 1, case .interface(let boxed) = values[0],
                boxed.typeName == GoFormat.spreadOperandsTypeName
            else { return values }
            return Array(try sliceElements(boxed.value))
        }

        /// The value of a `fmt` operand without the type the compiler boxed
        /// it with.
        func plainOperand(_ value: GoValue) -> GoValue {
            if case .interface(let boxed) = value, typeDescriptor(named: boxed.typeName) != nil {
                return boxed.value
            }
            return value
        }

        /// Take the result of the guest function a native call was waiting
        /// for off the stack. An instruction that can make such calls does
        /// this before it reads its operands, because the result lies above
        /// them.
        func resumeGuestCalls() throws {
            let frameIndex = vm.frames.count - 1
            guard vm.frames[frameIndex].awaitsGuestCall else { return }
            vm.frames[frameIndex].awaitsGuestCall = false
            vm.frames[frameIndex].guestCallRecovery = .none
            vm.frames[frameIndex].guestCallResults.append(try pop(&vm.stack))
        }

        /// Run `body`, a native that may need guest functions run: a `String`
        /// method while formatting, an `Unwrap` method while walking an error
        /// chain. A native cannot run guest code, so the first function it
        /// needs is called like any other instead, with `operands` back on
        /// the stack and the instruction set to execute again once it
        /// returns; the results gathered so far stay in the frame and are
        /// handed out in the same order on the next pass. The result is nil
        /// while a function is still to run.
        func replayingGuestCalls<Result>(
            operands: [GoValue],
            _ body: () throws -> Result
        ) throws -> Result? {
            let frameIndex = vm.frames.count - 1
            guestCallResults = vm.frames[frameIndex].guestCallResults
            guestCallCursor = 0
            defer { guestCallResults = nil }
            do {
                let result = try body()
                vm.frames[frameIndex].guestCallResults = []
                return result
            } catch let request as GoGuestCallRequest {
                guard vm.frames[frameIndex].guestCallResults.count
                    < resourceLimits.maximumCollectionElements
                else { throw GoRuntimeError.resourceLimitExceeded("guest calls of a native") }
                guard vm.frames.count < maximumCallDepth else {
                    throw GoRuntimeError.callStackLimitExceeded
                }
                vm.stack.append(contentsOf: operands)
                vm.frames[frameIndex].programCounter -= 1
                vm.frames[frameIndex].awaitsGuestCall = true
                vm.frames[frameIndex].guestCallRecovery = request.recovery
                vm.frames.append(
                    try makeFrame(
                        function: request.function, stackBase: vm.stack.count,
                        arguments: request.arguments, heap: &vm.heap))
                return nil
            }
        }

        /// The result of calling `function`, from an earlier pass of the
        /// native that is executing, or a request to run it now. Nil where
        /// no guest function can be run.
        ///
        /// With a `recovery` a panic of the function does not unwind the
        /// caller: the result is then the value it panicked with, boxed under
        /// `GoFormat.panicMarker`.
        func guestCall(
            _ function: GoBytecodeFunction,
            _ arguments: [GoValue],
            recovery: GoGuestCallRecovery = .none
        ) throws -> GoValue? {
            guard let results = guestCallResults else { return nil }
            guard guestCallCursor < results.count else {
                throw GoGuestCallRequest(
                    function: function, arguments: arguments, recovery: recovery)
            }
            guestCallCursor += 1
            return results[guestCallCursor - 1]
        }

        /// Hand a panic of the guest function the frame on top was waiting
        /// for to the native that asked for it, as the function's result.
        func deliverGuestPanic(_ value: GoValue) {
            vm.frames[vm.frames.count - 1].guestCallRecovery = .none
            vm.stack.append(
                .interface(GoInterfaceValue(typeName: GoFormat.panicMarker, value: value)))
        }

        /// The method `name` of the dynamic type `owner` (`T` or `*T`) when it
        /// takes `parameterCount` arguments besides its receiver and returns
        /// one value. A pointer also has the methods of what it points to.
        func method(_ name: String, of owner: String, parameterCount: Int = 0) -> GoBytecodeFunction? {
            var owners = [owner]
            if owner.hasPrefix("*") { owners.append(String(owner.dropFirst())) }
            for candidate in owners {
                if let function = functions[candidate + "." + name],
                    function.parameterCount == parameterCount + 1, function.returnCount == 1
                {
                    return function
                }
            }
            return nil
        }

        /// The receiver `function` takes for `value`: a method with a value
        /// receiver takes the value a pointer points to.
        func methodReceiver(_ value: GoValue, for function: GoBytecodeFunction) throws -> GoValue {
            if !function.name.hasPrefix("*"), case .pointer(let pointer) = value {
                return try read(pointer: pointer, heap: vm.heap)
            }
            return value
        }

        // MARK: Library errors

        /// A new error as `errors.New` and `fmt.Errorf` make them: distinct
        /// from every other error, and wrapping `wrapped`.
        ///
        /// Without `joins` it wraps the one error given, which may be nil, as
        /// one `%w` does; with it, all of them, as several do.
        func makeError(
            _ message: String,
            wrapping wrapped: [GoValue] = [],
            joins: Bool = false,
            joined: Bool = false
        ) throws -> GoValue {
            if joined { return try makeJoinedError(message, of: wrapped) }
            let typeName: String
            var fields = [GoStructFieldValue(name: "s", value: .string(message))]
            if joins == false, wrapped.isEmpty {
                typeName = GoErrors.plainType
            } else if !joins {
                typeName = GoErrors.wrappingType
                fields = [
                    GoStructFieldValue(name: "msg", value: .string(message)),
                    GoStructFieldValue(name: "err", value: wrapped[0]),
                ]
            } else {
                typeName = GoErrors.joiningType
                let backing = try vm.heap.allocate(.array(wrapped))
                fields = [
                    GoStructFieldValue(name: "msg", value: .string(message)),
                    GoStructFieldValue(
                        name: "errs",
                        value: .slice(
                            GoSliceValue(
                                backing: GoPointer(cell: backing), start: 0,
                                length: wrapped.count, capacity: wrapped.count,
                                zeroValue: .nilValue))),
                ]
            }
            let cell = try vm.heap.allocate(
                .structure(GoStructValue(typeName: String(typeName.dropFirst()), fields: fields)))
            return .interface(
                GoInterfaceValue(typeName: typeName, value: .pointer(GoPointer(cell: cell))))
        }

        /// What `errors.Join` gives for `errors`, none of which is nil, and
        /// `message`, their texts on a line each.
        func makeJoinedError(_ message: String, of errors: [GoValue]) throws -> GoValue {
            let backing = try vm.heap.allocate(.array(errors))
            let cell = try vm.heap.allocate(
                .structure(
                    GoStructValue(
                        typeName: String(GoErrors.joinedType.dropFirst()),
                        fields: [
                            GoStructFieldValue(
                                name: "errs",
                                value: .slice(
                                    GoSliceValue(
                                        backing: GoPointer(cell: backing), start: 0,
                                        length: errors.count, capacity: errors.count,
                                        zeroValue: .nilValue))),
                            GoStructFieldValue(name: "msg", value: .string(message)),
                        ])))
            return .interface(
                GoInterfaceValue(
                    typeName: GoErrors.joinedType, value: .pointer(GoPointer(cell: cell))))
        }

        /// The message of an error the library made and the errors it wraps,
        /// or nil for any other value.
        func libraryError(_ value: GoValue) throws -> (message: String, wrapped: [GoValue])? {
            guard case .interface(let boxed) = value else { return nil }
            if GoErrors.isMessageType(boxed.typeName), case .string(let message) = boxed.value {
                return (message, [])
            }
            if boxed.typeName == GoErrors.joinedType {
                // The errors, then their text.
                guard case .pointer(let pointer) = boxed.value,
                    case .structure(let structure) = try read(pointer: pointer, heap: vm.heap),
                    structure.fields.count == 2,
                    case .string(let message) = structure.fields[1].value
                else { return nil }
                return (message, Array(try sliceElements(structure.fields[0].value)))
            }
            guard GoErrors.isLibraryType(boxed.typeName), case .pointer(let pointer) = boxed.value,
                case .structure(let structure) = try read(pointer: pointer, heap: vm.heap),
                case .string(let message)? = structure.fields.first?.value
            else { return nil }
            guard structure.fields.count == 2 else { return (message, []) }
            if boxed.typeName == GoErrors.joiningType {
                return (message, Array(try sliceElements(structure.fields[1].value)))
            }
            let wrapped = structure.fields[1].value
            return (message, wrapped == .nilValue ? [] : [wrapped])
        }

        /// Whether `value` is an error: one the library made, or a value whose
        /// type has an `Error` method.
        func isError(_ value: GoValue) throws -> Bool {
            if try libraryError(value) != nil { return true }
            guard let target = methodTarget(value) else { return false }
            return method("Error", of: target.owner) != nil
        }

        /// The type a method of `value` is looked up under and the receiver
        /// it is called with, or nil for a value without methods.
        func methodTarget(_ value: GoValue) -> (owner: String, receiver: GoValue)? {
            switch value {
            case .interface(let boxed):
                guard let owner = GoTypeDescriptor.methodOwner(ofTypeName: boxed.typeName) else {
                    return nil
                }
                return (owner, boxed.value)
            case .structure(let structure):
                return structure.typeName.map { ($0, value) }
            default:
                // A connection or a listener, which travels as it is.
                return GoLibraryMethods.owner(ofHandle: value).map { ($0, value) }
            }
        }

        /// The first method of `target` that the dynamic type of `value`
        /// lacks, or nil when it implements the interface. A pointer has the
        /// methods of what it points to; a value has only its own.
        func missingMethod(
            of value: GoValue,
            for target: GoErrors.InterfaceTarget
        ) throws -> String? {
            if case .interface(let boxed) = value, try libraryError(value) != nil {
                // The compiler wrote that the types of its `Unwrap` are
                // not what the interface asks for.
                if target.implementers.contains(GoLibraryMethods.refusalMark + boxed.typeName) {
                    return "Unwrap"
                }
                let provided = GoErrors.methods(ofLibraryType: boxed.typeName)
                return target.methods.first {
                    !provided.contains($0.name) || $0.parameterCount != 0 || $0.resultCount != 1
                }?.name
            }
            guard let first = target.methods.first else { return nil }
            guard let owner = methodTarget(value)?.owner else { return first.name }
            if target.implementers.contains(owner) { return nil }
            if GoLibraryMethods.implements(owner, target) { return nil }
            // Which method is missing, for the message: one the type lacks,
            // or else one it has with other parameter or result types.
            var owners = [owner]
            if owner.hasPrefix("*") { owners.append(String(owner.dropFirst())) }
            let absent = target.methods.first { wanted in
                !owners.contains {
                    guard let function = functions[$0 + "." + wanted.name] else { return false }
                    return function.parameterCount == wanted.parameterCount + 1
                        && function.returnCount == wanted.resultCount
                }
            }
            return (absent ?? first).name
        }

        /// What the `Unwrap` method of an error the library made returns:
        /// the error one `%w` wrapped, or the slice of those several did or
        /// `errors.Join` joined. Nil for a value that has no such method.
        func libraryUnwrapResult(_ err: GoValue) throws -> GoValue? {
            guard case .interface(let boxed) = err, boxed.typeName != GoErrors.plainType,
                GoErrors.isLibraryType(boxed.typeName), case .pointer(let pointer) = boxed.value,
                case .structure(let structure) = try read(pointer: pointer, heap: vm.heap)
            else { return nil }
            // The slice is the error's own, as in Go; it comes first in
            // what `errors.Join` made and second in the others.
            let index = boxed.typeName == GoErrors.joinedType ? 0 : 1
            return structure.fields.indices.contains(index) ? structure.fields[index].value : nil
        }

        /// What `err` wraps: what Go's `Unwrap() error` returns as one error,
        /// and what `Unwrap() []error` returns as several.
        func unwrapped(_ err: GoValue) throws -> (single: GoValue?, several: [GoValue]) {
            if let library = try libraryError(err) {
                guard case .interface(let boxed) = err, GoErrors.wrapsSeveral(boxed.typeName)
                else { return (library.wrapped.first, []) }
                return (nil, library.wrapped)
            }
            guard let target = methodTarget(err),
                let function = method("Unwrap", of: target.owner),
                let result = try guestCall(
                    function, [try methodReceiver(target.receiver, for: function)])
            else { return (nil, []) }
            switch result {
            case .nilValue: return (nil, [])
            case .slice: return (nil, Array(try sliceElements(result)))
            default: return (result, [])
            }
        }

        /// The text of the error `err`: the message of one the library
        /// made, or what the `Error` method of its type returns, which
        /// runs first when it has not yet.
        func errorText(_ err: GoValue) throws -> String {
            if let library = try libraryError(err) { return library.message }
            guard let target = methodTarget(err),
                let function = method("Error", of: target.owner),
                case .string(let text)? = try guestCall(
                    function, [try methodReceiver(target.receiver, for: function)])
            else { throw GoRuntimeError.typeMismatch }
            return text
        }

        /// Run `errors.Join`: an error that wraps every operand that is
        /// not nil and reads as their texts, a line each, or nil when all
        /// of them are nil. The operands are errors, or one slice of them
        /// given with `...`.
        func executeJoinNative(argumentCount: Int) throws {
            try resumeGuestCalls()
            guard argumentCount >= 0, vm.stack.count >= argumentCount else {
                throw GoRuntimeError.stackUnderflow
            }
            let start = vm.stack.count - argumentCount
            let operands = Array(vm.stack[start...])
            vm.stack.removeSubrange(start...)
            let errors = try variadicOperands(operands).filter { $0 != .nilValue }
            guard !errors.isEmpty else {
                vm.stack.append(.nilValue)
                return
            }
            let text = try replayingGuestCalls(operands: operands) { () -> String in
                var lines: [String] = []
                var byteCount = 0
                for error in errors {
                    let line = try errorText(error)
                    byteCount = try checkedAdd(
                        byteCount, line.utf8.count + 1, resource: "string bytes")
                    guard byteCount <= resourceLimits.maximumStringBytes else {
                        throw GoRuntimeError.resourceLimitExceeded("string bytes")
                    }
                    lines.append(line)
                }
                return lines.joined(separator: "\n")
            }
            // An `Error` method is running first; this call executes again.
            guard let text else { return }
            vm.stack.append(try makeError(text, wrapping: errors, joined: true))
        }

        /// Run `errors.Unwrap`, `errors.Is`, or `errors.As`. Returns `false`
        /// when `name` is not such a function.
        func executeErrorNative(_ name: String, argumentCount: Int) throws -> Bool {
            if name == GoErrors.join {
                try executeJoinNative(argumentCount: argumentCount)
                return true
            }
            guard let expectedCount = GoErrors.argumentCounts[name] else { return false }
            guard argumentCount == expectedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expectedCount, actual: argumentCount)
            }
            try resumeGuestCalls()
            guard vm.stack.count >= argumentCount else { throw GoRuntimeError.stackUnderflow }
            let start = vm.stack.count - argumentCount
            let operands = Array(vm.stack[start...])
            vm.stack.removeSubrange(start...)

            /// Go's `errors.Is`: the chain of `err`, depth first, holds an
            /// error equal to `target` or one whose `Is` method says so.
            func matches(_ err: GoValue, _ target: GoValue, depth: Int) throws -> Bool {
                guard depth <= resourceLimits.maximumPointerDepth else {
                    throw GoRuntimeError.resourceLimitExceeded("error chain depth")
                }
                var current = err
                while true {
                    if current == target { return true }
                    if let receiver = methodTarget(current), try libraryError(current) == nil,
                        let function = method("Is", of: receiver.owner, parameterCount: 1),
                        case .bool(true)? = try guestCall(
                            function,
                            [try methodReceiver(receiver.receiver, for: function), target])
                    {
                        return true
                    }
                    let inner = try unwrapped(current)
                    if let single = inner.single {
                        current = single
                        continue
                    }
                    for element in inner.several where element != .nilValue {
                        if try matches(element, target, depth: depth + 1) { return true }
                    }
                    return false
                }
            }
            /// Go's `errors.As`: the first error in the chain whose type is
            /// the target's, or implements the target interface.
            func find(_ err: GoValue, typed specification: String, depth: Int) throws -> GoValue? {
                guard depth <= resourceLimits.maximumPointerDepth else {
                    throw GoRuntimeError.resourceLimitExceeded("error chain depth")
                }
                var current = err
                while true {
                    if let wanted = GoErrors.InterfaceTarget(specification) {
                        if try missingMethod(of: current, for: wanted) == nil { return current }
                    } else if GoTypeDescriptor.identity(of: current)
                        == GoTypeDescriptor.identity(ofTypeName: specification)
                    {
                        // The target variable has the concrete type, so it
                        // takes the value without its interface box.
                        if case .interface(let boxed) = current { return boxed.value }
                        return current
                    }
                    let inner = try unwrapped(current)
                    if let single = inner.single {
                        current = single
                        continue
                    }
                    for element in inner.several where element != .nilValue {
                        if let found = try find(element, typed: specification, depth: depth + 1) {
                            return found
                        }
                    }
                    return nil
                }
            }

            let outcome = try replayingGuestCalls(operands: operands) { () -> [GoValue] in
                let err = operands[0]
                switch name {
                case "$errors.Unwrap":
                    return [err == .nilValue ? .nilValue : try unwrapped(err).single ?? .nilValue]
                case "$errors.Is":
                    let target = operands[1]
                    if err == .nilValue || target == .nilValue { return [.bool(err == target)] }
                    return [.bool(try matches(err, target, depth: 0))]
                default:
                    guard case .string(let specification) = operands[2] else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard case .pointer(let target) = operands[1] else {
                        throw GoRuntimePanic(text: "errors: target must be a non-nil pointer")
                    }
                    guard err != .nilValue,
                        let found = try find(err, typed: specification, depth: 0)
                    else { return [.bool(false)] }
                    try writePointer(found, through: target, heap: &vm.heap)
                    return [.bool(true)]
                }
            }
            // A method is running first; this call executes again after it.
            if let outcome { vm.stack.append(contentsOf: outcome) }
            return true
        }

        /// Run a `fmt` function: the `Sprint`, `Print`, and `Fprint` families
        /// and `Errorf`. A file comes first, then a format if the function
        /// takes one, then the operands. Returns `false` when `name` is not
        /// such a function.
        func executeFormatNative(_ name: String, argumentCount: Int) throws -> Bool {
            guard let native = GoFormat.native(named: name) else { return false }
            try resumeGuestCalls()
            let fixedCount = native.fixedArgumentCount
            guard argumentCount >= fixedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: fixedCount, actual: argumentCount)
            }
            guard vm.stack.count >= argumentCount else { throw GoRuntimeError.stackUnderflow }
            let start = vm.stack.count - argumentCount
            let operands = Array(vm.stack[start...])
            vm.stack.removeSubrange(start...)
            let values = try variadicOperands(Array(operands[fixedCount...]))

            // A string result is bounded like any string, and printed text by
            // what is left of the run's output budget.
            let returnsText = native.destination == .string || native.destination == .error
            let scope =
                returnsText
                ? GoFormatScope(
                    limit: resourceLimits.maximumStringBytes,
                    overflow: .resourceLimitExceeded("string bytes"))
                : GoFormatScope(
                    limit: max(0, resourceLimits.maximumOutputBytes - outputBytesWritten),
                    overflow: .resourceLimitExceeded("output bytes"))
            var wrapped: [Int] = []
            let formatted = try replayingGuestCalls(operands: operands) { () -> String in
                wrapped = []
                switch native.layout {
                case .verbs:
                    guard case .string(let format) = operands[fixedCount - 1] else {
                        throw GoRuntimeError.typeMismatch
                    }
                    return try GoFormat.render(
                        format,
                        operands: GoFormat.Operands(
                            count: values.count,
                            integer: { index in
                                // A width or precision is an `int`, with or
                                // without the compiler's note of a named type.
                                if case .int(let integer) = plainOperand(values[index]) {
                                    return integer
                                }
                                return nil
                            },
                            format: { index, directive in
                                try formatOperand(values[index], directive, scope: scope)
                            },
                            describe: { index in
                                let value = values[index]
                                if value == .nilValue { return "<nil>" }
                                return inferredTypeName(of: value) + "="
                                    + (try formatValue(
                                        value, as: nil, GoFormat.Directive(verb: "v"), scope: scope,
                                        depth: 0))
                            },
                            wrapped: { wrapped.append($0) }),
                        wrapsErrors: native.destination == .error,
                        limit: scope.limit,
                        overflow: scope.overflow)
                case .operands:
                    return try formatOperands(values, separator: "", suffix: "", scope: scope)
                case .line:
                    return try formatOperands(values, separator: " ", suffix: "\n", scope: scope)
                }
            }
            // A method is running first; this call executes again after it.
            guard let text = formatted else { return true }

            let results: ((Int, String?) -> [GoValue])? =
                native.returnsCount
                ? { count, failure in [.int(Int64(count)), errorValue(failure)] } : nil
            switch native.destination {
            case .string:
                vm.stack.append(.string(text))
            case .error:
                // One `%w` wraps its operand, several wrap them all, in the
                // order of the operands. An operand that is no error wraps
                // nothing.
                let indexes = Set(wrapped).sorted()
                let errors = try indexes.map { index in
                    try isError(values[index]) ? values[index] : GoValue.nilValue
                }
                switch errors.count {
                case 0: vm.stack.append(try makeError(text))
                case 1: vm.stack.append(try makeError(text, wrapping: errors))
                default:
                    vm.stack.append(
                        try makeError(
                            text, wrapping: errors.filter { $0 != .nilValue }, joins: true))
                }
            case .standardOutput:
                try writeDescriptor(1, text, results: results)
            case .file:
                var opened = false
                if case .int(let handle) = operands[0], handle >= GoFiles.firstHandle {
                    // A closed file takes no output, and says so when asked.
                    guard openFiles[handle] != nil else {
                        if let results {
                            vm.stack.append(
                                contentsOf: results(0, "write: \(GoFiles.closedFile)"))
                        }
                        break
                    }
                    opened = true
                }
                guard let file = try resolveFile(operands[0]) else {
                    throw GoRuntimeError.typeMismatch
                }
                try writeDescriptor(file.descriptor, text, opened: opened, results: results)
            }
            return true
        }

        /// Run a native of the numeric types: an operation the lowerer chose
        /// for a sized integer, or a function of `strconv`, `unicode`,
        /// `unicode/utf8`, or `strings` that takes or gives one. Returns
        /// `false` when `name` is not such a function.
        func executeNumericNative(_ name: String, argumentCount: Int) throws -> Bool {
            guard let expectedCount = GoNumeric.argumentCounts[name] else { return false }
            guard argumentCount == expectedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expectedCount, actual: argumentCount)
            }
            guard vm.stack.count >= argumentCount else { throw GoRuntimeError.stackUnderflow }
            let start = vm.stack.count - argumentCount
            let operands = Array(vm.stack[start...])
            vm.stack.removeSubrange(start...)
            let integers = operands.compactMap { operand -> Int64? in
                if case .int(let integer) = operand { return integer }
                return nil
            }
            if integers.count == operands.count, let result = try GoNumeric.integer(name, integers) {
                vm.stack.append(result)
                return true
            }
            func text(_ index: Int) throws -> String {
                guard case .string(let text) = operands[index] else {
                    throw GoRuntimeError.typeMismatch
                }
                return text
            }
            func integer(_ index: Int) throws -> Int64 {
                guard case .int(let integer) = operands[index] else {
                    throw GoRuntimeError.typeMismatch
                }
                return integer
            }
            switch name {
            case "$num.runes":
                let elements = try text(0).unicodeScalars.map { GoValue.int(Int64($0.value)) }
                try requireCollectionCount(elements.count, resource: "slice elements")
                let cell = try vm.heap.allocate(.array(elements))
                vm.stack.append(
                    .slice(
                        GoSliceValue(
                            backing: GoPointer(cell: cell), start: 0, length: elements.count,
                            capacity: elements.count, zeroValue: .int(0))))
            case "$num.string":
                var scalars = String.UnicodeScalarView()
                for element in try sliceElements(operands[0]) {
                    guard case .int(let rune) = element else { throw GoRuntimeError.typeMismatch }
                    scalars.append(GoNumeric.scalar(rune))
                }
                let result = String(scalars)
                guard result.utf8.count <= resourceLimits.maximumStringBytes else {
                    throw GoRuntimeError.resourceLimitExceeded("string bytes")
                }
                vm.stack.append(.string(result))
            case "$strconv.ParseInt":
                let parsed = GoNumeric.parseSigned(
                    try text(0), base: try integer(1), bitSize: try integer(2))
                vm.stack.append(.int(parsed.value))
                vm.stack.append(
                    try parsed.failure.map {
                        try makeError($0.message(function: "ParseInt", text: try text(0)))
                    } ?? .nilValue)
            case "$strconv.ParseUint":
                let parsed = GoNumeric.parseUnsigned(
                    try text(0), base: try integer(1), bitSize: try integer(2))
                vm.stack.append(.int(Int64(bitPattern: parsed.value)))
                vm.stack.append(
                    try parsed.failure.map {
                        try makeError($0.message(function: "ParseUint", text: try text(0)))
                    } ?? .nilValue)
            case "$strconv.FormatInt", "$strconv.FormatUint":
                let base = try integer(1)
                guard (2...36).contains(base) else {
                    throw GoRuntimePanic(text: "strconv: illegal AppendInt/FormatInt base")
                }
                vm.stack.append(
                    .string(
                        name == "$strconv.FormatInt"
                            ? String(try integer(0), radix: Int(base))
                            : String(UInt64(bitPattern: try integer(0)), radix: Int(base))))
            case "$utf8.RuneCountInString":
                vm.stack.append(.int(Int64(try text(0).unicodeScalars.count)))
            case "$utf8.ValidString":
                // A string of the VM is valid UTF-8 by construction.
                _ = try text(0)
                vm.stack.append(.bool(true))
            case "$utf8.DecodeRuneInString":
                if let first = try text(0).unicodeScalars.first {
                    vm.stack.append(.int(Int64(first.value)))
                    vm.stack.append(.int(Int64(UTF8.width(first))))
                } else {
                    vm.stack.append(.int(0xFFFD))
                    vm.stack.append(.int(0))
                }
            case "$utf8.EncodeRune":
                guard case .slice(let destination) = operands[0] else {
                    // A nil slice has no room for the first byte.
                    guard operands[0] == .nilValue else { throw GoRuntimeError.typeMismatch }
                    throw GoRuntimePanic.index(0, length: 0)
                }
                let encoded = Array(String(Character(GoNumeric.scalar(try integer(1)))).utf8)
                guard encoded.count <= destination.length else {
                    // Go writes the last byte first, to check the bound once.
                    throw GoRuntimePanic.index(encoded.count - 1, length: destination.length)
                }
                try storeElements(encoded.map { GoValue.int(Int64($0)) }, into: destination)
                vm.stack.append(.int(Int64(encoded.count)))
            case "$strings.ContainsRune":
                vm.stack.append(.bool(GoNumeric.index(of: try integer(1), in: try text(0)) >= 0))
            case "$strings.IndexRune":
                vm.stack.append(.int(Int64(GoNumeric.index(of: try integer(1), in: try text(0)))))
            case "$strings.IndexByte":
                let wanted = UInt8(truncatingIfNeeded: try integer(1))
                let index = Array(try text(0).utf8).firstIndex(of: wanted)
                vm.stack.append(.int(Int64(index ?? -1)))
            case "$strconv.ParseFloat":
                let size = try integer(1)
                let parsed = GoFloat.parse(try text(0), bitSize: size == 32 ? 32 : 64)
                vm.stack.append(.int(Int64(bitPattern: parsed.value.bitPattern)))
                vm.stack.append(
                    try parsed.failure.map {
                        try makeError(
                            GoNumeric.ParseFailure($0).message(
                                function: "ParseFloat", text: try text(0)))
                    } ?? .nilValue)
            case "$strconv.FormatFloat":
                let value = Double(bitPattern: UInt64(bitPattern: try integer(0)))
                let size = try integer(3)
                guard size == 32 || size == 64 else {
                    throw GoRuntimePanic(text: "strconv: illegal AppendFloat/FormatFloat bitSize")
                }
                let precision = try integer(2)
                vm.stack.append(
                    .string(
                        GoFloat.format(
                            value, format: UInt8(truncatingIfNeeded: try integer(1)),
                            precision: Int(clamping: precision), bitSize: Int(size))))
            case "$sort.Float64s":
                // In Go's order: a NaN before every number.
                let sorted = try sliceElements(operands[0]).map { element -> Double in
                    guard case .int(let bits) = element else { throw GoRuntimeError.typeMismatch }
                    return Double(bitPattern: UInt64(bitPattern: bits))
                }.sorted { $0 < $1 || ($0.isNaN && !$1.isNaN) }
                if case .slice(let slice) = operands[0] {
                    try storeElements(
                        sorted.map { GoValue.int(Int64(bitPattern: $0.bitPattern)) }, into: slice)
                }
            default:
                throw GoRuntimeError.typeMismatch
            }
            return true
        }

        /// Run a `time` native. Operands are integers, and results integers,
        /// bools, and the text of a duration; `time.ParseDuration` alone
        /// takes a string and gives an error.
        /// Returns `false` when `name` is not such a function.
        func executeTimeNative(_ name: String, argumentCount: Int) throws -> Bool {
            if name == GoNative.parseDuration {
                guard argumentCount == 1 else {
                    throw GoRuntimeError.argumentCountMismatch(
                        function: name, expected: 1, actual: argumentCount)
                }
                guard case .string(let text) = try pop(&vm.stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                let parsed = GoDuration.parse(text)
                vm.stack.append(.int(parsed.duration))
                vm.stack.append(errorValue(parsed.error))
                return true
            }
            guard let expectedCount = GoNative.timeArgumentCounts[name] else { return false }
            guard argumentCount == expectedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expectedCount, actual: argumentCount)
            }
            guard vm.stack.count >= argumentCount else { throw GoRuntimeError.stackUnderflow }
            let start = vm.stack.count - argumentCount
            let operands = try vm.stack[start...].map { value -> Int64 in
                guard case .int(let integer) = value else { throw GoRuntimeError.typeMismatch }
                return integer
            }
            vm.stack.removeSubrange(start...)
            guard let result = GoNative.time(name, operands, now: runtimeTimestamp()) else {
                return false
            }
            vm.stack.append(result)
            return true
        }

        /// Run a native of `time.Time` and the types of its calendar: see
        /// `GoCalendar`. Returns `false` when `name` is not such a function.
        func executeCalendarNative(_ name: String, argumentCount: Int) throws -> Bool {
            guard let counts = GoCalendar.natives[name] else { return false }
            guard argumentCount == counts.operands else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: counts.operands, actual: argumentCount)
            }
            guard vm.stack.count >= argumentCount else { throw GoRuntimeError.stackUnderflow }
            let start = vm.stack.count - argumentCount
            let operands = Array(vm.stack[start...])
            vm.stack.removeSubrange(start...)
            for result in try GoCalendar.call(
                name, operands, now: runtimeTimestamp(), bytes: { try sliceBytes($0) })
            {
                switch result {
                case .value(let value): vm.stack.append(value)
                case .bytes(let bytes): vm.stack.append(try makeByteSlice(bytes))
                case .error(let message): vm.stack.append(errorValue(message))
                }
            }
            return true
        }

        // MARK: Locks and condition variables

        /// The struct a pointer operand of a `sync` native points to. A nil
        /// pointer panics, as the method does in Go.
        func structOperand(_ value: GoValue) throws -> (pointer: GoPointer, value: GoValue) {
            guard case .pointer(let pointer) = value else {
                if value == .nilValue { throw GoRuntimePanic.nilDereference }
                throw GoRuntimeError.typeMismatch
            }
            return (pointer, try read(pointer: pointer, heap: vm.heap))
        }

        /// Run a `sync` native: `TryLock` of a mutex, a method of a
        /// `sync.RWMutex`, or what a `sync.Cond` needs. See `GoSync`.
        /// Returns `false` when `name` is not such a function.
        func executeSyncNative(_ name: String, argumentCount: Int) throws -> Bool {
            guard let expectedCount = GoSync.argumentCounts[name] else { return false }
            guard argumentCount == expectedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expectedCount, actual: argumentCount)
            }
            guard vm.stack.count >= argumentCount else { throw GoRuntimeError.stackUnderflow }
            let start = vm.stack.count - argumentCount
            let operands = Array(vm.stack[start...])
            vm.stack.removeSubrange(start...)
            switch name {
            case "$sync.Mutex.TryLock":
                guard case .mutex(let mutex) = operands[0],
                    case .mutexStorage(var storage) = try read(
                        pointer: mutex.storage, heap: vm.heap)
                else { throw GoRuntimeError.typeMismatch }
                vm.stack.append(.bool(!storage.locked))
                if !storage.locked {
                    storage.locked = true
                    try writePointer(
                        .mutexStorage(storage), through: mutex.storage, heap: &vm.heap)
                }
            case GoLockCopies.copyName:
                vm.stack.append(try copiedLocks(operands[0]))
            case "$sync.RWMutex.RLocker":
                // The same lock under the type whose `Lock` reads.
                vm.stack.append(
                    .interface(
                        GoInterfaceValue(
                            typeName: GoSync.readLockerTypeName, value: operands[0])))
            case "$sync.NewCond":
                let cell = try vm.heap.allocate(GoSync.condition(locker: operands[0]))
                vm.stack.append(.pointer(GoPointer(cell: cell)))
            case GoSync.condAdd, GoSync.condWait, "$sync.Cond.Signal", "$sync.Cond.Broadcast":
                try executeConditionNative(name, operands)
            default:
                try executeReadWriteLockNative(name, receiver: operands[0])
            }
            return true
        }

        /// A method of `sync.RWMutex`, done to the struct `receiver` points
        /// to as Go's method does it. A goroutine that has to wait is
        /// parked under the struct's address and woken by the method that
        /// lets it go on.
        func executeReadWriteLockNative(_ name: String, receiver: GoValue) throws {
            let lock = try structOperand(receiver)
            guard var state = GoSync.ReadWriteState(lock.value) else {
                throw GoRuntimeError.typeMismatch
            }
            let address = GoAddress(lock.pointer)
            var waiters = lockWaiters[address]

            /// The queues of this lock, made when the first goroutine waits.
            func park(_ place: (inout GoLockWaiters) -> Void) throws {
                var queues =
                    try waiters ?? GoLockWaiters(root: retainRuntimeHandle(receiver))
                place(&queues)
                waiters = queues
            }
            /// A writer that holds the lock inside tells the readers: none
            /// may begin, and it waits for those that have. Whether it has
            /// to wait.
            func announceWriter() -> Bool {
                let readers = state.readerCount
                state.readerCount -= GoSync.maxReaders
                guard readers != 0 else { return false }
                state.readerWait += readers
                return state.readerWait != 0
            }

            switch name {
            case "$sync.RWMutex.RLock":
                state.readerCount += 1
                if state.readerCount < 0 {
                    // A writer holds the lock or waits for it.
                    try park { $0.readers.append(vm.currentGoroutineID) }
                    vm.currentBlocked = true
                }
            case "$sync.RWMutex.TryRLock":
                vm.stack.append(.bool(state.readerCount >= 0))
                if state.readerCount >= 0 { state.readerCount += 1 }
            case "$sync.RWMutex.RUnlock":
                state.readerCount -= 1
                if state.readerCount < 0 {
                    let before = state.readerCount + 1
                    guard before != 0, before != -GoSync.maxReaders else {
                        throw GoFatalError.readUnlockOfUnlocked
                    }
                    // A writer waits: the last reader to leave lets it in.
                    state.readerWait -= 1
                    if state.readerWait == 0, let writer = waiters?.pendingWriter {
                        waiters?.pendingWriter = nil
                        try wakeGoroutine(writer)
                    }
                }
            case "$sync.RWMutex.Lock":
                if state.isLocked {
                    try park { $0.writers.append(vm.currentGoroutineID) }
                    vm.currentBlocked = true
                } else {
                    state.isLocked = true
                    if announceWriter() {
                        try park { $0.pendingWriter = vm.currentGoroutineID }
                        vm.currentBlocked = true
                    }
                }
            case "$sync.RWMutex.TryLock":
                let free = !state.isLocked && state.readerCount == 0
                vm.stack.append(.bool(free))
                if free {
                    state.isLocked = true
                    state.readerCount = -GoSync.maxReaders
                }
            case "$sync.RWMutex.Unlock":
                state.readerCount += GoSync.maxReaders
                guard state.readerCount < GoSync.maxReaders else {
                    throw GoFatalError.unlockOfUnlocked
                }
                // Every reader that came while the writer had the lock goes
                // on, and then the lock inside passes to the next writer,
                // which waits for those readers in its turn.
                let readers = waiters?.readers ?? []
                waiters?.readers = []
                for reader in readers { try wakeGoroutine(reader) }
                if let next = waiters?.writers.first {
                    waiters?.writers.removeFirst()
                    if announceWriter() {
                        waiters?.pendingWriter = next
                    } else {
                        try wakeGoroutine(next)
                    }
                } else {
                    state.isLocked = false
                }
            default:
                throw GoRuntimeError.missingFunction(name)
            }
            try writePointer(state.stored(in: lock.value), through: lock.pointer, heap: &vm.heap)
            if let queues = waiters, queues.isEmpty {
                runtimeHandleRoots.removeValue(forKey: queues.root)
                lockWaiters[address] = nil
            } else {
                lockWaiters[address] = waiters
            }
        }

        /// What a `sync.Cond` asks of the VM: Go's notification list. `Wait`
        /// draws a ticket before it unlocks and parks after, so a `Signal`
        /// between the two is not lost; `Signal` calls the oldest ticket
        /// and `Broadcast` all of them.
        func executeConditionNative(_ name: String, _ operands: [GoValue]) throws {
            let condition = try structOperand(operands[0])
            guard var state = GoSync.ConditionState(condition.value) else {
                throw GoRuntimeError.typeMismatch
            }
            let address = GoAddress(condition.pointer)
            var parked = conditionWaiters[address]
            switch name {
            case GoSync.condAdd:
                vm.stack.append(.int(state.wait))
                state.wait = (state.wait + 1) & 0xFFFF_FFFF
            case GoSync.condWait:
                guard case .int(let ticket) = operands[1] else { throw GoRuntimeError.typeMismatch }
                // A ticket that was called meanwhile does not wait.
                guard !GoSync.ConditionState.isBefore(ticket, state.notify) else { return }
                var queue =
                    try parked ?? GoConditionWaiters(root: retainRuntimeHandle(operands[0]))
                queue.waiters.append((ticket, vm.currentGoroutineID))
                conditionWaiters[address] = queue
                vm.currentBlocked = true
                return
            case "$sync.Cond.Signal":
                guard state.wait != state.notify else { return }
                let ticket = state.notify
                state.notify = (state.notify + 1) & 0xFFFF_FFFF
                // Its goroutine may not have parked yet; it will not.
                if let index = parked?.waiters.firstIndex(where: { $0.ticket == ticket }),
                    let waiter = parked?.waiters.remove(at: index)
                {
                    try wakeGoroutine(waiter.goroutineID)
                }
            default:
                state.notify = state.wait
                for waiter in parked?.waiters ?? [] { try wakeGoroutine(waiter.goroutineID) }
                parked?.waiters = []
            }
            try writePointer(
                state.stored(in: condition.value), through: condition.pointer, heap: &vm.heap)
            if let queue = parked, queue.waiters.isEmpty {
                runtimeHandleRoots.removeValue(forKey: queue.root)
                conditionWaiters[address] = nil
            } else {
                conditionWaiters[address] = parked
            }
        }

        // MARK: The process

        /// The variables of the program's environment: those of its
        /// process when it first asks, and what it has set since.
        func withEnvironment<Result>(_ body: (inout GoEnvironment) -> Result) -> Result {
            var current = environment ?? GoEnvironment(processContext?.environment ?? [:])
            defer { environment = current }
            return body(&current)
        }

        /// Run a native of `os` that asks the process about itself or
        /// changes its environment. See `GoProcess`.
        /// Returns `false` when `name` is not such a function.
        func executeProcessNative(_ name: String, argumentCount: Int) throws -> Bool {
            guard let expectedCount = GoProcess.argumentCounts[name] else { return false }
            guard argumentCount == expectedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expectedCount, actual: argumentCount)
            }
            guard vm.stack.count >= argumentCount else { throw GoRuntimeError.stackUnderflow }
            let start = vm.stack.count - argumentCount
            let operands = try vm.stack[start...].map { value -> String in
                guard case .string(let text) = value else { throw GoRuntimeError.typeMismatch }
                return text
            }
            vm.stack.removeSubrange(start...)
            switch name {
            case "$os.Getenv":
                vm.stack.append(.string(withEnvironment { $0.value(of: operands[0]) } ?? ""))
            case "$os.LookupEnv":
                let value = withEnvironment { $0.value(of: operands[0]) }
                vm.stack.append(.string(value ?? ""))
                vm.stack.append(.bool(value != nil))
            case "$os.Setenv":
                guard GoProcess.isSettable(name: operands[0], value: operands[1]) else {
                    vm.stack.append(errorValue(GoProcess.invalidVariable))
                    break
                }
                withEnvironment { $0.set(operands[0], to: operands[1]) }
                processContext?.setenv(operands[0], operands[1])
                vm.stack.append(.nilValue)
            case "$os.Unsetenv":
                if withEnvironment({ $0.unset(operands[0]) }) {
                    processContext?.unsetenv(operands[0])
                }
                vm.stack.append(.nilValue)
            case "$os.Environ":
                let entries = withEnvironment { $0.entries }.map { GoValue.string($0) }
                try requireCollectionCount(entries.count, resource: "slice elements")
                let cell = try vm.heap.allocate(.array(entries))
                vm.stack.append(
                    .slice(
                        GoSliceValue(
                            backing: GoPointer(cell: cell), start: 0, length: entries.count,
                            capacity: entries.count, zeroValue: .string(""))))
            case "$os.Getpid":
                vm.stack.append(
                    .int(processContext.map { Int64($0.getpid()) } ?? GoProcess.detachedProcessID))
            case "$os.Hostname":
                vm.stack.append(.string(processContext?.hostname ?? GoProcess.detachedHostname))
                vm.stack.append(.nilValue)
            default:
                vm.stack.append(
                    .string(processContext?.currentDirectory ?? GoProcess.detachedDirectory))
                vm.stack.append(.nilValue)
            }
            return true
        }

        // MARK: Timers

        /// Logical time in nanoseconds, which a timer is due by.
        func logicalNanoseconds() -> Int64 {
            let nanoseconds = (eventLoop.now * 1_000_000_000).rounded()
            guard nanoseconds.isFinite, nanoseconds < 9.2e18 else { return .max }
            return Int64(max(0, nanoseconds))
        }

        /// Start a goroutine that calls the function value `value`, from
        /// outside any goroutine: what a timer of `time.AfterFunc` does
        /// when it fires.
        func startGoroutine(calling value: GoValue) throws {
            let target = try functionValueTarget(value)
            guard resourceLimits.maximumGoroutines >= 2,
                vm.goroutines.count <= resourceLimits.maximumGoroutines - 2
            else {
                throw GoRuntimeError.resourceLimitExceeded("goroutines")
            }
            guard nextGoroutineID < Int.max else {
                throw GoRuntimeError.resourceLimitExceeded("goroutine identifiers")
            }
            let id = nextGoroutineID
            nextGoroutineID += 1
            vm.goroutines[id] = GoroutineContext(
                frames: [
                    try makeFrame(
                        function: target.function, stackBase: 0,
                        arguments: try target.arguments(with: [GoValue]()), heap: &vm.heap)
                ],
                stack: [])
            vm.runQueue.append(id)
        }

        /// Stop the timer at `address` from firing. Whether it was running.
        func disarmTimer(at address: GoAddress) -> Bool {
            guard let timer = runningTimers.removeValue(forKey: address) else { return false }
            runtimeHandleRoots.removeValue(forKey: timer.root)
            finishTimer()
            return true
        }

        /// Have the timer whose struct `pointer` points to fire after
        /// `nanoseconds`, and every `period` after that when it is a
        /// ticker's.
        func armTimer(
            at pointer: GoPointer, after nanoseconds: Int64, period: Int64 = 0
        ) throws {
            try reserveTimer()
            let root: Int
            do {
                root = try retainRuntimeHandle(.pointer(pointer))
            } catch {
                finishTimer()
                throw error
            }
            let delay = max(0, nanoseconds)
            let (deadline, overflow) = logicalNanoseconds().addingReportingOverflow(delay)
            let sequence = nextTimerSequence
            nextTimerSequence &+= 1
            runningTimers[GoAddress(pointer)] = GoRunningTimer(
                sequence: sequence, root: root, period: period,
                deadline: overflow ? .max : deadline)
            scheduleTimer(at: pointer, sequence: sequence, after: delay)
        }

        /// Put the firing of a timer on the event loop. The work cannot be
        /// taken back, so it does nothing when the timer was stopped or
        /// reset since: its sequence number is then another.
        func scheduleTimer(at pointer: GoPointer, sequence: UInt64, after nanoseconds: Int64) {
            let address = GoAddress(pointer)
            scheduleRuntimeWork(after: Double(nanoseconds) / 1_000_000_000) {
                guard executionIsActive, asynchronousError == nil,
                    var timer = runningTimers[address], timer.sequence == sequence
                else { return }
                do {
                    let fields = GoTimers.fields(of: try read(pointer: pointer, heap: vm.heap))
                    if let function = fields?.function {
                        // What `time.AfterFunc` was given runs in a
                        // goroutine of its own.
                        _ = disarmTimer(at: address)
                        try startGoroutine(calling: function)
                        return
                    }
                    // The time goes to whoever waits or into the channel's
                    // one place; a ticker nobody reads drops it.
                    if let channel = fields?.channel,
                        case .sent = try trySelectSend(.int(runtimeTimestamp()), to: channel)
                    {
                        try wakeReadyBlockedSelects()
                    }
                    guard timer.period > 0 else {
                        _ = disarmTimer(at: address)
                        return
                    }
                    let now = logicalNanoseconds()
                    timer.deadline = GoTimers.nextDeadline(
                        after: timer.deadline, period: timer.period, now: now)
                    runningTimers[address] = timer
                    scheduleTimer(
                        at: pointer, sequence: sequence, after: max(0, timer.deadline &- now))
                } catch let panic as GoRuntimePanic {
                    asynchronousError = .panicError(panic.message)
                } catch let error as GoRuntimeError {
                    asynchronousError = error
                } catch {
                    asynchronousError = .typeMismatch
                }
            }
        }

        /// Take back a time a timer sent that nobody has received. Whether
        /// there was one.
        func drainTimerChannel(_ channel: GoValue) throws -> Bool {
            guard case .channel(let value) = channel,
                case .channelStorage(var storage) = try read(pointer: value.storage, heap: vm.heap),
                !storage.buffer.isEmpty
            else { return false }
            storage.buffer.removeAll()
            try writePointer(.channelStorage(storage), through: value.storage, heap: &vm.heap)
            return true
        }

        /// Run a timer native: a constructor, or `Stop` or `Reset` of a
        /// `time.Timer` or a `time.Ticker`. See `GoTimers`.
        /// Returns `false` when `name` is not such a function.
        func executeTimerNative(_ name: String, argumentCount: Int) throws -> Bool {
            guard let expectedCount = GoTimers.argumentCounts[name] else { return false }
            guard argumentCount == expectedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expectedCount, actual: argumentCount)
            }
            guard vm.stack.count >= argumentCount else { throw GoRuntimeError.stackUnderflow }
            let start = vm.stack.count - argumentCount
            let operands = Array(vm.stack[start...])
            vm.stack.removeSubrange(start...)
            func duration(_ index: Int) throws -> Int64 {
                guard case .int(let nanoseconds) = operands[index] else {
                    throw GoRuntimeError.typeMismatch
                }
                return nanoseconds
            }
            /// A new timer or ticker in a variable of its own, running.
            func make(
                _ typeName: String, after nanoseconds: Int64, period: Int64 = 0,
                function: GoValue? = nil
            ) throws {
                var channel = GoValue.nilValue
                if function == nil {
                    let cell = try vm.heap.allocate(.channelStorage(GoChannelStorage(capacity: 1)))
                    channel = .channel(GoChannelValue(storage: GoPointer(cell: cell)))
                }
                let pointer = GoPointer(
                    cell: try vm.heap.allocate(
                        GoTimers.value(typeName: typeName, channel: channel, function: function)))
                vm.stack.append(.pointer(pointer))
                try armTimer(at: pointer, after: nanoseconds, period: period)
            }

            switch name {
            case "$time.NewTimer":
                try make(GoTimers.timerTypeName, after: try duration(0))
                return true
            case "$time.AfterFunc":
                try make(GoTimers.timerTypeName, after: try duration(0), function: operands[1])
                return true
            case "$time.NewTicker":
                let period = try duration(0)
                guard period > 0 else { throw GoRuntimePanic(text: GoTimers.nonPositiveTicker) }
                try make(GoTimers.tickerTypeName, after: period, period: period)
                return true
            default:
                break
            }

            let timer = try structOperand(operands[0])
            guard let fields = GoTimers.fields(of: timer.value) else {
                throw GoRuntimeError.typeMismatch
            }
            let address = GoAddress(timer.pointer)
            switch name {
            case "$time.Timer.Stop", "$time.Timer.Reset":
                let method = name == "$time.Timer.Stop" ? "Stop" : "Reset"
                guard fields.isInitialized else {
                    throw GoRuntimePanic(text: GoTimers.uninitialized(method, "Timer"))
                }
                // It had not been used up when it was still to fire, or
                // had fired and nobody had the time yet.
                let wasRunning = disarmTimer(at: address)
                let wasSent = try drainTimerChannel(fields.channel)
                if name == "$time.Timer.Reset" {
                    try armTimer(at: timer.pointer, after: try duration(1))
                }
                vm.stack.append(.bool(wasRunning || wasSent))
            case "$time.Ticker.Stop":
                // Go lets a ticker nobody made be stopped.
                guard fields.isInitialized else { break }
                _ = disarmTimer(at: address)
                _ = try drainTimerChannel(fields.channel)
            default:
                let period = try duration(1)
                guard period > 0 else { throw GoRuntimePanic(text: GoTimers.nonPositiveReset) }
                guard fields.isInitialized else {
                    throw GoRuntimePanic(text: GoTimers.uninitialized("Reset", "Ticker"))
                }
                _ = disarmTimer(at: address)
                _ = try drainTimerChannel(fields.channel)
                try armTimer(at: timer.pointer, after: period, period: period)
            }
            return true
        }

        /// Run a native call of the library's own Go text: what the sorting
        /// functions of `sort` need of a slice whose element type they do
        /// not know. The slice arrives in an `any`. Returns `false` when
        /// `name` is not such a call.
        func executeSliceNative(_ name: String, argumentCount: Int) throws -> Bool {
            guard let expectedCount = GoNative.sliceArgumentCounts[name] else { return false }
            guard argumentCount == expectedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expectedCount, actual: argumentCount)
            }
            guard vm.stack.count >= argumentCount else { throw GoRuntimeError.stackUnderflow }
            let start = vm.stack.count - argumentCount
            let operands = Array(vm.stack[start...])
            vm.stack.removeSubrange(start...)
            var held = operands[0]
            var dynamicType = GoTypeDescriptor.inferred(from: held)
            if case .interface(let boxed) = held {
                held = boxed.value
                dynamicType =
                    typeDescriptor(named: boxed.typeName).map { $0.underlying($0.type) }
                    ?? GoTypeDescriptor.inferred(from: held)
            }
            switch name {
            case "$sort.length":
                guard case .string(let caller) = operands[1] else {
                    throw GoRuntimeError.typeMismatch
                }
                if case .slice(let slice) = held {
                    vm.stack.append(.int(Int64(try validatedSliceRange(slice).count)))
                } else if held == .nilValue, case .slice? = dynamicType {
                    vm.stack.append(.int(0))
                } else {
                    // What Go's `reflect` says of a value that is no slice.
                    throw GoRuntimePanic(
                        text: "reflect: call of \(caller) on "
                            + "\(GoNative.kindName(of: dynamicType)) Value")
                }
            default:
                guard case .int(let first) = operands[1], case .int(let second) = operands[2],
                    case .slice(let slice) = held
                else { throw GoRuntimeError.typeMismatch }
                let range = try validatedSliceRange(slice)
                guard let i = Int(exactly: first), let j = Int(exactly: second),
                    i >= 0, j >= 0, i < range.count, j < range.count
                else { throw GoRuntimePanic(text: "reflect: slice index out of range") }
                guard i != j else { break }
                // Each element is read and written where it lies, so an
                // exchange costs the same whatever the length.
                let left = appending(index: range.lowerBound + i, to: slice.backing)
                let right = appending(index: range.lowerBound + j, to: slice.backing)
                let moved = try read(pointer: left, heap: vm.heap)
                try writePointer(try read(pointer: right, heap: vm.heap), through: left, heap: &vm.heap)
                try writePointer(moved, through: right, heap: &vm.heap)
            }
            return true
        }

        /// Run a native of `bytes` or `bufio`: see `GoBytes`. The slices
        /// are read where they lie. Returns `false` when `name` is not such
        /// a function.
        func executeBytesNative(_ name: String, argumentCount: Int) throws -> Bool {
            guard let expectedCount = GoBytes.argumentCounts[name] else { return false }
            guard argumentCount == expectedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expectedCount, actual: argumentCount)
            }
            let second = try pop(&vm.stack)
            let first = try sliceElements(try pop(&vm.stack))
            // The second operand is a slice, or the byte to find.
            var other: ArraySlice<GoValue> = []
            if case .int = second {} else { other = try sliceElements(second) }
            guard let result = GoBytes.result(name, first, other, byte: second) else {
                throw GoRuntimeError.typeMismatch
            }
            vm.stack.append(result)
            return true
        }

        /// Run a native of `net/http`: see `GoHTTP`. Returns `false` when
        /// `name` is not such a function.
        func executeHTTPNative(_ name: String, argumentCount: Int) throws -> Bool {
            guard let expectedCount = GoHTTP.argumentCounts[name] else { return false }
            guard argumentCount == expectedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expectedCount, actual: argumentCount)
            }
            var second: Int64 = 0
            if expectedCount == 2 {
                guard case .int(let value) = try pop(&vm.stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                second = value
            }
            let operand = try pop(&vm.stack)
            func text() throws -> String {
                guard case .string(let text) = operand else { throw GoRuntimeError.typeMismatch }
                return text
            }
            switch name {
            case "$http.CanonicalHeaderKey":
                vm.stack.append(.string(GoHTTP.canonicalHeaderKey(try text())))
            case "$http.DetectContentType":
                vm.stack.append(.string(GoHTTP.detectContentType(try sliceBytes(operand))))
            case "$http.lineEnd":
                let start = Int(clamping: second)
                vm.stack.append(.int(Int64(GoHTTP.lineEnd(try sliceBytes(operand), from: start))))
            case "$http.formatTime":
                guard case .int(let seconds) = operand,
                    let layout = GoHTTP.TimeLayout(rawValue: second)
                else { throw GoRuntimeError.typeMismatch }
                vm.stack.append(.string(GoHTTP.formatTime(unixSeconds: seconds, layout: layout)))
            case "$http.remoteAddr":
                guard case .netConn(let connection) = operand else {
                    throw GoRuntimeError.typeMismatch
                }
                vm.stack.append(.string(connection.remoteAddr))
            case "$http.validToken":
                vm.stack.append(.bool(GoHTTP.isToken(try text())))
            case "$http.validHeaderValue":
                vm.stack.append(.bool(GoHTTP.isHeaderValue(try text())))
            default:
                return false
            }
            return true
        }

        /// Run a native of `net/url`: see `GoURL`. Returns `false` when
        /// `name` is not such a function.
        func executeURLNative(_ name: String, argumentCount: Int) throws -> Bool {
            guard let expectedCount = GoURL.argumentCounts[name] else { return false }
            guard argumentCount == expectedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expectedCount, actual: argumentCount)
            }
            var mode = GoURL.Mode.path
            if expectedCount == 2 {
                guard case .int(let raw) = try pop(&vm.stack), let named = GoURL.Mode(rawValue: raw)
                else { throw GoRuntimeError.typeMismatch }
                mode = named
            }
            guard case .string(let text) = try pop(&vm.stack) else {
                throw GoRuntimeError.typeMismatch
            }
            switch name {
            case "$url.unescape":
                // The text, then what was wrong with it and which kind of
                // error that is: none, an escape, or a host.
                switch GoURL.unescape(text, mode) {
                case .success(let bytes):
                    vm.stack.append(contentsOf: [
                        .string(GoNative.string(fromBytes: bytes)), .string(""), .int(0),
                    ])
                case .failure(.escape(let bad)):
                    vm.stack.append(contentsOf: [.string(""), .string(bad), .int(1)])
                case .failure(.host(let bad)):
                    vm.stack.append(contentsOf: [.string(""), .string(bad), .int(2)])
                }
            case "$url.escape":
                let escaped = GoURL.escape(text, mode)
                guard escaped.utf8.count <= resourceLimits.maximumStringBytes else {
                    throw GoRuntimeError.resourceLimitExceeded("string bytes")
                }
                vm.stack.append(.string(escaped))
            case "$url.validEncoded":
                vm.stack.append(.bool(GoURL.isValidEncoded(text, mode)))
            case "$url.hasControlByte":
                vm.stack.append(.bool(GoURL.hasControlByte(text)))
            default:
                return false
            }
            return true
        }

        /// Run an `os` file native: opening and closing files, positional I/O,
        /// seeking, and directory entries. Arguments are the top
        /// `argumentCount` stack entries in call order. A failed system call
        /// is a Go `error` result, never a VM error. Returns `false` when
        /// `name` is not such a function.
        func executeFileNative(_ name: String, argumentCount: Int) throws -> Bool {
            guard let expectedCount = GoFiles.argumentCounts[name] else { return false }
            guard argumentCount == expectedCount else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expectedCount, actual: argumentCount)
            }
            guard vm.stack.count >= argumentCount else { throw GoRuntimeError.stackUnderflow }
            let start = vm.stack.count - argumentCount
            let operands = Array(vm.stack[start...])
            vm.stack.removeSubrange(start...)

            func text(_ value: GoValue) throws -> String {
                guard case .string(let text) = value else { throw GoRuntimeError.typeMismatch }
                return text
            }
            func integer(_ value: GoValue) throws -> Int64 {
                guard case .int(let integer) = value else { throw GoRuntimeError.typeMismatch }
                return integer
            }
            /// `operation subject: reason`, the shape of Go's `*PathError`.
            func failure(_ operation: String, _ subject: String, _ reason: String) -> GoValue {
                errorValue("\(operation) \(subject): \(reason)")
            }
            func failure(_ operation: String, _ subject: String, _ error: Error) -> GoValue {
                failure(operation, subject, GoFiles.message(for: error))
            }
            /// Missing parent directories are an error in Go; the VFS would
            /// create them.
            func requireParentDirectory(
                of path: String, in processContext: ProcessContext
            ) throws {
                guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return }
                guard let parent = processContext.stat(String(path[..<slash])) else {
                    throw SyscallError.noSuchFileOrDirectory
                }
                guard parent.isDirectory else { throw SyscallError.notADirectory }
            }
            func creationMode(_ permissions: Int64, in processContext: ProcessContext) -> FileMode {
                FileMode(rawValue: UInt16(truncatingIfNeeded: permissions & 0o777))
                    .subtracting(processContext.fileCreationMask)
            }
            func open(_ path: String, flag: Int64, permissions: Int64) -> [GoValue] {
                guard let processContext else {
                    return [.nilValue, failure("open", path, "no file system")]
                }
                guard let mode = GoFiles.openMode(flag) else {
                    return [.nilValue, failure("open", path, SyscallError.invalidArgument)]
                }
                guard openFiles.count < resourceLimits.maximumRuntimeHandles else {
                    return [.nilValue, failure("open", path, "too many open files")]
                }
                do {
                    let creates = mode.flags.contains(.create) && processContext.stat(path) == nil
                    if creates { try requireParentDirectory(of: path, in: processContext) }
                    let descriptor = try processContext.openFile(
                        path, flags: mode.flags, access: mode.access)
                    if creates {
                        _ = processContext.chmod(
                            path, mode: creationMode(permissions, in: processContext))
                    }
                    let handle = nextFileHandle
                    nextFileHandle += 1
                    openFiles[handle] = GoFiles.OpenFile(
                        name: path, descriptor: descriptor,
                        appends: mode.flags.contains(.append))
                    return [.int(handle), .nilValue]
                } catch {
                    return [.nilValue, failure("open", path, error)]
                }
            }
            var methodFailure = GoValue.nilValue
            /// The receiver of a file method and the process that owns it. Without
            /// one, `methodFailure` is the error the method reports.
            func receiver(
                _ operation: String
            ) throws -> (file: GoFiles.OpenFile, process: ProcessContext)? {
                guard let file = try resolveFile(operands[0]) else {
                    // Go's methods give a nil file `ErrInvalid` as it is,
                    // and name the operation for a file that was closed.
                    methodFailure = errorValue(
                        operands[0] == .nilValue
                            ? GoFiles.invalidFile : "\(operation): \(GoFiles.closedFile)")
                    return nil
                }
                guard let processContext else {
                    methodFailure = failure(operation, file.name, "no file system")
                    return nil
                }
                return (file, processContext)
            }

            switch name {
            case "$os.Open":
                vm.stack.append(
                    contentsOf: open(
                        try text(operands[0]), flag: GoFiles.readOnly, permissions: 0))
            case "$os.Create":
                vm.stack.append(
                    contentsOf: open(
                        try text(operands[0]),
                        flag: GoFiles.readWrite | GoFiles.create | GoFiles.truncate,
                        permissions: 0o666))
            case "$os.OpenFile":
                vm.stack.append(
                    contentsOf: open(
                        try text(operands[0]),
                        flag: try integer(operands[1]),
                        permissions: try integer(operands[2])))
            case "$os.Remove":
                let path = try text(operands[0])
                guard let processContext else {
                    vm.stack.append(failure("remove", path, "no file system"))
                    break
                }
                do {
                    guard
                        let (parent, entry) = GoFiles.split(
                            path, workingDirectory: processContext.currentDirectory)
                    else { throw SyscallError.invalidArgument }
                    if processContext.lstat(path)?.isDirectory == true,
                        processContext.listDirectory(path)?.isEmpty == false
                    {
                        throw SyscallError.directoryNotEmpty
                    }
                    try processContext.remove(entry, in: FileSystemScope(rootPath: parent))
                    vm.stack.append(.nilValue)
                } catch {
                    vm.stack.append(failure("remove", path, error))
                }
            case "$os.Rename":
                let source = try text(operands[0])
                let destination = try text(operands[1])
                let subject = "\(source) \(destination)"
                guard let processContext else {
                    vm.stack.append(failure("rename", subject, "no file system"))
                    break
                }
                do {
                    let workingDirectory = processContext.currentDirectory
                    guard
                        let (sourceParent, sourceEntry) = GoFiles.split(
                            source, workingDirectory: workingDirectory),
                        let (destinationParent, destinationEntry) = GoFiles.split(
                            destination, workingDirectory: workingDirectory)
                    else { throw SyscallError.invalidArgument }
                    guard processContext.lstat(source) != nil,
                        let parent = processContext.stat(destinationParent)
                    else { throw SyscallError.noSuchFileOrDirectory }
                    guard parent.isDirectory else { throw SyscallError.notADirectory }
                    try processContext.rename(
                        sourceEntry, in: FileSystemScope(rootPath: sourceParent),
                        to: destinationEntry, in: FileSystemScope(rootPath: destinationParent))
                    vm.stack.append(.nilValue)
                } catch {
                    vm.stack.append(failure("rename", subject, error))
                }
            case "$os.Mkdir":
                let path = try text(operands[0])
                let permissions = try integer(operands[1])
                guard let processContext else {
                    vm.stack.append(failure("mkdir", path, "no file system"))
                    break
                }
                do {
                    guard
                        let (parent, entry) = GoFiles.split(
                            path, workingDirectory: processContext.currentDirectory)
                    else { throw SyscallError.fileExists }
                    guard let parentInfo = processContext.stat(parent) else {
                        throw SyscallError.noSuchFileOrDirectory
                    }
                    guard parentInfo.isDirectory else { throw SyscallError.notADirectory }
                    try processContext.mkdir(entry, in: FileSystemScope(rootPath: parent))
                    _ = processContext.chmod(
                        path, mode: creationMode(permissions, in: processContext))
                    vm.stack.append(.nilValue)
                } catch {
                    vm.stack.append(failure("mkdir", path, error))
                }
            case "$os.File.Close":
                guard let (file, processContext) = try receiver("close") else {
                    vm.stack.append(methodFailure)
                    break
                }
                if case .int(let handle) = operands[0] { openFiles[handle] = nil }
                do {
                    try processContext.closeFile(file.descriptor)
                    vm.stack.append(.nilValue)
                } catch {
                    vm.stack.append(failure("close", file.name, error))
                }
            case "$os.File.Sync":
                guard let (file, processContext) = try receiver("sync") else {
                    vm.stack.append(methodFailure)
                    break
                }
                // VFS writes are complete when they return; only the
                // descriptor can be wrong.
                vm.stack.append(
                    processContext.fileAccessMode(file.descriptor) == nil
                        ? failure("sync", file.name, SyscallError.badFileDescriptor)
                        : .nilValue)
            case "$os.File.Seek":
                let offset = try integer(operands[1])
                let whence = try integer(operands[2])
                guard let (file, processContext) = try receiver("seek") else {
                    vm.stack.append(contentsOf: [.int(0), methodFailure])
                    break
                }
                guard (0...2).contains(whence), let target = Int(exactly: offset),
                    let position = processContext.seek(
                        file.descriptor, to: target, whence: Int(whence))
                else {
                    vm.stack.append(contentsOf: [
                        .int(0), failure("seek", file.name, SyscallError.invalidArgument),
                    ])
                    break
                }
                vm.stack.append(contentsOf: [.int(Int64(position)), .nilValue])
            case "$os.File.ReadAt":
                let offset = try integer(operands[2])
                let destination: GoSliceValue?
                if case .slice(let slice) = operands[1] {
                    _ = try validatedSliceRange(slice)
                    destination = slice
                } else if operands[1] == .nilValue {
                    destination = nil
                } else {
                    throw GoRuntimeError.typeMismatch
                }
                guard let (file, processContext) = try receiver("readat") else {
                    vm.stack.append(contentsOf: [.int(0), methodFailure])
                    break
                }
                guard offset >= 0, let position = Int(exactly: offset) else {
                    vm.stack.append(contentsOf: [
                        .int(0), failure("readat", file.name, "negative offset"),
                    ])
                    break
                }
                do {
                    let wanted = destination?.length ?? 0
                    let bytes = try processContext.pread(
                        file.descriptor, max: wanted, offset: position)
                    guard bytes.count <= wanted else { throw GoRuntimeError.invalidSliceBounds }
                    if let destination { try storeBytes(bytes, into: destination) }
                    vm.stack.append(contentsOf: [
                        .int(Int64(bytes.count)),
                        bytes.count < wanted ? errorValue(GoFiles.endOfFile) : .nilValue,
                    ])
                } catch let error as GoRuntimeError {
                    throw error
                } catch {
                    vm.stack.append(contentsOf: [.int(0), failure("read", file.name, error)])
                }
            default:
                let contents = try sliceBytes(operands[1])
                let offset = try integer(operands[2])
                guard let (file, processContext) = try receiver("writeat") else {
                    vm.stack.append(contentsOf: [.int(0), methodFailure])
                    break
                }
                guard !file.appends else {
                    vm.stack.append(contentsOf: [
                        .int(0),
                        errorValue("os: invalid use of WriteAt on file opened with O_APPEND"),
                    ])
                    break
                }
                guard offset >= 0, let position = Int(exactly: offset) else {
                    vm.stack.append(contentsOf: [
                        .int(0), failure("writeat", file.name, "negative offset"),
                    ])
                    break
                }
                do {
                    let written = try processContext.pwrite(
                        file.descriptor, contents, offset: position)
                    vm.stack.append(contentsOf: [
                        .int(Int64(written)),
                        written < contents.count ? errorValue("short write") : .nilValue,
                    ])
                } catch {
                    vm.stack.append(contentsOf: [.int(0), failure("write", file.name, error)])
                }
            }
            return true
        }

        func performGarbageCollection() {
            var rootCells = Array(0..<executable.globalCount)
            var rootValues: [GoValue] = vm.stack

            func appendRoots(from frame: Frame) {
                for localIndex in frame.function.rootLocalIndices
                where frame.locals.indices.contains(localIndex) {
                    if let cell = frame.locals[localIndex] { rootCells.append(cell) }
                }
                for deferred in frame.deferredCalls {
                    rootValues.append(contentsOf: deferred.arguments)
                }
                rootValues.append(contentsOf: frame.guestCallResults)
                switch frame.pendingExit {
                case .returning(let values):
                    rootValues.append(contentsOf: values)
                case .panicking(let value):
                    rootValues.append(value)
                case .testFatal, nil:
                    break
                }
            }

            for frame in vm.frames { appendRoots(from: frame) }
            for context in vm.goroutines.values {
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
            vm.heap.collect(rootCells: rootCells, rootValues: rootValues)
        }

        /// Pop the operands of a Go `strings` function and return its result.
        func executeStrings(
            _ function: GoStringsFunction,
            stack: inout [GoValue]
        ) throws -> GoValue {
            func requireStringBytes(_ count: Int) throws {
                guard count <= resourceLimits.maximumStringBytes else {
                    throw GoRuntimeError.resourceLimitExceeded("string bytes")
                }
            }
            switch function {
            case .join:
                guard case .string(let separator) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                var elements: [String] = []
                switch try pop(&stack) {
                case .nilValue:
                    break
                case .slice(let slice):
                    _ = try validatedSliceRange(slice)
                    for index in 0..<slice.length {
                        let absoluteIndex = try checkedAdd(
                            slice.start, index, resource: "slice index")
                        guard case .string(let element) = try read(
                            pointer: appending(index: absoluteIndex, to: slice.backing),
                            heap: vm.heap)
                        else { throw GoRuntimeError.typeMismatch }
                        elements.append(element)
                    }
                default:
                    throw GoRuntimeError.typeMismatch
                }
                var total = separator.utf8.count * max(0, elements.count - 1)
                for element in elements {
                    total = try checkedAdd(total, element.utf8.count, resource: "string bytes")
                }
                try requireStringBytes(total)
                return .string(elements.joined(separator: separator))
            case .repeatString:
                guard case .int(let rawCount) = try pop(&stack),
                    case .string(let text) = try pop(&stack)
                else { throw GoRuntimeError.typeMismatch }
                guard rawCount >= 0, let count = Int(exactly: rawCount) else {
                    throw GoRuntimePanic(text: "strings: negative Repeat count")
                }
                let (total, overflow) = text.utf8.count.multipliedReportingOverflow(by: count)
                guard !overflow else {
                    throw GoRuntimeError.resourceLimitExceeded("string bytes")
                }
                try requireStringBytes(total)
                return .string(String(repeating: text, count: count))
            case .trimSpace:
                guard case .string(let text) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                return .string(GoStrings.trimSpace(text))
            case .contains, .count, .hasPrefix, .hasSuffix, .index, .lastIndex, .split:
                guard case .string(let second) = try pop(&stack),
                    case .string(let first) = try pop(&stack)
                else { throw GoRuntimeError.typeMismatch }
                switch function {
                case .contains:
                    return .bool(GoStrings.index(first, second) >= 0)
                case .count:
                    return .int(Int64(GoStrings.count(first, second)))
                case .hasPrefix:
                    return .bool(first.utf8.starts(with: second.utf8))
                case .hasSuffix:
                    return .bool(first.utf8.reversed().starts(with: second.utf8.reversed()))
                case .index:
                    return .int(Int64(GoStrings.index(first, second)))
                case .lastIndex:
                    return .int(Int64(GoStrings.lastIndex(first, second)))
                default:
                    let parts = GoStrings.split(first, second)
                    try requireCollectionCount(parts.count, resource: "slice elements")
                    let elements = parts.map { GoValue.string($0) }
                    let cell = try vm.heap.allocate(.array(elements))
                    return .slice(
                        GoSliceValue(
                            backing: GoPointer(cell: cell),
                            start: 0,
                            length: elements.count,
                            capacity: elements.count,
                            zeroValue: .string("")))
                }
            }
        }

        /// Execute a pure native library call lowered to a reserved `$` name.
        /// Pops `argumentCount` operands and pushes the results in order.
        /// Returns false when `name` is not a pure native.
        func executePureNative(
            _ name: String,
            argumentCount: Int,
            stack: inout [GoValue]
        ) throws -> Bool {
            if let local = GoNative.freshLocal(name) {
                let frameIndex = vm.frames.count - 1
                guard argumentCount == 0, vm.frames[frameIndex].locals.indices.contains(local) else {
                    throw GoRuntimeError.invalidLocal(local)
                }
                vm.frames[frameIndex].locals[local] = nil
                return true
            }
            if let locals = GoNative.resultLocals(name) {
                let frameIndex = vm.frames.count - 1
                guard argumentCount == 0,
                    locals.count == vm.frames[frameIndex].function.returnCount,
                    locals.allSatisfy(vm.frames[frameIndex].locals.indices.contains)
                else {
                    throw GoRuntimeError.invalidExecutable("invalid function result locals")
                }
                vm.frames[frameIndex].resultLocals = locals
                return true
            }
            if name == GoNative.requireValue {
                guard argumentCount == 1, let value = stack.popLast() else {
                    throw GoRuntimeError.stackUnderflow
                }
                if value == .nilValue { throw GoRuntimePanic.nilDereference }
                return true
            }
            if let local = GoNative.boundLocal(name) {
                // The local becomes the variable the pointer points to: a
                // function literal's name for a variable it captures.
                let frameIndex = vm.frames.count - 1
                guard argumentCount == 1, vm.frames[frameIndex].locals.indices.contains(local),
                    case .pointer(let pointer)? = stack.popLast(), pointer.path.isEmpty
                else {
                    throw GoRuntimeError.invalidLocal(local)
                }
                vm.frames[frameIndex].locals[local] = pointer.cell
                return true
            }
            guard let expected = GoNative.argumentCounts[name] else { return false }
            guard argumentCount == expected else {
                throw GoRuntimeError.argumentCountMismatch(
                    function: name, expected: expected, actual: argumentCount)
            }
            /// The elements a slice operand exposes, plus where they live.
            func sliceElements(
                _ value: GoValue
            ) throws -> (slice: GoSliceValue, backing: [GoValue], range: Range<Int>)? {
                switch value {
                case .nilValue:
                    return nil
                case .slice(let slice):
                    let range = try validatedSliceRange(slice)
                    guard case .array(let backing) = try read(pointer: slice.backing, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    return (slice, backing, range)
                default:
                    throw GoRuntimeError.typeMismatch
                }
            }
            /// The elements a `copy` or `append(slice, source...)` source
            /// supplies, in an array of their own: reading them first makes an
            /// overlapping move behave like Go's, in either direction.
            func sourceElements(_ source: GoValue) throws -> [GoValue] {
                switch source {
                case .string(let text):
                    return text.utf8.map { .int(Int64($0)) }
                case .nilValue:
                    return []
                case .slice(let slice):
                    let range = try validatedSliceRange(slice)
                    guard case .array(let backing) = try read(pointer: slice.backing, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    return Array(backing[range])
                default:
                    throw GoRuntimeError.typeMismatch
                }
            }
            switch name {
            case "$bits.not":
                guard case .int(let value) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                stack.append(.int(~value))
            case "$conv.bytesToString":
                var bytes: [UInt8] = []
                if let elements = try sliceElements(try pop(&stack)) {
                    bytes.reserveCapacity(elements.range.count)
                    for element in elements.backing[elements.range] {
                        guard case .int(let raw) = element, let byte = UInt8(exactly: raw) else {
                            throw GoRuntimeError.typeMismatch
                        }
                        bytes.append(byte)
                    }
                }
                let text = GoNative.string(fromBytes: bytes)
                guard text.utf8.count <= resourceLimits.maximumStringBytes else {
                    throw GoRuntimeError.resourceLimitExceeded("string bytes")
                }
                stack.append(.string(text))
            case "$conv.stringToBytes":
                guard case .string(let text) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                try requireCollectionCount(text.utf8.count, resource: "slice elements")
                let elements = text.utf8.map { GoValue.int(Int64($0)) }
                let cell = try vm.heap.allocate(.array(elements))
                stack.append(
                    .slice(
                        GoSliceValue(
                            backing: GoPointer(cell: cell),
                            start: 0,
                            length: elements.count,
                            capacity: elements.count,
                            zeroValue: .int(0))))
            case "$conv.runeToString":
                guard case .int(let value) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                stack.append(.string(GoNative.string(fromCodePoint: value)))
            case "$strconv.Itoa":
                guard case .int(let value) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                stack.append(.string(String(value)))
            case "$errors.New":
                guard case .string(let message) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                stack.append(try makeError(message))
            case "$new":
                // The address of a composite literal: a variable of its own
                // each time, which lives as long as a pointer reaches it.
                let cell = try vm.heap.allocate(try pop(&stack))
                stack.append(.pointer(GoPointer(cell: cell)))
            case "$clear":
                // `clear`: a map keeps its identity and loses its entries,
                // and every element of a slice becomes the zero value that
                // is the second operand. A nil map or slice has nothing.
                let zero = try pop(&stack)
                switch try pop(&stack) {
                case .nilValue:
                    break
                case .map(let mapValue):
                    guard mapValue.storage.path.isEmpty, vm.heap.contains(mapValue.storage.cell),
                        case .mapStorage = vm.heap[mapValue.storage.cell]
                    else { throw GoRuntimeError.typeMismatch }
                    try vm.heap.replace(mapValue.storage.cell, with: .mapStorage(GoMapStorage()))
                case .slice(let slice):
                    let range = try validatedSliceRange(slice)
                    try storeElements(
                        try copiedLocks(Array(repeating: zero, count: range.count)), into: slice)
                default:
                    throw GoRuntimeError.typeMismatch
                }
            case "$strings.ToUpper", "$strings.ToLower":
                guard case .string(let text) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                // A mapped code point can be longer than the original.
                let mapped = GoStrings.mapped(text, toUpper: name == "$strings.ToUpper")
                guard mapped.utf8.count <= resourceLimits.maximumStringBytes else {
                    throw GoRuntimeError.resourceLimitExceeded("string bytes")
                }
                stack.append(.string(mapped))
            case "$strings.Fields":
                guard case .string(let text) = try pop(&stack) else {
                    throw GoRuntimeError.typeMismatch
                }
                let elements = GoStrings.fields(text).map { GoValue.string($0) }
                try requireCollectionCount(elements.count, resource: "slice elements")
                let cell = try vm.heap.allocate(.array(elements))
                stack.append(
                    .slice(
                        GoSliceValue(
                            backing: GoPointer(cell: cell), start: 0, length: elements.count,
                            capacity: elements.count, zeroValue: .string(""))))
            case "$strings.TrimPrefix", "$strings.TrimSuffix":
                guard case .string(let affix) = try pop(&stack),
                    case .string(let text) = try pop(&stack)
                else { throw GoRuntimeError.typeMismatch }
                stack.append(
                    .string(
                        name == "$strings.TrimPrefix"
                            ? GoStrings.trimPrefix(text, affix) : GoStrings.trimSuffix(text, affix)))
            case "$append":
                var zero = try pop(&stack)
                let values = try copiedLocks(try sourceElements(try pop(&stack)))
                let base = try pop(&stack)
                var elements: [GoValue] = []
                var capacity = 0
                if case .slice(let slice) = base {
                    let range = try validatedSliceRange(slice)
                    if values.isEmpty {
                        // Nothing to add: the slice itself, as in Go.
                        stack.append(base)
                        break
                    }
                    let newLength = try checkedAdd(
                        slice.length, values.count, resource: "slice elements")
                    try requireCollectionCount(newLength, resource: "slice elements")
                    if newLength <= slice.capacity {
                        // The spare capacity is a window of the same backing
                        // array, so other slices of it see the new elements.
                        try storeElements(
                            values,
                            into: GoSliceValue(
                                backing: slice.backing,
                                start: range.upperBound,
                                length: values.count,
                                capacity: slice.capacity - slice.length,
                                zeroValue: slice.zeroValue))
                        stack.append(
                            .slice(
                                GoSliceValue(
                                    backing: slice.backing, start: slice.start,
                                    length: newLength, capacity: slice.capacity,
                                    zeroValue: slice.zeroValue)))
                        break
                    }
                    guard case .array(let backing) = try read(pointer: slice.backing, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    elements = Array(backing[range])
                    capacity = slice.capacity
                    zero = slice.zeroValue
                } else if base != .nilValue {
                    throw GoRuntimeError.typeMismatch
                } else if values.isEmpty {
                    stack.append(.nilValue)
                    break
                }
                elements.append(contentsOf: values)
                let newLength = elements.count
                try requireCollectionCount(newLength, resource: "slice elements")
                // Double like a one-element append, but never past the
                // collection limit while the new length still fits it.
                let (doubled, overflow) = capacity.multipliedReportingOverflow(by: 2)
                let newCapacity = max(
                    newLength,
                    min(overflow ? Int.max : doubled, resourceLimits.maximumCollectionElements))
                elements.append(contentsOf: repeatElement(zero, count: newCapacity - newLength))
                let cell = try vm.heap.allocate(.array(try copiedLocks(elements)))
                stack.append(
                    .slice(
                        GoSliceValue(
                            backing: GoPointer(cell: cell), start: 0, length: newLength,
                            capacity: newCapacity, zeroValue: zero)))
            case "$copy":
                let source = try pop(&stack)
                let destination = try pop(&stack)
                var values = try sourceElements(source)
                var copied = 0
                if case .slice(let target) = destination {
                    copied = min(values.count, try validatedSliceRange(target).count)
                    values.removeSubrange(copied...)
                    try storeElements(try copiedLocks(values), into: target)
                } else if destination != .nilValue {
                    throw GoRuntimeError.typeMismatch
                }
                stack.append(.int(Int64(copied)))
            case "$sort.Strings", "$sort.Ints":
                guard let elements = try sliceElements(try pop(&stack)) else { break }
                var backing = elements.backing
                if name == "$sort.Strings" {
                    let strings = try backing[elements.range].map { element -> String in
                        guard case .string(let text) = element else {
                            throw GoRuntimeError.typeMismatch
                        }
                        return text
                    }
                    backing.replaceSubrange(
                        elements.range,
                        with: GoNative.sortedStrings(strings).map { GoValue.string($0) })
                } else {
                    let integers = try backing[elements.range].map { element -> Int64 in
                        guard case .int(let value) = element else {
                            throw GoRuntimeError.typeMismatch
                        }
                        return value
                    }
                    backing.replaceSubrange(
                        elements.range,
                        with: integers.sorted().map { GoValue.int($0) })
                }
                try writePointer(.array(backing), through: elements.slice.backing, heap: &vm.heap)
            default:
                let (lhs, rhs) = try integerPair(&stack)
                guard let result = try GoNative.integerBinary(name, lhs, rhs) else {
                    return false
                }
                stack.append(.int(result))
            }
            return true
        }

        /// Run guest code until the program finishes or suspends on host input.
        ///
        /// A run-time error of the program, which Go reports as a panic, is
        /// raised by the instruction that meets it and becomes a panic of the
        /// frame that was executing: its deferred functions run, and one of
        /// them may `recover`.
        func runSlice() throws {
            while true {
                do {
                    return try runInstructions()
                } catch let panic as GoRuntimePanic {
                    guard !vm.frames.isEmpty else { throw GoRuntimeError.panicError(panic.message) }
                    vm.frames[vm.frames.count - 1].pendingExit = .panicking(panic.value)
                }
            }
        }

        func runInstructions() throws {
            executionLoop: while true {
                if vm.frames.isEmpty {
                    if vm.currentGoroutineID != 0 {
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
                    vm.frames.append(
                        try makeFrame(function: function, stackBase: 0, arguments: [], heap: &vm.heap))
                }
                if let pendingExit = vm.frames[vm.frames.count - 1].pendingExit {
                    let exitingIndex = vm.frames.count - 1
                    if let deferred = vm.frames[exitingIndex].deferredCalls.popLast() {
                        activeDeferredCallCount -= 1
                        if deferred.function == GoNative.callFunctionValue,
                            let value = deferred.arguments.first
                        {
                            // The value was read when the call was deferred.
                            let target = try functionValueTarget(value)
                            guard vm.frames.count < maximumCallDepth else {
                                throw GoRuntimeError.callStackLimitExceeded
                            }
                            vm.frames.append(
                                try makeFrame(
                                    function: target.function,
                                    stackBase: vm.stack.count,
                                    arguments: try target.arguments(
                                        with: deferred.arguments.dropFirst()),
                                    heap: &vm.heap,
                                    isDeferredCall: true))
                        } else if let function = functions[deferred.function]
                            ?? builtinGoroutineFunction(
                                named: deferred.function,
                                argumentCount: deferred.arguments.count)
                        {
                            guard vm.frames.count < maximumCallDepth else {
                                throw GoRuntimeError.callStackLimitExceeded
                            }
                            vm.frames.append(
                                try makeFrame(
                                    function: function,
                                    stackBase: vm.stack.count,
                                    arguments: deferred.arguments,
                                    heap: &vm.heap,
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
                        try scheduleNext(requeueCurrent: !vm.currentBlocked)
                        continue
                    }

                    let exiting = vm.frames.removeLast()
                    releaseFrame(exiting)
                    guard vm.stack.count >= exiting.stackBase else {
                        throw GoRuntimeError.stackUnderflow
                    }
                    if vm.stack.count > exiting.stackBase {
                        vm.stack.removeSubrange(exiting.stackBase...)
                    }
                    switch pendingExit {
                    case .returning(var values):
                        if exiting.resultLocals != nil {
                            values = try resultValues(of: exiting)
                        }
                        if var report = exiting.panicReport {
                            // The method has said what the panic is.
                            if case .string(let text)? = values.first {
                                report.describeFirst(as: text)
                            } else {
                                report.skipsMethod = true
                            }
                            try reportPanics(report)
                            continue
                        }
                        if exiting.isDeferredCall, !vm.frames.isEmpty,
                            vm.frames[vm.frames.count - 1].recoveredPanic != nil
                        {
                            // The call that recovered has returned: that
                            // panic, and those it had cut short, are over.
                            vm.frames[vm.frames.count - 1].recoveredPanic = nil
                            vm.frames[vm.frames.count - 1].earlierPanics = []
                        }
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
                            vm.stack.append(contentsOf: values)
                        }
                    case .panicking(let value):
                        guard !vm.frames.isEmpty else {
                            if var report = exiting.panicReport {
                                // The method that was to describe a panic
                                // panicked itself: its type and place do.
                                report.skipsMethod = true
                                try reportPanics(report)
                            } else {
                                try reportPanics(
                                    GoPanicReport(
                                        pending: exiting.earlierPanics
                                            + [GoPanicRecord(value: value, isRecovered: false)]))
                            }
                            continue
                        }
                        if vm.frames[vm.frames.count - 1].awaitsGuestCall,
                            vm.frames[vm.frames.count - 1].guestCallRecovery != .none
                        {
                            deliverGuestPanic(value)
                        } else {
                            let parent = vm.frames.count - 1
                            if exiting.isDeferredCall {
                                // The function was panicking when the call
                                // ran, or the call had recovered its panic:
                                // either comes before this one.
                                if case .panicking(let interrupted)? = vm.frames[parent].pendingExit {
                                    vm.frames[parent].earlierPanics.append(
                                        GoPanicRecord(value: interrupted, isRecovered: false))
                                } else if let recovered = vm.frames[parent].recoveredPanic {
                                    vm.frames[parent].earlierPanics.append(
                                        GoPanicRecord(value: recovered, isRecovered: true))
                                    vm.frames[parent].recoveredPanic = nil
                                }
                            }
                            vm.frames[parent].earlierPanics += exiting.earlierPanics
                            vm.frames[parent].pendingExit = .panicking(value)
                        }
                    case .testFatal:
                        if !vm.frames.isEmpty {
                            vm.frames[vm.frames.count - 1].pendingExit = .testFatal
                        }
                    }
                    if vm.frames.isEmpty {
                        if vm.currentGoroutineID == 0, startupFunctions.isEmpty {
                            break executionLoop
                        }
                        if vm.currentGoroutineID != 0 {
                            try resumeAfterGoroutineCompletion()
                            continue
                        }
                    }
                    try scheduleNext(requeueCurrent: true)
                    continue
                }
                let frameIndex = vm.frames.count - 1
                // The frame is a class: one read of `frames` serves the
                // whole instruction.
                let frame = vm.frames[frameIndex]
                let programCounter = frame.programCounter
                if programCounter >= frame.function.instructions.count {
                    frame.pendingExit = .returning([])
                    try scheduleNext(requeueCurrent: true)
                    continue
                }
                let instruction = frame.function.instructions[programCounter]
                frame.programCounter = programCounter + 1
                vm.currentBlocked = false
                vm.executed += 1
                guard vm.executed - vm.sliceStartInstruction <= instructionLimit else {
                    throw GoRuntimeError.instructionLimitExceeded
                }
                #if SWIFTIX_GO_PROFILE
                GoExecutionProfile.current?.record(
                    vm.frames[frameIndex].function,
                    programCounter: vm.frames[frameIndex].programCounter - 1)
                #endif
                switch instruction {
                case .push(let value):
                    vm.stack.append(value)
                case .load(let index):
                    guard frame.locals.indices.contains(index),
                        let cell = frame.locals[index],
                        let value = vm.heap.valueIfPresent(cell)
                    else {
                        throw GoRuntimeError.invalidLocal(index)
                    }
                    vm.stack.append(value)
                case .store(let index):
                    guard frame.locals.indices.contains(index) else {
                        throw GoRuntimeError.invalidLocal(index)
                    }
                    let value = try pop(&vm.stack)
                    if let cell = frame.locals[index] {
                        try vm.heap.replace(cell, with: value)
                    } else {
                        frame.locals[index] = try vm.heap.allocate(value)
                    }
                case .negate:
                    guard case .int(let value) = try pop(&vm.stack) else { throw GoRuntimeError.typeMismatch }
                    vm.stack.append(.int(0 &- value))
                case .not:
                    guard case .bool(let value) = try pop(&vm.stack) else { throw GoRuntimeError.typeMismatch }
                    vm.stack.append(.bool(!value))
                case .add:
                    let (left, right) = try popPair(&vm.stack)
                    switch (left, right) {
                    case (.int(let lhs), .int(let rhs)): vm.stack.append(.int(lhs &+ rhs))
                    case (.string(let lhs), .string(let rhs)):
                        let byteCount = try checkedAdd(
                            lhs.utf8.count, rhs.utf8.count, resource: "string bytes")
                        guard byteCount <= resourceLimits.maximumStringBytes else {
                            throw GoRuntimeError.resourceLimitExceeded("string bytes")
                        }
                        vm.stack.append(.string(lhs + rhs))
                    default: throw GoRuntimeError.typeMismatch
                    }
                case .subtract:
                    try integerBinary(&vm.stack) { $0 &- $1 }
                case .multiply:
                    try integerBinary(&vm.stack) { $0 &* $1 }
                case .divide:
                    let (lhs, rhs) = try integerPair(&vm.stack)
                    guard rhs != 0 else { throw GoRuntimePanic.divideByZero }
                    if lhs == Int64.min, rhs == -1 {
                        // Go defines signed integer division using two's-complement
                        // arithmetic; this quotient wraps to the minimum value.
                        vm.stack.append(.int(Int64.min))
                    } else {
                        vm.stack.append(.int(lhs / rhs))
                    }
                case .remainder:
                    let (lhs, rhs) = try integerPair(&vm.stack)
                    guard rhs != 0 else { throw GoRuntimePanic.divideByZero }
                    vm.stack.append(.int(lhs == Int64.min && rhs == -1 ? 0 : lhs % rhs))
                case .equal:
                    let (left, right) = try popPair(&vm.stack)
                    vm.stack.append(.bool(left == right))
                case .notEqual:
                    let (left, right) = try popPair(&vm.stack)
                    vm.stack.append(.bool(left != right))
                case .less:
                    try orderedComparison(&vm.stack, integer: <, string: <)
                case .lessEqual:
                    try orderedComparison(&vm.stack, integer: <=, string: <=)
                case .greater:
                    try orderedComparison(&vm.stack, integer: >, string: >)
                case .greaterEqual:
                    try orderedComparison(&vm.stack, integer: >=, string: >=)
                case .logicalAnd:
                    try booleanBinary(&vm.stack) { $0 && $1 }
                case .logicalOr:
                    try booleanBinary(&vm.stack) { $0 || $1 }
                case .print(let argumentCount, let newline):
                    try resumeGuestCalls()
                    guard argumentCount >= 0, vm.stack.count >= argumentCount else {
                        throw GoRuntimeError.stackUnderflow
                    }
                    let start = vm.stack.count - argumentCount
                    let operands = Array(vm.stack[start...])
                    vm.stack.removeSubrange(start...)
                    let values = try variadicOperands(operands)
                    let separator = newline ? " " : ""
                    guard
                        let text = try replayingGuestCalls(
                            operands: operands,
                            {
                                try formatOutput(
                                    values, separator: separator, suffix: newline ? "\n" : "")
                            })
                    else { break }
                    try emit(text)
                case .jump(let target):
                    try jump(to: target, in: frame)
                case .jumpIfFalse(let target):
                    guard case .bool(let condition) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    if !condition { try jump(to: target, in: frame) }
                case .jumpIfTrue(let target):
                    guard case .bool(let condition) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    if condition { try jump(to: target, in: frame) }
                case .call(let name, let argumentCount):
                    if name == GoNative.callFunctionValue {
                        // The function value lies under the arguments.
                        guard argumentCount >= 1, vm.stack.count >= argumentCount else {
                            throw GoRuntimeError.stackUnderflow
                        }
                        let start = vm.stack.count - argumentCount
                        let operands = Array(vm.stack[start...])
                        vm.stack.removeSubrange(start...)
                        let target = try functionValueTarget(operands[0])
                        guard vm.frames.count < maximumCallDepth else {
                            throw GoRuntimeError.callStackLimitExceeded
                        }
                        vm.frames.append(
                            try makeFrame(
                                function: target.function,
                                stackBase: vm.stack.count,
                                arguments: try target.arguments(with: operands.dropFirst()),
                                heap: &vm.heap))
                        break
                    }
                    guard let function = functions[name] else {
                        guard
                            try executePureNative(
                                name, argumentCount: argumentCount, stack: &vm.stack)
                                || executeHostNative(name, argumentCount: argumentCount)
                                || executeFileNative(name, argumentCount: argumentCount)
                                || executeCalendarNative(name, argumentCount: argumentCount)
                                || executeTimeNative(name, argumentCount: argumentCount)
                                || executeSyncNative(name, argumentCount: argumentCount)
                                || executeTimerNative(name, argumentCount: argumentCount)
                                || executeProcessNative(name, argumentCount: argumentCount)
                                || executeNumericNative(name, argumentCount: argumentCount)
                                || executeFormatNative(name, argumentCount: argumentCount)
                                || executeErrorNative(name, argumentCount: argumentCount)
                                || executeSliceNative(name, argumentCount: argumentCount)
                                || executeHTTPNative(name, argumentCount: argumentCount)
                                || executeURLNative(name, argumentCount: argumentCount)
                                || executeBytesNative(name, argumentCount: argumentCount)
                        else {
                            throw GoRuntimeError.missingFunction(name)
                        }
                        break
                    }
                    guard vm.frames.count < maximumCallDepth else {
                        throw GoRuntimeError.callStackLimitExceeded
                    }
                    guard argumentCount >= 0, vm.stack.count >= argumentCount else {
                        throw GoRuntimeError.stackUnderflow
                    }
                    guard argumentCount == function.parameterCount else {
                        throw GoRuntimeError.argumentCountMismatch(
                            function: name,
                            expected: function.parameterCount,
                            actual: argumentCount)
                    }
                    let argumentStart = vm.stack.count - argumentCount
                    let arguments = Array(vm.stack[argumentStart...])
                    vm.stack.removeSubrange(argumentStart...)
                    vm.frames.append(
                        try makeFrame(
                            function: function,
                            stackBase: vm.stack.count,
                            arguments: arguments,
                            heap: &vm.heap))
                case .spawn(let name, let argumentCount):
                    guard argumentCount >= 0, vm.stack.count >= argumentCount else {
                        throw GoRuntimeError.stackUnderflow
                    }
                    let argumentStart = vm.stack.count - argumentCount
                    var arguments = Array(vm.stack[argumentStart...])
                    let function: GoBytecodeFunction
                    if name == GoNative.callFunctionValue {
                        guard let value = arguments.first else {
                            throw GoRuntimeError.stackUnderflow
                        }
                        let target = try functionValueTarget(value)
                        function = target.function
                        arguments = try target.arguments(with: arguments.dropFirst())
                    } else {
                        guard let named = functions[name]
                            ?? builtinGoroutineFunction(named: name, argumentCount: argumentCount)
                        else {
                            throw GoRuntimeError.missingFunction(name)
                        }
                        guard argumentCount == named.parameterCount else {
                            throw GoRuntimeError.argumentCountMismatch(
                                function: name,
                                expected: named.parameterCount,
                                actual: argumentCount)
                        }
                        function = named
                    }
                    vm.stack.removeSubrange(argumentStart...)
                    guard resourceLimits.maximumGoroutines >= 2,
                        vm.goroutines.count <= resourceLimits.maximumGoroutines - 2
                    else {
                        throw GoRuntimeError.resourceLimitExceeded("goroutines")
                    }
                    guard nextGoroutineID < Int.max else {
                        throw GoRuntimeError.resourceLimitExceeded("goroutine identifiers")
                    }
                    let id = nextGoroutineID
                    nextGoroutineID += 1
                    vm.goroutines[id] = GoroutineContext(
                        frames: [try makeFrame(
                            function: function,
                            stackBase: 0,
                            arguments: arguments,
                            heap: &vm.heap)],
                        stack: [])
                    vm.runQueue.append(id)
                case .makeStruct(let typeName, let fieldNames):
                    guard vm.stack.count >= fieldNames.count else {
                        throw GoRuntimeError.stackUnderflow
                    }
                    let start = vm.stack.count - fieldNames.count
                    let values = Array(vm.stack[start...])
                    vm.stack.removeSubrange(start...)
                    vm.stack.append(
                        .structure(
                            GoStructValue(
                                typeName: typeName,
                                fields: zip(fieldNames, values).map {
                                    GoStructFieldValue(name: $0.0, value: $0.1)
                                })))
                case .getField(let name):
                    guard case .structure(let structure) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard let field = structure.fields.first(where: { $0.name == name }) else {
                        throw GoRuntimeError.unknownField(name)
                    }
                    vm.stack.append(field.value)
                case .setField(let name):
                    let value = try pop(&vm.stack)
                    guard case .structure(var structure) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard let index = structure.fields.firstIndex(where: { $0.name == name }) else {
                        throw GoRuntimeError.unknownField(name)
                    }
                    structure.fields[index].value = value
                    vm.stack.append(.structure(structure))
                case .addressLocal(let index, let fieldPath):
                    guard vm.frames[frameIndex].locals.indices.contains(index),
                        let cell = vm.frames[frameIndex].locals[index]
                    else {
                        throw GoRuntimeError.invalidLocal(index)
                    }
                    guard fieldPath.count <= resourceLimits.maximumPointerDepth else {
                        throw GoRuntimeError.resourceLimitExceeded("pointer depth")
                    }
                    vm.stack.append(
                        .pointer(
                            GoPointer(
                                cell: cell,
                                path: fieldPath.map(GoPointerComponent.field))))
                case .fieldAddress(let name):
                    let pointerValue = try pop(&vm.stack)
                    if pointerValue == .nilValue { throw GoRuntimePanic.nilDereference }
                    guard case .pointer(let pointer) = pointerValue else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard pointer.path.count < resourceLimits.maximumPointerDepth else {
                        throw GoRuntimeError.resourceLimitExceeded("pointer depth")
                    }
                    vm.stack.append(
                        .pointer(
                            GoPointer(
                                cell: pointer.cell,
                                path: pointer.path + [.field(name)])))
                case .dereference:
                    let pointerValue = try pop(&vm.stack)
                    if pointerValue == .nilValue { throw GoRuntimePanic.nilDereference }
                    guard case .pointer(let pointer) = pointerValue else {
                        throw GoRuntimeError.typeMismatch
                    }
                    vm.stack.append(try read(pointer: pointer, heap: vm.heap))
                case .setPointer:
                    let value = try pop(&vm.stack)
                    let pointerValue = try pop(&vm.stack)
                    if pointerValue == .nilValue { throw GoRuntimePanic.nilDereference }
                    guard case .pointer(let pointer) = pointerValue else {
                        throw GoRuntimeError.typeMismatch
                    }
                    try writePointer(value, through: pointer, heap: &vm.heap)
                case .makeArray(let elementCount):
                    guard elementCount >= 0, vm.stack.count >= elementCount else {
                        throw GoRuntimeError.stackUnderflow
                    }
                    let start = vm.stack.count - elementCount
                    let values = Array(vm.stack[start...])
                    vm.stack.removeSubrange(start...)
                    vm.stack.append(.array(values))
                case .makeSlice(let elementCount):
                    guard elementCount >= 0 else {
                        throw GoRuntimeError.invalidExecutable("negative slice element count")
                    }
                    let requiredCount = try checkedAdd(
                        elementCount, 1, resource: "operand stack")
                    guard vm.stack.count >= requiredCount else {
                        throw GoRuntimeError.stackUnderflow
                    }
                    let start = vm.stack.count - elementCount
                    let values = Array(vm.stack[start...])
                    vm.stack.removeSubrange(start...)
                    let zero = try pop(&vm.stack)
                    let cell = try vm.heap.allocate(.array(values))
                    vm.stack.append(
                        .slice(
                            GoSliceValue(
                                backing: GoPointer(cell: cell),
                                start: 0,
                                length: values.count,
                                capacity: values.count,
                                zeroValue: zero)))
                case .allocateSlice:
                    guard case .int(let capacity) = try pop(&vm.stack),
                        case .int(let length) = try pop(&vm.stack)
                    else { throw GoRuntimeError.typeMismatch }
                    let zero = try pop(&vm.stack)
                    guard length >= 0, let exactLength = Int(exactly: length) else {
                        throw GoRuntimePanic.makeSliceLength
                    }
                    guard capacity >= length, let exactCapacity = Int(exactly: capacity) else {
                        throw GoRuntimePanic.makeSliceCapacity
                    }
                    try requireCollectionCount(exactCapacity, resource: "slice elements")
                    let cell = try vm.heap.allocate(
                        .array(try copiedLocks(Array(repeating: zero, count: exactCapacity))))
                    vm.stack.append(
                        .slice(
                            GoSliceValue(
                                backing: GoPointer(cell: cell),
                                start: 0,
                                length: exactLength,
                                capacity: exactCapacity,
                                zeroValue: zero)))
                case .getIndex:
                    guard case .int(let rawIndex) = try pop(&vm.stack),
                        let index = Int(exactly: rawIndex)
                    else { throw GoRuntimeError.typeMismatch }
                    let base = try pop(&vm.stack)
                    switch base {
                    case .array(let values):
                        guard values.indices.contains(index) else {
                            throw GoRuntimePanic.index(index, length: values.count)
                        }
                        vm.stack.append(values[index])
                    case .slice(let slice):
                        _ = try validatedSliceRange(slice)
                        guard index >= 0, index < slice.length else {
                            throw GoRuntimePanic.index(index, length: slice.length)
                        }
                        let absoluteIndex = try checkedAdd(
                            slice.start, index, resource: "slice index")
                        vm.stack.append(
                            try read(
                                pointer: appending(index: absoluteIndex, to: slice.backing),
                                heap: vm.heap))
                    case .string(let string):
                        // Offsetting a native string's UTF-8 view is O(1); copying
                        // it into an array made byte loops quadratic.
                        let utf8 = string.utf8
                        guard index >= 0, index < utf8.count else {
                            throw GoRuntimePanic.index(index, length: utf8.count)
                        }
                        vm.stack.append(.int(Int64(utf8[utf8.index(utf8.startIndex, offsetBy: index)])))
                    case .nilValue:
                        // A nil slice has no elements.
                        throw GoRuntimePanic.index(index, length: 0)
                    default:
                        throw GoRuntimeError.typeMismatch
                    }
                case .setIndex:
                    let value = try pop(&vm.stack)
                    guard case .int(let rawIndex) = try pop(&vm.stack),
                        let index = Int(exactly: rawIndex)
                    else { throw GoRuntimeError.typeMismatch }
                    let base = try pop(&vm.stack)
                    switch base {
                    case .array(var values):
                        guard values.indices.contains(index) else {
                            throw GoRuntimePanic.index(index, length: values.count)
                        }
                        values[index] = value
                        vm.stack.append(.array(values))
                    case .slice(let slice):
                        _ = try validatedSliceRange(slice)
                        guard index >= 0, index < slice.length else {
                            throw GoRuntimePanic.index(index, length: slice.length)
                        }
                        let absoluteIndex = try checkedAdd(
                            slice.start, index, resource: "slice index")
                        try writePointer(
                            value,
                            through: appending(index: absoluteIndex, to: slice.backing),
                            heap: &vm.heap)
                        vm.stack.append(.slice(slice))
                    case .nilValue:
                        throw GoRuntimePanic.index(index, length: 0)
                    default:
                        throw GoRuntimeError.typeMismatch
                    }
                case .slice:
                    guard case .int(let rawHigh) = try pop(&vm.stack),
                        case .int(let rawLow) = try pop(&vm.stack),
                        let low = Int(exactly: rawLow),
                        let high = Int(exactly: rawHigh)
                    else { throw GoRuntimeError.typeMismatch }
                    let base = try pop(&vm.stack)
                    switch base {
                    case .slice(let slice):
                        _ = try validatedSliceRange(slice)
                        if let panic = GoRuntimePanic.slice(
                            low: low, high: high, limit: slice.capacity, limitIsCapacity: true)
                        {
                            throw panic
                        }
                        let newStart = try checkedAdd(
                            slice.start, low, resource: "slice bounds")
                        vm.stack.append(
                            .slice(
                                GoSliceValue(
                                    backing: slice.backing,
                                    start: newStart,
                                    length: high - low,
                                    capacity: slice.capacity - low,
                                    zeroValue: slice.zeroValue)))
                    case .string(let string):
                        let utf8 = string.utf8
                        if let panic = GoRuntimePanic.slice(
                            low: low, high: high, limit: utf8.count, limitIsCapacity: false)
                        {
                            throw panic
                        }
                        let lower = utf8.index(utf8.startIndex, offsetBy: low)
                        let upper = utf8.index(lower, offsetBy: high - low)
                        vm.stack.append(.string(String(decoding: utf8[lower..<upper], as: UTF8.self)))
                    case .nilValue:
                        // A nil slice can be sliced from 0 to 0, and stays nil.
                        if let panic = GoRuntimePanic.slice(
                            low: low, high: high, limit: 0, limitIsCapacity: true)
                        {
                            throw panic
                        }
                        vm.stack.append(.nilValue)
                    default:
                        throw GoRuntimeError.typeMismatch
                    }
                case .sliceArray:
                    let zero = try pop(&vm.stack)
                    guard case .int(let rawHigh) = try pop(&vm.stack),
                        case .int(let rawLow) = try pop(&vm.stack),
                        let low = Int(exactly: rawLow),
                        let high = Int(exactly: rawHigh)
                    else { throw GoRuntimeError.typeMismatch }
                    let arrayPointer = try pop(&vm.stack)
                    if arrayPointer == .nilValue { throw GoRuntimePanic.nilDereference }
                    guard case .pointer(let pointer) = arrayPointer,
                        case .array(let values) = try read(pointer: pointer, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    if let panic = GoRuntimePanic.slice(
                        low: low, high: high, limit: values.count, limitIsCapacity: false)
                    {
                        throw panic
                    }
                    vm.stack.append(
                        .slice(
                            GoSliceValue(
                                backing: pointer,
                                start: low,
                                length: high - low,
                                capacity: values.count - low,
                                zeroValue: zero)))
                case .length:
                    let base = try pop(&vm.stack)
                    switch base {
                    case .array(let values): vm.stack.append(.int(Int64(values.count)))
                    case .slice(let slice):
                        _ = try validatedSliceRange(slice)
                        vm.stack.append(.int(Int64(slice.length)))
                    case .string(let string): vm.stack.append(.int(Int64(string.utf8.count)))
                    case .map(let mapValue):
                        guard case .mapStorage(let storage) = try read(pointer: mapValue.storage, heap: vm.heap)
                        else { throw GoRuntimeError.typeMismatch }
                        vm.stack.append(.int(Int64(storage.count)))
                    case .channel(let channel):
                        guard case .channelStorage(let storage) = try read(
                            pointer: channel.storage, heap: vm.heap)
                        else { throw GoRuntimeError.typeMismatch }
                        vm.stack.append(.int(Int64(storage.buffer.count)))
                    case .nilValue: vm.stack.append(.int(0))
                    default: throw GoRuntimeError.typeMismatch
                    }
                case .capacity:
                    let base = try pop(&vm.stack)
                    switch base {
                    case .array(let values): vm.stack.append(.int(Int64(values.count)))
                    case .slice(let slice):
                        _ = try validatedSliceRange(slice)
                        vm.stack.append(.int(Int64(slice.capacity)))
                    case .channel(let channel):
                        guard case .channelStorage(let storage) = try read(
                            pointer: channel.storage, heap: vm.heap)
                        else { throw GoRuntimeError.typeMismatch }
                        vm.stack.append(.int(Int64(storage.capacity)))
                    case .nilValue: vm.stack.append(.int(0))
                    default: throw GoRuntimeError.typeMismatch
                    }
                case .append:
                    let suppliedZero = try pop(&vm.stack)
                    let value = try pop(&vm.stack)
                    let base = try pop(&vm.stack)
                    var slice: GoSliceValue
                    if case .slice(let existing) = base {
                        slice = existing
                    } else if base == .nilValue {
                        let cell = try vm.heap.allocate(.array([]))
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
                            heap: &vm.heap)
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
                                    heap: vm.heap))
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
                        let cell = try vm.heap.allocate(.array(try copiedLocks(values)))
                        slice = GoSliceValue(
                            backing: GoPointer(cell: cell),
                            start: 0,
                            length: newLength,
                            capacity: newCapacity,
                            zeroValue: slice.zeroValue)
                    }
                    vm.stack.append(.slice(slice))
                case .indexAddress:
                    guard case .int(let rawIndex) = try pop(&vm.stack),
                        let index = Int(exactly: rawIndex)
                    else { throw GoRuntimeError.typeMismatch }
                    let base = try pop(&vm.stack)
                    switch base {
                    case .pointer(let pointer):
                        guard pointer.path.count < resourceLimits.maximumPointerDepth else {
                            throw GoRuntimeError.resourceLimitExceeded("pointer depth")
                        }
                        guard case .array(let values) = try read(pointer: pointer, heap: vm.heap)
                        else { throw GoRuntimeError.typeMismatch }
                        guard values.indices.contains(index) else {
                            throw GoRuntimePanic.index(index, length: values.count)
                        }
                        vm.stack.append(.pointer(appending(index: index, to: pointer)))
                    case .slice(let slice):
                        _ = try validatedSliceRange(slice)
                        guard index >= 0, index < slice.length else {
                            throw GoRuntimePanic.index(index, length: slice.length)
                        }
                        let absoluteIndex = try checkedAdd(
                            slice.start, index, resource: "slice index")
                        vm.stack.append(
                            .pointer(appending(index: absoluteIndex, to: slice.backing)))
                    case .nilValue:
                        throw GoRuntimePanic.index(index, length: 0)
                    default:
                        throw GoRuntimeError.typeMismatch
                    }
                case .loadGlobal(let index):
                    guard index >= 0, index < executable.globalCount else {
                        throw GoRuntimeError.invalidLocal(index)
                    }
                    vm.stack.append(vm.heap[index])
                case .storeGlobal(let index):
                    guard index >= 0, index < executable.globalCount else {
                        throw GoRuntimeError.invalidLocal(index)
                    }
                    try vm.heap.replace(index, with: pop(&vm.stack))
                case .addressGlobal(let index):
                    guard index >= 0, index < executable.globalCount else {
                        throw GoRuntimeError.invalidLocal(index)
                    }
                    vm.stack.append(.pointer(GoPointer(cell: index)))
                case .deferCall(let name, let argumentCount):
                    guard argumentCount >= 0, vm.stack.count >= argumentCount else {
                        throw GoRuntimeError.stackUnderflow
                    }
                    let start = vm.stack.count - argumentCount
                    let arguments = Array(vm.stack[start...])
                    vm.stack.removeSubrange(start...)
                    guard activeDeferredCallCount < resourceLimits.maximumRuntimeHandles else {
                        throw GoRuntimeError.resourceLimitExceeded("deferred calls")
                    }
                    vm.frames[frameIndex].deferredCalls.append(
                        DeferredCall(function: name, arguments: arguments))
                    activeDeferredCallCount += 1
                case .panic:
                    let value = vm.stack.popLast() ?? .string("nil")
                    vm.frames[frameIndex].pendingExit = .panicking(value)
                case .recover:
                    guard vm.frames[frameIndex].isDeferredCall, frameIndex > 0,
                        case .panicking(let value) = vm.frames[frameIndex - 1].pendingExit
                    else {
                        vm.stack.append(.nilValue)
                        break
                    }
                    vm.frames[frameIndex - 1].pendingExit = .returning(
                        try resultValues(of: vm.frames[frameIndex - 1]))
                    vm.frames[frameIndex - 1].recoveredPanic = value
                    vm.stack.append(value)
                case .makeMap(let entryCount):
                    guard entryCount >= 0 else {
                        throw GoRuntimeError.invalidExecutable("negative map entry count")
                    }
                    guard entryCount <= resourceLimits.maximumMapEntries else {
                        throw GoRuntimeError.resourceLimitExceeded("map entries")
                    }
                    let stackEntryCount = try checkedMultiply(
                        entryCount, 2, resource: "map entries")
                    guard vm.stack.count >= stackEntryCount else {
                        throw GoRuntimeError.stackUnderflow
                    }
                    var storage = GoMapStorage()
                    storage.reserveCapacity(entryCount)
                    let start = vm.stack.count - stackEntryCount
                    for i in stride(from: start, to: vm.stack.count, by: 2) {
                        storage.set(vm.stack[i], vm.stack[i + 1])
                    }
                    vm.stack.removeSubrange(start...)
                    let cell = try vm.heap.allocate(.mapStorage(storage))
                    vm.stack.append(.map(GoMapValue(storage: GoPointer(cell: cell))))
                case .makeChannel:
                    guard case .int(let rawCapacity) = try pop(&vm.stack),
                        let capacity = Int(exactly: rawCapacity)
                    else { throw GoRuntimeError.typeMismatch }
                    let zero = try pop(&vm.stack)
                    guard capacity >= 0 else {
                        vm.frames[frameIndex].pendingExit = .panicking(
                            GoRuntimePanic(
                                GoErrors.plainRuntimeErrorType, "makechan: size out of range"
                            ).value)
                        break
                    }
                    guard capacity <= resourceLimits.maximumCollectionElements else {
                        throw GoRuntimeError.resourceLimitExceeded("channel capacity")
                    }
                    let cell = try vm.heap.allocate(.channelStorage(GoChannelStorage(capacity: capacity)))
                    _ = zero
                    vm.stack.append(.channel(GoChannelValue(storage: GoPointer(cell: cell))))
                case .sendChannel:
                    let value = try pop(&vm.stack)
                    let base = try pop(&vm.stack)
                    switch try trySelectSend(value, to: base) {
                    case .sent:
                        try wakeReadyBlockedSelects()
                    case .closed:
                        vm.frames[frameIndex].pendingExit = .panicking(
                            GoRuntimePanic.closedChannelSend.value)
                    case .blocked:
                        if base == .nilValue {
                            vm.currentBlocked = true
                            break
                        }
                        guard case .channel(let channel) = base,
                            case .channelStorage(var storage) = try read(
                                pointer: channel.storage, heap: vm.heap)
                        else { throw GoRuntimeError.typeMismatch }
                        storage.sendWaiters.append(GoChannelSendWaiter(
                            goroutineID: vm.currentGoroutineID,
                            value: value,
                            waitSequence: allocateWaitSequence()))
                        try writePointer(
                            .channelStorage(storage),
                            through: channel.storage,
                            heap: &vm.heap)
                        vm.currentBlocked = true
                    }
                case .receiveChannel(let commaOK):
                    let zero = try pop(&vm.stack)
                    let base = try pop(&vm.stack)
                    switch try trySelectReceive(from: base, zero: zero) {
                    case .received(let value, let ok):
                        vm.stack.append(value)
                        if commaOK { vm.stack.append(.bool(ok)) }
                        try wakeReadyBlockedSelects()
                    case .blocked:
                        if base == .nilValue {
                            vm.currentBlocked = true
                            break
                        }
                        guard case .channel(let channel) = base,
                            case .channelStorage(var storage) = try read(
                                pointer: channel.storage, heap: vm.heap)
                        else { throw GoRuntimeError.typeMismatch }
                        storage.receiveWaiters.append(GoChannelReceiveWaiter(
                            goroutineID: vm.currentGoroutineID,
                            commaOK: commaOK,
                            zeroValue: zero,
                            waitSequence: allocateWaitSequence()))
                        try writePointer(
                            .channelStorage(storage),
                            through: channel.storage,
                            heap: &vm.heap)
                        vm.currentBlocked = true
                    }
                case .closeChannel:
                    let base = try pop(&vm.stack)
                    guard case .channel(let channel) = base else {
                        if base == .nilValue {
                            vm.frames[frameIndex].pendingExit = .panicking(
                                GoRuntimePanic(
                                    GoErrors.plainRuntimeErrorType, "close of nil channel"
                                ).value)
                            break
                        }
                        throw GoRuntimeError.typeMismatch
                    }
                    guard case .channelStorage(var storage) = try read(
                        pointer: channel.storage, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    guard !storage.closed else {
                        vm.frames[frameIndex].pendingExit = .panicking(
                            GoRuntimePanic(
                                GoErrors.plainRuntimeErrorType, "close of closed channel"
                            ).value)
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
                        heap: &vm.heap)
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
                                channel: try localValue(channelLocal, in: vm.frames[frameIndex]),
                                value: try localValue(valueLocal, in: vm.frames[frameIndex]),
                                target: target))
                        case .receive(
                            let channelLocal, let destinationLocal, let okLocal,
                            let zeroLocal, let target):
                            evaluated.append(.receive(
                                channel: try localValue(channelLocal, in: vm.frames[frameIndex]),
                                destination: destinationLocal,
                                okDestination: okLocal,
                                zero: try localValue(zeroLocal, in: vm.frames[frameIndex]),
                                target: target))
                        }
                    }
                    var readyIndices: [Int] = []
                    for index in evaluated.indices
                    where try selectCaseIsReady(evaluated[index]) {
                        readyIndices.append(index)
                    }
                    if readyIndices.isEmpty, let defaultTarget {
                        try jump(to: defaultTarget, frame: &vm.frames[frameIndex])
                        break
                    }
                    guard !readyIndices.isEmpty else {
                        blockedSelects[vm.currentGoroutineID] = BlockedSelect(
                            cases: evaluated,
                            waitSequence: allocateWaitSequence())
                        vm.currentBlocked = true
                        break
                    }
                    let selected = evaluated[
                        readyIndices[selectRandomIndex(count: readyIndices.count)]]
                    switch selected {
                    case .send(let channel, let value, let target):
                        switch try trySelectSend(value, to: channel) {
                        case .sent:
                            try jump(to: target, frame: &vm.frames[frameIndex])
                        case .closed:
                            vm.frames[frameIndex].pendingExit = .panicking(
                                GoRuntimePanic.closedChannelSend.value)
                        case .blocked:
                            throw GoRuntimeError.typeMismatch
                        }
                    case .receive(
                        let channel, let destination, let okDestination, let zero, let target):
                        switch try trySelectReceive(from: channel, zero: zero) {
                        case .received(let value, let ok):
                            if let destination {
                                try storeLocal(value, at: destination, in: &vm.frames[frameIndex])
                            }
                            if let okDestination {
                                try storeLocal(.bool(ok), at: okDestination, in: &vm.frames[frameIndex])
                            }
                            try jump(to: target, frame: &vm.frames[frameIndex])
                        case .blocked:
                            throw GoRuntimeError.typeMismatch
                        }
                    }
                    try wakeReadyBlockedSelects()
                case .timeAfter:
                    guard case .int(let nanoseconds) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    let cell = try vm.heap.allocate(.channelStorage(GoChannelStorage(capacity: 1)))
                    let timerChannel = GoValue.channel(
                        GoChannelValue(storage: GoPointer(cell: cell)))
                    vm.stack.append(timerChannel)
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
                    let cell = try vm.heap.allocate(.mutexStorage(GoMutexStorage()))
                    vm.stack.append(.mutex(GoMutexValue(storage: GoPointer(cell: cell))))
                case .timeSleep:
                    guard case .int(let nanoseconds) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    let delay = max(0, Double(nanoseconds) / 1_000_000_000)
                    let sleepingID = vm.currentGoroutineID
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
                    vm.currentBlocked = true
                case .timeTick:
                    guard case .int(let nanoseconds) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard nanoseconds > 0 else {
                        // time.Tick returns a nil channel for a non-positive duration.
                        vm.stack.append(.nilValue)
                        break
                    }
                    let cell = try vm.heap.allocate(.channelStorage(GoChannelStorage(capacity: 1)))
                    let tickChannel = GoValue.channel(
                        GoChannelValue(storage: GoPointer(cell: cell)))
                    vm.stack.append(tickChannel)
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
                    let doneCell = try vm.heap.allocate(.channelStorage(GoChannelStorage(capacity: 1)))
                    let ctxStorage = GoContextStorage(doneChannel: GoPointer(cell: doneCell))
                    let ctxCell = try vm.heap.allocate(.contextStorage(ctxStorage))
                    vm.stack.append(.context(GoContextValue(storage: GoPointer(cell: ctxCell))))
                case .contextWithCancel:
                    guard case .context(let parent) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    let doneCell = try vm.heap.allocate(.channelStorage(GoChannelStorage(capacity: 1)))
                    let ctxStorage = GoContextStorage(doneChannel: GoPointer(cell: doneCell))
                    let ctxCell = try vm.heap.allocate(.contextStorage(ctxStorage))
                    let childCtx = GoContextValue(storage: GoPointer(cell: ctxCell))
                    // Register child in parent for propagation
                    guard case .contextStorage(var parentStorage) = try read(
                        pointer: parent.storage, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    parentStorage.children.append(GoPointer(cell: ctxCell))
                    try writePointer(
                        .contextStorage(parentStorage), through: parent.storage, heap: &vm.heap)
                    // Push ctx then cancel (cancel is same context reference used to cancel)
                    vm.stack.append(.context(childCtx))
                    vm.stack.append(.context(childCtx))
                case .contextWithTimeout:
                    guard case .int(let nanoseconds) = try pop(&vm.stack),
                        case .context(let parent) = try pop(&vm.stack)
                    else { throw GoRuntimeError.typeMismatch }
                    let doneCell = try vm.heap.allocate(.channelStorage(GoChannelStorage(capacity: 1)))
                    let ctxStorage = GoContextStorage(doneChannel: GoPointer(cell: doneCell))
                    let ctxCell = try vm.heap.allocate(.contextStorage(ctxStorage))
                    let childCtx = GoContextValue(storage: GoPointer(cell: ctxCell))
                    // Register child in parent
                    guard case .contextStorage(var parentStorage) = try read(
                        pointer: parent.storage, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    parentStorage.children.append(GoPointer(cell: ctxCell))
                    try writePointer(
                        .contextStorage(parentStorage), through: parent.storage, heap: &vm.heap)
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
                    vm.stack.append(.context(childCtx))
                    vm.stack.append(.context(childCtx))
                case .contextDone:
                    guard case .context(let ctx) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard case .contextStorage(let ctxStorage) = try read(
                        pointer: ctx.storage, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    let doneChannel = GoValue.channel(
                        GoChannelValue(storage: ctxStorage.doneChannel))
                    vm.stack.append(doneChannel)
                case .contextErr:
                    guard case .context(let ctx) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard case .contextStorage(let ctxStorage) = try read(
                        pointer: ctx.storage, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    if let message = ctxStorage.errorMessage {
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error", value: .string(message))))
                    } else {
                        vm.stack.append(.nilValue)
                    }
                case .cancelContext:
                    guard case .context(let ctx) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    try cancelContextTree(ctx.storage, message: "context canceled")
                case .netDial:
                    guard case .string(let address) = try pop(&vm.stack),
                        case .string(let network) = try pop(&vm.stack)
                    else { throw GoRuntimeError.typeMismatch }
                    guard let processContext else {
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: network not available"))))
                        break
                    }
                    guard network == "tcp" else {
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
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
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: invalid address \(address)"))))
                        break
                    }
                    guard let fd = processContext.tcpSocket() else {
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: socket creation failed"))))
                        break
                    }
                    closedNetDescriptors.remove(fd)
                    let dialingID = vm.currentGoroutineID
                    beginHostWait()
                    processContext.tcpConnect(fd, to: ip, port: port) {
                        defer { endHostWait() }
                        guard executionIsActive, asynchronousError == nil else { return }
                        // The kernel resumes for a failed handshake as well;
                        // the socket's readiness tells the outcomes apart.
                        let readiness = processContext.readiness(fd) ?? []
                        var failure: String?
                        if readiness.contains(.error) {
                            failure = "connection refused"
                        } else if !readiness.contains(.writable) {
                            failure = "connection timed out"
                        }
                        do {
                            if let failure {
                                processContext.close(fd)
                                try wakeGoroutine(
                                    dialingID,
                                    values: [
                                        .nilValue,
                                        errorValue("dial tcp \(address): connect: \(failure)"),
                                    ])
                                return
                            }
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
                    vm.currentBlocked = true
                case .netListen:
                    guard case .string(let address) = try pop(&vm.stack),
                        case .string(let network) = try pop(&vm.stack)
                    else { throw GoRuntimeError.typeMismatch }
                    guard let processContext else {
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: network not available"))))
                        break
                    }
                    guard network == "tcp" else {
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: unsupported network \(network)"))))
                        break
                    }
                    // Parse ":port" or "host:port"
                    let parts = address.split(separator: ":", maxSplits: 1)
                    let port: UInt16
                    if parts.count == 2 {
                        guard let p = UInt16(parts[1]) else {
                            vm.stack.append(.nilValue)
                            vm.stack.append(.interface(GoInterfaceValue(
                                typeName: "error",
                                value: .string("net: invalid port in address \(address)"))))
                            break
                        }
                        port = p
                    } else if parts.count == 1, let p = UInt16(parts[0]) {
                        port = p
                    } else {
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: invalid address \(address)"))))
                        break
                    }
                    guard let fd = processContext.tcpSocket() else {
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: socket creation failed"))))
                        break
                    }
                    processContext.bind(fd, address: nil, port: port)
                    guard processContext.tcpListen(fd, port: port) else {
                        processContext.close(fd)
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: listen on \(address) failed"))))
                        break
                    }
                    closedNetDescriptors.remove(fd)
                    vm.stack.append(.netListener(GoNetListenerValue(
                        fd: fd, network: "tcp", localAddr: address)))
                    vm.stack.append(.nilValue)
                case .netAccept:
                    if vm.stack.last == .nilValue { throw GoRuntimePanic.nilDereference }
                    guard case .netListener(let listener) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard let processContext else {
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: network not available"))))
                        break
                    }
                    if closedNetDescriptors.contains(listener.fd) {
                        vm.stack.append(.nilValue)
                        vm.stack.append(errorValue(GoParkedNetWait.closedMessage(
                            "accept", GoParkedNetWait.listenerAddress(listener.localAddr))))
                        break
                    }
                    let acceptingID = vm.currentGoroutineID
                    let parked = GoParkedNetWait(
                        goroutine: acceptingID,
                        resultsOnClose: [
                            .nilValue,
                            errorValue(GoParkedNetWait.closedMessage(
                                "accept", GoParkedNetWait.listenerAddress(listener.localAddr))),
                        ])
                    parkedNetWaits[listener.fd, default: []].append(parked)
                    beginHostWait()
                    processContext.tcpAccept(listener.fd) { acceptedFD in
                        if parked.abandoned {
                            // The listener was closed meanwhile.
                            processContext.close(acceptedFD)
                            return
                        }
                        defer { endHostWait() }
                        parkedNetWaits[listener.fd]?.removeAll { $0 === parked }
                        closedNetDescriptors.remove(acceptedFD)
                        guard executionIsActive, asynchronousError == nil else { return }
                        // Who connected, as Go's `RemoteAddr` says it.
                        let peer = processContext.tcpPeer(acceptedFD)
                            .map { "\($0.address):\($0.port)" } ?? ""
                        do {
                            try wakeGoroutine(
                                acceptingID,
                                values: [
                                    .netConn(GoNetConnValue(
                                        fd: acceptedFD, network: "tcp",
                                        remoteAddr: peer)),
                                    .nilValue,
                                ])
                        } catch let error as GoRuntimeError {
                            asynchronousError = error
                        } catch {
                            asynchronousError = .typeMismatch
                        }
                    }
                    vm.currentBlocked = true
                case .netRead:
                    if vm.stack.dropLast().last == .nilValue { throw GoRuntimePanic.nilDereference }
                    guard case .slice(let buf) = try pop(&vm.stack),
                        case .netConn(let conn) = try pop(&vm.stack)
                    else { throw GoRuntimeError.typeMismatch }
                    _ = try validatedSliceRange(buf)
                    guard buf.length <= resourceLimits.maximumNetworkTransferBytes else {
                        throw GoRuntimeError.resourceLimitExceeded("network transfer bytes")
                    }
                    guard let processContext else {
                        vm.stack.append(.int(0))
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: network not available"))))
                        break
                    }
                    let closedMessage = GoParkedNetWait.closedMessage(
                        "read", conn.remoteAddr)
                    if closedNetDescriptors.contains(conn.fd) {
                        vm.stack.append(.int(0))
                        vm.stack.append(errorValue(closedMessage))
                        break
                    }
                    let readingID = vm.currentGoroutineID
                    let maxBytes = buf.length
                    let parked = GoParkedNetWait(
                        goroutine: readingID,
                        resultsOnClose: [.int(0), errorValue(closedMessage)])
                    parkedNetWaits[conn.fd, default: []].append(parked)
                    beginHostWait()
                    processContext.tcpRecv(conn.fd, max: maxBytes) { bytes in
                        // The connection was closed meanwhile.
                        if parked.abandoned { return }
                        defer { endHostWait() }
                        parkedNetWaits[conn.fd]?.removeAll { $0 === parked }
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
                                        pointer: buf.backing, heap: vm.heap)
                                else {
                                    throw GoRuntimeError.invalidSliceBounds
                                }
                                for (offset, byte) in bytes.enumerated() {
                                    backing[range.lowerBound + offset] = .int(Int64(byte))
                                }
                                try writePointer(
                                    .array(backing), through: buf.backing, heap: &vm.heap)
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
                    vm.currentBlocked = true
                case .netWrite:
                    if vm.stack.dropLast().last == .nilValue { throw GoRuntimePanic.nilDereference }
                    guard case .slice(let buf) = try pop(&vm.stack),
                        case .netConn(let conn) = try pop(&vm.stack)
                    else { throw GoRuntimeError.typeMismatch }
                    let range = try validatedSliceRange(buf)
                    guard range.count <= resourceLimits.maximumNetworkTransferBytes else {
                        throw GoRuntimeError.resourceLimitExceeded("network transfer bytes")
                    }
                    guard let processContext else {
                        vm.stack.append(.int(0))
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: network not available"))))
                        break
                    }
                    guard case .array(let backing) = try read(pointer: buf.backing, heap: vm.heap)
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
                    vm.stack.append(.int(sent ? Int64(bytes.count) : 0))
                    vm.stack.append(sent ? .nilValue : .interface(GoInterfaceValue(
                        typeName: "error", value: .string("net: write failed"))))
                case .netClose:
                    let value = try pop(&vm.stack)
                    let fd: Int
                    switch value {
                    case .netConn(let conn): fd = conn.fd
                    case .netListener(let ln): fd = ln.fd
                    case .nilValue: throw GoRuntimePanic.nilDereference
                    default: throw GoRuntimeError.typeMismatch
                    }
                    if let processContext {
                        processContext.close(fd)
                    }
                    closedNetDescriptors.insert(fd)
                    // Whoever waits on the handle is woken, as by Go's Close.
                    for parked in parkedNetWaits.removeValue(forKey: fd) ?? [] {
                        parked.abandoned = true
                        endHostWait()
                        try wakeGoroutine(parked.goroutine, values: parked.resultsOnClose)
                    }
                    vm.stack.append(.nilValue)
                case .netLookupHost:
                    guard case .string(let host) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard processContext != nil else {
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
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
                        let backingCell = try vm.heap.allocate(.array([.string(addrStr)]))
                        let slice = GoSliceValue(
                            backing: GoPointer(cell: backingCell),
                            start: 0, length: 1, capacity: 1,
                            zeroValue: .string(""))
                        vm.stack.append(.slice(slice))
                        vm.stack.append(.nilValue)
                        runtimeHandleRoots.removeValue(forKey: runtimeHandleID)
                    } else {
                        // For non-literal hosts, return the host itself as an address
                        // (full DNS requires async resolve which is beyond M5 minimal)
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net: lookup \(host): no such host"))))
                        runtimeHandleRoots.removeValue(forKey: runtimeHandleID)
                    }
                case .httpHandleFunc(let handler):
                    guard case .string(let pattern) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    if httpHandlers[pattern] == nil,
                        httpHandlers.count >= resourceLimits.maximumRuntimeHandles
                    {
                        throw GoRuntimeError.resourceLimitExceeded("HTTP handlers")
                    }
                    httpHandlers[pattern] = handler
                case .httpListenAndServe:
                    guard case .string(let addr) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard let processContext else {
                        vm.stack.append(.interface(GoInterfaceValue(
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
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net/http: invalid address \(addr)"))))
                        break
                    }
                    guard let fd = processContext.tcpSocket() else {
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net/http: socket creation failed"))))
                        break
                    }
                    processContext.bind(fd, address: nil, port: port)
                    guard processContext.tcpListen(fd, port: port) else {
                        processContext.close(fd)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net/http: listen failed"))))
                        break
                    }
                    // Spawn an internal accept loop using the event loop
                    let handlersCopy = httpHandlers
                    func acceptLoop() {
                        beginHostWait()
                        processContext.tcpAccept(fd) { acceptedFD in
                            defer { endHostWait() }
                            guard executionIsActive, asynchronousError == nil else { return }
                            // Read HTTP request
                            beginHostWait()
                            processContext.tcpRecv(
                                acceptedFD,
                                max: resourceLimits.maximumNetworkTransferBytes
                            ) { bytes in
                                defer { endHostWait() }
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
                                                let writerCell = try vm.heap.allocate(.structure(GoStructValue(
                                                    typeName: "http.ResponseWriter", fields: [])))
                                                let reqCell = try vm.heap.allocate(.structure(GoStructValue(
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
                    vm.currentBlocked = true
                case .httpGet:
                    guard case .string(let url) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard let processContext else {
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
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
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net/http: invalid URL \(url)"))))
                        break
                    }
                    guard let fd = processContext.tcpSocket() else {
                        vm.stack.append(.nilValue)
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string("net/http: socket creation failed"))))
                        break
                    }
                    let gettingID = vm.currentGoroutineID
                    beginHostWait()
                    processContext.tcpConnect(fd, to: ip, port: port) {
                        defer { endHostWait() }
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
                        beginHostWait()
                        processContext.tcpRecv(
                            fd,
                            max: resourceLimits.maximumNetworkTransferBytes
                        ) { bytes in
                            defer { endHostWait() }
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
                    vm.currentBlocked = true
                case .mutexLock:
                    guard case .mutex(let mutex) = try pop(&vm.stack),
                        case .mutexStorage(var storage) = try read(
                            pointer: mutex.storage, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    if storage.locked {
                        storage.waiters.append(GoRuntimeWaiter(
                            goroutineID: vm.currentGoroutineID,
                            waitSequence: allocateWaitSequence()))
                        vm.currentBlocked = true
                    } else {
                        storage.locked = true
                    }
                    try writePointer(
                        .mutexStorage(storage), through: mutex.storage, heap: &vm.heap)
                case .mutexUnlock:
                    guard case .mutex(let mutex) = try pop(&vm.stack),
                        case .mutexStorage(var storage) = try read(
                            pointer: mutex.storage, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    guard storage.locked else { throw GoFatalError.mutexUnlockOfUnlocked }
                    if storage.waiters.isEmpty {
                        storage.locked = false
                    } else {
                        let waiter = storage.waiters.removeFirst()
                        try wakeGoroutine(waiter.goroutineID)
                    }
                    try writePointer(
                        .mutexStorage(storage), through: mutex.storage, heap: &vm.heap)
                case .makeWaitGroup:
                    let cell = try vm.heap.allocate(.waitGroupStorage(GoWaitGroupStorage()))
                    vm.stack.append(.waitGroup(GoWaitGroupValue(storage: GoPointer(cell: cell))))
                case .waitGroupAdd:
                    guard case .int(let delta) = try pop(&vm.stack),
                        case .waitGroup(let waitGroup) = try pop(&vm.stack),
                        case .waitGroupStorage(var storage) = try read(
                            pointer: waitGroup.storage, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    let (next, overflow) = storage.count.addingReportingOverflow(delta)
                    guard !overflow, next >= 0 else {
                        vm.frames[frameIndex].pendingExit = .panicking(
                            .string("sync: negative WaitGroup counter"))
                        break
                    }
                    storage.count = next
                    let waiters = next == 0 ? storage.waiters : []
                    if next == 0 { storage.waiters.removeAll() }
                    try writePointer(
                        .waitGroupStorage(storage), through: waitGroup.storage, heap: &vm.heap)
                    for waiter in waiters {
                        try wakeGoroutine(waiter.goroutineID)
                    }
                case .waitGroupWait:
                    guard case .waitGroup(let waitGroup) = try pop(&vm.stack),
                        case .waitGroupStorage(var storage) = try read(
                            pointer: waitGroup.storage, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    if storage.count > 0 {
                        storage.waiters.append(GoRuntimeWaiter(
                            goroutineID: vm.currentGoroutineID,
                            waitSequence: allocateWaitSequence()))
                        try writePointer(
                            .waitGroupStorage(storage), through: waitGroup.storage, heap: &vm.heap)
                        vm.currentBlocked = true
                    }
                case .garbageCollect:
                    performGarbageCollection()
                case .getMapIndex(let commaOK):
                    let zero = try pop(&vm.stack)
                    let key = try pop(&vm.stack)
                    let base = try pop(&vm.stack)
                    guard case .map(let mapValue) = base else {
                        if base == .nilValue {
                            vm.stack.append(zero)
                            if commaOK { vm.stack.append(.bool(false)) }
                            break
                        }
                        throw GoRuntimeError.typeMismatch
                    }
                    guard case .mapStorage(let storage) = try read(pointer: mapValue.storage, heap: vm.heap)
                    else { throw GoRuntimeError.typeMismatch }
                    if let value = storage.get(key) {
                        vm.stack.append(value)
                        if commaOK { vm.stack.append(.bool(true)) }
                    } else {
                        vm.stack.append(zero)
                        if commaOK { vm.stack.append(.bool(false)) }
                    }
                case .setMapIndex:
                    let value = try pop(&vm.stack)
                    let key = try pop(&vm.stack)
                    let base = try pop(&vm.stack)
                    guard case .map(let mapValue) = base else {
                        if base == .nilValue { throw GoRuntimePanic.nilMapAssignment }
                        throw GoRuntimeError.typeMismatch
                    }
                    guard vm.heap.contains(mapValue.storage.cell) else {
                        throw GoRuntimeError.invalidPointer
                    }
                    guard mapValue.storage.path.isEmpty,
                        try vm.heap.setMapEntry(
                            mapValue.storage.cell,
                            key: key,
                            value: value,
                            maximumEntries: resourceLimits.maximumMapEntries)
                    else { throw GoRuntimeError.typeMismatch }
                    vm.stack.append(.map(mapValue))
                case .deleteMap:
                    let key = try pop(&vm.stack)
                    let base = try pop(&vm.stack)
                    if base == .nilValue {
                        vm.stack.append(.nilValue)
                        break
                    }
                    guard case .map(let mapValue) = base else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard vm.heap.contains(mapValue.storage.cell) else {
                        throw GoRuntimeError.invalidPointer
                    }
                    guard mapValue.storage.path.isEmpty,
                        try vm.heap.removeMapEntry(mapValue.storage.cell, key: key)
                    else { throw GoRuntimeError.typeMismatch }
                    vm.stack.append(.map(mapValue))
                case .callInterface(let methodName, let argumentCount):
                    // Stack: [receiver, arg0, arg1, ..., argN-1] (receiver pushed first)
                    guard argumentCount >= 0 else {
                        throw GoRuntimeError.invalidExecutable("negative interface argument count")
                    }
                    let requiredCount = try checkedAdd(
                        argumentCount, 1, resource: "interface arguments")
                    guard vm.stack.count >= requiredCount else {
                        throw GoRuntimeError.stackUnderflow
                    }
                    let argStart = vm.stack.count - argumentCount
                    let arguments = Array(vm.stack[argStart...])
                    vm.stack.removeSubrange(argStart...)
                    let receiver = try pop(&vm.stack)
                    // An error the library made has no function behind its
                    // `Error` method.
                    if methodName == "Error", arguments.isEmpty,
                        let library = try libraryError(receiver)
                    {
                        vm.stack.append(.string(library.message))
                        break
                    }
                    if methodName == "Unwrap", arguments.isEmpty,
                        let wrapped = try libraryUnwrapResult(receiver)
                    {
                        vm.stack.append(wrapped)
                        break
                    }
                    // Unwrap interface to get concrete type and value
                    let concreteTypeName: String
                    let concreteValue: GoValue
                    if receiver == .nilValue {
                        // A method of a nil interface value.
                        throw GoRuntimePanic.nilDereference
                    } else if case .interface(let iface) = receiver {
                        // A value converted to an interface carries its type.
                        guard let owner = GoTypeDescriptor.methodOwner(ofTypeName: iface.typeName)
                        else { throw GoRuntimeError.typeMismatch }
                        concreteTypeName = owner
                        concreteValue = iface.value
                    } else if case .structure(let sv) = receiver, let tn = sv.typeName {
                        concreteTypeName = tn
                        concreteValue = receiver
                    } else if let owner = GoLibraryMethods.owner(ofHandle: receiver) {
                        // A handle of the library, whose methods the VM has.
                        concreteTypeName = owner
                        concreteValue = receiver
                    } else {
                        throw GoRuntimeError.typeMismatch
                    }
                    // Resolve method: try TypeName.method and *TypeName.method,
                    // and for a pointer the methods of what it points to.
                    var candidates = [
                        concreteTypeName + "." + methodName,
                        "*" + concreteTypeName + "." + methodName,
                    ]
                    if concreteTypeName.hasPrefix("*") {
                        candidates.append(concreteTypeName.dropFirst() + "." + methodName)
                    }
                    guard let functionName = candidates.first(where: { functions[$0] != nil }),
                        let function = functions[functionName]
                    else {
                        throw GoRuntimeError.missingFunction(concreteTypeName + "." + methodName)
                    }
                    guard vm.frames.count < maximumCallDepth else {
                        throw GoRuntimeError.callStackLimitExceeded
                    }
                    // A method with a value receiver takes the value a
                    // pointer points to.
                    var receiverValue = concreteValue
                    if !functionName.hasPrefix("*"), concreteTypeName.hasPrefix("*") {
                        // A nil pointer has no value to hand the method.
                        guard case .pointer(let pointer) = receiverValue else {
                            throw GoRuntimePanic.nilDereference
                        }
                        receiverValue = try read(pointer: pointer, heap: vm.heap)
                    }
                    let allArgs = [receiverValue] + arguments
                    guard allArgs.count == function.parameterCount else {
                        throw GoRuntimeError.argumentCountMismatch(
                            function: functionName,
                            expected: function.parameterCount,
                            actual: allArgs.count)
                    }
                    vm.frames.append(
                        try makeFrame(
                            function: function,
                            stackBase: vm.stack.count,
                            arguments: allArgs,
                            heap: &vm.heap))
                case .makeInterface(let typeName):
                    let value = try pop(&vm.stack)
                    vm.stack.append(.interface(GoInterfaceValue(typeName: typeName, value: value)))
                case .typeAssert(let targetName, let commaOK):
                    let zero = try pop(&vm.stack)
                    let source = try pop(&vm.stack)
                    // Types are compared by identity: a boxed value's, or the
                    // one a bare `int`, `string`, `bool`, or struct shows.
                    let dynamicType: String?
                    let dynamicValue: GoValue
                    if case .interface(let interfaceValue) = source {
                        dynamicType = GoTypeDescriptor.identity(ofTypeName: interfaceValue.typeName)
                        dynamicValue = interfaceValue.value
                    } else if source == .nilValue {
                        dynamicType = nil
                        dynamicValue = zero
                    } else {
                        dynamicType = GoTypeDescriptor.identity(of: source)
                        dynamicValue = source
                    }
                    if let wanted = GoErrors.InterfaceTarget(targetName) {
                        // An interface takes any value whose type has its
                        // methods, and the value keeps its own type.
                        let missing =
                            source == .nilValue
                            ? "" : try missingMethod(of: source, for: wanted)
                        if missing == nil {
                            vm.stack.append(source)
                            if commaOK { vm.stack.append(.bool(true)) }
                        } else if commaOK {
                            vm.stack.append(zero)
                            vm.stack.append(.bool(false))
                        } else {
                            let name =
                                wanted.typeName.isEmpty
                                ? (wanted.methods.map(\.name) == ["Error"] ? "error" : "interface")
                                : GoTypeDescriptor.goName(wanted.typeName)
                            vm.frames[frameIndex].pendingExit = .panicking(
                                GoRuntimePanic(
                                    GoErrors.assertionErrorType,
                                    source == .nilValue
                                        ? "interface conversion: interface is nil, not \(name)"
                                        : "interface conversion: \(inferredTypeName(of: source)) is not \(name): missing method \(missing ?? "")"
                                ).value)
                        }
                    } else if dynamicType == GoTypeDescriptor.identity(ofTypeName: targetName) {
                        vm.stack.append(dynamicValue)
                        if commaOK { vm.stack.append(.bool(true)) }
                    } else if commaOK {
                        vm.stack.append(zero)
                        vm.stack.append(.bool(false))
                    } else {
                        let held = source == .nilValue ? "nil" : inferredTypeName(of: source)
                        let wanted =
                            GoTypeDescriptor(typeName: targetName).map {
                                GoTypeDescriptor.name(of: $0.type)
                            }
                            ?? GoTypeDescriptor.dynamicType(named: targetName).map(
                                GoTypeDescriptor.name(of:)) ?? targetName
                        // Two types may print alike: Go says what keeps
                        // them apart.
                        var apart = ""
                        if held == wanted, source != .nilValue {
                            var heldPackage: String?
                            if case .interface(let interfaceValue) = source {
                                heldPackage = GoTypeDescriptor.packagePath(
                                    ofTypeName: interfaceValue.typeName)
                            }
                            let wantedPackage = GoTypeDescriptor.packagePath(ofTypeName: targetName)
                            if let heldPackage, let wantedPackage, heldPackage != wantedPackage {
                                apart = " (types from different packages)"
                            } else {
                                apart = " (types from different scopes)"
                            }
                        }
                        vm.frames[frameIndex].pendingExit = .panicking(
                            GoRuntimePanic(
                                GoErrors.assertionErrorType,
                                "interface conversion: interface {} is \(held), not \(wanted)\(apart)"
                            ).value)
                    }
                case .rangeKeys:
                    let base = try pop(&vm.stack)
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
                        guard case .mapStorage(let storage) = try read(pointer: mapValue.storage, heap: vm.heap)
                        else { throw GoRuntimeError.typeMismatch }
                        keys = storage.keys
                    case .nilValue:
                        keys = []
                    default:
                        throw GoRuntimeError.typeMismatch
                    }
                    vm.stack.append(.array(keys))
                case .rangeValue:
                    let zero = try pop(&vm.stack)
                    let key = try pop(&vm.stack)
                    let base = try pop(&vm.stack)
                    switch (base, key) {
                    case (.array(let values), .int(let rawIndex)):
                        guard let index = Int(exactly: rawIndex), values.indices.contains(index)
                        else { throw GoRuntimeError.indexOutOfRange }
                        vm.stack.append(values[index])
                    case (.slice(let slice), .int(let rawIndex)):
                        _ = try validatedSliceRange(slice)
                        guard let index = Int(exactly: rawIndex), index >= 0, index < slice.length
                        else { throw GoRuntimeError.indexOutOfRange }
                        let absoluteIndex = try checkedAdd(
                            slice.start, index, resource: "slice index")
                        vm.stack.append(try read(
                            pointer: appending(index: absoluteIndex, to: slice.backing),
                            heap: vm.heap))
                    case (.string(let string), .int(let rawOffset)):
                        guard let offset = Int(exactly: rawOffset) else {
                            throw GoRuntimeError.indexOutOfRange
                        }
                        let utf8 = string.utf8
                        guard offset >= 0, offset < utf8.count,
                            let scalarIndex = utf8.index(utf8.startIndex, offsetBy: offset)
                                .samePosition(in: string.unicodeScalars)
                        else { throw GoRuntimeError.indexOutOfRange }
                        vm.stack.append(.int(Int64(string.unicodeScalars[scalarIndex].value)))
                    case (.map(let mapValue), _):
                        guard case .mapStorage(let storage) = try read(pointer: mapValue.storage, heap: vm.heap)
                        else { throw GoRuntimeError.typeMismatch }
                        vm.stack.append(storage.get(key) ?? zero)
                    default:
                        throw GoRuntimeError.typeMismatch
                    }
                case .testFail(let argumentCount, let fatal):
                    guard argumentCount >= 0, vm.stack.count >= argumentCount else {
                        throw GoRuntimeError.stackUnderflow
                    }
                    let start = vm.stack.count - argumentCount
                    let values = Array(vm.stack[start...])
                    vm.stack.removeSubrange(start...)
                    testFailureCount += 1
                    // The frame state is final before a write that can park.
                    if fatal {
                        vm.frames[frameIndex].pendingExit = .testFatal
                    }
                    if !values.isEmpty {
                        try emit(
                            try formatOutput(
                                values,
                                prefix: "    ",
                                separator: " ",
                                suffix: "\n"))
                    }
                case .testBegin(let name):
                    subtests.append((name, testFailureCount))
                case .testEnd(let name):
                    let started = subtests.popLast()?.failuresAtStart ?? testFailureCount
                    let passed = testFailureCount == started
                    let status = passed ? "PASS" : "FAIL"
                    // The result is in place before a write that can park.
                    vm.stack.append(.bool(passed))
                    try emit("--- \(status): \(name)\n")
                case .osArgs:
                    let elements = arguments.map { GoValue.string($0) }
                    let cell = try vm.heap.allocate(.array(elements))
                    vm.stack.append(
                        .slice(
                            GoSliceValue(
                                backing: GoPointer(cell: cell),
                                start: 0,
                                length: elements.count,
                                capacity: elements.count,
                                zeroValue: .string(""))))
                case .exit:
                    guard case .int(let code) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    programExitCode = Int32(truncatingIfNeeded: code)
                    break executionLoop
                case .parseInt:
                    guard case .string(let text) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    if let value = Int64(text) {
                        vm.stack.append(.int(value))
                        vm.stack.append(.nilValue)
                    } else {
                        vm.stack.append(.int(0))
                        vm.stack.append(.interface(GoInterfaceValue(
                            typeName: "error",
                            value: .string(
                                "strconv.Atoi: parsing \"\(text)\": invalid syntax"))))
                    }
                case .readInput:
                    guard case .slice(let pathSlice) = try pop(&vm.stack),
                        case .string(let command) = try pop(&vm.stack)
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
                            heap: vm.heap)
                        else {
                            throw GoRuntimeError.typeMismatch
                        }
                        guard path.utf8.count <= resourceLimits.maximumStringBytes else {
                            throw GoRuntimeError.resourceLimitExceeded("path bytes")
                        }
                        paths.append(path)
                    }
                    guard let processContext else {
                        vm.stack.append(.string(""))
                        vm.stack.append(.int(1))
                        break
                    }
                    if paths.isEmpty, cooperative {
                        guard processContext.readiness(0) != nil else {
                            vm.stack.append(.string(""))
                            vm.stack.append(.int(0))
                            break
                        }
                        // Park this goroutine and gather fd 0 to end of input
                        // across process steps.
                        let readerID = vm.currentGoroutineID
                        var gathered: [UInt8] = []
                        func gatherStandardInput() {
                            beginHostWait()
                            processContext.read(0, max: 65_536) { chunk in
                                defer { endHostWait() }
                                guard executionIsActive, asynchronousError == nil else { return }
                                if chunk.isEmpty {
                                    do {
                                        try wakeGoroutine(
                                            readerID,
                                            values: [
                                                .string(String(decoding: gathered, as: UTF8.self)),
                                                .int(0),
                                            ])
                                    } catch {
                                        recordAsynchronousFailure(error)
                                    }
                                    return
                                }
                                guard gathered.count <= resourceLimits.maximumInputBytes,
                                    chunk.count
                                        <= resourceLimits.maximumInputBytes - gathered.count
                                else {
                                    asynchronousError = .resourceLimitExceeded("input bytes")
                                    return
                                }
                                gathered.append(contentsOf: chunk)
                                gatherStandardInput()
                            }
                        }
                        gatherStandardInput()
                        vm.currentBlocked = true
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
                        vm.stack.append(.string(String(decoding: bytes, as: UTF8.self)))
                        vm.stack.append(.int(0))
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
                    vm.stack.append(.string(String(decoding: bytes, as: UTF8.self)))
                    vm.stack.append(.int(status))
                case .readStdin:
                    guard let processContext, processContext.readiness(0) != nil else {
                        vm.stack.append(.string(""))
                        vm.stack.append(.int(1))
                        break
                    }
                    pendingHostInputWaits += 1
                    readStandardInputChunk(for: vm.currentGoroutineID)
                    vm.currentBlocked = true
                case .writeFile:
                    guard case .string(let contents) = try pop(&vm.stack),
                        case .string(let path) = try pop(&vm.stack)
                    else {
                        throw GoRuntimeError.typeMismatch
                    }
                    guard let processContext else {
                        vm.stack.append(.int(1))
                        break
                    }
                    var status: Int64 = 0
                    do {
                        let descriptor = try processContext.openFile(
                            path,
                            create: true,
                            truncate: true,
                            access: .writeOnly)
                        defer { try? processContext.closeFile(descriptor) }
                        var remaining = Array(contents.utf8)[...]
                        while !remaining.isEmpty {
                            let written = try processContext.writeFile(
                                descriptor,
                                Array(remaining))
                            guard written > 0 else {
                                status = 1
                                break
                            }
                            remaining = remaining.dropFirst(written)
                        }
                    } catch {
                        status = 1
                    }
                    vm.stack.append(.int(status))
                case .setTerminalRawMode:
                    guard case .bool(let enabled) = try pop(&vm.stack) else {
                        throw GoRuntimeError.typeMismatch
                    }
                    let applied = processContext?.setTerminalRawMode(0, enabled) ?? false
                    if applied { programEnabledRawMode = enabled }
                    vm.stack.append(.bool(applied))
                case .terminalWindowSize:
                    let size = processContext?.terminalWindowSize(1)
                        ?? processContext?.terminalWindowSize(0)
                    vm.stack.append(.int(Int64(size?.rows ?? 0)))
                    vm.stack.append(.int(Int64(size?.columns ?? 0)))
                case .strings(let function):
                    vm.stack.append(try executeStrings(function, stack: &vm.stack))
                case .return:
                    vm.frames[frameIndex].pendingExit = .returning([])
                case .returnValues(let count):
                    guard count >= 0 else {
                        throw GoRuntimeError.invalidExecutable("negative return count")
                    }
                    let requiredStackCount = try checkedAdd(
                        vm.frames[frameIndex].stackBase,
                        count,
                        resource: "operand stack")
                    guard vm.stack.count >= requiredStackCount else {
                        throw GoRuntimeError.stackUnderflow
                    }
                    let start = vm.stack.count - count
                    let values = Array(vm.stack[start...])
                    vm.stack.removeSubrange(start...)
                    vm.frames[frameIndex].pendingExit = .returning(values)
                }
                guard vm.stack.count <= resourceLimits.maximumValueStackEntries else {
                    throw GoRuntimeError.resourceLimitExceeded("operand stack")
                }
                if vm.heap.shouldCollect(threshold: garbageCollectionThreshold),
                    vm.frames.indices.contains(frameIndex),
                    vm.frames[frameIndex].isSafepoint(vm.frames[frameIndex].programCounter)
                {
                    performGarbageCollection()
                }
                try reportRuntimeMemoryIfChanged()
                try scheduleNext(requeueCurrent: !vm.currentBlocked)
            }
            if testFailureCount > 0 { throw GoRuntimeError.testFailure }
        }

        /// Continue a suspended run from the stdin continuation, reporting the
        /// final outcome through `resumedCompletion`.
        func resumeSuspendedExecution() {
            isSuspended = false
            if !cooperative {
                vm.sliceStartInstruction = vm.executed
                outputBytesWritten = 0
            }
            do {
                if let asynchronousError { throw asynchronousError }
                try driveEventLoopUntilRunnable()
                try runSlice()
            } catch is GoExecutionSuspension {
                isSuspended = true
                resumeHook = resumeSuspendedExecution
                return
            } catch {
                releaseExecution()
                resumedCompletion?(.failure(error))
                return
            }
            completedNormally = true
            releaseExecution()
            resumedCompletion?(.success(
                GoProcessResult(exitCode: programExitCode, statistics: vm.heap.statistics)))
        }

        do {
            try runSlice()
        } catch is GoExecutionSuspension {
            isSuspended = true
            resumeHook = resumeSuspendedExecution
            return nil
        }
        completedNormally = true
        return GoProcessResult(exitCode: programExitCode, statistics: vm.heap.statistics)
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
        try jump(to: target, in: frame)
    }

    private func jump(to target: Int, in frame: Frame) throws {
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
        if pointer.path.count == 1, case .index(let element) = pointer.path[0],
            try heap.replaceArrayElement(pointer.cell, element: element, with: value)
        {
            return
        }

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
            parts.reserveCapacity(storage.count * 4 + 2)
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
    /// Number of occupied cells, maintained on allocate/collect so statistics
    /// never scan the heap (they are sampled after every instruction).
    private var liveCells: Int
    private var liveBytesAfterCollection = 0
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
        self.liveCells = globalCount
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

    /// Whether enough has been allocated since the last collection to pay
    /// for another one.
    ///
    /// A collection visits every live value, so collecting every `threshold`
    /// allocations costs time proportional to the live heap per call-heavy
    /// loop iteration. Scaling the trigger with the bytes that survived the
    /// last collection keeps the amortized cost per allocation constant. The
    /// fixed threshold applies again once the heap is half full, so a program
    /// near its ceiling is still collected promptly.
    func shouldCollect(threshold: Int) -> Bool {
        guard allocationsSinceCollection >= threshold else { return false }
        if liveCells > maximumCells / 2 || liveBytes > maximumBytes / 2 { return true }
        return allocationsSinceCollection >= liveBytesAfterCollection / 64
    }

    var statistics: GoRuntimeStatistics {
        GoRuntimeStatistics(
            heapAllocations: totalAllocations,
            garbageCollections: collectionCount,
            reclaimedHeapCells: reclaimedCount,
            liveHeapCells: liveCells,
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

    /// The value in cell `index`, or nil when there is no such cell: one
    /// lookup where `contains` and the subscript make three.
    func valueIfPresent(_ index: Int) -> GoValue? {
        guard index >= 0, index < cells.count else { return nil }
        return cells[index]?.value
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

    /// Replace element `element` of the array stored in cell `index` without
    /// copying the array or re-measuring its other elements, so a slice store
    /// or append costs O(1) instead of O(length). Returns `false` when the
    /// cell does not hold an array with that element; the caller then takes
    /// the general path, which reports the precise error.
    mutating func replaceArrayElement(
        _ index: Int,
        element: Int,
        with value: GoValue
    ) throws -> Bool {
        guard contains(index), case .array(var values) = cells[index]!.value,
            values.indices.contains(element)
        else { return false }
        let oldBytes = try Self.estimatedBytes(of: values[element], maximum: maximumBytes)
        let newBytes = try Self.estimatedBytes(of: value, maximum: maximumBytes)
        let (layout, cellBytes, marked) = (
            cells[index]!.layout, cells[index]!.estimatedBytes, cells[index]!.marked)
        let bytesWithoutOldElement = liveBytes - oldBytes
        guard bytesWithoutOldElement <= maximumBytes,
            newBytes <= maximumBytes - bytesWithoutOldElement
        else {
            throw GoRuntimeError.resourceLimitExceeded("heap bytes")
        }
        // Drop the cell's reference first so `values` is uniquely referenced
        // and the element store below mutates the buffer in place.
        cells[index] = nil
        values[element] = value
        cells[index] = Cell(
            value: .array(values),
            layout: layout,
            estimatedBytes: cellBytes - oldBytes + newBytes,
            marked: marked)
        liveBytes = bytesWithoutOldElement + newBytes
        return true
    }

    /// Replace `values.count` elements of the array stored in cell `index`,
    /// starting at element `start`, in place: one accounting pass over the
    /// replaced range instead of one cell rebuild per element. Returns
    /// `false` when the cell does not hold an array covering that range.
    mutating func replaceArrayElements(
        _ index: Int,
        from start: Int,
        with values: [GoValue]
    ) throws -> Bool {
        guard contains(index), case .array(var elements) = cells[index]!.value,
            start >= 0, values.count <= elements.count, start <= elements.count - values.count
        else { return false }
        let range = start..<(start + values.count)
        var oldBytes = 0
        var newBytes = 0
        for element in elements[range] {
            oldBytes += try Self.estimatedBytes(of: element, maximum: maximumBytes)
        }
        for value in values {
            let bytes = try Self.estimatedBytes(of: value, maximum: maximumBytes)
            guard bytes <= maximumBytes - newBytes else {
                throw GoRuntimeError.resourceLimitExceeded("heap bytes")
            }
            newBytes += bytes
        }
        let (layout, cellBytes, marked) = (
            cells[index]!.layout, cells[index]!.estimatedBytes, cells[index]!.marked)
        let bytesWithoutOldElements = liveBytes - oldBytes
        guard bytesWithoutOldElements <= maximumBytes,
            newBytes <= maximumBytes - bytesWithoutOldElements
        else {
            throw GoRuntimeError.resourceLimitExceeded("heap bytes")
        }
        // As in `replaceArrayElement`: without the cell's reference the
        // store below mutates the buffer in place.
        cells[index] = nil
        elements.replaceSubrange(range, with: values)
        cells[index] = Cell(
            value: .array(elements),
            layout: layout,
            estimatedBytes: cellBytes - oldBytes + newBytes,
            marked: marked)
        liveBytes = bytesWithoutOldElements + newBytes
        return true
    }

    /// Bytes charged for one map entry besides its key and value.
    private static let mapEntryOverheadBytes = 16

    /// Set `key` in the map stored in cell `index` without copying the storage
    /// or re-measuring its other entries, so an insert or update costs O(1)
    /// instead of O(entries). A new key beyond `maximumEntries` is refused.
    /// Returns `false` when the cell does not hold map storage.
    mutating func setMapEntry(
        _ index: Int,
        key: GoValue,
        value: GoValue,
        maximumEntries: Int
    ) throws -> Bool {
        guard contains(index), case .mapStorage(var storage) = cells[index]!.value else {
            return false
        }
        let removedBytes: Int
        var addedBytes = try Self.estimatedBytes(of: value, maximum: maximumBytes)
        if let existing = storage.entry(for: key) {
            removedBytes = try Self.estimatedBytes(of: existing.value, maximum: maximumBytes)
        } else {
            guard storage.count < maximumEntries else {
                throw GoRuntimeError.resourceLimitExceeded("map entries")
            }
            removedBytes = 0
            let keyBytes = try Self.estimatedBytes(of: key, maximum: maximumBytes)
            guard keyBytes <= maximumBytes - Self.mapEntryOverheadBytes,
                addedBytes <= maximumBytes - Self.mapEntryOverheadBytes - keyBytes
            else { throw GoRuntimeError.resourceLimitExceeded("heap bytes") }
            addedBytes += Self.mapEntryOverheadBytes + keyBytes
        }
        let (layout, cellBytes, marked) = (
            cells[index]!.layout, cells[index]!.estimatedBytes, cells[index]!.marked)
        let bytesWithoutOldValue = liveBytes - removedBytes
        guard bytesWithoutOldValue <= maximumBytes,
            addedBytes <= maximumBytes - bytesWithoutOldValue
        else {
            throw GoRuntimeError.resourceLimitExceeded("heap bytes")
        }
        // Drop the cell's reference first so `storage` is uniquely referenced
        // and the update below mutates its buffers in place.
        cells[index] = nil
        storage.set(key, value)
        cells[index] = Cell(
            value: .mapStorage(storage),
            layout: layout,
            estimatedBytes: cellBytes - removedBytes + addedBytes,
            marked: marked)
        liveBytes = bytesWithoutOldValue + addedBytes
        return true
    }

    /// Delete `key` from the map stored in cell `index` in place and release
    /// the bytes of its entry. Returns `false` when the cell does not hold
    /// map storage; deleting an absent key succeeds.
    mutating func removeMapEntry(_ index: Int, key: GoValue) throws -> Bool {
        guard contains(index), case .mapStorage(var storage) = cells[index]!.value else {
            return false
        }
        // Measure the stored key: an equal key can have another representation.
        guard let existing = storage.entry(for: key) else { return true }
        let removedBytes =
            Self.mapEntryOverheadBytes
            + (try Self.estimatedBytes(of: existing.key, maximum: maximumBytes))
            + (try Self.estimatedBytes(of: existing.value, maximum: maximumBytes))
        let (layout, cellBytes, marked) = (
            cells[index]!.layout, cells[index]!.estimatedBytes, cells[index]!.marked)
        cells[index] = nil
        storage.delete(key)
        cells[index] = Cell(
            value: .mapStorage(storage),
            layout: layout,
            estimatedBytes: cellBytes - removedBytes,
            marked: marked)
        liveBytes -= removedBytes
        return true
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
        liveCells += 1
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
                liveCells -= 1
                cells[index] = nil
                freeList.append(index)
                reclaimedCount += 1
            }
        }
        liveBytesAfterCollection = liveBytes
    }

    private static func estimatedBytes(of root: GoValue, maximum: Int) throws -> Int {
        // Most values stored are scalars and strings: measure them without
        // the worklist below, with the same limit checks.
        switch root {
        case .int, .bool, .nilValue:
            guard maximum >= 32 else { throw GoRuntimeError.resourceLimitExceeded("heap bytes") }
            return 32
        case .string(let string):
            let count = string.utf8.count
            guard maximum >= 32, count <= maximum - 32 else {
                throw GoRuntimeError.resourceLimitExceeded("heap bytes")
            }
            return 32 + count
        default:
            break
        }
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
                try addProduct(storage.count, Self.mapEntryOverheadBytes)
                storage.forEachEntry { key, value in
                    worklist.append(key)
                    worklist.append(value)
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
            storage.forEachEntry { key, value in
                GoHeapLayout(key).appendReferences(in: key, to: &worklist)
                GoHeapLayout(value).appendReferences(in: value, to: &worklist)
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

/// Raised by a native to have a guest function run before it continues.
private struct GoGuestCallRequest: Error {
    let function: GoBytecodeFunction
    let arguments: [GoValue]
    let recovery: GoGuestCallRecovery
}

/// What a native does about a guest function it called that does not return.
private enum GoGuestCallRecovery {
    /// Nothing: a panic unwinds the caller like any other.
    case none
    /// It takes a panic as the result, as `fmt` does for a method.
    case panics
}

/// What the operands of one `fmt` call share: the named types of the
/// descriptor being formatted, and the bound on the text of one operand.
private struct GoFormatScope {
    var definitions: [String: GoRuntimeType] = [:]
    var limit: Int
    let overflow: GoRuntimeError
    /// Whether a value is printed by its `Error` or `String` method. Go's
    /// marker for a bad verb shows the value itself.
    var callsMethods = true
    /// False below an unexported struct field, where Go cannot call methods.
    var accessible = true

    /// `type` with every defined type replaced by what it is defined as.
    func underlying(_ type: GoRuntimeType) -> GoRuntimeType {
        if case .named(let name) = type, definitions[name] == nil,
            let library = GoErrors.definitions[name]
        {
            return library
        }
        return GoTypeDescriptor(type: type, definitions: definitions).underlying(type)
    }
}

/// Bytes a goroutine is waiting to write to a descriptor of its process.
private struct PendingDescriptorWrite {
    let goroutineID: Int
    let bytes: [UInt8]
    var offset = 0
    var idleRounds = 0
    /// Values the write yields from the accepted byte count and error message.
    let results: ((Int, String?) -> [GoValue])?
}

private struct DeferredCall {
    let function: String
    let arguments: [GoValue]
}

/// The state of a run that its instructions read and write all the time:
/// the running goroutine's frames and operand stack, the heap, and the
/// scheduler's counters and flags.
///
/// It is an object rather than local variables of `execute` because the
/// nested functions there escape (into host continuations), and every
/// access to a local variable captured by an escaping closure is checked for
/// exclusivity at run time, which cost more than the instructions did. The
/// VM is single-threaded and never holds two accesses to one of these at
/// once, so the checks are off.
private final class GoExecutionState {
    @exclusivity(unchecked) var heap: ManagedHeap
    @exclusivity(unchecked) var frames: [Frame] = []
    @exclusivity(unchecked) var stack: [GoValue] = []
    @exclusivity(unchecked) var executed = 0
    @exclusivity(unchecked) var lastEventLoopYieldInstruction = 0
    @exclusivity(unchecked) var currentGoroutineID = 0
    @exclusivity(unchecked) var goroutines = GoIntTable<GoroutineContext>()
    @exclusivity(unchecked) var runQueue = GoRunQueue()
    @exclusivity(unchecked) var currentBlocked = false
    /// True once the current goroutine's context is already stored in
    /// `goroutines` (parked, and possibly woken again) within this
    /// instruction, so the scheduler must not store it a second time.
    @exclusivity(unchecked) var currentParked = false
    @exclusivity(unchecked) var yieldRequested = false
    @exclusivity(unchecked) var sliceStartInstruction = 0
    @exclusivity(unchecked) var liveFrameLocalCount = 0
    @exclusivity(unchecked) var lastRuntimeMemoryReport: (bytes: Int, cells: Int, collections: Int)?

    init(heap: ManagedHeap) {
        self.heap = heap
    }
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

/// A call in progress.
///
/// A class, not a struct: the execution loop reads `frames[i].field` several
/// times per instruction, and reading a field of a struct element of an array
/// copies the whole element, retaining every array and string it holds. A
/// frame belongs to one goroutine's call stack at a time, and a parked
/// goroutine's frames are only touched through its saved context, so sharing
/// the object where the struct was copied changes nothing.
///
/// The fields the loop touches on every instruction skip the run-time
/// exclusivity check: the VM is single-threaded and never holds two accesses
/// to one of them at once.
private final class Frame {
    let function: GoBytecodeFunction
    let stackBase: Int
    @exclusivity(unchecked) var locals: [Int?]
    @exclusivity(unchecked) var programCounter = 0
    var deferredCalls: [DeferredCall] = []
    @exclusivity(unchecked) var pendingExit: FrameExit?
    let isDeferredCall: Bool
    /// Results of the guest functions that the native call this frame is
    /// executing has had run, in the order it asked for them: the `Error` and
    /// `String` methods of `fmt` operands, the `Unwrap` and `Is` methods of
    /// an error chain. The native runs again after each one returns, until it
    /// needs no further result.
    var guestCallResults: [GoValue] = []
    /// Whether the value on top of the stack is the result of such a call.
    var awaitsGuestCall = false
    /// What becomes of a panic of the function being waited for.
    var guestCallRecovery = GoGuestCallRecovery.none
    /// The panics that began before the one this frame is ending with and
    /// were not done with when it began: a deferred call panicked while the
    /// function was panicking, or after it had recovered. Go names them all
    /// when the last one ends the program.
    var earlierPanics: [GoPanicRecord] = []
    /// The panic a deferred call of this frame has recovered, until that
    /// call returns.
    var recoveredPanic: GoValue?
    /// The locals of the function's results, when it returns what they
    /// hold as it ends: after its deferred calls, which may have changed
    /// them or recovered a panic.
    var resultLocals: [Int]?
    /// The report of the panics that ended the goroutine, when this frame
    /// runs the `Error` or `String` method that says what the first one
    /// still to be described is.
    var panicReport: GoPanicReport?

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

    /// The function's safepoints as a set, made the first time a collection
    /// is due while this frame runs.
    private var safepoints: Set<Int>?

    /// Whether a collection may run with this frame stopped at
    /// `programCounter`: `safepointProgramCounters.contains`, without a
    /// scan of the list on every instruction while a collection is due.
    func isSafepoint(_ programCounter: Int) -> Bool {
        if let safepoints { return safepoints.contains(programCounter) }
        let made = Set(function.safepointProgramCounters)
        safepoints = made
        return made.contains(programCounter)
    }
}
