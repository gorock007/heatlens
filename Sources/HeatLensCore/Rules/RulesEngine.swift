import Foundation

public struct RuleThresholds: Sendable {
    public static let mediumCPUPercent = 50.0
    public static let highCPUPercent = 150.0
    public static let staleUptime: TimeInterval = 12 * 60 * 60
    public static let staleCPUPercent = 2.0
    public static let detachedUptime: TimeInterval = 24 * 60 * 60
    public static let detachedCPUPercent = 2.0
    public static let windowServerCPUPercent = 30.0
    public static let kernelTaskCPUPercent = 50.0
    public static let highSwapBytes: UInt64 = 1 << 30

    public static let `default` = RuleThresholds()

    public let mediumCPUPercent: Double
    public let highCPUPercent: Double
    public let staleUptime: TimeInterval
    public let staleCPUPercent: Double
    public let detachedUptime: TimeInterval
    public let detachedCPUPercent: Double
    public let windowServerCPUPercent: Double
    public let kernelTaskCPUPercent: Double
    public let highSwapBytes: UInt64

    public init(
        mediumCPUPercent: Double = RuleThresholds.mediumCPUPercent,
        highCPUPercent: Double = RuleThresholds.highCPUPercent,
        staleUptime: TimeInterval = RuleThresholds.staleUptime,
        staleCPUPercent: Double = RuleThresholds.staleCPUPercent,
        detachedUptime: TimeInterval = RuleThresholds.detachedUptime,
        detachedCPUPercent: Double = RuleThresholds.detachedCPUPercent,
        windowServerCPUPercent: Double = RuleThresholds.windowServerCPUPercent,
        kernelTaskCPUPercent: Double = RuleThresholds.kernelTaskCPUPercent,
        highSwapBytes: UInt64 = RuleThresholds.highSwapBytes
    ) {
        self.mediumCPUPercent = mediumCPUPercent
        self.highCPUPercent = highCPUPercent
        self.staleUptime = staleUptime
        self.staleCPUPercent = staleCPUPercent
        self.detachedUptime = detachedUptime
        self.detachedCPUPercent = detachedCPUPercent
        self.windowServerCPUPercent = windowServerCPUPercent
        self.kernelTaskCPUPercent = kernelTaskCPUPercent
        self.highSwapBytes = highSwapBytes
    }
}

public struct RulesEngine: Sendable {
    public let thresholds: RuleThresholds

    public init(thresholds: RuleThresholds = .default) {
        self.thresholds = thresholds
    }

    /// Ranked impact-first: current measured impact, then severity/uncertainty.
    public func evaluate(_ snapshot: ScanSnapshot, groups: [ProcessGroup]) -> [DiagnosticFinding] {
        let processes = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.identity, $0) })
        let evaluatedAt = snapshot.startedAt.addingTimeInterval(snapshot.interval)
        var candidates: [RankedFinding] = []

        for group in groups {
            let samples = group.members.compactMap { processes[$0] }
            let cpu = samples.compactMap(\.cpuPercentOfOneCore).reduce(0, +)
            let uptime = samples.map { $0.identity.uptime(at: evaluatedAt) }.max() ?? 0

            if cpu >= thresholds.mediumCPUPercent {
                let severity: Severity = cpu >= thresholds.highCPUPercent ? .high : .medium
                let activeKind = activeWorkKinds.contains(group.kind)
                let explanation = activeKind
                    ? "This workload used \(formatPercent(cpu)) of one CPU core during the scan and looks like active work, not junk."
                    : "This workload used \(formatPercent(cpu)) of one CPU core during the scan and is a current contributor."
                candidates.append(ranked(
                    title: "Sustained high CPU: \(group.label)",
                    severity: severity,
                    confidence: .high,
                    explanation: explanation,
                    evidence: group.evidence + [Evidence(label: "Group CPU", value: formatPercent(cpu), source: "sample interval delta")],
                    limitations: ["High CPU can be useful work; this finding does not mean the process is unwanted."],
                    group: group,
                    samples: samples,
                    impact: cpu,
                    key: "cpu-\(group.root.pid)-\(group.root.startTimeMicros)"
                ))
            }

            if devServerKinds.contains(group.kind), uptime >= thresholds.staleUptime, cpu < thresholds.staleCPUPercent {
                candidates.append(ranked(
                    title: "Potential stale development server",
                    severity: .review,
                    confidence: .medium,
                    explanation: "This \(group.kind) group has been running for \(formatDuration(uptime)) and used only \(formatPercent(cpu)) during the scan, so it may be a leftover rather than a current heat source.",
                    evidence: group.evidence + uptimeEvidence(uptime) + [Evidence(label: "Group CPU", value: formatPercent(cpu), source: "sample interval delta")],
                    limitations: ["This server may be intentionally always-on."],
                    group: group,
                    samples: samples,
                    impact: cpu,
                    key: "stale-\(group.root.pid)-\(group.root.startTimeMicros)"
                ))
            }

            if let root = processes[group.root], root.parentPID == 1,
               isScriptWorkload(group: group, root: root), uptime >= thresholds.detachedUptime,
               cpu < thresholds.detachedCPUPercent {
                candidates.append(ranked(
                    title: "Potential detached worker",
                    severity: .review,
                    confidence: .medium,
                    explanation: "This project worker has PPID 1, has run for \(formatDuration(uptime)), and used only \(formatPercent(cpu)); it merits review but is not causing meaningful heat now.",
                    evidence: group.evidence + [
                        Evidence(label: "Parent PID", value: "1", source: "process sample"),
                        Evidence(label: "Uptime", value: formatDuration(uptime), source: "process start time"),
                        Evidence(label: "Group CPU", value: formatPercent(cpu), source: "sample interval delta"),
                    ],
                    limitations: ["PPID 1 is a clue, not proof.", "This does not prove it is unused."],
                    group: group,
                    samples: samples,
                    impact: cpu,
                    key: "detached-\(group.root.pid)-\(group.root.startTimeMicros)"
                ))
            }
        }

        appendMemoryFinding(snapshot: snapshot, to: &candidates)
        appendUIAndKernelFindings(snapshot: snapshot, to: &candidates)
        appendThermalFinding(snapshot: snapshot, to: &candidates)

        return candidates.sorted {
            if $0.impact != $1.impact { return $0.impact > $1.impact }
            if $0.finding.severity != $1.finding.severity { return $0.finding.severity > $1.finding.severity }
            if confidenceRank($0.finding.confidence) != confidenceRank($1.finding.confidence) {
                return confidenceRank($0.finding.confidence) > confidenceRank($1.finding.confidence)
            }
            return $0.finding.title < $1.finding.title
        }.map(\.finding)
    }
}

private struct RankedFinding {
    let finding: DiagnosticFinding
    let impact: Double
}

private extension RulesEngine {
    var activeWorkKinds: Set<String> {
        ["next dev", "vite", "astro", "webpack", "turbo", "vitest", "jest", "tsc --watch", "claude", "opencode", "superset", "capcut", "app"]
    }

    var devServerKinds: Set<String> {
        ["next dev", "vite", "astro", "webpack", "turbo"]
    }

    func ranked(
        title: String,
        severity: Severity,
        confidence: Confidence,
        explanation: String,
        evidence: [Evidence],
        limitations: [String],
        group: ProcessGroup,
        samples: [ProcessSample],
        impact: Double,
        key: String
    ) -> RankedFinding {
        RankedFinding(
            finding: DiagnosticFinding(
                id: stableUUID(key),
                title: title,
                severity: severity,
                confidence: confidence,
                explanation: explanation,
                evidence: evidence,
                limitations: limitations,
                affectedProcesses: group.members,
                recommendedActions: actions(for: group, samples: samples)
            ),
            impact: impact
        )
    }

    func actions(for group: ProcessGroup, samples: [ProcessSample]) -> [SuggestedAction] {
        var actions: [SuggestedAction] = [.inspect(group.root)]
        if let project = group.project { actions.append(.openProject(path: project.directory)) }
        if let root = samples.first(where: { $0.identity == group.root }),
           group.kind != "system", root.owner == .currentUser,
           !["kernel_task", "windowserver", "launchd"].contains(root.name.lowercased()) {
            actions.append(.copyCommand(group.root))
        }
        actions.append(.openActivityMonitor)
        actions.append(.copyReport)
        return actions
    }

    func appendMemoryFinding(snapshot: ScanSnapshot, to candidates: inout [RankedFinding]) {
        let memory = snapshot.system.memory
        let impact = snapshot.system.busyCores * 100
        switch memory.pressure {
        case .warning, .critical:
            let severity: Severity = memory.pressure == .critical ? .high : .medium
            candidates.append(systemFinding(
                idKey: "memory-\(snapshot.id)-\(memory.pressure.rawValue)",
                title: memory.pressure == .critical ? "Critical memory pressure" : "Memory pressure warning",
                severity: severity,
                confidence: .high,
                explanation: "macOS reports \(memory.pressure.rawValue) memory pressure; this is the pressure signal, independent of RAM usage alone.",
                evidence: [
                    Evidence(label: "Memory pressure", value: memory.pressure.rawValue, source: "kern.memorystatus_vm_pressure_level"),
                    Evidence(label: "Swap-outs during scan", value: "\(memory.swapOutsDelta)", source: "vm.swapusage delta"),
                ],
                limitations: ["RAM usage alone is not evidence of memory pressure."],
                impact: impact
            ))
        case .normal where memory.swapUsedBytes >= thresholds.highSwapBytes:
            candidates.append(systemFinding(
                idKey: "swap-\(snapshot.id)",
                title: "Swap in use with normal pressure",
                severity: .info,
                confidence: .high,
                explanation: "Swap in use but the OS reports normal pressure.",
                evidence: [
                    Evidence(label: "Swap used", value: formatBytes(memory.swapUsedBytes), source: "vm.swapusage"),
                    Evidence(label: "Memory pressure", value: "normal", source: "kern.memorystatus_vm_pressure_level"),
                ],
                limitations: ["Existing swap can remain allocated after earlier pressure and does not by itself identify a current problem."],
                impact: 0
            ))
        case .normal, .unknown:
            break
        }
    }

    func appendUIAndKernelFindings(snapshot: ScanSnapshot, to candidates: inout [RankedFinding]) {
        for process in snapshot.processes {
            let cpu = process.cpuPercentOfOneCore ?? 0
            let lower = process.name.lowercased()
            if lower == "windowserver", cpu >= thresholds.windowServerCPUPercent {
                candidates.append(processInfoFinding(
                    process: process,
                    idKey: "windowserver-\(process.identity.startTimeMicros)",
                    title: "UI-heavy workload",
                    explanation: "WindowServer used \(formatPercent(cpu)) during the scan. This is a UI-compositing signal, not a GPU percentage.",
                    evidence: Evidence(label: "WindowServer CPU", value: formatPercent(cpu), source: "sample interval delta"),
                    limitations: ["There is no causal proof tying this activity to a particular app; this is not a GPU percentage."],
                    impact: cpu
                ))
            }
            if lower == "kernel_task", cpu >= thresholds.kernelTaskCPUPercent {
                candidates.append(processInfoFinding(
                    process: process,
                    idKey: "kernel-task-\(process.identity.startTimeMicros)",
                    title: "kernel_task activity",
                    explanation: "kernel_task used \(formatPercent(cpu)); this can be a signal of thermal management, not proof of overheating.",
                    evidence: Evidence(label: "kernel_task CPU", value: formatPercent(cpu), source: "sample interval delta"),
                    limitations: ["This is a signal of thermal management, not proof, and kernel_task must not be stopped."],
                    impact: cpu
                ))
            }
        }
    }

    func appendThermalFinding(snapshot: ScanSnapshot, to candidates: inout [RankedFinding]) {
        let state = snapshot.system.thermalState
        let severity: Severity?
        switch state {
        case .fair: severity = .info
        case .serious: severity = .medium
        case .critical: severity = .high
        case .nominal, .unavailable: severity = nil
        }
        guard let severity else { return }
        candidates.append(systemFinding(
            idKey: "thermal-\(snapshot.id)-\(state.rawValue)",
            title: "Thermal state: \(state.rawValue)",
            severity: severity,
            confidence: .high,
            explanation: "macOS reports a \(state.rawValue) thermal state.",
            evidence: [Evidence(label: "Thermal state", value: state.rawValue, source: "ProcessInfo.thermalState")],
            limitations: ["Thermal state is an OS signal, not a temperature reading or proof that one process caused it."],
            impact: snapshot.system.busyCores * 100
        ))
    }

    func systemFinding(
        idKey: String,
        title: String,
        severity: Severity,
        confidence: Confidence,
        explanation: String,
        evidence: [Evidence],
        limitations: [String],
        impact: Double
    ) -> RankedFinding {
        RankedFinding(
            finding: DiagnosticFinding(
                id: stableUUID(idKey),
                title: title,
                severity: severity,
                confidence: confidence,
                explanation: explanation,
                evidence: evidence,
                limitations: limitations,
                affectedProcesses: [],
                recommendedActions: [.openActivityMonitor, .copyReport]
            ),
            impact: impact
        )
    }

    func processInfoFinding(
        process: ProcessSample,
        idKey: String,
        title: String,
        explanation: String,
        evidence: Evidence,
        limitations: [String],
        impact: Double
    ) -> RankedFinding {
        RankedFinding(
            finding: DiagnosticFinding(
                id: stableUUID(idKey),
                title: title,
                severity: .info,
                confidence: .medium,
                explanation: explanation,
                evidence: [evidence],
                limitations: limitations,
                affectedProcesses: [process.identity],
                recommendedActions: [.inspect(process.identity), .openActivityMonitor, .copyReport]
            ),
            impact: impact
        )
    }

    func isScriptWorkload(group: ProcessGroup, root: ProcessSample) -> Bool {
        if group.kind == "node script" || group.kind == "bun" { return true }
        let executable = URL(fileURLWithPath: root.executablePath ?? root.name).lastPathComponent.lowercased()
        guard executable.hasPrefix("python") else { return false }
        return root.arguments?.dropFirst().contains(where: { $0.lowercased().hasSuffix(".py") }) == true
    }

    func uptimeEvidence(_ uptime: TimeInterval) -> [Evidence] {
        [Evidence(label: "Uptime", value: formatDuration(uptime), source: "process start time")]
    }

    func confidenceRank(_ confidence: Confidence) -> Int {
        switch confidence { case .low: 0; case .medium: 1; case .high: 2 }
    }

    func formatPercent(_ value: Double) -> String { String(format: "%.1f%%", value) }
    func formatDuration(_ seconds: TimeInterval) -> String { String(format: "%.1f h", seconds / 3_600) }
    func formatBytes(_ bytes: UInt64) -> String { String(format: "%.1f GiB", Double(bytes) / Double(1 << 30)) }

    func stableUUID(_ key: String) -> UUID {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in key.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte &+ 31)) &* 0x100000001b3
        }
        let hex = String(format: "%016llx%016llx", first, second)
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-4\(hex.dropFirst(13).prefix(3))-a\(hex.dropFirst(17).prefix(3))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidString) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}
