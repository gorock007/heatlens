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

    @Test("Phase 1 never recommends requestStop", arguments: [
        SyntheticSnapshots.activeWork,
        SyntheticSnapshots.detachedWorker,
        SyntheticSnapshots.oldNextServer,
        SyntheticSnapshots.hotVitestAndIdleWorker,
        SyntheticSnapshots.multiCore,
    ])
    func neverRequestsStop(snapshot: ScanSnapshot) {
        let actions = evaluate(snapshot).flatMap(\.recommendedActions)
        #expect(actions.allSatisfy { action in
            if case .requestStop = action { return false }
            return true
        })
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
