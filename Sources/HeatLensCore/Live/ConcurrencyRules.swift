import Foundation

/// Explains bursts of concurrent expensive work in plain words (brief 3b): "2 test runs began
/// within 10 s across 2 agent trees (claude, codex) in FDA, plus 3 containers". Rules only, fed
/// one live tick at a time like `TimelineDetector`; the first tick only sets the baseline.
///
/// A burst is ≥ `burstMinimum` expensive commands (`ExpensiveCommand.outermost`) started within
/// `burstWindow` of each other across ≥ 2 agent trees or ≥ 2 projects. Containers that start in
/// the burst's projects around the same time are added to it. With fewer commands than that,
/// ≥ 2 containers starting across ≥ 2 projects are a burst on their own, at low confidence.
public struct ConcurrencyRules: Sendable {
    /// Starts this close together are one burst.
    public static let burstWindow: TimeInterval = 10
    /// Commands (or, for a container-only burst, containers) a burst needs.
    public static let burstMinimum = 2
    /// Explanations kept on a tick, recent first.
    public static let limit = 5
    /// How long an explanation stays after nothing in its burst is running.
    public static let keepAfterEnd: TimeInterval = 10 * 60
    /// Parent hops walked looking for an agent, as in `ExpensiveCommand.outermost`.
    static let maxHops = 32

    struct CommandStart: Sendable {
        let identity: ProcessIdentity
        let label: String
        let category: ExpensiveCommand.Category
        let project: String?
        let tree: Explanation.AgentTree
        /// The process's fork time.
        let at: Date
    }

    struct ContainerStart: Sendable {
        let id: String
        let name: String
        let project: String?
        /// How the container was tied to its project.
        let basis: String
        /// The tick that first saw it running: Docker gives no start time in the list call.
        let at: Date
    }

    /// The newest burst. Later starts inside its window join it (its explanation is updated in
    /// place) instead of being reported again.
    struct OpenBurst: Sendable {
        let id: String
        let anchor: Date
        let containersOnly: Bool
        var members: Set<String>
    }

    private var initialized = false
    private var seenCommands: Set<ProcessIdentity> = []
    /// argv doesn't change for a process identity, so each process is classified once.
    private var classified: [ProcessIdentity: ExpensiveCommand.Match?] = [:]
    private var runningContainers: Set<String> = []
    private var commandStarts: [CommandStart] = []
    private var containerStarts: [ContainerStart] = []
    private var open: OpenBurst?
    /// Every explanation still worth showing, recent first, at most `limit`.
    public private(set) var current: [Explanation] = []

    public init() {}

    /// Feeds one tick and returns the explanations first found on it. Each burst is returned
    /// once; when it grows, its entry in `current` is updated instead.
    public mutating func explanations(for tick: LiveTick) -> [Explanation] {
        let at = tick.snapshot.startedAt.addingTimeInterval(tick.snapshot.interval)
        let first = !initialized
        initialized = true

        var newContainers: [ContainerStart] = []
        if tick.docker.availability.isAvailable {
            let running = tick.docker.containers.filter(\.isRunning)
            if !first {
                for container in running where !runningContainers.contains(container.containerID) {
                    let attribution = tick.projects.containerAttributions[container.containerID]
                    newContainers.append(ContainerStart(id: container.containerID, name: container.name, project: attribution?.project?.name,
                                                        basis: attribution?.evidence.source ?? "Docker", at: at))
                }
            }
            runningContainers = Set(running.map(\.containerID))
        }

        let processes = tick.snapshot.processes
        var cache = classified
        let commands = ExpensiveCommand.outermost(in: processes) { process in
            if let known = cache[process.identity] { return known }
            let match = ExpensiveCommand.classify(process)
            cache[process.identity] = match
            return match
        }
        var newCommands: [CommandStart] = []
        var byPID: [Int32: ProcessSample]?
        for (process, match) in commands where !seenCommands.contains(process.identity) {
            seenCommands.insert(process.identity)
            // An older process that only now became outermost (its parent command exited) didn't start now.
            guard !first, process.identity.startDate >= tick.snapshot.startedAt.addingTimeInterval(-1) else { continue }
            let lookup = byPID ?? Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, b in a.detailAccess == .processExited ? b : a })
            byPID = lookup
            newCommands.append(CommandStart(identity: process.identity, label: match.label, category: match.category,
                                            project: tick.projects.usage(containing: process.identity)?.project?.name,
                                            tree: Self.agentTree(of: process, in: lookup), at: min(process.identity.startDate, at)))
        }
        let alive = Set(processes.filter { $0.detailAccess != .processExited }.map(\.identity))
        seenCommands.formIntersection(alive)
        classified = cache.filter { alive.contains($0.key) }

        let retention = 3 * Self.burstWindow + tick.snapshot.interval
        commandStarts.removeAll { at.timeIntervalSince($0.at) > retention }
        containerStarts.removeAll { at.timeIntervalSince($0.at) > retention }
        commandStarts += newCommands
        containerStarts += newContainers

        var found: [Explanation] = []
        if !newCommands.isEmpty || !newContainers.isEmpty {
            var absorbed = Set<String>()
            if let burst = open {
                absorbed = grow(burst, interval: tick.snapshot.interval)
            }
            for command in newCommands.sorted(by: { $0.at < $1.at }) where !absorbed.contains(Self.key(command)) {
                if let burst = open, command.at >= burst.anchor, command.at.timeIntervalSince(burst.anchor) <= Self.burstWindow {
                    absorbed.formUnion(grow(burst, interval: tick.snapshot.interval))
                    continue
                }
                let cluster = commandStarts.filter { $0.at <= command.at && command.at.timeIntervalSince($0.at) <= Self.burstWindow }
                guard Self.isBurst(cluster), let anchor = cluster.map(\.at).min() else { continue }
                let explanation = start(anchor: anchor, containersOnly: false, interval: tick.snapshot.interval)
                found.append(explanation)
                absorbed.formUnion(open?.members ?? [])
            }
            for container in newContainers where !absorbed.contains(container.id) && container.project != nil {
                let cluster = containerStarts.filter { $0.project != nil && $0.at <= container.at && container.at.timeIntervalSince($0.at) <= Self.burstWindow }
                let commandsNearby = commandStarts.filter { abs($0.at.timeIntervalSince(container.at)) <= Self.burstWindow + tick.snapshot.interval }
                guard cluster.count >= Self.burstMinimum, Set(cluster.compactMap(\.project)).count >= 2,
                      !Self.isBurst(commandsNearby), let anchor = cluster.map(\.at).min() else { continue }
                found.append(start(anchor: anchor, containersOnly: true, interval: tick.snapshot.interval))
                absorbed.formUnion(open?.members ?? [])
            }
        }

        // Ended: nothing in the burst still running; dropped `keepAfterEnd` later.
        current = current.compactMap { explanation in
            var explanation = explanation
            let running = explanation.affected.contains(where: alive.contains) || explanation.containerIDs.contains(where: runningContainers.contains)
            if running {
                explanation.endedAt = nil
            } else if explanation.endedAt == nil {
                explanation.endedAt = at
            }
            if let ended = explanation.endedAt, at.timeIntervalSince(ended) > Self.keepAfterEnd { return nil }
            return explanation
        }
        if current.count > Self.limit { current.removeLast(current.count - Self.limit) }
        if let burst = open, !current.contains(where: { $0.id == burst.id }) { open = nil }
        return found.filter { new in current.contains { $0.id == new.id } }
            .map { new in current.first { $0.id == new.id } ?? new }
    }

    /// Opens a burst at `anchor`, recent first in `current`.
    private mutating func start(anchor: Date, containersOnly: Bool, interval: TimeInterval) -> Explanation {
        let (commands, containers) = members(anchor: anchor, containersOnly: containersOnly, interval: interval)
        let id = "burst-\(Int64((anchor.timeIntervalSince1970 * 1000).rounded()))-" + (commands.first.map { "\($0.identity.pid)" } ?? containers.first.map { String($0.id.prefix(12)) } ?? "")
        let explanation = Self.explanation(id: id, commands: commands, containers: containers, containersOnly: containersOnly)
        open = OpenBurst(id: id, anchor: anchor, containersOnly: containersOnly, members: Set(commands.map(Self.key) + containers.map(\.id)))
        current.removeAll { $0.id == id }
        current.insert(explanation, at: 0)
        return explanation
    }

    /// Recomputes the open burst's members; when new ones joined, updates its explanation in
    /// place. Returns the members, so their starts aren't reported again.
    private mutating func grow(_ burst: OpenBurst, interval: TimeInterval) -> Set<String> {
        let (commands, containers) = members(anchor: burst.anchor, containersOnly: burst.containersOnly, interval: interval)
        let keys = Set(commands.map(Self.key) + containers.map(\.id))
        guard !keys.isSubset(of: burst.members), let index = current.firstIndex(where: { $0.id == burst.id }) else { return burst.members }
        var updated = Self.explanation(id: burst.id, commands: commands, containers: containers, containersOnly: burst.containersOnly)
        updated.endedAt = nil
        current[index] = updated
        open?.members = keys
        return keys
    }

    /// Commands started within `burstWindow` after `anchor`, and the containers that started in
    /// their projects from `burstWindow` before the first to `burstWindow` (plus one refresh,
    /// since a container's time is when it was first seen) after the last.
    private func members(anchor: Date, containersOnly: Bool, interval: TimeInterval) -> ([CommandStart], [ContainerStart]) {
        let commands = commandStarts.filter { $0.at >= anchor && $0.at.timeIntervalSince(anchor) <= Self.burstWindow }.sorted { $0.at < $1.at }
        let projects = Set(commands.compactMap(\.project))
        let last = commands.last.map { max($0.at, anchor) } ?? anchor
        let containers = containerStarts.filter { container in
            guard let project = container.project, containersOnly || projects.contains(project) else { return false }
            return container.at >= anchor.addingTimeInterval(containersOnly ? 0 : -Self.burstWindow)
                && container.at <= last.addingTimeInterval(Self.burstWindow + interval)
        }
        return (commands, containers)
    }

    static func isBurst(_ commands: [CommandStart]) -> Bool {
        commands.count >= burstMinimum
            && (Set(commands.map(\.tree)).count >= 2 || Set(commands.compactMap(\.project)).count >= 2)
    }

    private static func key(_ command: CommandStart) -> String {
        "\(command.identity.pid)-\(command.identity.startTimeMicros)"
    }

    /// The nearest ancestor that is a coding agent (`RulesEngine.agentNames`), by process name,
    /// executable or argv[0]: the native Claude Code binary is named after its version.
    static func agentTree(of process: ProcessSample, in byPID: [Int32: ProcessSample]) -> Explanation.AgentTree {
        var parent = process.parentPID
        var hops = 0
        while parent > 1, hops < maxHops, let ancestor = byPID[parent] {
            let names = [ancestor.name, ancestor.executablePath, ancestor.arguments?.first].compactMap { $0 }
                .map { ($0 as NSString).lastPathComponent.lowercased() }
            if let name = names.first(where: RulesEngine.agentNames.contains) {
                return Explanation.AgentTree(name: name == "claude.exe" ? "claude" : name, root: ancestor.identity)
            }
            parent = ancestor.parentPID
            hops += 1
        }
        return .noAgent
    }

    // MARK: - Wording

    /// "claude ×2, codex": trees per agent name, most first, then by name; "no agent" last.
    static func treeNames(_ trees: [Explanation.AgentTree]) -> String {
        var counts: [String: Int] = [:]
        for tree in trees where tree.isAgent { counts[tree.name, default: 0] += 1 }
        var names = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
        let unattached = trees.filter { !$0.isAgent }.count
        if unattached > 0 { names.append(unattached > 1 ? "no agent ×\(unattached)" : "no agent") }
        return names.joined(separator: ", ")
    }

    static func explanation(id: String, commands: [CommandStart], containers: [ContainerStart], containersOnly: Bool) -> Explanation {
        var trees: [Explanation.AgentTree] = []
        for tree in commands.map(\.tree) where !trees.contains(tree) { trees.append(tree) }
        let commandProjects = Set(commands.compactMap(\.project)).sorted()
        let projects = Set(commandProjects + containers.compactMap(\.project)).sorted()
        let window = "\(Int(burstWindow)) s"
        let categories = Set(commands.map(\.category))
        let noun = categories == [.test] ? "test runs" : categories == [.build] ? "builds" : categories == [.install] ? "installs" : "expensive commands"
        let treeNames = Self.treeNames(trees)

        let title: String
        let recommendation: String
        let shared = containers.isEmpty ? "the same CPU cores" : "the same CPU cores and the Docker VM"
        if containersOnly {
            title = "\(containers.count) containers started within \(window) across \(projects.count) projects (\(projects.joined(separator: ", ")))"
            recommendation = "These containers compete for the Docker VM's CPU and memory. If the Mac runs hot, start one project's containers at a time."
        } else {
            var across = ""
            var place = ""
            if trees.count >= 2 {
                across = " across \(trees.count) \(trees.allSatisfy(\.isAgent) ? "agent" : "process") trees (\(treeNames))"
                if commandProjects.count == 1 { place = " in \(commandProjects[0])" }
            }
            if commandProjects.count >= 2 {
                across += " across \(commandProjects.count) projects (\(commandProjects.joined(separator: ", ")))"
            }
            let extra = containers.count >= 2 ? ", plus \(containers.count) containers" : ""
            title = "\(commands.count) \(noun) began within \(window)\(across)\(place)\(extra)"
            recommendation = trees.contains(where: \.isAgent) && trees.count >= 2
                ? "These \(noun) compete for \(shared). Run them one at a time, or have the agents take turns."
                : "These \(noun) compete for \(shared). If the Mac runs hot, let one finish before starting the next."
        }

        var observations = commands.map { command in
            let tree = command.tree.root.map { "under \(command.tree.name) (PID \($0.pid))" } ?? "no agent above it"
            return Explanation.Observation(timestamp: command.at, evidence: Evidence(
                label: "\(command.label) started",
                value: "PID \(command.identity.pid), in \(command.project ?? "an unknown project"), \(tree)",
                source: "process start time and parent tree"))
        }
        observations += containers.map { container in
            Explanation.Observation(timestamp: container.at, evidence: Evidence(
                label: "Container \(container.name) started",
                value: "in \(container.project ?? "an unknown project")",
                source: "Docker; project from \(container.basis)"))
        }
        observations.sort { $0.timestamp < $1.timestamp }

        let unplaced = commands.filter { $0.project == nil }.count
        let confidence: Confidence = containersOnly ? .low : unplaced > 0 ? .medium : .high
        var uncertainty = ["HeatLens sees when these started and what started them, not how much heat or power each one causes."]
        if containersOnly {
            uncertainty.append("Fewer than \(burstMinimum) expensive commands were seen, so this rests on container starts alone.")
        } else if unplaced > 0 {
            uncertainty.append("\(unplaced) of the \(commands.count) commands couldn't be tied to a project folder.")
        } else if !containers.isEmpty {
            uncertainty.append("A container's start time is when HeatLens first saw it running, up to one refresh late.")
        } else if !trees.contains(where: \.isAgent) {
            uncertainty.append("Commands with no agent above them are taken to be yours, typed in a terminal.")
        }

        return Explanation(id: id, title: title, observations: observations, confidence: confidence, uncertainty: uncertainty,
                           recommendation: recommendation, startedAt: observations.first?.timestamp ?? Date.distantPast,
                           projects: projects, agentTrees: trees, affected: commands.map(\.identity), containerIDs: containers.map(\.id))
    }
}
