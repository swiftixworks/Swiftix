import Testing
@testable import Swiftix

/// `hostname` and its address/name options.
@Suite("hostname command")
struct HostnameCommandTests {

    @Test func printsNamesAndAddresses() {
        let sh = NetworkShell(loopback: true, ethernet: true)
        func lines(_ command: String) -> [String] {
            let rows = sh.run("\(command) > /out; echo rc=$?")
            return (sh.read("/out") ?? "<missing>").split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init) + [rows.contains("rc=0") ? "ok" : "failed"]
        }
        #expect(lines("hostname") == ["swiftix", "", "ok"])
        // Loopback is left out of -I; each address is followed by a space.
        #expect(lines("hostname -I") == ["10.0.0.1 ", "", "ok"])
        #expect(lines("hostname --all-ip-addresses") == ["10.0.0.1 ", "", "ok"])
        #expect(lines("hostname -i") == ["10.0.0.1", "", "ok"])
        sh.run("hostname box.example.org")
        #expect(lines("hostname") == ["box.example.org", "", "ok"])
        #expect(lines("hostname -s") == ["box", "", "ok"])
        #expect(lines("hostname -f") == ["box.example.org", "", "ok"])
    }

    @Test func optionsAreNeverTakenForAName() {
        let sh = NetworkShell(loopback: true)
        #expect(sh.run("hostname -I; echo rc=$?").contains("rc=0"))
        #expect(sh.run("hostname -i").contains("127.0.0.1\n"))          // no other address
        let bad = sh.run("hostname -x; echo rc=$?")
        #expect(bad.contains("hostname: invalid option -- 'x'"))
        #expect(bad.contains("rc=2"))
        #expect(sh.run("hostname").contains("swiftix\n"))
        #expect(sh.run("hostname a b; echo rc=$?").contains("rc=2"))
    }
}
