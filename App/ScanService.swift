import Foundation
import HeatLensCore

/// Everything the popover shows for one finished scan.
struct ScanReport: Sendable {
    let snapshot: ScanSnapshot
    let groups: [ProcessGroup]
    /// Ranked: the array order is the display order.
    let findings: [DiagnosticFinding]
    /// Concise plain-text export (FR-11), already redacted by the service.
    let reportText: String
    /// Full JSON export with every process, already redacted by the service.
    let reportJSON: String

    init(snapshot: ScanSnapshot, groups: [ProcessGroup], findings: [DiagnosticFinding],
         reportText: String, reportJSON: String) {
        self.snapshot = snapshot
        self.groups = groups
        self.findings = findings
        self.reportText = reportText
        self.reportJSON = reportJSON
    }

    /// Builds both redacted exports with `Redactor`, the same text `heatlens-probe --report` prints.
    init(_ result: ScanResult) {
        let json = (try? Redactor.jsonReport(result.snapshot, groups: result.groups, findings: result.findings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.init(snapshot: result.snapshot, groups: result.groups, findings: result.findings,
                  reportText: Redactor.textReport(result.snapshot, groups: result.groups, findings: result.findings),
                  reportJSON: json)
    }
}

/// Runs one bounded scan. The app uses `PipelineScanService`; `FixtureScanService` is for
/// SwiftUI previews only. The popover only knows this protocol.
protocol ScanService: Sendable {
    /// Samples for `duration` seconds, calling `progress` with elapsed seconds as it goes.
    /// Throws `CancellationError` when the calling task is cancelled.
    func run(duration: TimeInterval, progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> ScanReport
}
