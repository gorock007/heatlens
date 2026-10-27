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

/// The listening ports at one instant, grouped like a scan's, without a CPU sample.
public struct PortsSnapshot: Sendable {
    /// One process reading: every `cpu` is nil, `interval` is 0 and `system` is a placeholder.
    /// `listeningPorts` and `notices` (the refused-processes notice) are real.
    public let snapshot: ScanSnapshot
    public let groups: [ProcessGroup]

    public init(snapshot: ScanSnapshot, groups: [ProcessGroup]) {
        self.snapshot = snapshot
        self.groups = groups
    }

    /// One row per (port, process), sorted by port then PID.
    public var listings: [PortListing] { PortListing.listings(snapshot, groups: groups) }
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

    /// `ScanCoordinator.ports` → `ProvenanceResolver.resolve`, for `heatlens ports`. No rules run:
    /// they need CPU figures.
    public func ports() async throws -> PortsSnapshot {
        let snapshot = try await coordinator.ports()
        return PortsSnapshot(snapshot: snapshot, groups: ProvenanceResolver.resolve(snapshot))
    }
}
