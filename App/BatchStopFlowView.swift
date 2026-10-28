import SwiftUI
import HeatLensCore

/// Runs one confirmed batch with `BatchStop` and keeps each row's status for the sheet.
@MainActor @Observable
final class BatchStopRun {
    private(set) var statuses: [BatchStop.ItemStatus] = []
    private(set) var isFinished = false
    private(set) var isCancelling = false
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil && !isFinished }

    /// At least one process exited after its SIGTERM.
    var stoppedAny: Bool { statuses.contains(.finished(.stopped)) }

    /// `onFinish` runs once, after the last status is in, with whether any process was stopped.
    /// `contexts` carries each process's audit context (origin, names, when the user confirmed).
    func start(_ identities: [ProcessIdentity], contexts: [ProcessIdentity: ActionContext],
               stopService: any ProcessStopping, onFinish: @escaping (_ stoppedAny: Bool) -> Void = { _ in }) {
        guard task == nil else { return }
        statuses = Array(repeating: .pending, count: identities.count)
        let batch = BatchStop { identity in
            let context = contexts[identity] ?? ActionContext(origin: .batchStop, confirmedAt: Date())
            return await stopService.requestStop(identity, wait: 3, context: context)
        }
        task = Task { [weak self] in
            let final = await batch.run(identities) { index, status in
                await MainActor.run { self?.statuses[index] = status }
            }
            self?.statuses = final
            self?.isFinished = true
            onFinish(final.contains(.finished(.stopped)))
        }
    }

    /// Stops before the next process; the one in progress finishes its own wait.
    func cancel() {
        isCancelling = true
        task?.cancel()
    }
}

/// One confirmation for several leftovers of one project: every process listed with a checkbox,
/// then each selected one stopped in order, revalidated right before its own SIGTERM. Afterwards,
/// with the Settings switch on, each still-running row has its own "Force quit…"; never all at once.
struct BatchStopFlowView: View {
    let leftovers: ProjectLeftovers
    let context: ReportContext
    let settings: SettingsModel
    let stopService: any ProcessStopping
    let onScanAgain: () -> Void
    /// Told when the run ends with at least one process stopped.
    let onStopped: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<ProcessIdentity>
    @State private var run = BatchStopRun()
    /// The rows that were sent to the run, in order; empty until "Stop selected".
    @State private var sent: [LeftoverCandidate] = []
    /// The ledger's SIGTERM time for each row that ignored it, read once the run has finished.
    @State private var stopRequestedAt: [ProcessIdentity: Date] = [:]
    /// The row whose force-quit confirmation is open.
    @State private var forceQuitTarget: StopTarget?
    /// Each row's force-quit result; a row is offered at most one force quit per run.
    @State private var forceQuitOutcomes: [ProcessIdentity: StopOutcome] = [:]

    init(leftovers: ProjectLeftovers, context: ReportContext, settings: SettingsModel, stopService: any ProcessStopping,
         onScanAgain: @escaping () -> Void, onStopped: @escaping () -> Void) {
        self.leftovers = leftovers
        self.context = context
        self.settings = settings
        self.stopService = stopService
        self.onScanAgain = onScanAgain
        self.onStopped = onStopped
        _selected = State(initialValue: Set(leftovers.candidates.map(\.identity)))
    }

    private var chosen: [LeftoverCandidate] { leftovers.candidates.filter { selected.contains($0.identity) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sent.isEmpty {
                confirmation
            } else {
                progress
            }
        }
        .padding(18)
        .frame(width: 380)
        .interactiveDismissDisabled(run.isRunning)
        .task(id: run.isFinished) {
            guard run.isFinished else { return }
            for (index, candidate) in sent.enumerated() where index < run.statuses.count
                && run.statuses[index] == .finished(.stillRunning) {
                stopRequestedAt[candidate.identity] = await stopService.stopRequestedAt(candidate.identity)
            }
        }
        .sheet(item: $forceQuitTarget) { target in
            if let sentAt = stopRequestedAt[target.identity] {
                ForceQuitFlowView(
                    target: target, stopRequestedAt: sentAt, stopService: stopService,
                    onCancel: { forceQuitTarget = nil },
                    onFinished: { outcome in
                        forceQuitOutcomes[target.identity] = outcome
                        if outcome == .stopped { onStopped() }
                    })
            }
        }
    }

    private var stoppedAny: Bool { run.stoppedAny || forceQuitOutcomes.values.contains(.stopped) }

    // MARK: Confirmation

    @ViewBuilder
    private var confirmation: some View {
        Text("Stop \(leftovers.candidates.count) leftovers in \(leftovers.projectName)?")
            .font(.headline)
        Text(leftovers.project.directory)
            .font(.caption)
            .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(leftovers.candidates) { candidate in
                Toggle(isOn: binding(for: candidate.identity)) {
                    rowLabel(candidate)
                }
                .toggleStyle(.checkbox)
            }
        }

        Text("HeatLens sends each one SIGTERM, which gives it a chance to exit cleanly, and checks it is still the same process right before signalling it.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text("Stopping a dev server or agent can interrupt tests, edits, builds or active sessions.")
            .font(.callout.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.defaultAction)
            Spacer()
            Button("Stop selected (\(chosen.count))", role: .destructive, action: stopSelected)
                .disabled(chosen.isEmpty)
        }
    }

    private func binding(for identity: ProcessIdentity) -> Binding<Bool> {
        Binding(
            get: { selected.contains(identity) },
            set: { isOn in
                if isOn { selected.insert(identity) } else { selected.remove(identity) }
            }
        )
    }

    private func rowLabel(_ candidate: LeftoverCandidate) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(candidate.process.name) · PID \(candidate.identity.pid)")
                .font(.caption.weight(.medium))
            Text(verbatim: "up \(context.uptime(candidate.identity)) · \(Format.cpu(candidate.process.cpuPercentOfOneCore)) in this scan")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(candidate.finding.title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stopSelected() {
        // A double-click can call this twice before SwiftUI re-renders; only the first one acts.
        guard sent.isEmpty, !chosen.isEmpty else { return }
        sent = chosen
        let confirmedAt = Date()
        let contexts = Dictionary(uniqueKeysWithValues: sent.map {
            ($0.identity, ActionContext(origin: .batchStop, processName: $0.process.name,
                                        projectName: leftovers.projectName, confirmedAt: confirmedAt))
        })
        run.start(sent.map(\.identity), contexts: contexts, stopService: stopService) { [onStopped] stoppedAny in
            if stoppedAny { onStopped() }
        }
    }

    // MARK: Progress and result

    @ViewBuilder
    private var progress: some View {
        Text(run.isFinished ? "Stop results" : "Stopping \(sent.count) leftover\(sent.count == 1 ? "" : "s")…")
            .font(.headline)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sent.enumerated()), id: \.element.id) { index, candidate in
                let status = index < run.statuses.count ? run.statuses[index] : .pending
                let forced = forceQuitOutcomes[candidate.identity]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "\(candidate.process.name) · PID \(candidate.identity.pid)")
                            .font(.caption.weight(.medium))
                        if let detail = forced.map({ forceQuitDetail($0, pid: candidate.identity.pid) }) ?? detail(for: status) {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if forced == nil, let sentAt = forceQuitOffer(for: candidate, status: status) {
                            ForceQuitOfferButton(stopRequestedAt: sentAt) {
                                forceQuitTarget = StopTarget(identity: candidate.identity, process: candidate.process,
                                                             project: leftovers.project, origin: .batchStop)
                            }
                            .controlSize(.small)
                            .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 4)
                    if let forced {
                        Text(StopWording.status(for: forced, signal: .sigkill))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(forced == .stopped ? .green : .orange)
                    } else {
                        statusLabel(status)
                    }
                }
            }
        }

        if run.isFinished {
            Text(summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Done") { dismiss() }
                Spacer()
                Button(stoppedAny ? "Rescan to see the difference" : "Scan again") {
                    dismiss()
                    onScanAgain()
                }
                .keyboardShortcut(.defaultAction)
            }
        } else {
            Text("HeatLens sends SIGTERM once to each and never force-quits on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(run.isCancelling ? "Cancelling…" : "Cancel") { run.cancel() }
                    .disabled(run.isCancelling)
                    .help("Stop before the next process; the one in progress finishes")
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: BatchStop.ItemStatus) -> some View {
        switch status {
        case .stopping:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("stopping…")
            }
            .font(.caption)
        default:
            Text(Self.label(for: status))
                .font(.caption.weight(.medium))
                .foregroundStyle(tint(for: status))
        }
    }

    static func label(for status: BatchStop.ItemStatus) -> String {
        switch status {
        case .pending: "waiting"
        case .stopping: "stopping…"
        case .finished(let outcome): StopWording.status(for: outcome)
        case .notAttempted: "not stopped (cancelled)"
        }
    }

    private func tint(for status: BatchStop.ItemStatus) -> Color {
        switch status {
        case .finished(.stopped): .green
        case .finished(.stillRunning), .finished(.failed): .orange
        default: .secondary
        }
    }

    /// The reason line under a row, only where the short label can't say it all.
    private func detail(for status: BatchStop.ItemStatus) -> String? {
        switch status {
        case .finished(.denied(let reason)): reason
        case .finished(.stillRunning):
            settings.forceQuitEnabled
                ? "It didn't exit. You can force quit it with its own button."
                : "It didn't exit. " + StopWording.ignoredStopHint(forceQuitOffered: false)
        default: nil
        }
    }

    /// The SIGTERM time of a finished, still-running row when the Settings switch is on; nil otherwise.
    private func forceQuitOffer(for candidate: LeftoverCandidate, status: BatchStop.ItemStatus) -> Date? {
        guard run.isFinished, settings.forceQuitEnabled, status == .finished(.stillRunning) else { return nil }
        return stopRequestedAt[candidate.identity]
    }

    /// The reason line after a row's force quit; the short label says "force quit" on its own.
    private func forceQuitDetail(_ outcome: StopOutcome, pid: Int32) -> String {
        outcome == .stopped ? "Ended with SIGKILL." : StopWording.message(for: outcome, pid: pid, signal: .sigkill)
    }

    /// "2 stopped · 1 skipped: it changed", in the order the statuses first appear.
    private var summary: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for status in run.statuses {
            let label = Self.label(for: status)
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += 1
        }
        return order.map { "\(counts[$0] ?? 0) \($0)" }.joined(separator: " · ")
    }
}

#Preview("Batch stop") {
    let report = FixtureScanService.report(startedAt: Date(), interval: 10)
    let context = ReportContext(report: report)
    let leftovers = LeftoverCandidates.batches(findings: report.findings, groups: report.groups,
                                               processes: report.snapshot.processes)
    return BatchStopFlowView(leftovers: leftovers[0], context: context, settings: SettingsModel(), stopService: FixtureStopService(),
                             onScanAgain: {}, onStopped: {})
}
