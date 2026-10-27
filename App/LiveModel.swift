import Foundation
import HeatLensCore
import Observation

/// Drives the panel's Live mode. Samples only between Start and Pause, a panel close, switching
/// back to Scan, or the 15-minute auto-pause (docs/v2/ADR-0003). Holds no timer of its own:
/// the monitor's sleep, inside the session, is the only wait.
@MainActor @Observable
final class LiveModel {
    enum State: Equatable {
        case stopped(reason: String?)
        /// Started; waiting for the first tick (about a second).
        case starting
        case running
    }

    private(set) var state: State = .stopped(reason: nil)
    private(set) var latest: LiveTick?

    let settings: SettingsModel
    @ObservationIgnored private let monitor: LiveMonitor
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(settings: SettingsModel, monitor: LiveMonitor = LiveMonitor()) {
        self.settings = settings
        self.monitor = monitor
    }

    var isRunning: Bool {
        if case .stopped = state { return false }
        return true
    }

    func start() {
        stop()
        generation += 1
        let current = generation
        let options = settings.collectionOptions
        let configuration = LiveConfiguration(interval: settings.liveInterval, hardware: options.hardwareProvider,
                                              docker: options.dockerSampler, userRules: options.userRules)
        state = .starting
        let monitor = self.monitor
        consumer = Task { [weak self] in
            let stream = await monitor.start(configuration)
            for await event in stream {
                guard let self, self.generation == current else { break }
                switch event {
                case .tick(let tick):
                    self.latest = tick
                    self.state = .running
                case .autoPaused:
                    self.state = .stopped(reason: "Paused after 15 minutes")
                case .failed(let message):
                    self.state = .stopped(reason: "Live mode stopped: \(message)")
                }
            }
            guard let self, self.generation == current else { return }
            if case .stopped = self.state {} else { self.state = .stopped(reason: nil) }
            self.consumer = nil
        }
    }

    /// Stops sampling. Keeps the last tick on screen. Cancelling the consumer ends its stream,
    /// and the monitor stops exactly that session (a later `start` is never affected).
    func stop() {
        generation += 1
        consumer?.cancel()
        consumer = nil
        if case .stopped = state {} else { state = .stopped(reason: nil) }
    }

    func refreshNow() {
        let monitor = self.monitor
        Task { await monitor.refreshNow() }
    }

    func setInterval(_ interval: TimeInterval) {
        settings.liveInterval = interval
        let monitor = self.monitor
        Task { await monitor.setInterval(interval) }
        if isRunning { refreshNow() }
    }
}
