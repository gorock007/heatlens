import AppKit
import HeatLensCore
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsModel()
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
        // Live mode samples only while someone is looking (docs/v2/ADR-0003).
        statusPanel.onClose = { live.stop() }
        self.statusPanel = statusPanel
        thermalAlerts = ThermalAlertService(model: model) { statusPanel.show() }
        // After ThermalAlertService, the notification delegate that presents and opens these too.
        liveAlerts = LiveAlertService(live: live, settings: settings)
        hotkey = GlobalHotkey(settings: settings) { statusPanel.toggle() }
        #if DEBUG
        thermalAlerts?.simulateFromLaunchArguments()
        #endif
    }
}
