import Foundation

/// What a power assertion stops macOS from doing, in plain words.
public enum SleepEffect: String, Hashable, Codable, Sendable {
    /// No sleep from inactivity; the display may still dim and turn off.
    case preventsIdleSleep
    /// No system sleep (on AC power; on battery it still blocks idle sleep).
    case preventsSleep
    /// The display stays on, which also keeps the Mac from idle sleep.
    case keepsDisplayOn

    /// The `AssertType` values IOPMLib.h says block sleep; nil for every other type (UserIsActive,
    /// BackgroundTask, PreventDiskIdle, ExternalMedia, Apple-internal types, …).
    public init?(assertionType: String) {
        switch assertionType {
        case "PreventUserIdleSystemSleep", "NoIdleSleepAssertion": self = .preventsIdleSleep
        case "PreventSystemSleep", "NetworkClientActive": self = .preventsSleep
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": self = .keepsDisplayOn
        default: return nil
        }
    }

    /// "Prevents idle sleep", "Prevents sleep", "Keeps the display on".
    public var label: String {
        switch self {
        case .preventsIdleSleep: "Prevents idle sleep"
        case .preventsSleep: "Prevents sleep"
        case .keepsDisplayOn: "Keeps the display on"
        }
    }

    /// "preventing idle sleep", for sentences.
    public var gerund: String {
        switch self {
        case .preventsIdleSleep: "preventing idle sleep"
        case .preventsSleep: "preventing sleep"
        case .keepsDisplayOn: "keeping the display on"
        }
    }

    /// Strongest first: what blocks the most sleep leads a combined sentence.
    static let strongestFirst: [SleepEffect] = [.preventsSleep, .keepsDisplayOn, .preventsIdleSleep]
}

/// One sleep-blocking power assertion, read with `IOPMCopyAssertionsByProcess`.
public struct PowerAssertion: Hashable, Codable, Sendable {
    /// The raw `AssertType`, e.g. "PreventUserIdleSystemSleep".
    public let type: String
    /// `AssertName` as the holder set it. It can hold personal text (a track title, a URL, a
    /// file path); exports pass it through `Redactor`, the app shows it as is.
    public let name: String
    /// `AssertStartWhen`, when present.
    public let startedAt: Date?
    /// `TimeoutSeconds`, when the holder set one.
    public let timeoutSeconds: TimeInterval?
    /// The process that created the assertion on this one's behalf (coreaudiod for audio
    /// playback); nil when the process holds its own.
    public let createdByPID: Int32?

    public init(type: String, name: String, startedAt: Date? = nil, timeoutSeconds: TimeInterval? = nil,
                createdByPID: Int32? = nil) {
        self.type = type
        self.name = name
        self.startedAt = startedAt
        self.timeoutSeconds = timeoutSeconds
        self.createdByPID = createdByPID
    }

    /// `Evidence.source` of a finding's assertion lines; `Redactor` cleans their names like the report's.
    public static let evidenceSource = "IOPMCopyAssertionsByProcess"

    /// nil only for a type this build doesn't treat as blocking sleep (never sampled, but JSON
    /// from elsewhere may hold one).
    public var effect: SleepEffect? { SleepEffect(assertionType: type) }

    /// Seconds held at `now`; nil without a start time.
    public func heldSeconds(at now: Date) -> TimeInterval? {
        startedAt.map { max(0, now.timeIntervalSince($0)) }
    }

    /// "under 1 min", "12 min", "3 h 12 min", "2 d 5 h".
    public static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "under 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h \(minutes % 60) min" }
        return "\(hours / 24) d \(hours % 24) h"
    }
}

/// The sleep-blocking assertions one process instance holds, as stored in
/// `ScanSnapshot.powerAssertions`.
public struct ProcessPowerAssertions: Hashable, Codable, Sendable {
    public let identity: ProcessIdentity
    /// Oldest first; assertions without a start time last.
    public let assertions: [PowerAssertion]

    public init(identity: ProcessIdentity, assertions: [PowerAssertion]) {
        self.identity = identity
        self.assertions = assertions
    }
}

/// One row of the "Keeping your Mac awake" list: an assertion and the process it belongs to,
/// tied to its group.
public struct PowerAssertionListing: Hashable, Sendable, Identifiable {
    public var id: String { "\(identity.pid)-\(identity.startTimeMicros)-\(index)" }
    public let assertion: PowerAssertion
    public let identity: ProcessIdentity
    public let processName: String
    /// The name of `assertion.createdByPID`'s process, when it is in the snapshot.
    public let createdByName: String?
    /// The group the process belongs to, nil when the resolver didn't group it.
    public let group: ProcessGroup?
    /// Position in the process's own list, so two identical assertions stay distinct rows.
    let index: Int

    /// One row per assertion, oldest first (no start time last), then by PID.
    public static func listings(_ snapshot: ScanSnapshot, groups: [ProcessGroup]) -> [PowerAssertionListing] {
        let names = Dictionary(snapshot.processes.map { ($0.identity, $0.name) }, uniquingKeysWith: { first, _ in first })
        let namesByPID = Dictionary(snapshot.processes.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
        var groupOf: [ProcessIdentity: ProcessGroup] = [:]
        for group in groups {
            for member in group.members where groupOf[member] == nil { groupOf[member] = group }
        }
        return snapshot.powerAssertions.flatMap { entry in
            entry.assertions.enumerated().map { index, assertion in
                PowerAssertionListing(assertion: assertion, identity: entry.identity,
                                      processName: names[entry.identity] ?? "PID \(entry.identity.pid)",
                                      createdByName: assertion.createdByPID.flatMap { namesByPID[$0] },
                                      group: groupOf[entry.identity], index: index)
            }
        }.sorted {
            let a = $0.assertion.startedAt ?? .distantFuture, b = $1.assertion.startedAt ?? .distantFuture
            return (a, $0.identity.pid, $0.index) < (b, $1.identity.pid, $1.index)
        }
    }
}

public extension ScanSnapshot {
    /// The sleep-blocking assertions `identity` holds; empty when none were seen.
    func assertions(for identity: ProcessIdentity) -> [PowerAssertion] {
        powerAssertions.first { $0.identity == identity }?.assertions ?? []
    }
}
