// swift-tools-version: 6.0
import PackageDescription

// HeatLens engine package. The menu-bar app (App/, xcodegen) links HeatLensCore in Phase 1.
// Deployment target rationale: docs/FEASIBILITY.md § "Deployment target".
let package = Package(
    name: "HeatLens",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HeatLensCore", targets: ["HeatLensCore"]),
        .library(name: "HeatLensCLI", targets: ["HeatLensCLI"]),
        .executable(name: "heatlens-probe", targets: ["heatlens-probe"]),
        .executable(name: "heatlens", targets: ["heatlens"]),
    ],
    targets: [
        .target(name: "HeatLensCore"),
        .executableTarget(name: "heatlens-probe", dependencies: ["HeatLensCore"]),
        .testTarget(name: "HeatLensCoreTests", dependencies: ["HeatLensCore"]),
        .target(name: "HeatLensCLI", dependencies: ["HeatLensCore"]),
        .executableTarget(name: "heatlens", dependencies: ["HeatLensCLI"]),
        .testTarget(name: "HeatLensCLITests", dependencies: ["HeatLensCLI"]),
    ]
)
