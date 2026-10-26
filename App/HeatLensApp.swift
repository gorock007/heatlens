import SwiftUI

@main
struct HeatLensApp: App {
    var body: some Scene {
        MenuBarExtra("HeatLens", systemImage: "thermometer.medium") {
            PopoverView()
        }
        .menuBarExtraStyle(.window)
    }
}
