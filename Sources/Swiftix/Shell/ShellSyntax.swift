/// Shell script syntax: the token set the structural lexer emits and the AST
/// the parser builds (statements, pipelines, redirections, compound commands).
/// Pure value types; no process state.
extension Programs {

    // MARK: - Tokens

    /// A structural token. `.word` carries the RAW source (quotes/escapes/`$`
    /// intact); operators are recognized only outside quotes.
    enum Token: Equatable {
        case word(String)
        case pipe                               // |
        case redirectInput(fd: Int)             // `<`  or `N<`  (fd defaults to 0)
        case redirectFile(fd: Int, append: Bool) // `>`/`>>` or `N>`/`N>>` (fd defaults to 1)
        /// `N>&M` / `N<&M` — e.g. `2>&1`, `1>&2`. `toFd == -1` is `N>&-` (close).
        case redirectDup(fromFd: Int, toFd: Int)
        /// `N<<[-]DELIM` with its body already collected by the lexer. `expand`
        /// is false when the delimiter was quoted (`<<'EOF'`).
        case hereDocument(fd: Int, body: String, expand: Bool)
        /// `N<<<` — the following word is the here-string.
        case hereString(fd: Int)
        case semicolon                          // ; or newline (statement separator)
        case doubleSemicolon                    // ;; (case-clause terminator)
        case and                                // &&
        case or                                 // ||
        case background                         // &
        case lparen                             // ( — subshell / function-def / case pattern
        case rparen                             // ) — subshell end / case-pattern terminator
    }

    // MARK: - AST

    /// One redirection, applied in source order. Target words are raw and are
    /// expanded when the command runs.
    struct Redirection {
        enum Kind {
            case input(String)
            case output(String, append: Bool)
            /// `fd>&target` / `fd<&target`.
            case duplicate(Int)
            /// `fd>&-`.
            case close
            case hereDocument(body: String, expand: Bool)
            case hereString(String)
        }
        var fd: Int
        var kind: Kind
    }

    /// A single command: a simple command, a pipeline of commands, or a compound
    /// built from nested statement lists.
    indirect enum ScriptCommand {
        /// Words plus redirections, expanded when it runs.
        case simple(RawStage)
        /// `a | b | c`, optionally negated with a leading `!`. A lone negated
        /// command is a one-element pipeline.
        case pipeline([ScriptCommand], negated: Bool)
        case ifClause(cond: [ScriptStatement], then: [ScriptStatement], els: [ScriptStatement])
        /// `while`/`until COND; do BODY; done`.
        case whileClause(cond: [ScriptStatement], body: [ScriptStatement], until: Bool)
        /// `for NAME [in WORDS]; do BODY; done` — WORDS are stored raw and
        /// expanded once when the loop runs; `nil` iterates `"$@"`.
        case forClause(variable: String, words: [String]?, body: [ScriptStatement])
        /// `case WORD in pat) … ;; … esac` — the subject word is stored raw and
        /// expanded when it runs; each clause's patterns are glob patterns matched
        /// against the expanded subject.
        case caseClause(subject: String, clauses: [CaseClause])
        /// `name() { … }` — a function definition. Registers `body` under `name`;
        /// invoking `name` later runs `body` in the shell with `$1…` bound.
        case functionDef(name: String, body: [ScriptStatement])
        /// `{ list; }` — runs in the current shell.
        case group([ScriptStatement])
        /// `( list )` — runs in a child shell process.
        case subshell([ScriptStatement])
        /// A compound command with trailing redirection applied to the whole
        /// block, e.g. `for … done > file` or `if … fi 2> err`.
        case redirected(ScriptCommand, [Redirection])
    }

    /// One `case` clause: alternative glob patterns and the body run on a match.
    struct CaseClause {
        var patterns: [String]
        var body: [ScriptStatement]
    }

    /// How two commands in an and-or list are joined.
    enum Connector { case and, or }

    /// An and-or list (`a && b || c`), optionally backgrounded (`&`). A script is
    /// a sequence of these separated by `;`/newline/`&`.
    struct ScriptStatement {
        var first: ScriptCommand
        var rest: [(connector: Connector, command: ScriptCommand)]
        var background: Bool
    }

    /// One simple command with RAW (unexpanded) words and its redirections.
    struct RawStage {
        var argv: [String] = []
        var redirections: [Redirection] = []
    }

}
