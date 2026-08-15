/// Condition and arithmetic helpers used by shell scripting: `test` / `[`
/// (predicate → exit status) and `expr` (evaluate an expression → stdout +
/// status). They carry no control flow themselves; the shell's `if`/`while`
/// branch on the exit status these produce (`0` = true).
///
/// Kept intentionally small: string, integer, and file predicates for `test`;
/// binary integer arithmetic and comparisons for `expr`. They join
/// `CommandRegistry.builtins` via `BuiltinCommands.all()`.
extension BuiltinCommands {

    static func controlCommands() -> [Command] {
        [
            // test EXPR / [ EXPR ] — evaluate a predicate; exit 0 if true, 1 if
            // false, 2 on a malformed expression.
            Command(name: "test", summary: "evaluate a conditional expression", category: .system) { ctx, argv in
                ctx.exit(evaluateTest(Array(argv.dropFirst()), ctx: ctx, bracket: false))
            },
            Command(name: "[", summary: "evaluate a conditional expression (bracket form)", category: .system) { ctx, argv in
                ctx.exit(evaluateTest(Array(argv.dropFirst()), ctx: ctx, bracket: true))
            },

            // expr A OP B — integer arithmetic (+ - * / %) or comparison
            // (= != < <= > >=). Prints the result; exits 1 when the result is 0
            // or the empty string (like GNU expr), 2 on a usage/parse error.
            Command(name: "expr", summary: "evaluate an integer/comparison expression", category: .system) { ctx, argv in
                let args = Array(argv.dropFirst())
                guard args.count == 3, let lhs = Int(args[0]), let rhs = Int(args[2]) else {
                    ctx.usage("expr", "expr <int> <op> <int>"); return
                }
                let op = args[1]
                let result: Int
                switch op {
                case "+": result = lhs + rhs
                case "-": result = lhs - rhs
                case "*": result = lhs * rhs
                case "/":
                    guard rhs != 0 else { ctx.fail("expr: division by zero"); return }
                    result = lhs / rhs
                case "%":
                    guard rhs != 0 else { ctx.fail("expr: division by zero"); return }
                    result = lhs % rhs
                case "=":  result = (lhs == rhs) ? 1 : 0
                case "!=": result = (lhs != rhs) ? 1 : 0
                case "<":  result = (lhs <  rhs) ? 1 : 0
                case "<=": result = (lhs <= rhs) ? 1 : 0
                case ">":  result = (lhs >  rhs) ? 1 : 0
                case ">=": result = (lhs >= rhs) ? 1 : 0
                default:
                    ctx.fail("expr: unknown operator \(op)"); return
                }
                ctx.print("\(result)\n")
                ctx.exit(result == 0 ? 1 : 0)
            },
        ]
    }

    /// Evaluate a `test`/`[` argument list to an exit code (0 = true, 1 = false,
    /// 2 = malformed). For `[`, a trailing `]` is required and stripped.
    static func evaluateTest(_ argv: [String], ctx: ProcessContext, bracket: Bool) -> Int32 {
        var args = argv
        if bracket {
            guard args.last == "]" else {
                ctx.error("[: missing ']'"); return 2
            }
            args.removeLast()
        }
        // Leading `!` negates the remainder.
        if args.first == "!" {
            let inner = evaluateTest(bracket ? Array(args.dropFirst()) + ["]"] : Array(args.dropFirst()),
                                     ctx: ctx, bracket: bracket)
            if inner == 2 { return 2 }
            return inner == 0 ? 1 : 0
        }
        switch args.count {
        case 0:
            return 1                                   // empty expression is false
        case 1:
            return args[0].isEmpty ? 1 : 0             // non-empty string is true
        case 2:
            let op = args[0], operand = args[1]
            switch op {
            case "-z": return operand.isEmpty ? 0 : 1
            case "-n": return operand.isEmpty ? 1 : 0
            case "-e": return ctx.stat(operand) != nil ? 0 : 1
            case "-f": return (ctx.stat(operand)?.isDirectory == false) ? 0 : 1
            case "-d": return (ctx.stat(operand)?.isDirectory == true) ? 0 : 1
            default:
                ctx.error("test: unknown unary operator \(op)"); return 2
            }
        case 3:
            let lhs = args[0], op = args[1], rhs = args[2]
            switch op {
            case "=", "==": return lhs == rhs ? 0 : 1
            case "!=":      return lhs != rhs ? 0 : 1
            case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
                guard let a = Int(lhs), let b = Int(rhs) else {
                    ctx.error("test: integer expected"); return 2
                }
                let truth: Bool
                switch op {
                case "-eq": truth = a == b
                case "-ne": truth = a != b
                case "-lt": truth = a <  b
                case "-le": truth = a <= b
                case "-gt": truth = a >  b
                default:    truth = a >= b   // -ge
                }
                return truth ? 0 : 1
            default:
                ctx.error("test: unknown binary operator \(op)"); return 2
            }
        default:
            ctx.error("test: too many arguments"); return 2
        }
    }
}
