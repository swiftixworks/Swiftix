/// Embedded fields of struct types and embedded interfaces.
///
/// `type derived struct { base; name string }` gives `derived` a field named
/// `base` and lends it what `base` has: `d.id` is `d.base.id`, and `d.Describe()`
/// calls the method of `base`. `type J interface { I; N() }` has the methods
/// of `I` and `N`. Neither adds a case to the frozen syntax tree:
///
/// - An embedded field is a field like any other, named by its type, with
///   `isEmbedded` set. A struct value therefore prints, compares, copies, and
///   is zeroed as it always was.
/// - An embedded interface is carried as a method no program can write,
///   `$embed`, whose one result is the type embedded, so every pass that
///   rewrites names reads it as a type. `GoEmbedding.resolve` then puts the
///   methods of the interface in its place, on the syntax tree, and nothing
///   after it knows.
/// - A promoted method is found by the VM as every method is, by the name of
///   the dynamic type: `derived.Describe`. `GoEmbedding.resolve` therefore
///   declares that method, on the syntax tree, for each method Go promotes:
///   a function that selects the embedded field and calls its method. The
///   method set of `derived`, what it implements, a method value, a method
///   expression, and a call through an interface are then what they are for
///   a method the program declared.
/// - A promoted field has no such stand-in. The checker and the compiler ask
///   `GoEmbedding.promotion` which embedded fields lead to a name, and read
///   `d.id` as the `d.base.id` it abbreviates; they do the same for a method
///   that is called or selected directly, which then costs no call more
///   than the method itself.
///
/// Which name an embedded field lends is Go's rule: the shallowest depth at
/// which the name is found wins, and two at one depth are ambiguous, which is
/// an error only where the name is used.
enum GoEmbedding {
    /// The name of the method an embedded interface is carried as.
    static let interfaceMethodName = "$embed"
    /// The receiver of a method declared here for a promoted one, by which
    /// such a method is told from one the program declared.
    static let receiverName = "$promoted"

    /// The parameters of such a method, which only pass through it.
    static func parameterName(_ index: Int) -> String { "$argument.\(index)" }

    /// The files of a program with every interface holding the methods of
    /// those it embeds, and with a method declared for each one a struct
    /// type is lent by its embedded fields.
    static func resolve(_ files: [GoFile]) throws -> [GoFile] {
        guard files.contains(where: \.usesEmbedding) else { return files }
        return promotingMethods(in: try flatteningInterfaces(in: files))
    }
}

// MARK: Embedded interfaces

extension GoInterfaceMethodDeclaration {
    /// The entry of an interface type that embeds `type`.
    static func embedded(
        _ type: GoTypeExpression, position: GoSourcePosition
    ) -> GoInterfaceMethodDeclaration {
        GoInterfaceMethodDeclaration(
            name: GoEmbedding.interfaceMethodName, results: [type], position: position)
    }

    /// The type this entry embeds, when it is no method.
    var embeddedInterface: GoTypeExpression? {
        name == GoEmbedding.interfaceMethodName ? results.first : nil
    }
}

extension GoEmbedding {
    static func flatteningInterfaces(in files: [GoFile]) throws -> [GoFile] {
        var flattener = InterfaceFlattener(files: files)
        return try files.map { file in
            let types = try file.typeDeclarations.map { declaration in
                GoTypeDeclaration(
                    name: declaration.name,
                    type: try flattener.flattened(declaration),
                    isAlias: declaration.isAlias,
                    position: declaration.position)
            }
            let globals = try file.globalDeclarations.map { declaration in
                GoGlobalDeclaration(
                    name: declaration.name,
                    explicitType: try declaration.explicitType.map { try flattener.rewrite($0) },
                    expression: try declaration.expression.map { try flattener.rewrite($0) },
                    isConstant: declaration.isConstant,
                    position: declaration.position)
            }
            return file.rebuilt(
                imports: file.imports,
                typeDeclarations: types,
                globalDeclarations: globals,
                functions: try file.functions.map { try flattener.rewrite($0) })
        }
    }
}

/// Replaces each embedded interface by its methods. Names mean here what
/// they meant before: the walk is the scoped one only because that one
/// reaches every type a program writes.
private struct InterfaceFlattener: GoScopedRewriter {
    private var declarations: [String: GoTypeDeclaration] = [:]
    /// Where each type is declared among all of them, for the one that
    /// comes first in a cycle.
    private var order: [String: Int] = [:]
    /// The type an interface type written at a place declares, by the place.
    private var owners: [String: String] = [:]
    /// The methods of each interface a declaration names, once known.
    private var methods: [String: [GoInterfaceMethodDeclaration]] = [:]
    private var expanding: [String] = []

    init(files: [GoFile]) {
        for declaration in files.lazy.flatMap(\.typeDeclarations) {
            order[declaration.name] = declarations.count
            declarations[declaration.name] = declaration
            if case .interface = declaration.type, declaration.type.functionSignature == nil {
                owners[Self.key(declaration.type.position)] = declaration.name
            }
        }
    }

    private static func key(_ position: GoSourcePosition) -> String {
        "\(position.path):\(position.offset)"
    }

    mutating func openScope() {}
    mutating func closeScope() {}

    mutating func declare(_ name: String, at position: GoSourcePosition) -> String { name }

    mutating func value(named name: String, at position: GoSourcePosition) -> GoExpression {
        .identifier(name, position: position)
    }

    mutating func type(named name: String, at position: GoSourcePosition) -> GoTypeExpression {
        .named(name, position: position)
    }

    mutating func member(
        _ member: String, of qualifier: String,
        qualifierPosition: GoSourcePosition, position: GoSourcePosition
    ) -> GoExpression? {
        nil
    }

    mutating func localType(_ declaration: GoTypeDeclaration) -> [GoStatement] {
        [
            .localType(
                name: declaration.name, type: declaration.type, isAlias: declaration.isAlias,
                position: declaration.position)
        ]
    }

    mutating func interface(
        _ methods: [GoInterfaceMethodDeclaration], at position: GoSourcePosition
    ) throws -> GoTypeExpression {
        guard methods.contains(where: { $0.embeddedInterface != nil }) else {
            return .interface(methods: methods, position: position)
        }
        return .interface(
            methods: try merged(methods, owner: owners[Self.key(position)]), position: position)
    }

    /// The type `declaration` declares, an interface with its methods in
    /// place of what it embeds.
    mutating func flattened(_ declaration: GoTypeDeclaration) throws -> GoTypeExpression {
        guard case .interface(_, let position) = declaration.type,
            declaration.type.functionSignature == nil
        else { return try rewrite(declaration.type) }
        return .interface(methods: try methods(of: declaration.name), position: position)
    }

    /// The methods of the interface the declaration `name` declares.
    private mutating func methods(of name: String) throws -> [GoInterfaceMethodDeclaration] {
        if let known = methods[name] { return known }
        guard let declaration = declarations[name] else { return [] }
        if let start = expanding.firstIndex(of: name) {
            // Go names the type of the cycle that the source declares first.
            let cycle = expanding[start...]
            let first = cycle.min { (order[$0] ?? 0) < (order[$1] ?? 0) } ?? name
            throw GoDiagnostic(
                position: declarations[first]?.position ?? declaration.position,
                message: cycle.count == 1
                    ? "invalid recursive type: \(first) refers to itself"
                    : "invalid recursive type \(first)")
        }
        expanding.append(name)
        defer { expanding.removeLast() }
        guard case .interface(let found, _) = try rewrite(declaration.type) else { return [] }
        methods[name] = found
        return found
    }

    /// The methods of an interface type that has `entries`: its own, and
    /// in the place of each embedded interface the methods of that one. A
    /// method two of them have is there once when both say the same of it.
    private mutating func merged(
        _ entries: [GoInterfaceMethodDeclaration], owner: String?
    ) throws -> [GoInterfaceMethodDeclaration] {
        var explicit: [String: GoInterfaceMethodDeclaration] = [:]
        for entry in entries where entry.embeddedInterface == nil { explicit[entry.name] = entry }
        var result: [GoInterfaceMethodDeclaration] = []
        var taken: [String: GoInterfaceMethodDeclaration] = [:]
        for entry in entries {
            guard let embedded = entry.embeddedInterface else {
                if taken[entry.name] == nil {
                    taken[entry.name] = entry
                    result.append(entry)
                }
                continue
            }
            for method in try embeddedMethods(embedded, at: entry.position, owner: owner) {
                // Go takes the methods an interface declares first, so the
                // one that disagrees with them is the embedded one.
                if let other = explicit[method.name] ?? taken[method.name] {
                    guard other.hasSameSignature(as: method) else {
                        throw GoDiagnostic(
                            position: entry.position, message: "duplicate method \(method.name)")
                    }
                    continue
                }
                taken[method.name] = method
                result.append(method)
            }
        }
        return result
    }

    /// The methods of the interface `type` is, embedded at `position`.
    private mutating func embeddedMethods(
        _ type: GoTypeExpression, at position: GoSourcePosition, owner: String?
    ) throws -> [GoInterfaceMethodDeclaration] {
        // Anything but an interface makes a type constraint of the
        // interface, which only generic code has a use for.
        let constraint = GoDiagnostic(
            position: position,
            message: (owner.map { "cannot use type \($0) outside a type constraint: " } ?? "")
                + "interface contains type constraints")
        switch type {
        case .named("error", _):
            return [
                GoInterfaceMethodDeclaration(
                    name: "Error", results: [.named("string", position: position)],
                    position: position)
            ]
        case .named("any", _):
            return []
        case .named(let name, _):
            guard let declaration = declarations[name] else {
                if GoEmbedding.isPredeclaredType(name) { throw constraint }
                throw GoDiagnostic(position: position, message: "undefined: \(name)")
            }
            switch declaration.type {
            case .interface where declaration.type.functionSignature == nil:
                return try methods(of: name)
            case .named:
                // `type J I`: the interface `I` is.
                guard !expanding.contains(name) else { return try methods(of: name) }
                expanding.append(name)
                defer { expanding.removeLast() }
                return try embeddedMethods(declaration.type, at: position, owner: owner)
            default:
                throw constraint
            }
        case .interface(let entries, _) where type.functionSignature == nil:
            // What an alias for an interface type was replaced by.
            return try merged(entries, owner: nil)
        default:
            throw constraint
        }
    }
}

extension GoEmbedding {
    /// Whether `name` is a type every program has without declaring it.
    static func isPredeclaredType(_ name: String) -> Bool {
        switch name {
        case "int", "string", "bool", "byte", "uint8", "error", "any": return true
        default:
            return name.contains(".") || GoPredeclared.unsupportedNumericTypes.contains(name)
        }
    }
}

extension GoInterfaceMethodDeclaration {
    /// Whether `other` takes and gives the same types.
    func hasSameSignature(as other: GoInterfaceMethodDeclaration) -> Bool {
        parameters.count == other.parameters.count && results.count == other.results.count
            && zip(parameters, other.parameters).allSatisfy { $0.isSameType(as: $1) }
            && zip(results, other.results).allSatisfy { $0.isSameType(as: $1) }
    }
}

extension GoTypeExpression {
    /// Whether this is the type `other` is, wherever each is written. By
    /// the time it is asked every name is a name of the whole program.
    func isSameType(as other: GoTypeExpression) -> Bool {
        switch (self, other) {
        case (.named(let left, _), .named(let right, _)):
            func plain(_ name: String) -> String { name == "uint8" ? "byte" : name }
            return plain(left) == plain(right)
        case (.named("any", _), .interface(let methods, _)),
            (.interface(let methods, _), .named("any", _)):
            return methods.isEmpty
        case (.pointer(let left, _), .pointer(let right, _)),
            (.slice(let left, _), .slice(let right, _)):
            return left.isSameType(as: right)
        case (.array(let leftLength, let left, _), .array(let rightLength, let right, _)):
            return leftLength == rightLength && left.isSameType(as: right)
        case (.map(let leftKey, let left, _), .map(let rightKey, let right, _)):
            return leftKey.isSameType(as: rightKey) && left.isSameType(as: right)
        case (.channel(let leftDirection, let left, _), .channel(let rightDirection, let right, _)):
            return leftDirection == rightDirection && left.isSameType(as: right)
        case (.structure(let left, _), .structure(let right, _)):
            return left.count == right.count
                && zip(left, right).allSatisfy {
                    $0.name == $1.name && $0.isEmbedded == $1.isEmbedded && $0.tag == $1.tag
                        && $0.type.isSameType(as: $1.type)
                }
        case (.interface(let left, _), .interface(let right, _)):
            return left.count == right.count
                && left.allSatisfy { method in
                    right.contains { $0.name == method.name && $0.hasSameSignature(as: method) }
                }
        default:
            return false
        }
    }
}

// MARK: Embedded fields

/// What a type has for a struct that embeds it to be lent: its fields, of
/// which the embedded ones lead further, and its methods.
struct GoEmbeddedShape: Sendable, Equatable {
    struct Field: Sendable, Equatable {
        let name: String
        /// The named type of an embedded field, and whether the field is a
        /// pointer to it.
        var embedded: String? = nil
        var isPointer = false
    }

    enum Kind: Sendable, Equatable {
        /// A type of the program, whose methods are functions it declares.
        case declared
        /// An interface, whose methods are those of the value it holds.
        case interface
        /// A type of the run-time library.
        case library
    }

    var fields: [Field] = []
    /// The methods of the type itself, with whether each has a pointer
    /// receiver: those the program declares on it, not those it is lent.
    var methods: [String: Bool] = [:]
    var kind = Kind.declared
    /// For a type of the library: whether its methods are there for a
    /// field that is a pointer to it, or only for one that is not; nil
    /// when they are there for both.
    var requiresPointer: Bool? = nil
}

/// A field or method a struct type is lent, and how to reach it.
struct GoPromotion: Sendable, Equatable {
    /// The embedded fields to select before the name, outermost first.
    let path: [String]
    /// The type that has the field or method.
    let holder: String
    let holderKind: GoEmbeddedShape.Kind
    let isMethod: Bool
    /// For a method: whether its receiver is a pointer, and whether a
    /// pointer lies on the way to it, which makes that receiver reachable
    /// from a value of the struct.
    let hasPointerReceiver: Bool
    let isIndirect: Bool

    /// `base.name` with the embedded fields between them written out.
    func selector(
        _ name: String, of base: GoExpression, position: GoSourcePosition
    ) -> GoExpression {
        var expression = base
        for field in path {
            expression = .selector(base: expression, name: field, position: position)
        }
        return .selector(base: expression, name: name, position: position)
    }
}

enum GoPromotionLookup: Sendable, Equatable {
    /// The type has the name itself, or nothing lends it.
    case none
    /// Two embedded fields lend it at one depth.
    case ambiguous
    case found(GoPromotion)
}

extension GoEmbeddedShape.Field {
    init(_ field: GoStructFieldDeclaration) {
        name = field.name
        guard field.isEmbedded else { return }
        switch field.type {
        case .named(let typeName, _):
            embedded = typeName
        case .pointer(.named(let typeName, _), _):
            embedded = typeName
            isPointer = true
        default:
            break
        }
    }

    init(_ field: GoStructFieldType) {
        name = field.name
        guard field.isEmbedded else { return }
        switch field.type {
        case .named(let typeName):
            embedded = typeName
        case .pointer(.named(let typeName)):
            embedded = typeName
            isPointer = true
        case .interface where field.name == "error":
            // The one interface that has a name and no declaration.
            embedded = "error"
        default:
            break
        }
    }
}

extension GoEmbedding {
    /// The name and the form of the receiver of a method: `T` or `*T`.
    static func receiver(_ type: GoTypeExpression) -> (typeName: String, isPointer: Bool)? {
        switch type {
        case .named(let name, _): return (name, false)
        case .pointer(.named(let name, _), _): return (name, true)
        default: return nil
        }
    }

    /// What each type the program declares has to lend.
    static func shapes(of files: [GoFile]) -> [String: GoEmbeddedShape] {
        var declarations: [String: GoTypeExpression] = [:]
        for declaration in files.lazy.flatMap(\.typeDeclarations) {
            declarations[declaration.name] = declaration.type
        }
        var shapes: [String: GoEmbeddedShape] = [:]
        for (name, declared) in declarations {
            // The struct or interface the type is, whatever names it is
            // declared through: `type T U` has the fields of `U`, not its
            // methods.
            var underlying = declared
            var seen: Set<String> = [name]
            while case .named(let other, _) = underlying, seen.insert(other).inserted,
                let next = declarations[other]
            {
                underlying = next
            }
            var shape = GoEmbeddedShape()
            switch underlying {
            case .structure(let fields, _):
                shape.fields = fields.map(GoEmbeddedShape.Field.init)
            case .interface(let methods, _) where underlying.functionSignature == nil:
                shape.kind = .interface
                for method in methods { shape.methods[method.name] = false }
            case .named("error", _):
                shape = libraryShape("error") ?? shape
            default:
                break
            }
            shapes[name] = shape
        }
        for function in files.lazy.flatMap(\.functions) {
            guard let parameter = function.receiver, parameter.name != receiverName,
                let receiver = receiver(parameter.type), shapes[receiver.typeName]?.kind == .declared
            else { continue }
            shapes[receiver.typeName]?.methods[function.name] = receiver.isPointer
        }
        return shapes
    }

    /// What a type of the run-time library has to lend, or `error`.
    static func libraryShape(_ name: String) -> GoEmbeddedShape? {
        var shape = GoEmbeddedShape(kind: .library)
        switch name {
        case "error":
            shape.kind = .interface
            shape.methods = ["Error": false]
        case "sync.Mutex":
            shape.methods = ["Lock": true, "Unlock": true, "TryLock": true]
        case "sync.WaitGroup":
            shape.methods = ["Add": true, "Done": true, "Wait": true]
        case "time.Time":
            for method in timeMethods { shape.methods[method] = false }
            shape.requiresPointer = false
        case "os.File":
            for method in fileMethods { shape.methods[method] = true }
            shape.requiresPointer = true
        case GoLibraryTypes.connectionName, GoLibraryTypes.listenerName:
            // A handle is an interface, and lends its methods as one does.
            guard case .interface(let methods)? = GoLibraryTypes.handleInterface(of: name) else {
                return nil
            }
            shape.kind = .interface
            for method in methods { shape.methods[method.name] = false }
        default:
            guard GoLibraryStructs.lend(name, to: &shape) else { return nil }
        }
        return shape
    }

    /// The methods `GoStandardLibrary` has for `time.Time` and `*os.File`,
    /// which it knows by name alone.
    static let timeMethods = [
        "Unix", "UnixMilli", "UnixNano", "Sub", "Add", "Before", "After", "Equal",
    ] + GoTimeLibrary.addedTimeMethods
    static let fileMethods = [
        "Write", "WriteString", "Read", "ReadAt", "WriteAt", "Seek", "Close", "Sync",
    ]

    /// What `name` is of a struct with the shape `root` that the struct
    /// does not have itself: the field or method the embedded fields lend
    /// it at the shallowest depth, as Go selects it.
    static func lookup(
        _ name: String, in root: GoEmbeddedShape, named rootName: String?,
        shapes: (String) -> GoEmbeddedShape?
    ) -> GoPromotionLookup {
        if root.methods[name] != nil || root.fields.contains(where: { $0.name == name }) {
            return .none
        }
        struct Entry {
            let type: String
            let path: [String]
            let isPointer: Bool
            let isIndirect: Bool
        }
        var current = root.fields.compactMap { field in
            field.embedded.map {
                Entry(
                    type: $0, path: [field.name], isPointer: field.isPointer,
                    isIndirect: field.isPointer)
            }
        }
        // A type met again deeper has nothing a shallower one lacked.
        var seen: Set<String> = rootName.map { [$0] } ?? []
        while !current.isEmpty {
            var found: [GoPromotion] = []
            var next: [Entry] = []
            var reached: Set<String> = []
            for entry in current where !seen.contains(entry.type) {
                reached.insert(entry.type)
                guard let shape = shapes(entry.type) else { continue }
                let lends = shape.requiresPointer.map { $0 == entry.isPointer } ?? true
                if shape.fields.contains(where: { $0.name == name }) {
                    found.append(
                        GoPromotion(
                            path: entry.path, holder: entry.type, holderKind: shape.kind,
                            isMethod: false, hasPointerReceiver: false,
                            isIndirect: entry.isIndirect))
                } else if lends, let hasPointerReceiver = shape.methods[name] {
                    found.append(
                        GoPromotion(
                            path: entry.path, holder: entry.type, holderKind: shape.kind,
                            isMethod: true, hasPointerReceiver: hasPointerReceiver,
                            isIndirect: entry.isIndirect))
                }
                for field in shape.fields {
                    guard let embedded = field.embedded else { continue }
                    next.append(
                        Entry(
                            type: embedded, path: entry.path + [field.name],
                            isPointer: field.isPointer,
                            isIndirect: entry.isIndirect || field.isPointer))
                }
            }
            if found.count > 1 { return .ambiguous }
            if let only = found.first { return .found(only) }
            seen.formUnion(reached)
            current = next
        }
        return .none
    }

    /// What `name` is of a value of `type`, a struct or a pointer to one,
    /// that the struct does not have itself.
    static func promotion(
        of name: String, in type: GoType, definitions: [String: GoTypeDefinition]
    ) -> GoPromotionLookup {
        var root = type
        if case .pointer(let pointee) = type { root = pointee }
        let shape: GoEmbeddedShape
        var rootName: String?
        switch root {
        case .named(let typeName):
            // A program that embeds nothing has no shapes at all.
            guard let known = definitions[typeName]?.embedding else { return .none }
            shape = known
            rootName = typeName
        case .structure(let fields):
            guard fields.contains(where: \.isEmbedded) else { return .none }
            shape = GoEmbeddedShape(fields: fields.map(GoEmbeddedShape.Field.init))
        default:
            return .none
        }
        guard shape.fields.contains(where: { $0.embedded != nil }) else { return .none }
        return lookup(name, in: shape, named: rootName) {
            definitions[$0]?.embedding ?? libraryShape($0)
        }
    }

    /// Go's rules for what a struct type may embed, which need the
    /// declarations of the program to check.
    static func validate(_ files: [GoFile]) throws {
        var declarations: [String: GoTypeExpression] = [:]
        for declaration in files.lazy.flatMap(\.typeDeclarations) {
            declarations[declaration.name] = declaration.type
        }
        func underlying(_ name: String) -> GoTypeExpression? {
            var current = declarations[name]
            var seen: Set<String> = [name]
            while case .named(let other, _)? = current, seen.insert(other).inserted,
                let next = declarations[other]
            {
                current = next
            }
            return current
        }
        for declaration in files.lazy.flatMap(\.typeDeclarations) {
            guard case .structure(let fields, _) = declaration.type else { continue }
            for field in fields where field.isEmbedded {
                let embedded = GoEmbeddedShape.Field(field)
                guard let typeName = embedded.embedded else { continue }
                let type = typeName == "error" || typeName == "any" ? nil : underlying(typeName)
                var isInterface = typeName == "error" || typeName == "any"
                if case .interface? = type, type?.functionSignature == nil { isInterface = true }
                if case .named("error", _)? = type { isInterface = true }
                if embedded.isPointer, isInterface {
                    throw GoDiagnostic(
                        position: field.type.position,
                        message: "embedded field type cannot be a pointer to an interface")
                }
                if case .pointer? = type {
                    throw GoDiagnostic(
                        position: field.type.position,
                        message: "embedded field type cannot be a pointer")
                }
            }
        }
    }
}

// MARK: Promoted methods

extension GoEmbedding {
    /// The files with a method declared for each one an embedded field
    /// lends a struct type the program declares.
    ///
    /// They go after the functions of the last file, so that no function
    /// the program wrote changes its place among them all. A second run
    /// finds its own methods by their receiver and declares none again.
    static func promotingMethods(in files: [GoFile]) -> [GoFile] {
        guard
            files.contains(where: { file in
                file.usesEmbedding
                    && file.typeDeclarations.contains { declaration in
                        if case .structure(let fields, _) = declaration.type {
                            return fields.contains(where: \.isEmbedded)
                        }
                        return false
                    }
            })
        else { return files }
        let shapes = shapes(of: files)
        var declarations: [String: GoTypeExpression] = [:]
        for declaration in files.lazy.flatMap(\.typeDeclarations) {
            declarations[declaration.name] = declaration.type
        }
        var methods: [String: GoFunctionDeclaration] = [:]
        var promoted: Set<String> = []
        for function in files.lazy.flatMap(\.functions) {
            guard let parameter = function.receiver, let receiver = receiver(parameter.type)
            else { continue }
            let key = receiver.typeName + "." + function.name
            if parameter.name == receiverName {
                promoted.insert(key)
            } else {
                methods[key] = function
            }
        }
        func shape(_ name: String) -> GoEmbeddedShape? { shapes[name] ?? libraryShape(name) }

        var synthesized: [GoFunctionDeclaration] = []
        for declaration in files.lazy.flatMap(\.typeDeclarations) {
            guard let root = shapes[declaration.name], root.kind == .declared,
                root.fields.contains(where: { $0.embedded != nil })
            else { continue }
            for name in lentMethodNames(root, named: declaration.name, shapes: shape).sorted()
            where !promoted.contains(declaration.name + "." + name) {
                guard
                    case .found(let promotion) = lookup(
                        name, in: root, named: declaration.name, shapes: shape),
                    promotion.isMethod,
                    let signature = signature(
                        of: name, in: promotion, methods: methods, declarations: declarations,
                        position: declaration.position)
                else { continue }
                synthesized.append(
                    promotedMethod(
                        name, of: declaration.name, promotion: promotion, signature: signature,
                        position: declaration.position))
            }
        }
        guard !synthesized.isEmpty, let last = files.last else { return files }
        return files.dropLast()
            + [
                last.rebuilt(
                    imports: last.imports,
                    typeDeclarations: last.typeDeclarations,
                    globalDeclarations: last.globalDeclarations,
                    functions: last.functions + synthesized)
            ]
    }

    /// The names of every method of every type the embedded fields of
    /// `root` reach, whichever of them `root` is lent.
    private static func lentMethodNames(
        _ root: GoEmbeddedShape, named rootName: String, shapes: (String) -> GoEmbeddedShape?
    ) -> Set<String> {
        var names: Set<String> = []
        var seen: Set<String> = [rootName]
        var pending = root.fields.compactMap(\.embedded)
        while let name = pending.popLast() {
            guard seen.insert(name).inserted, let shape = shapes(name) else { continue }
            names.formUnion(shape.methods.keys)
            pending.append(contentsOf: shape.fields.compactMap(\.embedded))
        }
        return names
    }

    /// What the method `name` that `promotion` found takes and gives.
    private static func signature(
        of name: String, in promotion: GoPromotion, methods: [String: GoFunctionDeclaration],
        declarations: [String: GoTypeExpression], position: GoSourcePosition
    ) -> (parameters: [GoTypeExpression], results: [GoTypeExpression])? {
        switch promotion.holderKind {
        case .declared:
            guard let method = methods[promotion.holder + "." + name] else { return nil }
            return (method.parameters.map(\.type), method.resultTypes)
        case .interface:
            if promotion.holder == "error" {
                return ([], [.named("string", position: position)])
            }
            if promotion.holder == GoLibraryStructs.lockerName { return ([], []) }
            if case .interface(let lent)? = GoLibraryTypes.handleInterface(of: promotion.holder) {
                // A handle of the library, whose methods the library knows.
                guard let method = lent.first(where: { $0.name == name }) else { return nil }
                let parameters = method.parameters.map { written($0, at: position) }
                let results = method.results.map { written($0, at: position) }
                guard !parameters.contains(nil), !results.contains(nil) else { return nil }
                return (parameters.compactMap { $0 }, results.compactMap { $0 })
            }
            var type = declarations[promotion.holder]
            var seen: Set<String> = [promotion.holder]
            while case .named(let other, _)? = type, seen.insert(other).inserted {
                if other == "error" { return ([], [.named("string", position: position)]) }
                type = declarations[other]
            }
            guard case .interface(let entries, _)? = type,
                let method = entries.first(where: { $0.name == name })
            else { return nil }
            return (method.parameters, method.results)
        case .library:
            return librarySignature(of: name, holder: promotion.holder, position: position)
        }
    }

    /// What the method `name` of the library type `holder` takes and
    /// gives, written as types.
    private static func librarySignature(
        of name: String, holder: String, position: GoSourcePosition
    ) -> (parameters: [GoTypeExpression], results: [GoTypeExpression])? {
        switch (holder, name) {
        case ("sync.Mutex", "TryLock"):
            // Declared for no struct: a program that embeds a mutex and
            // never tries it is the image it was. Called or selected, it
            // is the method of the field.
            return nil
        case ("sync.Mutex", _), ("sync.WaitGroup", "Done"), ("sync.WaitGroup", "Wait"):
            return ([], [])
        case ("sync.WaitGroup", "Add"):
            return ([.named("int", position: position)], [])
        default:
            let receiver =
                holder == "os.File"
                ? GoPredeclared.filePointer
                : GoLibraryStructs.methodOwner(.named(holder)) ?? GoType.named(holder)
            guard let native = GoStandardLibrary.method(of: receiver, named: name) else {
                return nil
            }
            let parameters = native.parameters.dropFirst().map { written($0, at: position) }
            let results = native.results.map { written($0, at: position) }
            guard !parameters.contains(nil), !results.contains(nil) else { return nil }
            return (parameters.compactMap { $0 }, results.compactMap { $0 })
        }
    }

    /// `type` as a program would write it, for the types the methods of
    /// the library take and give.
    private static func written(_ type: GoType, at position: GoSourcePosition) -> GoTypeExpression? {
        switch type {
        case .int: return .named("int", position: position)
        case .string: return .named("string", position: position)
        case .bool: return .named("bool", position: position)
        case .named(let name): return .named(name, position: position)
        case .pointer(let pointee):
            return written(pointee, at: position).map { .pointer(pointee: $0, position: position) }
        case .slice(let element):
            return written(element, at: position).map { .slice(element: $0, position: position) }
        case .interface(let methods):
            if methods.isEmpty { return .named("any", position: position) }
            return type == GoPredeclared.errorType ? .named("error", position: position) : nil
        default:
            return nil
        }
    }

    /// The method `name` of `typeName` that selects the embedded fields
    /// `promotion` names and calls the method there with what it is given.
    ///
    /// Its receiver is a pointer where Go has the method in the method set
    /// of the pointer alone: the promoted method takes a pointer, and no
    /// pointer lies on the way to it.
    private static func promotedMethod(
        _ name: String, of typeName: String, promotion: GoPromotion,
        signature: (parameters: [GoTypeExpression], results: [GoTypeExpression]),
        position: GoSourcePosition
    ) -> GoFunctionDeclaration {
        let named = GoTypeExpression.named(typeName, position: position)
        let needsPointer = promotion.hasPointerReceiver && !promotion.isIndirect
        let parameters = signature.parameters.enumerated().map { index, type in
            GoParameter(name: parameterName(index), type: type, position: position)
        }
        let arguments = parameters.map { parameter -> GoExpression in
            let argument = GoExpression.identifier(parameter.name, position: position)
            if case .array(GoSpread.variadicLength, _, _) = parameter.type {
                return .spread(argument, position: position)
            }
            return argument
        }
        let call = GoExpression.call(
            callee: promotion.selector(
                name, of: .identifier(receiverName, position: position), position: position),
            arguments: arguments, position: position)
        return GoFunctionDeclaration(
            name: name,
            receiver: GoParameter(
                name: receiverName,
                type: needsPointer ? .pointer(pointee: named, position: position) : named,
                position: position),
            parameters: parameters,
            resultTypes: signature.results,
            body: GoBlock(
                statements: [
                    signature.results.isEmpty
                        ? .expression(call) : .returnValues([call], position: position)
                ],
                position: position),
            position: position)
    }
}
