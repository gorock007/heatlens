import Foundation
import HeatLensCore

/// The real scan: `ScanPipeline` (coordinator → provenance → rules) plus redacted exports.
/// One pipeline per app, so its coordinator's one-scan-at-a-time guard covers every caller.
struct PipelineScanService: ScanService {
    let pipeline: ScanPipeline
    let projectLocator: ProjectRootLocator

    init(pipeline: ScanPipeline = ScanPipeline(), projectLocator: ProjectRootLocator = .shared) {
        self.pipeline = pipeline
        self.projectLocator = projectLocator
    }

    func run(duration: TimeInterval, options: CollectionOptions,
             progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> ScanReport {
        let docker = options.docker ? options.dockerSampler : nil
        let dockerBefore = docker?.reading()
        let result = try await pipeline.run(duration: duration, userRules: options.userRules, progress: progress)
        let hardware = options.hardwareProvider.sample()
        let dockerSnapshot = docker.map { DockerAssembly.snapshot(before: dockerBefore, after: $0.reading()) }
        let projects = ProjectAttributor.breakdown(snapshot: result.snapshot, groups: result.groups, docker: dockerSnapshot,
                                                   mappings: options.projectMappings, locator: projectLocator)
        return ScanReport(result, hardware: hardware, docker: dockerSnapshot, projects: projects)
    }
}
