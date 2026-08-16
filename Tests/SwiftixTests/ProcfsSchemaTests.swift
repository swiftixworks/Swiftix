import Testing
@testable import Swiftix

@Suite("procfs schema contracts")
struct ProcfsSchemaTests {

    @Test func procProcessesHasStableHeaderColumnsAndPidOrdering() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        let first = kernel.spawn("first") { ctx in ctx.sleep(10) { ctx.exit(0) } }
        let second = kernel.spawn("second") { ctx in ctx.sleep(10) { ctx.exit(0) } }
        loop.advance(by: 0)

        let rows = lines(readProcFile(ProcfsSchema.Processes.path, kernel, loop: loop))
        #expect(rows.first == ProcfsSchema.Processes.header)
        #expect(ProcfsSchema.Processes.fields == ["PID", "PPID", "PGID", "SID", "STATE", "TICKS", "FDS", "MEM", "NAME"])

        let processRows = rows.dropFirst().map { $0.split(separator: " ").map(String.init) }
        let pids = processRows.compactMap { Int($0[0]) }
        #expect(pids == pids.sorted())
        #expect(pids.starts(with: [first, second]))
        #expect(processRows.map { $0[8] } == ["first", "second", "reader"])   // NAME is column 8
        for columns in processRows {
            #expect(columns.count == ProcfsSchema.Processes.fields.count)
            // TICKS (scheduler steps) and FDS (open descriptors) are non-negative.
            #expect((Int(columns[5]) ?? -1) >= 0)
            #expect((Int(columns[6]) ?? -1) >= 0)
            #expect((Int(columns[7]) ?? -1) >= 0)
            if columns[8] != "reader" {
                #expect(columns[1] == "0")
                #expect(columns[2] == columns[0])
                #expect(columns[3] == columns[0])
                #expect(columns[4] == "S")
            }
        }
    }

    @Test func procNetFilesUseStableFieldOrderAndSorting() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let stack = kernel.netns.stack

        _ = stack.configuredInterface(address: IPv4Address(10, 0, 0, 1),
                                  mac: MACAddress("02:00:00:00:00:01")!,
                                  prefixLength: 24)
        _ = stack.configuredInterface(address: IPv4Address(10, 0, 1, 1),
                                  mac: MACAddress("02:00:00:00:00:02")!,
                                  prefixLength: 24)
        stack.configuredRoute(destination: IPv4Address(0, 0, 0, 0),
                       prefixLength: 0,
                       gateway: IPv4Address(10, 0, 0, 254),
                       interfaceIndex: 0)
        stack.configuredNeighbor(ip: IPv4Address(10, 0, 0, 254),
                          mac: MACAddress("02:00:00:00:00:fe")!)
        stack.configuredNeighbor(ip: IPv4Address(10, 0, 0, 2),
                          mac: MACAddress("02:00:00:00:00:02")!)

        #expect(ProcfsSchema.NetDev.fields == ["IFACE", "ADDR", "MAC", "RX_PACKETS", "TX_PACKETS", "RX_BYTES", "TX_BYTES", "DROPS", "FORWARDED"])
        #expect(lines(readProcFile(ProcfsSchema.NetDev.path, kernel, loop: loop)) == [
            "eth0 10.0.0.1 02:00:00:00:00:01 rx_packets=0 tx_packets=0 rx_bytes=0 tx_bytes=0 drops=0 forwarded=0",
            "eth1 10.0.1.1 02:00:00:00:00:02 rx_packets=0 tx_packets=0 rx_bytes=0 tx_bytes=0 drops=0 forwarded=0",
        ])

        #expect(ProcfsSchema.NetRoute.fields == ["DESTINATION", "GATEWAY", "INTERFACE"])
        #expect(lines(readProcFile(ProcfsSchema.NetRoute.path, kernel, loop: loop)) == [
            "10.0.0.0/24 * eth0",
            "10.0.1.0/24 * eth1",
            "0.0.0.0/0 10.0.0.254 eth0",
        ])

        #expect(ProcfsSchema.NetARP.fields == ["ADDRESS", "HWADDRESS"])
        #expect(lines(readProcFile(ProcfsSchema.NetARP.path, kernel, loop: loop)) == [
            "10.0.0.2 02:00:00:00:00:02",
            "10.0.0.254 02:00:00:00:00:fe",
        ])

        #expect(ProcfsSchema.NetTCP.fields == ["LOCAL_PORT", "REMOTE", "STATE", "CWND", "SSTHRESH", "SRTT", "RTTVAR", "RTO", "RWND", "PEERWND"])
    }

    @Test func procNetTraceAndDropHaveStructuredDetails() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let interface = kernel.netns.stack.configuredInterface(address: IPv4Address(10, 0, 0, 1),
                                                           mac: MACAddress("02:00:00:00:00:01")!)

        kernel.netns.stack.receive(PacketBuffer([0x00, 0x01, 0x02]), on: interface)

        #expect(ProcfsSchema.NetTrace.fields == ["SEQ", "DIRECTION", "INTERFACE", "STAGE", "DETAILS"])
        let traceRows = lines(readProcFile(ProcfsSchema.NetTrace.tracePath, kernel, loop: loop))
        let dropRows = lines(readProcFile(ProcfsSchema.NetTrace.dropPath, kernel, loop: loop))

        #expect(traceRows.first == "0 inbound eth0 ingress len=3")
        #expect(dropRows == ["1 inbound eth0 layer2 len=3 drop=malformedEthernet"])
        for row in traceRows + dropRows {
            #expect(row.split(separator: " ").count >= 5)
        }
    }

    private func readProcFile(_ path: String, _ kernel: Kernel, loop: EventLoop) -> String {
        final class Capture { var text = "" }
        let captured = Capture()
        kernel.spawn("reader") { ctx in
            guard let fd = ctx.open(path) else { return }
            captured.text = String(decoding: ctx.read(fd, max: 65535), as: UTF8.self)
            ctx.close(fd)
        }
        loop.runUntilIdle()
        return captured.text
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init)
    }
}
