import Foundation
import HeatLensCore
import Observation
import UserNotifications

/// The opt-in thermal alert (off by default). While the setting is on it listens for
/// `ProcessInfo.thermalStateDidChangeNotification` and nothing else: on a rise into serious or
/// critical it runs one normal scan and, when that scan has results, posts one notification
/// naming the top culprit. `ThermalAlertPolicy` decides when; at most one alert per 30 minutes.
@MainActor
final class ThermalAlertService: NSObject, UNUserNotificationCenterDelegate {
    private static let notificationID = "dev.heatlens.thermal-alert"

    private let model: ScanModel
    private let showPanel: @MainActor () -> Void
    private let policy = ThermalAlertPolicy()
    private var observer: NSObjectProtocol?
    private var previous: ThermalState = .unavailable
    /// When the last alert scan started. In memory only: HeatLens keeps no history.
    private var lastAlert: Date?

    init(model: ScanModel, showPanel: @escaping @MainActor () -> Void) {
        self.model = model
        self.showPanel = showPanel
        super.init()
        UNUserNotificationCenter.current().delegate = self
        followSetting()
    }

    /// Adds the observer while the setting is on and removes it when it's turned off.
    private func followSetting() {
        let enabled = withObservationTracking {
            model.settings.thermalAlertsEnabled
        } onChange: {
            Task { @MainActor [weak self] in self?.followSetting() }
        }
        if enabled { startObserving() } else { stopObserving() }
    }

    private func startObserving() {
        guard observer == nil else { return }
        previous = Self.current()
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalStateChanged(to: Self.current()) }
        }
    }

    private func stopObserving() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }

    private func thermalStateChanged(to current: ThermalState) {
        let previous = self.previous
        self.previous = current
        let now = Date()
        guard policy.shouldScan(previous: previous, current: current, enabled: model.settings.thermalAlertsEnabled,
                                lastAlert: lastAlert, now: now, scanRunning: model.isScanning) else { return }
        lastAlert = now
        model.startScan { [weak self] report in
            guard let self, let report else { return }
            post(report, thermalState: current)
        }
    }

    private func post(_ report: ScanReport, thermalState: ThermalState) {
        let result = ScanResult(snapshot: report.snapshot, groups: report.groups, findings: report.findings)
        let summary = policy.summary(for: result, exclusions: model.settings.exclusions, thermalState: thermalState)
        let content = UNMutableNotificationContent()
        content.title = summary.title
        content.body = summary.body
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        // Settings asks when the toggle is turned on; this covers a setting that was on before
        // permission was ever asked. macOS asks the user at most once.
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }

    private static func current() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unavailable
        }
    }

    #if DEBUG
    /// `-HeatLensSimulateThermal serious` (or `critical`): one synthetic rise from nominal, 3 s
    /// after launch, through the same policy as a real one. Debug builds only.
    func simulateFromLaunchArguments() {
        guard let raw = UserDefaults.standard.string(forKey: "HeatLensSimulateThermal"),
              let state = ThermalState(rawValue: raw) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            previous = .nominal
            thermalStateChanged(to: state)
        }
    }
    #endif

    // MARK: UNUserNotificationCenterDelegate

    /// HeatLens has no windows to be frontmost over, so show the banner even while it's active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    /// A click opens the panel on the results already in the model.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isOpen = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        completionHandler()
        guard isOpen else { return }
        Task { @MainActor [weak self] in self?.showPanel() }
    }
}
