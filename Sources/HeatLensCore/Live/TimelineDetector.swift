import Foundation

/// Finds timeline events by comparing consecutive live ticks (briefs 2d, 2e). The first tick only
/// sets the baseline: anything already running then is not reported as "started".
public struct TimelineDetector: Sendable {
    /// How far back "started again" looks, and how many starts make a repeat.
    public static let repeatWindow: TimeInterval = 10 * 60
    public static let repeatThreshold = 3

    private var initialized = false
    private var thermal: ThermalState?
    private var running: [String: String] = [:]
    private var seenCommands: Set<ProcessIdentity> = []
    private var lastConcurrent: Set<ProcessIdentity> = []
    private var starts: [(label: String, project: String?, at: Date)] = []
    private var reportedRepeats: [String: Date] = [:]
    /// argv doesn't change for a process identity, so each process is classified once.
    private var classified: [ProcessIdentity: ExpensiveCommand.Match?] = [:]

    public init() {}

    public mutating func events(for tick: LiveTick) -> [TimelineEvent] {
        let at = tick.snapshot.startedAt.addingTimeInterval(tick.snapshot.interval)
        var events: [TimelineEvent] = []
        let first = !initialized
        initialized = true

        let state = tick.snapshot.system.thermalState
        if let previous = thermal, previous != state, state != .unavailable, previous != .unavailable {
            events.append(TimelineEvent(timestamp: at, kind: .thermalChanged,
                                        title: "Thermal state \(previous.rawValue) → \(state.rawValue)"))
        }
        thermal = state

        if tick.docker.availability.isAvailable {
            let now = Dictionary(tick.docker.containers.filter(\.isRunning).map { ($0.containerID, $0.name) },
                                 uniquingKeysWith: { first, _ in first })
            if !first {
                for (id, name) in now where running[id] == nil {
                    let project = tick.projects.containerAttributions[id]?.project?.name
                    events.append(TimelineEvent(timestamp: at, kind: .containerStarted, title: "\(name) started", projectName: project))
                }
                for (id, name) in running where now[id] == nil {
                    events.append(TimelineEvent(timestamp: at, kind: .containerStopped, title: "\(name) stopped"))
                }
            }
            running = now
        }

        var cache = classified
        let commands = ExpensiveCommand.outermost(in: tick.snapshot.processes) { process in
            if let known = cache[process.identity] { return known }
            let match = ExpensiveCommand.classify(process)
            cache[process.identity] = match
            return match
        }
        let projectOf = { (process: ProcessSample) in tick.projects.usage(containing: process.identity)?.project?.name }
        for (process, match) in commands where !seenCommands.contains(process.identity) {
            seenCommands.insert(process.identity)
            guard !first else { continue }
            let project = projectOf(process)
            events.append(TimelineEvent(timestamp: at, kind: match.category == .test ? .testRunStarted : .expensiveCommandStarted,
                                        title: "\(match.label) started", projectName: project))
            starts.append((match.label, project, at))
        }
        let alive = Set(tick.snapshot.processes.filter { $0.detailAccess != .processExited }.map(\.identity))
        seenCommands.formIntersection(alive)
        classified = cache.filter { alive.contains($0.key) }

        // Several at once: reported when the set grows, not on every tick it lasts.
        let active = Set(commands.map(\.process.identity))
        if active.count >= 2, !active.isSubset(of: lastConcurrent) {
            let parts = commands.map { command in projectOf(command.process).map { "\(command.match.label) (\($0))" } ?? command.match.label }
            let projects = Set(commands.compactMap { projectOf($0.process) })
            let across = projects.count > 1 ? " across \(projects.count) projects" : ""
            events.append(TimelineEvent(timestamp: at, kind: .concurrentCommands,
                                        title: "\(commands.count) expensive commands at once\(across): " + parts.sorted().joined(separator: ", "),
                                        projectName: projects.count == 1 ? projects.first : nil, isInference: true))
        }
        lastConcurrent = active.count >= 2 ? active : []

        // The same command in the same project, started again and again.
        starts.removeAll { at.timeIntervalSince($0.at) > Self.repeatWindow }
        reportedRepeats = reportedRepeats.filter { at.timeIntervalSince($0.value) <= Self.repeatWindow }
        let grouped = Dictionary(grouping: starts, by: { "\($0.label)|\($0.project ?? "")" })
        for (key, runs) in grouped where runs.count >= Self.repeatThreshold && reportedRepeats[key] == nil {
            reportedRepeats[key] = at
            let place = runs[0].project.map { " in \($0)" } ?? ""
            events.append(TimelineEvent(timestamp: at, kind: .repeatedCommand,
                                        title: "\(runs[0].label) started \(runs.count) times in 10 minutes\(place) (likely repeated runs)",
                                        projectName: runs[0].project, isInference: true))
        }
        return events
    }
}
