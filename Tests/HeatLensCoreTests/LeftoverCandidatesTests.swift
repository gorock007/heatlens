import Foundation
import Testing
@testable import HeatLensCore

/// Pure grouping of offered leftover stops by project, on synthetic findings; nothing is signalled.
@Suite("Leftover candidates")
struct LeftoverCandidatesTests {
    static let app = ProjectAttribution(directory: "~/Projects/app", basis: "cwd", confidence: .high)
    static let site = ProjectAttribution(directory: "~/Projects/site", basis: "argv path", confidence: .medium)

    let server = SyntheticSnapshots.process(pid: 501, ageHours: 30, name: "node", executablePath: "/usr/local/bin/node")
    let serverChild = SyntheticSnapshots.process(pid: 502, parentPID: 501, ageHours: 30, name: "next-server",
                                                 executablePath: "/usr/local/bin/node")
    let worker = SyntheticSnapshots.process(pid: 601, ageHours: 50, name: "node", executablePath: "/usr/local/bin/node")
    let otherServer = SyntheticSnapshots.process(pid: 701, ageHours: 40, name: "vite", executablePath: "/usr/local/bin/node")
    let loose = SyntheticSnapshots.process(pid: 801, ageHours: 60, name: "python3", executablePath: "/opt/homebrew/bin/python3")
    let busy = SyntheticSnapshots.process(pid: 901, ageHours: 2, name: "node", executablePath: "/usr/local/bin/node", cpu: 90)

    var processes: [ProcessSample] { [server, serverChild, worker, otherServer, loose, busy] }

    var groups: [ProcessGroup] {
        [
            group(server, members: [server, serverChild], project: Self.app),
            group(worker, project: Self.app),
            group(otherServer, project: Self.site),
            group(loose, project: nil),
            group(busy, project: Self.app),
        ]
    }

    private func group(_ root: ProcessSample, members: [ProcessSample]? = nil, project: ProjectAttribution?) -> ProcessGroup {
        ProcessGroup(root: root.identity, members: (members ?? [root]).map(\.identity), kind: "node script",
                     label: root.name, project: project, confidence: .medium, evidence: [])
    }

    private func finding(_ kind: FindingKind, _ title: String, affected: [ProcessSample],
                         stops: [ProcessSample]) -> DiagnosticFinding {
        DiagnosticFinding(title: title, severity: kind == .highCPU ? .high : .review, confidence: .medium,
                          explanation: "", evidence: [], limitations: [],
                          affectedProcesses: affected.map(\.identity),
                          recommendedActions: [.inspect(affected[0].identity)] + stops.map { .requestStop($0.identity) },
                          kind: kind)
    }

    private func candidates(_ findings: [DiagnosticFinding], hidden: Set<UUID> = []) -> [ProjectLeftovers] {
        LeftoverCandidates.byProject(findings: findings, groups: groups, processes: processes, hiddenFindingIDs: hidden)
    }

    @Test("Only staleDevServer and detachedWorker stop offers count")
    func onlyLeftoverKinds() {
        let findings = [
            finding(.staleDevServer, "Stale server", affected: [server, serverChild], stops: [server]),
            finding(.detachedWorker, "Detached worker", affected: [worker], stops: [worker]),
            // Another kind carrying a stop offer must never join a batch.
            finding(.highCPU, "Busy", affected: [busy], stops: [busy]),
        ]
        let result = candidates(findings)
        #expect(result.count == 1)
        #expect(result.first?.candidates.map(\.identity) == [server.identity, worker.identity])
        #expect(result.first?.candidates.map(\.finding.title) == ["Stale server", "Detached worker"])
        #expect(result.first?.candidates.first?.process == server)
    }

    @Test("A leftover finding without a .requestStop contributes nothing")
    func needsStopOffer() {
        let findings = [
            finding(.staleDevServer, "No stop offered", affected: [server], stops: []),
            finding(.detachedWorker, "Worker", affected: [worker], stops: [worker]),
        ]
        #expect(candidates(findings).flatMap(\.candidates).map(\.identity) == [worker.identity])
    }

    @Test("Candidates are grouped per project, in first-finding order")
    func groupedByProject() {
        let findings = [
            finding(.staleDevServer, "Site server", affected: [otherServer], stops: [otherServer]),
            finding(.staleDevServer, "App server", affected: [server], stops: [server]),
            finding(.detachedWorker, "App worker", affected: [worker], stops: [worker]),
        ]
        let result = candidates(findings)
        #expect(result.map(\.project) == [Self.site, Self.app])
        #expect(result.map(\.candidates.count) == [1, 2])
        #expect(result.last?.projectName == "app")
    }

    @Test("Stops whose process has no project are never batched")
    func noProjectExcluded() {
        let findings = [
            finding(.detachedWorker, "Loose worker", affected: [loose], stops: [loose]),
            finding(.detachedWorker, "App worker", affected: [worker], stops: [worker]),
        ]
        let result = candidates(findings)
        #expect(result.map(\.project) == [Self.app])
        #expect(!result.flatMap(\.candidates).contains { $0.identity == loose.identity })
    }

    @Test("Findings hidden by exclusions drop their candidates")
    func hiddenExcluded() {
        let hiddenServer = finding(.staleDevServer, "Server", affected: [server], stops: [server])
        let findings = [hiddenServer, finding(.detachedWorker, "Worker", affected: [worker], stops: [worker])]
        let result = candidates(findings, hidden: [hiddenServer.id])
        #expect(result.flatMap(\.candidates).map(\.identity) == [worker.identity])
        #expect(LeftoverCandidates.batches(findings: findings, groups: groups, processes: processes,
                                           hiddenFindingIDs: [hiddenServer.id]).isEmpty)
    }

    @Test("An identity offered twice is listed once, under its first finding")
    func deduplicated() {
        let findings = [
            finding(.staleDevServer, "First", affected: [server], stops: [server, server]),
            finding(.detachedWorker, "Second", affected: [server], stops: [server]),
            finding(.detachedWorker, "Worker", affected: [worker], stops: [worker]),
        ]
        let listed = candidates(findings).flatMap(\.candidates)
        #expect(listed.map(\.identity) == [server.identity, worker.identity])
        #expect(listed.first?.finding.title == "First")
    }

    @Test("Stops with no process sample are skipped")
    func missingSample() {
        let ghost = SyntheticSnapshots.process(pid: 999, name: "ghost", executablePath: "/usr/local/bin/node")
        let findings = [finding(.detachedWorker, "Ghost", affected: [ghost], stops: [ghost])]
        let ghostGroups = groups + [group(ghost, project: Self.app)]
        #expect(LeftoverCandidates.byProject(findings: findings, groups: ghostGroups, processes: processes).isEmpty)
    }

    @Test("A batch needs at least 2 candidates that pass eligibility")
    func minimumBatch() {
        let findings = [
            finding(.staleDevServer, "App server", affected: [server], stops: [server]),
            finding(.detachedWorker, "App worker", affected: [worker], stops: [worker]),
            finding(.staleDevServer, "Site server", affected: [otherServer], stops: [otherServer]),
        ]
        let batches = LeftoverCandidates.batches(findings: findings, groups: groups, processes: processes)
        #expect(batches.map(\.project) == [Self.app])
        #expect(batches.first?.candidates.count == 2)

        // One of the two becomes ineligible: the project drops below the minimum.
        let onlyServer = LeftoverCandidates.batches(findings: findings, groups: groups, processes: processes,
                                                    isEligible: { $0.identity != worker.identity })
        #expect(onlyServer.isEmpty)
        #expect(LeftoverCandidates.minimumBatchSize == 2)
    }
}
