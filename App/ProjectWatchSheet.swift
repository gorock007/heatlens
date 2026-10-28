import SwiftUI
import HeatLensCore

/// "Watch this project…" (brief 4g, owner decision 6): preset thresholds only, and it only alerts.
/// Opened from a Projects-card row in Live or a scan result; Save writes the `projectWatches`
/// setting, which reaches the running session like any other alert setting.
struct ProjectWatchSheet: View {
    let project: Project
    let settings: SettingsModel

    @Environment(\.dismiss) private var dismiss
    @State private var cpu: Double?
    @State private var memory: Double?
    @State private var commands: Double?
    @State private var saveError: String?

    init(project: Project, settings: SettingsModel) {
        self.project = project
        self.settings = settings
        let existing = settings.watch(for: project.id)
        _cpu = State(initialValue: existing?.cpu)
        _memory = State(initialValue: existing?.memory)
        _commands = State(initialValue: existing?.commands)
    }

    private var existing: ProjectWatch? { settings.watch(for: project.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(existing == nil ? "Watch this project" : "Edit watch")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: project.name)
                    .font(.callout.weight(.semibold))
                Text(verbatim: ProjectFormat.path(project.root))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                pickerRow("CPU above", metric: .cpu, selection: $cpu)
                pickerRow("Memory above", metric: .memory, selection: $memory)
                pickerRow("Expensive commands at once", metric: .commands, selection: $commands)
            }
            .font(.callout)
            Text("Alerts only: HeatLens notifies you and never stops or changes anything. CPU and memory must hold for 2 minutes, commands for 30 seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !settings.liveAlertsEnabled {
                HStack {
                    Text("Alerts are off")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Turn on alerts") { settings.setLiveAlerts(true) }
                        .controlSize(.small)
                }
            }
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(existing == nil && cpu == nil && memory == nil && commands == nil)
            }
        }
        .padding(16)
        // The panel's own width, so the sheet doesn't spill past it.
        .frame(width: 300)
    }

    private func pickerRow(_ title: String, metric: ProjectWatch.Metric, selection: Binding<Double?>) -> some View {
        GridRow {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Picker(title, selection: selection) {
                Text("Off").tag(Double?.none)
                ForEach(ProjectWatch.choices(metric).map(\.on), id: \.self) { on in
                    Text(ProjectWatch.describe(on, for: metric)).tag(Double?.some(on))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func save() {
        guard let watch = ProjectWatch(projectID: project.id, name: project.name, cpu: cpu, memory: memory, commands: commands) else {
            saveError = "This project's folder can't be watched."
            return
        }
        guard settings.setWatch(watch) else {
            saveError = "You can watch at most \(ProjectWatch.maxWatches) projects. Remove one in Settings first."
            return
        }
        dismiss()
    }
}
