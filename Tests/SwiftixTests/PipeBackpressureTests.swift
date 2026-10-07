import Testing
@testable import Swiftix

/// Output larger than a pipe buffer (64 KiB) arrives complete: producers park
/// on a full pipe instead of dropping the tail, in pipelines, command
/// substitution, shell functions and compound commands alike.
@Suite("Pipe backpressure through the shell")
struct PipeBackpressureTests {

    /// Run to completion: a long pipeline may need more than one step budget.
    private func settle(_ h: CommandHarness) {
        while h.loop.runUntilIdle() == .budgetExceeded {}
    }

    private func stdout(_ h: CommandHarness, _ line: String) -> String {
        h.run("\(line) > /.big")
        settle(h)
        return h.contents(of: "/.big")
    }

    @Test func commandSubstitutionOfLargeOutputIsExact() {
        let h = CommandHarness()
        // 1..20000 joined by newlines: 108,893 bytes once the last newline is stripped.
        #expect(stdout(h, "x=$(seq 1 20000); echo ${#x}") == "108893\n")
        #expect(stdout(h, "x=$(seq 1 20000); echo \"$x\" | tail -n 1") == "20000\n")
        #expect(stdout(h, "echo $(seq 1 30000 | tail -n 1)") == "30000\n")
        #expect(stdout(h, "printf '%s\\n' $(seq 1 20000) | wc -l") == "20000\n")
    }

    @Test func pipelinesCarryEveryByte() {
        let h = CommandHarness()
        #expect(stdout(h, "seq 1 50000 | sort -rn | head -1") == "50000\n")
        #expect(stdout(h, "seq 1 100000 | wc -l") == "100000\n")
        #expect(stdout(h, "seq 1 20000 | tail -n 1") == "20000\n")
        #expect(stdout(h, "seq 1 20000 | cat | cat | grep -c 9") == "6878\n")
        #expect(stdout(h, "{ seq 1 20000 | tee /copy | wc -c; wc -c < /copy; }") == "108894\n108894\n")
    }

    @Test func aMegabyteFileSurvivesCatAndFilters() {
        let h = CommandHarness()
        h.run("head -c 1048576 /dev/zero > /big")
        settle(h)
        #expect(stdout(h, "cat /big | wc -c") == "1048576\n")
        #expect(stdout(h, "cat /big /big | wc -c") == "2097152\n")
        #expect(stdout(h, "y=$(cat /big | tr '\\0' a); echo ${#y}") == "1048576\n")
        #expect(stdout(h, "cat /big | gzip | gunzip | cmp - /big; echo $?") == "0\n")
    }

    @Test func shellCodeInAPipelineIsNotTruncated() {
        let h = CommandHarness()
        #expect(stdout(h, "f() { seq 1 20000; }; f | wc -l") == "20000\n")
        #expect(stdout(h, "{ seq 1 20000; seq 1 20000; } | wc -l") == "40000\n")
        #expect(stdout(h, "for i in 1 2 3; do seq 1 20000; done | wc -l") == "60000\n")
        #expect(stdout(h, "( seq 1 20000 ) | wc -l") == "20000\n")
        #expect(stdout(h, "seq 1 3000 | while read n; do echo $n; done | tail -n 1") == "3000\n")
    }

    @Test func aReaderThatStopsEarlyEndsTheProducer() {
        let h = CommandHarness()
        #expect(stdout(h, "yes | head -n 3") == "y\ny\ny\n")
        #expect(stdout(h, "seq 1 1000000 | head -n 2") == "1\n2\n")
        #expect(stdout(h, "cat /dev/zero | head -c 5 | wc -c") == "5\n")
        settle(h)
        #expect(!h.kernel.snapshotProcesses().contains { ["yes", "seq", "cat"].contains($0.name) })
    }
}
