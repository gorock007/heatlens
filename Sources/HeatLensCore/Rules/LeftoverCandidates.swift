import Foundation

/// One process a leftover finding already offers to stop, with what the confirmation shows.
public struct LeftoverCandidate: Identifiable, Hashable, Sendable {
    public var id: ProcessIdentity { identity }
    public let identity: ProcessIdentity
    public let process: ProcessSample
    /// The finding that offered the stop; its title labels the row.
    public let finding: DiagnosticFinding

    public init(identity: ProcessIdentity, process: ProcessSample, finding: DiagnosticFinding) {
        self.identity = identity
        self.process = process
        self.finding = finding
    }
}

/// Every stop the leftover findings of one project offer, in finding order.
public struct ProjectLeftovers: Identifiable, Hashable, Sendable {
    public var id: String { project.directory }
    public let project: ProjectAttribution
    public let candidates: [LeftoverCandidate]

    public init(project: ProjectAttribution, candidates: [LeftoverCandidate]) {
        self.project = project
        self.candidates = candidates
    }

    /// The folder's last path component, e.g. "portfolio-demo".
    public var projectName: String { (project.directory as NSString).lastPathComponent }
}

/// Groups the stops the rules already offer for leftovers by project, so one confirmation can
/// cover them. Pure: it never adds a candidate the rules didn't offer (PRD §6: age or PPID 1 is
/// never proof on its own), and each listed identity is still revalidated when it is stopped.
public enum LeftoverCandidates {
    /// The only finding kinds whose `.requestStop` can join a batch.
    public static let kinds: Set<FindingKind> = [.staleDevServer, .detachedWorker]
    /// A project needs at least this many stoppable leftovers before a batch is offered.
    public static let minimumBatchSize = 2

    /// Per project, every `.requestStop` offered by a visible `staleDevServer`/`detachedWorker`
    /// finding, de-duplicated by identity. Findings in `hiddenFindingIDs` (the user's exclusions)
    /// and stops whose process has no project or no sample are left out. Projects keep the order
    /// of their first finding.
    public static func byProject(findings: [DiagnosticFinding], groups: [ProcessGroup], processes: [ProcessSample],
                                 hiddenFindingIDs: Set<UUID> = []) -> [ProjectLeftovers] {
        let samples = Dictionary(processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []
        var projects: [String: ProjectAttribution] = [:]
        var candidates: [String: [LeftoverCandidate]] = [:]
        var seen = Set<ProcessIdentity>()

        for finding in findings {
            guard let kind = finding.kind, kinds.contains(kind), !hiddenFindingIDs.contains(finding.id) else { continue }
            for action in finding.recommendedActions {
                guard case .requestStop(let identity) = action, !seen.contains(identity),
                      let process = samples[identity],
                      let project = groups.first(where: { $0.members.contains(identity) })?.project else { continue }
                seen.insert(identity)
                let key = project.directory
                if projects[key] == nil {
                    projects[key] = project
                    order.append(key)
                }
                candidates[key, default: []].append(LeftoverCandidate(identity: identity, process: process, finding: finding))
            }
        }
        return order.compactMap { key in
            projects[key].map { ProjectLeftovers(project: $0, candidates: candidates[key] ?? []) }
        }
    }

    /// The projects a batch stop may be offered for: candidates `isEligible` rejects are dropped,
    /// then only projects with at least `minimumBatchSize` left are kept.
    public static func batches(findings: [DiagnosticFinding], groups: [ProcessGroup], processes: [ProcessSample],
                               hiddenFindingIDs: Set<UUID> = [],
                               isEligible: (ProcessSample) -> Bool = { _ in true }) -> [ProjectLeftovers] {
        byProject(findings: findings, groups: groups, processes: processes, hiddenFindingIDs: hiddenFindingIDs)
            .map { ProjectLeftovers(project: $0.project, candidates: $0.candidates.filter { isEligible($0.process) }) }
            .filter { $0.candidates.count >= minimumBatchSize }
    }
}
