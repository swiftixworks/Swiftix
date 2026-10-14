/// The library that came with the numeric types: the constants of `math`
/// and `unicode/utf8`, and the functions of `strconv`, `unicode`,
/// `unicode/utf8`, `strings`, and `math` that take or give a sized integer,
/// a rune, or a floating-point number.
///
/// A constant is a value of the compiler, exact like any other. A function
/// is a reserved call the VM runs (`GoNumeric` in the runtime).

enum GoNumberLibrary {
    /// The untyped constant `package.member`, or nil when the library has
    /// none of that name.
    static func constant(package: String, member: String) -> GoConstant? {
        func integer(_ value: GoBigInt, kind: GoConstant.Kind = .integer) -> GoConstant {
            .untyped(value, kind: kind, isPlain: false)
        }
        switch (package, member) {
        case ("math", "MaxInt"): return integer(GoNumericKind.int.integerRange.upperBound)
        case ("math", "MinInt"): return integer(GoNumericKind.int.integerRange.lowerBound)
        case ("math", "MaxUint"): return integer(GoNumericKind.uint.integerRange.upperBound)
        case ("math", _):
            // `MaxInt8`, `MinInt32`, `MaxUint16`: a bound of a sized type.
            for kind in GoNumericKind.allCases where kind.isInteger && kind.rawValue.last?.isNumber == true {
                let name = kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst()
                if member == "Max" + name { return integer(kind.integerRange.upperBound) }
                if member == "Min" + name, kind.isSigned {
                    return integer(kind.integerRange.lowerBound)
                }
            }
            return floatConstant(member)
        case ("utf8", "RuneError"), ("unicode", "ReplacementChar"):
            return integer(GoBigInt(Int64(0xFFFD)), kind: .rune)
        case ("utf8", "MaxRune"), ("unicode", "MaxRune"):
            return integer(GoBigInt(Int64(0x10FFFF)), kind: .rune)
        case ("time", _):
            return durationConstant(member)
        case ("utf8", "UTFMax"): return integer(GoBigInt(Int64(4)))
        case ("utf8", "RuneSelf"): return integer(GoBigInt(Int64(0x80)))
        default: return nil
        }
    }

    /// The units of `time`, which are constants of type `time.Duration`, so
    /// `const timeout = 5 * time.Second` is one too and an overflowing
    /// product is Go's compile error. They are plain: `time.Duration` is an
    /// `int64`, which the VM computes exactly, so an expression of them that
    /// stays within 64 bits is compiled as it was before they were constants.
    static func durationConstant(_ member: String) -> GoConstant? {
        guard let value = GoStandardLibrary.integerConstant(package: "time", member: member) else {
            return nil
        }
        return GoConstant(
            value: GoRational(GoBigInt(value)), kind: .integer, type: GoLibraryTypes.duration,
            isPlain: true)
    }

    /// The floating-point constants of `math`, as its source spells them.
    static func floatConstant(_ member: String) -> GoConstant? {
        guard GoNumericKind.floatsAreSupported else { return nil }
        let spelling: String
        switch member {
        case "E": spelling = "2.71828182845904523536028747135266249775724709369995957496696763"
        case "Pi": spelling = "3.14159265358979323846264338327950288419716939937510582097494459"
        case "Phi": spelling = "1.61803398874989484820458683436563811772030917980576286213544862"
        case "Sqrt2": spelling = "1.41421356237309504880168872420969807856967187537694807317667974"
        case "SqrtE": spelling = "1.64872127070012814684865078781416357165377610071014801157507931"
        case "SqrtPi": spelling = "1.77245385090551602729816748334114518279754945612238712821380779"
        case "SqrtPhi": spelling = "1.27201964951406896425242246173749149171560804184009624861664038"
        case "Ln2": spelling = "0.693147180559945309417232121458176568075500134360255254120680009"
        case "Log2E": spelling = "1.44269504088896340735992468100189213742664595415298593413544940693"
        case "Ln10": spelling = "2.30258509299404568401799145468436420760110148862877297603332790"
        case "Log10E": spelling = "0.43429448190325182765112891891660508229439700580366656611445378316"
        case "MaxFloat32": spelling = "0x1.fffffep127"
        case "SmallestNonzeroFloat32": spelling = "0x1p-149"
        case "MaxFloat64": spelling = "0x1.fffffffffffffp1023"
        case "SmallestNonzeroFloat64": spelling = "0x1p-1074"
        default: return nil
        }
        guard let literal = GoNumberLiteral.value(of: spelling) else { return nil }
        return GoConstant(value: literal.value, kind: .float, type: nil, isPlain: false)
    }

    /// Native functions reached as `package.Member(...)`.
    static func nativeFunction(package: String, member: String) -> GoNativeFunction? {
        let int64 = GoNumericKind.int64.type
        let uint64 = GoNumericKind.uint64.type
        let rune = GoPredeclared.rune
        let failure = GoPredeclared.errorType
        func function(_ parameters: [GoType], _ results: [GoType]) -> GoNativeFunction {
            let name = package + "." + member
            return GoNativeFunction(
                symbol: "$" + name, goName: name, parameters: parameters, results: results)
        }
        switch (package, member) {
        case ("strconv", "ParseInt"): return function([.string, .int, .int], [int64, failure])
        case ("strconv", "ParseUint"): return function([.string, .int, .int], [uint64, failure])
        case ("strconv", "FormatInt"): return function([int64, .int], [.string])
        case ("strconv", "FormatUint"): return function([uint64, .int], [.string])
        case ("unicode", "IsDigit"), ("unicode", "IsLetter"), ("unicode", "IsSpace"),
            ("unicode", "IsUpper"), ("unicode", "IsLower"):
            return function([rune], [.bool])
        case ("unicode", "ToUpper"), ("unicode", "ToLower"):
            return function([rune], [rune])
        case ("utf8", "RuneCountInString"): return function([.string], [.int])
        case ("utf8", "ValidString"): return function([.string], [.bool])
        case ("utf8", "RuneLen"): return function([rune], [.int])
        case ("utf8", "DecodeRuneInString"): return function([.string], [rune, .int])
        case ("utf8", "EncodeRune"):
            return function([.slice(GoPredeclared.byte), rune], [.int])
        case ("strings", "ContainsRune"): return function([.string, rune], [.bool])
        case ("strings", "IndexRune"): return function([.string, rune], [.int])
        case ("strings", "IndexByte"): return function([.string, GoPredeclared.byte], [.int])
        default: return floatFunction(package: package, member: member)
        }
    }

    /// The functions that take or give a floating-point number.
    static func floatFunction(package: String, member: String) -> GoNativeFunction? {
        guard GoNumericKind.floatsAreSupported else { return nil }
        let float = GoPredeclared.float64
        func function(_ parameters: [GoType], _ results: [GoType]) -> GoNativeFunction {
            let name = package + "." + member
            return GoNativeFunction(
                symbol: "$" + name, goName: name, parameters: parameters, results: results)
        }
        switch (package, member) {
        case ("math", "Sqrt"), ("math", "Floor"), ("math", "Ceil"), ("math", "Trunc"),
            ("math", "Round"), ("math", "RoundToEven"), ("math", "Abs"), ("math", "Log"),
            ("math", "Exp"):
            return function([float], [float])
        case ("math", "Max"), ("math", "Min"), ("math", "Pow"), ("math", "Mod"),
            ("math", "Copysign"):
            return function([float, float], [float])
        case ("math", "Inf"): return function([.int], [float])
        case ("math", "NaN"): return function([], [float])
        case ("math", "IsNaN"), ("math", "Signbit"): return function([float], [.bool])
        case ("math", "IsInf"): return function([float, .int], [.bool])
        case ("math", "Float64bits"): return function([float], [GoNumericKind.uint64.type])
        case ("math", "Float64frombits"): return function([GoNumericKind.uint64.type], [float])
        case ("math", "Float32bits"):
            return function([GoNumericKind.float32.type], [GoNumericKind.uint32.type])
        case ("math", "Float32frombits"):
            return function([GoNumericKind.uint32.type], [GoNumericKind.float32.type])
        case ("strconv", "ParseFloat"):
            return function([.string, .int], [float, GoPredeclared.errorType])
        case ("strconv", "FormatFloat"):
            return function([float, GoPredeclared.byte, .int, .int], [.string])
        case ("sort", "Float64s"): return function([.slice(float)], [])
        default: return nil
        }
    }

    /// Whether `name` is a reserved call of this library or one of the
    /// operations the lowerer emits for a number.
    static func isCallName(_ name: String) -> Bool {
        name.hasPrefix("$num.") || callNames.contains(name)
    }

    private static let callNames: Set<String> = [
        "$strconv.ParseInt", "$strconv.ParseUint", "$strconv.FormatInt", "$strconv.FormatUint",
        "$unicode.IsDigit", "$unicode.IsLetter", "$unicode.IsSpace", "$unicode.IsUpper",
        "$unicode.IsLower", "$unicode.ToUpper", "$unicode.ToLower",
        "$utf8.RuneCountInString", "$utf8.ValidString", "$utf8.RuneLen",
        "$utf8.DecodeRuneInString", "$utf8.EncodeRune",
        "$strings.ContainsRune", "$strings.IndexRune", "$strings.IndexByte",
        "$math.Sqrt", "$math.Floor", "$math.Ceil", "$math.Trunc", "$math.Round",
        "$math.RoundToEven", "$math.Abs", "$math.Max", "$math.Min", "$math.Pow", "$math.Mod",
        "$math.Log", "$math.Exp",
        "$math.Copysign", "$math.Inf", "$math.NaN", "$math.IsNaN", "$math.Signbit",
        "$math.IsInf", "$math.Float64bits", "$math.Float64frombits", "$math.Float32bits",
        "$math.Float32frombits", "$strconv.ParseFloat", "$strconv.FormatFloat",
        "$sort.Float64s",
    ]
}

extension GoNumberLibrary {
    /// The natives that read a number, as the Go text of `strconv` calls
    /// them: `native.ParseInt(s, base, bitSize)` is `$strconv.ParseInt`.
    /// They fail with the text of Go's error, which the text makes Go's
    /// `*strconv.NumError`; a program's `strconv.ParseInt` is the text's.
    static func parsingFunction(_ name: String) -> GoNativeFunction? {
        guard ["ParseInt", "ParseUint", "ParseFloat"].contains(name) else { return nil }
        return nativeFunction(package: "strconv", member: name)
    }
}
