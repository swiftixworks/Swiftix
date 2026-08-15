/// Shell script syntax: the token set the structural lexer emits and the AST
/// the parser builds (statements, pipelines, redirects, compound commands).
extension Programs {

    // MARK: - Tokens

    /// A structural token. `.word` carries the RAW source (quotes/escapes/`$`
    /// intact); operators are recognized only outside quotes.
    enum Token: Equatable {
        case word(String)
        case pipe                               // |
        case redirectInput(fd: Int)             // `<`  or `N<`  (fd defaults to 0)
        case redirectFile(fd: Int, append: Bool) // `>`/`>>` or `N>`/`N>>` (fd defaults to 1)
        case redirectDup(fromFd: Int, toFd: Int) // `N>&M` — e.g. `2>&1`, `1>&2`
        case semicolon                          // ; or newline (statement separator)
        case doubleSemicolon                    // ;; (case-clause terminator)
        case and                                // &&
        case or                                 // ||
        case background                         // &
        case lparen                             // ( — function-def / case-pattern grouping
        case rparen                             // ) — case-pattern terminator
    }

    // MARK: - AST

    /// A single command: a pipeline, or a compound (`if`/`while`) built from
    /// nested statement lists.
    indirect enum ScriptCommand {
        case pipeline([RawStage])
        case ifClause(cond: [ScriptStatement], then: [ScriptStatement], els: [ScriptStatement])
        case whileClause(cond: [ScriptStatement], body: [ScriptStatement])
        /// `for NAME in WORDS; do BODY; done` — WORDS are stored raw and expanded
        /// (parameter/arithmetic/glob) once when the loop runs.
        case forClause(variable: String, words: [String], body: [ScriptStatement])
        /// `case WORD in pat) … ;; … esac` — the subject word is stored raw and
        /// expanded when it runs; each clause's patterns are glob patterns matched
        /// against the expanded subject.
        case caseClause(subject: String, clauses: [CaseClause])
        /// `name() { … }` — a function definition. Registers `body` under `name`;
        /// invoking `name` later runs `body` in the shell with `$1…` bound.
        case functionDef(name: String, body: [ScriptStatement])
        /// A compound command with trailing redirection applied to the whole
        /// block, e.g. `for … done > file` or `if … fi 2> err`.
        case redirected(ScriptCommand, Redirects)
    }

    /// One `case` clause: alternative glob patterns and the body run on a match.
    struct CaseClause {
        var patterns: [String]
        var body: [ScriptStatement]
    }

    /// Redirections applied to a whole compound command (target filenames are raw
    /// and expanded when the command runs).
    struct Redirects {
        var stdinFile: String?
        var stdoutFile: String?
        var appendOut = false
        var stderrFile: String?
        var appendErr = false
        var stderrToStdout = false
        var stdoutToStderr = false

        var isEmpty: Bool {
            stdinFile == nil && stdoutFile == nil && stderrFile == nil
                && !stderrToStdout && !stdoutToStderr
        }
    }

    /// How two commands in an and-or list are joined.
    enum Connector { case and, or }

    /// An and-or list (`a && b || c`), optionally backgrounded (`&`). A script is
    /// a sequence of these separated by `;`/newline.
    struct ScriptStatement {
        var first: ScriptCommand
        var rest: [(connector: Connector, command: ScriptCommand)]
        var background: Bool
    }

    /// One pipeline stage with RAW (unexpanded) words; expanded to a `Stage` at
    /// run time by `expandStage`.
    struct RawStage {
        var argv: [String] = []
        var stdinFile: String?
        var stdoutFile: String?
        var appendOut = false
        /// `2>file` / `2>>file` target for standard error.
        var stderrFile: String?
        var appendErr = false
        /// `2>&1` — send stderr wherever stdout currently points.
        var stderrToStdout = false
        /// `1>&2` — send stdout wherever stderr currently points.
        var stdoutToStderr = false
    }

}
