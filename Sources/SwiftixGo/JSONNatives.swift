/// The natives of `encoding/json`'s text: a walk over a value that writes
/// its JSON, a walk over JSON that builds a value, each kept by the VM under
/// a handle while the text calls a method the walk stopped for, and Go's
/// scanner for what is built on it alone. See `JSONEncoder.swift` and
/// `JSONDecoder.swift` in the runtime. Pure value transformation; no
/// executor state.
enum GoJSONLibrary {
    /// The reserved call `name` of the package's text.
    static func textNative(_ name: String) -> GoNativeFunction? {
        let bytes = GoType.slice(GoPredeclared.byte)
        let any = GoType.interface([])
        let int64 = GoNumericKind.int64.type
        let signature: (parameters: [GoType], results: [GoType])
        switch name {
        // value, flags -> handle
        case "encodeStart": signature = ([any, .int], [.int])
        // handle -> code, value for a method, text
        case "encodeRun", "decodeRun": signature = ([.int], [.int, any, .string])
        // handle -> the text written
        case "encoded", "raw": signature = ([.int], [bytes])
        // handle -> message and offset of an error
        case "failure": signature = ([.int], [.string, int64])
        // handle, what a method returned
        case "resume": signature = ([.int, bytes], [])
        case "release": signature = ([.int], [])
        // text, target, flags -> handle
        case "decodeStart": signature = ([bytes, any, .int], [.int])
        // handle -> value, offset, struct, field of an UnmarshalTypeError
        case "typeError": signature = ([.int], [.string, int64, .string, .string])
        // handle, field -> struct, field, whether there is a context
        case "context": signature = ([.int, .string], [.string, .string, .bool])
        // text -> message and offset of its syntax error
        case "valid": signature = ([bytes], [.string, int64])
        case "compact": signature = ([bytes, bytes, .bool], [bytes, .string, int64])
        case "indent": signature = ([bytes, bytes, .string, .string], [bytes, .string, int64])
        // buffered text, at the end of the input -> length, bytes scanned, error
        case "scanValue": signature = ([bytes, .bool], [.int, .int, .string])
        case "quoteChar": signature = ([GoPredeclared.byte], [.string])
        default: return nil
        }
        return GoNativeFunction(
            symbol: "$json." + name, goName: "json." + name,
            parameters: signature.parameters, results: signature.results)
    }

    /// The call names of those.
    static let nativeCallNames = [
        "encodeStart", "encodeRun", "encoded", "failure", "resume", "release", "decodeStart",
        "decodeRun", "raw", "typeError", "context", "valid", "compact", "indent", "scanValue",
        "quoteChar",
    ].map { "$json." + $0 }
}
