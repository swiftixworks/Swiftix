/// `json.Marshal`'s walk over a value: Go's `encodeState` and the encoder
/// of each kind, with the work that Go's encoders do by recursion kept on a
/// stack of tasks instead, so that a value nested ten thousand deep costs no
/// Swift stack. Where Go calls a method of the program (`MarshalJSON`,
/// `MarshalText`, `IsZero`), the walk stops and says which, with the value
/// boxed for the call; the library's text calls it and hands back what it
/// returned, and the walk goes on. Pure value types over the heap access it
/// is given; no executor state.

/// What a walk over the guest heap may do, which the VM gives it.
struct GoJSONHeap {
    let read: (GoPointer) throws -> GoValue
    let write: (GoValue, GoPointer) throws -> Void
    let allocate: (GoValue) throws -> Int
    let descriptor: (String) -> GoTypeDescriptor?
    /// Whether the program has the method `name` with a receiver `owner`
    /// (`T` or `*T` as the VM names types) taking `parameters` arguments
    /// besides it.
    let method: (_ owner: String, _ name: String, _ parameters: Int) -> Bool
}

/// The codes the walks stop with, as the library's text numbers them.
enum GoJSONCode {
    static let encodeDone = 0
    static let encodeUnsupportedType = 1
    static let encodeUnsupportedValue = 2
    static let encodeFailed = 3
    static let encodeMarshalerSyntax = 4
    static let encodeMarshalerFailed = 5
    static let encodeCallMarshalJSON = 6
    static let encodeCallMarshalText = 7
    static let encodeCallKeyText = 8
    static let encodeCallIsZero = 9

    static let decodeDone = 0
    static let decodeSyntax = 1
    static let decodeInvalid = 2
    static let decodeType = 3
    static let decodeFailed = 4
    static let decodeCorrupt = 5
    static let decodeCallUnmarshalJSON = 6
    static let decodeCallUnmarshalText = 7
}

/// Where a walk stopped: done, failed, or waiting for a method's result.
struct GoJSONStop {
    let code: Int
    var value: GoValue = .nilValue
    var text: String = ""
}

/// How a value of one type is written: Go's `newTypeEncoder` choice of a
/// method before the kind.
private enum GoJSONMethodUse {
    case none, marshalJSON, addressMarshalJSON, marshalText, addressMarshalText
}

final class GoJSONEncoder {
    private(set) var output: [UInt8] = []
    private var types = GoJSONTypes()
    private let escapeHTML: Bool
    private var tasks: [Task] = []
    private var pointerLevel = 0
    private var pointersSeen: Set<String> = []
    private var awaiting: Awaiting?
    /// The message and offset of the error of a `MarshalerError`.
    private(set) var failure: (message: String, offset: Int64) = ("", 0)

    /// Go's `startDetectingCyclesAfter`.
    static let cycleDepth = 1_000

    private enum Task {
        case value(GoValue, GoRuntimeType?, quoted: Bool, address: GoPointer?)
        case bytes([UInt8])
        case leave(String?)
        case fields(FieldsState)
        case elements(ElementsState)
        case keys(MapState)
    }

    private struct FieldsState {
        let value: GoValue
        let type: GoRuntimeType
        let address: GoPointer?
        let fields: [GoJSONField]
        var next: Int
        var wroteField: Bool
        /// The value of the field `next` while its `IsZero` is asked.
        var current: (value: GoValue, address: GoPointer?)?
    }

    private struct ElementsState {
        let elements: ArraySlice<GoValue>
        let type: GoRuntimeType
        let base: GoPointer?
        let firstIndex: Int
        var next: Int
    }

    private struct MapState {
        let entries: [(key: GoValue, value: GoValue)]
        let keyType: GoRuntimeType
        let valueType: GoRuntimeType
        let mapType: GoRuntimeType
        var keys: [[UInt8]]
        let leaveKey: String?
    }

    private enum Awaiting {
        case marshalJSON(typeName: String)
        case marshalText
        case key(MapState)
        case isZero(FieldsState)
    }

    init(value: GoValue, escapeHTML: Bool) {
        self.escapeHTML = escapeHTML
        tasks = [.value(value, nil, quoted: false, address: nil)]
    }

    /// The values the walk still holds, which must stay alive while a
    /// method of the program runs.
    var heldValues: [GoValue] {
        var values: [GoValue] = []
        for task in tasks {
            switch task {
            case .value(let value, _, _, _): values.append(value)
            case .fields(let state): values.append(state.value)
            case .elements(let state): values.append(contentsOf: state.elements)
            case .keys(let state): for entry in state.entries { values += [entry.key, entry.value] }
            default: break
            }
        }
        if case .key(let state)? = awaiting {
            for entry in state.entries { values += [entry.key, entry.value] }
        }
        if case .isZero(let state)? = awaiting { values.append(state.value) }
        return values
    }

    // MARK: Resuming

    /// What the method the walk stopped for returned: the text of a
    /// `MarshalJSON` or `MarshalText`, or for `IsZero` nil when it said true.
    func resume(_ result: [UInt8]?) {
        guard let awaiting else { return }
        self.awaiting = nil
        switch awaiting {
        case .marshalJSON(let typeName):
            let (compacted, error) = GoJSONText.compact(output, result ?? [], escape: escapeHTML)
            if let error {
                failure = error
                tasks.append(.bytes([]))
                pendingStop = GoJSONStop(code: GoJSONCode.encodeMarshalerSyntax, text: typeName)
                return
            }
            output = compacted
        case .marshalText:
            GoJSONText.appendString(&output, result ?? [], escapeHTML: escapeHTML)
        case .key(var state):
            state.keys.append(result ?? [])
            tasks.append(.keys(state))
        case .isZero(var state):
            let (value, address) = state.current!
            state.current = nil
            if result == nil {
                state.next += 1
                tasks.append(.fields(state))
            } else {
                emitField(&state, value: value, address: address)
            }
        }
    }

    private var pendingStop: GoJSONStop?

    // MARK: Running

    /// Walks until the text is written, the walk fails, or a method of the
    /// program must be called.
    func run(_ heap: GoJSONHeap) throws -> GoJSONStop {
        if let stop = pendingStop {
            pendingStop = nil
            return stop
        }
        while let task = tasks.popLast() {
            switch task {
            case .bytes(let bytes):
                output += bytes
            case .leave(let key):
                pointerLevel -= 1
                if let key { pointersSeen.remove(key) }
            case .value(let value, let type, let quoted, let address):
                if let stop = try encode(value, type, quoted: quoted, address: address, heap) {
                    return stop
                }
            case .fields(var state):
                if let stop = try nextField(&state, heap) { return stop }
            case .elements(var state):
                guard state.next < state.elements.count else {
                    output.append(UInt8(ascii: "]"))
                    continue
                }
                if state.next > 0 { output.append(UInt8(ascii: ",")) }
                let index = state.next
                let element = state.elements[state.elements.startIndex + index]
                state.next += 1
                tasks.append(.elements(state))
                tasks.append(
                    .value(
                        element, state.type, quoted: false,
                        address: state.base.map {
                            GoPointer(cell: $0.cell, path: $0.path + [.index(state.firstIndex + index)])
                        }))
            case .keys(var state):
                if let stop = try nextKey(&state, heap) { return stop }
            }
        }
        return GoJSONStop(code: GoJSONCode.encodeDone)
    }

    // MARK: One value

    private func dynamic(_ value: GoValue) -> (GoValue, GoRuntimeType?) {
        switch value {
        case .interface(let boxed):
            if let descriptor = GoTypeDescriptor(typeName: boxed.typeName) {
                types.adopt(descriptor)
                return (boxed.value, descriptor.type)
            }
            if boxed.typeName == "error" { return (boxed.value, .other("error")) }
            return (boxed.value, GoTypeDescriptor.dynamicType(named: boxed.typeName))
        case .int: return (value, .integer)
        case .string: return (value, .string)
        case .bool: return (value, .boolean)
        case .structure(let structure): return (value, structure.typeName.map { .named($0) })
        default: return (value, nil)
        }
    }

    private func owner(_ type: GoRuntimeType) -> String? {
        switch type {
        case .named(let symbol): return symbol
        case .pointer(.named(let symbol)): return "*" + symbol
        default: return nil
        }
    }

    /// Whether `type` itself has the method (a pointer has its pointee's).
    private func implements(_ type: GoRuntimeType, _ name: String, _ heap: GoJSONHeap) -> Bool {
        switch type {
        case .named(let symbol): return heap.method(symbol, name, 0)
        case .pointer(.named(let symbol)):
            return heap.method("*" + symbol, name, 0) || heap.method(symbol, name, 0)
        default: return false
        }
    }

    private func methodUse(_ type: GoRuntimeType, _ heap: GoJSONHeap) -> GoJSONMethodUse {
        if case .named(let symbol) = type {
            if symbol == GoJSONTypes.rawMessage || symbol == GoJSONTypes.number { return .none }
            if heap.method("*" + symbol, "MarshalJSON", 0) { return .addressMarshalJSON }
            if heap.method(symbol, "MarshalJSON", 0) { return .marshalJSON }
            if heap.method("*" + symbol, "MarshalText", 0) { return .addressMarshalText }
            if heap.method(symbol, "MarshalText", 0) { return .marshalText }
            return .none
        }
        if case .pointer(.named(let symbol)) = type {
            if symbol == GoJSONTypes.rawMessage || symbol == GoJSONTypes.number { return .none }
            if implements(type, "MarshalJSON", heap) { return .marshalJSON }
            if implements(type, "MarshalText", heap) { return .marshalText }
        }
        return .none
    }

    private func typeName(_ type: GoRuntimeType) -> String { GoTypeDescriptor.name(of: type) }

    private func isInterface(_ type: GoRuntimeType) -> Bool {
        if case .interface = types.kind(type) { return true }
        return false
    }

    private func boxed(_ value: GoValue, _ type: GoRuntimeType) -> GoValue {
        .interface(
            GoInterfaceValue(
                typeName: GoJSONDescriptor.typeName(type, definitions: types.definitions), value: value))
    }

    private func encode(
        _ value: GoValue, _ declared: GoRuntimeType?, quoted: Bool, address: GoPointer?,
        _ heap: GoJSONHeap
    ) throws -> GoJSONStop? {
        var value = value
        var type = declared
        if type == nil || isInterface(type!) {
            if value == .nilValue {
                output += Array("null".utf8)
                return nil
            }
            (value, type) = dynamic(value)
            guard let found = type else {
                output += Array("null".utf8)
                return nil
            }
            type = found
            if isInterface(found) {
                tasks.append(.value(value, nil, quoted: quoted, address: nil))
                return nil
            }
            return try encode(value, found, quoted: quoted, address: nil, heap)
        }
        let type_ = type!
        // A method of the program, before the kind.
        switch methodUse(type_, heap) {
        case .addressMarshalJSON where address != nil, .addressMarshalText where address != nil:
            let pointerType = GoRuntimeType.pointer(type_)
            let isJSON = methodUse(type_, heap) == .addressMarshalJSON
            awaiting = isJSON ? .marshalJSON(typeName: typeName(type_)) : .marshalText
            return GoJSONStop(
                code: isJSON ? GoJSONCode.encodeCallMarshalJSON : GoJSONCode.encodeCallMarshalText,
                value: boxed(.pointer(address!), pointerType), text: typeName(type_))
        case .addressMarshalJSON, .addressMarshalText:
            // Not addressable: the value's own methods, if any.
            if heap.method(GoJSONDescriptorOwner.symbol(type_), "MarshalJSON", 0) {
                return callMarshalJSON(value, type_)
            }
            if heap.method(GoJSONDescriptorOwner.symbol(type_), "MarshalText", 0) {
                return callMarshalText(value, type_)
            }
        case .marshalJSON:
            if value == .nilValue, case .pointer = type_ {
                output += Array("null".utf8)
                return nil
            }
            return callMarshalJSON(value, type_)
        case .marshalText:
            if value == .nilValue, case .pointer = type_ {
                output += Array("null".utf8)
                return nil
            }
            return callMarshalText(value, type_)
        case .none:
            break
        }
        return try encodeKind(value, type_, quoted: quoted, address: address, heap)
    }

    private func callMarshalJSON(_ value: GoValue, _ type: GoRuntimeType) -> GoJSONStop {
        awaiting = .marshalJSON(typeName: typeName(type))
        return GoJSONStop(
            code: GoJSONCode.encodeCallMarshalJSON, value: boxed(value, type), text: typeName(type))
    }

    private func callMarshalText(_ value: GoValue, _ type: GoRuntimeType) -> GoJSONStop {
        awaiting = .marshalText
        return GoJSONStop(
            code: GoJSONCode.encodeCallMarshalText, value: boxed(value, type), text: typeName(type))
    }

    private func unsupported(_ type: GoRuntimeType) -> GoJSONStop {
        GoJSONStop(code: GoJSONCode.encodeUnsupportedType, text: typeName(type))
    }

    private func appendQuoted(_ bytes: [UInt8], _ quoted: Bool) {
        if quoted { output.append(0x22) }
        output += bytes
        if quoted { output.append(0x22) }
    }

    /// Go's cycle check, past the depth where it starts: nil, or the error.
    private func enter(_ key: @autoclosure () -> String, _ type: GoRuntimeType) -> (GoJSONStop?, String?) {
        pointerLevel += 1
        guard pointerLevel > Self.cycleDepth else { return (nil, nil) }
        let identity = key()
        if pointersSeen.contains(identity) {
            return (
                GoJSONStop(
                    code: GoJSONCode.encodeUnsupportedValue,
                    text: "encountered a cycle via " + typeName(type)), nil
            )
        }
        pointersSeen.insert(identity)
        return (nil, identity)
    }

    private func encodeKind(
        _ value: GoValue, _ type: GoRuntimeType, quoted: Bool, address: GoPointer?,
        _ heap: GoJSONHeap
    ) throws -> GoJSONStop? {
        if case .named(let symbol) = type, symbol == GoJSONTypes.rawMessage {
            return marshalRaw(value, type, heap)
        }
        if case .named(let symbol) = type, symbol == GoJSONTypes.number {
            guard case .string(var number) = value else { throw GoRuntimeError.typeMismatch }
            if number.isEmpty { number = "0" }
            guard GoJSONText.isValidNumber(Array(number.utf8)) else {
                return GoJSONStop(
                    code: GoJSONCode.encodeFailed,
                    text: "json: invalid number literal " + GoFormat.quote(number, asciiOnly: false))
            }
            appendQuoted(Array(number.utf8), quoted)
            return nil
        }
        switch types.kind(type) {
        case .bool:
            guard case .bool(let flag) = value else { throw GoRuntimeError.typeMismatch }
            appendQuoted(Array((flag ? "true" : "false").utf8), quoted)
        case .signed(let bits):
            guard case .int(let integer) = value else { throw GoRuntimeError.typeMismatch }
            let truncated: Int64
            switch bits {
            case 8: truncated = Int64(Int8(truncatingIfNeeded: integer))
            case 16: truncated = Int64(Int16(truncatingIfNeeded: integer))
            case 32: truncated = Int64(Int32(truncatingIfNeeded: integer))
            default: truncated = integer
            }
            appendQuoted(Array(String(truncated).utf8), quoted)
        case .unsigned(let bits):
            guard case .int(let integer) = value else { throw GoRuntimeError.typeMismatch }
            var unsigned = UInt64(bitPattern: integer)
            if bits < 64 { unsigned &= (UInt64(1) << UInt64(bits)) - 1 }
            appendQuoted(Array(String(unsigned).utf8), quoted)
        case .float(let bits):
            guard case .int(let pattern) = value else { throw GoRuntimeError.typeMismatch }
            let number = Double(bitPattern: UInt64(bitPattern: pattern))
            if number.isNaN || number.isInfinite {
                return GoJSONStop(
                    code: GoJSONCode.encodeUnsupportedValue,
                    text: GoFloat.format(number, format: UInt8(ascii: "g"), precision: -1, bitSize: bits))
            }
            appendQuoted(Self.float(number, bits: bits), quoted)
        case .string:
            guard case .string(let text) = value else { throw GoRuntimeError.typeMismatch }
            if quoted {
                var inner: [UInt8] = []
                GoJSONText.appendString(&inner, text.utf8, escapeHTML: escapeHTML)
                GoJSONText.appendString(&output, inner, escapeHTML: false)
            } else {
                GoJSONText.appendString(&output, text.utf8, escapeHTML: escapeHTML)
            }
        case .time:
            guard let time = GoTime(value) else { throw GoRuntimeError.typeMismatch }
            if let failure = GoTimeFormat.strictRFC3339Failure(time) {
                self.failure = ("Time.MarshalJSON: " + failure, 0)
                return GoJSONStop(code: GoJSONCode.encodeMarshalerFailed, text: "time.Time")
            }
            output.append(0x22)
            output += GoTimeFormat.format(time, layout: GoTimeFormat.rfc3339Nano)
            output.append(0x22)
        case .interface:
            tasks.append(.value(value, nil, quoted: quoted, address: nil))
        case .pointer:
            guard case .pointer(let pointee) = types.underlying(type) else { throw GoRuntimeError.typeMismatch }
            guard case .pointer(let pointer) = value else {
                output += Array("null".utf8)
                return nil
            }
            let (stop, key) = enter("\(pointer.cell):\(pointer.path)", type)
            if let stop { return stop }
            tasks.append(.leave(key))
            tasks.append(.value(try heap.read(pointer), pointee, quoted: quoted, address: pointer))
        case .structure:
            output.append(UInt8(ascii: "{"))
            tasks.append(
                .fields(
                    FieldsState(
                        value: value, type: type, address: address, fields: types.fields(of: type),
                        next: 0, wroteField: false)))
        case .slice:
            guard case .slice(let element) = types.underlying(type) else { throw GoRuntimeError.typeMismatch }
            guard case .slice(let slice) = value else {
                output += Array("null".utf8)
                return nil
            }
            guard case .array(let backing) = try heap.read(slice.backing),
                slice.start >= 0, slice.start + slice.length <= backing.count
            else { throw GoRuntimeError.typeMismatch }
            let elements = backing[slice.start..<(slice.start + slice.length)]
            if types.underlying(element) == .byte, methodUse(.pointer(element), heap) == .none,
                !isMarshalerElement(element, heap)
            {
                let bytes = try elements.map { element -> UInt8 in
                    guard case .int(let byte) = element else { throw GoRuntimeError.typeMismatch }
                    return UInt8(truncatingIfNeeded: byte)
                }
                output.append(0x22)
                output += GoJSONText.base64(bytes)
                output.append(0x22)
                return nil
            }
            let (stop, key) = enter("\(slice.backing.cell):\(slice.backing.path):\(slice.start):\(slice.length)", type)
            if let stop { return stop }
            output.append(UInt8(ascii: "["))
            tasks.append(.leave(key))
            tasks.append(
                .elements(
                    ElementsState(
                        elements: elements, type: element, base: slice.backing, firstIndex: slice.start,
                        next: 0)))
        case .array:
            guard case .array(_, let element) = types.underlying(type), case .array(let elements) = value
            else { throw GoRuntimeError.typeMismatch }
            output.append(UInt8(ascii: "["))
            tasks.append(
                .elements(
                    ElementsState(
                        elements: elements[...], type: element, base: address, firstIndex: 0, next: 0)))
        case .map:
            guard case .map(let keyType, let valueType) = types.underlying(type) else {
                throw GoRuntimeError.typeMismatch
            }
            switch types.kind(keyType) {
            case .string, .signed, .unsigned: break
            default:
                if !keyHasText(keyType, heap) { return unsupported(type) }
            }
            guard case .map(let map) = value else {
                output += Array("null".utf8)
                return nil
            }
            guard case .mapStorage(let storage) = try heap.read(map.storage) else {
                throw GoRuntimeError.typeMismatch
            }
            let (stop, key) = enter("\(map.storage.cell):\(map.storage.path)", type)
            if let stop { return stop }
            output.append(UInt8(ascii: "{"))
            tasks.append(
                .keys(
                    MapState(
                        entries: storage.entries, keyType: keyType, valueType: valueType, mapType: type,
                        keys: [], leaveKey: key)))
        case .other:
            if case .other(let name) = types.underlying(type), !name.hasPrefix("func"), name != "error" {
                output += Array("{}".utf8)
                return nil
            }
            if case .other("error") = type {
                output += Array("{}".utf8)
                return nil
            }
            return unsupported(type)
        }
        return nil
    }

    /// Whether the element type of a byte slice has a method that makes Go
    /// encode the slice as an array.
    private func isMarshalerElement(_ element: GoRuntimeType, _ heap: GoJSONHeap) -> Bool {
        implements(.pointer(element), "MarshalJSON", heap) || implements(.pointer(element), "MarshalText", heap)
    }

    /// Whether a map key of `type` is written by its `MarshalText`.
    private func keyHasText(_ type: GoRuntimeType, _ heap: GoJSONHeap) -> Bool {
        if case .other(GoJSONTypes.time) = type { return true }
        return implements(type, "MarshalText", heap)
    }

    /// `json.RawMessage`, whose `MarshalJSON` returns it, compacted.
    private func marshalRaw(_ value: GoValue, _ type: GoRuntimeType, _ heap: GoJSONHeap) -> GoJSONStop? {
        guard case .slice(let slice) = value,
            case .array(let backing)? = try? heap.read(slice.backing),
            slice.start + slice.length <= backing.count
        else {
            output += Array("null".utf8)
            return nil
        }
        let bytes = backing[slice.start..<(slice.start + slice.length)].map {
            guard case .int(let byte) = $0 else { return UInt8(0) }
            return UInt8(truncatingIfNeeded: byte)
        }
        let (compacted, error) = GoJSONText.compact(output, bytes, escape: escapeHTML)
        if let error {
            failure = error
            return GoJSONStop(code: GoJSONCode.encodeMarshalerSyntax, text: typeName(type))
        }
        output = compacted
        return nil
    }

    // MARK: Structs

    private func nextField(_ state: inout FieldsState, _ heap: GoJSONHeap) throws -> GoJSONStop? {
        while state.next < state.fields.count {
            let field = state.fields[state.next]
            guard let (value, address) = try fieldValue(field, of: state, heap) else {
                state.next += 1
                continue
            }
            if field.omitEmpty, try isEmpty(value, field.type, heap) {
                state.next += 1
                continue
            }
            if field.omitZero {
                if let stop = isZeroCall(value, field.type, address: address, heap) {
                    state.current = (value, address)
                    awaiting = .isZero(state)
                    return stop
                }
                if try isZero(value, field.type, heap) {
                    state.next += 1
                    continue
                }
            }
            emitField(&state, value: value, address: address)
            return nil
        }
        output.append(UInt8(ascii: "}"))
        return nil
    }

    private func emitField(_ state: inout FieldsState, value: GoValue, address: GoPointer?) {
        let field = state.fields[state.next]
        if state.wroteField { output.append(UInt8(ascii: ",")) }
        state.wroteField = true
        output.append(0x22)
        if escapeHTML {
            for c in field.nameBytes {
                if c == UInt8(ascii: "<") || c == UInt8(ascii: ">") || c == UInt8(ascii: "&") {
                    output += [0x5C, 0x75, 0x30, 0x30, GoJSONText.hex[Int(c >> 4)], GoJSONText.hex[Int(c & 0xF)]]
                } else {
                    output.append(c)
                }
            }
        } else {
            output += field.nameBytes
        }
        output += [0x22, UInt8(ascii: ":")]
        state.next += 1
        tasks.append(.fields(state))
        tasks.append(.value(value, field.type, quoted: field.quoted, address: address))
    }

    /// The value of `field` in the struct, and where it is; nil when an
    /// embedded pointer on the way is nil.
    private func fieldValue(
        _ field: GoJSONField, of state: FieldsState, _ heap: GoJSONHeap
    ) throws -> (GoValue, GoPointer?)? {
        var value = state.value
        var type = state.type
        var address = state.address
        for (level, position) in field.index.enumerated() {
            if case .pointer(let pointee) = types.underlying(type) {
                guard case .pointer(let pointer) = value else { return nil }
                value = try heap.read(pointer)
                address = pointer
                type = pointee
            }
            guard case .structure(let declared) = types.underlying(type),
                case .structure(let structure) = value, position < declared.count
            else { throw GoRuntimeError.typeMismatch }
            let name = field.goNames[level]
            let stored: GoStructFieldValue
            if position < structure.fields.count, structure.fields[position].name == name {
                stored = structure.fields[position]
            } else if let found = structure.fields.first(where: { $0.name == name }) {
                stored = found
            } else {
                throw GoRuntimeError.unknownField(name)
            }
            value = stored.value
            type = declared[position].type
            address = address.map { GoPointer(cell: $0.cell, path: $0.path + [.field(name)]) }
        }
        return (value, address)
    }

    /// Go's `isEmptyValue`.
    private func isEmpty(_ value: GoValue, _ type: GoRuntimeType, _ heap: GoJSONHeap) throws -> Bool {
        switch types.kind(type) {
        case .string:
            if case .string(let text) = value { return text.isEmpty }
            return false
        case .slice:
            if case .slice(let slice) = value { return slice.length == 0 }
            return true
        case .array:
            if case .array(let elements) = value { return elements.isEmpty }
            return false
        case .map:
            guard case .map(let map) = value else { return true }
            if case .mapStorage(let storage) = try heap.read(map.storage) { return storage.count == 0 }
            return false
        case .bool: return value == .bool(false)
        case .signed, .unsigned: return value == .int(0)
        case .float: return Self.isFloatZero(value)
        case .interface, .pointer: return value == .nilValue
        default: return false
        }
    }

    /// Go's `reflect.Value.IsZero`.
    private func isZero(_ value: GoValue, _ type: GoRuntimeType, _ heap: GoJSONHeap) throws -> Bool {
        switch types.kind(type) {
        case .string: return value == .string("")
        case .bool: return value == .bool(false)
        case .signed, .unsigned: return value == .int(0)
        case .float: return Self.isFloatZero(value)
        case .time: return GoTime(value) == .zero
        case .array:
            guard case .array(let elements) = value, case .array(_, let element) = types.underlying(type)
            else { return false }
            for item in elements where !(try isZero(item, element, heap)) { return false }
            return true
        case .structure:
            guard case .structure(let declared) = types.underlying(type),
                case .structure(let structure) = value
            else { return false }
            for (index, field) in declared.enumerated() where index < structure.fields.count {
                if !(try isZero(structure.fields[index].value, field.type, heap)) { return false }
            }
            return true
        default: return value == .nilValue
        }
    }

    /// A call of the `IsZero` method `omitzero` asks for, if the type has
    /// one: Go's choice of `field.isZero`.
    private func isZeroCall(
        _ value: GoValue, _ type: GoRuntimeType, address: GoPointer?, _ heap: GoJSONHeap
    ) -> GoJSONStop? {
        guard case .named(let symbol) = type else {
            if case .pointer(.named) = type, implements(type, "IsZero", heap) {
                if value == .nilValue { return nil }
                return GoJSONStop(code: GoJSONCode.encodeCallIsZero, value: boxed(value, type))
            }
            return nil
        }
        if heap.method(symbol, "IsZero", 0) {
            return GoJSONStop(code: GoJSONCode.encodeCallIsZero, value: boxed(value, type))
        }
        if heap.method("*" + symbol, "IsZero", 0) {
            let pointer: GoPointer
            if let address {
                pointer = address
            } else if let cell = try? heap.allocate(value) {
                pointer = GoPointer(cell: cell)
            } else {
                return nil
            }
            return GoJSONStop(code: GoJSONCode.encodeCallIsZero, value: boxed(.pointer(pointer), .pointer(type)))
        }
        return nil
    }

    // MARK: Maps

    private func nextKey(_ state: inout MapState, _ heap: GoJSONHeap) throws -> GoJSONStop? {
        while state.keys.count < state.entries.count {
            let key = state.entries[state.keys.count].key
            switch types.kind(state.keyType) {
            case .string:
                guard case .string(let text) = key else { throw GoRuntimeError.typeMismatch }
                state.keys.append(Array(text.utf8))
                continue
            default: break
            }
            if case .other(GoJSONTypes.time) = state.keyType {
                guard let time = GoTime(key) else { throw GoRuntimeError.typeMismatch }
                if let failure = GoTimeFormat.strictRFC3339Failure(time) {
                    return GoJSONStop(
                        code: GoJSONCode.encodeFailed,
                        text: "json: encoding error for type "
                            + GoFormat.quote(typeName(state.mapType), asciiOnly: false) + ": "
                            + GoFormat.quote("Time.MarshalText: " + failure, asciiOnly: false))
                }
                state.keys.append(GoTimeFormat.format(time, layout: GoTimeFormat.rfc3339Nano))
                continue
            }
            if implements(state.keyType, "MarshalText", heap) {
                if key == .nilValue, case .pointer = state.keyType {
                    state.keys.append([])
                    continue
                }
                awaiting = .key(state)
                return GoJSONStop(
                    code: GoJSONCode.encodeCallKeyText, value: boxed(key, state.keyType),
                    text: typeName(state.mapType))
            }
            guard case .int(let integer) = key else { throw GoRuntimeError.typeMismatch }
            switch types.kind(state.keyType) {
            case .unsigned(let bits):
                var unsigned = UInt64(bitPattern: integer)
                if bits < 64 { unsigned &= (UInt64(1) << UInt64(bits)) - 1 }
                state.keys.append(Array(String(unsigned).utf8))
            default:
                state.keys.append(Array(String(integer).utf8))
            }
        }
        let order = state.keys.indices.sorted { lhs, rhs in
            let (a, b) = (state.keys[lhs], state.keys[rhs])
            if a == b { return lhs < rhs }
            return a.lexicographicallyPrecedes(b)
        }
        tasks.append(.leave(state.leaveKey))
        tasks.append(.bytes([UInt8(ascii: "}")]))
        for (position, index) in order.enumerated().reversed() {
            tasks.append(.value(state.entries[index].value, state.valueType, quoted: false, address: nil))
            var prefix: [UInt8] = position > 0 ? [UInt8(ascii: ",")] : []
            GoJSONText.appendString(&prefix, state.keys[index], escapeHTML: escapeHTML)
            prefix.append(UInt8(ascii: ":"))
            tasks.append(.bytes(prefix))
        }
        return nil
    }

    // MARK: Numbers

    /// Whether a float is zero, which since Go 1.22 includes minus zero.
    private static func isFloatZero(_ value: GoValue) -> Bool {
        guard case .int(let pattern) = value else { return false }
        return Double(bitPattern: UInt64(bitPattern: pattern)) == 0
    }

    /// Go's `floatEncoder`: ES6 number text.
    static func float(_ number: Double, bits: Int) -> [UInt8] {
        let magnitude = abs(number)
        var format = UInt8(ascii: "f")
        if magnitude != 0 {
            if bits == 64 && (magnitude < 1e-6 || magnitude >= 1e21)
                || bits == 32 && (Float(magnitude) < Float(1e-6) || Float(magnitude) >= Float(1e21))
            {
                format = UInt8(ascii: "e")
            }
        }
        var text = Array(GoFloat.format(number, format: format, precision: -1, bitSize: bits).utf8)
        if format == UInt8(ascii: "e") {
            let n = text.count
            if n >= 4, text[n - 4] == UInt8(ascii: "e"), text[n - 3] == UInt8(ascii: "-"),
                text[n - 2] == UInt8(ascii: "0")
            {
                text[n - 2] = text[n - 1]
                text.removeLast()
            }
        }
        return text
    }
}

/// The VM's name of the defined type a value of `type` has.
enum GoJSONDescriptorOwner {
    static func symbol(_ type: GoRuntimeType) -> String {
        if case .named(let symbol) = type { return symbol }
        return ""
    }
}
