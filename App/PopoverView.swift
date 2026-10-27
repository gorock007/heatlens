import SwiftUI

/// The menu-bar popover (PRD §7): idle, scanning or results, or Live mode (PRD-v2 Phase 1).
/// Holds no timers; the only work happens inside a scan or live session the user started.
struct PopoverView: View {
    enum Mode: Hashable { case scan, live }

    let model: ScanModel
    let live: LiveModel
    let stopService: any ProcessStopping
    @State private var showingSettings = false
    @State private var mode: Mode = .scan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(showingSettings: showingSettings, settingsDisabled: model.isScanning) {
                showingSettings.toggle()
            }

            if !showingSettings {
                Picker("Mode", selection: $mode) {
                    Text("Scan").tag(Mode.scan)
                    Text("Live").tag(Mode.live)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, newMode in
                    if newMode == .scan { live.stop() }
                }
            }

            if showingSettings {
                SettingsView(settings: model.settings) { showingSettings = false }
            } else if mode == .live {
                LiveView(model: live)
            } else {
                switch model.state {
                case .idle(let lastScan):
                    IdleView(lastScan: lastScan) { model.startScan() }
                case .scanning(let elapsed, let total):
                    ScanningView(elapsed: elapsed, total: total) { model.cancel() }
                case .results(let report):
                    ResultsView(report: report, settings: model.settings, stopService: stopService,
                                previousReport: model.previousReport, stoppedSinceLastScan: model.stoppedSinceLastScan,
                                onScanAgain: { model.startScan() }, onStopped: { model.recordStop() },
                                onDone: { model.dismiss() })
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
        // New Settings switches take effect at once in a running live session.
        .onChange(of: showingSettings) { _, isShowing in
            if !isShowing, live.isRunning { live.start() }
        }
    }
}

private struct Header: View {
    let showingSettings: Bool
    let settingsDisabled: Bool
    let onSettings: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // Lets a press on the title reach the panel's drag background (StatusPanel.swift).
            Text("HeatLens")
                .font(.headline)
                .allowsHitTesting(false)
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
    let settings = SettingsModel()
    PopoverView(model: ScanModel(service: FixtureScanService(), settings: settings), live: LiveModel(settings: settings),
                stopService: FixtureStopService())
}
