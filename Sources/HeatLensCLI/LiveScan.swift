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

public enum LiveScan {
    /// One `ScanPipeline` scan, rendered by `Redactor`.
    public static func run(seconds: Int, progress: @escaping @Sendable (TimeInterval) -> Void = { _ in }) async throws -> ScanReports {
        let result = try await ScanPipeline().run(duration: TimeInterval(seconds), progress: progress)
        let text = Redactor.textReport(result.snapshot, groups: result.groups, findings: result.findings)
        let data = try Redactor.jsonReport(result.snapshot, groups: result.groups, findings: result.findings)
        return ScanReports(text: text, json: String(decoding: data, as: UTF8.self))
    }
}
