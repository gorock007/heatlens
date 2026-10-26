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
}
