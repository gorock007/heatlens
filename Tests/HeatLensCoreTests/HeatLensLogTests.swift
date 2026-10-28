import Foundation
import Testing
@testable import HeatLensCore

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [HeatLensLog.Entry] = []

    func append(_ entry: HeatLensLog.Entry) { lock.withLock { entries.append(entry) } }
    var all: [HeatLensLog.Entry] { lock.withLock { entries } }
}

private func capture(_ body: () async throws -> Void) async rethrows -> [HeatLensLog.Entry] {
    let lines = Lines()
    try await HeatLensLog.$sink.withValue({ lines.append($0) }) { try await body() }
    return lines.all
}

@Suite("HeatLensLog")
struct HeatLensLogTests {
    @Test("A .name reaches the sink as private; numbers, flags and words as public text")
    func namesArePrivate() async {
        let lines = await capture {
            HeatLensLog.notice(.actions, "action recorded", ["target": .name("secret-proj"), "n": .count(3), "on": .flag(true),
                                                            "s": .seconds(1.5), "p": .percent(40), "w": .word("stopped")])
        }
        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.privateText == " target=secret-proj")
        #expect(!line.publicText.contains("secret-proj"))
        #expect(line.publicText == " n=3 on=true s=1.5s p=40% w=stopped")
        #expect(line.level == .notice && line.category == .actions && line.event == "action recorded")
    }

    @Test("A 100-tick steady idle background session emits at most one notice")
    func steadyIdleIsQuiet() async throws {
        let notices = try await capture {
            let live = LiveMonitor(processSampler: IdleProcesses(), systemSampler: IdleHost(), sleep: { _ in await Task.yield() })
            let monitor = BackgroundMonitor(monitor: live)
            var configuration = LiveConfiguration()
            configuration.history = nil
            await monitor.configure(configuration, keepWatching: true)
            let ticks = Counter()
            let stream = await monitor.subscribe(.full)
            let reader = Task { for await event in stream { if case .tick = event { ticks.increment() } } }
            let deadline = ContinuousClock.now + .seconds(20)
            while ticks.value < 100, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            #expect(ticks.value >= 100)
            reader.cancel()
            // Still sampling: stopping would add its own line.
        }
        let persisted = notices.filter { $0.level != .debug && ($0.category == .background) }
        #expect(persisted.count <= 1, "\(persisted)")
        // The session-level lines are start-only; nothing per tick.
        #expect(notices.filter { $0.level != .debug }.count <= 3)
    }

    @Test("Logger( appears only in HeatLensLog.swift, and privacy: .public is never on a String")
    func sourceGrep() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var loggerFiles: [String] = []
        var publicLines: [(file: String, line: String)] = []
        for folder in ["Sources", "App"] {
            guard let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let name = String(url.path.dropFirst(root.path.count + 1))
                if text.contains("Logger(") { loggerFiles.append(name) }
                for line in text.split(separator: "\n") where line.contains("privacy: .public") {
                    publicLines.append((name, String(line)))
                }
            }
        }
        #expect(loggerFiles == ["Sources/HeatLensCore/Logging/HeatLensLog.swift"])
        #expect(!publicLines.isEmpty)
        for (file, line) in publicLines {
            #expect(file == "Sources/HeatLensCore/Logging/HeatLensLog.swift", "\(file)")
            // Only the StaticString event and the numbers-and-words text; names go through privateText.
            #expect(line.contains("\\(event, privacy: .public)\\(publicText, privacy: .public)\\(privateText, privacy: .private)"), "\(line)")
        }
    }

    @Test("Only .name carries a String")
    func onlyNameCarriesString() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/HeatLensCore/Logging/HeatLensLog.swift"), encoding: .utf8)
        let cases = text.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ") && $0.contains("(") }
        let withString = cases.filter { $0.contains("(String)") }
        #expect(withString.count == 1 && withString[0].contains("name(String)"), "\(withString)")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class IdleProcesses: ProcessSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    static let base = Date(timeIntervalSince1970: 2_000_000_000)

    func snapshot() throws -> ProcessCounters {
        let call = lock.withLock { calls += 1; return calls }
        let start = Int64(Self.base.timeIntervalSince1970 * 1_000_000) - 3_600_000_000
        let process = ProcessReading(identity: ProcessIdentity(pid: 10, startTimeMicros: start), parentPID: 1, owner: .currentUser,
                                     name: "proc-10", cpu: CPUTime(userNanoseconds: UInt64(call) * 10_000_000, systemNanoseconds: 0),
                                     residentBytes: 64 << 20, footprintBytes: 64 << 20, detailAccess: .available)
        return ProcessCounters(monotonicNanoseconds: UInt64(call) * 1_000_000_000,
                               wallClock: Self.base.addingTimeInterval(TimeInterval(call)), processes: [process])
    }
}

private struct IdleHost: SystemSampling {
    func counters() -> HostCounters {
        HostCounters(perCore: [CPULoadTicks(user: 0, system: 0, idle: 0, nice: 0)], swapOuts: 0)
    }

    func state() async throws -> HostState {
        HostState(coreCount: 1, totalBytes: 1 << 30, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                  compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0, memoryAvailable: true, pressure: .normal,
                  availablePercent: 50, thermalState: .nominal, pmset: nil)
    }
}
