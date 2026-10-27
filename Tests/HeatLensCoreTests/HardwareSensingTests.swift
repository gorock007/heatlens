import Foundation
import IOKit.ps
import Testing
@testable import HeatLensCore

/// An in-memory SMC: keys in index order, each with a type and raw bytes.
private final class FakeSMC: SMCReading, @unchecked Sendable {
    var values: [(key: String, value: SMCValue)]
    private(set) var readCount = 0

    init(_ values: [(String, SMCValue)]) {
        self.values = values.map { (key: $0.0, value: $0.1) }
    }

    func keyCount() -> UInt32? { UInt32(values.count) }
    func key(at index: UInt32) -> String? { Int(index) < values.count ? values[Int(index)].key : nil }
    func info(_ key: String) -> SMCKeyInfo? {
        values.first { $0.key == key }.map { SMCKeyInfo(size: UInt32($0.value.bytes.count), type: $0.value.type) }
    }
    func read(_ key: String) -> SMCValue? {
        readCount += 1
        return values.first { $0.key == key }?.value
    }

    static func float(_ value: Float) -> SMCValue {
        let bits = value.bitPattern
        return SMCValue(type: "flt ", bytes: [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 24)])
    }
}

@Suite("Hardware sensors")
struct HardwareSensingTests {
    @Test("SMCKeyData has the 80-byte C layout the AppleSMC user client expects")
    func keyDataLayout() {
        #expect(MemoryLayout<SMCKeyData>.size == 80)
        #expect(MemoryLayout<SMCKeyData>.offset(of: \.keyInfo) == 28)
        #expect(MemoryLayout<SMCKeyData>.offset(of: \.result) == 40)
        #expect(MemoryLayout<SMCKeyData>.offset(of: \.command) == 42)
        #expect(MemoryLayout<SMCKeyData>.offset(of: \.data32) == 44)
        #expect(MemoryLayout<SMCKeyData>.offset(of: \.bytes) == 48)
    }

    @Test("Only read commands exist")
    func readOnlyCommands() {
        #expect(SMCKeyData.Command(rawValue: 6) == nil)
        #expect(Set([SMCKeyData.Command.readBytes, .keyAtIndex, .keyInfo].map(\.rawValue)) == [5, 8, 9])
    }

    @Test("Decodes flt (little-endian), integer and fixed-point SMC types; rejects bad sizes and non-finite values")
    func decoding() {
        #expect(SMCDecoding.number(FakeSMC.float(66.5)) == 66.5)
        #expect(SMCDecoding.number(SMCValue(type: "ui8 ", bytes: [2])) == 2)
        #expect(SMCDecoding.number(SMCValue(type: "ui16", bytes: [0x01, 0x02])) == 258)
        #expect(SMCDecoding.number(SMCValue(type: "ui32", bytes: [0, 0, 0x09, 0x76])) == 2422)
        #expect(SMCDecoding.number(SMCValue(type: "fpe2", bytes: [0x1f, 0x40])) == 2000)
        #expect(SMCDecoding.number(SMCValue(type: "sp78", bytes: [0xff, 0x00])) == -1)
        #expect(SMCDecoding.number(SMCValue(type: "sp78", bytes: [0x2a, 0x80])) == 42.5)
        #expect(SMCDecoding.number(SMCValue(type: "flt ", bytes: [0, 0, 0])) == nil)
        #expect(SMCDecoding.number(FakeSMC.float(.nan)) == nil)
        #expect(SMCDecoding.number(FakeSMC.float(.infinity)) == nil)
        #expect(SMCDecoding.number(SMCValue(type: "hex_", bytes: [1])) == nil)
        #expect(SMCDecoding.fourCC("#KEY") == 0x234B_4559)
        #expect(SMCDecoding.fourCC("TOOLONG") == nil)
        #expect(SMCDecoding.string(fourCC: 0x666C_7420) == "flt ")
    }

    @Test("Fan keys are F, a digit, Ac")
    func fanKeys() {
        #expect(SMCKeyCatalog.fanIndex("F0Ac") == 0)
        #expect(SMCKeyCatalog.fanIndex("F1Ac") == 1)
        #expect(SMCKeyCatalog.fanIndex("FNum") == nil)
        #expect(SMCKeyCatalog.fanIndex("F0Mx") == nil)
        #expect(SMCKeyCatalog.fanIndex("FaAc") == nil)
        #expect(SMCKeyCatalog.fanIndex("F0Acc") == nil)
        #expect(SMCKeyCatalog.fanMaxKey(1) == "F1Mx")
    }

    @Test("Temperature summary uses macmon's filter (0 < t ≤ 150 °C) and reports average, hottest and count")
    func summary() throws {
        #expect(TemperatureSummary.summarize([]) == nil)
        #expect(TemperatureSummary.summarize([0, -3.1, 151, .nan]) == nil)
        let summary = try #require(TemperatureSummary.summarize([0, 40, .nan, 60, 150, 200]))
        #expect(summary.sensorCount == 3)
        #expect(abs(summary.averageCelsius - 250.0 / 3) < 1e-9)
        #expect(summary.hottestCelsius == 150)
    }

    @Test("Discovery keeps float CPU/GPU temperature keys and fan keys, skips the rest")
    func discovery() {
        let smc = FakeSMC([
            ("#KEY", SMCValue(type: "ui32", bytes: [0, 0, 0, 9])),
            ("Tp01", FakeSMC.float(60)), ("Te05", FakeSMC.float(55)), ("Ts0P", FakeSMC.float(40)),
            ("Tp02", SMCValue(type: "ui8 ", bytes: [50])),  // not a float: skipped
            ("Tg0A", FakeSMC.float(50)),
            ("F1Ac", FakeSMC.float(2500)), ("F0Ac", FakeSMC.float(2300)),
            ("TB0T", FakeSMC.float(34)),  // battery: not CPU or GPU
        ])
        let catalog = SMCKeyCatalog.discover(smc)
        #expect(catalog.cpuTemperatureKeys == ["Tp01", "Te05", "Ts0P"])
        #expect(catalog.gpuTemperatureKeys == ["Tg0A"])
        #expect(catalog.fanKeys == ["F0Ac", "F1Ac"])
    }

    @Test("A sample from the SMC has temperatures, fans with max, system power; CPU/GPU power stays unavailable")
    func sampleFromSMC() throws {
        let smc = FakeSMC([
            ("Tp01", FakeSMC.float(70)), ("Te05", FakeSMC.float(60)), ("Tg0A", FakeSMC.float(55)),
            ("F0Ac", FakeSMC.float(2314)), ("F0Mx", FakeSMC.float(6800)), ("F1Ac", FakeSMC.float(2516)),
            ("PSTR", FakeSMC.float(18.5)),
        ])
        let provider = SMCSensorProvider(open: { smc })
        let sample = provider.sample()
        let cpu = try #require(sample.cpuTemperature.value)
        #expect(cpu.averageCelsius == 65 && cpu.hottestCelsius == 70 && cpu.sensorCount == 2)
        #expect(sample.cpuTemperature.source == .smc && sample.cpuTemperature.source.isPrivateInterface)
        #expect(sample.gpuTemperature.value?.averageCelsius == 55)
        #expect(sample.fans.value == [FanReading(index: 0, rpm: 2314, maxRPM: 6800), FanReading(index: 1, rpm: 2516, maxRPM: nil)])
        #expect(sample.systemPowerWatts.value == 18.5)
        #expect(sample.cpuPowerWatts.value == nil && sample.gpuPowerWatts.value == nil)
        #expect(sample.cpuPowerWatts.availability == .unsupported(reason: "needs per-macOS power tables"))
    }

    @Test("Discovery runs once per connection; later samples read only the known keys")
    func discoveryOnce() {
        let smc = FakeSMC([("Tp01", FakeSMC.float(70)), ("PSTR", FakeSMC.float(10))])
        let provider = SMCSensorProvider(open: { smc })
        _ = provider.sample()
        let afterFirst = smc.readCount
        _ = provider.sample()
        // Second sample: one CPU key and PSTR, nothing else.
        #expect(smc.readCount - afterFirst == 2)
    }

    @Test("No SMC means unavailable readings, never zero")
    func noSMC() {
        let sample = SMCSensorProvider(open: { nil }).sample()
        for availability in [sample.cpuTemperature.availability, sample.gpuTemperature.availability,
                             sample.fans.availability, sample.systemPowerWatts.availability] {
            #expect(availability == .unsupported(reason: "AppleSMC not available"))
        }
        #expect(sample.cpuTemperature.value == nil && sample.fans.value == nil && sample.systemPowerWatts.value == nil)
    }

    @Test("Hardware sensors off: private readings are disabled, public context is still read")
    func disabled() {
        let sample = DisabledHardwareProvider().sample()
        #expect(sample.cpuTemperature.availability == .disabled)
        #expect(sample.systemPowerWatts.availability == .disabled)
        #expect(sample.cpuTemperature.value == nil)
        #expect(sample.thermalState != .unavailable)
    }

    @Test("A Mac with no fan keys reports an empty, available fan list; unreadable fan keys are a failure")
    func fanless() {
        let fanless = SMCSensorProvider(open: { FakeSMC([("Tp01", FakeSMC.float(50))]) }).sample()
        #expect(fanless.fans.availability == .available && fanless.fans.value == [])
        let broken = SMCSensorProvider(open: { FakeSMC([("F0Ac", SMCValue(type: "hex_", bytes: [0]))]) }).sample()
        #expect(broken.fans.availability == .failed(reason: "fan keys present but unreadable"))
        #expect(broken.cpuTemperature.availability == .unsupported(reason: "no CPU temperature keys on this Mac"))
        #expect(broken.systemPowerWatts.availability == .unsupported(reason: "no PSTR key"))
    }

    @Test("Implausible temperature values are a failure, not a number")
    func implausible() {
        let sample = SMCSensorProvider(open: { FakeSMC([("Tp01", FakeSMC.float(-3)), ("Tg01", FakeSMC.float(0))]) }).sample()
        #expect(sample.cpuTemperature.availability == .failed(reason: "no plausible CPU temperature readings"))
        #expect(sample.gpuTemperature.value == nil)
    }

    @Test("SensorReading never carries a value when unavailable, and an available reading without a value is a failure")
    func readingInvariant() {
        let hidden = SensorReading<Double>(value: 5, availability: .disabled, source: .smc)
        #expect(hidden.value == nil)
        let empty = SensorReading<Double>(value: nil, availability: .available, source: .smc)
        #expect(empty.availability == .failed(reason: "no value"))
    }

    @Test("Power context: internal battery on AC and charging; a desktop has no battery")
    func powerContext() {
        let laptop = PowerContextReader.parse([[
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSCurrentCapacityKey: 85, kIOPSMaxCapacityKey: 100, kIOPSIsChargingKey: true,
        ]], providing: kIOPSACPowerValue, lowPowerMode: false)
        #expect(laptop == PowerContext(source: .ac, hasBattery: true, batteryPercent: 85, isCharging: true, lowPowerMode: false))
        let onBattery = PowerContextReader.parse([[
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 40, kIOPSMaxCapacityKey: 80,
        ]], providing: kIOPSBatteryPowerValue, lowPowerMode: true)
        #expect(onBattery.source == .battery && onBattery.batteryPercent == 50 && onBattery.lowPowerMode)
        let desktop = PowerContextReader.parse([], providing: kIOPSACPowerValue, lowPowerMode: false)
        #expect(desktop == PowerContext(source: .ac, hasBattery: false, batteryPercent: nil, isCharging: nil, lowPowerMode: false))
    }

    @Test("HardwareSample round-trips through JSON, including unavailable readings")
    func codable() throws {
        let sample = SMCSensorProvider(open: { FakeSMC([("Tp01", FakeSMC.float(70)), ("F0Ac", FakeSMC.float(2000))]) }).sample()
        let data = try JSONEncoder().encode(sample)
        #expect(try JSONDecoder().decode(HardwareSample.self, from: data) == sample)
    }

    @Test("This Mac: the SMC reads plausible CPU and GPU temperatures", .enabled(if: IOKitSMCConnection() != nil))
    func liveSMC() throws {
        let provider = SMCSensorProvider()
        let sample = provider.sample()
        let cpu = try #require(sample.cpuTemperature.value, "\(sample.cpuTemperature.availability)")
        #expect(cpu.sensorCount > 0 && (10...150).contains(cpu.averageCelsius) && cpu.hottestCelsius >= cpu.averageCelsius)
        if let gpu = sample.gpuTemperature.value {
            #expect((10...150).contains(gpu.averageCelsius))
        }
        #expect(sample.fans.availability == .available)
        #expect(sample.chip?.isEmpty == false)
        provider.close()
    }
}
