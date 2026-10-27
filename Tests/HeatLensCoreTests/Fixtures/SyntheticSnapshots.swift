import Foundation
@testable import HeatLensCore

enum SyntheticSnapshots {
    static let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
    static let interval: TimeInterval = 5
    static let home = "/Users/someone"

    static func process(
        pid: Int32,
        parentPID: Int32 = 1,
        ageHours: Double = 1,
        owner: ProcessOwner = .currentUser,
        name: String,
        executablePath: String? = nil,
        arguments: [String]? = nil,
        currentDirectory: String? = nil,
        cpu: Double? = 0,
        detailAccess: DetailAccess = .available,
        cpuWatts: Double? = nil
    ) -> ProcessSample {
        let observedAt = startedAt.addingTimeInterval(interval)
        let startMicros = Int64(observedAt.addingTimeInterval(-ageHours * 3_600).timeIntervalSince1970 * 1_000_000)
        return ProcessSample(
            identity: ProcessIdentity(pid: pid, startTimeMicros: startMicros),
            parentPID: parentPID,
            owner: owner,
            name: name,
            executablePath: executablePath,
            arguments: arguments,
            currentDirectory: currentDirectory,
            cpu: cpu.map { _ in CPUTime(userNanoseconds: 1, systemNanoseconds: 0) },
            cpuPercentOfOneCore: cpu,
            residentBytes: 64 << 20,
            footprintBytes: 96 << 20,
            threadCount: 6,
            detailAccess: detailAccess,
            cpuWatts: cpuWatts,
            cpuEnergyNanojoules: cpuWatts.map { UInt64($0 * interval * 1e9) }
        )
    }

    static func snapshot(
        _ processes: [ProcessSample],
        pressure: MemoryPressureLevel = .normal,
        swapUsedBytes: UInt64 = 0,
        swapOutsDelta: UInt64 = 0,
        thermal: ThermalState = .nominal,
        hostBusyFraction: Double = 0.25,
        notices: [String] = []
    ) -> ScanSnapshot {
        let memory = MemorySnapshot(
            totalBytes: 18 << 30,
            freeBytes: 4 << 30,
            activeBytes: 5 << 30,
            inactiveBytes: 3 << 30,
            wiredBytes: 3 << 30,
            compressedBytes: 2 << 30,
            swapUsedBytes: swapUsedBytes,
            swapTotalBytes: 10 << 30,
            swapOutsDelta: swapOutsDelta,
            pressure: pressure,
            availablePercent: 40
        )
        let system = SystemSample(
            coreCount: 11,
            hostBusyFraction: hostBusyFraction,
            perCoreBusyFraction: Array(repeating: hostBusyFraction, count: 11),
            memory: memory,
            thermalState: thermal,
            pmsetCPUSpeedLimit: nil,
            pmsetCPUSchedulerLimit: nil
        )
        return ScanSnapshot(
            id: UUID(uuidString: "11111111-2222-4333-A444-555555555555")!,
            startedAt: startedAt,
            interval: interval,
            system: system,
            processes: processes,
            notices: notices
        )
    }

    static var activeWork: ScanSnapshot {
        snapshot([
            process(
                pid: 100,
                name: "CapCut",
                executablePath: "/Applications/CapCut.app/Contents/MacOS/CapCut",
                arguments: ["/Applications/CapCut.app/Contents/MacOS/CapCut"],
                currentDirectory: home + "/Movies/Edit",
                cpu: 82
            ),
            process(
                pid: 110,
                name: "claude.exe",
                executablePath: home + "/.local/bin/claude",
                arguments: ["claude", "--model", "invented"],
                currentDirectory: home + "/Developer/Client",
                cpu: 64
            ),
        ])
    }

    static var detachedWorker: ScanSnapshot {
        snapshot([
            process(
                pid: 200,
                ageHours: 48,
                name: "node",
                executablePath: "/usr/local/bin/node",
                arguments: ["node", home + "/Developer/Orchard/scripts/worker.js"],
                currentDirectory: home + "/Developer/Orchard",
                cpu: 0.1
            ),
        ])
    }

    static var oldNextServer: ScanSnapshot {
        snapshot([
            process(
                pid: 300,
                ageHours: 38,
                name: "npm",
                executablePath: "/usr/local/bin/npm",
                arguments: ["npm", "run", "dev"],
                currentDirectory: home + "/Developer/Portfolio",
                cpu: 0.1
            ),
            process(
                pid: 301,
                parentPID: 300,
                ageHours: 38,
                name: "node",
                executablePath: "/usr/local/bin/node",
                arguments: ["node", home + "/Developer/Portfolio/node_modules/.bin/next", "dev"],
                currentDirectory: home + "/Developer/Portfolio",
                cpu: 0.2
            ),
        ])
    }

    static var hotVitestAndIdleWorker: ScanSnapshot {
        snapshot([
            process(
                pid: 400,
                name: "node",
                executablePath: "/usr/local/bin/node",
                arguments: ["node", home + "/Developer/Tests/node_modules/.bin/vitest", "run"],
                currentDirectory: home + "/Developer/Tests",
                cpu: 96
            ),
            process(
                pid: 401,
                ageHours: 48,
                name: "node",
                executablePath: "/usr/local/bin/node",
                arguments: ["node", home + "/Developer/Old/scripts/worker.js"],
                currentDirectory: home + "/Developer/Old",
                cpu: 0.1
            ),
        ])
    }

    static var restricted: ScanSnapshot {
        snapshot([
            process(
                pid: 500,
                owner: .unknown,
                name: "mystery",
                arguments: nil,
                currentDirectory: nil,
                cpu: nil,
                detailAccess: .permissionDenied
            ),
        ])
    }

    static var multiCore: ScanSnapshot {
        snapshot([
            process(
                pid: 600,
                name: "node",
                executablePath: "/usr/local/bin/node",
                arguments: ["node", home + "/Developer/Build/build.js"],
                currentDirectory: home + "/Developer/Build",
                cpu: 180
            ),
        ], hostBusyFraction: 0.5)
    }

    static var appBundleFamily: ScanSnapshot {
        snapshot([
            process(
                pid: 830,
                name: "Google Chrome",
                executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                arguments: ["Google Chrome"],
                currentDirectory: home + "/Library/Application Support/Google/Chrome"
            ),
            process(
                pid: 831,
                name: "Google Chrome Helper",
                executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                arguments: ["Google Chrome Helper"]
            ),
            process(
                pid: 832,
                name: "Google Chrome Helper (Renderer)",
                executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                arguments: ["Google Chrome Helper", "--type=renderer"]
            ),
        ])
    }

    static var systemServiceFamily: ScanSnapshot {
        snapshot([
            process(pid: 840, owner: .root, name: "trustd", executablePath: "/usr/libexec/trustd", cpu: 1),
            process(pid: 841, owner: .otherUser, name: "securityd", executablePath: "/usr/sbin/securityd", cpu: 2),
            process(pid: 842, owner: .root, name: "diagnosticd", executablePath: "/System/Library/CoreServices/diagnosticd", cpu: 3),
            process(pid: 843, owner: .root, name: "kernel_task", executablePath: "/System/Library/Kernels/kernel", cpu: 1),
            process(pid: 844, owner: .currentUser, name: "WindowServer", executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", cpu: 2),
            process(pid: 845, owner: .root, name: "hot-service", executablePath: "/usr/libexec/hot-service", cpu: 12),
            process(pid: 846, owner: .currentUser, name: "ControlCenter", executablePath: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", cpu: 1),
        ])
    }
}
