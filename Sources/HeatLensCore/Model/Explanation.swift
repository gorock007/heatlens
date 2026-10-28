import Foundation

/// HeatLens's plain-words reading of a burst of concurrent work (PRD-v2 Phase 3, brief 3b): the
/// timestamped facts behind it, how sure it is, what it can't know, and a non-destructive
/// recommendation. Always an inference; it never claims how much heat or power one process caused.
public struct Explanation: Hashable, Codable, Sendable, Identifiable {
    /// One timestamped fact: what started, when, where and under whom.
    public struct Observation: Hashable, Codable, Sendable {
        public let timestamp: Date
        public let evidence: Evidence

        public init(timestamp: Date, evidence: Evidence) {
            self.timestamp = timestamp
            self.evidence = evidence
        }
    }

    /// The coding agent a command runs under, keyed by the agent process. `root` is nil for
    /// commands with no agent ancestor (a person in a terminal).
    public struct AgentTree: Hashable, Codable, Sendable {
        public let name: String
        public let root: ProcessIdentity?

        public init(name: String, root: ProcessIdentity?) {
            self.name = name
            self.root = root
        }

        public static let noAgent = AgentTree(name: "no agent", root: nil)
        public var isAgent: Bool { root != nil }
    }

    public let id: String
    /// Made of command labels, container names, project names and agent names only: no paths, no argv.
    public let title: String
    /// Oldest first.
    public let observations: [Observation]
    public let confidence: Confidence
    /// One or two lines naming what HeatLens can't know.
    public let uncertainty: [String]
    /// Advice only; nothing here acts on a process.
    public let recommendation: String
    /// When the first command (or container) of the burst started.
    public let startedAt: Date
    /// When HeatLens first saw nothing in the burst still running; nil while it runs.
    public var endedAt: Date?
    /// Project names, sorted.
    public let projects: [String]
    public let agentTrees: [AgentTree]
    public let affected: [ProcessIdentity]
    public let containerIDs: [String]

    public init(id: String, title: String, observations: [Observation], confidence: Confidence, uncertainty: [String],
                recommendation: String, startedAt: Date, endedAt: Date? = nil, projects: [String], agentTrees: [AgentTree],
                affected: [ProcessIdentity], containerIDs: [String]) {
        self.id = id
        self.title = String(title.prefix(200))
        self.observations = observations
        self.confidence = confidence
        self.uncertainty = uncertainty
        self.recommendation = recommendation
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.projects = projects
        self.agentTrees = agentTrees
        self.affected = affected
        self.containerIDs = containerIDs
    }

    /// The timeline's record of this explanation, at the moment it was found.
    public func timelineEvent(at timestamp: Date) -> TimelineEvent {
        TimelineEvent(timestamp: timestamp, kind: .concurrencyExplained, title: title,
                      projectName: projects.count == 1 ? projects.first : nil, isInference: true)
    }
}
