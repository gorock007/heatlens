import AppKit
import HeatLensCore
import MetricKit
import Observation
import SwiftUI

@main
struct HeatLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI is the status-item panel (StatusPanel.swift). The app still needs a scene; one
        // that's never inserted adds no window, menu item or shortcut (a Settings scene would
        // answer ⌘, with an empty window).
        MenuBarExtra("HeatLens", systemImage: "thermometer.medium", isInserted: .constant(false)) {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusPanel: StatusPanelController?
    private var thermalAlerts: ThermalAlertService?
    private var liveAlerts: LiveAlertService?
    private var hotkey: GlobalHotkey?
    private var live: LiveModel?
    private let crashDiagnostics = CrashDiagnostics()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsModel()
        CrashRecovery.shared.launched(keepWatching: settings.keepWatchingInBackground, retentionDays: settings.historyRetentionDays)
        MXMetricManager.shared.add(crashDiagnostics)
        let scanService: any ScanService
        let stopService: any ProcessStopping
        let containerStopService: any ContainerStopProviding
        // One ledger for the session: process stops, force quits and container stops. Its records
        // are saved to history only while Keep history is on (brief 3e-1).
        let ledger = ActionLog.shared.ledger
        ActionLog.shared.follow(settings)
        let containerStopAllowed: @MainActor @Sendable () -> Bool = { settings.canStopContainers }
        #if DEBUG
        // `-HeatLensFixtures YES`: canned results and stops that signal nothing and open no socket,
        // so fixture UI (the leftovers batch sheet, the container stop sheet and the rest) can be
        // clicked through. Debug builds only.
        if UserDefaults.standard.bool(forKey: "HeatLensFixtures") {
            scanService = FixtureScanService()
            stopService = FixtureStopService()
            containerStopService = FixtureContainerStopService(enabled: containerStopAllowed)
        } else {
            scanService = PipelineScanService()
            stopService = TerminatorStopService(ledger: ledger, forceQuitAllowed: { settings.forceQuitEnabled })
            containerStopService = ContainerStopService(ledger: ledger, enabled: containerStopAllowed)
        }
        #else
        scanService = PipelineScanService()
        stopService = TerminatorStopService(ledger: ledger, forceQuitAllowed: { settings.forceQuitEnabled })
        containerStopService = ContainerStopService(ledger: ledger, enabled: containerStopAllowed)
        #endif
        // One model for the app's lifetime, so a running scan and the last result survive a close.
        let model = ScanModel(service: scanService, settings: settings)
        let live = LiveModel(settings: settings)
        let statusPanel = StatusPanelController {
            PopoverView(model: model, live: live, stopService: stopService, containerStopService: containerStopService)
        }
        // v1's Live samples only while someone is looking (docs/v2/ADR-0003); with "Keep watching
        // in the background" on, a close drops to the background cadence (ADR-0008 §4).
        statusPanel.onOpen = { live.viewerOpened() }
        statusPanel.onClose = {
            live.viewerClosed()
            CrashRecovery.shared.panelClosed()
        }
        self.statusPanel = statusPanel
        self.live = live
        followLiveStatus()
        thermalAlerts = ThermalAlertService(model: model) { statusPanel.show() }
        // After ThermalAlertService, the notification delegate that presents and opens these too.
        liveAlerts = LiveAlertService(live: live, settings: settings)
        hotkey = GlobalHotkey(settings: settings) { statusPanel.toggle() }
        #if DEBUG
        thermalAlerts?.simulateFromLaunchArguments()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        CrashRecovery.shared.quitting()
    }

    /// The status item's tooltip names the mode.
    private func followLiveStatus() {
        guard let live else { return }
        let toolTip = withObservationTracking {
            live.toolTip
        } onChange: {
            Task { @MainActor [weak self] in self?.followLiveStatus() }
        }
        statusPanel?.toolTip = toolTip
    }
}

/// Notices after HeatLens quit unexpectedly (docs/v2/PHASE-4-PLAN.md, 4e). One settings flag,
/// `lastExitWasClean`: false while HeatLens runs, true once it quits normally. HeatLens never
/// reads crash reports, and never deletes or renames history by itself.
@MainActor @Observable
final class CrashRecovery {
    static let shared = CrashRecovery()
    static let cleanExitKey = "lastExitWasClean"
    static let crashReports = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

    /// "HeatLens quit unexpectedly last time…", until the panel closes after Live showed it.
    private(set) var uncleanExitNotice: String?
    /// The history file failed `PRAGMA quick_check` after an unclean exit.
    private(set) var historyDamaged = false
    @ObservationIgnored private var noticeSeen = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func launched(keepWatching: Bool, retentionDays: Int) {
        // A first launch has no flag: nothing to report.
        let clean = defaults.object(forKey: Self.cleanExitKey) as? Bool ?? true
        defaults.set(false, forKey: Self.cleanExitKey)
        guard !clean else { return }
        HeatLensLog.notice(.live, "unclean exit noticed", ["keepWatching": .flag(keepWatching)])
        uncleanExitNotice = keepWatching
            ? "HeatLens quit unexpectedly last time. Background watching resumed."
            : "HeatLens quit unexpectedly last time. Live is stopped."
        // Only a file that already exists: the check must not create one.
        guard HistoryService.shared.fileSize > 0 else { return }
        guard let store = HistoryService.shared.existingStore(retentionDays: retentionDays) else {
            // A file there that won't open is damaged too, as far as the user can act on it.
            historyDamaged = true
            return
        }
        Task {
            let ok = (try? await store.integrityCheck()) ?? true
            if !ok { historyDamaged = true }
        }
    }

    func quitting() {
        defaults.set(true, forKey: Self.cleanExitKey)
    }

    /// Live is showing the notice.
    func noticeShown() {
        if uncleanExitNotice != nil { noticeSeen = true }
    }

    /// The notice goes once it has been seen: when the panel closes or Live is left.
    func panelClosed() {
        guard noticeSeen else { return }
        uncleanExitNotice = nil
        noticeSeen = false
    }

    func showCrashReports() {
        NSWorkspace.shared.open(Self.crashReports)
    }

    func deleteHistory() async {
        await HistoryService.shared.deleteHistory()
        if HistoryService.shared.lastError == nil { historyDamaged = false }
    }
}

/// MetricKit's crash diagnostics (macOS 12+), delivered on a later launch. Each is logged
/// (exception type, signal, app version as numbers) and nothing is written to a file.
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for crash in payloads.flatMap({ $0.crashDiagnostics ?? [] }) {
            // The version goes in as numbers: the log's only text values are private names.
            let version = crash.applicationVersion.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
            HeatLensLog.error(.live, "crash diagnostic", ["exceptionType": .count(crash.exceptionType?.intValue ?? -1),
                                                          "signal": .count(crash.signal?.intValue ?? -1),
                                                          "versionMajor": .count(version[0]), "versionMinor": .count(version[1]),
                                                          "versionPatch": .count(version[2])])
        }
    }
}
