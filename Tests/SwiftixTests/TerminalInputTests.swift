import Testing
@testable import Swiftix

/// Terminal line-discipline features: up/down arrow command history, arrow-key
/// handling (no garbage insertion), and the `more` pager (including a piped
/// `seq | more` that advances via keypresses on the terminal).
@Suite("Terminal history + pager")
struct TerminalInputTests {

    // Escape sequences for the arrow keys.
    private let up: [UInt8]    = [0x1B, 0x5B, 0x41]
    private let down: [UInt8]  = [0x1B, 0x5B, 0x42]
    private let right: [UInt8] = [0x1B, 0x5B, 0x43]
    private let left: [UInt8]  = [0x1B, 0x5B, 0x44]

    // MARK: - History

    @Test func upRecallsPreviousCommand() {
        let pty = PseudoTerminal()
        pty.writeFromApp(Array("echo hi\n".utf8))
        _ = pty.slave.read(max: 4096)          // shell would consume the committed line
        pty.writeFromApp(up)                    // recall "echo hi"
        pty.writeFromApp(Array("\n".utf8))      // commit the recalled line
        #expect(String(decoding: pty.slave.read(max: 4096), as: UTF8.self) == "echo hi\n")
    }

    @Test func upTwiceReachesOlderCommand() {
        let pty = PseudoTerminal()
        pty.writeFromApp(Array("one\n".utf8)); _ = pty.slave.read(max: 4096)
        pty.writeFromApp(Array("two\n".utf8)); _ = pty.slave.read(max: 4096)
        pty.writeFromApp(up)                    // -> "two"
        pty.writeFromApp(up)                    // -> "one"
        pty.writeFromApp(Array("\n".utf8))
        #expect(String(decoding: pty.slave.read(max: 4096), as: UTF8.self) == "one\n")
    }

    @Test func downReturnsToTheEditedDraft() {
        let pty = PseudoTerminal()
        pty.writeFromApp(Array("first\n".utf8)); _ = pty.slave.read(max: 4096)
        pty.writeFromApp(Array("second".utf8))  // partial fresh draft (no newline)
        pty.writeFromApp(up)                    // stash "second", recall "first"
        pty.writeFromApp(down)                  // back to the stashed "second"
        pty.writeFromApp(Array("\n".utf8))
        #expect(String(decoding: pty.slave.read(max: 4096), as: UTF8.self) == "second\n")
    }

    @Test func arrowKeysAreNotInsertedAsText() {
        let pty = PseudoTerminal()
        pty.writeFromApp(Array("ab".utf8))
        pty.writeFromApp(right)                 // ignored, must not insert bytes
        pty.writeFromApp(Array("c\n".utf8))
        #expect(String(decoding: pty.slave.read(max: 4096), as: UTF8.self) == "abc\n")
    }

    @Test func emptyHistoryUpDoesNothing() {
        let pty = PseudoTerminal()
        pty.writeFromApp(Array("xy".utf8))
        pty.writeFromApp(up)                    // no history yet -> no change
        pty.writeFromApp(Array("\n".utf8))
        #expect(String(decoding: pty.slave.read(max: 4096), as: UTF8.self) == "xy\n")
    }

    // MARK: - Left/Right cursor editing

    @Test func leftArrowThenInsertPlacesCharAtCursor() {
        let pty = PseudoTerminal()
        pty.writeFromApp(Array("ac".utf8))       // "ac", cursor at end
        pty.writeFromApp(left)                    // cursor between a and c
        pty.writeFromApp(Array("b".utf8))         // insert -> "abc"
        pty.writeFromApp(Array("\n".utf8))
        #expect(String(decoding: pty.slave.read(max: 4096), as: UTF8.self) == "abc\n")
    }

    @Test func backspaceDeletesCharBeforeCursorMidLine() {
        let pty = PseudoTerminal()
        pty.writeFromApp(Array("abc".utf8))       // cursor at end (3)
        pty.writeFromApp(left)                     // -> before 'c' (2)
        pty.writeFromApp(left)                     // -> before 'b' (1)
        pty.writeFromApp([0x7F])                   // erase char before cursor -> 'a' removed
        pty.writeFromApp(Array("\n".utf8))
        #expect(String(decoding: pty.slave.read(max: 4096), as: UTF8.self) == "bc\n")
    }

    @Test func rightArrowMovesCursorBackToEnd() {
        let pty = PseudoTerminal()
        pty.writeFromApp(Array("ab".utf8))         // cursor at 2
        pty.writeFromApp(left)                      // cursor at 1
        pty.writeFromApp(right)                     // cursor back at 2 (end)
        pty.writeFromApp(Array("c".utf8))           // append -> "abc"
        pty.writeFromApp(Array("\n".utf8))
        #expect(String(decoding: pty.slave.read(max: 4096), as: UTF8.self) == "abc\n")
    }

    @Test func leftArrowClampsAtStart() {
        let pty = PseudoTerminal()
        pty.writeFromApp(Array("ab".utf8))
        pty.writeFromApp(left); pty.writeFromApp(left); pty.writeFromApp(left)  // clamp at 0
        pty.writeFromApp(Array("X".utf8))           // insert at start -> "Xab"
        pty.writeFromApp(Array("\n".utf8))
        #expect(String(decoding: pty.slave.read(max: 4096), as: UTF8.self) == "Xab\n")
    }

    @Test func rightArrowClampsAtEnd() {
        let pty = PseudoTerminal()
        pty.writeFromApp(Array("ab".utf8))
        pty.writeFromApp(right); pty.writeFromApp(right)   // already at end: no-op
        pty.writeFromApp(Array("c".utf8))
        pty.writeFromApp(Array("\n".utf8))
        #expect(String(decoding: pty.slave.read(max: 4096), as: UTF8.self) == "abc\n")
    }

    // MARK: - Pager

    @Test func moreShortContentPrintsWithoutPrompt() {
        let out = runShell(["seq 3 | more"])
        #expect(contains(out, Array("1\n2\n3".utf8)))
        #expect(!contains(out, Array("--More--".utf8)))
    }

    @Test func morePagesLongContentAdvancedByKeypress() {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        pty.writeFromApp(Array("export LINES=3\n".utf8))   // page height 3 -> 2 lines/page
        loop.runUntilIdle()
        pty.writeFromApp(Array("seq 5 | more\n".utf8))
        loop.runUntilIdle()

        // Advance through the pages by pressing Enter at each --More-- prompt.
        var guardCounter = 0
        while !contains(captured.out, Array("5\n".utf8)), guardCounter < 20 {
            #expect(contains(captured.out, Array("--More--".utf8)))
            pty.writeFromApp(Array("\n".utf8))
            loop.runUntilIdle()
            guardCounter += 1
        }
        #expect(contains(captured.out, Array("5\n".utf8)))   // reached the last line
    }

    // MARK: - Helpers

    private final class Capture { var out: [UInt8] = [] }

    private func runShell(_ lines: [String]) -> [UInt8] {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let pty = PseudoTerminal()
        let captured = Capture()
        pty.onOutput = { [weak pty] in
            guard let pty else { return }
            captured.out.append(contentsOf: pty.readForApp(max: 65535))
        }
        kernel.spawn("sh", Programs.shell(tty: pty.slave))
        loop.runUntilIdle()
        for line in lines {
            pty.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }
        return captured.out
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
