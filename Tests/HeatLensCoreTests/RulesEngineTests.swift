import Foundation
import Testing
@testable import HeatLensCore

@Suite("Rules engine")
struct RulesEngineTests {
    let engine = RulesEngine()

    @Test("Active CapCut and Claude CPU is described as active work, not junk")
    func activeWork() {
        let snapshot = SyntheticSnapshots.activeWork
        let findings = evaluate(snapshot)
        let active = findings.filter { $0.title.contains("Sustained high CPU") }
        #expect(active.count == 2)
        #expect(active.allSatisfy { $0.explanation.contains("active work") })
        #expect(active.allSatisfy { !$0.explanation.lowercased().contains("junk") || $0.explanation.contains("not junk") })
    }

    @Test("A 48-hour PPID-1 worker is review-only and not blamed for heat")
    func detachedWorker() throws {
        let findings = evaluate(SyntheticSnapshots.detachedWorker)
        let finding = try #require(findings.first(where: { $0.title == "Potential detached worker" }))
        #expect(finding.severity == .review)
        #expect(finding.confidence == .medium)
        #expect(finding.explanation.contains("not causing meaningful heat"))
        #expect(finding.limitations.contains("PPID 1 is a clue, not proof."))
        #expect(finding.limitations.contains("This does not prove it is unused."))
    }

    @Test("A 38-hour idle Next server is a possible leftover")
    func staleNext() throws {
        let finding = try #require(evaluate(SyntheticSnapshots.oldNextServer).first(where: { $0.title == "Potential stale development server" }))
        #expect(finding.severity == .review)
        #expect(finding.explanation.contains("leftover"))
        #expect(finding.limitations == ["This server may be intentionally always-on."])
    }

    @Test("A hot Vitest spike ranks before a two-day idle worker")
    func impactRanking() throws {
        let findings = evaluate(SyntheticSnapshots.hotVitestAndIdleWorker)
        let first = try #require(findings.first)
        #expect(first.title.contains("Sustained high CPU"))
        #expect(first.title.contains("vitest"))
        let detachedIndex = try #require(findings.firstIndex(where: { $0.title == "Potential detached worker" }))
        #expect(detachedIndex > 0)
    }

    @Test("Thermal unavailable produces no thermal finding")
    func thermalUnavailable() {
        let snapshot = SyntheticSnapshots.snapshot([], thermal: .unavailable)
        #expect(evaluate(snapshot).allSatisfy { !$0.title.lowercased().contains("thermal") })
    }

    @Test("A process using 180 percent is represented and rated high")
    func multipleCores() throws {
        let finding = try #require(evaluate(SyntheticSnapshots.multiCore).first(where: { $0.title.contains("Sustained high CPU") }))
        #expect(finding.severity == .high)
        #expect(finding.explanation.contains("180.0%"))
    }

    @Test("Memory pressure follows OS pressure, while old swap at normal pressure is info")
    func memoryPressure() throws {
        let warning = SyntheticSnapshots.snapshot([], pressure: .warning, swapUsedBytes: 8 << 30)
        #expect(try #require(evaluate(warning).first(where: { $0.title == "Memory pressure warning" })).severity == .medium)

        let critical = SyntheticSnapshots.snapshot([], pressure: .critical)
        #expect(try #require(evaluate(critical).first(where: { $0.title == "Critical memory pressure" })).severity == .high)

        let normal = SyntheticSnapshots.snapshot([], pressure: .normal, swapUsedBytes: 8 << 30)
        #expect(try #require(evaluate(normal).first(where: { $0.title == "Swap in use with normal pressure" })).severity == .info)
    }

    @Test("WindowServer and kernel_task findings are informational caveats")
    func systemSignals() throws {
        let snapshot = SyntheticSnapshots.snapshot([
            SyntheticSnapshots.process(pid: 900, owner: .root, name: "WindowServer", cpu: 31),
            SyntheticSnapshots.process(pid: 0, owner: .root, name: "kernel_task", cpu: 51),
        ])
        let findings = evaluate(snapshot)
        let window = try #require(findings.first(where: { $0.title == "UI-heavy workload" }))
        let kernel = try #require(findings.first(where: { $0.title == "kernel_task activity" }))
        #expect(window.severity == .info)
        #expect(window.limitations.joined().contains("not a GPU percentage"))
        #expect(kernel.severity == .info)
        #expect(kernel.limitations.joined().contains("thermal management"))
    }

    @Test("requestStop appears only on eligible review findings, for the group root", arguments: [
        SyntheticSnapshots.activeWork,
        SyntheticSnapshots.detachedWorker,
        SyntheticSnapshots.oldNextServer,
        SyntheticSnapshots.hotVitestAndIdleWorker,
        SyntheticSnapshots.multiCore,
        SyntheticSnapshots.snapshot([
            SyntheticSnapshots.process(pid: 900, owner: .root, name: "WindowServer", cpu: 31),
            SyntheticSnapshots.process(pid: 0, owner: .root, name: "kernel_task", cpu: 51),
        ], pressure: .critical, thermal: .serious),
    ])
    func requestStopOnlyOnEligibleReview(snapshot: ScanSnapshot) {
        let samples = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.identity, $0) })
        for finding in evaluate(snapshot) {
            let stops = stopTargets(finding)
            guard !stops.isEmpty else { continue }
            #expect([FindingKind.staleDevServer, .detachedWorker].contains(finding.kind))
            #expect(finding.severity == .review)
            #expect(stops.count == 1)
            // `.inspect` names the group root; the stop must target the same process.
            #expect(stops.first == inspectTarget(finding))
            #expect(stops.first.flatMap { samples[$0] }.map { ProcessTerminator().eligibility(of: $0) } == .eligible)
        }
    }

    @Test("Stale servers and detached workers offer a stop; high CPU and system findings never do")
    func requestStopWhereExpected() throws {
        let detached = try #require(evaluate(SyntheticSnapshots.detachedWorker).first { $0.kind == .detachedWorker })
        #expect(stopTargets(detached) == [detached.affectedProcesses[0]])

        let stale = try #require(evaluate(SyntheticSnapshots.oldNextServer).first { $0.kind == .staleDevServer })
        #expect(stopTargets(stale).count == 1)

        let mixed = evaluate(SyntheticSnapshots.hotVitestAndIdleWorker)
        #expect(mixed.filter { $0.kind == .detachedWorker }.allSatisfy { stopTargets($0).count == 1 })
        let hot = evaluate(SyntheticSnapshots.multiCore) + evaluate(SyntheticSnapshots.activeWork) + mixed
        #expect(hot.filter { $0.kind == .highCPU }.allSatisfy { stopTargets($0).isEmpty })
    }

    @Test("A leftover whose root fails eligibility gets no stop", arguments: [
        SyntheticSnapshots.process(pid: 200, ageHours: 48, owner: .root, name: "node", executablePath: "/usr/local/bin/node",
                                   arguments: ["node", "/Users/someone/Developer/Orchard/scripts/worker.js"],
                                   currentDirectory: "/Users/someone/Developer/Orchard", cpu: 0.1),
        SyntheticSnapshots.process(pid: 200, ageHours: 48, name: "node", executablePath: "/usr/bin/node",
                                   arguments: ["node", "/Users/someone/Developer/Orchard/scripts/worker.js"],
                                   currentDirectory: "/Users/someone/Developer/Orchard", cpu: 0.1),
        SyntheticSnapshots.process(pid: 200, ageHours: 48, name: "node", executablePath: nil,
                                   arguments: ["node", "/Users/someone/Developer/Orchard/scripts/worker.js"],
                                   currentDirectory: "/Users/someone/Developer/Orchard", cpu: 0.1),
    ])
    func ineligibleLeftover(root: ProcessSample) throws {
        let findings = evaluate(SyntheticSnapshots.snapshot([root]))
        let detached = try #require(findings.first { $0.kind == .detachedWorker })
        #expect(stopTargets(detached).isEmpty)
    }

    private func stopTargets(_ finding: DiagnosticFinding) -> [ProcessIdentity] {
        finding.recommendedActions.compactMap { if case .requestStop(let id) = $0 { id } else { nil } }
    }

    private func inspectTarget(_ finding: DiagnosticFinding) -> ProcessIdentity? {
        finding.recommendedActions.lazy.compactMap { if case .inspect(let id) = $0 { id } else { nil } }.first
    }

    @Test("Every finding carries the kind of rule that produced it")
    func findingKinds() {
        func kinds(_ snapshot: ScanSnapshot) -> Set<FindingKind?> { Set(evaluate(snapshot).map(\.kind)) }
        #expect(kinds(SyntheticSnapshots.multiCore).contains(.highCPU))
        #expect(kinds(SyntheticSnapshots.oldNextServer).contains(.staleDevServer))
        #expect(kinds(SyntheticSnapshots.detachedWorker).contains(.detachedWorker))
        #expect(kinds(SyntheticSnapshots.snapshot([], pressure: .warning)) == [.memoryPressure])
        #expect(kinds(SyntheticSnapshots.snapshot([], pressure: .normal, swapUsedBytes: 8 << 30)) == [.swapInUse])
        #expect(kinds(SyntheticSnapshots.snapshot([], thermal: .serious)) == [.thermal])
        let signals = SyntheticSnapshots.snapshot([
            SyntheticSnapshots.process(pid: 900, owner: .root, name: "WindowServer", cpu: 31),
            SyntheticSnapshots.process(pid: 0, owner: .root, name: "kernel_task", cpu: 51),
        ])
        #expect(kinds(signals).isSuperset(of: [.uiHeavy, .kernelTask]))
        let all = [SyntheticSnapshots.activeWork, SyntheticSnapshots.detachedWorker, SyntheticSnapshots.oldNextServer,
                   SyntheticSnapshots.hotVitestAndIdleWorker, SyntheticSnapshots.multiCore, signals]
        #expect(all.flatMap(evaluate).allSatisfy { $0.kind != nil })
    }

    @Test("Evaluation is deterministic including finding IDs")
    func deterministic() {
        let snapshot = SyntheticSnapshots.hotVitestAndIdleWorker
        let groups = ProvenanceResolver.resolve(snapshot)
        #expect(engine.evaluate(snapshot, groups: groups) == engine.evaluate(snapshot, groups: groups))
    }

    private func evaluate(_ snapshot: ScanSnapshot) -> [DiagnosticFinding] {
        engine.evaluate(snapshot, groups: ProvenanceResolver.resolve(snapshot))
    }
}
