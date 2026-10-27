import Foundation

public enum Redactor {
    /// How many processes the concise text report lists by CPU (FR-11), on top of every process a
    /// finding names. `jsonReport` always carries everything.
    public static let textProcessLimit = 15
    /// How many of one finding's processes the text report lists, highest CPU first.
    public static let textFindingProcessLimit = 5
    /// Longer argv in the text report is cut to this many characters.
    public static let textArgvLimit = 300
    /// Power assertion names in both reports are cut to this many characters.
    public static let assertionNameLimit = 80

    public static func textReport(
        _ snapshot: ScanSnapshot,
        groups: [ProcessGroup],
        findings: [DiagnosticFinding],
        homeDirectory: String = NSHomeDirectory(),
        processLimit: Int = Redactor.textProcessLimit
    ) -> String {
        let report = makeReport(snapshot, groups: groups, findings: findings, homeDirectory: homeDirectory)
        // Top N by CPU (unmeasured last), plus the busiest few each finding names, highest CPU first.
        let byCPU = report.processes.sorted { ($0.cpuPercent ?? -1, $1.pid) > ($1.cpuPercent ?? -1, $0.pid) }
        let named = Set(report.findings.flatMap { finding in
            let affected = Set(finding.affectedPIDs)
            return byCPU.filter { affected.contains($0.pid) }.prefix(textFindingProcessLimit).map(\.pid)
        })
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
            let affected = Set(finding.affectedPIDs)
            let affectedListed = affected.intersection(listedPIDs).count
            if affected.count > textFindingProcessLimit, affectedListed < affected.count {
                lines.append("  Processes: \(affectedListed) of \(affected.count) listed; Copy JSON for the full list")
            }
        }

        lines += portLines(report.listeningPorts)
        lines += awakeLines(report.powerAssertions, observedAt: report.startedAt.addingTimeInterval(report.interval))

        lines.append("Processes (top \(processLimit) by CPU, plus any named in a finding):")
        if listed.isEmpty { lines.append("- none") }
        for process in listed {
            let command = process.arguments.map { truncated($0.joined(separator: " "), to: textArgvLimit) } ?? "Unavailable"
            let energy = process.cpuWatts.map { String(format: " (%.2f W)", $0) } ?? ""
            lines.append("- PID \(process.pid) \(process.name); CPU \(process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "Unavailable")\(energy); cwd \(process.currentDirectory ?? "Unavailable"); argv \(command)")
        }
        if listed.count < report.processes.count {
            lines.append("\(report.processes.count - listed.count) other processes omitted; Copy JSON for the full list")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `text` cut to `limit` characters, with how many were cut.
    static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "… (+\(text.count - limit) chars)"
    }

    /// `heatlens ports`: the "Listening ports" section of `textReport` on its own, for a
    /// `PortsSnapshot` (one process reading, no CPU sample), with its notices.
    public static func portsTextReport(
        _ snapshot: ScanSnapshot,
        groups: [ProcessGroup],
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let report = makePortsReport(snapshot, groups: groups, homeDirectory: homeDirectory)
        var lines = ["HeatLens listening ports, read \(ISO8601DateFormatter().string(from: report.readAt))"]
        if !report.notices.isEmpty {
            lines.append("Notices: \(report.notices.joined(separator: "; "))")
        }
        lines += portLines(report.listeningPorts)
        return lines.joined(separator: "\n") + "\n"
    }

    /// `readAt`, `notices` and the same `listeningPorts` rows as `jsonReport`.
    public static func portsJSONReport(
        _ snapshot: ScanSnapshot,
        groups: [ProcessGroup],
        homeDirectory: String = NSHomeDirectory()
    ) throws -> Data {
        try encoder.encode(makePortsReport(snapshot, groups: groups, homeDirectory: homeDirectory))
    }

    /// `heatlens awake`: the "Keeping the Mac awake" section of `textReport` on its own, for an
    /// `AwakeSnapshot` (one process reading, no CPU sample), with its notices.
    public static func awakeTextReport(
        _ snapshot: ScanSnapshot,
        groups: [ProcessGroup],
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let report = makeAwakeReport(snapshot, groups: groups, homeDirectory: homeDirectory)
        var lines = ["HeatLens: what's keeping the Mac awake, read \(ISO8601DateFormatter().string(from: report.readAt))"]
        if !report.notices.isEmpty {
            lines.append("Notices: \(report.notices.joined(separator: "; "))")
        }
        lines += awakeLines(report.powerAssertions, observedAt: report.readAt)
        return lines.joined(separator: "\n") + "\n"
    }

    /// `readAt`, `notices` and the same `powerAssertions` rows as `jsonReport`.
    public static func awakeJSONReport(
        _ snapshot: ScanSnapshot,
        groups: [ProcessGroup],
        homeDirectory: String = NSHomeDirectory()
    ) throws -> Data {
        try encoder.encode(makeAwakeReport(snapshot, groups: groups, homeDirectory: homeDirectory))
    }

    public static func jsonReport(
        _ snapshot: ScanSnapshot,
        groups: [ProcessGroup],
        findings: [DiagnosticFinding],
        homeDirectory: String = NSHomeDirectory()
    ) throws -> Data {
        try encoder.encode(makeReport(snapshot, groups: groups, findings: findings, homeDirectory: homeDirectory))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The "Listening ports:" section, shared by the scan and ports text reports.
    private static func portLines(_ ports: [RedactedPort]) -> [String] {
        var lines = ["Listening ports:"]
        if ports.isEmpty { lines.append("- none") }
        for listing in ports {
            let project = listing.projectDirectory.map { "project \(($0 as NSString).lastPathComponent)" } ?? "Unknown project"
            lines.append("- :\(listing.port) (\(listing.scope)) — \(listing.processName), PID \(listing.pid), \(project)")
        }
        return lines
    }

    /// The "Keeping the Mac awake:" section, shared by the scan and awake text reports, e.g.
    /// `- Prevents idle sleep — caffeinate, PID 123, since 14:02 (3 h 12 min), project my-app, name "…"`.
    private static func awakeLines(_ assertions: [RedactedPowerAssertion], observedAt: Date) -> [String] {
        var lines = ["Keeping the Mac awake:"]
        if assertions.isEmpty { lines.append("- none") }
        for row in assertions {
            var parts = ["\(row.processName), PID \(row.pid)"]
            if let startedAt = row.startedAt {
                let held = row.heldSeconds.map { " (\(PowerAssertion.durationText($0)))" } ?? ""
                parts.append("since \(clockText(startedAt, observedAt: observedAt))\(held)")
            }
            if let timeout = row.timeoutSeconds { parts.append("timeout \(PowerAssertion.durationText(timeout))") }
            if let creator = row.createdByPID { parts.append("created by \(row.createdByName ?? "PID \(creator)") (PID \(creator))") }
            parts.append(row.projectDirectory.map { "project \(($0 as NSString).lastPathComponent)" } ?? "Unknown project")
            parts.append("name \"\(row.name)\"")
            lines.append("- \(row.effect) — \(parts.joined(separator: ", "))")
        }
        return lines
    }

    /// "14:02" on the day of `observedAt`, "Oct 26 14:02" before it; local time.
    static func clockText(_ date: Date, observedAt: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: observedAt) ? "HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
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
    let powerAssertions: [RedactedPowerAssertion]
}

private struct RedactedAwakeReport: Codable {
    let readAt: Date
    let notices: [String]
    let powerAssertions: [RedactedPowerAssertion]
}

/// The name is sanitized, URLs in it are cut to their host, and it is cut to 80 characters.
private struct RedactedPowerAssertion: Codable {
    let pid: Int32
    let processName: String
    let groupLabel: String?
    let projectDirectory: String?
    /// The raw `AssertType`, e.g. "PreventUserIdleSystemSleep".
    let type: String
    /// "Prevents idle sleep", "Prevents sleep" or "Keeps the display on".
    let effect: String
    let name: String
    let startedAt: Date?
    /// Whole seconds from `startedAt` to the end of the scan (or the read).
    let heldSeconds: Double?
    let timeoutSeconds: Double?
    let createdByPID: Int32?
    let createdByName: String?
}

private struct RedactedPortsReport: Codable {
    let readAt: Date
    let notices: [String]
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
    /// CPU energy over the interval (kernel per-task counter); own processes only.
    let cpuWatts: Double?
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
                    cpuWatts: process.cpuWatts,
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
            listeningPorts: portRows(snapshot, groups: groups, sanitizer: sanitizer),
            powerAssertions: assertionRows(snapshot, groups: groups, sanitizer: sanitizer)
        )
    }

    static func makeAwakeReport(_ snapshot: ScanSnapshot, groups: [ProcessGroup], homeDirectory: String) -> RedactedAwakeReport {
        let sanitizer = Sanitizer(homeDirectory: homeDirectory, groups: groups)
        return RedactedAwakeReport(readAt: snapshot.startedAt, notices: snapshot.notices.map(sanitizer.text),
                                   powerAssertions: assertionRows(snapshot, groups: groups, sanitizer: sanitizer))
    }

    static func assertionRows(_ snapshot: ScanSnapshot, groups: [ProcessGroup], sanitizer: Sanitizer) -> [RedactedPowerAssertion] {
        let observedAt = snapshot.startedAt.addingTimeInterval(snapshot.interval)
        return PowerAssertionListing.listings(snapshot, groups: groups).map { listing in
            let assertion = listing.assertion
            return RedactedPowerAssertion(
                pid: listing.identity.pid,
                processName: sanitizer.text(listing.processName),
                groupLabel: listing.group.map { sanitizer.text($0.label) },
                projectDirectory: listing.group?.project.map { sanitizer.text($0.directory) },
                type: sanitizer.text(assertion.type),
                effect: assertion.effect?.label ?? sanitizer.text(assertion.type),
                name: sanitizer.assertionName(assertion.name),
                startedAt: assertion.startedAt,
                heldSeconds: assertion.heldSeconds(at: observedAt).map { $0.rounded(.down) },
                timeoutSeconds: assertion.timeoutSeconds,
                createdByPID: assertion.createdByPID,
                createdByName: listing.createdByName.map(sanitizer.text)
            )
        }
    }

    static func makePortsReport(_ snapshot: ScanSnapshot, groups: [ProcessGroup], homeDirectory: String) -> RedactedPortsReport {
        let sanitizer = Sanitizer(homeDirectory: homeDirectory, groups: groups)
        return RedactedPortsReport(readAt: snapshot.startedAt, notices: snapshot.notices.map(sanitizer.text),
                                   listeningPorts: portRows(snapshot, groups: groups, sanitizer: sanitizer))
    }

    static func portRows(_ snapshot: ScanSnapshot, groups: [ProcessGroup], sanitizer: Sanitizer) -> [RedactedPort] {
        PortListing.listings(snapshot, groups: groups).map { listing in
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
    /// Whole words and path components only: user `al` must not turn /usr/local into /usr/loc<user>.
    let usernamePattern: NSRegularExpression?
    /// Labels built from an argv script name (`node sync.js`) and what they export as
    /// (`node <script>`). The app still shows the real label; only the export hides it.
    let scriptLabels: [(label: String, replacement: String)]

    init(homeDirectory: String, groups: [ProcessGroup] = []) {
        let trimmed = homeDirectory.count > 1 && homeDirectory.hasSuffix("/")
            ? String(homeDirectory.dropLast())
            : homeDirectory
        self.homeDirectory = trimmed
        self.username = URL(fileURLWithPath: trimmed).lastPathComponent
        self.usernamePattern = username.isEmpty || username == "/"
            ? nil
            : RedactionPatterns.compile("(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: username) + "(?![A-Za-z0-9_])",
                           caseInsensitive: true)
        var labels: [String: String] = [:]
        for group in groups where group.kind.hasSuffix(" script") {
            let tool = String(group.kind.dropLast(" script".count))
            let replacement = "\(tool) <script>"
            if group.label != replacement, group.label != tool { labels[group.label] = replacement }
        }
        // Longest first, so one label never leaves a fragment of a longer one behind.
        self.scriptLabels = labels.map { ($0.key, $0.value) }.sorted { $0.label.count > $1.label.count }
    }

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
        value = RedactionPatterns.replacing(usernamePattern, in: value, with: "<user>")
        value = RedactionPatterns.replacing(RedactionPatterns.secretFlag, in: value, with: "<secret redacted>")
        value = RedactionPatterns.replacing(RedactionPatterns.secretAssignment, in: value, with: "<secret redacted>")
        if RedactionPatterns.matches(RedactionPatterns.passwordContext, raw) {
            value = RedactionPatterns.replacing(RedactionPatterns.shortPasswordFlag, in: value, with: "<secret redacted>")
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
        if RedactionPatterns.matches(RedactionPatterns.credentialPrefix, component)
            || RedactionPatterns.matches(RedactionPatterns.longHex, component) { return true }
        // Base64-ish: a long unbroken run mixing upper case, lower case and digits.
        guard let base64Run = RedactionPatterns.base64Run else { return false }
        let runs = base64Run.matches(in: component, range: NSRange(component.startIndex..., in: component))
        return runs.contains { match in
            guard let range = Range(match.range, in: component) else { return false }
            let text = component[range]
            return text.contains(where: \.isUppercase) && text.contains(where: \.isLowercase) && text.contains(where: \.isNumber)
        }
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

    /// A power assertion's name: each URL cut to its host (`<file URL>` without one), then
    /// sanitized like any text, then cut to `Redactor.assertionNameLimit` characters.
    func assertionName(_ raw: String) -> String {
        let pattern = "(?i)\\b([a-z][a-z0-9+.-]*)://([^\\s/?#\"'<>]*)[^\\s\"'<>]*"
        var value = raw
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let source = raw as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: raw, range: NSRange(location: 0, length: source.length)) {
                result += source.substring(with: NSRange(location: last, length: match.range.location - last))
                let scheme = source.substring(with: match.range(at: 1)).lowercased()
                // Drop any user:password@ in front of the host.
                let authority = source.substring(with: match.range(at: 2))
                let host = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
                result += host.isEmpty ? "<\(scheme) URL>" : host
                last = match.range.location + match.range.length
            }
            value = result + source.substring(from: last)
        }
        value = text(value)
        let limit = Redactor.assertionNameLimit
        return value.count > limit ? String(value.prefix(limit - 1)) + "…" : value
    }

    func evidence(_ evidence: Evidence) -> RedactedEvidence {
        if evidence.source == PowerAssertion.evidenceSource {
            return RedactedEvidence(label: text(evidence.label), value: assertionName(evidence.value), source: evidence.source)
        }
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

/// Redaction regular expressions, shared by every report.
enum RedactionPatterns {
    // Compiled once: `String.range(of:options: .regularExpression)` compiles its pattern on every
    // call, which made one report cost about a second of CPU (docs/v2/GAP-ANALYSIS.md §4).

    /// Option names that carry a secret, with a `=value` or a following value that isn't another flag.
    static let secretFlag = compile("-{1,2}[\\w-]*(?:token|key|password|passwd|secret)[\\w-]*(?:=\\S+|\\s+(?!-)\\S+)",
                                    caseInsensitive: true)
    /// `API_TOKEN=x`-style environment assignments.
    static let secretAssignment = compile("\\b[A-Z_]*(?:TOKEN|KEY|SECRET|PASSWORD)=\\S+")
    /// A short `-p value` is only a password when the same text names a password option too,
    /// since `-p 3000` is usually a port.
    static let passwordContext = compile("(?i)(?:^|\\s)-{1,2}[\\w-]*pass[\\w-]*")
    static let shortPasswordFlag = compile("(?:^|(?<=\\s))-p(?:=|\\s+)(?!-)\\S+")
    /// Well-known credential prefixes, not glued to a preceding letter or digit (`task-runner` isn't `sk-…`).
    static let credentialPrefix = compile("(?<![A-Za-z0-9])(?:gh[po]_[A-Za-z0-9]|xox[abpr]-|sk-[A-Za-z0-9_-]{16}|AKIA[0-9A-Z]{16})")
    static let longHex = compile("[0-9a-fA-F]{32,}")
    static let base64Run = compile("[A-Za-z0-9+=_-]{32,}")

    /// The patterns are literals, so a failure is a programming error that the tests catch; nil
    /// then simply matches nothing.
    static func compile(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    static func replacing(_ regex: NSRegularExpression?, in value: String, with template: String) -> String {
        guard let regex else { return value }
        return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
    }

    static func matches(_ regex: NSRegularExpression?, _ value: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
