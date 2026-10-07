/// `ProcessContext` system services: wall-clock time, the file-mode creation
/// mask, terminal identity, kernel entropy, and guest power requests.
///
/// Concurrency: like the rest of `ProcessContext`, every member is called on the
/// kernel's serial executor and touches only that kernel's state.
extension ProcessContext {

    // MARK: - Wall clock

    /// Current real time as seconds since the Unix epoch (POSIX
    /// `clock_gettime(CLOCK_REALTIME)`), derived from the logical clock through
    /// the host-injected `Kernel.wallClock`. With no injected clock this is
    /// simply the logical time, so it stays deterministic in tests. Use
    /// `monotonicNanoseconds` for intervals; this value can jump when a host
    /// re-anchors the clock.
    public var realtimeSeconds: Double { kernel.epochNow }

    /// The local zone's fixed offset east of UTC, in seconds, as injected by the
    /// host (0 by default).
    public var utcOffsetSeconds: Int { kernel.wallClock.utcOffsetSeconds }

    /// The kernel's wall-clock mapping (epoch anchor, zone offset, abbreviation).
    var wallClock: WallClock { kernel.wallClock }

    /// Calendar fields for an instant on the kernel wall clock — the value
    /// `FileStat.atime/mtime/ctime` and `realtimeSeconds` are expressed in.
    /// `utc: true` ignores the injected zone (`date -u`).
    func calendarTime(_ epoch: Double, utc: Bool = false) -> CalendarTime {
        let clock = kernel.wallClock
        return utc
            ? CalendarTime(epoch: epoch)
            : CalendarTime(epoch: epoch,
                           utcOffsetSeconds: clock.utcOffsetSeconds,
                           zone: clock.zoneAbbreviation)
    }

    /// Calendar fields for the current instant.
    func currentCalendarTime(utc: Bool = false) -> CalendarTime {
        calendarTime(kernel.epochNow, utc: utc)
    }

    /// The `ls -l` time column for a file timestamp (`Oct  7 12:34`, or
    /// `Oct  7  2025` when older than about six months or in the future).
    func longListingTime(_ timestamp: Double) -> String {
        calendarTime(timestamp).longListingString(now: Int64(kernel.epochNow.rounded(.down)))
    }

    /// The `stat` rendering of a file timestamp (`2026-10-07 12:34:56 +0000`).
    func statTime(_ timestamp: Double) -> String {
        calendarTime(timestamp).statString
    }

    // MARK: - File-mode creation mask

    /// This process's file-mode creation mask (POSIX `umask`): the permission
    /// bits cleared from every file, directory, and FIFO it creates. Inherited
    /// by children; 022 for a top-level process.
    public var fileCreationMask: FileMode { process.umask }

    /// Replace the file-mode creation mask and return the previous one (POSIX
    /// `umask(2)`). Only the nine permission bits are retained. Never fails.
    @discardableResult
    public func umask(_ mask: FileMode) -> FileMode {
        let previous = process.umask
        process.umask = FileMode(rawValue: mask.rawValue & 0o777)
        recordSyscall("umask", result: String(previous.rawValue, radix: 8),
                      detail: "mask=\(String(process.umask.rawValue, radix: 8))")
        return previous
    }

    // MARK: - Terminal identity

    /// The name of this process's controlling terminal relative to `/dev`
    /// (`pts/0`), or `nil` when it has none.
    var controllingTerminalName: String? {
        process.controllingTerminal.map { "pts/\(kernel.terminalIndex(for: $0))" }
    }

    /// The `/dev`-relative name of the terminal open at `fd` (POSIX `ttyname`),
    /// or `nil` when `fd` is not a terminal.
    func terminalName(_ fd: Int) -> String? {
        (process.fileDescriptors.object(fd) as? TerminalControl)
            .map { "pts/\(kernel.terminalIndex(for: $0))" }
    }

    /// Whether the terminal at `fd` is in raw (non-canonical, no-echo) mode, or
    /// `nil` when `fd` is not a terminal.
    func terminalRawMode(_ fd: Int) -> Bool? {
        (process.fileDescriptors.object(fd) as? TerminalControl)?.rawMode
    }

    /// Login sessions currently attached to terminals (for `who`/`w`).
    func terminalSessions() -> [Kernel.TerminalSession] {
        kernel.terminalSessions()
    }

    // MARK: - Entropy

    /// `count` bytes from the kernel's deterministic, seedable generator — the
    /// same stream `/dev/urandom` reads. Not cryptographically secure.
    func randomBytes(_ count: Int) -> [UInt8] {
        kernel.randomBytes(count)
    }

    // MARK: - Power

    /// Ask the host to shut down or reboot the machine (the `reboot(2)`
    /// analogue). The request is only forwarded: the host's
    /// `Kernel.onPowerRequest` handler runs later on the kernel executor and
    /// decides what happens, so this call returns normally and the caller keeps
    /// running until the host acts.
    ///
    /// - Returns: `true` when a host handler accepted delivery of the request,
    ///   `false` when the host installed none (power control is unsupported).
    /// - Throws: `SyscallError.permissionDenied` unless the caller is uid 0.
    @discardableResult
    public func requestPower(_ request: PowerRequest) throws -> Bool {
        guard process.uid == 0 else {
            recordSyscall("reboot", error: .permissionDenied, detail: "\(request)")
            throw SyscallError.permissionDenied
        }
        let delivered = kernel.postPowerRequest(request)
        recordSyscall("reboot", result: delivered ? "0" : "-1", detail: "\(request)")
        return delivered
    }
}
