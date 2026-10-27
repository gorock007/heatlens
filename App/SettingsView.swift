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

                AgentConnectSection(bundleURL: Bundle.main.bundleURL)

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
