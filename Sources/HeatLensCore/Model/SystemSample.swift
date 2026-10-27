import Foundation

/// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
public enum MemoryPressureLevel: String, Hashable, Codable, Sendable {
    case normal, warning, critical, unknown

    public init(sysctlLevel: Int32) {
        switch sysctlLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }
}

/// `ProcessInfo.thermalState`, plus `unavailable` for when it cannot be read (FR-08).
public enum ThermalState: String, Hashable, Codable, Sendable {
    case nominal, fair, serious, critical, unavailable
}

public struct MemorySnapshot: Hashable, Codable, Sendable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    /// Growth across the sampling interval; the usable "swapping right now" signal.
    public let swapOutsDelta: UInt64
    public let pressure: MemoryPressureLevel
    /// `kern.memorystatus_level`, percent of memory the kernel considers available.
    public let availablePercent: Int?

    public init(totalBytes: UInt64, freeBytes: UInt64, activeBytes: UInt64, inactiveBytes: UInt64, wiredBytes: UInt64,
                compressedBytes: UInt64, swapUsedBytes: UInt64, swapTotalBytes: UInt64, swapOutsDelta: UInt64,
                pressure: MemoryPressureLevel, availablePercent: Int?) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapOutsDelta = swapOutsDelta
        self.pressure = pressure
        self.availablePercent = availablePercent
    }
}

/// Whole-machine readings for one scan.
public struct SystemSample: Hashable, Codable, Sendable {
    public let coreCount: Int
    /// 0...1 across all cores, from `host_processor_info` deltas.
    public let hostBusyFraction: Double
    public let perCoreBusyFraction: [Double]
    public let memory: MemorySnapshot
    public let thermalState: ThermalState
    /// From `pmset -g therm`, only when it reported them (nil on this M3 Pro at idle).
    public let pmsetCPUSpeedLimit: Int?
    public let pmsetCPUSchedulerLimit: Int?

    public init(coreCount: Int, hostBusyFraction: Double, perCoreBusyFraction: [Double], memory: MemorySnapshot,
                thermalState: ThermalState, pmsetCPUSpeedLimit: Int?, pmsetCPUSchedulerLimit: Int?) {
        self.coreCount = coreCount
        self.hostBusyFraction = hostBusyFraction
        self.perCoreBusyFraction = perCoreBusyFraction
        self.memory = memory
        self.thermalState = thermalState
        self.pmsetCPUSpeedLimit = pmsetCPUSpeedLimit
        self.pmsetCPUSchedulerLimit = pmsetCPUSchedulerLimit
    }

    /// Busy cores equivalent (e.g. 3.2 of 11).
    public var busyCores: Double { hostBusyFraction * Double(coreCount) }
}

/// Everything one scan observed. Findings are derived from this, never from live state.
public struct ScanSnapshot: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let interval: TimeInterval
    public let system: SystemSample
    public let processes: [ProcessSample]
    /// Data-quality notices for the overview ("CPU for root processes unavailable", …).
    public let notices: [String]
    /// TCP ports in LISTEN state, read once at the end of the scan; only processes with at least
    /// one port appear. Empty for snapshots (and JSON) from before ports were sampled.
    public let listeningPorts: [ProcessListeningPorts]

    public init(id: UUID = UUID(), startedAt: Date, interval: TimeInterval, system: SystemSample,
                processes: [ProcessSample], notices: [String], listeningPorts: [ProcessListeningPorts] = []) {
        self.id = id
        self.startedAt = startedAt
        self.interval = interval
        self.system = system
        self.processes = processes
        self.notices = notices
        self.listeningPorts = listeningPorts
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, interval, system, processes, notices, listeningPorts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), startedAt: try c.decode(Date.self, forKey: .startedAt),
                  interval: try c.decode(TimeInterval.self, forKey: .interval), system: try c.decode(SystemSample.self, forKey: .system),
                  processes: try c.decode([ProcessSample].self, forKey: .processes), notices: try c.decode([String].self, forKey: .notices),
                  listeningPorts: try c.decodeIfPresent([ProcessListeningPorts].self, forKey: .listeningPorts) ?? [])
    }
}
