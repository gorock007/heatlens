import SwiftUI

struct SettingsView: View {
    let settings: SettingsModel
    let onDone: () -> Void
    @State private var updates = UpdateChecker()

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

                MonitoringSourcesSection(settings: settings)

                VStack(alignment: .leading, spacing: 5) {
                    ExclusionEditor(
                        title: "Custom labels",
                        guidance: "One rule per line: token = Label, for example ffmpeg = Video encode. Matches a process name, executable or argument. Never runs anything.",
                        text: $settings.customLabels
                    )
                    let ignored = settings.ignoredLabelLines
                    if !ignored.isEmpty {
                        Text("Ignored: " + ignored.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    ExclusionEditor(
                        title: "Project folders",
                        guidance: "Optional. One folder per line: ~/Developer/FDA = FDA. Work in that folder counts toward that project. Without a line, HeatLens uses the nearest Git repository.",
                        text: $settings.projectMappingsText
                    )
                    let ignored = settings.ignoredMappingLines
                    if !ignored.isEmpty {
                        Text("Ignored: " + ignored.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ThermalAlertSection(settings: settings)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Open HeatLens with ⌃⌥H", isOn: $settings.globalHotkeyEnabled)
                    if settings.globalHotkeyEnabled, settings.globalHotkeyConflict {
                        Text("⌃⌥H is already used by another app")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                AgentConnectSection(bundleURL: Bundle.main.bundleURL)

                UpdateSection(checker: updates)

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

/// The opt-in sources from PRD-v2: both off by default, each says what it touches.
private struct MonitoringSourcesSection: View {
    @Bindable var settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Hardware sensors (private macOS interfaces)", isOn: $settings.hardwareSensorsEnabled)
                Text("Reads temperatures, fans and system power from the SMC, read-only and without admin rights. The interface is undocumented and may stop working after a macOS update; HeatLens then shows “Unavailable”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Docker containers", isOn: $settings.dockerEnabled)
                Text("Lists containers and their CPU and memory through the local Docker socket, read-only. HeatLens never starts Docker or changes a container.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Changes apply to the next scan or live start.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// The opt-in thermal alert. Turning it on asks for notification permission; if that's been
/// refused, points at System Settings, the only place it can be turned back on.
private struct ThermalAlertSection: View {
    let settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Alert me when my Mac runs hot", isOn: Binding(
                get: { settings.thermalAlertsEnabled },
                set: { settings.setThermalAlerts($0) }
            ))
            Text("Runs one scan when macOS reports serious thermal pressure, at most every 30 minutes. Nothing runs in between.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.thermalAlertsEnabled, settings.notificationsDenied {
                HStack {
                    Text("Notifications are off for HeatLens")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open System Settings") { Self.openNotificationSettings() }
                        .controlSize(.small)
                }
            }
        }
        .task(id: settings.thermalAlertsEnabled) {
            if settings.thermalAlertsEnabled { await settings.refreshNotificationStatus() }
        }
    }

    private static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.heatlens.HeatLens"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The click-only update check: one request to GitHub per click, never in the background.
private struct UpdateSection: View {
    let checker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("HeatLens \(checker.currentVersion)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(checker.state == .checking ? "Checking…" : "Check for updates…") {
                    Task { await checker.check() }
                }
                .disabled(checker.state == .checking)
            }
            Text("Contacts GitHub only when you click.")
                .font(.caption)
                .foregroundStyle(.secondary)
            switch checker.state {
            case .idle, .checking:
                EmptyView()
            case .upToDate:
                Text("You're up to date.")
                    .font(.caption)
            case .available(let version, let url):
                HStack {
                    Text("HeatLens \(version) is available.")
                        .font(.caption)
                    Spacer()
                    Button("Download") { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                }
            case .failed(let message):
                HStack {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Releases page") { NSWorkspace.shared.open(UpdateChecker.releasesPage) }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// Copies the command that registers the bundled `heatlens mcp` server with an agent. Nothing runs.
private struct AgentConnectSection: View {
    let bundleURL: URL
    @State private var copiedClaude = false
    @State private var copiedCodex = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect to an AI agent")
                .font(.subheadline.weight(.semibold))
            Text("Lets Claude Code, Codex or another MCP client run a read-only HeatLens scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let helper = AgentCommand.helperPath(bundleURL: bundleURL) {
                let claude = AgentCommand.claude(helper)
                let codex = AgentCommand.codex(helper)
                CommandText(text: claude, font: .caption.monospaced())
                Button(copiedClaude ? "Copied" : "Copy Claude Code command") {
                    Pasteboard.copy(claude)
                    copiedClaude = true
                }
                .resetsAfterCopy($copiedClaude)
                HStack {
                    Text("Codex")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(copiedCodex ? "Copied" : "Copy") {
                        Pasteboard.copy(codex)
                        copiedCodex = true
                    }
                    .controlSize(.small)
                    .resetsAfterCopy($copiedCodex)
                }
                .padding(.top, 4)
                CommandText(text: codex, font: .caption2.monospaced())
            } else {
                Text("Move HeatLens to Applications first")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct CommandText: View {
    let text: String
    let font: Font

    var body: some View {
        Text(verbatim: text)
            .font(font)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }
}

enum AgentCommand {
    /// The bundled CLI, or nil while the app runs from a translocated copy or a mounted disk
    /// image, where the path stops working once the app moves or the DMG is ejected.
    static func helperPath(bundleURL: URL) -> String? {
        let app = bundleURL.standardizedFileURL.path
        guard !app.contains("/AppTranslocation/"), !app.hasPrefix("/Volumes/") else { return nil }
        return bundleURL.appendingPathComponent("Contents/Helpers/heatlens").standardizedFileURL.path
    }

    static func claude(_ helper: String) -> String { "claude mcp add heatlens -- \(quoted(helper)) mcp" }
    static func codex(_ helper: String) -> String { "codex mcp add heatlens -- \(quoted(helper)) mcp" }

    /// Single-quoted for the shell, so spaces and other specials are literal.
    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
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
