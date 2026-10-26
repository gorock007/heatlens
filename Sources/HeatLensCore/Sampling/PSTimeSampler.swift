import Foundation

/// The read-only `ps` fallback for root and other-user processes, which libproc refuses
/// (docs/FEASIBILITY.md decision 4). `/bin/ps` carries Apple's task-port entitlement, so it
/// reports cumulative CPU `TIME` (10 ms resolution) and RSS for them. Two runs bracketing
/// the interval give a CPU delta. `ps` never lists pid 0.
public struct PSTimeSampler: Sendable {
    public struct Row: Hashable, Sendable {
        public let cpuNanoseconds: UInt64
        public let residentBytes: UInt64
    }

    public struct Reading: Sendable {
        /// Midpoint of the `ps` run on the `CLOCK_UPTIME_RAW` clock; `ps` reads each process
        /// at some moment during its ~30 ms run.
        public let monotonicNanoseconds: UInt64
        public let rows: [Int32: Row]
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    let executable: String
    let arguments: [String]
    let deadline: TimeInterval
    let onLaunch: (@Sendable (Int32) -> Void)?

    public init() {
        self.init(executable: "/bin/ps", arguments: ["-A", "-o", "pid=,time=,rss="])
    }

    /// Tests substitute the executable (a slow one, to cancel mid-run) and observe child PIDs.
    /// A run past `deadline` throws `ChildProcess.TimedOut`, which the scan reports as a ps failure.
    init(executable: String, arguments: [String], deadline: TimeInterval = ChildProcess.defaultDeadline,
         onLaunch: (@Sendable (Int32) -> Void)? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.deadline = deadline
        self.onLaunch = onLaunch
    }

    /// One `ps` run. Throws `CancellationError` (after the child has exited) when cancelled.
    public func snapshot() async throws -> Reading {
        let before = ProcessCounters.monotonicNow()
        let output = try await ChildProcess.run(executable, arguments, deadline: deadline, onLaunch: onLaunch)
        let after = ProcessCounters.monotonicNow()
        guard output.status == 0 else { throw Failure(description: "ps exited with status \(output.status)") }
        return Reading(monotonicNanoseconds: before + (after - before) / 2,
                       rows: Self.parse(String(decoding: output.stdout, as: UTF8.self)))
    }

    /// Parses `pid time rss` lines; malformed lines are skipped.
    public static func parse(_ text: String) -> [Int32: Row] {
        var rows: [Int32: Row] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count == 3, let pid = Int32(cols[0]), let cpu = parseCPUTime(cols[1]),
                  let rssKB = UInt64(cols[2]) else { continue }
            rows[pid] = Row(cpuNanoseconds: cpu, residentBytes: rssKB * 1024)
        }
        return rows
    }

    /// macOS `ps` prints `TIME` as `minutes:seconds.hundredths` with unbounded minutes
    /// (`247:18.96`); `[dd-]hh:mm:ss[.cc]` is accepted too in case a build prints hours.
    public static func parseCPUTime<S: StringProtocol>(_ text: S) -> UInt64? {
        var rest = Substring(text)
        var days: UInt64 = 0
        if let dash = rest.firstIndex(of: "-") {
            guard let d = UInt64(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        var fraction: UInt64 = 0
        if let dot = rest.firstIndex(of: ".") {
            let digits = rest[rest.index(after: dot)...]
            guard !digits.isEmpty, digits.count <= 9, let f = UInt64(digits) else { return nil }
            fraction = f * pow10(9 - digits.count)
            rest = rest[..<dot]
        }
        let fields = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { return nil }
        var seconds: UInt64 = 0
        for field in fields {
            guard !field.isEmpty, let v = UInt64(field) else { return nil }
            seconds = seconds * 60 + v
        }
        return (days * 86_400 + seconds) * 1_000_000_000 + fraction
    }

    private static func pow10(_ n: Int) -> UInt64 {
        (0..<n).reduce(1) { acc, _ in acc * 10 }
    }
}
