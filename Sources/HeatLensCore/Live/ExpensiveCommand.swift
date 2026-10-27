import Foundation

/// Recognises commands that load a Mac hard for a while (brief 2e): installs, builds, test runs.
/// Data only, from process names and argv tokens; nothing is run.
public enum ExpensiveCommand {
    public enum Category: String, Hashable, Sendable {
        case test, build, install
    }

    public struct Match: Hashable, Sendable {
        /// e.g. "vitest", "npm ci", "next build", "docker build".
        public let label: String
        public let category: Category
    }

    static let packageManagers: Set<String> = ["npm", "pnpm", "yarn", "bun"]
    /// A process needs one of these tokens to be worth a closer look.
    static let triggers: Set<String> = packageManagers.union([
        "vitest", "jest", "pytest", "playwright", "next", "vite", "tsc", "webpack", "docker", "com.docker.cli",
        "docker-buildx", "buildx", "cargo", "swift", "go", "xcodebuild", "gradle", "gradlew",
    ])

    /// The first few argv tokens, split on spaces (npm sets its title to "npm ci"), as file names.
    static func tokens(_ process: ProcessSample) -> [String] {
        let argv = process.arguments ?? [process.name]
        return argv.prefix(8)
            .flatMap { $0.split(separator: " ", omittingEmptySubsequences: true).prefix(4) }
            .prefix(10)
            .map { (String($0) as NSString).lastPathComponent.lowercased() }
    }

    public static func classify(_ process: ProcessSample) -> Match? {
        guard process.owner == .currentUser else { return nil }
        let t = tokens(process)
        guard t.contains(where: triggers.contains) else { return nil }
        func after(_ word: String) -> String? {
            guard let index = t.firstIndex(of: word), index + 1 < t.count else { return nil }
            return t[index + 1]
        }
        // Test runners first: `npm test` that runs vitest reports as both, the outer one wins later.
        if t.contains("vitest") { return Match(label: "vitest", category: .test) }
        if t.contains("jest") { return Match(label: "jest", category: .test) }
        if t.contains("pytest") || (after("-m") == "pytest") { return Match(label: "pytest", category: .test) }
        if after("playwright") == "test" { return Match(label: "playwright test", category: .test) }
        if after("next") == "build" { return Match(label: "next build", category: .build) }
        if after("vite") == "build" { return Match(label: "vite build", category: .build) }
        if t.first == "tsc" || (t.count > 1 && t[1] == "tsc" && t[0].hasPrefix("node")) { return Match(label: "tsc", category: .build) }
        if t.contains("webpack") { return Match(label: "webpack", category: .build) }

        if let manager = t.first(where: { packageManagers.contains($0) }), let sub = after(manager) {
            switch sub {
            case "ci": return Match(label: "\(manager) ci", category: .install)
            case "install", "i", "add": return Match(label: "\(manager) install", category: .install)
            case "test", "t": return Match(label: "\(manager) test", category: .test)
            case "run":
                if let script = after("run"), ["build", "test"].contains(script) {
                    return Match(label: "\(manager) run \(script)", category: script == "test" ? .test : .build)
                }
            default:
                break
            }
        }
        // Bare `yarn` installs.
        if t == ["yarn"] || (t.count == 2 && t[0].hasPrefix("node") && t[1] == "yarn") {
            return Match(label: "yarn install", category: .install)
        }

        if t.contains("docker") || t.contains("com.docker.cli") {
            if after("docker") == "build" || after("buildx") == "build" { return Match(label: "docker build", category: .build) }
            if after("compose") == "build" { return Match(label: "docker compose build", category: .build) }
        }
        if t.first == "docker-buildx", t.contains("build") { return Match(label: "docker build", category: .build) }
        for tool in ["cargo", "swift", "go"] {
            if let sub = after(tool), ["build", "test"].contains(sub), t.first == tool || t.first?.hasPrefix(tool) == true {
                return Match(label: "\(tool) \(sub)", category: sub == "test" ? .test : .build)
            }
        }
        if t.first == "xcodebuild" { return Match(label: "xcodebuild", category: t.contains("test") ? .test : .build) }
        if t.first == "gradle" || t.first == "gradlew" {
            if t.contains("test") { return Match(label: "gradle test", category: .test) }
            if t.contains("build") || t.contains("assemble") { return Match(label: "gradle build", category: .build) }
        }
        return nil
    }

    /// Matches in `processes`, keeping only the outermost: a match whose parent chain (within the
    /// snapshot) holds another match is part of that command, not a separate one.
    public static func outermost(in processes: [ProcessSample],
                                 classify: (ProcessSample) -> Match? = ExpensiveCommand.classify) -> [(process: ProcessSample, match: Match)] {
        let live = processes.filter { $0.detailAccess != .processExited }
        let matches = Dictionary(live.compactMap { p in classify(p).map { (p.pid, $0) } }, uniquingKeysWith: { first, _ in first })
        guard !matches.isEmpty else { return [] }
        let byPID = Dictionary(live.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return live.compactMap { process in
            guard let match = matches[process.pid] else { return nil }
            var parent = process.parentPID
            var hops = 0
            while parent > 1, hops < 32, let ancestor = byPID[parent] {
                if matches[parent] != nil { return nil }
                parent = ancestor.parentPID
                hops += 1
            }
            return (process, match)
        }
    }
}
