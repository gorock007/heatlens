import SwiftUI

/// The menu-bar popover (PRD §7): idle, scanning or results. Holds no timers; the only work
/// happens inside a scan the user started.
struct PopoverView: View {
    let model: ScanModel
    let stopService: any ProcessStopping
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(showingSettings: showingSettings, settingsDisabled: model.isScanning) {
                showingSettings.toggle()
            }

            if showingSettings {
                SettingsView(settings: model.settings) { showingSettings = false }
            } else {
                switch model.state {
                case .idle(let lastScan):
                    IdleView(lastScan: lastScan) { model.startScan() }
                case .scanning(let elapsed, let total):
                    ScanningView(elapsed: elapsed, total: total) { model.cancel() }
                case .results(let report):
                    ResultsView(report: report, settings: model.settings, stopService: stopService,
                                onScanAgain: { model.startScan() }, onDone: { model.dismiss() })
                case .failed(let message):
                    FailedView(message: message, onRetry: { model.startScan() }, onDone: { model.dismiss() })
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Quit HeatLens") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct Header: View {
    let showingSettings: Bool
    let settingsDisabled: Bool
    let onSettings: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("HeatLens")
                .font(.headline)
            Spacer()
            Button(showingSettings ? "Close settings" : "Settings", systemImage: showingSettings ? "xmark" : "gearshape",
                   action: onSettings)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(settingsDisabled)
                .help(showingSettings ? "Close settings" : "Settings")
        }
    }
}

private struct IdleView: View {
    let lastScan: Date?
    let onScan: () -> Void

    var body: some View {
        Text(lastScan.map { "Last scan: \(Format.relative($0))" } ?? "Last scan: never")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        Button(action: onScan) {
            Text("Scan now")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)

        Text("Nothing is monitored until you scan.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct ScanningView: View {
    let elapsed: TimeInterval
    let total: TimeInterval
    let onCancel: () -> Void

    var body: some View {
        Text("Measuring process activity (\(Int(elapsed)) of \(Int(total)) seconds)")
            .font(.callout)

        ProgressView(value: min(elapsed, total), total: max(total, 1))

        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
    }
}

private struct FailedView: View {
    let message: String
    let onRetry: () -> Void
    let onDone: () -> Void

    var body: some View {
        Label("The scan didn't finish", systemImage: "exclamationmark.triangle")
            .font(.callout.weight(.semibold))
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            Button("Done", action: onDone)
            Spacer()
            Button("Try again", action: onRetry)
                .keyboardShortcut(.defaultAction)
        }
    }
}

#Preview("Idle") {
    PopoverView(model: ScanModel(service: FixtureScanService()), stopService: FixtureStopService())
}
