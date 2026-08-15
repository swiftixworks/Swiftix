/// POSIX signal numbers (Linux values) the kernel understands.
///
/// Delivery happens at scheduling boundaries (a process is blocked, or about to
/// finish a step): `Kernel.kill` either runs an installed handler, or applies
/// the default disposition — SIGINT/SIGTERM terminate the process, SIGKILL
/// always terminates (uncatchable), others are ignored. A foreground process is
/// interrupted by Ctrl-C via `PseudoTerminal.onControlC`.
///
/// Stop/continue: SIGTSTP (default) suspends a process — its pending and future
/// scheduling steps are deferred — and SIGCONT resumes it, flushing the deferred
/// steps back onto the loop. SIGCONT is delivered even to a stopped process.
///
/// Masked regular signals are kept pending until unmasked. SIGKILL is never
/// maskable; SIGCONT always resumes a stopped process before any handler runs.
public enum Signal: Int32, Sendable {
    case sigint = 2
    case sigkill = 9
    case sigterm = 15
    case sigchld = 17
    case sigcont = 18
    case sigtstp = 20
}
