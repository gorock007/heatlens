import Foundation

/// One incident (PRD-v2 §7, PHASE-4-PLAN 4h): an explanation, an alert or the timeline's busiest
/// moment, with everything HeatLens already holds from 2 minutes before it started to 2 minutes
/// after it ended (or now). Built from data in memory; nothing new is sampled or stored. It still
/// holds PIDs, IDs and raw text: only `Redactor.incidentMarkdown`/`incidentJSON` may leave the app.
/// `Equatable` only, because `ActionRecord` is.
public struct Incident: Equatable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case explanation, alert, busiestMoment
    }

    /// What the incident was built from.
    public enum Trigger: Hashable, Sendable {
        case explanation(Explanation)
        case alert(Alert)
        case busiestMoment(TimelineAnalysis.Peak)

        public var kind: Kind {
            switch self {
            case .explanation: .explanation
            case .alert: .alert
            case .busiestMoment: .busiestMoment
            }
        }
    }

    /// One row of the incident's timeline: a minute, or a longer bucket when the window is too
    /// long for `IncidentBuilder.timelineRowLimit` one-minute rows.
    public struct TimelineRow: Hashable, Sendable {
        public let start: Date
        /// 0...1 of all cores, averaged over the row.
        public let hostBusyFraction: Double
        /// The row's busiest tick.
        public let hostBusyPeak: Double
        /// The hottest state in the row.
        public let thermalState: ThermalState
        /// The row's maximum.
        public let swapUsedBytes: UInt64
        /// Up to 3, busiest first by average CPU over the row.
        public let topProjects: [HistoryProjectPoint]
        /// Oldest first.
        public let events: [TimelineEvent]
    }

    /// Power and thermal context over the window; nil fields weren't measured.
    public struct Context: Hashable, Sendable {
        public let worstThermalState: ThermalState
        public let worstMemoryPressure: MemoryPressureLevel
        public let averageBusyFraction: Double?
        public let peakBusyFraction: Double?
        public let peakSwapUsedBytes: UInt64?
        public let peakCPUTemperatureCelsius: Double?
        public let averageSystemWatts: Double?
        public let peakSystemWatts: Double?
    }

    public let trigger: Trigger
    /// When the trigger started: the burst's first command, the alert's tick, the busiest point.
    public let startedAt: Date
    /// When it ended; nil while an explanation's burst still runs.
    public let endedAt: Date?
    public let windowStart: Date
    public let windowEnd: Date
    /// The trigger's explanation first, then the others overlapping the window, oldest first.
    public let explanations: [Explanation]
    /// Fired inside the window, oldest first; the trigger's alert is always included.
    public let alerts: [Alert]
    /// Seconds per timeline row: 60, or more for a long window.
    public let bucketSeconds: TimeInterval
    public let timeline: [TimelineRow]
    /// Taken inside the window, oldest first.
    public let actions: [ActionRecord]
    public let context: Context

    public var kind: Kind { trigger.kind }
}

public enum IncidentBuilder {
    /// The incident's window reaches this far either side of it.
    public static let defaultMargin: TimeInterval = 120
    /// The Markdown table stays readable: a longer window gets coarser rows, never more of them.
    public static let timelineRowLimit = 120

    public static func incident(from explanation: Explanation, timeline: HistoryWindow, alerts: [Alert] = [],
                                explanations: [Explanation] = [], actions: [ActionRecord] = [],
                                margin: TimeInterval = defaultMargin, now: Date = Date()) -> Incident {
        let margin = clamped(margin)
        let end = explanation.endedAt.map { min($0 + margin, now) } ?? now
        return build(.explanation(explanation), startedAt: explanation.startedAt, endedAt: explanation.endedAt,
                     windowStart: explanation.startedAt - margin, windowEnd: max(end, explanation.startedAt),
                     timeline: timeline, alerts: alerts, explanations: explanations, actions: actions, now: now)
    }

    public static func incident(from alert: Alert, timeline: HistoryWindow, alerts: [Alert] = [],
                                explanations: [Explanation] = [], actions: [ActionRecord] = [],
                                margin: TimeInterval = defaultMargin, now: Date = Date()) -> Incident {
        let margin = clamped(margin)
        return build(.alert(alert), startedAt: alert.firedAt, endedAt: alert.firedAt,
              windowStart: alert.firedAt - margin, windowEnd: max(min(alert.firedAt + margin, now), alert.firedAt),
              timeline: timeline, alerts: alerts, explanations: explanations, actions: actions, now: now)
    }

    public static func incident(from peak: TimelineAnalysis.Peak, timeline: HistoryWindow, alerts: [Alert] = [],
                                explanations: [Explanation] = [], actions: [ActionRecord] = [],
                                margin: TimeInterval = defaultMargin, now: Date = Date()) -> Incident {
        let margin = clamped(margin)
        let at = peak.point.timestamp
        return build(.busiestMoment(peak), startedAt: at, endedAt: at,
                     windowStart: at - margin, windowEnd: max(min(at + margin, now), at),
                     timeline: timeline, alerts: alerts, explanations: explanations, actions: actions, now: now)
    }

    /// A negative margin would put the window's start after its end; a non-finite one has no window.
    static func clamped(_ margin: TimeInterval) -> TimeInterval {
        margin.isFinite ? max(0, margin) : 0
    }

    /// `Int(x)` traps on NaN, ±∞ and anything past `Int`'s range; this gives 0 or the nearest bound instead.
    static func wholeNumber(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -1e15), 1e15))
    }

    private static func build(_ trigger: Incident.Trigger, startedAt: Date, endedAt: Date?, windowStart: Date, windowEnd: Date,
                              timeline: HistoryWindow, alerts: [Alert], explanations: [Explanation], actions: [ActionRecord],
                              now: Date) -> Incident {
        // Not a ClosedRange: one built from bad dates (NaN, start after end) traps.
        let window = { (date: Date) in date >= windowStart && date <= windowEnd }

        var keptExplanations: [Explanation] = []
        if case .explanation(let own) = trigger { keptExplanations.append(own) }
        for explanation in explanations.sorted(by: { $0.startedAt < $1.startedAt })
        where !keptExplanations.contains(where: { $0.id == explanation.id })
            && explanation.startedAt <= windowEnd && (explanation.endedAt ?? now) >= windowStart {
            keptExplanations.append(explanation)
        }

        var keptAlerts = alerts.filter { window($0.firedAt) }
        if case .alert(let own) = trigger, !keptAlerts.contains(where: { $0.id == own.id }) { keptAlerts.append(own) }
        keptAlerts.sort { $0.firedAt < $1.firedAt }

        let points = timeline.points.filter { window($0.timestamp) }
        let projects = timeline.projects.filter { window($0.timestamp) }
        let events = timeline.events.filter { window($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
        let minutes = (windowEnd.timeIntervalSince(windowStart) / 60).rounded(.up)
        let bucketSeconds = minutes.isFinite ? 60 * max(1, (minutes / Double(timelineRowLimit)).rounded(.up)) : 60

        return Incident(
            trigger: trigger, startedAt: startedAt, endedAt: endedAt, windowStart: windowStart, windowEnd: windowEnd,
            explanations: keptExplanations, alerts: keptAlerts, bucketSeconds: bucketSeconds,
            timeline: rows(points: points, projects: projects, events: events, from: windowStart, to: windowEnd, bucketSeconds: bucketSeconds),
            actions: actions.filter { window($0.at) }.sorted { $0.at < $1.at },
            context: context(points))
    }

    /// Rows only for buckets holding a point or an event, oldest first.
    private static func rows(points: [HistoryPoint], projects: [HistoryProjectPoint], events: [TimelineEvent],
                             from start: Date, to end: Date, bucketSeconds: TimeInterval) -> [Incident.TimelineRow] {
        // The window's last instant would start a bucket of its own; it joins the one before.
        let lastBucket = max(0, wholeNumber((end.timeIntervalSince(start) / bucketSeconds).rounded(.up)) - 1)
        func bucket(_ date: Date) -> Int { min(max(0, wholeNumber(date.timeIntervalSince(start) / bucketSeconds)), lastBucket) }
        let pointsByBucket = Dictionary(grouping: points) { bucket($0.timestamp) }
        let projectsByBucket = Dictionary(grouping: projects) { bucket($0.timestamp) }
        let eventsByBucket = Dictionary(grouping: events) { bucket($0.timestamp) }
        let buckets = Set(pointsByBucket.keys).union(eventsByBucket.keys).sorted()
        return buckets.map { index in
            let points = pointsByBucket[index] ?? []
            let top = Dictionary(grouping: projectsByBucket[index] ?? [], by: \.projectID).values.compactMap { rows -> HistoryProjectPoint? in
                guard let last = rows.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
                let count = Double(rows.count)
                let watts = rows.compactMap(\.watts)
                return HistoryProjectPoint(timestamp: last.timestamp, projectID: last.projectID, name: last.name,
                                           cpuPercent: rows.map(\.cpuPercent).reduce(0, +) / count,
                                           cpuPeakPercent: rows.map(\.cpuPeakPercent).max(),
                                           memoryBytes: rows.map(\.memoryBytes).max() ?? 0,
                                           watts: watts.isEmpty ? nil : watts.reduce(0, +) / Double(watts.count))
            }
            .sorted { ($0.cpuPercent, $1.name) > ($1.cpuPercent, $0.name) }
            return Incident.TimelineRow(
                start: start + Double(index) * bucketSeconds,
                hostBusyFraction: points.isEmpty ? 0 : points.map(\.hostBusyFraction).reduce(0, +) / Double(points.count),
                hostBusyPeak: points.map(\.hostBusyPeak).max() ?? 0,
                thermalState: points.map(\.thermalState).max { $0.rank < $1.rank } ?? .unavailable,
                swapUsedBytes: points.map(\.swapUsedBytes).max() ?? 0,
                topProjects: Array(top.prefix(3)),
                events: eventsByBucket[index] ?? [])
        }
    }

    private static func context(_ points: [HistoryPoint]) -> Incident.Context {
        let watts = points.compactMap(\.systemWatts)
        return Incident.Context(
            worstThermalState: points.map(\.thermalState).max { $0.rank < $1.rank } ?? .unavailable,
            worstMemoryPressure: points.map(\.memoryPressure).max { $0.rank < $1.rank } ?? .unknown,
            averageBusyFraction: points.isEmpty ? nil : points.map(\.hostBusyFraction).reduce(0, +) / Double(points.count),
            peakBusyFraction: points.map(\.hostBusyPeak).max(),
            peakSwapUsedBytes: points.map(\.swapUsedBytes).max(),
            peakCPUTemperatureCelsius: points.compactMap(\.cpuTemperatureCelsius).max(),
            averageSystemWatts: watts.isEmpty ? nil : watts.reduce(0, +) / Double(watts.count),
            peakSystemWatts: watts.max())
    }
}

public struct IncidentExportOptions: Hashable, Sendable {
    /// "Replace project names with Project A, B…", in order of first appearance, everywhere.
    public var anonymizeProjects: Bool

    public init(anonymizeProjects: Bool = false) {
        self.anonymizeProjects = anonymizeProjects
    }
}

extension Redactor {
    /// What every incident report says it leaves out (owner decision 5).
    public static let incidentLeftOut = [
        "process IDs", "process start times", "container IDs", "file and folder paths", "command lines (argv)",
        "environment variables",
    ]

    /// Markdown to paste into an issue: title, when, summary, observations, uncertainty, alerts, a
    /// timeline table (≤ `IncidentBuilder.timelineRowLimit` rows), actions, and what it leaves out.
    public static func incidentMarkdown(_ incident: Incident, options: IncidentExportOptions = IncidentExportOptions(),
                                        homeDirectory: String = NSHomeDirectory(), timeZone: TimeZone = .current) -> String {
        let report = makeIncidentReport(incident, options: options, homeDirectory: homeDirectory)
        let clock = { (date: Date) in clockText(date, observedAt: report.window.start, timeZone: timeZone) }
        // A burst spans seconds, so its facts need them to read in order.
        let precise = { (date: Date) in secondsClock(date, observedAt: report.window.start, timeZone: timeZone) }
        var lines = ["# HeatLens incident: \(report.title)", ""]

        let started = longClock(report.startedAt, timeZone: timeZone)
        let ended = report.endedAt.map { clockText($0, observedAt: report.startedAt, timeZone: timeZone) } ?? "still running"
        lines.append(report.endedAt == report.startedAt
            ? "**When:** \(started)"
            : "**When:** \(started) to \(ended)")
        let margin = IncidentBuilder.wholeNumber((report.startedAt.timeIntervalSince(report.window.start) / 60).rounded())
        lines.append("**Window:** \(clock(report.window.start)) to \(clock(report.window.end)) (\(margin) minute\(margin == 1 ? "" : "s") either side)")
        lines += ["", "## Summary", ""]
        lines.append("- \(report.summary)")
        lines += contextLines(report.context)

        lines += ["", "## Observations", ""]
        if report.explanations.isEmpty && report.busiestProjects.isEmpty {
            lines.append("None")
        }
        if !report.busiestProjects.isEmpty {
            lines.append("- Busiest projects at that moment: "
                + report.busiestProjects.map { "\($0.name) (\(cores($0.cpuPercent)))" }.joined(separator: ", "))
        }
        for explanation in report.explanations {
            lines.append("### \(explanation.title)")
            lines.append("")
            lines.append("Confidence: \(explanation.confidence)" + (explanation.agents.isEmpty ? "" : " · agents: \(explanation.agents.joined(separator: ", "))"))
            lines.append("")
            for observation in explanation.observations {
                lines.append("- \(precise(observation.at)) — \(observation.label): \(observation.value) (\(observation.source))")
            }
            lines.append("")
            lines.append("Recommendation: \(explanation.recommendation)")
            lines.append("")
        }
        if lines.last == "" { lines.removeLast() }

        lines += ["", "## Uncertainty", ""]
        var uncertainty: [String] = []
        for line in report.explanations.flatMap(\.uncertainty) where !uncertainty.contains(line) { uncertainty.append(line) }
        lines += uncertainty.isEmpty ? ["None"] : uncertainty.map { "- \($0)" }

        lines += ["", "## Alerts", ""]
        if report.alerts.isEmpty { lines.append("None") }
        for alert in report.alerts {
            lines.append("- \(precise(alert.firedAt)) — **\(alert.title)**")
            for observation in alert.observations {
                lines.append("  - \(observation.label): \(observation.value)")
            }
            lines.append("  - Suggestion: \(alert.suggestion)")
        }

        lines += ["", "## Timeline", ""]
        if report.timeline.isEmpty {
            lines.append("None")
        } else {
            if report.bucketSeconds > 60 { lines += ["One row per \(IncidentBuilder.wholeNumber(report.bucketSeconds / 60)) minutes.", ""] }
            lines.append("| Time | CPU avg | CPU peak | Thermal | Swap | Top projects | Events |")
            lines.append("|---|---|---|---|---|---|---|")
            for row in report.timeline {
                let projects = row.topProjects.map { "\($0.name) \(cores($0.cpuPercent))" }.joined(separator: ", ")
                let cells = [clock(row.start), percent(row.cpuPercent), percent(row.cpuPeakPercent), row.thermalState,
                             bytes(row.swapUsedBytes), projects, row.events.joined(separator: "; ")]
                lines.append("| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |")
            }
        }

        lines += ["", "## Actions", ""]
        if report.actions.isEmpty { lines.append("None") }
        for action in report.actions {
            let offered = action.offered.map { " (\($0))" } ?? ""
            let project = action.project.map { " in \($0)" } ?? ""
            lines.append("- \(precise(action.at)) — \(action.action)\(offered): \(action.target.kind) \(action.target.name)\(project) → \(action.outcome)")
        }

        lines += ["", "---", ""]
        lines.append("This report leaves out \(listText(report.leftOut)). HeatLens sees when work started and what started it; "
            + "it doesn't attribute heat or power to individual processes."
            + (report.anonymizedProjects ? " Project names are replaced with Project A, Project B and so on." : ""))
        return lines.joined(separator: "\n") + "\n"
    }

    /// `{"format": "heatlens-incident", "version": 1, …}`: the same redacted content as the Markdown.
    public static func incidentJSON(_ incident: Incident, options: IncidentExportOptions = IncidentExportOptions(),
                                    homeDirectory: String = NSHomeDirectory()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(makeIncidentReport(incident, options: options, homeDirectory: homeDirectory))
    }
}

// MARK: - Redaction

/// Owner decision 5's drop rules, applied after `Sanitizer`, plus the optional project anonymiser.
struct IncidentScrubber {
    let sanitizer: Sanitizer
    /// Lowercased real name → "Project A"; empty unless anonymising.
    private(set) var aliases: [String: String] = [:]
    private var aliasPattern: NSRegularExpression?

    /// One PID, or a list of them: `PID 1`, `PIDs 1, 2 and 3`, `pid=123`, `ppid=77`, `PID: 123`.
    private static let pidList = "\\bp?pids?\\s*[:=]?\\s*\\d+(?:\\s*(?:,|&|\\band\\b)\\s*\\d+)*"
    /// "(PID 19062)" with its leading space, then a bare one with a trailing comma.
    static let parenthesizedPID = RedactionPatterns.compile("\\s*\\(\\s*" + pidList + "\\s*\\)", caseInsensitive: true)
    static let barePID = RedactionPatterns.compile(pidList + ",?\\s*", caseInsensitive: true)
    /// Docker short (12) and full (64) IDs, and any other standalone 12-hex token.
    static let hexID = RedactionPatterns.compile("(?<![0-9A-Za-z])(?:[0-9a-fA-F]{64}|[0-9a-fA-F]{12})(?![0-9A-Za-z])")
    private static let pathRun = "[^\\s,;)\\]\"'>|]*"
    /// A rooted, home-relative or dot-relative path, plus each following space-separated piece
    /// that holds a `/` (`/Users/x/My Project/sub` is one path); or a bare `~`.
    static let rootedPath = RedactionPatterns.compile(
        "(?<![\\w.~-])(?:~|\\.{1,2})?/" + pathRun + "(?:\\s+" + "[^\\s,;)\\]\"'>|/]*/" + pathRun + ")*|(?<![\\w/])~(?![\\w/])")
    /// `C:\Users\x\My Project\y`, with the same swallowing of spaced pieces that hold a `\`.
    static let windowsPath = RedactionPatterns.compile(
        "(?<![A-Za-z0-9])[A-Za-z]:\\\\[^\\s,;)\\]\"'>|]*(?:\\s+[^\\s,;)\\]\"'>|\\\\]*\\\\[^\\s,;)\\]\"'>|]*)*")
    /// A relative path with two or more slashes (`src/app/main.ts`).
    static let relativePath = RedactionPatterns.compile("(?<![\\w./~-])[\\w.-]+(?:/[\\w.-]+){2,}/?")
    /// Newlines and tabs would break a Markdown line, heading or table row.
    static let lineBreaks = RedactionPatterns.compile("[\\t\\n\\r\\u000B\\u000C\\u0085\\u2028\\u2029]+")
    /// `<…>` disappears when Markdown is rendered as HTML, so placeholders use brackets.
    static let placeholders = [("<secret redacted>", "[secret redacted]"), ("<redacted>", "[redacted]"), ("<user>", "[user]"),
                               ("<arguments redacted>", "[arguments redacted]")]

    init(homeDirectory: String) {
        sanitizer = Sanitizer(homeDirectory: homeDirectory)
    }

    /// Project names in order of first appearance become "Project A", "Project B"… Names that
    /// differ only in case are one project with one alias.
    mutating func anonymize(_ names: [String]) {
        var ordered: [String] = []
        for raw in names {
            let name = sanitizer.projectName(raw).lowercased()
            guard !name.isEmpty, !ordered.contains(name) else { continue }
            ordered.append(name)
        }
        aliases = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, "Project " + Self.letters($0)) })
        // Longest first, so "example-api" is replaced whole, not as "example" plus "-api"; ties by
        // name, so the pattern is the same on every run.
        let alternation = ordered.sorted { ($0.count, $1) > ($1.count, $0) }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // A trailing digit run stays outside the match, so "heatlens2" becomes "Project A2".
        aliasPattern = ordered.isEmpty ? nil
            : RedactionPatterns.compile("(?<![A-Za-z0-9])(?:" + alternation + ")(?=[0-9]*(?![A-Za-z0-9]))", caseInsensitive: true)
    }

    /// A, B … Z, AA, AB …
    static func letters(_ index: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var value = index
        var result = ""
        repeat {
            result = String(alphabet[value % 26]) + result
            value = value / 26 - 1
        } while value >= 0
        return result
    }

    func text(_ raw: String) -> String {
        var value = RedactionPatterns.replacing(Self.lineBreaks, in: raw, with: " ")
        value = sanitizer.text(value)
        value = RedactionPatterns.replacing(Self.parenthesizedPID, in: value, with: "")
        value = RedactionPatterns.replacing(Self.barePID, in: value, with: "")
        value = RedactionPatterns.replacing(Self.hexID, in: value, with: "[id]")
        value = RedactionPatterns.replacing(Self.windowsPath, in: value, with: "[path]")
        value = RedactionPatterns.replacing(Self.rootedPath, in: value, with: "[path]")
        value = RedactionPatterns.replacing(Self.relativePath, in: value, with: "[path]")
        for (angled, bracketed) in Self.placeholders {
            value = value.replacingOccurrences(of: angled, with: bracketed)
        }
        if let aliasPattern {
            let source = value as NSString
            var result = ""
            var last = 0
            for match in aliasPattern.matches(in: value, range: NSRange(location: 0, length: source.length)) {
                result += source.substring(with: NSRange(location: last, length: match.range.location - last))
                let found = source.substring(with: match.range)
                result += aliases[found.lowercased()] ?? found
                last = match.range.location + match.range.length
            }
            value = result + source.substring(from: last)
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    func projectName(_ raw: String) -> String {
        let name = sanitizer.projectName(raw)
        return aliases[name.lowercased()] ?? text(name)
    }

    func evidence(_ evidence: Evidence) -> RedactedIncidentEvidence {
        let context = (evidence.label + " " + evidence.source).lowercased()
        let value = context.contains("argv") || context.contains("argument") ? "[arguments redacted]" : text(evidence.value)
        return RedactedIncidentEvidence(label: text(evidence.label), value: value, source: text(evidence.source))
    }
}

struct RedactedIncident: Codable {
    struct Window: Codable {
        let start: Date
        let end: Date
    }

    struct Context: Codable {
        let worstThermalState: String
        let worstMemoryPressure: String
        let averageCPUPercent: Double?
        let peakCPUPercent: Double?
        let peakSwapUsedBytes: UInt64?
        let peakCPUTemperatureCelsius: Double?
        let averageSystemWatts: Double?
        let peakSystemWatts: Double?
    }

    struct Observation: Codable {
        let at: Date
        let label: String
        let value: String
        let source: String
    }

    struct Explanation: Codable {
        let title: String
        let startedAt: Date
        let endedAt: Date?
        let confidence: String
        let projects: [String]
        let agents: [String]
        let observations: [Observation]
        let uncertainty: [String]
        let recommendation: String
    }

    struct Alert: Codable {
        let firedAt: Date
        let title: String
        let observations: [RedactedIncidentEvidence]
        let projects: [String]
        let suggestion: String
    }

    struct ProjectShare: Codable {
        let name: String
        /// Percent of one core.
        let cpuPercent: Double
    }

    struct Row: Codable {
        let start: Date
        /// Percent of all cores.
        let cpuPercent: Double
        let cpuPeakPercent: Double
        let thermalState: String
        let swapUsedBytes: UInt64
        let topProjects: [ProjectShare]
        let events: [String]
    }

    struct Target: Codable {
        /// "process", "container" or "project".
        let kind: String
        let name: String
    }

    struct Action: Codable {
        let at: Date
        let action: String
        let offered: String?
        let outcome: String
        let target: Target
        let project: String?
    }

    var format = "heatlens-incident"
    var version = 1
    let kind: String
    let title: String
    let summary: String
    let startedAt: Date
    let endedAt: Date?
    let window: Window
    let anonymizedProjects: Bool
    let context: Context
    /// The busiest moment's projects; empty for other kinds.
    let busiestProjects: [ProjectShare]
    let explanations: [Explanation]
    let alerts: [Alert]
    let bucketSeconds: TimeInterval
    let timeline: [Row]
    let actions: [Action]
    let leftOut: [String]
}

struct RedactedIncidentEvidence: Codable {
    let label: String
    let value: String
    let source: String
}

private extension Redactor {
    static func makeIncidentReport(_ incident: Incident, options: IncidentExportOptions, homeDirectory: String) -> RedactedIncident {
        var scrubber = IncidentScrubber(homeDirectory: homeDirectory)
        let peakProjects: [HistoryProjectPoint] = if case .busiestMoment(let peak) = incident.trigger {
            Array(peak.projects.filter(\.isNamedProject).prefix(3))
        } else {
            []
        }
        if options.anonymizeProjects {
            // The order the reports show them in.
            var names = peakProjects.map(\.name)
            names += incident.explanations.flatMap(\.projects)
            names += incident.alerts.flatMap(\.projects)
            names += incident.timeline.flatMap { row in
                row.topProjects.filter(\.isNamedProject).map(\.name) + row.events.compactMap(\.projectName)
            }
            names += incident.actions.flatMap { record -> [String] in
                var names: [String] = []
                if case .project(let name) = record.target { names.append(name) }
                if case .container(_, _, _, let compose?) = record.target { names.append(compose) }
                return names + [record.projectName].compactMap { $0 }
            }
            scrubber.anonymize(names)
        }
        let share = { (point: HistoryProjectPoint) in
            RedactedIncident.ProjectShare(name: point.isNamedProject ? scrubber.projectName(point.name) : point.name,
                                          cpuPercent: tenths(point.cpuPercent))
        }

        let title: String
        let summary: String
        switch incident.trigger {
        case .explanation(let explanation):
            title = scrubber.text(explanation.title)
            summary = "\(title). Confidence \(explanation.confidence.rawValue). \(scrubber.text(explanation.recommendation))"
        case .alert(let alert):
            title = scrubber.text(alert.title)
            summary = "Alert: \(title). \(scrubber.text(alert.suggestion))"
        case .busiestMoment(let peak):
            title = "busiest moment, \(percent(peak.point.hostBusyPeak * 100)) of all cores"
            let names = peakProjects.map { share($0).name }
            summary = "The busiest moment in the timeline: \(percent(peak.point.hostBusyPeak * 100)) of all cores, thermal state "
                + peak.point.thermalState.rawValue + (names.isEmpty ? "." : ", busiest \(listText(names)).")
        }

        let context = incident.context
        return RedactedIncident(
            kind: incident.kind.rawValue,
            title: title,
            summary: summary,
            startedAt: incident.startedAt,
            endedAt: incident.endedAt,
            window: .init(start: incident.windowStart, end: incident.windowEnd),
            anonymizedProjects: options.anonymizeProjects,
            context: .init(worstThermalState: context.worstThermalState.rawValue,
                           worstMemoryPressure: context.worstMemoryPressure.rawValue,
                           averageCPUPercent: context.averageBusyFraction.map { tenths($0 * 100) },
                           peakCPUPercent: context.peakBusyFraction.map { tenths($0 * 100) },
                           peakSwapUsedBytes: context.peakSwapUsedBytes,
                           peakCPUTemperatureCelsius: context.peakCPUTemperatureCelsius.map(tenths),
                           averageSystemWatts: context.averageSystemWatts.map(tenths),
                           peakSystemWatts: context.peakSystemWatts.map(tenths)),
            busiestProjects: peakProjects.map(share),
            explanations: incident.explanations.map { explanation in
                var agents: [String] = []
                for tree in explanation.agentTrees where tree.isAgent && !agents.contains(scrubber.text(tree.name)) {
                    agents.append(scrubber.text(tree.name))
                }
                return .init(title: scrubber.text(explanation.title),
                             startedAt: explanation.startedAt,
                             endedAt: explanation.endedAt,
                             confidence: explanation.confidence.rawValue,
                             projects: explanation.projects.map(scrubber.projectName),
                             agents: agents,
                             observations: explanation.observations.map { observation in
                                 let evidence = scrubber.evidence(observation.evidence)
                                 return .init(at: observation.timestamp, label: evidence.label, value: evidence.value, source: evidence.source)
                             },
                             uncertainty: explanation.uncertainty.map(scrubber.text),
                             recommendation: scrubber.text(explanation.recommendation))
            },
            alerts: incident.alerts.map { alert in
                .init(firedAt: alert.firedAt, title: scrubber.text(alert.title), observations: alert.observations.map(scrubber.evidence),
                      projects: alert.projects.map(scrubber.projectName), suggestion: scrubber.text(alert.suggestion))
            },
            bucketSeconds: incident.bucketSeconds,
            timeline: incident.timeline.map { row in
                .init(start: row.start, cpuPercent: tenths(row.hostBusyFraction * 100), cpuPeakPercent: tenths(row.hostBusyPeak * 100),
                      thermalState: row.thermalState.rawValue, swapUsedBytes: row.swapUsedBytes,
                      topProjects: row.topProjects.map(share), events: row.events.map { scrubber.text($0.title) })
            },
            actions: incident.actions.map { record in
                let target: RedactedIncident.Target = switch record.target {
                case .process(_, _, let name): .init(kind: "process", name: scrubber.text(name))
                case .container(_, let name, _, _): .init(kind: "container", name: scrubber.text(name))
                case .project(let name): .init(kind: "project", name: scrubber.projectName(name))
                }
                return .init(at: record.at, action: record.action.rawValue, offered: record.offered?.rawValue,
                             outcome: scrubber.text(record.outcome), target: target, project: record.projectName.map(scrubber.projectName))
            },
            leftOut: incidentLeftOut)
    }

    static func contextLines(_ context: RedactedIncident.Context) -> [String] {
        var parts: [String] = []
        if let average = context.averageCPUPercent, let peak = context.peakCPUPercent {
            parts.append("CPU \(percent(average)) average, \(percent(peak)) peak of all cores")
        }
        parts.append("thermal state at worst \(context.worstThermalState)")
        if let celsius = context.peakCPUTemperatureCelsius { parts.append("CPU up to \(IncidentBuilder.wholeNumber(celsius.rounded())) °C") }
        if let swap = context.peakSwapUsedBytes { parts.append("swap up to \(bytes(swap))") }
        parts.append("memory pressure at worst \(context.worstMemoryPressure)")
        if let average = context.averageSystemWatts, let peak = context.peakSystemWatts {
            parts.append(String(format: "system power %.1f W average, %.1f W peak", average, peak))
        }
        return ["- In the window: " + parts.joined(separator: "; ")]
    }

    /// Reports carry one decimal: `449.99999999999994` reads as noise (and as a long digit run).
    /// NaN and ±∞ become 0, since JSON can't carry them; values past ±1e15 are clamped.
    static func tenths(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (min(max(value, -1e15), 1e15) * 10).rounded() / 10
    }
    static func percent(_ value: Double) -> String { "\(IncidentBuilder.wholeNumber(tenths(value).rounded()))%" }
    static func cores(_ cpuPercentOfOneCore: Double) -> String { String(format: "%.1f cores", tenths(cpuPercentOfOneCore) / 100) }
    static func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory) }

    static func listText(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// "14:02:07" on the window's first day, "Oct 26 14:02:07" after it.
    static func secondsClock(_ date: Date, observedAt: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: observedAt) ? "HH:mm:ss" : "MMM d HH:mm:ss"
        return formatter.string(from: date)
    }

    /// "2026-10-28 14:02 GMT+1".
    static func longClock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter.string(from: date)
    }
}

private extension HistoryProjectPoint {
    /// Not the Docker VM or Unattributed rows, whose names are HeatLens's own.
    var isNamedProject: Bool { projectID != "docker-vm" && projectID != "unattributed" }
}
