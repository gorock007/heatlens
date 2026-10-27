import Foundation
import HeatLensCore
import Observation
import ServiceManagement
import UserNotifications

/// The opt-in sources a scan or live session reads, captured on the main actor.
struct CollectionOptions: Sendable {
    var hardwareSensors = false
    var docker = false
    var userRules: [WorkloadRule] = []
    var projectMappings: [ProjectMapping] = []

    var hardwareProvider: any HardwareSensorProviding {
        hardwareSensors ? SMCSensorProvider() : DisabledHardwareProvider()
    }

    var dockerSampler: any DockerSampling {
        docker ? DockerEngineSampler() : DisabledDockerSampler()
    }
}

/// User-controlled preferences only. HeatLens stores no scan history.
@MainActor @Observable
final class SettingsModel {
    private enum Key {
        static let sampleDuration = "sampleDuration"
        static let excludedProcesses = "excludedProcesses"
        static let excludedProjects = "excludedProjects"
        static let thermalAlertsEnabled = "thermalAlertsEnabled"
        static let globalHotkeyEnabled = "globalHotkeyEnabled"
        static let hardwareSensorsEnabled = "hardwareSensorsEnabled"
        static let dockerEnabled = "dockerEnabled"
        static let customLabels = "customLabels"
        static let projectMappings = "projectMappings"
        static let liveInterval = "liveInterval"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var sampleDuration: TimeInterval {
        didSet { defaults.set(sampleDuration, forKey: Key.sampleDuration) }
    }
    var excludedProcesses: String {
        didSet { defaults.set(excludedProcesses, forKey: Key.excludedProcesses) }
    }
    var excludedProjects: String {
        didSet { defaults.set(excludedProjects, forKey: Key.excludedProjects) }
    }
    /// Opt-in, off by default: one scan and a notification when macOS reports serious heat.
    var thermalAlertsEnabled: Bool {
        didSet { defaults.set(thermalAlertsEnabled, forKey: Key.thermalAlertsEnabled) }
    }
    /// Opt-in, off by default: ⌃⌥H opens or closes the panel from any app.
    var globalHotkeyEnabled: Bool {
        didSet { defaults.set(globalHotkeyEnabled, forKey: Key.globalHotkeyEnabled) }
    }
    /// On by default from v2.0 (docs/v2/ADR-0001, owner decision 2026-10-27): temperatures, fans and
    /// system power from the SMC, a private macOS interface, read-only. An explicit "off" is kept.
    var hardwareSensorsEnabled: Bool {
        didSet { defaults.set(hardwareSensorsEnabled, forKey: Key.hardwareSensorsEnabled) }
    }
    /// Opt-in, off by default: read-only Docker Engine API on the local socket (docs/v2/ADR-0002).
    var dockerEnabled: Bool {
        didSet { defaults.set(dockerEnabled, forKey: Key.dockerEnabled) }
    }
    /// `token = Label` lines; see `WorkloadRule.parse`.
    var customLabels: String {
        didSet { defaults.set(customLabels, forKey: Key.customLabels) }
    }
    /// `path = Name` lines; see `ProjectMapping.parse`.
    var projectMappingsText: String {
        didSet { defaults.set(projectMappingsText, forKey: Key.projectMappings) }
    }
    /// Live refresh interval: 2, 5 or 10 s.
    var liveInterval: TimeInterval {
        didSet { defaults.set(liveInterval, forKey: Key.liveInterval) }
    }
    /// Set by `GlobalHotkey` when ⌃⌥H couldn't be registered, usually because another app holds it.
    var globalHotkeyConflict = false
    /// True when the user has turned HeatLens notifications off in System Settings.
    private(set) var notificationsDenied = false

    private(set) var launchAtLoginEnabled = false
    private(set) var launchAtLoginStatus = "Off"
    private(set) var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedDuration = defaults.double(forKey: Key.sampleDuration)
        sampleDuration = [5.0, 10.0, 15.0].contains(storedDuration) ? storedDuration : 10
        excludedProcesses = defaults.string(forKey: Key.excludedProcesses) ?? ""
        excludedProjects = defaults.string(forKey: Key.excludedProjects) ?? ""
        thermalAlertsEnabled = defaults.bool(forKey: Key.thermalAlertsEnabled)
        globalHotkeyEnabled = defaults.bool(forKey: Key.globalHotkeyEnabled)
        hardwareSensorsEnabled = defaults.object(forKey: Key.hardwareSensorsEnabled) as? Bool ?? true
        dockerEnabled = defaults.bool(forKey: Key.dockerEnabled)
        customLabels = defaults.string(forKey: Key.customLabels) ?? ""
        projectMappingsText = defaults.string(forKey: Key.projectMappings) ?? ""
        let storedInterval = defaults.double(forKey: Key.liveInterval)
        liveInterval = LiveConfiguration.intervals.contains(storedInterval) ? storedInterval : 5
        refreshLaunchAtLoginStatus()
    }

    var excludedProcessNames: [String] { lines(in: excludedProcesses) }
    var excludedProjectPrefixes: [String] { lines(in: excludedProjects) }
    var workloadRules: [WorkloadRule] { WorkloadRule.parse(customLabels).rules }
    var ignoredLabelLines: [String] { WorkloadRule.parse(customLabels).ignored }
    var projectMappings: [ProjectMapping] { ProjectMapping.parse(projectMappingsText).mappings }
    var ignoredMappingLines: [String] { ProjectMapping.parse(projectMappingsText).invalid }

    /// What a scan or live session reads besides processes, from the switches above.
    var collectionOptions: CollectionOptions {
        CollectionOptions(hardwareSensors: hardwareSensorsEnabled, docker: dockerEnabled, userRules: workloadRules,
                          projectMappings: projectMappings)
    }

    var exclusions: ExclusionFilter {
        ExclusionFilter(processNames: excludedProcessNames, projectPrefixes: excludedProjectPrefixes)
    }

    /// Turning alerts on asks for notification permission (macOS asks only the first time).
    func setThermalAlerts(_ enabled: Bool) {
        thermalAlertsEnabled = enabled
        guard enabled else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            await refreshNotificationStatus()
        }
    }

    func refreshNotificationStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsDenied = status == .denied
    }

    func refreshLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginStatus = "On"
        case .requiresApproval:
            launchAtLoginEnabled = false
            launchAtLoginStatus = "Needs approval in System Settings"
        case .notFound:
            launchAtLoginEnabled = false
            launchAtLoginStatus = "Unavailable for this build"
        case .notRegistered:
            launchAtLoginEnabled = false
            launchAtLoginStatus = "Off"
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginStatus = "Unavailable"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }

    private func lines(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
