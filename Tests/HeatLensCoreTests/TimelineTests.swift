import Foundation
import Testing
@testable import HeatLensCore

private let home = SyntheticSnapshots.home

private func process(_ pid: Int32, parent: Int32 = 1, argv: [String], cwd: String? = home + "/Developer/FDA",
                     owner: ProcessOwner = .currentUser, cpu: Double = 50, ageHours: Double = 1) -> ProcessSample {
    SyntheticSnapshots.process(pid: pid, parentPID: parent, ageHours: ageHours, owner: owner,
                               name: (argv[0] as NSString).lastPathComponent, executablePath: argv[0],
                               arguments: argv, currentDirectory: cwd, cpu: cpu)
}

private func label(_ argv: [String], owner: ProcessOwner = .currentUser) -> String? {
    ExpensiveCommand.classify(process(100, argv: argv, owner: owner))?.label
}

private func container(_ id: Character, _ name: String) -> ContainerSample {
    ContainerSample(containerID: String(repeating: id, count: 64), name: name, image: "postgres:17", state: "running", status: "Up",
                    createdAt: Date(timeIntervalSince1970: 1_900_000_000),
                    labels: ["com.docker.compose.project.working_dir": home + "/Developer/FDA"],
                    cpuPercentOfOneCore: 1, memoryBytes: 1 << 20, vmCPUCount: 6)
}

/// A live tick at `minute` minutes past the synthetic start, with projects resolved against a
/// fake filesystem where ~/Developer/FDA and ~/Developer/shop are repositories.
private func tick(_ processes: [ProcessSample], containers: [ContainerSample]? = nil, thermal: ThermalState = .nominal,
                  seconds: TimeInterval = 0) -> LiveTick {
    let base = SyntheticSnapshots.snapshot(processes, thermal: thermal)
    let snapshot = ScanSnapshot(startedAt: base.startedAt.addingTimeInterval(seconds), interval: base.interval, system: base.system,
                                processes: base.processes, notices: [])
    let groups = ProvenanceResolver.resolve(snapshot)
    let docker = containers.map { DockerSnapshot(availability: .available, engineVersion: "28.5.1", apiVersion: "1.51", containers: $0, notices: []) }
        ?? .unavailable(.disabled)
    let locator = ProjectRootLocator(home: home, exists: { [home + "/Developer/FDA/.git", home + "/Developer/shop/.git"].contains($0) })
    let projects = ProjectAttributor.breakdown(snapshot: snapshot, groups: groups, docker: docker, mappings: [], locator: locator, home: home)
    return LiveTick(sequence: 1, snapshot: snapshot, groups: groups, hardware: DisabledHardwareProvider().sample(), docker: docker,
                    projects: projects, topByCPU: [], topByMemory: [], history: LiveHistory(capacity: 2).window(for: []),
                    collectionSeconds: 0)
}

@Suite("Expensive commands")
struct ExpensiveCommandTests {
    @Test("installs, builds and test runs are recognised from argv, including npm's one-string title")
    func recognised() {
        #expect(label(["npm ci"]) == "npm ci")
        #expect(label(["node", "/opt/homebrew/bin/npm", "install"]) == "npm install")
        #expect(label(["pnpm", "i"]) == "pnpm install")
        #expect(label(["yarn"]) == "yarn install")
        #expect(label(["node", home + "/Developer/FDA/node_modules/.bin/vitest", "run"]) == "vitest")
        #expect(label(["node", home + "/Developer/FDA/node_modules/next/dist/bin/next", "build"]) == "next build")
        #expect(label(["npm", "run", "build"]) == "npm run build")
        #expect(label(["/usr/bin/python3", "-m", "pytest", "-q"]) == "pytest")
        #expect(label(["docker", "build", "-t", "app", "."]) == "docker build")
        #expect(label(["docker", "compose", "build"]) == "docker compose build")
        #expect(label(["cargo", "test"]) == "cargo test")
        #expect(label(["swift", "build", "-c", "release"]) == "swift build")
        #expect(label(["xcodebuild", "-scheme", "App", "test"]) == "xcodebuild")
        #expect(label(["./gradlew", "assemble"]) == "gradle build")
    }

    @Test("servers, everyday commands and other users' processes are not")
    func notRecognised() {
        #expect(label(["node", "server.js"]) == nil)
        #expect(label(["npm", "run", "dev"]) == nil)
        #expect(label(["docker", "ps"]) == nil)
        #expect(label(["swift", "repl"]) == nil)
        #expect(label(["node", home + "/x/node_modules/vitest/dist/workers/forks.js"]) == nil)
        #expect(label(["npm", "ci"], owner: .root) == nil)
    }

    @Test("only the outermost command counts: npm test → sh → vitest is one run")
    func outermost() {
        let npm = process(10, argv: ["npm", "test"])
        let shell = process(11, parent: 10, argv: ["/bin/sh", "-c", "vitest run"])
        let vitest = process(12, parent: 11, argv: ["node", home + "/Developer/FDA/node_modules/.bin/vitest", "run"])
        let found = ExpensiveCommand.outermost(in: [npm, shell, vitest])
        #expect(found.map(\.match.label) == ["npm test"])
    }
}

@Suite("Timeline events")
struct TimelineDetectorTests {
    private let vitest = ["node", home + "/Developer/FDA/node_modules/.bin/vitest", "run"]

    @Test("the first tick is a baseline: running commands and containers aren't reported as started")
    func baseline() {
        var detector = TimelineDetector()
        let events = detector.events(for: tick([process(10, argv: vitest)], containers: [container("a", "fda-db-1")]))
        #expect(events.isEmpty)
    }

    @Test("a new test run, a build, a container start and stop, and a thermal change, each with its project")
    func observations() {
        var detector = TimelineDetector()
        _ = detector.events(for: tick([], containers: [container("a", "fda-db-1")]))
        let events = detector.events(for: tick([process(20, argv: vitest)], containers: [container("b", "fda-api-1")], thermal: .serious, seconds: 5))
        let titles = Set(events.map(\.title))
        #expect(titles == ["vitest started", "fda-api-1 started", "fda-db-1 stopped", "Thermal state nominal → serious"])
        #expect(events.first { $0.kind == .testRunStarted }?.projectName == "FDA")
        #expect(events.first { $0.kind == .containerStarted }?.projectName == "FDA")
        #expect(events.allSatisfy { !$0.isInference })
        let hotter = detector.events(for: tick([process(20, argv: vitest)], containers: [container("b", "fda-api-1")], thermal: .critical, seconds: 10))
        #expect(hotter.map(\.title) == ["Thermal state serious → critical"])
    }

    @Test("several expensive commands at once: reported when the set grows, labelled as inference")
    func concurrency() throws {
        var detector = TimelineDetector()
        _ = detector.events(for: tick([]))
        let one = [process(30, argv: vitest)]
        #expect(!detector.events(for: tick(one, seconds: 5)).contains { $0.kind == .concurrentCommands })
        let two = one + [process(31, argv: ["docker", "build", "."], cwd: home + "/Developer/shop")]
        let event = try #require(detector.events(for: tick(two, seconds: 10)).first { $0.kind == .concurrentCommands })
        #expect(event.isInference)
        #expect(event.title == "2 expensive commands at once across 2 projects: docker build (shop), vitest (FDA)")
        #expect(!detector.events(for: tick(two, seconds: 15)).contains { $0.kind == .concurrentCommands })
        let three = two + [process(32, argv: ["npm", "ci"])]
        #expect(detector.events(for: tick(three, seconds: 20)).contains { $0.kind == .concurrentCommands && $0.title.hasPrefix("3 expensive") })
    }

    @Test("the same command started three times in ten minutes in one project is flagged once as likely repeated runs")
    func repeats() {
        var detector = TimelineDetector()
        _ = detector.events(for: tick([]))
        var repeated: [TimelineEvent] = []
        for run in 0..<4 {
            // Each run is a new process (new PID), 2 minutes apart; the previous one has exited.
            let events = detector.events(for: tick([process(Int32(40 + run), argv: vitest)], seconds: TimeInterval(run * 120)))
            repeated += events.filter { $0.kind == .repeatedCommand }
        }
        #expect(repeated.count == 1)
        #expect(repeated.first?.title == "vitest started 3 times in 10 minutes in FDA (likely repeated runs)")
        #expect(repeated.first?.isInference == true)
    }
}

@Suite("Timeline analysis")
struct TimelineAnalysisTests {
    @Test("the peak names the projects busiest at that moment and the events just before it")
    func peak() throws {
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        let points = (0..<10).map { i in
            HistoryPoint(timestamp: t0.addingTimeInterval(TimeInterval(i * 5)), thermalState: .nominal, hostBusyFraction: i == 6 ? 0.9 : 0.2,
                         swapUsedBytes: 0, memoryPressure: .normal, cpuTemperatureCelsius: nil, systemWatts: nil, processWatts: nil)
        }
        let at = t0.addingTimeInterval(30)
        let projects = [
            HistoryProjectPoint(timestamp: at, projectID: "a", name: "FDA", cpuPercent: 420, memoryBytes: 0, watts: nil),
            HistoryProjectPoint(timestamp: at, projectID: "b", name: "shop", cpuPercent: 60, memoryBytes: 0, watts: nil),
            HistoryProjectPoint(timestamp: t0, projectID: "b", name: "shop", cpuPercent: 900, memoryBytes: 0, watts: nil),
        ]
        let events = [
            TimelineEvent(timestamp: t0.addingTimeInterval(-200), kind: .testRunStarted, title: "too early"),
            TimelineEvent(timestamp: t0.addingTimeInterval(20), kind: .testRunStarted, title: "vitest started", projectName: "FDA"),
            TimelineEvent(timestamp: t0.addingTimeInterval(45), kind: .containerStarted, title: "fda-db-1 started"),
        ]
        let peak = try #require(TimelineAnalysis.peak(in: HistoryWindow(points: points, projects: projects, events: events)))
        #expect(peak.point.timestamp == at)
        #expect(peak.projects.map(\.name) == ["FDA", "shop"])
        #expect(peak.events.map(\.title) == ["vitest started", "fda-db-1 started"])
        #expect(TimelineAnalysis.peak(in: .empty) == nil)
    }
}

@Suite("Timeline detector at scale")
struct TimelineDetectorScaleTests {
    @Test("1,000 processes with argv: detection on a tick stays under 10 ms")
    func scale() {
        var processes: [ProcessSample] = []
        for i in 0..<1_000 {
            let server: [String] = ["node", home + "/Developer/app/server-\(i).js", "--port", String(3000 + i)]
            processes.append(process(Int32(1_000 + i), argv: i % 50 == 0 ? ["npm", "ci"] : server))
        }
        let first = tick(processes)
        let second = tick(processes, seconds: 5)
        var detector = TimelineDetector()
        _ = detector.events(for: first)
        let start = ContinuousClock.now
        let events = detector.events(for: second)
        let elapsed = start.duration(to: .now)
        #expect(events.isEmpty)
        #expect(elapsed < .milliseconds(10), "took \(elapsed)")
    }
}
