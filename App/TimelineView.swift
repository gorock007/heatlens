import Charts
import SwiftUI
import HeatLensCore

/// Live mode's timeline (PRD-v2 Phase 2): CPU load over time with events marked, the busiest
/// moment and the projects and events behind it. "Session" is in memory; "1 hour" and "24 hours"
/// read the saved history when "Keep history" is on.
struct TimelineCard: View {
    enum Range: String, CaseIterable, Identifiable {
        case session = "Session", hour = "1 hour", day = "24 hours"
        var id: String { rawValue }
        var seconds: TimeInterval? {
            switch self {
            case .session: nil
            case .hour: 3_600
            case .day: 86_400
            }
        }
    }

    /// Events listed before "Show all": enough that a burst's container starts stay in view.
    static let recentEventCount = 12

    let tick: LiveTick
    let keepHistory: Bool
    @State private var range: Range = .session
    @State private var saved: HistoryWindow = .empty
    @State private var loadedAt: Int = -1

    private var window: HistoryWindow { range == .session ? tick.timeline : saved }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Timeline")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .fixedSize()
                .disabled(!keepHistory)
                .help(keepHistory ? "Show saved history" : "Turn on Keep history in Settings to look further back")
            }
            if window.points.count < 2 {
                Text(range == .session ? "The chart fills in as updates arrive." : "No saved history in this range yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                chart
                    .frame(height: 70)
            }
            if let peak = TimelineAnalysis.peak(in: window), window.points.count >= 2 {
                PeakSummary(peak: peak)
            }
            EventList(events: Array(window.events.suffix(Self.recentEventCount).reversed()))
            if window.events.count > Self.recentEventCount {
                DisclosureGroup("Show all \(window.events.count) events") {
                    EventList(events: Array(window.events.dropLast(Self.recentEventCount).reversed()))
                }
                .font(.caption)
            }
        }
        .task(id: "\(range.rawValue)-\(tick.sequence / 6)") { await load() }
    }

    private var chart: some View {
        Chart {
            ForEach(window.points, id: \.timestamp) { point in
                LineMark(x: .value("Time", point.timestamp), y: .value("CPU", point.hostBusyFraction * 100))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.blue)
            }
            ForEach(window.events) { event in
                RuleMark(x: .value("Event", event.timestamp))
                    .foregroundStyle(event.isInference ? .orange.opacity(0.7) : .secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: event.isInference ? [3, 2] : []))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.caption2) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
    }

    private func load() async {
        guard let seconds = range.seconds, keepHistory, let store = HistoryService.shared.store else {
            saved = .empty
            return
        }
        saved = (try? await store.window(since: Date().addingTimeInterval(-seconds))) ?? .empty
    }
}

private struct PeakSummary: View {
    let peak: TimelineAnalysis.Peak

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "Busiest moment \(peak.point.timestamp.formatted(date: .omitted, time: .standard)) · "
                 + "\(Int((peak.point.hostBusyPeak * 100).rounded()))% of all cores")
                .font(.caption.weight(.semibold))
            if !peak.projects.isEmpty {
                Text(verbatim: peak.projects.prefix(3).map { "\($0.name) \(ProjectFormat.cpu($0.cpuPeakPercent) ?? "")" }.joined(separator: " · "))
                    .font(.caption)
            }
            if !peak.events.isEmpty {
                Text(verbatim: "Just before: " + peak.events.suffix(3).map(\.title).joined(separator: "; "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct EventList: View {
    let events: [TimelineEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(events) { event in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(verbatim: event.title + (event.projectName.map { " · \($0)" } ?? ""))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if event.isInference {
                        Text("inference")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
