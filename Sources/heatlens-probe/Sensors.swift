import Foundation
import HeatLensCore

/// `--sensors`: the Phase 0 sensor demo (docs/v2/ADR-0001). Reads the SMC provider once a
/// second and prints each reading with its source and availability. Compare with
/// `macmon pipe -i 1000` run at the same time.
func printSensors(samples: Int) {
    let provider = SMCSensorProvider()
    for index in 0..<samples {
        if index > 0 { Thread.sleep(forTimeInterval: 1) }
        let started = ContinuousClock.now
        let sample = provider.sample()
        let elapsed = started.duration(to: .now)
        if index == 0 {
            print("\(sample.chip ?? "unknown chip") · \(sample.model ?? "unknown model") · source: SMC (private interface), read-only")
        }
        let time = ISO8601DateFormatter().string(from: sample.timestamp)
        print("\(time) · read \(String(format: "%.1f", Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)) ms")
        print("  CPU temperature  \(temperature(sample.cpuTemperature))")
        print("  GPU temperature  \(temperature(sample.gpuTemperature))")
        print("  fans             \(fans(sample.fans))")
        print("  system power     \(watts(sample.systemPowerWatts))")
        print("  CPU power        \(watts(sample.cpuPowerWatts))")
        print("  GPU power        \(watts(sample.gpuPowerWatts))")
        print("  thermal state    \(sample.thermalState.rawValue) (ProcessInfo, public)")
        print("  power            \(power(sample.power))")
    }
    provider.close()
}

private func unavailable(_ availability: SensorAvailability) -> String {
    switch availability {
    case .available: "available"
    case .disabled: "unavailable: turned off"
    case .unsupported(let reason): "unavailable: \(reason)"
    case .failed(let reason): "unavailable: \(reason)"
    }
}

private func temperature(_ reading: SensorReading<TemperatureSummary>) -> String {
    guard let value = reading.value else { return unavailable(reading.availability) }
    return String(format: "avg %.1f °C · hottest %.1f °C · %d sensors", value.averageCelsius, value.hottestCelsius, value.sensorCount)
}

private func fans(_ reading: SensorReading<[FanReading]>) -> String {
    guard let value = reading.value else { return unavailable(reading.availability) }
    if value.isEmpty { return "no fans reported" }
    return value.map { fan in
        "fan \(fan.index) \(Int(fan.rpm)) RPM" + (fan.maxRPM.map { " (max \(Int($0)))" } ?? "")
    }.joined(separator: " · ")
}

private func watts(_ reading: SensorReading<Double>) -> String {
    reading.value.map { String(format: "%.2f W", $0) } ?? unavailable(reading.availability)
}

private func power(_ context: PowerContext?) -> String {
    guard let context else { return "unavailable" }
    var parts = [context.source.rawValue.uppercased() == "AC" ? "AC power" : context.source.rawValue]
    if context.hasBattery {
        parts.append(context.batteryPercent.map { "battery \($0)%" } ?? "battery")
        if let charging = context.isCharging { parts.append(charging ? "charging" : "not charging") }
    }
    if context.lowPowerMode { parts.append("Low Power Mode") }
    return parts.joined(separator: " · ") + " (IOPowerSources, public)"
}
