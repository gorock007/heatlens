import Foundation
import HeatLensCore

/// Both redacted reports from one scan.
public struct ScanReports: Equatable, Sendable {
    public let text: String
    public let json: String

    public init(text: String, json: String) {
        self.text = text
        self.json = json
    }
}

/// Runs one scan of `seconds` and returns its reports. Injected so tests never run a real scan.
public typealias ScanRunner = @Sendable (_ seconds: Int) async throws -> ScanReports

/// Reads the listening ports once and returns both redacted reports (text, JSON). Injected like `ScanRunner`.
public typealias PortsRunner = @Sendable () async throws -> ScanReports

/// Reads the power assertions once and returns both redacted reports (text, JSON). Injected like `ScanRunner`.
public typealias AwakeRunner = @Sendable () async throws -> ScanReports

public enum LiveScan {
    /// One `ScanPipeline` scan, rendered by `Redactor`.
    public static func run(seconds: Int, progress: @escaping @Sendable (TimeInterval) -> Void = { _ in }) async throws -> ScanReports {
        let result = try await ScanPipeline().run(duration: TimeInterval(seconds), progress: progress)
        return try reports(result)
    }

    /// Both reports for one scan, with its projects. The CLI reads neither Docker nor the app's
    /// "Project folders" mappings, so projects come from Git roots and project files only.
    static func reports(_ result: ScanResult, locator: ProjectRootLocator = ProjectRootLocator(),
                        homeDirectory: String = NSHomeDirectory()) throws -> ScanReports {
        let projects = ProjectAttributor.breakdown(snapshot: result.snapshot, groups: result.groups, docker: nil,
                                                   mappings: [], locator: locator, home: homeDirectory)
        let text = Redactor.textReport(result.snapshot, groups: result.groups, findings: result.findings,
                                       projects: projects, homeDirectory: homeDirectory)
        let data = try Redactor.jsonReport(result.snapshot, groups: result.groups, findings: result.findings,
                                           projects: projects, homeDirectory: homeDirectory)
        return ScanReports(text: text, json: String(decoding: data, as: UTF8.self))
    }

    /// One `ScanPipeline.ports()` read (no sampling interval), rendered by `Redactor`.
    public static func ports() async throws -> ScanReports {
        let ports = try await ScanPipeline().ports()
        let text = Redactor.portsTextReport(ports.snapshot, groups: ports.groups)
        let data = try Redactor.portsJSONReport(ports.snapshot, groups: ports.groups)
        return ScanReports(text: text, json: String(decoding: data, as: UTF8.self))
    }

    /// One `ScanPipeline.awake()` read (no sampling interval), rendered by `Redactor`.
    public static func awake() async throws -> ScanReports {
        let awake = try await ScanPipeline().awake()
        let text = Redactor.awakeTextReport(awake.snapshot, groups: awake.groups)
        let data = try Redactor.awakeJSONReport(awake.snapshot, groups: awake.groups)
        return ScanReports(text: text, json: String(decoding: data, as: UTF8.self))
    }
}
