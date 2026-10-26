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
        detailAccess: DetailAccess = .available
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
            detailAccess: detailAccess
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
}
