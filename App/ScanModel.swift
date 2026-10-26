import Foundation
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

    private let service: any ScanService
    private var task: Task<Void, Never>?
    /// Bumped per scan so progress or results from a cancelled scan are dropped.
    private var generation = 0

    init(service: any ScanService) {
        self.service = service
    }

    var isScanning: Bool { task != nil }

    func startScan(duration: TimeInterval = ScanModel.defaultDuration) {
        guard task == nil else { return }
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
            } catch {
                finish(.failed(error.localizedDescription), generation: current)
            }
        }
    }

    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        generation += 1
        state = .idle(lastScan: lastScan)
    }

    /// Leaves results or an error and shows the idle view again.
    func dismiss() {
        guard task == nil else { return }
        state = .idle(lastScan: lastScan)
    }

    private func progress(_ elapsed: TimeInterval, total: TimeInterval, generation: Int) {
        guard generation == self.generation, case .scanning = state else { return }
        state = .scanning(elapsed: elapsed, total: total)
    }

    private func finish(_ newState: State, generation: Int) {
        guard generation == self.generation else { return }
        task = nil
        if case .results = newState { lastScan = Date() }
        state = newState
    }
}
