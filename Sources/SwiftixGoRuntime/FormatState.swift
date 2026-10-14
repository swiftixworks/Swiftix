/// Go's `fmt.Formatter` and `fmt.GoStringer` at run time.
///
/// Go's `fmt` asks a value how it prints before anything else: a `Format`
/// method prints it under every verb but `%T` and `%p`, and a `GoString`
/// method under `%#v`. A native cannot run the program's code, so `fmt`
/// asks for a guest call (see `replayingGuestCalls`) of a function made
/// here, whose result is the text: for `Format` it makes the `fmt.State`,
/// calls the method with it, and returns what the method wrote.
///
/// The state is Go's `*fmt.pp`: an interface value of that type around a
/// handle, whose methods are functions here that call natives on it, so a
/// `Format` method reaches them through its `fmt.State` like any method of
/// an interface. What it holds lives in the VM, by the handle, from the
/// call that makes it to the one that takes its text.
struct GoFormatState {
    /// The dynamic type of the state, as `%T` prints it.
    static let typeName = "*fmt.pp"

    /// The flags, width, and precision of the verb.
    var flags: Set<Unicode.Scalar> = []
    var width: Int?
    var precision: Int?
    /// What `Write` was given.
    var bytes: [UInt8] = []

    static let makeNative = "$fmt.pp.new"
    static let textNative = "$fmt.pp.text"

    /// The natives of the state and how many operands each takes; the
    /// receiver is the handle.
    static let argumentCounts: [String: Int] = [
        makeNative: 1, textNative: 1,
        "$fmt.pp.Write": 2, "$fmt.pp.WriteString": 2, "$fmt.pp.Width": 1,
        "$fmt.pp.Precision": 1, "$fmt.pp.Flag": 2,
    ]

    /// The methods of `*fmt.pp`, by the name a method of a program type
    /// would have.
    static let functions: [String: GoBytecodeFunction] = {
        var functions: [String: GoBytecodeFunction] = [:]
        for (method, operands, results) in [
            ("Write", 2, 2), ("WriteString", 2, 2), ("Width", 1, 2), ("Precision", 1, 2),
            ("Flag", 2, 1),
        ] {
            let name = typeName + "." + method
            functions[name] = GoBytecodeFunction(
                name: name, parameterCount: operands, returnCount: results, localCount: operands,
                instructions: (0..<operands).map(GoInstruction.load)
                    + [
                        .call("$fmt.pp." + method, argumentCount: operands),
                        .returnValues(count: results),
                    ])
        }
        return functions
    }()

    /// The state `directive` describes, written as the operand of
    /// `makeNative`: the flags, then the width and the precision.
    static func settings(of directive: GoFormat.Directive) -> GoValue {
        var text = ""
        if directive.minus { text += "-" }
        if directive.plus || directive.labelsFields { text += "+" }
        if directive.sharp || directive.goSyntax { text += "#" }
        if directive.space { text += " " }
        if directive.zero, !directive.minus { text += "0" }
        text += ";" + (directive.width.map(String.init) ?? "")
        text += ";" + (directive.precision.map(String.init) ?? "")
        return .string(text)
    }

    /// The state the operand of `makeNative` describes.
    init?(settings: GoValue) {
        guard case .string(let text) = settings else { return nil }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        flags = Set(parts[0].unicodeScalars)
        width = Int(parts[1])
        precision = Int(parts[2])
    }

    /// The function `fmt` runs for a value whose `Format` method is
    /// `format`. It takes the receiver, the verb, and the settings, and
    /// returns what the method wrote.
    static func caller(of format: GoBytecodeFunction) -> GoBytecodeFunction {
        GoBytecodeFunction(
            name: "$fmt.Format." + format.name, parameterCount: 3, returnCount: 1, localCount: 4,
            instructions: [
                .load(2), .call(makeNative, argumentCount: 1), .store(3),
                .load(0), .load(3), .load(1), .call(format.name, argumentCount: 3),
                .load(3), .call(textNative, argumentCount: 1),
                .returnValues(count: 1),
            ])
    }

    /// The method `name` of the dynamic type `owner` (`T` or `*T`) when it
    /// takes `parameterCount` arguments besides its receiver and returns
    /// `resultCount` values. A pointer also has the methods of what it
    /// points to.
    static func method(
        _ name: String, of owner: String, parameterCount: Int, resultCount: Int,
        in functions: [String: GoBytecodeFunction]
    ) -> GoBytecodeFunction? {
        var owners = [owner]
        if owner.hasPrefix("*") { owners.append(String(owner.dropFirst())) }
        for candidate in owners {
            if let function = functions[candidate + "." + name],
                function.parameterCount == parameterCount + 1,
                function.returnCount == resultCount
            {
                return function
            }
        }
        return nil
    }
}
