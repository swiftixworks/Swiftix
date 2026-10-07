import Testing
@testable import Swiftix

/// The shared option scanner of the network built-ins, and the rule it
/// enforces: an unknown option is a usage error, never an operand.
@Suite("Network command option parsing")
struct NetworkOptionsTests {

    typealias Item = NetworkOptions.Item

    @Test func clustersAttachedAndSeparateValues() throws {
        let items = try NetworkOptions.scan(["-sS", "-c1", "-o", "out", "host", "-w5"],
                                            flags: "sS", valued: "cow")
        #expect(items == [.option("s", nil), .option("S", nil), .option("c", "1"),
                          .option("o", "out"), .operand("host"), .option("w", "5")])
    }

    @Test func longOptionsMapToCanonicalNames() throws {
        let long: [String: NetworkOptions.Long] = ["head": .init("I"), "output": .init("o", value: true)]
        let items = try NetworkOptions.scan(["--head", "--output=a", "--output", "b", "url"], long: long)
        #expect(items == [.option("I", nil), .option("o", "a"), .option("o", "b"), .operand("url")])
    }

    @Test func doubleDashEndsOptionsAndBareDashIsAnOperand() throws {
        let items = try NetworkOptions.scan(["-q", "-", "--", "-x"], flags: "q")
        #expect(items == [.option("q", nil), .operand("-"), .operand("-x")])
    }

    @Test func unknownAndIncompleteOptionsAreFailures() {
        #expect(throws: NetworkOptions.Failure.unknown("x")) {
            _ = try NetworkOptions.scan(["-x"], flags: "q")
        }
        #expect(throws: NetworkOptions.Failure.unknown("q")) {
            _ = try NetworkOptions.scan(["-sq"], flags: "s")
        }
        #expect(throws: NetworkOptions.Failure.unknown("--nope")) {
            _ = try NetworkOptions.scan(["--nope"], flags: "q")
        }
        #expect(throws: NetworkOptions.Failure.missingValue("c")) {
            _ = try NetworkOptions.scan(["-c"], valued: "c")
        }
        #expect(throws: NetworkOptions.Failure.missingValue("--output")) {
            _ = try NetworkOptions.scan(["--output"], long: ["output": .init("o", value: true)])
        }
        #expect(throws: NetworkOptions.Failure.help) {
            _ = try NetworkOptions.scan(["--help"], flags: "q")
        }
    }

    /// Every network command rejects an option it does not know with the same
    /// two-line diagnostic and a non-zero status — it is never taken for a host.
    @Test(arguments: [
        "ping", "traceroute", "curl", "wget", "httpd", "nc", "telnet", "dig", "nslookup", "host",
        "netstat", "ss", "arp", "route", "ifconfig", "tcpdump", "trace", "drops", "dnsd", "ip",
    ])
    func unknownOptionIsAUsageError(command: String) {
        let sh = NetworkShell()
        let out = sh.run("\(command) -% target; echo rc=$?")
        #expect(out.contains("\(command): invalid option -- '"), "\(out)")
        #expect(out.contains("\(command): usage:"), "\(out)")
        #expect(out.contains("rc=2"), "\(out)")
        #expect(!out.contains("resolve"), "\(out)")
        #expect(!out.contains("not known"), "\(out)")
    }

    @Test func helpPrintsUsageAndSucceeds() {
        let sh = NetworkShell()
        let out = sh.run("curl --help; echo rc=$?")
        #expect(out.contains("Usage: curl "))
        #expect(out.contains("rc=0"))
    }
}
