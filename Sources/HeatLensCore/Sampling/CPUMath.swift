import Darwin
import Foundation

/// Converts Mach absolute-time ticks to nanoseconds. On Apple Silicon the timebase is
/// 125/3 (a 24 MHz counter), so ticks are *not* nanoseconds; on Intel it is 1/1.
/// Per-process CPU counters from `proc_pidinfo(PROC_PIDTASKINFO)` and
/// `proc_pid_rusage` are in these ticks, as is `mach_absolute_time()`.
public struct MachTimebase: Sendable, Equatable {
    public let numer: UInt32
    public let denom: UInt32

    public init(numer: UInt32, denom: UInt32) {
        self.numer = numer
        self.denom = max(denom, 1)
    }

    /// The running kernel's timebase.
    public static func current() -> MachTimebase {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return MachTimebase(numer: info.numer, denom: info.denom)
    }

    /// Overflow-safe: a 64-bit tick count times a 32-bit numerator fits in 128 bits.
    public func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        if numer == denom { return ticks }
        let (high, low) = ticks.multipliedFullWidth(by: UInt64(numer))
        let (quotient, _) = UInt64(denom).dividingFullWidth((high: high, low: low))
        return quotient
    }
}

/// CPU time consumed by a process, in nanoseconds, split as the kernel reports it.
public struct CPUTime: Hashable, Codable, Sendable {
    public var userNanoseconds: UInt64
    public var systemNanoseconds: UInt64

    public init(userNanoseconds: UInt64, systemNanoseconds: UInt64) {
        self.userNanoseconds = userNanoseconds
        self.systemNanoseconds = systemNanoseconds
    }

    public init(userTicks: UInt64, systemTicks: UInt64, timebase: MachTimebase) {
        self.init(userNanoseconds: timebase.nanoseconds(fromTicks: userTicks),
                  systemNanoseconds: timebase.nanoseconds(fromTicks: systemTicks))
    }

    public var totalNanoseconds: UInt64 { userNanoseconds &+ systemNanoseconds }
}

/// Aggregate CPU ticks for a core or the whole host, from
/// `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`. These are scheduler ticks
/// (`CLK_TCK`), not Mach time, so only ratios between them are meaningful.
public struct CPULoadTicks: Hashable, Codable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public var busy: UInt64 { user &+ system &+ nice }
    public var total: UInt64 { busy &+ idle }

    /// 0...1 share of the interval the core(s) were busy; 0 when nothing elapsed.
    public var busyFraction: Double {
        total == 0 ? 0 : Double(busy) / Double(total)
    }

    public static func + (lhs: CPULoadTicks, rhs: CPULoadTicks) -> CPULoadTicks {
        CPULoadTicks(user: lhs.user &+ rhs.user, system: lhs.system &+ rhs.system,
                     idle: lhs.idle &+ rhs.idle, nice: lhs.nice &+ rhs.nice)
    }
}

/// Interval arithmetic for CPU utilisation (PRD §4.1, FR-03). Cumulative CPU time is
/// never shown as utilisation; only the delta across a measured interval is.
public enum CPUMath {
    /// Difference between two readings of one process. Returns nil when any counter
    /// went backwards, which means the PID was reused or the reading is unusable; the
    /// caller drops the sample instead of showing a negative or absurd number.
    public static func delta(before: CPUTime, after: CPUTime) -> CPUTime? {
        guard after.userNanoseconds >= before.userNanoseconds,
              after.systemNanoseconds >= before.systemNanoseconds else { return nil }
        return CPUTime(userNanoseconds: after.userNanoseconds - before.userNanoseconds,
                       systemNanoseconds: after.systemNanoseconds - before.systemNanoseconds)
    }

    /// Same for host tick counters.
    public static func delta(before: CPULoadTicks, after: CPULoadTicks) -> CPULoadTicks? {
        guard after.user >= before.user, after.system >= before.system,
              after.idle >= before.idle, after.nice >= before.nice else { return nil }
        return CPULoadTicks(user: after.user - before.user, system: after.system - before.system,
                            idle: after.idle - before.idle, nice: after.nice - before.nice)
    }

    /// Utilisation where 100 means one core busy for the whole interval, so a
    /// multi-threaded process reads above 100 (PRD §9 scenario 12). 0 if nothing elapsed.
    public static func percentOfOneCore(cpuNanoseconds: UInt64, elapsedNanoseconds: UInt64) -> Double {
        guard elapsedNanoseconds > 0 else { return 0 }
        return Double(cpuNanoseconds) / Double(elapsedNanoseconds) * 100
    }

    /// Share of the whole machine, 0...100 across `coreCount` cores.
    public static func percentOfMachine(cpuNanoseconds: UInt64, elapsedNanoseconds: UInt64, coreCount: Int) -> Double {
        guard coreCount > 0 else { return 0 }
        return percentOfOneCore(cpuNanoseconds: cpuNanoseconds, elapsedNanoseconds: elapsedNanoseconds) / Double(coreCount)
    }
}
