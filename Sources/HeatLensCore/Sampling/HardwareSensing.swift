import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Reads hardware sensors and power context at one instant. Every reading carries its own
/// availability; a provider never throws and never reports a missing value as zero.
public protocol HardwareSensorProviding: Sendable {
    func sample() -> HardwareSample
}

/// Used when the user hasn't turned hardware sensors on: private readings are `.disabled`,
/// public context (thermal state, power source) is still read.
public struct DisabledHardwareProvider: HardwareSensorProviding {
    public init() {}

    public func sample() -> HardwareSample {
        HardwareSampleAssembly.sample(smc: nil, smcAvailability: .disabled)
    }
}

/// The native SMC reader (docs/v2/ADR-0001). Opens the `AppleSMC` user client on first use,
/// discovers the temperature and fan keys once, then reads only those. Read commands only.
public final class SMCSensorProvider: HardwareSensorProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let open: @Sendable () -> (any SMCReading)?
    private var connection: (any SMCReading)?
    private var catalog: SMCKeyCatalog?
    private var openFailed = false

    public convenience init() {
        self.init(open: { IOKitSMCConnection() })
    }

    /// Tests pass a fake SMC.
    init(open: @escaping @Sendable () -> (any SMCReading)?) {
        self.open = open
    }

    public func sample() -> HardwareSample {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil, !openFailed {
            connection = open()
            openFailed = connection == nil
        }
        guard let connection else {
            return HardwareSampleAssembly.sample(smc: nil, smcAvailability: .unsupported(reason: "AppleSMC not available"))
        }
        if catalog == nil {
            catalog = SMCKeyCatalog.discover(connection)
        }
        return HardwareSampleAssembly.sample(smc: (connection, catalog!), smcAvailability: .available)
    }

    /// Drops the SMC connection; the next sample reopens it.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        connection = nil
        catalog = nil
        openFailed = false
    }
}

// MARK: - Assembly (pure apart from the public context reads)

enum HardwareSampleAssembly {
    static let powerUnavailable = SensorAvailability.unsupported(reason: "needs per-macOS power tables")

    static func sample(smc: (any SMCReading, SMCKeyCatalog)?, smcAvailability: SensorAvailability,
                       now: Date = Date(), power: PowerContext? = PowerContextReader.read(),
                       thermalState: ThermalState = HostSystemSampler.thermalState(ProcessInfo.processInfo.thermalState),
                       chip: String? = HardwareIdentity.chip, model: String? = HardwareIdentity.model) -> HardwareSample {
        let cpuTemperature: SensorReading<TemperatureSummary>
        let gpuTemperature: SensorReading<TemperatureSummary>
        let fans: SensorReading<[FanReading]>
        let systemPower: SensorReading<Double>
        if let (connection, catalog) = smc {
            cpuTemperature = temperatures(catalog.cpuTemperatureKeys, connection, family: "CPU")
            gpuTemperature = temperatures(catalog.gpuTemperatureKeys, connection, family: "GPU")
            fans = fanReadings(catalog.fanKeys, connection)
            systemPower = connection.number(SMCKeyCatalog.systemPowerKey).map { .available($0, from: .smc) }
                ?? .unavailable(.unsupported(reason: "no \(SMCKeyCatalog.systemPowerKey) key"), source: .smc)
        } else {
            cpuTemperature = .unavailable(smcAvailability, source: .smc)
            gpuTemperature = .unavailable(smcAvailability, source: .smc)
            fans = .unavailable(smcAvailability, source: .smc)
            systemPower = .unavailable(smcAvailability, source: .smc)
        }
        return HardwareSample(timestamp: now, chip: chip, model: model,
                              cpuTemperature: cpuTemperature, gpuTemperature: gpuTemperature, fans: fans,
                              systemPowerWatts: systemPower,
                              cpuPowerWatts: .unavailable(powerUnavailable, source: .none),
                              gpuPowerWatts: .unavailable(powerUnavailable, source: .none),
                              thermalState: thermalState, power: power)
    }

    static func temperatures(_ keys: [String], _ connection: any SMCReading, family: String) -> SensorReading<TemperatureSummary> {
        guard !keys.isEmpty else {
            return .unavailable(.unsupported(reason: "no \(family) temperature keys on this Mac"), source: .smc)
        }
        guard let summary = TemperatureSummary.summarize(keys.compactMap { connection.number($0) }) else {
            return .unavailable(.failed(reason: "no plausible \(family) temperature readings"), source: .smc)
        }
        return .available(summary, from: .smc)
    }

    static func fanReadings(_ keys: [String], _ connection: any SMCReading) -> SensorReading<[FanReading]> {
        var fans: [FanReading] = []
        for key in keys {
            guard let index = SMCKeyCatalog.fanIndex(key), let rpm = connection.number(key), SMCKeyCatalog.isPlausibleRPM(rpm) else {
                continue
            }
            let max = connection.number(SMCKeyCatalog.fanMaxKey(index)).flatMap { SMCKeyCatalog.isPlausibleRPM($0) && $0 > 0 ? $0 : nil }
            fans.append(FanReading(index: index, rpm: rpm, maxRPM: max))
        }
        if fans.isEmpty, !keys.isEmpty {
            return .unavailable(.failed(reason: "fan keys present but unreadable"), source: .smc)
        }
        // No fan keys at all: a fanless Mac. Available, with an empty list.
        return .available(fans, from: .smc)
    }
}

extension TemperatureSummary {
    /// macmon's filter (0 < t ≤ 150 °C), so the two agree; nil when nothing is plausible.
    static func summarize(_ values: [Double]) -> TemperatureSummary? {
        let valid = values.filter { $0 > 0 && $0 <= 150 }
        guard let hottest = valid.max() else { return nil }
        return TemperatureSummary(averageCelsius: valid.reduce(0, +) / Double(valid.count), hottestCelsius: hottest,
                                  sensorCount: valid.count)
    }
}

// MARK: - SMC keys

/// The SMC keys HeatLens reads, found once per connection. Key families follow macmon and
/// public SMC references: `Tp`/`Te`/`Ts` CPU, `Tg` GPU, `F<n>Ac` fans, `PSTR` system power.
/// Their meanings are community-documented, not Apple's, so the UI says "SMC sensors".
struct SMCKeyCatalog: Hashable, Sendable {
    static let cpuTemperaturePrefixes = ["Tp", "Te", "Ts"]
    static let gpuTemperaturePrefixes = ["Tg"]
    static let systemPowerKey = "PSTR"
    /// SMC exposes a few thousand keys; anything far above that is a bad count.
    static let maxKeyCount: UInt32 = 20_000

    let cpuTemperatureKeys: [String]
    let gpuTemperatureKeys: [String]
    let fanKeys: [String]

    static func discover(_ connection: any SMCReading) -> SMCKeyCatalog {
        guard let count = connection.keyCount(), count > 0 else {
            return SMCKeyCatalog(cpuTemperatureKeys: [], gpuTemperatureKeys: [], fanKeys: [])
        }
        var cpu: [String] = [], gpu: [String] = [], fans: [String] = []
        for index in 0..<min(count, maxKeyCount) {
            guard let key = connection.key(at: index) else { continue }
            if fanIndex(key) != nil {
                fans.append(key)
                continue
            }
            let isCPU = cpuTemperaturePrefixes.contains { key.hasPrefix($0) }
            let isGPU = gpuTemperaturePrefixes.contains { key.hasPrefix($0) }
            // Only 4-byte floats are temperatures on Apple Silicon; skip anything else.
            guard isCPU || isGPU, connection.info(key)?.isFloat == true else { continue }
            if isCPU { cpu.append(key) } else { gpu.append(key) }
        }
        return SMCKeyCatalog(cpuTemperatureKeys: cpu, gpuTemperatureKeys: gpu, fanKeys: Array(Set(fans)).sorted())
    }

    /// `F0Ac` → 0. Four characters, `F`, a digit, `Ac`.
    static func fanIndex(_ key: String) -> Int? {
        let chars = Array(key)
        guard chars.count == 4, chars[0] == "F", chars[2] == "A", chars[3] == "c", let digit = chars[1].wholeNumberValue else {
            return nil
        }
        return digit
    }

    static func fanMaxKey(_ index: Int) -> String { "F\(index)Mx" }

    static func isPlausibleRPM(_ value: Double) -> Bool { value >= 0 && value <= 100_000 }
}

// MARK: - SMC protocol

struct SMCKeyInfo: Hashable, Sendable {
    let size: UInt32
    /// FourCC data type, e.g. "flt ", "ui16".
    let type: String

    var isFloat: Bool { type == "flt " && size == 4 }
}

struct SMCValue: Hashable, Sendable {
    let type: String
    let bytes: [UInt8]
}

/// The SMC operations HeatLens uses. All are reads.
protocol SMCReading: AnyObject {
    func keyCount() -> UInt32?
    func key(at index: UInt32) -> String?
    func info(_ key: String) -> SMCKeyInfo?
    func read(_ key: String) -> SMCValue?
}

extension SMCReading {
    func number(_ key: String) -> Double? {
        read(key).flatMap(SMCDecoding.number)
    }
}

enum SMCDecoding {
    /// Decodes the numeric SMC types. Apple Silicon reports floats little-endian; the integer
    /// and fixed-point types are big-endian, as on Intel Macs. Non-finite results are nil.
    static func number(_ value: SMCValue) -> Double? {
        let b = value.bytes
        let result: Double?
        switch value.type {
        case "flt " where b.count == 4:
            result = Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        case "ui8 " where b.count == 1:
            result = Double(b[0])
        case "ui16" where b.count == 2:
            result = Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32" where b.count == 4:
            result = Double(bigEndianUInt32(b))
        case "fpe2" where b.count == 2:
            result = Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "sp78" where b.count == 2:
            result = Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        default:
            result = nil
        }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    static func bigEndianUInt32(_ b: [UInt8]) -> UInt32 {
        b.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func fourCC(_ key: String) -> UInt32? {
        let bytes = Array(key.utf8)
        guard bytes.count == 4 else { return nil }
        return bigEndianUInt32(bytes)
    }

    static func string(fourCC value: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }, as: UTF8.self)
    }
}

/// `SMCKeyData` as the AppleSMC user client expects it: 80 bytes, C layout. Swift places a
/// field right after the previous one's *size*, so `KeyInfo` carries explicit padding to keep
/// `result` at offset 40 (a test pins the size and offsets).
struct SMCKeyData {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PowerLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0; var padding: (UInt8, UInt8, UInt8) = (0, 0, 0) }

    var key: UInt32 = 0
    var version = Version()
    var powerLimit = PowerLimit()
    var keyInfo = KeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

    /// The only commands HeatLens sends. Writing (6) is deliberately absent.
    enum Command: UInt8 {
        case readBytes = 5
        case keyAtIndex = 8
        case keyInfo = 9
    }

    static let selector: UInt32 = 2
    static let keyNotFound: UInt8 = 132
}

/// The live connection to `AppleSMCKeysEndpoint`. Not thread-safe; `SMCSensorProvider` locks.
final class IOKitSMCConnection: SMCReading {
    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyData.KeyInfo] = [:]

    init?() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var name = [CChar](repeating: 0, count: 128)
            guard connection == 0, IORegistryEntryGetName(service, &name) == KERN_SUCCESS,
                  HardwareIdentity.string(name) == "AppleSMCKeysEndpoint" else { continue }
            if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
        }
        if connection == 0 { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func keyCount() -> UInt32? {
        guard let value = read("#KEY"), value.bytes.count == 4 else { return nil }
        return SMCDecoding.bigEndianUInt32(value.bytes)
    }

    func key(at index: UInt32) -> String? {
        var input = SMCKeyData()
        input.command = SMCKeyData.Command.keyAtIndex.rawValue
        input.data32 = index
        return call(input).map { SMCDecoding.string(fourCC: $0.key) }
    }

    func info(_ key: String) -> SMCKeyInfo? {
        guard let code = SMCDecoding.fourCC(key), let info = keyInfo(code) else { return nil }
        return SMCKeyInfo(size: info.dataSize, type: SMCDecoding.string(fourCC: info.dataType))
    }

    func read(_ key: String) -> SMCValue? {
        guard let code = SMCDecoding.fourCC(key), let info = keyInfo(code), info.dataSize <= 32 else { return nil }
        var input = SMCKeyData()
        input.key = code
        input.keyInfo = info
        input.command = SMCKeyData.Command.readBytes.rawValue
        guard var output = call(input) else { return nil }
        let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return SMCValue(type: SMCDecoding.string(fourCC: info.dataType), bytes: bytes)
    }

    private func keyInfo(_ code: UInt32) -> SMCKeyData.KeyInfo? {
        if let cached = infoCache[code] { return cached }
        var input = SMCKeyData()
        input.key = code
        input.command = SMCKeyData.Command.keyInfo.rawValue
        guard let output = call(input) else { return nil }
        infoCache[code] = output.keyInfo
        return output.keyInfo
    }

    private func call(_ input: SMCKeyData) -> SMCKeyData? {
        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let status = IOConnectCallStructMethod(connection, SMCKeyData.selector, &input, MemoryLayout<SMCKeyData>.stride,
                                               &output, &outputSize)
        guard status == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }
}

// MARK: - Public context

enum HardwareIdentity {
    static let chip = sysctlString("machdep.cpu.brand_string")
    static let model = sysctlString("hw.model")

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = string(buffer)
        return value.isEmpty ? nil : value
    }

    /// A NUL-terminated C buffer as a String.
    static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// AC or battery, charge and Low Power Mode, from public APIs.
enum PowerContextReader {
    static func read() -> PowerContext? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        let descriptions = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return parse(descriptions, providing: providing, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Pure, for tests. Uses the internal battery only; UPSes and accessories are ignored.
    static func parse(_ descriptions: [[String: Any]], providing: String?, lowPowerMode: Bool) -> PowerContext {
        let battery = descriptions.first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        let source: PowerSourceKind
        switch providing ?? battery?[kIOPSPowerSourceStateKey] as? String {
        case kIOPSACPowerValue: source = .ac
        case kIOPSBatteryPowerValue: source = .battery
        default: source = .unknown
        }
        var percent: Int?
        if let current = battery?[kIOPSCurrentCapacityKey] as? Int, let max = battery?[kIOPSMaxCapacityKey] as? Int, max > 0 {
            percent = Int((Double(current) / Double(max) * 100).rounded())
        }
        return PowerContext(source: source, hasBattery: battery != nil, batteryPercent: percent,
                            isCharging: battery?[kIOPSIsChargingKey] as? Bool, lowPowerMode: lowPowerMode)
    }
}
