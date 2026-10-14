/// `os.Args` as a variable. The VM keeps one slice of the arguments,
/// made when it is first read, so what a program writes into it stays; a
/// program that assigns the variable gives the VM another slice through the
/// reserved call `$os.setArgs`. Reading `os.Args` is the instruction it
/// always was.
enum GoOSArgs {
    static let setter = "$os.setArgs"

    /// Whether `expression` is the selection `os.Args` of the package.
    static func isOSArgs(_ expression: GoExpression) -> Bool {
        guard case .selector(.identifier("os", _), "Args", _) = expression else { return false }
        return true
    }
}

extension FunctionChecker {
    /// Whether `expression` names the package variable `os.Args`, not a
    /// field of a variable named `os`.
    func isOSArgs(_ expression: GoExpression) -> Bool {
        GoOSArgs.isOSArgs(expression) && importedPaths.contains("os") && lookup("os") == nil
    }
}
