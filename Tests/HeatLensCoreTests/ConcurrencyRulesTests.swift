import Foundation
import Testing
@testable import HeatLensCore

private let home = SyntheticSnapshots.home
private let t0 = SyntheticSnapshots.startedAt
private let fda = home + "/Developer/FDA"
private let shop = home + "/Developer/shop"

/// A process forked `startedAt` seconds after the synthetic start (old ones: `startedAt` negative).
private func process(_ pid: Int32, parent: Int32 = 1, argv: [String], name: String? = nil, cwd: String? = fda,
                     startedAt: TimeInterval = -3_600, exited: Bool = false) -> ProcessSample {
    // SyntheticSnapshots dates a process `ageHours` before t0 + interval.
    let ageHours = (SyntheticSnapshots.interval - startedAt) / 3_600
    return SyntheticSnapshots.process(pid: pid, parentPID: parent, ageHours: ageHours, name: name ?? (argv[0] as NSString).lastPathComponent,
                                      executablePath: argv[0], arguments: argv, currentDirectory: cwd, cpu: 50,
                                      detailAccess: exited ? .processExited : .available)
}

private func container(_ id: Character, _ name: String, project: String = fda) -> ContainerSample {
    ContainerSample(containerID: String(repeating: id, count: 64), name: name, image: "postgres:17", state: "running", status: "Up",
                    createdAt: t0, labels: ["com.docker.compose.project.working_dir": project],
                    cpuPercentOfOneCore: 1, memoryBytes: 1 << 20, vmCPUCount: 6)
}

/// A live tick covering `seconds`…`seconds + 5` past t0, with projects resolved against a fake
/// filesystem where ~/Developer/FDA and ~/Developer/shop are repositories.
private func tick(_ processes: [ProcessSample], containers: [ContainerSample]? = nil, seconds: TimeInterval = 0) -> LiveTick {
    let base = SyntheticSnapshots.snapshot(processes)
    let snapshot = ScanSnapshot(startedAt: base.startedAt.addingTimeInterval(seconds), interval: base.interval, system: base.system,
                                processes: base.processes, notices: [])
    let groups = ProvenanceResolver.resolve(snapshot)
    let docker = containers.map { DockerSnapshot(availability: .available, engineVersion: "28.5.1", apiVersion: "1.51", containers: $0, notices: []) }
        ?? .unavailable(.disabled)
    let locator = ProjectRootLocator(home: home, exists: { [fda + "/.git", shop + "/.git"].contains($0) })
    let projects = ProjectAttributor.breakdown(snapshot: snapshot, groups: groups, docker: docker, mappings: [], locator: locator, home: home)
    return LiveTick(sequence: 1, snapshot: snapshot, groups: groups, hardware: DisabledHardwareProvider().sample(), docker: docker,
                    projects: projects, topByCPU: [], topByMemory: [], history: LiveHistory(capacity: 2).window(for: []),
                    collectionSeconds: 0)
}

private let vitest = ["node", fda + "/node_modules/.bin/vitest", "run"]
/// The native Claude Code binary is named after its version; argv[0] still says claude.
private let claude = SyntheticSnapshots.process(pid: 100, ageHours: 1, name: "2.1.4", executablePath: home + "/.local/share/claude/versions/2.1.4",
                                                arguments: ["claude"], currentDirectory: fda, cpu: 3)
private let codex = process(200, argv: ["codex"])

/// Each agent runs `npm run test:integration`, which runs vitest through a shell.
private func testRun(agent: Int32, at seconds: TimeInterval) -> [ProcessSample] {
    [process(agent + 1, parent: agent, argv: ["npm", "run", "test:integration"], startedAt: seconds),
     process(agent + 2, parent: agent + 1, argv: ["/bin/sh", "-c", "vitest run --config vitest.integration.ts"], startedAt: seconds),
     process(agent + 3, parent: agent + 2, argv: vitest, startedAt: seconds)]
}

@Suite("Concurrency explanations")
struct ConcurrencyRulesTests {
    @Test("FDA: two agents start integration tests within 10 s while 3 containers start — one explanation, high confidence")
    func fdaScenario() throws {
        var rules = ConcurrencyRules()
        #expect(rules.explanations(for: tick([claude, codex], containers: [])).isEmpty)
        let first = [claude, codex] + testRun(agent: 100, at: 6)
        #expect(rules.explanations(for: tick(first, containers: [], seconds: 5)).isEmpty)
        let both = first + testRun(agent: 200, at: 12)
        let containers = [container("a", "fda-db-1"), container("b", "fda-redis-1"), container("c", "fda-api-1")]
        let found = rules.explanations(for: tick(both, containers: containers, seconds: 10))

        let explanation = try #require(found.first)
        #expect(found.count == 1)
        #expect(explanation.title == "2 test runs began within 10 s across 2 agent trees (claude, codex) in FDA, plus 3 containers")
        #expect(explanation.confidence == .high)
        #expect(explanation.agentTrees.map(\.name) == ["claude", "codex"])
        #expect(explanation.agentTrees.map(\.root) == [claude.identity, codex.identity])
        #expect(explanation.projects == ["FDA"])
        #expect(explanation.affected.map(\.pid) == [102, 202])
        #expect(Set(explanation.containerIDs) == Set(containers.map(\.containerID)))
        #expect(explanation.startedAt == t0.addingTimeInterval(6))
        #expect(explanation.recommendation == "These test runs compete for the same CPU cores and the Docker VM. Run them one at a time, or have the agents take turns.")
        // An observation for each command and each container, oldest first.
        #expect(explanation.observations.count == 5)
        #expect(explanation.observations.map(\.timestamp) == explanation.observations.map(\.timestamp).sorted())
        #expect(explanation.observations[0].evidence.label == "vitest started")
        #expect(explanation.observations[0].evidence.value == "PID 102, in FDA, under claude (PID 100)")
        #expect(explanation.observations.filter { $0.evidence.label.hasPrefix("Container fda-") }.count == 3)
        #expect(!explanation.uncertainty.isEmpty && explanation.uncertainty.count <= 2)
        #expect(explanation.uncertainty[0].contains("not how much heat or power"))
        // Inference, never a path or argv.
        for text in [explanation.title, explanation.recommendation] + explanation.observations.map(\.evidence.value) {
            #expect(!text.contains("/"))
            #expect(!text.contains("--config"))
        }
        let event = explanation.timelineEvent(at: t0.addingTimeInterval(15))
        #expect(event.kind == .concurrencyExplained && event.isInference && event.projectName == "FDA")
        #expect(rules.current.map(\.id) == [explanation.id])
    }

    @Test("the same burst on the next 5 ticks is reported once")
    func reportedOnce() {
        var rules = ConcurrencyRules()
        _ = rules.explanations(for: tick([claude, codex]))
        let both = [claude, codex] + testRun(agent: 100, at: 6) + testRun(agent: 200, at: 8)
        #expect(rules.explanations(for: tick(both, seconds: 5)).count == 1)
        for step in 2...6 {
            #expect(rules.explanations(for: tick(both, seconds: TimeInterval(step * 5))).isEmpty)
        }
        #expect(rules.current.count == 1)
    }

    @Test("containers seen a tick later join the burst instead of being reported again")
    func grows() throws {
        var rules = ConcurrencyRules()
        _ = rules.explanations(for: tick([claude, codex], containers: []))
        let both = [claude, codex] + testRun(agent: 100, at: 6) + testRun(agent: 200, at: 8)
        let found = rules.explanations(for: tick(both, containers: [], seconds: 5))
        #expect(found.first?.title == "2 test runs began within 10 s across 2 agent trees (claude, codex) in FDA")
        let containers = [container("a", "fda-db-1"), container("b", "fda-api-1")]
        #expect(rules.explanations(for: tick(both, containers: containers, seconds: 10)).isEmpty)
        let grown = try #require(rules.current.first)
        #expect(grown.id == found.first?.id)
        #expect(grown.title.hasSuffix(", plus 2 containers"))
        #expect(grown.containerIDs.count == 2)
    }

    @Test("a single agent running one test explains nothing")
    func singleAgent() {
        var rules = ConcurrencyRules()
        _ = rules.explanations(for: tick([claude]))
        #expect(rules.explanations(for: tick([claude] + testRun(agent: 100, at: 6), seconds: 5)).isEmpty)
        #expect(rules.current.isEmpty)
    }

    @Test("two commands 30 s apart are not a burst")
    func farApart() {
        var rules = ConcurrencyRules()
        _ = rules.explanations(for: tick([claude, codex]))
        let one = [claude, codex] + testRun(agent: 100, at: 6)
        #expect(rules.explanations(for: tick(one, seconds: 5)).isEmpty)
        #expect(rules.explanations(for: tick(one + testRun(agent: 200, at: 36), seconds: 35)).isEmpty)
        #expect(rules.current.isEmpty)
    }

    @Test("two projects with no agents: one explanation across 2 projects")
    func twoProjects() throws {
        var rules = ConcurrencyRules()
        let shells = [process(40, argv: ["Terminal"]), process(50, parent: 40, argv: ["-zsh"]), process(60, parent: 40, argv: ["-zsh"], cwd: shop)]
        _ = rules.explanations(for: tick(shells))
        let commands = shells + [process(51, parent: 50, argv: ["npm ci"], name: "sleep", startedAt: 6),
                                 process(61, parent: 60, argv: ["vitest"], name: "sleep", cwd: shop, startedAt: 7)]
        let found = rules.explanations(for: tick(commands, seconds: 5))
        let explanation = try #require(found.first)
        #expect(found.count == 1)
        #expect(explanation.title == "2 expensive commands began within 10 s across 2 projects (FDA, shop)")
        #expect(explanation.agentTrees == [.noAgent])
        #expect(explanation.confidence == .high)
        #expect(explanation.recommendation.hasSuffix("If the Mac runs hot, let one finish before starting the next."))
    }

    @Test("a command with no project lowers confidence to medium")
    func unplaced() throws {
        var rules = ConcurrencyRules()
        _ = rules.explanations(for: tick([claude, codex]))
        let both = [claude, codex] + testRun(agent: 100, at: 6)
            + [process(300, argv: ["npm", "ci"], cwd: nil, startedAt: 7)]
        let explanation = try #require(rules.explanations(for: tick(both, seconds: 5)).first)
        #expect(explanation.confidence == .medium)
        #expect(explanation.uncertainty.contains("1 of the 2 commands couldn't be tied to a project folder."))
    }

    @Test("containers alone across 2 projects: low confidence")
    func containersOnly() throws {
        var rules = ConcurrencyRules()
        _ = rules.explanations(for: tick([], containers: []))
        let containers = [container("a", "fda-db-1"), container("b", "shop-db-1", project: shop)]
        let explanation = try #require(rules.explanations(for: tick([], containers: containers, seconds: 5)).first)
        #expect(explanation.confidence == .low)
        #expect(explanation.title == "2 containers started within 10 s across 2 projects (FDA, shop)")
        #expect(explanation.affected.isEmpty)
    }

    @Test("the first tick only sets the baseline")
    func baseline() {
        var rules = ConcurrencyRules()
        let both = [claude, codex] + testRun(agent: 100, at: 3) + testRun(agent: 200, at: 4)
        #expect(rules.explanations(for: tick(both, containers: [container("a", "fda-db-1"), container("b", "fda-api-1")], seconds: 0)).isEmpty)
        #expect(rules.explanations(for: tick(both, containers: [container("a", "fda-db-1"), container("b", "fda-api-1")], seconds: 5)).isEmpty)
        #expect(rules.current.isEmpty)
    }

    @Test("an explanation ends when its burst stops running and is dropped 10 minutes later")
    func expires() {
        var rules = ConcurrencyRules()
        _ = rules.explanations(for: tick([claude, codex]))
        let both = [claude, codex] + testRun(agent: 100, at: 6) + testRun(agent: 200, at: 8)
        _ = rules.explanations(for: tick(both, seconds: 5))
        _ = rules.explanations(for: tick([claude, codex], seconds: 10))
        #expect(rules.current.first?.endedAt == t0.addingTimeInterval(15))
        _ = rules.explanations(for: tick([claude, codex], seconds: 600))
        #expect(rules.current.count == 1)
        _ = rules.explanations(for: tick([claude, codex], seconds: 620))
        #expect(rules.current.isEmpty)
    }

    @Test("history stores and reads back the new event kind")
    func history() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heatlens-history-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.sqlite")
        let store = try HistoryStore(url: url, now: { t0.addingTimeInterval(60) })
        let point = HistoryPoint(timestamp: t0, thermalState: .nominal, hostBusyFraction: 0.5, swapUsedBytes: 0, memoryPressure: .normal,
                                 cpuTemperatureCelsius: nil, systemWatts: nil, processWatts: nil)
        let event = TimelineEvent(timestamp: t0, kind: .concurrencyExplained, title: "2 test runs began within 10 s", projectName: "FDA", isInference: true)
        try await store.record(point, projects: [], events: [event])
        let window = try await store.window(since: t0.addingTimeInterval(-60))
        #expect(window.events == [event])
        await store.close()
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("1,000 processes: under 10 ms a tick after the first")
    func cost() {
        var many: [ProcessSample] = []
        for i in 0..<1_000 {
            let pid = Int32(1_000 + i)
            let parent: Int32 = i % 10 == 0 ? 1 : pid - 1
            let argv: [String] = i % 50 == 0 ? vitest : ["node", "worker-\(i).js"]
            many.append(process(pid, parent: parent, argv: argv, cwd: i % 2 == 0 ? fda : shop))
        }
        var rules = ConcurrencyRules()
        let steady = tick(many)
        _ = rules.explanations(for: steady)
        let clock = ContinuousClock()
        let runs = 20
        let elapsed = clock.measure {
            for _ in 0..<runs { _ = rules.explanations(for: steady) }
        }
        let (seconds, attoseconds) = elapsed.components
        let perTick: Double = (Double(seconds) * 1_000 + Double(attoseconds) / 1e15) / Double(runs)
        #expect(perTick < 10, "\(perTick) ms per tick")
    }
}
