import Darwin
import Foundation

/// Reads the local Docker Engine at one instant. Two readings bracket an interval and
/// `DockerAssembly` turns them into per-container CPU (docs/v2/ADR-0002).
public protocol DockerSampling: Sendable {
    func reading() -> DockerReading
}

/// Raw counters from one Docker read. Opaque outside the engine; pass two to `DockerAssembly`.
public struct DockerReading: Sendable {
    let availability: DockerAvailability
    let engineVersion: String?
    let apiVersion: String?
    let containers: [DockerContainerSummary]
    /// Keyed by full container ID; only running containers, at most `DockerEngineSampler.maxStatsContainers`.
    let stats: [String: DockerStatsCounters]
    let monotonicNanoseconds: UInt64
    let notices: [String]

    static func unavailable(_ availability: DockerAvailability, notices: [String] = []) -> DockerReading {
        DockerReading(availability: availability, engineVersion: nil, apiVersion: nil, containers: [], stats: [:],
                      monotonicNanoseconds: ProcessCounters.monotonicNow(), notices: notices)
    }
}

/// Docker turned off in Settings: never touches the socket.
public struct DisabledDockerSampler: DockerSampling {
    public init() {}
    public func reading() -> DockerReading { .unavailable(.disabled) }
}

/// The live sampler: finds the local socket, negotiates the API version, lists containers, and
/// reads one-shot stats for running ones. GET requests to a fixed set of paths only.
public struct DockerEngineSampler: DockerSampling {
    /// Running containers that get stats per reading; the rest are listed without CPU/memory.
    public static let maxStatsContainers = 20
    /// Total time one reading may spend on stats requests before it stops and says so.
    static let statsBudgetSeconds: TimeInterval = 3

    private let transport: (any DockerTransport)?
    private let locatorFailure: DockerAvailability?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) {
        switch DockerSocketLocator.locate(environment: environment, home: home) {
        case .success(let path):
            self.init(transport: UnixSocketTransport(socketPath: path), locatorFailure: nil)
        case .failure(let failure):
            self.init(transport: nil, locatorFailure: failure.availability)
        }
    }

    init(transport: (any DockerTransport)?, locatorFailure: DockerAvailability? = nil) {
        self.transport = transport
        self.locatorFailure = locatorFailure
    }

    public func reading() -> DockerReading {
        let reading = read()
        availabilityLog.note(reading.availability)
        return reading
    }

    private let availabilityLog = AvailabilityLog()

    /// Logs Docker's availability when it changes, not every reading.
    private final class AvailabilityLog: @unchecked Sendable {
        private let lock = NSLock()
        private var last: DockerAvailability?

        func note(_ availability: DockerAvailability) {
            let changed = lock.withLock {
                // Compared by case: an error message or version doesn't count as a change.
                defer { last = availability }
                return last.map { "\(Self.word($0))" != "\(Self.word(availability))" } ?? true
            }
            if changed { HeatLensLog.notice(.docker, "docker availability changed", ["state": .word(Self.word(availability))]) }
        }

        static func word(_ availability: DockerAvailability) -> StaticString {
            switch availability {
            case .available: "available"
            case .disabled: "disabled"
            case .socketNotFound: "socketNotFound"
            case .permissionDenied: "permissionDenied"
            case .daemonNotResponding: "daemonNotResponding"
            case .unsupportedAPI: "unsupportedAPI"
            case .error: "error"
            }
        }
    }

    private func read() -> DockerReading {
        guard let transport else { return .unavailable(locatorFailure ?? .socketNotFound) }
        let version: DockerVersionResponse
        do {
            version = try decode(DockerVersionResponse.self, try transport.get(DockerEndpoint.version.path))
        } catch {
            return .unavailable(Self.availability(for: error))
        }
        guard let api = DockerAPIVersion(version.ApiVersion), api >= DockerAPIVersion.minimum else {
            return .unavailable(.unsupportedAPI(version: version.ApiVersion))
        }
        let summaries: [DockerContainerSummary]
        do {
            summaries = try decode([DockerContainerSummary].self, try transport.get(DockerEndpoint.containers(api: api).path))
        } catch {
            return .unavailable(Self.availability(for: error))
        }
        let containers = summaries.filter { DockerContainerID($0.Id) != nil }
        var notices: [String] = []
        if containers.count < summaries.count {
            notices.append("\(summaries.count - containers.count) container(s) with an unexpected ID were skipped")
        }
        let running = containers.filter { $0.State == "running" }
        var stats: [String: DockerStatsCounters] = [:]
        let deadline = Date().addingTimeInterval(Self.statsBudgetSeconds)
        for container in running.prefix(Self.maxStatsContainers) {
            guard Date() < deadline else {
                notices.append("Docker stats stopped after \(Int(Self.statsBudgetSeconds)) s; some containers have no CPU or memory")
                break
            }
            guard let id = DockerContainerID(container.Id),
                  let response = try? transport.get(DockerEndpoint.stats(api: api, id: id).path),
                  let decoded = try? decode(DockerStatsResponse.self, response) else { continue }
            stats[container.Id] = DockerStatsCounters(decoded)
        }
        if running.count > Self.maxStatsContainers {
            notices.append("CPU and memory for \(Self.maxStatsContainers) of \(running.count) running containers")
        }
        return DockerReading(availability: .available, engineVersion: version.Version, apiVersion: api.description,
                             containers: containers, stats: stats, monotonicNanoseconds: ProcessCounters.monotonicNow(),
                             notices: notices)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: UnixSocketHTTP.Response) throws -> T {
        guard response.status == 200 else { throw DockerEngineError.status(response.status) }
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw DockerEngineError.badJSON
        }
    }

    static func availability(for error: Error) -> DockerAvailability {
        switch error {
        case UnixSocketHTTP.Failure.connectFailed(let code) where code == ENOENT:
            return .socketNotFound
        case UnixSocketHTTP.Failure.connectFailed(let code) where code == EACCES || code == EPERM:
            return .permissionDenied
        case UnixSocketHTTP.Failure.connectFailed(let code) where code == ECONNREFUSED:
            return .daemonNotResponding
        case UnixSocketHTTP.Failure.timedOut:
            return .daemonNotResponding
        case DockerEngineError.status(let status):
            return .error(message: "Docker Engine answered HTTP \(status)")
        case DockerEngineError.badJSON:
            return .error(message: "Docker Engine sent a response HeatLens couldn't read")
        case UnixSocketHTTP.Failure.responseTooLarge:
            return .error(message: "Docker Engine response was too large")
        default:
            return .error(message: "\(error)")
        }
    }
}

enum DockerEngineError: Error, Equatable {
    case status(Int)
    case badJSON
}

// MARK: - Interval assembly (pure)

public enum DockerAssembly {
    /// Containers from `after`, with CPU from the `total_usage` delta between the two readings
    /// (100 = one core) and memory from `after`. Running containers first, then by name.
    public static func snapshot(before: DockerReading?, after: DockerReading) -> DockerSnapshot {
        guard after.availability.isAvailable else {
            return .unavailable(after.availability, notices: after.notices)
        }
        let elapsed = before.map { after.monotonicNanoseconds > $0.monotonicNanoseconds ? after.monotonicNanoseconds - $0.monotonicNanoseconds : 0 } ?? 0
        let samples = after.containers.map { summary -> ContainerSample in
            let now = after.stats[summary.Id]
            let then = before?.stats[summary.Id]
            return ContainerSample(
                containerID: summary.Id,
                name: summary.Names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? summary.shortID,
                image: summary.Image, state: summary.State, status: summary.Status ?? "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(summary.Created)),
                labels: summary.Labels ?? [:],
                cpuPercentOfOneCore: cpuPercent(before: then, after: now, elapsedNanoseconds: elapsed),
                memoryBytes: now?.memoryBytes, vmCPUCount: now?.onlineCPUs,
                bindMountSources: summary.bindSources
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return DockerSnapshot(availability: .available, engineVersion: after.engineVersion, apiVersion: after.apiVersion,
                              containers: samples, notices: after.notices)
    }

    static func cpuPercent(before: DockerStatsCounters?, after: DockerStatsCounters?, elapsedNanoseconds: UInt64) -> Double? {
        guard let before, let after, elapsedNanoseconds > 0, after.totalUsageNanoseconds >= before.totalUsageNanoseconds else {
            return nil
        }
        return Double(after.totalUsageNanoseconds - before.totalUsageNanoseconds) / Double(elapsedNanoseconds) * 100
    }
}

// MARK: - Endpoints and validation

/// A container ID as the Engine reports it: 12 to 64 lowercase hex characters. Nothing else can
/// reach a request path.
struct DockerContainerID: Hashable, Sendable {
    let value: String

    init?(_ raw: String) {
        guard (12...64).contains(raw.utf8.count), raw.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        value = raw
    }

    /// The full 64-character ID; a stop is addressed only by this (ADR-0007 decision 1).
    var isFull: Bool { value.utf8.count == 64 }
}

struct DockerAPIVersion: Comparable, CustomStringConvertible, Sendable {
    /// One-shot stats need 1.41 (Docker Engine 20.10).
    static let minimum = DockerAPIVersion(major: 1, minor: 41)

    let major: Int
    let minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]), (0...99).contains(major), (0...999).contains(minor),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        self.init(major: major, minor: minor)
    }

    var description: String { "\(major).\(minor)" }

    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor) < (rhs.major, rhs.minor) }
}

/// Every request HeatLens can make. There is no other way to build a path. `stop` is the only
/// one sent as a POST (ADR-0007).
enum DockerEndpoint {
    case ping
    case version
    case containers(api: DockerAPIVersion)
    case stats(api: DockerAPIVersion, id: DockerContainerID)
    case inspect(api: DockerAPIVersion, id: DockerContainerID)
    case stop(api: DockerAPIVersion, id: DockerContainerID, timeout: Int)

    /// `docker stop`'s `t` is clamped to this range.
    static let stopTimeoutRange = 0...120

    /// A `stop` timeout is clamped to `stopTimeoutRange`. A `stop` with a short ID gives a path
    /// `UnixSocketHTTP.isAllowedStopPath` refuses, so it can't be sent.
    var path: String {
        switch self {
        case .ping: "/_ping"
        case .version: "/version"
        case .containers(let api): "/v\(api)/containers/json?all=1"
        case .stats(let api, let id): "/v\(api)/containers/\(id.value)/stats?stream=false&one-shot=true"
        case .inspect(let api, let id): "/v\(api)/containers/\(id.value)/json"
        case .stop(let api, let id, let timeout):
            "/v\(api)/containers/\(id.value)/stop?t=\(min(max(timeout, Self.stopTimeoutRange.lowerBound), Self.stopTimeoutRange.upperBound))"
        }
    }
}

// MARK: - Transport and socket discovery

protocol DockerTransport: Sendable {
    func get(_ path: String) throws -> UnixSocketHTTP.Response
    /// Only `UnixSocketHTTP.isAllowedStopPath` paths; only `ContainerStopper` calls it.
    func post(_ path: String, timeout: TimeInterval) throws -> UnixSocketHTTP.Response
}

struct UnixSocketTransport: DockerTransport {
    let socketPath: String
    var timeout: TimeInterval = 2

    func get(_ path: String) throws -> UnixSocketHTTP.Response {
        try UnixSocketHTTP.get(path: path, socketPath: socketPath, timeout: timeout)
    }

    func post(_ path: String, timeout: TimeInterval) throws -> UnixSocketHTTP.Response {
        try UnixSocketHTTP.post(path: path, socketPath: socketPath, timeout: timeout)
    }
}

enum DockerSocketLocator {
    enum Failure: Error, Equatable {
        case notFound
        case notASocket(String)
        case untrustedOwner(String)

        var availability: DockerAvailability {
            switch self {
            case .notFound: .socketNotFound
            case .notASocket(let path): .error(message: "\(path) is not a socket")
            case .untrustedOwner(let path): .error(message: "\(path) is owned by another user; not connecting")
            }
        }
    }

    /// `DOCKER_HOST` only when it names a local `unix://` socket; then Docker Desktop's paths.
    static func candidates(environment: [String: String], home: String) -> [String] {
        var paths: [String] = []
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            paths.append(String(host.dropFirst("unix://".count)))
        }
        paths.append(home + "/.docker/run/docker.sock")
        paths.append("/var/run/docker.sock")
        return paths
    }

    /// The first candidate that exists, is a socket, and is owned by this user or root.
    static func locate(environment: [String: String], home: String,
                       stat statPath: (String) -> (mode: mode_t, owner: uid_t)? = Self.fileStatus,
                       currentUser: uid_t = getuid()) -> Result<String, Failure> {
        for path in candidates(environment: environment, home: home) where path.hasPrefix("/") {
            guard let info = statPath(path) else { continue }
            guard info.mode & S_IFMT == S_IFSOCK else { return .failure(.notASocket(path)) }
            guard info.owner == currentUser || info.owner == 0 else { return .failure(.untrustedOwner(path)) }
            return .success(path)
        }
        return .failure(.notFound)
    }

    /// Follows symlinks (`/var/run/docker.sock` → `~/.docker/run/docker.sock`).
    static func fileStatus(_ path: String) -> (mode: mode_t, owner: uid_t)? {
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &info, 0) == 0 else { return nil }
        return (info.st_mode, info.st_uid)
    }

    /// Why a socket that is fine for reads may not carry a container stop (ADR-0007 decision 4).
    enum StopRefusal: Error, Equatable {
        /// The reads use a `DOCKER_HOST` socket: Colima, OrbStack, Podman are untested.
        case dockerHost
        /// Not one of Docker Desktop's two paths, or a symlink that resolves elsewhere.
        case notDockerDesktop(String)
        /// Missing, not a socket, or not owned by this user (root included).
        case notOwned(String)

        var reason: String {
            switch self {
            case .dockerHost, .notDockerDesktop: "Stopping is only supported through Docker Desktop's socket for now."
            case .notOwned: "HeatLens only stops containers through a Docker socket you own."
            }
        }
    }

    /// The paths a stop may go through, and the targets a symlink there may resolve to.
    static func stopPaths(home: String) -> [String] {
        [home + "/.docker/run/docker.sock", "/var/run/docker.sock", "/private/var/run/docker.sock"]
    }

    /// Decision 4: `path` (what `locate` chose for reads) carries a stop only when it did not
    /// come from `DOCKER_HOST`, is one of Docker Desktop's two paths, a symlink there resolves to
    /// one of them again, and the socket it ends at is owned by `currentUser` (not root).
    static func stopPolicy(for path: String, environment: [String: String], home: String,
                           lstat linkStatus: (String) -> (mode: mode_t, owner: uid_t)? = Self.linkStatus,
                           realpath resolve: (String) -> String? = Self.resolvedPath,
                           currentUser: uid_t = getuid()) -> Result<String, StopRefusal> {
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://"), String(host.dropFirst("unix://".count)) == path {
            return .failure(.dockerHost)
        }
        let allowed = stopPaths(home: home)
        guard allowed.prefix(2).contains(path) else { return .failure(.notDockerDesktop(path)) }
        guard var info = linkStatus(path) else { return .failure(.notOwned(path)) }
        var socket = path
        if info.mode & S_IFMT == S_IFLNK {
            guard let target = resolve(path), allowed.contains(target) || resolve(allowed[0]) == target else {
                return .failure(.notDockerDesktop(path))
            }
            guard let targetInfo = linkStatus(target) else { return .failure(.notOwned(target)) }
            socket = target
            info = targetInfo
        }
        guard info.mode & S_IFMT == S_IFSOCK, info.owner == currentUser, currentUser != 0 else {
            return .failure(.notOwned(socket))
        }
        return .success(socket)
    }

    /// Does not follow a symlink in the last component.
    static func linkStatus(_ path: String) -> (mode: mode_t, owner: uid_t)? {
        var info = Darwin.stat()
        guard Darwin.lstat(path, &info) == 0 else { return nil }
        return (info.st_mode, info.st_uid)
    }

    static func resolvedPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - Engine JSON (fields HeatLens reads; everything else is ignored)

struct DockerVersionResponse: Decodable {
    let Version: String
    let ApiVersion: String
}

struct DockerContainerSummary: Decodable, Sendable {
    let Id: String
    let Names: [String]
    let Image: String
    let State: String
    let Status: String?
    let Created: Int64
    let Labels: [String: String]?
    /// Only `Type` and `Source` are read, and only bind sources are kept.
    let Mounts: [Mount]?

    struct Mount: Decodable, Sendable {
        let `Type`: String?
        let Source: String?
    }

    var shortID: String { String(Id.prefix(12)) }
    var bindSources: [String] {
        (Mounts ?? []).compactMap { $0.Type == "bind" ? $0.Source : nil }.filter { $0.hasPrefix("/") }
    }
}

/// `GET /containers/{id}/json`, only the fields ADR-0007 decision 3 reads.
struct DockerContainerInspect: Decodable, Sendable {
    struct StateInfo: Decodable, Sendable {
        let Status: String
        let StartedAt: String?
    }
    struct ConfigInfo: Decodable, Sendable {
        /// Seconds; nil means the Engine's default (10).
        let StopTimeout: Int?
        let StopSignal: String?
        let Labels: [String: String]?
    }
    struct HostConfigInfo: Decodable, Sendable {
        struct RestartPolicyInfo: Decodable, Sendable { let Name: String? }
        let RestartPolicy: RestartPolicyInfo?
    }

    let Id: String
    /// With a leading `/`.
    let Name: String
    /// RFC 3339 with nanoseconds, e.g. `2026-10-27T10:00:13.123456789Z`.
    let Created: String
    let State: StateInfo
    let Config: ConfigInfo?
    let HostConfig: HostConfigInfo?

    var name: String { Name.hasPrefix("/") ? String(Name.dropFirst()) : Name }

    /// `Created` as whole Unix seconds (the list's precision), or nil when it doesn't parse.
    var createdSeconds: Int64? {
        // ISO8601DateFormatter doesn't take nine fractional digits; drop them, keep the zone.
        var text = Created
        if let dot = text.firstIndex(of: ".") {
            let zone = text[dot...].firstIndex { $0 == "Z" || $0 == "+" || $0 == "-" } ?? text.endIndex
            text.removeSubrange(dot..<zone)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text).map { Int64($0.timeIntervalSince1970.rounded(.down)) }
    }
}

struct DockerStatsResponse: Decodable {
    struct CPUStats: Decodable {
        struct Usage: Decodable { let total_usage: UInt64 }
        let cpu_usage: Usage
        let online_cpus: Int?
    }
    struct MemoryStats: Decodable {
        struct Detail: Decodable { let inactive_file: UInt64? }
        let usage: UInt64?
        let stats: Detail?
    }
    let cpu_stats: CPUStats
    let memory_stats: MemoryStats
}

struct DockerStatsCounters: Hashable, Sendable {
    let totalUsageNanoseconds: UInt64
    let onlineCPUs: Int?
    let memoryBytes: UInt64?

    init(totalUsageNanoseconds: UInt64, onlineCPUs: Int?, memoryBytes: UInt64?) {
        self.totalUsageNanoseconds = totalUsageNanoseconds
        self.onlineCPUs = onlineCPUs
        self.memoryBytes = memoryBytes
    }

    init(_ response: DockerStatsResponse) {
        let usage = response.memory_stats.usage
        let inactive = response.memory_stats.stats?.inactive_file ?? 0
        self.init(totalUsageNanoseconds: response.cpu_stats.cpu_usage.total_usage, onlineCPUs: response.cpu_stats.online_cpus,
                  memoryBytes: usage.map { $0 >= inactive ? $0 - inactive : $0 })
    }
}
