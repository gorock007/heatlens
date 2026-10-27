import Foundation

/// Turns a live tick into the rows `HistoryStore` keeps (brief 2c). Pure.
public enum HistoryRecorder {
    public static func point(from tick: LiveTick) -> HistoryPoint {
        let system = tick.snapshot.system
        let observedAt = tick.snapshot.startedAt.addingTimeInterval(tick.snapshot.interval)
        return HistoryPoint(timestamp: observedAt, thermalState: system.thermalState, hostBusyFraction: system.hostBusyFraction,
                            swapUsedBytes: system.memory.swapUsedBytes, memoryPressure: system.memory.pressure,
                            cpuTemperatureCelsius: tick.hardware.cpuTemperature.value?.averageCelsius,
                            systemWatts: tick.hardware.systemPowerWatts.value,
                            processWatts: tick.snapshot.measuredCPUWatts)
    }

    /// The busiest rows of the tick's project breakdown (Docker VM and Unattributed included),
    /// at most `HistoryStore.projectsPerTick`, skipping rows that used no CPU.
    public static func projectPoints(from tick: LiveTick) -> [HistoryProjectPoint] {
        let observedAt = tick.snapshot.startedAt.addingTimeInterval(tick.snapshot.interval)
        return tick.projects.usages
            .filter { $0.totalCPUPercent > 0 }
            .sorted { $0.totalCPUPercent > $1.totalCPUPercent }
            .prefix(HistoryStore.projectsPerTick)
            .map { usage in
                HistoryProjectPoint(timestamp: observedAt, projectID: usage.project?.id ?? usage.id, name: usage.name,
                                    cpuPercent: usage.totalCPUPercent, memoryBytes: usage.memoryBytes, watts: usage.cpuWatts)
            }
    }
}
