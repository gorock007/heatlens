import Foundation

/// What `BackgroundMonitor` is doing, for the Live header and Settings' status line
/// (docs/v2/ADR-0008 §1).
public struct BackgroundStatus: Hashable, Codable, Sendable {
    public enum Mode: Hashable, Codable, Sendable {
        /// Nothing samples.
        case paused(PauseReason)
        /// Someone is looking at Live, at the panel's interval (2...10 s).
        case foreground(TimeInterval)
        /// "Keep watching in the background": `SamplingPolicy`'s cadence, no auto-pause.
        case background
    }

    public enum PauseReason: Hashable, Codable, Sendable {
        /// `configure` hasn't been called yet.
        case notConfigured
        /// Nobody is looking and "Keep watching in the background" is off: v1's Live.
        case notWatching
        /// Pause: until `resume()` (the app's next launch makes a new monitor).
        case user
        /// 15 minutes of foreground with "Keep watching" off, as Live has always done.
        case autoPaused
        /// Reading the process list failed.
        case failed(String)
    }

    public var mode: Mode
    /// The wait after the last tick, and why. Nil while paused.
    public var interval: TimeInterval?
    public var reason: SamplingPolicy.Reason?
    /// When `mode` last changed (a new foreground interval doesn't count).
    public var since: Date
    /// The end of the last tick, and the wall time it spent reading and computing.
    public var lastTickAt: Date?
    public var lastTickCost: TimeInterval?

    public init(mode: Mode, interval: TimeInterval? = nil, reason: SamplingPolicy.Reason? = nil, since: Date,
                lastTickAt: Date? = nil, lastTickCost: TimeInterval? = nil) {
        self.mode = mode
        self.interval = interval
        self.reason = reason
        self.since = since
        self.lastTickAt = lastTickAt
        self.lastTickCost = lastTickCost
    }

    public var isSampling: Bool {
        if case .paused = mode { return false }
        return true
    }
}

public enum BackgroundEvent: Sendable {
    /// Every tick, to `.full` subscribers only.
    case tick(LiveTick)
    /// After every tick and every change of mode; also the first event of each subscription.
    case status(BackgroundStatus)
    /// The alerts that fired on a tick, to every subscriber.
    case alerts([Alert])
    /// Sampling stopped, and why.
    case stopped(BackgroundStatus.PauseReason)
}

/// The one Live session of the app (docs/v2/ADR-0008 §1): it decides when `LiveMonitor` samples
/// and how often, and feeds subscribers. All analysis stays in `LiveMonitor.run`; this adds the
/// modes, the subscriptions, a ring of recent alerts and a status. It never signals and never
/// stops anything but its own sampling.
///
/// - With "Keep watching in the background" off it is today's Live: it samples only while a
///   viewer is attached, at the viewer's interval, and pauses itself after 15 minutes.
/// - With it on, a viewer leaving, or 15 minutes of foreground, drops to `SamplingPolicy`'s
///   cadence instead, until Pause or the app quits.
///
/// Calls into `LiveMonitor` run one at a time in the order they were asked for, so a quick
/// pause and resume can't start two sessions or leave none.
public actor BackgroundMonitor {
    public enum Subscription: Hashable, Sendable {
        /// Every `LiveTick`, while the Live view is showing.
        case full
        /// Status, alerts and stops: what a closed panel needs.
        case summary
    }

    /// Foreground this long falls back to background cadence (Keep watching on) or pauses (off).
    public static let foregroundLimit: TimeInterval = 15 * 60
    /// Alerts kept for "while HeatLens was closed" (owner decision 3). In memory only.
    public static let recentAlertLimit = 50
    /// A tick sends up to three events (tick, alerts, status); a slow subscriber loses old
    /// ticks first, not the alerts that came after them.
    static let bufferDepth = 8

    private let live: LiveMonitor
    private let now: @Sendable () -> Date
    private var configuration: LiveConfiguration?
    private var keepWatching = false
    /// The panel's interval while someone is looking at Live.
    private var viewer: TimeInterval?
    private var foregroundSince: Date?
    /// Set by Pause, the 15-minute pause or a failure; only `resume()` clears it.
    private var hold: BackgroundStatus.PauseReason?
    /// A `LiveMonitor` session has been asked for and not stopped.
    private var sampling = false
    private var sessionID = 0
    private var consumer: Task<Void, Never>?
    /// The last queued call into `LiveMonitor`; each waits for the one before.
    private var queue: Task<Void, Never>?
    private var subscribers: [Int: (kind: Subscription, continuation: AsyncStream<BackgroundEvent>.Continuation)] = [:]
    private var nextSubscriber = 0
    private var latest: LiveTick?
    private var lastIntervalNotice: Date?
    /// The current session's last decision, nil until its first tick.
    private var decision: SamplingPolicy.Decision?
    private var ring = RecentAlerts(limit: BackgroundMonitor.recentAlertLimit)
    public private(set) var status: BackgroundStatus

    public init(monitor: LiveMonitor = LiveMonitor()) {
        self.init(monitor: monitor, now: { Date() })
    }

    /// Tests inject the clock for the 15-minute rule.
    init(monitor: LiveMonitor, now: @escaping @Sendable () -> Date) {
        live = monitor
        self.now = now
        status = BackgroundStatus(mode: .paused(.notConfigured), since: now())
    }

    deinit {
        consumer?.cancel()
        for subscriber in subscribers.values { subscriber.continuation.finish() }
    }

    public var isSampling: Bool { sampling }

    /// The settings to sample with, and whether to keep watching with nobody looking. Applies at
    /// once: a running session restarts with them (as closing Settings restarts Live today).
    /// The configuration's `sampling` and `autoPauseAfter` are replaced: this actor decides both.
    public func configure(_ configuration: LiveConfiguration, keepWatching: Bool) async {
        var configuration = configuration
        configuration.sampling = .adaptive
        configuration.autoPauseAfter = nil
        self.configuration = configuration
        self.keepWatching = keepWatching
        reconcile(restart: true)
        await queue?.value
    }

    /// Someone is looking at Live, or changed the panel's interval. Doesn't undo a pause.
    public func viewerAttached(interval: TimeInterval) async {
        let interval = LiveConfiguration.clamped(interval)
        if viewer == nil { foregroundSince = now() }
        viewer = interval
        let wasSampling = sampling
        reconcile()
        if wasSampling, sampling {
            // setViewer doesn't cut the current wait short: tick now so the panel fills at once.
            enqueue { [live] in
                await live.setViewer(interval: interval)
                await live.refreshNow()
            }
        }
        await queue?.value
    }

    /// The panel closed or switched to Scan.
    public func viewerDetached() async {
        detach()
        await queue?.value
    }

    /// Stops sampling until `resume()`, whatever the mode.
    public func pause() async {
        hold = .user
        reconcile()
        await queue?.value
    }

    /// Clears Pause, the 15-minute pause or a failure, and samples again if a viewer is attached
    /// or Keep watching is on.
    public func resume() async {
        hold = nil
        reconcile()
        await queue?.value
    }

    /// Ends the current wait, so a tick happens now.
    public func refreshNow() async {
        guard sampling else { return }
        enqueue { [live] in await live.refreshNow() }
        await queue?.value
    }

    /// Alert settings changed: from the next tick, without restarting (timers and cooldowns kept).
    public func setAlerts(_ alerts: AlertConfiguration) async {
        configuration?.alerts = alerts
        enqueue { [live] in await live.setAlerts(alerts) }
        await queue?.value
    }

    /// Events from now on, starting with the current status. Cancelling every subscription
    /// detaches the viewer: a foreground-only session stops, a background one goes on.
    public func subscribe(_ kind: Subscription) -> AsyncStream<BackgroundEvent> {
        let (stream, continuation) = AsyncStream<BackgroundEvent>.makeStream(bufferingPolicy: .bufferingNewest(Self.bufferDepth))
        nextSubscriber += 1
        let id = nextSubscriber
        subscribers[id] = (kind, continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(.status(status))
        return stream
    }

    /// Alerts fired after `since` (all of them for nil), oldest first: at most the newest 50.
    public func recentAlerts(since: Date? = nil) -> [Alert] {
        ring.alerts(since: since)
    }

    /// The last tick's explanations: bursts still running or ended within 10 minutes.
    public var explanations: [Explanation] {
        latest?.explanations ?? []
    }

    // MARK: - Modes

    private func detach() {
        viewer = nil
        foregroundSince = nil
        let wasSampling = sampling
        reconcile()
        if wasSampling, sampling {
            enqueue { [live] in await live.setViewer(interval: nil) }
        }
    }

    private func unsubscribe(_ id: Int) {
        guard subscribers.removeValue(forKey: id) != nil, subscribers.isEmpty, viewer != nil else { return }
        detach()
    }

    /// Starts, restarts or stops the `LiveMonitor` session to match the settings, the viewer
    /// and any pause, then publishes the status if it changed.
    private func reconcile(restart: Bool = false) {
        let wanted = configuration != nil && hold == nil && (viewer != nil || keepWatching)
        if wanted, let configuration {
            if !sampling || restart {
                sampling = true
                sessionID += 1
                decision = nil
                let id = sessionID
                let viewer = self.viewer
                // As Live's auto-pause always has, the 15 minutes run from the session's start.
                if viewer != nil { foregroundSince = now() }
                enqueue { await self.begin(configuration, viewer: viewer, session: id) }
            }
        } else if sampling {
            sampling = false
            sessionID += 1
            consumer?.cancel()
            consumer = nil
            enqueue { [live] in await live.stop() }
            let reason = pauseReason
            emit(.stopped(reason))
        }
        publishStatus()
    }

    private var pauseReason: BackgroundStatus.PauseReason {
        hold ?? (configuration == nil ? .notConfigured : .notWatching)
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await operation()
        }
    }

    private func begin(_ configuration: LiveConfiguration, viewer: TimeInterval?, session id: Int) async {
        // LiveMonitor keeps the viewer across sessions, so set it first: the first wait uses it.
        await live.setViewer(interval: viewer)
        let stream = await live.start(configuration)
        // A stop or restart asked for meanwhile is queued behind this and replaces the session.
        guard id == sessionID else { return }
        consumer?.cancel()
        consumer = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.receive(event, session: id)
            }
        }
    }

    private func receive(_ event: LiveEvent, session id: Int) {
        guard id == sessionID, sampling else { return }
        switch event {
        case .tick(let tick):
            latest = tick
            decision = tick.sampling
            ring.append(tick.alerts)
            emit(.tick(tick))
            if !tick.alerts.isEmpty { emit(.alerts(tick.alerts)) }
            if let since = foregroundSince, now().timeIntervalSince(since) >= Self.foregroundLimit {
                // A forgotten panel: background cadence with Keep watching on, else Live's auto-pause.
                if keepWatching { detach() } else { hold = .autoPaused }
            }
            // Publishes the status: its last tick changed, and maybe its mode.
            reconcile()
        case .autoPaused:
            // Not expected (autoPauseAfter is nil), but LiveMonitor has stopped itself.
            hold = .autoPaused
            reconcile()
        case .failed(let message):
            hold = .failed(message)
            reconcile()
        }
    }

    // MARK: - Status and subscribers

    private func publishStatus() {
        var next = status
        next.mode = sampling ? viewer.map { .foreground($0) } ?? .background : .paused(pauseReason)
        let current = sampling ? currentDecision : nil
        next.interval = current?.interval
        next.reason = current?.reason
        if let latest {
            next.lastTickAt = latest.snapshot.startedAt.addingTimeInterval(latest.snapshot.interval)
            next.lastTickCost = latest.collectionSeconds
        }
        if !Self.sameKind(next.mode, status.mode) { next.since = now() }
        guard next != status else { return }
        logChange(from: status, to: next)
        status = next
        emit(.status(next))
    }

    /// Mode changes are notices. A new interval or reason within a mode is a notice at most once
    /// per 10 minutes, and debug otherwise, so a steady session persists next to nothing.
    private func logChange(from old: BackgroundStatus, to new: BackgroundStatus) {
        if !Self.sameKind(old.mode, new.mode) {
            let reason: StaticString
            switch new.mode {
            case .foreground: reason = "viewer attached"
            case .background:
                if case .foreground = old.mode { reason = "viewer left" } else { reason = "keep watching" }
            case .paused(let why):
                switch why {
                case .notConfigured: reason = "notConfigured"
                case .notWatching: reason = "notWatching"
                case .user: reason = "user"
                case .autoPaused: reason = "autoPaused"
                case .failed: reason = "failed"
                }
            }
            HeatLensLog.notice(.background, "mode changed", ["to": .word(Self.word(new.mode)), "why": .word(reason),
                                                            "interval": .seconds(new.interval ?? 0)])
        } else if old.interval != new.interval || old.reason != new.reason {
            let date = now()
            let quiet = lastIntervalNotice.map { date.timeIntervalSince($0) < Self.intervalNoticeGap } ?? false
            guard new.interval != nil else { return }
            let values: KeyValuePairs<StaticString, HeatLensLog.Value> = ["interval": .seconds(new.interval ?? 0), "why": .word(Self.word(new.reason))]
            if quiet {
                HeatLensLog.debug(.background, "interval changed", values)
            } else {
                lastIntervalNotice = date
                HeatLensLog.notice(.background, "interval changed", values)
            }
        }
    }

    private static let intervalNoticeGap: TimeInterval = 10 * 60

    private static func word(_ mode: BackgroundStatus.Mode) -> StaticString {
        switch mode {
        case .paused: "paused"
        case .foreground: "foreground"
        case .background: "background"
        }
    }

    private static func word(_ reason: SamplingPolicy.Reason?) -> StaticString {
        switch reason {
        case .viewer: "viewer"
        case .idle: "idle"
        case .incident: "incident"
        case .battery: "battery"
        case .lowPowerMode: "lowPowerMode"
        case .fixed: "fixed"
        case nil: "none"
        }
    }

    /// What the policy waits now. A viewer always wins. A tick decided before the viewer left
    /// still says "viewer", so until the next tick the background wait is worked out from the
    /// last tick's power and incident.
    private var currentDecision: SamplingPolicy.Decision {
        if let viewer { return SamplingPolicy.Decision(interval: viewer, reason: .viewer) }
        if let decision, decision.reason != .viewer { return decision }
        return SamplingPolicy.next(SamplingPolicy.Context(power: latest?.hardware.power, incident: decision?.reason == .incident))
    }

    private static func sameKind(_ a: BackgroundStatus.Mode, _ b: BackgroundStatus.Mode) -> Bool {
        switch (a, b) {
        case (.foreground, .foreground), (.background, .background): true
        case (.paused(let x), .paused(let y)): x == y
        default: false
        }
    }

    private func emit(_ event: BackgroundEvent) {
        for subscriber in subscribers.values {
            if case .tick = event, subscriber.kind == .summary { continue }
            subscriber.continuation.yield(event)
        }
    }
}

/// The newest alerts, oldest first, bounded.
struct RecentAlerts: Sendable {
    let limit: Int
    private(set) var all: [Alert] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    mutating func append(_ alerts: [Alert]) {
        guard !alerts.isEmpty else { return }
        all += alerts
        if all.count > limit { all.removeFirst(all.count - limit) }
    }

    func alerts(since: Date?) -> [Alert] {
        guard let since else { return all }
        return all.filter { $0.firedAt > since }
    }
}
