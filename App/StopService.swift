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
    /// The one ledger for the app session, shared by single and batch stops and container stops;
    /// `forceQuit` needs the SIGTERM it recorded.
    private let ledger: StopLedger
    /// The Settings switch, read on the main actor right before a force quit.
    private let forceQuitAllowed: @MainActor @Sendable () -> Bool

    init(ledger: StopLedger, forceQuitAllowed: @escaping @MainActor @Sendable () -> Bool) {
        self.ledger = ledger
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

// MARK: - Containers (docs/v2/ADR-0007)

/// Hands out the container stopper for one container detail and its confirmation.
protocol ContainerStopProviding: Sendable {
    /// Docker and "Allow stopping a container" are both on in Settings.
    @MainActor var isEnabled: Bool { get }
    /// Chosen now, from Settings: the stopper that can POST only while the switch is on.
    @MainActor func stopper() -> any ContainerStopping
}

struct ContainerStopService: ContainerStopProviding {
    /// The same ledger as `TerminatorStopService`, so every stop of the session is in one place.
    let ledger: StopLedger
    let enabled: @MainActor @Sendable () -> Bool

    @MainActor var isEnabled: Bool { enabled() }

    /// While the switch is off the type that can send a POST is never constructed.
    @MainActor func stopper() -> any ContainerStopping {
        enabled() ? ContainerStopper(ledger: ledger) : DisabledContainerStopper(ledger: ledger)
    }
}

/// Preview-only: honours the Settings switch, applies the real eligibility rules to the fixture
/// containers, and never opens a socket.
struct FixtureContainerStopService: ContainerStopProviding {
    let enabled: @MainActor @Sendable () -> Bool

    @MainActor var isEnabled: Bool { enabled() }

    @MainActor func stopper() -> any ContainerStopping {
        enabled() ? FixtureContainerStopper() : DisabledContainerStopper()
    }
}

/// Every eligible fixture container stops after half a second; `demo-db-1` reports a restart policy.
struct FixtureContainerStopper: ContainerStopping {
    func eligibility(of container: ContainerSample, project: Project?, exclusions: ExclusionFilter) -> ContainerStopEligibility {
        ContainerStopEligibility.evaluate(name: container.name, image: container.image, state: container.state,
                                          labels: container.labels, projectDirectory: project?.root, exclusions: exclusions)
    }

    /// Unused: `ContainerStopPlan` can't be built outside HeatLensCore, so `ContainerSelection.terms`
    /// asks `terms(for:)` instead.
    func preview(_ target: ContainerStopTarget) async -> ContainerStopPreview {
        .unavailable(.denied(reason: "Fixture stopper"))
    }

    func terms(for target: ContainerStopTarget) async -> ContainerStopTerms {
        try? await Task.sleep(for: .milliseconds(300))
        return ContainerStopTerms(stopSignal: "SIGTERM", timeoutSeconds: 10,
                                  restartPolicy: target.name == "demo-db-1" ? "unless-stopped" : nil)
    }

    func stop(_ target: ContainerStopTarget, context: ActionContext?) async -> ContainerStopOutcome {
        try? await Task.sleep(for: .milliseconds(500))
        return .stopped
    }
}

/// One container from a scan result, with the stopper chosen when its detail opened.
struct ContainerSelection: Identifiable {
    var id: String { container.containerID }
    let container: ContainerSample
    let attribution: ContainerAttribution?
    /// e.g. "28.5.1", from the scan's Docker reading.
    let engineVersion: String?
    /// Settings allowed stopping when the detail opened; `stopper` is the disabled one otherwise.
    let isStopEnabled: Bool
    let stopper: any ContainerStopping

    var project: Project? { attribution?.project }

    /// The GET-only preview, as the confirmation's terms, or what `stop` would return instead.
    func terms(exclusions: ExclusionFilter) async -> Result<ContainerStopTerms, ContainerStopRefusal> {
        let target = target(exclusions: exclusions)
        if let fixture = stopper as? FixtureContainerStopper { return .success(await fixture.terms(for: target)) }
        switch await stopper.preview(target) {
        case .ready(let plan): return .success(ContainerStopTerms(plan))
        case .unavailable(let outcome): return .failure(ContainerStopRefusal(outcome: outcome))
        }
    }

    func target(exclusions: ExclusionFilter) -> ContainerStopTarget {
        ContainerStopTarget(container: container, project: project, exclusions: exclusions)
    }

    /// The record's context, with `confirmedAt` the moment the user pressed Stop container.
    func context(confirmedAt: Date = Date()) -> ActionContext {
        ActionContext(origin: .containerDetail, projectName: project?.name, confirmedAt: confirmedAt)
    }
}

/// What the confirmation states: the app's copy of `ContainerStopPlan`, whose initializer is
/// internal to HeatLensCore, so previews can build one too.
struct ContainerStopTerms: Equatable {
    let stopSignal: String
    let timeoutSeconds: Int
    let restartPolicy: String?

    init(stopSignal: String, timeoutSeconds: Int, restartPolicy: String?) {
        self.stopSignal = stopSignal
        self.timeoutSeconds = timeoutSeconds
        self.restartPolicy = restartPolicy
    }

    init(_ plan: ContainerStopPlan) {
        self.init(stopSignal: plan.stopSignal, timeoutSeconds: plan.timeoutSeconds, restartPolicy: plan.restartPolicy)
    }
}

/// A preview that found nothing can be sent.
struct ContainerStopRefusal: Error {
    let outcome: ContainerStopOutcome
}

/// Container stop words, shared by the detail view and the confirmation.
enum ContainerStopWording {
    static let turnOn = "Turn on “Allow stopping a container” in Settings to stop it from here."
    static let turnOnDocker = "Turn on “Docker containers” and “Allow stopping a container” in Settings to stop it from here."

    /// ADR-0007 decision 2, with the signal and timeout from the inspect.
    static func explanation(_ plan: ContainerStopTerms) -> String {
        "Docker sends \(plan.stopSignal) to the container's main process and, if it is still running after \(plan.timeoutSeconds) s, force-kills it (the same as `docker stop`). Data the container hasn't written yet can be lost. It stays stopped until something starts it again (`docker start`, `docker compose up`); other containers in the same Compose project keep running."
    }

    static func restartPolicy(_ plan: ContainerStopTerms) -> String? {
        plan.restartPolicy.map { "Restart policy: \($0); it stays stopped after an explicit stop." }
    }

    /// e.g. "Docker Desktop · Engine 28.5.1, on this Mac". Stops go only through Docker Desktop's socket.
    static func engine(_ version: String?) -> String {
        "Docker Desktop · Engine \(version ?? "version unknown"), on this Mac"
    }

    /// The full sentence after one stop (or a preview that found it can't happen).
    static func message(for outcome: ContainerStopOutcome, name: String) -> String {
        switch outcome {
        case .stopped:
            "Docker stopped \(name)."
        case .stillStopping:
            "Docker is still stopping \(name). HeatLens stopped waiting and sent nothing else; scan again to see where it is."
        case .alreadyStopped:
            "\(name) isn't running any more. Nothing was stopped."
        case .gone:
            "Docker no longer has \(name). Nothing was stopped."
        case .identityChanged:
            "\(name) is now a different container (it was recreated since the scan). Nothing was sent; scan again first."
        case .denied(let reason):
            "HeatLens didn't stop \(name): \(reason)"
        case .failed(let message):
            "HeatLens couldn't stop \(name): \(sentence(message)) Scan again to see its state."
        }
    }

    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") ? text : text + "."
    }
}
