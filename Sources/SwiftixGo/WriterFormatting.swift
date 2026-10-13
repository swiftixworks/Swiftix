/// `fmt.Fprint`, `fmt.Fprintln`, and `fmt.Fprintf` to a writer that is no
/// file.
///
/// The three functions are natives of the VM, which writes to a descriptor
/// of the process. Go lets them write to any `io.Writer`: an
/// `http.ResponseWriter`, a `net.Conn`, a type of the program. A native
/// cannot call the `Write` method of such a value, so the call is compiled
/// as what Go's `fmt` does itself, which formats the operands into a buffer
/// and passes it to `Write` once:
///
///     fmt.Fprintf(w, format, operands...)
///     w.Write([]byte(fmt.Sprintf(format, operands...)))
///
/// The results are those of `Write`, `(n int, err error)`. The checker and
/// the compiler both ask here for the second form, so that a writer is
/// checked and lowered like any method call. A call whose first argument is
/// a `*os.File` stays the native it was.
enum GoWriterFormat {
    /// The function of `fmt` that makes the text `member` writes.
    private static func formatter(of member: String) -> String? {
        switch member {
        case "Fprint": return "Sprint"
        case "Fprintln": return "Sprintln"
        case "Fprintf": return "Sprintf"
        default: return nil
        }
    }

    /// The call `writer.Write(bytes)`, as a method call of the syntax tree.
    static func write(
        _ bytes: GoExpression, to writer: GoExpression
    ) -> (callee: GoExpression, arguments: [GoExpression]) {
        let position = writer.position
        let byteSlice = GoTypeExpression.slice(
            element: .named("byte", position: position), position: position)
        return (
            .selector(base: writer, name: "Write", position: position),
            [
                .call(
                    callee: .typeExpression(byteSlice, position: position), arguments: [bytes],
                    position: position)
            ]
        )
    }

    /// `writer.Write([]byte(fmt.Sprint...(operands...)))` for the call
    /// `fmt.Fprint...(writer, operands...)`; nil when `callee` is none of
    /// the three functions or the call has no writer.
    static func call(
        callee: GoExpression, arguments: [GoExpression]
    ) -> (callee: GoExpression, arguments: [GoExpression])? {
        guard case .selector(let package, let member, let position) = callee,
            let formatter = formatter(of: member), let writer = arguments.first
        else { return nil }
        let text = GoExpression.call(
            callee: .selector(base: package, name: formatter, position: position),
            arguments: Array(arguments.dropFirst()), position: position)
        return write(text, to: writer)
    }
}
