import Darwin
import Foundation

/// One stop or force-quit attempt, sent or refused (ADR-0006 §Audit record). Phase 3e persists
/// these. It carries no argv, no environment and no path; the project appears by name only.
public struct ActionRecord: Identifiable, Equatable, Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// SIGTERM, from `ProcessTerminator.requestStop`.
        case stopRequested
        /// The kill signal, from `ProcessTerminator.forceQuit`.
        case forceQuit
        /// ADR-0007.
        case containerStop
    }

    public enum Target: Equatable, Codable, Sendable {
        case process(pid: Int32, startTimeMicros: Int64, name: String)
        case container(shortID: String, name: String, image: String, composeProject: String?)
    }

    /// Where in the app the user confirmed the action.
    public enum Origin: String, Codable, Sendable {
        case processDetail, leftoverCard, batchStop, containerDetail
    }

    /// Names and images are cut to this many characters.
    public static let nameLimit = 80
    /// `detail` is cut to this many characters.
    public static let detailLimit = 200

    public let id: UUID
    /// When the action was decided: the signal was sent, or it was refused.
    public let at: Date
    public let action: Action
    public let target: Target
    /// The attributed project's name, never its directory.
    public let projectName: String?
    /// nil when the caller gave no `ActionContext` (engine tests).
    public let origin: Origin?
    /// When the user pressed the destructive button; nil without an `ActionContext`.
    public let confirmedAt: Date?
    /// When the signal or request left HeatLens; nil when it was refused.
    public let signalSentAt: Date?
    /// The outcome's case name, e.g. `stillRunning`.
    public let outcome: String
    /// The reason for `denied`/`failed`, redacted and capped; nil otherwise.
    public let detail: String?

    /// Caps every name and redacts `detail`, so no caller can store more than §Audit record allows.
    public init(id: UUID = UUID(), at: Date, action: Action, target: Target, projectName: String?,
                origin: Origin?, confirmedAt: Date?, signalSentAt: Date?, outcome: String, detail: String?) {
        self.id = id
        self.at = at
        self.action = action
        self.target = target.capped
        self.projectName = projectName.map { Self.cap($0, Self.nameLimit) }
        self.origin = origin
        self.confirmedAt = confirmedAt
        self.signalSentAt = signalSentAt
        self.outcome = outcome
        self.detail = detail.map { Self.cap(Self.redacted($0), Self.detailLimit) }
    }

    /// The process this record is about, or nil for a container.
    public var processIdentity: ProcessIdentity? {
        guard case .process(let pid, let start, _) = target else { return nil }
        return ProcessIdentity(pid: pid, startTimeMicros: start)
    }

    static func cap(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }

    /// The home directory, the user name and secret-looking options, the same rules the
    /// report redactor applies. Its sanitizer is private to `Redactor.swift`, so this repeats
    /// the parts a reason text can contain.
    static func redacted(_ raw: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var value = raw
        let home = homeDirectory.count > 1 && homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if home.count > 1 {
            value = value == home ? "~" : value.replacingOccurrences(of: home + "/", with: "~/")
            let username = (home as NSString).lastPathComponent
            if !username.isEmpty {
                let pattern = RedactionPatterns.compile("(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: username) + "(?![A-Za-z0-9_])",
                                                        caseInsensitive: true)
                value = RedactionPatterns.replacing(pattern, in: value, with: "<user>")
            }
        }
        value = RedactionPatterns.replacing(RedactionPatterns.secretFlag, in: value, with: "<secret redacted>")
        return RedactionPatterns.replacing(RedactionPatterns.secretAssignment, in: value, with: "<secret redacted>")
    }
}

extension ActionRecord.Target {
    var capped: Self {
        let cap = { (text: String) in ActionRecord.cap(text, ActionRecord.nameLimit) }
        switch self {
        case .process(let pid, let start, let name):
            return .process(pid: pid, startTimeMicros: start, name: cap(name))
        case .container(let shortID, let name, let image, let project):
            return .container(shortID: String(shortID.prefix(12)), name: cap(name), image: cap(image), composeProject: project.map(cap))
        }
    }
}

/// What the app knows about a confirmed action that the engine doesn't; it goes into the record.
public struct ActionContext: Sendable {
    public let origin: ActionRecord.Origin
    /// The name shown in the confirmation; the record uses the kernel's name when it can read one.
    public let processName: String?
    public let projectName: String?
    public let confirmedAt: Date

    public init(origin: ActionRecord.Origin, processName: String? = nil, projectName: String? = nil, confirmedAt: Date) {
        self.origin = origin
        self.processName = processName
        self.projectName = projectName
        self.confirmedAt = confirmedAt
    }
}

extension StopOutcome {
    /// The case name an `ActionRecord` stores.
    public var caseName: String {
        switch self {
        case .stopped: "stopped"
        case .stillRunning: "stillRunning"
        case .alreadyExited: "alreadyExited"
        case .identityChanged: "identityChanged"
        case .denied: "denied"
        case .failed: "failed"
        }
    }

    /// The reason text an `ActionRecord` stores, for `denied` and `failed` only.
    var recordDetail: String? {
        switch self {
        case .denied(let reason): reason
        case .failed(let code): "\(String(cString: strerror(code))) (errno \(code))"
        case .stopped, .stillRunning, .alreadyExited, .identityChanged: nil
        }
    }
}

/// Every stop and force-quit attempt in this app session, in memory only (ADR-0006 decision 2).
/// `ProcessTerminator.forceQuit` reads it: no recorded SIGTERM for the same identity, no force
/// quit. Entries older than `retention` are dropped.
public actor StopLedger {
    public static let retention: TimeInterval = 10 * 60

    private var entries: [ActionRecord] = []

    public init() {}

    public func record(_ record: ActionRecord) {
        prune()
        entries.append(record)
    }

    /// When the newest SIGTERM that actually left HeatLens for exactly this identity was sent.
    public func stopRequestedAt(_ identity: ProcessIdentity) -> Date? {
        prune()
        return entries.last { $0.action == .stopRequested && $0.processIdentity == identity && $0.signalSentAt != nil }?.signalSentAt
    }

    /// Records decided at or after `date`, oldest first.
    public func records(since date: Date) -> [ActionRecord] {
        prune()
        return entries.filter { $0.at >= date }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        entries.removeAll { $0.at < cutoff }
    }
}
