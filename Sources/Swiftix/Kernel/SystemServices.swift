/// Consumer seams for the two pieces of machine state a host owns rather than
/// the guest: real (wall-clock) time and power control.
///
/// Both are plain `Sendable` values exchanged with `Kernel` on its serial
/// executor; neither introduces a platform dependency into the core.

/// Maps the kernel's logical clock onto real time.
///
/// Swiftix itself only has logical time (`EventLoop.now`). A host that wants
/// `date`, `ls -l`, and file timestamps to show real dates supplies the Unix
/// epoch that corresponds to logical time zero, plus a fixed zone offset — the
/// core has no time-zone database and never reads a platform clock. The default
/// value is fully deterministic: logical time zero is 1970-01-01T00:00:00Z.
///
/// File timestamps are stamped with this clock (`epochAtLogicalZero` + logical
/// seconds), so with the default they are exactly the logical seconds earlier
/// releases stored, and the filesystem snapshot format is unchanged.
public struct WallClock: Sendable, Equatable {
    /// Seconds since 1970-01-01T00:00:00Z at logical time zero of the `EventLoop`.
    public var epochAtLogicalZero: Double
    /// Offset of the displayed local zone east of UTC, in seconds.
    public var utcOffsetSeconds: Int
    /// Abbreviation shown for the local zone (for example `UTC` or `CEST`).
    public var zoneAbbreviation: String

    /// Creates a clock mapping. A non-finite epoch is replaced by `0`.
    public init(epochAtLogicalZero: Double = 0,
                utcOffsetSeconds: Int = 0,
                zoneAbbreviation: String = "UTC") {
        self.epochAtLogicalZero = epochAtLogicalZero.isFinite ? epochAtLogicalZero : 0
        self.utcOffsetSeconds = utcOffsetSeconds
        self.zoneAbbreviation = zoneAbbreviation
    }

    /// The epoch time, in seconds, at `logicalTime` on the kernel's loop.
    public func epochSeconds(atLogicalTime logicalTime: Double) -> Double {
        epochAtLogicalZero + logicalTime
    }
}

/// A guest request to change the machine's power state, delivered to the host
/// through `Kernel.onPowerRequest`.
public enum PowerRequest: Sendable, Equatable {
    /// Halt and power off (`shutdown -h now`, `poweroff`, `halt`).
    case shutdown
    /// Restart the machine (`shutdown -r now`, `reboot`).
    case reboot
}
