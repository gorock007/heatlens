import Foundation
import Security
import Testing
@testable import HeatLensCore

/// Synthetic values for the helper's messages, shared with `HelperXPCTests`.
enum HelperFixtures {
    static let base = Date(timeIntervalSince1970: 1_900_000_000)

    static func status(_ mode: BackgroundStatus.Mode = .background) -> BackgroundStatus {
        BackgroundStatus(mode: mode, interval: 30, reason: .idle, since: base, lastTickAt: base.addingTimeInterval(30), lastTickCost: 0.05)
    }

    static func alert(_ index: Int = 0) -> HeatLensCore.Alert {
        HeatLensCore.Alert(id: "memory-\(index)", rule: .memory, firedAt: base.addingTimeInterval(TimeInterval(index)),
                           title: "Memory above 90% for 2 minutes",
                           observations: [Evidence(label: "Used", value: "93%", source: "kern.memorystatus_level")],
                           projects: ["project-a"], suggestion: "Close what you aren't using.")
    }

    static let watchAlert = HeatLensCore.Alert(id: "watch-1", rule: nil,
                                               watch: .init(projectName: "project-b", metric: .cpu, projectHash: "abc123"),
                                               firedAt: base, title: "project-b above 200% CPU", observations: [],
                                               projects: ["project-b"], suggestion: "Look at project-b's builds.")

    static let explanation = Explanation(id: "burst-1", title: "Three test runs at once", observations: [
        .init(timestamp: base, evidence: Evidence(label: "vitest", value: "started", source: "libproc")),
    ], confidence: .medium, uncertainty: ["HeatLens can't tell which run heated the Mac"],
    recommendation: "Run them one after another.", startedAt: base, projects: ["project-a"],
    agentTrees: [.noAgent], affected: [ProcessIdentity(pid: 42, startTimeMicros: 7)], containerIDs: [])

    static let action = ActionRecord(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, at: base, action: .stopRequested,
                                     target: .process(pid: 4242, startTimeMicros: 99, name: "node"), projectName: "project-a",
                                     origin: .processDetail, confirmedAt: base, signalSentAt: base, outcome: "exited", detail: nil)

    static let settings = BackgroundSettings(hardwareSensors: true, docker: true,
                                             userRules: [WorkloadRule(token: "builder", label: "Builder")!],
                                             projectMappings: [ProjectMapping(root: "/Users/me/Developer/A", name: "A")],
                                             alerts: AlertConfiguration(isEnabled: true, watches: [ProjectWatch(projectID: "/users/me/developer/a", name: "A", cpu: 200)!]),
                                             keepHistory: true, historyRetentionDays: 30, mcpReadEnabled: true)

    static let window = HistoryWindow(points: [HistoryPoint(timestamp: base, thermalState: .fair, hostBusyFraction: 0.4, swapUsedBytes: 1 << 30,
                                                            memoryPressure: .warning, cpuTemperatureCelsius: nil, systemWatts: 12.5,
                                                            processWatts: nil)],
                                      projects: [HistoryProjectPoint(timestamp: base, projectID: "/users/me/a", name: "A", cpuPercent: 120,
                                                                     memoryBytes: 1 << 28, watts: nil)],
                                      events: [TimelineEvent(timestamp: base, kind: .testRunStarted, title: "vitest", projectName: "A")])

    /// A tick the size of a busy Mac: `count` processes, groups, both top lists with 150-tick
    /// trends, Docker, projects and a full session timeline.
    static func tick(processes count: Int = 1_000) -> LiveTick {
        let start = Int64(base.timeIntervalSince1970 * 1_000_000)
        let processes = (0..<count).map { index in
            ProcessSample(identity: ProcessIdentity(pid: Int32(100 + index), startTimeMicros: start - Int64(index)), parentPID: Int32(1 + index / 10),
                          owner: index.isMultiple(of: 7) ? .root : .currentUser, name: "proc-\(index)",
                          executablePath: "/Applications/Tool \(index % 40).app/Contents/MacOS/tool",
                          arguments: ["tool", "--flag", "~/projects/project-\(index % 12)/file-\(index).ts"],
                          currentDirectory: "~/projects/project-\(index % 12)",
                          cpu: CPUTime(userNanoseconds: UInt64(index) * 1_000_000, systemNanoseconds: 500_000),
                          cpuPercentOfOneCore: index.isMultiple(of: 3) ? nil : Double(index % 97) / 3,
                          residentBytes: UInt64(index + 1) << 20, footprintBytes: index.isMultiple(of: 5) ? nil : UInt64(index + 2) << 20,
                          threadCount: 4 + index % 30, detailAccess: index.isMultiple(of: 7) ? .permissionDenied : .available,
                          measurementSource: .libproc, cpuWatts: Double(index % 11) / 10, cpuEnergyNanojoules: UInt64(index) * 1_000)
        }
        let memory = MemorySnapshot(totalBytes: 18 << 30, freeBytes: 200 << 20, activeBytes: 3 << 30, inactiveBytes: 3 << 30,
                                    wiredBytes: 5 << 30, compressedBytes: 6 << 30, swapUsedBytes: 2 << 30, swapTotalBytes: 4 << 30,
                                    swapOutsDelta: 0, pressure: .normal, availablePercent: 40)
        let system = SystemSample(coreCount: 12, hostBusyFraction: 0.45, perCoreBusyFraction: Array(repeating: 0.45, count: 12),
                                  memory: memory, thermalState: .fair, pmsetCPUSpeedLimit: nil, pmsetCPUSchedulerLimit: nil)
        let snapshot = ScanSnapshot(id: UUID(), startedAt: base, interval: 5, system: system, processes: processes, notices: ["a notice"])
        let groups = stride(from: 0, to: count, by: 5).map { index in
            ProcessGroup(root: processes[index].identity, members: processes[index..<min(index + 5, count)].map(\.identity), kind: "node script",
                         label: "node script \(index)", project: ProjectAttribution(directory: "~/projects/project-\(index % 12)",
                                                                                    basis: "git repository", confidence: .high),
                         confidence: .medium, evidence: [Evidence(label: "parent", value: "zsh", source: "libproc")])
        }
        let (byCPU, byMemory) = LiveMonitor.topLists(processes, count: 12)
        var history = LiveHistory(capacity: 150)
        let trended = Set((byCPU + byMemory).map(\.identity))
        let small = ScanSnapshot(id: UUID(), startedAt: base, interval: 5, system: system,
                                 processes: processes.filter { trended.contains($0.identity) }, notices: [])
        for step in 0..<150 {
            history.append(ScanSnapshot(id: small.id, startedAt: base.addingTimeInterval(TimeInterval(step) * 5), interval: 5,
                                        system: system, processes: small.processes, notices: []), hardware: nil)
        }
        let hardware = HardwareSampleAssembly.sample(smc: nil, smcAvailability: .disabled, now: base,
                                                     power: PowerContext(source: .ac, hasBattery: true, batteryPercent: 80,
                                                                         isCharging: true, lowPowerMode: false),
                                                     thermalState: .fair, chip: "Apple M3 Pro", model: "Mac15,6")
        let containers = (0..<10).map { index in
            ContainerSample(containerID: String(repeating: "\(index)", count: 64), name: "db-\(index)", image: "postgres:16",
                            state: "running", status: "Up 3 hours", createdAt: base, labels: ["com.docker.compose.project": "a"],
                            cpuPercentOfOneCore: 3, memoryBytes: 256 << 20, vmCPUCount: 6, bindMountSources: ["/Users/me/a"])
        }
        let project = Project(name: "project-a", root: "/Users/me/projects/project-a", confidence: .high, basis: "git repository")
        let breakdown = ProjectBreakdown(usages: [
            ProjectUsage(bucket: .project(project), groupRoots: [processes[0].identity], processes: processes.prefix(80).map(\.identity),
                         containers: containers, hostCPUPercent: 140, containerCPUPercent: 30, memoryBytes: 4 << 30,
                         containerMemoryBytes: 2 << 30, cpuWatts: 3.2),
            ProjectUsage(bucket: .dockerVM, groupRoots: [], processes: [], containers: [], hostCPUPercent: 20, containerCPUPercent: nil,
                         memoryBytes: 1 << 30, containerMemoryBytes: nil, cpuWatts: nil),
            ProjectUsage(bucket: .unattributed, groupRoots: [], processes: processes.suffix(400).map(\.identity), containers: [],
                         hostCPUPercent: 50, containerCPUPercent: nil, memoryBytes: 8 << 30, containerMemoryBytes: nil, cpuWatts: 1),
        ], containerAttributions: [containers[0].containerID: ContainerAttribution(containerID: containers[0].containerID, project: project,
                                                                                    evidence: Evidence(label: "bind mount", value: "a", source: "docker"))],
        notices: [])
        var tick = LiveTick(sequence: 42, snapshot: snapshot, groups: groups, hardware: hardware,
                            docker: DockerSnapshot(availability: .available, engineVersion: "27.0", apiVersion: "1.46", containers: containers, notices: []),
                            projects: breakdown, topByCPU: byCPU, topByMemory: byMemory, history: history.window(for: trended),
                            collectionSeconds: 0.056, historyFailure: "disk full")
        tick.events = [TimelineEvent(timestamp: base, kind: .containerStarted, title: "db-0 started", projectName: "project-a")]
        tick.explanations = [explanation]
        tick.alerts = [alert(), watchAlert]
        tick.runningCommandsByProject = [project.id: 2]
        tick.plannedInterval = 5
        tick.sampling = SamplingPolicy.Decision(interval: 5, reason: .incident)
        let points = (0..<150).map { HistoryPoint(timestamp: base.addingTimeInterval(TimeInterval($0) * 5), thermalState: .nominal,
                                                  hostBusyFraction: 0.3, swapUsedBytes: 0, memoryPressure: .normal,
                                                  cpuTemperatureCelsius: 55, systemWatts: 10, processWatts: 6) }
        let projectPoints = points.flatMap { point in
            (0..<8).map { HistoryProjectPoint(timestamp: point.timestamp, projectID: "p\($0)", name: "project-\($0)", cpuPercent: 12,
                                              memoryBytes: 1 << 28, watts: 0.4) }
        }
        tick.timeline = HistoryWindow(points: points, projects: projectPoints, events: Array(repeating: tick.events[0], count: 200))
        return tick
    }

    /// `LiveTick` isn't `Equatable` (its trend window isn't): compare what it holds.
    static func expectSame(_ a: LiveTick, _ b: LiveTick, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.sequence == b.sequence, sourceLocation: sourceLocation)
        #expect(a.snapshot == b.snapshot, sourceLocation: sourceLocation)
        #expect(a.groups == b.groups, sourceLocation: sourceLocation)
        #expect(a.hardware == b.hardware, sourceLocation: sourceLocation)
        #expect(a.docker == b.docker, sourceLocation: sourceLocation)
        #expect(a.projects == b.projects, sourceLocation: sourceLocation)
        #expect(a.topByCPU == b.topByCPU, sourceLocation: sourceLocation)
        #expect(a.topByMemory == b.topByMemory, sourceLocation: sourceLocation)
        #expect(a.history.timestamps == b.history.timestamps, sourceLocation: sourceLocation)
        #expect(a.history.hostBusy == b.history.hostBusy, sourceLocation: sourceLocation)
        #expect(a.history.cpuTemperature == b.history.cpuTemperature, sourceLocation: sourceLocation)
        #expect(a.history.cpu == b.history.cpu, sourceLocation: sourceLocation)
        #expect(a.history.memoryBytes == b.history.memoryBytes, sourceLocation: sourceLocation)
        #expect(a.collectionSeconds == b.collectionSeconds, sourceLocation: sourceLocation)
        #expect(a.historyFailure == b.historyFailure, sourceLocation: sourceLocation)
        #expect(a.events == b.events, sourceLocation: sourceLocation)
        #expect(a.explanations == b.explanations, sourceLocation: sourceLocation)
        #expect(a.alerts == b.alerts, sourceLocation: sourceLocation)
        #expect(a.runningCommandsByProject == b.runningCommandsByProject, sourceLocation: sourceLocation)
        #expect(a.plannedInterval == b.plannedInterval, sourceLocation: sourceLocation)
        #expect(a.sampling == b.sampling, sourceLocation: sourceLocation)
        #expect(a.timeline == b.timeline, sourceLocation: sourceLocation)
    }
}

/// A body no side knows.
private enum Unknown: Codable {
    case launchMissiles(target: String)
}

/// An envelope as another version would send it.
private func envelope(version: Int, body: some Codable) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(HelperEnvelope(protocolVersion: version, build: "other", body: body))
}

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    let data = try HelperCodec.encode(value, build: "100")
    let (back, build) = try HelperCodec.decode(T.self, from: data)
    #expect(build == "100")
    return back
}

private func failure(_ body: () throws -> Void) -> HelperFailure? {
    do {
        try body()
        return nil
    } catch {
        return error as? HelperFailure
    }
}

@Suite("Helper protocol")
struct HelperProtocolTests {
    static let controlRequests: [HelperControlRequest] = [
        .hello(appBuild: "100"), .configure(HelperFixtures.settings), .setViewer(attached: true, interval: 5),
        .setViewer(attached: false, interval: nil), .subscribe(.full), .subscribe(.summary), .refreshNow, .pause, .resume,
        .pauseUntilAppOpens, .status, .recentAlerts(since: nil), .recentAlerts(since: HelperFixtures.base),
        .historyWindow(since: HelperFixtures.base), .savedActions(since: .distantPast), .historySize,
        .recordActions([HelperFixtures.action]), .setRetention(days: 7), .deleteHistory, .shutdown,
    ]

    static let readRequests: [HelperReadRequest] = [.liveStatus, .recentAlerts(limit: 10), .explanations]

    @Test("Every control request and reply round-trips")
    func controlRoundTrip() throws {
        for request in Self.controlRequests {
            #expect(try roundTrip(request) == request)
        }
        let replies: [HelperControlReply] = [
            .hello(HelperHello(helperBuild: "100", status: HelperFixtures.status(.foreground(5)))),
            .restartRequired(helperBuild: "99"), .done, .status(HelperFixtures.status(.paused(.failed("ps went away")))),
            .status(HelperFixtures.status(.paused(.notConfigured))), .alerts([HelperFixtures.alert(), HelperFixtures.watchAlert]),
            .historyWindow(HelperFixtures.window), .historyWindow(.empty), .savedActions([HelperFixtures.action]),
            .historySize(123_456), .failure(.helloRequired), .failure(.history("disk full")),
        ]
        for reply in replies {
            #expect(try roundTrip(reply) == reply)
        }
    }

    @Test("Every read request and reply round-trips")
    func readRoundTrip() throws {
        for request in Self.readRequests {
            #expect(try roundTrip(request) == request)
        }
        let replies: [HelperReadReply] = [
            .liveStatus(HelperFixtures.status()), .recentAlerts([HelperFixtures.alert(3)]), .explanations([HelperFixtures.explanation]),
            .notRunning(HelperProtocol.notRunningMessage), .failure(.invalidArgument("limit")),
        ]
        for reply in replies {
            #expect(try roundTrip(reply) == reply)
        }
    }

    @Test("Pushes round-trip: a full tick and a summary")
    func eventRoundTrip() throws {
        let tick = HelperFixtures.tick(processes: 50)
        guard case .tick(let back) = try roundTrip(HelperEvent.tick(tick)) else {
            Issue.record("not a tick")
            return
        }
        HelperFixtures.expectSame(tick, back)

        let summary = HelperEvent.summary(status: HelperFixtures.status(), newAlerts: [HelperFixtures.alert()],
                                          explanations: [HelperFixtures.explanation])
        guard case .summary(let status, let alerts, let explanations) = try roundTrip(summary) else {
            Issue.record("not a summary")
            return
        }
        #expect(status == HelperFixtures.status())
        #expect(alerts == [HelperFixtures.alert()])
        #expect(explanations == [HelperFixtures.explanation])
    }

    @Test("Every failure round-trips and says something")
    func failureRoundTrip() throws {
        let failures: [HelperFailure] = [
            .tooLarge(bytes: 9 << 20), .malformed("x"), .versionMismatch(received: 2, expected: 1), .helloRequired,
            .invalidArgument("y"), .restartRequired(helperBuild: "9"), .history("z"), .disconnected("gone"), .timedOut,
            .unexpectedReply("done"), .busy,
        ]
        for failure in failures {
            #expect(try roundTrip(failure) == failure)
            #expect(!failure.description.isEmpty)
        }
        #expect(HelperFailure.versionMismatch(received: 2, expected: 1).description == HelperProtocol.mismatchMessage)
    }

    @Test("A message over 8 MB is refused before decoding, on both sides")
    func oversize() throws {
        var big = HelperCodec.magic
        big.append(Data(count: HelperCodec.maximumBytes + 1 - big.count))
        #expect(failure { _ = try HelperCodec.decode(HelperControlRequest.self, from: big) } == .tooLarge(bytes: HelperCodec.maximumBytes + 1))
        let huge = String(repeating: "x", count: HelperCodec.maximumBytes)
        guard case .tooLarge = failure({ _ = try HelperCodec.encode(HelperControlRequest.hello(appBuild: huge), build: "1") }) else {
            Issue.record("an oversize message was encoded")
            return
        }
        // Exactly at the cap is still parsed (and here is junk).
        var atCap = HelperCodec.magic
        atCap.append(Data(count: HelperCodec.maximumBytes - atCap.count))
        guard case .malformed = failure({ _ = try HelperCodec.decode(HelperControlRequest.self, from: atCap) }) else {
            Issue.record("8 MB of junk wasn't malformed")
            return
        }
    }

    @Test("Truncated, empty, JSON and XML property lists are malformed, never a crash")
    func malformed() throws {
        let data = try HelperCodec.encode(HelperControlRequest.configure(HelperFixtures.settings), build: "1")
        for cut in [0, 4, 8, 9, data.count / 2, data.count - 1] {
            guard case .malformed = failure({ _ = try HelperCodec.decode(HelperControlRequest.self, from: data.prefix(cut)) }) else {
                Issue.record("a message cut at \(cut) of \(data.count) bytes decoded")
                continue
            }
        }
        let json = try JSONEncoder().encode(HelperEnvelope(build: "1", body: HelperControlRequest.status))
        let xmlEncoder = PropertyListEncoder()
        xmlEncoder.outputFormat = .xml
        let xml = try xmlEncoder.encode(HelperEnvelope(build: "1", body: HelperControlRequest.status))
        for other in [json, xml, Data("bplist00".utf8), Data(repeating: 0xFF, count: 64)] {
            guard case .malformed = failure({ _ = try HelperCodec.decode(HelperControlRequest.self, from: other) }) else {
                Issue.record("\(other.count) bytes of a non-binary-plist decoded")
                continue
            }
        }
        // The right envelope with the wrong body type.
        let reply = try HelperCodec.encode(HelperControlReply.done, build: "1")
        guard case .malformed = failure({ _ = try HelperCodec.decode(HelperControlRequest.self, from: reply) }) else {
            Issue.record("a reply decoded as a request")
            return
        }
    }

    @Test("Another protocol version is refused before its body is read, with the mismatch message")
    func wrongVersion() throws {
        for version in [0, 2, -1, Int.max] {
            let data = try envelope(version: version, body: HelperControlRequest.status)
            #expect(failure { _ = try HelperCodec.decode(HelperControlRequest.self, from: data) }
                    == .versionMismatch(received: version, expected: HelperProtocol.protocolVersion))
            // Even a body this version can't read is a mismatch, not malformed.
            let unknown = try envelope(version: version, body: Unknown.launchMissiles(target: "everything"))
            #expect(failure { _ = try HelperCodec.decode(HelperReadRequest.self, from: unknown) }
                    == .versionMismatch(received: version, expected: HelperProtocol.protocolVersion))
        }
    }

    @Test("An unknown case is an error, never a crash")
    func unknownCase() throws {
        let data = try envelope(version: HelperProtocol.protocolVersion, body: Unknown.launchMissiles(target: "everything"))
        for decode in [
            { _ = try HelperCodec.decode(HelperControlRequest.self, from: data) },
            { _ = try HelperCodec.decode(HelperReadRequest.self, from: data) },
            { _ = try HelperCodec.decode(HelperEvent.self, from: data) },
        ] as [() throws -> Void] {
            guard case .malformed = failure(decode) else {
                Issue.record("an unknown case decoded")
                continue
            }
        }
        let subscription = try envelope(version: HelperProtocol.protocolVersion, body: ["subscribe": ["_0": "everything"]])
        guard case .malformed = failure({ _ = try HelperCodec.decode(HelperControlRequest.self, from: subscription) }) else {
            Issue.record("an unknown subscription decoded")
            return
        }
    }

    @Test("No control request decodes as a read, and no read as a control request")
    func channelsDontOverlap() throws {
        for request in Self.controlRequests {
            let data = try HelperCodec.encode(request, build: "1")
            guard case .malformed = failure({ _ = try HelperCodec.decode(HelperReadRequest.self, from: data) }) else {
                Issue.record("\(request) decoded as a read")
                continue
            }
        }
        for request in Self.readRequests {
            let data = try HelperCodec.encode(request, build: "1")
            guard case .malformed = failure({ _ = try HelperCodec.decode(HelperControlRequest.self, from: data) }) else {
                Issue.record("\(request) decoded as a control request")
                continue
            }
        }
    }

    @Test("A decoded alert rule is clamped as a built one is")
    func alertRuleClamped() throws {
        struct Raw: Encodable {
            let kind = "memory", isEnabled = true, on = 0.5, off = 0.9, sustain = -5.0, clear = 10.0, cooldown = -1.0
        }
        let rule = try PropertyListDecoder().decode(AlertRule.self, from: PropertyListEncoder().encode(Raw()))
        #expect(rule.off == 0.5)
        #expect(rule.sustain == 0)
        #expect(rule.cooldown == 0)
        #expect(try roundTrip(AlertRule.sustainedCPU) == AlertRule.sustainedCPU)
    }

    @Test("A 1,000-process tick encodes and decodes in under 80 ms")
    func tickCost() throws {
        let tick = HelperFixtures.tick(processes: 1_000)
        let data = try HelperCodec.encode(HelperEvent.tick(tick), build: "1")
        #expect(data.count < HelperCodec.maximumBytes / 4)
        guard case .tick(let back) = try HelperCodec.decode(HelperEvent.self, from: data).body else {
            Issue.record("not a tick")
            return
        }
        HelperFixtures.expectSame(tick, back)
        // This thread's CPU time, not wall time: the budget is CPU, and under the parallel full
        // suite the wall clock also counts time spent waiting for a core. Nothing in the loop
        // awaits, so it stays on one thread.
        var best = Duration.seconds(60)
        for _ in 0..<7 {
            let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let encoded = try HelperCodec.encode(HelperEvent.tick(tick), build: "1")
            _ = try HelperCodec.decode(HelperEvent.self, from: encoded)
            best = min(best, .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started)))
        }
        // Owner ruling on 4j: binary-plist Codable stays, and the bound is 80 ms in release and
        // debug alike (Foundation's coders are prebuilt, so debug is barely slower). Measured in
        // release: about 24 ms to encode and 31 ms to decode. It's paid only for `.full` pushes,
        // while the Live view is visible; a closed panel gets small summaries.
        let limit = Duration.milliseconds(80)
        print("HelperProtocolTests.tickCost: \(data.count) bytes, best of 7 \(best) CPU (limit \(limit))")
        #expect(best < limit)
    }

    @Test("Background/ and the helper have no action path and no network code (ADR-0008 §3)")
    func noActionsOrNetwork() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources").standardized
        let folders = ["HeatLensCore/Background", "heatlens-helper"].map { sources.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        #expect(folders.count >= 1)
        let forbidden = ["kill(", "requestStop", "forceQuit", "ContainerStopper", "StopLedger", "\"POST ", "URLSession",
                         "import Network", "UNUserNotificationCenter", "BatchStop", "ProcessTerminator"]
        var checked = 0
        for folder in folders {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                checked += 1
                for word in forbidden {
                    #expect(!source.contains(word), "\(file.lastPathComponent) contains \(word)")
                }
            }
        }
        #expect(checked >= 4)
    }

    @Test("The requirement strings compile, and this ad-hoc test runner satisfies none of them")
    func requirements() throws {
        #expect(HelperProtocol.appRequirement
                == "anchor apple generic and identifier \"dev.heatlens.HeatLens\" and certificate leaf[subject.OU] = \"9PXJ82UU32\"")
        #expect(HelperProtocol.cliRequirement.contains("identifier \"dev.heatlens.heatlens\" "))
        #expect(HelperProtocol.helperRequirement.contains("identifier \"dev.heatlens.heatlens-helper\" "))
        var me: SecCode?
        #expect(SecCodeCopySelf([], &me) == errSecSuccess)
        let code = try #require(me)
        for text in [HelperProtocol.appRequirement, HelperProtocol.cliRequirement, HelperProtocol.helperRequirement] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, "\(text)")
            let parsed = try #require(requirement)
            #expect(SecCodeCheckValidity(code, [], parsed) != errSecSuccess, "the test runner passed \(text)")
        }
    }
}
