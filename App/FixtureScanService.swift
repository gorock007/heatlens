import Foundation
import HeatLensCore

/// Synthetic scan modelled on PRD §7, for SwiftUI previews only (the app runs
/// `PipelineScanService`). Every path, PID and name here is invented; nothing is read from this Mac.
struct FixtureScanService: ScanService {
    func run(duration: TimeInterval, progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> ScanReport {
        let startedAt = Date()
        let seconds = max(1, Int(duration.rounded(.up)))
        for second in 1...seconds {
            try await Task.sleep(for: .seconds(1))
            progress(min(TimeInterval(second), duration))
        }
        return Self.report(startedAt: startedAt, interval: duration)
    }

    static func report(startedAt: Date, interval: TimeInterval) -> ScanReport {
        let fixture = Fixture(now: startedAt)
        let snapshot = ScanSnapshot(startedAt: startedAt, interval: interval, system: fixture.system,
                                    processes: fixture.processes, notices: fixture.notices)
        return ScanReport(ScanResult(snapshot: snapshot, groups: fixture.groups, findings: fixture.findings))
    }
}

private struct Fixture {
    let now: Date

    private static let gib: UInt64 = 1 << 30
    private static let mib: UInt64 = 1 << 20
    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86_400

    private func identity(_ pid: Int32, age: TimeInterval) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTimeMicros: Int64((now.timeIntervalSince1970 - age) * 1_000_000))
    }

    private func process(_ pid: Int32, parent: Int32, age: TimeInterval, name: String, argv: [String]?,
                         cwd: String?, cpuPercent: Double?, megabytes: UInt64?,
                         owner: ProcessOwner = .currentUser) -> ProcessSample {
        let cpu = cpuPercent.map { CPUTime(userNanoseconds: UInt64($0 / 100 * 10e9 * 0.8),
                                           systemNanoseconds: UInt64($0 / 100 * 10e9 * 0.2)) }
        return ProcessSample(identity: identity(pid, age: age), parentPID: parent, owner: owner, name: name,
                             executablePath: argv?.first, arguments: argv, currentDirectory: cwd,
                             cpu: cpu, cpuPercentOfOneCore: cpuPercent,
                             residentBytes: megabytes.map { $0 * Self.mib },
                             footprintBytes: megabytes.map { $0 * Self.mib * 9 / 10 },
                             threadCount: owner == .currentUser ? 12 : nil,
                             detailAccess: owner == .currentUser ? .available : .permissionDenied)
    }

    // MARK: Processes

    var opencode: ProcessSample {
        process(4101, parent: 3990, age: 3 * Self.hour, name: "opencode",
                argv: ["/opt/homebrew/bin/opencode", "run", "<prompt>"], cwd: "~/Projects/jarvis-demo",
                cpuPercent: 31.2, megabytes: 380)
    }
    var opencodeWorker: ProcessSample {
        process(4102, parent: 4101, age: 3 * Self.hour, name: "opencode",
                argv: ["/opt/homebrew/bin/opencode", "worker"], cwd: "~/Projects/jarvis-demo",
                cpuPercent: 12.8, megabytes: 210)
    }
    var worker: ProcessSample {
        process(12874, parent: 1, age: 2 * Self.day + 5 * Self.hour, name: "node",
                argv: ["/usr/local/bin/node", "~/Projects/demo-site/scripts/worker.js"], cwd: "~/Projects/demo-site",
                cpuPercent: 0, megabytes: 96)
    }
    var npm: ProcessSample {
        process(23001, parent: 22990, age: 38 * Self.hour, name: "npm",
                argv: ["npm", "run", "dev"], cwd: "~/Projects/portfolio-demo", cpuPercent: 0, megabytes: 60)
    }
    var nextDev: ProcessSample {
        process(23002, parent: 23001, age: 38 * Self.hour, name: "node",
                argv: ["node", "~/Projects/portfolio-demo/node_modules/.bin/next", "dev"],
                cwd: "~/Projects/portfolio-demo", cpuPercent: 0.3, megabytes: 140)
    }
    var nextServer: ProcessSample {
        process(23003, parent: 23002, age: 38 * Self.hour, name: "next-server",
                argv: ["next-server (v15.0.0)"], cwd: "~/Projects/portfolio-demo", cpuPercent: 1.1, megabytes: 610)
    }
    var browser: ProcessSample {
        process(801, parent: 1, age: 6 * Self.hour, name: "Safari",
                argv: ["/Applications/Safari.app/Contents/MacOS/Safari"], cwd: "/", cpuPercent: 12.5, megabytes: 1240)
    }
    var windowServer: ProcessSample {
        process(160, parent: 1, age: 4 * Self.day, name: "WindowServer", argv: nil, cwd: nil,
                cpuPercent: nil, megabytes: nil, owner: .otherUser)
    }

    var processes: [ProcessSample] {
        [browser, opencode, opencodeWorker, nextServer, nextDev, npm, worker, windowServer]
    }

    // MARK: System

    var system: SystemSample {
        let memory = MemorySnapshot(totalBytes: 36 * Self.gib, freeBytes: 2 * Self.gib, activeBytes: 14 * Self.gib,
                                    inactiveBytes: 12 * Self.gib, wiredBytes: 4 * Self.gib,
                                    compressedBytes: 4 * Self.gib,
                                    swapUsedBytes: 17 * Self.gib / 2, swapTotalBytes: 10 * Self.gib,
                                    swapOutsDelta: 0, pressure: .normal, availablePercent: 41)
        let perCore = [0.62, 0.55, 0.48, 0.41, 0.30, 0.25, 0.20, 0.14, 0.12, 0.08, 0.05]
        return SystemSample(coreCount: 11, hostBusyFraction: 3.2 / 11, perCoreBusyFraction: perCore,
                            memory: memory, thermalState: .unavailable,
                            pmsetCPUSpeedLimit: nil, pmsetCPUSchedulerLimit: nil)
    }

    var notices: [String] {
        [
            "CPU and memory of root and other users' processes (such as WindowServer) are not accessible.",
            "Readable processes account for about half of the measured host load.",
        ]
    }

    // MARK: Groups

    var groups: [ProcessGroup] {
        [
            ProcessGroup(root: opencode.identity, members: [opencode.identity, opencodeWorker.identity],
                         kind: "opencode", label: "OpenCode agent",
                         project: ProjectAttribution(directory: "~/Projects/jarvis-demo", basis: "cwd", confidence: .high),
                         confidence: .high,
                         evidence: [Evidence(label: "argv[0]", value: "opencode", source: "argv")]),
            ProcessGroup(root: npm.identity, members: [npm.identity, nextDev.identity, nextServer.identity],
                         kind: "next dev", label: "Next.js dev server",
                         project: ProjectAttribution(directory: "~/Projects/portfolio-demo", basis: "cwd", confidence: .high),
                         confidence: .high,
                         evidence: [Evidence(label: "Command", value: "npm run dev → next dev", source: "argv")]),
            ProcessGroup(root: browser.identity, members: [browser.identity], kind: "app", label: "Safari",
                         project: nil, confidence: .high,
                         evidence: [Evidence(label: "Executable", value: "/Applications/Safari.app", source: "proc_pidpath")]),
            ProcessGroup(root: worker.identity, members: [worker.identity], kind: "node script",
                         label: "Node script worker.js",
                         project: ProjectAttribution(directory: "~/Projects/demo-site", basis: "argv path", confidence: .medium),
                         confidence: .medium,
                         evidence: [Evidence(label: "Parent", value: "launchd (PPID 1)", source: "proc_pidinfo")]),
            ProcessGroup(root: windowServer.identity, members: [windowServer.identity], kind: "unknown",
                         label: "WindowServer", project: nil, confidence: .low,
                         evidence: [Evidence(label: "Details", value: "Permission denied", source: "proc_pidinfo")]),
        ]
    }

    // MARK: Findings

    var findings: [DiagnosticFinding] {
        [
            DiagnosticFinding(
                title: "OpenCode agent is the top CPU contributor",
                severity: .medium, confidence: .high,
                explanation: "OpenCode used 44% CPU (of one core) across 2 processes. Its working directory "
                    + "suggests active agent work in jarvis-demo.",
                evidence: [
                    Evidence(label: "CPU in sample", value: "44.0% of one core (2 processes)", source: "proc_pid_rusage"),
                    Evidence(label: "Working directory", value: "~/Projects/jarvis-demo", source: "cwd"),
                    Evidence(label: "Command", value: "opencode run <prompt>", source: "argv"),
                ],
                limitations: [
                    "Project attribution comes from the working directory, not from reading project files.",
                    "Being busy does not mean it is the cause of heat.",
                ],
                affectedProcesses: [opencode.identity, opencodeWorker.identity],
                recommendedActions: [.inspect(opencode.identity), .openProject(path: "~/Projects/jarvis-demo"),
                                     .copyCommand(opencode.identity), .openActivityMonitor],
                kind: .highCPU),
            DiagnosticFinding(
                title: "Swap in use",
                severity: .info, confidence: .high,
                explanation: "8.5 GB of 10 GB swap is in use, but memory pressure is normal and nothing was "
                    + "swapped out during the sample.",
                evidence: [
                    Evidence(label: "Swap used", value: "8.5 GB of 10 GB", source: "vm.swapusage"),
                    Evidence(label: "Swap-outs in sample", value: "0", source: "vm_statistics64"),
                ],
                limitations: ["Swap stays allocated after the pressure that caused it has passed."],
                affectedProcesses: [],
                recommendedActions: [.openActivityMonitor, .copyReport],
                kind: .swapInUse),
            DiagnosticFinding(
                title: "Possible leftover development worker",
                severity: .review, confidence: .medium,
                explanation: "node …/scripts/worker.js · PID 12874 · elapsed 2d 5h · 0% CPU in sample · PPID 1. "
                    + "Long-lived project worker whose parent was adopted by launchd. Stopping it is unlikely "
                    + "to fix current heat.",
                evidence: [
                    Evidence(label: "Parent", value: "launchd (PPID 1)", source: "proc_pidinfo"),
                    Evidence(label: "Elapsed", value: "2d 5h", source: "proc_pidinfo"),
                    Evidence(label: "CPU in sample", value: "0.0% of one core", source: "proc_pid_rusage"),
                    Evidence(label: "Script", value: "~/Projects/demo-site/scripts/worker.js", source: "argv"),
                ],
                limitations: ["This does not prove it is unused."],
                affectedProcesses: [worker.identity],
                recommendedActions: [.inspect(worker.identity), .openProject(path: "~/Projects/demo-site"),
                                     .copyCommand(worker.identity), .requestStop(worker.identity)],
                kind: .detachedWorker),
            DiagnosticFinding(
                title: "Long-running dev server",
                severity: .review, confidence: .medium,
                explanation: "next dev for portfolio-demo has been running for 38h and used 1.4% CPU in the sample.",
                evidence: [
                    Evidence(label: "Command", value: "npm run dev → next dev → next-server", source: "argv"),
                    Evidence(label: "Elapsed", value: "1d 14h", source: "proc_pidinfo"),
                    Evidence(label: "Memory", value: "810 MB across 3 processes", source: "proc_pid_rusage"),
                ],
                limitations: ["You may still be using this server in a browser tab."],
                affectedProcesses: [npm.identity, nextDev.identity, nextServer.identity],
                recommendedActions: [.inspect(npm.identity), .openProject(path: "~/Projects/portfolio-demo"),
                                     .copyCommand(nextDev.identity), .requestStop(npm.identity)],
                kind: .staleDevServer),
        ]
    }
}
