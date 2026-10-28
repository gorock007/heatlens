import SwiftUI
import HeatLensCore

/// The one confirmation for a container stop (docs/v2/ADR-0007 decision 2). It opens with a GET-only
/// preview for the stop signal, timeout and restart policy it states; Cancel is the default and
/// Stop container has no keyboard shortcut.
struct ContainerStopFlowView: View {
    let selection: ContainerSelection
    let settings: SettingsModel
    let onScanAgain: () -> Void
    let onStopped: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .checking

    private enum Phase {
        /// The preview's inspect is running.
        case checking
        case confirmation(ContainerStopTerms)
        case stopping(ContainerStopTerms)
        /// After a stop, or a preview that found nothing can be sent.
        case outcome(ContainerStopOutcome, sent: Bool)
    }

    private var container: ContainerSample { selection.container }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .checking:
                Text("Stop \(container.name)?")
                    .font(.headline)
                ProgressView("Checking the container with Docker…")
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                    Spacer()
                }
            case .confirmation(let plan):
                Text("Stop \(container.name)?")
                    .font(.headline)
                details
                Text(LocalizedStringKey(ContainerStopWording.explanation(plan)))
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let restart = ContainerStopWording.restartPolicy(plan) {
                    Text(restart)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("Stop container", role: .destructive) { stop(plan) }
                }
            case .stopping(let plan):
                ProgressView("Waiting for Docker to stop \(container.name)…")
                Text("HeatLens sends one stop request and waits up to \(plan.timeoutSeconds + 5) s for Docker's answer. It never retries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .outcome(let outcome, let sent):
                Text(sent ? "Stop result" : "Can't stop this container")
                    .font(.headline)
                Text(ContainerStopWording.message(for: outcome, name: container.name))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Done") { dismiss() }
                    Spacer()
                    Button(stopped(outcome) ? "Rescan to see the difference" : "Scan again") {
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
        .task { await checkFirst() }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            row("Container", container.name)
            row("Image", container.image)
            row("ID", container.shortID)
            row("State", "\(container.state) · \(container.status)")
            if let compose = container.composeProject {
                row("Compose", "\(compose) / \(container.composeService ?? "?")")
            }
            row("Project", selection.project.map { "\($0.name) · \(ProjectFormat.path($0.root))" } ?? "Unknown project")
            row("Engine", ContainerStopWording.engine(selection.engineVersion))
        }
        .font(.caption)
    }

    private var isStopping: Bool {
        if case .stopping = phase { return true }
        return false
    }

    private func stopped(_ outcome: ContainerStopOutcome) -> Bool {
        outcome == .stopped || outcome == .stillStopping
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// GET only: the identity check and the plan the confirmation states. `stop` inspects again.
    private func checkFirst() async {
        guard case .checking = phase else { return }
        switch await selection.terms(exclusions: settings.exclusions) {
        case .success(let terms): phase = .confirmation(terms)
        case .failure(let refusal): phase = .outcome(refusal.outcome, sent: false)
        }
    }

    private func stop(_ plan: ContainerStopTerms) {
        // A double-click can call this twice before SwiftUI re-renders; only the first one acts.
        guard case .confirmation = phase else { return }
        let context = selection.context()
        let target = selection.target(exclusions: settings.exclusions)
        phase = .stopping(plan)
        Task {
            let outcome = await selection.stopper.stop(target, context: context)
            phase = .outcome(outcome, sent: true)
            if stopped(outcome) { onStopped() }
        }
    }
}
