/// BSD-like socket option values and per-socket storage.
public enum SocketOption: Hashable, Sendable {
    case reuseAddress
}

protocol SocketOptionStorage: AnyObject {
    func setSocketOption(_ option: SocketOption, enabled: Bool)
    func socketOption(_ option: SocketOption) -> Bool
}

final class SocketOptions {
    private var enabled: Set<SocketOption> = []

    func set(_ option: SocketOption, enabled isEnabled: Bool) {
        if isEnabled {
            enabled.insert(option)
        } else {
            enabled.remove(option)
        }
    }

    func contains(_ option: SocketOption) -> Bool {
        enabled.contains(option)
    }
}
