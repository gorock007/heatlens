import Foundation

/// The background helper's wire protocol (docs/v2/ADR-0008 §2): two Mach services, one `@objc`
/// method per direction carrying `Data`, and inside it a versioned `Codable` envelope encoded as
/// a binary property list (`HelperCodec`). Neither request type has an action case: the helper
/// samples, keeps history and answers, and never signals anything or writes to Docker.
public enum HelperProtocol {
    /// The major version. A mismatch is refused on both sides with `mismatchMessage`.
    public static let protocolVersion = 1

    /// The app's control service: `HelperControlXPC`.
    public static let controlServiceName = "dev.heatlens.HeatLens.helper"
    /// The CLI's read-only service: `HelperReadXPC`.
    public static let readServiceName = "dev.heatlens.HeatLens.helper.read"

    public static let teamID = "9PXJ82UU32"
    /// Who may connect to the control service: the app.
    public static let appRequirement = requirement(identifier: "dev.heatlens.HeatLens")
    /// Who may connect to the read service: the CLI, signed with this identifier by `scripts/release.sh`.
    public static let cliRequirement = requirement(identifier: "dev.heatlens.heatlens")
    /// What the app and the CLI check the helper against.
    public static let helperRequirement = requirement(identifier: "dev.heatlens.heatlens-helper")

    public static let mismatchMessage = "HeatLens and its background helper are different versions; quit and reopen HeatLens"
    /// Every read's answer while the MCP switch is off, or the helper is unconfigured or paused.
    public static let notRunningMessage = "Background monitoring isn't running in HeatLens"

    private static func requirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

/// What every message carries around its body.
public struct HelperEnvelope<Body: Codable>: Codable {
    /// `HelperProtocol.protocolVersion` of the sender.
    public let protocolVersion: Int
    /// `CFBundleVersion` of the sender.
    public let build: String
    public let body: Body

    public init(protocolVersion: Int = HelperProtocol.protocolVersion, build: String, body: Body) {
        self.protocolVersion = protocolVersion
        self.build = build
        self.body = body
    }
}

extension HelperEnvelope: Sendable where Body: Sendable {}

/// Everything the core needs to sample, sent by the app on every connect and every Settings
/// change. The helper keeps none of it on disk.
public struct BackgroundSettings: Hashable, Codable, Sendable {
    /// Read the SMC's temperatures, fans and power.
    public var hardwareSensors: Bool
    /// Read containers from Docker's socket.
    public var docker: Bool
    public var userRules: [WorkloadRule]
    public var projectMappings: [ProjectMapping]
    /// Alert rules and the project watchlists (`AlertConfiguration.watches`).
    public var alerts: AlertConfiguration
    public var keepHistory: Bool
    public var historyRetentionDays: Int
    /// The MCP read tools' switch: off, every read answers `.notRunning`.
    public var mcpReadEnabled: Bool

    public init(hardwareSensors: Bool = false, docker: Bool = false, userRules: [WorkloadRule] = [],
                projectMappings: [ProjectMapping] = [], alerts: AlertConfiguration = .off, keepHistory: Bool = false,
                historyRetentionDays: Int = HistoryStore.defaultRetentionDays, mcpReadEnabled: Bool = false) {
        self.hardwareSensors = hardwareSensors
        self.docker = docker
        self.userRules = userRules
        self.projectMappings = projectMappings
        self.alerts = alerts
        self.keepHistory = keepHistory
        self.historyRetentionDays = historyRetentionDays
        self.mcpReadEnabled = mcpReadEnabled
    }
}

/// App → helper, over `HelperControlXPC`. Every request but `hello` is refused until the
/// connection's `hello` has been answered.
public enum HelperControlRequest: Equatable, Codable, Sendable {
    /// Answered with `.hello`, or `.restartRequired` when the builds differ (the helper then exits).
    case hello(appBuild: String)
    case configure(BackgroundSettings)
    /// Foreground at `interval` (2...10 s), or background cadence.
    case setViewer(attached: Bool, interval: TimeInterval?)
    /// Pushes start on `HelperEventsXPC`; a later subscribe replaces this connection's.
    case subscribe(BackgroundMonitor.Subscription)
    case refreshNow
    case pause
    case resume
    /// Sent as the app quits: sampling stops until the app's next `hello`.
    case pauseUntilAppOpens
    case status
    /// The recent-alerts ring after `since` (all of it for nil).
    case recentAlerts(since: Date?)
    case historyWindow(since: Date)
    case savedActions(since: Date)
    case historySize
    case recordActions([ActionRecord])
    case setRetention(days: Int)
    case deleteHistory
    /// Stop sampling, close history and exit.
    case shutdown
}

public struct HelperHello: Hashable, Codable, Sendable {
    public let helperBuild: String
    public let protocolVersion: Int
    public let status: BackgroundStatus

    public init(helperBuild: String, protocolVersion: Int = HelperProtocol.protocolVersion, status: BackgroundStatus) {
        self.helperBuild = helperBuild
        self.protocolVersion = protocolVersion
        self.status = status
    }
}

public enum HelperControlReply: Equatable, Codable, Sendable {
    case hello(HelperHello)
    /// The app is a different build: the helper exits after replying, and launchd starts the
    /// bundle's own binary on the next message.
    case restartRequired(helperBuild: String)
    /// The request was carried out.
    case done
    case status(BackgroundStatus)
    case alerts([Alert])
    case historyWindow(HistoryWindow)
    case savedActions([ActionRecord])
    /// Bytes on disk for the database and its WAL, whether or not it's open.
    case historySize(UInt64)
    case failure(HelperFailure)
}

/// CLI → helper, over `HelperReadXPC`: three reads and nothing else. The keys carry a `read.`
/// prefix, so no control request decodes as a read and no read decodes as a control request.
public enum HelperReadRequest: Hashable, Codable, Sendable {
    case liveStatus
    /// The newest `limit` alerts of the ring, oldest first; `limit` is 1...50.
    case recentAlerts(limit: Int)
    case explanations

    enum CodingKeys: String, CodingKey {
        case liveStatus = "read.liveStatus"
        case recentAlerts = "read.recentAlerts"
        case explanations = "read.explanations"
    }
}

public enum HelperReadReply: Equatable, Codable, Sendable {
    case liveStatus(BackgroundStatus)
    case recentAlerts([Alert])
    case explanations([Explanation])
    /// The MCP switch is off, or the helper is unconfigured or paused (owner decision 7).
    case notRunning(String)
    case failure(HelperFailure)
}

/// `LiveTick` made `Codable`: what a `.full` subscription pushes.
public typealias LiveTickPayload = LiveTick

/// Helper → app, over `HelperEventsXPC`.
public enum HelperEvent: Codable, Sendable {
    /// Every tick, under `.full` only.
    case tick(LiveTickPayload)
    /// After every status change and every tick's alerts, to every subscription.
    case summary(status: BackgroundStatus, newAlerts: [Alert], explanations: [Explanation])
}

/// Why a message was refused or a request failed, on either side.
public enum HelperFailure: Error, Hashable, Codable, Sendable, CustomStringConvertible {
    /// Over `HelperCodec.maximumBytes`; refused before decoding.
    case tooLarge(bytes: Int)
    /// Not a binary property list, truncated, an unknown case or a missing field.
    case malformed(String)
    case versionMismatch(received: Int, expected: Int)
    /// A request other than `hello` before this connection's `hello`.
    case helloRequired
    case invalidArgument(String)
    /// The helper answered `.restartRequired` (client side).
    case restartRequired(helperBuild: String)
    /// The history couldn't be opened, read or written. A `configure` that reports this still
    /// applied: the session samples without saving.
    case history(String)
    /// The connection is gone or the helper can't be reached (client side).
    case disconnected(String)
    /// No reply in time (client side).
    case timedOut
    /// The reply wasn't the one this request expects.
    case unexpectedReply(String)
    /// Too many messages queued on one connection.
    case busy

    public var description: String {
        switch self {
        case .tooLarge(let bytes): "Message too large (\(bytes) bytes; the limit is \(HelperCodec.maximumBytes))"
        case .malformed(let detail): "Malformed message: \(detail)"
        case .versionMismatch: HelperProtocol.mismatchMessage
        case .helloRequired: "Say hello first"
        case .invalidArgument(let detail): "Invalid argument: \(detail)"
        case .restartRequired: HelperProtocol.mismatchMessage
        case .history(let detail): detail
        case .disconnected(let detail): "The background helper isn't reachable: \(detail)"
        case .timedOut: "The background helper didn't answer in time"
        case .unexpectedReply(let detail): "Unexpected reply: \(detail)"
        case .busy: "The background helper is busy"
        }
    }
}

extension BackgroundMonitor.Subscription: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "full": self = .full
        case "summary": self = .summary
        case let other:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown subscription \(other.prefix(40))")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .full ? "full" : "summary")
    }
}
