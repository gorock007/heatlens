import Foundation

/// Best-effort reading of `pmset -g therm` (PRD §4.1: optional, parsed defensively).
/// Only integer `Key = Value` lines are interpreted; everything else is kept as a note.
/// No field is ever synthesised: a key that is absent stays nil.
public struct PmsetThermalReport: Hashable, Sendable {
    public let values: [String: Int]
    public let notes: [String]

    public init(values: [String: Int], notes: [String]) {
        self.values = values
        self.notes = notes
    }

    /// Percent of nominal CPU speed the scheduler allows (100 = unthrottled).
    public var cpuSpeedLimit: Int? { values["CPU_Speed_Limit"] }
    /// Percent of CPU time the scheduler allows (100 = unthrottled).
    public var cpuSchedulerLimit: Int? { values["CPU_Scheduler_Limit"] }
    public var availableCPUs: Int? { values["CPU_Available_CPUs"] }

    /// true/false when at least one limit key is present; nil when pmset gave no limits.
    public var indicatesThrottling: Bool? {
        let limits = [cpuSpeedLimit, cpuSchedulerLimit].compactMap { $0 }
        guard !limits.isEmpty else { return nil }
        return limits.contains { $0 < 100 }
    }

    public var isEmpty: Bool { values.isEmpty }
}

public enum PmsetThermParser {
    public static func parse(_ text: String) -> PmsetThermalReport {
        var values: [String: Int] = [:]
        var notes: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               let value = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !key.contains(" ") {
                    values[key] = value
                    continue
                }
            }
            notes.append(line)
        }
        return PmsetThermalReport(values: values, notes: notes)
    }
}
