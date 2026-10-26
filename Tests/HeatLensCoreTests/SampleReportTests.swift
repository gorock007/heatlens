import Foundation
import Testing
@testable import HeatLensCore

@Suite("Sample reports")
struct SampleReportTests {
    /// The PRD §7 results card, built only from invented names under `/Users/example`. The worker runs at
    /// 64% rather than the PRD's 44% because 50% is the default threshold for a CPU finding.
    static let home = "/Users/example"

    static var snapshot: ScanSnapshot {
        SyntheticSnapshots.snapshot([
            SyntheticSnapshots.process(
                pid: 700,
                name: "opencode",
                executablePath: home + "/.local/bin/opencode",
                arguments: ["opencode", "run", "--model", "invented"],
                currentDirectory: home + "/Developer/orchard-notes",
                cpu: 64
            ),
            SyntheticSnapshots.process(
                pid: 710,
                ageHours: 53,
                name: "node",
                executablePath: "/usr/local/bin/node",
                arguments: ["node", home + "/Developer/idea-garden/scripts/worker.js"],
                currentDirectory: home + "/Developer/idea-garden",
                cpu: 0
            ),
        ], hostBusyFraction: 0.31)
    }

    @Test("The PRD §7 scenario renders as text and JSON; HEATLENS_WRITE_SAMPLES=<dir> writes them")
    func renderSamples() throws {
        let snapshot = Self.snapshot
        let groups = ProvenanceResolver.resolve(snapshot)
        let findings = RulesEngine().evaluate(snapshot, groups: groups)
        let text = Redactor.textReport(snapshot, groups: groups, findings: findings, homeDirectory: Self.home)
        let json = try Redactor.jsonReport(snapshot, groups: groups, findings: findings, homeDirectory: Self.home)

        #expect(!findings.isEmpty)
        #expect(text.contains("HeatLens scan"))
        #expect(try JSONSerialization.jsonObject(with: json) is [String: Any])
        #expect(!text.contains(Self.home))

        if let directory = ProcessInfo.processInfo.environment["HEATLENS_WRITE_SAMPLES"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try text.write(to: url.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            try json.write(to: url.appendingPathComponent("report.json"), options: .atomic)
        }
    }
}
