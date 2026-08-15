/// A pseudo-terminal — the headless console primitive a host app drives. The app
/// feeds keystrokes via `writeFromApp` and reads display output via `readForApp`
/// (`onOutput` fires when output is available). The shell process uses `slave`
/// as its stdin + stdout.
///
/// Canonical line discipline: input is line-buffered (a slave `read` sees a whole
/// line once Enter is pressed) and echoed to the display. Ctrl-C (0x03) fires
/// `onControlC`; Ctrl-Z (0x1A) fires `onControlZ`. Common readline-style control
/// keys (A/E/K/L/U/W) edit or redraw the current cooked input line. Raw mode
/// forwards every byte untouched to the foreground program.
///
/// Terminal control operations a process performs on its controlling tty — the
/// moral equivalent of `termios`, `TIOCGWINSZ`, and `tcsetpgrp`. A pty slave
/// conforms so a process holding it as a descriptor can update terminal-local
/// state through `ProcessContext`.
protocol TerminalControl: AnyObject {
    var rawMode: Bool { get set }
    var terminalWindowSize: WindowSize { get set }
    var foregroundProcessGroupID: PID? { get set }
    var linePrompt: [UInt8] { get set }
}

/// Ordered slave-side input. EOF is a record in the same queue as bytes so
/// `Ctrl-D`, later input, and repeated EOF events cannot overtake or coalesce.
private struct TerminalInputQueue {
    private enum Element {
        case byte(UInt8)
        case endOfFile
    }

    private var elements: BoundedFIFOQueue<Element>

    init(capacity: Int) {
        elements = BoundedFIFOQueue(capacity: capacity)
    }

    var isEmpty: Bool { elements.isEmpty }
    var count: Int { elements.count }
    var highWaterMark: Int { elements.highWaterMark }
    var rejectedCount: Int { elements.rejectedCount }

    @discardableResult
    mutating func append<S: Sequence>(contentsOf bytes: S) -> Int where S.Element == UInt8 {
        elements.append(contentsOf: bytes.lazy.map(Element.byte))
    }

    @discardableResult
    mutating func appendEndOfFile() -> Bool {
        elements.append(.endOfFile)
    }

    mutating func popFirst(_ maximumCount: Int) -> [UInt8] {
        guard let first = elements.first else { return [] }
        if case .endOfFile = first {
            _ = elements.popFirst()
            return []
        }

        let limit = max(0, maximumCount)
        guard limit > 0 else { return [] }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(limit, elements.count))
        while bytes.count < limit, let next = elements.first {
            guard case .byte(let byte) = next else { break }
            _ = elements.popFirst()
            bytes.append(byte)
        }
        return bytes
    }
}

public final class PseudoTerminal {
    static let maximumCanonicalLineBytes = 4 * 1_024
    static let maximumSlaveInputBytes = 64 * 1_024
    static let maximumMasterOutputBytes = 1 * 1_024 * 1_024
    static let maximumHistoryEntries = 100
    static let maximumHistoryBytes = 64 * 1_024

    public struct QueueStatistics: Sendable, Equatable {
        public let slaveInputBytes: Int
        public let slaveInputHighWater: Int
        public let masterOutputBytes: Int
        public let masterOutputHighWater: Int
        public let historyEntries: Int
        public let historyBytes: Int
        public let droppedInputBytes: Int
        public let droppedOutputBytes: Int
    }

    public init() {}

    public var echo = true

    /// Raw (non-canonical) input mode — the moral equivalent of `cfmakeraw`.
    /// While true, every app byte is delivered to the slave immediately without
    /// echo, line buffering, history handling, or terminal-generated signals.
    public var rawMode = false

    /// Character-cell dimensions reported to programs through the tty syscall
    /// surface. Defaults to the traditional 24×80 before a view lays itself out.
    public var windowSize = WindowSize(rows: 24, columns: 80)

    /// Foreground job for this PTY. Keeping this on the terminal rather than only
    /// on Kernel is what makes job-control signals safe across terminal tabs.
    public var foregroundProcessGroupID: PID?

    /// Prefix redrawn by Ctrl-L in cooked mode. The interactive shell updates it
    /// when switching between its primary and continuation prompts; foreground
    /// programs clear it through job-control handoff, so the PTY never invents
    /// shell UI for another reader.
    public var linePrompt: [UInt8] = []

    private var inputLine: [UInt8] = []
    private var slaveReadable = TerminalInputQueue(capacity: maximumSlaveInputBytes)
    private var masterReadable = BoundedFIFOQueue<UInt8>(capacity: maximumMasterOutputBytes)

    private var history: [[UInt8]] = []
    private var historyBytes = 0
    private var droppedCanonicalInputBytes = 0
    private var historyCursor: Int?
    private var savedDraft: [UInt8] = []
    private enum EscapeState { case none, sawESC, csi }
    private var escapeState: EscapeState = .none

    /// UTF-8 byte insertion point within `inputLine`.
    private var cursor = 0

    fileprivate var slaveReadWaiter: (() -> Void)?
    private let slaveReadinessBroadcaster = ReadinessBroadcaster()
    public var onOutput: (() -> Void)?
    public var onControlC: (() -> Void)?
    public var onControlZ: (() -> Void)?

    public lazy var slave: Slave = Slave(terminal: self)

    // MARK: - App side

    /// Feed input bytes (keystrokes) from the app.
    public func writeFromApp(_ bytes: [UInt8]) {
        if rawMode {
            guard !bytes.isEmpty else { return }
            slaveReadable.append(contentsOf: bytes)
            let waiter = slaveReadWaiter
            slaveReadWaiter = nil
            waiter?()
            slaveReadinessBroadcaster.notify()
            return
        }

        var producedOutput = false
        for byte in bytes {
            // Cooked-mode arrow sequences are consumed by line editing/history.
            switch escapeState {
            case .sawESC:
                escapeState = (byte == 0x5B) ? .csi : .none
                continue
            case .csi:
                if byte >= 0x40, byte <= 0x7E {
                    escapeState = .none
                    switch byte {
                    case 0x41: producedOutput = historyRecall(older: true) || producedOutput
                    case 0x42: producedOutput = historyRecall(older: false) || producedOutput
                    case 0x43: producedOutput = moveCursorRight() || producedOutput
                    case 0x44: producedOutput = moveCursorLeft() || producedOutput
                    default: break
                    }
                }
                continue
            case .none:
                break
            }

            if byte == 0x1B {
                escapeState = .sawESC
                continue
            }
            if byte == 0x03 {
                if echo {
                    masterReadable.append(contentsOf: Array("^C\n".utf8))
                    producedOutput = true
                }
                inputLine.removeAll(); cursor = 0
                resetHistoryBrowsing()
                onControlC?()
                continue
            }
            if byte == 0x1A {
                if echo {
                    masterReadable.append(contentsOf: Array("^Z\n".utf8))
                    producedOutput = true
                }
                inputLine.removeAll(); cursor = 0
                resetHistoryBrowsing()
                onControlZ?()
                continue
            }
            if byte == 0x01 { // Ctrl-A: beginning of line
                producedOutput = moveCursorToStart() || producedOutput
                continue
            }
            if byte == 0x05 { // Ctrl-E: end of line
                producedOutput = moveCursorToEnd() || producedOutput
                continue
            }
            if byte == 0x0B { // Ctrl-K: erase cursor -> end
                producedOutput = eraseToLineEnd() || producedOutput
                historyCursor = nil
                continue
            }
            if byte == 0x0C { // Ctrl-L: clear screen, redraw prompt + current line
                producedOutput = clearAndRedrawInput() || producedOutput
                continue
            }
            if byte == 0x15 { // Ctrl-U: erase beginning -> cursor
                producedOutput = eraseToLineStart() || producedOutput
                historyCursor = nil
                continue
            }
            if byte == 0x17 { // Ctrl-W: erase previous word
                producedOutput = erasePreviousWord() || producedOutput
                historyCursor = nil
                continue
            }
            if byte == 0x04 { // Ctrl-D: delete, submit partial line, or VEOF
                if cursor < inputLine.count {
                    producedOutput = deleteAtCursor() || producedOutput
                    historyCursor = nil
                } else {
                    submitCanonicalEOF()
                }
                continue
            }
            if byte == 0x7F || byte == 0x08 {
                producedOutput = eraseBeforeCursor() || producedOutput
                historyCursor = nil
                continue
            }
            if byte == 0x0A {
                if echo { masterReadable.append(0x0A); producedOutput = true }
                inputLine.append(0x0A)
                recordHistory(inputLine)
                slaveReadable.append(contentsOf: inputLine)
                inputLine.removeAll(); cursor = 0
                resetHistoryBrowsing()
                let waiter = slaveReadWaiter
                slaveReadWaiter = nil
                waiter?()
                slaveReadinessBroadcaster.notify()
                continue
            }

            // Ignore remaining C0 control bytes in cooked mode. Full-screen/raw
            // programs still receive them byte-for-byte through the fast path.
            guard byte >= 0x20 else { continue }
            producedOutput = insertAtCursor(byte) || producedOutput
            historyCursor = nil
        }
        if producedOutput { onOutput?() }
    }

    // MARK: - Line editing (cursor-aware)

    private func columns(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $1 & 0xC0 == 0x80 ? $0 : $0 + 1 }
    }

    private func insertAtCursor(_ byte: UInt8) -> Bool {
        guard inputLine.count < Self.maximumCanonicalLineBytes - 1 else {
            droppedCanonicalInputBytes += 1
            return false
        }
        inputLine.insert(byte, at: cursor)
        cursor += 1
        guard echo else { return false }
        masterReadable.append(byte)
        if cursor < inputLine.count {
            let tail = inputLine[cursor...]
            masterReadable.append(contentsOf: tail)
            for _ in 0..<columns(tail) { masterReadable.append(0x08) }
        }
        return true
    }

    private func eraseBeforeCursor() -> Bool {
        guard cursor > 0 else { return false }
        var start = cursor - 1
        while start > 0, (inputLine[start] & 0xC0) == 0x80 { start -= 1 }
        inputLine.removeSubrange(start..<cursor)
        cursor = start
        guard echo else { return false }
        let tail = inputLine[cursor...]
        masterReadable.append(0x08)
        masterReadable.append(contentsOf: tail)
        masterReadable.append(0x20)
        for _ in 0..<(columns(tail) + 1) { masterReadable.append(0x08) }
        return true
    }

    private func deleteAtCursor() -> Bool {
        guard cursor < inputLine.count else { return false }
        var end = cursor + 1
        while end < inputLine.count, (inputLine[end] & 0xC0) == 0x80 { end += 1 }
        return eraseRange(cursor..<end, cursorAfter: cursor)
    }

    /// Canonical Ctrl-D: pending characters become one readable record without a
    /// newline; an empty line produces one EOF read. Both wake a parked reader.
    private func submitCanonicalEOF() {
        if inputLine.isEmpty {
            slaveReadable.appendEndOfFile()
        } else {
            slaveReadable.append(contentsOf: inputLine)
            inputLine.removeAll()
            cursor = 0
            resetHistoryBrowsing()
        }
        let waiter = slaveReadWaiter
        slaveReadWaiter = nil
        waiter?()
        slaveReadinessBroadcaster.notify()
    }

    private func moveCursorLeft() -> Bool {
        guard cursor > 0 else { return false }
        var start = cursor - 1
        while start > 0, (inputLine[start] & 0xC0) == 0x80 { start -= 1 }
        cursor = start
        guard echo else { return false }
        masterReadable.append(0x08)
        return true
    }

    private func moveCursorRight() -> Bool {
        guard cursor < inputLine.count else { return false }
        var end = cursor + 1
        while end < inputLine.count, (inputLine[end] & 0xC0) == 0x80 { end += 1 }
        guard echo else { cursor = end; return false }
        masterReadable.append(contentsOf: inputLine[cursor..<end])
        cursor = end
        return true
    }

    private func moveCursorToStart() -> Bool {
        guard cursor > 0 else { return false }
        let distance = columns(inputLine[..<cursor])
        cursor = 0
        guard echo else { return false }
        for _ in 0..<distance { masterReadable.append(0x08) }
        return true
    }

    private func moveCursorToEnd() -> Bool {
        guard cursor < inputLine.count else { return false }
        let tail = inputLine[cursor...]
        cursor = inputLine.count
        guard echo else { return false }
        masterReadable.append(contentsOf: tail)
        return true
    }

    private func eraseToLineStart() -> Bool {
        guard cursor > 0 else { return false }
        return eraseRange(0..<cursor, cursorAfter: 0)
    }

    private func eraseToLineEnd() -> Bool {
        guard cursor < inputLine.count else { return false }
        return eraseRange(cursor..<inputLine.count, cursorAfter: cursor)
    }

    private func erasePreviousWord() -> Bool {
        guard cursor > 0 else { return false }
        var start = cursor
        while start > 0, inputLine[start - 1] == 0x20 || inputLine[start - 1] == 0x09 {
            start -= 1
        }
        while start > 0, inputLine[start - 1] != 0x20, inputLine[start - 1] != 0x09 {
            start -= 1
        }
        return eraseRange(start..<cursor, cursorAfter: start)
    }

    /// Redraw the whole editable region after a range mutation. Starting from the
    /// current visual cursor, advance to the old end, erase the old input, draw
    /// the replacement, then back up to its logical cursor.
    private func eraseRange(_ range: Range<Int>, cursorAfter: Int) -> Bool {
        guard !range.isEmpty else { return false }
        let oldLine = inputLine
        let oldCursor = cursor
        inputLine.removeSubrange(range)
        cursor = cursorAfter
        guard echo else { return false }

        masterReadable.append(contentsOf: oldLine[oldCursor...])
        for _ in 0..<columns(oldLine[...]) {
            masterReadable.append(contentsOf: [0x08, 0x20, 0x08])
        }
        masterReadable.append(contentsOf: inputLine)
        for _ in 0..<columns(inputLine[cursor...]) { masterReadable.append(0x08) }
        return true
    }

    /// Clear the ANSI display and redraw the prompt supplied by the current
    /// cooked reader plus its uncommitted line, preserving cursor position.
    private func clearAndRedrawInput() -> Bool {
        guard echo else { return false }
        masterReadable.append(contentsOf: [0x1B, 0x5B, 0x32, 0x4A, 0x1B, 0x5B, 0x48]) // ESC[2J ESC[H
        masterReadable.append(contentsOf: linePrompt)
        masterReadable.append(contentsOf: inputLine)
        for _ in 0..<columns(inputLine[cursor...]) { masterReadable.append(0x08) }
        return true
    }

    // MARK: - History

    private func recordHistory(_ line: [UInt8]) {
        var entry = line
        if entry.last == 0x0A { entry.removeLast() }
        guard !entry.isEmpty, history.last != entry else { return }
        guard entry.count <= Self.maximumHistoryBytes else { return }
        while !history.isEmpty,
              history.count >= Self.maximumHistoryEntries
                || historyBytes > Self.maximumHistoryBytes - entry.count {
            historyBytes -= history.removeFirst().count
        }
        history.append(entry)
        historyBytes += entry.count
    }

    private func resetHistoryBrowsing() {
        historyCursor = nil
        savedDraft = []
    }

    private func replaceInputLine(with newLine: [UInt8]) {
        if echo {
            masterReadable.append(contentsOf: inputLine[cursor...])
            for _ in 0..<columns(inputLine[...]) {
                masterReadable.append(contentsOf: [0x08, 0x20, 0x08])
            }
            masterReadable.append(contentsOf: newLine)
        }
        inputLine = newLine
        cursor = newLine.count
    }

    private func historyRecall(older: Bool) -> Bool {
        if older {
            guard !history.isEmpty else { return false }
            if historyCursor == nil {
                savedDraft = inputLine
                historyCursor = history.count - 1
            } else if historyCursor! > 0 {
                historyCursor! -= 1
            }
            replaceInputLine(with: history[historyCursor!])
            return true
        }

        guard let browseCursor = historyCursor else { return false }
        if browseCursor < history.count - 1 {
            historyCursor = browseCursor + 1
            replaceInputLine(with: history[historyCursor!])
        } else {
            historyCursor = nil
            replaceInputLine(with: savedDraft)
        }
        return true
    }

    public var currentInputLine: String { String(decoding: inputLine, as: UTF8.self) }

    public func readForApp(max: Int) -> [UInt8] {
        let wasFull = masterReadable.remainingCapacity == 0
        let result = masterReadable.popFirst(max)
        if wasFull, !result.isEmpty { slaveReadinessBroadcaster.notify() }
        return result
    }

    /// Current depth, high-water, and drop counters for the terminal's bounded
    /// queues. Full input/output queues retain old data and drop newest bytes.
    public var queueStatistics: QueueStatistics {
        QueueStatistics(slaveInputBytes: slaveReadable.count,
                        slaveInputHighWater: slaveReadable.highWaterMark,
                        masterOutputBytes: masterReadable.count,
                        masterOutputHighWater: masterReadable.highWaterMark,
                        historyEntries: history.count,
                        historyBytes: historyBytes,
                        droppedInputBytes: slaveReadable.rejectedCount
                            + droppedCanonicalInputBytes,
                        droppedOutputBytes: masterReadable.rejectedCount)
    }

    // MARK: - Slave side (used by the shell)

    fileprivate func slaveRead(max: Int) -> [UInt8] {
        slaveReadable.popFirst(max)
    }

    fileprivate var slaveHasData: Bool { !slaveReadable.isEmpty }

    fileprivate func addSlaveReadinessListener(_ listener: @escaping () -> Void) -> ReadinessSubscription {
        slaveReadinessBroadcaster.add(listener)
    }

    fileprivate func slaveWrite(_ bytes: [UInt8]) -> Int {
        let accepted = masterReadable.append(contentsOf: bytes)
        if accepted > 0 { onOutput?() }
        return accepted
    }

    public final class Slave: FileObject, ReadableStream, ReadinessEventSource, TerminalControl {
        private unowned let terminal: PseudoTerminal

        init(terminal: PseudoTerminal) {
            self.terminal = terminal
        }

        var rawMode: Bool {
            get { terminal.rawMode }
            set { terminal.rawMode = newValue }
        }

        var terminalWindowSize: WindowSize {
            get { terminal.windowSize }
            set { terminal.windowSize = newValue }
        }

        var foregroundProcessGroupID: PID? {
            get { terminal.foregroundProcessGroupID }
            set { terminal.foregroundProcessGroupID = newValue }
        }

        var linePrompt: [UInt8] {
            get { terminal.linePrompt }
            set { terminal.linePrompt = newValue }
        }

        public func read(max: Int) -> [UInt8] { terminal.slaveRead(max: max) }

        @discardableResult
        public func write(_ bytes: [UInt8]) -> Int {
            terminal.slaveWrite(bytes)
        }

        public var readiness: IOReadiness {
            var mask: IOReadiness = terminal.masterReadable.remainingCapacity > 0
                ? [.writable] : []
            if terminal.slaveHasData { mask.insert(.readable) }
            return mask
        }

        var hasBytesAvailable: Bool { terminal.slaveHasData }
        var onReadable: (() -> Void)? {
            get { terminal.slaveReadWaiter }
            set { terminal.slaveReadWaiter = newValue }
        }

        func addReadinessListener(_ listener: @escaping () -> Void) -> ReadinessSubscription {
            terminal.addSlaveReadinessListener(listener)
        }
    }
}
