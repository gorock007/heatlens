import Foundation
import Testing
@testable import HeatLensCore

/// Synthetic, FDA-shaped (PHASE-3-REPORT Run 2): two agent trees in two projects, two containers,
/// one alert, a stop and a container stop. Every name and path here is made up.
private enum IncidentFixture {
    static let home = "/Users/hlfixture"
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let token = "--token=s3cr3tvalue"
    static let fullContainerID = String(repeating: "ab12", count: 16)
    static let shortContainerID = "a1b2c3d4e5f6"
    static let realNames = ["orbit-api", "lumen-web"]

    static let explanation = Explanation(
        id: "burst-1",
        title: "4 test runs began within 30 s across 2 agent trees (claude, codex) across 2 projects (lumen-web, orbit-api), "
            + "plus 2 containers, from \(home)/Developer/orbit-api \(token)",
        observations: [
            observation(5, "npm test started", "PID 19389, in orbit-api, under claude (PID 19062)"),
            observation(8, "pytest started", "PID 19410, in lumen-web, under codex (PID 18800)"),
            observation(12, "Container orbit-api-db-1 started", "in orbit-api", source: "Docker; project from compose label"),
            observation(14, "Container lumen-web-cache-1 started", "in lumen-web, id \(shortContainerID)",
                        source: "Docker; project from compose label"),
            observation(20, "cargo test started", "PID 19500, in orbit-api at \(home)/Developer/orbit-api, under claude (PID 19062)"),
        ],
        confidence: .high,
        uncertainty: ["HeatLens sees when these started and what started them, not how much heat or power each one causes."],
        recommendation: "These test runs compete for the same CPU cores and the Docker VM. Run them one at a time, or have the agents take turns.",
        startedAt: t0, endedAt: t0 + 180,
        projects: ["lumen-web", "orbit-api"],
        agentTrees: [.init(name: "claude", root: ProcessIdentity(pid: 19062, startTimeMicros: 1)),
                     .init(name: "codex", root: ProcessIdentity(pid: 18800, startTimeMicros: 2))],
        affected: [ProcessIdentity(pid: 19389, startTimeMicros: 3), ProcessIdentity(pid: 19410, startTimeMicros: 4)],
        containerIDs: [fullContainerID, shortContainerID])

    /// Overlaps the window's end.
    static let laterExplanation = Explanation(
        id: "burst-2", title: "2 builds began within 30 s in orbit-api", observations: [observation(250, "swift build started", "PID 20001, in orbit-api")],
        confidence: .medium, uncertainty: ["1 of the 2 commands couldn't be tied to a project folder."],
        recommendation: "Let one finish before starting the next.", startedAt: t0 + 250, endedAt: t0 + 400,
        projects: ["orbit-api"], agentTrees: [.noAgent], affected: [], containerIDs: [])

    /// Over before the window opens.
    static let earlierExplanation = Explanation(
        id: "burst-0", title: "Old burst nobody should see", observations: [], confidence: .low, uncertainty: [],
        recommendation: "", startedAt: t0 - 3_600, endedAt: t0 - 3_500, projects: ["orbit-api"], agentTrees: [], affected: [],
        containerIDs: [])

    static let alert = Alert(
        id: "alert-1", rule: .sustainedCPU, firedAt: t0 + 60, title: "CPU above 80% for 2 minutes",
        observations: [Evidence(label: "CPU now", value: "92% (9.2 of 10 cores)", source: "host_processor_info"),
                       Evidence(label: "Busiest projects", value: "orbit-api, lumen-web", source: "Live updates"),
                       Evidence(label: "Held", value: "2 min, under \(home)/Developer \(token)", source: "Live updates")],
        projects: ["orbit-api", "lumen-web"], suggestion: "Pause one project's tests.")

    static let lateAlert = Alert(id: "alert-2", rule: .swap, firedAt: t0 + 900, title: "Late swap alert nobody should see",
                                 observations: [], projects: [], suggestion: "")

    static let actions = [
        ActionRecord(at: t0 + 90, action: .stopRequested, target: .process(pid: 19389, startTimeMicros: 3, name: "npm test"),
                     projectName: "orbit-api", origin: .processDetail, confirmedAt: t0 + 89, signalSentAt: t0 + 90,
                     outcome: "stillRunning", detail: "at \(home)/Developer/orbit-api"),
        ActionRecord(at: t0 + 120, action: .containerStop,
                     target: .container(shortID: shortContainerID, name: "orbit-api-db-1", image: "registry.example/orbit/db:16",
                                        composeProject: "orbit-api"),
                     projectName: "orbit-api", origin: .containerDetail, confirmedAt: t0 + 118, signalSentAt: t0 + 119,
                     outcome: "stopped", detail: nil),
        ActionRecord(at: t0 + 1_000, action: .ignored, target: .project(name: "late-project"), projectName: "late-project",
                     origin: .projectRow, confirmedAt: t0 + 1_000, signalSentAt: nil, outcome: "ignored", detail: nil),
    ]

    /// A tick every 10 s from 10 minutes before to 15 minutes after t0.
    static func timeline(from start: Date = t0 - 600, to end: Date = t0 + 900, step: TimeInterval = 10) -> HistoryWindow {
        var points: [HistoryPoint] = []
        var projects: [HistoryProjectPoint] = []
        for at in stride(from: start.timeIntervalSince1970, through: end.timeIntervalSince1970, by: step).map(Date.init(timeIntervalSince1970:)) {
            let busy = at >= t0 && at <= t0 + 180 ? 0.9 : 0.2
            points.append(HistoryPoint(timestamp: at, thermalState: busy > 0.5 ? .serious : .nominal, hostBusyFraction: busy,
                                       swapUsedBytes: 1 << 30, memoryPressure: .normal, cpuTemperatureCelsius: 80,
                                       systemWatts: 20, processWatts: 15))
            projects += [
                HistoryProjectPoint(timestamp: at, projectID: "/users/hlfixture/developer/orbit-api", name: "orbit-api",
                                    cpuPercent: 500 * busy, memoryBytes: 1 << 30, watts: nil),
                HistoryProjectPoint(timestamp: at, projectID: "/users/hlfixture/developer/lumen-web", name: "lumen-web",
                                    cpuPercent: 300 * busy, memoryBytes: 1 << 29, watts: nil),
                HistoryProjectPoint(timestamp: at, projectID: "docker-vm", name: "Docker VM", cpuPercent: 100 * busy,
                                    memoryBytes: 1 << 31, watts: nil),
            ]
        }
        let events = [
            TimelineEvent(timestamp: t0 - 400, kind: .testRunStarted, title: "Early event nobody should see"),
            TimelineEvent(timestamp: t0 + 5, kind: .testRunStarted, title: "npm test (PID 19389) in \(home)/Developer/orbit-api",
                          projectName: "orbit-api"),
            TimelineEvent(timestamp: t0 + 12, kind: .containerStarted, title: "orbit-api-db-1 (\(shortContainerID)) started",
                          projectName: "orbit-api"),
            explanation.timelineEvent(at: t0 + 30),
        ]
        return HistoryWindow(points: points, projects: projects, events: events)
    }

    static func incident(now: Date = t0 + 2_000) -> Incident {
        IncidentBuilder.incident(from: explanation, timeline: timeline(), alerts: [alert, lateAlert],
                                 explanations: [earlierExplanation, laterExplanation], actions: actions, now: now)
    }

    private static func observation(_ offset: TimeInterval, _ label: String, _ value: String,
                                    source: String = "process start time and parent tree") -> Explanation.Observation {
        Explanation.Observation(timestamp: t0 + offset, evidence: Evidence(label: label, value: value, source: source))
    }
}

@Suite("Incident report")
struct IncidentReportTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func outputs(_ incident: Incident, anonymize: Bool) throws -> (markdown: String, json: String, data: Data) {
        let options = IncidentExportOptions(anonymizeProjects: anonymize)
        let markdown = Redactor.incidentMarkdown(incident, options: options, homeDirectory: IncidentFixture.home, timeZone: utc)
        let data = try Redactor.incidentJSON(incident, options: options, homeDirectory: IncidentFixture.home)
        return (markdown, try #require(String(data: data, encoding: .utf8)), data)
    }

    private func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    @Test("Neither output holds a PID, a hex ID, the home directory, a rooted path or the token")
    func dropsSensitiveData() throws {
        for anonymize in [false, true] {
            let (markdown, json, _) = try outputs(IncidentFixture.incident(), anonymize: anonymize)
            for report in [markdown, json] {
                #expect(!matches("(?i)\\bpid", report))
                #expect(!matches("(?<![0-9A-Za-z])[0-9a-fA-F]{12,}(?![0-9A-Za-z])", report))
                #expect(!report.contains(IncidentFixture.home))
                #expect(!report.contains("hlfixture"))
                #expect(!matches("(^|[\\s\"'(])~?/\\w", report))
                #expect(!report.contains("~/"))
                #expect(!report.contains("s3cr3tvalue"))
                #expect(!report.contains("registry.example"))
                #expect(!report.contains("19062") && !report.contains("19389"))
            }
        }
    }

    @Test("Names, explanation text, alerts and actions are kept")
    func keepsNames() throws {
        let (markdown, json, _) = try outputs(IncidentFixture.incident(), anonymize: false)
        for report in [markdown, json] {
            for name in IncidentFixture.realNames + ["claude", "codex", "orbit-api-db-1", "npm test", "CPU above 80% for 2 minutes"] {
                #expect(report.contains(name), "missing \(name)")
            }
            #expect(report.contains("in orbit-api, under claude"))
            #expect(report.contains("stillRunning"))
        }
        #expect(markdown.contains("Confidence: high"))
        #expect(markdown.contains("doesn't attribute heat or power to individual processes"))
    }

    @Test("Anonymised names match across Markdown and JSON, with no real name left")
    func anonymizesConsistently() throws {
        let (markdown, json, data) = try outputs(IncidentFixture.incident(), anonymize: true)
        for report in [markdown, json] {
            for name in IncidentFixture.realNames { #expect(!report.lowercased().contains(name), "\(name) left") }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(RedactedIncident.self, from: data)
        // First appearance: the trigger's projects, sorted (lumen-web, orbit-api).
        #expect(report.explanations.first?.projects == ["Project A", "Project B"])
        #expect(report.alerts.first?.projects == ["Project B", "Project A"])
        #expect(report.actions.map(\.project) == ["Project B", "Project B"])
        #expect(report.actions.last?.target.name == "Project B-db-1")
        #expect(report.anonymizedProjects)
        for text in report.explanations.map(\.title) + report.alerts.flatMap({ $0.observations.map(\.value) })
            + report.explanations.flatMap({ $0.observations.map(\.value) }) {
            #expect(markdown.contains(text), "Markdown lacks \(text)")
        }
        #expect(markdown.contains("in Project B, under claude"))
        #expect(markdown.contains("Project B-db-1"))
        #expect(markdown.contains("Docker VM"))
    }

    @Test("The JSON decodes, with its format and version")
    func jsonDecodes() throws {
        let (_, _, data) = try outputs(IncidentFixture.incident(), anonymize: false)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["format"] as? String == "heatlens-incident")
        #expect(object["version"] as? Int == 1)
        #expect(object["kind"] as? String == "explanation")
        #expect((object["leftOut"] as? [String])?.isEmpty == false)
    }

    @Test("Only what overlaps 2 minutes either side is kept")
    func windowFilter() throws {
        let t0 = IncidentFixture.t0
        let incident = IncidentFixture.incident()
        #expect(incident.windowStart == t0 - 120)
        #expect(incident.windowEnd == t0 + 300)
        #expect(incident.explanations.map(\.id) == ["burst-1", "burst-2"])
        #expect(incident.alerts.map(\.id) == ["alert-1"])
        #expect(incident.actions.count == 2)
        #expect(incident.bucketSeconds == 60)
        #expect(incident.timeline.count == 7)
        #expect(incident.timeline.first?.start == t0 - 120)
        #expect(incident.timeline.flatMap(\.events).count == 3)
        #expect(incident.timeline.allSatisfy { $0.topProjects.count == 3 })
        #expect(incident.context.worstThermalState == .serious)

        let (markdown, json, _) = try outputs(incident, anonymize: false)
        for report in [markdown, json] {
            #expect(!report.contains("nobody should see"))
            #expect(!report.contains("late-project"))
        }

        // Still running: the window ends now.
        let running = IncidentBuilder.incident(
            from: Explanation(id: "r", title: "running", observations: [], confidence: .low, uncertainty: [], recommendation: "",
                              startedAt: t0, projects: [], agentTrees: [], affected: [], containerIDs: []),
            timeline: IncidentFixture.timeline(), now: t0 + 60)
        #expect(running.windowEnd == t0 + 60)
        #expect(running.endedAt == nil)
        #expect(Redactor.incidentMarkdown(running, homeDirectory: IncidentFixture.home, timeZone: utc).contains("still running"))
    }

    @Test("Alert and busiest-moment incidents centre on their moment")
    func otherTriggers() throws {
        let t0 = IncidentFixture.t0
        let fromAlert = IncidentBuilder.incident(from: IncidentFixture.alert, timeline: IncidentFixture.timeline(), now: t0 + 2_000)
        #expect(fromAlert.windowStart == t0 - 60 && fromAlert.windowEnd == t0 + 180)
        #expect(fromAlert.alerts.map(\.id) == ["alert-1"])

        let window = IncidentFixture.timeline()
        let peak = try #require(TimelineAnalysis.peak(in: window))
        let fromPeak = IncidentBuilder.incident(from: peak, timeline: window, now: t0 + 2_000)
        #expect(fromPeak.kind == .busiestMoment)
        let (markdown, json, _) = try outputs(fromPeak, anonymize: true)
        #expect(markdown.contains("busiest moment, 90% of all cores"))
        #expect(markdown.contains("Busiest projects at that moment: Project A"))
        for report in [markdown, json] {
            for name in IncidentFixture.realNames { #expect(!report.contains(name)) }
        }
    }

    @Test("An empty section says None")
    func emptySections() {
        let incident = IncidentBuilder.incident(from: IncidentFixture.alert, timeline: .empty, now: IncidentFixture.t0 + 2_000)
        let markdown = Redactor.incidentMarkdown(incident, homeDirectory: IncidentFixture.home, timeZone: utc)
        for section in ["Observations", "Uncertainty", "Timeline", "Actions"] {
            #expect(markdown.contains("## \(section)\n\nNone\n"), "\(section) isn't None")
        }
        #expect(!markdown.contains("## Alerts\n\nNone"))
    }

    @Test("A week-long window is capped at 120 timeline rows")
    func weekLongWindow() throws {
        let t0 = IncidentFixture.t0
        let week: TimeInterval = 7 * 24 * 3_600
        let long = Explanation(id: "week", title: "A long burst in orbit-api", observations: [], confidence: .low, uncertainty: [],
                               recommendation: "", startedAt: t0, endedAt: t0 + week, projects: ["orbit-api"], agentTrees: [],
                               affected: [], containerIDs: [])
        let incident = IncidentBuilder.incident(from: long, timeline: IncidentFixture.timeline(from: t0 - 600, to: t0 + week + 600, step: 60),
                                                now: t0 + week + 3_600)
        #expect(incident.timeline.count <= IncidentBuilder.timelineRowLimit)
        #expect(incident.timeline.count >= 100)
        #expect(incident.bucketSeconds > 60)
        let markdown = Redactor.incidentMarkdown(incident, homeDirectory: IncidentFixture.home, timeZone: utc)
        let rows = markdown.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Time") }
        #expect(rows.count == incident.timeline.count)
        #expect(rows.count <= 120)
    }

    // MARK: - Review fixes

    private func scrubbed(_ raw: String, anonymizing names: [String] = []) -> String {
        var scrubber = IncidentScrubber(homeDirectory: IncidentFixture.home)
        if !names.isEmpty { scrubber.anonymize(names) }
        return scrubber.text(raw)
    }

    private func decoded(_ data: Data) throws -> RedactedIncident {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RedactedIncident.self, from: data)
    }

    @Test("A project named only by a timeline event is anonymised too")
    func eventOnlyProject() throws {
        let base = IncidentFixture.timeline()
        let event = TimelineEvent(timestamp: IncidentFixture.t0 + 40, kind: .containerStarted, title: "secretproj-db-1 started",
                                  projectName: "secretproj")
        let window = HistoryWindow(points: base.points, projects: base.projects, events: base.events + [event])
        let incident = IncidentBuilder.incident(from: IncidentFixture.explanation, timeline: window, now: IncidentFixture.t0 + 2_000)
        let (markdown, json, _) = try outputs(incident, anonymize: true)
        for report in [markdown, json] {
            #expect(!report.lowercased().contains("secretproj"))
            #expect(report.contains("Project C-db-1 started"))
        }
    }

    @Test("PIDs go in every spelling: lists, key=value, colon, ppid", arguments: [
        ("Stopped PIDs 1, 2 and 3 today", "Stopped today"),
        ("saw pids 11, 22, 33 here", "saw here"),
        ("child pid=123 exited", "child exited"),
        ("parent ppid=77 lives", "parent lives"),
        ("PID: 123 is busy", "is busy"),
        ("under claude (PID 19062)", "under claude"),
        ("under codex (pids 4, 5 & 6)", "under codex"),
        ("PID 19389, in orbit-api", "in orbit-api"),
    ])
    func pidSpellings(raw: String, expected: String) {
        let result = scrubbed(raw)
        #expect(result == expected)
        #expect(!result.lowercased().contains("pid"))
    }

    @Test("Names differing only in case share one alias, the same in Markdown and JSON, every run")
    func caseVariantNames() throws {
        let t0 = IncidentFixture.t0
        let explanation = Explanation(id: "c", title: "2 builds began within 30 s in Foo", observations: [], confidence: .medium,
                                      uncertainty: [], recommendation: "", startedAt: t0, endedAt: t0 + 30, projects: ["Foo"],
                                      agentTrees: [], affected: [], containerIDs: [])
        let alert = Alert(id: "a", rule: .sustainedCPU, firedAt: t0 + 10, title: "CPU above 80% for 2 minutes",
                          observations: [Evidence(label: "Busiest project", value: "foo", source: "Live updates")],
                          projects: ["foo"], suggestion: "Pause FOO.")
        let window = HistoryWindow(
            points: [HistoryPoint(timestamp: t0, thermalState: .nominal, hostBusyFraction: 0.5, swapUsedBytes: 0, memoryPressure: .normal,
                                  cpuTemperatureCelsius: nil, systemWatts: nil, processWatts: nil)],
            projects: [HistoryProjectPoint(timestamp: t0, projectID: "/x/foo", name: "FOO", cpuPercent: 100, memoryBytes: 0, watts: nil)],
            events: [])
        let incident = IncidentBuilder.incident(from: explanation, timeline: window, alerts: [alert], now: t0 + 1_000)
        let first = try outputs(incident, anonymize: true)
        let second = try outputs(incident, anonymize: true)
        #expect(first.markdown == second.markdown)
        #expect(first.json == second.json)
        for report in [first.markdown, first.json] {
            #expect(!report.lowercased().contains("foo"))
            // The footer names "Project A, Project B and so on"; no field may.
            #expect(!report.replacingOccurrences(of: "Project A, Project B and so on", with: "").contains("Project B"))
        }
        let report = try decoded(first.data)
        #expect(report.explanations.first?.projects == ["Project A"])
        #expect(report.alerts.first?.projects == ["Project A"])
        #expect(report.alerts.first?.suggestion == "Pause Project A.")
        #expect(report.timeline.first?.topProjects.first?.name == "Project A")
        #expect(first.markdown.contains("Pause Project A."))
    }

    @Test("Paths with spaces and Windows paths leave no fragment", arguments: [
        ("open /Users/other/My Project/sub/file.txt now", "open [path] now"),
        ("in ~/Documents/a b/c today", "in [path] today"),
        ("at C:\\Users\\other\\My Project\\file.txt now", "at [path] now"),
        ("cwd \(IncidentFixture.home)/My Project/sub", "cwd [path]"),
    ])
    func spacedPaths(raw: String, expected: String) {
        #expect(scrubbed(raw) == expected)
    }

    @Test("A name followed by digits is still replaced")
    func aliasDigitSuffix() {
        let result = scrubbed("heatlens2 and heatlens-x, heatlens42; not heatlensx", anonymizing: ["heatlens"])
        #expect(result == "Project A2 and Project A-x, Project A42; not heatlensx")
    }

    @Test("Markdown keeps every field on one line, and placeholders survive HTML rendering")
    func markdownSafety() throws {
        let t0 = IncidentFixture.t0
        let explanation = Explanation(
            id: "n", title: "Burst\nin orbit-api\t| now", observations: [
                .init(timestamp: t0 + 1, evidence: Evidence(label: "npm\ntest started", value: "in\r\norbit-api", source: "tree"))],
            confidence: .low, uncertainty: ["two\nlines"], recommendation: "Wait.\nThen retry.", startedAt: t0, endedAt: t0 + 30,
            projects: ["orbit-api"], agentTrees: [], affected: [], containerIDs: [])
        let base = IncidentFixture.timeline()
        let window = HistoryWindow(points: base.points, projects: base.projects,
                                   events: [TimelineEvent(timestamp: t0 + 2, kind: .testRunStarted, title: "multi\nline | event")])
        let incident = IncidentBuilder.incident(from: explanation, timeline: window, now: t0 + 1_000)
        let markdown = Redactor.incidentMarkdown(incident, homeDirectory: IncidentFixture.home, timeZone: utc)
        #expect(markdown.contains("# HeatLens incident: Burst in orbit-api | now\n"))
        #expect(markdown.contains("### Burst in orbit-api | now\n"))
        #expect(markdown.contains("npm test started: in orbit-api (tree)"))
        #expect(markdown.contains("- two lines\n"))
        #expect(markdown.contains("multi line \\| event"))
        let rows = markdown.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Time") }
        #expect(rows.count == incident.timeline.count)
        #expect(!markdown.contains("\t") && !markdown.contains("\r"))

        let (fixtureMarkdown, fixtureJSON, _) = try outputs(IncidentFixture.incident(), anonymize: false)
        for report in [fixtureMarkdown, fixtureJSON] {
            #expect(report.contains("[path]") && report.contains("[id]") && report.contains("[secret redacted]"))
            for angled in ["<path>", "<id>", "<user>", "<secret redacted>", "<redacted>"] { #expect(!report.contains(angled)) }
        }
    }

    @Test("A negative or non-finite margin is treated as none, never a trap")
    func badMargins() throws {
        let t0 = IncidentFixture.t0
        let window = IncidentFixture.timeline()
        for margin in [-500, -.infinity, .infinity, .nan] as [TimeInterval] {
            let fromExplanation = IncidentBuilder.incident(from: IncidentFixture.explanation, timeline: window, margin: margin, now: t0 + 2_000)
            #expect(fromExplanation.windowStart == t0 && fromExplanation.windowEnd == t0 + 180)
            let fromAlert = IncidentBuilder.incident(from: IncidentFixture.alert, timeline: window, margin: margin, now: t0 + 2_000)
            #expect(fromAlert.windowStart == t0 + 60 && fromAlert.windowEnd == t0 + 60)
            let peak = try #require(TimelineAnalysis.peak(in: window))
            let fromPeak = IncidentBuilder.incident(from: peak, timeline: window, margin: margin, now: t0 + 2_000)
            #expect(fromPeak.windowStart == fromPeak.windowEnd)
            _ = Redactor.incidentMarkdown(fromAlert, homeDirectory: IncidentFixture.home, timeZone: utc)
        }
    }

    @Test("NaN, infinite and huge measurements export as numbers, never a trap")
    func nonFiniteValues() throws {
        let t0 = IncidentFixture.t0
        let values: [Double] = [.nan, .infinity, -.infinity, 1e300]
        let points = values.enumerated().map { index, value in
            HistoryPoint(timestamp: t0 + Double(index) * 10, thermalState: .fair, hostBusyFraction: value, hostBusyPeak: value,
                         swapUsedBytes: .max, memoryPressure: .warning, cpuTemperatureCelsius: value, systemWatts: value, processWatts: value)
        }
        let projects = values.enumerated().map { index, value in
            HistoryProjectPoint(timestamp: t0 + Double(index) * 10, projectID: "/x/orbit-api", name: "orbit-api", cpuPercent: value,
                                memoryBytes: .max, watts: value)
        }
        let window = HistoryWindow(points: points, projects: projects, events: [])
        let peak = TimelineAnalysis.Peak(point: points[1], projects: projects, events: [])
        for incident in [IncidentBuilder.incident(from: peak, timeline: window, now: t0 + 1_000),
                         IncidentBuilder.incident(from: IncidentFixture.explanation, timeline: window, now: t0 + 1_000)] {
            let (markdown, _, data) = try outputs(incident, anonymize: false)
            _ = try decoded(data)
            for token in ["nan", "inf"] { #expect(!markdown.lowercased().contains(token), "\(token) in Markdown") }
        }
    }
}
