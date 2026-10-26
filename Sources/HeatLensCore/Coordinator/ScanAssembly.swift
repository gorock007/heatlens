import Foundation

/// Turns the readings at both ends of a scan into a `ScanSnapshot`. Pure, so the matching
/// rules are testable with fake readings.
///
/// Matching rules:
/// - A process gets a CPU delta only when the full `ProcessIdentity` (pid + start time) is
///   in both readings. A PID whose start time changed (reuse) or that vanished keeps its
///   first reading's name/path/argv, with `cpu == nil` and `detailAccess = .processExited`.
/// - A process **born mid-scan** (absent at the start, started after the first reading) gets
///   its whole cumulative CPU, all of which fell inside the window, as `cpu`, and
///   `cpuPercentOfOneCore` over its own lifetime in the window (so a compiler that ran flat
///   out for 2 s of a 5 s scan reads ~100 %, not 40 %).
/// - Processes libproc refused get CPU and RSS from the two `ps` runs (`measurementSource = .ps`)
///   and keep `detailAccess = .permissionDenied`, since argv, cwd and footprint stay unreadable.
enum ScanAssembly {
    /// Shortest lifetime a born-mid-scan percentage is divided by, so a process seen a few
    /// milliseconds after birth does not read as thousands of percent.
    static let minimumLifetimeNanoseconds: UInt64 = 100_000_000

    static func snapshot(startedAt: Date, before: ProcessCounters, after: ProcessCounters,
                         psBefore: PSTimeSampler.Reading?, psAfter: PSTimeSampler.Reading?, psFailure: String?,
                         hostBefore: HostCounters, hostAfter: HostCounters, state: HostState) -> ScanSnapshot {
        let elapsed = after.monotonicNanoseconds > before.monotonicNanoseconds
            ? after.monotonicNanoseconds - before.monotonicNanoseconds : 0
        var psElapsed: UInt64 = 0
        if let psBefore, let psAfter, psAfter.monotonicNanoseconds > psBefore.monotonicNanoseconds {
            psElapsed = psAfter.monotonicNanoseconds - psBefore.monotonicNanoseconds
        }

        let beforeByPID = Dictionary(before.processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var survivors = Set<ProcessIdentity>()
        var samples: [ProcessSample] = []
        samples.reserveCapacity(after.processes.count + 16)

        for reading in after.processes {
            let pid = reading.identity.pid
            if let earlier = beforeByPID[pid], earlier.identity == reading.identity {
                survivors.insert(reading.identity)
                if let a = earlier.cpu, let b = reading.cpu, let delta = CPUMath.delta(before: a, after: b) {
                    samples.append(sample(reading, cpu: delta, over: elapsed, source: .libproc))
                } else if reading.detailAccess == .permissionDenied, psElapsed > 0,
                          let a = psBefore?.rows[pid], let b = psAfter?.rows[pid], b.cpuNanoseconds >= a.cpuNanoseconds {
                    let delta = CPUTime(userNanoseconds: b.cpuNanoseconds - a.cpuNanoseconds, systemNanoseconds: 0)
                    samples.append(sample(reading, cpu: delta, over: psElapsed, residentBytes: b.residentBytes, source: .ps))
                } else {
                    samples.append(sample(reading, cpu: nil, over: elapsed, source: nil))
                }
            } else if reading.identity.startDate > before.wallClock {
                // Born mid-scan (including a new process on a reused PID).
                let lifetime = UInt64(max(0, after.wallClock.timeIntervalSince(reading.identity.startDate)) * 1e9)
                let window = min(max(lifetime, minimumLifetimeNanoseconds), max(elapsed, minimumLifetimeNanoseconds))
                if let cpu = reading.cpu {
                    samples.append(sample(reading, cpu: cpu, over: window, source: .libproc))
                } else if reading.detailAccess == .permissionDenied, let row = psAfter?.rows[pid] {
                    samples.append(sample(reading, cpu: CPUTime(userNanoseconds: row.cpuNanoseconds, systemNanoseconds: 0),
                                          over: window, residentBytes: row.residentBytes, source: .ps))
                } else {
                    samples.append(sample(reading, cpu: nil, over: elapsed, source: nil))
                }
            } else {
                // Alive before the scan but missed by the first enumeration: no baseline.
                samples.append(sample(reading, cpu: nil, over: elapsed, source: nil))
            }
        }

        var exitedCount = 0
        for earlier in before.processes where !survivors.contains(earlier.identity) {
            exitedCount += 1
            samples.append(ProcessSample(identity: earlier.identity, parentPID: earlier.parentPID, owner: earlier.owner,
                                         name: earlier.name, executablePath: earlier.executablePath,
                                         arguments: earlier.arguments, currentDirectory: earlier.currentDirectory,
                                         cpu: nil, cpuPercentOfOneCore: nil, residentBytes: nil, footprintBytes: nil,
                                         threadCount: nil, detailAccess: .processExited))
        }
        samples.sort { ($0.identity.pid, $0.identity.startTimeMicros) < ($1.identity.pid, $1.identity.startTimeMicros) }

        let system = systemSample(hostBefore: hostBefore, hostAfter: hostAfter, state: state)
        let notices = notices(samples: samples, exitedCount: exitedCount, psFailure: psFailure,
                              elapsed: elapsed, hostBefore: hostBefore, hostAfter: hostAfter, system: system, state: state)
        return ScanSnapshot(startedAt: startedAt, interval: TimeInterval(elapsed) / 1e9, system: system,
                            processes: samples, notices: notices)
    }

    private static func sample(_ r: ProcessReading, cpu: CPUTime?, over window: UInt64, residentBytes: UInt64? = nil,
                               source: MeasurementSource?) -> ProcessSample {
        let rss = residentBytes ?? r.residentBytes
        return ProcessSample(identity: r.identity, parentPID: r.parentPID, owner: r.owner, name: r.name,
                      executablePath: r.executablePath, arguments: r.arguments, currentDirectory: r.currentDirectory,
                      cpu: cpu,
                      cpuPercentOfOneCore: cpu.map { CPUMath.percentOfOneCore(cpuNanoseconds: $0.totalNanoseconds, elapsedNanoseconds: window) },
                      residentBytes: rss, footprintBytes: r.footprintBytes,
                      threadCount: r.threadCount, detailAccess: r.detailAccess,
                      measurementSource: cpu == nil && rss == nil ? nil : (source ?? .libproc))
    }

    private static func hostDeltas(_ before: HostCounters, _ after: HostCounters) -> [CPULoadTicks]? {
        guard let a = before.perCore, let b = after.perCore, a.count == b.count, !a.isEmpty else { return nil }
        let deltas = zip(a, b).map { CPUMath.delta(before: $0, after: $1) }
        // A 32-bit tick counter that wrapped makes that core unusable; drop the host reading
        // rather than report a skewed total.
        guard deltas.allSatisfy({ $0 != nil }) else { return nil }
        return deltas.compactMap { $0 }
    }

    static func systemSample(hostBefore: HostCounters, hostAfter: HostCounters, state: HostState) -> SystemSample {
        let deltas = hostDeltas(hostBefore, hostAfter)
        let total = deltas?.reduce(CPULoadTicks(user: 0, system: 0, idle: 0, nice: 0), +)
        var swapOutsDelta: UInt64 = 0
        if let a = hostBefore.swapOuts, let b = hostAfter.swapOuts, b >= a { swapOutsDelta = b - a }
        let memory = MemorySnapshot(totalBytes: state.totalBytes, freeBytes: state.freeBytes, activeBytes: state.activeBytes,
                                    inactiveBytes: state.inactiveBytes, wiredBytes: state.wiredBytes,
                                    compressedBytes: state.compressedBytes, swapUsedBytes: state.swapUsedBytes,
                                    swapTotalBytes: state.swapTotalBytes, swapOutsDelta: swapOutsDelta,
                                    pressure: state.pressure, availablePercent: state.availablePercent)
        return SystemSample(coreCount: deltas?.count ?? state.coreCount, hostBusyFraction: total?.busyFraction ?? 0,
                            perCoreBusyFraction: deltas?.map(\.busyFraction) ?? [], memory: memory,
                            thermalState: state.thermalState, pmsetCPUSpeedLimit: state.pmset?.cpuSpeedLimit,
                            pmsetCPUSchedulerLimit: state.pmset?.cpuSchedulerLimit)
    }

    static func notices(samples: [ProcessSample], exitedCount: Int, psFailure: String?, elapsed: UInt64,
                        hostBefore: HostCounters, hostAfter: HostCounters, system: SystemSample, state: HostState) -> [String] {
        var notices: [String] = []
        let refused = samples.filter { $0.detailAccess == .permissionDenied }
        let fromPS = refused.filter { $0.measurementSource == .ps }.count
        if fromPS > 0 {
            notices.append("CPU and memory for \(fromPS) root/other-user processes are from ps (10 ms resolution); "
                           + "their command line, working directory and footprint are not accessible.")
        }
        if let psFailure, !refused.isEmpty {
            notices.append("CPU for \(refused.count) root/other-user processes is unavailable: ps failed (\(psFailure)).")
        } else if refused.count > fromPS {
            notices.append("\(refused.count - fromPS) root/other-user processes have no CPU figure (not readable by libproc or ps).")
        }
        if samples.contains(where: { $0.detailAccess == .notSupported }) {
            notices.append("kernel_task (pid 0) is not readable by libproc or ps; its CPU counts only in the host total.")
        }
        if exitedCount > 0 {
            notices.append("\(exitedCount) processes exited during the scan and have no CPU figure.")
        }

        if hostDeltas(hostBefore, hostAfter) == nil {
            notices.append("Total CPU load unavailable (host_processor_info gave no usable reading).")
        } else if elapsed > 0 {
            let processCores = Double(samples.compactMap { $0.cpu?.totalNanoseconds }.reduce(0, +)) / Double(elapsed)
            let busyCores = system.busyCores
            if busyCores >= 0.05 {
                let share = processCores / busyCores * 100
                notices.append(String(format: "Per-process CPU accounts for %.0f%% of measured host load (%.1f of %.1f busy cores).",
                                      share, processCores, busyCores))
            }
        }
        if !state.memoryAvailable {
            notices.append("Memory statistics unavailable (host_statistics64 failed).")
        }
        if state.thermalState == .unavailable {
            notices.append("Thermal state unavailable.")
        }
        if let pmsetNotice = state.pmsetNotice {
            notices.append(pmsetNotice)
        }
        return notices
    }
}
