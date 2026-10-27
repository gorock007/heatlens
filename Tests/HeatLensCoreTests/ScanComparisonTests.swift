import Foundation
import Testing
@testable import HeatLensCore

@Suite("Scan comparison")
struct ScanComparisonTests {
    let home = SyntheticSnapshots.home

    private func process(_ pid: Int32, ageHours: Double = 1, name: String = "node", cpu: Double? = 0) -> ProcessSample {
        SyntheticSnapshots.process(pid: pid, ageHours: ageHours, name: name, cpu: cpu)
    }

    /// One group per process, labelled by name, in `home/Developer/<project>`.
    private func group(_ sample: ProcessSample, label: String? = nil, project: String? = "my-app") -> ProcessGroup {
        ProcessGroup(root: sample.identity, members: [sample.identity], kind: "node script", label: label ?? sample.name,
                     project: project.map { ProjectAttribution(directory: home + "/Developer/" + $0, basis: "cwd", confidence: .high) },
                     confidence: .high, evidence: [])
    }

    private func finding(_ identities: [ProcessIdentity]) -> DiagnosticFinding {
        DiagnosticFinding(title: "Possible leftover", severity: .review, confidence: .medium, explanation: "",
                          evidence: [], limitations: [], affectedProcesses: identities, recommendedActions: [],
                          kind: .detachedWorker)
    }

    private func result(_ processes: [ProcessSample], groups: [ProcessGroup]? = nil, findings: [DiagnosticFinding] = [],
                        minutesLater: Double = 0, pressure: MemoryPressureLevel = .normal, swap: UInt64 = 0,
                        thermal: ThermalState = .nominal, busy: Double = 0.25) -> ScanResult {
        let base = SyntheticSnapshots.snapshot(processes, pressure: pressure, swapUsedBytes: swap, thermal: thermal,
                                               hostBusyFraction: busy)
        let snapshot = ScanSnapshot(startedAt: base.startedAt.addingTimeInterval(minutesLater * 60), interval: base.interval,
                                    system: base.system, processes: processes, notices: [])
        return ScanResult(snapshot: snapshot, groups: groups ?? processes.map { group($0) }, findings: findings)
    }

    @Test("A group whose root PID and start time are absent is gone; elapsed is start to start")
    func goneByIdentity() {
        let leftover = process(200, ageHours: 48, cpu: 0)
        let server = process(300, name: "next-server", cpu: 3)
        let before = result([leftover, server], groups: [group(leftover, label: "next dev"), group(server)],
                            findings: [finding([leftover.identity])])
        let after = result([server], minutesLater: 4)

        let comparison = ScanComparison.compare(before: before, after: after)
        #expect(comparison.gone.map(\.root) == [leftover.identity])
        #expect(comparison.gone.first?.label == "next dev")
        #expect(comparison.gone.first?.projectName == "my-app")
        #expect(comparison.gone.first?.cpuPercentOfOneCore == 0)
        #expect(comparison.moreGoneCount == 0)
        #expect(comparison.elapsed == 240)
        #expect(!comparison.isAboutTheSame)
    }

    @Test("PID reuse: the same PID with a new start time counts as gone")
    func pidReuse() {
        let leftover = process(200, ageHours: 48)
        let before = result([leftover], findings: [finding([leftover.identity])])
        let reused = process(200, ageHours: 0.01, name: "zsh")
        #expect(reused.identity.pid == leftover.identity.pid && reused.identity != leftover.identity)

        let comparison = ScanComparison.compare(before: before, after: result([reused]))
        #expect(comparison.gone.map(\.root) == [leftover.identity])

        let still = ScanComparison.compare(before: before, after: result([leftover]))
        #expect(still.gone.isEmpty)
    }

    @Test("A gone group counts only with a previous finding or at least 0.2 cores; exclusions hide it")
    func goneNoiseAndExclusions() {
        let named = process(200, name: "watcher", cpu: 0)
        let busy = process(201, name: "vitest", cpu: 20)
        let quiet = process(202, name: "mdworker", cpu: 19.9)
        let unmeasured = process(203, name: "WindowServer", cpu: nil)
        let before = result([named, busy, quiet, unmeasured],
                            groups: [group(named), group(busy), group(quiet, project: nil), group(unmeasured, project: nil)],
                            findings: [finding([named.identity])])
        let after = result([])

        let comparison = ScanComparison.compare(before: before, after: after)
        #expect(comparison.gone.map(\.label) == ["vitest", "watcher"])
        #expect(comparison.gone.first?.cpuPercentOfOneCore == 20)

        let byName = ScanComparison.compare(before: before, after: after, exclusions: ExclusionFilter(processNames: ["VITEST"]))
        #expect(byName.gone.map(\.label) == ["watcher"])

        // Excluding the project hides the finding too, so the watcher no longer qualifies by it.
        let byProject = ScanComparison.compare(before: before, after: after,
                                               exclusions: ExclusionFilter(projectPrefixes: [home + "/Developer/my-app"]))
        #expect(byProject.gone.isEmpty)
    }

    @Test("A group's CPU is the sum of its members'")
    func groupCPU() {
        let root = process(200, name: "npm", cpu: 12)
        let child = process(201, name: "node", cpu: 9)
        let gone = ProcessGroup(root: root.identity, members: [root.identity, child.identity], kind: "next dev",
                                label: "Next.js dev server", project: nil, confidence: .high, evidence: [])
        let comparison = ScanComparison.compare(before: result([root, child], groups: [gone]), after: result([]))
        #expect(comparison.gone.first?.cpuPercentOfOneCore == 21)
    }

    @Test("Changes under the noise floor read as about the same")
    func noiseFloor() {
        let mib: UInt64 = 1 << 20
        let before = result([], swap: 2_000 * mib, busy: 0.25)

        // 11 cores: 0.01 of the host is 0.11 cores; 99 MB of swap.
        let small = ScanComparison.compare(before: before, after: result([], swap: 2_099 * mib, busy: 0.26))
        #expect(!small.busyCoresChanged)
        #expect(!small.swapChanged)
        #expect(small.isAboutTheSame)

        let smallDown = ScanComparison.compare(before: before, after: result([], swap: 1_901 * mib, busy: 0.24))
        #expect(smallDown.isAboutTheSame)

        // 0.03 of the host is 0.33 cores; 100 MB of swap.
        let large = ScanComparison.compare(before: before, after: result([], swap: 1_900 * mib, busy: 0.22))
        #expect(large.busyCoresChanged)
        #expect(large.swapChanged)
        #expect(!large.isAboutTheSame)
        #expect(abs(large.busyCores.before - 2.75) < 0.0001)
        #expect(large.swapUsedBytes == .init(before: 2_000 * mib, after: 1_900 * mib))
    }

    @Test("Any change of memory pressure or thermal state counts")
    func levelChanges() {
        let before = result([], pressure: .warning, thermal: .serious)

        let pressure = ScanComparison.compare(before: before, after: result([], pressure: .normal, thermal: .serious))
        #expect(pressure.memoryPressureChanged)
        #expect(pressure.memoryPressure == .init(before: .warning, after: .normal))
        #expect(!pressure.thermalChanged)
        #expect(!pressure.isAboutTheSame)

        let thermal = ScanComparison.compare(before: before, after: result([], pressure: .warning, thermal: .fair))
        #expect(thermal.thermalChanged)
        #expect(thermal.thermalState == .init(before: .serious, after: .fair))
        #expect(!thermal.memoryPressureChanged)
        #expect(!thermal.isAboutTheSame)
    }

    @Test("At most 5 gone groups, highest CPU first, plus a count of the rest")
    func goneCap() {
        let processes: [ProcessSample] = (0..<7).map { index in
            let cpu = Double(30 + index * 10)
            return process(Int32(400 + index), name: "worker\(index)", cpu: cpu)
        }
        let comparison = ScanComparison.compare(before: result(processes), after: result([]))
        #expect(comparison.gone.map(\.label) == ["worker6", "worker5", "worker4", "worker3", "worker2"])
        #expect(comparison.moreGoneCount == 2)
    }

    @Test("The same scan again is about the same")
    func nothingChanged() {
        let leftover = process(200, ageHours: 48)
        let busy = process(201, cpu: 80)
        let before = result([leftover, busy], findings: [finding([leftover.identity])], swap: 1 << 30)
        let after = result([leftover, busy], minutesLater: 2, swap: 1 << 30)

        let comparison = ScanComparison.compare(before: before, after: after)
        #expect(comparison.gone.isEmpty)
        #expect(comparison.moreGoneCount == 0)
        #expect(!comparison.busyCoresChanged && !comparison.swapChanged)
        #expect(!comparison.memoryPressureChanged && !comparison.thermalChanged)
        #expect(comparison.isAboutTheSame)
        #expect(comparison.elapsed == 120)
    }
}
