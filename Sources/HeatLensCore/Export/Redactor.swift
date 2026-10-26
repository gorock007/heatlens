import Foundation

public enum Redactor {
    /// How many processes the concise text report lists by CPU (FR-11), on top of every process a
    /// finding names. `jsonReport` always carries everything.
    public static let textProcessLimit = 15

    public static func textReport(
        _ snapshot: ScanSnapshot,
        groups: [ProcessGroup],
        findings: [DiagnosticFinding],
        homeDirectory: String = NSHomeDirectory(),
        processLimit: Int = Redactor.textProcessLimit
    ) -> String {
        let report = makeReport(snapshot, groups: groups, findings: findings, homeDirectory: homeDirectory)
        // Top N by CPU (unmeasured last), plus everything a finding names, highest CPU first.
        let named = Set(findings.flatMap(\.affectedProcesses).map(\.pid))
        let byCPU = report.processes.sorted { ($0.cpuPercent ?? -1, $1.pid) > ($1.cpuPercent ?? -1, $0.pid) }
        let top = Set(byCPU.prefix(max(processLimit, 0)).map(\.pid))
        let listed = byCPU.filter { top.contains($0.pid) || named.contains($0.pid) }
        let listedPIDs = Set(listed.map(\.pid))
        let listedGroups = report.groups.filter { !listedPIDs.isDisjoint(with: $0.memberPIDs) }
        var lines = [
            "HeatLens scan \(report.scanID.uuidString)",
            "Started: \(ISO8601DateFormatter().string(from: report.startedAt)); interval: \(String(format: "%.1f", report.interval)) s",
            "System: \(String(format: "%.1f", report.hostBusyPercent))% busy, memory pressure \(report.memoryPressure), thermal \(report.thermalState)",
        ]
        if !report.notices.isEmpty {
            lines.append("Notices: \(report.notices.joined(separator: "; "))")
        }

        lines.append("Groups:")
        if listedGroups.isEmpty { lines.append("- none") }
        for group in listedGroups {
            lines.append("- \(group.label) [\(group.kind), \(group.confidence)] root PID \(group.rootPID), project: \(group.project?.directory ?? "Unknown project")")
        }
        if listedGroups.count < report.groups.count {
            lines.append("\(report.groups.count - listedGroups.count) other groups omitted")
        }

        lines.append("Findings (ranked):")
        if report.findings.isEmpty { lines.append("- none") }
        for finding in report.findings {
            lines.append("- [\(finding.severity)] \(finding.title): \(finding.explanation)")
            lines.append("  Evidence: \(finding.evidence.map { "\($0.label)=\($0.value) (\($0.source))" }.joined(separator: "; "))")
            lines.append("  Limitations: \(finding.limitations.joined(separator: "; "))")
        }

        lines.append("Processes (top \(processLimit) by CPU, plus any named in a finding):")
        if listed.isEmpty { lines.append("- none") }
        for process in listed {
            let command = process.arguments?.joined(separator: " ") ?? "Unavailable"
            lines.append("- PID \(process.pid) \(process.name); CPU \(process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "Unavailable"); cwd \(process.currentDirectory ?? "Unavailable"); argv \(command)")
        }
        if listed.count < report.processes.count {
            lines.append("\(report.processes.count - listed.count) other processes omitted; Copy JSON for the full list")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func jsonReport(
        _ snapshot: ScanSnapshot,
        groups: [ProcessGroup],
        findings: [DiagnosticFinding],
        homeDirectory: String = NSHomeDirectory()
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(makeReport(snapshot, groups: groups, findings: findings, homeDirectory: homeDirectory))
    }
}

private struct RedactedReport: Codable {
    let scanID: UUID
    let startedAt: Date
    let interval: TimeInterval
    let hostBusyPercent: Double
    let memoryPressure: String
    let thermalState: String
    let notices: [String]
    let processes: [RedactedProcess]
    let groups: [RedactedGroup]
    let findings: [RedactedFinding]
}

private struct RedactedProcess: Codable {
    let pid: Int32
    let parentPID: Int32
    let owner: String
    let name: String
    let executablePath: String?
    let arguments: [String]?
    let currentDirectory: String?
    let cpuPercent: Double?
    let residentBytes: UInt64?
    let footprintBytes: UInt64?
    let detailAccess: String
}

private struct RedactedProject: Codable {
    let directory: String
    let basis: String
    let confidence: String
}

private struct RedactedGroup: Codable {
    let rootPID: Int32
    let memberPIDs: [Int32]
    let kind: String
    let label: String
    let project: RedactedProject?
    let confidence: String
    let evidence: [RedactedEvidence]
}

private struct RedactedEvidence: Codable {
    let label: String
    let value: String
    let source: String
}

private struct RedactedAction: Codable {
    let kind: String
    let pid: Int32?
    let path: String?
}

private struct RedactedFinding: Codable {
    let id: UUID
    let title: String
    let severity: String
    let confidence: String
    let explanation: String
    let evidence: [RedactedEvidence]
    let limitations: [String]
    let affectedPIDs: [Int32]
    let recommendedActions: [RedactedAction]
}

private extension Redactor {
    static func makeReport(
        _ snapshot: ScanSnapshot,
        groups: [ProcessGroup],
        findings: [DiagnosticFinding],
        homeDirectory: String
    ) -> RedactedReport {
        let sanitizer = Sanitizer(homeDirectory: homeDirectory)
        return RedactedReport(
            scanID: snapshot.id,
            startedAt: snapshot.startedAt,
            interval: snapshot.interval,
            hostBusyPercent: snapshot.system.hostBusyFraction * 100,
            memoryPressure: snapshot.system.memory.pressure.rawValue,
            thermalState: snapshot.system.thermalState.rawValue,
            notices: snapshot.notices.map(sanitizer.text),
            processes: snapshot.processes.sorted { $0.pid < $1.pid }.map { process in
                RedactedProcess(
                    pid: process.pid,
                    parentPID: process.parentPID,
                    owner: sanitizer.text(process.owner.rawValue),
                    name: sanitizer.text(process.name),
                    executablePath: process.executablePath.map(sanitizer.text),
                    arguments: sanitizer.arguments(process.arguments),
                    currentDirectory: process.currentDirectory.map(sanitizer.text),
                    cpuPercent: process.cpuPercentOfOneCore,
                    residentBytes: process.residentBytes,
                    footprintBytes: process.footprintBytes,
                    detailAccess: process.detailAccess.rawValue
                )
            },
            groups: groups.map { group in
                RedactedGroup(
                    rootPID: group.root.pid,
                    memberPIDs: group.members.map(\.pid),
                    kind: sanitizer.text(group.kind),
                    label: sanitizer.text(group.label),
                    project: group.project.map {
                        RedactedProject(
                            directory: sanitizer.text($0.directory),
                            basis: sanitizer.text($0.basis),
                            confidence: $0.confidence.rawValue
                        )
                    },
                    confidence: group.confidence.rawValue,
                    evidence: group.evidence.map { sanitizer.evidence($0) }
                )
            },
            findings: findings.map { finding in
                RedactedFinding(
                    id: finding.id,
                    title: sanitizer.text(finding.title),
                    severity: finding.severity.rawValue,
                    confidence: finding.confidence.rawValue,
                    explanation: sanitizer.text(finding.explanation),
                    evidence: finding.evidence.map { sanitizer.evidence($0) },
                    limitations: finding.limitations.map(sanitizer.text),
                    affectedPIDs: finding.affectedProcesses.map(\.pid),
                    recommendedActions: finding.recommendedActions.map { sanitizer.action($0) }
                )
            }
        )
    }
}

private struct Sanitizer {
    let homeDirectory: String
    let username: String

    init(homeDirectory: String) {
        let trimmed = homeDirectory.count > 1 && homeDirectory.hasSuffix("/")
            ? String(homeDirectory.dropLast())
            : homeDirectory
        self.homeDirectory = trimmed
        self.username = URL(fileURLWithPath: trimmed).lastPathComponent
    }

    func text(_ raw: String) -> String {
        var value = raw
        if value == homeDirectory {
            value = "~"
        } else if !homeDirectory.isEmpty {
            value = value.replacingOccurrences(of: homeDirectory + "/", with: "~/")
        }
        if !username.isEmpty, username != "/" {
            value = value.replacingOccurrences(
                of: NSRegularExpression.escapedPattern(for: username),
                with: "<user>",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        for option in ["token", "api[-_]?key", "password", "secret"] {
            value = value.replacingOccurrences(
                of: "--\(option)(?:=|\\s+)\\S+",
                with: "<secret redacted>",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return value
    }

    func arguments(_ arguments: [String]?) -> [String]? {
        guard let arguments else { return nil }
        guard let executable = arguments.first else { return [] }
        var redacted = [text(executable)]
        if arguments.count > 1 {
            redacted.append("<\(arguments.count - 1) args redacted>")
        }
        return redacted
    }

    func evidence(_ evidence: Evidence) -> RedactedEvidence {
        let sensitiveContext = (evidence.label + " " + evidence.source).lowercased()
        let value = sensitiveContext.contains("argv") || sensitiveContext.contains("argument") || sensitiveContext.contains("command")
            ? "<arguments redacted>"
            : text(evidence.value)
        return RedactedEvidence(label: text(evidence.label), value: value, source: text(evidence.source))
    }

    func action(_ action: SuggestedAction) -> RedactedAction {
        switch action {
        case .inspect(let identity):
            RedactedAction(kind: "inspect", pid: identity.pid, path: nil)
        case .openProject(let path):
            RedactedAction(kind: "openProject", pid: nil, path: text(path))
        case .copyCommand(let identity):
            RedactedAction(kind: "copyCommand", pid: identity.pid, path: nil)
        case .openActivityMonitor:
            RedactedAction(kind: "openActivityMonitor", pid: nil, path: nil)
        case .copyReport:
            RedactedAction(kind: "copyReport", pid: nil, path: nil)
        case .requestStop(let identity):
            RedactedAction(kind: "requestStop", pid: identity.pid, path: nil)
        }
    }
}
