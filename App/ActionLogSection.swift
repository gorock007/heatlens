import HeatLensCore
import SwiftUI

/// "Recent actions": the session's action records, plus saved ones while Keep history is on
/// (brief 3e-1). Read-only.
struct ActionLogSection: View {
    let settings: SettingsModel
    var log: ActionLog = .shared
    static let shownLimit = 50

    @State private var expanded = false
    @State private var records: [ActionRecord] = []
    @State private var total = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 3) {
                    if records.isEmpty {
                        Text("No actions yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(records) { record in
                        Text(ActionLogLine.text(for: record))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if total > records.count {
                        Text("Showing the newest \(records.count) of \(total).")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            } label: {
                Text("Recent actions (\(total))")
                    .font(.subheadline.weight(.semibold))
            }
            Text(settings.keepHistory
                 ? "Also saved with your history for \(settings.historyRetentionDays == 1 ? "1 day" : "\(settings.historyRetentionDays) days")."
                 : "Kept until HeatLens quits.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = log.saveError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: Reload(revision: log.revision, keepHistory: settings.keepHistory, expanded: expanded)) {
            let recent = await log.recent(limit: Self.shownLimit, includingSaved: settings.keepHistory,
                                          retentionDays: settings.historyRetentionDays)
            records = recent.records
            total = recent.total
        }
    }

    private struct Reload: Equatable {
        let revision: Int
        let keepHistory: Bool
        let expanded: Bool
    }
}

/// One line per record, e.g. "14:02 · Stop requested · node (my-app) · stopped".
enum ActionLogLine {
    static func text(for record: ActionRecord, now: Date = Date()) -> String {
        [time(record.at, now: now), action(record), target(record), outcome(record)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// "14:02" today, "Oct 27, 14:02" before.
    static func time(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func action(_ record: ActionRecord) -> String {
        switch record.action {
        case .stopRequested: "Stop requested"
        case .forceQuit: "Force quit"
        case .containerStop: "Container stop"
        case .ignored: "Ignored"
        case .cancelled:
            switch record.offered {
            case .stopRequested: "Cancelled stop request"
            case .forceQuit: "Cancelled force quit"
            case .containerStop: "Cancelled container stop"
            case .ignored, .cancelled, nil: "Cancelled"
            }
        }
    }

    static func target(_ record: ActionRecord) -> String {
        switch record.target {
        case .process(_, _, let name):
            return record.projectName.map { "\(name) (\($0))" } ?? name
        case .container(_, let name, _, let composeProject):
            return (record.projectName ?? composeProject).map { "\(name) (\($0))" } ?? name
        case .project(let name):
            return "project \(name)"
        }
    }

    /// nil when the action already says it all (ignored, cancelled).
    static func outcome(_ record: ActionRecord) -> String? {
        switch record.action {
        case .ignored: return nil
        case .cancelled: return "nothing sent"
        case .stopRequested, .forceQuit, .containerStop: break
        }
        let reason = record.detail.map { ": \($0)" } ?? ""
        switch record.outcome {
        case "stopped": return record.action == .forceQuit ? "ended" : "stopped"
        case "stillRunning": return "still running"
        case "alreadyExited": return "already exited"
        case "identityChanged": return "changed since the scan, nothing sent"
        case "alreadyStopped": return "already stopped"
        case "gone": return "no longer in Docker"
        case "stillStopping": return "still stopping"
        case "denied": return "refused" + reason
        case "failed": return "failed" + reason
        default: return record.outcome + reason
        }
    }
}
