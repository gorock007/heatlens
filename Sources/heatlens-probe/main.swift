import Darwin
import Foundation
import HeatLensCore

// heatlens-probe: Phase 0a feasibility spike. Rough on purpose; prints one bounded-sample
// report. Flags: --duration <s> (default 5), --no-fixtures, --top <n>.

var duration: Double = 5
var useFixtures = true
var topN = 15
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--duration": duration = Double(it.next() ?? "") ?? duration
        case "--no-fixtures": useFixtures = false
        case "--top": topN = Int(it.next() ?? "") ?? topN
        default: print("unknown flag \(a)"); exit(2)
        }
    }
}
duration = min(max(duration, 1), 15)

func sysctlString(_ name: String) -> String {
    var len = 0
    guard sysctlbyname(name, nil, &len, nil, 0) == 0, len > 0 else { return "?" }
    var buf = [CChar](repeating: 0, count: len)
    guard sysctlbyname(name, &buf, &len, nil, 0) == 0 else { return "?" }
    return String(cString: buf)
}

let timebase = MachTimebase.current()
let myUID = getuid()
let coreCount = Int(sysctlUInt64("hw.ncpu") ?? 0)
let env = ProcessInfo.processInfo.environment
let sandboxed = env["APP_SANDBOX_CONTAINER_ID"]

func section(_ title: String) { print("\n== \(title) ==") }

print("heatlens-probe · \(Date()) · sample \(duration)s")
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(sysctlString("hw.model")) · \(sysctlString("machdep.cpu.brand_string")) · \(coreCount) cores (P \(sysctlUInt64("hw.perflevel0.physicalcpu") ?? 0) / E \(sysctlUInt64("hw.perflevel1.physicalcpu") ?? 0)) · RAM \(fmtBytes(sysctlUInt64("hw.memsize") ?? 0))")
print("timebase \(timebase.numer)/\(timebase.denom) · page size \(sysctlUInt64("hw.pagesize") ?? 0) · probe pid \(getpid()) uid \(myUID) · sandbox container: \(sandboxed ?? "none") · home \(redact(homeDirectory)) · NSHomeDirectory \(redact(NSHomeDirectory()))")

// MARK: 1. PID enumeration
section("1. PID enumeration")
let pids = listAllPIDs()
let kinfo = kinfoAll()
let psOut = runTool("/bin/ps", ["-A", "-o", "pid="])
let psLaunchError = lastLaunchError
let psPIDs: Set<pid_t> = Set((psOut?.stdout ?? "").split(whereSeparator: \.isNewline).compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) })
let libprocSet = Set(pids)
print("proc_listallpids: \(pids.count) · sysctl KERN_PROC_ALL: \(kinfo.count) · ps -A: \(psPIDs.count)\(psOut == nil ? " (ps could not launch: \(psLaunchError ?? "?"))" : "")")
if pids.isEmpty { errno = 0; let n = proc_listallpids(nil, 0); print("proc_listallpids returned \(n), errno \(Failure(code: errno))") }
print("pid 0 present: libproc \(libprocSet.contains(0)) · kinfo \(kinfo[0] != nil) · ps \(psPIDs.contains(0))")
let onlyPs = psPIDs.subtracting(libprocSet).sorted(), onlyLib = libprocSet.subtracting(psPIDs).sorted()
print("only in ps: \(onlyPs.prefix(10).map { "\($0)/\(kinfo[$0]?.comm ?? "?")" }) · only in libproc: \(onlyLib.prefix(10).map { "\($0)/\(kinfo[$0]?.comm ?? "?")" })")
print("(differences are expected to be transient processes, ps itself, and pid 0; ps counts are from a separate instant)")

// MARK: 2. Per-field availability by owner class
section("2. Per-process fields by owner (ok/total, errno of failures)")
enum Owner: String, CaseIterable { case own, root, other, unknown }
struct Tally { var ok = 0; var total = 0; var failures: [Failure: Int] = [:] }
let fields = ["bsdinfo(ppid,start,uid)", "taskinfo(cpu,rss)", "rusage_v4(cpu,footprint)", "pidpath", "cwd(vnodepath)", "argv(procargs2)"]
var tally: [String: [Owner: Tally]] = [:]
var bsdTable: [pid_t: BSDInfo] = [:]
var pathTable: [pid_t: String] = [:]
var cwdTable: [pid_t: String] = [:]
var argsTable: [pid_t: ProcessArguments] = [:]
var startAgreement = (agree: 0, differ: 0)
var commTruncated = 0
let fieldPIDs = Array(Set(pids).union(kinfo.keys)).sorted()
@MainActor func record(_ field: String, _ owner: Owner, _ failure: Failure?) {
    var t = tally[field, default: [:]][owner, default: Tally()]
    t.total += 1
    if let failure { t.failures[failure, default: 0] += 1 } else { t.ok += 1 }
    tally[field, default: [:]][owner] = t
}
for pid in fieldPIDs {
    let bsd = bsdInfo(pid)
    let uid: uid_t? = (try? bsd.get().uid) ?? kinfo[pid]?.uid
    let owner: Owner = uid.map { $0 == myUID ? .own : ($0 == 0 ? .root : .other) } ?? .unknown
    switch bsd {
    case .success(let info):
        bsdTable[pid] = info
        record(fields[0], owner, nil)
        if let k = kinfo[pid] {
            if k.startSec == Int(info.startSec) && k.startUSec == Int32(info.startUSec) { startAgreement.agree += 1 } else { startAgreement.differ += 1 }
        }
        if info.comm != info.name { commTruncated += 1 }
    case .failure(let f): record(fields[0], owner, f)
    }
    switch taskInfo(pid) { case .success: record(fields[1], owner, nil); case .failure(let f): record(fields[1], owner, f) }
    switch rusageV4(pid) { case .success: record(fields[2], owner, nil); case .failure(let f): record(fields[2], owner, f) }
    switch pidPath(pid) { case .success(let p): pathTable[pid] = p; record(fields[3], owner, nil); case .failure(let f): record(fields[3], owner, f) }
    switch currentDirectory(pid) { case .success(let c): cwdTable[pid] = c; record(fields[4], owner, nil); case .failure(let f): record(fields[4], owner, f) }
    switch processArguments(pid) { case .success(let a): argsTable[pid] = a; record(fields[5], owner, nil); case .failure(let f): record(fields[5], owner, f) }
}
print(pad("field", 26) + Owner.allCases.map { pad($0.rawValue, 12) }.joined() + "failure errnos")
for f in fields {
    var errs: [Failure: Int] = [:]
    let cells = Owner.allCases.map { o -> String in
        let t = tally[f]?[o] ?? Tally()
        for (k, v) in t.failures { errs[k, default: 0] += v }
        return pad("\(t.ok)/\(t.total)", 12)
    }
    print(pad(f, 26) + cells.joined() + errs.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: " "))
}
print("bsdinfo vs kinfo_proc start time: agree \(startAgreement.agree), differ \(startAgreement.differ) · pbi_name longer than 16-char pbi_comm for \(commTruncated) processes")
if let k0 = kinfo[0] { print("pid 0: kinfo comm \(k0.comm) uid \(k0.uid) · bsdinfo \(bsdTable[0].map { "ok comm=\($0.comm)" } ?? "failed") · taskinfo \((try? taskInfo(0).get()).map { _ in "ok" } ?? "failed") · rusage \((try? rusageV4(0).get()).map { _ in "ok" } ?? "failed")") }
if let b1 = bsdTable[1] { print("pid 1: \(b1.comm) uid \(b1.uid) path \(pathTable[1] ?? "-") args \(argsTable[1].map { "\($0.arguments)" } ?? "unavailable") cwd \(cwdTable[1] ?? "unavailable")") }
let argsOtherSample = pids.first { bsdTable[$0]?.uid != myUID && argsTable[$0] != nil }
print("argv readable for a non-own process: \(argsOtherSample.map { "yes, e.g. pid \($0) \(bsdTable[$0]?.comm ?? "")" } ?? "none")")
// Fallback check: does read-only `ps` (an Apple platform binary) report CPU time for root processes to us?
if let ps = runTool("/bin/ps", ["-A", "-o", "pid=,uid=,time=,rss=,comm="]) {
    var rootRows = 0, rootWithTime = 0, rootWithRSS = 0
    var samples: [String] = []
    for line in ps.stdout.split(whereSeparator: \.isNewline) {
        let cols = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard cols.count == 5, let uid = Int(cols[1]), uid == 0 else { continue }
        rootRows += 1
        if cols[2] != "0:00.00" { rootWithTime += 1 }
        if cols[3] != "0" { rootWithRSS += 1 }
        let comm = String(cols[4])
        if comm.hasSuffix("kernel_task") || comm.hasSuffix("WindowServer") || comm == "/sbin/launchd" { samples.append(line.trimmingCharacters(in: .whitespaces)) }
    }
    print("ps fallback for root processes: \(rootRows) rows · nonzero TIME \(rootWithTime) · nonzero RSS \(rootWithRSS) · e.g. \(samples)")
}

// MARK: 3. CPU sample
section("3. CPU sample (\(duration)s, 100% = one core)")
let fixtures = Fixtures()
if useFixtures {
    fixtures.startBusy()
    fixtures.startOrphan()
    for l in fixtures.log { print("  " + l) }
    usleep(300_000) // let `yes` reach steady state before the first snapshot
}
struct Reading { let identity: ProcessIdentity?; let task: TaskSample?; let ru: RusageSample? }
func snapshot(_ pids: [pid_t]) -> [pid_t: Reading] {
    var out: [pid_t: Reading] = [:]
    out.reserveCapacity(pids.count)
    for pid in pids {
        out[pid] = Reading(identity: try? bsdInfo(pid).get().identity, task: try? taskInfo(pid).get(), ru: try? rusageV4(pid).get())
    }
    return out
}
func enumerate() -> [pid_t] { let l = listAllPIDs(); return l.isEmpty ? Array(kinfoAll().keys).sorted() : l }
let pidsA = enumerate()
let hostA = hostCPUTicks()
let tA = mach_absolute_time()
let snapA = snapshot(pidsA)
let tAEnd = mach_absolute_time()
Thread.sleep(forTimeInterval: duration)
let pidsB = enumerate()
let hostB = hostCPUTicks()
let tB = mach_absolute_time()
let snapB = snapshot(pidsB)
let elapsedNs = timebase.nanoseconds(fromTicks: tB - tA)
for pid in pidsB where bsdTable[pid] == nil {
    if case .success(let b) = bsdInfo(pid) { bsdTable[pid] = b }
    if case .success(let p) = pidPath(pid) { pathTable[pid] = p }
    if case .success(let c) = currentDirectory(pid) { cwdTable[pid] = c }
    if case .success(let a) = processArguments(pid) { argsTable[pid] = a }
}
print("elapsed \(String(format: "%.3f", Double(elapsedNs) / 1e9))s (monotonic) · snapshot A took \(timebase.nanoseconds(fromTicks: tAEnd - tA) / 1_000_000) ms for \(pidsA.count) pids")

struct Usage { let pid: pid_t; let taskPct: Double?; let ruPct: Double?; let rss: UInt64?; let footprint: UInt64?; let threads: Int32? }
var usages: [Usage] = []
var vanished = 0, appeared = 0, identityMismatch = 0, noIdentity = 0, counterBackwards = 0
for pid in pidsB {
    guard let a = snapA[pid], let b = snapB[pid] else { appeared += 1; continue }
    guard let ia = a.identity, let ib = b.identity else { noIdentity += 1; continue }
    guard ia == ib else { identityMismatch += 1; continue }
    var taskPct: Double? = nil, ruPct: Double? = nil
    if let ta = a.task, let tb = b.task {
        if let d = CPUMath.delta(before: CPUTime(userTicks: ta.userTicks, systemTicks: ta.systemTicks, timebase: timebase),
                                 after: CPUTime(userTicks: tb.userTicks, systemTicks: tb.systemTicks, timebase: timebase)) {
            taskPct = CPUMath.percentOfOneCore(cpuNanoseconds: d.totalNanoseconds, elapsedNanoseconds: elapsedNs)
        } else { counterBackwards += 1 }
    }
    if let ra = a.ru, let rb = b.ru, ra.startAbsTicks == rb.startAbsTicks {
        if let d = CPUMath.delta(before: CPUTime(userTicks: ra.userTicks, systemTicks: ra.systemTicks, timebase: timebase),
                                 after: CPUTime(userTicks: rb.userTicks, systemTicks: rb.systemTicks, timebase: timebase)) {
            ruPct = CPUMath.percentOfOneCore(cpuNanoseconds: d.totalNanoseconds, elapsedNanoseconds: elapsedNs)
        }
    }
    usages.append(Usage(pid: pid, taskPct: taskPct, ruPct: ruPct, rss: b.task?.residentSize, footprint: b.ru?.physFootprint, threads: b.task?.threads))
}
vanished = Set(pidsA).subtracting(pidsB).count
let withDelta = usages.filter { $0.taskPct != nil }.count
let withRuDelta = usages.filter { $0.ruPct != nil }.count
let disagreements = usages.filter { u in if let t = u.taskPct, let r = u.ruPct { return abs(t - r) > 2 } else { return false } }.count
print("pids: \(pidsA.count) → \(pidsB.count) · vanished \(vanished) · appeared \(appeared) · identity changed \(identityMismatch) · no bsdinfo (EPERM/ESRCH) \(noIdentity) · counters backwards \(counterBackwards)")
print("CPU delta available: taskinfo \(withDelta)/\(usages.count) · rusage \(withRuDelta)/\(usages.count) · taskinfo vs rusage differ by >2 pts: \(disagreements)")
let sumPct = usages.compactMap(\.taskPct).reduce(0, +)
if let hostA, let hostB, hostA.count == hostB.count {
    let deltas = zip(hostA, hostB).compactMap { CPUMath.delta(before: $0, after: $1) }
    let total = deltas.reduce(CPULoadTicks(user: 0, system: 0, idle: 0, nice: 0), +)
    print(String(format: "host (host_processor_info): %.1f%% of %d cores busy = %.2f cores · user %.1f%% sys %.1f%% · per-core busy %%: ", total.busyFraction * 100, deltas.count, total.busyFraction * Double(deltas.count), Double(total.user) / Double(max(total.total, 1)) * 100, Double(total.system) / Double(max(total.total, 1)) * 100) + deltas.map { String(format: "%.0f", $0.busyFraction * 100) }.joined(separator: " "))
} else {
    print("host_processor_info unavailable")
}
print(String(format: "sum of per-process CPU: %.1f%% = %.2f cores (processes that lived through the interval only)", sumPct, sumPct / 100))
print("\ntop \(topN) by CPU:")
print(pad("pid", 7) + pad("cpu%", 8, right: true) + pad("ru%", 8, right: true) + pad("rss", 10, right: true) + pad("footprint", 11, right: true) + pad("thr", 5, right: true) + "  " + pad("owner", 6) + pad("age", 8) + "name · path")
for u in usages.sorted(by: { ($0.taskPct ?? -1) > ($1.taskPct ?? -1) }).prefix(topN) {
    let b = bsdTable[u.pid]
    let owner = b.map { $0.uid == myUID ? "own" : ($0.uid == 0 ? "root" : "other") } ?? "?"
    let age = b.map { fmtDuration($0.identity.uptime()) } ?? "?"
    print(pad("\(u.pid)", 7) + pad(u.taskPct.map { String(format: "%.1f", $0) } ?? "n/a", 8, right: true) + pad(u.ruPct.map { String(format: "%.1f", $0) } ?? "n/a", 8, right: true) + pad(u.rss.map(fmtBytes) ?? "n/a", 10, right: true) + pad(u.footprint.map(fmtBytes) ?? "n/a", 11, right: true) + pad(u.threads.map { "\($0)" } ?? "", 5, right: true) + "  " + pad(owner, 6) + pad(age, 8) + "\(b?.name ?? kinfo[u.pid]?.comm ?? "?") · \(truncate(redact(pathTable[u.pid] ?? "-"), 60))")
}
if let busy = fixtures.busyPID {
    let ours = usages.first { $0.pid == busy }
    let ps = runTool("/bin/ps", ["-o", "%cpu=", "-p", "\(busy)"])?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "n/a"
    print("\nbusy fixture `yes` pid \(busy): probe taskinfo \(ours?.taskPct.map { String(format: "%.1f%%", $0) } ?? "n/a") · rusage \(ours?.ruPct.map { String(format: "%.1f%%", $0) } ?? "n/a") · ps -o %cpu (decaying average, not interval): \(ps)%")
}

// MARK: 4. System memory
section("4. System memory")
let memTotal = sysctlUInt64("hw.memsize") ?? 0
if let vm = vmSnapshot() {
    print("vm_statistics64: free \(fmtBytes(vm.bytes(vm.free))) · active \(fmtBytes(vm.bytes(vm.active))) · inactive \(fmtBytes(vm.bytes(vm.inactive))) · speculative \(fmtBytes(vm.bytes(vm.speculative))) · wired \(fmtBytes(vm.bytes(vm.wired))) · compressed \(fmtBytes(vm.bytes(vm.compressor))) · of \(fmtBytes(memTotal))")
    print("cumulative since boot: compressions \(vm.compressions) · decompressions \(vm.decompressions) · swapins \(vm.swapins) · swapouts \(vm.swapouts) (deltas across a scan are the usable signal)")
} else { print("host_statistics64 failed") }
let (swap, swapErr) = swapUsage()
print("vm.swapusage: " + (swap.map { "used \(fmtBytes($0.used)) of \(fmtBytes($0.total)), encrypted \($0.encrypted)" } ?? "unavailable \(swapErr?.description ?? "")"))
let (lvl, lvlErr) = sysctlInt32("kern.memorystatus_vm_pressure_level")
print("kern.memorystatus_vm_pressure_level: " + (lvl.map { "\($0) = \(memoryPressureName($0))" } ?? "unavailable \(lvlErr?.description ?? "")"))
let (mlvl, mlvlErr) = sysctlInt32("kern.memorystatus_level")
print("kern.memorystatus_level (percent available): " + (mlvl.map { "\($0)" } ?? "unavailable \(mlvlErr?.description ?? "")"))

// MARK: 5. Thermal
section("5. Thermal")
print("ProcessInfo.thermalState: \(thermalStateName(ProcessInfo.processInfo.thermalState))")
if let therm = runTool("/usr/bin/pmset", ["-g", "therm"]) {
    let report = PmsetThermParser.parse(therm.stdout)
    print("pmset -g therm (exit \(therm.status)) raw:")
    for line in therm.stdout.split(whereSeparator: \.isNewline) { print("  | " + line) }
    if !therm.stderr.isEmpty { print("  stderr: \(therm.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    print("parsed: values \(report.values.sorted { $0.key < $1.key }) · throttling indicated: \(report.indicatesThrottling.map { "\($0)" } ?? "no limit keys reported")")
} else { print("pmset could not be launched") }
print("no temperature source is used or reported")

// MARK: 6. Real-world grouping
section("6. Grouping of own processes (ancestry + argv + cwd)")
let usageByPID = Dictionary(uniqueKeysWithValues: usages.map { ($0.pid, $0) })
var rows: [ProcRow] = []
for pid in pidsB {
    guard let b = bsdTable[pid] ?? (try? bsdInfo(pid).get()), b.uid == myUID else { continue }
    rows.append(ProcRow(pid: pid, ppid: b.ppid, uid: b.uid, comm: b.comm, name: b.name, path: pathTable[pid], cwd: cwdTable[pid],
                        args: argsTable[pid], start: b.identity.startDate, cpuPercent: usageByPID[pid]?.taskPct, footprint: usageByPID[pid]?.footprint))
}
var parentTable: [pid_t: (ppid: pid_t, comm: String)] = [:]
for (pid, k) in kinfoAll() { parentTable[pid] = (k.ppid, k.comm) }
for (pid, b) in bsdTable { parentTable[pid] = (b.ppid, b.comm) }
let classified = rows.map { ($0, classify($0), projectGuess($0)) }
let interesting = classified.filter { !["other", "shell"].contains($0.1.kind) }
print("own processes: \(rows.count) · with argv \(rows.filter { $0.args != nil }.count) · with cwd \(rows.filter { $0.cwd != nil }.count) · matched a rule: \(interesting.count)")
var kindCounts: [String: Int] = [:]
for c in classified { kindCounts[c.1.kind.split(separator: ":").first.map(String.init) ?? c.1.kind, default: 0] += 1 }
print("by kind: " + kindCounts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " · "))
print("\n" + pad("pid", 7) + pad("cpu%", 7, right: true) + "  " + pad("age", 8) + pad("ppid", 6) + pad("kind", 30) + pad("project (basis)", 46) + "ancestry → · argv")
for (r, c, p) in interesting.sorted(by: { ($0.0.cpuPercent ?? -1, $0.0.start) > ($1.0.cpuPercent ?? -1, $1.0.start) }).prefix(45) {
    let proj = (p.dir ?? "unknown project") + " (\(p.basis))"
    let anc = ancestry(of: r.pid, in: parentTable).prefix(4).joined(separator: " → ")
    let argv = truncate(redact(r.argv.joined(separator: " ")), 90)
    print(pad("\(r.pid)", 7) + pad(r.cpuPercent.map { String(format: "%.1f", $0) } ?? "n/a", 7, right: true) + "  " + pad(fmtDuration(Date().timeIntervalSince(r.start)), 8) + pad("\(r.ppid)", 6) + pad(truncate(c.kind, 29), 30) + pad(truncate(proj, 45), 46) + anc + " · " + argv)
}
func isSystemPath(_ path: String?) -> Bool {
    guard let path else { return false }
    return ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/Library/PrivilegedHelperTools/", "/private/var/", "/Applications/"].contains { path.hasPrefix($0) }
}
let allOrphans = classified.filter { $0.0.ppid == 1 }
let orphans = allOrphans.filter { r, c, p in
    !["other", "shell"].contains(c.kind) || !isSystemPath(r.path) || (p.dir.map { $0.hasPrefix("~/") && !$0.hasPrefix("~/Library") } ?? false)
}
print("\nown processes with PPID 1: \(allOrphans.count) (launchd-started agents, launchd-adopted orphans, and apps launched by Finder/Dock) · user-space candidates after dropping system/app paths: \(orphans.count)")
for (r, c, p) in orphans.sorted(by: { $0.0.start < $1.0.start }).prefix(30) {
    print("  \(pad("\(r.pid)", 7))\(pad(fmtDuration(Date().timeIntervalSince(r.start)), 8))\(pad(truncate(c.kind, 28), 29))\(pad(p.dir ?? "unknown project", 40)) \(truncate(redact(r.path ?? r.comm), 70))")
}
if let o = fixtures.orphanPID {
    let hit = orphans.first { $0.0.pid == o }
    let row = classified.first { $0.0.pid == o }
    print("orphan fixture pid \(o): \(hit != nil ? "listed as a PPID-1 candidate" : "NOT listed as a PPID-1 candidate") · in own rows: \(row != nil) · ppid \(row?.0.ppid.description ?? "?") · path \(row?.0.path ?? "nil") · cwd \(row?.0.cwd.map(redact) ?? "nil") · argv \(row?.0.argv ?? []) · ancestry \(ancestry(of: o, in: parentTable))")
}

// MARK: 7. Cleanup
section("7. Fixture cleanup")
if useFixtures {
    fixtures.stopAll()
    for l in fixtures.log.suffix(6) { print("  " + l) }
} else { print("  no fixtures") }
print("\ndone")
