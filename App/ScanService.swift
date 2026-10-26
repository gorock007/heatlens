import Foundation
import HeatLensCore

/// Everything the popover shows for one finished scan.
struct ScanReport: Sendable {
    let snapshot: ScanSnapshot
    let groups: [ProcessGroup]
    /// Ranked: the array order is the display order.
    let findings: [DiagnosticFinding]
    /// Plain-text export, already redacted by the service.
    let reportText: String
}

/// Runs one bounded scan. The Phase 1 wiring brief swaps `FixtureScanService` for the real
/// coordinator; the popover only knows this protocol.
protocol ScanService: Sendable {
    /// Samples for `duration` seconds, calling `progress` with elapsed seconds as it goes.
    /// Throws `CancellationError` when the calling task is cancelled.
    func run(duration: TimeInterval, progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> ScanReport
}
