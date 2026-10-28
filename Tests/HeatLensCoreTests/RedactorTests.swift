import Foundation
import Testing
@testable import HeatLensCore

@Suite("Redacted export")
struct RedactorTests {
    @Test("Text and JSON remove home paths, extra argv, tokens, and username")
    func privacyRedaction() throws {
        let home = SyntheticSnapshots.home
        let process = SyntheticSnapshots.process(
            pid: 1_000,
            name: "someone-agent",
            executablePath: home + "/bin/agent",
            arguments: [home + "/bin/agent", "--token=abc", "prompt from someone"],
            currentDirectory: home + "/Developer/Secret",
            cpu: 55
        )
        let snapshot = SyntheticSnapshots.snapshot(
            [process],
            notices: ["someone has a path at " + home + "/Developer/Secret"]
        )
        let groups = ProvenanceResolver.resolve(snapshot)
        let plantedFinding = DiagnosticFinding(
            id: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-ADDD-EEEEEEEEEEEE")!,
            title: "Review someone command",
            severity: .review,
            confidence: .medium,
            explanation: "Found " + home + "/Developer/Secret and --token=abc",
            evidence: [Evidence(label: "argv", value: home + "/bin/agent --token=abc", source: "argv")],
            limitations: ["Only someone can decide"],
            affectedProcesses: [process.identity],
            recommendedActions: [.openProject(path: home + "/Developer/Secret"), .copyReport]
        )

        let text = Redactor.textReport(snapshot, groups: groups, findings: [plantedFinding], homeDirectory: home)
        let jsonData = try Redactor.jsonReport(snapshot, groups: groups, findings: [plantedFinding], homeDirectory: home)
        let json = try #require(String(data: jsonData, encoding: .utf8))

        for report in [text, json] {
            #expect(!report.contains(home))
            #expect(!report.contains("--token=abc"))
            #expect(!report.contains("someone"))
            #expect(report.contains("~/Developer/Secret"))
            #expect(report.contains("<2 args redacted>"))
        }
        #expect(try JSONSerialization.jsonObject(with: jsonData) is [String: Any])
    }

    @Test("Nil argv and cwd export as unavailable without crashing")
    func restrictedExport() throws {
        let snapshot = SyntheticSnapshots.restricted
        let groups = ProvenanceResolver.resolve(snapshot)
        let text = Redactor.textReport(snapshot, groups: groups, findings: [], homeDirectory: SyntheticSnapshots.home)
        let json = try Redactor.jsonReport(snapshot, groups: groups, findings: [], homeDirectory: SyntheticSnapshots.home)
        #expect(text.contains("Unknown project"))
        #expect(text.contains("argv Unavailable"))
        #expect(!json.isEmpty)
    }

    @Test("Text lists the top 15 by CPU plus finding processes; JSON keeps everything")
    func conciseText() throws {
        let home = SyntheticSnapshots.home
        let busy = (1...30).map { index in
            SyntheticSnapshots.process(pid: Int32(2_000 + index), name: "busy\(index)",
                                       arguments: [home + "/bin/busy", "--secret=xyz"], cpu: Double(index))
        }
        let idle = SyntheticSnapshots.process(pid: 3_000, ageHours: 48, name: "leftover",
                                              arguments: [home + "/bin/leftover", "someone"],
                                              currentDirectory: home + "/Developer/Old", cpu: 0)
        let unreadable = SyntheticSnapshots.process(pid: 3_001, owner: .root, name: "daemon", cpu: nil,
                                                    detailAccess: .permissionDenied)
        let snapshot = SyntheticSnapshots.snapshot(busy + [idle, unreadable])
        let finding = DiagnosticFinding(title: "Review leftover", severity: .review, confidence: .medium,
                                        explanation: "Idle", evidence: [], limitations: [],
                                        affectedProcesses: [idle.identity], recommendedActions: [])
        let groups = ProvenanceResolver.resolve(snapshot)

        let text = Redactor.textReport(snapshot, groups: groups, findings: [finding], homeDirectory: home)
        let processLines = text.split(separator: "\n").filter { $0.hasPrefix("- PID ") }
        #expect(processLines.count == 16)
        #expect(processLines.first?.contains("PID 2030 busy30") == true)
        #expect(text.contains("PID 2016 busy16"))
        #expect(!text.contains("PID 2015 busy15"))
        #expect(!text.contains("daemon"))
        #expect(text.contains("PID 3000 leftover"))
        #expect(text.contains("16 other processes omitted; Copy JSON for the full list"))
        for leaked in [home, "someone", "--secret=xyz"] { #expect(!text.contains(leaked)) }

        let json = try Redactor.jsonReport(snapshot, groups: groups, findings: [finding], homeDirectory: home)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect((object["processes"] as? [Any])?.count == 32)
    }

    @Test("Text lists at most 5 of a finding's processes, busiest first, and cuts long argv; JSON keeps everything")
    func findingProcessCap() throws {
        let home = SyntheticSnapshots.home
        let longPath = "/opt" + String(repeating: "/abc", count: 99)   // 400 characters
        let busy = (1...20).map { (index: Int) -> ProcessSample in
            let executable: String = index == 20 ? longPath : "/bin/busy"
            return SyntheticSnapshots.process(pid: Int32(4_000 + index), name: "busy\(index)",
                                              arguments: [executable], cpu: Double(50 + index))
        }
        let swarm = (1...20).map { (index: Int) -> ProcessSample in
            SyntheticSnapshots.process(pid: Int32(5_000 + index), name: "swarm\(index)", cpu: Double(index) / 10)
        }
        let unmeasured = SyntheticSnapshots.process(pid: 5_100, name: "swarm-unmeasured", cpu: nil)
        let few = SyntheticSnapshots.process(pid: 5_200, name: "few", cpu: 0)
        let snapshot = SyntheticSnapshots.snapshot(busy + swarm + [unmeasured, few])
        let big = DiagnosticFinding(title: "Many processes", severity: .review, confidence: .medium,
                                    explanation: "Swarm", evidence: [], limitations: [],
                                    affectedProcesses: (swarm + [unmeasured]).map(\.identity), recommendedActions: [])
        let small = DiagnosticFinding(title: "One process", severity: .review, confidence: .medium,
                                      explanation: "Few", evidence: [], limitations: [],
                                      affectedProcesses: [few.identity], recommendedActions: [])
        let groups = ProvenanceResolver.resolve(snapshot)

        let text = Redactor.textReport(snapshot, groups: groups, findings: [big, small], homeDirectory: home)
        let processLines = text.split(separator: "\n").filter { $0.hasPrefix("- PID ") }
        #expect(processLines.count == 21)   // top 15 by CPU, 5 of the swarm, and `few`
        for index in 16...20 { #expect(text.contains("PID \(5_000 + index) swarm\(index);")) }
        for index in 1...15 { #expect(!text.contains("PID \(5_000 + index) swarm\(index);")) }
        #expect(!text.contains("swarm-unmeasured"))
        #expect(text.contains("PID 5200 few"))
        #expect(text.contains("  Processes: 5 of 21 listed; Copy JSON for the full list"))
        #expect(text.components(separatedBy: "  Processes: ").count == 2)   // not under the small finding
        #expect(text.contains("21 other processes omitted; Copy JSON for the full list"))

        let longLine = try #require(processLines.first { $0.contains("PID 4020 ") })
        #expect(longLine.hasSuffix("argv " + String(longPath.prefix(300)) + "… (+100 chars)"))
        #expect(!text.contains(longPath))

        let json = try #require(String(data: try Redactor.jsonReport(snapshot, groups: groups, findings: [big, small],
                                                                     homeDirectory: home), encoding: .utf8))
        #expect(json.contains(longPath))
        #expect(!json.contains("chars)"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((object["processes"] as? [Any])?.count == 42)
    }

    @Test("A small scan lists every process and says nothing is omitted")
    func nothingOmitted() {
        let snapshot = SyntheticSnapshots.detachedWorker
        let text = Redactor.textReport(snapshot, groups: ProvenanceResolver.resolve(snapshot), findings: [],
                                       homeDirectory: SyntheticSnapshots.home)
        #expect(!text.contains("omitted"))
    }

    private func reports(_ snapshot: ScanSnapshot, findings: [DiagnosticFinding], home: String = SyntheticSnapshots.home) throws -> [String] {
        let groups = ProvenanceResolver.resolve(snapshot)
        let text = Redactor.textReport(snapshot, groups: groups, findings: findings, homeDirectory: home)
        let json = try Redactor.jsonReport(snapshot, groups: groups, findings: findings, homeDirectory: home)
        return [text, try #require(String(data: json, encoding: .utf8))]
    }

    @Test("A node script label exports as `node <script>` in groups, titles, explanations and evidence")
    func scriptLabel() throws {
        let home = SyntheticSnapshots.home
        let process = SyntheticSnapshots.process(
            pid: 1_100, name: "node", executablePath: "/usr/local/bin/node",
            arguments: ["node", home + "/clients/acme-merger/sync-ghp_FAKETOKEN123.js"],
            currentDirectory: home + "/clients/acme-merger", cpu: 95
        )
        let snapshot = SyntheticSnapshots.snapshot([process])
        let group = try #require(ProvenanceResolver.resolve(snapshot).first { $0.root == process.identity })
        #expect(group.kind == "node script")
        #expect(group.label == "node sync-ghp_FAKETOKEN123.js")   // the app keeps the real label
        let finding = DiagnosticFinding(
            title: "Sustained high CPU: \(group.label)", severity: .high, confidence: .medium,
            explanation: "\(group.label) used 95% of a core.",
            evidence: [Evidence(label: "Group", value: group.label, source: "provenance")],
            limitations: [], affectedProcesses: [process.identity], recommendedActions: [.requestStop(process.identity)]
        )
        for report in try reports(snapshot, findings: [finding]) {
            #expect(!report.contains("FAKETOKEN123"))
            #expect(!report.contains("sync-"))
            #expect(report.contains("Sustained high CPU: node <script>"))
            #expect(report.contains("node <script> used 95% of a core."))
        }
    }

    @Test("Credential-looking path components and secret options are redacted; ordinary text survives")
    func secretsInPathsAndText() throws {
        let home = SyntheticSnapshots.home
        let secretDirectory = home + "/clients/acme-merger/ghp_FAKETOKEN456"
        let process = SyntheticSnapshots.process(
            pid: 1_200, name: "vite", executablePath: "/usr/local/bin/node",
            arguments: ["node", "vite"], currentDirectory: secretDirectory, cpu: 40
        )
        let snapshot = SyntheticSnapshots.snapshot([process], notices: [
            "run --auth-token=FAKEAUTH1 now",
            "env API_TOKEN=FAKEENV2 set",
            "mysql --ask-password -p FAKEPW3",
            "vite -p 3000 in ~/Developer/task-runner",
            "keys AKIAFAKEFAKEFAKE1234 xoxb-FAKE-SLACK sk-FAKEFAKEFAKEFAKE0000 at /tmp/0123456789abcdef0123456789abcdef/x",
            "blob ~/cache/QmFzZTY0RmFrZVNlY3JldEZvclRlc3RpbmdPbmx5/y",
            "long ~/Developer/my-long-project-name-that-is-quite-long/z",
        ])
        let finding = DiagnosticFinding(
            title: "Review vite", severity: .review, confidence: .medium, explanation: "Runs in " + secretDirectory,
            evidence: [Evidence(label: "Project", value: secretDirectory, source: "cwd")],
            limitations: [], affectedProcesses: [process.identity],
            recommendedActions: [.openProject(path: secretDirectory)]
        )
        for report in try reports(snapshot, findings: [finding]) {
            for leaked in ["FAKETOKEN456", "FAKEAUTH1", "FAKEENV2", "FAKEPW3", "AKIAFAKE", "xoxb-", "sk-FAKE",
                           "0123456789abcdef0123456789abcdef", "QmFzZTY0"] {
                #expect(!report.contains(leaked), "\(leaked) leaked")
            }
            #expect(report.contains("~/clients/acme-merger/<redacted>"))
            #expect(report.contains("vite -p 3000 in ~/Developer/task-runner"))
            #expect(report.contains("~/Developer/my-long-project-name-that-is-quite-long/z"))
        }
    }

    @Test("The username is replaced only as a whole word or path component")
    func usernameWholeWord() throws {
        let home = "/Users/al"
        let process = SyntheticSnapshots.process(
            pid: 1_300, name: "node", executablePath: "/usr/local/bin/node",
            arguments: ["/usr/local/bin/node"], currentDirectory: home + "/Developer/app", cpu: 10
        )
        let snapshot = SyntheticSnapshots.snapshot([process], notices: ["al started a scan; Al's Mac; final"])
        for report in try reports(snapshot, findings: [], home: home) {
            #expect(report.contains("/usr/local/bin/node"))
            #expect(!report.contains("loc<user>"))
            #expect(report.contains("~/Developer/app"))
            #expect(report.contains("<user> started a scan; <user>'s Mac; final"))
        }
    }

    @Test("Every redaction pattern compiles; one that didn't would silently redact nothing")
    func patternsCompile() {
        #expect(RedactionPatterns.secretFlag != nil)
        #expect(RedactionPatterns.secretAssignment != nil)
        #expect(RedactionPatterns.passwordContext != nil)
        #expect(RedactionPatterns.shortPasswordFlag != nil)
        #expect(RedactionPatterns.credentialPrefix != nil)
        #expect(RedactionPatterns.longHex != nil)
        #expect(RedactionPatterns.base64Run != nil)
    }

    @Test("Both reports for 1,000 processes with long argv take well under a second (patterns are compiled once)")
    func reportCostIsBounded() throws {
        let home = SyntheticSnapshots.home
        let processes = (0..<1_000).map { index in
            SyntheticSnapshots.process(
                pid: Int32(2_000 + index), name: "node",
                executablePath: "/usr/local/bin/node",
                arguments: ["/usr/local/bin/node", home + "/Developer/project-\(index)/node_modules/.bin/vitest",
                            "--run", "--reporter=dot", "src/feature/component-\(index).test.ts"],
                currentDirectory: home + "/Developer/project-\(index)", cpu: Double(index % 7)
            )
        }
        let snapshot = SyntheticSnapshots.snapshot(processes)
        let groups = ProvenanceResolver.resolve(snapshot)
        let findings = RulesEngine().evaluate(snapshot, groups: groups)
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            _ = Redactor.textReport(snapshot, groups: groups, findings: findings, homeDirectory: home)
            _ = try Redactor.jsonReport(snapshot, groups: groups, findings: findings, homeDirectory: home)
        }
        // Guards against the old multi-second regression (uncompiled patterns), not a tight budget:
        // idle it takes 0.4–0.5 s, and heavy machine load has pushed it past 2 s.
        #expect(elapsed < .seconds(3), "took \(elapsed)")
    }
}

@Suite("Redacted export: projects")
struct RedactorProjectTests {
    static let home = SyntheticSnapshots.home

    static func identities(_ count: Int, from pid: Int32) -> [ProcessIdentity] {
        (0..<count).map { ProcessIdentity(pid: pid + Int32($0), startTimeMicros: 1) }
    }

    static func container(_ id: String) -> ContainerSample {
        ContainerSample(containerID: id, name: "db-" + id, image: "postgres", state: "running", status: "Up", createdAt: .distantPast,
                        labels: [:], cpuPercentOfOneCore: 15, memoryBytes: 200 << 20, vmCPUCount: 6)
    }

    static func project(_ name: String, root: String, basis: String = "git repository", cpu: Double?, memory: UInt64,
                        processes: Int, from pid: Int32, containers: [ContainerSample] = []) -> ProjectUsage {
        ProjectUsage(bucket: .project(Project(name: name, root: root, confidence: .high, basis: basis)), groupRoots: [],
                     processes: identities(processes, from: pid), containers: containers, hostCPUPercent: cpu,
                     containerCPUPercent: containers.isEmpty ? nil : 30, memoryBytes: memory,
                     containerMemoryBytes: containers.isEmpty ? nil : 400 << 20, cpuWatts: nil)
    }

    static func other(_ bucket: ProjectUsage.Bucket, cpu: Double, memory: UInt64, processes: Int, from pid: Int32) -> ProjectUsage {
        ProjectUsage(bucket: bucket, groupRoots: [], processes: identities(processes, from: pid), containers: [],
                     hostCPUPercent: cpu, containerCPUPercent: nil, memoryBytes: memory, containerMemoryBytes: nil, cpuWatts: nil)
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    /// The "Projects:" section's lines, up to the next section.
    static func projectSection(_ text: String) -> [String] {
        let lines = text.split(separator: "\n").map(String.init)
        guard let start = lines.firstIndex(of: "Projects:") else { return [] }
        let rest = Array(lines[(start + 1)...])
        var result: [String] = []
        for line in rest {
            if line.hasPrefix("- ") || line.hasPrefix("and ") || line.contains("idle project") {
                result.append(line)
                continue
            }
            break
        }
        return result
    }

    static let breakdown = ProjectBreakdown(usages: [
        project("my-app", root: home + "/Developer/my-app", cpu: 180, memory: 1_500 << 20, processes: 12, from: 100,
                containers: [container("a"), container("b")]),
        project("someone/api", root: home + "/Clients/someone-api", basis: "user mapping", cpu: 4, memory: 64 << 20,
                processes: 1, from: 200),
        other(.dockerVM, cpu: 50, memory: 2 << 30, processes: 1, from: 300),
        other(.unattributed, cpu: 20, memory: 3 << 30, processes: 40, from: 400),
    ], containerAttributions: [:], notices: [])

    @Test("Two projects, the Docker VM and Unattributed render as lines and JSON fields, by name only")
    func rendersRows() throws {
        let snapshot = SyntheticSnapshots.snapshot([])
        let text = Redactor.textReport(snapshot, groups: [], findings: [], projects: Self.breakdown, homeDirectory: Self.home)
        let section = Self.projectSection(text)
        #expect(section == [
            "- my-app: 2.1 cores (19%), \(Self.bytes(1_500 << 20)) + \(Self.bytes(400 << 20)) in Docker, 12 processes, 2 containers",
            "- Docker VM: 0.5 cores (5%), \(Self.bytes(2 << 30)), 1 process",
            "- Unattributed: 0.2 cores (2%), \(Self.bytes(3 << 30)), 40 processes",
            "1 idle project not shown; Copy JSON for the full list",
        ])
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.firstIndex(of: "Projects:") == lines.firstIndex { $0.hasPrefix("System:") }.map { $0 + 1 })
        for line in section where line.hasPrefix("- ") { #expect(!line.contains("/"), "\(line)") }

        let json = try Redactor.jsonReport(snapshot, groups: [], findings: [], projects: Self.breakdown, homeDirectory: Self.home)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let rows = try #require(object["projects"] as? [[String: Any]])
        #expect(rows.map { $0["name"] as? String } == ["my-app", "<user>-api", "Docker VM", "Unattributed"])
        #expect(rows.map { $0["kind"] as? String } == ["project", "project", "dockerVM", "unattributed"])
        #expect(rows[0]["cpuPercent"] as? Double == 210)
        #expect(rows[0]["memoryBytes"] as? Int == 1_500 << 20)
        #expect(rows[0]["containerMemoryBytes"] as? Int == 400 << 20)
        #expect(rows[0]["processCount"] as? Int == 12)
        #expect(rows[0]["containerCount"] as? Int == 2)
        #expect(rows[0]["basis"] as? String == "git repository")
        #expect(rows[1]["basis"] as? String == "user mapping")
        #expect(rows[2]["basis"] == nil)
        for row in rows {
            #expect(row["directory"] == nil && row["root"] == nil)
            for case let value as String in row.values { #expect(!value.contains("/"), "\(value)") }
        }
    }

    @Test("More than 8 projects end in \"and N more\"; the Docker VM and Unattributed are still listed")
    func capsProjects() {
        let projects = (0..<11).map { index in
            Self.project("p\(index)", root: Self.home + "/p\(index)", cpu: Double(100 - index), memory: 1 << 20, processes: 1,
                         from: Int32(100 + index))
        }
        let breakdown = ProjectBreakdown(usages: projects + [Self.other(.unattributed, cpu: 1, memory: 1 << 20, processes: 1, from: 900)],
                                         containerAttributions: [:], notices: [])
        let text = Redactor.textReport(SyntheticSnapshots.snapshot([]), groups: [], findings: [], projects: breakdown,
                                       homeDirectory: Self.home)
        let section = Self.projectSection(text)
        #expect(section.count == Redactor.textProjectLimit + 2)
        #expect(section.prefix(Redactor.textProjectLimit).map { String($0.prefix(5)) } == (0..<8).map { "- p\($0):" })
        #expect(section[Redactor.textProjectLimit] == "and 3 more projects; Copy JSON for the full list")
        #expect(section.contains("1 idle project not shown; Copy JSON for the full list"))
    }

    @Test("An empty breakdown leaves the section and the JSON rows out")
    func emptyBreakdown() throws {
        let snapshot = SyntheticSnapshots.snapshot([])
        let text = Redactor.textReport(snapshot, groups: [], findings: [], homeDirectory: Self.home)
        #expect(!text.contains("Projects:"))
        let json = try Redactor.jsonReport(snapshot, groups: [], findings: [], homeDirectory: Self.home)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect((object["projects"] as? [Any])?.isEmpty == true)
    }

    @Test("Idle projects are hidden in text report")
    func hidesIdleProjects() {
        let busy = Self.project("busy-app", root: Self.home + "/Developer/busy-app", cpu: 200, memory: 1_000 << 20, processes: 5, from: 100)
        let idleOne = Self.project("idle1", root: Self.home + "/Developer/idle1", cpu: 2, memory: 64 << 20, processes: 1, from: 200)
        let idleTwo = Self.project("idle2", root: Self.home + "/Developer/idle2", cpu: nil, memory: 32 << 20, processes: 1, from: 300)
        let breakdown = ProjectBreakdown(usages: [busy, idleOne, idleTwo], containerAttributions: [:], notices: [])
        let text = Redactor.textReport(SyntheticSnapshots.snapshot([]), groups: [], findings: [], projects: breakdown, homeDirectory: Self.home)
        let section = Self.projectSection(text)
        #expect(section.contains("- busy-app: 2.0 cores (18%), \(Self.bytes(1_000 << 20)), 5 processes"))
        #expect(!section.contains("idle1"))
        #expect(!section.contains("idle2"))
        #expect(section.contains("2 idle projects not shown; Copy JSON for the full list"))
    }

    @Test("All idle projects leave out the whole Projects section")
    func allIdleLeavesOutSection() {
        let idleOne = Self.project("idle1", root: Self.home + "/Developer/idle1", cpu: 2, memory: 64 << 20, processes: 1, from: 200)
        let idleTwo = Self.project("idle2", root: Self.home + "/Developer/idle2", cpu: nil, memory: 32 << 20, processes: 1, from: 300)
        let breakdown = ProjectBreakdown(usages: [idleOne, idleTwo], containerAttributions: [:], notices: [])
        let text = Redactor.textReport(SyntheticSnapshots.snapshot([]), groups: [], findings: [], projects: breakdown, homeDirectory: Self.home)
        #expect(!text.contains("Projects:"))
    }

    @Test("9 busy + 3 idle shows 8 lines with more and idle count")
    func busyAndIdleWithCap() {
        let busyProjects = (0..<9).map { index in
            Self.project("p\(index)", root: Self.home + "/p\(index)", cpu: Double(200 - index), memory: 1 << 20, processes: 1, from: Int32(100 + index))
        }
        let idleProjects = (0..<3).map { index in
            Self.project("idle\(index)", root: Self.home + "/idle\(index)", cpu: index == 0 ? 2 : nil, memory: 1 << 20, processes: 1, from: Int32(200 + index))
        }
        let breakdown = ProjectBreakdown(usages: busyProjects + idleProjects, containerAttributions: [:], notices: [])
        let text = Redactor.textReport(SyntheticSnapshots.snapshot([]), groups: [], findings: [], projects: breakdown, homeDirectory: Self.home)
        let section = Self.projectSection(text)
        #expect(section.prefix(Redactor.textProjectLimit).map { String($0.prefix(5)) } == (0..<8).map { "- p\($0):" })
        #expect(section.contains("and 1 more projects; Copy JSON for the full list"))
        #expect(section.contains("3 idle projects not shown; Copy JSON for the full list"))
    }

    @Test("JSON still lists all rows including idle")
    func jsonListsAllRows() throws {
        let busy = Self.project("busy-app", root: Self.home + "/Developer/busy-app", cpu: 200, memory: 1_000 << 20, processes: 5, from: 100)
        let idleOne = Self.project("idle1", root: Self.home + "/Developer/idle1", cpu: 2, memory: 64 << 20, processes: 1, from: 200)
        let idleTwo = Self.project("idle2", root: Self.home + "/Developer/idle2", cpu: nil, memory: 32 << 20, processes: 1, from: 300)
        let breakdown = ProjectBreakdown(usages: [busy, idleOne, idleTwo], containerAttributions: [:], notices: [])
        let json = try Redactor.jsonReport(SyntheticSnapshots.snapshot([]), groups: [], findings: [], projects: breakdown, homeDirectory: Self.home)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let rows = try #require(object["projects"] as? [[String: Any]])
        #expect(rows.count == 3)
    }
}
