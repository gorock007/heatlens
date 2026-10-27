import Foundation

/// A user-defined label: processes whose name, executable or an argv token matches `token`
/// (case-insensitive, whole file name) are grouped and labelled `label`. Data only: HeatLens
/// never runs anything from a rule. Rules apply to the current user's processes only, never to
/// root, other users or protected system processes.
public struct WorkloadRule: Hashable, Codable, Sendable {
    public static let maxRules = 50
    public static let maxTokenLength = 64
    public static let maxLabelLength = 60

    public let token: String
    public let label: String

    public init?(token: String, label: String) {
        let token = token.trimmingCharacters(in: .whitespaces)
        let label = label.trimmingCharacters(in: .whitespaces)
        guard (1...Self.maxTokenLength).contains(token.count), token.unicodeScalars.allSatisfy(Self.isTokenScalar),
              (1...Self.maxLabelLength).contains(label.count), !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        self.token = token.lowercased()
        self.label = label
    }

    static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._@+-".unicodeScalars.contains(scalar))
    }

    /// One rule per line: `token = Label`. Blank lines and `#` comments are skipped; any other
    /// line that doesn't parse is returned in `ignored`, so Settings can say which. At most
    /// `maxRules` rules; the rest are ignored.
    public static func parse(_ text: String) -> (rules: [WorkloadRule], ignored: [String]) {
        var rules: [WorkloadRule] = []
        var ignored: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "="),
                  let rule = WorkloadRule(token: String(line[..<equals]), label: String(line[line.index(after: equals)...])),
                  rules.count < maxRules else {
                ignored.append(line)
                continue
            }
            if !rules.contains(where: { $0.token == rule.token }) { rules.append(rule) }
        }
        return (rules, ignored)
    }
}

/// Parent/child structure of one snapshot, for the detail view's subtree.
public enum ProcessTree {
    public struct Node: Hashable, Sendable {
        public let process: ProcessSample
        /// 1 for a direct child.
        public let depth: Int
    }

    /// Descendants of `pid` in depth-first order, at most `maxDepth` levels and `maxCount` nodes.
    /// `truncated` is true when either limit cut the tree short. Cycles are ignored.
    public static func descendants(of pid: Int32, in processes: [ProcessSample], maxDepth: Int = 4,
                                   maxCount: Int = 40) -> (nodes: [Node], truncated: Bool) {
        let children = Dictionary(grouping: processes.filter { $0.pid != $0.parentPID }, by: \.parentPID)
            .mapValues { $0.sorted { $0.pid < $1.pid } }
        var nodes: [Node] = []
        var truncated = false
        var visited: Set<Int32> = [pid]
        func walk(_ parent: Int32, depth: Int) {
            for child in children[parent] ?? [] where visited.insert(child.pid).inserted {
                guard nodes.count < maxCount else { truncated = true; return }
                nodes.append(Node(process: child, depth: depth))
                if depth < maxDepth {
                    walk(child.pid, depth: depth + 1)
                } else if !(children[child.pid] ?? []).isEmpty {
                    truncated = true
                }
            }
        }
        walk(pid, depth: 1)
        return (nodes, truncated)
    }
}
