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

/// The action-log records the app writes itself (brief 3e-2): an ignore, and a confirmation the
/// user backed out of. Stops, force quits and container stops are recorded by the engine.
@MainActor
enum ActionRecording {
    /// Shown where the user pressed an ignore button; there is no confirmation, since it's reversible.
    static let ignoredNote = "Ignored. Remove it in Settings → Exclusions to undo."

    /// "Ignore this process": the name goes into Settings' excluded processes, once.
    static func ignoreProcess(_ identity: ProcessIdentity, name: String, projectName: String?,
                              origin: ActionRecord.Origin, settings: SettingsModel) {
        let clickedAt = Date()
        settings.ignoreProcess(name)
        record(.ignored, target: .process(pid: identity.pid, startTimeMicros: identity.startTimeMicros, name: name),
               projectName: projectName, origin: origin, at: clickedAt, confirmedAt: clickedAt, outcome: "ignored")
    }

    /// "Ignore this project": the directory goes into Settings' excluded projects; the log gets
    /// the project's name only, never the directory.
    static func ignoreProject(directory: String, name: String, origin: ActionRecord.Origin, settings: SettingsModel) {
        let clickedAt = Date()
        settings.ignoreProject(directory)
        record(.ignored, target: .project(name: name), projectName: nil, origin: origin, at: clickedAt,
               confirmedAt: clickedAt, outcome: "ignored")
    }

    /// A stop, force quit or container stop whose confirmation was cancelled; nothing was sent.
    static func cancelled(_ offered: ActionRecord.Action, target: ActionRecord.Target, projectName: String?,
                          origin: ActionRecord.Origin) {
        record(.cancelled, target: target, projectName: projectName, origin: origin, at: Date(), confirmedAt: nil,
               outcome: "cancelled", offered: offered)
    }

    static func processTarget(_ target: StopTarget) -> ActionRecord.Target {
        .process(pid: target.identity.pid, startTimeMicros: target.identity.startTimeMicros, name: target.process.name)
    }

    private static func record(_ action: ActionRecord.Action, target: ActionRecord.Target, projectName: String?,
                               origin: ActionRecord.Origin, at: Date, confirmedAt: Date?, outcome: String,
                               offered: ActionRecord.Action? = nil) {
        let record = ActionRecord(at: at, action: action, target: target, projectName: projectName, origin: origin,
                                  confirmedAt: confirmedAt, signalSentAt: nil, outcome: outcome, detail: nil,
                                  offered: offered)
        let ledger = ActionLog.shared.ledger
        Task { await ledger.record(record) }
    }
}

struct ResultsView: View {
    let report: ScanReport
    let settings: SettingsModel
    let stopService: any ProcessStopping
    let containerStopService: any ContainerStopProviding
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
    @State private var selectedContainer: ContainerSelection?
    @State private var containerStopTarget: ContainerSelection?
    /// Set after "Ignore this process" on a finding card, whose card the exclusion then hides.
    @State private var showIgnoredNote = false

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
                                  onBack: { self.selectedProcess = nil }, onRequestStop: { stopTarget = $0 },
                                  settings: settings)
            } else if let selectedContainer {
                ContainerDetailView(selection: selectedContainer, settings: settings,
                                    onBack: { self.selectedContainer = nil }, onRequestStop: { containerStopTarget = $0 })
            } else {
                resultList(context: context)
            }
        }
        .sheet(item: $stopTarget) { target in
            StopFlowView(target: target, settings: settings, stopService: stopService, onScanAgain: onScanAgain,
                         onStopped: onStopped)
        }
        .sheet(item: $batchTarget) { leftovers in
            BatchStopFlowView(leftovers: leftovers, context: context, settings: settings, stopService: stopService,
                              onScanAgain: onScanAgain, onStopped: onStopped)
        }
        .sheet(item: $containerStopTarget) { selection in
            ContainerStopFlowView(selection: selection, settings: settings, onScanAgain: onScanAgain, onStopped: onStopped)
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
                    DockerCard(snapshot: docker, onInspect: inspectContainer, canStop: settings.canStopContainers)
                }

                if showIgnoredNote {
                    Label(ActionRecording.ignoredNote, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                                    onInspect: { selectedProcess = $0 }, onRequestStop: requestStopFromCard,
                                    onIgnoreProcess: ignoreProcessFromCard)
                    }
                }

                if !report.projects.usages.isEmpty {
                    ProjectsCard(breakdown: report.projects, groups: report.groups, onInspectContainer: inspectContainer,
                                 settings: settings)
                }

                ResultSection(title: "Potential leftovers") {
                    if leftovers.isEmpty { EmptyNote("No long-running candidates found.") }
                    ForEach(leftovers) { finding in
                        if let batch = batchAbove[finding.id] {
                            BatchStopRow(leftovers: batch) { batchTarget = batch }
                        }
                        FindingCard(finding: finding, context: context, stopService: stopService,
                                    onInspect: { selectedProcess = $0 }, onRequestStop: requestStopFromCard,
                                    onIgnoreProcess: ignoreProcessFromCard)
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

    /// Opens a container's detail, with the stopper Settings allow right now (ADR-0007 decision 6).
    private func inspectContainer(_ container: ContainerSample) {
        let enabled = containerStopService.isEnabled
        selectedContainer = ContainerSelection(container: container,
                                               attribution: report.projects.containerAttributions[container.containerID],
                                               engineVersion: report.docker?.engineVersion, isStopEnabled: enabled,
                                               stopper: containerStopService.stopper())
    }

    /// A stop offered on a finding card; the audit record files every card under `leftoverCard`.
    private func requestStopFromCard(_ target: StopTarget) {
        var target = target
        target.origin = .leftoverCard
        stopTarget = target
    }

    /// "Ignore this process" on a finding card. The card goes away with the exclusion, so the note
    /// shows above the findings instead.
    private func ignoreProcessFromCard(_ identity: ProcessIdentity, name: String) {
        let projectName = context.project(for: identity).map { ($0.directory as NSString).lastPathComponent }
        ActionRecording.ignoreProcess(identity, name: name, projectName: projectName, origin: .findingCard,
                                      settings: settings)
        showIgnoredNote = true
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
    let settings: SettingsModel
    let stopService: any ProcessStopping
    let onScanAgain: () -> Void
    let onStopped: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .confirmation

    private enum Phase {
        case confirmation
        case stopping
        /// `stopRequestedAt` is the ledger's SIGTERM time, read only when the process ignored it.
        case outcome(StopOutcome, stopRequestedAt: Date?)
        /// The separate force-quit confirmation (ADR-0006 decision 4), never this sheet's SIGTERM step.
        case forceQuit(stopRequestedAt: Date)
    }

    var body: some View {
        Group {
            if case .forceQuit(let stopRequestedAt) = phase {
                ForceQuitFlowView(
                    target: target, stopRequestedAt: stopRequestedAt, stopService: stopService,
                    onCancel: { phase = .outcome(.stillRunning, stopRequestedAt: stopRequestedAt) },
                    onFinished: { if $0 == .stopped { onStopped() } },
                    onScanAgain: onScanAgain)
            } else {
                stopSteps
                    .padding(18)
                    .frame(width: 330)
                    .interactiveDismissDisabled(isStopping)
            }
        }
        // Cancel, Escape or the sheet closing while the SIGTERM is still only offered.
        .onDisappear {
            guard case .confirmation = phase else { return }
            ActionRecording.cancelled(.stopRequested, target: ActionRecording.processTarget(target),
                                      projectName: target.context().projectName, origin: target.origin)
        }
    }

    private var stopSteps: some View {
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
                Text("HeatLens sends SIGTERM once and never force-quits on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .outcome(let outcome, let stopRequestedAt):
                let offer = outcome == .stillRunning && settings.forceQuitEnabled ? stopRequestedAt : nil
                Text("Stop result")
                    .font(.headline)
                Text(StopWording.message(for: outcome, pid: target.identity.pid, forceQuitOffered: offer != nil))
                    .fixedSize(horizontal: false, vertical: true)
                if let offer {
                    ForceQuitOfferButton(stopRequestedAt: offer) { phase = .forceQuit(stopRequestedAt: offer) }
                }
                HStack {
                    Button("Done") { dismiss() }
                    Spacer()
                    Button(outcome == .stopped ? "Rescan to see the difference" : "Scan again") {
                        dismiss()
                        onScanAgain()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .forceQuit:
                EmptyView()
            }
        }
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
        let context = target.context()
        phase = .stopping
        Task {
            let outcome = await stopService.requestStop(target.identity, wait: 3, context: context)
            let stopRequestedAt = outcome == .stillRunning ? await stopService.stopRequestedAt(target.identity) : nil
            phase = .outcome(outcome, stopRequestedAt: stopRequestedAt)
            if outcome == .stopped { onStopped() }
        }
    }
}

/// "Force quit…" and the seconds since the stop request, updated once a second. The engine refuses
/// a force quit once the request is `ProcessTerminator.offerLifetime` old, so the button stops too.
struct ForceQuitOfferButton: View {
    let stopRequestedAt: Date
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(stopRequestedAt))
            let expired = elapsed >= ProcessTerminator.offerLifetime
            VStack(alignment: .leading, spacing: 2) {
                Button("Force quit…", role: .destructive, action: action)
                    .disabled(expired)
                Text(expired ? ForceQuitFlowView.expiredText : "Stop request sent \(Int(elapsed)) s ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The second confirmation for SIGKILL (docs/v2/ADR-0006 decision 4), shared by the single stop
/// sheet and each still-running row of the batch sheet. Cancel is the default; Force Quit has no
/// keyboard shortcut.
struct ForceQuitFlowView: View {
    static let expiredText = "Too long since the stop request; request a stop again."

    let target: StopTarget
    /// The ledger's time for the SIGTERM this process ignored.
    let stopRequestedAt: Date
    let stopService: any ProcessStopping
    let onCancel: () -> Void
    /// Told the outcome once the force quit has run.
    let onFinished: (StopOutcome) -> Void
    /// Nil where the presenting sheet has its own "Scan again" (the batch sheet).
    var onScanAgain: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .forceQuitConfirmation

    private enum Phase {
        case forceQuitConfirmation
        case forceQuitting
        case forceQuitOutcome(StopOutcome)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .forceQuitConfirmation:
                confirmation
            case .forceQuitting:
                ProgressView("Waiting for PID \(target.identity.pid) to exit…")
                Text("HeatLens waits at least \(Int(ProcessTerminator.minimumGraceAfterStop)) s after the stop request, checks it is still the same process, then sends SIGKILL once, to this process only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .forceQuitOutcome(let outcome):
                Text("Force Quit result")
                    .font(.headline)
                Text(StopWording.message(for: outcome, pid: target.identity.pid, signal: .sigkill))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let onScanAgain {
                        Button("Done") { dismiss() }
                        Spacer()
                        Button(outcome == .stopped ? "Rescan to see the difference" : "Scan again") {
                            dismiss()
                            onScanAgain()
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Spacer()
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 330)
        .interactiveDismissDisabled(isForceQuitting)
        // Cancel (the presenter then swaps this view out), Escape or the sheet closing while
        // SIGKILL is still only offered.
        .onDisappear {
            guard case .forceQuitConfirmation = phase else { return }
            ActionRecording.cancelled(.forceQuit, target: ActionRecording.processTarget(target),
                                      projectName: target.context().projectName, origin: target.origin)
        }
    }

    @ViewBuilder
    private var confirmation: some View {
        Text("Force quit \(target.process.name)?")
            .font(.headline)
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(stopRequestedAt))
            let expired = elapsed >= ProcessTerminator.offerLifetime
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    row("Process", "\(target.process.name) · PID \(target.identity.pid)")
                    row("Project", target.project?.directory ?? "Unknown project")
                    row("Uptime", Format.uptime(target.identity.uptime(at: timeline.date)))
                    row("Stop request", expired ? Self.expiredText : "sent \(Int(elapsed)) s ago, ignored")
                }
                .font(.caption)
                Text("Force Quit sends SIGKILL. The process ends at once and cannot save or clean up: unsaved edits, open files, database writes and child processes it owns can be lost or left half done. This cannot be undone.")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Child processes it owns can be left running; scan again to see them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("Force Quit", role: .destructive, action: forceQuit)
                        .disabled(expired)
                }
            }
        }
    }

    private var isForceQuitting: Bool {
        if case .forceQuitting = phase { return true }
        return false
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func forceQuit() {
        // A double-click can call this twice before SwiftUI re-renders; only the first one acts.
        guard case .forceQuitConfirmation = phase else { return }
        let context = target.context()
        phase = .forceQuitting
        Task {
            let outcome = await stopService.forceQuit(target.identity, context: context)
            phase = .forceQuitOutcome(outcome)
            onFinished(outcome)
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
                    containerStopService: FixtureContainerStopService(enabled: { true }),
                    previousReport: FixtureScanService.report(startedAt: firstScan, interval: 10),
                    stoppedSinceLastScan: false, onScanAgain: {}, onStopped: {}, onDone: {})
    }
    .padding(16)
    .frame(width: 300)
}
