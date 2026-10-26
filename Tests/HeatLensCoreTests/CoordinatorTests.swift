import Darwin
import Foundation
import Testing
@testable import HeatLensCore

/// Returns scripted readings: `before` on the first call, then whatever `after` builds from
/// the live clocks on later calls. Every reading is `.available`, so no `ps` ever runs.
private final class FakeProcessSampler: ProcessSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let before: [ProcessReading]
    private let after: @Sendable (Date) -> [ProcessReading]

    init(before: [ProcessReading], after: @escaping @Sendable (Date) -> [ProcessReading]) {
        self.before = before
        self.after = after
    }

    func snapshot() throws -> ProcessCounters {
        let call = lock.withLock { calls += 1; return calls }
        let now = Date()
        return ProcessCounters(monotonicNanoseconds: ProcessCounters.monotonicNow(), wallClock: now,
                               processes: call == 1 ? before : after(now))
    }
}

private struct FakeSystemSampler: SystemSampling {
    func counters() -> HostCounters {
        HostCounters(perCore: [CPULoadTicks(user: 0, system: 0, idle: 0, nice: 0)], swapOuts: 0)
    }

    func state() async throws -> HostState {
        HostState(coreCount: 1, totalBytes: 1 << 30, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                  compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0, memoryAvailable: true, pressure: .normal,
                  availablePercent: 50, thermalState: .nominal, pmset: nil)
    }
}

private func reading(_ identity: ProcessIdentity, cpuSeconds: Double?, owner: ProcessOwner = .currentUser,
             access: DetailAccess = .available) -> ProcessReading {
    ProcessReading(identity: identity, parentPID: 1, owner: owner, name: "fake-\(identity.pid)",
                   cpu: cpuSeconds.map { CPUTime(userNanoseconds: UInt64($0 * 1e9), systemNanoseconds: 0) },
                   residentBytes: access == .available ? 1 << 20 : nil, detailAccess: access)
}

private func micros(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000_000) }

private func fakeCoordinator(before: [ProcessReading] = [],
                     after: @escaping @Sendable (Date) -> [ProcessReading] = { _ in [] }) -> ScanCoordinator {
    ScanCoordinator(processSampler: FakeProcessSampler(before: before, after: after), systemSampler: FakeSystemSampler())
}

@Suite("ScanCoordinator with fake samplers")
struct CoordinatorFakeTests {
    @Test("PID reuse: the old instance is .processExited with no CPU; the new one is born mid-scan")
    func pidReuse() async throws {
        let longLived = ProcessIdentity(pid: 7, startTimeMicros: micros(Date()) - 3_600_000_000)
        let original = ProcessIdentity(pid: 42, startTimeMicros: micros(Date()) - 60_000_000)
        let vanished = ProcessIdentity(pid: 9, startTimeMicros: micros(Date()) - 60_000_000)
        let coordinator = fakeCoordinator(
            before: [reading(longLived, cpuSeconds: 10), reading(original, cpuSeconds: 30), reading(vanished, cpuSeconds: 1)],
            after: { now in
                // Same pid 42, new start time half a second ago: a different process.
                let reused = ProcessIdentity(pid: 42, startTimeMicros: micros(now) - 500_000)
                return [reading(longLived, cpuSeconds: 11), reading(reused, cpuSeconds: 0.25)]
            })

        let snapshot = try await coordinator.scan(duration: 1) { _ in }
        let old = try #require(snapshot.processes.first { $0.identity == original })
        #expect(old.detailAccess == .processExited)
        #expect(old.cpu == nil && old.cpuPercentOfOneCore == nil)

        let gone = try #require(snapshot.processes.first { $0.identity == vanished })
        #expect(gone.detailAccess == .processExited && gone.cpu == nil)

        let reused = try #require(snapshot.processes.first { $0.pid == 42 && $0.identity != original })
        #expect(reused.detailAccess == .available)
        #expect(reused.cpu?.totalNanoseconds == 250_000_000)
        // Born-mid-scan rule: percent over its own ~0.5 s lifetime, not the whole interval.
        #expect((40...60).contains(reused.cpuPercentOfOneCore ?? 0))

        let steady = try #require(snapshot.processes.first { $0.identity == longLived })
        #expect(steady.cpu?.totalNanoseconds == 1_000_000_000)
        #expect(steady.measurementSource == .libproc)
        #expect((85...101).contains(steady.cpuPercentOfOneCore ?? 0))
        #expect(snapshot.notices.contains { $0.contains("2 processes exited") })
    }

    @Test("a second concurrent scan throws .alreadyRunning; the coordinator is reusable afterwards")
    func alreadyRunning() async throws {
        let coordinator = fakeCoordinator()
        let first = Task { try await coordinator.scan(duration: 1) { _ in } }
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: ScanError.alreadyRunning) { try await coordinator.scan(duration: 1) { _ in } }
        _ = try await first.value
        _ = try await coordinator.scan(duration: 1) { _ in }
    }

    @Test("cancelling during the wait throws promptly and frees the coordinator")
    func cancelWait() async throws {
        let coordinator = fakeCoordinator()
        let scan = Task { try await coordinator.scan(duration: 10) { _ in } }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = Date()
        scan.cancel()
        await #expect(throws: CancellationError.self) { try await scan.value }
        #expect(Date().timeIntervalSince(cancelledAt) < 0.5)
        _ = try await coordinator.scan(duration: 1) { _ in }
    }

    @Test("duration is clamped to 1...15 s; non-finite or non-positive is invalid")
    func clamping() async throws {
        #expect(try ScanCoordinator.clampedDuration(0.2) == 1)
        #expect(try ScanCoordinator.clampedDuration(5) == 5)
        #expect(try ScanCoordinator.clampedDuration(10) == 10)
        #expect(try ScanCoordinator.clampedDuration(60) == 15)
        for bad in [0, -1, .nan, .infinity] as [TimeInterval] {
            #expect(throws: ScanError.invalidDuration) { try ScanCoordinator.clampedDuration(bad) }
        }
        let coordinator = fakeCoordinator()
        await #expect(throws: ScanError.invalidDuration) { try await coordinator.scan(duration: .nan) { _ in } }
        let started = Date()
        let snapshot = try await coordinator.scan(duration: 0.2) { _ in }
        #expect(snapshot.interval >= 0.95 && snapshot.interval < 1.5)
        #expect(Date().timeIntervalSince(started) >= 0.95)
    }

    @Test("progress is reported about once a second, ending at the duration")
    func progress() async throws {
        let ticks = Recorder<TimeInterval>()
        _ = try await fakeCoordinator().scan(duration: 2) { ticks.append($0) }
        let values = ticks.values
        #expect((2...3).contains(values.count))
        #expect(values == values.sorted())
        #expect(abs((values.last ?? 0) - 2) < 0.2)
    }
}

@Suite("ScanAssembly")
struct CoordinatorAssemblyTests {
    let state = HostState(coreCount: 2, totalBytes: 1 << 30, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                          compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0, memoryAvailable: true, pressure: .normal,
                          availablePercent: nil, thermalState: .unavailable, pmset: nil)

    @Test("refused processes get CPU and RSS from the two ps runs, with honest notices")
    func psFallback() throws {
        let t0 = Date()
        let root = ProcessIdentity(pid: 606, startTimeMicros: micros(t0) - 86_400_000_000)
        let own = ProcessIdentity(pid: 1000, startTimeMicros: micros(t0) - 60_000_000)
        let second: UInt64 = 1_000_000_000
        let before = ProcessCounters(monotonicNanoseconds: 10 * second, wallClock: t0,
                                     processes: [reading(root, cpuSeconds: nil, owner: .root, access: .permissionDenied),
                                                 reading(own, cpuSeconds: 1)])
        let after = ProcessCounters(monotonicNanoseconds: 12 * second, wallClock: t0.addingTimeInterval(2),
                                    processes: [reading(root, cpuSeconds: nil, owner: .root, access: .permissionDenied),
                                                reading(own, cpuSeconds: 2)])
        let psBefore = PSTimeSampler.Reading(monotonicNanoseconds: 10 * second, rows: [606: .init(cpuNanoseconds: 5 * second, residentBytes: 1)])
        let psAfter = PSTimeSampler.Reading(monotonicNanoseconds: 12 * second, rows: [606: .init(cpuNanoseconds: 6 * second, residentBytes: 4096)])
        // Two cores, 2 s: host busy 3 of 4 core-seconds = 1.5 busy cores.
        let hostBefore = HostCounters(perCore: [.init(user: 0, system: 0, idle: 0, nice: 0), .init(user: 0, system: 0, idle: 0, nice: 0)], swapOuts: 5)
        let hostAfter = HostCounters(perCore: [.init(user: 100, system: 0, idle: 0, nice: 0), .init(user: 50, system: 0, idle: 50, nice: 0)], swapOuts: 9)

        let snapshot = ScanAssembly.snapshot(startedAt: t0, before: before, after: after, psBefore: psBefore, psAfter: psAfter,
                                             psFailure: nil, hostBefore: hostBefore, hostAfter: hostAfter, state: state)
        let server = try #require(snapshot.processes.first { $0.identity == root })
        #expect(server.measurementSource == .ps)
        #expect(server.detailAccess == .permissionDenied)
        #expect(server.cpuPercentOfOneCore == 50)
        #expect(server.residentBytes == 4096)
        #expect(snapshot.system.hostBusyFraction == 0.75)
        #expect(snapshot.system.memory.swapOutsDelta == 4)
        #expect(snapshot.interval == 2)
        #expect(snapshot.notices.contains { $0.contains("1 root/other-user processes are from ps (10 ms resolution)") })
        // (1 s own + 1 s root) / 2 s = 1 core of 1.5 busy.
        #expect(snapshot.notices.contains { $0.contains("Per-process CPU accounts for 67% of measured host load") })
        #expect(snapshot.notices.contains("Thermal state unavailable."))
    }

    @Test("a ps failure leaves refused processes without CPU and says so")
    func psFailed() {
        let t0 = Date()
        let root = ProcessIdentity(pid: 606, startTimeMicros: micros(t0) - 1_000_000)
        let counters = ProcessCounters(monotonicNanoseconds: 1, wallClock: t0,
                                       processes: [reading(root, cpuSeconds: nil, owner: .root, access: .permissionDenied)])
        let later = ProcessCounters(monotonicNanoseconds: 1_000_000_001, wallClock: t0.addingTimeInterval(1), processes: counters.processes)
        let snapshot = ScanAssembly.snapshot(startedAt: t0, before: counters, after: later, psBefore: nil, psAfter: nil,
                                             psFailure: "ps exited with status 1", hostBefore: HostCounters(perCore: nil, swapOuts: nil),
                                             hostAfter: HostCounters(perCore: nil, swapOuts: nil), state: state)
        #expect(snapshot.processes.first?.cpu == nil)
        #expect(snapshot.processes.first?.measurementSource == nil)
        #expect(snapshot.notices.contains { $0.contains("CPU for 1 root/other-user processes is unavailable") })
        #expect(snapshot.notices.contains { $0.hasPrefix("Total CPU load unavailable") })
    }

    @Test("a pmset notice from the host state reaches the scan notices")
    func pmsetNotice() {
        let t0 = Date()
        let counters = ProcessCounters(monotonicNanoseconds: 1, wallClock: t0, processes: [])
        let later = ProcessCounters(monotonicNanoseconds: 1_000_000_001, wallClock: t0.addingTimeInterval(1), processes: [])
        let timedOut = HostState(coreCount: 2, totalBytes: 1 << 30, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                                 compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0, memoryAvailable: true, pressure: .normal,
                                 availablePercent: nil, thermalState: .nominal, pmset: nil,
                                 pmsetNotice: "pmset thermal data unavailable (/usr/bin/pmset did not finish within 5 s).")
        let snapshot = ScanAssembly.snapshot(startedAt: t0, before: counters, after: later, psBefore: nil, psAfter: nil,
                                             psFailure: nil, hostBefore: HostCounters(perCore: nil, swapOuts: nil),
                                             hostAfter: HostCounters(perCore: nil, swapOuts: nil), state: timedOut)
        #expect(snapshot.notices.contains("pmset thermal data unavailable (/usr/bin/pmset did not finish within 5 s)."))
        #expect(snapshot.system.pmsetCPUSpeedLimit == nil)
    }
}

@Suite("ScanCoordinator against this Mac", .serialized)
struct CoordinatorLiveTests {
    @Test("a busy `yes` fixture measures ≥ 80% of one core")
    func busyFixture() async throws {
        let fixture = try BusyFixture()
        defer { #expect(fixture.stop()) }
        try await Task.sleep(for: .milliseconds(300))

        let snapshot = try await ScanCoordinator().scan(duration: 2) { _ in }
        let yes = try #require(snapshot.processes.first { $0.identity == fixture.yesIdentity })
        #expect(yes.owner == .currentUser && yes.detailAccess == .available && yes.measurementSource == .libproc)
        // On a saturated Mac (another job using every core) `yes` cannot get a whole core, so
        // the bar drops to "clearly measured, not off by a timebase factor".
        let saturated = snapshot.system.hostBusyFraction >= 0.9
        #expect((yes.cpuPercentOfOneCore ?? 0) >= (saturated ? 30 : 80),
                "yes \(yes.cpuPercentOfOneCore ?? -1)% · host busy \(snapshot.system.hostBusyFraction)")
        #expect((yes.cpuPercentOfOneCore ?? 0) <= 105)
        #expect(snapshot.system.coreCount > 0 && snapshot.system.hostBusyFraction > 0)
        #expect(snapshot.notices.contains { $0.contains("from ps (10 ms resolution)") })
        #expect(snapshot.processes.contains { $0.measurementSource == .ps && $0.cpu != nil })
    }

    @Test("cancelling mid-scan throws within ~1 s and leaves no ps or fixture child")
    func cancelMidScan() async throws {
        let fixture = try BusyFixture()
        let psChildren = Recorder<ProcessIdentity>()
        let ps = PSTimeSampler(executable: "/bin/ps", arguments: ["-A", "-o", "pid=,time=,rss="]) { pid in
            if let identity = LibprocProcessSampler.identity(of: pid) { psChildren.append(identity) }
        }
        let coordinator = ScanCoordinator(processSampler: LibprocProcessSampler(), systemSampler: HostSystemSampler(),
                                          fallbackSampler: ps)
        let scan = Task { try await coordinator.scan(duration: 5) { _ in } }
        try await Task.sleep(for: .milliseconds(1500))

        let cancelledAt = Date()
        scan.cancel()
        await #expect(throws: CancellationError.self) { try await scan.value }
        #expect(Date().timeIntervalSince(cancelledAt) < 1)
        for child in psChildren.values { #expect(waitUntilGone(child)) }
        #expect(fixture.stop())
    }

    @Test("cancelling while ps is running terminates that ps child")
    func cancelDuringPS() async throws {
        let launched = Recorder<ProcessIdentity>()
        // A stand-in "ps" that would run for 30 s.
        let slow = PSTimeSampler(executable: "/bin/sleep", arguments: ["30"]) { pid in
            if let identity = LibprocProcessSampler.identity(of: pid) { launched.append(identity) }
        }
        let coordinator = ScanCoordinator(processSampler: LibprocProcessSampler(), systemSampler: HostSystemSampler(),
                                          fallbackSampler: slow)
        let scan = Task { try await coordinator.scan(duration: 5) { _ in } }
        let deadline = Date().addingTimeInterval(3)
        while launched.values.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let child = try #require(launched.values.first)

        let cancelledAt = Date()
        scan.cancel()
        await #expect(throws: CancellationError.self) { try await scan.value }
        #expect(Date().timeIntervalSince(cancelledAt) < 1)
        #expect(waitUntilGone(child))
    }
}
