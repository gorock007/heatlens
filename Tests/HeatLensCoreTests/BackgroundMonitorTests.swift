import Foundation
import Testing
@testable import HeatLensCore

private struct ListFailed: Error {}

/// Call n (from 1) returns one process with a clock that advances exactly 1 s per call. Counts
/// calls, and can throw on a chosen call.
private final class ScriptedProcessSampler: ProcessSampling, @unchecked Sendable {
    static let base = Date(timeIntervalSince1970: 2_000_000_000)
    private let lock = NSLock()
    private var calls = 0
    private let failOnCall: Int?

    init(failOnCall: Int? = nil) {
        self.failOnCall = failOnCall
    }

    var callCount: Int { lock.withLock { calls } }

    func snapshot() throws -> ProcessCounters {
        let call = lock.withLock { calls += 1; return calls }
        if call == failOnCall { throw ListFailed() }
        let start = Int64(Self.base.timeIntervalSince1970 * 1_000_000) - 3_600_000_000
        let process = ProcessReading(identity: ProcessIdentity(pid: 10, startTimeMicros: start), parentPID: 1, owner: .currentUser,
                                     name: "proc-10", cpu: CPUTime(userNanoseconds: UInt64(call) * 10_000_000, systemNanoseconds: 0),
                                     residentBytes: 64 << 20, footprintBytes: 64 << 20, detailAccess: .available)
        return ProcessCounters(monotonicNanoseconds: UInt64(call) * 1_000_000_000,
                               wallClock: Self.base.addingTimeInterval(TimeInterval(call)), processes: [process])
    }
}

/// A quiet host. With `alternatingMemory`, used memory goes 50%, 10%, 50%… per tick, so a
/// memory rule at 40% (clears below 30%, no sustain, clear or cooldown) fires every other tick.
private final class ScriptedSystemSampler: SystemSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let alternatingMemory: Bool

    init(alternatingMemory: Bool = false) {
        self.alternatingMemory = alternatingMemory
    }

    func counters() -> HostCounters {
        HostCounters(perCore: [CPULoadTicks(user: 0, system: 0, idle: 0, nice: 0)], swapOuts: 0)
    }

    func state() async throws -> HostState {
        let call = lock.withLock { calls += 1; return calls }
        let available = alternatingMemory && call.isMultiple(of: 2) ? 90 : 50
        return HostState(coreCount: 1, totalBytes: 1 << 30, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                         compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0, memoryAvailable: true, pressure: .normal,
                         availablePercent: available, thermalState: .nominal, pmset: nil)
    }
}

/// No sensors, and the power context the test picks.
private struct FixedPowerHardware: HardwareSensorProviding {
    let power: PowerContext?

    func sample() -> HardwareSample {
        HardwareSampleAssembly.sample(smc: nil, smcAvailability: .disabled, power: power)
    }
}

private func power(_ source: PowerSourceKind) -> PowerContext {
    PowerContext(source: source, hasBattery: source != .ac, batteryPercent: 50, isCharging: nil, lowPowerMode: false)
}

/// Records every wait the session asks for, and waits a millisecond per second asked, so the
/// order of waits is real but a 15-minute session takes no time.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var sleeps: [TimeInterval] { lock.withLock { recorded } }

    var sleep: @Sendable (TimeInterval) async throws -> Void {
        { [self] seconds in
            lock.withLock { recorded.append(seconds) }
            try await Task.sleep(for: .milliseconds(seconds))
        }
    }

    func last(_ count: Int) -> [TimeInterval] {
        Array(sleeps.suffix(count))
    }
}

/// The 15-minute rule's clock, moved by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_900_000_000)

    var now: @Sendable () -> Date {
        { [self] in lock.withLock { date } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(seconds) }
    }
}

/// Everything one subscription received.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BackgroundEvent] = []

    func append(_ event: BackgroundEvent) {
        lock.withLock { events.append(event) }
    }

    var ticks: Int {
        lock.withLock { events.filter { if case .tick = $0 { true } else { false } }.count }
    }

    var alerts: [HeatLensCore.Alert] {
        lock.withLock { events.flatMap { (event: BackgroundEvent) -> [HeatLensCore.Alert] in if case .alerts(let alerts) = event { alerts } else { [] } } }
    }

    var stops: [BackgroundStatus.PauseReason] {
        lock.withLock { events.compactMap { if case .stopped(let reason) = $0 { reason } else { nil } } }
    }

    var statuses: [BackgroundStatus] {
        lock.withLock { events.compactMap { if case .status(let status) = $0 { status } else { nil } } }
    }
}

private func collect(_ stream: AsyncStream<BackgroundEvent>, into log: EventLog) -> Task<Void, Never> {
    Task {
        for await event in stream { log.append(event) }
    }
}

private struct Fixture {
    let processes: ScriptedProcessSampler
    let recorder = SleepRecorder()
    let clock = TestClock()
    let monitor: BackgroundMonitor

    init(processes: ScriptedProcessSampler = ScriptedProcessSampler(), system: ScriptedSystemSampler = ScriptedSystemSampler()) {
        self.processes = processes
        let live = LiveMonitor(processSampler: processes, systemSampler: system, sleep: recorder.sleep)
        monitor = BackgroundMonitor(monitor: live, now: clock.now)
    }

    /// Process-list reads so far: one per tick, plus the baseline at each session's start.
    var calls: Int { processes.callCount }
}

private func configuration(_ source: PowerSourceKind = .ac, alerts: AlertConfiguration = .off) -> LiveConfiguration {
    LiveConfiguration(hardware: FixedPowerHardware(power: power(source)), alerts: alerts)
}

/// Memory at 40% fires; below 30% clears at once; no cooldown unless asked.
private func memoryAlerts(cooldown: TimeInterval = 0) -> AlertConfiguration {
    AlertConfiguration(isEnabled: true, rules: [AlertRule(kind: .memory, on: 0.4, off: 0.3, sustain: 0, clear: 0, cooldown: cooldown)])
}

private func eventually(_ seconds: Double = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@Suite("Background monitor")
struct BackgroundMonitorTests {
    @Test("Nothing is sampled before configure or while paused; a viewer doesn't undo Pause, resume does")
    func noWorkBeforeConfigureOrWhilePaused() async {
        let fixture = Fixture()
        let monitor = fixture.monitor
        await monitor.viewerAttached(interval: 5)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fixture.calls == 0)
        #expect(await monitor.status.mode == .paused(.notConfigured))
        #expect(await !monitor.isSampling)

        await monitor.configure(configuration(), keepWatching: false)
        #expect(await eventually { fixture.calls >= 3 })
        #expect(await monitor.status.mode == .foreground(5))

        await monitor.pause()
        let paused = fixture.calls
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.calls == paused)
        #expect(await monitor.status.mode == .paused(.user))
        #expect(await monitor.status.interval == nil)

        await monitor.viewerAttached(interval: 2)
        await monitor.refreshNow()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fixture.calls == paused)
        #expect(await monitor.status.mode == .paused(.user))

        await monitor.resume()
        #expect(await eventually { fixture.calls > paused + 2 })
        #expect(await monitor.status.mode == .foreground(2))
        await monitor.pause()
    }

    @Test("Keep watching off: nothing samples without a viewer, and the viewer leaving stops sampling")
    func keepWatchingOffDetachStops() async {
        let fixture = Fixture()
        let monitor = fixture.monitor
        let log = EventLog()
        let collector = collect(await monitor.subscribe(.full), into: log)
        await monitor.configure(configuration(), keepWatching: false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fixture.calls == 0)
        #expect(await monitor.status.mode == .paused(.notWatching))

        await monitor.viewerAttached(interval: 5)
        #expect(await eventually { log.ticks >= 2 })
        #expect(fixture.recorder.sleeps.prefix(3).allSatisfy { $0 == 1 || $0 == 5 })

        await monitor.viewerDetached()
        #expect(await !monitor.isSampling)
        #expect(await monitor.status.mode == .paused(.notWatching))
        let stopped = fixture.calls
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.calls == stopped)
        #expect(await eventually { log.stops == [.notWatching] })
        collector.cancel()
    }

    @Test("Keep watching on: background starts at once, a viewer gets its interval, and leaving returns to the policy's cadence")
    func keepWatchingOnDetachChangesCadence() async {
        let cases: [(PowerSourceKind, TimeInterval, SamplingPolicy.Reason)] = [(.ac, 30, .idle), (.battery, 60, .battery)]
        for (source, interval, reason) in cases {
            let fixture = Fixture()
            let monitor = fixture.monitor
            await monitor.configure(configuration(source), keepWatching: true)
            #expect(await monitor.status.mode == .background)
            #expect(await eventually { fixture.recorder.sleeps.count >= 3 })
            #expect(Array(fixture.recorder.sleeps.prefix(3)) == [1, interval, interval], "\(source)")
            #expect(await eventually { await monitor.status.lastTickAt != nil })
            let status = await monitor.status
            #expect(status.interval == interval)
            #expect(status.reason == reason)
            #expect((status.lastTickCost ?? -1) >= 0)

            await monitor.viewerAttached(interval: 5)
            #expect(await monitor.status.mode == .foreground(5))
            #expect(await monitor.status.reason == .viewer)
            #expect(await eventually { fixture.recorder.last(2) == [5, 5] }, "\(source)")

            await monitor.viewerDetached()
            #expect(await monitor.status.mode == .background)
            // Known before the next tick: worked out from the last tick's power.
            #expect(await monitor.status.interval == interval)
            #expect(await monitor.status.reason == reason)
            #expect(await eventually { fixture.recorder.last(2) == [interval, interval] }, "\(source)")
            #expect(await monitor.isSampling)
            await monitor.pause()
        }
    }

    @Test("Keep watching on: 15 minutes of foreground falls back to background cadence")
    func forgottenForegroundFallsBack() async {
        let fixture = Fixture()
        let monitor = fixture.monitor
        await monitor.configure(configuration(), keepWatching: true)
        await monitor.viewerAttached(interval: 5)
        #expect(await eventually { fixture.recorder.last(2) == [5, 5] })

        fixture.clock.advance(14 * 60)
        let before = fixture.calls
        #expect(await eventually { fixture.calls >= before + 3 })
        #expect(await monitor.status.mode == .foreground(5))

        fixture.clock.advance(60)
        #expect(await eventually { await monitor.status.mode == .background })
        #expect(await eventually { fixture.recorder.last(2) == [30, 30] })
        #expect(await monitor.isSampling)

        // Looking again starts a new 15 minutes.
        await monitor.viewerAttached(interval: 10)
        #expect(await eventually { fixture.recorder.last(2) == [10, 10] })
        #expect(await monitor.status.mode == .foreground(10))
        await monitor.pause()
    }

    @Test("Keep watching off: 15 minutes of foreground pauses, as Live always has, until resume")
    func forgottenForegroundPausesWhenOff() async {
        let fixture = Fixture()
        let monitor = fixture.monitor
        let log = EventLog()
        let collector = collect(await monitor.subscribe(.summary), into: log)
        await monitor.configure(configuration(), keepWatching: false)
        await monitor.viewerAttached(interval: 5)
        #expect(await eventually { fixture.calls >= 3 })

        fixture.clock.advance(15 * 60)
        #expect(await eventually { await !monitor.isSampling })
        #expect(await monitor.status.mode == .paused(.autoPaused))
        #expect(await eventually { log.stops == [.autoPaused] })
        let paused = fixture.calls
        await monitor.viewerAttached(interval: 5)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.calls == paused)

        await monitor.resume()
        #expect(await monitor.status.mode == .foreground(5))
        #expect(await eventually { fixture.calls > paused + 2 })
        await monitor.pause()
        collector.cancel()
    }

    @Test("The recent-alerts ring keeps the newest 50, oldest first, and filters by time")
    func recentAlertsRing() async {
        let fixture = Fixture(system: ScriptedSystemSampler(alternatingMemory: true))
        let monitor = fixture.monitor
        let log = EventLog()
        let collector = collect(await monitor.subscribe(.summary), into: log)
        await monitor.configure(configuration(alerts: memoryAlerts()), keepWatching: true)
        #expect(await eventually(20) { log.alerts.count >= 60 })
        await monitor.pause()
        try? await Task.sleep(for: .milliseconds(50))

        let ring = await monitor.recentAlerts()
        let logged = log.alerts
        #expect(ring.count == BackgroundMonitor.recentAlertLimit)
        #expect(ring.last == logged.last)
        #expect(ring.first.map { $0 != logged.first } == true)
        #expect(zip(ring, ring.dropFirst()).allSatisfy { $0.firedAt < $1.firedAt })
        let cut = ring[39].firedAt
        #expect(await monitor.recentAlerts(since: cut) == Array(ring[40...]))
        collector.cancel()

        var bounded = RecentAlerts(limit: 3)
        let alerts = (0..<5).map {
            HeatLensCore.Alert(id: "a\($0)", rule: .memory, firedAt: Date(timeIntervalSince1970: TimeInterval($0)), title: "t",
                               observations: [], projects: [], suggestion: "s")
        }
        bounded.append(Array(alerts[0..<2]))
        bounded.append([])
        bounded.append(Array(alerts[2...]))
        #expect(bounded.alerts(since: nil).map(\.id) == ["a2", "a3", "a4"])
        #expect(bounded.alerts(since: Date(timeIntervalSince1970: 3)).map(\.id) == ["a4"])
    }

    @Test(".summary subscribers get status and alerts but no ticks; .full gets all three")
    func summaryHasNoTicks() async {
        let fixture = Fixture(system: ScriptedSystemSampler(alternatingMemory: true))
        let monitor = fixture.monitor
        let full = EventLog()
        let summary = EventLog()
        let collectors = [collect(await monitor.subscribe(.full), into: full), collect(await monitor.subscribe(.summary), into: summary)]
        await monitor.configure(configuration(alerts: memoryAlerts()), keepWatching: true)
        #expect(await eventually { summary.alerts.count >= 3 && full.alerts.count >= 3 })
        await monitor.pause()
        #expect(summary.ticks == 0)
        #expect(full.ticks > 0)
        #expect(summary.statuses.count > 3)
        #expect(summary.statuses.first?.mode == .paused(.notConfigured))
        #expect(await eventually { summary.stops == [.user] && full.stops == [.user] })
        collectors.forEach { $0.cancel() }
    }

    @Test("Cancelling every subscription stops a foreground-only session but not a background one")
    func cancellingSubscriptions() async {
        // Keep watching off: the last subscription going detaches the viewer, which stops sampling.
        let off = Fixture()
        let first = collect(await off.monitor.subscribe(.full), into: EventLog())
        let second = collect(await off.monitor.subscribe(.summary), into: EventLog())
        await off.monitor.configure(configuration(), keepWatching: false)
        await off.monitor.viewerAttached(interval: 5)
        #expect(await eventually { off.calls >= 3 })
        first.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await off.monitor.isSampling)
        second.cancel()
        #expect(await eventually { await !off.monitor.isSampling })
        #expect(await off.monitor.status.mode == .paused(.notWatching))

        // Keep watching on: background goes on; a viewer whose panel went away drops to background.
        let on = Fixture()
        let only = collect(await on.monitor.subscribe(.full), into: EventLog())
        await on.monitor.configure(configuration(), keepWatching: true)
        await on.monitor.viewerAttached(interval: 5)
        #expect(await eventually { on.recorder.last(2) == [5, 5] })
        only.cancel()
        #expect(await eventually { await on.monitor.status.mode == .background })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await on.monitor.isSampling)
        let calls = on.calls
        #expect(await eventually { on.calls > calls })
        await on.monitor.pause()
    }

    @Test("Turning Keep watching off with nobody looking stops background sampling; on again restarts it")
    func switchOffStops() async {
        let fixture = Fixture()
        let monitor = fixture.monitor
        await monitor.configure(configuration(), keepWatching: true)
        #expect(await eventually { fixture.calls >= 3 })
        await monitor.configure(configuration(), keepWatching: false)
        #expect(await !monitor.isSampling)
        #expect(await monitor.status.mode == .paused(.notWatching))
        let stopped = fixture.calls
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.calls == stopped)
        await monitor.configure(configuration(), keepWatching: true)
        #expect(await eventually { fixture.calls > stopped + 2 })
        await monitor.pause()
    }

    @Test("A cooldown holds across Pause, resume and a restart: one evaluator for the monitor's life")
    func cooldownAcrossModes() async {
        let fixture = Fixture(system: ScriptedSystemSampler(alternatingMemory: true))
        let monitor = fixture.monitor
        let log = EventLog()
        let collector = collect(await monitor.subscribe(.summary), into: log)
        await monitor.configure(configuration(alerts: memoryAlerts(cooldown: 3_600)), keepWatching: true)
        #expect(await eventually { log.alerts.count == 1 })
        await monitor.pause()
        await monitor.resume()
        await monitor.viewerAttached(interval: 2)
        await monitor.configure(configuration(alerts: memoryAlerts(cooldown: 3_600)), keepWatching: true)
        let calls = fixture.calls
        #expect(await eventually { fixture.calls >= calls + 10 })
        #expect(log.alerts.count == 1)
        await monitor.pause()
        collector.cancel()
    }

    @Test("A failing process list stops sampling with the reason, until resume")
    func failure() async {
        let fixture = Fixture(processes: ScriptedProcessSampler(failOnCall: 3))
        let monitor = fixture.monitor
        let log = EventLog()
        let collector = collect(await monitor.subscribe(.summary), into: log)
        await monitor.configure(configuration(), keepWatching: true)
        #expect(await eventually { await !monitor.isSampling })
        guard case .paused(.failed) = await monitor.status.mode else {
            Issue.record("expected a failure pause, got \(await monitor.status.mode)")
            return
        }
        #expect(await eventually { log.stops.count == 1 })
        await monitor.resume()
        #expect(await eventually { fixture.calls >= 6 })
        #expect(await monitor.isSampling)
        await monitor.pause()
        collector.cancel()
    }

    @Test("Background/ has no action path and no network code (ADR-0008 §3)")
    func noActionsInBackground() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/HeatLensCore/Background").standardized
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let forbidden = ["kill(", "requestStop", "forceQuit", "ContainerStopper", "StopLedger", "\"POST ", "URLSession", "import Network"]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for word in forbidden {
                #expect(!source.contains(word), "\(file.lastPathComponent) contains \(word)")
            }
        }
    }
}
