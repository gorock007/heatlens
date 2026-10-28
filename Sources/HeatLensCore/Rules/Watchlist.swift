import Foundation

/// A per-project alert policy (docs/v2/PHASE-4-PLAN.md 4f, owner decision 6): the same machine as
/// Live's system alerts, scoped to one project folder, with preset thresholds only. It only
/// alerts; it never stops or changes anything. Stored as a setting (`UserDefaults` key
/// `projectWatches`, a JSON array), and checked only while the Alerts master switch is on.
public struct ProjectWatch: Hashable, Codable, Sendable, Identifiable {
    public enum Metric: String, Hashable, Codable, Sendable, CaseIterable {
        /// The Projects card's CPU figure (`ProjectUsage.totalCPUPercent`), 100 = one core.
        case cpu
        /// The Projects card's memory: host footprint plus memory in the Docker VM, in GB.
        case memory
        /// Outermost expensive commands running at once (`LiveTick.runningCommandsByProject`).
        case commands
    }

    public static let nameLimit = 80
    /// Watches kept from the setting; the rest are dropped with a notice.
    public static let maxWatches = 50
    static let idLimit = 1024
    static let gib = Double(1 << 30)

    /// `Project.id`: the standardized root folder, lowercased.
    public let projectID: String
    /// How the project is shown, at most `nameLimit` characters.
    public let name: String
    /// % of one core, one of `choices(.cpu)`; nil is off.
    public let cpu: Double?
    /// GB, one of `choices(.memory)`; nil is off.
    public let memory: Double?
    /// Commands at once, one of `choices(.commands)`; nil is off.
    public let commands: Double?

    public var id: String { projectID }

    /// Nil unless `projectID` is an absolute folder and every threshold is one of its metric's
    /// `choices`: there are no free-form numbers. An empty name becomes the folder's name.
    public init?(projectID: String, name: String, cpu: Double? = nil, memory: Double? = nil, commands: Double? = nil) {
        let id = projectID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.hasPrefix("/"), id.count > 1, id.count <= Self.idLimit,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let thresholds: [(Metric, Double?)] = [(.cpu, cpu), (.memory, memory), (.commands, commands)]
        for (metric, on) in thresholds {
            if let on, Self.limits(metric, on: on) == nil { return nil }
        }
        let cleaned = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        self.projectID = id
        self.name = String((cleaned.isEmpty ? (id as NSString).lastPathComponent : cleaned).prefix(Self.nameLimit))
        self.cpu = cpu
        self.memory = memory
        self.commands = commands
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let watch = ProjectWatch(projectID: try container.decode(String.self, forKey: .projectID),
                                       name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
                                       cpu: try container.decodeIfPresent(Double.self, forKey: .cpu),
                                       memory: try container.decodeIfPresent(Double.self, forKey: .memory),
                                       commands: try container.decodeIfPresent(Double.self, forKey: .commands)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a valid project watch"))
        }
        self = watch
    }

    /// The `on` threshold for `metric`; nil when it's off.
    public func threshold(_ metric: Metric) -> Double? {
        switch metric {
        case .cpu: cpu
        case .memory: memory
        case .commands: commands
        }
    }

    /// True when at least one metric is on.
    public var isWatching: Bool { Metric.allCases.contains { threshold($0) != nil } }

    // MARK: - Presets

    /// The `on` thresholds offered, each with the value it clears below.
    public static func choices(_ metric: Metric) -> [(on: Double, off: Double)] {
        switch metric {
        case .cpu: [(100, 75), (200, 150), (400, 300)]
        case .memory: [(2, 1.5), (4, 3), (8, 6)]
        case .commands: [(2, 2), (3, 3)]
        }
    }

    /// The full limits for one of `choices`; nil for any other value.
    public static func limits(_ metric: Metric, on: Double) -> AlertRuleState.Limits? {
        guard let choice = choices(metric).first(where: { $0.on == on }) else { return nil }
        switch metric {
        case .cpu, .memory:
            return AlertRuleState.Limits(on: choice.on, off: choice.off, sustain: 2 * 60, clear: 60, cooldown: AlertRule.defaultCooldown)
        case .commands:
            return AlertRuleState.Limits(on: choice.on, off: choice.off, sustain: 30, clear: 0, cooldown: AlertRule.defaultCooldown)
        }
    }

    /// "200%", "4 GB", "1.5 GB", "2": how settings and alert titles name a threshold.
    public static func describe(_ value: Double, for metric: Metric) -> String {
        switch metric {
        case .cpu: "\(Int(value.rounded()))%"
        case .memory: value == value.rounded() ? "\(Int(value)) GB" : String(format: "%.1f GB", value)
        case .commands: "\(Int(value.rounded()))"
        }
    }

    // MARK: - Storage

    /// Reads the `projectWatches` setting. Entries that don't decode, and any after `maxWatches`,
    /// are dropped, and `notice` says so; a repeated project keeps its first entry.
    public static func parse(_ data: Data) -> (watches: [ProjectWatch], notice: String?) {
        guard !data.isEmpty else { return ([], nil) }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return ([], "The watched projects setting couldn't be read, so no project is watched.")
        }
        var watches: [ProjectWatch] = []
        var unreadable = 0
        var extra = 0
        for entry in entries {
            guard let watch = entry.watch else {
                unreadable += 1
                continue
            }
            guard !watches.contains(where: { $0.projectID == watch.projectID }) else { continue }
            if watches.count < maxWatches { watches.append(watch) } else { extra += 1 }
        }
        var notices: [String] = []
        if unreadable == 1 { notices.append("1 watched project couldn't be read and was dropped.") }
        if unreadable > 1 { notices.append("\(unreadable) watched projects couldn't be read and were dropped.") }
        if extra > 0 { notices.append("Only the first \(maxWatches) watched projects are kept.") }
        return (watches, notices.isEmpty ? nil : notices.joined(separator: " "))
    }

    /// The `projectWatches` setting's JSON.
    public static func encoded(_ watches: [ProjectWatch]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(watches)) ?? Data("[]".utf8)
    }

    /// One array element; a bad one decodes to nil instead of failing the whole array.
    private struct Entry: Decodable {
        let watch: ProjectWatch?

        init(from decoder: any Decoder) throws {
            watch = try? ProjectWatch(from: decoder)
        }
    }

    /// A stable, path-free key for a project (FNV-1a, 16 hex digits), e.g. for notification identifiers.
    public static func hash(of projectID: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in projectID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

/// Checks `ProjectWatch`es against Live ticks through `AlertRuleState`, one state per project and
/// metric. `AlertEvaluator` owns it: it handles gaps, sleep and the master switch, and passes the
/// span each tick covers. A project that isn't on a tick has no value, which resets its timers and
/// never fires.
public struct WatchlistEvaluator: Sendable {
    struct Key: Hashable, Sendable {
        let projectID: String
        let metric: ProjectWatch.Metric
    }

    /// Process names per alert.
    static let processLimit = 3
    private var states: [Key: AlertRuleState] = [:]

    public init() {}

    /// True while any of `watches`' metrics is holding or fired on the last tick.
    public func isActive(_ watches: [ProjectWatch]) -> Bool {
        guard !states.isEmpty else { return false }
        return watches.contains { watch in
            ProjectWatch.Metric.allCases.contains { metric in
                watch.threshold(metric) != nil && states[Key(projectID: watch.projectID, metric: metric)]?.isActive == true
            }
        }
    }

    public mutating func resetTimers() {
        for key in states.keys { states[key]?.resetTimers() }
    }

    /// The watch alerts that fired on this tick, which covered `start...end`.
    public mutating func alerts(for tick: LiveTick, watches: [ProjectWatch], start: Date, end: Date) -> [Alert] {
        guard !watches.isEmpty else {
            states.removeAll()
            return []
        }
        var usages: [String: ProjectUsage] = [:]
        for usage in tick.projects.usages {
            if let project = usage.project { usages[project.id] = usage }
        }
        var fired: [Alert] = []
        var watched = Set<Key>()
        for watch in watches {
            let usage = usages[watch.projectID]
            for metric in ProjectWatch.Metric.allCases {
                guard let on = watch.threshold(metric), let limits = ProjectWatch.limits(metric, on: on) else { continue }
                let key = Key(projectID: watch.projectID, metric: metric)
                guard watched.insert(key).inserted else { continue }
                var state = states[key] ?? AlertRuleState()
                let value = usage.flatMap { Self.value(metric, of: $0, in: tick) }
                if let held = state.step(value, limits: limits, start: start, end: end), let usage, let value {
                    fired.append(Self.alert(watch, metric: metric, limits: limits, value: value, held: held, usage: usage, tick: tick, at: end))
                }
                states[key] = state
            }
        }
        // A watch removed (or a metric turned off) forgets its state.
        if states.count > watched.count { states = states.filter { watched.contains($0.key) } }
        return fired
    }

    /// The metric's value for a project on the tick.
    static func value(_ metric: ProjectWatch.Metric, of usage: ProjectUsage, in tick: LiveTick) -> Double? {
        switch metric {
        case .cpu: usage.totalCPUPercent
        case .memory: Double(usage.memoryBytes + (usage.containerMemoryBytes ?? 0)) / ProjectWatch.gib
        case .commands: Double(usage.project.flatMap { tick.runningCommandsByProject[$0.id] } ?? 0)
        }
    }

    // MARK: - Wording

    static func alert(_ watch: ProjectWatch, metric: ProjectWatch.Metric, limits: AlertRuleState.Limits, value: Double, held: TimeInterval,
                      usage: ProjectUsage, tick: LiveTick, at: Date) -> Alert {
        let name = AlertEvaluator.safeName(watch.name)
        let on = ProjectWatch.describe(limits.on, for: metric)
        let off = ProjectWatch.describe(limits.off, for: metric)
        let duration = AlertEvaluator.duration(limits.sustain)
        let title: String
        let now: Evidence
        let threshold: String
        switch metric {
        case .cpu:
            title = "\(name) above \(on) CPU for \(duration)"
            now = Evidence(label: "CPU now", value: "\(Int(value.rounded()))% of one core", source: "per-project breakdown")
            threshold = "\(on); clears below \(off)"
        case .memory:
            title = "\(name) above \(on) memory for \(duration)"
            var text = ByteCountFormatter.string(fromByteCount: Int64(usage.memoryBytes), countStyle: .memory)
            if let docker = usage.containerMemoryBytes, docker > 0 {
                text += " + " + ByteCountFormatter.string(fromByteCount: Int64(docker), countStyle: .memory) + " in Docker"
            }
            now = Evidence(label: "Memory now", value: text, source: "per-project breakdown")
            threshold = "\(on); clears below \(off)"
        case .commands:
            title = "\(name) running \(on) or more expensive commands at once for \(duration)"
            now = Evidence(label: "Expensive commands now", value: "\(Int(value)) running", source: "process list")
            threshold = "\(on) or more; clears at \(Int(limits.off) - 1) or fewer"
        }
        let processes = busiestProcesses(in: usage, by: metric, tick: tick)
        var observations = [now,
                            Evidence(label: "Threshold", value: threshold, source: "your watch on \(name)"),
                            Evidence(label: "Held", value: AlertEvaluator.duration(held), source: "Live updates")]
        if !processes.isEmpty {
            observations.append(Evidence(label: processes.count == 1 ? "Busiest process" : "Busiest processes",
                                         value: processes.joined(separator: ", "), source: "per-project breakdown"))
        }
        let suggestion = processes.isEmpty ? "See Projects in Live."
            : "Its busiest \(processes.count == 1 ? "process is" : "processes are") \(processes.joined(separator: ", ")); see Projects."
        let hash = ProjectWatch.hash(of: watch.projectID)
        return Alert(id: "alert-watch-\(metric.rawValue)-\(hash)-\(Int64((at.timeIntervalSince1970 * 1000).rounded()))", rule: nil,
                     watch: Alert.Watch(projectName: name, metric: metric, projectHash: hash), firedAt: at, title: title,
                     observations: observations, projects: [name], suggestion: suggestion)
    }

    /// Up to `processLimit` distinct process names in the project, busiest first by CPU (by memory
    /// for a memory watch). Names only.
    static func busiestProcesses(in usage: ProjectUsage, by metric: ProjectWatch.Metric, tick: LiveTick) -> [String] {
        let members = Set(usage.processes)
        let samples = tick.snapshot.processes.filter { members.contains($0.identity) && $0.detailAccess != .processExited }
        let score: (ProcessSample) -> Double = metric == .memory
            ? { Double(LiveMonitor.memory($0) ?? 0) }
            : { $0.cpuPercentOfOneCore ?? 0 }
        var names: [String] = []
        for sample in samples.map({ ($0, score($0)) }).filter({ $0.1 > 0 }).sorted(by: { ($0.1, $1.0.pid) > ($1.1, $0.0.pid) }) {
            let name = AlertEvaluator.safeName(sample.0.name)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
            if names.count == processLimit { break }
        }
        return names
    }
}
