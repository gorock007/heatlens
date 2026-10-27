import SwiftUI
import HeatLensCore

/// Read-only lookups the result views share.
struct ReportContext {
    let report: ScanReport
    let processes: [ProcessIdentity: ProcessSample]
    let observedAt: Date
    /// Findings the user's exclusions hide (Settings).
    let hiddenFindingIDs: Set<UUID>
    /// Every listening port with its process and group, sorted by port.
    let portListings: [PortListing]
    /// Every sleep-blocking power assertion with its process and group, oldest first.
    let assertionListings: [PowerAssertionListing]

    init(report: ScanReport, hiddenFindingIDs: Set<UUID> = []) {
        self.report = report
        self.hiddenFindingIDs = hiddenFindingIDs
        processes = Dictionary(report.snapshot.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        observedAt = report.snapshot.startedAt.addingTimeInterval(report.snapshot.interval)
        portListings = PortListing.listings(report.snapshot, groups: report.groups)
        assertionListings = PowerAssertionListing.listings(report.snapshot, groups: report.groups)
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

    /// The process's descendants, indented by depth, from this scan's snapshot.
    func children(of identity: ProcessIdentity) -> String {
        let live = report.snapshot.processes.filter { $0.detailAccess != .processExited }
        let tree = ProcessTree.descendants(of: identity.pid, in: live, maxDepth: 4, maxCount: 20)
        guard !tree.nodes.isEmpty else { return "None" }
        let lines = tree.nodes.map { node in
            String(repeating: "  ", count: node.depth - 1) + "\(node.process.name) (PID \(node.process.pid))"
        }
        return (lines + (tree.truncated ? ["…"] : [])).joined(separator: "\n")
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
    /// The results before these, for "Since last scan"; nil after a relaunch or on the first scan.
    let previousReport: ScanReport?
    let stoppedSinceLastScan: Bool
    let onScanAgain: () -> Void
    /// Told when a stop or batch stop ends with at least one process stopped.
    let onStopped: () -> Void
    let onDone: () -> Void

    @State private var selectedProcess: ProcessIdentity?
    @State private var stopTarget: StopTarget?
    @State private var batchTarget: ProjectLeftovers?

    private var context: ReportContext {
        let visible = Set(visibleFindings.map(\.id))
        return ReportContext(report: report, hiddenFindingIDs: Set(report.findings.map(\.id)).subtracting(visible))
    }

    private var comparison: ScanComparison? {
        guard let previousReport else { return nil }
        return ScanComparison.compare(before: previousReport.result, after: report.result, exclusions: settings.exclusions)
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
            StopFlowView(target: target, stopService: stopService, onScanAgain: onScanAgain, onStopped: onStopped)
        }
        .sheet(item: $batchTarget) { leftovers in
            BatchStopFlowView(leftovers: leftovers, context: context, stopService: stopService,
                              onScanAgain: onScanAgain, onStopped: onStopped)
        }
    }

    @ViewBuilder
    private func resultList(context: ReportContext) -> some View {
        let visible = visibleFindings
        let findings = visible.filter { $0.severity != .review }
        let leftovers = visible.filter { $0.severity == .review }
        let batchAbove = batchesByFirstFinding(context: context)
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
                if let comparison {
                    SinceLastScanSection(comparison: comparison)
                }

                OverviewSection(snapshot: report.snapshot)
                if let hardware = report.hardware, hardware.cpuTemperature.availability != .disabled {
                    HardwareCard(sample: hardware)
                }
                if let docker = report.docker {
                    DockerCard(snapshot: docker)
                }

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
                    ForEach(leftovers) { finding in
                        if let batch = batchAbove[finding.id] {
                            BatchStopRow(leftovers: batch) { batchTarget = batch }
                        }
                        FindingCard(finding: finding, context: context, stopService: stopService,
                                    onInspect: { selectedProcess = $0 }, onRequestStop: { stopTarget = $0 })
                    }
                }

                if !context.portListings.isEmpty {
                    ResultSection(title: "Ports") {
                        PortList(listings: context.portListings) { selectedProcess = $0 }
                    }
                }

                if !context.assertionListings.isEmpty {
                    ResultSection(title: "Keeping your Mac awake") {
                        AwakeList(listings: context.assertionListings, observedAt: context.observedAt) { selectedProcess = $0 }
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
            Button(stoppedSinceLastScan ? "Rescan to see the difference" : "Scan again", action: onScanAgain)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Projects with 2 or more stoppable leftovers, keyed by the first of their findings, so the
    /// batch button shows once per project, above that project's first leftover card.
    private func batchesByFirstFinding(context: ReportContext) -> [UUID: ProjectLeftovers] {
        let batches = LeftoverCandidates.batches(
            findings: report.findings, groups: report.groups, processes: report.snapshot.processes,
            hiddenFindingIDs: context.hiddenFindingIDs,
            isEligible: { if case .eligible = stopService.eligibility(of: $0) { true } else { false } })
        var byFinding: [UUID: ProjectLeftovers] = [:]
        for batch in batches {
            if let first = batch.candidates.first { byFinding[first.finding.id] = batch }
        }
        return byFinding
    }

    private var visibleFindings: [DiagnosticFinding] {
        settings.exclusions.visibleFindings(report.findings, snapshot: report.snapshot, groups: report.groups)
    }
}

struct StopFlowView: View {
    let target: StopTarget
    let stopService: any ProcessStopping
    let onScanAgain: () -> Void
    let onStopped: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .confirmation

    private enum Phase {
        case confirmation
        case stopping
        case outcome(String, stopped: Bool)
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
            case .outcome(let message, let stopped):
                Text("Stop result")
                    .font(.headline)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Done") { dismiss() }
                    Spacer()
                    Button(stopped ? "Rescan to see the difference" : "Scan again") {
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
            phase = .outcome(StopWording.message(for: outcome, pid: target.identity.pid), stopped: outcome == .stopped)
            if outcome == .stopped { onStopped() }
        }
    }
}

/// "portfolio-demo has 2 leftovers  [Stop leftovers (2)…]", above that project's first leftover card.
private struct BatchStopRow: View {
    let leftovers: ProjectLeftovers
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(leftovers.projectName) has \(leftovers.candidates.count) leftovers")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Stop leftovers (\(leftovers.candidates.count))…", role: .destructive, action: onStop)
                .controlSize(.small)
                .help("Review and stop \(leftovers.project.directory)'s leftovers together, one confirmation")
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

/// "Since last scan (4 min ago)": one row per metric that moved beyond the noise floor and the
/// groups that are gone, or one line when nothing changed.
private struct SinceLastScanSection: View {
    let comparison: ScanComparison

    var body: some View {
        ResultSection(title: "Since last scan (\(PowerAssertion.durationText(comparison.elapsed)) ago)") {
            if comparison.isAboutTheSame {
                EmptyNote("About the same as the last scan.")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    if comparison.busyCoresChanged {
                        let cores = comparison.busyCores
                        row("CPU", String(format: "%.1f → %.1f cores", cores.before, cores.after))
                    }
                    if comparison.memoryPressureChanged {
                        let pressure = comparison.memoryPressure
                        row("Memory pressure", "\(Format.pressure(pressure.before)) → \(Format.pressure(pressure.after))")
                    }
                    if comparison.swapChanged {
                        let swap = comparison.swapUsedBytes
                        row("Swap", "\(Format.bytes(swap.before)) → \(Format.bytes(swap.after))")
                    }
                    if comparison.thermalChanged {
                        let thermal = comparison.thermalState
                        row("Thermal", "\(Format.thermal(thermal.before)) → \(Format.thermal(thermal.after))")
                    }
                    if !comparison.gone.isEmpty {
                        row("Gone", gone)
                    }
                }
                .font(.callout)
            }
        }
    }

    /// "next dev (my-app), node watch-images.js (portfolio-demo), and 2 more".
    private var gone: String {
        var names = comparison.gone.map { group in
            group.projectName.map { "\(group.label) (\($0))" } ?? group.label
        }
        if comparison.moreGoneCount > 0 { names.append("and \(comparison.moreGoneCount) more") }
        return names.joined(separator: ", ")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Text(verbatim: value).fixedSize(horizontal: false, vertical: true)
        }
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

private struct PortList: View {
    let listings: [PortListing]
    let onInspect: (ProcessIdentity) -> Void

    static let collapsedCount = 6
    @State private var expanded = false

    private var shown: [PortListing] { expanded ? listings : Array(listings.prefix(Self.collapsedCount)) }

    var body: some View {
        ForEach(shown) { listing in
            // The whole row inspects, like a group's member rows; the trailing word says so.
            Button { onInspect(listing.identity) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: ":\(listing.port.port)")
                        .font(.callout.monospacedDigit().weight(.medium))
                        .frame(width: 46, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "\(listing.processName) · PID \(listing.identity.pid)")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(verbatim: detail(listing))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("Inspect")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Inspect process")
        }
        if listings.count > Self.collapsedCount {
            Button(expanded ? "Show fewer ports" : "Show all \(listings.count) ports") { expanded.toggle() }
                .controlSize(.small)
        }
    }

    private func detail(_ listing: PortListing) -> String {
        var parts = [listing.port.scopeLabel]
        if let group = listing.group {
            parts.append(group.label)
            if let project = group.project { parts.append((project.directory as NSString).lastPathComponent) }
        }
        return parts.joined(separator: " · ")
    }
}

private struct AwakeList: View {
    let listings: [PowerAssertionListing]
    let observedAt: Date
    let onInspect: (ProcessIdentity) -> Void

    static let collapsedCount = 6
    @State private var expanded = false

    private var shown: [PowerAssertionListing] { expanded ? listings : Array(listings.prefix(Self.collapsedCount)) }

    var body: some View {
        ForEach(shown) { listing in
            // The whole row inspects, like the Ports rows; the trailing word says so.
            Button { onInspect(listing.identity) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: listing.assertion.effect == .keepsDisplayOn ? "display" : "cup.and.saucer")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "\(listing.processName) · PID \(listing.identity.pid)")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(verbatim: detail(listing))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("Inspect")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(listing.assertion.name.isEmpty ? "Inspect process" : "\(listing.assertion.name) — inspect process")
        }
        if listings.count > Self.collapsedCount {
            Button(expanded ? "Show fewer" : "Show all \(listings.count)") { expanded.toggle() }
                .controlSize(.small)
        }
    }

    private func detail(_ listing: PowerAssertionListing) -> String {
        var parts = [listing.assertion.effect?.label ?? listing.assertion.type]
        if let held = listing.assertion.heldSeconds(at: observedAt) { parts.append(PowerAssertion.durationText(held)) }
        if let group = listing.group {
            parts.append(group.label)
            if let project = group.project { parts.append((project.directory as NSString).lastPathComponent) }
        }
        return parts.joined(separator: " · ")
    }
}

extension PowerAssertion {
    /// "Prevents idle sleep for 3 h 12 min (“caffeinate command-line tool”)", for the detail view.
    func detailText(at now: Date) -> String {
        var text = effect?.label ?? type
        if let held = heldSeconds(at: now) { text += " for \(PowerAssertion.durationText(held))" }
        if !name.isEmpty { text += " (“\(name)”)" }
        return text
    }
}

extension ListeningPort {
    /// "loopback", "all interfaces", or the specific address it is bound to.
    var scopeLabel: String {
        switch scope {
        case .loopback: "loopback"
        case .allInterfaces: "all interfaces"
        case .specificAddress: address ?? "specific address"
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
                Text(([Format.cpu(metrics.hasMeasuredCPU ? metrics.cpu : nil),
                       Format.watts(context.report.snapshot.cpuWatts(for: group.members))].compactMap { $0 }
                      + ["\(group.members.count) process\(group.members.count == 1 ? "" : "es")"]).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension ScanReport {
    var result: ScanResult { ScanResult(snapshot: snapshot, groups: groups, findings: findings) }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#Preview("Results") {
    let firstScan = Date().addingTimeInterval(-4 * 60)
    VStack(alignment: .leading, spacing: 12) {
        ResultsView(report: FixtureScanService.report(startedAt: Date(), interval: 10, processClock: firstScan, afterStop: true),
                    settings: SettingsModel(), stopService: FixtureStopService(),
                    previousReport: FixtureScanService.report(startedAt: firstScan, interval: 10),
                    stoppedSinceLastScan: false, onScanAgain: {}, onStopped: {}, onDone: {})
    }
    .padding(16)
    .frame(width: 300)
}
