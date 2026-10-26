import Darwin
import Foundation

/// One process as read at one instant. CPU here is *cumulative*; the coordinator turns two
/// readings into a `ProcessSample` delta.
public struct ProcessReading: Hashable, Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let owner: ProcessOwner
    public let name: String
    public let executablePath: String?
    public let arguments: [String]?
    public let currentDirectory: String?
    /// Cumulative CPU since the process started; nil when libproc refused it.
    public let cpu: CPUTime?
    public let residentBytes: UInt64?
    public let footprintBytes: UInt64?
    public let threadCount: Int?
    /// `.available` when CPU and memory were readable, `.permissionDenied` for root/other-user
    /// processes (the ps fallback fills those), `.notSupported` for pid 0.
    public let detailAccess: DetailAccess

    public init(identity: ProcessIdentity, parentPID: Int32, owner: ProcessOwner, name: String,
                executablePath: String? = nil, arguments: [String]? = nil, currentDirectory: String? = nil,
                cpu: CPUTime?, residentBytes: UInt64? = nil, footprintBytes: UInt64? = nil, threadCount: Int? = nil,
                detailAccess: DetailAccess) {
        self.identity = identity
        self.parentPID = parentPID
        self.owner = owner
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.cpu = cpu
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
        self.threadCount = threadCount
        self.detailAccess = detailAccess
    }
}

/// A point-in-time read of every process.
public struct ProcessCounters: Sendable {
    /// `CLOCK_UPTIME_RAW` (Mach absolute time in ns) when the read began; deltas between two
    /// counters are the interval CPU is divided by.
    public let monotonicNanoseconds: UInt64
    /// Wall clock at the same instant, compared with process start times to spot births.
    public let wallClock: Date
    public let processes: [ProcessReading]

    public init(monotonicNanoseconds: UInt64, wallClock: Date, processes: [ProcessReading]) {
        self.monotonicNanoseconds = monotonicNanoseconds
        self.wallClock = wallClock
        self.processes = processes
    }

    /// Monotonic time in nanoseconds, the clock every counter uses.
    public static func monotonicNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

public protocol ProcessSampling: Sendable {
    /// One point-in-time read.
    func snapshot() throws -> ProcessCounters
}

/// Reads every process with libproc, falling back to `sysctl KERN_PROC_ALL` for the identity,
/// parent and owner of processes libproc refuses (docs/FEASIBILITY.md "Chosen API per field").
/// Sequential: ~700 pids take a few milliseconds, so there is no per-pid concurrency.
public struct LibprocProcessSampler: ProcessSampling {
    let timebase: MachTimebase
    let currentUID: uid_t

    public init() {
        self.timebase = .current()
        self.currentUID = getuid()
    }

    public func snapshot() throws -> ProcessCounters {
        let started = ProcessCounters.monotonicNow()
        let wall = Date()
        let kinfo = Libproc.kinfoAll()
        var pids = Libproc.listAllPIDs()
        if pids.isEmpty { pids = kinfo.keys.sorted() }

        var readings: [ProcessReading] = []
        readings.reserveCapacity(pids.count)
        for pid in pids {
            if let reading = read(pid, kinfo: kinfo[pid]) { readings.append(reading) }
        }
        return ProcessCounters(monotonicNanoseconds: started, wallClock: wall, processes: readings)
    }

    /// The identity of a live process, or nil when it is gone. For re-checking a PID before
    /// acting on it (FR-09) and for tests.
    public static func identity(of pid: Int32) -> ProcessIdentity? {
        if case .success(let info) = Libproc.bsdInfo(pid) { return info.identity(pid: pid) }
        return Libproc.kinfoAll()[pid]?.identity(pid: pid)
    }

    private func owner(_ uid: uid_t) -> ProcessOwner {
        uid == currentUID ? .currentUser : (uid == 0 ? .root : .otherUser)
    }

    /// nil when the process exited before it could be read.
    private func read(_ pid: pid_t, kinfo: Libproc.KInfo?) -> ProcessReading? {
        let path = try? Libproc.pidPath(pid).get()
        switch Libproc.bsdInfo(pid) {
        case .success(let bsd):
            let task = try? Libproc.taskInfo(pid).get()
            let rusage = try? Libproc.rusageV4(pid).get()
            let cpu = task.map { CPUTime(userTicks: $0.userTicks, systemTicks: $0.systemTicks, timebase: timebase) }
                ?? rusage.map { CPUTime(userTicks: $0.userTicks, systemTicks: $0.systemTicks, timebase: timebase) }
            return ProcessReading(identity: bsd.identity(pid: pid), parentPID: bsd.ppid, owner: owner(bsd.uid), name: bsd.name,
                                  executablePath: path,
                                  arguments: (try? Libproc.processArguments(pid).get())?.arguments,
                                  currentDirectory: try? Libproc.currentDirectory(pid).get(),
                                  cpu: cpu, residentBytes: task?.residentSize, footprintBytes: rusage?.physFootprint,
                                  threadCount: task.map { Int($0.threads) },
                                  detailAccess: cpu == nil ? .permissionDenied : .available)
        case .failure(let failure):
            guard failure.code != ESRCH, let kinfo else { return nil }
            return ProcessReading(identity: kinfo.identity(pid: pid), parentPID: kinfo.ppid, owner: owner(kinfo.uid),
                                  name: Self.displayName(comm: kinfo.comm, path: path), executablePath: path,
                                  cpu: nil, detailAccess: pid == 0 ? .notSupported : .permissionDenied)
        }
    }

    /// `p_comm` is cut at 16 bytes; the executable's file name is the full name when it extends it.
    static func displayName(comm: String, path: String?) -> String {
        guard let base = path.map({ ($0 as NSString).lastPathComponent }), !base.isEmpty,
              base.hasPrefix(comm), base.count > comm.count else { return comm }
        return base
    }
}
