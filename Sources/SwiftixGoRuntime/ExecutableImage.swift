/// Deterministic binary encoding for compiled Swiftix Go executables.

public enum GoExecutableImageError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidMagic
    case unsupportedVersion(UInt16)
    case unsupportedABI(UInt16)
    case unsupportedTarget(goos: String, goarch: String)
    case truncated
    case invalidUTF8
    case invalidBoolean(UInt8)
    case invalidOpcode(UInt8)
    case invalidValueTag(UInt8)
    case invalidCount
    case duplicateFunction(String)
    case missingEntryPoint(String)
    case trailingData

    public var description: String {
        switch self {
        case .invalidMagic: return "not a Swiftix Go executable"
        case .unsupportedVersion(let version):
            return "unsupported Swiftix Go executable version \(version)"
        case .unsupportedABI(let version):
            return "unsupported Swiftix Go ABI version \(version)"
        case .unsupportedTarget(let goos, let goarch):
            return "unsupported Swiftix Go target \(goos)/\(goarch)"
        case .truncated: return "truncated Swiftix Go executable"
        case .invalidUTF8: return "invalid UTF-8 in Swiftix Go executable"
        case .invalidBoolean(let value): return "invalid boolean value \(value)"
        case .invalidOpcode(let opcode): return "invalid bytecode opcode \(opcode)"
        case .invalidValueTag(let tag): return "invalid bytecode value tag \(tag)"
        case .invalidCount: return "invalid count in Swiftix Go executable"
        case .duplicateFunction(let name): return "duplicate function \(name)"
        case .missingEntryPoint(let name): return "missing entry point \(name)"
        case .trailingData: return "trailing data in Swiftix Go executable"
        }
    }
}

public enum GoExecutableImage {
    public static let formatVersion: UInt16 = 10
    public static let abiVersion: UInt16 = 10
    public static let targetOS = "swiftix"
    public static let targetArchitecture = "svm64"
    public static let maximumImageSize = 16 * 1_024 * 1_024

    private static let magic = Array("\u{7f}SWIFTIXGO".utf8)
    fileprivate static let maximumFunctions = 65_535
    fileprivate static let maximumLocals = 1_048_576
    fileprivate static let maximumInstructions = 1_048_576
    fileprivate static let maximumStringBytes = 1_048_576

    public static func recognizes(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: magic)
    }

    public static func encode(_ executable: GoExecutable) throws -> [UInt8] {
        try validate(executable)
        var writer = ImageWriter(maximumBytes: maximumImageSize)
        writer.append(contentsOf: magic)
        writer.writeUInt16(formatVersion)
        writer.writeUInt16(abiVersion)
        try writer.write(targetOS, maximumBytes: maximumStringBytes)
        try writer.write(targetArchitecture, maximumBytes: maximumStringBytes)
        try writer.write(executable.entryPoint, maximumBytes: maximumStringBytes)
        try writer.writeCount(executable.globalCount, maximum: maximumLocals)
        try writer.writeCount(executable.initializers.count, maximum: maximumFunctions)
        for initializer in executable.initializers {
            try writer.write(initializer, maximumBytes: maximumStringBytes)
        }
        try writer.writeCount(executable.functions.count, maximum: maximumFunctions)
        for function in executable.functions {
            try writer.write(function.name, maximumBytes: maximumStringBytes)
            try writer.writeCount(function.parameterCount, maximum: maximumLocals)
            try writer.writeCount(function.returnCount, maximum: maximumLocals)
            try writer.writeCount(function.localCount, maximum: maximumLocals)
            try writer.writeCount(function.rootLocalIndices.count, maximum: maximumLocals)
            for index in function.rootLocalIndices {
                try writer.writeCount(index, maximum: maximumLocals)
            }
            try writer.writeCount(
                function.safepointProgramCounters.count,
                maximum: maximumInstructions + 1)
            for programCounter in function.safepointProgramCounters {
                try writer.writeCount(programCounter, maximum: maximumInstructions)
            }
            try writer.writeCount(function.instructions.count, maximum: maximumInstructions)
            for instruction in function.instructions {
                try writer.write(instruction)
            }
        }
        guard !writer.exceededLimit else {
            throw GoExecutableImageError.invalidCount
        }
        return writer.bytes
    }

    public static func decode(_ bytes: [UInt8]) throws -> GoExecutable {
        guard bytes.count <= maximumImageSize else {
            throw GoExecutableImageError.invalidCount
        }
        var reader = ImageReader(bytes: bytes)
        guard try reader.readBytes(count: magic.count) == magic else {
            throw GoExecutableImageError.invalidMagic
        }
        let version = try reader.readUInt16()
        guard version == formatVersion else {
            throw GoExecutableImageError.unsupportedVersion(version)
        }
        let abi = try reader.readUInt16()
        guard abi == abiVersion else {
            throw GoExecutableImageError.unsupportedABI(abi)
        }
        let goos = try reader.readString(maximumBytes: maximumStringBytes)
        let goarch = try reader.readString(maximumBytes: maximumStringBytes)
        guard goos == targetOS, goarch == targetArchitecture else {
            throw GoExecutableImageError.unsupportedTarget(goos: goos, goarch: goarch)
        }
        let entryPoint = try reader.readString(maximumBytes: maximumStringBytes)
        let globalCount = try reader.readCount(maximum: maximumLocals)
        let initializerCount = try reader.readCount(maximum: maximumFunctions)
        var initializers: [String] = []
        initializers.reserveCapacity(initializerCount)
        for _ in 0..<initializerCount {
            initializers.append(try reader.readString(maximumBytes: maximumStringBytes))
        }
        let functionCount = try reader.readCount(maximum: maximumFunctions)
        var functions: [GoBytecodeFunction] = []
        var functionNames: Set<String> = []
        functions.reserveCapacity(functionCount)
        for _ in 0..<functionCount {
            let name = try reader.readString(maximumBytes: maximumStringBytes)
            guard functionNames.insert(name).inserted else {
                throw GoExecutableImageError.duplicateFunction(name)
            }
            let parameterCount = try reader.readCount(maximum: maximumLocals)
            let returnCount = try reader.readCount(maximum: maximumLocals)
            let localCount = try reader.readCount(maximum: maximumLocals)
            guard parameterCount <= localCount else {
                throw GoExecutableImageError.invalidCount
            }
            let rootCount = try reader.readCount(maximum: maximumLocals)
            var rootLocalIndices: [Int] = []
            rootLocalIndices.reserveCapacity(rootCount)
            for _ in 0..<rootCount {
                let index = try reader.readCount(maximum: maximumLocals)
                guard index < localCount else { throw GoExecutableImageError.invalidCount }
                rootLocalIndices.append(index)
            }
            guard Set(rootLocalIndices).count == rootLocalIndices.count else {
                throw GoExecutableImageError.invalidCount
            }
            let safepointCount = try reader.readCount(maximum: maximumInstructions + 1)
            var safepointProgramCounters: [Int] = []
            safepointProgramCounters.reserveCapacity(safepointCount)
            for _ in 0..<safepointCount {
                safepointProgramCounters.append(
                    try reader.readCount(maximum: maximumInstructions))
            }
            let instructionCount = try reader.readCount(maximum: maximumInstructions)
            guard safepointProgramCounters.allSatisfy({ $0 <= instructionCount }) else {
                throw GoExecutableImageError.invalidCount
            }
            guard Set(safepointProgramCounters).count == safepointProgramCounters.count else {
                throw GoExecutableImageError.invalidCount
            }
            var instructions: [GoInstruction] = []
            instructions.reserveCapacity(instructionCount)
            for _ in 0..<instructionCount {
                instructions.append(try reader.readInstruction())
            }
            functions.append(
                GoBytecodeFunction(
                    name: name,
                    parameterCount: parameterCount,
                    returnCount: returnCount,
                    localCount: localCount,
                    instructions: instructions,
                    rootLocalIndices: rootLocalIndices,
                    safepointProgramCounters: safepointProgramCounters))
        }
        guard reader.isAtEnd else { throw GoExecutableImageError.trailingData }
        guard functionNames.contains(entryPoint) else {
            throw GoExecutableImageError.missingEntryPoint(entryPoint)
        }
        guard initializers.allSatisfy(functionNames.contains) else {
            throw GoExecutableImageError.missingEntryPoint(
                initializers.first(where: { !functionNames.contains($0) }) ?? entryPoint)
        }
        let executable = GoExecutable(
            entryPoint: entryPoint,
            initializers: initializers,
            globalCount: globalCount,
            functions: functions)
        try validate(executable)
        return executable
    }

    static func validate(_ executable: GoExecutable) throws {
        do {
            try GoExecutableValidator.validate(executable, limits: .executableImage)
        } catch let error as GoExecutableValidationError {
            switch error {
            case .duplicateFunction(let name):
                throw GoExecutableImageError.duplicateFunction(name)
            case .missingEntryPoint(let name), .missingInitializer(let name):
                throw GoExecutableImageError.missingEntryPoint(name)
            case .invalid, .resourceLimitExceeded:
                throw GoExecutableImageError.invalidCount
            }
        }
    }
}

private struct ImageWriter {
    private let maximumBytes: Int
    private(set) var bytes: [UInt8] = []
    private(set) var exceededLimit = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        bytes.reserveCapacity(min(maximumBytes, 64 * 1_024))
    }

    mutating func append(contentsOf appended: [UInt8]) {
        guard !exceededLimit,
            bytes.count <= maximumBytes,
            appended.count <= maximumBytes - bytes.count
        else {
            exceededLimit = true
            return
        }
        bytes.append(contentsOf: appended)
    }

    mutating func writeByte(_ value: UInt8) {
        guard !exceededLimit, bytes.count < maximumBytes else {
            exceededLimit = true
            return
        }
        bytes.append(value)
    }

    mutating func writeBoolean(_ value: Bool) {
        writeByte(value ? 1 : 0)
    }

    mutating func writeUInt16(_ value: UInt16) {
        writeByte(UInt8(truncatingIfNeeded: value))
        writeByte(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func writeUInt32(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            writeByte(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func writeInt64(_ value: Int64) {
        let bits = UInt64(bitPattern: value)
        for shift in stride(from: 0, through: 56, by: 8) {
            writeByte(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
    }

    mutating func writeCount(_ value: Int, maximum: Int) throws {
        guard value >= 0, value <= maximum, let encoded = UInt32(exactly: value) else {
            throw GoExecutableImageError.invalidCount
        }
        writeUInt32(encoded)
    }

    mutating func write(_ value: String, maximumBytes: Int) throws {
        let byteCount = value.utf8.count
        try writeCount(byteCount, maximum: maximumBytes)
        guard byteCount <= self.maximumBytes - min(bytes.count, self.maximumBytes) else {
            exceededLimit = true
            return
        }
        append(contentsOf: Array(value.utf8))
    }

    mutating func write(_ instruction: GoInstruction) throws {
        switch instruction {
        case .push(let value):
            writeByte(0)
            switch value {
            case .int(let integer):
                writeByte(0)
                writeInt64(integer)
            case .string(let string):
                writeByte(1)
                try write(string, maximumBytes: GoExecutableImage.maximumStringBytes)
            case .bool(let boolean):
                writeByte(2)
                writeBoolean(boolean)
            case .nilValue:
                writeByte(3)
            case .structure:
                throw GoExecutableImageError.invalidValueTag(4)
            case .pointer:
                throw GoExecutableImageError.invalidValueTag(5)
            case .array:
                throw GoExecutableImageError.invalidValueTag(6)
            case .slice:
                throw GoExecutableImageError.invalidValueTag(7)
            case .map:
                throw GoExecutableImageError.invalidValueTag(8)
            case .interface:
                throw GoExecutableImageError.invalidValueTag(9)
            case .mapStorage:
                throw GoExecutableImageError.invalidValueTag(10)
            case .channel:
                throw GoExecutableImageError.invalidValueTag(11)
            case .channelStorage:
                throw GoExecutableImageError.invalidValueTag(12)
            case .mutex:
                throw GoExecutableImageError.invalidValueTag(13)
            case .mutexStorage:
                throw GoExecutableImageError.invalidValueTag(14)
            case .waitGroup:
                throw GoExecutableImageError.invalidValueTag(15)
            case .waitGroupStorage:
                throw GoExecutableImageError.invalidValueTag(16)
            case .context:
                throw GoExecutableImageError.invalidValueTag(17)
            case .contextStorage:
                throw GoExecutableImageError.invalidValueTag(18)
            case .netConn:
                throw GoExecutableImageError.invalidValueTag(19)
            case .netListener:
                throw GoExecutableImageError.invalidValueTag(20)
            }
        case .load(let index):
            writeByte(1)
            try writeCount(index, maximum: GoExecutableImage.maximumLocals)
        case .store(let index):
            writeByte(2)
            try writeCount(index, maximum: GoExecutableImage.maximumLocals)
        case .negate: writeByte(3)
        case .not: writeByte(4)
        case .add: writeByte(5)
        case .subtract: writeByte(6)
        case .multiply: writeByte(7)
        case .divide: writeByte(8)
        case .remainder: writeByte(9)
        case .equal: writeByte(10)
        case .notEqual: writeByte(11)
        case .less: writeByte(12)
        case .lessEqual: writeByte(13)
        case .greater: writeByte(14)
        case .greaterEqual: writeByte(15)
        case .logicalAnd: writeByte(16)
        case .logicalOr: writeByte(17)
        case .print(let argumentCount, let newline):
            writeByte(18)
            try writeCount(argumentCount, maximum: GoExecutableImage.maximumLocals)
            writeBoolean(newline)
        case .jump(let target):
            writeByte(19)
            try writeCount(target, maximum: GoExecutableImage.maximumInstructions)
        case .jumpIfFalse(let target):
            writeByte(20)
            try writeCount(target, maximum: GoExecutableImage.maximumInstructions)
        case .jumpIfTrue(let target):
            writeByte(21)
            try writeCount(target, maximum: GoExecutableImage.maximumInstructions)
        case .call(let name, let argumentCount):
            writeByte(22)
            try write(name, maximumBytes: GoExecutableImage.maximumStringBytes)
            try writeCount(argumentCount, maximum: GoExecutableImage.maximumLocals)
        case .return:
            writeByte(23)
        case .returnValues(let count):
            writeByte(24)
            try writeCount(count, maximum: GoExecutableImage.maximumLocals)
        case .makeStruct(let typeName, let fieldNames):
            writeByte(25)
            writeBoolean(typeName != nil)
            if let typeName {
                try write(typeName, maximumBytes: GoExecutableImage.maximumStringBytes)
            }
            try writeCount(fieldNames.count, maximum: GoExecutableImage.maximumLocals)
            for fieldName in fieldNames {
                try write(fieldName, maximumBytes: GoExecutableImage.maximumStringBytes)
            }
        case .getField(let name):
            writeByte(26)
            try write(name, maximumBytes: GoExecutableImage.maximumStringBytes)
        case .setField(let name):
            writeByte(27)
            try write(name, maximumBytes: GoExecutableImage.maximumStringBytes)
        case .addressLocal(let index, let fieldPath):
            writeByte(28)
            try writeCount(index, maximum: GoExecutableImage.maximumLocals)
            try writeCount(fieldPath.count, maximum: GoExecutableImage.maximumLocals)
            for field in fieldPath {
                try write(field, maximumBytes: GoExecutableImage.maximumStringBytes)
            }
        case .dereference:
            writeByte(29)
        case .setPointer:
            writeByte(30)
        case .fieldAddress(let name):
            writeByte(31)
            try write(name, maximumBytes: GoExecutableImage.maximumStringBytes)
        case .makeArray(let elementCount):
            writeByte(32)
            try writeCount(elementCount, maximum: GoExecutableImage.maximumLocals)
        case .makeSlice(let elementCount):
            writeByte(33)
            try writeCount(elementCount, maximum: GoExecutableImage.maximumLocals)
        case .allocateSlice: writeByte(34)
        case .getIndex: writeByte(35)
        case .setIndex: writeByte(36)
        case .slice: writeByte(37)
        case .sliceArray: writeByte(38)
        case .length: writeByte(39)
        case .capacity: writeByte(40)
        case .append: writeByte(41)
        case .indexAddress: writeByte(42)
        case .loadGlobal(let index):
            writeByte(43)
            try writeCount(index, maximum: GoExecutableImage.maximumLocals)
        case .storeGlobal(let index):
            writeByte(44)
            try writeCount(index, maximum: GoExecutableImage.maximumLocals)
        case .addressGlobal(let index):
            writeByte(45)
            try writeCount(index, maximum: GoExecutableImage.maximumLocals)
        case .deferCall(let name, let argumentCount):
            writeByte(46)
            try write(name, maximumBytes: GoExecutableImage.maximumStringBytes)
            try writeCount(argumentCount, maximum: GoExecutableImage.maximumLocals)
        case .panic:
            writeByte(47)
        case .makeMap(let entryCount):
            writeByte(48)
            try writeCount(entryCount, maximum: GoExecutableImage.maximumLocals)
        case .getMapIndex(let commaOK):
            writeByte(49)
            writeBoolean(commaOK)
        case .setMapIndex:
            writeByte(50)
        case .deleteMap:
            writeByte(51)
        case .callInterface(let name, let argumentCount):
            writeByte(52)
            try write(name, maximumBytes: GoExecutableImage.maximumStringBytes)
            try writeCount(argumentCount, maximum: GoExecutableImage.maximumLocals)
        case .makeInterface(let typeName):
            writeByte(53)
            try write(typeName, maximumBytes: GoExecutableImage.maximumStringBytes)
        case .rangeKeys:
            writeByte(54)
        case .rangeValue:
            writeByte(55)
        case .recover:
            writeByte(56)
        case .typeAssert(let typeName, let commaOK):
            writeByte(57)
            try write(typeName, maximumBytes: GoExecutableImage.maximumStringBytes)
            writeBoolean(commaOK)
        case .testFail(let argumentCount, let fatal):
            writeByte(58)
            try writeCount(argumentCount, maximum: GoExecutableImage.maximumLocals)
            writeBoolean(fatal)
        case .testBegin(let name):
            writeByte(59)
            try write(name, maximumBytes: GoExecutableImage.maximumStringBytes)
        case .testEnd(let name):
            writeByte(60)
            try write(name, maximumBytes: GoExecutableImage.maximumStringBytes)
        case .spawn(let name, let argumentCount):
            writeByte(61)
            try write(name, maximumBytes: GoExecutableImage.maximumStringBytes)
            try writeCount(argumentCount, maximum: GoExecutableImage.maximumLocals)
        case .makeChannel:
            writeByte(62)
        case .sendChannel:
            writeByte(63)
        case .receiveChannel(let commaOK):
            writeByte(64)
            writeBoolean(commaOK)
        case .closeChannel:
            writeByte(65)
        case .select(let cases, let defaultTarget):
            writeByte(66)
            try writeCount(cases.count, maximum: GoExecutableImage.maximumInstructions)
            for selectCase in cases {
                switch selectCase {
                case .send(let channelLocal, let valueLocal, let target):
                    writeByte(0)
                    try writeCount(channelLocal, maximum: GoExecutableImage.maximumLocals)
                    try writeCount(valueLocal, maximum: GoExecutableImage.maximumLocals)
                    try writeCount(target, maximum: GoExecutableImage.maximumInstructions)
                case .receive(
                    let channelLocal, let destinationLocal, let okLocal,
                    let zeroLocal, let target):
                    writeByte(1)
                    try writeCount(channelLocal, maximum: GoExecutableImage.maximumLocals)
                    writeBoolean(destinationLocal != nil)
                    if let destinationLocal {
                        try writeCount(destinationLocal, maximum: GoExecutableImage.maximumLocals)
                    }
                    writeBoolean(okLocal != nil)
                    if let okLocal {
                        try writeCount(okLocal, maximum: GoExecutableImage.maximumLocals)
                    }
                    try writeCount(zeroLocal, maximum: GoExecutableImage.maximumLocals)
                    try writeCount(target, maximum: GoExecutableImage.maximumInstructions)
                }
            }
            writeBoolean(defaultTarget != nil)
            if let defaultTarget {
                try writeCount(defaultTarget, maximum: GoExecutableImage.maximumInstructions)
            }
        case .timeAfter:
            writeByte(67)
        case .timeSleep:
            writeByte(75)
        case .timeTick:
            writeByte(76)
        case .contextBackground:
            writeByte(77)
        case .contextWithCancel:
            writeByte(78)
        case .contextWithTimeout:
            writeByte(79)
        case .contextDone:
            writeByte(80)
        case .contextErr:
            writeByte(81)
        case .cancelContext:
            writeByte(82)
        case .netDial:
            writeByte(83)
        case .netListen:
            writeByte(84)
        case .netAccept:
            writeByte(85)
        case .netRead:
            writeByte(86)
        case .netWrite:
            writeByte(87)
        case .netClose:
            writeByte(88)
        case .netLookupHost:
            writeByte(89)
        case .httpHandleFunc(let handler):
            writeByte(90)
            try write(handler, maximumBytes: GoExecutableImage.maximumStringBytes)
        case .httpListenAndServe:
            writeByte(91)
        case .httpGet:
            writeByte(92)
        case .osArgs:
            writeByte(93)
        case .exit:
            writeByte(94)
        case .parseInt:
            writeByte(95)
        case .readInput:
            writeByte(96)
        case .makeMutex:
            writeByte(68)
        case .mutexLock:
            writeByte(69)
        case .mutexUnlock:
            writeByte(70)
        case .makeWaitGroup:
            writeByte(71)
        case .waitGroupAdd:
            writeByte(72)
        case .waitGroupWait:
            writeByte(73)
        case .garbageCollect:
            writeByte(74)
        }
    }
}

private struct ImageReader {
    let bytes: [UInt8]
    var offset = 0

    var isAtEnd: Bool { offset == bytes.count }

    mutating func readByte() throws -> UInt8 {
        guard bytes.indices.contains(offset) else {
            throw GoExecutableImageError.truncated
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= bytes.count - count else {
            throw GoExecutableImageError.truncated
        }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func readUInt16() throws -> UInt16 {
        UInt16(try readByte()) | (UInt16(try readByte()) << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, through: 24, by: 8) {
            value |= UInt32(try readByte()) << UInt32(shift)
        }
        return value
    }

    mutating func readInt64() throws -> Int64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 56, by: 8) {
            value |= UInt64(try readByte()) << UInt64(shift)
        }
        return Int64(bitPattern: value)
    }

    mutating func readCount(maximum: Int) throws -> Int {
        let value = try readUInt32()
        guard value <= UInt32(maximum) else {
            throw GoExecutableImageError.invalidCount
        }
        return Int(value)
    }

    mutating func readBoolean() throws -> Bool {
        let value = try readByte()
        switch value {
        case 0: return false
        case 1: return true
        default: throw GoExecutableImageError.invalidBoolean(value)
        }
    }

    mutating func readString(maximumBytes: Int) throws -> String {
        let count = try readCount(maximum: maximumBytes)
        let encoded = try readBytes(count: count)
        let decoded = String(decoding: encoded, as: UTF8.self)
        guard Array(decoded.utf8) == encoded else {
            throw GoExecutableImageError.invalidUTF8
        }
        return decoded
    }

    mutating func readInstruction() throws -> GoInstruction {
        let opcode = try readByte()
        switch opcode {
        case 0:
            let tag = try readByte()
            switch tag {
            case 0: return .push(.int(try readInt64()))
            case 1:
                return .push(
                    .string(
                        try readString(
                            maximumBytes: GoExecutableImage.maximumStringBytes)))
            case 2: return .push(.bool(try readBoolean()))
            case 3: return .push(.nilValue)
            default: throw GoExecutableImageError.invalidValueTag(tag)
            }
        case 1: return .load(try readCount(maximum: GoExecutableImage.maximumLocals))
        case 2: return .store(try readCount(maximum: GoExecutableImage.maximumLocals))
        case 3: return .negate
        case 4: return .not
        case 5: return .add
        case 6: return .subtract
        case 7: return .multiply
        case 8: return .divide
        case 9: return .remainder
        case 10: return .equal
        case 11: return .notEqual
        case 12: return .less
        case 13: return .lessEqual
        case 14: return .greater
        case 15: return .greaterEqual
        case 16: return .logicalAnd
        case 17: return .logicalOr
        case 18:
            return .print(
                argumentCount: try readCount(maximum: GoExecutableImage.maximumLocals),
                newline: try readBoolean())
        case 19:
            return .jump(try readCount(maximum: GoExecutableImage.maximumInstructions))
        case 20:
            return .jumpIfFalse(
                try readCount(maximum: GoExecutableImage.maximumInstructions))
        case 21:
            return .jumpIfTrue(
                try readCount(maximum: GoExecutableImage.maximumInstructions))
        case 22:
            return .call(
                try readString(maximumBytes: GoExecutableImage.maximumStringBytes),
                argumentCount: try readCount(maximum: GoExecutableImage.maximumLocals))
        case 23: return .return
        case 24: return .returnValues(count: try readCount(maximum: GoExecutableImage.maximumLocals))
        case 25:
            let hasTypeName = try readBoolean()
            let typeName =
                hasTypeName
                ? try readString(maximumBytes: GoExecutableImage.maximumStringBytes)
                : nil
            let fieldCount = try readCount(maximum: GoExecutableImage.maximumLocals)
            var fieldNames: [String] = []
            fieldNames.reserveCapacity(fieldCount)
            for _ in 0..<fieldCount {
                fieldNames.append(
                    try readString(maximumBytes: GoExecutableImage.maximumStringBytes))
            }
            return .makeStruct(typeName: typeName, fieldNames: fieldNames)
        case 26:
            return .getField(
                try readString(maximumBytes: GoExecutableImage.maximumStringBytes))
        case 27:
            return .setField(
                try readString(maximumBytes: GoExecutableImage.maximumStringBytes))
        case 28:
            let index = try readCount(maximum: GoExecutableImage.maximumLocals)
            let pathCount = try readCount(maximum: GoExecutableImage.maximumLocals)
            var fieldPath: [String] = []
            fieldPath.reserveCapacity(pathCount)
            for _ in 0..<pathCount {
                fieldPath.append(
                    try readString(maximumBytes: GoExecutableImage.maximumStringBytes))
            }
            return .addressLocal(index: index, fieldPath: fieldPath)
        case 29: return .dereference
        case 30: return .setPointer
        case 31:
            return .fieldAddress(
                try readString(maximumBytes: GoExecutableImage.maximumStringBytes))
        case 32:
            return .makeArray(
                elementCount: try readCount(maximum: GoExecutableImage.maximumLocals))
        case 33:
            return .makeSlice(
                elementCount: try readCount(maximum: GoExecutableImage.maximumLocals))
        case 34: return .allocateSlice
        case 35: return .getIndex
        case 36: return .setIndex
        case 37: return .slice
        case 38: return .sliceArray
        case 39: return .length
        case 40: return .capacity
        case 41: return .append
        case 42: return .indexAddress
        case 43: return .loadGlobal(try readCount(maximum: GoExecutableImage.maximumLocals))
        case 44: return .storeGlobal(try readCount(maximum: GoExecutableImage.maximumLocals))
        case 45: return .addressGlobal(try readCount(maximum: GoExecutableImage.maximumLocals))
        case 46:
            return .deferCall(
                try readString(maximumBytes: GoExecutableImage.maximumStringBytes),
                argumentCount: try readCount(maximum: GoExecutableImage.maximumLocals))
        case 47: return .panic
        case 48: return .makeMap(entryCount: try readCount(maximum: GoExecutableImage.maximumLocals))
        case 49: return .getMapIndex(commaOK: try readBoolean())
        case 50: return .setMapIndex
        case 51: return .deleteMap
        case 52:
            return .callInterface(
                try readString(maximumBytes: GoExecutableImage.maximumStringBytes),
                argumentCount: try readCount(maximum: GoExecutableImage.maximumLocals))
        case 53:
            return .makeInterface(
                typeName: try readString(maximumBytes: GoExecutableImage.maximumStringBytes))
        case 54: return .rangeKeys
        case 55: return .rangeValue
        case 56: return .recover
        case 57:
            return .typeAssert(
                typeName: try readString(maximumBytes: GoExecutableImage.maximumStringBytes),
                commaOK: try readBoolean())
        case 58:
            return .testFail(
                argumentCount: try readCount(maximum: GoExecutableImage.maximumLocals),
                fatal: try readBoolean())
        case 59:
            return .testBegin(
                try readString(maximumBytes: GoExecutableImage.maximumStringBytes))
        case 60:
            return .testEnd(
                try readString(maximumBytes: GoExecutableImage.maximumStringBytes))
        case 61:
            return .spawn(
                try readString(maximumBytes: GoExecutableImage.maximumStringBytes),
                argumentCount: try readCount(maximum: GoExecutableImage.maximumLocals))
        case 62: return .makeChannel
        case 63: return .sendChannel
        case 64: return .receiveChannel(commaOK: try readBoolean())
        case 65: return .closeChannel
        case 66:
            let caseCount = try readCount(maximum: GoExecutableImage.maximumInstructions)
            var cases: [GoSelectCaseInstruction] = []
            cases.reserveCapacity(caseCount)
            for _ in 0..<caseCount {
                switch try readByte() {
                case 0:
                    cases.append(.send(
                        channelLocal: try readCount(maximum: GoExecutableImage.maximumLocals),
                        valueLocal: try readCount(maximum: GoExecutableImage.maximumLocals),
                        target: try readCount(maximum: GoExecutableImage.maximumInstructions)))
                case 1:
                    let channelLocal = try readCount(maximum: GoExecutableImage.maximumLocals)
                    let destinationLocal = try readBoolean()
                        ? try readCount(maximum: GoExecutableImage.maximumLocals) : nil
                    let okLocal = try readBoolean()
                        ? try readCount(maximum: GoExecutableImage.maximumLocals) : nil
                    let zeroLocal = try readCount(maximum: GoExecutableImage.maximumLocals)
                    let target = try readCount(maximum: GoExecutableImage.maximumInstructions)
                    cases.append(.receive(
                        channelLocal: channelLocal,
                        destinationLocal: destinationLocal,
                        okLocal: okLocal,
                        zeroLocal: zeroLocal,
                        target: target))
                case let tag:
                    throw GoExecutableImageError.invalidValueTag(tag)
                }
            }
            let defaultTarget = try readBoolean()
                ? try readCount(maximum: GoExecutableImage.maximumInstructions) : nil
            return .select(cases: cases, defaultTarget: defaultTarget)
        case 67: return .timeAfter
        case 68: return .makeMutex
        case 69: return .mutexLock
        case 70: return .mutexUnlock
        case 71: return .makeWaitGroup
        case 72: return .waitGroupAdd
        case 73: return .waitGroupWait
        case 74: return .garbageCollect
        case 75: return .timeSleep
        case 76: return .timeTick
        case 77: return .contextBackground
        case 78: return .contextWithCancel
        case 79: return .contextWithTimeout
        case 80: return .contextDone
        case 81: return .contextErr
        case 82: return .cancelContext
        case 83: return .netDial
        case 84: return .netListen
        case 85: return .netAccept
        case 86: return .netRead
        case 87: return .netWrite
        case 88: return .netClose
        case 89: return .netLookupHost
        case 90:
            let handler = try readString(maximumBytes: GoExecutableImage.maximumStringBytes)
            return .httpHandleFunc(handler)
        case 91: return .httpListenAndServe
        case 92: return .httpGet
        case 93: return .osArgs
        case 94: return .exit
        case 95: return .parseInt
        case 96: return .readInput
        default: throw GoExecutableImageError.invalidOpcode(opcode)
        }
    }
}
