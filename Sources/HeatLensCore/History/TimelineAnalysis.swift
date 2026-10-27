import Foundation

/// From a CPU spike to the work behind it (PRD-v2 Phase 2 exit): the busiest point in a window,
/// the projects busiest at that moment, and the events just before it.
public enum TimelineAnalysis {
    public struct Peak: Hashable, Sendable {
        public let point: HistoryPoint
        /// Busiest first, from the project points closest to the peak (within one minute).
        public let projects: [HistoryProjectPoint]
        /// Events from two minutes before to 30 seconds after the peak, oldest first.
        public let events: [TimelineEvent]
    }

    public static let lookBack: TimeInterval = 120
    public static let lookAhead: TimeInterval = 30

    /// nil for an empty window. Uses each point's peak load, so a rolled-up minute counts by its busiest tick.
    public static func peak(in window: HistoryWindow) -> Peak? {
        guard let top = window.points.max(by: { ($0.hostBusyPeak, $1.timestamp) < ($1.hostBusyPeak, $0.timestamp) }) else { return nil }
        let nearest = window.projects
            .filter { abs($0.timestamp.timeIntervalSince(top.timestamp)) <= 60 }
            .min { abs($0.timestamp.timeIntervalSince(top.timestamp)) < abs($1.timestamp.timeIntervalSince(top.timestamp)) }?
            .timestamp
        let projects = nearest.map { at in
            window.projects.filter { $0.timestamp == at }.sorted { $0.cpuPeakPercent > $1.cpuPeakPercent }
        } ?? []
        let events = window.events.filter {
            let delta = $0.timestamp.timeIntervalSince(top.timestamp)
            return delta >= -lookBack && delta <= lookAhead
        }
        return Peak(point: top, projects: projects, events: events)
    }
}
