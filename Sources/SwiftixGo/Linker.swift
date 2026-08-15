/// Single-package symbol resolution and executable-layout validation for Swiftix Go.

public enum GoSinglePackageLinker {
    public static func link(
        entryPoint: String,
        initializers: [String],
        globalCount: Int,
        functions: [GoIRFunction],
        externalSymbols: Set<String> = []
    ) throws -> GoIRProgram {
        guard globalCount >= 0 else { throw linkError("invalid global storage size") }

        var symbols: Set<String> = externalSymbols
        for function in functions {
            guard symbols.insert(function.name).inserted else {
                throw linkError("duplicate symbol: \(function.name)")
            }
        }
        guard symbols.contains(entryPoint) else {
            throw linkError("undefined entry point: \(entryPoint)")
        }
        for initializer in initializers where !symbols.contains(initializer) {
            throw linkError("undefined initializer: \(initializer)")
        }

        for function in functions {
            for operation in function.operations {
                switch operation {
                case .call(let target, _, _):
                    guard symbols.contains(target) else {
                        throw linkError("undefined symbol: \(target)")
                    }
                case .loadGlobal(_, let index), .storeGlobal(let index, _),
                    .addressGlobal(_, let index):
                    guard index >= 0, index < globalCount else {
                        throw linkError("invalid global slot \(index)")
                    }
                default:
                    continue
                }
            }
        }

        return GoIRProgram(
            entryPoint: entryPoint,
            initializers: initializers,
            globalCount: globalCount,
            functions: functions)
    }

    private static func linkError(_ message: String) -> GoDiagnostic {
        GoDiagnostic(
            position: GoSourcePosition(
                path: "<link>",
                offset: 0,
                line: 1,
                column: 1),
            message: message)
    }
}
