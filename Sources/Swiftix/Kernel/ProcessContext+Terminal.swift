/// `ProcessContext` stream + terminal control: blocking stream reads, isatty,
/// window size, raw mode, and standard-IO wiring.
extension ProcessContext {

    // MARK: - Streams (blocking read)

    /// Install an existing file object (e.g. a pty slave) as a new descriptor.
    @discardableResult
    public func install(_ object: FileObject) -> Int {
        process.fileDescriptors.allocate(object)
    }

    // MARK: - Terminal control (tty)

    /// Whether `fd` refers to a terminal (POSIX `isatty`). A full-screen program
    /// uses this to decide whether raw mode / window-size queries make sense.
    public func isATTY(_ fd: Int) -> Bool {
        process.fileDescriptors.object(fd) is TerminalControl
    }

    /// The window size (rows × columns) of the terminal at `fd`, or `nil` when
    /// `fd` is not a terminal — the moral equivalent of `ioctl(fd, TIOCGWINSZ)`.
    /// A curses-style program reads this to lay itself out and re-reads it to
    /// react to a resize.
    public func terminalWindowSize(_ fd: Int) -> WindowSize? {
        (process.fileDescriptors.object(fd) as? TerminalControl)?.terminalWindowSize
    }

    /// Set the window size of the terminal at `fd` (the app side keeps it in step
    /// with the on-screen grid). Returns `false` when `fd` is not a terminal.
    @discardableResult
    public func setTerminalWindowSize(_ fd: Int, _ size: WindowSize) -> Bool {
        guard let terminal = process.fileDescriptors.object(fd) as? TerminalControl else { return false }
        terminal.terminalWindowSize = size
        return true
    }

    /// Switch the terminal at `fd` into (or out of) raw, non-canonical mode — the
    /// moral equivalent of `cfmakeraw` + `tcsetattr`. In raw mode input arrives
    /// one byte at a time with no echo or line editing, so a full-screen program
    /// receives arrow keys, control bytes, and ESC itself directly. Returns
    /// `false` when `fd` is not a terminal.
    @discardableResult
    public func setTerminalRawMode(_ fd: Int, _ enabled: Bool) -> Bool {
        guard let terminal = process.fileDescriptors.object(fd) as? TerminalControl else { return false }
        terminal.rawMode = enabled
        return true
    }

    /// Set the cooked-line prompt prefix used when Ctrl-L redraws the current
    /// input. This is shell/readline state rather than a PTY guess; foreground
    /// job handoff clears it until the shell presents its next prompt.
    @discardableResult
    func setTerminalLinePrompt(_ fd: Int, _ prompt: String) -> Bool {
        guard let terminal = process.fileDescriptors.object(fd) as? TerminalControl else { return false }
        terminal.linePrompt = Array(prompt.utf8)
        return true
    }

    /// Wire `object` as this process's standard streams — stdin (0), stdout (1),
    /// and stderr (2) — so a program can use the fd 0/1/2 convention (and the
    /// `print`/`arguments` conveniences) without knowing how it was launched.
    /// Used by the shell to connect a spawned command to the terminal.
    @discardableResult
    public func installStandardIO(_ object: FileObject) -> (stdin: Int, stdout: Int, stderr: Int) {
        process.fileDescriptors.install(object, at: 0)
        process.fileDescriptors.install(object, at: 1)
        process.fileDescriptors.install(object, at: 2)
        if let terminal = object as? TerminalControl {
            process.controllingTerminal = terminal
        }
        return (stdin: 0, stdout: 1, stderr: 2)
    }

    /// Blocking read: park the process until the stream has bytes, then resume
    /// with up to 4096 of them. Works on any `ReadableStream` (pty, …). Call as
    /// the tail of a step.
    public func read(_ fd: Int, resume: @escaping (_ bytes: [UInt8]) -> Void) {
        read(fd, max: 4096, resume: resume)
    }

    /// Blocking read with an explicit upper bound. The bound is applied before
    /// bytes leave the underlying object, so ABI adapters with smaller guest
    /// buffers never consume and discard unread data.
    public func read(_ fd: Int,
                     max maxBytes: Int,
                     resume: @escaping (_ bytes: [UInt8]) -> Void) {
        guard let object = process.fileDescriptors.object(fd),
              process.fileDescriptors.access(fd)?.canRead == true else { return }
        let limit = Swift.max(0, maxBytes)
        let kernel = self.kernel
        let process = self.process
        // A regular file (or any non-stream descriptor) never blocks: resume
        // immediately with the bytes at the current offset (empty == EOF). This
        // lets a program read stdin uniformly whether it is a pipe, a tty, or a
        // redirected file (`cat < file`).
        guard let stream = object as? ReadableStream else {
            let waitID = process.beginWait(.descriptor(fd: fd, operation: "read"))
            kernel.runStep(process) {
                process.endWait(waitID)
                resume(object.read(max: limit))
            }
            return
        }
        if stream.hasBytesAvailable {
            let waitID = process.beginWait(.descriptor(fd: fd, operation: "read"))
            kernel.runStep(process) {
                process.endWait(waitID)
                resume(stream.read(max: limit))
            }
            return
        }
        var completed = false
        var subscription: ReadinessSubscription?
        let waitID = process.beginWait(.descriptor(fd: fd, operation: "read")) {
            guard !completed else { return }
            completed = true
            subscription?.cancel()
            subscription = nil
        }
        subscription = stream.addReadWaiter { [weak kernel, weak process] in
            guard let kernel, let process else { return }
            guard !completed else { return }
            completed = true
            subscription?.cancel()
            subscription = nil
            process.disarmWaitCancellation(waitID)
            kernel.runStep(process) {
                process.endWait(waitID)
                resume(stream.read(max: limit))
            }
        }
    }

}
