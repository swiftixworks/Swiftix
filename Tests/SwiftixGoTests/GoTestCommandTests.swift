/// go test command tests.
///
/// Extracted verbatim from the original single `SwiftixGoTests` suite when it was
/// split per feature area; shared fixtures live in `GoTestSupport.swift`.

import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("go test command")
struct GoTestCommandTests: GoTestHarness {

    @Test func goTestDiscoverAndRunsTestFunctions() {
        let output = runShell(
            ["cd /testpkg", "go test"],
            seed: { context in
                _ = context.mkdir("/testpkg")
                Self.write(context, path: "/testpkg/go.mod", contents: "module example/testpkg\n\ngo 1.24\n")
                Self.write(
                    context, path: "/testpkg/math.go",
                    contents: "package main\nfunc Add(a, b int) int { return a + b }\n")
                Self.write(
                    context, path: "/testpkg/math_test.go",
                    contents: "package main\nfunc TestAddPositive() {\n\tresult := Add(2, 3)\n\tif result != 5 {\n\t\tpanic(\"expected 5\")\n\t}\n}\nfunc TestAddZero() {\n\tresult := Add(0, 0)\n\tif result != 0 {\n\t\tpanic(\"expected 0\")\n\t}\n}\n")
            })

        #expect(output.contains("PASS: TestAddPositive"))
        #expect(output.contains("PASS: TestAddZero"))
        #expect(output.contains("ok"))
    }

    @Test func goTestReportsFailingTests() {
        let output = runShell(
            ["cd /failpkg", "go test"],
            seed: { context in
                _ = context.mkdir("/failpkg")
                Self.write(context, path: "/failpkg/go.mod", contents: "module example/failpkg\n\ngo 1.24\n")
                Self.write(
                    context, path: "/failpkg/lib.go",
                    contents: "package main\nfunc Broken() int { return 42 }\n")
                Self.write(
                    context, path: "/failpkg/lib_test.go",
                    contents: "package main\nfunc TestBroken() {\n\tif Broken() != 99 {\n\t\tpanic(\"wrong value\")\n\t}\n}\n")
            })

        #expect(output.contains("FAIL: TestBroken"))
        #expect(output.contains("FAIL"))
    }

    @Test func goTestTreatsNonzeroOsExitAsFailure() {
        let output = runShell(
            ["cd /exit-test", "go test", "echo status=$?"],
            seed: { context in
                _ = context.mkdir("/exit-test")
                Self.write(
                    context,
                    path: "/exit-test/go.mod",
                    contents: "module example/exit-test\n\ngo 1.24\n")
                Self.write(
                    context,
                    path: "/exit-test/main.go",
                    contents: "package main\nfunc main() {}\n")
                Self.write(
                    context,
                    path: "/exit-test/exit_test.go",
                    contents: "package main\nimport \"os\"\nfunc TestExit() { os.Exit(5) }\n")
            })

        #expect(output.contains("FAIL: TestExit"))
        #expect(output.contains("test exited with status 5"))
        #expect(output.contains("status=1"))
    }

    @Test func goTestUsesTestingTSubtestsAndRecursesAcrossModule() {
        let output = runShell(
            ["cd /testing-module", "go test ./...", "echo status=$?"],
            seed: { context in
                _ = context.mkdir("/testing-module/math")
                Self.write(
                    context, path: "/testing-module/go.mod",
                    contents: "module example/testing\n\ngo 1.24\n")
                Self.write(
                    context, path: "/testing-module/main.go",
                    contents: "package main\nfunc main() {}\n")
                Self.write(
                    context, path: "/testing-module/main_test.go",
                    contents: "package main\nimport \"testing\"\nfunc TestRoot(t *testing.T) { t.Run(\"child\", func(t *testing.T) { if 2 + 2 != 4 { t.Fatal(\"bad math\") } }) }\n")
                Self.write(
                    context, path: "/testing-module/math/math.go",
                    contents: "package math\nfunc Add(a, b int) int { return a + b }\n")
                Self.write(
                    context, path: "/testing-module/math/math_test.go",
                    contents: "package math\nimport \"testing\"\nfunc TestAdd(t *testing.T) { if Add(2, 3) != 5 { t.Error(\"want 5\") } }\n")
            })

        #expect(output.contains("--- PASS: TestRoot"))
        #expect(output.contains("--- PASS: TestRoot/child"))
        #expect(output.contains("--- PASS: TestAdd"))
        #expect(output.contains("ok  \texample/testing"))
        #expect(output.contains("ok  \texample/testing/math"))
        #expect(output.contains("status=0"))
    }

    @Test func testingTErrorAndFatalFailThePackageAndReportMessages() {
        let output = runShell(
            ["cd /testing-fail", "go test", "echo status=$?"],
            seed: { context in
                _ = context.mkdir("/testing-fail")
                Self.write(
                    context, path: "/testing-fail/go.mod",
                    contents: "module example/testing-fail\n\ngo 1.24\n")
                Self.write(
                    context, path: "/testing-fail/main.go",
                    contents: "package main\nfunc main() {}\n")
                Self.write(
                    context, path: "/testing-fail/main_test.go",
                    contents: "package main\nimport \"fmt\"\nimport \"testing\"\nfunc TestError(t *testing.T) { t.Error(\"soft failure\") }\nfunc fatalHelper(t *testing.T) {\n\tdefer fmt.Println(\"fatal defer\")\n\tt.Fatal(\"fatal failure\")\n\tt.Error(\"helper unreachable\")\n}\nfunc TestFatal(t *testing.T) {\n\tfatalHelper(t)\n\tt.Error(\"caller unreachable\")\n}\nfunc TestSubtest(t *testing.T) {\n\tpassed := t.Run(\"child\", func(t *testing.T) {\n\t\tt.Fatal(\"child fatal\")\n\t\tt.Error(\"unreachable\")\n\t})\n\tif passed { t.Error(\"T.Run should report failure\") }\n}\n")
            })

        #expect(output.contains("soft failure"))
        #expect(output.contains("fatal failure"))
        #expect(output.contains("fatal defer"))
        #expect(output.contains("--- FAIL: TestError"))
        #expect(output.contains("--- FAIL: TestFatal"))
        #expect(output.contains("--- FAIL: TestSubtest/child"))
        #expect(!output.contains("helper unreachable"))
        #expect(!output.contains("caller unreachable"))
        #expect(!output.contains("unreachable"))
        #expect(!output.contains("T.Run should report failure"))
        #expect(output.contains("status=1"))
    }
}
