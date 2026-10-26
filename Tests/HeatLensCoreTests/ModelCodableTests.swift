import Foundation
import Testing
@testable import HeatLensCore

@Suite("Model types")
struct ModelCodableTests {
    let identity = ProcessIdentity(pid: 12874, startTimeMicros: 1_792_800_000_000_000)

    var snapshot: ScanSnapshot {
        let memory = MemorySnapshot(totalBytes: 18 << 30, freeBytes: 200 << 20, activeBytes: 3 << 30, inactiveBytes: 3 << 30,
                                    wiredBytes: 5 << 30, compressedBytes: 6 << 30, swapUsedBytes: 8 << 30, swapTotalBytes: 10 << 30,
                                    swapOutsDelta: 0, pressure: MemoryPressureLevel(sysctlLevel: 2), availablePercent: 32)
        let system = SystemSample(coreCount: 11, hostBusyFraction: 0.3, perCoreBusyFraction: Array(repeating: 0.3, count: 11),
                                  memory: memory, thermalState: .nominal, pmsetCPUSpeedLimit: nil, pmsetCPUSchedulerLimit: nil)
        let process = ProcessSample(identity: identity, parentPID: 1, owner: .currentUser, name: "node",
                                    executablePath: "~/.nvm/versions/node/v24/bin/node",
                                    arguments: ["node", "~/projects/project-a/scripts/worker.js"], currentDirectory: "~/projects/project-a",
                                    cpu: CPUTime(userNanoseconds: 1_000_000, systemNanoseconds: 0), cpuPercentOfOneCore: 0.02,
                                    residentBytes: 50 << 20, footprintBytes: 80 << 20, threadCount: 7, detailAccess: .available)
        let denied = ProcessSample(identity: ProcessIdentity(pid: 606, startTimeMicros: 1), parentPID: 1, owner: .root, name: "WindowServer",
                                   executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                                   arguments: nil, currentDirectory: nil, cpu: nil, cpuPercentOfOneCore: nil, residentBytes: nil,
                                   footprintBytes: nil, threadCount: nil, detailAccess: .permissionDenied)
        return ScanSnapshot(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, startedAt: Date(timeIntervalSince1970: 1_792_995_000), interval: 5, system: system,
                            processes: [process, denied], notices: ["CPU for root-owned processes is not accessible"])
    }

    @Test("ScanSnapshot survives a JSON round-trip (export, FR-11)")
    func snapshotRoundTrip() throws {
        let data = try JSONEncoder().encode(snapshot)
        let back = try JSONDecoder().decode(ScanSnapshot.self, from: data)
        #expect(back == snapshot)
        #expect(back.processes[0].isAdoptedByLaunchd)
        #expect(back.processes[1].detailAccess == .permissionDenied)
        #expect(back.system.busyCores == 3.3)
        #expect(back.system.memory.pressure == .warning)
    }

    @Test("DiagnosticFinding with actions round-trips and severities order")
    func findingRoundTrip() throws {
        let finding = DiagnosticFinding(title: "Possible leftover development worker", severity: .review, confidence: .medium,
                                        explanation: "long-lived project worker adopted by launchd",
                                        evidence: [Evidence(label: "PPID", value: "1", source: "proc_pidinfo")],
                                        limitations: ["this does not prove it is unused"],
                                        affectedProcesses: [identity],
                                        recommendedActions: [.inspect(identity), .openProject(path: "~/projects/project-a"), .requestStop(identity)])
        let back = try JSONDecoder().decode(DiagnosticFinding.self, from: JSONEncoder().encode(finding))
        #expect(back == finding)
        let ordered: [Severity] = [.info, .review, .medium, .high]
        #expect(ordered == ordered.sorted())
        #expect(Severity.info < Severity.high)
        #expect(MemoryPressureLevel(sysctlLevel: 9) == .unknown)
    }
}
