import Darwin
import Foundation
import Testing
@testable import HeatLensCore

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 2_000_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private func scratchURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("heatlens-history-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("history.sqlite")
}

private func point(_ date: Date, busy: Double = 0.25, thermal: ThermalState = .nominal, temperature: Double? = 55) -> HistoryPoint {
    HistoryPoint(timestamp: date, thermalState: thermal, hostBusyFraction: busy, swapUsedBytes: 1 << 30, memoryPressure: .normal,
                 cpuTemperatureCelsius: temperature, systemWatts: 18, processWatts: nil)
}

private func mode(_ path: String) -> mode_t {
    var info = Darwin.stat()
    return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
}

@Suite("History store", .serialized)
struct HistoryStoreTests {
    @Test("the folder is private (0700), the database 0600, and symlinks are refused")
    func permissions() async throws {
        let url = scratchURL()
        let store = try HistoryStore(url: url)
        try await store.record(point(Date()), projects: [], events: [])
        #expect(mode(url.deletingLastPathComponent().path) == 0o700)
        #expect(mode(url.path) == 0o600)
        await store.close()

        let other = scratchURL()
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = other.deletingLastPathComponent().appendingPathComponent("elsewhere.sqlite")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        try FileManager.default.createSymbolicLink(atPath: other.path, withDestinationPath: target.path)
        #expect(throws: HistoryStore.Failure.unsafeLocation(other.path)) { try HistoryStore(url: other) }

        let linkedFolder = scratchURL()
        let real = linkedFolder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkedFolder.deletingLastPathComponent().path, withDestinationPath: real.path)
        #expect(throws: HistoryStore.Failure.unsafeLocation(linkedFolder.deletingLastPathComponent().path)) { try HistoryStore(url: linkedFolder) }
    }

    @Test("a tick round-trips: points, projects and events, missing readings stay nil, text is bound not spliced")
    func roundTrip() async throws {
        let clock = TestClock()
        let store = try HistoryStore(url: scratchURL(), now: { clock.now })
        let t = clock.now
        let hostile = "x'); DROP TABLE samples; --"
        try await store.record(point(t, busy: 0.5, thermal: .serious, temperature: nil),
                               projects: [HistoryProjectPoint(timestamp: t, projectID: "/users/someone/developer/fda", name: "FDA",
                                                              cpuPercent: 170, memoryBytes: 96 << 20, watts: 1.5)],
                               events: [TimelineEvent(timestamp: t, kind: .testRunStarted, title: hostile, projectName: "FDA", isInference: true)])
        let window = try await store.window(since: t.addingTimeInterval(-1))
        #expect(window.points.count == 1)
        let first = try #require(window.points.first)
        #expect(first.thermalState == .serious && first.hostBusyFraction == 0.5 && first.cpuTemperatureCelsius == nil)
        #expect(window.projects.first?.name == "FDA" && window.projects.first?.watts == 1.5)
        #expect(window.events == [TimelineEvent(timestamp: t, kind: .testRunStarted, title: hostile, projectName: "FDA", isInference: true)])
        #expect(try await store.counts().samples == 1)
    }

    @Test("ticks older than an hour roll up into minutes: busy averaged, peaks and heat kept as maxima")
    func rollup() async throws {
        let clock = TestClock()
        let store = try HistoryStore(url: scratchURL(), now: { clock.now })
        let start = Date(timeIntervalSince1970: 2_000_000_000 - 2_000_000_000.truncatingRemainder(dividingBy: 60))
        // Two hours at 5 s: 1,440 ticks. Busy alternates 0.2 / 0.6; one serious tick per minute.
        for i in 0..<1_440 {
            let t = start.addingTimeInterval(TimeInterval(i * 5))
            try await store.record(point(t, busy: i % 2 == 0 ? 0.2 : 0.6, thermal: i % 12 == 3 ? .serious : .nominal), projects: [], events: [])
        }
        clock.advance(start.addingTimeInterval(7_200).timeIntervalSince(clock.now))
        try await store.maintain()
        let window = try await store.window(since: start)
        let rolled = window.points.filter { $0.sampleCount > 1 }
        let raw = window.points.filter { $0.sampleCount == 1 }
        #expect(rolled.count == 60)
        #expect(raw.count == 720)
        let minute = try #require(rolled.first)
        #expect(minute.sampleCount == 12)
        #expect(abs(minute.hostBusyFraction - 0.4) < 1e-9 && minute.hostBusyPeak == 0.6)
        #expect(minute.thermalState == .serious)
        #expect(minute.timestamp.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0)
    }

    @Test("retention drops old rows; a shorter setting applies at once")
    func retention() async throws {
        let clock = TestClock()
        let store = try HistoryStore(url: scratchURL(), retentionDays: 7, now: { clock.now })
        try await store.record(point(clock.now), projects: [], events: [TimelineEvent(timestamp: clock.now, kind: .containerStarted, title: "db")])
        clock.advance(3 * 86_400)
        try await store.record(point(clock.now), projects: [], events: [])
        try await store.maintain()
        #expect(try await store.counts().samples == 2)
        clock.advance(5 * 86_400)
        try await store.maintain()
        #expect(try await store.counts().samples == 1)
        #expect(try await store.counts().events == 0)
        try await store.setRetention(days: 1)
        #expect(try await store.counts().samples == 0)
    }

    @Test("seven days of minute-by-minute history with eight projects stays small and bounded")
    func sizeBound() async throws {
        let clock = TestClock()
        let store = try HistoryStore(url: scratchURL(), retentionDays: 7, now: { clock.now })
        let started = ContinuousClock.now
        for minute in 0..<(8 * 24 * 60) {
            clock.advance(60)
            let t = clock.now
            let projects = (0..<10).map {
                HistoryProjectPoint(timestamp: t, projectID: "/users/someone/developer/project-\($0)", name: "project-\($0)",
                                    cpuPercent: Double($0 + minute % 7), memoryBytes: 512 << 20, watts: 0.5)
            }
            try await store.record(point(t), projects: projects, events: minute % 30 == 0 ? [TimelineEvent(timestamp: t, kind: .testRunStarted, title: "vitest")] : [])
        }
        try await store.maintain()
        let counts = try await store.counts()
        #expect(counts.samples <= 7 * 24 * 60 + 1)
        #expect(counts.projectSamples <= (7 * 24 * 60 + 1) * HistoryStore.projectsPerTick)
        #expect(counts.events <= 7 * 48 + 1)
        #expect(store.fileSize < 8 << 20, "\(store.fileSize) bytes")
        #expect(started.duration(to: .now) < .seconds(60), "\(started.duration(to: .now))")
    }

    @Test("an hour of 5-second ticks with eight projects costs about a millisecond each")
    func tickCost() async throws {
        let clock = TestClock()
        let store = try HistoryStore(url: scratchURL(), now: { clock.now })
        let started = ContinuousClock.now
        for _ in 0..<720 {
            clock.advance(5)
            let t = clock.now
            try await store.record(point(t), projects: (0..<8).map {
                HistoryProjectPoint(timestamp: t, projectID: "/users/someone/developer/p\($0)", name: "p\($0)", cpuPercent: 10, memoryBytes: 1 << 20, watts: 0.2)
            }, events: [])
        }
        let perTick = started.duration(to: .now) / 720
        #expect(perTick < .milliseconds(5), "\(perTick) per tick")
        #expect(try await store.counts().projectSamples == 720 * 8)
    }

    @Test("Delete history removes the database and its WAL; a new store starts empty")
    func deleteHistory() async throws {
        let url = scratchURL()
        let store = try HistoryStore(url: url)
        try await store.record(point(Date()), projects: [], events: [])
        #expect(FileManager.default.fileExists(atPath: url.path))
        try await HistoryStore.deleteHistory(at: url, closing: store)
        for suffix in ["", "-wal", "-shm"] { #expect(!FileManager.default.fileExists(atPath: url.path + suffix)) }
        await #expect(throws: HistoryStore.Failure.open("closed")) { try await store.counts() }
        let fresh = try HistoryStore(url: url)
        #expect(try await fresh.counts().samples == 0)
        // Deleting twice is fine.
        try await HistoryStore.deleteHistory(at: url, closing: fresh)
        try await HistoryStore.deleteHistory(at: url)
    }
}
