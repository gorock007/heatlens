import Foundation

/// The address family a listening socket was bound with. `dual` is one port seen on both IPv4
/// and IPv6 (two sockets, or one IPv6 socket that also accepts IPv4), reported once.
public enum AddressFamily: String, Hashable, Codable, Sendable {
    case ipv4, ipv6, dual
}

/// Where a listening socket accepts connections from.
public enum BindScope: String, Hashable, Codable, Sendable, Comparable {
    /// 127.0.0.0/8 or ::1: only this Mac.
    case loopback
    /// One particular local address (a LAN or VPN interface); `ListeningPort.address` names it.
    case specificAddress
    /// 0.0.0.0 or ::: every interface, so other machines on the network may reach it.
    case allInterfaces

    private var rank: Int { [BindScope.loopback, .specificAddress, .allInterfaces].firstIndex(of: self) ?? 0 }
    public static func < (lhs: BindScope, rhs: BindScope) -> Bool { lhs.rank < rhs.rank }
}

/// One TCP port a process listens on, read with `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`.
public struct ListeningPort: Hashable, Codable, Sendable {
    public let port: UInt16
    public let family: AddressFamily
    public let scope: BindScope
    /// The bound address when `scope == .specificAddress` (e.g. "192.168.1.20"); nil otherwise.
    public let address: String?

    public init(port: UInt16, family: AddressFamily, scope: BindScope, address: String? = nil) {
        self.port = port
        self.family = family
        self.scope = scope
        self.address = scope == .specificAddress ? address : nil
    }
}

/// The ports one process instance listens on, as stored in `ScanSnapshot.listeningPorts`.
public struct ProcessListeningPorts: Hashable, Codable, Sendable {
    public let identity: ProcessIdentity
    /// Sorted by port, one entry per port.
    public let ports: [ListeningPort]

    public init(identity: ProcessIdentity, ports: [ListeningPort]) {
        self.identity = identity
        self.ports = ports
    }
}

/// One row of the "Ports" list: a port and the process holding it, tied to its group.
public struct PortListing: Hashable, Sendable, Identifiable {
    public var id: String { "\(port.port)-\(identity.pid)-\(identity.startTimeMicros)" }
    public let port: ListeningPort
    public let identity: ProcessIdentity
    public let processName: String
    /// The group the process belongs to, nil when the resolver didn't group it.
    public let group: ProcessGroup?

    /// One row per (port, process), sorted by port then PID.
    public static func listings(_ snapshot: ScanSnapshot, groups: [ProcessGroup]) -> [PortListing] {
        let names = Dictionary(snapshot.processes.map { ($0.identity, $0.name) }, uniquingKeysWith: { first, _ in first })
        var groupOf: [ProcessIdentity: ProcessGroup] = [:]
        for group in groups {
            for member in group.members where groupOf[member] == nil { groupOf[member] = group }
        }
        return snapshot.listeningPorts.flatMap { entry in
            entry.ports.map {
                PortListing(port: $0, identity: entry.identity, processName: names[entry.identity] ?? "PID \(entry.identity.pid)",
                            group: groupOf[entry.identity])
            }
        }.sorted { ($0.port.port, $0.identity.pid) < ($1.port.port, $1.identity.pid) }
    }
}

public extension ScanSnapshot {
    /// The ports `identity` listens on, sorted; empty when none were seen.
    func ports(for identity: ProcessIdentity) -> [ListeningPort] {
        listeningPorts.first { $0.identity == identity }?.ports ?? []
    }

    /// Distinct ports across `identities`, sorted.
    func portNumbers(for identities: [ProcessIdentity]) -> [UInt16] {
        let wanted = Set(identities)
        return Set(listeningPorts.filter { wanted.contains($0.identity) }.flatMap { $0.ports.map(\.port) }).sorted()
    }
}
