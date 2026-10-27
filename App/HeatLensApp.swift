import AppKit
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
    private var hotkey: GlobalHotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsModel()
        let scanService: any ScanService
        let stopService: any ProcessStopping
        #if DEBUG
        // `-HeatLensFixtures YES`: canned results and a stop that signals nothing, so fixture UI
        // (the leftovers batch sheet and the rest) can be clicked through. Debug builds only.
        if UserDefaults.standard.bool(forKey: "HeatLensFixtures") {
            scanService = FixtureScanService()
            stopService = FixtureStopService()
        } else {
            scanService = PipelineScanService()
            stopService = TerminatorStopService()
        }
        #else
        scanService = PipelineScanService()
        stopService = TerminatorStopService()
        #endif
        // One model for the app's lifetime, so a running scan and the last result survive a close.
        let model = ScanModel(service: scanService, settings: settings)
        let statusPanel = StatusPanelController {
            PopoverView(model: model, stopService: stopService)
        }
        self.statusPanel = statusPanel
        thermalAlerts = ThermalAlertService(model: model) { statusPanel.show() }
        hotkey = GlobalHotkey(settings: settings) { statusPanel.toggle() }
        #if DEBUG
        thermalAlerts?.simulateFromLaunchArguments()
        #endif
    }
}
