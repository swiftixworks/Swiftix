/// Centralizes TCP waiter wakeups and readiness notifications.
final class TCPConnectionNotifications {
    var onEstablished: (() -> Void)?

    private let readinessBroadcaster = ReadinessBroadcaster()
    private let readWaiters = WaitQueue()

    func addReadinessListener(_ listener: @escaping () -> Void) -> ReadinessSubscription {
        readinessBroadcaster.add(listener)
    }

    func addReadWaiter(_ waiter: @escaping () -> Void) -> ReadinessSubscription {
        readWaiters.add(waiter)
    }

    func established() {
        onEstablished?()
        readinessBroadcaster.notify()
    }

    func readable() {
        readWaiters.notifyOne()
        readinessBroadcaster.notify()
    }

    func readinessChanged() {
        readinessBroadcaster.notify()
    }

    func unblockConnectAndRead() {
        onEstablished?()
        readWaiters.notifyAll()
    }
}
