import SwiftUI

@main
struct HeatLensApp: App {
    @State private var model: ScanModel

    init() {
        let settings = SettingsModel()
        _model = State(initialValue: ScanModel(service: PipelineScanService(), settings: settings))
    }

    var body: some Scene {
        MenuBarExtra("HeatLens", systemImage: "thermometer.medium") {
            PopoverView(model: model, stopService: TerminatorStopService())
        }
        .menuBarExtraStyle(.window)
    }
}
