import Foundation

/// The machine at one live tick, as the history keeps it (brief 2c). Rolled-up points are
/// one-minute aggregates: averages for load and power, maxima for heat, swap and pressure.
public struct HistoryPoint: Hashable, Sendable {
    public let timestamp: Date
    public let thermalState: ThermalState
    /// 0...1 of all cores (the minute's average when rolled up).
    public let hostBusyFraction: Double
    /// The minute's maximum when rolled up.
    public let hostBusyPeak: Double
    public let swapUsedBytes: UInt64
    public let memoryPressure: MemoryPressureLevel
    public let cpuTemperatureCelsius: Double?
    public let systemWatts: Double?
    /// CPU energy of the processes HeatLens can read.
    public let processWatts: Double?
    /// Ticks behind this point: 1 for a raw tick.
    public let sampleCount: Int

    public init(timestamp: Date, thermalState: ThermalState, hostBusyFraction: Double, hostBusyPeak: Double? = nil,
                swapUsedBytes: UInt64, memoryPressure: MemoryPressureLevel, cpuTemperatureCelsius: Double?,
                systemWatts: Double?, processWatts: Double?, sampleCount: Int = 1) {
        self.timestamp = timestamp
        self.thermalState = thermalState
        self.hostBusyFraction = hostBusyFraction
        self.hostBusyPeak = hostBusyPeak ?? hostBusyFraction
        self.swapUsedBytes = swapUsedBytes
        self.memoryPressure = memoryPressure
        self.cpuTemperatureCelsius = cpuTemperatureCelsius
        self.systemWatts = systemWatts
        self.processWatts = processWatts
        self.sampleCount = sampleCount
    }
}

/// One project's share at one tick (or one minute). Only names and folders are kept, never
/// command lines.
public struct HistoryProjectPoint: Hashable, Sendable {
    public let timestamp: Date
    /// `Project.id` (the lowercased root), "docker-vm" or "unattributed".
    public let projectID: String
    public let name: String
    public let cpuPercent: Double
    public let cpuPeakPercent: Double
    public let memoryBytes: UInt64
    public let watts: Double?

    public init(timestamp: Date, projectID: String, name: String, cpuPercent: Double, cpuPeakPercent: Double? = nil,
                memoryBytes: UInt64, watts: Double?) {
        self.timestamp = timestamp
        self.projectID = projectID
        self.name = name
        self.cpuPercent = cpuPercent
        self.cpuPeakPercent = cpuPeakPercent ?? cpuPercent
        self.memoryBytes = memoryBytes
        self.watts = watts
    }
}

/// Something notable on the timeline (briefs 2d, 2e). `isInference` marks HeatLens's
/// interpretation ("three expensive commands at once") as opposed to an observation.
public struct TimelineEvent: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case thermalChanged
        case containerStarted
        case containerStopped
        case testRunStarted
        case expensiveCommandStarted
        case concurrentCommands
        case repeatedCommand
        /// A concurrency burst explained in plain words (brief 3b); the full explanation lives on the tick.
        case concurrencyExplained
        /// A Live alert rule fired (brief 3c); the alert itself lives on the tick.
        case alertFired
    }

    public var id: String { "\(Int64(timestamp.timeIntervalSince1970 * 1000))-\(kind.rawValue)-\(title)" }
    public let timestamp: Date
    public let kind: Kind
    /// Short, made of process names, container names and project names only.
    public let title: String
    public let projectName: String?
    public let isInference: Bool

    public init(timestamp: Date, kind: Kind, title: String, projectName: String? = nil, isInference: Bool = false) {
        self.timestamp = timestamp
        self.kind = kind
        self.title = String(title.prefix(200))
        self.projectName = projectName.map { String($0.prefix(80)) }
        self.isInference = isInference
    }
}

/// What the timeline reads back.
public struct HistoryWindow: Hashable, Sendable {
    public let points: [HistoryPoint]
    public let projects: [HistoryProjectPoint]
    public let events: [TimelineEvent]

    public static let empty = HistoryWindow(points: [], projects: [], events: [])
}

extension ThermalState {
    /// For `MAX()` in rollups: higher is hotter; unavailable is lowest.
    var rank: Int {
        switch self {
        case .unavailable: -1
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }

    init(rank: Int) {
        switch rank {
        case 0: self = .nominal
        case 1: self = .fair
        case 2: self = .serious
        case 3: self = .critical
        default: self = .unavailable
        }
    }
}

extension MemoryPressureLevel {
    var rank: Int {
        switch self {
        case .unknown: -1
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    init(rank: Int) {
        switch rank {
        case 0: self = .normal
        case 1: self = .warning
        case 2: self = .critical
        default: self = .unknown
        }
    }
}
