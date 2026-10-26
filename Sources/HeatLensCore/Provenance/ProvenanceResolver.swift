import Foundation

/// Turns a flat process snapshot into workload groups using only captured data.
public enum ProvenanceResolver {
    public static func resolve(_ snapshot: ScanSnapshot) -> [ProcessGroup] {
        guard !snapshot.processes.isEmpty else { return [] }

        let processesByPID = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0) })
        let classifications = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, classify($0)) })
        let bundles = Dictionary(uniqueKeysWithValues: snapshot.processes.compactMap { process in
            appBundle(for: process).map { (process.pid, $0) }
        })
        let anchors = Set(snapshot.processes.compactMap { process in
            classifications[process.pid]?.isAnchor == true ? process.pid : nil
        })

        var keysByPID: [Int32: GroupingKey] = [:]
        var ordinaryMembersByRoot: [Int32: [ProcessSample]] = [:]

        for process in snapshot.processes {
            let bundle = bundles[process.pid]
            // Root/other-user Apple paths are system services even when the executable happens
            // to live inside one of Apple's own .app bundles. Per-user agents embedded below
            // /System/Library are services too; actual user-launched app bundles retain their
            // application identity.
            let isPerUserSystemService = process.executablePath?.hasPrefix("/System/Library/") == true
            if isAppleService(process),
               process.owner == .root || process.owner == .otherUser || bundle == nil || isPerUserSystemService {
                if isSystemException(process) {
                    keysByPID[process.pid] = .tree(process.pid)
                } else if process.owner == .root || process.owner == .otherUser {
                    keysByPID[process.pid] = .systemServices
                } else {
                    keysByPID[process.pid] = .userServices
                }
                continue
            }
            if let bundle {
                keysByPID[process.pid] = .app(bundle.key)
                continue
            }

            let rootPID = groupRoot(
                for: process,
                processesByPID: processesByPID,
                classifications: classifications,
                anchors: anchors
            )
            if let bundle = bundles[rootPID], classifications[rootPID]?.kind != "app" {
                keysByPID[process.pid] = .app(bundle.key)
            } else {
                ordinaryMembersByRoot[rootPID, default: []].append(process)
            }
        }

        // Keep a distinct group when ancestry has a named workload anchor or honest project
        // evidence. Coalesce only otherwise-anonymous launchd branches, which are not useful as
        // hundreds of individual groups.
        for (rootPID, members) in ordinaryMembersByRoot {
            let root = processesByPID[rootPID] ?? members.min { $0.pid < $1.pid }!
            let hasAnchor = members.contains { classifications[$0.pid]?.isAnchor == true }
            let project = projectAttribution(root: root, members: members, classifications: classifications)
            let workload = representative(in: members, classifications: classifications).classification
            let key: GroupingKey
            if let project {
                let identity = workload.kind == "unknown"
                    ? "unknown"
                    : workload.kind + "|" + workload.label.lowercased()
                key = .workload(identity, project.directory.lowercased())
            } else if hasAnchor, workload.kind != "system" {
                key = .workload(workload.kind + "|" + workload.label.lowercased(), "")
            } else {
                key = .background(backgroundOwner(for: members))
            }
            for member in members {
                keysByPID[member.pid] = key
            }
        }

        var membersByKey: [GroupingKey: [ProcessSample]] = [:]
        for process in snapshot.processes {
            guard let key = keysByPID[process.pid] else { continue }
            membersByKey[key, default: []].append(process)
        }

        return membersByKey.compactMap { key, unsortedMembers in
            let members = unsortedMembers.sorted { $0.pid < $1.pid }
            guard let root = groupRoot(for: key, members: members, processesByPID: processesByPID, bundles: bundles) else {
                return nil
            }
            let representative = representative(in: members, classifications: classifications)
            let presentation = presentation(
                for: key,
                root: root,
                representative: representative,
                bundles: bundles
            )
            let project = projectAttribution(root: root, members: members, classifications: classifications)

            var evidence = [presentation.evidence]
            if presentation.evidence != representative.classification.evidence {
                evidence.append(representative.classification.evidence)
            }
            if representative.process.pid != root.pid {
                evidence.append(Evidence(
                    label: "Grouping root",
                    value: "PID \(root.pid) groups PID \(representative.process.pid)",
                    source: "parent tree or workload family"
                ))
            }
            if let project {
                evidence.append(Evidence(label: "Project", value: project.directory, source: project.basis))
            } else {
                evidence.append(Evidence(label: "Project", value: "Unknown project", source: "cwd and argv unavailable or inconclusive"))
            }

            return ProcessGroup(
                root: root.identity,
                members: members.map(\.identity),
                kind: presentation.kind,
                label: presentation.label,
                project: project,
                confidence: presentation.confidence,
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
    let label: String
    let confidence: Confidence
    let evidence: Evidence
    let priority: Int
    let isAnchor: Bool
}

private struct AppBundle {
    let key: String
    let name: String
    let path: String
}

private enum GroupingKey: Hashable {
    case app(String)
    case systemServices
    case userServices
    case tree(Int32)
    case workload(String, String)
    case background(ProcessOwner)
}

private struct Presentation {
    let kind: String
    let label: String
    let confidence: Confidence
    let evidence: Evidence
}

private extension ProvenanceResolver {
    static let scriptExtensions = [".js", ".mjs", ".cjs", ".ts", ".mts", ".py"]
    static let packageRunners = Set(["npm", "pnpm", "yarn", "npx"])
    static let devAndBuildKinds = Set(["next dev", "vite", "astro", "webpack", "turbo", "vitest", "jest", "tsc --watch"])
    static let protectedSystemNames = Set(["kernel_task", "windowserver"])
    static let appleServicePrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

    static func classify(_ process: ProcessSample) -> Classification {
        let argv = process.arguments ?? []
        let executable = basename(process.executablePath ?? argv.first ?? process.name).lowercased()
        let tokens = argv.map { basename($0).lowercased() }
        let argumentPaths = argv.map { $0.lowercased() }

        func result(
            _ kind: String,
            label: String? = nil,
            _ confidence: Confidence,
            _ value: String,
            _ source: String,
            _ priority: Int,
            anchor: Bool = true
        ) -> Classification {
            Classification(
                kind: kind,
                label: label ?? kind,
                confidence: confidence,
                evidence: Evidence(label: "Workload label", value: value, source: source),
                priority: priority,
                isAnchor: anchor
            )
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
            return result("package runner", label: executable, .medium, "\(executable) executable", "executable name", 60)
        }
        if executable == "bun" {
            return result("bun", .high, "bun executable", "executable name", 75)
        }
        if executable == "node" {
            if let script = argv.dropFirst().first(where: isScriptPath) {
                let scriptName = basename(script)
                return result("node script", label: "node \(scriptName)", .medium, scriptName, "argv script path", 75)
            }
            if appBundle(path: process.executablePath) != nil {
                return result("app", label: process.name, .high, process.executablePath ?? process.name, "application executable path", 40, anchor: false)
            }
            return result("unknown", label: processName(process), .low, "node executable without script evidence", "executable name", 0, anchor: false)
        }

        let protectedNames = protectedSystemNames.union(["launchd"])
        if process.owner == .root || protectedNames.contains(process.name.lowercased()) || protectedNames.contains(executable) {
            return result("system", label: processName(process), process.owner == .root ? .high : .medium, process.name, "owner and process name", 20)
        }
        if appBundle(path: process.executablePath) != nil {
            return result("app", label: process.name, .high, process.executablePath ?? process.name, "application executable path", 40, anchor: false)
        }
        return result("unknown", label: processName(process), .low, process.name, "process name; no known tool hint", 0, anchor: false)
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
        // A generic app bundle is grouped by bundle path, not used as the ancestor root of a
        // shell or unrelated helper which happens to descend from the app.
        return chain.last(where: { $0.pid != 1 && classifications[$0.pid]?.kind != "app" })?.pid ?? process.pid
    }

    static func groupRoot(
        for key: GroupingKey,
        members: [ProcessSample],
        processesByPID: [Int32: ProcessSample],
        bundles: [Int32: AppBundle]
    ) -> ProcessSample? {
        switch key {
        case .tree(let pid):
            return members.first(where: { $0.pid == pid }) ?? processesByPID[pid] ?? members.first
        case .app(let bundleKey):
            let bundleName = members.compactMap { bundles[$0.pid] }.first(where: { $0.key == bundleKey })?.name.lowercased()
            return members.first(where: { $0.name.lowercased() == bundleName }) ?? members.first
        case .systemServices, .userServices, .workload, .background:
            return members.first
        }
    }

    static func representative(
        in members: [ProcessSample],
        classifications: [Int32: Classification]
    ) -> (process: ProcessSample, classification: Classification) {
        members.compactMap { process -> (ProcessSample, Classification)? in
            classifications[process.pid].map { (process, $0) }
        }
        .max { lhs, rhs in
            if lhs.1.priority != rhs.1.priority { return lhs.1.priority < rhs.1.priority }
            return lhs.0.pid > rhs.0.pid
        } ?? (members[0], classify(members[0]))
    }

    static func presentation(
        for key: GroupingKey,
        root: ProcessSample,
        representative: (process: ProcessSample, classification: Classification),
        bundles: [Int32: AppBundle]
    ) -> Presentation {
        switch key {
        case .app(let bundleKey):
            let bundle = bundles.values.first(where: { $0.key == bundleKey })
            let specificKind = representative.classification.kind
            return Presentation(
                kind: specificKind == "app" || specificKind == "unknown" ? "app" : specificKind,
                label: bundle?.name ?? processName(root),
                confidence: .high,
                evidence: Evidence(label: "Application bundle", value: bundle?.path ?? processName(root), source: "executable path")
            )
        case .systemServices:
            return Presentation(
                kind: "system",
                label: "macOS system services",
                confidence: .high,
                evidence: Evidence(label: "System service family", value: "Apple root and other-user services", source: "owner and executable path")
            )
        case .userServices:
            return Presentation(
                kind: "system",
                label: "macOS user services",
                confidence: .high,
                evidence: Evidence(label: "System service family", value: "Apple per-user services", source: "executable path")
            )
        case .background(let owner):
            let label: String
            switch owner {
            case .currentUser: label = "Background processes"
            case .root: label = "Root background processes"
            case .otherUser: label = "Other-user background processes"
            case .unknown: label = "Unclassified background processes"
            }
            return Presentation(
                kind: "unknown",
                label: label,
                confidence: .low,
                evidence: Evidence(label: "Workload family", value: label, source: "owner and absence of project or tool evidence")
            )
        case .workload(let identity, _) where identity == "unknown":
            return Presentation(
                kind: "unknown",
                label: "Project processes",
                confidence: .low,
                evidence: Evidence(label: "Workload family", value: "Unclassified processes with the same project", source: "cwd or argv path")
            )
        case .tree, .workload:
            return Presentation(
                kind: representative.classification.kind,
                label: representative.classification.label,
                confidence: representative.classification.confidence,
                evidence: representative.classification.evidence
            )
        }
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
            if let directory = argv.dropFirst().compactMap(projectDirectoryFromArgument).first {
                return ProjectAttribution(directory: directory, basis: "argv path", confidence: .medium)
            }
        }
        return nil
    }

    static func usableProjectDirectory(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let standardized = (path as NSString).standardizingPath
        guard standardized != "/", !isLikelyHomeDirectory(standardized) else { return nil }

        let components = standardized.split(separator: "/").map(String.init)
        if let special = supersetProjectDirectory(components) {
            return "/" + special.joined(separator: "/")
        }

        if components.count >= 3,
           ["Users", "home"].contains(components[0]),
           components[2].lowercased() == "library" {
            return nil
        }
        guard !components.contains(where: { $0.hasPrefix(".") }) else { return nil }
        let lowercased = standardized.lowercased()
        let excluded = [
            "/library", "/system", "/private", "/var", "/tmp", "/usr",
            "/applications", "/opt/homebrew", "/bin", "/sbin",
        ]
        guard !excluded.contains(where: { hasPathPrefix(lowercased, prefix: $0) }) else { return nil }
        return standardized
    }

    static func supersetProjectDirectory(_ components: [String]) -> ArraySlice<String>? {
        guard components.count >= 5,
              ["Users", "home"].contains(components[0]),
              components[2] == ".superset" else { return nil }
        if components[3] == "projects", !components[4].hasPrefix(".") {
            return components.prefix(5)
        }
        if components[3] == "worktrees", components.count >= 6,
           !components[4].hasPrefix("."), !components[5].hasPrefix(".") {
            return components.prefix(6)
        }
        return nil
    }

    static func projectDirectoryFromArgument(_ value: String) -> String? {
        guard value.hasPrefix("/") else { return nil }
        let standardized = (value as NSString).standardizingPath
        let marker = "/node_modules/"
        let candidate: String
        if let range = standardized.range(of: marker) {
            candidate = String(standardized[..<range.lowerBound])
        } else {
            candidate = (standardized as NSString).deletingLastPathComponent
        }
        return usableProjectDirectory(candidate)
    }

    static func isLikelyHomeDirectory(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return false }
        return parts[0] == "Users" || parts[0] == "home" || (parts[0] == "var" && parts[1] == "root")
    }

    static func appBundle(for process: ProcessSample) -> AppBundle? {
        appBundle(path: process.executablePath)
    }

    static func appBundle(path: String?) -> AppBundle? {
        guard let path, path.hasPrefix("/") else { return nil }
        let standardized = (path as NSString).standardizingPath
        let components = (standardized as NSString).pathComponents
        var accumulated = ""
        for component in components {
            if component == "/" {
                accumulated = "/"
            } else {
                accumulated = accumulated == "/" ? "/\(component)" : "\(accumulated)/\(component)"
            }
            if component.lowercased().hasSuffix(".app") {
                let name = String(component.dropLast(4))
                return AppBundle(key: accumulated.lowercased(), name: name, path: accumulated)
            }
        }
        return nil
    }

    static func isAppleService(_ process: ProcessSample) -> Bool {
        guard let path = process.executablePath else { return false }
        return appleServicePrefixes.contains(where: { path.hasPrefix($0) })
    }

    static func isSystemException(_ process: ProcessSample) -> Bool {
        protectedSystemNames.contains(process.name.lowercased()) || (process.cpuPercentOfOneCore ?? 0) >= 10
    }

    static func backgroundOwner(for members: [ProcessSample]) -> ProcessOwner {
        if members.contains(where: { $0.owner == .currentUser }) { return .currentUser }
        if members.contains(where: { $0.owner == .root }) { return .root }
        if members.contains(where: { $0.owner == .otherUser }) { return .otherUser }
        return .unknown
    }

    static func hasPathPrefix(_ path: String, prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    static func processName(_ process: ProcessSample) -> String {
        let trimmed = process.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let executablePath = process.executablePath, !basename(executablePath).isEmpty {
            return basename(executablePath)
        }
        return "Process \(process.pid)"
    }

    static func basename(_ value: String) -> String {
        (value as NSString).lastPathComponent
    }

    static func isScriptPath(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return scriptExtensions.contains(where: lowercased.hasSuffix)
    }
}
