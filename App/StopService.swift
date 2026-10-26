import Foundation
import HeatLensCore

protocol ProcessStopping: Sendable {
    func eligibility(of process: ProcessSample) -> StopEligibility
    func requestStop(_ identity: ProcessIdentity, wait: TimeInterval) async -> StopOutcome
}

struct TerminatorStopService: ProcessStopping {
    private let terminator = ProcessTerminator()

    func eligibility(of process: ProcessSample) -> StopEligibility {
        terminator.eligibility(of: process)
    }

    func requestStop(_ identity: ProcessIdentity, wait: TimeInterval = 3) async -> StopOutcome {
        await terminator.requestStop(identity, wait: wait)
    }
}

/// Preview-only stopper. It never signals a process and makes every synthetic process eligible.
struct FixtureStopService: ProcessStopping {
    func eligibility(of process: ProcessSample) -> StopEligibility { .eligible }

    func requestStop(_ identity: ProcessIdentity, wait: TimeInterval = 3) async -> StopOutcome {
        try? await Task.sleep(for: .milliseconds(500))
        return .stopped
    }
}

struct StopTarget: Identifiable {
    var id: ProcessIdentity { identity }
    let identity: ProcessIdentity
    let process: ProcessSample
    let project: ProjectAttribution?
}
