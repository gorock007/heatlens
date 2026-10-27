import Foundation

/// Who owns a process, as far as HeatLens can tell. Determines which fields are readable
/// (docs/FEASIBILITY.md §2): only `currentUser` processes expose CPU, memory, cwd and argv.
public enum ProcessOwner: String, Hashable, Codable, Sendable {
    case currentUser, root, otherUser, unknown
}

/// Why detail fields (CPU, memory, cwd, argv) are missing, so the UI can say
/// "Not accessible" with a reason instead of showing zeros (FR-13, PRD §9.6).
public enum DetailAccess: String, Hashable, Codable, Sendable {
    case available
    /// EPERM from libproc: another user's or root's process.
    case permissionDenied
    /// The process exited between enumeration and sampling.
    case processExited
    /// The kernel's own task (pid 0) or a facility this build cannot use.
    case notSupported
}

/// Where a sample's `cpu` and `residentBytes` came from, so the UI can qualify ps-derived
/// numbers ("10 ms resolution") for processes libproc refuses.
public enum MeasurementSource: String, Hashable, Codable, Sendable {
    case libproc
    /// `/bin/ps -A -o pid=,time=,rss=`, run twice; CPU resolution 10 ms.
    case ps
}

/// One process as observed across a scan's sampling interval (PRD §4.1).
/// `cpu` is the *delta* over the interval, never cumulative time.
public struct ProcessSample: Identifiable, Hashable, Codable, Sendable {
    public var id: ProcessIdentity { identity }
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let owner: ProcessOwner
    /// Long process name (`pbi_name`, or `kinfo_proc.p_comm` for processes libproc refuses).
    public let name: String
    public let executablePath: String?
    /// argv[0...] when readable; nil means not accessible, [] means genuinely empty.
    public let arguments: [String]?
    public let currentDirectory: String?
    public let cpu: CPUTime?
    /// 100 = one full core (PRD FR-03); nil when `cpu` is nil.
    public let cpuPercentOfOneCore: Double?
    public let residentBytes: UInt64?
    public let footprintBytes: UInt64?
    public let threadCount: Int?
    public let detailAccess: DetailAccess
    /// nil when there are no CPU/RSS figures (or for samples built before this field existed).
    public let measurementSource: MeasurementSource?
    /// Average CPU power over the interval in watts, from the kernel's per-task energy counter
    /// (`proc_pid_rusage` v6, a public API). Own processes only: nil for root/other-user processes
    /// (ps has no energy), exited ones, and samples built before this field existed.
    public let cpuWatts: Double?
    /// The CPU energy behind `cpuWatts`, in nanojoules, all inside the interval. Totals add this up
    /// and divide by the whole interval: adding watts would overcount a process born mid-interval,
    /// whose watts are over its own shorter lifetime.
    public let cpuEnergyNanojoules: UInt64?

    public init(identity: ProcessIdentity, parentPID: Int32, owner: ProcessOwner, name: String,
                executablePath: String?, arguments: [String]?, currentDirectory: String?,
                cpu: CPUTime?, cpuPercentOfOneCore: Double?, residentBytes: UInt64?, footprintBytes: UInt64?,
                threadCount: Int?, detailAccess: DetailAccess, measurementSource: MeasurementSource? = nil,
                cpuWatts: Double? = nil, cpuEnergyNanojoules: UInt64? = nil) {
        self.identity = identity
        self.parentPID = parentPID
        self.owner = owner
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.cpu = cpu
        self.cpuPercentOfOneCore = cpuPercentOfOneCore
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
        self.threadCount = threadCount
        self.detailAccess = detailAccess
        self.measurementSource = measurementSource
        self.cpuWatts = cpuWatts
        self.cpuEnergyNanojoules = cpuEnergyNanojoules
    }

    public var pid: Int32 { identity.pid }
    /// PPID 1 is an orphan/detached *clue*, not proof of a leak (PRD §4.2).
    public var isAdoptedByLaunchd: Bool { parentPID == 1 }
}

public extension ScanSnapshot {
    /// Average CPU power of `identities` over the whole interval, in watts; nil when none of them
    /// has a reading, so a group of root processes says "unavailable" rather than 0 W.
    func cpuWatts(for identities: [ProcessIdentity]) -> Double? {
        let wanted = Set(identities)
        return averageWatts(processes.filter { wanted.contains($0.identity) })
    }

    /// The same for every process with a reading: the processes HeatLens can read (your own), not
    /// the whole CPU. nil when no process had one.
    var measuredCPUWatts: Double? { averageWatts(processes) }

    private func averageWatts(_ samples: [ProcessSample]) -> Double? {
        let energies = samples.compactMap(\.cpuEnergyNanojoules)
        guard !energies.isEmpty, interval > 0 else { return nil }
        return Double(energies.reduce(0, +)) / (interval * 1e9)
    }
}
