import Foundation
import Testing
@testable import HeatLensCore

private let home = SyntheticSnapshots.home
private let t0 = SyntheticSnapshots.startedAt
private let step = SyntheticSnapshots.interval
private let fda = home + "/Developer/FDA"
private let shop = home + "/Developer/shop"
private let gib = Double(1 << 30)

/// What one tick reads for each rule.
struct AlertReading {
    var cpu = 0.25
    var memoryUsed = 0.5
    var swap: Double = 0
    var thermal: ThermalState = .nominal
    /// Running containers; nil when Docker isn't available.
    var containers: Int? = 0
}

private func container(_ index: Int, project: String) -> ContainerSample {
    ContainerSample(containerID: String(format: "%064d", index), name: "db-\(index)", image: "postgres:17", state: "running", status: "Up",
                    createdAt: t0, labels: ["com.docker.compose.project.working_dir": project],
                    cpuPercentOfOneCore: 1, memoryBytes: 1 << 20, vmCPUCount: 6)
}

private let busyFDA = SyntheticSnapshots.process(pid: 300, name: "node", executablePath: "/usr/local/bin/node",
                                                 arguments: ["node", fda + "/scripts/build.js"], currentDirectory: fda, cpu: 400)
private let busyShop = SyntheticSnapshots.process(pid: 400, name: "swift-build", executablePath: "/usr/bin/swift-build",
                                                  arguments: ["swift-build"], currentDirectory: shop, cpu: 150)

/// The `n`th tick of a back-to-back session (each starts where the previous ended), with
/// projects resolved against a fake filesystem where ~/Developer/FDA and ~/Developer/shop are repositories.
/// `start` and `interval` override the back-to-back timing.
private func tick(_ n: Int, _ reading: AlertReading, processes: [ProcessSample] = [busyFDA, busyShop],
                  start: Date? = nil, interval: TimeInterval? = nil) -> LiveTick {
    let base = SyntheticSnapshots.snapshot(processes)
    let memory = MemorySnapshot(totalBytes: 18 << 30, freeBytes: 4 << 30, activeBytes: 5 << 30, inactiveBytes: 3 << 30, wiredBytes: 3 << 30,
                                compressedBytes: 2 << 30, swapUsedBytes: UInt64(reading.swap), swapTotalBytes: 10 << 30, swapOutsDelta: 0,
                                pressure: .normal, availablePercent: Int(((1 - reading.memoryUsed) * 100).rounded()))
    let system = SystemSample(coreCount: 10, hostBusyFraction: reading.cpu, perCoreBusyFraction: Array(repeating: reading.cpu, count: 10),
                              memory: memory, thermalState: reading.thermal, pmsetCPUSpeedLimit: nil, pmsetCPUSchedulerLimit: nil)
    let snapshot = ScanSnapshot(startedAt: start ?? t0.addingTimeInterval(Double(n) * step), interval: interval ?? step, system: system,
                                processes: base.processes, notices: [])
    let groups = ProvenanceResolver.resolve(snapshot)
    let docker = reading.containers.map { count in
        DockerSnapshot(availability: .available, engineVersion: "28.5.1", apiVersion: "1.51",
                       containers: (0..<count).map { container($0, project: $0 % 2 == 0 ? fda : shop) }, notices: [])
    } ?? .unavailable(.disabled)
    let locator = ProjectRootLocator(home: home, exists: { [fda + "/.git", shop + "/.git"].contains($0) })
    let projects = ProjectAttributor.breakdown(snapshot: snapshot, groups: groups, docker: docker, mappings: [], locator: locator, home: home)
    return LiveTick(sequence: n + 1, snapshot: snapshot, groups: groups, hardware: DisabledHardwareProvider().sample(), docker: docker,
                    projects: projects, topByCPU: [], topByMemory: [], history: LiveHistory(capacity: 2).window(for: []),
                    collectionSeconds: 0)
}

/// Feeds ticks `from..<to` with the same reading; returns every alert that fired.
private func feed(_ evaluator: inout AlertEvaluator, _ ticks: Range<Int>, _ reading: AlertReading) -> [Alert] {
    ticks.flatMap { evaluator.alerts(for: tick($0, reading)) }
}

private func ticks(_ seconds: TimeInterval) -> Int { Int((seconds / step).rounded()) }

private let allOn = AlertConfiguration(isEnabled: true)

/// Per rule: a reading below `off`, one between `off` and `on`, and one at or above `on`.
struct AlertCase: CustomTestStringConvertible, Sendable {
    let kind: AlertRule.Kind
    let low: @Sendable (inout AlertReading) -> Void
    let middle: @Sendable (inout AlertReading) -> Void
    let high: @Sendable (inout AlertReading) -> Void
    var rule: AlertRule { AlertRule.defaults(kind) }
    var testDescription: String { kind.rawValue }

    func reading(_ set: (inout AlertReading) -> Void) -> AlertReading {
        var reading = AlertReading()
        set(&reading)
        return reading
    }
}

let alertCases: [AlertCase] = [
    AlertCase(kind: .sustainedCPU, low: { $0.cpu = 0.3 }, middle: { $0.cpu = 0.7 }, high: { $0.cpu = 0.95 }),
    AlertCase(kind: .memory, low: { $0.memoryUsed = 0.6 }, middle: { $0.memoryUsed = 0.85 }, high: { $0.memoryUsed = 0.93 }),
    AlertCase(kind: .swap, low: { $0.swap = 0.5 * gib }, middle: { $0.swap = 1.5 * gib }, high: { $0.swap = 3 * gib }),
    // Thermal's off equals its on, so there is no in-between: fair counts as clear.
    AlertCase(kind: .thermal, low: { $0.thermal = .fair }, middle: { $0.thermal = .fair }, high: { $0.thermal = .serious }),
    AlertCase(kind: .containers, low: { $0.containers = 2 }, middle: { $0.containers = 5 }, high: { $0.containers = 7 }),
]

@Suite("Alert policies")
struct AlertPolicyTests {
    @Test("fire → hold → clear → cooldown", arguments: alertCases)
    func lifecycle(_ c: AlertCase) throws {
        let rule = c.rule
        var evaluator = AlertEvaluator(configuration: allOn)
        let low = c.reading(c.low), middle = c.reading(c.middle), high = c.reading(c.high)
        var n = 0
        func run(_ count: Int, _ reading: AlertReading) -> [Alert] {
            defer { n += count }
            return feed(&evaluator, n..<(n + count), reading)
        }

        // Below on → nothing.
        #expect(run(ticks(rule.sustain) + 4, low).isEmpty)
        // On for less than sustain → nothing (and the dip resets the hold).
        #expect(run(ticks(rule.sustain) - 1, high).isEmpty)
        #expect(run(1, low).isEmpty)
        // On for sustain → exactly one alert, on the tick that completes it.
        #expect(run(ticks(rule.sustain) - 1, high).isEmpty)
        let fired = run(1, high)
        let alert = try #require(fired.first)
        #expect(fired.count == 1)
        #expect(alert.rule == c.kind)
        let firstFiring = alert.firedAt
        // Staying high → no repeat.
        #expect(run(ticks(rule.cooldown) + 10, high).isEmpty)
        // Dipping between off and on → no clear and no repeat, even after the cooldown.
        if c.kind != .thermal {
            #expect(run(ticks(rule.clear) + 4, middle).isEmpty)
            #expect(run(ticks(rule.sustain) + 4, high).isEmpty)
        }

        // A fresh firing, then: below off for clear, high again inside the cooldown → nothing.
        evaluator = AlertEvaluator(configuration: allOn)
        n = 0
        let refired = run(ticks(rule.sustain), high)
        #expect(refired.count == 1)
        let fireTick = n
        #expect(run(max(1, ticks(rule.clear)), low).isEmpty)
        // The tick whose end is a full cooldown after the firing is the first that may fire again.
        #expect(run(ticks(rule.cooldown) - 1 - (n - fireTick), high).isEmpty)
        // After the cooldown → a second alert (the value has stayed high long enough).
        let second = run(1, high)
        #expect(second.count == 1)
        #expect(second.first.map { $0.firedAt.timeIntervalSince(refired[0].firedAt) } == rule.cooldown)
        #expect(firstFiring > refired[0].firedAt)
    }

    @Test("the first firing comes exactly `sustain` after the value reached `on`", arguments: alertCases)
    func timing(_ c: AlertCase) throws {
        var evaluator = AlertEvaluator(configuration: allOn)
        let alerts = (0..<ticks(c.rule.sustain) + 2).flatMap { n in evaluator.alerts(for: tick(n, c.reading(c.high))).map { (n, $0) } }
        let (n, alert) = try #require(alerts.first)
        #expect(alerts.count == 1)
        #expect(n == ticks(c.rule.sustain) - 1)
        #expect(alert.firedAt == t0.addingTimeInterval(c.rule.sustain))
    }

    @Test("master switch off → nothing")
    func masterOff() {
        var evaluator = AlertEvaluator(configuration: AlertConfiguration(isEnabled: false))
        let everything = AlertReading(cpu: 1, memoryUsed: 0.99, swap: 8 * gib, thermal: .critical, containers: 12)
        #expect(feed(&evaluator, 0..<ticks(20 * 60), everything).isEmpty)
        #expect(AlertConfiguration.off.isEnabled == false)
        #expect(LiveConfiguration().alerts == .off)
    }

    @Test("one rule off → nothing for it; the others still fire")
    func singleRuleOff() {
        var configuration = allOn
        configuration.rules = configuration.rules.map { rule in
            var rule = rule
            rule.isEnabled = rule.kind != .sustainedCPU
            return rule
        }
        var evaluator = AlertEvaluator(configuration: configuration)
        let fired = feed(&evaluator, 0..<ticks(3 * 60), AlertReading(cpu: 1, swap: 3 * gib))
        #expect(fired.map(\.rule) == [.swap])
    }

    @Test("a gap in ticks resets holding")
    func gapResetsHolding() {
        var evaluator = AlertEvaluator(configuration: allOn)
        let hot = AlertReading(cpu: 0.95)
        let hold = ticks(AlertRule.sustainedCPU.sustain)
        #expect(feed(&evaluator, 0..<(hold - 2), hot).isEmpty)
        // Paused for a minute: the next tick starts 60 s after the last ended.
        let resumed = hold - 2 + ticks(60)
        #expect(feed(&evaluator, resumed..<(resumed + hold - 1), hot).isEmpty)
        #expect(feed(&evaluator, (resumed + hold - 1)..<(resumed + hold), hot).count == 1)
    }

    @Test("swap above 2 GB for 10 minutes: one alert at 1 minute, then quiet")
    func swapHeld() throws {
        var evaluator = AlertEvaluator(configuration: allOn)
        let swapped = AlertReading(swap: 3 * gib)
        let fired = (0..<ticks(10 * 60)).flatMap { n in evaluator.alerts(for: tick(n, swapped)).map { (n, $0) } }
        let (n, alert) = try #require(fired.first)
        #expect(fired.count == 1)
        #expect(alert.rule == .swap)
        #expect(n == ticks(60) - 1)
    }

    @Test("ticks shaped like LiveMonitor's, 5 s apart plus 100–200 ms of collection: jitter never resets holding")
    func jitteredTicks() throws {
        // LiveMonitor: a tick starts at the previous reading's wall clock and lasts the monotonic
        // time between readings; the next reading comes a full interval after the tick finished.
        // Wall clock and monotonic clock are read a few microseconds apart, so allow ±5 ms between them.
        var generator = SystemRandomNumberGenerator()
        var evaluator = AlertEvaluator(configuration: allOn)
        let hot = AlertReading(cpu: 0.95, swap: 3 * gib)
        var wall = t0
        var fired: [(TimeInterval, Alert)] = []
        for n in 0..<ticks(10 * 60) {
            let elapsed = step + Double.random(in: 0.1...0.2, using: &generator)
            let skew = Double.random(in: -0.005...0.005, using: &generator)
            let next = wall.addingTimeInterval(elapsed + skew)
            fired += evaluator.alerts(for: tick(n, hot, start: wall, interval: elapsed)).map { ($0.firedAt.timeIntervalSince(t0), $0) }
            wall = next
        }
        #expect(fired.map(\.1.rule).sorted { $0.rawValue < $1.rawValue } == [.sustainedCPU, .swap])
        let swap = try #require(fired.first { $0.1.rule == .swap })
        #expect(swap.0 >= 60 && swap.0 < 60 + step + 0.3)
        let cpu = try #require(fired.first { $0.1.rule == .sustainedCPU })
        #expect(cpu.0 >= 120 && cpu.0 < 120 + step + 0.3)
    }

    @Test("a gap resets clearing too, but the cooldown carries across it")
    func gapKeepsCooldown() {
        var evaluator = AlertEvaluator(configuration: allOn)
        let hot = AlertReading(cpu: 0.95), cool = AlertReading(cpu: 0.2)
        let hold = ticks(AlertRule.sustainedCPU.sustain)
        #expect(feed(&evaluator, 0..<hold, hot).count == 1)
        #expect(feed(&evaluator, hold..<(hold + ticks(60)), cool).isEmpty)
        // A new session 5 minutes later, still inside the 15-minute cooldown.
        let restart = hold + ticks(6 * 60)
        #expect(feed(&evaluator, restart..<(restart + hold + 4), hot).isEmpty)
    }

    @Test("thermal unavailable never fires")
    func thermalUnavailable() {
        var evaluator = AlertEvaluator(configuration: allOn)
        #expect(feed(&evaluator, 0..<ticks(10 * 60), AlertReading(thermal: .unavailable)).isEmpty)
        // Unavailable in the middle of a hold breaks it.
        let hold = ticks(AlertRule.thermal.sustain)
        var other = AlertEvaluator(configuration: allOn)
        #expect(feed(&other, 0..<(hold - 1), AlertReading(thermal: .critical)).isEmpty)
        #expect(feed(&other, (hold - 1)..<hold, AlertReading(thermal: .unavailable)).isEmpty)
        #expect(feed(&other, hold..<(2 * hold - 1), AlertReading(thermal: .critical)).isEmpty)
        #expect(feed(&other, (2 * hold - 1)..<(2 * hold), AlertReading(thermal: .critical)).first?.title == "Thermal pressure critical for 1 minute")
    }

    @Test("containers when Docker is unavailable → nothing")
    func dockerUnavailable() {
        var evaluator = AlertEvaluator(configuration: allOn)
        #expect(feed(&evaluator, 0..<ticks(10 * 60), AlertReading(containers: nil)).isEmpty)
    }

    @Test("wording: title, observations, projects and suggestion; no paths")
    func wording() throws {
        var evaluator = AlertEvaluator(configuration: allOn)
        let all = AlertReading(cpu: 0.95, memoryUsed: 0.93, swap: 3 * gib, thermal: .serious, containers: 7)
        let fired = feed(&evaluator, 0..<ticks(2 * 60), all)
        #expect(Set(fired.map(\.rule)) == Set(AlertRule.Kind.allCases))
        let byRule = Dictionary(uniqueKeysWithValues: fired.map { ($0.rule, $0) })

        let cpu = try #require(byRule[.sustainedCPU])
        #expect(cpu.title == "CPU above 80% for 2 minutes")
        #expect(cpu.observations.map(\.label) == ["CPU now", "Threshold", "Held", "Busiest projects"])
        #expect(cpu.observations[0].value == "95% (9.5 of 10 cores)")
        #expect(cpu.observations[1].value == "80%; clears below 60%")
        #expect(cpu.observations[2].value == "2 minutes")
        #expect(cpu.projects == ["FDA", "shop"])
        #expect(cpu.suggestion == "Open Live to see what's busy.")

        #expect(byRule[.memory]?.title == "Memory above 90% used for 2 minutes")
        #expect(byRule[.memory]?.observations[0].value == "93% (7% available)")
        #expect(byRule[.swap]?.title == "Swap above 2 GB for 1 minute")
        #expect(byRule[.thermal]?.title == "Thermal pressure serious for 1 minute")
        #expect(byRule[.containers]?.title == "6 or more containers running for 1 minute")
        #expect(byRule[.containers]?.observations[1].value == "6 or more; clears at 4 or fewer")
        #expect(byRule[.containers]?.projects == ["FDA", "shop"])

        for alert in fired {
            let text = ([alert.title, alert.suggestion] + alert.projects + alert.observations.flatMap { [$0.label, $0.value] }).joined(separator: " ")
            #expect(!text.contains("/"), "\(text)")
            #expect(!text.contains(home))
            #expect(!alert.suggestion.isEmpty)
            #expect((1...3).contains(alert.projects.count))
        }
    }

    @Test("each alert adds an .alertFired timeline event at its firing time")
    func timelineEvent() throws {
        var evaluator = AlertEvaluator(configuration: allOn)
        let alert = try #require(feed(&evaluator, 0..<ticks(60), AlertReading(swap: 3 * gib)).first)
        let event = alert.timelineEvent
        #expect(event.kind == .alertFired)
        #expect(event.title == alert.title)
        #expect(event.timestamp == alert.firedAt)
        #expect(!event.isInference)
    }

    @Test("LiveMonitor: alerts land on the tick and its events, off by default, and the cooldown survives a restart")
    func liveMonitorWiring() async throws {
        let quiet = LiveMonitor(processSampler: ClockedProcessSampler(), systemSampler: FullMemorySampler(), sleep: { _ in await Task.yield() })
        let plain = await liveTicks(quiet.start(LiveConfiguration()), count: 4)
        #expect(plain.allSatisfy { $0.alerts.isEmpty && !$0.events.contains { $0.kind == .alertFired } })
        await quiet.stop()

        // 95% used for 2 s (ticks are 1 s apart): fires on the second tick, once.
        let rule = AlertRule(kind: .memory, on: 0.9, off: 0.8, sustain: 2, clear: 1)
        let configuration = LiveConfiguration(alerts: AlertConfiguration(isEnabled: true, rules: [rule]))
        let live = LiveMonitor(processSampler: ClockedProcessSampler(), systemSampler: FullMemorySampler(), sleep: { _ in await Task.yield() })
        let got = await liveTicks(live.start(configuration), count: 5)
        await live.stop()
        #expect(got.map(\.alerts.count) == [0, 1, 0, 0, 0])
        let alert = try #require(got[1].alerts.first)
        #expect(alert.title == "Memory above 90% used for 2 seconds")
        #expect(got[1].events.contains(alert.timelineEvent))
        #expect(got[4].timeline.events.filter { $0.kind == .alertFired }.count == 1)

        // Pause and start again on the same monitor: still inside the cooldown.
        let again = await liveTicks(live.start(configuration), count: 5)
        await live.stop()
        #expect(again.allSatisfy { $0.alerts.isEmpty })
    }

    @Test("threshold choices keep a lower off; the nearest choice wins for a stored value")
    func thresholdChoices() {
        for kind in AlertRule.Kind.allCases {
            let choices = AlertRule.thresholdChoices(kind)
            #expect(!choices.isEmpty)
            #expect(choices.contains { $0.on == AlertRule.defaults(kind).on && $0.off == AlertRule.defaults(kind).off })
            for choice in choices { #expect(choice.off <= choice.on) }
        }
        let cpu = AlertRule.defaults(.sustainedCPU, on: 0.62)
        #expect(cpu.on == 0.6 && cpu.off == 0.4)
        let swap = AlertRule.defaults(.swap, on: 1 * gib, isEnabled: false)
        #expect(swap.off == 0.5 * gib && !swap.isEnabled)
        #expect(AlertRule.defaults(.containers, on: 10).off == 9)
    }

    @Test("history stores and reads back the new event kind")
    func history() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heatlens-history-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.sqlite")
        let store = try HistoryStore(url: url, now: { t0.addingTimeInterval(60) })
        let point = HistoryPoint(timestamp: t0, thermalState: .nominal, hostBusyFraction: 0.9, swapUsedBytes: 0, memoryPressure: .normal,
                                 cpuTemperatureCelsius: nil, systemWatts: nil, processWatts: nil)
        let event = TimelineEvent(timestamp: t0, kind: .alertFired, title: "CPU above 80% for 2 minutes", projectName: "FDA")
        try await store.record(point, projects: [], events: [event])
        let window = try await store.window(since: t0.addingTimeInterval(-60))
        #expect(window.events == [event])
        await store.close()
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("1,000 processes: under 2 ms a tick")
    func cost() {
        var many: [ProcessSample] = []
        for i in 0..<1_000 {
            let cwd = i % 2 == 0 ? fda : shop
            many.append(SyntheticSnapshots.process(pid: Int32(1_000 + i), name: "node", executablePath: "/usr/local/bin/node",
                                                   arguments: ["node", "worker-\(i).js"], currentDirectory: cwd, cpu: 5))
        }
        let busy = AlertReading(cpu: 0.95, memoryUsed: 0.93, swap: 3 * gib, thermal: .serious, containers: 7)
        let runs = 200
        // Projects are resolved once; each tick just moves on by one interval.
        let base = tick(0, busy, processes: many)
        let prepared = (0..<runs).map { n in
            let snapshot = ScanSnapshot(startedAt: t0.addingTimeInterval(Double(n) * step), interval: step, system: base.snapshot.system,
                                        processes: base.snapshot.processes, notices: [])
            return LiveTick(sequence: n + 1, snapshot: snapshot, groups: base.groups, hardware: base.hardware, docker: base.docker,
                            projects: base.projects, topByCPU: [], topByMemory: [], history: base.history, collectionSeconds: 0)
        }
        var evaluator = AlertEvaluator(configuration: allOn)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for tick in prepared { _ = evaluator.alerts(for: tick) }
        }
        let (seconds, attoseconds) = elapsed.components
        let perTick: Double = (Double(seconds) * 1_000 + Double(attoseconds) / 1e15) / Double(runs)
        #expect(perTick < 2, "\(perTick) ms per tick")
    }
}

/// No processes; a clock that advances 1 s per call.
private final class ClockedProcessSampler: ProcessSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func snapshot() throws -> ProcessCounters {
        let call = lock.withLock { calls += 1; return calls }
        return ProcessCounters(monotonicNanoseconds: UInt64(call) * 1_000_000_000, wallClock: t0.addingTimeInterval(TimeInterval(call)),
                               processes: [])
    }
}

/// 5% of memory available, so 95% used.
private struct FullMemorySampler: SystemSampling {
    func counters() -> HostCounters {
        HostCounters(perCore: [CPULoadTicks(user: 0, system: 0, idle: 0, nice: 0)], swapOuts: 0)
    }

    func state() async throws -> HostState {
        HostState(coreCount: 1, totalBytes: 1 << 30, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                  compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0, memoryAvailable: true, pressure: .normal,
                  availablePercent: 5, thermalState: .nominal, pmset: nil)
    }
}

private func liveTicks(_ stream: AsyncStream<LiveEvent>, count: Int) async -> [LiveTick] {
    var result: [LiveTick] = []
    for await event in stream {
        if case .tick(let tick) = event { result.append(tick) }
        if result.count == count { break }
    }
    return result
}
