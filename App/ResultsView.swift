import SwiftUI
import HeatLensCore

/// Read-only lookups the result views share.
struct ReportContext {
    let report: ScanReport
    let processes: [ProcessIdentity: ProcessSample]
    let observedAt: Date
    /// Findings the user's exclusions hide (Settings).
    let hiddenFindingIDs: Set<UUID>

    init(report: ScanReport, hiddenFindingIDs: Set<UUID> = []) {
        self.report = report
        self.hiddenFindingIDs = hiddenFindingIDs
        processes = Dictionary(report.snapshot.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        observedAt = report.snapshot.startedAt.addingTimeInterval(report.snapshot.interval)
    }

    func uptime(_ identity: ProcessIdentity) -> String {
        Format.uptime(identity.uptime(at: observedAt))
    }

    func project(for identity: ProcessIdentity) -> ProjectAttribution? {
        report.groups.first(where: { $0.members.contains(identity) })?.project
    }

    func findings(for identity: ProcessIdentity) -> [DiagnosticFinding] {
        report.findings.filter { $0.affectedProcesses.contains(identity) }
    }

    /// True when this process has findings and the user's exclusions hide every one of them;
    /// an exclusion also suppresses the stop offer.
    func isExcluded(_ identity: ProcessIdentity) -> Bool {
        let own = findings(for: identity)
        return !own.isEmpty && own.allSatisfy { hiddenFindingIDs.contains($0.id) }
    }

    func offersStop(for identity: ProcessIdentity) -> Bool {
        report.findings.contains { finding in
            finding.recommendedActions.contains {
                if case .requestStop(let offeredIdentity) = $0 { return offeredIdentity == identity }
                return false
            }
        }
    }

    func parentChain(for identity: ProcessIdentity) -> String {
        guard let process = processes[identity] else { return Format.notAccessible }
        let byPID = Dictionary(report.snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var nextPID = process.parentPID
        var seen = Set<Int32>()
        var chain: [String] = []
        while nextPID > 0, !seen.contains(nextPID), chain.count < 12 {
            seen.insert(nextPID)
            guard let parent = byPID[nextPID] else {
                chain.append(nextPID == 1 ? "launchd (PID 1, not in snapshot)" : "PID \(nextPID) (not in snapshot)")
                break
            }
            chain.append("\(parent.name) (PID \(parent.pid))")
            nextPID = parent.parentPID
        }
        return chain.isEmpty ? Format.notAccessible : chain.joined(separator: " ← ")
    }
}

struct ResultsView: View {
    let report: ScanReport
    let settings: SettingsModel
    let stopService: any ProcessStopping
    let onScanAgain: () -> Void
    let onDone: () -> Void

    @State private var selectedProcess: ProcessIdentity?
    @State private var stopTarget: StopTarget?

    private var context: ReportContext {
        let base = ReportContext(report: report)
        let visible = Set(visibleFindings(context: base).map(\.id))
        return ReportContext(report: report, hiddenFindingIDs: Set(report.findings.map(\.id)).subtracting(visible))
    }

    var body: some View {
        let context = self.context
        Group {
            if let selectedProcess {
                ProcessDetailView(identity: selectedProcess, context: context, stopService: stopService,
                                  onBack: { self.selectedProcess = nil }, onRequestStop: { stopTarget = $0 })
            } else {
                resultList(context: context)
            }
        }
        .sheet(item: $stopTarget) { target in
            StopFlowView(target: target, stopService: stopService, onScanAgain: onScanAgain)
        }
    }

    @ViewBuilder
    private func resultList(context: ReportContext) -> some View {
        let visible = visibleFindings(context: context)
        let findings = visible.filter { $0.severity != .review }
        let leftovers = visible.filter { $0.severity == .review }
        let hiddenCount = report.findings.count - visible.count

        VStack(alignment: .leading, spacing: 2) {
            Text(Headline.text(for: report))
                .font(.headline)
            Text("\(Int(report.snapshot.interval))-second sample")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OverviewSection(snapshot: report.snapshot)

                if hiddenCount > 0 {
                    Label("\(hiddenCount) finding\(hiddenCount == 1 ? "" : "s") hidden by your exclusions",
                          systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ResultSection(title: "Findings") {
                    if findings.isEmpty { EmptyNote("No findings in this sample.") }
                    ForEach(findings) {
                        FindingCard(finding: $0, context: context, stopService: stopService,
                                    onInspect: { selectedProcess = $0 }, onRequestStop: { stopTarget = $0 })
                    }
                }

                ResultSection(title: "Potential leftovers") {
                    if leftovers.isEmpty { EmptyNote("No long-running candidates found.") }
                    ForEach(leftovers) {
                        FindingCard(finding: $0, context: context, stopService: stopService,
                                    onInspect: { selectedProcess = $0 }, onRequestStop: { stopTarget = $0 })
                    }
                }

                ResultSection(title: "What's using resources") {
                    GroupList(groups: report.groups, context: context) { selectedProcess = $0 }
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: 440)

        HStack {
            Button("Copy report") { Pasteboard.copy(report.reportText) }
                .help("Concise redacted summary: top processes and findings")
            Button("Copy JSON") { Pasteboard.copy(report.reportJSON) }
                .help("Full redacted report with every process")
        }

        HStack {
            Button("Done", action: onDone)
            Spacer()
            Button("Scan again", action: onScanAgain)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func visibleFindings(context: ReportContext) -> [DiagnosticFinding] {
        report.findings.filter { finding in
            guard !finding.affectedProcesses.isEmpty else { return true }
            return !finding.affectedProcesses.allSatisfy { identity in
                matchesExclusion(identity, context: context)
            }
        }
    }

    private func matchesExclusion(_ identity: ProcessIdentity, context: ReportContext) -> Bool {
        if let name = context.processes[identity]?.name,
           settings.excludedProcessNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return true
        }
        guard let directory = context.project(for: identity)?.directory else { return false }
        let path = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath).standardizedFileURL.path
        return settings.excludedProjectPrefixes.contains { prefix in
            let expanded = URL(fileURLWithPath: (prefix as NSString).expandingTildeInPath).standardizedFileURL.path
            return path == expanded || path.hasPrefix(expanded.hasSuffix("/") ? expanded : expanded + "/")
        }
    }
}

struct StopFlowView: View {
    let target: StopTarget
    let stopService: any ProcessStopping
    let onScanAgain: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .confirmation

    private enum Phase {
        case confirmation
        case stopping
        case outcome(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .confirmation:
                Text("Send SIGTERM?")
                    .font(.headline)
                confirmationDetails
                Text("Stopping a dev server or agent can interrupt tests, edits, builds or active sessions.")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("Send SIGTERM", role: .destructive, action: requestStop)
                }
            case .stopping:
                ProgressView("Waiting for PID \(target.identity.pid) to exit…")
                Text("HeatLens sends SIGTERM once and does not force-quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .outcome(let message):
                Text("Stop result")
                    .font(.headline)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Done") { dismiss() }
                    Spacer()
                    Button("Scan again") {
                        dismiss()
                        onScanAgain()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 330)
        .interactiveDismissDisabled(isStopping)
    }

    private var confirmationDetails: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            row("PID", "\(target.identity.pid)")
            row("Command", Format.command(target.process.arguments) ?? Format.notAccessible)
            row("Project", target.project?.directory ?? "Unknown project")
            row("Impact", Format.impact(target.process.cpuPercentOfOneCore))
        }
        .font(.caption)
    }

    private var isStopping: Bool {
        if case .stopping = phase { return true }
        return false
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func requestStop() {
        // A double-click can call this twice before SwiftUI re-renders; only the first one acts.
        guard case .confirmation = phase else { return }
        phase = .stopping
        Task {
            let outcome = await stopService.requestStop(target.identity, wait: 3)
            phase = .outcome(message(for: outcome))
        }
    }

    private func message(for outcome: StopOutcome) -> String {
        switch outcome {
        case .stopped:
            "Process PID \(target.identity.pid) exited after SIGTERM."
        case .stillRunning:
            "Process PID \(target.identity.pid) didn't exit. HeatLens does not force-quit; use Activity Monitor if needed."
        case .alreadyExited:
            "Process PID \(target.identity.pid) had already exited. Nothing was sent."
        case .identityChanged:
            "PID \(target.identity.pid) now belongs to a different process. Nothing was sent."
        case .denied(let reason):
            "HeatLens didn't send SIGTERM: \(reason)"
        case .failed(let errno):
            "HeatLens couldn't send SIGTERM to PID \(target.identity.pid) (error \(errno)). Nothing else was changed."
        }
    }
}

private struct ResultSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct EmptyNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

private struct OverviewSection: View {
    let snapshot: ScanSnapshot

    var body: some View {
        let system = snapshot.system
        ResultSection(title: "Overview") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Thermal state", Format.thermal(system.thermalState))
                row("CPU load", String(format: "%.1f of %d cores busy", system.busyCores, system.coreCount))
                row("Memory pressure", Format.pressure(system.memory.pressure))
                row("Swap", "\(Format.bytes(system.memory.swapUsedBytes)) of \(Format.bytes(system.memory.swapTotalBytes)) used")
            }
            .font(.callout)

            ForEach(snapshot.notices, id: \.self) { notice in
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

private struct GroupList: View {
    let groups: [ProcessGroup]
    let context: ReportContext
    let onInspect: (ProcessIdentity) -> Void

    @State private var expanded = false

    private var sorted: [ProcessGroup] {
        groups.sorted {
            let left = GroupMetrics(group: $0, context: context).cpu
            let right = GroupMetrics(group: $1, context: context).cpu
            if left != right { return left > right }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private var idleCount: Int { sorted.count { GroupMetrics(group: $0, context: context).isIdle } }
    private var collapsedGroups: [ProcessGroup] {
        Array(sorted.filter { !GroupMetrics(group: $0, context: context).isIdle }.prefix(12))
    }
    private var shownGroups: [ProcessGroup] { expanded ? sorted : collapsedGroups }
    private var canExpand: Bool { shownGroups.count < sorted.count }

    var body: some View {
        if groups.isEmpty {
            EmptyNote("No process groups.")
        } else {
            ForEach(shownGroups) { group in
                GroupRow(group: group, context: context, onInspect: onInspect)
            }
            if !expanded, idleCount > 0 {
                Text("\(idleCount) idle group\(idleCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if canExpand {
                Button("Show all \(groups.count) groups") { expanded = true }
                    .controlSize(.small)
            } else if expanded, groups.count > 12 || idleCount > 0 {
                Button("Show fewer groups") { expanded = false }
                    .controlSize(.small)
            }
        }
    }
}

private struct GroupMetrics {
    let cpu: Double
    let memory: UInt64
    let hasMeasuredCPU: Bool
    private let hasCompleteCPU: Bool
    private let hasCompleteMemory: Bool

    init(group: ProcessGroup, context: ReportContext) {
        let samples = group.members.compactMap { context.processes[$0] }
        let cpuValues = samples.compactMap(\.cpuPercentOfOneCore)
        let memoryValues = samples.compactMap { $0.footprintBytes ?? $0.residentBytes }
        cpu = cpuValues.reduce(0, +)
        memory = memoryValues.reduce(0, +)
        hasMeasuredCPU = !cpuValues.isEmpty
        hasCompleteCPU = !samples.isEmpty && cpuValues.count == samples.count
        hasCompleteMemory = !samples.isEmpty && memoryValues.count == samples.count
    }

    var isIdle: Bool {
        hasCompleteCPU && hasCompleteMemory && cpu == 0 && memory < 50 * 1_024 * 1_024
    }
}

private struct GroupRow: View {
    let group: ProcessGroup
    let context: ReportContext
    let onInspect: (ProcessIdentity) -> Void

    private var members: [(ProcessIdentity, ProcessSample?)] {
        group.members.map { ($0, context.processes[$0]) }
    }

    private var metrics: GroupMetrics { GroupMetrics(group: group, context: context) }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let project = group.project {
                    Text("Project: \(project.directory) (from \(project.basis), \(Format.confidence(project.confidence)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unknown project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(members, id: \.0) { identity, sample in
                    Button { onInspect(identity) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(sample?.name ?? "Process") · PID \(identity.pid)")
                                .font(.caption.weight(.medium))
                            Text("\(Format.measurement(sample)) · up \(context.uptime(identity))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Inspect process")
                }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.label)
                    .font(.callout)
                Text("\(Format.cpu(metrics.hasMeasuredCPU ? metrics.cpu : nil)) · \(group.members.count) process\(group.members.count == 1 ? "" : "es")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#Preview("Results") {
    VStack(alignment: .leading, spacing: 12) {
        ResultsView(report: FixtureScanService.report(startedAt: Date(), interval: 10),
                    settings: SettingsModel(), stopService: FixtureStopService(), onScanAgain: {}, onDone: {})
    }
    .padding(16)
    .frame(width: 300)
}
