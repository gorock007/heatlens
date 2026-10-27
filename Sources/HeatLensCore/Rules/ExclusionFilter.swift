import Foundation

/// The user's Settings exclusions: exact process names (case-insensitive) and project directory
/// prefixes (`~` expanded, matched on a path boundary). A finding is hidden only when every
/// process it names is excluded; findings without processes always stay.
public struct ExclusionFilter: Hashable, Sendable {
    public let processNames: [String]
    public let projectPrefixes: [String]

    public init(processNames: [String] = [], projectPrefixes: [String] = []) {
        self.processNames = processNames
        self.projectPrefixes = projectPrefixes
    }

    /// `findings` in their ranked order, minus the ones the exclusions hide.
    public func visibleFindings(_ findings: [DiagnosticFinding], snapshot: ScanSnapshot,
                                groups: [ProcessGroup]) -> [DiagnosticFinding] {
        let names = Dictionary(snapshot.processes.map { ($0.identity, $0.name) }, uniquingKeysWith: { first, _ in first })
        return findings.filter { finding in
            guard !finding.affectedProcesses.isEmpty else { return true }
            return !finding.affectedProcesses.allSatisfy { identity in
                let project = groups.first(where: { $0.members.contains(identity) })?.project
                return excludes(processName: names[identity], projectDirectory: project?.directory)
            }
        }
    }

    public func excludes(processName: String?, projectDirectory: String?) -> Bool {
        if let processName,
           processNames.contains(where: { $0.caseInsensitiveCompare(processName) == .orderedSame }) {
            return true
        }
        guard let projectDirectory else { return false }
        let path = Self.standardized(projectDirectory)
        return projectPrefixes.contains { prefix in
            let expanded = Self.standardized(prefix)
            return path == expanded || path.hasPrefix(expanded.hasSuffix("/") ? expanded : expanded + "/")
        }
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}
