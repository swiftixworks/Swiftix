/// `json.Unmarshal`'s walk: Go's `decodeState` over text already known to be
/// valid, with what Go's decoder does by recursion kept on a stack of frames.
/// A value is built from the one it replaces, as Go merges into a value in
/// place: a struct keeps the fields the text does not name, a map its
/// entries, a non-nil pointer is decoded through, a slice reuses its array.
/// What lies behind a pointer is written to the heap when its value is done.
/// Where Go calls `UnmarshalJSON` or `UnmarshalText`, the walk stops with the
/// receiver and the text, and goes on when the library's text has called it.
/// Pure value types over the heap access it is given; no executor state.

final class GoJSONDecoder {
    private let data: [UInt8]
    private var position = 0
    private var types = GoJSONTypes()
    private let useNumber: Bool
    private let disallowUnknownFields: Bool
    private var frames: [Frame] = []
    private var saved: Failure?
    /// Go's `errorContext`: the struct whose field is being decoded, and
    /// the path of field names to it.
    private var contextStruct: GoRuntimeType?
    private var fieldStack: [String] = []
    private var next: Action
    private var awaiting: (readBack: GoPointer?, deliver: GoValue)?
    /// The text a method is called with.
    private(set) var raw: [UInt8] = []
    private(set) var failure: Failure?

    enum Failure {
        case syntax(String, Int64)
        case type(value: String, type: String, offset: Int64, strct: String, field: String)
        case plain(String)
        case corrupt(Int64)
    }

    /// What the walk does next: begin a value of a type over the value it
    /// replaces, begin a value of an `any` (Go's `valueInterface`), or hand
    /// a finished value to the frame below.
    private enum Action {
        case slot(Slot)
        case generic
        case value(GoValue)
        case stop(GoJSONStop)
    }

    private struct Slot {
        let type: GoRuntimeType
        let current: GoValue
    }

    private enum Frame {
        /// What a pointer points to, written through it when it is done,
        /// after which `deliver` is what the pointer's place holds.
        case pointer(GoPointer, deliver: GoValue)
        case array(ArrayState)
        case structure(StructState)
        case map(MapState)
        case anyArray([GoValue])
        case anyObject(GoMapStorage, key: String)
    }

    private struct ArrayState {
        let type: GoRuntimeType
        let element: GoRuntimeType
        let isSlice: Bool
        var elements: [GoValue]
        var length: Int
        var index = 0
        let existing: GoSliceValue?
        var grown = false
    }

    private struct StructState {
        let type: GoRuntimeType
        var value: GoValue
        let fields: [GoJSONField]
        let savedDepth: Int
        let savedStruct: GoRuntimeType?
        /// Where the value being decoded goes.
        var target: FieldPlace?
    }

    private enum FieldPlace {
        /// Fields by position, from the struct of the frame.
        case inValue([Int], names: [String])
        case inHeap(GoPointer)
    }

    private struct MapState {
        let type: GoRuntimeType
        let keyType: GoRuntimeType
        let element: GoRuntimeType
        let map: GoMapValue
        var storage: GoMapStorage
        var key: [UInt8] = []
        var keyItem: [UInt8] = []
        var keyStart = 0
        /// The value of the entry while the method that reads its key runs.
        var pendingValue: GoValue?
    }

    private struct Fatal: Error {
        let stop: GoJSONStop
    }

    /// `data` decoded into what `target`, an interface holding a pointer,
    /// points to. `check` first checks the whole text, as `Unmarshal` does.
    init(data: [UInt8], target: GoValue, check: Bool, useNumber: Bool, disallowUnknownFields: Bool) {
        self.data = data
        self.useNumber = useNumber
        self.disallowUnknownFields = disallowUnknownFields
        next = .stop(GoJSONStop(code: GoJSONCode.decodeDone))
        if check, let error = GoJSONText.check(data) {
            failure = .syntax(error.message, error.offset)
            next = .stop(GoJSONStop(code: GoJSONCode.decodeSyntax))
            return
        }
        start(target)
    }

    private var heap: GoJSONHeap!

    private func start(_ target: GoValue) {
        var value = target
        var type: GoRuntimeType?
        switch target {
        case .interface(let boxed):
            value = boxed.value
            if let descriptor = GoTypeDescriptor(typeName: boxed.typeName) {
                types.adopt(descriptor)
                type = descriptor.type
            } else {
                type = GoTypeDescriptor.dynamicType(named: boxed.typeName)
            }
        case .int: type = .integer
        case .string: type = .string
        case .bool: type = .boolean
        case .structure(let structure): type = structure.typeName.map { .named($0) }
        default: break
        }
        guard let type else {
            next = .stop(GoJSONStop(code: GoJSONCode.decodeInvalid, text: "nil"))
            return
        }
        guard case .pointer(let pointee) = types.underlying(type) else {
            next = .stop(
                GoJSONStop(code: GoJSONCode.decodeInvalid, text: "non-pointer " + GoTypeDescriptor.name(of: type)))
            return
        }
        guard case .pointer(let pointer) = value else {
            next = .stop(GoJSONStop(code: GoJSONCode.decodeInvalid, text: "nil " + GoTypeDescriptor.name(of: type)))
            return
        }
        skipSpace()
        pendingTop = (pointer, type, pointee)
    }

    private var pendingTop: (GoPointer, GoRuntimeType, GoRuntimeType)?

    /// The values the walk holds, which must stay alive while a method of
    /// the program runs.
    var heldValues: [GoValue] {
        var values: [GoValue] = []
        for frame in frames {
            switch frame {
            case .pointer(let pointer, let deliver): values += [.pointer(pointer), deliver]
            case .array(let state):
                values += state.elements
                if let existing = state.existing { values.append(.slice(existing)) }
            case .structure(let state): values.append(state.value)
            case .map(let state):
                values.append(.map(state.map))
                values.append(.mapStorage(state.storage))
            case .anyArray(let elements): values += elements
            case .anyObject(let storage, _): values.append(.mapStorage(storage))
            }
        }
        if let awaiting {
            values.append(awaiting.deliver)
            if let pointer = awaiting.readBack { values.append(.pointer(pointer)) }
        }
        return values
    }

    /// Go's `errorContext` for an error of a method: the struct and the path.
    func context(field: String) -> (String, String, Bool) {
        guard contextStruct != nil || !fieldStack.isEmpty else { return ("", field, false) }
        var stack = fieldStack
        if !field.isEmpty { stack.append(field) }
        return (contextStruct.map(GoJSONTypes.shortName) ?? "", stack.joined(separator: "."), true)
    }

    /// The method the walk stopped for has returned without an error.
    func resume(_ heap: GoJSONHeap) throws {
        guard let awaiting else { return }
        self.awaiting = nil
        if let pointer = awaiting.readBack {
            next = .value(try heap.read(pointer))
        } else {
            next = .value(awaiting.deliver)
        }
    }

    // MARK: Running

    func run(_ heap: GoJSONHeap) throws -> GoJSONStop {
        self.heap = heap
        defer { self.heap = nil }
        do {
            if let (pointer, type, pointee) = pendingTop {
                pendingTop = nil
                // Go's `indirect` from the pointer it was given, which it
                // cannot set: its methods first, then what it points to.
                switch try methodAt(pointer: pointer, type: type, deliver: .pointer(pointer)) {
                case .stop(let stop)?: return stop
                case .handled?: break
                default:
                    frames.append(.pointer(pointer, deliver: .pointer(pointer)))
                    next = .slot(Slot(type: pointee, current: try heap.read(pointer)))
                }
            }
            while true {
                switch next {
                case .stop(let stop):
                    return stop
                case .slot(let slot):
                    next = try begin(slot)
                case .generic:
                    next = try beginGeneric()
                case .value(let value):
                    guard let frame = frames.popLast() else {
                        next = .stop(finish())
                        continue
                    }
                    next = try consume(frame, value)
                }
            }
        } catch let fatal as Fatal {
            next = .stop(fatal.stop)
            return fatal.stop
        }
    }

    private func finish() -> GoJSONStop {
        guard let saved else { return GoJSONStop(code: GoJSONCode.decodeDone) }
        failure = saved
        switch saved {
        case .syntax: return GoJSONStop(code: GoJSONCode.decodeSyntax)
        case .type(_, let type, _, _, _): return GoJSONStop(code: GoJSONCode.decodeType, text: type)
        case .plain(let message): return GoJSONStop(code: GoJSONCode.decodeFailed, text: message)
        case .corrupt: return GoJSONStop(code: GoJSONCode.decodeCorrupt)
        }
    }

    private func fatal(_ message: String) -> Fatal {
        Fatal(stop: GoJSONStop(code: GoJSONCode.decodeFailed, text: message))
    }

    // MARK: Errors

    private func save(_ failure: Failure) {
        guard saved == nil else { return }
        if case .type(let value, let type, let offset, _, let field) = failure,
            contextStruct != nil || !fieldStack.isEmpty
        {
            var stack = fieldStack
            if !field.isEmpty { stack.append(field) }
            saved = .type(
                value: value, type: type, offset: offset,
                strct: contextStruct.map(GoJSONTypes.shortName) ?? "",
                field: stack.joined(separator: "."))
            return
        }
        saved = failure
    }

    private func typeError(_ value: String, _ type: GoRuntimeType, _ offset: Int) {
        save(.type(value: value, type: GoTypeDescriptor.name(of: type), offset: Int64(offset), strct: "", field: ""))
    }

    private func quotedUse(_ item: ArraySlice<UInt8>, _ type: GoRuntimeType) -> String {
        "json: invalid use of ,string struct tag, trying to unmarshal "
            + GoFormat.quote(String(decoding: item, as: UTF8.self), asciiOnly: false) + " into "
            + GoTypeDescriptor.name(of: type)
    }

    // MARK: The text

    private func skipSpace() {
        while position < data.count, GoJSONScanner.isSpace(data[position]) { position += 1 }
    }

    /// The end of the literal that starts at `position`.
    private func literalEnd(_ start: Int) -> Int {
        var i = start
        switch data[i] {
        case UInt8(ascii: "\""):
            i += 1
            while i < data.count {
                if data[i] == UInt8(ascii: "\\") {
                    i += 2
                    continue
                }
                if data[i] == UInt8(ascii: "\"") { return i + 1 }
                i += 1
            }
            return data.count
        case UInt8(ascii: "t"), UInt8(ascii: "n"): return min(data.count, i + 4)
        case UInt8(ascii: "f"): return min(data.count, i + 5)
        default:
            while i < data.count {
                let c = data[i]
                if (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45 {
                    i += 1
                } else {
                    break
                }
            }
            return i
        }
    }

    /// Past the value at `position`, without recursion.
    private func skipValue() {
        skipSpace()
        var depth = 0
        repeat {
            skipSpace()
            guard position < data.count else { return }
            let c = data[position]
            switch c {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                position += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                position += 1
            case UInt8(ascii: ","), UInt8(ascii: ":"):
                position += 1
            default:
                position = literalEnd(position)
            }
        } while depth > 0
    }

    /// Go's `unquoteBytes` of a string literal.
    static func unquote(_ s: ArraySlice<UInt8>) -> [UInt8]? {
        guard s.count >= 2, s.first == 0x22, s.last == 0x22 else { return nil }
        let body = Array(s.dropFirst().dropLast())
        var out: [UInt8] = []
        out.reserveCapacity(body.count)
        var r = 0
        func getu4(_ at: Int) -> Int32 {
            guard at + 6 <= body.count, body[at] == 0x5C, body[at + 1] == UInt8(ascii: "u") else { return -1 }
            var value: Int32 = 0
            for c in body[(at + 2)..<(at + 6)] {
                let digit: Int32
                switch c {
                case 0x30...0x39: digit = Int32(c - 0x30)
                case 0x61...0x66: digit = Int32(c - 0x61 + 10)
                case 0x41...0x46: digit = Int32(c - 0x41 + 10)
                default: return -1
                }
                value = value * 16 + digit
            }
            return value
        }
        func append(_ value: UInt32) {
            let scalar = Unicode.Scalar(value) ?? Unicode.Scalar(0xFFFD)!
            out += Array(String(Character(scalar)).utf8)
        }
        while r < body.count {
            let c = body[r]
            if c == 0x5C {
                r += 1
                guard r < body.count else { return nil }
                switch body[r] {
                case 0x22, 0x5C, 0x2F, 0x27: out.append(body[r]); r += 1
                case UInt8(ascii: "b"): out.append(0x08); r += 1
                case UInt8(ascii: "f"): out.append(0x0C); r += 1
                case UInt8(ascii: "n"): out.append(0x0A); r += 1
                case UInt8(ascii: "r"): out.append(0x0D); r += 1
                case UInt8(ascii: "t"): out.append(0x09); r += 1
                case UInt8(ascii: "u"):
                    r -= 1
                    var rr = getu4(r)
                    if rr < 0 { return nil }
                    r += 6
                    if rr >= 0xD800 && rr < 0xE000 {
                        let rr1 = getu4(r)
                        if rr < 0xDC00 && rr1 >= 0xDC00 && rr1 < 0xE000 {
                            r += 6
                            append(UInt32((rr - 0xD800) << 10 | (rr1 - 0xDC00)) + 0x10000)
                            continue
                        }
                        rr = 0xFFFD
                    }
                    append(UInt32(rr))
                default:
                    return nil
                }
            } else if c == 0x22 || c < 0x20 {
                return nil
            } else if c < 0x80 {
                out.append(c)
                r += 1
            } else {
                let (scalar, size) = GoJSONText.decodeRune(body, at: r)
                if scalar == nil {
                    out += [0xEF, 0xBF, 0xBD]
                } else {
                    out += body[r..<(r + size)]
                }
                r += size
            }
        }
        return out
    }

    // MARK: Methods

    private func pointerOwner(_ type: GoRuntimeType) -> (String, String)? {
        // The receiver names a pointer type's methods are found under.
        switch type {
        case .pointer(.named(let symbol)): return ("*" + symbol, symbol)
        default: return nil
        }
    }

    private func has(_ type: GoRuntimeType, _ name: String) -> Bool {
        guard let (pointer, value) = pointerOwner(type) else { return false }
        return heap.method(pointer, name, 1) || heap.method(value, name, 1)
    }

    /// The call of `UnmarshalJSON` that a pointer of `type` asks for, if it
    /// has the method: Go's `indirect` returning an `Unmarshaler`.
    private func methodAt(pointer: GoPointer, type: GoRuntimeType, deliver: GoValue) throws -> Resolution? {
        guard has(type, "UnmarshalJSON") || isTimePointer(type) || isRawPointer(type) else { return nil }
        return try unmarshalJSON(pointer: pointer, type: type, readBack: nil, deliver: deliver)
    }

    /// `UnmarshalJSON` of the value at `position` through `pointer`.
    private func unmarshalJSON(
        pointer: GoPointer, type: GoRuntimeType, readBack: GoPointer?, deliver: GoValue
    ) throws -> Resolution {
        let start = position
        skipValue()
        let text = Array(data[start..<position])
        if let stop = try callUnmarshalJSON(
            pointer: pointer, type: type, text: text, readBack: readBack, deliver: deliver)
        {
            return .stop(stop)
        }
        return .handled
    }

    /// Whether `type` is a defined type, whose pointer may have methods.
    private static func isDefined(_ type: GoRuntimeType) -> Bool {
        switch type {
        case .named, .other(GoJSONTypes.time): return true
        default: return false
        }
    }

    private func isTimePointer(_ type: GoRuntimeType) -> Bool {
        if case .pointer(.other(GoJSONTypes.time)) = type { return true }
        return false
    }

    private func isRawPointer(_ type: GoRuntimeType) -> Bool {
        if case .pointer(.named(GoJSONTypes.rawMessage)) = type { return true }
        return false
    }

    /// `UnmarshalJSON` of `text` through `pointer`: done here for a time and
    /// a `RawMessage`, asked of the program otherwise.
    private func callUnmarshalJSON(
        pointer: GoPointer, type: GoRuntimeType, text: [UInt8], readBack: GoPointer?, deliver: GoValue
    ) throws -> GoJSONStop? {
        if isTimePointer(type) {
            if text == Array("null".utf8) {
                next = readBack != nil ? .value(try heap.read(pointer)) : .value(deliver)
                return nil
            }
            guard text.count >= 2, text.first == 0x22, text.last == 0x22 else {
                throw fatal("Time.UnmarshalJSON: input is not a JSON string")
            }
            let inner = String(decoding: text.dropFirst().dropLast(), as: UTF8.self)
            switch GoTimeFormat.parse(
                layout: GoTimeFormat.rfc3339, value: inner, defaultLocation: .utc, local: .local)
            {
            case .success(let time):
                if let failure = GoTimeFormat.strictRFC3339Failure(time) {
                    throw fatal("parsing time " + GoFormat.quote(inner, asciiOnly: false) + ": " + failure)
                }
                try heap.write(time.value, pointer)
            case .failure(let failure):
                throw fatal(failure.message)
            }
            next = readBack != nil ? .value(try heap.read(pointer)) : .value(deliver)
            return nil
        }
        if isRawPointer(type) {
            let bytes = try makeBytes(text)
            try heap.write(bytes, pointer)
            next = readBack != nil ? .value(try heap.read(pointer)) : .value(deliver)
            return nil
        }
        raw = text
        awaiting = (readBack, deliver)
        return GoJSONStop(
            code: GoJSONCode.decodeCallUnmarshalJSON,
            value: .interface(
                GoInterfaceValue(
                    typeName: GoJSONDescriptor.typeName(type, definitions: types.definitions),
                    value: .pointer(pointer))))
    }

    private func makeBytes(_ bytes: [UInt8]) throws -> GoValue {
        let cell = try heap.allocate(.array(bytes.map { .int(Int64($0)) }))
        return .slice(
            GoSliceValue(
                backing: GoPointer(cell: cell), start: 0, length: bytes.count, capacity: bytes.count,
                zeroValue: .int(0)))
    }

    private enum Resolution {
        case slot(Slot, originalType: GoRuntimeType, textMethod: GoPointer?)
        case stop(GoJSONStop)
        case handled
    }

    /// Go's `indirect`: through pointers, allocating nil ones, to the value
    /// a JSON value is stored in, or to a method that takes the JSON text
    /// instead. Frames that write each pointer's value back are pushed on
    /// the way.
    private func indirect(_ slot: Slot, isNull: Bool, isString: Bool) throws -> Resolution {
        var type = slot.type
        var current = slot.current
        let original = slot.type
        var hops = 0
        while hops < 10_000 {
            hops += 1
            // A defined type whose pointer has the method: through the
            // value's address, here a cell the value is copied to.
            if types.kind(type) != .pointer, Self.isDefined(type) {
                let pointerType = GoRuntimeType.pointer(type)
                if has(pointerType, "UnmarshalJSON") || isTimePointer(pointerType) || isRawPointer(pointerType) {
                    let cell = GoPointer(cell: try heap.allocate(current))
                    return try unmarshalJSON(pointer: cell, type: pointerType, readBack: cell, deliver: .nilValue)
                }
                if !isNull, has(pointerType, "UnmarshalText") {
                    let cell = GoPointer(cell: try heap.allocate(current))
                    return .slot(Slot(type: type, current: current), originalType: original, textMethod: cell)
                }
            }
            switch types.kind(type) {
            case .interface:
                guard case .interface(let boxed) = current,
                    let descriptor = GoTypeDescriptor(typeName: boxed.typeName),
                    case .pointer(let pointee) = descriptor.type,
                    case .pointer(let pointer) = boxed.value
                else { return .slot(Slot(type: type, current: current), originalType: original, textMethod: nil) }
                types.adopt(descriptor)
                if isNull, types.kind(pointee) != .pointer {
                    return .slot(Slot(type: type, current: current), originalType: original, textMethod: nil)
                }
                if let resolution = try methodAt(pointer: pointer, type: descriptor.type, deliver: current) {
                    return resolution
                }
                frames.append(.pointer(pointer, deliver: current))
                if !isNull, has(descriptor.type, "UnmarshalText") {
                    return .slot(
                        Slot(type: pointee, current: try heap.read(pointer)), originalType: original,
                        textMethod: pointer)
                }
                type = pointee
                current = try heap.read(pointer)
            case .pointer:
                guard case .pointer(let pointee) = types.underlying(type) else { throw GoRuntimeError.typeMismatch }
                if isNull {
                    return .slot(Slot(type: type, current: current), originalType: original, textMethod: nil)
                }
                let pointer: GoPointer
                if case .pointer(let existing) = current {
                    pointer = existing
                } else {
                    pointer = GoPointer(cell: try heap.allocate(types.zero(pointee)))
                }
                let deliver = GoValue.pointer(pointer)
                if let resolution = try methodAt(pointer: pointer, type: type, deliver: deliver) {
                    return resolution
                }
                frames.append(.pointer(pointer, deliver: deliver))
                if has(type, "UnmarshalText") {
                    return .slot(
                        Slot(type: pointee, current: try heap.read(pointer)), originalType: original,
                        textMethod: pointer)
                }
                type = pointee
                current = try heap.read(pointer)
            default:
                return .slot(Slot(type: type, current: current), originalType: original, textMethod: nil)
            }
        }
        return .slot(Slot(type: type, current: current), originalType: original, textMethod: nil)
    }

    // MARK: Beginning a value

    private func begin(_ slot: Slot) throws -> Action {
        skipSpace()
        guard position < data.count else { return .value(slot.current) }
        let c = data[position]
        if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
            let resolution = try indirect(slot, isNull: false, isString: false)
            switch resolution {
            case .stop(let stop): return .stop(stop)
            case .handled: return next
            case .slot(let target, let original, let textMethod):
                position += 1
                let what = c == UInt8(ascii: "{") ? "object" : "array"
                if textMethod != nil {
                    typeError(what, original, position)
                    position -= 1
                    skipValue()
                    return .value(target.current)
                }
                return c == UInt8(ascii: "{") ? try beginObject(target) : try beginArray(target)
            }
        }
        let start = position
        let end = literalEnd(start)
        position = end
        let item = data[start..<end]
        position = start
        let resolution = try indirect(slot, isNull: c == UInt8(ascii: "n"), isString: c == UInt8(ascii: "\""))
        position = end
        switch resolution {
        case .stop(let stop): return .stop(stop)
        case .handled: return next
        case .slot(let target, let original, let textMethod):
            if let textMethod {
                return try storeText(item, target, original: original, pointer: textMethod, fromQuoted: false)
            }
            return .value(try store(item, target, fromQuoted: false))
        }
    }

    /// A literal for a type whose pointer has `UnmarshalText`.
    private func storeText(
        _ item: ArraySlice<UInt8>, _ target: Slot, original: GoRuntimeType, pointer: GoPointer, fromQuoted: Bool
    ) throws -> Action {
        guard item.first == 0x22 else {
            if fromQuoted { save(.plain(quotedUse(item, original))); return .value(target.current) }
            var what = "number"
            switch item.first {
            case UInt8(ascii: "n"): what = "null"
            case UInt8(ascii: "t"), UInt8(ascii: "f"): what = "bool"
            default: break
            }
            typeError(what, original, position)
            return .value(target.current)
        }
        guard let text = Self.unquote(item) else {
            throw fatal(quotedUse(item, original))
        }
        raw = text
        awaiting = (pointer, .nilValue)
        let pointerType: GoRuntimeType = .pointer(target.type)
        return .stop(
            GoJSONStop(
                code: GoJSONCode.decodeCallUnmarshalText,
                value: .interface(
                    GoInterfaceValue(
                        typeName: GoJSONDescriptor.typeName(pointerType, definitions: types.definitions),
                        value: .pointer(pointer)))))
    }

    /// Go's `literalStore` into a value of the slot's type.
    private func store(_ item: ArraySlice<UInt8>, _ slot: Slot, fromQuoted: Bool) throws -> GoValue {
        let type = slot.type
        let current = slot.current
        let offset = position
        guard let c = item.first else {
            save(.plain(quotedUse(item, type)))
            return current
        }
        let kind = types.kind(type)
        switch c {
        case UInt8(ascii: "n"):
            if fromQuoted && Array(item) != Array("null".utf8) {
                save(.plain(quotedUse(item, type)))
                return current
            }
            switch kind {
            case .interface, .pointer, .map, .slice: return .nilValue
            default: return current
            }
        case UInt8(ascii: "t"), UInt8(ascii: "f"):
            let value = c == UInt8(ascii: "t")
            if fromQuoted && Array(item) != Array("true".utf8) && Array(item) != Array("false".utf8) {
                save(.plain(quotedUse(item, type)))
                return current
            }
            switch kind {
            case .bool: return .bool(value)
            case .interface(empty: true): return .bool(value)
            case .interface:
                typeError("bool", type, offset)
            default:
                if fromQuoted { save(.plain(quotedUse(item, type))) } else { typeError("bool", type, offset) }
            }
            return current
        case 0x22:
            guard let bytes = Self.unquote(item) else {
                if fromQuoted { throw fatal(quotedUse(item, type)) }
                return current
            }
            switch kind {
            case .slice:
                guard case .slice(let element) = types.underlying(type), types.underlying(element) == .byte else {
                    typeError("string", type, offset)
                    return current
                }
                let (decoded, corrupt) = GoJSONText.unbase64(bytes)
                if let corrupt {
                    save(.corrupt(Int64(corrupt)))
                    return current
                }
                return try makeBytes(decoded)
            case .string:
                if case .named(GoJSONTypes.number) = type, !GoJSONText.isValidNumber(bytes) {
                    throw fatal(
                        "json: invalid number literal, trying to unmarshal "
                            + GoFormat.quote(String(decoding: item, as: UTF8.self), asciiOnly: false)
                            + " into Number")
                }
                return .string(String(decoding: bytes, as: UTF8.self))
            case .interface(empty: true):
                return .string(String(decoding: bytes, as: UTF8.self))
            default:
                typeError("string", type, offset)
                return current
            }
        default:
            let text = String(decoding: item, as: UTF8.self)
            if c != UInt8(ascii: "-") && (c < 0x30 || c > 0x39) {
                if fromQuoted { throw fatal(quotedUse(item, type)) }
                return current
            }
            switch kind {
            case .interface(let empty):
                guard let number = convertNumber(text) else { return current }
                if !empty {
                    typeError("number", type, offset)
                    return current
                }
                return number
            case .signed(let bits):
                guard let n = Int64(text), text.first != "+", Self.fits(n, bits: bits) else {
                    typeError("number " + text, type, offset)
                    return current
                }
                return .int(n)
            case .unsigned(let bits):
                guard let first = text.utf8.first, first >= 0x30, first <= 0x39, let n = UInt64(text),
                    bits == 64 || n < UInt64(1) << UInt64(bits)
                else {
                    typeError("number " + text, type, offset)
                    return current
                }
                return .int(Int64(bitPattern: n))
            case .float(let bits):
                let (value, failure) = GoFloat.parse(text, bitSize: bits)
                if failure != nil {
                    typeError("number " + text, type, offset)
                    return current
                }
                return .int(Int64(bitPattern: value.bitPattern))
            default:
                if kind == .string, case .named(GoJSONTypes.number) = type { return .string(text) }
                if fromQuoted { throw fatal(quotedUse(item, type)) }
                typeError("number", type, offset)
                return current
            }
        }
    }

    private static func fits(_ value: Int64, bits: Int) -> Bool {
        guard bits < 64 else { return true }
        let limit = Int64(1) << Int64(bits - 1)
        return value >= -limit && value < limit
    }

    /// Go's `convertNumber`: a float64 or a `Number` in an `any`.
    private func convertNumber(_ text: String) -> GoValue? {
        if useNumber {
            return .interface(
                GoInterfaceValue(
                    typeName: GoJSONDescriptor.typeName(
                        .named(GoJSONTypes.number), definitions: [GoJSONTypes.number: .string]),
                    value: .string(text)))
        }
        let (value, failure) = GoFloat.parse(text, bitSize: 64)
        if failure != nil {
            save(.type(value: "number " + text, type: "float64", offset: Int64(position + 1), strct: "", field: ""))
            return nil
        }
        return Self.float64(value)
    }

    private static func float64(_ value: Double) -> GoValue {
        .interface(GoInterfaceValue(typeName: GoTypeDescriptor.marker + "d", value: .int(Int64(bitPattern: value.bitPattern))))
    }

    // MARK: Values of an `any`

    private func beginGeneric() throws -> Action {
        skipSpace()
        guard position < data.count else { return .value(.nilValue) }
        switch data[position] {
        case UInt8(ascii: "{"):
            position += 1
            frames.append(.anyObject(GoMapStorage(), key: ""))
            return try nextGenericKey()
        case UInt8(ascii: "["):
            position += 1
            skipSpace()
            if position < data.count, data[position] == UInt8(ascii: "]") {
                position += 1
                return .value(try anySlice([]))
            }
            frames.append(.anyArray([]))
            return .generic
        default:
            let start = position
            position = literalEnd(start)
            let item = data[start..<position]
            switch item.first {
            case UInt8(ascii: "n"): return .value(.nilValue)
            case UInt8(ascii: "t"): return .value(.bool(true))
            case UInt8(ascii: "f"): return .value(.bool(false))
            case 0x22: return .value(.string(String(decoding: Self.unquote(item) ?? [], as: UTF8.self)))
            default: return .value(convertNumber(String(decoding: item, as: UTF8.self)) ?? .nilValue)
            }
        }
    }

    private func nextGenericKey() throws -> Action {
        skipSpace()
        if position < data.count, data[position] == UInt8(ascii: "}") {
            position += 1
            guard case .anyObject(let storage, _)? = frames.popLast() else { throw GoRuntimeError.typeMismatch }
            return .value(try anyMap(storage))
        }
        let start = position
        position = literalEnd(start)
        let key = String(decoding: Self.unquote(data[start..<position]) ?? [], as: UTF8.self)
        skipSpace()
        position += 1  // the colon
        guard case .anyObject(let storage, _)? = frames.popLast() else { throw GoRuntimeError.typeMismatch }
        frames.append(.anyObject(storage, key: key))
        return .generic
    }

    private func anySlice(_ elements: [GoValue]) throws -> GoValue {
        let capacity = Self.grownCapacity(for: elements.count)
        let cell = try heap.allocate(.array(elements + [GoValue](repeating: .nilValue, count: capacity - elements.count)))
        let slice = GoValue.slice(
            GoSliceValue(backing: GoPointer(cell: cell), start: 0, length: elements.count, capacity: capacity, zeroValue: .nilValue))
        return .interface(GoInterfaceValue(typeName: GoTypeDescriptor.marker + "[a", value: slice))
    }

    private func anyMap(_ storage: GoMapStorage) throws -> GoValue {
        let cell = try heap.allocate(.mapStorage(storage))
        return .interface(
            GoInterfaceValue(
                typeName: GoTypeDescriptor.marker + "Msa", value: .map(GoMapValue(storage: GoPointer(cell: cell)))))
    }

    /// The capacity a slice appended to one element at a time has: Go's
    /// `growslice` without the rounding to its allocator's size classes.
    static func grownCapacity(for count: Int) -> Int {
        var capacity = 0
        while capacity < count {
            if capacity == 0 {
                capacity = 1
            } else if capacity < 256 {
                capacity *= 2
            } else {
                capacity += (capacity + 3 * 256) / 4
            }
        }
        return capacity
    }

    // MARK: Arrays

    private func beginArray(_ slot: Slot) throws -> Action {
        let type = slot.type
        switch types.kind(type) {
        case .interface(empty: true):
            position -= 1
            return try beginGeneric()
        case .slice:
            guard case .slice(let element) = types.underlying(type) else { throw GoRuntimeError.typeMismatch }
            var state = ArrayState(
                type: type, element: element, isSlice: true, elements: [], length: 0, existing: nil)
            if case .slice(let existing) = slot.current,
                case .array(let backing) = try heap.read(existing.backing),
                existing.start + existing.capacity <= backing.count
            {
                state = ArrayState(
                    type: type, element: element, isSlice: true,
                    elements: Array(backing[existing.start..<(existing.start + existing.capacity)]),
                    length: existing.length, existing: existing)
            }
            return try nextElement(state)
        case .array:
            guard case .array(_, let element) = types.underlying(type), case .array(let elements) = slot.current
            else { throw GoRuntimeError.typeMismatch }
            return try nextElement(
                ArrayState(
                    type: type, element: element, isSlice: false, elements: elements, length: elements.count,
                    existing: nil))
        default:
            typeError("array", type, position)
            position -= 1
            skipValue()
            return .value(slot.current)
        }
    }

    private func nextElement(_ state: ArrayState) throws -> Action {
        var state = state
        while true {
            skipSpace()
            if position < data.count, data[position] == UInt8(ascii: ",") {
                position += 1
                skipSpace()
            }
            if position < data.count, data[position] == UInt8(ascii: "]") {
                position += 1
                return .value(try finishArray(state))
            }
            let i = state.index
            if state.isSlice {
                if i >= state.elements.count {
                    state.grown = true
                    let capacity = Self.grownCapacity(for: i + 1)
                    state.elements += [GoValue](
                        repeating: types.zero(state.element), count: capacity - state.elements.count)
                }
                if i >= state.length { state.length = i + 1 }
            }
            if i < state.length {
                frames.append(.array(state))
                return .slot(Slot(type: state.element, current: state.elements[i]))
            }
            // Past the end of an array: the value is read and dropped.
            skipValue()
            state.index += 1
        }
    }

    private func finishArray(_ state: ArrayState) throws -> GoValue {
        var state = state
        let i = state.index
        if !state.isSlice {
            for k in min(i, state.elements.count)..<state.elements.count {
                state.elements[k] = types.zero(state.element)
            }
            return .array(state.elements)
        }
        if i < state.length { state.length = i }
        if i == 0 {
            let cell = try heap.allocate(.array([]))
            return .slice(
                GoSliceValue(
                    backing: GoPointer(cell: cell), start: 0, length: 0, capacity: 0,
                    zeroValue: types.zero(state.element)))
        }
        if let existing = state.existing, !state.grown {
            guard case .array(var backing) = try heap.read(existing.backing) else { throw GoRuntimeError.typeMismatch }
            backing.replaceSubrange(existing.start..<(existing.start + existing.capacity), with: state.elements)
            try heap.write(.array(backing), existing.backing)
            return .slice(
                GoSliceValue(
                    backing: existing.backing, start: existing.start, length: state.length,
                    capacity: existing.capacity, zeroValue: existing.zeroValue))
        }
        let cell = try heap.allocate(.array(state.elements))
        return .slice(
            GoSliceValue(
                backing: GoPointer(cell: cell), start: 0, length: state.length, capacity: state.elements.count,
                zeroValue: types.zero(state.element)))
    }

    // MARK: Objects

    private func beginObject(_ slot: Slot) throws -> Action {
        let type = slot.type
        switch types.kind(type) {
        case .interface(empty: true):
            position -= 1
            return try beginGeneric()
        case .map:
            guard case .map(let keyType, let element) = types.underlying(type) else { throw GoRuntimeError.typeMismatch }
            switch types.kind(keyType) {
            case .string, .signed, .unsigned: break
            default:
                if !has(.pointer(keyType), "UnmarshalText") && keyType != .other(GoJSONTypes.time) {
                    typeError("object", type, position)
                    position -= 1
                    skipValue()
                    return .value(slot.current)
                }
            }
            let map: GoMapValue
            var storage = GoMapStorage()
            if case .map(let existing) = slot.current {
                map = existing
                if case .mapStorage(let found) = try heap.read(existing.storage) { storage = found }
            } else {
                map = GoMapValue(storage: GoPointer(cell: try heap.allocate(.mapStorage(storage))))
            }
            return try nextMapKey(MapState(type: type, keyType: keyType, element: element, map: map, storage: storage))
        case .structure:
            let state = StructState(
                type: type, value: slot.current, fields: types.fields(of: type), savedDepth: fieldStack.count,
                savedStruct: contextStruct)
            return try nextStructKey(state)
        default:
            typeError("object", type, position)
            position -= 1
            skipValue()
            return .value(slot.current)
        }
    }

    /// Past a comma, at a key or the end of the object: true at the end.
    private func atObjectEnd() -> Bool {
        skipSpace()
        if position < data.count, data[position] == UInt8(ascii: ",") {
            position += 1
            skipSpace()
        }
        if position < data.count, data[position] == UInt8(ascii: "}") {
            position += 1
            return true
        }
        return false
    }

    /// The key at `position` and where it starts; the colon after it read.
    private func readKey() -> (ArraySlice<UInt8>, Int) {
        let start = position
        position = literalEnd(start)
        let item = data[start..<position]
        skipSpace()
        position += 1
        skipSpace()
        return (item, start)
    }

    private func nextMapKey(_ state: MapState) throws -> Action {
        var state = state
        if atObjectEnd() {
            try heap.write(.mapStorage(state.storage), state.map.storage)
            return .value(.map(state.map))
        }
        let (item, start) = readKey()
        state.key = Self.unquote(item) ?? []
        state.keyItem = Array(item)
        state.keyStart = start
        frames.append(.map(state))
        return .slot(Slot(type: state.element, current: types.zero(state.element)))
    }

    private func nextStructKey(_ state: StructState) throws -> Action {
        var state = state
        while true {
            if atObjectEnd() { return .value(state.value) }
            let (item, _) = readKey()
            let key = Self.unquote(item) ?? []
            var field = state.fields.first { $0.nameBytes == key }
            if field == nil {
                let folded = GoJSONTypes.fold(key)
                field = state.fields.first { $0.folded == folded }
            }
            guard let field else {
                if disallowUnknownFields {
                    save(.plain("json: unknown field " + GoFormat.quote(String(decoding: key, as: UTF8.self), asciiOnly: false)))
                }
                skipValue()
                continue
            }
            // Go's walk to the field, through embedded pointers, which it
            // allocates where they are nil.
            var place = FieldPlace.inValue([], names: [])
            var type = state.type
            var embeddedFailure = false
            for (level, index) in field.index.enumerated() {
                if case .pointer(let pointee) = types.underlying(type) {
                    let pointerValue = try read(place, in: state.value)
                    let pointer: GoPointer
                    if case .pointer(let existing) = pointerValue {
                        pointer = existing
                    } else {
                        let name = field.goNames[level - 1]
                        if !GoJSONTypes.isExported(name) {
                            save(.plain("json: cannot set embedded pointer to unexported struct: " + GoTypeDescriptor.name(of: pointee)))
                            embeddedFailure = true
                            break
                        }
                        pointer = GoPointer(cell: try heap.allocate(types.zero(pointee)))
                        try write(.pointer(pointer), at: place, in: &state.value)
                    }
                    place = .inHeap(pointer)
                    type = pointee
                }
                if level < field.index.count - 1 {
                    fieldStack.append(field.goNames[level])
                }
                guard case .structure(let declared) = types.underlying(type), index < declared.count else {
                    throw GoRuntimeError.typeMismatch
                }
                switch place {
                case .inValue(let positions, let names):
                    place = .inValue(positions + [index], names: names + [field.goNames[level]])
                case .inHeap(let pointer):
                    place = .inHeap(GoPointer(cell: pointer.cell, path: pointer.path + [.field(field.goNames[level])]))
                }
                type = declared[index].type
            }
            if embeddedFailure {
                fieldStack.removeSubrange(state.savedDepth...)
                skipValue()
                continue
            }
            contextStruct = state.type
            fieldStack.append(field.name)
            state.target = place
            let current = try read(place, in: state.value)
            if field.quoted {
                return try quotedValue(state, type: type, current: current)
            }
            frames.append(.structure(state))
            return .slot(Slot(type: type, current: current))
        }
    }

    /// Go's `valueQuoted` and the `literalStore` of what it finds, for a
    /// field with the `,string` option.
    private func quotedValue(_ state: StructState, type: GoRuntimeType, current: GoValue) throws -> Action {
        skipSpace()
        frames.append(.structure(state))
        guard position < data.count else { return .value(current) }
        let c = data[position]
        if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
            skipValue()
            save(
                .plain(
                    "json: invalid use of ,string struct tag, trying to unmarshal unquoted value into "
                        + GoTypeDescriptor.name(of: type)))
            return .value(current)
        }
        let start = position
        position = literalEnd(start)
        let item = data[start..<position]
        switch c {
        case UInt8(ascii: "n"):
            let resolution = try indirect(Slot(type: type, current: current), isNull: true, isString: false)
            if case .slot(let target, _, _) = resolution {
                return .value(try store(Array("null".utf8)[...], target, fromQuoted: false))
            }
            if case .stop(let stop) = resolution { return .stop(stop) }
            return next
        case 0x22:
            let inner = Self.unquote(item) ?? []
            let resolution = try indirect(Slot(type: type, current: current), isNull: inner.first == UInt8(ascii: "n"), isString: true)
            switch resolution {
            case .stop(let stop): return .stop(stop)
            case .handled: return next
            case .slot(let target, let original, let textMethod):
                if let textMethod {
                    return try storeText(inner[...], target, original: original, pointer: textMethod, fromQuoted: true)
                }
                return .value(try store(inner[...], target, fromQuoted: true))
            }
        default:
            if c != UInt8(ascii: "t") && c != UInt8(ascii: "f") {
                _ = convertNumber(String(decoding: item, as: UTF8.self))
            }
            save(
                .plain(
                    "json: invalid use of ,string struct tag, trying to unmarshal unquoted value into "
                        + GoTypeDescriptor.name(of: type)))
            return .value(current)
        }
    }

    private func read(_ place: FieldPlace, in value: GoValue) throws -> GoValue {
        switch place {
        case .inHeap(let pointer): return try heap.read(pointer)
        case .inValue(let positions, let names):
            var current = value
            for (position, name) in zip(positions, names) {
                guard case .structure(let structure) = current else { throw GoRuntimeError.typeMismatch }
                current = try Self.field(structure, position, name).value
            }
            return current
        }
    }

    private static func field(_ structure: GoStructValue, _ position: Int, _ name: String) throws -> GoStructFieldValue {
        if position < structure.fields.count, structure.fields[position].name == name { return structure.fields[position] }
        guard let found = structure.fields.first(where: { $0.name == name }) else { throw GoRuntimeError.unknownField(name) }
        return found
    }

    private func write(_ newValue: GoValue, at place: FieldPlace, in value: inout GoValue) throws {
        switch place {
        case .inHeap(let pointer): try heap.write(newValue, pointer)
        case .inValue(let positions, let names):
            value = try Self.replacing(value, positions[...], names[...], with: newValue)
        }
    }

    private static func replacing(
        _ value: GoValue, _ positions: ArraySlice<Int>, _ names: ArraySlice<String>, with newValue: GoValue
    ) throws -> GoValue {
        guard let position = positions.first, let name = names.first else { return newValue }
        guard case .structure(var structure) = value else { throw GoRuntimeError.typeMismatch }
        var index = position
        if !(index < structure.fields.count && structure.fields[index].name == name) {
            guard let found = structure.fields.firstIndex(where: { $0.name == name }) else {
                throw GoRuntimeError.unknownField(name)
            }
            index = found
        }
        structure.fields[index].value = try replacing(
            structure.fields[index].value, positions.dropFirst(), names.dropFirst(), with: newValue)
        return .structure(structure)
    }

    // MARK: Values handed back

    private func consume(_ frame: Frame, _ value: GoValue) throws -> Action {
        switch frame {
        case .pointer(let pointer, let deliver):
            try heap.write(value, pointer)
            return .value(deliver)
        case .array(var state):
            state.elements[state.index] = value
            state.index += 1
            return try nextElement(state)
        case .structure(var state):
            if let target = state.target {
                try write(value, at: target, in: &state.value)
            }
            state.target = nil
            fieldStack.removeSubrange(state.savedDepth...)
            contextStruct = state.savedStruct
            return try nextStructKey(state)
        case .map(var state):
            if let pending = state.pendingValue {
                // The key, from its method.
                state.pendingValue = nil
                state.storage.set(value, pending)
                return try nextMapKey(state)
            }
            let pointerType = GoRuntimeType.pointer(state.keyType)
            if has(pointerType, "UnmarshalText") || isTimePointer(pointerType) {
                // Go's `literalStore` of the quoted key into a new key.
                let cell = GoPointer(cell: try heap.allocate(types.zero(state.keyType)))
                state.pendingValue = value
                frames.append(.map(state))
                if has(pointerType, "UnmarshalJSON") || isTimePointer(pointerType) {
                    if let stop = try callUnmarshalJSON(
                        pointer: cell, type: pointerType, text: state.keyItem, readBack: cell, deliver: .nilValue)
                    {
                        return .stop(stop)
                    }
                    return next
                }
                raw = state.key
                awaiting = (cell, .nilValue)
                return .stop(
                    GoJSONStop(
                        code: GoJSONCode.decodeCallUnmarshalText,
                        value: .interface(
                            GoInterfaceValue(
                                typeName: GoJSONDescriptor.typeName(pointerType, definitions: types.definitions),
                                value: .pointer(cell)))))
            }
            if let key = try mapKey(state) {
                state.storage.set(key, value)
            }
            return try nextMapKey(state)
        case .anyArray(var elements):
            elements.append(value)
            skipSpace()
            if position < data.count, data[position] == UInt8(ascii: ",") {
                position += 1
                frames.append(.anyArray(elements))
                return .generic
            }
            position += 1  // the closing bracket
            return .value(try anySlice(elements))
        case .anyObject(var storage, let key):
            storage.set(.string(key), value)
            skipSpace()
            if position < data.count, data[position] == UInt8(ascii: ",") { position += 1 }
            frames.append(.anyObject(storage, key: ""))
            return try nextGenericKey()
        }
    }

    /// The key of a map entry, from the text of its key.
    private func mapKey(_ state: MapState) throws -> GoValue? {
        let text = String(decoding: state.key, as: UTF8.self)
        switch types.kind(state.keyType) {
        case .string: return .string(text)
        case .signed(let bits):
            guard let n = Int64(text), text.first != "+", Self.fits(n, bits: bits) else {
                typeError("number " + text, state.keyType, state.keyStart + 1)
                return nil
            }
            return .int(n)
        case .unsigned(let bits):
            guard let first = text.utf8.first, first >= 0x30, first <= 0x39, let n = UInt64(text),
                bits == 64 || n < UInt64(1) << UInt64(bits)
            else {
                typeError("number " + text, state.keyType, state.keyStart + 1)
                return nil
            }
            return .int(Int64(bitPattern: n))
        default:
            return nil
        }
    }
}
