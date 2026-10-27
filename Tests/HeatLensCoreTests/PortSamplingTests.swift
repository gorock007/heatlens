import Darwin
import Foundation
import Testing
@testable import HeatLensCore

private let tcp = Int32(SOCKINFO_TCP)
private let v4 = UInt8(INI_IPV4)
private let v6 = UInt8(INI_IPV6)

private func v6Bytes(_ last: [UInt8], mapped: Bool = false) -> [UInt8] {
    Array(repeating: 0, count: 10) + (mapped ? [0xff, 0xff] : [0, 0]) + Array(repeating: 0, count: 4 - last.count) + last
}

/// A copy of `snapshot` with ports attached; the synthetic builders don't take them.
func withPorts(_ snapshot: ScanSnapshot, _ ports: [ProcessListeningPorts], notices: [String]? = nil) -> ScanSnapshot {
    ScanSnapshot(id: snapshot.id, startedAt: snapshot.startedAt, interval: snapshot.interval, system: snapshot.system,
                 processes: snapshot.processes, notices: notices ?? snapshot.notices, listeningPorts: ports)
}

@Suite("Listening-port parsing")
struct PortParsingTests {
    @Test("Only TCP sockets in LISTEN state with a port and an IP family count")
    func filtersNonListeners() {
        #expect(PortParsing.listeningPort(SocketRecord(kind: tcp, tcpState: TSI_S_LISTEN, ipFlags: v4, localPort: 3000)) != nil)
        #expect(PortParsing.listeningPort(SocketRecord(kind: tcp, tcpState: TSI_S_ESTABLISHED, ipFlags: v4, localPort: 3000)) == nil)
        #expect(PortParsing.listeningPort(SocketRecord(kind: Int32(SOCKINFO_IN), tcpState: TSI_S_LISTEN, ipFlags: v4, localPort: 53)) == nil)
        #expect(PortParsing.listeningPort(SocketRecord(kind: Int32(SOCKINFO_UN), tcpState: TSI_S_LISTEN, ipFlags: 0, localPort: 0)) == nil)
        #expect(PortParsing.listeningPort(SocketRecord(kind: tcp, tcpState: TSI_S_LISTEN, ipFlags: 0, localPort: 3000)) == nil)
        #expect(PortParsing.listeningPort(SocketRecord(kind: tcp, tcpState: TSI_S_LISTEN, ipFlags: v4, localPort: 0)) == nil)
    }

    @Test("Bind scope and family from IPv4 and IPv6 local addresses")
    func scopes() {
        func port(_ flags: UInt8, a4: [UInt8] = [0, 0, 0, 0], a6: [UInt8] = Array(repeating: 0, count: 16)) -> ListeningPort? {
            PortParsing.listeningPort(SocketRecord(kind: tcp, tcpState: TSI_S_LISTEN, ipFlags: flags, localPort: 8765,
                                                   localAddress4: a4, localAddress6: a6))
        }
        #expect(port(v4) == ListeningPort(port: 8765, family: .ipv4, scope: .allInterfaces))
        #expect(port(v4, a4: [127, 0, 0, 1]) == ListeningPort(port: 8765, family: .ipv4, scope: .loopback))
        #expect(port(v4, a4: [127, 1, 2, 3])?.scope == .loopback)
        #expect(port(v4, a4: [192, 168, 1, 20]) == ListeningPort(port: 8765, family: .ipv4, scope: .specificAddress, address: "192.168.1.20"))
        #expect(port(v6) == ListeningPort(port: 8765, family: .ipv6, scope: .allInterfaces))
        #expect(port(v4 | v6) == ListeningPort(port: 8765, family: .dual, scope: .allInterfaces))
        #expect(port(v6, a6: v6Bytes([1])) == ListeningPort(port: 8765, family: .ipv6, scope: .loopback))
        #expect(port(v6, a6: v6Bytes([127, 0, 0, 1], mapped: true))?.scope == .loopback)
        #expect(port(v6, a6: v6Bytes([0, 0, 0, 0], mapped: true))?.scope == .allInterfaces)
        let linkLocal: [UInt8] = [0xfe, 0x80] + Array(repeating: 0, count: 13) + [1]
        #expect(port(v6, a6: linkLocal) == ListeningPort(port: 8765, family: .ipv6, scope: .specificAddress, address: "fe80::1"))
        // The address is kept only for a specific bind.
        #expect(ListeningPort(port: 1, family: .ipv4, scope: .loopback, address: "127.0.0.1").address == nil)
    }

    @Test("IPv4/IPv6 twins of one port merge into one dual entry with the widest scope")
    func deduplicates() {
        let merged = PortParsing.merged([
            ListeningPort(port: 9229, family: .ipv4, scope: .loopback),
            ListeningPort(port: 3000, family: .ipv6, scope: .loopback),
            ListeningPort(port: 3000, family: .ipv4, scope: .loopback),
            ListeningPort(port: 5173, family: .ipv4, scope: .loopback),
            ListeningPort(port: 5173, family: .ipv6, scope: .allInterfaces),
            ListeningPort(port: 9229, family: .ipv4, scope: .loopback),
        ])
        #expect(merged == [
            ListeningPort(port: 3000, family: .dual, scope: .loopback),
            ListeningPort(port: 5173, family: .dual, scope: .allInterfaces),
            ListeningPort(port: 9229, family: .ipv4, scope: .loopback),
        ])
    }

    @Test("SocketRecord reads kind, state, flags, network-order port and addresses from socket_fdinfo")
    func readsSocketFDInfo() {
        var info = socket_fdinfo()
        info.psi.soi_kind = tcp
        info.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_LISTEN
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = v4
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(3000).bigEndian)
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4 = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let record = SocketRecord(info)
        #expect(record.kind == tcp && record.tcpState == TSI_S_LISTEN && record.ipFlags == v4)
        #expect(record.localPort == 3000)
        #expect(record.localAddress4 == [127, 0, 0, 1])
        #expect(PortParsing.listeningPort(record) == ListeningPort(port: 3000, family: .ipv4, scope: .loopback))
    }
}

/// A listening TCP socket on an ephemeral loopback port, owned by this test process.
private final class LoopbackListener {
    let fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                bind(fd, pointer, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        guard bound else { close(fd); throw POSIXError(.EADDRNOTAVAIL) }
        self.fd = fd
        port = UInt16(bigEndian: addr.sin_port)
    }

    deinit { close(fd) }
}

@Suite("Listening-port sampling", .serialized)
struct PortSamplerTests {
    @Test("Live: a loopback listener this process opens is found for getpid()")
    func findsOwnListener() throws {
        let listener = try LoopbackListener()
        let identity = try #require(LibprocProcessSampler.identity(of: getpid()))
        let me = ProcessReading(identity: identity, parentPID: getppid(), owner: .currentUser, name: "tests",
                                cpu: CPUTime(userNanoseconds: 0, systemNanoseconds: 0), detailAccess: .available)
        let reading = LibprocPortSampler().listeningPorts(of: [me])
        let ports = reading.ports.first { $0.identity == identity }?.ports ?? []
        #expect(ports.contains(ListeningPort(port: listener.port, family: .ipv4, scope: .loopback)))
        #expect(reading.refusedCount == 0)
        withExtendedLifetime(listener) {}
    }

    @Test("Refused processes are counted, not read; a stale identity on a live PID is skipped")
    func skipsRefusedAndStale() throws {
        let listener = try LoopbackListener()
        let identity = try #require(LibprocProcessSampler.identity(of: getpid()))
        let refused = ProcessReading(identity: ProcessIdentity(pid: 1, startTimeMicros: 0), parentPID: 0, owner: .root,
                                     name: "launchd", cpu: nil, detailAccess: .permissionDenied)
        let kernel = ProcessReading(identity: ProcessIdentity(pid: 0, startTimeMicros: 0), parentPID: 0, owner: .root,
                                    name: "kernel_task", cpu: nil, detailAccess: .notSupported)
        // Our own PID with a different start time: an earlier process that held this PID.
        let stale = ProcessReading(identity: ProcessIdentity(pid: getpid(), startTimeMicros: identity.startTimeMicros - 1),
                                   parentPID: 1, owner: .currentUser, name: "old", cpu: nil, detailAccess: .available)
        let reading = LibprocPortSampler().listeningPorts(of: [refused, kernel, stale])
        #expect(reading.refusedCount == 1)
        #expect(reading.ports.isEmpty)
        withExtendedLifetime(listener) {}
    }
}

private struct FixedPortSampler: PortSampling {
    let reading: @Sendable ([ProcessReading]) -> PortReading
    func listeningPorts(of processes: [ProcessReading]) -> PortReading { reading(processes) }
}

private final class TwoReadings: ProcessSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let before: [ProcessReading]
    let after: [ProcessReading]
    init(before: [ProcessReading], after: [ProcessReading]) { self.before = before; self.after = after }
    func snapshot() throws -> ProcessCounters {
        let call = lock.withLock { calls += 1; return calls }
        return ProcessCounters(monotonicNanoseconds: ProcessCounters.monotonicNow(), wallClock: Date(),
                               processes: call == 1 ? before : after)
    }
}

private struct QuietSystemSampler: SystemSampling {
    func counters() -> HostCounters {
        HostCounters(perCore: [CPULoadTicks(user: 0, system: 0, idle: 0, nice: 0)], swapOuts: 0)
    }
    func state() async throws -> HostState {
        HostState(coreCount: 1, totalBytes: 1 << 30, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                  compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0, memoryAvailable: true, pressure: .normal,
                  availablePercent: 50, thermalState: .nominal, pmset: nil)
    }
}

@Suite("Listening ports in the snapshot")
struct PortSnapshotTests {
    @Test("The coordinator samples ports once, from the second reading, and adds one notice for refused processes")
    func coordinatorAttachesPorts() async throws {
        let start = Int64(Date().timeIntervalSince1970 * 1_000_000) - 60_000_000
        let server = ProcessIdentity(pid: 4242, startTimeMicros: start)
        let gone = ProcessIdentity(pid: 4243, startTimeMicros: start)
        func reading(_ identity: ProcessIdentity) -> ProcessReading {
            ProcessReading(identity: identity, parentPID: 1, owner: .currentUser, name: "fake-\(identity.pid)",
                           cpu: CPUTime(userNanoseconds: 0, systemNanoseconds: 0), detailAccess: .available)
        }
        let seen = Recorder<[Int32]>()
        let ports = FixedPortSampler { processes in
            seen.append(processes.map(\.identity.pid))
            return PortReading(ports: [
                ProcessListeningPorts(identity: server, ports: [ListeningPort(port: 3000, family: .dual, scope: .loopback)]),
                // Not in the snapshot as a live process: dropped.
                ProcessListeningPorts(identity: gone, ports: [ListeningPort(port: 4000, family: .ipv4, scope: .loopback)]),
            ], refusedCount: 3)
        }
        let coordinator = ScanCoordinator(processSampler: TwoReadings(before: [reading(server), reading(gone)], after: [reading(server)]),
                                          systemSampler: QuietSystemSampler(), portSampler: ports)
        let snapshot = try await coordinator.scan(duration: 1) { _ in }
        #expect(seen.values == [[4242]])
        #expect(snapshot.listeningPorts == [ProcessListeningPorts(identity: server, ports: [ListeningPort(port: 3000, family: .dual, scope: .loopback)])])
        #expect(snapshot.ports(for: server).map(\.port) == [3000])
        #expect(snapshot.ports(for: gone).isEmpty)
        #expect(snapshot.notices.filter { $0.contains("Listening ports") } == ["Listening ports of 3 root/other-user processes are not visible."])
    }

    @Test("JSON without listeningPorts decodes as empty; with them it round-trips")
    func codableBackwardCompatible() throws {
        let base = SyntheticSnapshots.oldNextServer
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
        var stripped = old
        stripped.removeValue(forKey: "listeningPorts")
        let decoded = try JSONDecoder().decode(ScanSnapshot.self, from: JSONSerialization.data(withJSONObject: stripped))
        #expect(decoded.listeningPorts.isEmpty)
        #expect(decoded == base)

        let identity = base.processes[1].identity
        let ported = withPorts(base, [ProcessListeningPorts(identity: identity, ports: [
            ListeningPort(port: 3000, family: .dual, scope: .allInterfaces),
            ListeningPort(port: 9229, family: .ipv4, scope: .specificAddress, address: "10.0.0.5"),
        ])])
        #expect(try JSONDecoder().decode(ScanSnapshot.self, from: JSONEncoder().encode(ported)) == ported)
    }

    @Test("Findings for a listening group gain one evidence line; severity and ranking don't change")
    func rulesEvidence() throws {
        let base = SyntheticSnapshots.oldNextServer
        let groups = ProvenanceResolver.resolve(base)
        let without = RulesEngine().evaluate(base, groups: groups)
        let ported = withPorts(base, [ProcessListeningPorts(identity: base.processes[1].identity, ports: [
            ListeningPort(port: 9229, family: .ipv4, scope: .loopback),
            ListeningPort(port: 3000, family: .dual, scope: .loopback),
        ])])
        let with = RulesEngine().evaluate(ported, groups: groups)
        #expect(with.map(\.id) == without.map(\.id))
        #expect(with.map(\.severity) == without.map(\.severity))
        let stale = try #require(with.first { $0.kind == .staleDevServer })
        #expect(stale.evidence.filter { $0.label == "Listening on" }.map(\.value) == [":3000, :9229"])
        let before = try #require(without.first { $0.kind == .staleDevServer })
        #expect(stale.evidence.count == before.evidence.count + 1)
    }

    @Test("Reports list ports with the process and project, sanitized; the JSON has no bind address")
    func exports() throws {
        let home = SyntheticSnapshots.home
        let server = SyntheticSnapshots.process(pid: 123, name: "next-server", executablePath: "/usr/local/bin/node",
                                                arguments: ["next-server"], currentDirectory: home + "/Developer/my-app", cpu: 1)
        let lan = SyntheticSnapshots.process(pid: 200, name: "python3", currentDirectory: home, cpu: 0)
        let base = SyntheticSnapshots.snapshot([server, lan])
        let snapshot = withPorts(base, [
            ProcessListeningPorts(identity: server.identity, ports: [ListeningPort(port: 3000, family: .dual, scope: .loopback)]),
            ProcessListeningPorts(identity: lan.identity, ports: [ListeningPort(port: 8765, family: .ipv4, scope: .specificAddress,
                                                                                 address: "192.168.1.20")]),
        ])
        let groups = [
            ProcessGroup(root: server.identity, members: [server.identity], kind: "next dev", label: "Next.js dev server",
                         project: ProjectAttribution(directory: home + "/Developer/my-app", basis: "cwd", confidence: .high),
                         confidence: .high, evidence: []),
        ]
        let text = Redactor.textReport(snapshot, groups: groups, findings: [], homeDirectory: home)
        #expect(text.contains("Listening ports:\n- :3000 (loopback) — next-server, PID 123, project my-app\n"
                              + "- :8765 (specific address) — python3, PID 200, Unknown project\n"))

        let json = try Redactor.jsonReport(snapshot, groups: groups, findings: [], homeDirectory: home)
        let jsonText = String(decoding: json, as: UTF8.self)
        #expect(!jsonText.contains(home))
        #expect(!jsonText.contains("192.168.1.20"))
        let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let ports = try #require(object["listeningPorts"] as? [[String: Any]])
        #expect(ports.count == 2)
        #expect(ports[0]["port"] as? Int == 3000)
        #expect(ports[0]["projectDirectory"] as? String == "~/Developer/my-app")
        #expect(ports[0]["groupLabel"] as? String == "Next.js dev server")
        #expect(ports[1]["scope"] as? String == "specific address")

        let none = Redactor.textReport(base, groups: groups, findings: [], homeDirectory: home)
        #expect(none.contains("Listening ports:\n- none\n"))
    }
}

/// Hands out one fixed reading and counts how often it was asked.
private final class OneReading: ProcessSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let processes: [ProcessReading]
    init(_ processes: [ProcessReading]) { self.processes = processes }
    var calls: Int { lock.withLock { count } }
    func snapshot() throws -> ProcessCounters {
        lock.withLock { count += 1 }
        return ProcessCounters(monotonicNanoseconds: ProcessCounters.monotonicNow(), wallClock: Date(), processes: processes)
    }
}

/// Fails the test if a ports read touches host counters or state.
private struct UnusedSystemSampler: SystemSampling {
    func counters() -> HostCounters {
        Issue.record("ports() read host counters")
        return HostCounters(perCore: nil, swapOuts: nil)
    }
    func state() async throws -> HostState {
        Issue.record("ports() read host state")
        throw CancellationError()
    }
}

@Suite("Ports without a CPU sample")
struct PortsSnapshotTests {
    @Test("coordinator.ports() reads processes once, samples ports once, and skips host and CPU sampling")
    func coordinatorPorts() async throws {
        let start = Int64(Date().timeIntervalSince1970 * 1_000_000) - 60_000_000
        let server = ProcessIdentity(pid: 4242, startTimeMicros: start)
        let other = ProcessIdentity(pid: 4300, startTimeMicros: start)
        let unknown = ProcessIdentity(pid: 4400, startTimeMicros: start)
        let readings = [server, other].map {
            ProcessReading(identity: $0, parentPID: 1, owner: .currentUser, name: "fake-\($0.pid)",
                           cpu: CPUTime(userNanoseconds: 5_000_000_000, systemNanoseconds: 0), residentBytes: 4096,
                           detailAccess: .available)
        }
        let processes = OneReading(readings)
        let seen = Recorder<[Int32]>()
        let ports = FixedPortSampler { processes in
            seen.append(processes.map(\.identity.pid))
            return PortReading(ports: [
                ProcessListeningPorts(identity: server, ports: [ListeningPort(port: 3000, family: .dual, scope: .loopback)]),
                // Not in the reading: dropped.
                ProcessListeningPorts(identity: unknown, ports: [ListeningPort(port: 4000, family: .ipv4, scope: .loopback)]),
            ], refusedCount: 2)
        }
        let coordinator = ScanCoordinator(processSampler: processes, systemSampler: UnusedSystemSampler(), portSampler: ports)
        let snapshot = try await coordinator.ports()
        #expect(processes.calls == 1)
        #expect(seen.values == [[4242, 4300]])
        #expect(snapshot.interval == 0)
        #expect(snapshot.processes.map(\.pid) == [4242, 4300])
        #expect(snapshot.processes.allSatisfy { $0.cpu == nil && $0.cpuPercentOfOneCore == nil })
        #expect(snapshot.listeningPorts == [ProcessListeningPorts(identity: server, ports: [ListeningPort(port: 3000, family: .dual, scope: .loopback)])])
        #expect(snapshot.notices == ["Listening ports of 2 root/other-user processes are not visible."])
    }

    @Test("The ports reports use the scan report's port lines and rows, sanitized, with a header and notices")
    func portsReports() throws {
        let home = SyntheticSnapshots.home
        let server = SyntheticSnapshots.process(pid: 123, name: "next-server", executablePath: "/usr/local/bin/node",
                                                arguments: ["next-server"], currentDirectory: home + "/Developer/my-app", cpu: 1)
        let lan = SyntheticSnapshots.process(pid: 200, name: "python3", currentDirectory: home, cpu: 0)
        let snapshot = withPorts(SyntheticSnapshots.snapshot([server, lan]), [
            ProcessListeningPorts(identity: server.identity, ports: [ListeningPort(port: 3000, family: .dual, scope: .loopback)]),
            ProcessListeningPorts(identity: lan.identity, ports: [ListeningPort(port: 8765, family: .ipv4, scope: .specificAddress,
                                                                                 address: "192.168.1.20")]),
        ], notices: ["Listening ports of 3 root/other-user processes are not visible."])
        let groups = [
            ProcessGroup(root: server.identity, members: [server.identity], kind: "next dev", label: "Next.js dev server",
                         project: ProjectAttribution(directory: home + "/Developer/my-app", basis: "cwd", confidence: .high),
                         confidence: .high, evidence: []),
        ]
        let text = Redactor.portsTextReport(snapshot, groups: groups, homeDirectory: home)
        let section = "Listening ports:\n- :3000 (loopback) — next-server, PID 123, project my-app\n"
            + "- :8765 (specific address) — python3, PID 200, Unknown project\n"
        #expect(text.hasPrefix("HeatLens listening ports, read "))
        #expect(text.hasSuffix("Notices: Listening ports of 3 root/other-user processes are not visible.\n" + section))
        // Same lines as the scan report's section.
        #expect(Redactor.textReport(snapshot, groups: groups, findings: [], homeDirectory: home).contains(section))
        #expect(!text.contains(home) && !text.contains("192.168.1.20"))

        let json = try Redactor.portsJSONReport(snapshot, groups: groups, homeDirectory: home)
        let jsonText = String(decoding: json, as: UTF8.self)
        #expect(!jsonText.contains(home) && !jsonText.contains("192.168.1.20"))
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(object.keys) == ["readAt", "notices", "listeningPorts"])
        let full = try #require(try JSONSerialization.jsonObject(with: Redactor.jsonReport(snapshot, groups: groups, findings: [],
                                                                                          homeDirectory: home)) as? [String: Any])
        #expect(NSArray(array: object["listeningPorts"] as? [Any] ?? []) == NSArray(array: full["listeningPorts"] as? [Any] ?? []))
        #expect((object["listeningPorts"] as? [Any])?.count == 2)

        let none = Redactor.portsTextReport(SyntheticSnapshots.snapshot([server]), groups: groups, homeDirectory: home)
        #expect(none.hasSuffix("Listening ports:\n- none\n"))
    }

    @Test("Live: ScanPipeline.ports() finds this process's loopback listener in well under a second")
    func livePipelinePorts() async throws {
        let listener = try LoopbackListener()
        let clock = ContinuousClock()
        let began = clock.now
        let ports = try await ScanPipeline().ports()
        let took = began.duration(to: clock.now)
        #expect(took < .seconds(1), "took \(took)")
        #expect(ports.listings.contains { $0.identity.pid == getpid() && $0.port.port == listener.port && $0.port.scope == .loopback })
        #expect(ports.snapshot.interval == 0)
        withExtendedLifetime(listener) {}
    }
}
