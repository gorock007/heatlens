import Foundation

/// How long a live session waits after each tick, and why (docs/v2/PHASE-4-PLAN.md 4a, owner
/// decision 8). Pure: `LiveMonitor` asks it after every tick.
///
/// | Situation      | On power | On battery (or unknown) | Low Power Mode     |
/// |----------------|----------|-------------------------|--------------------|
/// | Viewer on Live | 2/5/10 s | 2/5/10 s                | 2/5/10 s           |
/// | Incident       | 5 s      | 10 s                    | 120 s (never fast) |
/// | Idle           | 30 s     | 60 s                    | 120 s              |
public enum SamplingPolicy {
    public enum Mode: Hashable, Sendable {
        /// Every tick waits this long (the panel's picker, clamped to 2...10 s): today's Live.
        case fixed(TimeInterval)
        /// The table above, with the viewer's interval set through `LiveMonitor.setViewer(interval:)`.
        case adaptive
    }

    public struct Context: Hashable, Sendable {
        /// The panel's interval while someone is looking at Live; nil when nobody is.
        public var viewerInterval: TimeInterval?
        /// Nil (unreadable) counts as battery.
        public var power: PowerContext?
        /// `IncidentTracker`'s verdict for the tick just taken.
        public var incident: Bool

        public init(viewerInterval: TimeInterval? = nil, power: PowerContext? = nil, incident: Bool = false) {
            self.viewerInterval = viewerInterval
            self.power = power
            self.incident = incident
        }
    }

    /// Why the interval is what it is. Low Power Mode outranks everything but a viewer; an
    /// incident outranks battery, so 10 s on battery reads "incident" and 60 s reads "battery".
    public enum Reason: String, Hashable, Codable, Sendable {
        case viewer, idle, incident, battery, lowPowerMode, fixed
    }

    public struct Decision: Hashable, Codable, Sendable {
        public let interval: TimeInterval
        public let reason: Reason

        public init(interval: TimeInterval, reason: Reason) {
            self.interval = interval
            self.reason = reason
        }
    }

    public static let incidentOnPower: TimeInterval = 5
    public static let incidentOnBattery: TimeInterval = 10
    public static let idleOnPower: TimeInterval = 30
    public static let idleOnBattery: TimeInterval = 60
    public static let lowPowerMode: TimeInterval = 120

    /// The adaptive table.
    public static func next(_ context: Context) -> Decision {
        if let viewer = context.viewerInterval {
            return Decision(interval: LiveConfiguration.clamped(viewer), reason: .viewer)
        }
        if context.power?.lowPowerMode == true {
            return Decision(interval: lowPowerMode, reason: .lowPowerMode)
        }
        let onPower = context.power?.source == .ac
        if context.incident {
            return Decision(interval: onPower ? incidentOnPower : incidentOnBattery, reason: .incident)
        }
        return onPower ? Decision(interval: idleOnPower, reason: .idle) : Decision(interval: idleOnBattery, reason: .battery)
    }

    /// `.fixed` ignores the context; `.adaptive` is `next(_:)`.
    public static func next(_ mode: Mode, _ context: Context) -> Decision {
        switch mode {
        case .fixed(let interval): Decision(interval: LiveConfiguration.clamped(interval), reason: .fixed)
        case .adaptive: next(context)
        }
    }
}

/// Decides whether the Mac is in an incident, fed one tick at a time like `TimelineDetector`.
/// Any one trigger on a tick starts or extends it; it holds for `hold` after the last trigger,
/// so one quiet tick doesn't flap the cadence. Holds no timer: time is the ticks' own end times.
public struct IncidentTracker: Sendable {
    /// How long the incident cadence holds after the last trigger.
    public static let hold: TimeInterval = 120
    /// All cores at least this busy (0...1) is a trigger.
    public static let busyFraction = 0.6
    /// Events that start a burst. Going fast on the first start keeps the rest of it precise.
    public static let triggerEvents: Set<TimelineEvent.Kind> = [
        .testRunStarted, .expensiveCommandStarted, .containerStarted, .concurrentCommands, .thermalChanged,
    ]

    /// The end of the last tick that had a trigger.
    public private(set) var lastTrigger: Date?

    public init() {}

    /// Feeds one tick; true while the incident holds. `alertsActive`: an alert rule (or watch)
    /// is holding at or above its threshold, or fired on this tick (`AlertEvaluator.isActive`).
    /// So a firing ends the incident `hold` later, unless something else triggers, however long the value stays up.
    public mutating func update(_ tick: LiveTick, alertsActive: Bool) -> Bool {
        let end = tick.snapshot.startedAt.addingTimeInterval(tick.snapshot.interval)
        if alertsActive || Self.triggers(tick) { lastTrigger = end }
        return isIncident(at: end)
    }

    /// True from a trigger until `hold` has passed.
    public func isIncident(at date: Date) -> Bool {
        guard let lastTrigger else { return false }
        return date.timeIntervalSince(lastTrigger) < Self.hold
    }

    /// The tick-only triggers: an explanation still open, a starting event, busy cores, or heat.
    static func triggers(_ tick: LiveTick) -> Bool {
        let system = tick.snapshot.system
        return tick.explanations.contains { $0.endedAt == nil }
            || tick.events.contains { triggerEvents.contains($0.kind) }
            || system.hostBusyFraction >= busyFraction
            || system.thermalState.rank >= ThermalState.serious.rank
    }
}
