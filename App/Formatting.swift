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

    static let exited = "Exited during scan"

    /// CPU energy over the interval: "3.1 W", "12 W", "<0.1 W". nil stays nil so callers can omit it.
    static func watts(_ watts: Double?) -> String? {
        guard let watts else { return nil }
        if watts > 0 && watts < 0.05 { return "<0.1 W" }
        return watts >= 10 ? "\(Int(watts.rounded())) W" : String(format: "%.1f W", watts)
    }

    /// CPU and memory for one process row: "Exited during scan" when it vanished mid-scan, and a
    /// "via ps" note when the numbers came from ps rather than libproc.
    static func measurement(_ sample: ProcessSample?) -> String {
        guard let sample else { return "\(notAccessible) · \(notAccessible)" }
        if sample.detailAccess == .processExited { return exited }
        let line = "\(cpu(sample.cpuPercentOfOneCore)) · \(bytes(sample.footprintBytes ?? sample.residentBytes))"
        return sample.measurementSource == .ps ? line + " · via ps" : line
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

    static func owner(_ owner: ProcessOwner?) -> String {
        switch owner {
        case .currentUser: "Current user"
        case .root: "root"
        case .otherUser: "Another user"
        case .unknown: "Unknown"
        case nil: notAccessible
        }
    }

    static func impact(_ percent: Double?) -> String {
        guard let percent else { return "CPU impact was not accessible in this sample." }
        let shown = percent < 10 ? String(format: "%.1f", percent) : String(format: "%.0f", percent)
        if percent < 5 {
            return "\(shown)% CPU in this sample — stopping it is unlikely to cool your Mac."
        }
        return "\(shown)% CPU in this sample."
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
            finding.kind == .highCPU && (finding.severity == .high || finding.severity == .medium)
        }
        if system.hostBusyFraction >= 0.6 || cpuFinding { return "High load observed" }
        return "No significant issue observed"
    }
}
