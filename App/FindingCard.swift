import SwiftUI
import HeatLensCore

/// One finding (PRD §3 "Result card example"): what was seen, why, how sure, what it can't
/// prove, and the safe actions.
struct FindingCard: View {
    let finding: DiagnosticFinding
    let context: ReportContext
    let stopService: any ProcessStopping
    let onInspect: (ProcessIdentity) -> Void
    let onRequestStop: (StopTarget) -> Void

    @State private var showEvidence = false
    @State private var copiedCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(finding.title)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Chip(text: Format.severity(finding.severity), tint: tint)
                Chip(text: Format.confidence(finding.confidence), tint: .secondary)
            }

            Text(finding.explanation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if !finding.evidence.isEmpty {
                DisclosureGroup("Evidence", isExpanded: $showEvidence) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(finding.evidence, id: \.self) { item in
                            Text("\(item.label): \(item.value)")
                                .font(.caption)
                                + Text("  \(item.source)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
                .font(.caption)
            }

            ForEach(finding.limitations, id: \.self) { limitation in
                Text(limitation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FlowLayout(spacing: 6) {
                ForEach(Array(visibleActions.enumerated()), id: \.offset) { _, action in
                    actionButton(action)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var tint: Color {
        switch finding.severity {
        case .high: .red
        case .medium: .orange
        case .review: .yellow
        case .info: .secondary
        }
    }

    private var visibleActions: [SuggestedAction] {
        finding.recommendedActions.filter {
            if case .requestStop(let identity) = $0 {
                guard let process = context.processes[identity] else { return false }
                if case .eligible = stopService.eligibility(of: process) { return true }
                return false
            }
            return true
        }
    }

    @ViewBuilder
    private func actionButton(_ action: SuggestedAction) -> some View {
        switch action {
        case .inspect(let identity):
            Button("Inspect details") { onInspect(identity) }
        case .openProject(let path):
            let exists = projectExists(path)
            Button("Open project") { openProject(path) }
                .disabled(!exists)
                .help(exists ? path : "Folder not found: \(path)")
        case .copyCommand(let identity):
            let command = Format.command(context.processes[identity]?.arguments)
            Button(copiedCommand ? "Copied" : "Copy command") {
                if let command {
                    Pasteboard.copy(command)
                    copiedCommand = true
                }
            }
            .disabled(command == nil)
            .help(command == nil ? "Command line not accessible" : "Copy the command line")
        case .openActivityMonitor:
            Button("Activity Monitor", action: openActivityMonitor)
        case .copyReport:
            Button("Copy report") { Pasteboard.copy(context.report.reportText) }
        case .requestStop(let identity):
            if let process = context.processes[identity] {
                Button("Request stop", role: .destructive) {
                    onRequestStop(StopTarget(identity: identity, process: process, project: context.project(for: identity)))
                }
            }
        }
    }
}

private struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// Wraps action buttons onto as many lines as the card width needs.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if size == .zero { continue }
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
