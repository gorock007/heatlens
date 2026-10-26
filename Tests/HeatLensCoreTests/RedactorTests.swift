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
}
