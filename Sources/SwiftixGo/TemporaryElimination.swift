import SwiftixGoRuntime

/// A bytecode pass that removes the compiler's single-use temporaries.
///
/// The lowering gives every intermediate value a local of its own: an
/// operand is computed, stored, and loaded again where it is used
/// (`push 1; store 16; load 4; load 16; add`), and a result is stored and
/// loaded at once (`less; store 11; load 11; jumpIfFalse`). Locals and
/// stores cost a heap cell each, and these pairs are most of what a loop
/// executes. The pass
///
/// - deletes `store t; load t` when `t` is written and read once and nothing
///   can jump between them, and
/// - moves the side-effect-free code that computes a single-use `t` to where
///   `t` is loaded, when only side-effect-free code that does not change its
///   inputs lies between.
///
/// The table of source lines a panic's trace reads is kept in step: each
/// statement's first instruction is moved with the code. The pass runs on
/// every image the compiler emits; `GoExecutable.eliminatingTemporaries()`
/// applies it to an image built by an earlier compiler.
enum GoTemporaryElimination {
    /// Whether the compiler runs the pass; tests turn it off to compare
    /// an image with the one the pass makes of it.
    @TaskLocal static var isEnabled = true

    static func apply(to executable: GoExecutable) -> GoExecutable {
        var lines = executable.sourceLines
        var result = GoExecutable(
            entryPoint: executable.entryPoint,
            initializers: executable.initializers,
            globalCount: executable.globalCount,
            functions: executable.functions.map { function in
                let known = lines.functions[function.name]
                var offsets = known?.offsets ?? []
                let applied = apply(to: function, statementOffsets: &offsets)
                if let known, offsets != known.offsets {
                    lines.functions[function.name] = GoSourceLines.Function(
                        goName: known.goName, path: known.path,
                        hasArguments: known.hasArguments,
                        offsets: offsets, lines: known.lines)
                }
                return applied
            })
        result.sourceLines = lines
        return result
    }

    static func apply(to function: GoBytecodeFunction) -> GoBytecodeFunction {
        var offsets: [Int] = []
        return apply(to: function, statementOffsets: &offsets)
    }

    /// `function` with its temporaries removed, and `statementOffsets`, the
    /// first instruction of each statement, moved with them.
    static func apply(
        to function: GoBytecodeFunction, statementOffsets: inout [Int]
    ) -> GoBytecodeFunction {
        var instructions = function.instructions
        // The safepoints are left alone unless they are every program
        // counter, which is what the compiler emits.
        guard function.safepointProgramCounters == Array(0...instructions.count) else {
            return function
        }
        // Each round rewrites every temporary whose code does not overlap
        // another's; a rewrite can make room for another, so rounds repeat
        // until none is left. A round is one scan of the function, so a long
        // function costs a few scans, not one per temporary.
        while let (rewritten, moved) = eliminateRound(
            in: instructions, parameterCount: function.parameterCount)
        {
            instructions = rewritten
            statementOffsets = statementOffsets.map(moved)
        }
        guard instructions.count != function.instructions.count else { return function }
        return GoBytecodeFunction(
            name: function.name,
            parameterCount: function.parameterCount,
            returnCount: function.returnCount,
            localCount: function.localCount,
            instructions: instructions,
            rootLocalIndices: function.rootLocalIndices,
            safepointProgramCounters: Array(0...instructions.count))
    }

    /// How a local is used in a function.
    private struct Uses {
        var stores: [Int] = []
        var loads: [Int] = []
        /// Named some other way: its address taken, bound, made fresh, a
        /// result, or used by a `select`.
        var pinned = false
    }

    private static func uses(in instructions: [GoInstruction]) -> [Int: Uses] {
        var table: [Int: Uses] = [:]
        func pin(_ local: Int?) {
            if let local { table[local, default: Uses()].pinned = true }
        }
        for (index, instruction) in instructions.enumerated() {
            switch instruction {
            case .load(let local): table[local, default: Uses()].loads.append(index)
            case .store(let local): table[local, default: Uses()].stores.append(index)
            case .addressLocal(let local, _): pin(local)
            case .call(let name, _), .deferCall(let name, _), .spawn(let name, _):
                // `$fresh.<local>`, `$bind.<local>`, `$results.<local>...`
                guard name.hasPrefix("$") else { break }
                for part in name.split(separator: ".").dropFirst() { pin(Int(part)) }
            case .select(let cases, _):
                for selectCase in cases {
                    switch selectCase {
                    case .send(let channel, let value, _):
                        pin(channel)
                        pin(value)
                    case .receive(let channel, let destination, let ok, let zero, _):
                        pin(channel)
                        pin(destination)
                        pin(ok)
                        pin(zero)
                    }
                }
            default:
                break
            }
        }
        return table
    }

    private static func jumpTargets(in instructions: [GoInstruction]) -> Set<Int> {
        var targets: Set<Int> = []
        for instruction in instructions {
            switch instruction {
            case .jump(let target), .jumpIfFalse(let target), .jumpIfTrue(let target):
                targets.insert(target)
            case .select(let cases, let defaultTarget):
                if let defaultTarget { targets.insert(defaultTarget) }
                for selectCase in cases {
                    switch selectCase {
                    case .send(_, _, let target): targets.insert(target)
                    case .receive(_, _, _, _, let target): targets.insert(target)
                    }
                }
            default:
                break
            }
        }
        return targets
    }

    /// Operands taken and values left by an instruction that neither has an
    /// effect nor can panic; nil for any other.
    private static func pureStackEffect(_ instruction: GoInstruction) -> (pops: Int, pushes: Int)? {
        switch instruction {
        case .push, .load:
            return (0, 1)
        case .negate, .not, .length, .getField:
            return (1, 1)
        case .add, .subtract, .multiply, .equal, .notEqual, .less, .lessEqual, .greater,
            .greaterEqual, .logicalAnd, .logicalOr:
            return (2, 1)
        default:
            return nil
        }
    }

    /// One rewrite: the old instructions `start...load` become
    /// `replacement`. `between` is how many of the replacement's
    /// instructions come before the moved definition (0 when a pair was
    /// deleted), and `store` is where the definition's store was.
    private struct Rewrite {
        let start: Int
        let store: Int
        let load: Int
        let between: Int
        let replacement: [GoInstruction]
    }

    /// The rewrite of `local`, if it is a single-use temporary that can go.
    private static func rewrite(
        of use: Uses, in instructions: [GoInstruction], targets: Set<Int>
    ) -> Rewrite? {
        guard !use.pinned, use.stores.count == 1, use.loads.count == 1 else { return nil }
        let store = use.stores[0]
        let load = use.loads[0]
        guard store < load, !(store + 1...load).contains(where: targets.contains) else {
            return nil
        }
        if load == store + 1 {
            return Rewrite(start: store, store: store, load: load, between: 0, replacement: [])
        }
        // The code that computes the value: walk back until it has
        // produced exactly the one value the store takes.
        var needed = 1
        var start = store
        while needed > 0 {
            start -= 1
            guard start >= 0, let effect = pureStackEffect(instructions[start]) else {
                break
            }
            needed += effect.pops - effect.pushes
        }
        guard needed == 0, start >= 0,
            !(start + 1...store).contains(where: targets.contains)
        else { return nil }
        let definition = instructions[start..<store]
        let inputs = Set(definition.compactMap { instruction -> Int? in
            if case .load(let local) = instruction { return local }
            return nil
        })
        let between = instructions[(store + 1)..<load]
        let movable = between.allSatisfy { instruction in
            if case .store(let local) = instruction { return !inputs.contains(local) }
            return pureStackEffect(instruction) != nil
        }
        guard movable else { return nil }
        return Rewrite(
            start: start, store: store, load: load, between: between.count,
            replacement: Array(between) + Array(definition))
    }

    /// One round of rewrites, with where each old instruction offset moved,
    /// or nil when there is none left.
    ///
    /// Rewrites go together when the instructions they take out are apart
    /// and none's definition reads another's temporary: each definition
    /// then lands where its load was, whatever lies between, as it would
    /// alone. The elements of a long literal, each stored and then loaded
    /// in order, are all moved in one round.
    private static func eliminateRound(
        in instructions: [GoInstruction],
        parameterCount: Int
    ) -> ([GoInstruction], (Int) -> Int)? {
        let targets = jumpTargets(in: instructions)
        var rewrites: [(local: Int, rewrite: Rewrite)] = []
        for (local, use) in uses(in: instructions) where local >= parameterCount {
            if let rewrite = rewrite(of: use, in: instructions, targets: targets) {
                rewrites.append((local, rewrite))
            }
        }
        rewrites.sort { $0.rewrite.start < $1.rewrite.start }
        func loads(_ rewrite: Rewrite) -> Set<Int> {
            Set(instructions[rewrite.start..<rewrite.store].compactMap { instruction -> Int? in
                if case .load(let local) = instruction { return local }
                return nil
            })
        }
        var chosen: [Rewrite] = []
        var removed: Set<Int> = []
        var chosenLocals: Set<Int> = []
        var readByChosen: Set<Int> = []
        for (local, rewrite) in rewrites {
            let taken = Set(rewrite.start...rewrite.store).union([rewrite.load])
            let read = loads(rewrite)
            guard removed.isDisjoint(with: taken), chosenLocals.isDisjoint(with: read),
                !readByChosen.contains(local)
            else { continue }
            chosen.append(rewrite)
            removed.formUnion(taken)
            chosenLocals.insert(local)
            readByChosen.formUnion(read)
        }
        guard !chosen.isEmpty else { return nil }

        // Each kept instruction in its order, and each moved definition
        // where its load was.
        var definitionAt: [Int: Rewrite] = [:]
        for rewrite in chosen { definitionAt[rewrite.load] = rewrite }
        var result: [GoInstruction] = []
        result.reserveCapacity(instructions.count)
        var newIndex = [Int](repeating: -1, count: instructions.count + 1)
        for index in instructions.indices {
            if let rewrite = definitionAt[index] {
                newIndex[index] = result.count
                result += instructions[rewrite.start..<rewrite.store]
            } else if !removed.contains(index) {
                newIndex[index] = result.count
                result.append(instructions[index])
            }
        }
        newIndex[instructions.count] = result.count
        // An instruction taken out is where the next one that stays is now:
        // control that reached it reaches what followed it, the moved code
        // being pure.
        for index in stride(from: instructions.count - 1, through: 0, by: -1) where newIndex[index] < 0 {
            newIndex[index] = newIndex[index + 1]
        }
        let moved: (Int) -> Int = { offset in newIndex[min(max(offset, 0), instructions.count)] }
        return (retargeted(result, moved), moved)
    }

    /// `instructions` with each jump target given by `target` of the old one.
    private static func retargeted(
        _ instructions: [GoInstruction], _ target: (Int) -> Int
    ) -> [GoInstruction] {
        instructions.map { instruction in
            switch instruction {
            case .jump(let old): return .jump(target(old))
            case .jumpIfFalse(let old): return .jumpIfFalse(target(old))
            case .jumpIfTrue(let old): return .jumpIfTrue(target(old))
            case .select(let cases, let defaultTarget):
                return .select(
                    cases: cases.map { selectCase in
                        switch selectCase {
                        case .send(let channel, let value, let old):
                            return .send(channelLocal: channel, valueLocal: value, target: target(old))
                        case .receive(let channel, let destination, let ok, let zero, let old):
                            return .receive(
                                channelLocal: channel, destinationLocal: destination,
                                okLocal: ok, zeroLocal: zero, target: target(old))
                        }
                    },
                    defaultTarget: defaultTarget.map(target))
            default:
                return instruction
            }
        }
    }
}

extension GoExecutable {
    /// This image with the compiler's single-use temporaries removed (see
    /// `GoTemporaryElimination`).
    public func eliminatingTemporaries() -> GoExecutable {
        GoTemporaryElimination.apply(to: self)
    }
}
