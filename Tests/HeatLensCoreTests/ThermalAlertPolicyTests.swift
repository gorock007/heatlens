import Foundation
import Testing
@testable import HeatLensCore

@Suite("Thermal alert policy")
struct ThermalAlertPolicyTests {
    let policy = ThermalAlertPolicy()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let home = SyntheticSnapshots.home

    private func scans(_ previous: ThermalState, _ current: ThermalState, enabled: Bool = true,
                       lastAlert: Date? = nil, scanRunning: Bool = false) -> Bool {
        policy.shouldScan(previous: previous, current: current, enabled: enabled,
                          lastAlert: lastAlert, now: now, scanRunning: scanRunning)
    }

    @Test("A rise into serious or critical scans")
    func rises() {
        #expect(scans(.fair, .serious))
        #expect(scans(.nominal, .serious))
        #expect(scans(.nominal, .critical))
        #expect(scans(.serious, .critical))
        #expect(scans(.unavailable, .serious))
    }

    @Test("A fall, a rise below serious, or no change doesn't scan")
    func nonRises() {
        #expect(!scans(.critical, .serious))
        #expect(!scans(.serious, .fair))
        #expect(!scans(.nominal, .fair))
        #expect(!scans(.serious, .serious))
        #expect(!scans(.critical, .critical))
        #expect(!scans(.serious, .unavailable))
    }

    @Test("Off means no scan")
    func disabled() {
        #expect(!scans(.fair, .serious, enabled: false))
        #expect(!scans(.nominal, .critical, enabled: false))
    }

    @Test("A scan already running means no second one")
    func scanRunning() {
        #expect(!scans(.fair, .serious, scanRunning: true))
    }

    @Test("The 30-minute cooldown ends at exactly 30:00")
    func cooldownEdge() {
        #expect(!scans(.fair, .serious, lastAlert: now.addingTimeInterval(-(30 * 60 - 1))))
        #expect(scans(.fair, .serious, lastAlert: now.addingTimeInterval(-30 * 60)))
        #expect(scans(.fair, .serious, lastAlert: now.addingTimeInterval(-2 * 60 * 60)))
        #expect(!scans(.fair, .serious, lastAlert: now))
    }

    private func result(_ snapshot: ScanSnapshot) -> ScanResult {
        let groups = ProvenanceResolver.resolve(snapshot)
        return ScanResult(snapshot: snapshot, groups: groups, findings: RulesEngine().evaluate(snapshot, groups: groups))
    }

    @Test("The body names the top CPU group's label, project folder and CPU")
    func summaryWithCPUFinding() {
        let snapshot = SyntheticSnapshots.snapshot(SyntheticSnapshots.hotVitestAndIdleWorker.processes, thermal: .serious)
        let summary = policy.summary(for: result(snapshot), homeDirectory: home)
        #expect(summary.title == "Your Mac is running hot")
        #expect(summary.body == "vitest in Tests · 96% CPU")
    }

    @Test("Excluded groups are skipped for the next visible CPU finding")
    func summaryRespectsExclusions() {
        let processes = SyntheticSnapshots.hotVitestAndIdleWorker.processes + SyntheticSnapshots.multiCore.processes
        let snapshot = SyntheticSnapshots.snapshot(processes, thermal: .serious)
        let full = policy.summary(for: result(snapshot), homeDirectory: home)
        #expect(full.body.hasSuffix("in Build · 180% CPU"))

        let filter = ExclusionFilter(projectPrefixes: [home + "/Developer/Build"])
        let filtered = policy.summary(for: result(snapshot), exclusions: filter, homeDirectory: home)
        #expect(filtered.body == "vitest in Tests · 96% CPU")
    }

    @Test("With no CPU finding the body says nothing stands out")
    func summaryWithoutCPUFinding() {
        let snapshot = SyntheticSnapshots.snapshot(SyntheticSnapshots.detachedWorker.processes, thermal: .serious)
        let summary = policy.summary(for: result(snapshot), homeDirectory: home)
        #expect(summary.title == "Your Mac is running hot")
        #expect(summary.body == "No single process stands out. macOS reports serious thermal pressure.")
        let critical = policy.summary(for: result(snapshot), thermalState: .critical, homeDirectory: home)
        #expect(critical.body == "No single process stands out. macOS reports critical thermal pressure.")

        let excluded = SyntheticSnapshots.snapshot(SyntheticSnapshots.multiCore.processes, thermal: .serious)
        let hidden = policy.summary(for: result(excluded), exclusions: ExclusionFilter(processNames: ["node"]), homeDirectory: home)
        #expect(hidden.body.hasPrefix("No single process stands out."))
    }

    @Test("No argv, full path or user name reaches the notification")
    func summaryIsRedacted() throws {
        let process = SyntheticSnapshots.process(
            pid: 900, name: "node", executablePath: "/usr/local/bin/node",
            arguments: ["node", home + "/secret-client/run.js", "--token=abc123"],
            currentDirectory: home, cpu: 150)
        let snapshot = SyntheticSnapshots.snapshot([process], thermal: .critical)
        let group = ProcessGroup(root: process.identity, members: [process.identity], kind: "node script",
                                 label: "node " + home + "/secret-client/run.js someone",
                                 project: ProjectAttribution(directory: home, basis: "cwd", confidence: .medium),
                                 confidence: .medium, evidence: [])
        let finding = DiagnosticFinding(title: "Sustained high CPU", severity: .high, confidence: .high, explanation: "",
                                        evidence: [], limitations: [], affectedProcesses: [process.identity],
                                        recommendedActions: [], kind: .highCPU)
        let summary = policy.summary(for: ScanResult(snapshot: snapshot, groups: [group], findings: [finding]),
                                     thermalState: .critical, homeDirectory: home)
        #expect(summary.body == "node run.js · 150% CPU")
        for leaked in ["/", "someone", "secret-client", "--token", "abc123", "Users"] {
            #expect(!summary.body.contains(leaked), "leaked \(leaked)")
        }

        let real = policy.summary(for: result(SyntheticSnapshots.snapshot(SyntheticSnapshots.multiCore.processes, thermal: .serious)),
                                  homeDirectory: home)
        let argv = try #require(SyntheticSnapshots.multiCore.processes.first?.arguments)
        #expect(!real.body.contains("/"))
        #expect(!real.body.contains("someone"))
        #expect(argv.filter { $0.contains("/") }.allSatisfy { !real.body.contains($0) })
    }

    @Test("Long labels and project names keep the body under 110 characters")
    func summaryLength() {
        let process = SyntheticSnapshots.process(pid: 901, name: "x", cpu: 1234)
        let snapshot = SyntheticSnapshots.snapshot([process], thermal: .serious)
        let group = ProcessGroup(root: process.identity, members: [process.identity], kind: "app",
                                 label: String(repeating: "VeryLongApplicationName", count: 5),
                                 project: ProjectAttribution(directory: home + "/" + String(repeating: "deep-project", count: 6),
                                                             basis: "cwd", confidence: .high),
                                 confidence: .high, evidence: [])
        let finding = DiagnosticFinding(title: "Sustained high CPU", severity: .high, confidence: .high, explanation: "",
                                        evidence: [], limitations: [], affectedProcesses: [process.identity],
                                        recommendedActions: [], kind: .highCPU)
        let summary = policy.summary(for: ScanResult(snapshot: snapshot, groups: [group], findings: [finding]), homeDirectory: home)
        #expect(summary.body.count <= 110)
        #expect(summary.body.hasSuffix(" · 1234% CPU"))
        #expect(summary.body.contains("…"))
    }
}
