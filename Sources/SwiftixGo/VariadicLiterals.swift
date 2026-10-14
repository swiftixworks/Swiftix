/// The arguments of a function literal that a `go` or `defer` statement
/// calls where it is written.
///
/// A literal that captures nothing is a function of the program, called by
/// its name, and such a call lowered each argument as it is: a variadic
/// literal got its arguments one by one, not as a slice, and a value passed
/// to an interface parameter was not boxed with its type, so `%T` of an
/// `int8` said `int`. They are lowered now as for any function of the
/// program; an argument that needs neither is lowered as it always was.

extension IRLowerer {
    /// The argument registers of a call of the lifted literal `name`.
    mutating func lowerLiftedLiteralArguments(
        _ arguments: [GoExpression], of name: String
    ) throws -> [Int] {
        try lowerArguments(arguments, parameters: functionParameterTypes[name])
    }
}
