/// Goroutines parked in `Accept` or `Read` of a network handle, so that
/// closing the handle wakes them as Go's `Close` does.
///
/// The kernel's accept and receive waits cannot be withdrawn: a listener
/// that is closed never resumes its accept, and a connection resumes its
/// receive only when the peer sends or goes away. So the VM keeps each wait
/// it starts under the descriptor, and `Close` wakes every goroutine parked
/// on that descriptor with the error Go gives (`use of closed network
/// connection`) and marks the wait abandoned: a continuation that arrives
/// after all does nothing, and the host wait it held is ended by the close.
/// A descriptor that was closed answers at once until the kernel hands the
/// number out again. Mutable reference state of one run; no process state.
final class GoParkedNetWait {
    /// The goroutine that waits.
    let goroutine: Int
    /// What it is woken with when the descriptor is closed under it.
    let resultsOnClose: [GoValue]
    /// Whether the descriptor was closed and the goroutine woken already.
    var abandoned = false

    init(goroutine: Int, resultsOnClose: [GoValue]) {
        self.goroutine = goroutine
        self.resultsOnClose = resultsOnClose
    }

    /// Go's error for an operation on a closed handle: `accept tcp
    /// [::]:8080: use of closed network connection`.
    static func closedMessage(_ operation: String, _ address: String) -> String {
        "\(operation) tcp \(address): use of closed network connection"
    }

    /// The address of a listener as Go prints it: a listener on every
    /// interface is `[::]:port`.
    static func listenerAddress(_ address: String) -> String {
        address.hasPrefix(":") ? "[::]" + address : address
    }
}
