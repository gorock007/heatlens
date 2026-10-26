// swift-tools-version: 6.0
import PackageDescription

// HeatLens engine package. The menu-bar app (App/, xcodegen) links HeatLensCore in Phase 1.
// Deployment target rationale: docs/FEASIBILITY.md § "Deployment target".
let package = Package(
    name: "HeatLens",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HeatLensCore", targets: ["HeatLensCore"]),
        .executable(name: "heatlens-probe", targets: ["heatlens-probe"]),
    ],
    targets: [
        .target(name: "HeatLensCore"),
        .executableTarget(name: "heatlens-probe", dependencies: ["HeatLensCore"]),
        .testTarget(name: "HeatLensCoreTests", dependencies: ["HeatLensCore"]),
    ]
)
