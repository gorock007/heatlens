import Foundation

/// One scan against the one before it, for "Since last scan". In memory only: HeatLens keeps no
/// scan history (FR-10), so the app compares just the previous results it still holds.
public struct ScanComparison: Hashable, Sendable {
    public struct Change<Value: Hashable & Sendable>: Hashable, Sendable {
        public let before: Value
        public let after: Value

        public init(before: Value, after: Value) {
            self.before = before
            self.after = after
        }
    }

    /// A group of the previous scan whose root (PID and start time) is absent from this one.
    public struct GoneGroup: Hashable, Sendable {
        public let root: ProcessIdentity
        public let label: String
        /// The project directory's last component, e.g. "my-app".
        public let projectName: String?
        /// The sum of its members' CPU in the previous scan; nil when none was measured.
        public let cpuPercentOfOneCore: Double?

        public init(root: ProcessIdentity, label: String, projectName: String?, cpuPercentOfOneCore: Double?) {
            self.root = root
            self.label = label
            self.projectName = projectName
            self.cpuPercentOfOneCore = cpuPercentOfOneCore
        }
    }

    /// Below these a change reads as "about the same". Memory pressure and thermal state count
    /// any change of level.
    public static let busyCoresFloor = 0.2
    public static let swapBytesFloor: UInt64 = 100 << 20
    /// A gone group with no finding in the previous scan is listed only from this much CPU, so
    /// background processes that come and go between scans don't fill the line.
    public static let goneCPUFloorPercent = busyCoresFloor * 100
    public static let goneLimit = 5

    /// From the previous scan's start to this one's.
    public let elapsed: TimeInterval
    public let busyCores: Change<Double>
    public let memoryPressure: Change<MemoryPressureLevel>
    public let swapUsedBytes: Change<UInt64>
    public let thermalState: Change<ThermalState>
    /// Highest CPU first, at most `goneLimit`.
    public let gone: [GoneGroup]
    /// Gone groups beyond `gone`.
    public let moreGoneCount: Int

    public init(elapsed: TimeInterval, busyCores: Change<Double>, memoryPressure: Change<MemoryPressureLevel>,
                swapUsedBytes: Change<UInt64>, thermalState: Change<ThermalState>, gone: [GoneGroup], moreGoneCount: Int) {
        self.elapsed = elapsed
        self.busyCores = busyCores
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.thermalState = thermalState
        self.gone = gone
        self.moreGoneCount = moreGoneCount
    }

    public var busyCoresChanged: Bool { abs(busyCores.after - busyCores.before) >= Self.busyCoresFloor }
    public var memoryPressureChanged: Bool { memoryPressure.before != memoryPressure.after }
    public var swapChanged: Bool {
        let (low, high) = (min(swapUsedBytes.before, swapUsedBytes.after), max(swapUsedBytes.before, swapUsedBytes.after))
        return high - low >= Self.swapBytesFloor
    }
    public var thermalChanged: Bool { thermalState.before != thermalState.after }

    public var isAboutTheSame: Bool {
        !busyCoresChanged && !memoryPressureChanged && !swapChanged && !thermalChanged && gone.isEmpty
    }

    /// `exclusions` keeps hidden processes out of "gone", as it keeps them out of the findings.
    public static func compare(before: ScanResult, after: ScanResult,
                               exclusions: ExclusionFilter = ExclusionFilter()) -> ScanComparison {
        let old = before.snapshot.system
        let new = after.snapshot.system
        let gone = goneGroups(before: before, after: after, exclusions: exclusions)
        return ScanComparison(
            elapsed: after.snapshot.startedAt.timeIntervalSince(before.snapshot.startedAt),
            busyCores: Change(before: old.busyCores, after: new.busyCores),
            memoryPressure: Change(before: old.memory.pressure, after: new.memory.pressure),
            swapUsedBytes: Change(before: old.memory.swapUsedBytes, after: new.memory.swapUsedBytes),
            thermalState: Change(before: old.thermalState, after: new.thermalState),
            gone: Array(gone.prefix(goneLimit)),
            moreGoneCount: max(0, gone.count - goneLimit))
    }

    /// Groups whose root identity is absent from `after` and that either had a member named in a
    /// visible finding of `before`, or used at least `goneCPUFloorPercent`.
    private static func goneGroups(before: ScanResult, after: ScanResult, exclusions: ExclusionFilter) -> [GoneGroup] {
        let present = Set(after.snapshot.processes.map(\.identity))
        let samples = Dictionary(before.snapshot.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let named = Set(exclusions.visibleFindings(before.findings, snapshot: before.snapshot, groups: before.groups)
            .flatMap(\.affectedProcesses))

        let gone = before.groups.compactMap { group -> GoneGroup? in
            guard !present.contains(group.root),
                  !exclusions.excludes(processName: samples[group.root]?.name, projectDirectory: group.project?.directory)
            else { return nil }
            let cpuValues = group.members.compactMap { samples[$0]?.cpuPercentOfOneCore }
            let cpu = cpuValues.isEmpty ? nil : cpuValues.reduce(0, +)
            guard group.members.contains(where: named.contains) || (cpu ?? 0) >= goneCPUFloorPercent else { return nil }
            return GoneGroup(root: group.root, label: group.label,
                             projectName: group.project.map { ($0.directory as NSString).lastPathComponent },
                             cpuPercentOfOneCore: cpu)
        }
        return gone.sorted {
            let (left, right) = ($0.cpuPercentOfOneCore ?? 0, $1.cpuPercentOfOneCore ?? 0)
            if left != right { return left > right }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }
}
