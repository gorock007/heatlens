import Foundation

/// Where a hardware reading came from, so the UI can tell a private sensor reading from the
/// OS's public thermal state (PRD-v2 §6 Phase 1, docs/v2/ADR-0001).
public enum SensorSource: String, Hashable, Codable, Sendable {
    /// The `AppleSMC` IOKit user client: a private, undocumented interface.
    case smc
    /// IOKit power-source API (`IOPSCopyPowerSourcesInfo`): public.
    case ioPowerSources
    /// `ProcessInfo` (thermal state, Low Power Mode): public.
    case processInfo
    /// No source can provide this reading in this build.
    case none

    public var isPrivateInterface: Bool { self == .smc }
}

/// Why a reading has no value. A missing value is never shown as zero (PRD-v2 §6 Phase 1).
public enum SensorAvailability: Hashable, Codable, Sendable {
    case available
    /// The user has not turned on hardware sensors in Settings.
    case disabled
    /// This Mac or macOS build has no such sensor, or HeatLens can't read it here.
    case unsupported(reason: String)
    /// Reading was attempted and failed.
    case failed(reason: String)

    public var isAvailable: Bool { self == .available }
}

/// One reading with its value, availability and source. `value` is nil unless `availability`
/// is `.available`.
public struct SensorReading<Value: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
    public let value: Value?
    public let availability: SensorAvailability
    public let source: SensorSource

    public init(value: Value?, availability: SensorAvailability, source: SensorSource) {
        self.value = availability.isAvailable ? value : nil
        self.availability = value == nil && availability.isAvailable
            ? .failed(reason: "no value")
            : availability
        self.source = source
    }

    public static func available(_ value: Value, from source: SensorSource) -> Self {
        Self(value: value, availability: .available, source: source)
    }

    public static func unavailable(_ availability: SensorAvailability, source: SensorSource) -> Self {
        Self(value: nil, availability: availability, source: source)
    }
}

/// A group of temperature sensors (e.g. every CPU sensor the SMC exposes), summarised. The
/// hottest value is the hottest sensor read, not a named die hotspot: key meanings are
/// community-documented, not Apple-documented.
public struct TemperatureSummary: Hashable, Codable, Sendable {
    public let averageCelsius: Double
    public let hottestCelsius: Double
    public let sensorCount: Int

    public init(averageCelsius: Double, hottestCelsius: Double, sensorCount: Int) {
        self.averageCelsius = averageCelsius
        self.hottestCelsius = hottestCelsius
        self.sensorCount = sensorCount
    }
}

public struct FanReading: Hashable, Codable, Sendable {
    /// SMC fan number (`F0Ac` is 0).
    public let index: Int
    public let rpm: Double
    public let maxRPM: Double?

    public init(index: Int, rpm: Double, maxRPM: Double?) {
        self.index = index
        self.rpm = rpm
        self.maxRPM = maxRPM
    }
}

public enum PowerSourceKind: String, Hashable, Codable, Sendable {
    case ac, battery, unknown
}

/// Public power context: what the Mac runs on, and whether macOS is saving power.
public struct PowerContext: Hashable, Codable, Sendable {
    public let source: PowerSourceKind
    public let hasBattery: Bool
    public let batteryPercent: Int?
    public let isCharging: Bool?
    public let lowPowerMode: Bool

    public init(source: PowerSourceKind, hasBattery: Bool, batteryPercent: Int?, isCharging: Bool?, lowPowerMode: Bool) {
        self.source = source
        self.hasBattery = hasBattery
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.lowPowerMode = lowPowerMode
    }
}

/// Hardware readings at one instant (PRD-v2 §7 `HardwareSample`).
public struct HardwareSample: Hashable, Codable, Sendable {
    public let timestamp: Date
    /// `machdep.cpu.brand_string`, e.g. "Apple M3 Pro".
    public let chip: String?
    /// `hw.model`, e.g. "Mac15,6".
    public let model: String?
    public let cpuTemperature: SensorReading<TemperatureSummary>
    public let gpuTemperature: SensorReading<TemperatureSummary>
    /// Empty but available on a Mac that reports no fans.
    public let fans: SensorReading<[FanReading]>
    /// Whole-system power from the SMC (`PSTR`).
    public let systemPowerWatts: SensorReading<Double>
    /// Unavailable in Phase 1: on macOS 27 these need per-firmware CLPC tables (ADR-0001).
    public let cpuPowerWatts: SensorReading<Double>
    public let gpuPowerWatts: SensorReading<Double>
    /// Public, always read.
    public let thermalState: ThermalState
    public let power: PowerContext?

    public init(timestamp: Date, chip: String?, model: String?,
                cpuTemperature: SensorReading<TemperatureSummary>, gpuTemperature: SensorReading<TemperatureSummary>,
                fans: SensorReading<[FanReading]>, systemPowerWatts: SensorReading<Double>,
                cpuPowerWatts: SensorReading<Double>, gpuPowerWatts: SensorReading<Double>,
                thermalState: ThermalState, power: PowerContext?) {
        self.timestamp = timestamp
        self.chip = chip
        self.model = model
        self.cpuTemperature = cpuTemperature
        self.gpuTemperature = gpuTemperature
        self.fans = fans
        self.systemPowerWatts = systemPowerWatts
        self.cpuPowerWatts = cpuPowerWatts
        self.gpuPowerWatts = gpuPowerWatts
        self.thermalState = thermalState
        self.power = power
    }
}
