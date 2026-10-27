import Darwin
import Foundation
import Testing
@testable import HeatLensCore

/// Per-process CPU energy from `proc_pid_rusage` v6 (`ri_energy_nj`), docs/v2/ADR-0001 addendum.
@Suite("CPU energy")
struct EnergyTests {
    private let second: UInt64 = 1_000_000_000
    private let state = HostState(coreCount: 2, totalBytes: 1 << 30, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                                  compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0, memoryAvailable: true, pressure: .normal,
                                  availablePercent: nil, thermalState: .nominal, pmset: nil)

    private func cpu(_ seconds: Double) -> CPUTime { CPUTime(userNanoseconds: UInt64(seconds * 1e9), systemNanoseconds: 0) }

    private func reading(_ identity: ProcessIdentity, cpuSeconds: Double?, joules: Double?, owner: ProcessOwner = .currentUser,
                         access: DetailAccess = .available) -> ProcessReading {
        ProcessReading(identity: identity, parentPID: 1, owner: owner, name: "fake-\(identity.pid)",
                       cpu: cpuSeconds.map(cpu), residentBytes: 1 << 20, detailAccess: access,
                       energyNanojoules: joules.map { UInt64($0 * 1e9) })
    }

    private func micros(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000_000) }

    @Test("watts are nanojoules per nanosecond over the interval")
    func wattsMath() {
        #expect(CPUMath.watts(energyBefore: 1_000_000_000, energyAfter: 7_000_000_000, cpu: cpu(1), elapsedNanoseconds: 2 * second) == 3)
        #expect(CPUMath.watts(energyNanojoules: 500_000_000, cpu: cpu(0.1), elapsedNanoseconds: second) == 0.5)
    }

    @Test("a counter that went backwards, is missing, or stood still while the process ran is unavailable, not 0 W")
    func neverInventsZero() {
        #expect(CPUMath.watts(energyBefore: 9, energyAfter: 3, cpu: cpu(1), elapsedNanoseconds: second) == nil)
        #expect(CPUMath.watts(energyBefore: nil, energyAfter: 3, cpu: cpu(1), elapsedNanoseconds: second) == nil)
        #expect(CPUMath.watts(energyBefore: 3, energyAfter: nil, cpu: cpu(1), elapsedNanoseconds: second) == nil)
        #expect(CPUMath.watts(energyBefore: 5, energyAfter: 5, cpu: cpu(0.5), elapsedNanoseconds: second) == nil)
        #expect(CPUMath.watts(energyBefore: 5, energyAfter: 9, cpu: cpu(0.5), elapsedNanoseconds: 0) == nil)
        // An idle process really used no energy.
        #expect(CPUMath.watts(energyBefore: 5, energyAfter: 5, cpu: cpu(0), elapsedNanoseconds: second) == 0)
    }

    @Test("a scan gives survivors and births watts over the same window as their CPU; ps rows and exits get none")
    func assembly() throws {
        let t0 = Date()
        let own = ProcessIdentity(pid: 10, startTimeMicros: micros(t0) - 60_000_000)
        let root = ProcessIdentity(pid: 11, startTimeMicros: micros(t0) - 60_000_000)
        let gone = ProcessIdentity(pid: 12, startTimeMicros: micros(t0) - 60_000_000)
        // Born 1 s before the end of a 2 s scan, so its window is its 1 s lifetime.
        let born = ProcessIdentity(pid: 13, startTimeMicros: micros(t0) + 1_000_000)
        let before = ProcessCounters(monotonicNanoseconds: 10 * second, wallClock: t0, processes: [
            reading(own, cpuSeconds: 1, joules: 4),
            reading(root, cpuSeconds: nil, joules: nil, owner: .root, access: .permissionDenied),
            reading(gone, cpuSeconds: 1, joules: 1),
        ])
        let after = ProcessCounters(monotonicNanoseconds: 12 * second, wallClock: t0.addingTimeInterval(2), processes: [
            reading(own, cpuSeconds: 2, joules: 10),
            reading(root, cpuSeconds: nil, joules: nil, owner: .root, access: .permissionDenied),
            reading(born, cpuSeconds: 0.5, joules: 1.5),
        ])
        let psBefore = PSTimeSampler.Reading(monotonicNanoseconds: 10 * second, rows: [11: .init(cpuNanoseconds: 1 * second, residentBytes: 1)])
        let psAfter = PSTimeSampler.Reading(monotonicNanoseconds: 12 * second, rows: [11: .init(cpuNanoseconds: 2 * second, residentBytes: 1)])
        let snapshot = ScanAssembly.snapshot(startedAt: t0, before: before, after: after, psBefore: psBefore, psAfter: psAfter,
                                             psFailure: nil, hostBefore: HostCounters(perCore: nil, swapOuts: nil),
                                             hostAfter: HostCounters(perCore: nil, swapOuts: nil), state: state)
        let sample = { (id: ProcessIdentity) in snapshot.processes.first { $0.identity == id } }
        #expect(sample(own)?.cpuWatts == 3)
        let bornWatts = try #require(sample(born)?.cpuWatts)
        #expect(abs(bornWatts - 1.5) < 0.1)
        #expect(sample(root)?.cpuPercentOfOneCore == 50)
        #expect(sample(root)?.cpuWatts == nil)
        #expect(sample(gone)?.detailAccess == .processExited && sample(gone)?.cpuWatts == nil)
        // The total is energy over the whole 2 s: (6 J + 1.5 J) / 2 s. Adding the born process's
        // 1.5 W (over its own 1 s) to the survivor's 3 W would overcount it as 4.5 W.
        #expect(abs((snapshot.measuredCPUWatts ?? 0) - 3.75) < 0.01)
        #expect(sample(own)?.cpuEnergyNanojoules == 6_000_000_000)
    }

    @Test("group and total sums skip unreadable members and are nil, not 0, when nobody has a reading")
    func sums() {
        let a = SyntheticSnapshots.process(pid: 1, name: "node", cpu: 50, cpuWatts: 1.5)
        let b = SyntheticSnapshots.process(pid: 2, name: "node", cpu: 25, cpuWatts: 0.75)
        let r = SyntheticSnapshots.process(pid: 3, owner: .root, name: "kernel-ish", cpu: 10, detailAccess: .permissionDenied)
        let snapshot = SyntheticSnapshots.snapshot([a, b, r])
        #expect(snapshot.cpuWatts(for: [a.identity, b.identity, r.identity]) == 2.25)
        #expect(snapshot.cpuWatts(for: [r.identity]) == nil)
        #expect(snapshot.measuredCPUWatts == 2.25)
        #expect(SyntheticSnapshots.snapshot([r]).measuredCPUWatts == nil)
    }

    @Test("the high-CPU finding names the group's energy; reports carry it in text and JSON")
    func findingsAndReports() throws {
        let hot = SyntheticSnapshots.process(pid: 4242, name: "node", executablePath: "/opt/homebrew/bin/node",
                                             arguments: ["node", "build.js"], currentDirectory: SyntheticSnapshots.home + "/Developer/app",
                                             cpu: 180, cpuWatts: 5.4)
        let snapshot = SyntheticSnapshots.snapshot([hot])
        let groups = ProvenanceResolver.resolve(snapshot)
        let findings = RulesEngine().evaluate(snapshot, groups: groups)
        let finding = try #require(findings.first { $0.kind == .highCPU })
        #expect(finding.evidence.contains { $0.label == "Group CPU energy" && $0.value == "5.4 W" })

        let text = Redactor.textReport(snapshot, groups: groups, findings: findings, homeDirectory: SyntheticSnapshots.home)
        #expect(text.contains("PID 4242 node; CPU 180.0% (5.40 W);"))
        let json = try Redactor.jsonReport(snapshot, groups: groups, findings: findings, homeDirectory: SyntheticSnapshots.home)
        #expect(String(decoding: json, as: UTF8.self).contains("\"cpuWatts\" : 5.4"))
    }

    @Test("samples saved before the field existed still decode, without energy")
    func decodesOldJSON() throws {
        let sample = SyntheticSnapshots.process(pid: 5, name: "old", cpu: 1)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        object.removeValue(forKey: "cpuWatts")
        let decoded = try JSONDecoder().decode(ProcessSample.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.cpuWatts == nil && decoded.identity == sample.identity)
    }
}

@Suite("CPU energy against this Mac", .serialized)
struct EnergyLiveTests {
    @Test("this test process reports its own energy, and busy work reads as plausible watts")
    func ownProcess() throws {
        let first = try Libproc.rusage(getpid()).get()
        guard let start = first.energyNanojoules else { return } // A kernel without rusage v6 (not this Mac).
        let t0 = ProcessCounters.monotonicNow()
        var x = 0.0
        while ProcessCounters.monotonicNow() - t0 < 300_000_000 { x += sin(x) + 1 }
        let second = try Libproc.rusage(getpid()).get()
        let end = try #require(second.energyNanojoules)
        let elapsed = ProcessCounters.monotonicNow() - t0
        #expect(x > 0)
        // On a VM the counter may stand still; that must come out as unavailable, never 0 W.
        guard end > start else { return }
        let watts = Double(end - start) / Double(elapsed)
        // One busy thread on Apple Silicon: roughly 0.3 W (E-core) to 8 W (P-core at full clock).
        #expect((0.1...20).contains(watts), "measured \(watts) W")
    }

    @Test("a real reading gives the current-user processes energy and root processes none")
    func realSampler() throws {
        let readings = try LibprocProcessSampler().snapshot().processes
        let me = try #require(readings.first { $0.identity.pid == getpid() })
        #expect(me.energyNanojoules != nil)
        #expect(!readings.contains { $0.owner == .root && $0.detailAccess == .permissionDenied && $0.energyNanojoules != nil })
    }
}
