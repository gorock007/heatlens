import Foundation
import HeatLensCore
import Observation
import UserNotifications

/// Posts one notification per Live alert (brief 3c). The alerts come from the monitor's
/// `.alerts` events, so they post whether or not the panel is open, and nothing here runs unless
/// Live or background watching samples: no timer, no sampling of its own. It also hands alert
/// settings to the session.
///
/// Foreground presentation and click-to-open come from `ThermalAlertService`, the app's
/// `UNUserNotificationCenter` delegate: its handlers apply to every HeatLens notification.
@MainActor
final class LiveAlertService {
    private static let notificationPrefix = "dev.heatlens.live-alert."

    private let live: LiveModel
    private let settings: SettingsModel
    /// Alerts already posted, so an alert seen twice never posts twice.
    private var posted: [String] = []
    private var events: Task<Void, Never>?

    init(live: LiveModel, settings: SettingsModel) {
        self.live = live
        self.settings = settings
        followAlerts()
        followSettings()
    }

    /// `.summary`: status and alerts, never ticks, for the app's lifetime.
    private func followAlerts() {
        let monitor = live.monitor
        events = Task { [weak self] in
            let stream = await monitor.subscribe(.summary)
            for await event in stream {
                guard let self else { break }
                if case .alerts(let alerts) = event { self.receive(alerts) }
            }
        }
    }

    private func receive(_ alerts: [Alert]) {
        for alert in alerts where !posted.contains(alert.id) {
            posted.append(alert.id)
            post(alert)
        }
        if posted.count > 50 { posted.removeFirst(posted.count - 50) }
    }

    /// A rule or threshold changed in Settings: the session picks it up on its next tick.
    private func followSettings() {
        let configuration = withObservationTracking {
            settings.alertConfiguration
        } onChange: {
            Task { @MainActor [weak self] in self?.followSettings() }
        }
        live.setAlerts(configuration)
    }

    /// One per rule, or per watched project and metric, so a repeat replaces the last banner.
    /// `projectHash` keeps the folder out of the identifier.
    private static func identifier(_ alert: Alert) -> String {
        if let watch = alert.watch { return notificationPrefix + "watch.\(watch.metric.rawValue).\(watch.projectHash)" }
        return notificationPrefix + (alert.rule?.rawValue ?? alert.id)
    }

    /// A rule: its projects, then the suggestion. A watch, whose title already names the project:
    /// the value now and the threshold, then the suggestion. Names and figures only, never a path.
    private static func body(_ alert: Alert) -> String {
        guard alert.watch != nil else {
            return (alert.projects.isEmpty ? "" : alert.projects.joined(separator: ", ") + " · ") + alert.suggestion
        }
        let figures = alert.observations.prefix(2).map { "\($0.label): \($0.value)" }
        return (figures + [alert.suggestion]).joined(separator: " · ")
    }

    private func post(_ alert: Alert) {
        // The opt-in thermal alert (v1) already notifies on serious heat: the timeline marker is enough.
        if alert.rule == .thermal, settings.thermalAlertsEnabled { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = Self.body(alert)
        // Owner decision 2 (ADR-0008): alerts respect Focus, never Time Sensitive.
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: Self.identifier(alert), content: content, trigger: nil)
        // Settings asks when the switch is turned on; macOS asks the user at most once.
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }
}
