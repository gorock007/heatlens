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
        static let forceQuitEnabled = "forceQuitEnabled"
        static let containerStopEnabled = "containerStopEnabled"
        static let customLabels = "customLabels"
        static let projectMappings = "projectMappings"
        static let liveInterval = "liveInterval"
        static let keepHistory = "keepHistory"
        static let historyRetentionDays = "historyRetentionDays"
        static let liveAlertsEnabled = "liveAlertsEnabled"
        static let keepWatchingInBackground = "keepWatchingInBackground"
        static func alertRuleEnabled(_ kind: AlertRule.Kind) -> String { "liveAlert.\(kind.rawValue).enabled" }
        static func alertThreshold(_ kind: AlertRule.Kind) -> String { "liveAlert.\(kind.rawValue).on" }
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
    /// Off by default: after a stop request a process ignores, offer Force Quit (SIGKILL) behind a
    /// second confirmation (docs/v2/ADR-0006). Off, HeatLens sends nothing stronger than SIGTERM.
    var forceQuitEnabled: Bool {
        didSet { defaults.set(forceQuitEnabled, forKey: Key.forceQuitEnabled) }
    }
    /// Off by default, and only in effect while `dockerEnabled` is on: a scan result's container
    /// detail offers "Stop container…", which is `docker stop` (docs/v2/ADR-0007). Off, HeatLens
    /// only reads from Docker. Turning Docker off keeps this value but disables stopping.
    var containerStopEnabled: Bool {
        didSet { defaults.set(containerStopEnabled, forKey: Key.containerStopEnabled) }
    }
    /// Docker is on and "Allow stopping a container" is on.
    var canStopContainers: Bool { dockerEnabled && containerStopEnabled }
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
    /// Off by default: live ticks are saved to a local, bounded history (docs/v2/ADR-0005).
    var keepHistory: Bool {
        didSet { defaults.set(keepHistory, forKey: Key.keepHistory) }
    }
    var historyRetentionDays: Int {
        didSet {
            defaults.set(historyRetentionDays, forKey: Key.historyRetentionDays)
            HistoryService.shared.setRetention(days: historyRetentionDays)
        }
    }
    /// Opt-in, off by default: alert rules checked only while Live runs (brief 3c).
    var liveAlertsEnabled: Bool {
        didSet { defaults.set(liveAlertsEnabled, forKey: Key.liveAlertsEnabled) }
    }
    /// Off by default (docs/v2/ADR-0008 §4): after the panel closes, Live keeps sampling at
    /// `SamplingPolicy`'s cadence until Pause or Quit, so alerts and history keep working.
    var keepWatchingInBackground: Bool {
        didSet { defaults.set(keepWatchingInBackground, forKey: Key.keepWatchingInBackground) }
    }
    /// Each rule's own switch; all on once the master switch is on.
    var alertRulesEnabled: [AlertRule.Kind: Bool] {
        didSet { for (kind, enabled) in alertRulesEnabled { defaults.set(enabled, forKey: Key.alertRuleEnabled(kind)) } }
    }
    /// Each rule's *on* threshold, one of `AlertRule.thresholdChoices`; its *off* follows.
    var alertThresholds: [AlertRule.Kind: Double] {
        didSet { for (kind, on) in alertThresholds { defaults.set(on, forKey: Key.alertThreshold(kind)) } }
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
        forceQuitEnabled = defaults.bool(forKey: Key.forceQuitEnabled)
        containerStopEnabled = defaults.bool(forKey: Key.containerStopEnabled)
        customLabels = defaults.string(forKey: Key.customLabels) ?? ""
        projectMappingsText = defaults.string(forKey: Key.projectMappings) ?? ""
        let storedInterval = defaults.double(forKey: Key.liveInterval)
        liveInterval = LiveConfiguration.intervals.contains(storedInterval) ? storedInterval : 5
        keepHistory = defaults.bool(forKey: Key.keepHistory)
        let storedRetention = defaults.integer(forKey: Key.historyRetentionDays)
        historyRetentionDays = HistoryStore.retentionChoices.contains(storedRetention) ? storedRetention : HistoryStore.defaultRetentionDays
        liveAlertsEnabled = defaults.bool(forKey: Key.liveAlertsEnabled)
        keepWatchingInBackground = defaults.bool(forKey: Key.keepWatchingInBackground)
        var rulesEnabled: [AlertRule.Kind: Bool] = [:]
        var thresholds: [AlertRule.Kind: Double] = [:]
        for kind in AlertRule.Kind.allCases {
            rulesEnabled[kind] = defaults.object(forKey: Key.alertRuleEnabled(kind)) as? Bool ?? true
            let stored = defaults.object(forKey: Key.alertThreshold(kind)) as? Double
            thresholds[kind] = AlertRule.defaults(kind, on: stored ?? AlertRule.defaults(kind).on).on
        }
        alertRulesEnabled = rulesEnabled
        alertThresholds = thresholds
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

    func isProcessExcluded(_ name: String) -> Bool {
        exclusions.excludes(processName: name, projectDirectory: nil)
    }

    /// True for the directory itself and for anything under an excluded prefix.
    func isProjectExcluded(_ directory: String) -> Bool {
        exclusions.excludes(processName: nil, projectDirectory: directory)
    }

    /// "Ignore this process": adds the name to the excluded processes unless it already matches
    /// one (case-insensitively, as the filter compares). Returns whether a line was added.
    @discardableResult
    func ignoreProcess(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isProcessExcluded(name) else { return false }
        excludedProcesses = appending(name, to: excludedProcesses)
        return true
    }

    /// "Ignore this project": adds the directory, with `~` for the home directory, unless it or a
    /// prefix of it is already excluded. Returns whether a line was added.
    @discardableResult
    func ignoreProject(_ directory: String) -> Bool {
        guard !directory.isEmpty, !isProjectExcluded(directory) else { return false }
        excludedProjects = appending(ProjectFormat.path(directory), to: excludedProjects)
        return true
    }

    /// What Live checks, from the switches and thresholds above.
    var alertConfiguration: AlertConfiguration {
        AlertConfiguration(isEnabled: liveAlertsEnabled, rules: AlertRule.Kind.allCases.map { kind in
            AlertRule.defaults(kind, on: alertThresholds[kind] ?? AlertRule.defaults(kind).on, isEnabled: alertRulesEnabled[kind] ?? true)
        })
    }

    /// Like `setThermalAlerts`: turning Live alerts on asks for notification permission.
    func setLiveAlerts(_ enabled: Bool) {
        liveAlertsEnabled = enabled
        guard enabled else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            await refreshNotificationStatus()
        }
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

    private func appending(_ line: String, to text: String) -> String {
        text.isEmpty || text.hasSuffix("\n") ? text + line : text + "\n" + line
    }

    private func lines(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
