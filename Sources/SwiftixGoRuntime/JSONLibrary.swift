/// The natives of `encoding/json`'s text (`GoJSONLibrary` in `SwiftixGo`).
///
/// `Marshal` and `Unmarshal` each start a walk, which the VM keeps under a
/// handle until the text releases it. A walk runs until it is done, fails,
/// or needs a method of the program called; while the text calls it, what
/// the walk holds is a root of the collector, under the handle. Reference
/// state of one run; no process state.
enum GoJSONNatives {
    /// Reserved call names, with the number of operands each pops.
    static let argumentCounts: [String: Int] = [
        "$json.encodeStart": 2, "$json.encodeRun": 1, "$json.encoded": 1, "$json.failure": 1,
        "$json.resume": 2, "$json.release": 1, "$json.decodeStart": 3, "$json.decodeRun": 1,
        "$json.raw": 1, "$json.typeError": 1, "$json.context": 2, "$json.valid": 1,
        "$json.compact": 3, "$json.indent": 4, "$json.scanValue": 2, "$json.quoteChar": 1,
    ]

    /// The flags of a decoding, as the text numbers them.
    static let decodeCheck = 1
    static let decodeUseNumber = 2
    static let decodeDisallowUnknownFields = 4

    /// A walk under its handle.
    enum Walk {
        case encoder(GoJSONEncoder)
        case decoder(GoJSONDecoder)

        var heldValues: [GoValue] {
            switch self {
            case .encoder(let encoder): return encoder.heldValues
            case .decoder(let decoder): return decoder.heldValues
            }
        }
    }

    /// What the VM lends the natives.
    struct Host {
        let heap: GoJSONHeap
        let bytes: (GoValue) throws -> [UInt8]
        let makeBytes: ([UInt8]) throws -> GoValue
        /// A new handle, rooted.
        let retain: () throws -> Int
        /// Sets what a handle keeps alive.
        let root: (Int, GoValue) -> Void
        let release: (Int) -> Void
    }

    /// The results of the native `name` on `operands`.
    static func call(
        _ name: String, _ operands: [GoValue], walks: inout [Int: Walk], host: Host
    ) throws -> [GoValue] {
        func integer(_ index: Int) throws -> Int {
            guard case .int(let value) = operands[index], let result = Int(exactly: value) else {
                throw GoRuntimeError.typeMismatch
            }
            return result
        }
        func text(_ index: Int) throws -> String {
            guard case .string(let value) = operands[index] else { throw GoRuntimeError.typeMismatch }
            return value
        }
        func walk() throws -> Walk {
            guard let found = walks[try integer(0)] else { throw GoRuntimeError.typeMismatch }
            return found
        }
        /// Runs a walk to its next stop, rooting what it holds while it
        /// waits for a method.
        func stopped(_ stop: GoJSONStop, _ handle: Int, _ walk: Walk) -> [GoValue] {
            let waits: Bool
            switch walk {
            case .encoder: waits = stop.code >= GoJSONCode.encodeCallMarshalJSON
            case .decoder: waits = stop.code >= GoJSONCode.decodeCallUnmarshalJSON
            }
            host.root(handle, waits ? .array(walk.heldValues + [stop.value]) : .nilValue)
            return [.int(Int64(stop.code)), stop.value, .string(stop.text)]
        }
        switch name {
        case "$json.encodeStart":
            guard case .int(let flags) = operands[1] else { throw GoRuntimeError.typeMismatch }
            let handle = try host.retain()
            walks[handle] = .encoder(GoJSONEncoder(value: operands[0], escapeHTML: flags & 1 != 0))
            return [.int(Int64(handle))]
        case "$json.decodeStart":
            guard case .int(let flags) = operands[2] else { throw GoRuntimeError.typeMismatch }
            let handle = try host.retain()
            walks[handle] = .decoder(
                GoJSONDecoder(
                    data: try host.bytes(operands[0]), target: operands[1],
                    check: flags & Int64(decodeCheck) != 0, useNumber: flags & Int64(decodeUseNumber) != 0,
                    disallowUnknownFields: flags & Int64(decodeDisallowUnknownFields) != 0))
            return [.int(Int64(handle))]
        case "$json.encodeRun", "$json.decodeRun":
            let found = try walk()
            switch found {
            case .encoder(let encoder): return stopped(try encoder.run(host.heap), try integer(0), found)
            case .decoder(let decoder): return stopped(try decoder.run(host.heap), try integer(0), found)
            }
        case "$json.resume":
            switch try walk() {
            case .encoder(let encoder):
                encoder.resume(operands[1] == .nilValue ? nil : try host.bytes(operands[1]))
            case .decoder(let decoder):
                try decoder.resume(host.heap)
            }
            return []
        case "$json.encoded":
            guard case .encoder(let encoder) = try walk() else { throw GoRuntimeError.typeMismatch }
            return [try host.makeBytes(encoder.output)]
        case "$json.raw":
            guard case .decoder(let decoder) = try walk() else { throw GoRuntimeError.typeMismatch }
            return [try host.makeBytes(decoder.raw)]
        case "$json.failure":
            switch try walk() {
            case .encoder(let encoder):
                return [.string(encoder.failure.message), .int(encoder.failure.offset)]
            case .decoder(let decoder):
                switch decoder.failure {
                case .syntax(let message, let offset)?: return [.string(message), .int(offset)]
                case .corrupt(let offset)?: return [.string(""), .int(offset)]
                default: return [.string(""), .int(0)]
                }
            }
        case "$json.typeError":
            guard case .decoder(let decoder) = try walk(),
                case .type(let value, _, let offset, let strct, let field)? = decoder.failure
            else { return [.string(""), .int(0), .string(""), .string("")] }
            return [.string(value), .int(offset), .string(strct), .string(field)]
        case "$json.context":
            guard case .decoder(let decoder) = try walk() else { throw GoRuntimeError.typeMismatch }
            let (strct, field, found) = decoder.context(field: try text(1))
            return [.string(strct), .string(field), .bool(found)]
        case "$json.release":
            let handle = try integer(0)
            if walks.removeValue(forKey: handle) != nil { host.release(handle) }
            return []
        case "$json.valid":
            if let error = GoJSONText.check(try host.bytes(operands[0])) {
                return [.string(error.message), .int(error.offset)]
            }
            return [.string(""), .int(0)]
        case "$json.compact":
            guard case .bool(let escape) = operands[2] else { throw GoRuntimeError.typeMismatch }
            let (bytes, error) = GoJSONText.compact(
                try host.bytes(operands[0]), try host.bytes(operands[1]), escape: escape)
            return [try host.makeBytes(bytes), .string(error?.message ?? ""), .int(error?.offset ?? 0)]
        case "$json.indent":
            let (bytes, error) = GoJSONText.indent(
                try host.bytes(operands[0]), try host.bytes(operands[1]), prefix: Array(try text(2).utf8),
                indent: Array(try text(3).utf8))
            return [try host.makeBytes(bytes), .string(error?.message ?? ""), .int(error?.offset ?? 0)]
        case "$json.scanValue":
            guard case .bool(let atEnd) = operands[1] else { throw GoRuntimeError.typeMismatch }
            let (length, count, message) = GoJSONText.valueEnd(try host.bytes(operands[0]), atEnd: atEnd)
            return [.int(Int64(length)), .int(Int64(count)), .string(message)]
        default:
            return [.string(GoJSONScanner.quoteChar(UInt8(truncatingIfNeeded: try integer(0))))]
        }
    }
}
