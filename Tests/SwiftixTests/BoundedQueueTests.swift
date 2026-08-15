/// Capacity and backpressure policies for long-lived protocol queues.

import Testing
@testable import Swiftix

@Suite("Bounded protocol queues")
struct BoundedQueueTests {
    @Test func udpInboxDropsNewestAtPacketLimit() {
        let socket = UDPSocket(stack: NetworkStack(loop: EventLoop()))
        let datagram = Datagram(payload: [1],
                                sourceAddress: IPv4Address(10, 0, 0, 1),
                                sourcePort: 1234)

        for _ in 0..<UDPSocket.maximumQueuedDatagrams {
            #expect(socket.deliver(datagram))
        }
        #expect(!socket.deliver(datagram))
        #expect(socket.queueStatistics.datagrams == UDPSocket.maximumQueuedDatagrams)
        #expect(socket.queueStatistics.highWaterDatagrams == UDPSocket.maximumQueuedDatagrams)
        #expect(socket.queueStatistics.droppedDatagrams == 1)
        #expect(socket.receive()?.payload == [1])
        #expect(socket.queueStatistics.datagrams == UDPSocket.maximumQueuedDatagrams - 1)
    }

    @Test func arpPendingQueueDropsNewestPerNeighbor() {
        let cache = NetworkNeighborCache()
        let target = IPv4Address(10, 0, 0, 2)
        for _ in 0..<NetworkNeighborCache.maximumPendingPacketsPerNeighbor {
            #expect(cache.enqueue([1], waitingFor: target))
        }
        #expect(!cache.enqueue([2], waitingFor: target))
        #expect(cache.pendingStatistics.packets
                == NetworkNeighborCache.maximumPendingPacketsPerNeighbor)
        #expect(cache.pendingStatistics.droppedPackets == 1)
        #expect(cache.drainPending(waitingFor: target).count
                == NetworkNeighborCache.maximumPendingPacketsPerNeighbor)
        #expect(cache.pendingStatistics.packets == 0)
    }

    @Test func fullPipeIsNotWritableAndNonblockingWriteReturnsEAGAIN() throws {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        final class Capture {
            var fullWrite = 0
            var overflowWrite = -1
            var readiness: IOReadiness?
            var error: SyscallError?
            var writableAfterRead = false
        }
        let capture = Capture()

        kernel.spawn("pipe-capacity") { context in
            let pipe = context.pipe()
            capture.fullWrite = context.write(pipe.write,
                                              [UInt8](repeating: 1,
                                                      count: PipeBuffer.capacity))
            capture.overflowWrite = context.write(pipe.write, [2])
            capture.readiness = context.readiness(pipe.write)
            context.setNonBlocking(pipe.write)
            do {
                _ = try context.writeFile(pipe.write, [3])
            } catch let error as SyscallError {
                capture.error = error
            } catch {}
            _ = context.read(pipe.read, max: 1)
            capture.writableAfterRead = context.readiness(pipe.write)?.contains(.writable) == true
        }
        loop.runUntilIdle()

        #expect(capture.fullWrite == PipeBuffer.capacity)
        #expect(capture.overflowWrite == 0)
        #expect(capture.readiness?.contains(.writable) == false)
        #expect(capture.error == .wouldBlock)
        #expect(capture.writableAfterRead)
    }

    @Test func ttyBoundsRawInputOutputAndHistory() {
        let terminal = PseudoTerminal()
        terminal.rawMode = true
        terminal.writeFromApp([UInt8](repeating: 1,
                                     count: PseudoTerminal.maximumSlaveInputBytes + 10))
        #expect(terminal.queueStatistics.slaveInputBytes
                == PseudoTerminal.maximumSlaveInputBytes)
        #expect(terminal.queueStatistics.droppedInputBytes == 10)

        let output = [UInt8](repeating: 2,
                             count: PseudoTerminal.maximumMasterOutputBytes + 10)
        #expect(terminal.slave.write(output) == PseudoTerminal.maximumMasterOutputBytes)
        #expect(terminal.queueStatistics.masterOutputBytes
                == PseudoTerminal.maximumMasterOutputBytes)
        #expect(terminal.queueStatistics.droppedOutputBytes == 10)
        #expect(!terminal.slave.readiness.contains(.writable))
        var writableNotification = false
        let subscription = terminal.slave.addReadinessListener {
            writableNotification = true
        }
        _ = terminal.readForApp(max: 1)
        #expect(terminal.slave.readiness.contains(.writable))
        #expect(writableNotification)
        withExtendedLifetime(subscription) {}

        let historyTerminal = PseudoTerminal()
        historyTerminal.echo = false
        for index in 0..<(PseudoTerminal.maximumHistoryEntries + 5) {
            historyTerminal.writeFromApp(Array("command-\(index)\n".utf8))
            _ = historyTerminal.slave.read(max: 64)
        }
        #expect(historyTerminal.queueStatistics.historyEntries
                == PseudoTerminal.maximumHistoryEntries)
        #expect(historyTerminal.queueStatistics.historyBytes
                <= PseudoTerminal.maximumHistoryBytes)
    }
}
