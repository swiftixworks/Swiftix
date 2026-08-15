/// Resource ceilings and structural validation shared by Swiftix Go images and execution.
/// Validation runs before the VM allocates globals, frame locals, or instruction metadata.

public struct GoRuntimeResourceLimits: Sendable, Equatable {
    public let maximumFunctions: Int
    public let maximumGlobals: Int
    public let maximumTotalLocals: Int
    public let maximumTotalInstructions: Int
    public let maximumMetadataEntries: Int
    public let maximumStringBytes: Int
    public let maximumHeapCells: Int
    public let maximumHeapBytes: Int
    public let maximumCollectionElements: Int
    public let maximumMapEntries: Int
    public let maximumGoroutines: Int
    public let maximumTimers: Int
    public let maximumRuntimeHandles: Int
    public let maximumInputBytes: Int
    public let maximumOutputBytes: Int
    public let maximumNetworkTransferBytes: Int
    public let maximumValueStackEntries: Int
    public let maximumLiveFrameLocals: Int
    public let maximumPointerDepth: Int

    public init(
        maximumFunctions: Int = 65_535,
        maximumGlobals: Int = 262_144,
        maximumTotalLocals: Int = 1_048_576,
        maximumTotalInstructions: Int = 1_048_576,
        maximumMetadataEntries: Int = 2_097_152,
        maximumStringBytes: Int = 1_048_576,
        maximumHeapCells: Int = 262_144,
        maximumHeapBytes: Int = 64 * 1_024 * 1_024,
        maximumCollectionElements: Int = 262_144,
        maximumMapEntries: Int = 65_536,
        maximumGoroutines: Int = 16_384,
        maximumTimers: Int = 16_384,
        maximumRuntimeHandles: Int = 16_384,
        maximumInputBytes: Int = 16 * 1_024 * 1_024,
        maximumOutputBytes: Int = 16 * 1_024 * 1_024,
        maximumNetworkTransferBytes: Int = 1_024 * 1_024,
        maximumValueStackEntries: Int = 1_048_576,
        maximumLiveFrameLocals: Int = 1_048_576,
        maximumPointerDepth: Int = 1_024
    ) {
        self.maximumFunctions = max(0, maximumFunctions)
        self.maximumGlobals = max(0, maximumGlobals)
        self.maximumTotalLocals = max(0, maximumTotalLocals)
        self.maximumTotalInstructions = max(0, maximumTotalInstructions)
        self.maximumMetadataEntries = max(0, maximumMetadataEntries)
        self.maximumStringBytes = max(0, maximumStringBytes)
        self.maximumHeapCells = max(0, maximumHeapCells)
        self.maximumHeapBytes = max(0, maximumHeapBytes)
        self.maximumCollectionElements = max(0, maximumCollectionElements)
        self.maximumMapEntries = max(0, maximumMapEntries)
        self.maximumGoroutines = max(0, maximumGoroutines)
        self.maximumTimers = max(0, maximumTimers)
        self.maximumRuntimeHandles = max(0, maximumRuntimeHandles)
        self.maximumInputBytes = max(0, maximumInputBytes)
        self.maximumOutputBytes = max(0, maximumOutputBytes)
        self.maximumNetworkTransferBytes = max(0, maximumNetworkTransferBytes)
        self.maximumValueStackEntries = max(0, maximumValueStackEntries)
        self.maximumLiveFrameLocals = max(0, maximumLiveFrameLocals)
        self.maximumPointerDepth = max(0, maximumPointerDepth)
    }
}

internal enum GoExecutableValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case duplicateFunction(String)
    case missingEntryPoint(String)
    case missingInitializer(String)
    case invalid(String)
    case resourceLimitExceeded(String)

    var description: String {
        switch self {
        case .duplicateFunction(let name):
            return "duplicate function \(name)"
        case .missingEntryPoint(let name):
            return "missing entry point \(name)"
        case .missingInitializer(let name):
            return "missing initializer \(name)"
        case .invalid(let reason):
            return reason
        case .resourceLimitExceeded(let resource):
            return "resource limit exceeded: \(resource)"
        }
    }
}

internal enum GoExecutableValidator {
    static func validate(
        _ executable: GoExecutable,
        limits: GoRuntimeResourceLimits
    ) throws {
        guard executable.globalCount >= 0 else {
            throw GoExecutableValidationError.invalid("negative global count")
        }
        try requireAtMost(
            executable.globalCount,
            limits.maximumGlobals,
            resource: "globals")
        try requireAtMost(
            executable.functions.count,
            limits.maximumFunctions,
            resource: "functions")
        try requireAtMost(
            executable.initializers.count,
            limits.maximumFunctions,
            resource: "initializers")
        try requireString(executable.entryPoint, limits: limits, role: "entry point")

        var names: Set<String> = []
        names.reserveCapacity(executable.functions.count)
        var totalLocals = 0
        var totalInstructions = 0
        var totalMetadata = 0

        for function in executable.functions {
            try requireString(function.name, limits: limits, role: "function name")
            guard names.insert(function.name).inserted else {
                throw GoExecutableValidationError.duplicateFunction(function.name)
            }
            guard function.parameterCount >= 0,
                function.returnCount >= 0,
                function.localCount >= 0
            else {
                throw GoExecutableValidationError.invalid(
                    "negative function count in \(function.name)")
            }
            guard function.parameterCount <= function.localCount else {
                throw GoExecutableValidationError.invalid(
                    "invalid parameter, result, or local count in \(function.name)")
            }
            try requireAtMost(
                function.returnCount,
                limits.maximumValueStackEntries,
                resource: "function results")
            try add(
                function.localCount,
                to: &totalLocals,
                limit: limits.maximumTotalLocals,
                resource: "total locals")
            try add(
                function.instructions.count,
                to: &totalInstructions,
                limit: limits.maximumTotalInstructions,
                resource: "total instructions")
            try add(
                function.rootLocalIndices.count,
                to: &totalMetadata,
                limit: limits.maximumMetadataEntries,
                resource: "function metadata")
            try add(
                function.safepointProgramCounters.count,
                to: &totalMetadata,
                limit: limits.maximumMetadataEntries,
                resource: "function metadata")

            guard Set(function.rootLocalIndices).count == function.rootLocalIndices.count,
                function.rootLocalIndices.allSatisfy({
                    $0 >= 0 && $0 < function.localCount
                })
            else {
                throw GoExecutableValidationError.invalid(
                    "invalid root-local metadata in \(function.name)")
            }
            guard Set(function.safepointProgramCounters).count
                    == function.safepointProgramCounters.count,
                function.safepointProgramCounters.allSatisfy({
                    $0 >= 0 && $0 <= function.instructions.count
                })
            else {
                throw GoExecutableValidationError.invalid(
                    "invalid safepoint metadata in \(function.name)")
            }

            for instruction in function.instructions {
                try validate(
                    instruction,
                    in: function,
                    globalCount: executable.globalCount,
                    totalMetadata: &totalMetadata,
                    limits: limits)
            }
        }

        guard names.contains(executable.entryPoint) else {
            throw GoExecutableValidationError.missingEntryPoint(executable.entryPoint)
        }
        guard Set(executable.initializers).count == executable.initializers.count else {
            throw GoExecutableValidationError.invalid("duplicate initializer")
        }
        for initializer in executable.initializers {
            try requireString(initializer, limits: limits, role: "initializer")
            guard names.contains(initializer) else {
                throw GoExecutableValidationError.missingInitializer(initializer)
            }
        }
    }

    private static func validate(
        _ instruction: GoInstruction,
        in function: GoBytecodeFunction,
        globalCount: Int,
        totalMetadata: inout Int,
        limits: GoRuntimeResourceLimits
    ) throws {
        func local(_ index: Int) throws {
            guard index >= 0, index < function.localCount else {
                throw GoExecutableValidationError.invalid(
                    "invalid local index \(index) in \(function.name)")
            }
        }
        func global(_ index: Int) throws {
            guard index >= 0, index < globalCount else {
                throw GoExecutableValidationError.invalid(
                    "invalid global index \(index) in \(function.name)")
            }
        }
        func target(_ index: Int) throws {
            guard index >= 0, index <= function.instructions.count else {
                throw GoExecutableValidationError.invalid(
                    "invalid jump target \(index) in \(function.name)")
            }
        }
        func count(_ value: Int, resource: String) throws {
            guard value >= 0 else {
                throw GoExecutableValidationError.invalid(
                    "negative \(resource) in \(function.name)")
            }
            try requireAtMost(value, limits.maximumCollectionElements, resource: resource)
        }
        func argumentCount(_ value: Int) throws {
            guard value >= 0 else {
                throw GoExecutableValidationError.invalid(
                    "negative argument count in \(function.name)")
            }
            try requireAtMost(
                value,
                limits.maximumValueStackEntries,
                resource: "instruction arguments")
        }

        switch instruction {
        case .push(let value):
            switch value {
            case .int, .bool, .nilValue:
                break
            case .string(let string):
                try requireString(string, limits: limits, role: "string constant")
            default:
                throw GoExecutableValidationError.invalid(
                    "non-constant push value in \(function.name)")
            }
        case .load(let index), .store(let index):
            try local(index)
        case .print(let value, _), .testFail(let value, _):
            try argumentCount(value)
        case .jump(let index), .jumpIfFalse(let index), .jumpIfTrue(let index):
            try target(index)
        case .call(let name, let value), .spawn(let name, let value),
            .deferCall(let name, let value), .callInterface(let name, let value):
            try requireString(name, limits: limits, role: "function reference")
            try argumentCount(value)
        case .makeStruct(let typeName, let fieldNames):
            if let typeName {
                try requireString(typeName, limits: limits, role: "type name")
            }
            try add(
                fieldNames.count,
                to: &totalMetadata,
                limit: limits.maximumMetadataEntries,
                resource: "instruction metadata")
            for fieldName in fieldNames {
                try requireString(fieldName, limits: limits, role: "field name")
            }
        case .getField(let name), .setField(let name), .fieldAddress(let name),
            .makeInterface(let name), .testBegin(let name), .testEnd(let name):
            try requireString(name, limits: limits, role: "instruction string")
        case .addressLocal(let index, let fieldPath):
            try local(index)
            try requireAtMost(
                fieldPath.count,
                limits.maximumPointerDepth,
                resource: "pointer depth")
            try add(
                fieldPath.count,
                to: &totalMetadata,
                limit: limits.maximumMetadataEntries,
                resource: "instruction metadata")
            for fieldName in fieldPath {
                try requireString(fieldName, limits: limits, role: "field path")
            }
        case .makeArray(let value), .makeSlice(let value):
            try count(value, resource: "collection elements")
        case .loadGlobal(let index), .storeGlobal(let index), .addressGlobal(let index):
            try global(index)
        case .returnValues(let value):
            try argumentCount(value)
        case .makeMap(let value):
            guard value >= 0 else {
                throw GoExecutableValidationError.invalid(
                    "negative map entry count in \(function.name)")
            }
            try requireAtMost(value, limits.maximumMapEntries, resource: "map entries")
        case .select(let cases, let defaultTarget):
            try add(
                cases.count,
                to: &totalMetadata,
                limit: limits.maximumMetadataEntries,
                resource: "select metadata")
            for selectCase in cases {
                switch selectCase {
                case .send(let channelLocal, let valueLocal, let destination):
                    try local(channelLocal)
                    try local(valueLocal)
                    try target(destination)
                case .receive(
                    let channelLocal,
                    let destinationLocal,
                    let okLocal,
                    let zeroLocal,
                    let destination):
                    try local(channelLocal)
                    if let destinationLocal { try local(destinationLocal) }
                    if let okLocal { try local(okLocal) }
                    try local(zeroLocal)
                    try target(destination)
                }
            }
            if let defaultTarget { try target(defaultTarget) }
        case .typeAssert(let name, _), .httpHandleFunc(let name):
            try requireString(name, limits: limits, role: "instruction string")
        case .negate, .not, .add, .subtract, .multiply, .divide, .remainder,
            .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual,
            .logicalAnd, .logicalOr, .dereference, .setPointer,
            .allocateSlice, .getIndex, .setIndex, .slice, .sliceArray, .length,
            .capacity, .append, .indexAddress, .return, .panic, .recover,
            .makeChannel, .sendChannel, .receiveChannel, .closeChannel,
            .timeAfter, .timeSleep, .timeTick, .contextBackground,
            .contextWithCancel, .contextWithTimeout, .contextDone, .contextErr,
            .cancelContext, .netDial, .netListen, .netAccept, .netRead,
            .netWrite, .netClose, .netLookupHost, .httpListenAndServe, .httpGet,
            .makeMutex, .mutexLock, .mutexUnlock, .makeWaitGroup,
            .waitGroupAdd, .waitGroupWait, .garbageCollect, .getMapIndex,
            .setMapIndex, .deleteMap, .rangeKeys, .rangeValue, .osArgs, .exit,
            .parseInt, .readInput:
            break
        }
    }

    private static func requireString(
        _ value: String,
        limits: GoRuntimeResourceLimits,
        role: String
    ) throws {
        try requireAtMost(
            value.utf8.count,
            limits.maximumStringBytes,
            resource: "\(role) bytes")
    }

    private static func requireAtMost(
        _ value: Int,
        _ maximum: Int,
        resource: String
    ) throws {
        guard value <= maximum else {
            throw GoExecutableValidationError.resourceLimitExceeded(resource)
        }
    }

    private static func add(
        _ value: Int,
        to total: inout Int,
        limit: Int,
        resource: String
    ) throws {
        guard value >= 0, total <= limit, value <= limit - total else {
            throw GoExecutableValidationError.resourceLimitExceeded(resource)
        }
        total += value
    }
}

internal extension GoRuntimeResourceLimits {
    static let executableImage = GoRuntimeResourceLimits(
        maximumFunctions: 65_535,
        maximumGlobals: 1_048_576,
        maximumTotalLocals: 1_048_576,
        maximumTotalInstructions: 1_048_576,
        maximumMetadataEntries: 2_097_152,
        maximumStringBytes: 1_048_576,
        maximumHeapCells: Int.max,
        maximumHeapBytes: Int.max,
        maximumCollectionElements: 1_048_576,
        maximumMapEntries: 1_048_576,
        maximumGoroutines: Int.max,
        maximumTimers: Int.max,
        maximumRuntimeHandles: Int.max,
        maximumInputBytes: Int.max,
        maximumOutputBytes: Int.max,
        maximumNetworkTransferBytes: Int.max,
        maximumValueStackEntries: 1_048_576,
        maximumLiveFrameLocals: Int.max,
        maximumPointerDepth: 1_048_576)
}
