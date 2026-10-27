import Foundation

public enum ScanError: Error, Equatable {
    case alreadyRunning
    /// The duration was NaN, infinite, or not positive. Finite positive values are clamped instead.
    case invalidDuration
}

/// Runs one bounded, cancellable scan at a time and returns a `ScanSnapshot`. Does no work
/// outside `scan()`: no timers, no background sampling.
///
/// A scan reads host counters, every process (libproc), and, when libproc refused some
/// processes, one `ps` run; waits out the interval reporting progress about once a second;
/// then repeats those reads plus memory/thermal state, and lists the TCP ports the processes
/// listen on and the power assertions they hold (once each, at the end). `ScanAssembly` turns the two ends into per-process deltas.
public actor ScanCoordinator {
    public static let durationRange: ClosedRange<TimeInterval> = 1...15

    private let processSampler: any ProcessSampling
    private let systemSampler: any SystemSampling
    private let fallbackSampler: PSTimeSampler
    private let portSampler: any PortSampling
    private let assertionSampler: any PowerAssertionSampling
    private var isScanning = false

    public init(processSampler: some ProcessSampling = LibprocProcessSampler(),
                systemSampler: some SystemSampling = HostSystemSampler(),
                portSampler: some PortSampling = LibprocPortSampler(),
                assertionSampler: some PowerAssertionSampling = IOKitPowerAssertionSampler()) {
        self.init(processSampler: processSampler, systemSampler: systemSampler, fallbackSampler: PSTimeSampler(),
                  portSampler: portSampler, assertionSampler: assertionSampler)
    }

    /// Tests inject a `PSTimeSampler` that runs a slow executable or reports its child PIDs.
    init(processSampler: any ProcessSampling, systemSampler: any SystemSampling, fallbackSampler: PSTimeSampler,
         portSampler: any PortSampling = LibprocPortSampler(),
         assertionSampler: any PowerAssertionSampling = IOKitPowerAssertionSampler()) {
        self.processSampler = processSampler
        self.systemSampler = systemSampler
        self.fallbackSampler = fallbackSampler
        self.portSampler = portSampler
        self.assertionSampler = assertionSampler
    }

    /// duration clamped to 1...15 s (PRD offers 5/10/15). progress is called about once a second with elapsed seconds.
    /// Throws CancellationError if the calling Task is cancelled (returns within ~1 s), ScanError.alreadyRunning if a scan is in flight.
    public func scan(duration: TimeInterval, progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> ScanSnapshot {
        let duration = try Self.clampedDuration(duration)
        guard !isScanning else { throw ScanError.alreadyRunning }
        isScanning = true
        defer { isScanning = false }
        try Task.checkCancellation()

        let clock = ContinuousClock()
        let begin = clock.now
        let startedAt = Date()
        let hostBefore = systemSampler.counters()
        let before = try processSampler.snapshot()
        var psBefore: PSTimeSampler.Reading?, psAfter: PSTimeSampler.Reading?, psFailure: String?
        if before.processes.contains(where: { $0.detailAccess == .permissionDenied }) {
            (psBefore, psFailure) = try await readFallback()
        }

        while true {
            let elapsed = Self.seconds(begin.duration(to: clock.now))
            guard elapsed < duration else { break }
            try await Task.sleep(for: .seconds(min(1, duration - elapsed)))
            progress(min(Self.seconds(begin.duration(to: clock.now)), duration))
        }

        let hostAfter = systemSampler.counters()
        let after = try processSampler.snapshot()
        if psBefore != nil {
            (psAfter, psFailure) = try await readFallback()
        }
        let state = try await systemSampler.state()
        try Task.checkCancellation()
        let ports = portSampler.listeningPorts(of: after.processes)
        let assertions = assertionSampler.powerAssertions(of: after.processes)

        return ScanAssembly.snapshot(startedAt: startedAt, before: before, after: after,
                                     psBefore: psBefore, psAfter: psAfter, psFailure: psFailure,
                                     hostBefore: hostBefore, hostAfter: hostAfter, state: state, ports: ports,
                                     assertions: assertions)
    }

    /// The TCP ports processes listen on right now, from one process reading: no interval, no
    /// CPU or host sampling, no `ps`. Takes milliseconds, and may run while a scan waits.
    public func ports() throws -> ScanSnapshot {
        try Task.checkCancellation()
        let reading = try processSampler.snapshot()
        return ScanAssembly.portsSnapshot(reading: reading, ports: portSampler.listeningPorts(of: reading.processes))
    }

    /// The sleep-blocking power assertions processes hold right now, from one process reading:
    /// no interval, no CPU or host sampling, no `ps`. Takes milliseconds, and may run while a scan waits.
    public func awake() throws -> ScanSnapshot {
        try Task.checkCancellation()
        let reading = try processSampler.snapshot()
        return ScanAssembly.awakeSnapshot(reading: reading,
                                          assertions: assertionSampler.powerAssertions(of: reading.processes))
    }

    static func clampedDuration(_ duration: TimeInterval) throws -> TimeInterval {
        guard duration.isFinite, duration > 0 else { throw ScanError.invalidDuration }
        return min(max(duration, durationRange.lowerBound), durationRange.upperBound)
    }

    /// A `ps` failure becomes a notice (the second value); cancellation propagates.
    private func readFallback() async throws -> (PSTimeSampler.Reading?, String?) {
        do {
            return (try await fallbackSampler.snapshot(), nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (nil, "\(error)")
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (s, attoseconds) = duration.components
        return TimeInterval(s) + TimeInterval(attoseconds) / 1e18
    }
}
