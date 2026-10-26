import Foundation

/// One finished scan: the raw snapshot, its process groups and the ranked findings.
public struct ScanResult: Sendable {
    public let snapshot: ScanSnapshot
    public let groups: [ProcessGroup]
    /// Ranked impact-first; the array order is the display order.
    public let findings: [DiagnosticFinding]

    public init(snapshot: ScanSnapshot, groups: [ProcessGroup], findings: [DiagnosticFinding]) {
        self.snapshot = snapshot
        self.groups = groups
        self.findings = findings
    }
}

/// The one composition point shared by the app and the probe:
/// `ScanCoordinator.scan` → `ProvenanceResolver.resolve` → `RulesEngine.evaluate`.
public struct ScanPipeline: Sendable {
    public let coordinator: ScanCoordinator
    public let rules: RulesEngine

    public init(coordinator: ScanCoordinator = ScanCoordinator(), rules: RulesEngine = RulesEngine()) {
        self.coordinator = coordinator
        self.rules = rules
    }

    /// Throws whatever the coordinator throws (`CancellationError`, `ScanError`); a task cancelled
    /// after sampling still throws rather than returning a result nobody asked for.
    public func run(duration: TimeInterval, progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> ScanResult {
        let snapshot = try await coordinator.scan(duration: duration, progress: progress)
        try Task.checkCancellation()
        let groups = ProvenanceResolver.resolve(snapshot)
        let findings = rules.evaluate(snapshot, groups: groups)
        return ScanResult(snapshot: snapshot, groups: groups, findings: findings)
    }
}
