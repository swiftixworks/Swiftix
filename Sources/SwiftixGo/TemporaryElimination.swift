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
/// It changes every image and the instruction count programs are charged,
/// so it is off: the compiler runs it only in a build compiled with
/// `-DSWIFTIX_GO_TEMPORARIES`, where `GoExecutable.eliminatingTemporaries()`
/// also applies it to an image that was already built.
enum GoTemporaryElimination {
    static func apply(to executable: GoExecutable) -> GoExecutable {
        GoExecutable(
            entryPoint: executable.entryPoint,
            initializers: executable.initializers,
            globalCount: executable.globalCount,
            functions: executable.functions.map(apply(to:)))
    }

    static func apply(to function: GoBytecodeFunction) -> GoBytecodeFunction {
        var instructions = function.instructions
        // The safepoints are left alone unless they are every program
        // counter, which is what the compiler emits.
        guard function.safepointProgramCounters == Array(0...instructions.count) else {
            return function
        }
        while let rewritten = eliminateOne(
            in: instructions, parameterCount: function.parameterCount)
        {
            instructions = rewritten
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

    /// One elimination, or nil when there is none left.
    private static func eliminateOne(
        in instructions: [GoInstruction],
        parameterCount: Int
    ) -> [GoInstruction]? {
        let table = uses(in: instructions)
        let targets = jumpTargets(in: instructions)
        for (local, use) in table.sorted(by: { $0.key < $1.key }) {
            guard local >= parameterCount, !use.pinned,
                use.stores.count == 1, use.loads.count == 1
            else { continue }
            let store = use.stores[0]
            let load = use.loads[0]
            guard store < load, !(store + 1...load).contains(where: targets.contains) else {
                continue
            }
            if load == store + 1 {
                var result = instructions
                result.removeSubrange(store...load)
                return remapped(result, removed: store...load, inserted: 0, at: store)
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
            else { continue }
            let definition = Array(instructions[start..<store])
            let inputs = Set(definition.compactMap { instruction -> Int? in
                if case .load(let local) = instruction { return local }
                return nil
            })
            let between = instructions[(store + 1)..<load]
            let movable = between.allSatisfy { instruction in
                if case .store(let local) = instruction { return !inputs.contains(local) }
                return pureStackEffect(instruction) != nil
            }
            guard movable else { continue }
            var result = Array(instructions[..<start])
            result += between
            result += definition
            result += instructions[(load + 1)...]
            return remapped(
                result, removed: start...load,
                inserted: between.count + definition.count, at: start)
        }
        return nil
    }

    /// `instructions` with its jump targets moved: the old instructions in
    /// `removed` became the `inserted` ones at `at`, and no jump lands
    /// inside that range except at its start.
    private static func remapped(
        _ instructions: [GoInstruction],
        removed: ClosedRange<Int>,
        inserted: Int,
        at start: Int
    ) -> [GoInstruction] {
        let shift = inserted - removed.count
        func map(_ target: Int) -> Int {
            target <= removed.lowerBound ? target : target + shift
        }
        return instructions.map { instruction in
            switch instruction {
            case .jump(let target): return .jump(map(target))
            case .jumpIfFalse(let target): return .jumpIfFalse(map(target))
            case .jumpIfTrue(let target): return .jumpIfTrue(map(target))
            case .select(let cases, let defaultTarget):
                return .select(
                    cases: cases.map { selectCase in
                        switch selectCase {
                        case .send(let channel, let value, let target):
                            return .send(channelLocal: channel, valueLocal: value, target: map(target))
                        case .receive(let channel, let destination, let ok, let zero, let target):
                            return .receive(
                                channelLocal: channel, destinationLocal: destination,
                                okLocal: ok, zeroLocal: zero, target: map(target))
                        }
                    },
                    defaultTarget: defaultTarget.map(map))
            default:
                return instruction
            }
        }
    }
}

#if SWIFTIX_GO_TEMPORARIES
extension GoExecutable {
    /// This image with the compiler's single-use temporaries removed (see
    /// `GoTemporaryElimination`).
    public func eliminatingTemporaries() -> GoExecutable {
        GoTemporaryElimination.apply(to: self)
    }
}
#endif
