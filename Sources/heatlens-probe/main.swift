import Darwin
import Foundation
import HeatLensCore

// heatlens-probe: dev CLI over ScanCoordinator. Runs one scan and prints the system summary,
// data-quality notices and the top processes by CPU. Prints real paths (home shown as ~) and
// process names from this Mac: never paste its output into the repo.
// Flags: --duration <1…15> (default 5), --no-fixtures, --top <n> (default 15),
// --report (print the redacted text report the app copies, from the same ScanPipeline, and exit).

var duration: Double = 5
var useFixtures = true
var topN = 15
var reportMode = false
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--duration": duration = Double(it.next() ?? "") ?? duration
        case "--no-fixtures": useFixtures = false
        case "--top": topN = Int(it.next() ?? "") ?? topN
        case "--report": reportMode = true
        default: print("unknown flag \(a)"); exit(2)
        }
    }
}

let fixtures = Fixtures()
if useFixtures {
    fixtures.startBusy()
    usleep(300_000) // let `yes` reach steady state before the first snapshot
}

func showProgress(_ elapsed: TimeInterval) {
    FileHandle.standardError.write(Data(String(format: "\rscanning… %.0fs", elapsed).utf8))
}

if reportMode {
    do {
        let result = try await ScanPipeline().run(duration: duration, progress: showProgress)
        FileHandle.standardError.write(Data("\r".utf8))
        fixtures.stopAll()
        print(Redactor.textReport(result.snapshot, groups: result.groups, findings: result.findings), terminator: "")
        exit(0)
    } catch {
        fixtures.stopAll()
        print("scan failed: \(error)")
        exit(1)
    }
}

let snapshot: ScanSnapshot
do {
    snapshot = try await ScanCoordinator().scan(duration: duration, progress: showProgress)
    FileHandle.standardError.write(Data("\r".utf8))
} catch {
    fixtures.stopAll()
    print("scan failed: \(error)")
    exit(1)
}

let system = snapshot.system
let memory = system.memory
print("heatlens-probe · \(snapshot.startedAt) · scan \(String(format: "%.2f", snapshot.interval))s")
print(String(format: "host: %.1f%% of %d cores busy = %.2f cores · per-core busy %%: ", system.hostBusyFraction * 100,
             system.coreCount, system.busyCores) + system.perCoreBusyFraction.map { String(format: "%.0f", $0 * 100) }.joined(separator: " "))
print("memory: free \(fmtBytes(memory.freeBytes)) · active \(fmtBytes(memory.activeBytes)) · inactive \(fmtBytes(memory.inactiveBytes)) · wired \(fmtBytes(memory.wiredBytes)) · compressed \(fmtBytes(memory.compressedBytes)) · of \(fmtBytes(memory.totalBytes))")
print("swap: \(fmtBytes(memory.swapUsedBytes)) of \(fmtBytes(memory.swapTotalBytes)) · swap-outs during scan \(memory.swapOutsDelta) · pressure \(memory.pressure.rawValue) · available \(memory.availablePercent.map { "\($0)%" } ?? "n/a")")
let limits = [system.pmsetCPUSpeedLimit.map { "speed \($0)%" }, system.pmsetCPUSchedulerLimit.map { "scheduler \($0)%" }].compactMap { $0 }
print("thermal: \(system.thermalState.rawValue) · pmset limits: \(limits.isEmpty ? "none reported" : limits.joined(separator: ", "))")

let processes = snapshot.processes
func count(_ predicate: (ProcessSample) -> Bool) -> Int { processes.filter(predicate).count }
print("processes: \(processes.count) · own \(count { $0.owner == .currentUser }) · root \(count { $0.owner == .root }) · other \(count { $0.owner == .otherUser }) · CPU from libproc \(count { $0.cpu != nil && $0.measurementSource == .libproc }) · from ps \(count { $0.cpu != nil && $0.measurementSource == .ps }) · exited \(count { $0.detailAccess == .processExited })")
print("\nnotices:")
for notice in snapshot.notices { print("  - " + notice) }

let byIdentity = Dictionary(processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
print("\nlistening ports (\(snapshot.listeningPorts.reduce(0) { $0 + $1.ports.count })):")
for entry in snapshot.listeningPorts {
    for port in entry.ports {
        let scope = port.scope == .specificAddress ? (port.address ?? "specific address") : port.scope.rawValue
        print("  :\(port.port) (\(scope), \(port.family.rawValue)) · \(byIdentity[entry.identity]?.name ?? "?") · PID \(entry.identity.pid)")
    }
}
do {
    // The coordinator's port read happens inside the scan; time the same read once more on its own.
    let readings = try LibprocProcessSampler().snapshot().processes
    let timing = LibprocPortSampler().listeningPorts(of: readings)
    print(String(format: "port sampling: %.1f ms for %d processes (%d skipped as other users')",
                 Double(timing.elapsedNanoseconds) / 1e6, readings.count, timing.refusedCount))
} catch {
    print("port sampling timing failed: \(error)")
}

print("\ntop \(topN) by CPU (100% = one core):")
print(pad("pid", 7) + pad("cpu%", 8, right: true) + pad("src", 8, right: true) + pad("rss", 10, right: true) + pad("footprint", 11, right: true) + pad("thr", 5, right: true) + "  " + pad("owner", 6) + pad("age", 8) + "name · path")
let ownerLabel: [ProcessOwner: String] = [.currentUser: "own", .root: "root", .otherUser: "other", .unknown: "?"]
for p in processes.filter({ $0.cpuPercentOfOneCore != nil }).sorted(by: { $0.cpuPercentOfOneCore! > $1.cpuPercentOfOneCore! }).prefix(topN) {
    let fixture = p.pid == fixtures.busyPID ? "  (fixture)" : ""
    print(pad("\(p.pid)", 7) + pad(String(format: "%.1f", p.cpuPercentOfOneCore!), 8, right: true)
          + pad(p.measurementSource?.rawValue ?? "-", 8, right: true) + pad(p.residentBytes.map(fmtBytes) ?? "n/a", 10, right: true)
          + pad(p.footprintBytes.map(fmtBytes) ?? "n/a", 11, right: true) + pad(p.threadCount.map { "\($0)" } ?? "", 5, right: true)
          + "  " + pad(ownerLabel[p.owner] ?? "?", 6) + pad(fmtDuration(p.identity.uptime()), 8)
          + "\(p.name) · \(truncate(redact(p.executablePath ?? "-"), 60))" + fixture)
}

if useFixtures {
    print("\nfixture self-test:")
    if let pid = fixtures.busyPID {
        let measured = processes.first { $0.pid == pid }?.cpuPercentOfOneCore
        let verdict = measured.map { $0 >= 80 ? "ok" : "LOW (busy machine?)" } ?? "MISSING"
        print("  busy `yes` pid \(pid): \(measured.map { String(format: "%.1f%%", $0) } ?? "n/a") of one core · expect ≥ 80% · \(verdict)")
    }
    fixtures.stopAll()
    for line in fixtures.log { print("  " + line) }
}
print("\ndone")
