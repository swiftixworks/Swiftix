/// Go `fmt` verbs for `Sprintf`, `Printf`, `Fprintf`, and `Errorf`.
///
/// `render` walks a format string the way Go's `doPrintf` does: flags, width,
/// precision, verb, and Go's own markers for a mistake (`%!d(string=hi)`,
/// `%!d(MISSING)`, `%!(EXTRA int=1)`). The scalar functions follow Go's
/// `fmtInteger`, `fmtS`, `fmtSbx`, `fmtQ`, `fmtC`, and `fmtUnicode`. The VM
/// supplies the operands and walks slices, structs, and maps, because only it
/// can read the heap. Pure functions of their arguments; no process or
/// executor state.

enum GoFormat {
    /// One `fmt` function as the VM runs it.
    struct Native: Equatable {
        enum Destination: Equatable {
            /// The result is the text.
            case string
            /// The result is an error with the text as its message.
            case error
            case standardOutput
            /// The first operand is the `*os.File` to write to.
            case file
        }

        enum Layout: Equatable {
            /// A format string, then the operands of its verbs: `Printf`.
            case verbs
            /// Operands, with a space between two that are not strings: `Print`.
            case operands
            /// Operands separated by spaces, then a newline: `Println`.
            case line
        }

        let destination: Destination
        let layout: Layout
        /// Whether Go's `(n int, err error)` is pushed after the write. A
        /// call compiled as a statement asks for none.
        var returnsCount = false

        /// Operands before the ones that are formatted.
        var fixedArgumentCount: Int {
            (destination == .file ? 1 : 0) + (layout == .verbs ? 1 : 0)
        }
    }

    /// Type name that marks the last operand as a `[]any` given as
    /// `values...`: its elements are the operands.
    static let spreadOperandsTypeName = "$spread"

    /// Methods `fmt` prints a value with, in the order Go looks for them.
    static let textMethods = ["Error", "String"]

    /// Type name of the interface value that carries what a method `fmt`
    /// called panicked with. No Go type and no other reserved name has it.
    static let panicMarker = "$panic"

    /// What Go prints for a method it could not call on a nil pointer.
    static let nilText = "<nil>"

    /// Verbs under which Go prints a value by its `Error` or `String` method.
    static func usesTextMethod(_ directive: Directive) -> Bool {
        !directive.goSyntax && ["v", "s", "x", "X", "q"].contains(directive.verb)
    }

    /// Suffix of the call name of an output function whose `(n, err)` is read.
    static let countSuffix = ".n"

    /// The `fmt` function a reserved call name denotes.
    static func native(named name: String) -> Native? {
        let returnsCount = name.hasSuffix(countSuffix)
        let base = returnsCount ? String(name.dropLast(countSuffix.utf8.count)) : name
        var native: Native
        switch base {
        case "$fmt.Sprintf": native = Native(destination: .string, layout: .verbs)
        case "$fmt.Sprint": native = Native(destination: .string, layout: .operands)
        case "$fmt.Sprintln": native = Native(destination: .string, layout: .line)
        case "$fmt.Errorf": native = Native(destination: .error, layout: .verbs)
        case "$fmt.Printf": native = Native(destination: .standardOutput, layout: .verbs)
        case "$fmt.Print": native = Native(destination: .standardOutput, layout: .operands)
        case "$fmt.Println": native = Native(destination: .standardOutput, layout: .line)
        case "$fmt.Fprintf": native = Native(destination: .file, layout: .verbs)
        case "$fmt.Fprint": native = Native(destination: .file, layout: .operands)
        case "$fmt.Fprintln": native = Native(destination: .file, layout: .line)
        default: return nil
        }
        // Only a write has a count to return.
        if returnsCount {
            guard native.destination == .standardOutput || native.destination == .file else {
                return nil
            }
            native.returnsCount = true
        }
        return native
    }

    /// Go's cap on a width or precision taken from an operand, and the value
    /// past which a width or precision in the format takes no further digit.
    static let maximumCount = 1_000_000

    /// One `%` directive after its width and precision are known.
    struct Directive: Equatable, Sendable {
        var verb: Unicode.Scalar
        var minus = false
        var plus = false
        var sharp = false
        var space = false
        var zero = false
        var width: Int?
        var precision: Int?
        /// `%+v`: struct fields are printed with their names.
        var labelsFields = false
        /// `%#v`: the value in Go syntax.
        var goSyntax = false
        /// A `%w` of `fmt.Errorf`, which prints an error as `%v` does.
        var wraps = false
    }

    /// The operands of one `Printf`-style call, as `render` needs them.
    struct Operands {
        let count: Int
        /// Operand `index` when it is an integer, for a `*` width or precision.
        let integer: (Int) -> Int64?
        /// Operand `index` under a directive.
        let format: (Int, Directive) throws -> String
        /// `type=value` of operand `index`, or `<nil>`, for the EXTRA marker.
        let describe: (Int) throws -> String
        /// Told the index of each operand a `%w` of `fmt.Errorf` names.
        var wrapped: (Int) -> Void = { _ in }
    }

    /// Format `format` with `operands`. `wrapsErrors` is `fmt.Errorf`, where
    /// `%w` names an error to wrap. A result longer than `limit` bytes throws
    /// `overflow`.
    static func render(
        _ format: String,
        operands: Operands,
        wrapsErrors: Bool = false,
        limit: Int,
        overflow: GoRuntimeError
    ) throws -> String {
        let scalars = Array(format.unicodeScalars)
        var output = String.UnicodeScalarView()
        var byteCount = 0
        var next = 0

        func emit(_ text: String) throws {
            let count = text.utf8.count
            guard count <= limit - byteCount else { throw overflow }
            byteCount += count
            output.append(contentsOf: text.unicodeScalars)
        }
        /// A run of decimal digits at `index`, nil when it passes Go's cap.
        /// Like Go's `parsenum`, the cap is tested before each further digit,
        /// so the largest number accepted has one digit more than the cap.
        func number(_ index: inout Int) -> (value: Int, present: Bool)? {
            var value = 0
            var present = false
            while index < scalars.count, ("0"..."9").contains(scalars[index]) {
                guard value <= maximumCount else { return nil }
                value = value * 10 + Int(scalars[index].value - 0x30)
                present = true
                index += 1
            }
            return (value, present)
        }
        /// The next operand as a width or precision.
        func count() -> Int? {
            guard next < operands.count else { return nil }
            defer { next += 1 }
            guard let value = operands.integer(next), abs(value) <= Int64(maximumCount) else {
                return nil
            }
            return Int(value)
        }

        // Set by an explicit argument index, after which Go reports no
        // operand as extra.
        var reordered = false
        var index = 0
        while index < scalars.count {
            let literalStart = index
            while index < scalars.count, scalars[index] != "%" { index += 1 }
            if index > literalStart {
                var literal = String.UnicodeScalarView()
                literal.append(contentsOf: scalars[literalStart..<index])
                try emit(String(literal))
            }
            guard index < scalars.count else { break }
            index += 1

            var directive = Directive(verb: "v")
            var goodArgument = true
            /// Go's `argNumber`: a `[n]` selects the operand used next.
            /// Returns whether one was found.
            func argumentNumber() -> Bool {
                guard index < scalars.count, scalars[index] == "[" else { return false }
                reordered = true
                guard scalars.count - index >= 3,
                    let close = scalars[(index + 1)...].firstIndex(of: "]")
                else {
                    index += 1
                    goodArgument = false
                    return false
                }
                var cursor = index + 1
                let parsed = number(&cursor)
                index = close + 1
                guard let parsed, parsed.present, cursor == close else {
                    goodArgument = false
                    return false
                }
                if parsed.value >= 1, parsed.value <= operands.count {
                    next = parsed.value - 1
                } else {
                    goodArgument = false
                }
                return true
            }
            flags: while index < scalars.count {
                switch scalars[index] {
                case "#": directive.sharp = true
                case "0": directive.zero = !directive.minus
                case "+": directive.plus = true
                case "-":
                    directive.minus = true
                    directive.zero = false
                case " ": directive.space = true
                default: break flags
                }
                index += 1
            }
            var afterIndex = argumentNumber()
            if index < scalars.count, scalars[index] == "*" {
                index += 1
                if let width = count() {
                    directive.width = abs(width)
                    if width < 0 {
                        directive.minus = true
                        directive.zero = false
                    }
                } else {
                    try emit("%!(BADWIDTH)")
                }
                afterIndex = false
            } else {
                guard let width = number(&index) else {
                    try emit("%!(NOVERB)")
                    break
                }
                if width.present {
                    directive.width = width.value
                    // `%[3]2d`: an index must be followed by `*` or the verb.
                    if afterIndex { goodArgument = false }
                }
            }
            // A `.` that ends the format is the verb, as in Go.
            if index + 1 < scalars.count, scalars[index] == "." {
                index += 1
                if afterIndex { goodArgument = false }
                afterIndex = argumentNumber()
                if index < scalars.count, scalars[index] == "*" {
                    index += 1
                    // Go marks a negative precision like one that is no integer.
                    if let precision = count(), precision >= 0 {
                        directive.precision = precision
                    } else {
                        try emit("%!(BADPREC)")
                    }
                    afterIndex = false
                } else {
                    guard let precision = number(&index) else {
                        try emit("%!(NOVERB)")
                        break
                    }
                    directive.precision = precision.value
                }
            }
            if !afterIndex { afterIndex = argumentNumber() }
            guard index < scalars.count else {
                try emit("%!(NOVERB)")
                break
            }
            directive.verb = scalars[index]
            index += 1

            if directive.verb == "%" {
                try emit("%")
            } else if !goodArgument {
                try emit("%!\(directive.verb)(BADINDEX)")
            } else if next >= operands.count {
                try emit("%!\(directive.verb)(MISSING)")
            } else {
                // `%w` of `fmt.Errorf` takes the flags of `%v`; whether its
                // operand is an error is for the caller to say.
                directive.wraps = directive.verb == "w" && wrapsErrors
                if directive.wraps { operands.wrapped(next) }
                if directive.verb == "v" || directive.wraps {
                    directive.goSyntax = directive.sharp
                    directive.sharp = false
                    directive.labelsFields = directive.plus
                    directive.plus = false
                }
                try emit(try operands.format(next, directive))
                next += 1
            }
        }
        if !reordered, next < operands.count {
            var extra = "%!(EXTRA "
            for operand in next..<operands.count {
                if operand > next { extra += ", " }
                extra += try operands.describe(operand)
            }
            try emit(extra + ")")
        }
        return String(output)
    }

    // MARK: - Scalars

    /// An integer under `directive`, or nil when the verb does not apply.
    /// `unsigned` is a `uint8`, which `%#v` prints in hexadecimal.
    static func integer(_ value: Int64, _ directive: Directive, unsigned: Bool = false) -> String? {
        switch directive.verb {
        case "v" where directive.goSyntax && unsigned:
            var hexadecimal = directive
            hexadecimal.sharp = true
            return digits(value, base: 16, hexadecimal)
        case "v", "d": return digits(value, base: 10, directive)
        case "b": return digits(value, base: 2, directive)
        case "o", "O": return digits(value, base: 8, directive)
        case "x", "X": return digits(value, base: 16, directive)
        case "c": return pad(String(Character(scalar(value))), directive)
        case "q": return pad(quote(scalar(value), asciiOnly: directive.plus), directive)
        case "U":
            var text = String(value.magnitude, radix: 16, uppercase: true)
            let minimum = max(4, directive.precision ?? 0)
            if text.count < minimum { text = String(repeating: "0", count: minimum - text.count) + text }
            text = "U+" + text
            if directive.sharp, let narrowed = UInt32(exactly: value),
                let character = Unicode.Scalar(narrowed), GoUnicode.isPrint(character)
            {
                text += " '" + String(Character(character)) + "'"
            }
            var spaces = directive
            spaces.zero = false
            return pad(text, spaces)
        default: return nil
        }
    }

    /// A string under `directive`, or nil when the verb does not apply.
    static func string(_ value: String, _ directive: Directive) -> String? {
        switch directive.verb {
        case "v" where directive.goSyntax: return quoted(truncated(value, directive), directive)
        case "v", "s": return pad(truncated(value, directive), directive)
        case "x", "X": return hexadecimal(Array(value.utf8), directive)
        case "q": return quoted(truncated(value, directive), directive)
        default: return nil
        }
    }

    /// A `[]byte` under `directive`, or nil when the verb applies to each
    /// byte as an integer instead of to the bytes as text.
    static func bytes(_ value: [UInt8], _ directive: Directive) -> String? {
        switch directive.verb {
        case "s": return pad(truncated(String(decoding: value, as: UTF8.self), directive), directive)
        case "x", "X": return hexadecimal(value, directive)
        case "q": return quoted(truncated(String(decoding: value, as: UTF8.self), directive), directive)
        default: return nil
        }
    }

    /// The address of a pointer, slice, map, or channel under `directive`, or
    /// nil when the verb does not apply: Go's `fmtPointer` without `%#v`.
    static func address(_ value: UInt64, _ directive: Directive) -> String? {
        var hexadecimal = directive
        switch directive.verb {
        case "v":
            hexadecimal.sharp = true
        case "p":
            // `%#p` drops the `0x`.
            hexadecimal.sharp = !directive.sharp
        case "b": return digits(magnitude: value, negative: false, base: 2, directive)
        case "o": return digits(magnitude: value, negative: false, base: 8, directive)
        case "d": return digits(magnitude: value, negative: false, base: 10, directive)
        case "x", "X": return digits(magnitude: value, negative: false, base: 16, directive)
        default: return nil
        }
        hexadecimal.verb = "x"
        return digits(magnitude: value, negative: false, base: 16, hexadecimal)
    }

    /// A bool under `directive`, or nil when the verb does not apply.
    static func boolean(_ value: Bool, _ directive: Directive) -> String? {
        guard directive.verb == "v" || directive.verb == "t" else { return nil }
        return pad(value ? "true" : "false", directive)
    }

    /// Go's marker for a verb that does not apply: `%!d(string=hi)`.
    static func badVerb(_ directive: Directive, typeName: String, value: String) -> String {
        "%!\(directive.verb)(\(typeName)=\(value))"
    }

    /// Go's marker for a nil operand under a verb other than `%v`.
    static func badVerb(_ directive: Directive) -> String {
        "%!\(directive.verb)(<nil>)"
    }

    /// Pad `text` to the directive's width, counted in code points: on the
    /// left with spaces or zeros, or on the right with spaces after `-`.
    static func pad(_ text: String, _ directive: Directive) -> String {
        guard let width = directive.width else { return text }
        let missing = width - text.unicodeScalars.count
        guard missing > 0 else { return text }
        if directive.minus { return text + String(repeating: " ", count: missing) }
        return String(repeating: directive.zero ? "0" : " ", count: missing) + text
    }

    /// Go's `strconv.Quote`, or `QuoteToASCII` with `asciiOnly`.
    static func quote(_ text: String, asciiOnly: Bool) -> String {
        var result = "\""
        for scalar in text.unicodeScalars { result += escaped(scalar, quote: "\"", asciiOnly: asciiOnly) }
        return result + "\""
    }

    /// Go's `strconv.QuoteRune`, or `QuoteRuneToASCII` with `asciiOnly`.
    static func quote(_ scalar: Unicode.Scalar, asciiOnly: Bool) -> String {
        "'" + escaped(scalar, quote: "'", asciiOnly: asciiOnly) + "'"
    }

    /// The order Go prints two map keys in: integers by value, strings by
    /// their bytes, `false` before `true`, structs and arrays by their first
    /// difference, and nil first. Keys it cannot order compare equal.
    static func keyOrder(_ lhs: GoValue, _ rhs: GoValue) -> Int {
        func rank(_ value: GoValue) -> Int {
            switch value {
            case .nilValue: return 0
            case .bool: return 1
            case .int: return 2
            case .string: return 3
            case .pointer: return 4
            case .structure: return 5
            case .array: return 6
            default: return 7
            }
        }
        func sign<T: Comparable>(_ left: T, _ right: T) -> Int {
            left < right ? -1 : (left > right ? 1 : 0)
        }
        func first(_ left: [GoValue], _ right: [GoValue]) -> Int {
            for (a, b) in zip(left, right) {
                let order = keyOrder(a, b)
                if order != 0 { return order }
            }
            return sign(left.count, right.count)
        }
        switch (lhs, rhs) {
        case (.interface(let left), _): return keyOrder(left.value, rhs)
        case (_, .interface(let right)): return keyOrder(lhs, right.value)
        case (.int(let left), .int(let right)): return sign(left, right)
        case (.bool(let left), .bool(let right)): return sign(left ? 1 : 0, right ? 1 : 0)
        case (.string(let left), .string(let right)):
            if left.utf8.elementsEqual(right.utf8) { return 0 }
            return left.utf8.lexicographicallyPrecedes(right.utf8) ? -1 : 1
        case (.pointer(let left), .pointer(let right)): return sign(left.cell, right.cell)
        case (.structure(let left), .structure(let right)):
            return first(left.fields.map(\.value), right.fields.map(\.value))
        case (.array(let left), .array(let right)): return first(left, right)
        default: return sign(rank(lhs), rank(rhs))
        }
    }

    // MARK: - Helpers

    /// The code point `value` names, or U+FFFD when it names none.
    private static func scalar(_ value: Int64) -> Unicode.Scalar {
        UInt32(exactly: value).flatMap(Unicode.Scalar.init) ?? "\u{FFFD}"
    }

    /// The first `precision` code points of `text`.
    private static func truncated(_ text: String, _ directive: Directive) -> String {
        guard let precision = directive.precision, text.unicodeScalars.count > precision else {
            return text
        }
        var prefix = String.UnicodeScalarView()
        prefix.append(contentsOf: text.unicodeScalars.prefix(precision))
        return String(prefix)
    }

    private static func quoted(_ text: String, _ directive: Directive) -> String {
        if directive.sharp, canBackquote(text) { return pad("`" + text + "`", directive) }
        return pad(quote(text, asciiOnly: directive.plus), directive)
    }

    /// Go's `strconv.CanBackquote`: no backquote and no control character
    /// other than a tab.
    private static func canBackquote(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            scalar != "`" && scalar != "\u{FEFF}" && scalar != "\u{7F}"
                && (scalar.value >= 0x20 || scalar == "\t")
        }
    }

    private static func escaped(
        _ scalar: Unicode.Scalar,
        quote: Unicode.Scalar,
        asciiOnly: Bool
    ) -> String {
        if scalar == quote || scalar == "\\" { return "\\" + String(Character(scalar)) }
        switch scalar {
        case "\u{07}": return "\\a"
        case "\u{08}": return "\\b"
        case "\u{0C}": return "\\f"
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "\t": return "\\t"
        case "\u{0B}": return "\\v"
        default: break
        }
        if scalar.isASCII ? GoUnicode.isPrint(scalar) : (!asciiOnly && GoUnicode.isPrint(scalar)) {
            return String(Character(scalar))
        }
        let hex = String(scalar.value, radix: 16)
        func padded(_ length: Int) -> String {
            String(repeating: "0", count: max(0, length - hex.count)) + hex
        }
        if scalar.value < 0x80 { return "\\x" + padded(2) }
        return scalar.value > 0xFFFF ? "\\U" + padded(8) : "\\u" + padded(4)
    }

    private static func digits(_ value: Int64, base: Int, _ directive: Directive) -> String {
        digits(magnitude: value.magnitude, negative: value < 0, base: base, directive)
    }

    /// Go's `fmtInteger`: sign, base prefix, and digits padded to the
    /// precision, or to the width under the zero flag.
    private static func digits(
        magnitude: UInt64,
        negative: Bool,
        base: Int,
        _ directive: Directive
    ) -> String {
        var spaces = directive
        spaces.zero = false
        let signed = negative || directive.plus || directive.space
        var minimum = 0
        if let precision = directive.precision {
            if precision == 0, magnitude == 0 { return pad("", spaces) }
            minimum = precision
        } else if directive.zero, let width = directive.width {
            minimum = signed ? width - 1 : width
        }
        var text = String(magnitude, radix: base, uppercase: directive.verb == "X")
        if text.count < minimum { text = String(repeating: "0", count: minimum - text.count) + text }
        if directive.verb == "O" {
            text = "0o" + text
        } else if directive.sharp {
            switch base {
            case 2: text = "0b" + text
            case 8: if !text.hasPrefix("0") { text = "0" + text }
            case 16: text = (directive.verb == "X" ? "0X" : "0x") + text
            default: break
            }
        }
        if negative {
            text = "-" + text
        } else if directive.plus {
            text = "+" + text
        } else if directive.space {
            text = " " + text
        }
        return pad(text, spaces)
    }

    /// Go's `fmtSbx`: two hex digits per byte, with `#` for a `0x` prefix and
    /// a space flag to separate the bytes.
    private static func hexadecimal(_ value: [UInt8], _ directive: Directive) -> String {
        let length = min(value.count, directive.precision ?? value.count)
        let prefix = directive.verb == "X" ? "0X" : "0x"
        var text = ""
        for (offset, byte) in value.prefix(length).enumerated() {
            if directive.space, offset > 0 { text += " " }
            if directive.sharp, directive.space || offset == 0 { text += prefix }
            let pair = String(byte, radix: 16, uppercase: directive.verb == "X")
            text += pair.count == 1 ? "0" + pair : pair
        }
        return pad(text, directive)
    }
}
