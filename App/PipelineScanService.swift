import Foundation
import HeatLensCore

/// The real scan: `ScanPipeline` (coordinator → provenance → rules) plus redacted exports.
/// One pipeline per app, so its coordinator's one-scan-at-a-time guard covers every caller.
struct PipelineScanService: ScanService {
    let pipeline: ScanPipeline

    init(pipeline: ScanPipeline = ScanPipeline()) {
        self.pipeline = pipeline
    }

    func run(duration: TimeInterval, progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> ScanReport {
        ScanReport(try await pipeline.run(duration: duration, progress: progress))
    }
}
