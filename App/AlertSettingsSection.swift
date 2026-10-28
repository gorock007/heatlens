import AppKit
import HeatLensCore
import SwiftUI

/// Live alerts (brief 3c): off by default. One master switch, then a switch and an *on*
/// threshold per rule; the *off* threshold follows from the choice. Checked while Live runs or
/// HeatLens is watching in the background (docs/v2/ADR-0008).
struct AlertSettingsSection: View {
    let settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Alert me while Live is running", isOn: Binding(
                get: { settings.liveAlertsEnabled },
                set: { settings.setLiveAlerts($0) }
            ))
            Text(settings.keepWatchingInBackground
                 ? "Checked while Live runs or HeatLens is watching in the background, until Pause or Quit."
                 : "Checked while Live runs or HeatLens is watching in the background. Keep watching in the background is off, so Live stops when the panel closes: turn it on below, or drag the panel off the menu bar to keep it open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.liveAlertsEnabled {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    ForEach(AlertRule.Kind.allCases, id: \.self) { kind in
                        GridRow {
                            Toggle(Self.name(kind), isOn: Binding(
                                get: { settings.alertRulesEnabled[kind] ?? true },
                                set: { settings.alertRulesEnabled[kind] = $0 }
                            ))
                            threshold(kind)
                        }
                    }
                }
                .controlSize(.small)
                .padding(.leading, 18)
                if settings.thermalAlertsEnabled, settings.alertRulesEnabled[.thermal] ?? true {
                    Text("“Alert me when my Mac runs hot” is on, so a Live thermal alert only marks the timeline.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 18)
                }
                watchedProjects
                    .padding(.leading, 18)
                if settings.notificationsDenied {
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
        }
        .task(id: settings.liveAlertsEnabled) {
            if settings.liveAlertsEnabled { await settings.refreshNotificationStatus() }
        }
    }

    /// The watches from Projects cards (brief 4g): names and thresholds, each with Remove.
    @ViewBuilder
    private var watchedProjects: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Watched projects")
                .font(.callout)
            if settings.projectWatches.isEmpty {
                Text("None. Open a project in Live or a scan result and choose “Watch this project…”.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(settings.projectWatches) { watch in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: watch.name)
                            .font(.caption)
                        Text(Self.summary(watch))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { settings.removeWatch(projectID: watch.projectID) }
                        .controlSize(.small)
                }
            }
            if let notice = settings.projectWatchesNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    /// "CPU above 200% · Memory above 4 GB"
    private static func summary(_ watch: ProjectWatch) -> String {
        ProjectWatch.Metric.allCases.compactMap { metric in
            watch.threshold(metric).map { on in
                switch metric {
                case .cpu: "CPU above \(ProjectWatch.describe(on, for: metric))"
                case .memory: "Memory above \(ProjectWatch.describe(on, for: metric))"
                case .commands: "\(ProjectWatch.describe(on, for: metric)) or more commands at once"
                }
            }
        }.joined(separator: " · ")
    }

    @ViewBuilder
    private func threshold(_ kind: AlertRule.Kind) -> some View {
        let rule = AlertRule.defaults(kind, on: settings.alertThresholds[kind] ?? AlertRule.defaults(kind).on)
        let choices = AlertRule.thresholdChoices(kind)
        HStack(spacing: 4) {
            if choices.count > 1 {
                Picker(Self.name(kind), selection: Binding(
                    get: { rule.on },
                    set: { settings.alertThresholds[kind] = $0 }
                )) {
                    ForEach(choices.map(\.on), id: \.self) { Text(AlertRule.describe($0, for: kind)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Text(AlertRule.describe(rule.on, for: kind) + " or higher")
            }
            Text(Self.detail(rule))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .disabled(!(settings.alertRulesEnabled[kind] ?? true))
    }

    private static func name(_ kind: AlertRule.Kind) -> String {
        switch kind {
        case .sustainedCPU: "CPU"
        case .memory: "Memory used"
        case .swap: "Swap"
        case .thermal: "Thermal pressure"
        case .containers: "Running containers"
        }
    }

    /// "for 2 min · clears below 60%"
    private static func detail(_ rule: AlertRule) -> String {
        let minutes = Int(rule.sustain / 60)
        let clears = rule.kind == .containers
            ? "clears at \(Int(rule.off) - 1) or fewer"
            : rule.kind == .thermal ? "clears below serious" : "clears below \(AlertRule.describe(rule.off, for: rule.kind))"
        return "for \(minutes) min · \(clears)"
    }

    private static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.heatlens.HeatLens"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") else { return }
        NSWorkspace.shared.open(url)
    }
}
