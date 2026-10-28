import Foundation
import Testing
@testable import HeatLensCore

private let t0 = SyntheticSnapshots.startedAt

private func power(_ source: PowerSourceKind, lowPower: Bool = false) -> PowerContext {
    PowerContext(source: source, hasBattery: source != .ac, batteryPercent: 80, isCharging: nil, lowPowerMode: lowPower)
}

/// One cell of the PHASE-4-PLAN 4a table.
struct SamplingCase: CustomTestStringConvertible, Sendable {
    let name: String
    let context: SamplingPolicy.Context
    let interval: TimeInterval
    let reason: SamplingPolicy.Reason
    var testDescription: String { name }
}

private let table: [SamplingCase] = [
    SamplingCase(name: "viewer, on power", context: .init(viewerInterval: 5, power: power(.ac)), interval: 5, reason: .viewer),
    SamplingCase(name: "viewer, on battery", context: .init(viewerInterval: 2, power: power(.battery)), interval: 2, reason: .viewer),
    SamplingCase(name: "viewer, Low Power Mode", context: .init(viewerInterval: 10, power: power(.battery, lowPower: true), incident: true),
                 interval: 10, reason: .viewer),
    SamplingCase(name: "incident, on power", context: .init(power: power(.ac), incident: true), interval: 5, reason: .incident),
    SamplingCase(name: "incident, on battery", context: .init(power: power(.battery), incident: true), interval: 10, reason: .incident),
    SamplingCase(name: "incident, Low Power Mode", context: .init(power: power(.ac, lowPower: true), incident: true),
                 interval: 120, reason: .lowPowerMode),
    SamplingCase(name: "idle, on power", context: .init(power: power(.ac)), interval: 30, reason: .idle),
    SamplingCase(name: "idle, on battery", context: .init(power: power(.battery)), interval: 60, reason: .battery),
    SamplingCase(name: "idle, Low Power Mode", context: .init(power: power(.battery, lowPower: true)), interval: 120, reason: .lowPowerMode),
    SamplingCase(name: "idle, source unknown", context: .init(power: power(.unknown)), interval: 60, reason: .battery),
    SamplingCase(name: "incident, source unknown", context: .init(power: power(.unknown), incident: true), interval: 10, reason: .incident),
    SamplingCase(name: "idle, no power context", context: .init(power: nil), interval: 60, reason: .battery),
    SamplingCase(name: "incident, no power context", context: .init(power: nil, incident: true), interval: 10, reason: .incident),
]

/// A tick ending at `t0 + end` seconds, with the given triggers.
private func tick(end: TimeInterval, busy: Double = 0.1, thermal: ThermalState = .nominal, events: [TimelineEvent.Kind] = [],
                  openExplanation: Bool = false, endedExplanation: Bool = false) -> LiveTick {
    let base = SyntheticSnapshots.snapshot([], thermal: thermal, hostBusyFraction: busy)
    let step = SyntheticSnapshots.interval
    let snapshot = ScanSnapshot(startedAt: t0.addingTimeInterval(end - step), interval: step, system: base.system, processes: [], notices: [])
    var tick = LiveTick(sequence: 1, snapshot: snapshot, groups: [], hardware: DisabledHardwareProvider().sample(), docker: .unavailable(.disabled),
                        projects: .empty, topByCPU: [], topByMemory: [], history: LiveHistory(capacity: 2).window(for: []),
                        collectionSeconds: 0)
    let at = t0.addingTimeInterval(end)
    tick.events = events.map { TimelineEvent(timestamp: at, kind: $0, title: $0.rawValue) }
    func explanation(ended: Bool) -> Explanation {
        Explanation(id: "burst", title: "3 commands at once", observations: [], confidence: .high, uncertainty: [], recommendation: "",
                    startedAt: t0, endedAt: ended ? at : nil, projects: [], agentTrees: [], affected: [], containerIDs: [])
    }
    if openExplanation { tick.explanations.append(explanation(ended: false)) }
    if endedExplanation { tick.explanations.append(explanation(ended: true)) }
    return tick
}

@Suite("Sampling policy")
struct SamplingPolicyTests {
    @Test("every cell of the table", arguments: table)
    func cell(_ c: SamplingCase) {
        #expect(SamplingPolicy.next(c.context) == SamplingPolicy.Decision(interval: c.interval, reason: c.reason))
        #expect(SamplingPolicy.next(.adaptive, c.context) == SamplingPolicy.next(c.context))
    }

    @Test("Low Power Mode is never fast without a viewer, whatever the source or incident")
    func lowPowerNeverFast() {
        for source in [PowerSourceKind.ac, .battery, .unknown] {
            for incident in [false, true] {
                let decision = SamplingPolicy.next(.init(power: power(source, lowPower: true), incident: incident))
                #expect(decision.interval == 120)
                #expect(decision.reason == .lowPowerMode)
            }
        }
    }

    @Test("the viewer wins over everything, and its interval clamps to 2…10 s")
    func viewerWins() {
        for context in table.map(\.context) {
            var viewed = context
            viewed.viewerInterval = 5
            #expect(SamplingPolicy.next(viewed) == SamplingPolicy.Decision(interval: 5, reason: .viewer))
        }
        #expect(SamplingPolicy.next(.init(viewerInterval: 0.5)).interval == 2)
        #expect(SamplingPolicy.next(.init(viewerInterval: 60)).interval == 10)
    }

    @Test(".fixed ignores power, incidents and the viewer")
    func fixed() {
        for context in table.map(\.context) {
            #expect(SamplingPolicy.next(.fixed(5), context) == SamplingPolicy.Decision(interval: 5, reason: .fixed))
        }
        #expect(SamplingPolicy.next(.fixed(1), .init()).interval == 2)
    }

    @Test("every background interval is at least ADR-0003's 2 s floor")
    func floor() {
        for c in table { #expect(c.interval >= LiveConfiguration.intervalRange.lowerBound) }
    }
}

/// `update` outside `#expect`, which can't call a mutating method.
private func feed(_ tracker: inout IncidentTracker, _ tick: LiveTick, alertsActive: Bool = false) -> Bool {
    tracker.update(tick, alertsActive: alertsActive)
}

@Suite("Incident tracker")
struct IncidentTrackerTests {
    @Test("a quiet tick is no incident")
    func quiet() {
        var tracker = IncidentTracker()
        #expect(!feed(&tracker, tick(end: 5, endedExplanation: true)))
        #expect(tracker.lastTrigger == nil)
    }

    @Test("each trigger on its own starts an incident")
    func triggers() {
        let cases: [(String, LiveTick, Bool)] = [
            ("alert holding or uncleared", tick(end: 5), true),
            ("open explanation", tick(end: 5, openExplanation: true), false),
            ("busy cores at 60%", tick(end: 5, busy: 0.6), false),
            ("thermal serious", tick(end: 5, thermal: .serious), false),
            ("thermal critical", tick(end: 5, thermal: .critical), false),
        ] + IncidentTracker.triggerEvents.map { ("event \($0.rawValue)", tick(end: 5, events: [$0]), false) }
        for (name, tick, alerts) in cases {
            var tracker = IncidentTracker()
            #expect(feed(&tracker, tick, alertsActive: alerts), "\(name)")
        }
    }

    @Test("near misses don't: 59% busy, fair thermal, other events, an ended explanation")
    func nearMisses() {
        let others: [TimelineEvent.Kind] = [.containerStopped, .repeatedCommand, .concurrencyExplained, .alertFired]
        let ticks = [tick(end: 5, busy: 0.59), tick(end: 5, thermal: .fair), tick(end: 5, thermal: .unavailable),
                     tick(end: 5, events: others), tick(end: 5, endedExplanation: true)]
        for tick in ticks {
            var tracker = IncidentTracker()
            #expect(!feed(&tracker, tick))
        }
    }

    @Test("the incident holds for 120 s after the last trigger, then drops back")
    func hold() {
        var tracker = IncidentTracker()
        #expect(feed(&tracker, tick(end: 10, events: [.testRunStarted])))
        #expect(feed(&tracker, tick(end: 15)))
        #expect(feed(&tracker, tick(end: 129.9)))
        #expect(!feed(&tracker, tick(end: 130)))
        #expect(!feed(&tracker, tick(end: 160)))
    }

    @Test("a later trigger extends the hold")
    func extend() {
        var tracker = IncidentTracker()
        _ = feed(&tracker, tick(end: 10, busy: 0.9))
        _ = feed(&tracker, tick(end: 100, thermal: .serious))
        #expect(feed(&tracker, tick(end: 200)))
        #expect(!feed(&tracker, tick(end: 220)))
        #expect(tracker.lastTrigger == t0.addingTimeInterval(100))
    }
}
