import Foundation

/// One alert rule checked while Live runs (PRD-v2 Phase 3, brief 3c). It fires once when its value
/// has stayed at or above `on` for `sustain`. It can't fire again until the value has stayed below
/// `off` for `clear` and `cooldown` has passed since it last fired.
public struct AlertRule: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// All cores' busy fraction, 0...1 (`SystemSample.busyCores / coreCount`).
        case sustainedCPU
        /// Used memory, 0...1: 100 − `kern.memorystatus_level`, the kernel's available percentage.
        case memory
        /// Swap used, in bytes.
        case swap
        /// `ThermalState` as a rank: serious is 2, critical 3. Unavailable has no value.
        case thermal
        /// Running containers, only when Docker answered.
        case containers
    }

    public let kind: Kind
    public var isEnabled: Bool
    /// Fires at or above this.
    public var on: Double
    /// Clears strictly below this: lower than `on`, so a value hovering at the line doesn't flap.
    public var off: Double
    /// How long the value must stay at or above `on` before the rule fires.
    public var sustain: TimeInterval
    /// How long the value must stay below `off` before the rule can fire again.
    public var clear: TimeInterval
    /// The least time between two firings of this rule.
    public var cooldown: TimeInterval

    public init(kind: Kind, isEnabled: Bool = true, on: Double, off: Double, sustain: TimeInterval, clear: TimeInterval,
                cooldown: TimeInterval = AlertRule.defaultCooldown) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.on = on
        self.off = min(off, on)
        self.sustain = max(0, sustain)
        self.clear = max(0, clear)
        self.cooldown = max(0, cooldown)
    }

    static let gib = Double(1 << 30)

    /// 15 minutes per rule.
    public static let defaultCooldown: TimeInterval = 15 * 60
    /// CPU ≥ 80% for 2 min; clears below 60% for 1 min.
    public static let sustainedCPU = AlertRule(kind: .sustainedCPU, on: 0.8, off: 0.6, sustain: 2 * 60, clear: 60)
    /// Memory ≥ 90% used for 2 min; clears below 80% for 1 min.
    public static let memory = AlertRule(kind: .memory, on: 0.9, off: 0.8, sustain: 2 * 60, clear: 60)
    /// Swap ≥ 2 GB for 1 min; clears below 1 GB.
    public static let swap = AlertRule(kind: .swap, on: 2 * gib, off: 1 * gib, sustain: 60, clear: 0)
    /// Serious or critical for 1 min; clears below serious.
    public static let thermal = AlertRule(kind: .thermal, on: 2, off: 2, sustain: 60, clear: 0)
    /// ≥ 6 running for 1 min; clears at 4 or fewer (below 5).
    public static let containers = AlertRule(kind: .containers, on: 6, off: 5, sustain: 60, clear: 0)

    public static func defaults(_ kind: Kind) -> AlertRule {
        switch kind {
        case .sustainedCPU: sustainedCPU
        case .memory: memory
        case .swap: swap
        case .thermal: thermal
        case .containers: containers
        }
    }

    /// The `on` thresholds Settings offers, each with its `off`. CPU, memory and containers keep the
    /// default's gap; swap clears at half, so the lowest choice still has room to clear. Thermal
    /// has one level.
    public static func thresholdChoices(_ kind: Kind) -> [(on: Double, off: Double)] {
        switch kind {
        case .sustainedCPU: [(0.6, 0.4), (0.8, 0.6), (0.9, 0.7)]
        case .memory: [(0.8, 0.7), (0.9, 0.8), (0.95, 0.85)]
        case .swap: [(1 * gib, 0.5 * gib), (2 * gib, 1 * gib), (4 * gib, 2 * gib)]
        case .thermal: [(2, 2)]
        case .containers: [(4, 3), (6, 5), (10, 9)]
        }
    }

    /// The default rule with `on` moved to one of `thresholdChoices` (the nearest, for a stored
    /// value that isn't one), and its matching `off`.
    public static func defaults(_ kind: Kind, on: Double, isEnabled: Bool = true) -> AlertRule {
        var rule = defaults(kind)
        let choice = thresholdChoices(kind).min { abs($0.on - on) < abs($1.on - on) } ?? (rule.on, rule.off)
        rule.on = choice.on
        rule.off = choice.off
        rule.isEnabled = isEnabled
        return rule
    }

    /// "80%", "2 GB", "serious", "6": how Settings and alert titles name a threshold.
    public static func describe(_ value: Double, for kind: Kind) -> String {
        switch kind {
        case .sustainedCPU, .memory: "\(Int((value * 100).rounded()))%"
        case .swap: ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
        case .thermal: value >= 3 ? "critical" : "serious"
        case .containers: "\(Int(value.rounded()))"
        }
    }
}

/// The user's alert settings, passed in through `LiveConfiguration`. Off unless turned on.
public struct AlertConfiguration: Hashable, Sendable {
    /// "Alert me while Live is running": nothing is checked while this is off.
    public var isEnabled: Bool
    public var rules: [AlertRule]

    public init(isEnabled: Bool = false, rules: [AlertRule] = AlertRule.Kind.allCases.map(AlertRule.defaults)) {
        self.isEnabled = isEnabled
        self.rules = rules
    }

    public static let off = AlertConfiguration()
}

/// One alert that fired on a Live tick. Names only: no paths, no argv.
public struct Alert: Hashable, Sendable, Identifiable {
    public let id: String
    public let rule: AlertRule.Kind
    /// The end of the tick it fired on.
    public let firedAt: Date
    /// "CPU above 80% for 2 minutes".
    public let title: String
    /// The value now, the threshold, how long it held, and the busiest projects.
    public let observations: [Evidence]
    /// Up to 3 project names, busiest first for this rule.
    public let projects: [String]
    /// Advice only; an alert never stops or changes anything.
    public let suggestion: String

    public init(id: String, rule: AlertRule.Kind, firedAt: Date, title: String, observations: [Evidence], projects: [String],
                suggestion: String) {
        self.id = id
        self.rule = rule
        self.firedAt = firedAt
        self.title = String(title.prefix(200))
        self.observations = observations
        self.projects = projects
        self.suggestion = suggestion
    }

    /// The timeline's marker for this alert.
    public var timelineEvent: TimelineEvent {
        TimelineEvent(timestamp: firedAt, kind: .alertFired, title: title, projectName: projects.count == 1 ? projects.first : nil)
    }
}

/// Checks `AlertConfiguration` against Live ticks, fed one at a time like `TimelineDetector`.
/// Holds no timer: it only looks at the ticks it's given, so nothing is checked when Live isn't
/// running. A tick that doesn't start where the previous one ended (a pause, a new session)
/// resets the hold and clear timers, so a rule never fires on time it didn't see. So does a tick
/// lasting more than `sleepFactor` × its planned interval (the Mac slept), and its timers then
/// start at the tick's end. The cooldown is kept across both, for as long as the evaluator lives.
public struct AlertEvaluator: Sendable {
    /// Ticks within this of each other count as back to back.
    public static let gapTolerance: TimeInterval = 1
    /// A tick longer than this many planned intervals slept through (docs/v2/PHASE-4-PLAN.md 4a).
    public static let sleepFactor: Double = 3
    /// Project names per alert.
    public static let projectLimit = 3
    static let nameLimit = 40

    struct State: Sendable {
        /// When the value first reached `on` in the current run of ticks.
        var holdingSince: Date?
        /// When the value first fell below `off` after firing.
        var clearingSince: Date?
        /// False from a firing until the value has cleared.
        var armed = true
        var lastFired: Date?

        mutating func resetTimers() {
            holdingSince = nil
            clearingSince = nil
        }
    }

    public var configuration: AlertConfiguration
    private var states: [AlertRule.Kind: State] = [:]
    private var lastEnd: Date?

    public init(configuration: AlertConfiguration = .off) {
        self.configuration = configuration
    }

    /// True while an enabled rule is holding (at or above `on`) or has fired and not yet cleared.
    /// `IncidentTracker` treats that as an incident.
    public var isActive: Bool {
        guard configuration.isEnabled else { return false }
        return configuration.rules.contains { rule in
            guard rule.isEnabled, let state = states[rule.kind] else { return false }
            return state.holdingSince != nil || !state.armed
        }
    }

    /// The alerts that fired on this tick.
    public mutating func alerts(for tick: LiveTick) -> [Alert] {
        var start = tick.snapshot.startedAt
        let end = start.addingTimeInterval(tick.snapshot.interval)
        if let lastEnd, abs(start.timeIntervalSince(lastEnd)) > Self.gapTolerance {
            for kind in states.keys { states[kind]?.resetTimers() }
        }
        if let planned = tick.plannedInterval, tick.snapshot.interval > Self.sleepFactor * planned {
            for kind in states.keys { states[kind]?.resetTimers() }
            // The value wasn't seen while the Mac slept: holding and clearing start now.
            start = end
        }
        lastEnd = end
        guard configuration.isEnabled else {
            for kind in states.keys { states[kind]?.resetTimers() }
            return []
        }

        var fired: [Alert] = []
        for rule in configuration.rules {
            var state = states[rule.kind] ?? State()
            defer { states[rule.kind] = state }
            guard rule.isEnabled, let value = Self.value(rule.kind, in: tick) else {
                state.resetTimers()
                continue
            }
            if !state.armed {
                if value < rule.off {
                    let since = state.clearingSince ?? start
                    state.clearingSince = since
                    if end.timeIntervalSince(since) >= rule.clear {
                        state.armed = true
                        state.clearingSince = nil
                    }
                } else {
                    state.clearingSince = nil
                }
                continue
            }
            guard value >= rule.on else {
                state.holdingSince = nil
                continue
            }
            let since = state.holdingSince ?? start
            state.holdingSince = since
            let held = end.timeIntervalSince(since)
            guard held >= rule.sustain else { continue }
            if let last = state.lastFired, end.timeIntervalSince(last) < rule.cooldown { continue }
            state.lastFired = end
            state.armed = false
            state.resetTimers()
            fired.append(Self.alert(rule, value: value, held: held, tick: tick, at: end))
        }
        return fired
    }

    /// The rule's value on this tick; nil when it can't be read, which never fires.
    static func value(_ kind: AlertRule.Kind, in tick: LiveTick) -> Double? {
        let system = tick.snapshot.system
        switch kind {
        case .sustainedCPU:
            guard system.coreCount > 0 else { return nil }
            return system.busyCores / Double(system.coreCount)
        case .memory:
            return system.memory.availablePercent.map { 1 - Double(min(max($0, 0), 100)) / 100 }
        case .swap:
            return Double(system.memory.swapUsedBytes)
        case .thermal:
            return system.thermalState == .unavailable ? nil : Double(system.thermalState.rank)
        case .containers:
            guard tick.docker.availability.isAvailable else { return nil }
            return Double(tick.docker.containers.filter(\.isRunning).count)
        }
    }

    // MARK: - Wording

    static func alert(_ rule: AlertRule, value: Double, held: TimeInterval, tick: LiveTick, at: Date) -> Alert {
        let system = tick.snapshot.system
        let on = AlertRule.describe(rule.on, for: rule.kind)
        let off = AlertRule.describe(rule.off, for: rule.kind)
        let duration = Self.duration(rule.sustain)
        let title: String
        let now: Evidence
        let threshold: String
        let suggestion: String
        switch rule.kind {
        case .sustainedCPU:
            title = "CPU above \(on) for \(duration)"
            now = Evidence(label: "CPU now", value: "\(AlertRule.describe(value, for: .sustainedCPU)) (\(String(format: "%.1f", system.busyCores)) of \(system.coreCount) cores)",
                           source: "host_processor_info")
            threshold = "\(on); clears below \(off)"
            suggestion = "Open Live to see what's busy."
        case .memory:
            title = "Memory above \(on) used for \(duration)"
            now = Evidence(label: "Memory used now", value: "\(AlertRule.describe(value, for: .memory)) (\(system.memory.availablePercent ?? 0)% available)",
                           source: "kern.memorystatus_level")
            threshold = "\(on) used; clears below \(off)"
            suggestion = "Open Live's Top memory list to see what's using memory."
        case .swap:
            title = "Swap above \(on) for \(duration)"
            now = Evidence(label: "Swap now", value: "\(AlertRule.describe(value, for: .swap)) used", source: "vm.swapusage")
            threshold = "\(on); clears below \(off)"
            suggestion = "Open Live's Top memory list to see what's using memory."
        case .thermal:
            title = "Thermal pressure \(system.thermalState.rawValue) for \(duration)"
            now = Evidence(label: "Thermal state now", value: system.thermalState.rawValue, source: "ProcessInfo.thermalState")
            threshold = "serious or higher; clears below serious"
            suggestion = "Open Live to see what's busy. macOS may be slowing the Mac to cool it."
        case .containers:
            title = "\(on) or more containers running for \(duration)"
            now = Evidence(label: "Containers running now", value: "\(Int(value))", source: "Docker")
            threshold = "\(on) or more; clears at \(Int(rule.off) - 1) or fewer"
            suggestion = "Open Live's Docker card to see which containers are running."
        }
        let projects = topProjects(for: rule.kind, in: tick.projects)
        var observations = [now,
                            Evidence(label: "Threshold", value: threshold, source: "your alert settings"),
                            Evidence(label: "Held", value: Self.duration(held), source: "Live updates")]
        if !projects.isEmpty {
            observations.append(Evidence(label: projects.count == 1 ? "Busiest project" : "Busiest projects",
                                         value: projects.joined(separator: ", "), source: "per-project breakdown"))
        }
        return Alert(id: "alert-\(rule.kind.rawValue)-\(Int64((at.timeIntervalSince1970 * 1000).rounded()))", rule: rule.kind, firedAt: at,
                     title: title, observations: observations, projects: projects, suggestion: suggestion)
    }

    /// Project rows only (not the Docker VM or Unattributed), ranked by what this rule measures.
    static func topProjects(for kind: AlertRule.Kind, in breakdown: ProjectBreakdown) -> [String] {
        let rows = breakdown.usages.filter { $0.project != nil }
        let score: (ProjectUsage) -> Double = switch kind {
        case .sustainedCPU, .thermal: { $0.totalCPUPercent }
        case .memory, .swap: { Double($0.memoryBytes + ($0.containerMemoryBytes ?? 0)) }
        case .containers: { Double($0.containers.filter(\.isRunning).count) }
        }
        return rows.map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }
            .prefix(projectLimit)
            .map { safeName($0.0.name) }
    }

    /// A folder name or a user mapping's name; anything path-like shrinks to its last part.
    static func safeName(_ name: String) -> String {
        let last = name.contains("/") ? (name as NSString).lastPathComponent : name
        let clean = last.replacingOccurrences(of: "/", with: "")
        return clean.count <= nameLimit ? clean : String(clean.prefix(nameLimit - 1)) + "…"
    }

    /// "2 minutes", "1 minute", "45 seconds", "2 min 5 s".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return total == 1 ? "1 second" : "\(total) seconds" }
        let minutes = total / 60
        let rest = total % 60
        if rest == 0 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        return "\(minutes) min \(rest) s"
    }
}
