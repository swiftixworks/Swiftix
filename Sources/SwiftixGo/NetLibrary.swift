/// The natives under `net`, which is Go text of the library.
///
/// `net.Conn`, `net.Listener`, and `net.Addr` are Go's interfaces, and
/// `*net.TCPConn`, `*net.TCPListener`, `*net.TCPAddr`, and `*net.OpError`
/// Go's types, all declared in `Sources/SwiftixGoLibrary/net`, so that a
/// type of the program can be a connection and an error is the value Go
/// returns. What only the kernel can do is a native the text calls as
/// `native.name(...)`: each takes and gives the number of a descriptor,
/// addresses as text, and a code for what went wrong (`codeTimeout`, ...),
/// which the text turns into Go's error. The VM executes them
/// (`GoNetNatives` in `SwiftixGoRuntime`), parks a goroutine that waits,
/// and wakes it when its deadline passes or the descriptor is closed.
///
/// The handle values of the earlier `net` (`GoValue.netConn`) and their
/// instructions stay for images built before; nothing emits them now.
enum GoNetLibrary {
    /// The native the text of `net` calls as `native.name(...)`.
    static func textNative(_ name: String) -> GoNativeFunction? {
        let int64 = GoNumericKind.int64.type
        let bytes = GoType.slice(GoPredeclared.byte)
        let signature: (parameters: [GoType], results: [GoType])
        switch name {
        // ip, port -> descriptor, port, code
        case "listen": signature = ([.string, .int], [.int, .int, .int])
        // descriptor -> descriptor, local ip, remote ip, remote port, code
        case "accept": signature = ([.int], [.int, .string, .string, .int, .int])
        // ip, port -> descriptor, local ip, local port, code
        case "dial": signature = ([.string, .int], [.int, .string, .int, .int])
        // descriptor, buffer -> count, code
        case "read", "write": signature = ([.int, bytes], [.int, .int])
        case "close": signature = ([.int], [])
        // descriptor, which deadlines, Unix nanoseconds or the least int64
        case "deadline": signature = ([.int, .int, int64], [])
        default: return nil
        }
        return GoNativeFunction(
            symbol: "$net." + name, goName: "net." + name,
            parameters: signature.parameters, results: signature.results)
    }

    /// The call names of those.
    static let nativeCallNames = ["listen", "accept", "dial", "read", "write", "close", "deadline"]
        .map { "$net." + $0 }
}
