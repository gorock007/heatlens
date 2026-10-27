import Darwin
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import HeatLensCore

/// A copy of `snapshot` with power assertions attached; the synthetic builders don't take them.
func withAssertions(_ snapshot: ScanSnapshot, _ assertions: [ProcessPowerAssertions], notices: [String]? = nil) -> ScanSnapshot {
    ScanSnapshot(id: snapshot.id, startedAt: snapshot.startedAt, interval: snapshot.interval, system: snapshot.system,
                 processes: snapshot.processes, notices: notices ?? snapshot.notices, listeningPorts: snapshot.listeningPorts,
                 powerAssertions: assertions)
}

private let observedAt = SyntheticSnapshots.startedAt.addingTimeInterval(SyntheticSnapshots.interval)
/// 3 h 12 min before the end of the synthetic scan.
private let threeHoursAgo = observedAt.addingTimeInterval(-(3 * 3_600 + 12 * 60))

private func reading(_ pid: Int32, name: String, ageSeconds: TimeInterval = 86_400, parentPID: Int32 = 1) -> ProcessReading {
    let start = Int64((Date().timeIntervalSince1970 - ageSeconds) * 1_000_000)
    return ProcessReading(identity: ProcessIdentity(pid: pid, startTimeMicros: start), parentPID: parentPID, owner: .currentUser,
                          name: name, cpu: CPUTime(userNanoseconds: 0, systemNanoseconds: 0), detailAccess: .available)
}

private func raw(_ type: String, name: String = "a name", started: Date? = Date().addingTimeInterval(-60), level: Int? = 255,
                 timeout: Double? = nil, onBehalfOf: Int32? = nil) -> [String: Any] {
    var dictionary: [String: Any] = ["AssertType": type, "AssertName": name]
    if let started { dictionary["AssertStartWhen"] = started }
    if let level { dictionary["AssertLevel"] = NSNumber(value: level) }
    if let timeout { dictionary["TimeoutSeconds"] = NSNumber(value: timeout) }
    if let onBehalfOf { dictionary["AssertionOnBehalfOfPID"] = NSNumber(value: onBehalfOf) }
    return dictionary
}

@Suite("Power assertion parsing")
struct PowerAssertionParsingTests {
    @Test("Sleep-blocking types map to plain words; transient and non-blocking types don't")
    func effects() {
        #expect(SleepEffect(assertionType: "PreventUserIdleSystemSleep") == .preventsIdleSleep)
        #expect(SleepEffect(assertionType: "NoIdleSleepAssertion") == .preventsIdleSleep)
        #expect(SleepEffect(assertionType: "PreventSystemSleep") == .preventsSleep)
        #expect(SleepEffect(assertionType: "NetworkClientActive") == .preventsSleep)
        #expect(SleepEffect(assertionType: "PreventUserIdleDisplaySleep") == .keepsDisplayOn)
        #expect(SleepEffect(assertionType: "NoDisplaySleepAssertion") == .keepsDisplayOn)
        for dropped in ["UserIsActive", "BackgroundTask", "PreventDiskIdle", "ExternalMedia", "InternalPreventDisplaySleep",
                        "SystemIsActive", "ApplePushServiceTask", "SoftwareUpdateTask", ""] {
            #expect(SleepEffect(assertionType: dropped) == nil, "\(dropped)")
        }
        #expect(SleepEffect.preventsIdleSleep.label == "Prevents idle sleep")
        #expect(SleepEffect.preventsSleep.label == "Prevents sleep")
        #expect(SleepEffect.keepsDisplayOn.label == "Keeps the display on")
    }

    @Test("Durations read as minutes, hours and minutes, or days and hours")
    func durations() {
        #expect(PowerAssertion.durationText(20) == "under 1 min")
        #expect(PowerAssertion.durationText(12 * 60 + 30) == "12 min")
        #expect(PowerAssertion.durationText(3 * 3_600 + 12 * 60) == "3 h 12 min")
        #expect(PowerAssertion.durationText(2 * 86_400 + 5 * 3_600 + 59) == "2 d 5 h")
        #expect(PowerAssertion.durationText(-5) == "under 1 min")
    }

    @Test("Reads type, name, start and timeout; drops off-level, non-blocking and unknown-PID assertions")
    func filtersAndReads() throws {
        let started = Date().addingTimeInterval(-300)
        let caffeinate = reading(100, name: "caffeinate", ageSeconds: 400)
        let raws: [Int32: [[String: Any]]] = [
            100: [
                raw("PreventUserIdleSystemSleep", name: "caffeinate command-line tool", started: started, timeout: 300),
                raw("UserIsActive"), raw("BackgroundTask"), raw("PreventDiskIdle"),
                raw("PreventUserIdleDisplaySleep", level: 0),
                raw("NoDisplaySleepAssertion", name: "", started: nil, level: nil, timeout: 0),
            ],
            // Not in the reading.
            999: [raw("PreventSystemSleep")],
        ]
        let found = PowerAssertionParsing.assertions(raws, processes: [caffeinate])
        #expect(found.map(\.identity) == [caffeinate.identity])
        let assertions = try #require(found.first?.assertions)
        #expect(assertions == [
            PowerAssertion(type: "PreventUserIdleSystemSleep", name: "caffeinate command-line tool", startedAt: started, timeoutSeconds: 300),
            // No start time sorts last; a zero timeout is no timeout.
            PowerAssertion(type: "NoDisplaySleepAssertion", name: ""),
        ])
        #expect(assertions.map(\.effect) == [.preventsIdleSleep, .keepsDisplayOn])
    }

    @Test("An assertion made on another process's behalf belongs to it; powerd's own and reused-PID ones are dropped")
    func attribution() throws {
        let coreaudiod = reading(777, name: "coreaudiod")
        let player = reading(1126, name: "Music")
        let powerd = reading(550, name: "powerd")
        let reused = reading(2000, name: "new-process", ageSeconds: 10)
        let raws: [Int32: [[String: Any]]] = [
            777: [
                raw("PreventUserIdleSystemSleep", name: "com.apple.audio.context", onBehalfOf: 1126),
                // Its beneficiary isn't in the reading: stays with coreaudiod.
                raw("PreventUserIdleSystemSleep", name: "other", onBehalfOf: 4242),
            ],
            550: [
                raw("PreventUserIdleSystemSleep", name: "Powerd - Prevent sleep while display is on"),
                raw("PreventUserIdleDisplaySleep", name: "for someone", onBehalfOf: 1126),
            ],
            // Started an hour before this process did: an earlier process with the same PID.
            2000: [raw("PreventUserIdleSystemSleep", started: Date().addingTimeInterval(-3_600))],
        ]
        let found = PowerAssertionParsing.assertions(raws, processes: [coreaudiod, player, powerd, reused])
        #expect(found.map(\.identity.pid) == [777, 1126])
        #expect(found[0].assertions.map(\.name) == ["other"])
        #expect(found[0].assertions[0].createdByPID == nil)
        #expect(Set(found[1].assertions.map(\.name)) == ["com.apple.audio.context", "for someone"])
        #expect(Set(found[1].assertions.compactMap(\.createdByPID)) == [777, 550])
    }
}

@Suite("Power assertion sampling", .serialized)
struct PowerAssertionSamplerTests {
    @Test("Live: an assertion this process creates is found for getpid(), then released")
    func findsOwnAssertion() throws {
        var id: IOPMAssertionID = 0
        let created = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                  IOPMAssertionLevel(kIOPMAssertionLevelOn), "HeatLens test" as CFString, &id)
        try #require(created == kIOReturnSuccess)
        defer { IOPMAssertionRelease(id) }
        let identity = try #require(LibprocProcessSampler.identity(of: getpid()))
        let me = ProcessReading(identity: identity, parentPID: getppid(), owner: .currentUser, name: "tests",
                                cpu: CPUTime(userNanoseconds: 0, systemNanoseconds: 0), detailAccess: .available)
        let reading = IOKitPowerAssertionSampler().powerAssertions(of: [me])
        #expect(reading.failure == nil)
        let mine = reading.assertions.first { $0.identity == identity }?.assertions ?? []
        let test = try #require(mine.first { $0.name == "HeatLens test" })
        #expect(test.type == "PreventUserIdleSystemSleep")
        #expect(test.effect == .preventsIdleSleep)
        #expect(test.createdByPID == nil)
        let started = try #require(test.startedAt)
        #expect(abs(started.timeIntervalSinceNow) < 60)
        // Only processes in the reading are reported.
        #expect(reading.assertions.allSatisfy { $0.identity == identity })
    }
}

private struct FixedAssertionSampler: PowerAssertionSampling {
    let reading: @Sendable ([ProcessReading]) -> PowerAssertionReading
    func powerAssertions(of processes: [ProcessReading]) -> PowerAssertionReading { reading(processes) }
}

private final class Readings: ProcessSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let before: [ProcessReading]
    let after: [ProcessReading]
    init(before: [ProcessReading], after: [ProcessReading]) { self.before = before; self.after = after }
    var calls: Int { lock.withLock { count } }
    func snapshot() throws -> ProcessCounters {
        let call = lock.withLock { count += 1; return count }
        return ProcessCounters(monotonicNanoseconds: ProcessCounters.monotonicNow(), wallClock: Date(),
                               processes: call == 1 ? before : after)
    }
}

private struct QuietHost: SystemSampling {
    func counters() -> HostCounters {
        HostCounters(perCore: [CPULoadTicks(user: 0, system: 0, idle: 0, nice: 0)], swapOuts: 0)
    }
    func state() async throws -> HostState {
        HostState(coreCount: 1, totalBytes: 1 << 30, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                  compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0, memoryAvailable: true, pressure: .normal,
                  availablePercent: 50, thermalState: .nominal, pmset: nil)
    }
}

/// Fails the test if an awake read touches host counters or state.
private struct NoHost: SystemSampling {
    func counters() -> HostCounters {
        Issue.record("awake() read host counters")
        return HostCounters(perCore: nil, swapOuts: nil)
    }
    func state() async throws -> HostState {
        Issue.record("awake() read host state")
        throw CancellationError()
    }
}

/// Answers no ports without touching libproc, so these tests only exercise assertions.
private struct NoPorts: PortSampling {
    func listeningPorts(of processes: [ProcessReading]) -> PortReading { PortReading(ports: [], refusedCount: 0) }
}

@Suite("Power assertions in the snapshot")
struct PowerAssertionSnapshotTests {
    private let assertion = PowerAssertion(type: "PreventUserIdleSystemSleep", name: "caffeinate command-line tool",
                                           startedAt: Date(timeIntervalSince1970: 1_000), timeoutSeconds: 300)

    @Test("The coordinator reads assertions once, from the second reading; exited holders are dropped")
    func coordinatorAttaches() async throws {
        let holder = reading(4242, name: "caffeinate")
        let gone = reading(4243, name: "gone")
        let seen = Recorder<[Int32]>()
        let assertion = self.assertion
        let sampler = FixedAssertionSampler { processes in
            seen.append(processes.map(\.identity.pid))
            return PowerAssertionReading(assertions: [
                ProcessPowerAssertions(identity: holder.identity, assertions: [assertion]),
                ProcessPowerAssertions(identity: gone.identity, assertions: [assertion]),
            ])
        }
        let coordinator = ScanCoordinator(processSampler: Readings(before: [holder, gone], after: [holder]),
                                          systemSampler: QuietHost(), portSampler: NoPorts(), assertionSampler: sampler)
        let snapshot = try await coordinator.scan(duration: 1) { _ in }
        #expect(seen.values == [[4242]])
        #expect(snapshot.powerAssertions == [ProcessPowerAssertions(identity: holder.identity, assertions: [assertion])])
        #expect(snapshot.assertions(for: holder.identity) == [assertion])
        #expect(snapshot.assertions(for: gone.identity).isEmpty)
        #expect(!snapshot.notices.contains { $0.contains("awake") })
    }

    @Test("A failed read becomes one notice and no assertions")
    func failureNotice() async throws {
        let sampler = FixedAssertionSampler { _ in
            PowerAssertionReading(assertions: [], failure: "IOPMCopyAssertionsByProcess returned 0xe00002c7")
        }
        let processes = [reading(4242, name: "x")]
        let coordinator = ScanCoordinator(processSampler: Readings(before: processes, after: processes),
                                          systemSampler: QuietHost(), portSampler: NoPorts(), assertionSampler: sampler)
        let snapshot = try await coordinator.scan(duration: 1) { _ in }
        #expect(snapshot.powerAssertions.isEmpty)
        #expect(snapshot.notices.filter { $0.contains("awake") }
                == ["What's keeping the Mac awake is unavailable (IOPMCopyAssertionsByProcess returned 0xe00002c7)."])
    }

    @Test("coordinator.awake() reads processes once and assertions once, with no host or CPU sampling")
    func coordinatorAwake() async throws {
        let holder = reading(4242, name: "caffeinate")
        let other = reading(4300, name: "other")
        let processes = Readings(before: [holder, other], after: [])
        let seen = Recorder<[Int32]>()
        let assertion = self.assertion
        let sampler = FixedAssertionSampler { processes in
            seen.append(processes.map(\.identity.pid))
            return PowerAssertionReading(assertions: [ProcessPowerAssertions(identity: holder.identity, assertions: [assertion])])
        }
        let coordinator = ScanCoordinator(processSampler: processes, systemSampler: NoHost(), portSampler: NoPorts(),
                                          assertionSampler: sampler)
        let snapshot = try await coordinator.awake()
        #expect(processes.calls == 1)
        #expect(seen.values == [[4242, 4300]])
        #expect(snapshot.interval == 0)
        #expect(snapshot.processes.allSatisfy { $0.cpu == nil })
        #expect(snapshot.powerAssertions == [ProcessPowerAssertions(identity: holder.identity, assertions: [assertion])])
        #expect(snapshot.listeningPorts.isEmpty && snapshot.notices.isEmpty)
    }

    @Test("JSON without powerAssertions decodes as empty; with them it round-trips")
    func codableBackwardCompatible() throws {
        let base = SyntheticSnapshots.oldNextServer
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
        var stripped = old
        stripped.removeValue(forKey: "powerAssertions")
        stripped.removeValue(forKey: "listeningPorts")
        let decoded = try JSONDecoder().decode(ScanSnapshot.self, from: JSONSerialization.data(withJSONObject: stripped))
        #expect(decoded.powerAssertions.isEmpty)
        #expect(decoded == base)

        let held = withAssertions(base, [ProcessPowerAssertions(identity: base.processes[0].identity, assertions: [
            assertion, PowerAssertion(type: "PreventUserIdleDisplaySleep", name: "", createdByPID: 777),
        ])])
        #expect(try JSONDecoder().decode(ScanSnapshot.self, from: JSONEncoder().encode(held)) == held)
    }
}

@Suite("Keeping the Mac awake: rules")
struct PowerAssertionRulesTests {
    /// Hot vitest, an idle detached worker, swap in use and a fair thermal state: findings of
    /// every impact, including 0 (swap).
    private func base(_ extra: [ProcessSample]) -> ScanSnapshot {
        let processes = SyntheticSnapshots.hotVitestAndIdleWorker.processes + extra
        return SyntheticSnapshots.snapshot(processes, swapUsedBytes: 2 << 30, thermal: .fair)
    }

    private let caffeinate = SyntheticSnapshots.process(pid: 700, ageHours: 4, name: "caffeinate",
                                                        executablePath: "/usr/bin/caffeinate", arguments: ["caffeinate", "-i"])

    @Test("One info finding per holding group, ranked after every other finding, which keep their IDs, order and severities")
    func ranksLast() throws {
        let plain = base([caffeinate])
        let groups = ProvenanceResolver.resolve(plain)
        let without = RulesEngine().evaluate(plain, groups: groups)
        #expect(without.count >= 3)
        let held = withAssertions(plain, [ProcessPowerAssertions(identity: caffeinate.identity, assertions: [
            PowerAssertion(type: "PreventUserIdleSystemSleep", name: "caffeinate command-line tool", startedAt: threeHoursAgo),
        ])])
        let with = RulesEngine().evaluate(held, groups: groups)
        #expect(with.count == without.count + 1)
        #expect(Array(with.dropLast()).map(\.id) == without.map(\.id))
        #expect(Array(with.dropLast()).map(\.severity) == without.map(\.severity))
        let awake = try #require(with.last)
        #expect(awake.kind == .preventingSleep)
        #expect(awake.severity == .info)
        let group = try #require(groups.first { $0.members.contains(caffeinate.identity) })
        #expect(awake.title == "Keeping your Mac awake: \(group.label)")
        #expect(awake.explanation.hasPrefix("caffeinate (PID 700) has been preventing idle sleep for 3 h 12 min."))
        #expect(awake.explanation == "caffeinate (PID 700) has been preventing idle sleep for 3 h 12 min. "
                + "It was left running after the process that started it exited (PPID 1).")
        #expect(awake.limitations == ["Apps keep the Mac awake on purpose while playing media, downloading or running a task; this is not a fault."])
        #expect(awake.evidence.contains(Evidence(label: "PreventUserIdleSystemSleep", value: "caffeinate command-line tool",
                                                 source: "IOPMCopyAssertionsByProcess")))
        #expect(awake.affectedProcesses == [caffeinate.identity])
        #expect(awake.recommendedActions.first == .inspect(caffeinate.identity))
        #expect(awake.recommendedActions.allSatisfy {
            if case .inspect = $0 { return true }
            if case .openProject = $0 { return true }
            return false
        })
    }

    @Test("A group's assertions combine into one finding, strongest effect first, with Open project when it has one")
    func combinesPerGroup() throws {
        let home = SyntheticSnapshots.home
        let agent = SyntheticSnapshots.process(pid: 800, name: "claude", executablePath: home + "/.local/bin/claude",
                                               arguments: ["claude"], currentDirectory: home + "/Developer/App", cpu: 1)
        let shell = SyntheticSnapshots.process(pid: 801, parentPID: 800, name: "zsh", executablePath: "/bin/zsh",
                                               arguments: ["zsh"], currentDirectory: home + "/Developer/App")
        let caffeinate = SyntheticSnapshots.process(pid: 802, parentPID: 801, name: "caffeinate", executablePath: "/usr/bin/caffeinate",
                                                    arguments: ["caffeinate", "-d"], currentDirectory: home + "/Developer/App")
        let snapshot = withAssertions(SyntheticSnapshots.snapshot([agent, shell, caffeinate]), [
            ProcessPowerAssertions(identity: agent.identity, assertions: [
                PowerAssertion(type: "PreventUserIdleSystemSleep", name: "a", startedAt: observedAt.addingTimeInterval(-600)),
            ]),
            ProcessPowerAssertions(identity: caffeinate.identity, assertions: [
                PowerAssertion(type: "PreventUserIdleDisplaySleep", name: "b", startedAt: observedAt.addingTimeInterval(-1_200)),
            ]),
        ])
        let groups = ProvenanceResolver.resolve(snapshot)
        let awake = RulesEngine().evaluate(snapshot, groups: groups).filter { $0.kind == .preventingSleep }
        let group = try #require(groups.first { $0.members.contains(caffeinate.identity) })
        try #require(group.members.contains(agent.identity), "the caffeinate is grouped with the agent that started it")
        #expect(awake.count == 1)
        let finding = try #require(awake.first)
        #expect(finding.explanation.hasPrefix("2 processes in this group are keeping the display on and preventing idle sleep, the longest for 20 min."))
        #expect(finding.explanation.contains("caffeinate (PID 802) was started by claude (PID 800), an AI agent."))
        #expect(finding.recommendedActions == [.inspect(agent.identity), .openProject(path: try #require(group.project).directory)])
    }

    @Test("Several left-behind caffeinates in one group share one sentence")
    func leftoverCaffeinates() throws {
        let one = SyntheticSnapshots.process(pid: 710, name: "caffeinate", executablePath: "/usr/bin/caffeinate", arguments: ["caffeinate"])
        let two = SyntheticSnapshots.process(pid: 711, name: "caffeinate", executablePath: "/usr/bin/caffeinate", arguments: ["caffeinate"])
        let held = PowerAssertion(type: "PreventUserIdleSystemSleep", name: "caffeinate command-line tool")
        let snapshot = withAssertions(SyntheticSnapshots.snapshot([one, two]), [
            ProcessPowerAssertions(identity: one.identity, assertions: [held]),
            ProcessPowerAssertions(identity: two.identity, assertions: [held]),
        ])
        let group = ProcessGroup(root: one.identity, members: [one.identity, two.identity], kind: "unknown",
                                 label: "Background processes", project: nil, confidence: .low, evidence: [])
        let finding = try #require(RulesEngine().evaluate(snapshot, groups: [group]).first { $0.kind == .preventingSleep })
        #expect(finding.explanation == "2 processes in this group are preventing idle sleep. "
                + "caffeinate PIDs 710 and 711 were left running after the processes that started them exited (PPID 1).")
        #expect(finding.recommendedActions == [.inspect(one.identity)])
    }

    @Test("No assertions, no finding")
    func none() {
        let snapshot = base([caffeinate])
        #expect(RulesEngine().evaluate(snapshot, groups: ProvenanceResolver.resolve(snapshot)).allSatisfy { $0.kind != .preventingSleep })
    }
}

@Suite("Keeping the Mac awake: reports")
struct PowerAssertionReportTests {
    private let home = SyntheticSnapshots.home

    private func fixture() -> (ScanSnapshot, [ProcessGroup], ProcessSample) {
        let caffeinate = SyntheticSnapshots.process(pid: 123, ageHours: 4, name: "caffeinate", executablePath: "/usr/bin/caffeinate",
                                                    arguments: ["caffeinate", "-i"], currentDirectory: home + "/Developer/my-app")
        let browser = SyntheticSnapshots.process(pid: 200, name: "Safari", currentDirectory: "/")
        let coreaudiod = SyntheticSnapshots.process(pid: 77, owner: .root, name: "coreaudiod", cpu: nil, detailAccess: .permissionDenied)
        let snapshot = withAssertions(SyntheticSnapshots.snapshot([coreaudiod, caffeinate, browser]), [
            ProcessPowerAssertions(identity: caffeinate.identity, assertions: [
                PowerAssertion(type: "PreventUserIdleSystemSleep", name: "caffeinate command-line tool", startedAt: threeHoursAgo,
                               timeoutSeconds: 4 * 3_600),
            ]),
            ProcessPowerAssertions(identity: browser.identity, assertions: [
                PowerAssertion(type: "PreventUserIdleDisplaySleep",
                               name: "Playing https://user:pw@video.example.com/watch?v=secret from file:///Users/someone/Movies/Holiday.mov",
                               startedAt: observedAt.addingTimeInterval(-90), createdByPID: 77),
                PowerAssertion(type: "PreventUserIdleSystemSleep",
                               name: "Exporting " + home + "/Movies/" + String(repeating: "Long project name ", count: 8)),
            ]),
        ])
        let groups = [
            ProcessGroup(root: caffeinate.identity, members: [caffeinate.identity], kind: "unknown", label: "caffeinate",
                         project: ProjectAttribution(directory: home + "/Developer/my-app", basis: "cwd", confidence: .high),
                         confidence: .low, evidence: []),
        ]
        return (snapshot, groups, caffeinate)
    }

    @Test("The text report lists each assertion with process, start, duration, timeout, creator, project and a cleaned name")
    func textSection() {
        let (snapshot, groups, _) = fixture()
        let text = Redactor.textReport(snapshot, groups: groups, findings: [], homeDirectory: home)
        let since = Redactor.clockText(threeHoursAgo, observedAt: observedAt)
        let since2 = Redactor.clockText(observedAt.addingTimeInterval(-90), observedAt: observedAt)
        let expected = "Keeping the Mac awake:\n"
            + "- Prevents idle sleep — caffeinate, PID 123, since \(since) (3 h 12 min), timeout 4 h 0 min, project my-app, name \"caffeinate command-line tool\"\n"
            + "- Keeps the display on — Safari, PID 200, since \(since2) (1 min), created by coreaudiod (PID 77), Unknown project, "
            + "name \"Playing video.example.com from <file URL>\"\n"
            + "- Prevents idle sleep — Safari, PID 200, Unknown project, name \"Exporting ~/Movies/Long project name Long project name Long project name Long p…\"\n"
        #expect(text.contains(expected))
        #expect(text.range(of: "Listening ports:")!.lowerBound < text.range(of: "Keeping the Mac awake:")!.lowerBound)
        #expect(!text.contains(home) && !text.contains("secret") && !text.contains("Holiday") && !text.contains("pw@"))
        let none = Redactor.textReport(SyntheticSnapshots.snapshot([]), groups: [], findings: [], homeDirectory: home)
        #expect(none.contains("Keeping the Mac awake:\n- none\n"))
    }

    @Test("Names: URLs become their host, home paths ~, and 80 characters at most")
    func nameCleaning() throws {
        let (snapshot, groups, _) = fixture()
        let json = try Redactor.jsonReport(snapshot, groups: groups, findings: [], homeDirectory: home)
        let jsonText = String(decoding: json, as: UTF8.self)
        #expect(!jsonText.contains(home) && !jsonText.contains("secret") && !jsonText.contains("Holiday"))
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let rows = try #require(object["powerAssertions"] as? [[String: Any]])
        #expect(rows.count == 3)
        #expect(rows[0]["pid"] as? Int == 123)
        #expect(rows[0]["type"] as? String == "PreventUserIdleSystemSleep")
        #expect(rows[0]["effect"] as? String == "Prevents idle sleep")
        #expect((rows[0]["heldSeconds"] as? NSNumber)?.doubleValue == 11_520)
        #expect((rows[0]["timeoutSeconds"] as? NSNumber)?.doubleValue == 14_400)
        #expect(rows[0]["projectDirectory"] as? String == "~/Developer/my-app")
        #expect(rows[0]["groupLabel"] as? String == "caffeinate")
        #expect(rows[1]["createdByPID"] as? Int == 77)
        #expect(rows[1]["createdByName"] as? String == "coreaudiod")
        #expect(rows[1]["name"] as? String == "Playing video.example.com from <file URL>")
        let long = try #require(rows[2]["name"] as? String)
        #expect(long.count == Redactor.assertionNameLimit)
        #expect(long.hasPrefix("Exporting ~/Movies/") && long.hasSuffix("…"))
        #expect(rows[2]["startedAt"] == nil)
    }

    @Test("Finding evidence carries the cleaned name in exports, the raw one in the app")
    func findingEvidence() throws {
        let (snapshot, groups, _) = fixture()
        let all = ProvenanceResolver.resolve(snapshot)
        let findings = RulesEngine().evaluate(snapshot, groups: all)
        let browserFinding = try #require(findings.first { $0.kind == .preventingSleep && $0.affectedProcesses.contains { $0.pid == 200 } })
        #expect(browserFinding.evidence.contains { $0.value.contains("https://user:pw@video.example.com") })
        #expect(browserFinding.evidence.contains { $0.label == "Created for PID 200 by" && $0.value == "coreaudiod (PID 77)" })
        let json = String(decoding: try Redactor.jsonReport(snapshot, groups: all, findings: findings, homeDirectory: home), as: UTF8.self)
        let text = Redactor.textReport(snapshot, groups: all, findings: findings, homeDirectory: home)
        for report in [json, text] {
            #expect(!report.contains("secret") && !report.contains("Holiday") && !report.contains(home))
            #expect(report.contains("Playing video.example.com from <file URL>"))
        }
        _ = groups
    }

    @Test("The awake reports reuse the scan report's lines and rows, with a header and notices")
    func awakeReports() throws {
        let (base, groups, _) = fixture()
        let snapshot = withAssertions(base, base.powerAssertions, notices: ["What's keeping the Mac awake is unavailable (x)."])
        let text = Redactor.awakeTextReport(snapshot, groups: groups, homeDirectory: home)
        #expect(text.hasPrefix("HeatLens: what's keeping the Mac awake, read "))
        #expect(text.contains("Notices: What's keeping the Mac awake is unavailable (x).\nKeeping the Mac awake:\n"))
        let scanText = Redactor.textReport(snapshot, groups: groups, findings: [], homeDirectory: home)
        let section = String(text[text.range(of: "Keeping the Mac awake:")!.lowerBound...])
        #expect(scanText.contains(section))

        let json = try Redactor.awakeJSONReport(snapshot, groups: groups, homeDirectory: home)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(object.keys) == ["readAt", "notices", "powerAssertions"])
        let full = try #require(try JSONSerialization.jsonObject(with: Redactor.jsonReport(snapshot, groups: groups, findings: [],
                                                                                          homeDirectory: home)) as? [String: Any])
        #expect(NSArray(array: object["powerAssertions"] as? [Any] ?? []) == NSArray(array: full["powerAssertions"] as? [Any] ?? []))
        #expect(!String(decoding: json, as: UTF8.self).contains(home))
    }

    @Test("Live: ScanPipeline.awake() finds this process's assertion in well under a second")
    func livePipelineAwake() async throws {
        var id: IOPMAssertionID = 0
        let created = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                  IOPMAssertionLevel(kIOPMAssertionLevelOn), "HeatLens pipeline test" as CFString, &id)
        try #require(created == kIOReturnSuccess)
        defer { IOPMAssertionRelease(id) }
        let clock = ContinuousClock()
        let began = clock.now
        let awake = try await ScanPipeline().awake()
        let took = began.duration(to: clock.now)
        #expect(took < .seconds(1), "took \(took)")
        #expect(awake.listings.contains { $0.identity.pid == getpid() && $0.assertion.name == "HeatLens pipeline test"
            && $0.assertion.effect == .keepsDisplayOn })
        #expect(awake.snapshot.interval == 0)
    }
}
