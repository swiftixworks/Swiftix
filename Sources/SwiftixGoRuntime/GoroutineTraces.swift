/// Where the instructions of each function came from, for the goroutine
/// trace Go prints after an unrecovered panic:
///
///     panic: runtime error: index out of range [3] with length 1
///
///     goroutine 1 [running]:
///     main.(*T).get(...)
///         /home/user/m/main.go:8 +0x1c
///     main.main()
///         /home/user/m/main.go:20 +0x2a
///
/// The compiler writes it beside the executable it makes. It is not part of
/// the image: an image has the bytes it had before there were traces, and
/// two executables are equal whatever their tables say. A run of an image
/// read back from its bytes (a built program run as a process) therefore
/// names each function but cannot say where it is, and prints `?:0` as Go
/// does for a frame it knows nothing of.
public struct GoSourceLines: Sendable, Equatable {
    /// One function: its name as Go prints it, its file, and for each
    /// instruction offset at which a statement begins, that statement's line.
    public struct Function: Sendable {
        public let goName: String
        public let path: String
        /// Whether Go prints `(...)` after the name rather than `()`: the
        /// function has parameters or a receiver.
        public let hasArguments: Bool
        public let offsets: [Int]
        public let lines: [Int]

        public init(goName: String, path: String, hasArguments: Bool, offsets: [Int], lines: [Int]) {
            self.goName = goName
            self.path = path
            self.hasArguments = hasArguments
            self.offsets = offsets
            self.lines = lines
        }

        /// The line of the statement the instruction at `offset` belongs to:
        /// the last that begins at or before it.
        func line(at offset: Int) -> Int? {
            var low = 0
            var high = offsets.count
            while low < high {
                let middle = (low + high) / 2
                if offsets[middle] <= offset { low = middle + 1 } else { high = middle }
            }
            return low == 0 ? nil : lines[low - 1]
        }
    }

    public var functions: [String: Function] = [:]

    public init() {}

    public var isEmpty: Bool { functions.isEmpty }

    /// Tables never make two executables different.
    public static func == (_: GoSourceLines, _: GoSourceLines) -> Bool { true }
}

/// A frame of a goroutine when a panic began: the function and the offset of
/// the instruction it was executing.
struct GoTraceFrame: Sendable {
    let function: GoBytecodeFunction
    let offset: Int
}

/// The text of Go's goroutine trace.
enum GoTraceback {
    /// How the compiler names the function of a literal.
    static let literalPrefix = "$literal."

    /// What follows the lines that say what panicked: a blank line, the
    /// goroutine, and each frame from the innermost out. The offsets are the
    /// VM's instruction offsets within the function and the arguments are
    /// never shown, so each frame is `name(...)`, or `name()` for a function
    /// without parameters, as Go prints a frame it inlined.
    static func text(
        goroutine: Int, frames: [GoTraceFrame], lines: GoSourceLines
    ) -> String {
        var out = "\n\ngoroutine \(goroutine + 1) [running]:"
        for frame in frames.reversed() {
            let symbol = frame.function.name
            // Wrappers the compiler made have no place in the source.
            guard !symbol.hasPrefix("$native.") else { continue }
            let known = lines.functions[symbol]
            let hasArguments = known?.hasArguments ?? (frame.function.parameterCount > 0)
            out += "\n" + (known?.goName ?? goName(of: symbol))
            out += hasArguments ? "(...)" : "()"
            var position = "?:0"
            if let known, let line = known.line(at: frame.offset) {
                position = "\(known.path):\(line)"
            }
            out += "\n\t\(position) +0x" + String(frame.offset, radix: 16)
        }
        return out
    }

    /// The name Go gives the function of the image named `symbol`, where the
    /// compiler wrote no table: `main.f` for `f`, `main.(*T).m` for `*T.m`,
    /// `io/fs.(*PathError).Error` for `*io/fs.PathError.Error`. A literal,
    /// whose Go name says where it stands among the literals of its
    /// function, is named by the offset of its text: `main.func·215`.
    static func goName(of symbol: String) -> String {
        if symbol.hasPrefix(literalPrefix), let dot = symbol.lastIndex(of: ".") {
            return "main.func·" + symbol[symbol.index(after: dot)...]
        }
        if symbol == "main" || !symbol.contains(".") { return "main." + symbol }
        guard symbol.hasPrefix("*") else { return symbol }
        let body = symbol.dropFirst()
        guard let methodDot = body.lastIndex(of: ".") else { return symbol }
        let receiver = body[..<methodDot]
        let method = body[body.index(after: methodDot)...]
        guard let typeDot = receiver.lastIndex(of: ".") else {
            return "main.(*\(receiver)).\(method)"
        }
        let package = receiver[..<typeDot]
        let type = receiver[receiver.index(after: typeDot)...]
        return "\(package).(*\(type)).\(method)"
    }
}

extension GoSourceLines {
    /// The table as text, one function a line, for a build cache to keep
    /// beside an image: `symbol`, the Go name, the path, `1` when the
    /// function has arguments, the offsets, and the lines, separated by
    /// tabs. A function whose names hold a tab or a line break is left out.
    public var encoded: [UInt8] {
        var text = ""
        for (symbol, function) in functions.sorted(by: { $0.key < $1.key }) {
            let fields = [symbol, function.goName, function.path]
            guard !fields.contains(where: { $0.contains("\t") || $0.contains("\n") }) else {
                continue
            }
            text += fields.joined(separator: "\t") + "\t" + (function.hasArguments ? "1" : "0")
            text += "\t" + function.offsets.map(String.init).joined(separator: ",")
            text += "\t" + function.lines.map(String.init).joined(separator: ",") + "\n"
        }
        return Array(text.utf8)
    }

    /// The table `encoded` wrote, or nil for anything else.
    public init?(encoded bytes: [UInt8]) {
        self.init()
        let text = String(decoding: bytes, as: UTF8.self)
        for row in text.split(separator: "\n") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 6 else { return nil }
            func numbers(_ field: Substring) -> [Int]? {
                field.isEmpty ? [] : field.split(separator: ",").map { Int($0) }.reduce([]) {
                    guard let list = $0, let value = $1 else { return nil }
                    return list + [value]
                }
            }
            guard let offsets = numbers(fields[4]), let lines = numbers(fields[5]),
                offsets.count == lines.count
            else { return nil }
            functions[String(fields[0])] = Function(
                goName: String(fields[1]), path: String(fields[2]),
                hasArguments: fields[3] == "1", offsets: offsets, lines: lines)
        }
    }
}
