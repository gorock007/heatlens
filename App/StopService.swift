import Foundation
import HeatLensCore

protocol ProcessStopping: Sendable {
    func eligibility(of process: ProcessSample) -> StopEligibility
    func requestStop(_ identity: ProcessIdentity, wait: TimeInterval, context: ActionContext) async -> StopOutcome
    /// SIGKILL, only after a SIGTERM this service sent to the same identity (docs/v2/ADR-0006).
    func forceQuit(_ identity: ProcessIdentity, context: ActionContext) async -> StopOutcome
    /// When this service sent its last SIGTERM to exactly this identity, for the force-quit offer.
    func stopRequestedAt(_ identity: ProcessIdentity) async -> Date?
}

struct TerminatorStopService: ProcessStopping {
    private let terminator = ProcessTerminator()
    /// The one ledger for the app session, shared by single and batch stops; `forceQuit` needs the
    /// SIGTERM it recorded.
    private let ledger = StopLedger()
    /// The Settings switch, read on the main actor right before a force quit.
    private let forceQuitAllowed: @MainActor @Sendable () -> Bool

    init(forceQuitAllowed: @escaping @MainActor @Sendable () -> Bool) {
        self.forceQuitAllowed = forceQuitAllowed
    }

    func eligibility(of process: ProcessSample) -> StopEligibility {
        terminator.eligibility(of: process)
    }

    func requestStop(_ identity: ProcessIdentity, wait: TimeInterval = 3, context: ActionContext) async -> StopOutcome {
        await terminator.requestStop(identity, wait: wait, ledger: ledger, context: context)
    }

    func forceQuit(_ identity: ProcessIdentity, context: ActionContext) async -> StopOutcome {
        guard await forceQuitAllowed() else { return .denied(reason: StopWording.forceQuitOff) }
        return await terminator.forceQuit(identity, ledger: ledger, context: context)
    }

    func stopRequestedAt(_ identity: ProcessIdentity) async -> Date? {
        await ledger.stopRequestedAt(identity)
    }
}

/// Preview-only stopper. It never signals a process and makes every synthetic process eligible.
/// PID 23140 (a portfolio-demo leftover) ignores the stop request, so previews show the force-quit offer.
struct FixtureStopService: ProcessStopping {
    static let stubbornPID: Int32 = 23140
    private let sent = SentTimes()

    func eligibility(of process: ProcessSample) -> StopEligibility { .eligible }

    func requestStop(_ identity: ProcessIdentity, wait: TimeInterval = 3, context: ActionContext) async -> StopOutcome {
        await sent.record(identity)
        try? await Task.sleep(for: .milliseconds(500))
        return identity.pid == Self.stubbornPID ? .stillRunning : .stopped
    }

    func forceQuit(_ identity: ProcessIdentity, context: ActionContext) async -> StopOutcome {
        try? await Task.sleep(for: .milliseconds(500))
        return .stopped
    }

    func stopRequestedAt(_ identity: ProcessIdentity) async -> Date? {
        await sent.date(for: identity)
    }

    private actor SentTimes {
        private var dates: [ProcessIdentity: Date] = [:]
        func record(_ identity: ProcessIdentity) { dates[identity] = Date() }
        func date(for identity: ProcessIdentity) -> Date? { dates[identity] }
    }
}

struct StopTarget: Identifiable {
    var id: ProcessIdentity { identity }
    let identity: ProcessIdentity
    let process: ProcessSample
    let project: ProjectAttribution?
    /// Where the user asked for the stop, for the audit record.
    var origin: ActionRecord.Origin = .processDetail

    /// The record's context, with `confirmedAt` the moment the user pressed the confirming button.
    func context(confirmedAt: Date = Date()) -> ActionContext {
        ActionContext(origin: origin, processName: process.name,
                      projectName: project.map { ($0.directory as NSString).lastPathComponent },
                      confirmedAt: confirmedAt)
    }
}

/// The signal a stop result is about, so the words match what was sent.
enum StopSignal {
    case sigterm
    case sigkill
}

/// Stop results in words, shared by the single and the batch stop flows so both say the same thing.
enum StopWording {
    static let forceQuitOff = "Force Quit is off in Settings"

    /// What to do about a SIGTERM the process ignored, depending on the Settings switch (ADR-0006 decision 1).
    static func ignoredStopHint(forceQuitOffered: Bool) -> String {
        forceQuitOffered
            ? "You can force quit it below."
            : "HeatLens does not force-quit unless you turn that on in Settings; Activity Monitor can also stop it."
    }

    /// The full sentence after one stop, e.g. "Process PID 23001 exited after SIGTERM."
    static func message(for outcome: StopOutcome, pid: Int32, signal: StopSignal = .sigterm,
                        forceQuitOffered: Bool = false) -> String {
        let name = signal == .sigterm ? "SIGTERM" : "SIGKILL"
        switch outcome {
        case .stopped:
            return signal == .sigterm ? "Process PID \(pid) exited after SIGTERM." : "Process PID \(pid) was force quit (SIGKILL)."
        case .stillRunning:
            return signal == .sigterm
                ? "Process PID \(pid) didn't exit. " + ignoredStopHint(forceQuitOffered: forceQuitOffered)
                : "Process PID \(pid) is still there after SIGKILL, usually because it is stuck waiting on the system. Activity Monitor can show it."
        case .alreadyExited:
            return "Process PID \(pid) had already exited. Nothing was sent."
        case .identityChanged:
            return "PID \(pid) now belongs to a different process. Nothing was sent."
        case .denied(let reason):
            return "HeatLens didn't send \(name): \(reason)"
        case .failed(let errno):
            return "HeatLens couldn't send \(name) to PID \(pid) (error \(errno)). Nothing else was changed."
        }
    }

    /// A short row status for the same outcome, e.g. "stopped", "skipped: it changed".
    static func status(for outcome: StopOutcome, signal: StopSignal = .sigterm) -> String {
        switch outcome {
        case .stopped: signal == .sigterm ? "stopped" : "force quit"
        case .stillRunning: "still running"
        case .alreadyExited: "already gone"
        case .identityChanged: "skipped: it changed"
        case .denied: "skipped: not allowed"
        case .failed(let errno): "couldn't send (error \(errno))"
        }
    }
}
