import Foundation
import HeatLensCore
import Observation
import UserNotifications

/// Posts one notification per Live alert (brief 3c). The alerts come from `LiveTick.alerts`, so
/// nothing here runs unless Live is running: no timer, no sampling of its own. It also hands
/// Settings changes to a running session.
///
/// Foreground presentation and click-to-open come from `ThermalAlertService`, the app's
/// `UNUserNotificationCenter` delegate: its handlers apply to every HeatLens notification.
@MainActor
final class LiveAlertService {
    private static let notificationPrefix = "dev.heatlens.live-alert."

    private let live: LiveModel
    private let settings: SettingsModel
    /// Alerts already posted, so a tick seen twice never posts twice.
    private var posted: [String] = []

    init(live: LiveModel, settings: SettingsModel) {
        self.live = live
        self.settings = settings
        followTicks()
        followSettings()
    }

    private func followTicks() {
        let alerts = withObservationTracking {
            live.latest?.alerts ?? []
        } onChange: {
            Task { @MainActor [weak self] in self?.followTicks() }
        }
        for alert in alerts where !posted.contains(alert.id) {
            posted.append(alert.id)
            post(alert)
        }
        if posted.count > 50 { posted.removeFirst(posted.count - 50) }
    }

    /// A rule or threshold changed in Settings: the running session picks it up on its next tick.
    private func followSettings() {
        let configuration = withObservationTracking {
            settings.alertConfiguration
        } onChange: {
            Task { @MainActor [weak self] in self?.followSettings() }
        }
        live.setAlerts(configuration)
    }

    private func post(_ alert: Alert) {
        // The opt-in thermal alert (v1) already notifies on serious heat: the timeline marker is enough.
        if alert.rule == .thermal, settings.thermalAlertsEnabled { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = (alert.projects.isEmpty ? "" : alert.projects.joined(separator: ", ") + " · ") + alert.suggestion
        let request = UNNotificationRequest(identifier: Self.notificationPrefix + (alert.rule?.rawValue ?? alert.id), content: content, trigger: nil)
        // Settings asks when the switch is turned on; macOS asks the user at most once.
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }
}
