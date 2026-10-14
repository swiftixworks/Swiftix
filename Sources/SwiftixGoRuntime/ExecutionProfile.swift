#if SWIFTIX_GO_PROFILE
/// What a run executed, instruction by instruction: how many of each kind,
/// in each function, and the hottest sequences of two and three.
///
/// It exists only in a build compiled with `-DSWIFTIX_GO_PROFILE`, so an
/// ordinary build carries neither the type nor the per-instruction hook.
/// A harness sets `current` before a run and reads it afterwards.
public final class GoExecutionProfile: @unchecked Sendable {
    public nonisolated(unsafe) static var current: GoExecutionProfile?

    public private(set) var instructions = 0
    public private(set) var byKind: [String: Int] = [:]
    public private(set) var byFunction: [String: Int] = [:]
    public private(set) var pairs: [String: Int] = [:]
    public private(set) var triples: [String: Int] = [:]
    private var kinds: [String: [String]] = [:]
    private var previous: (String, String)?
    private var previousFunction = ""

    public init() {}

    func record(_ function: GoBytecodeFunction, programCounter: Int) {
        instructions += 1
        let kind: String
        if let names = kinds[function.name] {
            kind = names[programCounter]
        } else {
            let names = function.instructions.map(Self.kind(of:))
            kinds[function.name] = names
            kind = names[programCounter]
        }
        byKind[kind, default: 0] += 1
        byFunction[function.name, default: 0] += 1
        if previousFunction != function.name { previous = nil }
        previousFunction = function.name
        if let (first, second) = previous {
            pairs[second + " ; " + kind, default: 0] += 1
            triples[first + " ; " + second + " ; " + kind, default: 0] += 1
            previous = (second, kind)
        } else {
            previous = ("", kind)
        }
    }

    /// The instruction's case, with the callee of a call: `call fmt.Println`.
    static func kind(of instruction: GoInstruction) -> String {
        switch instruction {
        case .call(let name, _): return "call " + name
        case .callInterface(let name, _): return "callInterface " + name
        case .strings(let function): return "strings.\(function)"
        default:
            let text = String(describing: instruction)
            if let open = text.firstIndex(of: "(") { return String(text[..<open]) }
            return text
        }
    }

    /// The largest entries of `table`, most executed first.
    public static func top(_ table: [String: Int], _ count: Int) -> [(String, Int)] {
        Array(table.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(count)).map { ($0.key, $0.value) }
    }
}
#endif
