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

        lines.append("Listening ports:")
        if report.listeningPorts.isEmpty { lines.append("- none") }
        for listing in report.listeningPorts {
            let project = listing.projectDirectory.map { "project \(($0 as NSString).lastPathComponent)" } ?? "Unknown project"
            lines.append("- :\(listing.port) (\(listing.scope)) — \(listing.processName), PID \(listing.pid), \(project)")
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
    let listeningPorts: [RedactedPort]
}

/// A specific bind address (a LAN or VPN IP) is left out; the scope says one was used.
private struct RedactedPort: Codable {
    let port: UInt16
    let family: String
    /// "loopback", "all interfaces" or "specific address".
    let scope: String
    let pid: Int32
    let processName: String
    let groupLabel: String?
    let projectDirectory: String?
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
        let sanitizer = Sanitizer(homeDirectory: homeDirectory, groups: groups)
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
            },
            listeningPorts: PortListing.listings(snapshot, groups: groups).map { listing in
                RedactedPort(
                    port: listing.port.port,
                    family: listing.port.family.rawValue,
                    scope: scopeText(listing.port.scope),
                    pid: listing.identity.pid,
                    processName: sanitizer.text(listing.processName),
                    groupLabel: listing.group.map { sanitizer.text($0.label) },
                    projectDirectory: listing.group?.project.map { sanitizer.text($0.directory) }
                )
            }
        )
    }

    static func scopeText(_ scope: BindScope) -> String {
        switch scope {
        case .loopback: "loopback"
        case .allInterfaces: "all interfaces"
        case .specificAddress: "specific address"
        }
    }
}

private struct Sanitizer {
    let homeDirectory: String
    let username: String
    /// Labels built from an argv script name (`node sync.js`) and what they export as
    /// (`node <script>`). The app still shows the real label; only the export hides it.
    let scriptLabels: [(label: String, replacement: String)]

    init(homeDirectory: String, groups: [ProcessGroup] = []) {
        let trimmed = homeDirectory.count > 1 && homeDirectory.hasSuffix("/")
            ? String(homeDirectory.dropLast())
            : homeDirectory
        self.homeDirectory = trimmed
        self.username = URL(fileURLWithPath: trimmed).lastPathComponent
        var labels: [String: String] = [:]
        for group in groups where group.kind.hasSuffix(" script") {
            let tool = String(group.kind.dropLast(" script".count))
            let replacement = "\(tool) <script>"
            if group.label != replacement, group.label != tool { labels[group.label] = replacement }
        }
        // Longest first, so one label never leaves a fragment of a longer one behind.
        self.scriptLabels = labels.map { ($0.key, $0.value) }.sorted { $0.label.count > $1.label.count }
    }

    /// Option names that carry a secret, with a `=value` or a following value that isn't another flag.
    static let secretFlag = "-{1,2}[\\w-]*(?:token|key|password|passwd|secret)[\\w-]*(?:=\\S+|\\s+(?!-)\\S+)"
    /// `API_TOKEN=x`-style environment assignments.
    static let secretAssignment = "\\b[A-Z_]*(?:TOKEN|KEY|SECRET|PASSWORD)=\\S+"
    /// A short `-p value` is only a password when the same text names a password option too,
    /// since `-p 3000` is usually a port.
    static let passwordContext = "(?i)(?:^|\\s)-{1,2}[\\w-]*pass[\\w-]*"
    static let shortPasswordFlag = "(?:^|(?<=\\s))-p(?:=|\\s+)(?!-)\\S+"
    /// Well-known credential prefixes, not glued to a preceding letter or digit (`task-runner` isn't `sk-…`).
    static let credentialPrefix = "(?<![A-Za-z0-9])(?:gh[po]_[A-Za-z0-9]|xox[abpr]-|sk-[A-Za-z0-9_-]{16}|AKIA[0-9A-Z]{16})"
    static let longHex = "[0-9a-fA-F]{32,}"
    static let base64Run = "[A-Za-z0-9+=_-]{32,}"

    func text(_ raw: String) -> String {
        var value = raw
        for script in scriptLabels {
            value = value.replacingOccurrences(of: script.label, with: script.replacement)
        }
        if value == homeDirectory {
            value = "~"
        } else if !homeDirectory.isEmpty {
            value = value.replacingOccurrences(of: homeDirectory + "/", with: "~/")
        }
        if !username.isEmpty, username != "/" {
            // Whole words and path components only: user `al` must not turn /usr/local into /usr/loc<user>.
            value = value.replacingOccurrences(
                of: "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: username) + "(?![A-Za-z0-9_])",
                with: "<user>",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        value = value.replacingOccurrences(of: Self.secretFlag, with: "<secret redacted>",
                                           options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: Self.secretAssignment, with: "<secret redacted>", options: .regularExpression)
        if raw.range(of: Self.passwordContext, options: .regularExpression) != nil {
            value = value.replacingOccurrences(of: Self.shortPasswordFlag, with: "<secret redacted>", options: .regularExpression)
        }
        return redactingCredentialComponents(value)
    }

    /// Replaces each path component or word that looks like a credential with `<redacted>`.
    func redactingCredentialComponents(_ value: String) -> String {
        var result = ""
        var component = ""
        func flush() {
            result += Self.looksLikeCredential(component) ? "<redacted>" : component
            component = ""
        }
        for character in value {
            if character == "/" || character.isWhitespace {
                flush()
                result.append(character)
            } else {
                component.append(character)
            }
        }
        flush()
        return result
    }

    static func looksLikeCredential(_ component: String) -> Bool {
        guard component.count >= 4 else { return false }
        if component.range(of: credentialPrefix, options: .regularExpression) != nil { return true }
        if component.range(of: longHex, options: .regularExpression) != nil { return true }
        // Base64-ish: a long unbroken run mixing upper case, lower case and digits.
        var searchStart = component.startIndex
        while let run = component.range(of: base64Run, options: .regularExpression, range: searchStart..<component.endIndex) {
            let text = component[run]
            if text.contains(where: \.isUppercase), text.contains(where: \.isLowercase), text.contains(where: \.isNumber) {
                return true
            }
            searchStart = run.upperBound
        }
        return false
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
