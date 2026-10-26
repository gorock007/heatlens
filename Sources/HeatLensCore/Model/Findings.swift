import Foundation

public enum Severity: String, Hashable, Codable, Sendable, Comparable {
    case info, review, medium, high
    private var rank: Int { [Severity.info, .review, .medium, .high].firstIndex(of: self) ?? 0 }
    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

public enum Confidence: String, Hashable, Codable, Sendable {
    case low, medium, high
}

/// One observed fact backing a label or finding (PRD §4.2: raw evidence for every inference).
public struct Evidence: Hashable, Codable, Sendable {
    public let label: String
    public let value: String
    /// Where it came from, e.g. "proc_pidinfo", "argv", "cwd", "host_processor_info".
    public let source: String

    public init(label: String, value: String, source: String) {
        self.label = label
        self.value = value
        self.source = source
    }
}

/// Actions the UI may offer. Nothing here executes anything; Phase 2 implements `requestStop`.
public enum SuggestedAction: Hashable, Codable, Sendable {
    case inspect(ProcessIdentity)
    case openProject(path: String)
    case copyCommand(ProcessIdentity)
    case openActivityMonitor
    case copyReport
    case requestStop(ProcessIdentity)
}

/// PRD §4.3 output type.
public struct DiagnosticFinding: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let title: String
    public let severity: Severity
    public let confidence: Confidence
    public let explanation: String
    public let evidence: [Evidence]
    public let limitations: [String]
    public let affectedProcesses: [ProcessIdentity]
    public let recommendedActions: [SuggestedAction]

    public init(id: UUID = UUID(), title: String, severity: Severity, confidence: Confidence, explanation: String,
                evidence: [Evidence], limitations: [String], affectedProcesses: [ProcessIdentity],
                recommendedActions: [SuggestedAction]) {
        self.id = id
        self.title = title
        self.severity = severity
        self.confidence = confidence
        self.explanation = explanation
        self.evidence = evidence
        self.limitations = limitations
        self.affectedProcesses = affectedProcesses
        self.recommendedActions = recommendedActions
    }
}

/// A project directory inferred for a process group (PRD §4.2). Absent → "Unknown project".
public struct ProjectAttribution: Hashable, Codable, Sendable {
    public let directory: String
    /// "cwd" or "argv path"; never from reading files.
    public let basis: String
    public let confidence: Confidence

    public init(directory: String, basis: String, confidence: Confidence) {
        self.directory = directory
        self.basis = basis
        self.confidence = confidence
    }
}

/// Output of the ProvenanceResolver: processes grouped by parent tree and tool hints.
public struct ProcessGroup: Identifiable, Hashable, Codable, Sendable {
    public var id: ProcessIdentity { root }
    public let root: ProcessIdentity
    public let members: [ProcessIdentity]
    /// e.g. "next dev", "vitest", "claude", "opencode", "superset", "docker", "node script", "app", "unknown".
    public let kind: String
    public let label: String
    public let project: ProjectAttribution?
    public let confidence: Confidence
    public let evidence: [Evidence]

    public init(root: ProcessIdentity, members: [ProcessIdentity], kind: String, label: String,
                project: ProjectAttribution?, confidence: Confidence, evidence: [Evidence]) {
        self.root = root
        self.members = members
        self.kind = kind
        self.label = label
        self.project = project
        self.confidence = confidence
        self.evidence = evidence
    }
}
