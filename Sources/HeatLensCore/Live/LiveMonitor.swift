import Foundation

/// What a live session reads and how often (docs/v2/ADR-0003).
public struct LiveConfiguration: Sendable {
    /// The refresh intervals the UI offers; anything else is clamped into 2...10 s.
    public static let intervals: [TimeInterval] = [2, 5, 10]
    public static let intervalRange: ClosedRange<TimeInterval> = 2...10
    /// The gap before the first tick, so the first numbers appear quickly.
    public static let warmUp: TimeInterval = 1

    public var interval: TimeInterval
    public var hardware: any HardwareSensorProviding
    public var docker: any DockerSampling
    public var userRules: [WorkloadRule]
    /// The session ends itself after this long, so a forgotten panel can't sample forever.
    public var autoPauseAfter: TimeInterval
    /// Ticks of trend history kept in memory (150 × 5 s = 12.5 minutes).
    public var historyCapacity: Int
    /// Processes per top list, each with a trend.
    public var topCount: Int
    /// Finds repository roots for the per-project breakdown; nil leaves `LiveTick.projects` empty.
    /// One locator per app, so its cache spans sessions.
    public var projectLocator: ProjectRootLocator?
    public var projectMappings: [ProjectMapping]
    /// Where ticks are kept when the user turned on "Keep history"; nil writes nothing.
    public var history: HistoryStore?
    /// The user's alert rules (brief 3c); off unless turned on in Settings.
    public var alerts: AlertConfiguration

    public init(interval: TimeInterval = 5, hardware: any HardwareSensorProviding = DisabledHardwareProvider(),
                docker: any DockerSampling = DisabledDockerSampler(), userRules: [WorkloadRule] = [],
                autoPauseAfter: TimeInterval = 15 * 60, historyCapacity: Int = 150, topCount: Int = 12,
                projectLocator: ProjectRootLocator? = nil, projectMappings: [ProjectMapping] = [],
                history: HistoryStore? = nil, alerts: AlertConfiguration = .off) {
        self.interval = Self.clamped(interval)
        self.hardware = hardware
        self.docker = docker
        self.userRules = userRules
        self.autoPauseAfter = autoPauseAfter
        self.historyCapacity = max(2, historyCapacity)
        self.topCount = max(1, topCount)
        self.projectLocator = projectLocator
        self.projectMappings = projectMappings
        self.history = history
        self.alerts = alerts
    }

    static func clamped(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite else { return 5 }
        return min(max(interval, intervalRange.lowerBound), intervalRange.upperBound)
    }
}

/// One live update: the interval since the previous tick, as a normal `ScanSnapshot`, plus
/// hardware, Docker, top lists and their trends.
public struct LiveTick: Sendable {
    public let sequence: Int
    public let snapshot: ScanSnapshot
    public let groups: [ProcessGroup]
    public let hardware: HardwareSample
    public let docker: DockerSnapshot
    /// CPU and memory per project, the Docker VM's remainder and Unattributed (brief 2b).
    public let projects: ProjectBreakdown
    /// Busiest processes by CPU over the interval, then by memory footprint (RSS when no footprint).
    public let topByCPU: [ProcessSample]
    public let topByMemory: [ProcessSample]
    /// Oldest first, aligned with `history.timestamps`, for every process in the top lists.
    public let history: LiveHistory.Window
    /// Wall time this tick spent reading and computing (not the interval).
    public let collectionSeconds: TimeInterval
    /// Set when the previous tick couldn't be saved to the history; the session goes on.
    public var historyFailure: String? = nil
    /// Events found on this tick (briefs 2d, 2e).
    public var events: [TimelineEvent] = []
    /// Concurrency bursts explained in plain words (brief 3b): recent first, at most
    /// `ConcurrencyRules.limit`, each kept until 10 minutes after its burst ends.
    public var explanations: [Explanation] = []
    /// Alerts that fired on this tick (brief 3c); empty on most ticks.
    public var alerts: [Alert] = []
    /// This session's timeline so far, in memory: points, busiest projects and events, bounded
    /// like the trend ring.
    public var timeline: HistoryWindow = .empty
}

public enum LiveEvent: Sendable {
    case tick(LiveTick)
    /// The session hit `autoPauseAfter` and stopped itself.
    case autoPaused
    /// Reading the process list failed; the session stopped.
    case failed(String)
}

/// Samples the Mac every few seconds while a session is running, and does nothing otherwise:
/// no timer outlives `stop()`, and dropping the stream stops the session. Reuses
/// `ScanAssembly`, so a live tick and a scan agree on CPU (100 = one core), PID reuse and
/// processes born mid-interval. Never runs `ps`, `pmset`, ports or power assertions.
public actor LiveMonitor {
    private let processSampler: any ProcessSampling
    private let systemSampler: any SystemSampling
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var session: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    private var continuation: AsyncStream<LiveEvent>.Continuation?
    private var interval: TimeInterval = 5
    private var sessionID = 0
    /// Outlives a session, so an alert's cooldown holds across Pause and Start. In memory only.
    private var alertEvaluator = AlertEvaluator()

    public init(processSampler: some ProcessSampling = LibprocProcessSampler(),
                systemSampler: some SystemSampling = HostSystemSampler(readsPmset: false)) {
        self.init(processSampler: processSampler, systemSampler: systemSampler,
                  sleep: { try await Task.sleep(for: .seconds($0)) })
    }

    /// Tests inject a sleep that returns at once.
    init(processSampler: any ProcessSampling, systemSampler: any SystemSampling,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.processSampler = processSampler
        self.systemSampler = systemSampler
        self.sleep = sleep
    }

    public var isRunning: Bool { session != nil }

    /// Starts a session, stopping any previous one. The stream ends when the session stops.
    public func start(_ configuration: LiveConfiguration) -> AsyncStream<LiveEvent> {
        stop()
        sessionID += 1
        let id = sessionID
        interval = configuration.interval
        let (stream, continuation) = AsyncStream<LiveEvent>.makeStream(bufferingPolicy: .bufferingNewest(2))
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop(session: id) }
        }
        session = Task { [weak self] in
            await self?.run(configuration, session: id)
        }
        return stream
    }

    public func stop() {
        session?.cancel()
        sleeper?.cancel()
        session = nil
        sleeper = nil
        continuation?.finish()
        continuation = nil
    }

    /// Ends the next wait early, so a tick happens now.
    public func refreshNow() {
        sleeper?.cancel()
    }

    /// Takes effect from the next wait.
    public func setInterval(_ newValue: TimeInterval) {
        interval = LiveConfiguration.clamped(newValue)
    }

    /// Alert settings changed while a session runs; takes effect from the next tick. Hold and
    /// cooldown timers are kept.
    public func setAlerts(_ configuration: AlertConfiguration) {
        alertEvaluator.configuration = configuration
    }

    private func stop(session id: Int) {
        if id == sessionID { stop() }
    }

    private func emit(_ event: LiveEvent, session id: Int) {
        guard id == sessionID else { return }
        continuation?.yield(event)
    }

    private func wait(_ seconds: TimeInterval) async throws {
        let sleep = self.sleep
        let sleeper = Task { try await sleep(seconds) }
        self.sleeper = sleeper
        // Cancelled by refreshNow (go on) or by stop (the session's own cancellation ends the loop).
        _ = try? await sleeper.value
        self.sleeper = nil
        try Task.checkCancellation()
    }

    private func run(_ configuration: LiveConfiguration, session id: Int) async {
        let startedAt = ContinuousClock.now
        var history = LiveHistory(capacity: configuration.historyCapacity)
        var sequence = 0
        var historyFailure: String?
        var detector = TimelineDetector()
        var concurrency = ConcurrencyRules()
        alertEvaluator.configuration = configuration.alerts
        var timeline = (points: [HistoryPoint](), projects: [HistoryProjectPoint](), events: [TimelineEvent]())
        do {
            var previousProcesses = try processSampler.snapshot()
            var previousHost = systemSampler.counters()
            var previousDocker: DockerReading? = configuration.docker.reading()
            try await wait(LiveConfiguration.warmUp)
            while !Task.isCancelled {
                let began = ContinuousClock.now
                let host = systemSampler.counters()
                let processes = try processSampler.snapshot()
                let state = try await systemSampler.state()
                let hardware = configuration.hardware.sample()
                let dockerReading = configuration.docker.reading()
                try Task.checkCancellation()

                let snapshot = ScanAssembly.snapshot(startedAt: previousProcesses.wallClock, before: previousProcesses, after: processes,
                                                     psBefore: nil, psAfter: nil, psFailure: nil,
                                                     hostBefore: previousHost, hostAfter: host, state: state, live: true)
                let groups = ProvenanceResolver.resolve(snapshot, userRules: configuration.userRules)
                let docker = DockerAssembly.snapshot(before: previousDocker, after: dockerReading)
                history.append(snapshot, hardware: hardware)
                let (byCPU, byMemory) = Self.topLists(snapshot.processes, count: configuration.topCount)
                sequence += 1
                let projects = configuration.projectLocator.map {
                    ProjectAttributor.breakdown(snapshot: snapshot, groups: groups, docker: docker,
                                                mappings: configuration.projectMappings, locator: $0)
                } ?? .empty
                var tick = LiveTick(sequence: sequence, snapshot: snapshot, groups: groups, hardware: hardware, docker: docker,
                                    projects: projects, topByCPU: byCPU, topByMemory: byMemory,
                                    history: history.window(for: Set((byCPU + byMemory).map(\.identity))),
                                    collectionSeconds: Self.seconds(began.duration(to: .now)), historyFailure: historyFailure)
                tick.events = detector.events(for: tick)
                let explained = concurrency.explanations(for: tick)
                tick.explanations = concurrency.current
                tick.events += explained.map { $0.timelineEvent(at: snapshot.startedAt.addingTimeInterval(snapshot.interval)) }
                tick.alerts = alertEvaluator.alerts(for: tick)
                tick.events += tick.alerts.map(\.timelineEvent)
                let point = HistoryRecorder.point(from: tick)
                let projectPoints = HistoryRecorder.projectPoints(from: tick)
                timeline.points.append(point)
                timeline.projects += projectPoints
                timeline.events += tick.events
                let capacity = configuration.historyCapacity
                if timeline.points.count > capacity {
                    let oldest = timeline.points[timeline.points.count - capacity].timestamp
                    timeline.points.removeFirst(timeline.points.count - capacity)
                    timeline.projects.removeAll { $0.timestamp < oldest }
                }
                if timeline.events.count > Self.timelineEventLimit { timeline.events.removeFirst(timeline.events.count - Self.timelineEventLimit) }
                tick.timeline = HistoryWindow(points: timeline.points, projects: timeline.projects, events: timeline.events)
                emit(.tick(tick), session: id)
                if let store = configuration.history {
                    do {
                        try await store.record(point, projects: projectPoints, events: tick.events)
                        historyFailure = nil
                    } catch {
                        historyFailure = "\(error)"
                    }
                }
                previousProcesses = processes
                previousHost = host
                previousDocker = dockerReading

                if Self.seconds(startedAt.duration(to: .now)) >= configuration.autoPauseAfter {
                    emit(.autoPaused, session: id)
                    stop(session: id)
                    return
                }
                // A full interval after the tick finished: a slow tick delays the next one, never queues it.
                try await wait(interval)
            }
        } catch is CancellationError {
            return
        } catch {
            emit(.failed("\(error)"), session: id)
            stop(session: id)
        }
    }

    /// Events kept in a session's in-memory timeline.
    static let timelineEventLimit = 200

    static func topLists(_ processes: [ProcessSample], count: Int) -> (cpu: [ProcessSample], memory: [ProcessSample]) {
        let live = processes.filter { $0.detailAccess != .processExited }
        let byCPU = live.filter { ($0.cpuPercentOfOneCore ?? 0) > 0 }
            .sorted { ($0.cpuPercentOfOneCore ?? 0, $1.pid) > ($1.cpuPercentOfOneCore ?? 0, $0.pid) }
        let byMemory = live.filter { memory($0) != nil }
            .sorted { (memory($0) ?? 0, $1.pid) > (memory($1) ?? 0, $0.pid) }
        return (Array(byCPU.prefix(count)), Array(byMemory.prefix(count)))
    }

    /// Footprint (Activity Monitor's "Memory") when readable, else RSS.
    static func memory(_ process: ProcessSample) -> UInt64? {
        process.footprintBytes ?? process.residentBytes
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (s, attoseconds) = duration.components
        return TimeInterval(s) + TimeInterval(attoseconds) / 1e18
    }
}

/// A bounded, in-memory ring of recent ticks: host load, CPU temperature, and per-process CPU
/// and memory. Compact storage (Float, KiB) keeps ~800 processes × 150 ticks near 1 MB.
/// Dropped when the session stops; persistence is Phase 2's history store.
public struct LiveHistory: Sendable {
    public struct Window: Sendable {
        public let timestamps: [Date]
        /// 0...1 of all cores.
        public let hostBusy: [Double?]
        public let cpuTemperature: [Double?]
        /// Percent of one core, per process, aligned with `timestamps`.
        public let cpu: [ProcessIdentity: [Double?]]
        public let memoryBytes: [ProcessIdentity: [UInt64?]]
    }

    public let capacity: Int
    private(set) var timestamps: [Date] = []
    private var hostBusy: [Float] = []
    private var cpuTemperature: [Float] = []
    private var cpu: [ProcessIdentity: [Float]] = [:]
    private var memoryKiB: [ProcessIdentity: [UInt32]] = [:]
    private static let noMemory = UInt32.max

    public init(capacity: Int) {
        self.capacity = max(2, capacity)
    }

    var trackedProcessCount: Int { cpu.count }

    mutating func append(_ snapshot: ScanSnapshot, hardware: HardwareSample?) {
        let count = timestamps.count
        timestamps.append(snapshot.startedAt.addingTimeInterval(snapshot.interval))
        hostBusy.append(Float(snapshot.system.hostBusyFraction))
        cpuTemperature.append(hardware?.cpuTemperature.value.map { Float($0.averageCelsius) } ?? .nan)
        var seen = Set<ProcessIdentity>()
        for process in snapshot.processes where process.detailAccess != .processExited {
            seen.insert(process.identity)
            let memory = LiveMonitor.memory(process).map { UInt32(min($0 / 1024, UInt64(Self.noMemory - 1))) } ?? Self.noMemory
            cpu[process.identity, default: Array(repeating: .nan, count: count)].append(process.cpuPercentOfOneCore.map(Float.init) ?? .nan)
            memoryKiB[process.identity, default: Array(repeating: Self.noMemory, count: count)].append(memory)
        }
        for identity in Array(cpu.keys) where !seen.contains(identity) {
            cpu[identity]?.append(.nan)
            memoryKiB[identity]?.append(Self.noMemory)
        }
        if timestamps.count > capacity {
            let excess = timestamps.count - capacity
            timestamps.removeFirst(excess)
            hostBusy.removeFirst(excess)
            cpuTemperature.removeFirst(excess)
            for identity in Array(cpu.keys) {
                cpu[identity]?.removeFirst(excess)
                memoryKiB[identity]?.removeFirst(excess)
                // Gone for the whole window: forget it.
                if cpu[identity]?.allSatisfy(\.isNaN) == true, memoryKiB[identity]?.allSatisfy({ $0 == Self.noMemory }) == true {
                    cpu[identity] = nil
                    memoryKiB[identity] = nil
                }
            }
        }
    }

    func window(for identities: Set<ProcessIdentity>) -> Window {
        func optional(_ value: Float) -> Double? { value.isNaN ? nil : Double(value) }
        var cpuSeries: [ProcessIdentity: [Double?]] = [:]
        var memorySeries: [ProcessIdentity: [UInt64?]] = [:]
        for identity in identities {
            if let values = cpu[identity] { cpuSeries[identity] = values.map(optional) }
            if let values = memoryKiB[identity] { memorySeries[identity] = values.map { $0 == Self.noMemory ? nil : UInt64($0) * 1024 } }
        }
        return Window(timestamps: timestamps, hostBusy: hostBusy.map(optional), cpuTemperature: cpuTemperature.map(optional),
                      cpu: cpuSeries, memoryBytes: memorySeries)
    }
}
