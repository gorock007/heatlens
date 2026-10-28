import Foundation
import HeatLensCore

/// `--live <seconds>`: a live session with the SMC provider and Docker on, as the app would run
/// it, printing each tick's own cost. For docs/PERFORMANCE.md: wrap it in `/usr/bin/time -l`.
func runLive(seconds: TimeInterval, interval: TimeInterval) async {
    let monitor = LiveMonitor()
    let configuration = LiveConfiguration(interval: interval, hardware: SMCSensorProvider(), docker: DockerEngineSampler(),
                                          autoPauseAfter: seconds, projectLocator: ProjectRootLocator())
    var costs: [TimeInterval] = []
    for await event in await monitor.start(configuration) {
        switch event {
        case .tick(let tick):
            costs.append(tick.collectionSeconds)
            let temperature = tick.hardware.cpuTemperature.value.map { String(format: "%.1f °C", $0.averageCelsius) } ?? "—"
            let energy = tick.snapshot.measuredCPUWatts.map { String(format: "%.2f W", $0) } ?? "—"
            let system = tick.hardware.systemPowerWatts.value.map { String(format: "%.1f W", $0) } ?? "—"
            print(String(format: "tick %3d · %4d processes · %3d groups · host %4.1f%% · CPU %@ · energy %@ · system %@ · %d containers · cost %.1f ms",
                         tick.sequence, tick.snapshot.processes.count, tick.groups.count, tick.snapshot.system.hostBusyFraction * 100,
                         temperature, energy, system, tick.docker.containers.count, tick.collectionSeconds * 1000))
            // Project names are folder names; the probe never prints their paths.
            let projects = tick.projects.usages.prefix(6).map { usage in
                String(format: "%@ %.0f%%%@", usage.name, usage.totalCPUPercent,
                       usage.containers.isEmpty ? "" : " (\(usage.containers.count) containers)")
            }
            print("  projects: " + projects.joined(separator: " · "))
            for event in tick.events {
                print("  event: \(event.kind.rawValue) · \(event.title)\(event.isInference ? " (inference)" : "")")
            }
        case .autoPaused:
            print("auto-paused after \(Int(seconds)) s")
        case .failed(let message):
            print("failed: \(message)")
        }
    }
    let sorted = costs.sorted()
    if !sorted.isEmpty {
        print(String(format: "ticks %d · median cost %.1f ms · max %.1f ms", sorted.count, sorted[sorted.count / 2] * 1000, sorted.last! * 1000))
    }
}

/// What `--background` pretends the Mac runs on; `.measured` reads it.
enum AssumedPower {
    case measured, battery, lowPowerMode
}

/// Real sensors, with the power context swapped for `--assume-battery` / `--assume-low-power`.
private struct AssumedPowerProvider: HardwareSensorProviding {
    let base: SMCSensorProvider
    let power: AssumedPower

    func sample() -> HardwareSample {
        let sample = base.sample()
        let real = sample.power
        let assumed: PowerContext? = switch power {
        case .measured: real
        case .battery: PowerContext(source: .battery, hasBattery: true, batteryPercent: real?.batteryPercent, isCharging: false,
                                    lowPowerMode: false)
        case .lowPowerMode: PowerContext(source: real?.source ?? .battery, hasBattery: real?.hasBattery ?? true,
                                         batteryPercent: real?.batteryPercent, isCharging: real?.isCharging, lowPowerMode: true)
        }
        return HardwareSample(timestamp: sample.timestamp, chip: sample.chip, model: sample.model, cpuTemperature: sample.cpuTemperature,
                              gpuTemperature: sample.gpuTemperature, fans: sample.fans, systemPowerWatts: sample.systemPowerWatts,
                              cpuPowerWatts: sample.cpuPowerWatts, gpuPowerWatts: sample.gpuPowerWatts,
                              thermalState: sample.thermalState, power: assumed)
    }
}

/// `--background <seconds>`: an adaptive session with nobody looking (docs/v2/PHASE-4-PLAN.md 4a),
/// sensors and Docker on, printing each tick's span, the next interval and why, and its cost.
/// Stops after `seconds`. For docs/PERFORMANCE.md §2.9: wrap it in `/usr/bin/time -l`.
func runBackground(seconds: TimeInterval, power: AssumedPower) async {
    let monitor = LiveMonitor()
    let configuration = LiveConfiguration(sampling: .adaptive, hardware: AssumedPowerProvider(base: SMCSensorProvider(), power: power),
                                          docker: DockerEngineSampler(), autoPauseAfter: nil, projectLocator: ProjectRootLocator())
    let stream = await monitor.start(configuration)
    let timer = Task {
        try await Task.sleep(for: .seconds(seconds))
        await monitor.stop()
    }
    var spans: [TimeInterval] = []
    var costs: [TimeInterval] = []
    var reasons: [String: Int] = [:]
    for await event in stream {
        switch event {
        case .tick(let tick):
            let decision = tick.sampling
            costs.append(tick.collectionSeconds)
            // The first tick follows the 1 s warm-up, not a policy interval.
            if tick.sequence > 1 { spans.append(tick.snapshot.interval) }
            reasons[decision?.reason.rawValue ?? "?", default: 0] += 1
            let power = tick.hardware.power.map { "\($0.source.rawValue)\($0.lowPowerMode ? " · low power" : "")" } ?? "unknown"
            print(String(format: "tick %3d · span %6.1f s (planned %5.0f s) · next %4.0f s (%@) · host %4.1f%% · %@ · %d events · cost %.1f ms",
                         tick.sequence, tick.snapshot.interval, tick.plannedInterval ?? 0, decision?.interval ?? 0,
                         decision?.reason.rawValue ?? "?", tick.snapshot.system.hostBusyFraction * 100, power, tick.events.count,
                         tick.collectionSeconds * 1000))
            for event in tick.events {
                print("  event: \(event.kind.rawValue)\(event.isInference ? " (inference)" : "")")
            }
        case .autoPaused:
            print("auto-paused")
        case .failed(let message):
            print("failed: \(message)")
        }
    }
    timer.cancel()
    func median(_ values: [TimeInterval]) -> TimeInterval { values.sorted()[values.count / 2] }
    guard !costs.isEmpty else { return }
    print(String(format: "ticks %d · median span %.1f s · median cost %.1f ms · max cost %.1f ms · reasons %@",
                 costs.count, spans.isEmpty ? 0 : median(spans), median(costs) * 1000, costs.max()! * 1000,
                 reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
}
