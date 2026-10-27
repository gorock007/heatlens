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

/// Stop results in words, shared by the single and the batch stop flows so both say the same thing.
enum StopWording {
    /// The full sentence after one stop, e.g. "Process PID 23001 exited after SIGTERM."
    static func message(for outcome: StopOutcome, pid: Int32) -> String {
        switch outcome {
        case .stopped:
            "Process PID \(pid) exited after SIGTERM."
        case .stillRunning:
            "Process PID \(pid) didn't exit. HeatLens does not force-quit; use Activity Monitor if needed."
        case .alreadyExited:
            "Process PID \(pid) had already exited. Nothing was sent."
        case .identityChanged:
            "PID \(pid) now belongs to a different process. Nothing was sent."
        case .denied(let reason):
            "HeatLens didn't send SIGTERM: \(reason)"
        case .failed(let errno):
            "HeatLens couldn't send SIGTERM to PID \(pid) (error \(errno)). Nothing else was changed."
        }
    }

    /// A short row status for the same outcome, e.g. "stopped", "skipped: it changed".
    static func status(for outcome: StopOutcome) -> String {
        switch outcome {
        case .stopped: "stopped"
        case .stillRunning: "still running"
        case .alreadyExited: "already gone"
        case .identityChanged: "skipped: it changed"
        case .denied: "skipped: not allowed"
        case .failed(let errno): "couldn't send (error \(errno))"
        }
    }
}
