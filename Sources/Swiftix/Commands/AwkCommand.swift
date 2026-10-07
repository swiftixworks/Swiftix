/// The `awk` built-in (category .text): option parsing and program loading in
/// front of `AwkParser` and `AwkInterpreter`.
///
/// Supported: pattern–action rules (`BEGIN`, `END`, expressions, ranges),
/// fields and the standard special variables, the full expression grammar,
/// associative arrays, control flow, `print` / `printf` with `>` and `>>`
/// redirection, `getline` (plain and `< file`), the string and math builtins,
/// user-defined functions, and commands run through `sh -c`: output pipes
/// (`print | "cmd"`), input pipes (`"cmd" | getline`) and `system()`.
///
/// Concurrency: an async command body on the kernel's single serial executor;
/// all waiting happens inside `await`ed `ProcessContext` syscalls.
extension BuiltinCommands {

    static func awkCommands() -> [Command] {
        [
            Command(name: "awk",
                    summary: "pattern scanning and text processing language",
                    category: .text,
                    usage: """
                    awk [-F fs] [-v var=value] [-f progfile | 'program'] [file...]
                      -F fs         input field separator (a regular expression if longer than one character)
                      -v var=value  assign a variable before the program starts (repeatable)
                      -f progfile   read the program from a file instead of the first operand (repeatable)
                    """,
                    asyncRun: { ctx, argv in await runAwk(ctx, argv) }),
        ]
    }

    private static func runAwk(_ ctx: ProcessContext, _ argv: [String]) async {
        guard let options = ctx.options("awk", Array(argv.dropFirst()), "F:v:f:", stopAtOperand: true) else {
            return
        }
        var operands = options.operands
        var source = ""
        if options.has("f") {
            for path in options.all("f") {
                do {
                    let bytes = try await readOperand(ctx, path)
                    source += String(decoding: bytes, as: UTF8.self) + "\n"
                } catch {
                    ctx.fail("awk: can't open file \(path): \(errnoText(error))")
                    return
                }
            }
        } else {
            guard !operands.isEmpty else {
                ctx.usage("awk", "awk [-F fs] [-v var=value] [-f progfile | 'program'] [file...]")
                return
            }
            source = operands.removeFirst()
        }

        let program: AwkProgram
        do {
            program = try AwkParser.parse(source)
        } catch let error as AwkSyntaxError {
            ctx.fail("awk: syntax error at source line \(error.line): \(error.message)")
            return
        } catch {
            ctx.fail("awk: syntax error")
            return
        }

        let interpreter = AwkInterpreter(ctx, program: program, arguments: ["awk"] + operands)
        do {
            if let separator = options.value("F") {
                // POSIX: `-Ft` means a tab.
                let value = separator == "t" ? "\\t" : separator
                try interpreter.assignCommandLine("FS=" + value)
            }
            for assignment in options.all("v") {
                guard try interpreter.assignCommandLine(assignment) else {
                    ctx.fail("awk: invalid -v argument '\(assignment)': expected var=value")
                    return
                }
            }
        } catch let AwkRuntimeError.failure(message) {
            ctx.fail("awk: \(message)")
            return
        } catch {
            ctx.exit(2)
            return
        }
        ctx.exit(await interpreter.run())
    }
}
