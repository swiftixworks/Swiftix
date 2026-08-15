/// Tests for the block device layer (RamDisk + ProcessContext syscalls).
import Testing
@testable import Swiftix

@Suite("Block devices")
struct BlockDeviceTests {

    @Test func ramDiskReadWriteRoundTrips() {
        let disk = RamDisk(sectorCount: 4, sectorSize: 512)
        #expect(disk.capacity == 2048)
        #expect(disk.read(sector: 0) == [UInt8](repeating: 0, count: 512))

        let data = [UInt8](repeating: 0xAB, count: 512)
        #expect(disk.write(sector: 1, data: data) == true)
        #expect(disk.read(sector: 1) == data)
        #expect(disk.read(sector: 0) == [UInt8](repeating: 0, count: 512))  // other sectors unchanged
    }

    @Test func ramDiskRejectsOutOfRange() {
        let disk = RamDisk(sectorCount: 2, sectorSize: 512)
        #expect(disk.read(sector: 2) == nil)
        #expect(disk.write(sector: 2, data: [UInt8](repeating: 0, count: 512)) == false)
    }

    @Test func ramDiskRejectsWrongSize() {
        let disk = RamDisk(sectorCount: 2, sectorSize: 512)
        #expect(disk.write(sector: 0, data: [1, 2, 3]) == false)  // too short
    }

    @Test func processContextBlockDeviceSyscalls() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result {
            var created = false
            var names: [String] = []
            var readBack: [UInt8]? = nil
        }
        let result = Result()

        kernel.spawn("test") { ctx in
            result.created = ctx.createBlockDevice(name: "sda", sectorCount: 8)
            result.names = ctx.listBlockDevices()
            let sector = [UInt8](repeating: 0xFF, count: 512)
            _ = ctx.writeBlock(device: "sda", sector: 0, data: sector)
            result.readBack = ctx.readBlock(device: "sda", sector: 0)
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.created == true)
        #expect(result.names == ["sda"])
        #expect(result.readBack == [UInt8](repeating: 0xFF, count: 512))
    }

    @Test func procDevicesListsBlockDevices() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)

        final class Result { var output = "" }
        let result = Result()

        kernel.spawn("test") { ctx in
            _ = ctx.createBlockDevice(name: "vda", sectorCount: 16)
            if let fd = ctx.open("/proc/devices") {
                let bytes = ctx.read(fd, max: 65535)
                result.output = String(decoding: bytes, as: UTF8.self)
                ctx.close(fd)
            }
            ctx.exit(0)
        }
        loop.runUntilIdle()

        #expect(result.output.contains("vda"))
        #expect(result.output.contains("sectors=16"))
        #expect(result.output.contains("sectorsize=512"))
        #expect(result.output.contains("capacity=8192"))
    }
}
