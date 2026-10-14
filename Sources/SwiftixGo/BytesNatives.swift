/// The natives of `bytes` and `bufio`, which the Go source of the packages
/// calls.
///
/// Both packages are written in Go (see `GoSourceLibrary`). A loop over the
/// bytes of a slice costs the VM some thirty instructions a byte, and
/// finding a byte or comparing two slices is what a server does with every
/// line it reads, so those four are single calls: `native.indexByte(p, c)`
/// is the reserved call `$indexByte` of the package. The VM's side is
/// `GoBytes`.
extension GoStandardLibrary {
    static func bytesNativeFunction(package: String, member: String) -> GoNativeFunction? {
        let bytes = GoType.slice(GoPredeclared.byte)
        let signature: (parameters: [GoType], result: GoType)
        switch (package, member) {
        // The index of the first byte that is the second operand, or -1.
        case (_, "indexByte"): signature = ([bytes, GoPredeclared.byte], .int)
        // The index of the first place the second slice lies in the first.
        case ("bytes", "index"): signature = ([bytes, bytes], .int)
        // Whether two slices hold the same bytes.
        case ("bytes", "equal"): signature = ([bytes, bytes], .bool)
        // The order of two slices, byte by byte: -1, 0, or 1.
        case ("bytes", "compare"): signature = ([bytes, bytes], .int)
        default: return nil
        }
        return GoNativeFunction(
            symbol: "$\(package).\(member)", goName: "\(package).\(member)",
            parameters: signature.parameters, results: [signature.result])
    }

    static let bytesNativeCallNames = [
        "$bufio.indexByte", "$bytes.indexByte", "$bytes.index", "$bytes.equal", "$bytes.compare",
    ]
}
