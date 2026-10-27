import Foundation

/// Whether HeatLens could talk to a local Docker Engine, and if not, why (docs/v2/ADR-0002).
public enum DockerAvailability: Hashable, Codable, Sendable {
    case available
    /// The user has not turned on Docker containers in Settings. The socket was not opened.
    case disabled
    /// No Docker socket at the known local paths. Docker is not installed or not running.
    case socketNotFound
    /// The socket exists but this user may not connect to it.
    case permissionDenied
    /// The socket exists but nothing answered in time (Docker Desktop stopped or starting).
    case daemonNotResponding
    /// The Engine's API is older than the 1.41 HeatLens needs for one-shot stats.
    case unsupportedAPI(version: String)
    case error(message: String)

    public var isAvailable: Bool { self == .available }
}

/// One container at one sampling interval (PRD-v2 §7 `ContainerSample`). CPU is the delta across
/// the interval, with 100 = one core, as for processes.
public struct ContainerSample: Identifiable, Hashable, Codable, Sendable {
    public var id: String { containerID }
    /// The full 64-hex-character ID.
    public let containerID: String
    /// Without the leading `/`.
    public let name: String
    public let image: String
    /// Engine state: `running`, `exited`, `paused`, `restarting`, `created`, `dead`.
    public let state: String
    /// Engine status text, e.g. "Up 3 days".
    public let status: String
    public let createdAt: Date
    public let labels: [String: String]
    /// nil when the container was not running at both ends of the interval, or stats were capped.
    public let cpuPercentOfOneCore: Double?
    /// `usage − inactive_file`, as `docker stats` shows it.
    public let memoryBytes: UInt64?
    /// CPUs inside the Docker VM, for context ("of 6 VM CPUs"); not the host's cores.
    public let vmCPUCount: Int?

    public init(containerID: String, name: String, image: String, state: String, status: String, createdAt: Date,
                labels: [String: String], cpuPercentOfOneCore: Double?, memoryBytes: UInt64?, vmCPUCount: Int?) {
        self.containerID = containerID
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.createdAt = createdAt
        self.labels = labels
        self.cpuPercentOfOneCore = cpuPercentOfOneCore
        self.memoryBytes = memoryBytes
        self.vmCPUCount = vmCPUCount
    }

    public var shortID: String { String(containerID.prefix(12)) }
    public var isRunning: Bool { state == "running" }
    /// Compose labels: evidence for project attribution (Phase 2), not attribution itself.
    public var composeProject: String? { labels["com.docker.compose.project"] }
    public var composeService: String? { labels["com.docker.compose.service"] }
    public var composeWorkingDirectory: String? { labels["com.docker.compose.project.working_dir"] }
}

/// Everything one Docker read (or interval) found.
public struct DockerSnapshot: Hashable, Codable, Sendable {
    public let availability: DockerAvailability
    /// e.g. "28.5.1".
    public let engineVersion: String?
    /// The API version HeatLens used, e.g. "1.51".
    public let apiVersion: String?
    /// Running containers first, then by name.
    public let containers: [ContainerSample]
    /// Data-quality notes ("stats for 20 of 23 running containers").
    public let notices: [String]

    public init(availability: DockerAvailability, engineVersion: String?, apiVersion: String?,
                containers: [ContainerSample], notices: [String]) {
        self.availability = availability
        self.engineVersion = engineVersion
        self.apiVersion = apiVersion
        self.containers = containers
        self.notices = notices
    }

    public static func unavailable(_ availability: DockerAvailability, notices: [String] = []) -> DockerSnapshot {
        DockerSnapshot(availability: availability, engineVersion: nil, apiVersion: nil, containers: [], notices: notices)
    }
}
