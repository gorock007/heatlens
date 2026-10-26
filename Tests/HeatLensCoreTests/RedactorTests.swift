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
}
