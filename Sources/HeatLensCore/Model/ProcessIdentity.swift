import Foundation

/// Identifies one process *instance*. A PID is reused after exit; the pair
/// (pid, start time) is unique for the life of a boot (PRD §4.1, FR-09).
///
/// `startTimeMicros` is the kernel's fork timestamp in microseconds since the Unix
/// epoch (`proc_bsdinfo.pbi_start_tvsec/usec`, the same value `ps -o lstart` shows).
/// It is assigned once and never changes, so two readings of a live process compare
/// equal, and a reused PID compares unequal.
public struct ProcessIdentity: Hashable, Codable, Sendable, CustomStringConvertible {
    public let pid: Int32
    public let startTimeMicros: Int64

    public init(pid: Int32, startTimeMicros: Int64) {
        self.pid = pid
        self.startTimeMicros = startTimeMicros
    }

    /// Builds from the two fields libproc reports.
    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.init(pid: pid, startTimeMicros: Int64(startSeconds) * 1_000_000 + Int64(startMicroseconds))
    }

    public var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(startTimeMicros) / 1_000_000)
    }

    /// Seconds the process has been alive at `now`; never negative.
    public func uptime(at now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(startDate))
    }

    public var description: String {
        "pid \(pid) started \(startDate)"
    }
}
