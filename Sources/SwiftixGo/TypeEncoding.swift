/// Encodes a `GoType` as the descriptor an interface value carries.
///
/// The format is defined with its decoder, `GoTypeDescriptor` in
/// `SwiftixGoRuntime`: the type in prefix notation, then one line per named
/// type it reaches with that type's underlying type. A named type keeps the
/// name the compiler and the VM know it by, which is also how its methods are
/// named; the runtime prints Go's spelling. Output depends only on the type
/// and the definitions, so the same type always encodes to the same text and
/// identical sources encode identically.

struct GoTypeEncoder {
    let definitions: [String: GoTypeDefinition]
    /// Declared name of the package whose type names carry no qualifier,
    /// for the signatures that are kept as text.
    let packageName: String

    /// Named types still to be defined, in the order they were reached.
    private var pending: [String] = []
    private var reached: Set<String> = []

    init(definitions: [String: GoTypeDefinition], packageName: String) {
        self.definitions = definitions
        self.packageName = packageName
    }

    /// The descriptor of `type`, without the marker that introduces it.
    mutating func descriptor(of type: GoType) -> String {
        var text = encode(type)
        var next = 0
        while next < pending.count {
            let name = pending[next]
            next += 1
            guard let definition = definitions[name] else { continue }
            text += "\n" + counted(name) + encode(definition.underlying)
        }
        return text
    }

    /// Go's spelling of a type name: `main.point` for a type of the package
    /// being compiled, `lib.Point` for a linker symbol `path/to/lib.Point`.
    func goName(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return packageName + "." + name }
        let path = name[..<dot]
        return (path.split(separator: "/").last.map(String.init) ?? String(path)) + name[dot...]
    }

    private func counted(_ text: String) -> String {
        "\(text.utf8.count):" + text
    }

    private mutating func encode(_ type: GoType) -> String {
        switch type {
        case .int: return "i"
        case .string: return "s"
        case .bool: return "t"
        case .void, .nilType: return "a"
        case .named(let name):
            if name == "byte" { return "b" }
            // A library type has no definition here and prints by name.
            guard definitions[name] != nil else { return "O" + counted(name) }
            if reached.insert(name).inserted { pending.append(name) }
            return "N" + counted(name)
        case .pointer(let pointee): return "*" + encode(pointee)
        case .slice(let element): return "[" + encode(element)
        case .array(let length, let element): return "A\(length);" + encode(element)
        case .map(let key, let value): return "M" + encode(key) + encode(value)
        case .structure(let fields):
            var text = "S\(fields.count);"
            for field in fields { text += counted(field.name) + encode(field.type) }
            return text
        case .channel(let direction, let element):
            let code: Int
            switch direction {
            case .bidirectional: code = 0
            case .sendOnly: code = 1
            case .receiveOnly: code = 2
            }
            return "C\(code)" + encode(element)
        case .interface(let methods):
            if methods.isEmpty { return "a" }
            if methods == [GoInterfaceMethod(name: "Error", results: [.string])] { return "e" }
            let listed = methods.sorted { $0.name < $1.name }.map {
                $0.name + signature(parameters: $0.parameters, results: $0.results)
            }
            return "I" + counted("interface { " + listed.joined(separator: "; ") + " }")
        case .function(let parameters, let results):
            return "O" + counted("func" + signature(parameters: parameters, results: results))
        }
    }

    /// `(int, string) error`, the way Go prints a signature.
    private func signature(parameters: [GoType], results: [GoType]) -> String {
        let list = "(" + parameters.map(goTypeName).joined(separator: ", ") + ")"
        switch results.count {
        case 0: return list
        case 1: return list + " " + goTypeName(results[0])
        default: return list + " (" + results.map(goTypeName).joined(separator: ", ") + ")"
        }
    }

    /// The text Go prints for a type that appears inside a signature.
    private func goTypeName(_ type: GoType) -> String {
        switch type {
        case .named(let name):
            if name == "byte" { return "uint8" }
            return definitions[name] == nil ? name : goName(name)
        case .pointer(let pointee): return "*" + goTypeName(pointee)
        case .slice(let element): return "[]" + goTypeName(element)
        case .array(let length, let element): return "[\(length)]" + goTypeName(element)
        case .map(let key, let value):
            return "map[" + goTypeName(key) + "]" + goTypeName(value)
        case .interface(let methods):
            if methods.isEmpty { return "interface {}" }
            if methods == [GoInterfaceMethod(name: "Error", results: [.string])] { return "error" }
            return "interface {...}"
        default: return type.description
        }
    }
}
