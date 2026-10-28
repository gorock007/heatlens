import Darwin
import Foundation

/// What one `ContainerStopping.stop` call did (ADR-0007).
public enum ContainerStopOutcome: Equatable, Sendable {
    /// The Engine answered 204: the container stopped (after its stop signal, or the Engine's
    /// own force after the timeout).
    case stopped
    /// HeatLens's wait (`t` + 5 s) ran out; Docker is still stopping it. Never retried.
    case stillStopping
    /// Not running at the inspect, or the Engine answered 304. Nothing was stopped.
    case alreadyStopped
    /// The Engine no longer has a container with this ID (404).
    case gone
    /// The ID now answers with a different name or creation time; nothing was sent.
    case identityChanged
    /// A rule refused the stop; nothing was sent. `reason` is plain words for the UI.
    case denied(reason: String)
    /// The Engine or the socket failed; `message` is redacted and at most 200 characters.
    case failed(message: String)

    /// The case name an `ActionRecord` stores.
    public var caseName: String {
        switch self {
        case .stopped: "stopped"
        case .stillStopping: "stillStopping"
        case .alreadyStopped: "alreadyStopped"
        case .gone: "gone"
        case .identityChanged: "identityChanged"
        case .denied: "denied"
        case .failed: "failed"
        }
    }

    var recordDetail: String? {
        switch self {
        case .denied(let reason): reason
        case .failed(let message): message
        case .stopped, .stillStopping, .alreadyStopped, .gone, .identityChanged: nil
        }
    }
}

/// Whether the UI may offer "Stop container…" (ADR-0007 decision 5).
public enum ContainerStopEligibility: Equatable, Sendable {
    case eligible
    /// The container or its project matches a Settings exclusion.
    case excluded
    /// `reason` is plain words the UI shows where the button would be.
    case denied(reason: String)

    /// One "never offered" rule: a prefix of a label key, the name or the image.
    public struct Rule: Equatable, Sendable {
        public enum Field: Sendable { case labelKey, name, image }
        public let field: Field
        public let prefix: String
        public let reason: String
    }

    static let desktopReason = "This container belongs to Docker Desktop itself (an extension or a helper). HeatLens never stops it."
    static let devEnvironmentReason = "This is a Docker Dev Environment. Manage it from Docker Desktop."
    static let kubernetesReason = "This container is part of Kubernetes in Docker Desktop. HeatLens never stops it."
    static let buildxReason = "This is a buildx builder that Docker manages. HeatLens never stops it."

    /// Docker Desktop's own containers, Dev Environments, Kubernetes pods, buildx builders.
    public static let neverOffered: [Rule] = [
        Rule(field: .labelKey, prefix: "com.docker.desktop.", reason: desktopReason),
        Rule(field: .labelKey, prefix: "io.docker.desktop.", reason: desktopReason),
        Rule(field: .labelKey, prefix: "com.docker.dev-environments.", reason: devEnvironmentReason),
        Rule(field: .labelKey, prefix: "io.kubernetes.", reason: kubernetesReason),
        Rule(field: .name, prefix: "k8s_", reason: kubernetesReason),
        Rule(field: .name, prefix: "buildx_buildkit_", reason: buildxReason),
        Rule(field: .image, prefix: "moby/buildkit", reason: buildxReason),
    ]

    static let notRunningReason = "This container isn't running, so there is nothing to stop."

    /// Pure. The same rules run on the scan's container (offer) and on the inspect response
    /// right before the call, so a label the list didn't show still protects the container.
    public static func evaluate(name: String, image: String, state: String, labels: [String: String],
                                projectDirectory: String?, exclusions: ExclusionFilter) -> Self {
        guard state == "running" else { return .denied(reason: notRunningReason) }
        for rule in neverOffered {
            let matches = switch rule.field {
            case .labelKey: labels.keys.contains { $0.hasPrefix(rule.prefix) }
            case .name: name.hasPrefix(rule.prefix)
            case .image: image.hasPrefix(rule.prefix)
            }
            if matches { return .denied(reason: rule.reason) }
        }
        let workingDirectory = labels["com.docker.compose.project.working_dir"]
        if exclusions.excludes(processName: name, projectDirectory: projectDirectory)
            || exclusions.excludes(processName: nil, projectDirectory: workingDirectory) {
            return .excluded
        }
        return .eligible
    }
}

/// The container the user confirmed, as the scan listed it. Built only from a scan result.
public struct ContainerStopTarget: Equatable, Sendable {
    /// The full 64-hex ID; nothing else addresses the container.
    public let containerID: String
    /// Without the leading `/`.
    public let name: String
    public let image: String
    /// From the list, at whole-second precision.
    public let createdAt: Date
    public let composeProject: String?
    /// The attributed project's name, for the record.
    public let projectName: String?
    /// The attributed project's directory, for the exclusion re-check; never recorded.
    public let projectDirectory: String?
    public let exclusions: ExclusionFilter

    public init(containerID: String, name: String, image: String, createdAt: Date, composeProject: String?,
                projectName: String?, projectDirectory: String? = nil, exclusions: ExclusionFilter = ExclusionFilter()) {
        self.containerID = containerID
        self.name = name
        self.image = image
        self.createdAt = createdAt
        self.composeProject = composeProject
        self.projectName = projectName
        self.projectDirectory = projectDirectory
        self.exclusions = exclusions
    }

    public init(container: ContainerSample, project: Project?, exclusions: ExclusionFilter) {
        self.init(containerID: container.containerID, name: container.name, image: container.image, createdAt: container.createdAt,
                  composeProject: container.composeProject, projectName: project?.name, projectDirectory: project?.root,
                  exclusions: exclusions)
    }

    var shortID: String { String(containerID.prefix(12)) }
}

/// What the confirmation states, read from a fresh inspect (ADR-0007 decision 2).
public struct ContainerStopPlan: Equatable, Sendable {
    /// e.g. `SIGTERM`; the image's own `StopSignal` when it sets one.
    public let stopSignal: String
    /// The `t` HeatLens sends: the container's `StopTimeout`, else 10, capped at 120.
    public let timeoutSeconds: Int
    /// e.g. `always`, `unless-stopped`; nil for `no` or none.
    public let restartPolicy: String?
}

/// Before the confirmation: either what a stop would do, or why it can't happen.
public enum ContainerStopPreview: Equatable, Sendable {
    case ready(ContainerStopPlan)
    /// What `stop` would return without sending anything.
    case unavailable(ContainerStopOutcome)
}

/// Stops one explicitly selected container, the way `docker stop` does (ADR-0007).
public protocol ContainerStopping: Sendable {
    /// Pure: whether the UI may offer "Stop container…" for a scan's container.
    func eligibility(of container: ContainerSample, project: Project?, exclusions: ExclusionFilter) -> ContainerStopEligibility
    /// GET only: the identity check and the plan the confirmation shows. Not recorded.
    func preview(_ target: ContainerStopTarget) async -> ContainerStopPreview
    /// Inspect, re-check identity and eligibility, then one stop request. Every attempt is
    /// recorded in the ledger, sent or refused.
    func stop(_ target: ContainerStopTarget, context: ActionContext?) async -> ContainerStopOutcome
}

extension ContainerStopping {
    public func stop(_ target: ContainerStopTarget) async -> ContainerStopOutcome {
        await stop(target, context: nil)
    }
}

/// "Allow stopping a container" is off: never opens the socket and holds no transport.
public struct DisabledContainerStopper: ContainerStopping {
    static let reason = "Stopping containers is turned off in Settings."

    private let ledger: StopLedger?

    public init(ledger: StopLedger? = nil) {
        self.ledger = ledger
    }

    public func eligibility(of container: ContainerSample, project: Project?, exclusions: ExclusionFilter) -> ContainerStopEligibility {
        .denied(reason: Self.reason)
    }

    public func preview(_ target: ContainerStopTarget) async -> ContainerStopPreview {
        .unavailable(.denied(reason: Self.reason))
    }

    public func stop(_ target: ContainerStopTarget, context: ActionContext?) async -> ContainerStopOutcome {
        let outcome = ContainerStopOutcome.denied(reason: Self.reason)
        await ledger?.record(ContainerAttempt(outcome: outcome).record(target, context))
        return outcome
    }
}

/// The one type that can send a POST to the Docker Engine (ADR-0007). One stop at a time.
///
/// Invariants: the container is addressed only by its full ID; its `Id`, name and creation
/// second are re-read by inspect immediately before the call, with the eligibility rules run
/// again on that response; exactly one `stop` request per call, never retried; the request
/// goes only through a user-owned Docker Desktop socket (`DockerSocketLocator.stopPolicy`).
public actor ContainerStopper: ContainerStopping {
    /// The Engine's default when the container sets no `StopTimeout`.
    static let defaultStopTimeout = 10
    static let anotherStopReason = "Another container is being stopped. Wait for it to finish."

    private let transport: (any DockerTransport)?
    /// Why this socket can't carry a stop; set exactly when `transport` is nil.
    private let refusal: String?
    private let ledger: StopLedger?
    /// HeatLens waits `t` plus this for the Engine's answer.
    private let deadlineMargin: TimeInterval
    private var inFlight = false

    /// Finds the socket the reads use and applies the stop policy to it. A refused socket is
    /// never opened; `eligibility` and `stop` then give the reason.
    public init(ledger: StopLedger?, environment: [String: String] = ProcessInfo.processInfo.environment,
                home: String = NSHomeDirectory()) {
        switch DockerSocketLocator.locate(environment: environment, home: home) {
        case .failure:
            self.init(transport: nil, refusal: "HeatLens can't reach Docker right now, so it can't stop the container.", ledger: ledger)
        case .success(let path):
            switch DockerSocketLocator.stopPolicy(for: path, environment: environment, home: home) {
            case .success(let socket):
                self.init(transport: UnixSocketTransport(socketPath: socket), refusal: nil, ledger: ledger)
            case .failure(let refusal):
                self.init(transport: nil, refusal: refusal.reason, ledger: ledger)
            }
        }
    }

    init(transport: (any DockerTransport)?, refusal: String? = nil, ledger: StopLedger?, deadlineMargin: TimeInterval = 5) {
        self.transport = transport
        self.refusal = transport == nil ? (refusal ?? "HeatLens can't reach Docker right now, so it can't stop the container.") : nil
        self.ledger = ledger
        self.deadlineMargin = deadlineMargin
    }

    public nonisolated func eligibility(of container: ContainerSample, project: Project?,
                                        exclusions: ExclusionFilter) -> ContainerStopEligibility {
        let rules = ContainerStopEligibility.evaluate(name: container.name, image: container.image, state: container.state,
                                                      labels: container.labels, projectDirectory: project?.root,
                                                      exclusions: exclusions)
        if rules == .eligible, let refusal { return .denied(reason: refusal) }
        return rules
    }

    public func preview(_ target: ContainerStopTarget) async -> ContainerStopPreview {
        guard let transport else { return .unavailable(.denied(reason: refusal ?? "")) }
        return await Self.offActor {
            switch Self.prepare(target, transport: transport) {
            case .success(let prepared): .ready(prepared.plan)
            case .failure(let attempt): .unavailable(attempt.outcome)
            }
        }
    }

    public func stop(_ target: ContainerStopTarget, context: ActionContext?) async -> ContainerStopOutcome {
        let attempt: ContainerAttempt
        if inFlight {
            attempt = ContainerAttempt(outcome: .denied(reason: Self.anotherStopReason))
        } else if let transport {
            inFlight = true
            let margin = deadlineMargin
            attempt = await Self.offActor { Self.stopOnce(target, transport: transport, deadlineMargin: margin) }
            inFlight = false
        } else {
            attempt = ContainerAttempt(outcome: .denied(reason: refusal ?? ""))
        }
        await ledger?.record(attempt.record(target, context))
        return attempt.outcome
    }

    /// The socket calls block for up to `t` + 5 s, so they run on a dispatch queue rather than
    /// on the actor or the cooperative pool. The actor stays free to refuse a second stop.
    private static func offActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    // MARK: The sequence (blocking; off the actor)

    struct Prepared {
        let api: DockerAPIVersion
        let id: DockerContainerID
        let plan: ContainerStopPlan
    }

    /// Version, inspect by full ID, identity, state and eligibility on the inspect response.
    /// GET requests only.
    static func prepare(_ target: ContainerStopTarget, transport: any DockerTransport) -> Result<Prepared, ContainerAttempt> {
        guard let id = DockerContainerID(target.containerID), id.isFull else {
            return .failure(ContainerAttempt(outcome: .denied(reason: "HeatLens needs the container's full ID to stop it.")))
        }
        let api: DockerAPIVersion
        do {
            let version = try decode(DockerVersionResponse.self, try transport.get(DockerEndpoint.version.path))
            guard let negotiated = DockerAPIVersion(version.ApiVersion), negotiated >= DockerAPIVersion.minimum else {
                return .failure(ContainerAttempt(outcome: .failed(message: "This Docker Engine's API (\(version.ApiVersion)) is older than HeatLens supports.")))
            }
            api = negotiated
        } catch {
            return .failure(ContainerAttempt(outcome: .failed(message: message(for: error))))
        }

        let inspect: DockerContainerInspect
        do {
            let response = try transport.get(DockerEndpoint.inspect(api: api, id: id).path)
            if response.status == 404 { return .failure(ContainerAttempt(outcome: .gone)) }
            inspect = try decode(DockerContainerInspect.self, response)
        } catch {
            return .failure(ContainerAttempt(outcome: .failed(message: message(for: error))))
        }

        // The same container instance: the ID, the name and the creation second all match.
        guard inspect.Id == id.value, inspect.name == target.name,
              inspect.createdSeconds == Int64(target.createdAt.timeIntervalSince1970.rounded(.down)) else {
            return .failure(ContainerAttempt(outcome: .identityChanged))
        }
        guard inspect.State.Status == "running" else { return .failure(ContainerAttempt(outcome: .alreadyStopped)) }
        switch ContainerStopEligibility.evaluate(name: inspect.name, image: target.image, state: inspect.State.Status,
                                                 labels: inspect.Config?.Labels ?? [:], projectDirectory: target.projectDirectory,
                                                 exclusions: target.exclusions) {
        case .eligible: break
        case .excluded:
            return .failure(ContainerAttempt(outcome: .denied(reason: "This container is excluded in Settings, so nothing was sent.")))
        case .denied(let reason):
            return .failure(ContainerAttempt(outcome: .denied(reason: reason)))
        }
        return .success(Prepared(api: api, id: id, plan: plan(for: inspect)))
    }

    static func plan(for inspect: DockerContainerInspect) -> ContainerStopPlan {
        let range = DockerEndpoint.stopTimeoutRange
        // A negative StopTimeout means "never force"; the closest bounded wait is the cap.
        let timeout = inspect.Config?.StopTimeout.map { $0 < 0 ? range.upperBound : min($0, range.upperBound) } ?? defaultStopTimeout
        let signal = inspect.Config?.StopSignal.flatMap { $0.isEmpty ? nil : $0 } ?? "SIGTERM"
        let restart = inspect.HostConfig?.RestartPolicy?.Name.flatMap { $0.isEmpty || $0 == "no" ? nil : $0 }
        return ContainerStopPlan(stopSignal: signal, timeoutSeconds: timeout, restartPolicy: restart)
    }

    /// `prepare`, then exactly one stop request; a deadline is reported, never retried.
    static func stopOnce(_ target: ContainerStopTarget, transport: any DockerTransport,
                         deadlineMargin: TimeInterval) -> ContainerAttempt {
        let prepared: Prepared
        switch prepare(target, transport: transport) {
        case .success(let value): prepared = value
        case .failure(let refused): return refused
        }
        let timeout = prepared.plan.timeoutSeconds
        let path = DockerEndpoint.stop(api: prepared.api, id: prepared.id, timeout: timeout).path
        let sentAt = Date()
        do {
            let response = try transport.post(path, timeout: TimeInterval(timeout) + deadlineMargin)
            switch response.status {
            case 204: return ContainerAttempt(outcome: .stopped, signalSentAt: sentAt)
            case 304: return ContainerAttempt(outcome: .alreadyStopped, signalSentAt: sentAt)
            case 404: return ContainerAttempt(outcome: .gone, signalSentAt: sentAt)
            default:
                return ContainerAttempt(outcome: .failed(message: engineMessage(response)), signalSentAt: sentAt)
            }
        } catch UnixSocketHTTP.Failure.timedOut {
            // Docker keeps stopping after HeatLens stops waiting; re-list to see where it is.
            return ContainerAttempt(outcome: relisted(prepared, transport: transport), signalSentAt: sentAt)
        } catch {
            let nothingSent = switch error {
            case UnixSocketHTTP.Failure.connectFailed, UnixSocketHTTP.Failure.invalidPath, UnixSocketHTTP.Failure.socketPathTooLong: true
            default: false
            }
            return ContainerAttempt(outcome: .failed(message: message(for: error)), signalSentAt: nothingSent ? nil : sentAt)
        }
    }

    /// After the deadline: `.stopped` if the list no longer shows it running, else `.stillStopping`.
    static func relisted(_ prepared: Prepared, transport: any DockerTransport) -> ContainerStopOutcome {
        guard let list = try? decode([DockerContainerSummary].self, transport.get(DockerEndpoint.containers(api: prepared.api).path)) else {
            return .stillStopping
        }
        let running = list.contains { $0.Id == prepared.id.value && $0.State == "running" }
        return running ? .stillStopping : .stopped
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ response: UnixSocketHTTP.Response) throws -> T {
        guard response.status == 200 else { throw DockerEngineError.status(response.status) }
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw DockerEngineError.badJSON
        }
    }

    /// The Engine's `{"message": …}`, redacted and capped; else the status.
    static func engineMessage(_ response: UnixSocketHTTP.Response) -> String {
        struct EngineError: Decodable { let message: String }
        let text = (try? JSONDecoder().decode(EngineError.self, from: response.body))?.message
        return clean("Docker Engine answered HTTP \(response.status)" + (text.map { ": \($0)" } ?? ""))
    }

    static func message(for error: Error) -> String {
        switch error {
        case UnixSocketHTTP.Failure.connectFailed(let code) where code == ENOENT:
            return "Docker isn't running (no socket)."
        case UnixSocketHTTP.Failure.connectFailed(let code) where code == EACCES || code == EPERM:
            return "macOS refused HeatLens access to the Docker socket."
        case UnixSocketHTTP.Failure.connectFailed(let code) where code == ECONNREFUSED:
            return "Docker didn't answer."
        case UnixSocketHTTP.Failure.timedOut:
            return "Docker didn't answer in time."
        case DockerEngineError.status(let status):
            return "Docker Engine answered HTTP \(status)"
        case DockerEngineError.badJSON:
            return "Docker Engine sent a response HeatLens couldn't read"
        case UnixSocketHTTP.Failure.responseTooLarge:
            return "Docker Engine response was too large"
        default:
            return clean("\(error)")
        }
    }

    static func clean(_ text: String) -> String {
        ActionRecord.cap(ActionRecord.redacted(text), ActionRecord.detailLimit)
    }
}

/// What one container stop attempt did, before it becomes an `ActionRecord`.
struct ContainerAttempt: Error {
    let outcome: ContainerStopOutcome
    /// When the stop request left HeatLens; nil when nothing was sent.
    let signalSentAt: Date?

    init(outcome: ContainerStopOutcome, signalSentAt: Date? = nil) {
        self.outcome = outcome
        self.signalSentAt = signalSentAt
    }

    func record(_ target: ContainerStopTarget, _ context: ActionContext?) -> ActionRecord {
        ActionRecord(at: signalSentAt ?? Date(), action: .containerStop,
                     target: .container(shortID: target.shortID, name: target.name, image: target.image,
                                        composeProject: target.composeProject),
                     projectName: context?.projectName ?? target.projectName, origin: context?.origin,
                     confirmedAt: context?.confirmedAt, signalSentAt: signalSentAt, outcome: outcome.caseName,
                     detail: outcome.recordDetail)
    }
}
