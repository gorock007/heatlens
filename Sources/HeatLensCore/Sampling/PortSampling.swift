import Darwin
import Foundation

/// TCP listeners found at one instant, for the processes a scan saw.
public struct PortReading: Sendable {
    /// Only processes with at least one listening port, sorted by PID.
    public let ports: [ProcessListeningPorts]
    /// Processes skipped because libproc refuses their descriptors (other users', root's).
    public let refusedCount: Int
    /// `CLOCK_UPTIME_RAW` time the read took, for docs/PERFORMANCE.md and the probe.
    public let elapsedNanoseconds: UInt64

    public init(ports: [ProcessListeningPorts], refusedCount: Int, elapsedNanoseconds: UInt64 = 0) {
        self.ports = ports
        self.refusedCount = refusedCount
        self.elapsedNanoseconds = elapsedNanoseconds
    }
}

public protocol PortSampling: Sendable {
    /// One read of the TCP sockets in LISTEN state held by `processes`.
    func listeningPorts(of processes: [ProcessReading]) -> PortReading
}

/// Lists each readable process's socket descriptors (`PROC_PIDLISTFDS`) and reads every
/// socket with `PROC_PIDFDSOCKETINFO`, keeping TCP sockets in LISTEN state. Processes libproc
/// refuses are not asked at all (their `detailAccess` already says so); they are counted for
/// the overview notice instead.
public struct LibprocPortSampler: PortSampling {
    public init() {}

    public func listeningPorts(of processes: [ProcessReading]) -> PortReading {
        let started = ProcessCounters.monotonicNow()
        var found: [ProcessListeningPorts] = []
        var refused = 0
        for process in processes {
            switch process.detailAccess {
            case .permissionDenied: refused += 1; continue
            case .notSupported, .processExited: continue
            case .available: break
            }
            let pid = process.identity.pid
            // A PID reused since the process was read belongs to someone else's sockets.
            guard case .success(let bsd) = Libproc.bsdInfo(pid), bsd.identity(pid: pid) == process.identity else { continue }
            switch Libproc.socketFDs(pid) {
            case .success(let fds):
                let ports = fds.compactMap { fd -> ListeningPort? in
                    guard case .success(let info) = Libproc.socketInfo(pid, fd: fd) else { return nil }
                    return PortParsing.listeningPort(SocketRecord(info))
                }
                let merged = PortParsing.merged(ports)
                if !merged.isEmpty { found.append(ProcessListeningPorts(identity: process.identity, ports: merged)) }
            case .failure(let failure):
                if failure.code == EPERM { refused += 1 }
            }
        }
        found.sort { $0.identity.pid < $1.identity.pid }
        return PortReading(ports: found, refusedCount: refused,
                           elapsedNanoseconds: ProcessCounters.monotonicNow() - started)
    }
}

/// The fields of a `socket_fdinfo` that decide whether and where it listens. Tests build these
/// from synthetic values; `init(_: socket_fdinfo)` reads them from the kernel's struct.
struct SocketRecord: Hashable {
    /// `soi_kind`; `SOCKINFO_TCP` for TCP.
    let kind: Int32
    /// `tcpsi_state`; `TSI_S_LISTEN` for a listener.
    let tcpState: Int32
    /// `insi_vflag`: `INI_IPV4`, `INI_IPV6` or both (an IPv6 socket that also takes IPv4).
    let ipFlags: UInt8
    /// Host byte order (`insi_lport` holds it in network order).
    let localPort: UInt16
    /// `ina_46.i46a_addr4`, 4 bytes in network order.
    let localAddress4: [UInt8]
    /// `ina_6`, 16 bytes.
    let localAddress6: [UInt8]

    init(kind: Int32, tcpState: Int32, ipFlags: UInt8, localPort: UInt16, localAddress4: [UInt8] = [0, 0, 0, 0],
         localAddress6: [UInt8] = Array(repeating: 0, count: 16)) {
        self.kind = kind
        self.tcpState = tcpState
        self.ipFlags = ipFlags
        self.localPort = localPort
        self.localAddress4 = localAddress4
        self.localAddress6 = localAddress6
    }

    init(_ info: socket_fdinfo) {
        let tcp = info.psi.soi_proto.pri_tcp
        let ini = tcp.tcpsi_ini
        var address4 = ini.insi_laddr.ina_46.i46a_addr4
        var address6 = ini.insi_laddr.ina_6
        self.init(kind: info.psi.soi_kind, tcpState: tcp.tcpsi_state, ipFlags: ini.insi_vflag,
                  localPort: UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)),
                  localAddress4: withUnsafeBytes(of: &address4) { Array($0) },
                  localAddress6: withUnsafeBytes(of: &address6) { Array($0) })
    }
}

/// Pure filtering and deduplication, so they are testable without live sockets.
enum PortParsing {
    /// nil unless the record is a TCP socket in LISTEN state with an IP family.
    static func listeningPort(_ record: SocketRecord) -> ListeningPort? {
        guard record.kind == Int32(SOCKINFO_TCP), record.tcpState == TSI_S_LISTEN, record.localPort != 0 else { return nil }
        let v4 = record.ipFlags & UInt8(INI_IPV4) != 0
        let v6 = record.ipFlags & UInt8(INI_IPV6) != 0
        let family: AddressFamily
        switch (v4, v6) {
        case (true, true): family = .dual
        case (false, true): family = .ipv6
        case (true, false): family = .ipv4
        case (false, false): return nil
        }
        let (scope, address) = v6 ? scope(ipv6: record.localAddress6) : scope(ipv4: record.localAddress4)
        return ListeningPort(port: record.localPort, family: family, scope: scope, address: address)
    }

    static func scope(ipv4 bytes: [UInt8]) -> (BindScope, String?) {
        guard bytes.count == 4 else { return (.specificAddress, nil) }
        if bytes.allSatisfy({ $0 == 0 }) { return (.allInterfaces, nil) }
        if bytes[0] == 127 { return (.loopback, nil) }
        return (.specificAddress, bytes.map(String.init).joined(separator: "."))
    }

    static func scope(ipv6 bytes: [UInt8]) -> (BindScope, String?) {
        guard bytes.count == 16 else { return (.specificAddress, nil) }
        if bytes.allSatisfy({ $0 == 0 }) { return (.allInterfaces, nil) }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return (.loopback, nil) }
        // ::ffff:a.b.c.d is an IPv4 address in an IPv6 socket.
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return scope(ipv4: Array(bytes.suffix(4)))
        }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else { return (.specificAddress, nil) }
        return (.specificAddress, String(cString: text))
    }

    /// One entry per port, sorted. IPv4 and IPv6 twins of a port become `.dual`; the widest
    /// scope wins (a port on 127.0.0.1 and on 0.0.0.0 is reachable from everywhere).
    static func merged(_ ports: [ListeningPort]) -> [ListeningPort] {
        Dictionary(grouping: ports, by: \.port).map { port, twins in
            let families = Set(twins.map(\.family))
            let family: AddressFamily = families.count == 1 ? families.first! : .dual
            let widest = twins.max { $0.scope < $1.scope }!
            let address = twins.compactMap(\.address).sorted().first
            return ListeningPort(port: port, family: family, scope: widest.scope, address: address)
        }.sorted { $0.port < $1.port }
    }
}
