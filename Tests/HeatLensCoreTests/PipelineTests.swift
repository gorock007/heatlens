import Foundation
import Testing
@testable import HeatLensCore

/// A hot process that burns `cpuPerSecond` seconds of CPU per wall second. Every reading is
/// `.available`, so no `ps` ever runs.
private final class HotProcessSampler: ProcessSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var firstAt: Date?
    private let identity: ProcessIdentity
    private let cpuPerSecond: Double

    init(cpuPerSecond: Double) {
        identity = ProcessIdentity(pid: 4_242, startTimeMicros: Int64(Date().timeIntervalSince1970 * 1_000_000) - 600_000_000)
        self.cpuPerSecond = cpuPerSecond
    }

    func snapshot() throws -> ProcessCounters {
        let now = Date()
        let elapsed = lock.withLock { () -> TimeInterval in
            if firstAt == nil { firstAt = now }
            return now.timeIntervalSince(firstAt!)
        }
        let cpu = CPUTime(userNanoseconds: UInt64((100 + elapsed * cpuPerSecond) * 1e9), systemNanoseconds: 0)
        let hot = ProcessReading(identity: identity, parentPID: 1, owner: .currentUser, name: "vitest",
                                 executablePath: "/usr/local/bin/node", arguments: ["node", "vitest"],
                                 cpu: cpu, residentBytes: 1 << 20, detailAccess: .available)
        return ProcessCounters(monotonicNanoseconds: ProcessCounters.monotonicNow(), wallClock: now, processes: [hot])
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

private func pipeline(cpuPerSecond: Double = 1.6) -> ScanPipeline {
    ScanPipeline(coordinator: ScanCoordinator(processSampler: HotProcessSampler(cpuPerSecond: cpuPerSecond),
                                              systemSampler: QuietSystemSampler()))
}

@Suite("ScanPipeline")
struct PipelineTests {
    @Test("scan → groups → findings: a hot process becomes a ranked high-CPU finding")
    func endToEnd() async throws {
        let progress = Counter()
        let result = try await pipeline().run(duration: 1) { _ in progress.increment() }
        #expect(progress.value >= 1)
        let sample = try #require(result.snapshot.processes.first { $0.pid == 4_242 })
        #expect((120...200).contains(sample.cpuPercentOfOneCore ?? 0))
        #expect(result.groups.contains { $0.members.contains(sample.identity) })
        let first = try #require(result.findings.first)
        #expect(first.kind == .highCPU)
        #expect(first.affectedProcesses.contains(sample.identity))
    }

    @Test("cancelling the task cancels the scan")
    func cancellation() async throws {
        let scan = Task { try await pipeline().run(duration: 10) { _ in } }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = Date()
        scan.cancel()
        await #expect(throws: CancellationError.self) { try await scan.value }
        #expect(Date().timeIntervalSince(cancelledAt) < 0.5)
    }

    @Test("a second run on the same coordinator throws .alreadyRunning")
    func alreadyRunning() async throws {
        let shared = pipeline()
        let first = Task { try await shared.run(duration: 1) { _ in } }
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: ScanError.alreadyRunning) { try await shared.run(duration: 1) { _ in } }
        _ = try await first.value
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
