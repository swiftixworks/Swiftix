/// Generation-checked TCP timer state preventing stale callbacks from firing.
struct TCPEpochTimer {
    private(set) var epoch = 0
    private var token: EventLoop.EventToken?

    mutating func cancel() {
        epoch += 1
        token?.cancel()
        token = nil
    }

    mutating func schedule(on loop: EventLoop, after delay: Double, _ fire: @escaping (Int) -> Void) {
        token?.cancel()
        epoch += 1
        let scheduledEpoch = epoch
        token = loop.scheduleCancellable(after: delay) {
            fire(scheduledEpoch)
        }
    }

    /// Kernel-owned network timers use the stack's owner-aware scheduling seam;
    /// the EventLoop overload remains for standalone timer tests.
    mutating func schedule(on stack: NetworkStack, after delay: Double, _ fire: @escaping (Int) -> Void) {
        token?.cancel()
        epoch += 1
        let scheduledEpoch = epoch
        token = stack.scheduleCancellable(after: delay) {
            fire(scheduledEpoch)
        }
    }

    func accepts(_ scheduledEpoch: Int) -> Bool {
        scheduledEpoch == epoch
    }
}
