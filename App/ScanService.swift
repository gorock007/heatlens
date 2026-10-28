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
    /// Read at the end of the scan; private readings are `.disabled` when the switch is off.
    let hardware: HardwareSample?
    /// Two Docker readings bracketing the scan; nil when Docker is off in Settings.
    let docker: DockerSnapshot?
    /// CPU and memory per project (PRD-v2 Phase 2).
    let projects: ProjectBreakdown

    init(snapshot: ScanSnapshot, groups: [ProcessGroup], findings: [DiagnosticFinding],
         reportText: String, reportJSON: String, hardware: HardwareSample? = nil, docker: DockerSnapshot? = nil,
         projects: ProjectBreakdown = .empty) {
        self.snapshot = snapshot
        self.groups = groups
        self.findings = findings
        self.reportText = reportText
        self.reportJSON = reportJSON
        self.hardware = hardware
        self.docker = docker
        self.projects = projects
    }

    /// Builds both redacted exports with `Redactor`, the same text `heatlens-probe --report` prints.
    /// Hardware and Docker stay out of the exports in Phase 1 (docs/v2/ADR-0002).
    init(_ result: ScanResult, hardware: HardwareSample? = nil, docker: DockerSnapshot? = nil, projects: ProjectBreakdown = .empty) {
        let json = (try? Redactor.jsonReport(result.snapshot, groups: result.groups, findings: result.findings,
                                         projects: projects))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.init(snapshot: result.snapshot, groups: result.groups, findings: result.findings,
                  reportText: Redactor.textReport(result.snapshot, groups: result.groups, findings: result.findings,
                                                  projects: projects),
                  reportJSON: json, hardware: hardware, docker: docker, projects: projects)
    }
}

/// Runs one bounded scan. The app uses `PipelineScanService`; `FixtureScanService` is for
/// SwiftUI previews only. The popover only knows this protocol.
protocol ScanService: Sendable {
    /// Samples for `duration` seconds, calling `progress` with elapsed seconds as it goes.
    /// Throws `CancellationError` when the calling task is cancelled.
    func run(duration: TimeInterval, options: CollectionOptions,
             progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> ScanReport
}
