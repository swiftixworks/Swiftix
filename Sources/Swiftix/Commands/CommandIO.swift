/// Diagnostics and option-token helpers shared by the built-in commands.
///
/// The built-ins are plain programs over `ProcessContext`, so reporting a problem
/// means writing bytes to fd 2 and setting an exit status. Spelled out at every
/// call site that was `ctx.write(2, Array("cmd: …\n".utf8)); ctx.exit(2); return`
/// — 136 times across `Commands/`, with the trailing newline, the `2`, and the
/// `cmd: ` prefix all re-typed each time. These helpers name the three recurring
/// shapes so a command says what it means and the convention is enforced in one
/// place rather than by copy-paste.
///
/// Deliberately `internal`: this is the shape of the library's own built-ins, not
/// part of the consumer boundary. A consumer writing its own `Command` uses the
/// public syscall surface (`write` / `exit`) directly.
///
/// Concurrency: pure extensions over `ProcessContext`, which is part of the
/// non-Sendable reference-type core and is only touched on the single serial
/// executor driving the kernel. Nothing here adds state or locks.

extension ProcessContext {

    /// Writes one diagnostic line to stderr, supplying the trailing newline.
    func error(_ message: String) {
        write(2, Array((message + "\n").utf8))
    }

    /// Writes one diagnostic line to stderr and sets the exit status.
    ///
    /// The caller must still `return`, because a `Command` body owns its own
    /// control flow — `exit(_:)` records the status, it does not unwind.
    func fail(_ message: String, code: Int32 = 2) {
        error(message)
        exit(code)
    }

    /// Reports a usage error in the built-ins' standard form
    /// (`"<command>: usage: <synopsis>"`) and sets the exit status.
    ///
    /// Exit code 2 is the convention across the built-in set for "you invoked me
    /// wrongly", as distinct from 1 for "I ran and the operation failed".
    func usage(_ command: String, _ synopsis: String, code: Int32 = 2) {
        fail("\(command): usage: \(synopsis)", code: code)
    }
}

/// Shared argument-vector predicates for the built-ins' option parsers.
enum CommandArguments {

    /// Whether `token` introduces options rather than naming an operand.
    ///
    /// True for `-l`, a combined `-la`, and a long `--uts`; false for an operand,
    /// for the empty string, and for a bare `-` (which by convention names standard
    /// input, not an option).
    ///
    /// This single predicate replaces three spellings that were scattered across
    /// the option loops and looked like they disagreed:
    ///
    ///     first.hasPrefix("-") && first.count > 1     // ls, du, grep, kill
    ///     first.hasPrefix("-") && first.count >= 2    // touch
    ///     first.hasPrefix("-") && first != "-"        // unshare, nsenter
    ///
    /// All three are the same test: a string that starts with `-` has `count > 1`
    /// exactly when it is not the one-character string `-`. Naming it once removes
    /// the appearance of a disagreement and gives the `-`-means-stdin convention a
    /// place to be documented.
    static func isOptionToken(_ token: String) -> Bool {
        token.hasPrefix("-") && token != "-"
    }
}
