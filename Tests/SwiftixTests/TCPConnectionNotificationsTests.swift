import Testing
@testable import Swiftix

@Suite("TCP connection notifications")
struct TCPConnectionNotificationsTests {
    @Test func establishedFiresConnectWaiterAndReadinessListener() {
        let notifications = TCPConnectionNotifications()
        final class Capture {
            var established = 0
            var readiness = 0
        }
        let captured = Capture()

        notifications.onEstablished = { captured.established += 1 }
        let subscription = notifications.addReadinessListener { captured.readiness += 1 }

        notifications.established()

        #expect(captured.established == 1)
        #expect(captured.readiness == 1)
        _ = subscription
    }

    @Test func readableFiresReadWaiterAndReadinessListener() {
        let notifications = TCPConnectionNotifications()
        final class Capture {
            var readable = 0
            var readiness = 0
        }
        let captured = Capture()

        notifications.onReadable = { captured.readable += 1 }
        let subscription = notifications.addReadinessListener { captured.readiness += 1 }

        notifications.readable()

        #expect(captured.readable == 1)
        #expect(captured.readiness == 1)
        _ = subscription
    }
}
