import Foundation

/// Turns a flat process snapshot into workload groups using only captured data.
public enum ProvenanceResolver {
    public static func resolve(_ snapshot: ScanSnapshot) -> [ProcessGroup] {
        guard !snapshot.processes.isEmpty else { return [] }

        let processesByPID = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0) })
        let classifications = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, classify($0)) })
        let anchors = Set(snapshot.processes.compactMap { process in
            classifications[process.pid]?.isAnchor == true ? process.pid : nil
        })

        var membersByRoot: [Int32: [ProcessSample]] = [:]
        for process in snapshot.processes {
            let rootPID = groupRoot(
                for: process,
                processesByPID: processesByPID,
                classifications: classifications,
                anchors: anchors
            )
            membersByRoot[rootPID, default: []].append(process)
        }

        return membersByRoot.compactMap { rootPID, unsortedMembers in
            guard let root = processesByPID[rootPID] else { return nil }
            let members = unsortedMembers.sorted { $0.pid < $1.pid }
            let representative = members
                .compactMap { process -> (ProcessSample, Classification)? in
                    guard let classification = classifications[process.pid] else { return nil }
                    return (process, classification)
                }
                .max { lhs, rhs in
                    if lhs.1.priority != rhs.1.priority { return lhs.1.priority < rhs.1.priority }
                    return lhs.0.pid > rhs.0.pid
                } ?? (root, classify(root))
            let project = projectAttribution(root: root, members: members, classifications: classifications)

            var evidence = [representative.1.evidence]
            if representative.0.pid != root.pid {
                evidence.append(Evidence(
                    label: "Grouping root",
                    value: "PID \(root.pid) is an ancestor of PID \(representative.0.pid)",
                    source: "parent tree"
                ))
            }
            if let project {
                evidence.append(Evidence(label: "Project", value: project.directory, source: project.basis))
            } else {
                evidence.append(Evidence(label: "Project", value: "Unknown project", source: "cwd and argv unavailable or inconclusive"))
            }

            let projectName = project.map { URL(fileURLWithPath: $0.directory).lastPathComponent } ?? "Unknown project"
            return ProcessGroup(
                root: root.identity,
                members: members.map(\.identity),
                kind: representative.1.kind,
                label: "\(representative.1.kind) — \(projectName)",
                project: project,
                confidence: representative.1.confidence,
                evidence: evidence
            )
        }
        .sorted {
            if $0.root.pid != $1.root.pid { return $0.root.pid < $1.root.pid }
            return $0.label < $1.label
        }
    }
}

private struct Classification {
    let kind: String
    let confidence: Confidence
    let evidence: Evidence
    let priority: Int
    let isAnchor: Bool
}

private extension ProvenanceResolver {
    static let scriptExtensions = [".js", ".mjs", ".cjs", ".ts", ".mts", ".py"]
    static let packageRunners = Set(["npm", "pnpm", "yarn", "npx"])
    static let devAndBuildKinds = Set(["next dev", "vite", "astro", "webpack", "turbo", "vitest", "jest", "tsc --watch"])

    static func classify(_ process: ProcessSample) -> Classification {
        let argv = process.arguments ?? []
        let executable = basename(process.executablePath ?? argv.first ?? process.name).lowercased()
        let tokens = argv.map { basename($0).lowercased() }
        let path = (process.executablePath ?? "").lowercased()
        let argumentPaths = argv.map { $0.lowercased() }

        func result(_ kind: String, _ confidence: Confidence, _ value: String, _ source: String, _ priority: Int, anchor: Bool = true) -> Classification {
            Classification(
                kind: kind,
                confidence: confidence,
                evidence: Evidence(label: "Workload label", value: value, source: source),
                priority: priority,
                isAnchor: anchor
            )
        }

        if path.contains("capcut.app/") || process.name.lowercased().contains("capcut") {
            return result("capcut", .high, "CapCut application path or process name", "executable path", 80)
        }
        if path.contains("superset.app/") || path.contains("/superset/") {
            return result("superset", .high, "Superset application path", "executable path", 70)
        }
        if executable.hasPrefix("docker") || executable.hasPrefix("com.docker") || path.contains("docker.app/") {
            return result("docker", .high, "Docker executable or application path", "executable path", 70)
        }
        if executable == "claude" || executable == "claude.exe" || tokens.first == "claude" || tokens.contains("claude")
            || argumentPaths.contains(where: { $0.contains("/@anthropic-ai/claude-code/") }) {
            return result("claude", .high, "claude executable token", "argv token", 90)
        }
        if executable.hasPrefix("opencode") || tokens.contains(where: { $0.hasPrefix("opencode") }) {
            return result("opencode", .high, "opencode executable token", "argv token", 90)
        }
        if tokens.first?.hasPrefix("next-server") == true || (tokens.contains("next") && argv.contains("dev")) {
            return result("next dev", .high, "next and dev argv tokens", "argv tokens", 100)
        }
        for tool in ["vite", "astro", "webpack", "turbo", "vitest", "jest"] where tokens.contains(tool) {
            return result(tool, .high, "\(tool) argv token", "argv token", tool == "vitest" || tool == "jest" ? 98 : 96)
        }
        if tokens.contains("tsc"), argv.contains("--watch") || argv.contains("-w") {
            return result("tsc --watch", .high, "tsc and watch argv tokens", "argv tokens", 96)
        }
        if packageRunners.contains(executable) || tokens.first.map(packageRunners.contains) == true {
            return result("package runner", .medium, "\(executable) executable", "executable name", 60)
        }
        if executable == "bun" {
            return result("bun", .high, "bun executable", "executable name", 75)
        }
        if executable == "node" {
            if let script = argv.dropFirst().first(where: isScriptPath) {
                return result("node script", .medium, basename(script), "argv script path", 75)
            }
            if path.contains(".app/") {
                return result("app", .high, process.executablePath ?? process.name, "application executable path", 40)
            }
            return result("unknown", .low, "node executable without script evidence", "executable name", 0, anchor: false)
        }

        let protectedNames = Set(["kernel_task", "windowserver", "launchd"])
        if process.owner == .root || protectedNames.contains(process.name.lowercased()) || protectedNames.contains(executable) {
            return result("system", process.owner == .root ? .high : .medium, process.name, "owner and process name", 20)
        }
        if path.contains(".app/") || path.hasSuffix(".app") || path.hasPrefix("/applications/") {
            return result("app", .high, process.executablePath ?? process.name, "executable path", 40)
        }
        return result("unknown", .low, process.name, "process name; no known tool hint", 0, anchor: false)
    }

    static func groupRoot(
        for process: ProcessSample,
        processesByPID: [Int32: ProcessSample],
        classifications: [Int32: Classification],
        anchors: Set<Int32>
    ) -> Int32 {
        var chain: [ProcessSample] = []
        var current: ProcessSample? = process
        var seen: Set<Int32> = []
        while let item = current, seen.insert(item.pid).inserted {
            chain.append(item)
            guard item.parentPID > 1 else { break }
            current = processesByPID[item.parentPID]
        }

        if let ownClassification = classifications[process.pid], devAndBuildKinds.contains(ownClassification.kind),
           let runner = chain.dropFirst().first(where: { classifications[$0.pid]?.kind == "package runner" }) {
            return runner.pid
        }
        if let ownClassification = classifications[process.pid], ["unknown", "package runner"].contains(ownClassification.kind),
           let nearestAnchor = chain.first(where: { anchors.contains($0.pid) }),
           classifications[nearestAnchor.pid]?.kind == "package runner",
           let agent = chain.first(where: { ["claude", "opencode"].contains(classifications[$0.pid]?.kind ?? "") }) {
            return agent.pid
        }
        if let nearestAnchor = chain.first(where: { anchors.contains($0.pid) }) {
            return nearestAnchor.pid
        }
        return chain.last(where: { $0.pid != 1 })?.pid ?? process.pid
    }

    static func projectAttribution(
        root: ProcessSample,
        members: [ProcessSample],
        classifications: [Int32: Classification]
    ) -> ProjectAttribution? {
        let ordered = [root] + members.filter { $0.pid != root.pid }.sorted {
            (classifications[$0.pid]?.priority ?? 0) > (classifications[$1.pid]?.priority ?? 0)
        }
        for process in ordered {
            if let cwd = usableProjectDirectory(process.currentDirectory) {
                return ProjectAttribution(directory: cwd, basis: "cwd", confidence: .high)
            }
        }
        for process in ordered {
            guard let argv = process.arguments else { continue }
            if let path = argv.dropFirst().first(where: isProjectArgumentPath) {
                return ProjectAttribution(
                    directory: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                    basis: "argv path",
                    confidence: .medium
                )
            }
        }
        return nil
    }

    static func usableProjectDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty, path != "/", !isLikelyHomeDirectory(path) else { return nil }
        return path
    }

    static func isLikelyHomeDirectory(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return false }
        return parts[0] == "Users" || parts[0] == "home" || (parts[0] == "var" && parts[1] == "root")
    }

    static func basename(_ value: String) -> String {
        (value as NSString).lastPathComponent
    }

    static func isScriptPath(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return scriptExtensions.contains(where: lowercased.hasSuffix)
    }

    static func isProjectArgumentPath(_ value: String) -> Bool {
        guard value.hasPrefix("/") else { return false }
        let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/", "/Applications/"]
        return !systemPrefixes.contains(where: value.hasPrefix)
    }
}
