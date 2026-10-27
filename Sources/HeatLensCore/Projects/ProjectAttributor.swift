import Foundation

/// A development project HeatLens attributed work to (PRD-v2 §7 `Project`).
public struct Project: Identifiable, Hashable, Codable, Sendable {
    /// The standardized root path, lowercased: one project per directory.
    public var id: String { root.lowercased() }
    public let name: String
    public let root: String
    public let confidence: Confidence
    /// Why this root: "git repository", "package.json", "user mapping", "working directory".
    public let basis: String

    public init(name: String, root: String, confidence: Confidence, basis: String) {
        self.name = name
        self.root = root
        self.confidence = confidence
        self.basis = basis
    }
}

/// A user-defined "this directory is that project" line from Settings: `~/Developer/FDA = FDA`.
/// Data only; matched by path prefix on whole components.
public struct ProjectMapping: Hashable, Sendable {
    public let root: String
    public let name: String

    /// One mapping per line: `path = Name` or just `path` (named after its last component).
    /// Paths must be absolute or start with `~/`. Returns the valid mappings and the lines it skipped.
    public static func parse(_ text: String, home: String = NSHomeDirectory()) -> (mappings: [ProjectMapping], invalid: [String]) {
        var mappings: [ProjectMapping] = []
        var invalid: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            var path = parts[0]
            if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
            guard path.hasPrefix("/"), path.count > 1 else { invalid.append(line); continue }
            let root = (path as NSString).standardizingPath
            let name = parts.count == 2 && !parts[1].isEmpty ? parts[1] : (root as NSString).lastPathComponent
            guard root != "/", (root as NSString).standardizingPath != (home as NSString).standardizingPath else {
                invalid.append(line); continue
            }
            mappings.append(ProjectMapping(root: root, name: String(name.prefix(80))))
        }
        return (mappings, invalid)
    }

    func contains(_ path: String) -> Bool {
        ProjectAttributor.isPath(path, inside: root)
    }
}

/// How one container was tied to a project, or why it wasn't.
public struct ContainerAttribution: Hashable, Sendable {
    public let containerID: String
    public let project: Project?
    public let evidence: Evidence
}

/// Turns process-group directories and container evidence into projects (brief 2a), then adds
/// up CPU and memory per project (brief 2b). Pure apart from the locator's stats.
public enum ProjectAttributor {
    /// Apple's Virtualization framework process that runs Docker Desktop's Linux VM. Its CPU *is*
    /// the containers' CPU, so container CPU is moved out of it, never added on top.
    public static let virtualMachineExecutable = "com.apple.Virtualization.VirtualMachine"

    /// The project for a directory found from a process's cwd or argv: a user mapping first, then
    /// the repository root above it, then the directory itself (lower confidence).
    public static func project(forDirectory directory: String, attribution: Confidence, mappings: [ProjectMapping],
                               locator: ProjectRootLocator) -> Project {
        if let mapping = longestMapping(for: directory, in: mappings) {
            return Project(name: mapping.name, root: mapping.root, confidence: .high, basis: "user mapping")
        }
        if let root = locator.root(for: directory) {
            let basis = root.marker == ProjectRootLocator.repositoryMarker ? "git repository" : root.marker
            return Project(name: (root.path as NSString).lastPathComponent, root: root.path, confidence: attribution, basis: basis)
        }
        return Project(name: (directory as NSString).lastPathComponent, root: directory,
                       confidence: attribution == .high ? .medium : .low, basis: "working directory")
    }

    /// Evidence order: a user mapping over any container path, Compose's `working_dir` label,
    /// the Compose file's folder, then bind mounts that all point into one project. Anything
    /// else is unattributed, never guessed from a name.
    public static func attribute(_ container: ContainerSample, mappings: [ProjectMapping], locator: ProjectRootLocator,
                                 home: String = NSHomeDirectory()) -> ContainerAttribution {
        let configDirectory = container.labels["com.docker.compose.project.config_files"]?
            .split(separator: ",").first.map { (String($0).trimmingCharacters(in: .whitespaces) as NSString).deletingLastPathComponent }
        let composePaths = [container.composeWorkingDirectory, configDirectory].compactMap { $0 }.filter { $0.hasPrefix("/") }
        let binds = container.bindMountSources.filter { usableBindSource($0, home: home) }

        for path in composePaths + binds {
            if let mapping = longestMapping(for: path, in: mappings) {
                return ContainerAttribution(containerID: container.containerID,
                                            project: Project(name: mapping.name, root: mapping.root, confidence: .high, basis: "user mapping"),
                                            evidence: Evidence(label: "Project", value: mapping.name, source: "user mapping of a container path"))
            }
        }
        if let working = container.composeWorkingDirectory, working.hasPrefix("/") {
            let project = project(forDirectory: working, attribution: .high, mappings: [], locator: locator)
            return ContainerAttribution(containerID: container.containerID, project: project,
                                        evidence: Evidence(label: "Project", value: project.name, source: "Compose working_dir label"))
        }
        if let configDirectory, configDirectory.hasPrefix("/") {
            let project = project(forDirectory: configDirectory, attribution: .high, mappings: [], locator: locator)
            return ContainerAttribution(containerID: container.containerID, project: project,
                                        evidence: Evidence(label: "Project", value: project.name, source: "Compose config_files label"))
        }
        let bindProjects = Set(binds.compactMap { locator.root(for: $0)?.path })
        if bindProjects.count == 1, let root = bindProjects.first {
            let project = project(forDirectory: root, attribution: .medium, mappings: [], locator: locator)
            return ContainerAttribution(containerID: container.containerID, project: project,
                                        evidence: Evidence(label: "Project", value: project.name, source: "bind mount"))
        }
        let reason = bindProjects.count > 1
            ? "bind mounts point into \(bindProjects.count) projects"
            : (container.composeProject.map { "Compose project \"\($0)\" has no working_dir label" } ?? "no Compose labels or project bind mounts")
        return ContainerAttribution(containerID: container.containerID, project: nil,
                                    evidence: Evidence(label: "Project", value: "Unattributed", source: reason))
    }

    /// Bind sources worth resolving: absolute, not the Docker socket, not system or temp paths.
    static func usableBindSource(_ path: String, home: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasSuffix(".sock") else { return false }
        let lower = path.lowercased()
        let excluded = ["/var", "/private", "/tmp", "/etc", "/usr", "/dev", "/run", "/system", "/library"]
        if excluded.contains(where: { lower == $0 || lower.hasPrefix($0 + "/") }) { return false }
        let homeLower = (home as NSString).standardizingPath.lowercased()
        if lower.hasPrefix(homeLower + "/.") { return false }
        return true
    }

    static func longestMapping(for path: String, in mappings: [ProjectMapping]) -> ProjectMapping? {
        mappings.filter { $0.contains(path) }.max { $0.root.count < $1.root.count }
    }

    static func isPath(_ path: String, inside root: String) -> Bool {
        let path = (path as NSString).standardizingPath.lowercased()
        let root = root.lowercased()
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
