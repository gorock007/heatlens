import Darwin
import Foundation
import Testing
@testable import HeatLensCore

/// A stop request the test writes into the ledger itself, as if `requestStop` had sent SIGTERM
/// `secondsAgo` seconds ago (or refused it, with `sent: false`).
private func forgedStop(_ identity: ProcessIdentity, secondsAgo: TimeInterval, sent: Bool = true) -> ActionRecord {
    let at = Date().addingTimeInterval(-secondsAgo)
    return ActionRecord(at: at, action: .stopRequested,
                        target: .process(pid: identity.pid, startTimeMicros: identity.startTimeMicros, name: "fixture"),
                        projectName: nil, origin: nil, confirmedAt: nil, signalSentAt: sent ? at : nil,
                        outcome: sent ? "stillRunning" : "denied", detail: nil)
}

/// ADR-0006 §Tests 1–8. Every signal goes to a `FixtureChild` this file spawned; the root-owned
/// and Apple cases are refused before any signal by design, which is what they prove.
@Suite("Force quit with fixture children", .serialized)
struct ForceQuitTests {
    let terminator = ProcessTerminator()

    @Test("1. A child that ignores SIGTERM is .stillRunning, then force quit ends it; both are recorded")
    func happyPath() async throws {
        let child = try FixtureChild.ignoringSIGTERM()
        defer { child.stop() }
        let ledger = StopLedger()
        let confirmed = Date()
        let context = ActionContext(origin: .processDetail, processName: "bash", projectName: "demo", confirmedAt: confirmed)

        #expect(await terminator.requestStop(child.identity, wait: 0.5, ledger: ledger, context: context) == .stillRunning)
        #expect(await ledger.stopRequestedAt(child.identity) != nil)
        #expect(child.isAlive)

        #expect(await terminator.forceQuit(child.identity, ledger: ledger, context: context) == .stopped)
        #expect(waitUntilGone(child.identity))

        let records = await ledger.records(since: .distantPast)
        #expect(records.map(\.action) == [.stopRequested, .forceQuit])
        #expect(records.map(\.outcome) == ["stillRunning", "stopped"])
        #expect(records.allSatisfy { $0.signalSentAt != nil && $0.processIdentity == child.identity })
        #expect(records.allSatisfy { $0.origin == .processDetail && $0.projectName == "demo" && $0.confirmedAt == confirmed })
        #expect(records.allSatisfy { $0.detail == nil })
        if let stop = records.first?.signalSentAt, let kill = records.last?.signalSentAt {
            #expect(kill.timeIntervalSince(stop) >= ProcessTerminator.minimumGraceAfterStop - 0.05)
        }
    }

    @Test("2. A wrong start time is .identityChanged, nothing is sent and the child lives")
    func pidReuse() async throws {
        let child = try FixtureChild.waitingOnStdin()
        defer { child.stop() }
        let impostor = ProcessIdentity(pid: child.identity.pid, startTimeMicros: child.identity.startTimeMicros + 1_000_000)
        let ledger = StopLedger()
        await ledger.record(forgedStop(impostor, secondsAgo: 10))

        #expect(await terminator.forceQuit(impostor, ledger: ledger) == .identityChanged)
        try await Task.sleep(for: .milliseconds(200))
        #expect(child.isAlive)
        #expect(await ledger.records(since: .distantPast).last?.signalSentAt == nil)
    }

    @Test("3. A child the test ended after the ledger entry is .alreadyExited")
    func exitedBeforeSignal() async throws {
        let child = try FixtureChild.waitingOnStdin()
        let ledger = StopLedger()
        await ledger.record(forgedStop(child.identity, secondsAgo: 10))
        #expect(child.stop())

        #expect(await terminator.forceQuit(child.identity, ledger: ledger) == .alreadyExited)
    }

    @Test("4. pid 1 and a root-owned process are refused before any signal")
    func rootOwned() async throws {
        let ledger = StopLedger()
        let launchd = ProcessIdentity(pid: 1, startTimeMicros: 1)
        await ledger.record(forgedStop(launchd, secondsAgo: 10))
        guard case .denied = await terminator.forceQuit(launchd, ledger: ledger) else {
            Issue.record("pid 1 was not denied")
            return
        }

        // The first root process HeatLens can see; it is never signalled, only refused.
        let kinfo = Libproc.kinfoAll()
        let rootPID = try #require(kinfo.keys.sorted().first { $0 > 1 && kinfo[$0]?.uid == 0 })
        let root = try #require(LibprocProcessSampler.identity(of: rootPID))
        await ledger.record(forgedStop(root, secondsAgo: 10))
        let outcome = await terminator.forceQuit(root, ledger: ledger)
        guard case .denied = outcome else {
            Issue.record("root pid \(rootPID): expected .denied, got \(outcome)")
            return
        }
        #expect(await ledger.records(since: .distantPast).filter { $0.action == .forceQuit }.allSatisfy { $0.signalSentAt == nil })
    }

    @Test("5. An Apple binary with a forged ledger entry is denied by eligibility and lives")
    func appleBinary() async throws {
        let child = try FixtureChild("/usr/bin/head", ["-n", "1"])
        defer { child.stop() }
        let ledger = StopLedger()
        await ledger.record(forgedStop(child.identity, secondsAgo: 10))

        let outcome = await terminator.forceQuit(child.identity, ledger: ledger)
        guard case .denied(let reason) = outcome else {
            Issue.record("expected .denied, got \(outcome)")
            return
        }
        #expect(reason.contains("Apple"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(child.isAlive)
    }

    @Test("6. No sent SIGTERM for this exact identity in the last 60 s: denied at once, child lives")
    func noPriorStop() async throws {
        let child = try FixtureChild.ignoringSIGTERM()
        defer { child.stop() }
        let otherStart = ProcessIdentity(pid: child.identity.pid, startTimeMicros: child.identity.startTimeMicros + 1_000_000)
        let cases: [(String, [ActionRecord], String)] = [
            ("no entry", [], "No stop request"),
            ("entry older than 60 s", [forgedStop(child.identity, secondsAgo: ProcessTerminator.offerLifetime + 1)], "too long"),
            ("entry for a different start time", [forgedStop(otherStart, secondsAgo: 10)], "No stop request"),
            ("a refused stop request", [forgedStop(child.identity, secondsAgo: 10, sent: false)], "No stop request"),
        ]
        for (label, entries, expected) in cases {
            let ledger = StopLedger()
            for entry in entries { await ledger.record(entry) }
            let started = ContinuousClock.now
            let outcome = await terminator.forceQuit(child.identity, ledger: ledger)
            guard case .denied(let reason) = outcome else {
                Issue.record("\(label): expected .denied, got \(outcome)")
                continue
            }
            #expect(reason.contains(expected), "\(label): \(reason)")
            #expect(ContinuousClock.now - started < .seconds(1), "\(label) waited before refusing")
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(child.isAlive)
    }

    @Test("7. An entry 1 s old makes force quit wait out the 5 s grace before signalling")
    func grace() async throws {
        let child = try FixtureChild.ignoringSIGTERM()
        defer { child.stop() }
        let ledger = StopLedger()
        await ledger.record(forgedStop(child.identity, secondsAgo: 1))

        let started = ContinuousClock.now
        let outcome = await terminator.forceQuit(child.identity, ledger: ledger)
        let elapsed = ContinuousClock.now - started

        #expect(outcome == .stopped)
        #expect(elapsed >= .seconds(4))
        #expect(waitUntilGone(child.identity))
        let sentAt = try #require(await ledger.records(since: .distantPast).last?.signalSentAt)
        let stopAt = try #require(await ledger.stopRequestedAt(child.identity))
        #expect(sentAt.timeIntervalSince(stopAt) >= ProcessTerminator.minimumGraceAfterStop - 0.05)
    }

    @Test("8. One kill-signal site in Sources/, no process-group signal, no stop path in the CLI targets")
    func oneSignalSite() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files: [(path: String, text: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((String(url.path.dropFirst(sources.path.count + 1)), try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(files.count > 10, "Sources/ not found at \(sources.path)")
        func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

        let kills = files.filter { count("SIGKILL", in: $0.text) > 0 }
        #expect(kills.map(\.path) == ["HeatLensCore/Safety/ProcessTerminator.swift"])
        #expect(kills.map { count("SIGKILL", in: $0.text) } == [1])
        #expect(files.filter { $0.text.contains("killpg") }.map(\.path).isEmpty)

        let cli = files.filter { !$0.path.hasPrefix("HeatLensCore/") }
        #expect(!cli.isEmpty)
        for word in ["forceQuit", "requestStop", "StopLedger", "ProcessTerminator"] {
            #expect(cli.filter { $0.text.contains(word) }.map(\.path).isEmpty, "\(word) in a CLI target")
        }
    }
}

@Suite("Stop ledger")
struct StopLedgerTests {
    private let identity = ProcessIdentity(pid: 40_001, startTimeMicros: 7)

    @Test("stopRequestedAt is the newest sent SIGTERM for exactly this identity")
    func newestSent() async {
        let ledger = StopLedger()
        let older = forgedStop(identity, secondsAgo: 30)
        let newer = forgedStop(identity, secondsAgo: 10)
        await ledger.record(older)
        await ledger.record(newer)
        await ledger.record(forgedStop(identity, secondsAgo: 1, sent: false))
        await ledger.record(forgedStop(ProcessIdentity(pid: identity.pid, startTimeMicros: 8), secondsAgo: 0))
        #expect(await ledger.stopRequestedAt(identity) == newer.signalSentAt)
    }

    @Test("Records older than 10 minutes are kept; stopRequestedAt still looks back only 10 minutes")
    func sessionLifetime() async {
        let ledger = StopLedger()
        let old = forgedStop(identity, secondsAgo: StopLedger.stopLookupWindow + 60)
        await ledger.record(old)
        #expect(await ledger.records() == [old])
        #expect(await ledger.stopRequestedAt(identity) == nil)
        let recent = forgedStop(identity, secondsAgo: 5)
        await ledger.record(recent)
        #expect(await ledger.records() == [recent, old])
        #expect(await ledger.records(since: Date().addingTimeInterval(-60)) == [recent])
        #expect(await ledger.stopRequestedAt(identity) == recent.signalSentAt)
    }

    @Test("Keeping old records doesn't loosen force quit: a SIGTERM over 60 s old is refused, child lives")
    func offerStillExpires() async throws {
        let child = try FixtureChild.ignoringSIGTERM()
        defer { child.stop() }
        for secondsAgo in [ProcessTerminator.offerLifetime + 1, StopLedger.stopLookupWindow - 1, StopLedger.stopLookupWindow + 60] {
            let ledger = StopLedger()
            await ledger.record(forgedStop(child.identity, secondsAgo: secondsAgo))
            let outcome = await ProcessTerminator().forceQuit(child.identity, ledger: ledger)
            guard case .denied = outcome else {
                Issue.record("\(secondsAgo) s: expected .denied, got \(outcome)")
                continue
            }
            #expect(await ledger.records().first?.signalSentAt == nil)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(child.isAlive)
    }

    @Test("The ledger keeps the newest 500 records, and onRecord sees every one")
    func capacity() async {
        let seen = Counter()
        let ledger = StopLedger { _ in seen.increment() }
        let records = (0..<(StopLedger.capacity + 20)).map { index in
            ActionRecord(at: Date(timeIntervalSince1970: TimeInterval(index)), action: .stopRequested,
                         target: .process(pid: 40_000 + Int32(index), startTimeMicros: 1, name: "fixture"),
                         projectName: nil, origin: nil, confirmedAt: nil, signalSentAt: nil, outcome: "denied", detail: nil)
        }
        for record in records { await ledger.record(record) }
        let kept = await ledger.records()
        #expect(kept.count == StopLedger.capacity)
        #expect(kept.first == records.last)
        #expect(kept.last == records[20])
        #expect(seen.value == records.count)
    }

    @Test("The 3e kinds, the project target and the new origins encode and decode")
    func newKindsCodable() throws {
        let records = [
            ActionRecord(at: Date(timeIntervalSince1970: 1_800_000_000.25), action: .ignored, target: .project(name: "my-app"),
                         projectName: "my-app", origin: .projectRow, confirmedAt: nil, signalSentAt: nil, outcome: "ignored", detail: nil),
            ActionRecord(at: Date(timeIntervalSince1970: 1_800_000_001), action: .ignored,
                         target: .process(pid: 4_242, startTimeMicros: 9, name: "node"),
                         projectName: nil, origin: .findingCard, confirmedAt: nil, signalSentAt: nil, outcome: "ignored", detail: nil),
            ActionRecord(at: Date(timeIntervalSince1970: 1_800_000_002), action: .cancelled,
                         target: .container(shortID: "abcdef012345", name: "db", image: "postgres", composeProject: "fda"),
                         projectName: "FDA", origin: .containerDetail, confirmedAt: nil, signalSentAt: nil, outcome: "cancelled",
                         detail: nil, offered: .containerStop),
        ]
        let data = try JSONEncoder().encode(records)
        #expect(try JSONDecoder().decode([ActionRecord].self, from: data) == records)
        let long = ActionRecord(at: Date(), action: .ignored, target: .project(name: String(repeating: "p", count: 100)),
                                projectName: nil, origin: .projectRow, confirmedAt: nil, signalSentAt: nil, outcome: "ignored", detail: nil)
        #expect(long.target == .project(name: String(repeating: "p", count: ActionRecord.nameLimit)))
    }

    @Test("A record saved before 3e (no `offered`) still decodes")
    func oldRecordDecodes() throws {
        let json = """
            {"action":"stopRequested","at":800000000.5,"confirmedAt":799999999,"id":"5B7C1C4E-2F0E-4C47-9B44-3A0D3F2A9E11",\
            "origin":"leftoverCard","outcome":"stillRunning","projectName":"demo","signalSentAt":800000000.5,\
            "target":{"process":{"name":"node","pid":4242,"startTimeMicros":17}}}
            """
        let record = try JSONDecoder().decode(ActionRecord.self, from: Data(json.utf8))
        #expect(record.action == .stopRequested)
        #expect(record.target == .process(pid: 4_242, startTimeMicros: 17, name: "node"))
        #expect(record.origin == .leftoverCard)
        #expect(record.offered == nil)
        #expect(record.detail == nil)
        #expect(record.signalSentAt == Date(timeIntervalSinceReferenceDate: 800_000_000.5))
    }

    @Test("A refused stop request is recorded with no signalSentAt and doesn't open a force quit")
    func refusedStopRecorded() async throws {
        let child = try FixtureChild.waitingOnStdin()
        defer { child.stop() }
        let impostor = ProcessIdentity(pid: child.identity.pid, startTimeMicros: child.identity.startTimeMicros - 1_000_000)
        let ledger = StopLedger()

        #expect(await ProcessTerminator().requestStop(impostor, ledger: ledger) == .identityChanged)
        let record = try #require(await ledger.records(since: .distantPast).first)
        #expect(record.action == .stopRequested)
        #expect(record.outcome == "identityChanged")
        #expect(record.signalSentAt == nil)
        #expect(await ledger.stopRequestedAt(impostor) == nil)
        #expect(child.isAlive)
    }

    @Test("Names are capped at 80, detail is redacted and capped at 200, a container id at 12")
    func caps() {
        let home = NSHomeDirectory()
        let record = ActionRecord(at: Date(), action: .stopRequested,
                                  target: .process(pid: 2, startTimeMicros: 1, name: String(repeating: "n", count: 100)),
                                  projectName: String(repeating: "p", count: 100), origin: .batchStop, confirmedAt: nil,
                                  signalSentAt: nil, outcome: "denied",
                                  detail: "\(home)/secret/app API_TOKEN=abc123 " + String(repeating: "x", count: 300))
        guard case .process(_, _, let name) = record.target else { Issue.record("not a process"); return }
        #expect(name.count == 80)
        #expect(record.projectName?.count == 80)
        let detail = record.detail ?? ""
        #expect(detail.count == 200)
        #expect(detail.hasPrefix("~/secret/app <secret redacted>"))
        #expect(!detail.contains(home))

        let container = ActionRecord(at: Date(), action: .containerStop,
                                     target: .container(shortID: String(repeating: "a", count: 64), name: "web", image: "nginx", composeProject: nil),
                                     projectName: nil, origin: .containerDetail, confirmedAt: nil, signalSentAt: nil,
                                     outcome: "stopped", detail: nil)
        guard case .container(let shortID, _, _, _) = container.target else { Issue.record("not a container"); return }
        #expect(shortID.count == 12)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
