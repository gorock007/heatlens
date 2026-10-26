import SwiftUI

struct SettingsView: View {
    let settings: SettingsModel
    let onDone: () -> Void

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sample duration")
                        .font(.subheadline.weight(.semibold))
                    Picker("Sample duration", selection: $settings.sampleDuration) {
                        Text("5 s").tag(TimeInterval(5))
                        Text("10 s").tag(TimeInterval(10))
                        Text("15 s").tag(TimeInterval(15))
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                ExclusionEditor(
                    title: "Excluded processes",
                    guidance: "One exact process name per line, for example node.",
                    text: $settings.excludedProcesses
                )

                ExclusionEditor(
                    title: "Excluded projects",
                    guidance: "One project directory prefix per line. ~/Projects/demo hides its children.",
                    text: $settings.excludedProjects
                )

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: Binding(
                        get: { settings.launchAtLoginEnabled },
                        set: { settings.setLaunchAtLogin($0) }
                    ))
                    Text(settings.launchAtLoginStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = settings.launchAtLoginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("Settings are stored on this Mac. HeatLens keeps no scan history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.trailing, 8)
        }
        .frame(height: 440)

        HStack {
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { settings.refreshLaunchAtLoginStatus() }
    }
}

private struct ExclusionEditor: View {
    let title: String
    let guidance: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            TextEditor(text: $text)
                .font(.caption.monospaced())
                .frame(height: 64)
                .padding(4)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            Text(guidance)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
