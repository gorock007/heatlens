import Foundation
import HeatLensCore

/// Display strings shared by the popover views. "Not accessible" stands in for anything the
/// scan could not read; nothing is ever estimated or invented.
enum Format {
    static let notAccessible = "Not accessible"

    /// 100 = one core (FR-03): "44% CPU (of one core)", "180% CPU (≈1.8 cores)".
    static func cpu(_ percent: Double?) -> String {
        guard let percent else { return notAccessible }
        if percent > 100 {
            return "\(Int(percent.rounded()))% CPU (≈\(String(format: "%.1f", percent / 100)) cores)"
        }
        let shown = percent < 10 && percent > 0 ? String(format: "%.1f", percent) : "\(Int(percent.rounded()))"
        return "\(shown)% CPU (of one core)"
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return notAccessible }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    /// "2d 5h", "3h 12m", "4m".
    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(max(minutes, 0))m"
    }

    static func thermal(_ state: ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        case .unavailable: "Unavailable"
        }
    }

    static func pressure(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }

    static func severity(_ severity: Severity) -> String {
        switch severity {
        case .info: "Info"
        case .review: "Review"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    static func confidence(_ confidence: Confidence) -> String {
        switch confidence {
        case .low: "Low confidence"
        case .medium: "Medium confidence"
        case .high: "High confidence"
        }
    }

    /// Shell-style command line from argv; nil when argv is not accessible.
    static func command(_ arguments: [String]?) -> String? {
        guard let arguments, !arguments.isEmpty else { return nil }
        return arguments.map { arg in
            arg.contains(where: { $0 == " " || $0 == "'" || $0 == "\"" })
                ? "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
                : arg
        }.joined(separator: " ")
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// PRD §3 step 4 status line, derived from the report. States what was observed, never a cause.
enum Headline {
    static func text(for report: ScanReport) -> String {
        let system = report.snapshot.system
        switch system.thermalState {
        case .serious, .critical: return "Thermal pressure reported"
        default: break
        }
        switch system.memory.pressure {
        case .warning, .critical: return "Memory pressure"
        default: break
        }
        let cpuFinding = report.findings.contains { finding in
            (finding.severity == .high || finding.severity == .medium)
                && finding.evidence.contains { $0.label.localizedCaseInsensitiveContains("CPU") }
        }
        if system.hostBusyFraction >= 0.6 || cpuFinding { return "High load observed" }
        return "No significant issue observed"
    }
}
