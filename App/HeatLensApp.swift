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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One model for the app's lifetime, so a running scan and the last result survive a close.
        let model = ScanModel(service: PipelineScanService(), settings: SettingsModel())
        statusPanel = StatusPanelController {
            PopoverView(model: model, stopService: TerminatorStopService())
        }
    }
}
