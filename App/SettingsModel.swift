import Foundation
import Observation
import ServiceManagement

/// User-controlled preferences only. HeatLens stores no scan history.
@MainActor @Observable
final class SettingsModel {
    private enum Key {
        static let sampleDuration = "sampleDuration"
        static let excludedProcesses = "excludedProcesses"
        static let excludedProjects = "excludedProjects"
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

    private(set) var launchAtLoginEnabled = false
    private(set) var launchAtLoginStatus = "Off"
    private(set) var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedDuration = defaults.double(forKey: Key.sampleDuration)
        sampleDuration = [5.0, 10.0, 15.0].contains(storedDuration) ? storedDuration : 10
        excludedProcesses = defaults.string(forKey: Key.excludedProcesses) ?? ""
        excludedProjects = defaults.string(forKey: Key.excludedProjects) ?? ""
        refreshLaunchAtLoginStatus()
    }

    var excludedProcessNames: [String] { lines(in: excludedProcesses) }
    var excludedProjectPrefixes: [String] { lines(in: excludedProjects) }

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
