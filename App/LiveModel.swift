import Foundation
import HeatLensCore
import Observation

/// Drives the panel's Live mode over the app's one `BackgroundMonitor` (docs/v2/ADR-0008 §4).
/// With "Keep watching in the background" off it is v1's Live: it samples between Start and
/// Pause, a panel close, switching back to Scan, or the 15-minute auto-pause. With it on, a
/// panel close or Scan drops to the background cadence instead, until Pause or Quit. Holds no
/// timer of its own: the monitor's sleep, inside the session, is the only wait.
@MainActor @Observable
final class LiveModel {
    enum State: Equatable {
        case stopped(reason: String?)
        /// Started; waiting for the first tick (about a second).
        case starting
        case running
    }

    private(set) var latest: LiveTick?
    /// The alerts of the most recent tick that had any, kept on screen for `alertBannerDuration`
    /// after they fired (or until dismissed), across later ticks without alerts.
    private(set) var recentAlerts: [HeatLensCore.Alert] = []
    /// What the monitor is doing: the Live header, Settings' status line and the tooltip.
    private(set) var status = BackgroundStatus(mode: .paused(.notConfigured), since: Date())

    /// How long Live's alert banner stays up: one tick (5 s) was too short to notice.
    static let alertBannerDuration: TimeInterval = 2 * 60

    let settings: SettingsModel
    /// Shared with `LiveAlertService`, which posts from its alerts whether or not the panel is open.
    @ObservationIgnored let monitor: BackgroundMonitor
    @ObservationIgnored private var summary: Task<Void, Never>?
    /// Ticks, only while the Live view shows.
    @ObservationIgnored private var full: Task<Void, Never>?
    /// The last queued call into the monitor; each waits for the one before, so Start's
    /// resume-then-attach and a quick Pause can't overtake each other.
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var panelOpen = false
    @ObservationIgnored private var liveShowing = false
    @ObservationIgnored private var settingsOpen = false
    /// A setting other than Keep watching changed while Settings was open: applied when it closes.
    @ObservationIgnored private var settingsPending = false
    @ObservationIgnored private var appliedKeepWatching: Bool?

    init(settings: SettingsModel, monitor: BackgroundMonitor = BackgroundMonitor()) {
        self.settings = settings
        self.monitor = monitor
        followStatus()
        // Configures at once: with Keep watching on, background mode starts at launch.
        followSettings()
    }

    var state: State {
        switch status.mode {
        case .paused(let reason): .stopped(reason: Self.pauseText(reason))
        case .foreground, .background: latest == nil ? .starting : .running
        }
    }

    var isRunning: Bool { status.isSampling }

    /// The panel's Live view is watching at the picker's interval.
    var isForeground: Bool {
        if case .foreground = status.mode { return true }
        return false
    }

    var isBackground: Bool { status.mode == .background }

    /// Start live: clears Pause, then watches at the picker's interval.
    func start() {
        let interval = settings.liveInterval
        send {
            await $0.resume()
            await $0.viewerAttached(interval: interval)
        }
    }

    /// Pause: nothing samples until Start live or the next launch.
    func pause() {
        send { await $0.pause() }
    }

    /// The panel opened.
    func viewerOpened() {
        panelOpen = true
        followTicks()
    }

    /// The panel closed: v1's Live stops; with Keep watching on, the background cadence takes over.
    func viewerClosed() {
        panelOpen = false
        followTicks()
        send { await $0.viewerDetached() }
        applyPendingSettings()
    }

    /// Switched to Scan.
    func viewerDetached() {
        send { await $0.viewerDetached() }
    }

    /// Whether the Live view is on screen (Live mode, Settings closed).
    func setLiveShowing(_ showing: Bool) {
        liveShowing = showing
        followTicks()
    }

    /// Settings opened or closed. Changes made inside it restart a running session once, on close.
    func setSettingsOpen(_ open: Bool) {
        settingsOpen = open
        if !open { applyPendingSettings() }
    }

    /// When the banner's alerts are due to go; nil when there are none.
    var recentAlertsExpireAt: Date? {
        recentAlerts.map(\.firedAt).max()?.addingTimeInterval(Self.alertBannerDuration)
    }

    /// Clears the banner once `alertBannerDuration` has passed since its alerts fired.
    func expireAlerts(now: Date = Date()) {
        if let expiry = recentAlertsExpireAt, now >= expiry { recentAlerts = [] }
    }

    /// The banner's ×: the alerts stay in Timeline.
    func dismissAlerts() {
        recentAlerts = []
    }

    func refreshNow() {
        send { await $0.refreshNow() }
    }

    /// Alert settings changed: takes effect from the next tick, without restarting the session.
    func setAlerts(_ configuration: AlertConfiguration) {
        send { await $0.setAlerts(configuration) }
    }

    /// The picker: only a watching panel follows it at once; background keeps the policy's cadence.
    func setInterval(_ interval: TimeInterval) {
        settings.liveInterval = interval
        guard isForeground else { return }
        send { await $0.viewerAttached(interval: interval) }
    }

    // MARK: - Status text

    /// "every 30 s (idle, on power)"; nil while paused.
    var cadence: String? {
        guard let interval = status.interval, let reason = status.reason else { return nil }
        let why = switch reason {
        case .idle: "idle, on power"
        case .battery: "idle, on battery"
        case .incident: "incident"
        case .lowPowerMode: "Low Power Mode"
        case .viewer: "while you watch"
        case .fixed: "fixed"
        }
        return "every \(Int(interval.rounded())) s (\(why))"
    }

    /// Settings' status line under the switch.
    var statusLine: String {
        switch status.mode {
        case .background: "Watching · " + (cadence ?? "starting")
        case .foreground(let interval): "Watching live · every \(Int(interval.rounded())) s while the panel is open"
        case .paused(.user): "Paused until you press Start live or HeatLens opens again"
        case .paused(let reason): Self.pauseText(reason).map { "Paused · \($0)" } ?? "Paused"
        }
    }

    /// The status item's tooltip.
    var toolTip: String {
        switch status.mode {
        case .background: "HeatLens: watching in the background"
        case .foreground: "HeatLens: Live"
        case .paused: "HeatLens"
        }
    }

    private static func pauseText(_ reason: BackgroundStatus.PauseReason) -> String? {
        switch reason {
        case .notConfigured, .notWatching, .user: nil
        case .autoPaused: "Paused after 15 minutes"
        case .failed(let message): "Live mode stopped: \(message)"
        }
    }

    // MARK: - Monitor

    private func send(_ operation: @escaping @Sendable (BackgroundMonitor) async -> Void) {
        let previous = queue
        let monitor = self.monitor
        queue = Task {
            await previous?.value
            await operation(monitor)
        }
    }

    /// Status and alerts for the app's lifetime: what a closed panel still needs.
    private func followStatus() {
        let monitor = self.monitor
        summary = Task { [weak self] in
            let stream = await monitor.subscribe(.summary)
            for await event in stream {
                guard let self else { break }
                switch event {
                case .status(let status):
                    self.status = status
                case .alerts(let alerts):
                    self.recentAlerts = alerts
                    self.expireAlerts()
                case .tick, .stopped:
                    break
                }
            }
        }
    }

    /// Subscribes to ticks while the Live view is on screen, and only then.
    private func followTicks() {
        guard panelOpen, liveShowing else {
            full?.cancel()
            full = nil
            return
        }
        guard full == nil else { return }
        let monitor = self.monitor
        full = Task { [weak self] in
            let stream = await monitor.subscribe(.full)
            for await event in stream {
                guard let self else { break }
                if case .tick(let tick) = event {
                    self.latest = tick
                    self.expireAlerts()
                }
            }
        }
        // Background ticks while the panel was closed weren't kept: fetch a fresh one rather than
        // show one up to two minutes old.
        if isBackground { refreshNow() }
    }

    /// Hands Settings changes to the monitor (the `LiveAlertService.followSettings` pattern).
    /// Keep watching applies at once; other changes restart a running session, so those made
    /// while Settings is open wait for it to close, as Live has always done. Alert settings go
    /// through `setAlerts` instead (no restart), so they aren't read here.
    private func followSettings() {
        let keepWatching = withObservationTracking {
            _ = settings.collectionOptions
            _ = settings.keepHistory
            _ = settings.historyRetentionDays
            return settings.keepWatchingInBackground
        } onChange: {
            Task { @MainActor [weak self] in self?.followSettings() }
        }
        if keepWatching != appliedKeepWatching || !settingsOpen {
            applySettings()
        } else {
            settingsPending = true
        }
    }

    private func applyPendingSettings() {
        if settingsPending { applySettings() }
    }

    private func applySettings() {
        settingsPending = false
        let keepWatching = settings.keepWatchingInBackground
        appliedKeepWatching = keepWatching
        let options = settings.collectionOptions
        let configuration = LiveConfiguration(interval: settings.liveInterval, hardware: options.hardwareProvider,
                                              docker: options.dockerSampler, userRules: options.userRules,
                                              projectLocator: .shared, projectMappings: options.projectMappings,
                                              history: settings.keepHistory
                                                ? HistoryService.shared.store(retentionDays: settings.historyRetentionDays) : nil,
                                              alerts: settings.alertConfiguration)
        send { await $0.configure(configuration, keepWatching: keepWatching) }
    }
}
