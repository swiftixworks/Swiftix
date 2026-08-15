/// Centralizes TCP waiter wakeups and readiness notifications.
final class TCPConnectionNotifications {
    var onEstablished: (() -> Void)?
    var onReadable: (() -> Void)?

    private let readinessBroadcaster = ReadinessBroadcaster()

    func addReadinessListener(_ listener: @escaping () -> Void) -> ReadinessSubscription {
        readinessBroadcaster.add(listener)
    }

    func established() {
        onEstablished?()
        readinessBroadcaster.notify()
    }

    func readable() {
        onReadable?()
        readinessBroadcaster.notify()
    }

    func readinessChanged() {
        readinessBroadcaster.notify()
    }

    func unblockConnectAndRead() {
        onEstablished?()
        onReadable?()
    }
}
