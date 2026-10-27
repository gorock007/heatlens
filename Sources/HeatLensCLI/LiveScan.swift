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

public enum LiveScan {
    /// One `ScanPipeline` scan, rendered by `Redactor`.
    public static func run(seconds: Int, progress: @escaping @Sendable (TimeInterval) -> Void = { _ in }) async throws -> ScanReports {
        let result = try await ScanPipeline().run(duration: TimeInterval(seconds), progress: progress)
        let text = Redactor.textReport(result.snapshot, groups: result.groups, findings: result.findings)
        let data = try Redactor.jsonReport(result.snapshot, groups: result.groups, findings: result.findings)
        return ScanReports(text: text, json: String(decoding: data, as: UTF8.self))
    }

    /// One `ScanPipeline.ports()` read (no sampling interval), rendered by `Redactor`.
    public static func ports() async throws -> ScanReports {
        let ports = try await ScanPipeline().ports()
        let text = Redactor.portsTextReport(ports.snapshot, groups: ports.groups)
        let data = try Redactor.portsJSONReport(ports.snapshot, groups: ports.groups)
        return ScanReports(text: text, json: String(decoding: data, as: UTF8.self))
    }
}
