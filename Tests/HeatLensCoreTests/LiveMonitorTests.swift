import Foundation
import Testing
@testable import HeatLensCore

private struct ListFailed: Error {}

/// Call n (from 1) returns `script(n)` with a clock that advances exactly 1 s per call, so
/// interval CPU is exact. Counts calls, and can throw on a chosen call.
private final class ScriptedProcessSampler: ProcessSampling, @unchecked Sendable {
    static let base = Date(timeIntervalSince1970: 2_000_000_000)
    private let lock = NSLock()
    private var calls = 0
    private let script: @Sendable (Int) -> [ProcessReading]
    private let failOnCall: Int?

    init(failOnCall: Int? = nil, script: @escaping @Sendable (Int) -> [ProcessReading]) {
        self.script = script
        self.failOnCall = failOnCall
    }

    var callCount: Int { lock.withLock { calls } }

    func snapshot() throws -> ProcessCounters {
        let call = lock.withLock { calls += 1; return calls }
        if call == failOnCall { throw ListFailed() }
        return ProcessCounters(monotonicNanoseconds: UInt64(call) * 1_000_000_000,
                               wallClock: Self.base.addingTimeInterval(TimeInterval(call)), processes: script(call))
    }
}

private struct QuietSystemSampler: SystemSampling {
    func counters() -> HostCounters {
        HostCounters(perCore: [CPULoadTicks(user: 0, system: 0, idle: 0, nice: 0)], swapOuts: 0)
    }

    func state() async throws -> HostState {
        HostState(coreCount: 1, totalBytes: 1 << 30, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                  compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0, memoryAvailable: true, pressure: .normal,
                  availablePercent: 50, thermalState: .nominal, pmset: nil)
    }
}

private let startMicros = Int64(ScriptedProcessSampler.base.timeIntervalSince1970 * 1_000_000) - 3_600_000_000

private func reading(_ pid: Int32, cpuSeconds: Double?, start: Int64 = startMicros, footprint: UInt64? = 64 << 20,
                     access: DetailAccess = .available) -> ProcessReading {
    let cpu: CPUTime? = cpuSeconds.map { CPUTime(userNanoseconds: UInt64($0 * 1e9), systemNanoseconds: 0) }
    return ProcessReading(identity: ProcessIdentity(pid: pid, startTimeMicros: start), parentPID: 1,
                          owner: access == .permissionDenied ? .root : .currentUser, name: "proc-\(pid)",
                          cpu: cpu, residentBytes: footprint, footprintBytes: footprint, detailAccess: access)
}

private func monitor(_ sampler: ScriptedProcessSampler,
                     sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in await Task.yield() }) -> LiveMonitor {
    LiveMonitor(processSampler: sampler, systemSampler: QuietSystemSampler(), sleep: sleep)
}

private func ticks(_ stream: AsyncStream<LiveEvent>, count: Int) async -> [LiveTick] {
    var result: [LiveTick] = []
    for await event in stream {
        if case .tick(let tick) = event { result.append(tick) }
        if result.count == count { break }
    }
    return result
}

private func names(_ stream: AsyncStream<LiveEvent>) async -> [String] {
    var result: [String] = []
    for await event in stream {
        switch event {
        case .tick: result.append("tick")
        case .autoPaused: result.append("paused")
        case .failed: result.append("failed")
        }
    }
    return result
}

private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Suite("Live monitor")
struct LiveMonitorTests {
    @Test("Nothing is sampled before start or after stop")
    func noWorkOutsideSession() async {
        let sampler = ScriptedProcessSampler { _ in [reading(10, cpuSeconds: 1)] }
        let live = monitor(sampler)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sampler.callCount == 0)
        #expect(await !live.isRunning)
        let stream = await live.start(LiveConfiguration())
        _ = await ticks(stream, count: 2)
        await live.stop()
        let afterStop = sampler.callCount
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sampler.callCount == afterStop)
        #expect(await !live.isRunning)
    }

    @Test("History is written once per tick during a session, and never before start or after stop")
    func historyOnlyFromTicks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heatlens-live-\(UUID().uuidString)/history.sqlite")
        let store = try HistoryStore(url: url)
        let sampler = ScriptedProcessSampler { call in [reading(10, cpuSeconds: Double(call))] }
        let live = monitor(sampler)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(try await store.counts().samples == 0)
        let stream = await live.start(LiveConfiguration(history: store))
        let got = await ticks(stream, count: 3)
        await live.stop()
        #expect(got.count == 3)
        #expect(await eventually { (try? await store.counts().samples) ?? 0 >= 3 })
        let written = try await store.counts().samples
        try? await Task.sleep(for: .milliseconds(100))
        #expect(try await store.counts().samples == written)
        #expect(got.allSatisfy { $0.historyFailure == nil })
        try await HistoryStore.deleteHistory(at: url, closing: store)
    }

    @Test("CPU is the delta between consecutive ticks, 100 = one core")
    func deltas() async {
        // Cumulative CPU 0 s, 0.5 s, 1.5 s, 1.75 s at 1 s steps.
        let cumulative: [Double] = [0, 0.5, 1.5, 1.75]
        let sampler = ScriptedProcessSampler { call in [reading(10, cpuSeconds: cumulative[min(call - 1, 3)])] }
        let live = monitor(sampler)
        let got = await ticks(await live.start(LiveConfiguration()), count: 3)
        await live.stop()
        let cpu: [Double?] = got.map { (tick: LiveTick) -> Double? in
            tick.snapshot.processes.first { $0.pid == 10 }?.cpuPercentOfOneCore
        }
        let expected: [Double?] = [50, 100, 25]
        #expect(cpu == expected)
        #expect(got.map(\.sequence) == [1, 2, 3])
        let intervals: [TimeInterval] = got.map(\.snapshot.interval)
        #expect(intervals == [1, 1, 1])
    }

    @Test("A reused PID between ticks is a new process, not a CPU spike for the old one")
    func pidReuse() async throws {
        let reusedStart = Int64(ScriptedProcessSampler.base.addingTimeInterval(1.5).timeIntervalSince1970 * 1_000_000)
        let sampler = ScriptedProcessSampler { call in
            call == 1 ? [reading(42, cpuSeconds: 100)] : [reading(42, cpuSeconds: 0.25, start: reusedStart)]
        }
        let live = monitor(sampler)
        let tick = try #require(await ticks(await live.start(LiveConfiguration()), count: 1).first)
        await live.stop()
        let old = try #require(tick.snapshot.processes.first { $0.pid == 42 && $0.identity.startTimeMicros == startMicros })
        #expect(old.detailAccess == .processExited)
        #expect(old.cpuPercentOfOneCore == nil)
        let new = try #require(tick.snapshot.processes.first { $0.pid == 42 && $0.identity.startTimeMicros == reusedStart })
        let newCPU: Double = new.cpuPercentOfOneCore ?? 0
        #expect(newCPU <= 100)
        #expect(tick.snapshot.notices.contains("1 processes exited since the last update."))
    }

    @Test("Live notices say root processes aren't sampled in live mode; ps never runs")
    func liveNotice() async throws {
        let sampler = ScriptedProcessSampler { _ in
            [reading(10, cpuSeconds: 1), reading(1, cpuSeconds: nil, footprint: nil, access: .permissionDenied)]
        }
        let live = monitor(sampler)
        let tick = try #require(await ticks(await live.start(LiveConfiguration()), count: 1).first)
        await live.stop()
        #expect(tick.snapshot.notices.contains("Live mode doesn't sample CPU for 1 root/other-user processes; Scan now includes them."))
        let fromPS: Int = tick.snapshot.processes.filter { $0.measurementSource == .ps }.count
        #expect(fromPS == 0)
    }

    @Test("Hardware and Docker come from the configured providers; off means disabled, not zero")
    func providers() async throws {
        let live = monitor(ScriptedProcessSampler { _ in [] })
        let tick = try #require(await ticks(await live.start(LiveConfiguration()), count: 1).first)
        await live.stop()
        #expect(tick.hardware.cpuTemperature.availability == .disabled)
        #expect(tick.hardware.cpuTemperature.value == nil)
        #expect(tick.docker.availability == .disabled)
        #expect(tick.docker.containers.isEmpty)
    }

    @Test("Top lists rank by CPU and by memory, skip exited processes, and carry aligned trends")
    func topLists() async throws {
        let sampler = ScriptedProcessSampler { call in
            [reading(1, cpuSeconds: Double(call) * 0.1, footprint: 900 << 20),
             reading(2, cpuSeconds: Double(call) * 0.9, footprint: 100 << 20),
             reading(3, cpuSeconds: 0, footprint: 500 << 20)]
        }
        let live = monitor(sampler)
        let got = await ticks(await live.start(LiveConfiguration(topCount: 2)), count: 3)
        await live.stop()
        let last = try #require(got.last)
        #expect(last.topByCPU.map(\.pid) == [2, 1])
        #expect(last.topByMemory.map(\.pid) == [1, 3])
        #expect(last.history.timestamps.count == 3)
        let trend: [Double?] = try #require(last.history.cpu[last.topByCPU[0].identity])
        let trendValues: [Double] = trend.compactMap { $0 }
        #expect(trend.count == 3)
        #expect(trendValues.count == 3)
        #expect(trendValues.allSatisfy { (value: Double) -> Bool in abs(value - 90) < 0.01 })
        let memorySeries: [UInt64?] = try #require(last.history.memoryBytes[last.topByMemory[0].identity])
        let expectedMemory: UInt64 = 900 << 20
        #expect(memorySeries.last == .some(expectedMemory))
    }

    @Test("History stays bounded and forgets processes gone for the whole window")
    func historyBound() {
        var history = LiveHistory(capacity: 3)
        let system = SyntheticSnapshots.snapshot([]).system
        func snapshot(_ pids: [Int32], at second: Int) -> ScanSnapshot {
            let processes: [ProcessSample] = pids.map { pid in SyntheticSnapshots.process(pid: pid, name: "p\(pid)", cpu: Double(pid)) }
            return ScanSnapshot(startedAt: Date(timeIntervalSince1970: TimeInterval(second)), interval: 1,
                                system: system, processes: processes, notices: [])
        }
        history.append(snapshot([1, 2], at: 0), hardware: nil)
        history.append(snapshot([1], at: 1), hardware: nil)
        #expect(history.trackedProcessCount == 2)
        for second in 2..<6 { history.append(snapshot([1], at: second), hardware: nil) }
        #expect(history.timestamps.count == 3)
        #expect(history.trackedProcessCount == 1)
        let window = history.window(for: Set(snapshot([1], at: 0).processes.map(\.identity)))
        let firstSeriesCount: Int = window.cpu.values.first?.count ?? 0
        #expect(firstSeriesCount == 3)
        #expect(window.hostBusy.count == 3)
        let temperatures: [Double?] = window.cpuTemperature
        #expect(temperatures.allSatisfy { (value: Double?) -> Bool in value == nil })
    }

    @Test("The session pauses itself after autoPauseAfter and the stream ends")
    func autoPause() async {
        let live = monitor(ScriptedProcessSampler { _ in [reading(10, cpuSeconds: 1)] })
        let events = await names(await live.start(LiveConfiguration(autoPauseAfter: 0)))
        #expect(events == ["tick", "paused"])
        #expect(await !live.isRunning)
    }

    @Test("A failing process list ends the session with .failed")
    func failure() async {
        let live = monitor(ScriptedProcessSampler(failOnCall: 3) { _ in [reading(10, cpuSeconds: 1)] })
        let events = await names(await live.start(LiveConfiguration()))
        #expect(events == ["tick", "failed"])
        #expect(await !live.isRunning)
    }

    @Test("Refresh now ends the wait early")
    func refreshNow() async throws {
        let live = monitor(ScriptedProcessSampler { call in [reading(10, cpuSeconds: Double(call))] },
                           sleep: { try await Task.sleep(for: .seconds($0 * 60)) })
        let stream = await live.start(LiveConfiguration(interval: 10))
        let started = ContinuousClock.now
        let collector = Task { await ticks(stream, count: 2) }
        for _ in 0..<2 {
            try await Task.sleep(for: .milliseconds(100))
            await live.refreshNow()
        }
        let got = await collector.value
        #expect(got.count == 2)
        #expect(started.duration(to: .now) < .seconds(5))
        await live.stop()
    }

    @Test("Dropping the stream stops the session")
    func droppingStops() async {
        let sampler = ScriptedProcessSampler { _ in [reading(10, cpuSeconds: 1)] }
        let live = monitor(sampler, sleep: { try await Task.sleep(for: .milliseconds(20 * $0)) })
        let stream = await live.start(LiveConfiguration())
        let consumer = Task { _ = await ticks(stream, count: 1_000) }
        try? await Task.sleep(for: .milliseconds(100))
        consumer.cancel()
        #expect(await eventually { await !live.isRunning })
        let calls = sampler.callCount
        try? await Task.sleep(for: .milliseconds(150))
        #expect(sampler.callCount == calls)
    }

    @Test("Starting again replaces the running session")
    func restart() async {
        let live = monitor(ScriptedProcessSampler { _ in [reading(10, cpuSeconds: 1)] })
        let first = await live.start(LiveConfiguration())
        let second = await live.start(LiveConfiguration())
        var firstEvents = 0
        for await _ in first { firstEvents += 1 }
        #expect(firstEvents <= 2)
        #expect(await ticks(second, count: 1).count == 1)
        await live.stop()
    }

    @Test("Intervals clamp to 2…10 s")
    func intervals() {
        #expect(LiveConfiguration(interval: 0.5).interval == 2)
        #expect(LiveConfiguration(interval: 100).interval == 10)
        #expect(LiveConfiguration(interval: .nan).interval == 5)
        #expect(LiveConfiguration.intervals == [2, 5, 10])
    }

    @Test("A 1,000-process tick (assembly, grouping, history, top lists) stays cheap")
    func thousandProcesses() async throws {
        let home = SyntheticSnapshots.home
        let sampler = ScriptedProcessSampler { call in
            (0..<1_000).map { index -> ProcessReading in
                let pid = Int32(2_000 + index)
                let parent: Int32 = index % 10 == 0 ? 1 : Int32(2_000 + index - index % 10)
                let project: String = home + "/Developer/p\(index / 10)"
                let cpuNanos = UInt64(call) * UInt64(index % 7) * 10_000_000
                let arguments: [String] = ["node", project + "/node_modules/.bin/vitest"]
                return ProcessReading(identity: ProcessIdentity(pid: pid, startTimeMicros: startMicros), parentPID: parent,
                                      owner: .currentUser, name: "node", executablePath: "/usr/local/bin/node",
                                      arguments: arguments, currentDirectory: project,
                                      cpu: CPUTime(userNanoseconds: cpuNanos, systemNanoseconds: 0),
                                      residentBytes: 50 << 20, footprintBytes: 60 << 20, detailAccess: .available)
            }
        }
        let live = monitor(sampler)
        let got = await ticks(await live.start(LiveConfiguration()), count: 3)
        await live.stop()
        let last = try #require(got.last)
        #expect(last.snapshot.processes.count == 1_000)
        #expect(!last.groups.isEmpty)
        // Debug-build bound; release is far lower (docs/PERFORMANCE.md).
        #expect(last.collectionSeconds < 0.5, "tick took \(last.collectionSeconds) s")
    }

    @Test("This Mac: two live ticks with the real samplers")
    func liveMac() async throws {
        let live = LiveMonitor(processSampler: LibprocProcessSampler(), systemSampler: HostSystemSampler(readsPmset: false),
                               sleep: { _ in try await Task.sleep(for: .milliseconds(500)) })
        let got = await ticks(await live.start(LiveConfiguration(hardware: SMCSensorProvider())), count: 2)
        await live.stop()
        let last = try #require(got.last)
        #expect(last.snapshot.processes.count > 20)
        #expect(last.snapshot.system.hostBusyFraction > 0)
        #expect(!last.topByCPU.isEmpty)
        #expect(!last.topByMemory.isEmpty)
        let ceiling: Double = Double(last.snapshot.system.coreCount) * 100 + 5
        let busiest: Double = last.snapshot.processes.compactMap(\.cpuPercentOfOneCore).max() ?? 0
        #expect(busiest <= ceiling)
        #expect(last.collectionSeconds < 2)
    }
}
