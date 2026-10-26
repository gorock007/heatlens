import SwiftUI

@main
struct HeatLensApp: App {
    @State private var model = ScanModel(service: FixtureScanService())

    var body: some Scene {
        MenuBarExtra("HeatLens", systemImage: "thermometer.medium") {
            PopoverView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
