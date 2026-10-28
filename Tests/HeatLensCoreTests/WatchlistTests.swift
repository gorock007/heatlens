import Foundation
import Testing
@testable import HeatLensCore

private let home = SyntheticSnapshots.home
private let t0 = SyntheticSnapshots.startedAt
private let step = SyntheticSnapshots.interval
private let fda = home + "/Developer/FDA"
private let shop = home + "/Developer/shop"
private let gib = Double(1 << 30)

/// What one project reads on a tick.
private struct Load {
    var cpu: Double = 10
    var memoryGB: Double = 0.5
    var commands = 0
}

private let node = SyntheticSnapshots.process(pid: 300, name: "node", executablePath: "/usr/local/bin/node",
                                              arguments: ["node", fda + "/scripts/build.js"], currentDirectory: fda, cpu: 180)
private let swiftBuild = SyntheticSnapshots.process(pid: 301, name: "swift-build", executablePath: "/usr/bin/swift-build",
                                                    arguments: ["swift-build"], currentDirectory: fda, cpu: 60)
private let indexer = SyntheticSnapshots.process(pid: 302, name: "/usr/bin/sourcekit-lsp", currentDirectory: fda, cpu: 20)

private func project(_ root: String) -> Project {
    Project(name: (root as NSString).lastPathComponent, root: root, confidence: .high, basis: "git repository")
}

private func usage(_ root: String, _ load: Load, processes: [ProcessIdentity] = []) -> ProjectUsage {
    ProjectUsage(bucket: .project(project(root)), groupRoots: processes, processes: processes, containers: [],
                 hostCPUPercent: load.cpu, containerCPUPercent: nil, memoryBytes: UInt64(load.memoryGB * gib),
                 containerMemoryBytes: nil, cpuWatts: nil)
}

/// The `n`th tick of a back-to-back session; only the projects in `loads` are on it. FDA's row
/// holds node, swift-build and sourcekit-lsp.
private func tick(_ n: Int, _ loads: [String: Load], start: Date? = nil) -> LiveTick {
    let processes = [node, swiftBuild, indexer]
    let base = SyntheticSnapshots.snapshot(processes)
    let snapshot = ScanSnapshot(startedAt: start ?? t0.addingTimeInterval(Double(n) * step), interval: step, system: base.system,
                                processes: base.processes, notices: [])
    let usages = loads.sorted { $0.key < $1.key }.map { root, load in
        usage(root, load, processes: root == fda ? processes.map(\.identity) : [])
    }
    var tick = LiveTick(sequence: n + 1, snapshot: snapshot, groups: [], hardware: DisabledHardwareProvider().sample(), docker: .unavailable(.disabled),
                        projects: ProjectBreakdown(usages: usages, containerAttributions: [:], notices: []), topByCPU: [], topByMemory: [],
                        history: LiveHistory(capacity: 2).window(for: []), collectionSeconds: 0)
    tick.runningCommandsByProject = Dictionary(uniqueKeysWithValues: loads.filter { $0.value.commands > 0 }.map { (project($0.key).id, $0.value.commands) })
    return tick
}

private func ticks(_ seconds: TimeInterval) -> Int { Int((seconds / step).rounded()) }

private func watch(_ root: String = fda, cpu: Double? = nil, memory: Double? = nil, commands: Double? = nil) -> ProjectWatch {
    ProjectWatch(projectID: project(root).id, name: (root as NSString).lastPathComponent, cpu: cpu, memory: memory, commands: commands)!
}

private func evaluator(_ watches: [ProjectWatch], enabled: Bool = true) -> AlertEvaluator {
    AlertEvaluator(configuration: AlertConfiguration(isEnabled: enabled, rules: [], watches: watches))
}

/// Per metric: a watch at its lowest preset, and loads below `off`, between `off` and `on`, and at or above `on`.
struct WatchCase: CustomTestStringConvertible, Sendable {
    let metric: ProjectWatch.Metric
    let on: Double
    let low: Double
    let middle: Double
    let high: Double
    var testDescription: String { metric.rawValue }
    var limits: AlertRuleState.Limits { ProjectWatch.limits(metric, on: on)! }

    fileprivate var watch: ProjectWatch {
        switch metric {
        case .cpu: HeatLensCoreTests.watch(cpu: on)
        case .memory: HeatLensCoreTests.watch(memory: on)
        case .commands: HeatLensCoreTests.watch(commands: on)
        }
    }

    fileprivate func load(_ value: Double) -> Load {
        switch metric {
        case .cpu: Load(cpu: value)
        case .memory: Load(memoryGB: value)
        case .commands: Load(commands: Int(value))
        }
    }
}

let watchCases: [WatchCase] = [
    WatchCase(metric: .cpu, on: 200, low: 100, middle: 170, high: 250),
    WatchCase(metric: .memory, on: 4, low: 2, middle: 3.5, high: 5),
    // Commands clear below `on`: there is no in-between.
    WatchCase(metric: .commands, on: 2, low: 1, middle: 1, high: 3),
]

@Suite("Project watches")
struct WatchlistTests {
    @Test("each metric fires once, exactly `sustain` after reaching `on`", arguments: watchCases)
    func firesAfterSustain(_ c: WatchCase) throws {
        var evaluator = evaluator([c.watch])
        let fired = (0..<ticks(c.limits.sustain) + 4).flatMap { n in evaluator.alerts(for: tick(n, [fda: c.load(c.high)])).map { (n, $0) } }
        let (n, alert) = try #require(fired.first)
        #expect(fired.count == 1)
        #expect(n == ticks(c.limits.sustain) - 1)
        #expect(alert.firedAt == t0.addingTimeInterval(c.limits.sustain))
        #expect(alert.rule == nil)
        #expect(alert.watch == Alert.Watch(projectName: "FDA", metric: c.metric, projectHash: ProjectWatch.hash(of: project(fda).id)))
        #expect(alert.projects == ["FDA"])
        #expect(alert.timelineEvent.projectName == "FDA")
    }

    @Test("hysteresis and cooldown", arguments: watchCases)
    func hysteresisAndCooldown(_ c: WatchCase) {
        let limits = c.limits
        var evaluator = evaluator([c.watch])
        var n = 0
        func run(_ count: Int, _ value: Double) -> [Alert] {
            defer { n += count }
            return (n..<(n + count)).flatMap { evaluator.alerts(for: tick($0, [fda: c.load(value)])) }
        }
        #expect(run(ticks(limits.sustain) + 4, c.low).isEmpty)
        // A dip below `on` resets the hold.
        #expect(run(ticks(limits.sustain) - 1, c.high).isEmpty)
        #expect(run(1, c.low).isEmpty)
        #expect(run(ticks(limits.sustain) - 1, c.high).isEmpty)
        #expect(run(1, c.high).count == 1)
        // Staying high, or settling between off and on, never repeats, even after the cooldown.
        #expect(run(ticks(limits.cooldown) + 10, c.high).isEmpty)
        if c.metric != .commands {
            #expect(run(ticks(limits.clear) + 4, c.middle).isEmpty)
            #expect(run(ticks(limits.sustain) + 4, c.high).isEmpty)
        }

        // A fresh firing; cleared below off; high again inside the cooldown → nothing until it passes.
        evaluator = AlertEvaluator(configuration: evaluator.configuration)
        n = 0
        let refired = run(ticks(limits.sustain), c.high)
        #expect(refired.count == 1)
        let refireTick = n
        #expect(run(max(1, ticks(limits.clear)), c.low).isEmpty)
        #expect(run(ticks(limits.cooldown) - 1 - (n - refireTick), c.high).isEmpty)
        let second = run(1, c.high)
        #expect(second.count == 1)
        #expect(second.first.map { $0.firedAt.timeIntervalSince(refired[0].firedAt) } == limits.cooldown)
    }

    @Test("a project missing from a tick resets its hold and never fires; so does a gap")
    func absentProjectResets() {
        let hold = ticks(2 * 60)
        var evaluator = evaluator([watch(cpu: 100)])
        let hot = [fda: Load(cpu: 150)]
        #expect((0..<(hold - 1)).flatMap { evaluator.alerts(for: tick($0, hot)) }.isEmpty)
        #expect(evaluator.alerts(for: tick(hold - 1, [shop: Load(cpu: 500)])).isEmpty)
        #expect(!evaluator.isActive)
        #expect((hold..<(2 * hold - 1)).flatMap { evaluator.alerts(for: tick($0, hot)) }.isEmpty)
        #expect(evaluator.alerts(for: tick(2 * hold - 1, hot)).count == 1)

        // Paused for a minute in the middle of a hold: it starts over.
        var paused = AlertEvaluator(configuration: evaluator.configuration)
        #expect((0..<(hold - 1)).flatMap { paused.alerts(for: tick($0, hot)) }.isEmpty)
        let resumed = hold - 1 + ticks(60)
        #expect((resumed..<(resumed + hold - 1)).flatMap { paused.alerts(for: tick($0, hot)) }.isEmpty)
        #expect(paused.alerts(for: tick(resumed + hold - 1, hot)).count == 1)
    }

    @Test("two projects stay independent: their own holds, cooldowns and alerts")
    func independentProjects() {
        let hold = ticks(2 * 60)
        var evaluator = evaluator([watch(fda, cpu: 200), watch(shop, cpu: 200)])
        // FDA hot from the start; shop hot from tick 10.
        var fired: [(Int, Alert)] = []
        for n in 0..<(10 + hold + 5) {
            let loads = [fda: Load(cpu: 300), shop: Load(cpu: n >= 10 ? 300 : 50)]
            fired += evaluator.alerts(for: tick(n, loads)).map { (n, $0) }
        }
        #expect(fired.map(\.0) == [hold - 1, 10 + hold - 1])
        #expect(fired.map(\.1.title) == ["FDA above 200% CPU for 2 minutes", "shop above 200% CPU for 2 minutes"])
        #expect(Set(fired.map(\.1.id)).count == 2)
        #expect(fired[0].1.watch?.projectHash != fired[1].1.watch?.projectHash)
    }

    @Test("several metrics on one project are separate rules")
    func severalMetrics() {
        var evaluator = evaluator([watch(cpu: 100, memory: 2, commands: 2)])
        let fired = (0..<ticks(2 * 60)).flatMap { evaluator.alerts(for: tick($0, [fda: Load(cpu: 150, memoryGB: 3, commands: 2)])) }
        #expect(fired.compactMap(\.watch?.metric) == [.commands, .cpu, .memory])
    }

    @Test("master switch off → nothing, and not active")
    func masterOff() {
        var evaluator = evaluator([watch(cpu: 100, memory: 2, commands: 2)], enabled: false)
        let everything = [fda: Load(cpu: 900, memoryGB: 20, commands: 5)]
        #expect((0..<ticks(20 * 60)).flatMap { evaluator.alerts(for: tick($0, everything)) }.isEmpty)
        #expect(!evaluator.isActive)
        #expect(AlertConfiguration().watches.isEmpty)
    }

    @Test("isActive: a watch holding or firing on this tick; settling between off and on after a firing isn't")
    func isActive() {
        var evaluator = evaluator([watch(cpu: 200)])
        _ = evaluator.alerts(for: tick(0, [fda: Load(cpu: 100)]))
        #expect(!evaluator.isActive)
        _ = evaluator.alerts(for: tick(1, [fda: Load(cpu: 250)]))
        #expect(evaluator.isActive)
        let hold = ticks(2 * 60)
        let fired = (2..<(hold + 1)).flatMap { evaluator.alerts(for: tick($0, [fda: Load(cpu: 250)])) }
        #expect(fired.count == 1)
        #expect(evaluator.isActive)
        _ = evaluator.alerts(for: tick(hold + 1, [fda: Load(cpu: 170)]))
        #expect(!evaluator.isActive)
        // Removing the watch forgets it.
        evaluator.configuration.watches = []
        #expect(!evaluator.isActive)
    }

    @Test("presets only: any other threshold, or a relative folder, is not a watch")
    func presetsOnly() throws {
        #expect(ProjectWatch(projectID: project(fda).id, name: "FDA", cpu: 150) == nil)
        #expect(ProjectWatch(projectID: project(fda).id, name: "FDA", memory: 3) == nil)
        #expect(ProjectWatch(projectID: project(fda).id, name: "FDA", commands: 4) == nil)
        #expect(ProjectWatch(projectID: "Developer/FDA", name: "FDA", cpu: 100) == nil)
        #expect(ProjectWatch(projectID: "", name: "FDA") == nil)
        for metric in ProjectWatch.Metric.allCases {
            for choice in ProjectWatch.choices(metric) {
                let limits = try #require(ProjectWatch.limits(metric, on: choice.on))
                #expect(limits.off == choice.off && limits.off <= limits.on)
                #expect(limits.cooldown == 15 * 60)
                #expect(limits.sustain == (metric == .commands ? 30 : 120))
                #expect(limits.clear == (metric == .commands ? 0 : 60))
            }
        }
        let named = try #require(ProjectWatch(projectID: fda, name: "  ", cpu: 400))
        #expect(named.projectID == project(fda).id)
        #expect(named.name == "fda")
        #expect(named.isWatching)
        #expect(ProjectWatch(projectID: fda, name: String(repeating: "x", count: 200))?.name.count == ProjectWatch.nameLimit)
        #expect(ProjectWatch(projectID: fda, name: "FDA")?.isWatching == false)
    }

    @Test("storage: round trip; malformed entries are dropped with a notice")
    func storage() throws {
        let watches = [watch(cpu: 200, memory: 4), watch(shop, commands: 3)]
        let data = ProjectWatch.encoded(watches)
        #expect(ProjectWatch.parse(data).watches == watches)
        #expect(ProjectWatch.parse(data).notice == nil)
        #expect(ProjectWatch.parse(Data()).watches.isEmpty && ProjectWatch.parse(Data()).notice == nil)

        let garbage = ProjectWatch.parse(Data("not json".utf8))
        #expect(garbage.watches.isEmpty)
        #expect(garbage.notice == "The watched projects setting couldn't be read, so no project is watched.")
        #expect(ProjectWatch.parse(Data(#"{"projectID":"/x"}"#.utf8)).notice != nil)

        let id = project(fda).id
        let mixed = """
        [{"projectID":"\(id)","name":"FDA","cpu":200},
         {"projectID":"\(id)","name":"FDA again","cpu":400},
         {"projectID":"\(project(shop).id)","name":"shop","cpu":150},
         {"name":"no folder","memory":4},
         {"projectID":"relative/path","name":"x","commands":2},
         {"projectID":"/users/someone/developer/api","name":"api","memory":"lots"},
         42]
        """
        let parsed = ProjectWatch.parse(Data(mixed.utf8))
        #expect(parsed.watches.map(\.name) == ["FDA"])
        #expect(parsed.watches.first?.cpu == 200)
        #expect(parsed.notice == "5 watched projects couldn't be read and were dropped.")

        let one = ProjectWatch.parse(Data(#"[{"projectID":"/a","cpu":100},{"projectID":"/b","cpu":1}]"#.utf8))
        #expect(one.watches.map(\.projectID) == ["/a"])
        #expect(one.notice == "1 watched project couldn't be read and was dropped.")

        let many = (0..<(ProjectWatch.maxWatches + 3)).map { ProjectWatch(projectID: "/p/\($0)", name: "p\($0)", cpu: 100)! }
        let capped = ProjectWatch.parse(ProjectWatch.encoded(many))
        #expect(capped.watches.count == ProjectWatch.maxWatches)
        #expect(capped.notice == "Only the first 50 watched projects are kept.")
    }

    @Test("wording: titles, observations and suggestion name the project and its processes, never a path")
    func wording() throws {
        var evaluator = evaluator([watch(cpu: 200, memory: 4, commands: 2)])
        let fired = (0..<ticks(2 * 60)).flatMap { evaluator.alerts(for: tick($0, [fda: Load(cpu: 260, memoryGB: 5, commands: 3)])) }
        let byMetric = Dictionary(uniqueKeysWithValues: fired.compactMap { alert in alert.watch.map { ($0.metric, alert) } })

        let cpu = try #require(byMetric[.cpu])
        #expect(cpu.title == "FDA above 200% CPU for 2 minutes")
        #expect(cpu.observations.map(\.label) == ["CPU now", "Threshold", "Held", "Busiest processes"])
        #expect(cpu.observations.map(\.value) == ["260% of one core", "200%; clears below 150%", "2 minutes", "node, swift-build, sourcekit-lsp"])
        #expect(cpu.observations[1].source == "your watch on FDA")
        #expect(cpu.suggestion == "Its busiest processes are node, swift-build, sourcekit-lsp; see Projects.")

        let memory = try #require(byMetric[.memory])
        #expect(memory.title == "FDA above 4 GB memory for 2 minutes")
        #expect(memory.observations[0].value == "5 GB")
        #expect(memory.observations[1].value == "4 GB; clears below 3 GB")

        let commands = try #require(byMetric[.commands])
        #expect(commands.title == "FDA running 2 or more expensive commands at once for 30 seconds")
        #expect(commands.observations[0].value == "3 running")
        #expect(commands.observations[1].value == "2 or more; clears at 1 or fewer")

        #expect(ProjectWatch.describe(1.5, for: .memory) == "1.5 GB")
        for alert in fired {
            let text = ([alert.id, alert.title, alert.suggestion] + alert.projects + alert.observations.flatMap { [$0.label, $0.value, $0.source] })
                .joined(separator: " ")
            #expect(!text.contains("/"), "\(text)")
            #expect(!text.lowercased().contains("stop") && !text.lowercased().contains("kill") && !text.lowercased().contains("quit"))
        }
    }

    @Test("ConcurrencyRules counts outermost expensive commands running per project")
    func runningCommandsByProject() {
        let locator = ProjectRootLocator(home: home, exists: { [fda + "/.git", shop + "/.git"].contains($0) })
        func command(_ pid: Int32, parent: Int32 = 1, _ argv: [String], in directory: String) -> ProcessSample {
            SyntheticSnapshots.process(pid: pid, parentPID: parent, name: (argv[0] as NSString).lastPathComponent, executablePath: argv[0],
                                       arguments: argv, currentDirectory: directory, cpu: 50)
        }
        let processes = [
            command(500, ["/usr/local/bin/npm", "test"], in: fda),
            // Under the npm above: not outermost, so not counted again.
            command(501, parent: 500, ["/usr/local/bin/node", fda + "/node_modules/.bin/vitest", "run"], in: fda),
            command(510, ["/usr/bin/swift", "build"], in: fda),
            command(520, ["/usr/local/bin/pnpm", "install"], in: shop),
            command(530, ["/bin/zsh"], in: shop),
        ]
        let snapshot = SyntheticSnapshots.snapshot(processes)
        let groups = ProvenanceResolver.resolve(snapshot)
        let projects = ProjectAttributor.breakdown(snapshot: snapshot, groups: groups, docker: .unavailable(.disabled), mappings: [],
                                                   locator: locator, home: home)
        let tick = LiveTick(sequence: 1, snapshot: snapshot, groups: groups, hardware: DisabledHardwareProvider().sample(),
                            docker: .unavailable(.disabled), projects: projects, topByCPU: [], topByMemory: [],
                            history: LiveHistory(capacity: 2).window(for: []), collectionSeconds: 0)
        var rules = ConcurrencyRules()
        _ = rules.explanations(for: tick)
        #expect(rules.runningByProject == [project(fda).id: 2, project(shop).id: 1])

        var quiet = ConcurrencyRules()
        let idle = LiveTick(sequence: 1, snapshot: SyntheticSnapshots.snapshot([processes[4]]), groups: [], hardware: tick.hardware,
                            docker: tick.docker, projects: .empty, topByCPU: [], topByMemory: [], history: tick.history, collectionSeconds: 0)
        _ = quiet.explanations(for: idle)
        #expect(quiet.runningByProject.isEmpty)
    }

    @Test("50 watches × 300 projects: under 1 ms a tick (10 ms in debug)")
    func cost() {
        let roots = (0..<300).map { home + "/Developer/project-\($0)" }
        let usages = roots.enumerated().map { i, root in usage(root, Load(cpu: Double(i % 500), memoryGB: Double(i % 9), commands: 0)) }
        let watches = roots.prefix(50).map { watch($0, cpu: 200, memory: 4, commands: 2) }
        let base = tick(0, [:])
        let runs = 200
        let prepared = (0..<runs).map { n in
            var t = LiveTick(sequence: n + 1, snapshot: ScanSnapshot(startedAt: t0.addingTimeInterval(Double(n) * step), interval: step,
                                                                     system: base.snapshot.system, processes: base.snapshot.processes, notices: []),
                             groups: [], hardware: base.hardware, docker: base.docker,
                             projects: ProjectBreakdown(usages: usages, containerAttributions: [:], notices: []), topByCPU: [], topByMemory: [],
                             history: base.history, collectionSeconds: 0)
            t.runningCommandsByProject = Dictionary(uniqueKeysWithValues: roots.enumerated().map { (project($1).id, $0 % 4) })
            return t
        }
        var evaluator = evaluator(watches)
        let elapsed = ContinuousClock().measure {
            for tick in prepared { _ = evaluator.alerts(for: tick) }
        }
        let (seconds, attoseconds) = elapsed.components
        let perTick = (Double(seconds) * 1_000 + Double(attoseconds) / 1e15) / Double(runs)
        #if DEBUG
        let bound = 10.0
        #else
        let bound = 1.0
        #endif
        #expect(perTick < bound, "\(perTick) ms per tick")
    }
}
