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
