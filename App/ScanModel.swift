import Foundation
import HeatLensCore
import Observation

/// Drives the popover through idle → scanning → results. Nothing runs outside a scan:
/// the only timer is the service's own sleep, inside the scan task.
@MainActor @Observable
final class ScanModel {
    enum State {
        case idle(lastScan: Date?)
        case scanning(elapsed: TimeInterval, total: TimeInterval)
        case results(ScanReport)
        case failed(String)
    }

    static let defaultDuration: TimeInterval = 10

    private(set) var state: State = .idle(lastScan: nil)
    private(set) var lastScan: Date?
    /// The results before the latest ones, for "Since last scan". In memory only: HeatLens keeps
    /// no scan history (FR-10), so a relaunch forgets it.
    private(set) var previousReport: ScanReport?
    /// True once a stop since the latest results ended with the process exiting; the next
    /// results clear it.
    private(set) var stoppedSinceLastScan = false
    /// The latest results, kept through Done, a cancel or a failed scan.
    private var latestReport: ScanReport?

    private let service: any ScanService
    let settings: SettingsModel
    private var task: Task<Void, Never>?
    /// Bumped per scan so progress or results from a cancelled scan are dropped.
    private var generation = 0
    /// Told once how the current scan ended: its report, or nil when it failed or was cancelled.
    private var onFinish: (@MainActor (ScanReport?) -> Void)?

    init(service: any ScanService, settings: SettingsModel = SettingsModel()) {
        self.service = service
        self.settings = settings
    }

    var isScanning: Bool { task != nil }

    func startScan(duration: TimeInterval? = nil, onFinish: (@MainActor (ScanReport?) -> Void)? = nil) {
        guard task == nil else { return }
        self.onFinish = onFinish
        let duration = duration ?? settings.sampleDuration
        generation += 1
        let current = generation
        let service = self.service
        state = .scanning(elapsed: 0, total: duration)
        task = Task {
            do {
                let report = try await service.run(duration: duration) { elapsed in
                    Task { @MainActor [weak self] in self?.progress(elapsed, total: duration, generation: current) }
                }
                try Task.checkCancellation()
                finish(.results(report), generation: current)
            } catch is CancellationError {
                // cancel() already returned to idle.
            } catch ScanError.alreadyRunning {
                // FR-13: another scan owns the coordinator; drop this one quietly.
                finish(.idle(lastScan: lastScan), generation: current)
            } catch {
                finish(.failed(Self.message(for: error)), generation: current)
            }
        }
    }

    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        generation += 1
        state = .idle(lastScan: lastScan)
        reportFinish(nil)
    }

    /// Leaves results or an error and shows the idle view again.
    func dismiss() {
        guard task == nil else { return }
        state = .idle(lastScan: lastScan)
    }

    /// A stop or batch stop reported at least one `.stopped`.
    func recordStop() {
        stoppedSinceLastScan = true
    }

    /// Plain words for the failed state (FR-13); never a raw error dump.
    static func message(for error: Error) -> String {
        switch error {
        case ScanError.invalidDuration:
            "The scan length wasn't valid. Try again."
        default:
            "HeatLens couldn't read process activity on this Mac. Nothing was changed. "
                + "(\(error.localizedDescription))"
        }
    }

    private func progress(_ elapsed: TimeInterval, total: TimeInterval, generation: Int) {
        guard generation == self.generation, case .scanning = state else { return }
        state = .scanning(elapsed: elapsed, total: total)
    }

    private func finish(_ newState: State, generation: Int) {
        guard generation == self.generation else { return }
        task = nil
        if case .results(let report) = newState {
            lastScan = Date()
            if let latestReport { previousReport = latestReport }
            latestReport = report
            stoppedSinceLastScan = false
        }
        state = newState
        if case .results(let report) = newState { reportFinish(report) } else { reportFinish(nil) }
    }

    private func reportFinish(_ report: ScanReport?) {
        let handler = onFinish
        onFinish = nil
        handler?(report)
    }
}
